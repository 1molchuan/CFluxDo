import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../doh_proxy/doh_proxy_ffi.dart' show DohProxyFfi;
import '../doh_proxy/doh_proxy_service.dart' show DohProxyService;
import 'bootstrap_doh_client.dart' show dohUserAgent;

/// 发请求的函数：测试时注入假实现。返回 (状态码, 响应正文)
typedef CfhubPost =
    Future<(int, String)> Function(
      String path, {
      Map<String, Object?>? body,
      String? bearer,
    });

/// 向 cfhub 要 Connect 授权地址的结果
class CfhubStartResult {
  const CfhubStartResult.ok(Uri this.url) : unavailable = false;

  /// cfhub 还没开放这个接口（404）
  const CfhubStartResult.unavailable() : url = null, unavailable = true;

  /// 网络问题、服务端异常或地址不合法
  const CfhubStartResult.failed() : url = null, unavailable = false;

  final Uri? url;
  final bool unavailable;
}

/// 用 Connect 回调换探针令牌的结果
enum CfhubTokenOutcome {
  /// 拿到令牌
  ok,

  /// 服务端明确拒绝（401/403）
  rejected,

  /// 接口未开放（404）
  unavailable,

  /// 网络或服务端异常，稍后再试
  failed,
}

class CfhubTokenResult {
  const CfhubTokenResult.ok(String this.token) : outcome = CfhubTokenOutcome.ok;

  const CfhubTokenResult.rejected()
    : outcome = CfhubTokenOutcome.rejected,
      token = null;

  const CfhubTokenResult.unavailable()
    : outcome = CfhubTokenOutcome.unavailable,
      token = null;

  const CfhubTokenResult.failed()
    : outcome = CfhubTokenOutcome.failed,
      token = null;

  final CfhubTokenOutcome outcome;
  final String? token;
}

/// cfhub（众包 ECH 测速分池）的探针令牌接口
///
/// 和 [AccelDohApi] 一样：优先走 Rust 的 reqwest 客户端（与 DoH 查询同一套 TLS 栈），
/// 失败再退回 Dart 自己的 HttpClient。两条路都不经过 App 的 Dio，
/// 不会带上 linux.do 的 cookie；发过去的只有 Connect 回调里的 code/state
/// 和 cfhub 自己发的令牌。令牌值不写日志。
class CfhubApi {
  CfhubApi({String baseUrl = defaultBaseUrl, CfhubPost? post})
    : _baseUri = _baseOf(baseUrl),
      _customPost = post;

  /// cfhub 的主机名，探针上报和令牌接口都在这里
  static const String host = 'cfhub6.1molchuan.top';
  static const String defaultBaseUrl = 'https://$host';

  static const String _startPath = '/api/v1/app/connect/start';
  static const String _tokenPath = '/api/v1/app/token';
  static const String _revokePath = '/api/v1/app/token/revoke';

  static const Duration _connectTimeout = Duration(seconds: 5);
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Rust 路径的外层超时要盖过它内部的最坏情况（经优选节点 2+3+8 s，再回退 reqwest 10 s），
  /// 否则 Dart 这边提前放弃、改用自己的客户端再发一次，令牌换码那一步的一次性 code 会被烧掉
  static const Duration _nativeTimeout = Duration(seconds: 25);

  /// 探针令牌固定以 cfp_ 开头，其余是可打印 ASCII
  static final RegExp _tokenPattern = RegExp(r'^cfp_[\x21-\x7E]{1,4096}$');

  final Uri _baseUri;
  final CfhubPost? _customPost;

  /// 最近一次失败卡在哪一步（如 `start HTTP 403`、`token 网络错误`），给界面提示用；不含任何敏感值
  String? lastFailure;

  static Uri _baseOf(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  /// 让 cfhub 生成一次 Connect 授权地址（state 由服务端生成并记住）
  ///
  /// 只接受 https://connect.linux.do/oauth2/authorize...，其他地址一律当失败
  Future<CfhubStartResult> startConnect() async {
    try {
      final (status, body) = await _send(_startPath, body: const {});
      if (status == HttpStatus.notFound) {
        debugPrint('[CFHUB] Connect 接口未开放 (404)');
        return const CfhubStartResult.unavailable();
      }
      if (status != HttpStatus.ok) {
        debugPrint('[CFHUB] 获取 Connect 授权地址失败: HTTP $status');
        lastFailure = 'start HTTP $status';
        return const CfhubStartResult.failed();
      }
      final json = jsonDecode(body);
      final raw = json is Map ? json['authorize_url'] : null;
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'connect.linux.do' ||
          !uri.path.startsWith('/oauth2/authorize')) {
        debugPrint('[CFHUB] Connect 授权地址不对，忽略');
        lastFailure = 'start bad url';
        return const CfhubStartResult.failed();
      }
      lastFailure = null;
      return CfhubStartResult.ok(uri);
    } catch (e) {
      debugPrint('[CFHUB] 获取 Connect 授权地址失败: $e');
      lastFailure = 'start ${e.runtimeType}';
      return const CfhubStartResult.failed();
    }
  }

  /// 用 Connect 回调里的 code/state 换探针令牌，cfhub 负责去 Connect 核验身份
  Future<CfhubTokenResult> exchangeCode(String code, String state) async {
    try {
      final (status, text) = await _send(
        _tokenPath,
        body: {'code': code, 'state': state},
      );
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        debugPrint('[CFHUB] cfhub 拒绝发放探针令牌: HTTP $status');
        return const CfhubTokenResult.rejected();
      }
      if (status == HttpStatus.notFound) {
        debugPrint('[CFHUB] 令牌接口未开放 (404)');
        return const CfhubTokenResult.unavailable();
      }
      if (status != HttpStatus.ok) {
        debugPrint('[CFHUB] 申请探针令牌失败: HTTP $status');
        lastFailure = 'token HTTP $status';
        return const CfhubTokenResult.failed();
      }
      final json = jsonDecode(text);
      final token = json is Map ? json['token'] : null;
      if (token is! String || !_tokenPattern.hasMatch(token)) {
        debugPrint('[CFHUB] 探针令牌格式不对，忽略');
        lastFailure = 'token bad body';
        return const CfhubTokenResult.failed();
      }
      debugPrint('[CFHUB] 已拿到探针令牌');
      lastFailure = null;
      return CfhubTokenResult.ok(token);
    } catch (e) {
      debugPrint('[CFHUB] 申请探针令牌失败: $e');
      lastFailure = 'token ${e.runtimeType}';
      return const CfhubTokenResult.failed();
    }
  }

  /// 通知 cfhub 作废令牌，尽力而为，失败不影响本地
  Future<void> revoke(String token) async {
    try {
      await _send(_revokePath, bearer: token);
    } catch (e) {
      debugPrint('[CFHUB] 作废探针令牌失败(忽略): $e');
    }
  }

  Future<(int, String)> _send(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) {
    final custom = _customPost;
    if (custom != null) return custom(path, body: body, bearer: bearer);
    return _post(path, body: body, bearer: bearer);
  }

  Future<(int, String)> _post(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    // 有 Rust 库的平台走 Rust 的 reqwest 客户端；Rust 那边失败再退回 Dart 的 HttpClient
    if (DohProxyFfi.isAvailable) {
      final native = await _postViaNative(path, body: body, bearer: bearer);
      if (native != null) return native;
    }
    final client = _createClient();
    try {
      final request = await client
          .postUrl(_baseUri.replace(path: path))
          .timeout(_requestTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(_requestTimeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      return (response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, String)?> _postViaNative(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'application/json',
      if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
      if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
    };
    try {
      final result = await DohProxyService.instance
          .accelRequest(
            'POST',
            _baseUri.replace(path: path).toString(),
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(_nativeTimeout);
      if (result == null) return null;
      return (result.status, result.body);
    } catch (e) {
      debugPrint('[CFHUB] Rust 侧请求 cfhub 失败，改用 Dart 客户端: $path $e');
      return null;
    }
  }

  /// 独立客户端：不走代理、不存 cookie
  HttpClient _createClient() {
    return HttpClient()
      ..userAgent = dohUserAgent
      ..connectionTimeout = _connectTimeout
      ..findProxy = ((_) => 'DIRECT');
  }
}
