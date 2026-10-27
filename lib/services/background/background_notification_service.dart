import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../l10n/s.dart';
import 'notification_task_handler.dart';

/// 后台通知统一管理入口
///
/// Android 用前台服务保活进程，主 Isolate 的 MessageBus 长轮询继续运行。
class BackgroundNotificationService {
  static final BackgroundNotificationService _instance =
      BackgroundNotificationService._internal();
  factory BackgroundNotificationService() => _instance;
  BackgroundNotificationService._internal();

  bool _enabled = false;
  bool _androidInited = false;

  /// 初始化（在 main() 中调用一次）
  Future<void> initialize() async {}

  /// 启用后台通知（App 切后台时调用）
  Future<void> enable(int userId) async {
    if (_enabled) return;
    _enabled = true;
    debugPrint('[BackgroundNotification] 启用后台通知, userId=$userId');
    await _startAndroidForegroundService();
  }

  /// 禁用后台通知（App 回前台时调用）
  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    debugPrint('[BackgroundNotification] 禁用后台通知');
    await _stopAndroidForegroundService();
  }

  bool get isEnabled => _enabled;

  void _initAndroidForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service',
        channelName: S.current.notification_channelBackground,
        channelDescription: S.current.notification_channelBackgroundDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        // 使用应用默认图标
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 不需要周期性事件，主 Isolate 的 MessageBus 已在轮询
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startAndroidForegroundService() async {
    // 延迟到首次启动服务时初始化，此时 navigatorKey.currentContext 已可用
    if (!_androidInited) {
      _androidInited = true;
      _initAndroidForegroundTask();
    }

    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (serviceRunning) {
      debugPrint('[BackgroundNotification] Android 前台服务已在运行');
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 200,
      notificationTitle: 'CFluxDo',
      notificationText: S.current.notification_backgroundRunning,
      callback: startNotificationTaskHandler,
    );
    debugPrint('[BackgroundNotification] Android 前台服务已启动');
  }

  Future<void> _stopAndroidForegroundService() async {
    final serviceRunning = await FlutterForegroundTask.isRunningService;
    if (!serviceRunning) return;

    await FlutterForegroundTask.stopService();
    debugPrint('[BackgroundNotification] Android 前台服务已停止');
  }
}
