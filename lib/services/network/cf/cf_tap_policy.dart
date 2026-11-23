import 'dart:math' as math;

/// 验证页「替用户点 Turnstile 勾选框」的规则（纯函数，便于单测）。
///
/// - 只在 Turnstile 明确要人工操作（`interactiveBegin` / `interactiveTimeout`）后点；
/// - 纯后台轮次（没人在等结果）不点：那是用户正在阅读时的静默尝试，维持
///   「只露胶囊、让用户自己决定」；前台或有人在等结果的后台轮次才点；
/// - 点下去要看到效果（Turnstile 上报 `interactiveEnd`）才算数，没效果有限次重试。
class CfTapPolicy {
  const CfTapPolicy._();

  /// 点下去后等 Turnstile 反馈（`interactiveEnd`）的窗口
  static const effectWindow = Duration(milliseconds: 1800);

  /// 有人在等的后台轮次：点中后再留这么久给 widget 签出 clearance，再弹前台
  static const postTapGrace = Duration(milliseconds: 2500);

  /// 定位不到（被遮罩盖住 / 还没渲染出来）时的重试
  static const locateAttempts = 4;
  static const locateRetryDelay = Duration(milliseconds: 250);

  /// 点了没效果，隔这么久再点
  static const retryDelay = Duration(milliseconds: 600);

  /// 同一回合（一次「要人工操作」信号）最多点几次
  static const maxAttemptsPerRound = 2;

  /// 同一文档最多点几次（`interactiveTimeout` 会开新回合，这里兜住总数）
  static const maxAttemptsPerDocument = 3;

  /// 勾选框位置（定位脚本按这几个数算点击点）：标准 widget 宽 ≥ [checkboxMinWidth]、
  /// 高 ≤ [checkboxMaxHeight]，勾选框在左侧 [checkboxLeft] 处（窄一点按
  /// [checkboxLeftRatio] 缩），竖直居中。别的尺寸布局不确定，不点。
  static const checkboxMinWidth = 200.0;
  static const checkboxMaxHeight = 120.0;
  static const checkboxLeft = 32.0;
  static const checkboxLeftRatio = 0.12;

  /// 本页当前状态下该不该替用户点
  static bool shouldAttempt({
    required bool supported,
    required bool interactiveSignaled,
    required bool isBackground,
    required bool someoneWaiting,
    required bool done,
  }) =>
      supported &&
      interactiveSignaled &&
      !done &&
      (!isBackground || someoneWaiting);

  /// 本回合 / 本文档还有没有点击余额
  static bool hasBudget({
    required int roundAttempts,
    required int documentAttempts,
  }) =>
      roundAttempts < maxAttemptsPerRound &&
      documentAttempts < maxAttemptsPerDocument;

  /// widget 内勾选框的偏移；不是标准尺寸返回 null（不点）
  static ({double dx, double dy})? checkboxOffset(double width, double height) {
    if (width >= checkboxMinWidth &&
        height > 0 &&
        height <= checkboxMaxHeight) {
      return (
        dx: math.min(checkboxLeft, width * checkboxLeftRatio),
        dy: height / 2,
      );
    }
    return null;
  }
}
