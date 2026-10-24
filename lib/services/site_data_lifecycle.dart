import '../storage/app_database.dart';
import 'media/playback_position_store.dart';

/// 在旧引擎退出前收集编辑器现场并刷盘，不改变当前站点。
class SiteDataLifecycle {
  SiteDataLifecycle._();

  static final Set<Future<void> Function()> _flushCallbacks = {};

  /// 注册已有持久化入口，返回解绑函数；编辑器须在这里读取最新富文本。
  static void Function() register(Future<void> Function() flush) {
    _flushCallbacks.add(flush);
    return () => _flushCallbacks.remove(flush);
  }

  static Future<void> flushBeforeSwitch() async {
    for (final flush in _flushCallbacks.toList(growable: false)) {
      await flush();
    }
    await AppDatabase.flushPending();
    await PlaybackPositionStore.instance.flush();
  }
}
