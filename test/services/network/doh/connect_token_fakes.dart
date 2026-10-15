import 'dart:async';
import 'dart:convert';

import 'package:fluxdo/services/network/doh/connect_bound_token.dart';
import 'package:fluxdo/services/network/doh/connect_code_flow.dart';

/// 假令牌服务端收到的一次请求
class FakeTokenCall {
  const FakeTokenCall(this.path, this.body, this.bearer, this.oneShot);

  final String path;
  final Map<String, Object?>? body;
  final String? bearer;
  final bool oneShot;
}

/// 一个路径的响应：返回 (状态码, 正文)，抛异常模拟网络错误
typedef FakeTokenReply = FutureOr<(int, String)> Function(FakeTokenCall call);

/// 假的令牌服务端（加速 / cfhub 通用）：按 [ConnectTokenPolicy] 的路径应答并记录请求
///
/// 默认：start 给合法的 Connect 授权地址，换码发 [issuedToken]，续期 500，作废 200。
class FakeTokenServer {
  FakeTokenServer(this.policy) {
    reply(
      policy.startPath,
      (_) => (200, jsonEncode({'authorize_url': authorizeUrl})),
    );
    reply(policy.tokenPath, (_) => (200, jsonEncode({'token': issuedToken})));
    final refresh = policy.refreshPath;
    if (refresh != null) reply(refresh, (_) => (500, ''));
    reply(policy.revokePath, (_) => (200, ''));
  }

  static const String authorizeUrl =
      'https://connect.linux.do/oauth2/authorize?client_id=x&state=s';

  /// 两种令牌格式都认（cfhub 要 cfp_ 前缀）
  static const String issuedToken = 'cfp_issued';

  final ConnectTokenPolicy policy;
  final List<FakeTokenCall> calls = [];
  final Map<String, FakeTokenReply> _replies = {};
  final Map<String, List<FakeTokenReply>> _queued = {};

  /// 设定某个路径的固定响应
  void reply(String path, FakeTokenReply reply) => _replies[path] = reply;

  /// 固定回某个状态码和 JSON 正文（[json] 为 null 时正文为空）
  void respond(String path, int status, [Object? json]) =>
      reply(path, (_) => (status, json == null ? '' : jsonEncode(json)));

  /// 只对下一次请求生效的响应，用完回到固定响应
  void once(String path, FakeTokenReply reply) =>
      (_queued[path] ??= []).add(reply);

  /// 让某个路径的请求挂住，直到返回的 Completer 完成
  Completer<void> hold(String path) {
    final gate = Completer<void>();
    final fallback = _replies[path]!;
    reply(path, (call) async {
      await gate.future;
      return fallback(call);
    });
    return gate;
  }

  int count(String path) => calls.where((c) => c.path == path).length;

  List<String> get paths => [for (final c in calls) c.path];

  List<String> get revoked => [
    for (final c in calls)
      if (c.path == policy.revokePath) c.bearer!,
  ];

  FakeTokenCall? lastCall(String path) {
    for (final c in calls.reversed) {
      if (c.path == path) return c;
    }
    return null;
  }

  /// Dart 那条路：记录后按路径应答
  Future<(int, String)> handle(ConnectTokenRequest request) async {
    final call = FakeTokenCall(
      request.path,
      request.body,
      request.bearer,
      request.oneShot,
    );
    calls.add(call);
    final queued = _queued[request.path];
    final reply = queued != null && queued.isNotEmpty
        ? queued.removeAt(0)
        : _replies[request.path];
    if (reply == null) return (404, '');
    return reply(call);
  }

  /// 走假服务端的传输；默认 Rust 不可用（直接退回 Dart，即本服务端）
  ConnectTokenTransport transport({
    ConnectTokenNativeSend? native,
    Duration nativeTimeout = ConnectTokenTransport.defaultNativeTimeout,
  }) => ConnectTokenTransport(
    baseUrl: 'https://token.example',
    logTag: policy.logTag,
    native: native ?? (_) async => null,
    dart: handle,
    nativeTimeout: nativeTimeout,
  );
}

/// 假的 Connect 授权：不发请求，按设定返回；[onFetch] 在返回前执行（模拟中途换号等）
class FakeConnectFlow implements ConnectCodeFlow {
  ConnectCodeResult result = const ConnectCodeResult.code(
    'the-code',
    'the-state',
  );

  FutureOr<void> Function()? onFetch;

  final List<({Uri url, bool silent, String requestTag})> calls = [];

  @override
  Future<ConnectCodeResult> fetchCode(
    Uri authorizeUrl, {
    bool silent = true,
    String requestTag = '',
  }) async {
    calls.add((url: authorizeUrl, silent: silent, requestTag: requestTag));
    await onFetch?.call();
    return result;
  }
}
