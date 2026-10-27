/// 一轮 CF 验证的结果。
///
/// 只有两种形态：「定稿值 V 已经在 jar 里」，或带类型的失败原因。此前验证
/// 入口返回 `bool?`：`true` 只代表页面判定通过（值可能还没进 jar，调用方要
/// 各自「等 1.5 秒 → 同步 → 重试 3 次」），`null` 混着冷却 / 没有 context /
/// 没有 overlay 三种情况，调用方只能再去读服务状态猜是哪一种。
sealed class CfRoundOutcome {
  const CfRoundOutcome({required this.round});

  /// 验证轮次号；0 表示根本没有起轮（冷却中 / 没有前台 UI）。
  final int round;

  bool get passed => this is CfRoundPassed;
}

/// 通过：页面上报的挑战结果已按统一定稿规则收敛，定稿值 [clearance]
/// 已经过权威闸门写进 jar。拿到它的调用方可以直接重放，不需要再同步。
final class CfRoundPassed extends CfRoundOutcome {
  const CfRoundPassed({
    required super.round,
    required this.clearance,
    this.interactionRequired = false,
  });

  final String clearance;

  /// 这一轮露出过需要用户操作的挑战（勾选框等）。刚由用户亲手过的值若是
  /// 被原生链路拒绝，再弹一次同样的挑战大概率仍要用户再点一次，恢复流程
  /// 据此优先尝试浏览器网络栈。
  final bool interactionRequired;

  @override
  String toString() =>
      'CfRoundPassed(round=$round, ${clearance.length} chars'
      '${interactionRequired ? ', interactive' : ''})';
}

/// 失败原因。
enum CfRoundFailure {
  /// 冷却期内，没有起验证。
  cooldown,

  /// 没有前台 UI（navigator context / overlay 不可用），没有起验证。
  noUi,

  /// 用户退出验证页。
  cancelled,

  /// 挑战一直没有通过（静默轮次超时、无挑战也无新值等）。
  timeout,

  /// 页面判定已通过，但在时限内没能读到/写进一枚定稿值。
  notLanded,

  /// 网络层 502 / 加载失败导致无从判断：不计失败、不覆盖 jar 里原来的值。
  inconclusive;

  /// 是否计入连续失败（同一轮只记一次）。冷却 / 无 UI 没有起轮，
  /// inconclusive 是网络问题而非验证问题，都不计。
  bool get countsAsFailure =>
      this == cancelled || this == timeout || this == notLanded;
}

/// 失败：[reason] 说明为什么没有拿到可用的 cf_clearance。
final class CfRoundFailed extends CfRoundOutcome {
  const CfRoundFailed({required super.round, required this.reason});

  final CfRoundFailure reason;

  @override
  String toString() => 'CfRoundFailed(round=$round, ${reason.name})';
}

/// 发起/加入验证的方式。
enum CfVerifyMode {
  /// 只在后台尝试（静默请求）：超时直接失败，不把验证页弹到用户脸上。
  background,

  /// 先后台静默尝试一个宽限期，仍未通过再转前台（页面数据/操作请求）。
  silentFirst,

  /// 直接前台展示（用户主动点击的验证入口、登录前置验证）。
  foreground,
}
