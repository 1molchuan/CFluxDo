import 'dart:math' as math;

/// 验证页「替用户点 Turnstile 勾选框」的规则（纯函数，便于单测）。
///
/// - 只在 Turnstile 明确要人工操作（`interactiveBegin` / `interactiveTimeout`）后点；
/// - 前后台都点：后台轮次的 WebView 在屏幕外，注入的触摸只送进这个 WebView，
///   用户全程无感；点不成才按原样弹前台 / 露胶囊交给用户；
/// - 点下去要看到效果（Turnstile 上报 `interactiveEnd`）才算数，没效果有限次重试；
/// - 点击进行中、以及点中后 [clearanceWait] 内，不自动弹前台、不超时放弃。
class CfTapPolicy {
  const CfTapPolicy._();

  /// 点下去后等 Turnstile 反馈（`interactiveEnd`）的窗口
  static const effectWindow = Duration(milliseconds: 1800);

  /// 点中后等 widget 签出 clearance 的时间：这期间压住自动弹前台和超时放弃
  static const clearanceWait = Duration(seconds: 8);

  /// 定位不到（被遮罩盖住 / 还没渲染出来）时的重试
  static const locateAttempts = 12;
  static const locateRetryDelay = Duration(milliseconds: 100);

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
    required bool done,
  }) => supported && interactiveSignaled && !done;

  /// 自动点击还没出结果、或点中后还在等 clearance：别弹前台、别超时放弃
  static bool holdsPromotion({
    required bool tapRunning,
    required DateTime? effectiveAt,
    required DateTime now,
  }) =>
      tapRunning ||
      (effectiveAt != null && now.difference(effectiveAt) < clearanceWait);

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
