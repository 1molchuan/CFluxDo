import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../doh_proxy/doh_proxy_ffi.dart' show DohProxyFfi;
import '../doh_proxy/doh_proxy_service.dart' show DohProxyService;
import 'bootstrap_doh_client.dart' show dohUserAgent;
import 'connect_code_flow.dart';

/// 一种「LinuxDo Connect 换令牌」用途的约定：接口路径、令牌格式、手动授权的重试安排
///
/// 加速 DoH（AccelDohApi.policy）和 cfhub 探针（CfhubApi.policy）各一份；
/// 流程本身都在 [ConnectBoundToken]。
class ConnectTokenPolicy {
  ConnectTokenPolicy({
    required this.logTag,
    required this.tokenName,
    required this.startPath,
    required this.tokenPath,
    this.refreshPath,
    required this.revokePath,
    required this.tokenPattern,
    this.defaultLifetime,
    this.notFoundMeansUnavailable = false,
    this.retryDelays = const [],
    required this.connectRequestTag,
  });

  /// 日志前缀，如 `[DOH]`
  final String logTag;

  /// 日志里怎么称呼这种令牌，如「加速令牌」
  final String tokenName;

  /// 让服务端生成一次 Connect 授权地址（state 由服务端生成并记住）
  final String startPath;

  /// 用 Connect 回调里的 code/state 换令牌
  final String tokenPath;

  /// 令牌续期；没有续期的用途为 null
  final String? refreshPath;

  /// 作废令牌
  final String revokePath;

  /// 服务端发的令牌必须整段匹配，否则当失败
  final RegExp tokenPattern;

  /// 服务端没给 expires_in 时按这个有效期算；null 表示这种令牌不看有效期
  final Duration? defaultLifetime;

  /// 404 当作「服务端还没开放这个接口」，否则按普通失败
  final bool notFoundMeansUnavailable;

  /// 手动授权遇到网络类失败时整条链路重来前等多久，最多重来 `length` 次；
  /// 后台静默授权从不在这里重来，由调用方自己的退避接管
  final List<Duration> retryDelays;

  /// Connect 那几跳的请求标签（网络日志里区分用途）
  final String connectRequestTag;
}

/// 发给令牌服务端的一次 POST
class ConnectTokenRequest {
  const ConnectTokenRequest({
    required this.url,
    this.body,
    this.bearer,
    required this.oneShot,
  });

  final Uri url;
  final Map<String, Object?>? body;
  final String? bearer;

  /// 一次性请求（换码、续期）：Rust 侧超时时请求可能已经到了服务端，不能再用 Dart 重发
  final bool oneShot;

  String get path => url.path;
}

/// Rust 那条路：返回 null 表示 Rust 不可用或请求没成，改走 Dart
typedef ConnectTokenNativeSend =
    Future<(int, String)?> Function(ConnectTokenRequest request);

/// Dart 那条路：返回 (状态码, 响应正文)，失败直接抛
typedef ConnectTokenDartSend =
    Future<(int, String)> Function(ConnectTokenRequest request);

/// 令牌接口的传输：优先走 Rust 的 reqwest 客户端（和 DoH 查询同一套 TLS 栈），
/// Rust 那边失败（库没加载、请求异常、非一次性请求超时）再退回 Dart 自己的 HttpClient
///
/// 两条路都不经过 App 的 Dio，不会带上 linux.do 的 cookie；发过去的只有
/// Connect 回调里的 code/state 和服务端自己发的令牌。令牌值不写日志。
///
/// [native] / [dart] / [nativeTimeout] 只在测试里替换（假的 Rust / 假服务端）。
class ConnectTokenTransport {
  ConnectTokenTransport({
    required String baseUrl,
    this.logTag = '',
    HttpClient Function()? createClient,
    ConnectTokenNativeSend? native,
    ConnectTokenDartSend? dart,
    this.nativeTimeout = defaultNativeTimeout,
  }) : baseUri = _baseOf(baseUrl),
       _createClient = createClient ?? createDirectClient,
       _native = native ?? _sendViaRust,
       _dart = dart;

  /// Rust 路径的外层超时要盖过它内部的最坏情况（加速：reqwest 单次 10 s、连接层失败
  /// 换路再来一次；cfhub：经优选节点 2+3+8 s 再回退 reqwest 10 s），否则 Dart 这边
  /// 提前放弃、改用自己的客户端再发一次，一次性请求会被重复提交
  static const Duration defaultNativeTimeout = Duration(seconds: 25);

  static const Duration connectTimeout = Duration(seconds: 5);
  static const Duration _requestTimeout = Duration(seconds: 10);

  final Uri baseUri;
  final String logTag;
  final Duration nativeTimeout;
  final HttpClient Function() _createClient;
  final ConnectTokenNativeSend _native;
  final ConnectTokenDartSend? _dart;

  static Uri _baseOf(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  /// 独立客户端：不走代理、不存 cookie
  static HttpClient createDirectClient() => HttpClient()
    ..userAgent = dohUserAgent
    ..connectionTimeout = connectTimeout
    ..findProxy = ((_) => 'DIRECT');

  /// [oneShot] 为 true 时，Rust 侧超时直接抛出 [TimeoutException]，不退回 Dart 重发
  Future<(int, String)> post(
    String path, {
    Map<String, Object?>? body,
    String? bearer,
    required bool oneShot,
  }) async {
    final request = ConnectTokenRequest(
      url: baseUri.replace(path: path),
      body: body,
      bearer: bearer,
      oneShot: oneShot,
    );
    final native = await _tryNative(request);
    if (native != null) return native;
    return (_dart ?? _sendViaDart)(request);
  }

  Future<(int, String)?> _tryNative(ConnectTokenRequest request) async {
    try {
      return await _native(request).timeout(nativeTimeout);
    } on TimeoutException {
      if (request.oneShot) {
        debugPrint('$logTag Rust 侧请求超时，一次性请求不重发: ${request.path}');
        rethrow;
      }
      debugPrint('$logTag Rust 侧请求超时，改用 Dart 客户端: ${request.path}');
      return null;
    } catch (e) {
      debugPrint('$logTag Rust 侧请求失败，改用 Dart 客户端: ${request.path} $e');
      return null;
    }
  }

  static Future<(int, String)?> _sendViaRust(
    ConnectTokenRequest request,
  ) async {
    if (!DohProxyFfi.isAvailable) return null;
    final body = request.body;
    final bearer = request.bearer;
    final result = await DohProxyService.instance.accelRequest(
      'POST',
      request.url.toString(),
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
        if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    );
    if (result == null) return null;
    return (result.status, result.body);
  }

  Future<(int, String)> _sendViaDart(ConnectTokenRequest request) async {
    final client = _createClient();
    try {
      final http = await client
          .postUrl(request.url)
          .timeout(_requestTimeout);
      http.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final bearer = request.bearer;
      if (bearer != null) {
        http.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      final body = request.body;
      if (body != null) {
        http.headers.contentType = ContentType.json;
        http.write(jsonEncode(body));
      }
      final response = await http.close().timeout(_requestTimeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      return (response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }
}

enum ConnectTokenOutcome {
  /// 拿到令牌
  issued,

  /// 服务端明确拒绝（401/403）
  rejected,

  /// 服务端还没开放这个接口（404，仅 [ConnectTokenPolicy.notFoundMeansUnavailable]）
  serverUnavailable,

  /// 这个账号用不了 Connect（没有授权页，或同意后没拿到 code）
  connectUnavailable,

  /// 等结果期间换了号、退出或被调用方作废：结果已丢弃，拿到的令牌已作废
  stale,

  /// 网络或服务端异常，[ConnectTokenResult.failureDetail] 说明卡在哪一步
  failed,
}

class ConnectTokenResult {
  const ConnectTokenResult(this.outcome)
    : token = null,
      lifetime = null,
      failureDetail = null,
      retryable = false;

  const ConnectTokenResult.issued(String this.token, this.lifetime)
    : outcome = ConnectTokenOutcome.issued,
      failureDetail = null,
      retryable = false;

  const ConnectTokenResult.failed(String this.failureDetail)
    : outcome = ConnectTokenOutcome.failed,
      token = null,
      lifetime = null,
      retryable = true;

  final ConnectTokenOutcome outcome;
  final String? token;

  /// 令牌有效期；策略不看有效期且服务端没给时为 null
  final Duration? lifetime;

  /// 卡在哪一步（如 `start HTTP 403`、`connect failed`、`token TimeoutException`），
  /// 给界面提示用；不含任何敏感值
  final String? failureDetail;

  /// 网络类失败：整条链路重来是安全的（每次都是新的 state 和 code）
  final bool retryable;
}

/// 经 LinuxDo Connect 绑定账号的令牌：取授权地址 → Connect 授权 → 换码 → 续期 / 作废
///
/// 加速 DoH 与 cfhub 探针共用这一条流程，各自的差别只在 [ConnectTokenPolicy]
/// 和调用方的策略（何时授权、失败后怎么退避、令牌存哪）。这里负责：
/// - 只认 `https://connect.linux.do/oauth2/authorize…` 的授权地址；
/// - 换号守卫：每一步回来都核对发起时的账号和 [invalidate] 代数，变了就丢弃结果，
///   换码时已经拿到的令牌顺手作废；
/// - 作废先于重发：重新换码 / 续期前先等上一次作废落地（服务端可能按账号作废，
///   晚到的作废会把新令牌一起作废）；
/// - 手动授权遇到网络类失败整条链路重来，被拒 / 不可用 / 换号不重来；
/// - 一次性请求（换码、续期）在 Rust 侧超时后不经 Dart 重发（见 [ConnectTokenTransport]）。
///
/// [currentUserId] 返回现在登录的账号（没有为 null）；[sleep] 只在测试里替换重试等待。
class ConnectBoundToken {
  ConnectBoundToken({
    required this.policy,
    required ConnectTokenTransport transport,
    required ConnectCodeFlow Function() flow,
    required int? Function() currentUserId,
    Future<void> Function(Duration delay)? sleep,
  }) : _transport = transport,
       _flow = flow,
       _currentUserId = currentUserId,
       _sleep = sleep ?? _defaultSleep;

  /// 重新发令牌前最多等上一次作废这么久；作废本来就是尽力而为
  static const Duration revokeWait = Duration(seconds: 5);

  final ConnectTokenPolicy policy;
  final ConnectTokenTransport _transport;
  final ConnectCodeFlow Function() _flow;
  final int? Function() _currentUserId;
  final Future<void> Function(Duration delay) _sleep;

  /// [invalidate] 时自增，用来丢弃之前发出、之后才返回的结果
  int _epoch = 0;

  /// 还没落地的作废请求
  Future<void>? _pendingRevoke;

  String? _lastFailureDetail;

  /// 最近一次 [authorize] 失败卡在哪一步；没失败时为 null
  String? get lastFailureDetail => _lastFailureDetail;

  String get _tag => policy.logTag;

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  /// 退出登录、换号或用户关掉了功能：进行中的授权 / 续期结果一律丢弃
  void invalidate() => _epoch++;

  /// 为 [userId] 走一遍 Connect 换令牌
  ///
  /// [interactive] 为 true 是用户手动发起：Connect 撞盾弹验证页，网络类失败按
  /// [ConnectTokenPolicy.retryDelays] 整条链路重来。为 false 是后台静默授权：
  /// 只走一次，失败交给调用方的退避。
  Future<ConnectTokenResult> authorize({
    required int userId,
    required bool interactive,
  }) async {
    final guard = _Guard(_epoch, userId);
    final delays = interactive ? policy.retryDelays : const <Duration>[];
    var result = await _attempt(guard, interactive: interactive);
    for (final delay in delays) {
      if (!result.retryable) break;
      await _sleep(delay);
      if (!_isCurrent(guard)) {
        result = const ConnectTokenResult(ConnectTokenOutcome.stale);
        break;
      }
      debugPrint('$_tag 授权失败（${result.failureDetail}），整体重来');
      result = await _attempt(guard, interactive: interactive);
    }
    _lastFailureDetail = result.outcome == ConnectTokenOutcome.failed
        ? result.failureDetail
        : null;
    return result;
  }

  /// 令牌续期（只走一次）；401/403 说明旧令牌已失效，要重新走 Connect
  Future<ConnectTokenResult> refresh(
    String token, {
    required int userId,
  }) async {
    final path = policy.refreshPath;
    if (path == null) {
      throw UnsupportedError('${policy.tokenName}没有续期接口');
    }
    final guard = _Guard(_epoch, userId);
    if (_pendingRevoke != null) {
      await _awaitPendingRevoke();
      if (!_isCurrent(guard)) {
        return const ConnectTokenResult(ConnectTokenOutcome.stale);
      }
    }
    final result = await _issue('refresh', path, bearer: token);
    return _dropIfStale(guard, result);
  }

  /// 通知服务端作废令牌，尽力而为，失败不影响本地。下一次换码 / 续期会先等它落地
  Future<void> revoke(String token) {
    final sent = _sendRevoke(token);
    final previous = _pendingRevoke;
    _pendingRevoke = previous == null
        ? sent
        : Future.wait([previous, sent]).then((_) {});
    return sent;
  }

  bool _isCurrent(_Guard guard) =>
      guard.epoch == _epoch && _currentUserId() == guard.userId;

  /// 等结果期间退出或换了号：这个令牌不能留
  ConnectTokenResult _dropIfStale(_Guard guard, ConnectTokenResult result) {
    if (_isCurrent(guard)) return result;
    final token = result.token;
    if (token != null) unawaited(revoke(token));
    return const ConnectTokenResult(ConnectTokenOutcome.stale);
  }

  Future<ConnectTokenResult> _attempt(
    _Guard guard, {
    required bool interactive,
  }) async {
    if (!_isCurrent(guard)) {
      return const ConnectTokenResult(ConnectTokenOutcome.stale);
    }
    await _awaitPendingRevoke();
    if (!_isCurrent(guard)) {
      return const ConnectTokenResult(ConnectTokenOutcome.stale);
    }

    final start = await _start();
    if (!_isCurrent(guard)) {
      return const ConnectTokenResult(ConnectTokenOutcome.stale);
    }
    final authorizeUrl = start.url;
    if (authorizeUrl == null) return start.result!;

    final connect = await _flow().fetchCode(
      authorizeUrl,
      silent: !interactive,
      requestTag: policy.connectRequestTag,
    );
    if (!_isCurrent(guard)) {
      return const ConnectTokenResult(ConnectTokenOutcome.stale);
    }
    switch (connect.outcome) {
      case ConnectCodeOutcome.failed:
        return const ConnectTokenResult.failed('connect failed');
      case ConnectCodeOutcome.unavailable:
        debugPrint('$_tag Connect 授权没拿到 code，此账号用不了 Connect');
        return const ConnectTokenResult(
          ConnectTokenOutcome.connectUnavailable,
        );
      case ConnectCodeOutcome.code:
        break;
    }

    final result = await _issue(
      'token',
      policy.tokenPath,
      body: {'code': connect.code!, 'state': connect.state!},
    );
    return _dropIfStale(guard, result);
  }

  /// 只接受 https://connect.linux.do/oauth2/authorize...，其他地址一律当失败
  Future<_StartResult> _start() async {
    try {
      final (status, body) = await _transport.post(
        policy.startPath,
        body: const {},
        oneShot: false,
      );
      if (status == HttpStatus.notFound && policy.notFoundMeansUnavailable) {
        debugPrint('$_tag Connect 接口未开放 (404)');
        return const _StartResult.failed(
          ConnectTokenResult(ConnectTokenOutcome.serverUnavailable),
        );
      }
      if (status != HttpStatus.ok) {
        debugPrint('$_tag 获取 Connect 授权地址失败: HTTP $status');
        return _StartResult.failed(
          ConnectTokenResult.failed('start HTTP $status'),
        );
      }
      final json = jsonDecode(body);
      final raw = json is Map ? json['authorize_url'] : null;
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'connect.linux.do' ||
          !uri.path.startsWith('/oauth2/authorize')) {
        debugPrint('$_tag Connect 授权地址不对，忽略');
        return const _StartResult.failed(
          ConnectTokenResult.failed('start bad url'),
        );
      }
      return _StartResult.ok(uri);
    } catch (e) {
      debugPrint('$_tag 获取 Connect 授权地址失败: $e');
      return _StartResult.failed(
        ConnectTokenResult.failed('start ${e.runtimeType}'),
      );
    }
  }

  /// 换码 / 续期：都是一次性请求，[step] 写进失败说明
  Future<ConnectTokenResult> _issue(
    String step,
    String path, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    try {
      final (status, text) = await _transport.post(
        path,
        body: body,
        bearer: bearer,
        oneShot: true,
      );
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        debugPrint('$_tag 服务端拒绝发放${policy.tokenName}: $path HTTP $status');
        return const ConnectTokenResult(ConnectTokenOutcome.rejected);
      }
      if (status == HttpStatus.notFound && policy.notFoundMeansUnavailable) {
        debugPrint('$_tag 令牌接口未开放 (404): $path');
        return const ConnectTokenResult(ConnectTokenOutcome.serverUnavailable);
      }
      if (status != HttpStatus.ok) {
        debugPrint('$_tag 申请${policy.tokenName}失败: $path HTTP $status');
        return ConnectTokenResult.failed('$step HTTP $status');
      }
      final json = jsonDecode(text);
      final token = json is Map ? json['token'] : null;
      if (token is! String || !policy.tokenPattern.hasMatch(token)) {
        debugPrint('$_tag ${policy.tokenName}格式不对，忽略');
        return ConnectTokenResult.failed('$step bad body');
      }
      final expiresIn = json['expires_in'];
      final lifetime = expiresIn is num && expiresIn > 0
          ? Duration(seconds: expiresIn.toInt())
          : policy.defaultLifetime;
      debugPrint(
        lifetime == null
            ? '$_tag 已拿到${policy.tokenName}'
            : '$_tag 已拿到${policy.tokenName}，有效期 ${lifetime.inMinutes} 分钟',
      );
      return ConnectTokenResult.issued(token, lifetime);
    } catch (e) {
      debugPrint('$_tag 申请${policy.tokenName}失败: $path $e');
      return ConnectTokenResult.failed('$step ${e.runtimeType}');
    }
  }

  Future<void> _sendRevoke(String token) async {
    try {
      await _transport.post(policy.revokePath, bearer: token, oneShot: false);
    } catch (e) {
      debugPrint('$_tag 作废${policy.tokenName}失败(忽略): $e');
    }
  }

  /// 等上一次的作废请求结束（最多 [revokeWait]，失败也不管），避免它压掉随后发的新令牌
  Future<void> _awaitPendingRevoke() async {
    final pending = _pendingRevoke;
    if (pending == null) return;
    try {
      await pending.timeout(revokeWait);
    } catch (_) {
      // 作废本来就是尽力而为
    }
    if (identical(_pendingRevoke, pending)) _pendingRevoke = null;
  }
}

/// 发起时的账号和代数
class _Guard {
  const _Guard(this.epoch, this.userId);

  final int epoch;
  final int userId;
}

class _StartResult {
  const _StartResult.ok(Uri this.url) : result = null;

  const _StartResult.failed(ConnectTokenResult this.result) : url = null;

  final Uri? url;
  final ConnectTokenResult? result;
}
