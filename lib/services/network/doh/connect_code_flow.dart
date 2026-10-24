import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../../oauth_flow_helper.dart';
import '../../site_context.dart';
import '../cf/cf_challenge_classifier.dart';
import '../discourse_dio.dart';
import '../exceptions/api_exception.dart';
import '../flux_request_spec.dart';

enum ConnectCodeOutcome {
  /// 拿到了回调里的 code/state
  code,

  /// 这个账号用不了 Connect（没有授权页，或 Connect 直接报错）
  unavailable,

  /// 撞 CF 盾后用户关掉了验证页（或验证没完成）
  cancelled,

  /// 网络问题或撞盾没过，[ConnectCodeResult.failureDetail] 说明是哪种
  failed,
}

class ConnectCodeResult {
  const ConnectCodeResult.code(String this.code, String this.state)
    : outcome = ConnectCodeOutcome.code,
      failureDetail = null,
      retryable = false;

  const ConnectCodeResult.unavailable()
    : outcome = ConnectCodeOutcome.unavailable,
      code = null,
      state = null,
      failureDetail = null,
      retryable = false;

  const ConnectCodeResult.cancelled()
    : outcome = ConnectCodeOutcome.cancelled,
      code = null,
      state = null,
      failureDetail = null,
      retryable = false;

  const ConnectCodeResult.failed({
    String this.failureDetail = 'failed',
    this.retryable = true,
  }) : outcome = ConnectCodeOutcome.failed,
       code = null,
       state = null;

  final ConnectCodeOutcome outcome;
  final String? code;
  final String? state;

  /// 失败时卡在哪（`HTTP 404` / `challenge` / `connectionTimeout`），拼在 `connect ` 后面
  final String? failureDetail;

  /// 网络类失败可以整体重来；撞盾没过马上重来还会撞同一个盾，不算
  final bool retryable;
}

/// 在 App 里走一遍 LinuxDo Connect 授权，拿到回调里的 code/state
///
/// 加速 DoH 和 cfhub 探针共用。只有发往 linux.do 系域名的请求走 App 的 Dio
/// （带 L 站登录态，用来证明身份）。跳回令牌服务端的那一跳不会真的发出去，
/// 只从 Location 里取 code/state，再由 ConnectBoundToken 交给服务端。
class ConnectCodeFlow {
  static const int _maxRedirects = 8;

  Dio? _dio;

  /// 按业务 API 链路建：撞 CF 盾时走过盾恢复（换值重放 / 验证 / 兼容模式）
  Dio get _client => _dio ??= DiscourseDio.create(kind: DiscourseDioKind.api);

  /// [silent] 为 true 时是后台自动续期：不弹错误提示，CF 盾只在后台验证。
  /// [requestTag] 写进网络日志，区分是哪种用途在走 Connect
  Future<ConnectCodeResult> fetchCode(
    Uri authorizeUrl, {
    bool silent = true,
    String requestTag = 'accel_doh_connect',
  }) async {
    if (!SiteContext.isLinuxDo) return const ConnectCodeResult.unavailable();
    try {
      // 模拟"业务页加载完成 → 跳转到授权页"的导航延迟
      await OAuthFlowHelper.humanGap(minMs: 800, maxMs: 1500);

      var uri = authorizeUrl;
      var response = await _get(uri, silent: silent, requestTag: requestTag);
      for (var hop = 0; ; hop++) {
        final next = _redirectTarget(response, uri);
        if (next == null) break;
        // 之前授权过的应用，Connect 可能直接跳回回调地址
        final callback = _callbackOf(next);
        if (callback != null) return callback;
        if (!_isLinuxDoHost(next.host) || hop >= _maxRedirects) {
          debugPrint('[CONNECT] Connect 授权跳到了意外的地址: ${next.host}');
          return const ConnectCodeResult.unavailable();
        }
        uri = next;
        response = await _get(uri, silent: silent, requestTag: requestTag);
      }

      if (response.statusCode != 200) {
        debugPrint('[CONNECT] Connect 授权页打不开: HTTP ${response.statusCode}');
        return ConnectCodeResult.failed(
          failureDetail: 'HTTP ${response.statusCode}',
        );
      }
      final data = response.data;
      final approveLink = html_parser
          .parse(data is String ? data : '')
          .querySelector('a[href*="/oauth2/approve/"]')
          ?.attributes['href'];
      if (approveLink == null) {
        debugPrint('[CONNECT] Connect 授权页没有同意按钮，当作此账号不能用 Connect');
        return const ConnectCodeResult.unavailable();
      }
      final approveUri = uri.resolve(approveLink);
      if (approveUri.scheme != 'https' || approveUri.host != uri.host) {
        return const ConnectCodeResult.unavailable();
      }

      // 模拟点击同意的反应时间
      await OAuthFlowHelper.humanGap(minMs: 600, maxMs: 1200);

      // 这一跳会跳到令牌服务端，不能把 Set-Cookie 另存到那个域名下
      final approveResponse = await _get(
        approveUri,
        silent: silent,
        requestTag: requestTag,
        allowRedirectSetCookie: false,
      );
      final next = _redirectTarget(approveResponse, approveUri);
      final callback = next == null ? null : _callbackOf(next);
      if (callback == null) {
        debugPrint('[CONNECT] Connect 同意后没有拿到 code');
        return const ConnectCodeResult.unavailable();
      }

      // 模拟浏览器跳回业务方的延迟
      await OAuthFlowHelper.humanGap(minMs: 400, maxMs: 900);
      return callback;
    } on DioException catch (e) {
      debugPrint('[CONNECT] Connect 授权请求失败: ${e.type} ${e.message}');
      return classifyFailure(e);
    }
  }

  /// Connect 那几跳的请求失败归类（撞盾判定统一问 [CfChallengeClassifier]）
  @visibleForTesting
  static ConnectCodeResult classifyFailure(DioException e) {
    final cf = e.error;
    if (cf is CfChallengeException && cf.userCancelled) {
      // 过盾验证页被用户关掉或没完成：CF 那边已经提示过，当用户取消
      return const ConnectCodeResult.cancelled();
    }
    if (CfChallengeClassifier.isChallengeFailure(e)) {
      // 过盾恢复（换值重放 / 验证 / 兼容模式）走完仍被拦：马上重来还会撞同一个盾
      return const ConnectCodeResult.failed(
        failureDetail: 'challenge',
        retryable: false,
      );
    }
    final status = e.response?.statusCode;
    return ConnectCodeResult.failed(
      failureDetail: status != null ? 'HTTP $status' : e.type.name,
    );
  }

  /// 每一跳都手动处理：自动跟随会把回调地址也请求一遍
  Future<Response<dynamic>> _get(
    Uri uri, {
    required bool silent,
    required String requestTag,
    bool allowRedirectSetCookie = true,
  }) {
    return _client.getUri<dynamic>(
      uri,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.plain,
        // CF 的挑战页无论被 validateStatus 放行还是判成错误，都由
        // CfChallengeInterceptor 截下过盾后重放（CfChallengeClassifier 统一判定）。
        // 这里只放行 2xx/3xx：其余 4xx/5xx 按错误走，不当授权页解析
        validateStatus: (status) => status != null && status < 400,
        extra: {
          FluxRequestKeys.skipCsrf: true,
          FluxRequestKeys.skipRedirect: true,
          FluxRequestKeys.skipAuthCheck: true,
          FluxRequestKeys.allowRedirectSetCookie: allowRedirectSetCookie,
          FluxRequestKeys.isSilent: silent,
          // 用户手动授权时按「操作」对待：撞 CF 盾弹验证页让用户过盾，
          // 而不是像数据请求那样静默失败让用户再点一次
          if (!silent) FluxRequestKeys.showErrorToast: true,
          FluxRequestKeys.requestTag: requestTag,
        },
      ),
    );
  }

  static Uri? _redirectTarget(Response<dynamic> response, Uri from) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value('location');
    if (location == null || location.isEmpty) return null;
    return from.resolve(location);
  }

  /// 跳出 linux.do、带着 code 和 state 的地址就是授权回调
  static ConnectCodeResult? _callbackOf(Uri uri) {
    if (_isLinuxDoHost(uri.host)) return null;
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    if (code == null || code.isEmpty || state == null || state.isEmpty) {
      return null;
    }
    return ConnectCodeResult.code(code, state);
  }

  static bool _isLinuxDoHost(String host) =>
      host == 'linux.do' || host.endsWith('.linux.do');
}
