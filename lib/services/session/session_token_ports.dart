import 'package:dio/dio.dart';

/// [SessionTokenAuthority] 依赖的外部端口。
///
/// `_t` 有两份存储（CookieJar 与 WebView cookie store）和一个裁判（服务端）。
/// authority 只通过这里的小接口读写它们：生产实现见
/// `session_token_stores.dart`（存储）与 `_auth.dart`（服务端探测、
/// User API Key、认证层回调）；测试里换成内存假实现即可驱动全部决策。

/// 服务端对一枚候选 `_t` 的答复。
enum SessionTokenProbeOutcome {
  /// 服务端返回了 current_user：这枚 `_t` 有效。
  valid,

  /// 服务端明确答复会话失效（404、带登出信号的 401/403 等）。
  rejected,

  /// 没有结论：网关 502、超时、撞 CF 盾、非预期响应体、会话代已变……
  /// 拿到它的一方绝不能据此判死、冷却或覆盖另一端的值。
  inconclusive,
}

/// 一次探测的结果。
class SessionTokenProbeResult {
  const SessionTokenProbeResult._({
    required this.outcome,
    this.currentUser,
    this.networkFailure = false,
    this.statusCode,
  });

  /// 服务端确认有效，[currentUser] 是 `/session/current.json` 的 current_user。
  const SessionTokenProbeResult.valid(Map<String, dynamic> currentUser)
    : this._(outcome: SessionTokenProbeOutcome.valid, currentUser: currentUser);

  /// 服务端明确拒绝。
  const SessionTokenProbeResult.rejected({int? statusCode})
    : this._(
        outcome: SessionTokenProbeOutcome.rejected,
        statusCode: statusCode,
      );

  /// 没有结论。[networkFailure] 表示请求本身失败（网络 / 网关 / 撞盾），
  /// 认证层据此决定 strike 是否升级；非预期响应体、会话代变化等为 false。
  const SessionTokenProbeResult.inconclusive({
    bool networkFailure = false,
    int? statusCode,
  }) : this._(
         outcome: SessionTokenProbeOutcome.inconclusive,
         networkFailure: networkFailure,
         statusCode: statusCode,
       );

  final SessionTokenProbeOutcome outcome;
  final Map<String, dynamic>? currentUser;
  final bool networkFailure;
  final int? statusCode;

  bool get isValid => outcome == SessionTokenProbeOutcome.valid;
  bool get isRejected => outcome == SessionTokenProbeOutcome.rejected;
  bool get isConclusive => outcome != SessionTokenProbeOutcome.inconclusive;

  @override
  String toString() =>
      'SessionTokenProbeResult(${outcome.name}'
      '${statusCode == null ? '' : ', status=$statusCode'}'
      '${networkFailure ? ', network' : ''})';
}

/// CookieJar 一侧的 `_t`（Dio 请求用它）。
abstract interface class SessionTokenJarStore {
  /// jar 是否已初始化（未初始化时 authority 什么都不做）。
  bool get isReady;

  /// 当前 `_t`，没有返回 null。
  Future<String?> read();

  /// 当前 `_t` 的过期时间（会话 cookie / 没有值返回 null）。
  Future<DateTime?> readExpiry();

  /// 可信写入 `_t`，必须带 [expires]（jar 只落盘带过期时间的 cookie）。
  /// 返回写入后读回是否一致——调用方不必自己再读一遍。
  Future<bool> writeTrusted(String value, {required DateTime expires});

  /// 把 WebView 里值为 [value] 的 `_forum_session` 可信写入 jar
  /// （与已验证的 WebView `_t` 一起采纳）。
  Future<void> adoptForumSessionFromWebView(
    String value, {
    int? requestGeneration,
    bool allowLowConfidence = false,
  });
}

/// WebView cookie store 一侧的 `_t`（站内页、WebView 适配器用它）。
abstract interface class SessionTokenWebViewStore {
  /// WebView 当前「那一枚」`_t`：多变体时按会话 cookie 选优规则取一枚。
  /// 读失败直接抛出，由 authority 按「跳过」处理。
  Future<String?> read();

  /// WebView 里值为 [value] 的那枚 `_t` 自带的过期时间（没有返回 null）。
  Future<DateTime?> readExpiry(String value);

  /// WebView 当前的 `_forum_session`（随 WebView 的 `_t` 一起探测 / 采纳）。
  Future<String?> readForumSession();

  /// 把 [value] 写进 WebView 并读回确认，失败重试一次；返回最终是否成功。
  ///
  /// [clearVariantsFirst] 先清掉同名所有变体再写（收敛多变体）。
  /// [rawSetCookie] 给了就原样写这条 Set-Cookie 头（Dio 刚收到的服务端值）。
  Future<bool> write(
    String value, {
    required String reason,
    String? url,
    String? rawSetCookie,
    DateTime? expires,
    bool clearVariantsFirst = false,
  });
}

/// 服务端探测（由认证层实现：它持有主 Dio 与 cookie 头拼装逻辑）。
abstract interface class SessionTokenProbe {
  /// 只用候选 `_t`（可选带上同源的 `_forum_session`）单独探测
  /// `/session/current.json`：不经 CookieJar、不触发恢复层。
  Future<SessionTokenProbeResult> probeCandidate(
    String token, {
    String? forumSession,
    int? requestGeneration,
  });

  /// 用 CookieJar 当前的会话走一次正常请求探测（主探测）。
  Future<SessionTokenProbeResult> probeJarSession({
    required String source,
    String? triggerInfo,
    int? requestGeneration,
  });
}

/// User API Key 自愈（补发 OTP → 兑换新 `_t`，新值由 Set-Cookie 落 jar）。
abstract interface class SessionTokenUserApiKey {
  /// 成功返回 current_user JSON，失败返回 null。
  Future<Map<String, dynamic>?> heal();
}

/// authority → 认证层的通知（认证层负责 strike 计数与登出体验）。
abstract interface class SessionTokenAuthListener {
  /// authority 改写了 jar 的 `_t`（采纳 / 恢复）：同步认证层的内存副本。
  void onTokenReplaced(String token);

  /// 2xx 响应里服务端静默删 `_t` 的指令被拦下：请认证层按强信号走一次
  /// probe（恢复链由 [SessionTokenAuthority.recover] 执行）。
  void onDeletionDeferred(RequestOptions requestOptions, int? statusCode);
}
