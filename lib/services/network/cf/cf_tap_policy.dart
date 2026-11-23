import 'dart:math' as math;

class CfTapPolicy {
  const CfTapPolicy._();

  static const postTapGrace = Duration(milliseconds: 2500);
  static const locateAttempts = 3;
  static const locateRetryDelay = Duration(milliseconds: 120);

  static bool shouldAttempt({
    required bool supported,
    required bool interactiveSignaled,
    required bool alreadyAttempted,
    required bool done,
  }) => supported && interactiveSignaled && !alreadyAttempted && !done;

  static ({double dx, double dy}) checkboxOffset(double width, double height) {
    if (width >= 200 && height > 0 && height <= 120) {
      return (dx: math.min(32, width * 0.12), dy: height / 2);
    }
    return (dx: width / 2, dy: height / 2);
  }

  static ({double nx, double ny}) normalize({
    required double left,
    required double top,
    required double width,
    required double height,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    final offset = checkboxOffset(width, height);
    return (
      nx: ((left + offset.dx) / viewportWidth).clamp(0.01, 0.99).toDouble(),
      ny: ((top + offset.dy) / viewportHeight).clamp(0.01, 0.99).toDouble(),
    );
  }
}
