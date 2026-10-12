import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bootstrap_doh_client.dart' show dohUserAgent;

/// 加速服务端发令牌的结果
enum AccelDohIssueOutcome {
  /// 拿到令牌
  issued,

  /// 服务端明确拒绝（401/403）
  rejected,

  /// 网络或服务端异常，稍后再试
  failed,
}

class AccelDohIssueResult {
  const AccelDohIssueResult.issued(String this.token, Duration this.lifetime)
    : outcome = AccelDohIssueOutcome.issued;

  const AccelDohIssueResult.rejected()
    : outcome = AccelDohIssueOutcome.rejected,
      token = null,
      lifetime = null;

  const AccelDohIssueResult.failed()
    : outcome = AccelDohIssueOutcome.failed,
      token = null,
      lifetime = null;

  final AccelDohIssueOutcome outcome;
  final String? token;
  final Duration? lifetime;
}

/// cfluxdo 加速服务端的令牌接口
///
/// 走独立的 HttpClient，不经过 App 的 Dio，不会带上 linux.do 的 cookie。
/// 发过去的只有 Connect 回调里的 code/state 和服务端自己发的令牌。
class AccelDohApi {
  AccelDohApi({required String serverUrl, required List<String> bootstrapIps})
    : _baseUri = _baseOf(serverUrl),
      _bootstrapIps = bootstrapIps;

  final Uri _baseUri;
  final List<String> _bootstrapIps;

  static const Duration _connectTimeout = Duration(seconds: 5);
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// 服务端没给 expires_in 时按这个有效期算
  static const Duration _defaultLifetime = Duration(hours: 24);

  static final RegExp _tokenPattern = RegExp(r'^[\x21-\x7E]{1,4096}$');

  static Uri _baseOf(String serverUrl) {
    final uri = Uri.parse(serverUrl);
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  /// 让服务端生成一次 Connect 授权地址（state 由服务端生成并记住）
  ///
  /// 只接受 https://connect.linux.do/oauth2/authorize，其他地址一律当失败
  Future<Uri?> startConnect() async {
    try {
      final (status, body) = await _post('/v1/connect/start', body: const {});
      if (status != HttpStatus.ok) {
        debugPrint('[DOH] 获取 Connect 授权地址失败: HTTP $status');
        return null;
      }
      final json = jsonDecode(body);
      final raw = json is Map ? json['authorize_url'] : null;
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'connect.linux.do' ||
          !uri.path.startsWith('/oauth2/authorize')) {
        debugPrint('[DOH] Connect 授权地址不对，忽略');
        return null;
      }
      return uri;
    } catch (e) {
      debugPrint('[DOH] 获取 Connect 授权地址失败: $e');
      return null;
    }
  }

  /// 用 Connect 回调里的 code/state 换加速令牌，服务端负责去 Connect 核验身份
  Future<AccelDohIssueResult> exchangeCode({
    required String code,
    required String state,
  }) => _issue('/v1/token', body: {'code': code, 'state': state});

  /// 令牌续期；401/403 说明旧令牌已失效，要重新走 Connect
  Future<AccelDohIssueResult> refresh(String token) =>
      _issue('/v1/token/refresh', bearer: token);

  /// 通知服务端作废令牌，尽力而为，失败不影响本地
  Future<void> revoke(String token) async {
    try {
      await _post('/v1/token/revoke', bearer: token);
    } catch (e) {
      debugPrint('[DOH] 作废加速令牌失败(忽略): $e');
    }
  }

  Future<AccelDohIssueResult> _issue(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    try {
      final (status, text) = await _post(path, body: body, bearer: bearer);
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        debugPrint('[DOH] 加速服务端拒绝发放令牌: $path HTTP $status');
        return const AccelDohIssueResult.rejected();
      }
      if (status != HttpStatus.ok) {
        debugPrint('[DOH] 申请加速令牌失败: $path HTTP $status');
        return const AccelDohIssueResult.failed();
      }
      final json = jsonDecode(text);
      final token = json is Map ? json['token'] : null;
      if (token is! String || !_tokenPattern.hasMatch(token)) {
        debugPrint('[DOH] 加速令牌格式不对，忽略');
        return const AccelDohIssueResult.failed();
      }
      final expiresIn = json['expires_in'];
      final lifetime = expiresIn is num && expiresIn > 0
          ? Duration(seconds: expiresIn.toInt())
          : _defaultLifetime;
      debugPrint('[DOH] 已拿到加速令牌，有效期 ${lifetime.inMinutes} 分钟');
      return AccelDohIssueResult.issued(token, lifetime);
    } catch (e) {
      debugPrint('[DOH] 申请加速令牌失败: $path $e');
      return const AccelDohIssueResult.failed();
    }
  }

  Future<(int, String)> _post(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final client = _createClient();
    try {
      final request = await client
          .postUrl(_baseUri.replace(path: path))
          .timeout(_requestTimeout);
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

  HttpClient _createClient() {
    final bootstrapIps = _bootstrapIps;
    return HttpClient()
      ..userAgent = dohUserAgent
      ..connectionTimeout = _connectTimeout
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) async =>
          ConnectionTask.fromSocket(
            _connectSecure(uri.host, uri.port, bootstrapIps),
            () {},
          );
  }

  /// 先按系统 DNS 连；解析不出或连不上时直连加速节点 IP（SNI 仍是加速域名）
  static Future<Socket> _connectSecure(
    String host,
    int port,
    List<String> bootstrapIps,
  ) async {
    final targets = <Object>[
      host,
      ...bootstrapIps
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>(),
    ];
    Object? lastError;
    for (final target in targets) {
      Socket? raw;
      try {
        raw = await Socket.connect(target, port, timeout: _connectTimeout);
        return await SecureSocket.secure(
          raw,
          host: host,
        ).timeout(_connectTimeout);
      } catch (e) {
        raw?.destroy();
        lastError = e;
      }
    }
    throw lastError ?? SocketException('无法连接 $host');
  }
}
