import 'dart:io';

import 'connect_bound_token.dart';

/// cfluxdo 加速服务端的令牌接口约定（流程见 [ConnectBoundToken]）
///
/// 走独立的 HTTP 客户端，不经过 App 的 Dio，不会带上 linux.do 的 cookie。
/// 发过去的只有 Connect 回调里的 code/state 和服务端自己发的令牌。
abstract final class AccelDohApi {
  static final ConnectTokenPolicy policy = ConnectTokenPolicy(
    logTag: '[DOH]',
    tokenName: '加速令牌',
    startPath: '/v1/connect/start',
    tokenPath: '/v1/token',
    // 服务端每次续期都换新令牌：Rust 侧超时后不能拿旧令牌重发
    refreshPath: '/v1/token/refresh',
    revokePath: '/v1/token/revoke',
    tokenPattern: RegExp(r'^[\x21-\x7E]{1,4096}$'),
    // 服务端没给 expires_in 时按这个有效期算
    defaultLifetime: const Duration(hours: 24),
    // 只用于菜单里的手动授权；后台自动授权 / 续期失败走 AccelDohAuthService 自己的退避
    retryDelays: ConnectTokenPolicy.manualRetryDelays,
    connectRequestTag: 'accel_doh_connect',
  );

  /// [serverUrl] 是本机的加速 DoH 地址，令牌接口走同一个域名
  static ConnectTokenTransport transport({
    required String serverUrl,
    required List<String> bootstrapIps,
  }) => ConnectTokenTransport(
    baseUrl: serverUrl,
    logTag: policy.logTag,
    createClient: () => ConnectTokenTransport.createDirectClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) async =>
          ConnectionTask.fromSocket(
            _connectSecure(uri.host, uri.port, bootstrapIps),
            () {},
          ),
  );

  /// 先按系统 DNS 连；解析不出或连不上时直连加速节点 IP（SNI 仍是加速域名）
  static Future<Socket> _connectSecure(
    String host,
    int port,
    List<String> bootstrapIps,
  ) async {
    const timeout = ConnectTokenTransport.connectTimeout;
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
        raw = await Socket.connect(target, port, timeout: timeout);
        return await SecureSocket.secure(
          raw,
          host: host,
          supportedProtocols: const ['http/1.1'],
        ).timeout(timeout);
      } catch (e) {
        raw?.destroy();
        lastError = e;
      }
    }
    throw lastError ?? SocketException('无法连接 $host');
  }
}
