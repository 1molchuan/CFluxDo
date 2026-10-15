import 'connect_bound_token.dart';

/// cfhub（众包 ECH 测速分池）的探针令牌接口约定（流程见 [ConnectBoundToken]）
///
/// 和加速令牌一样：优先走 Rust 的 reqwest 客户端，失败再退回 Dart 自己的
/// HttpClient；两条路都不经过 App 的 Dio，不会带上 linux.do 的 cookie。
abstract final class CfhubApi {
  /// cfhub 的主机名，探针上报和令牌接口都在这里
  static const String host = 'cfhub6.1molchuan.top';
  static const String defaultBaseUrl = 'https://$host';

  static final ConnectTokenPolicy policy = ConnectTokenPolicy(
    logTag: '[CFHUB]',
    tokenName: '探针令牌',
    startPath: '/api/v1/app/connect/start',
    tokenPath: '/api/v1/app/token',
    revokePath: '/api/v1/app/token/revoke',
    // 探针令牌固定以 cfp_ 开头，其余是可打印 ASCII
    tokenPattern: RegExp(r'^cfp_[\x21-\x7E]{1,4096}$'),
    // cfhub 接口还没开放时回 404
    notFoundMeansUnavailable: true,
    // 整条链路（取授权地址 → Connect → 换令牌）有 4 跳、每跳只请求一次，
    // 移动网络上任一跳瞬时失败就整体失败，所以网络类失败最多重来 2 次
    retryDelays: const [Duration(seconds: 2), Duration(seconds: 4)],
    connectRequestTag: 'cfhub_connect',
  );

  static ConnectTokenTransport transport({String baseUrl = defaultBaseUrl}) =>
      ConnectTokenTransport(baseUrl: baseUrl, logTag: policy.logTag);
}
