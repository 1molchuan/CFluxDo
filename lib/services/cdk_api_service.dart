import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cdk_project.dart';
import 'app_logger.dart';
import 'cdk_oauth_service.dart';
import 'network/discourse_dio.dart';
import 'network/exceptions/oauth_exception.dart';
import 'site_context.dart';

/// CDK 站业务错误：后端 `{error_msg}` 原样给用户看（中文，如「项目未开始」「已领取」）
class CdkApiException implements Exception {
  const CdkApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// hCaptcha 令牌被拒（失效 / sitekey 不对）：清掉缓存的 sitekey 下次重新发现
  bool get isCaptchaRejected =>
      message.contains('验证码') || message.contains('人机验证');

  @override
  String toString() => message;
}

/// cdk.linux.do 的原生接口：领取记录、项目详情、领取、待支付订单。
///
/// 会话沿用 [CdkOAuthService] 授权得到的 `linux_do_cdk_session_id`（Cookie 由
/// DiscourseDio 的 CookieManager 带上），CF 那层与主站共用 `.linux.do` 的
/// cf_clearance。写请求必须带 `X-Requested-With: XMLHttpRequest`（后端 CSRF 只看它）。
///
/// 领取要 hCaptcha 令牌：校验在 CDK 前端的 Next.js 中间件里（拿令牌去
/// hcaptcha.com/siteverify），和 CF 盾无关，每次领取都要一枚新的。sitekey 在容器
/// 启动时才注入前端脚本，见 [hcaptchaSiteKey]。
class CdkApiService {
  CdkApiService({Dio? dio}) : _dio = dio ?? DiscourseDio.create();

  static const String baseUrl = CdkOAuthService.baseUrl;
  static const String _siteKeyPrefsKey = 'cdk_hcaptcha_sitekey';
  static const Duration _siteKeyTtl = Duration(days: 7);

  final Dio _dio;

  Options _options({bool write = false}) => Options(
    followRedirects: false,
    headers: write ? const {'X-Requested-With': 'XMLHttpRequest'} : null,
    extra: const {
      'skipCsrf': true,
      'showErrorToast': false,
      'skipRedirect': true,
    },
  );

  void _ensureSite() {
    if (!SiteContext.isLinuxDo) {
      throw UnsupportedError('仅 LINUX DO 支持 CDK');
    }
  }

  /// 统一拆 `{error_msg, data}`；401 视为授权过期，CF 质询交给上层的过盾提示
  Future<Object?> _call(Future<Response<dynamic>> Function() send) async {
    _ensureSite();
    final Response<dynamic> response;
    try {
      response = await send();
    } on DioException catch (e) {
      final classified = OAuthErrorPolicy.classify(e, serviceName: 'CDK');
      if (!identical(classified, e)) throw classified;
      final message = _errorMessage(e.response?.data);
      if (message != null) {
        throw CdkApiException(message, statusCode: e.response?.statusCode);
      }
      rethrow;
    }
    final body = response.data;
    final message = _errorMessage(body);
    if (message != null) {
      throw CdkApiException(message, statusCode: response.statusCode);
    }
    return body is Map ? body['data'] : null;
  }

  static String? _errorMessage(Object? body) {
    if (body is String && body.trimLeft().startsWith('{')) {
      try {
        body = jsonDecode(body);
      } catch (_) {
        return null;
      }
    }
    if (body is! Map) return null;
    final msg = body['error_msg'];
    return msg is String && msg.isNotEmpty ? msg : null;
  }

  /// 领取记录（新的在前）。[page] 从 1 开始，[size] ≤ 100
  Future<CdkReceivedPage> receivedHistory({
    int page = 1,
    int size = 20,
    String? search,
  }) async {
    final data = await _call(
      () => _dio.get<dynamic>(
        '$baseUrl/api/v1/projects/received',
        queryParameters: {
          'current': page,
          'size': size,
          if (search != null && search.trim().isNotEmpty)
            'search': search.trim(),
        },
        options: _options(),
      ),
    );
    return data is Map<String, dynamic>
        ? CdkReceivedPage.fromJson(data)
        : const CdkReceivedPage(total: 0, items: []);
  }

  Future<CdkProject> project(String id) async {
    final data = await _call(
      () => _dio.get<dynamic>(
        '$baseUrl/api/v1/projects/${Uri.encodeComponent(id)}',
        options: _options(),
      ),
    );
    if (data is! Map<String, dynamic>) {
      throw const FormatException('CDK 项目详情响应缺少 data');
    }
    return CdkProject.fromJson(data);
  }

  Future<CdkPendingPayment> pendingPayment(String id) async {
    final data = await _call(
      () => _dio.get<dynamic>(
        '$baseUrl/api/v1/projects/${Uri.encodeComponent(id)}/pending-payment',
        options: _options(),
      ),
    );
    return data is Map<String, dynamic>
        ? CdkPendingPayment.fromJson(data)
        : const CdkPendingPayment(hasPending: false, payUrl: '', amount: '');
  }

  /// 领取。[captchaToken] 来自 hCaptcha 验证层，一次性
  Future<CdkReceiveResult> receive(String id, String captchaToken) async {
    try {
      final data = await _call(
        () => _dio.post<dynamic>(
          '$baseUrl/api/v1/projects/${Uri.encodeComponent(id)}/receive',
          data: {'captcha_token': captchaToken},
          options: _options(write: true),
        ),
      );
      if (data is! Map<String, dynamic>) {
        throw const FormatException('CDK 领取响应缺少 data');
      }
      return CdkReceiveResult.fromJson(data);
    } on CdkApiException catch (e) {
      if (e.isCaptchaRejected) await forgetSiteKey();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // hCaptcha sitekey
  // ---------------------------------------------------------------------------

  /// hCaptcha 的 sitekey。CDK 前端镜像在容器启动时把它替换进 Next.js 脚本
  /// （entrypoint.sh 的 replace_placeholder），源码里没有，只能从线上脚本里读：
  /// 取领取页 HTML → 脚本列表 → 找到含 hCaptcha 的那块 → 匹配 sitekey。
  /// 结果缓存 [_siteKeyTtl]；领取时被判验证码无效就清掉重来（站方换 key 能自愈）。
  Future<String?> hcaptchaSiteKey(String projectId) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = _readCachedSiteKey(prefs);
    if (cached != null) return cached;

    final key = await _discoverSiteKey(projectId);
    if (key != null) {
      await prefs.setString(
        _siteKeyPrefsKey,
        jsonEncode({'key': key, 'at': DateTime.now().millisecondsSinceEpoch}),
      );
    }
    return key;
  }

  Future<void> forgetSiteKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_siteKeyPrefsKey);
  }

  static String? _readCachedSiteKey(SharedPreferences prefs) {
    final raw = prefs.getString(_siteKeyPrefsKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(map['at'] as int);
      if (DateTime.now().difference(at) > _siteKeyTtl) return null;
      final key = map['key'];
      return key is String && isSiteKey(key) ? key : null;
    } catch (_) {
      return null;
    }
  }

  static final RegExp _uuid = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  );

  static bool isSiteKey(String value) =>
      _uuid.hasMatch(value) && _uuid.firstMatch(value)!.group(0) == value;

  /// 从一段前端脚本里认出 sitekey：优先 `sitekey…"<uuid>"` 紧挨着的写法；
  /// 否则在提到 hcaptcha 的脚本里只有一个 uuid 时取它
  static String? extractSiteKey(String script) {
    final near = RegExp(
      r'''sitekey[^"'`]{0,80}["'`]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})["'`]''',
      caseSensitive: false,
    ).firstMatch(script);
    if (near != null) return near.group(1);
    if (!script.toLowerCase().contains('hcaptcha')) return null;
    final all = {for (final m in _uuid.allMatches(script)) m.group(0)!};
    return all.length == 1 ? all.first : null;
  }

  /// 领取页 HTML 里引用的 Next.js 脚本，领取页自己的那块排在最前。
  ///
  /// App Router 的页面脚本不在 `<script src>` 里，而是写在 RSC 数据
  /// （`self.__next_f.push(...)`）中，形如 `static/chunks/app/(main)/receive/
  /// %5BprojectId%5D/page-xxx.js`、不带 `/_next/` 前缀（2026-11-17 线上实测，
  /// sitekey 就在这一块）。两种写法都收，统一补成 `/_next/static/…`
  static List<String> scriptPaths(String html) {
    final paths = <String>{
      for (final m in RegExp(
        r'''(?:/_next/)?(static/chunks/[^"'\\\s?]+\.js)''',
      ).allMatches(html))
        '/_next/${m.group(1)!}',
    }.toList();
    int rank(String p) {
      final decoded = Uri.decodeFull(p);
      if (decoded.contains('receive')) return 0;
      if (decoded.contains('/app/')) return 1;
      return 2;
    }

    paths.sort((a, b) => rank(a).compareTo(rank(b)));
    return paths;
  }

  Future<String?> _discoverSiteKey(String projectId) async {
    _ensureSite();
    final textOptions = Options(
      responseType: ResponseType.plain,
      followRedirects: true,
      headers: const {'Accept': 'text/html,*/*'},
      extra: const {'skipCsrf': true, 'showErrorToast': false},
    );
    try {
      final page = await _dio.get<String>(
        '$baseUrl/receive/${Uri.encodeComponent(projectId)}',
        options: textOptions,
      );
      final html = page.data ?? '';
      final inline = extractSiteKey(html);
      if (inline != null) return inline;
      // 最多看 20 块，领取页那块通常第一个就中
      for (final path in scriptPaths(html).take(20)) {
        final script = await _dio.get<String>(
          '$baseUrl$path',
          options: textOptions,
        );
        final key = extractSiteKey(script.data ?? '');
        if (key != null) return key;
      }
      AppLogger.warning('CDK 领取页脚本里没找到 hCaptcha sitekey', tag: 'CDK');
    } on DioException catch (e) {
      AppLogger.warning(
        'CDK hCaptcha sitekey 获取失败：${e.type.name} ${e.response?.statusCode ?? ''}',
        tag: 'CDK',
      );
    }
    return null;
  }
}
