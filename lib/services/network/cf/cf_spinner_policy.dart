import 'dart:math' as math;

/// 验证页「挑战还在转圈时别露给用户」的判定（纯函数，便于单测）。
///
/// 挑战页出来后，Turnstile 往往要先转几秒圈自动验证，自动验证不过才出勾选框；
/// 出勾选框时它会向宿主页 postMessage `interactiveBegin`（超时没点是
/// `interactiveTimeout`）。以前页面一出挑战标记就露给用户，用户只能盯着圈干等；
/// 先静默再前台的轮次也是 6 s 一到就弹前台，同样落在转圈上。现在：
/// - 后台：转圈期间留在后台、什么都不露，预算放宽到 [spinnerBackgroundMax]；
///   勾选框一出来，有人在等就立刻转前台，没人在等（纯后台轮次）才露胶囊，
///   留 [awaitingTapMax] 等用户自己点；
/// - 前台：先盖着显示我们自己的加载动画，勾选框出来再露；收不到消息时最多盖
///   [revealFallback]。
class CfSpinnerPolicy {
  const CfSpinnerPolicy._();

  static const revealFallback = Duration(seconds: 6);
  static const spinnerBackgroundMax = Duration(seconds: 20);

  /// 挑战已在页面上、Turnstile 还没要人工操作
  static bool spinning({
    required bool hasSeenChallenge,
    required bool interactiveSignaled,
    required bool renderGone,
  }) => hasSeenChallenge && !interactiveSignaled && !renderGone;

  /// 前台里要不要先盖着（不露挑战页）
  static bool deferReveal({
    required bool isBackground,
    required bool interactiveSignaled,
    required bool force,
  }) => !isBackground && !interactiveSignaled && !force;

  /// 纯后台轮次里勾选框已出来、胶囊在等用户点：留这么久再放弃
  static const awaitingTapMax = Duration(seconds: 45);

  /// 后台轮次的预算（秒）：转圈时至少给到 [spinnerBackgroundMax]；
  /// 胶囊在等用户点时至少给到 [awaitingTapMax]
  static int backgroundBudgetSeconds({
    required int baseSeconds,
    required bool spinning,
    bool awaitingTap = false,
  }) {
    if (awaitingTap) return math.max(baseSeconds, awaitingTapMax.inSeconds);
    return spinning
        ? math.max(baseSeconds, spinnerBackgroundMax.inSeconds)
        : baseSeconds;
  }

  /// 先静默再前台的宽限期到点时要不要暂缓弹前台
  static bool holdGracePromotion({
    required bool afterGrace,
    required bool isBackground,
    required bool spinning,
  }) => afterGrace && isBackground && spinning;
}
