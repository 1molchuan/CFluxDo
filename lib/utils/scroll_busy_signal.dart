import 'package:flutter/foundation.dart';

/// 全局滚动繁忙信号:近期是否有列表在滚动。
///
/// 由 app 根部的 NotificationListener 喂入(见 main.dart 的
/// MaterialApp.builder),后台维护类任务动手前查询让路 —— 典型是
/// cf_clearance 的 WebView cookie 兜底轮询:一趟平台主线程 IPC,与
/// vsync 分发/触摸事件同线程,滚动中执行会直接顶出掉帧(诊断时间轴
/// "[STALL] 平台主线程阻塞"的来源之一)。周期任务跳过本轮即可,
/// 下一轮自然补上;不适用于用户正在等结果的前台请求。
class ScrollBusySignal {
  ScrollBusySignal._();

  static DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 滚动静默判定窗口:最后一次滚动通知后 1s 内视为繁忙
  /// (覆盖惯性滚动的整个衰减尾巴)
  static const _busyWindow = Duration(seconds: 1);

  /// 滚动通知到达时调用(赋值级开销,每帧多次调用无碍)
  static void touch() => _lastScrollAt = DateTime.now();

  static bool get isBusy =>
      DateTime.now().difference(_lastScrollAt) < _busyWindow;

  /// 滚动是否已经停了至少 [idle]
  static bool isIdleFor(Duration idle) =>
      DateTime.now().difference(_lastScrollAt) >= idle;

  /// 等到滚动已经停了 [idle] 再返回；一直在滚最多等 [maxWait]。
  /// 给预取类后台请求用：快速划过的卡片不在滚动中逐个发请求。
  static Future<void> waitIdle(
    Duration idle, {
    Duration maxWait = const Duration(seconds: 8),
  }) async {
    final start = DateTime.now();
    while (true) {
      final now = DateTime.now();
      final left = idle - now.difference(_lastScrollAt);
      final budget = maxWait - now.difference(start);
      if (left <= Duration.zero || budget <= Duration.zero) return;
      await Future<void>.delayed(left < budget ? left : budget);
    }
  }

  @visibleForTesting
  static void resetForTest() =>
      _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
}
