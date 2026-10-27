import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import '../services/discourse/discourse_service.dart';
import 'core_providers.dart';
import 'message_bus_providers.dart';

/// 最近通知 Notifier（非分页，供快捷面板和 messageBus 使用）
class RecentNotificationsNotifier extends AsyncNotifier<List<DiscourseNotification>> {
  /// 未读数涨了、面板还没打开过时后台先取的一份（silent，不更新"已看到"
  /// 位置）。面板打开时先显示它，再正常拉一次。
  static ({List<DiscourseNotification> list, DateTime at})? _prefetched;
  static DateTime? _lastPrefetchAt;
  static Future<void>? _prefetching;
  static const _prefetchMaxAge = Duration(minutes: 2);
  static const _prefetchMinInterval = Duration(seconds: 30);

  /// 退出登录 / 换账号时清掉（预取的是当前账号的通知）
  static void clearPrefetched() {
    _prefetched = null;
    _lastPrefetchAt = null;
    _prefetching = null;
  }

  /// 后台预取（同时只一个、两次至少隔 30 秒）。失败不打扰。
  static Future<void> prefetch(DiscourseService service) {
    final running = _prefetching;
    if (running != null) return running;
    final last = _lastPrefetchAt;
    if (last != null && DateTime.now().difference(last) < _prefetchMinInterval) {
      return Future.value();
    }
    _lastPrefetchAt = DateTime.now();
    return _prefetching = () async {
      try {
        final response = await service.getRecentNotifications(silent: true);
        _prefetched = (list: response.notifications, at: DateTime.now());
      } catch (_) {
      } finally {
        _prefetching = null;
      }
    }();
  }

  static List<DiscourseNotification>? _takePrefetched() {
    final prefetched = _prefetched;
    _prefetched = null;
    if (prefetched == null ||
        DateTime.now().difference(prefetched.at) > _prefetchMaxAge) {
      return null;
    }
    return prefetched.list;
  }

  /// 上次正常拉取（会更新"已看到"位置）的时间
  DateTime? _fetchedAt;

  @override
  Future<List<DiscourseNotification>> build() async {
    final prefetched = _takePrefetched();
    if (prefetched != null) return prefetched;
    final service = ref.read(discourseServiceProvider);
    final response = await service.getRecentNotifications();
    _fetchedAt = DateTime.now();
    return response.notifications;
  }

  /// 打开通知面板时调用：先显示手上的（预取的或上次的），再正常拉一次——
  /// 服务端据此更新"已看到"位置。刚正常拉过（provider 刚建好）就不重复拉。
  Future<void> refreshOnOpen() async {
    try {
      await future;
    } catch (_) {
      if (ref.mounted) ref.invalidateSelf();
      return;
    }
    if (!ref.mounted) return;
    final fetchedAt = _fetchedAt;
    if (fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < const Duration(seconds: 2)) {
      return;
    }
    try {
      final response = await ref
          .read(discourseServiceProvider)
          .getRecentNotifications();
      if (!ref.mounted) return;
      _fetchedAt = DateTime.now();
      state = AsyncValue.data(response.notifications);
    } catch (_) {
      // 手上已经有一份在显示（预取的或上次的），拉新失败就先留着它
    }
  }

  /// 添加新通知（由 messageBus 调用）
  /// 高优先级未读通知排在最前
  void addNotification(DiscourseNotification notification) {
    final currentList = state.value;
    if (currentList == null) return;

    // 检查是否已存在
    if (currentList.any((n) => n.id == notification.id)) return;

    final newList = List<DiscourseNotification>.from(currentList);

    // 高优先级且未读 → 插入到位置 0
    // 其他 → 插入到第一个非高优先级或已读通知的位置
    int insertPosition = 0;
    if (!notification.highPriority || notification.read) {
      final nextPosition = newList.indexWhere((n) => !n.highPriority || n.read);
      if (nextPosition != -1) {
        insertPosition = nextPosition;
      }
    }

    newList.insert(insertPosition, notification);
    state = AsyncValue.data(newList);
  }

  /// 根据 messageBus 推送的 recent 字段同步通知列表
  /// 复刻 Discourse 逻辑：更新已读状态 + 移除不在 recent 中的过期通知
  void syncWithRecent(Map<int, bool> readStatusMap) {
    final currentList = state.value;
    if (currentList == null) return;

    // 与 Discourse 对齐：只保留 recent 中存在的通知，同时更新已读状态
    final newList = <DiscourseNotification>[];
    for (final n in currentList) {
      final newRead = readStatusMap[n.id];
      if (newRead != null) {
        newList.add(newRead != n.read ? n.copyWith(read: newRead) : n);
      }
      // 不在 readStatusMap 中的通知被移除（过期）
    }

    if (newList.length != currentList.length ||
        newList.any((n) {
          final old = currentList.firstWhere((o) => o.id == n.id);
          return old.read != n.read;
        })) {
      state = AsyncValue.data(newList);
    }
  }

  /// 标记单个通知为已读
  void markAsRead(int notificationId) {
    state.whenData((list) {
      state = AsyncValue.data(
        list.map((n) {
          if (n.id == notificationId && !n.read) {
            return n.copyWith(read: true);
          }
          return n;
        }).toList(),
      );
    });
  }

  /// 标记所有通知为已读
  Future<void> markAllAsRead() async {
    final service = ref.read(discourseServiceProvider);
    await service.markAllNotificationsRead();

    // 重置通知计数
    ref.read(notificationCountStateProvider.notifier).markAllRead();

    // 更新本地状态
    state.whenData((list) {
      state = AsyncValue.data(
        list.map((n) => n.copyWith(read: true)).toList(),
      );
    });
  }
}

final recentNotificationsProvider =
    AsyncNotifierProvider<RecentNotificationsNotifier, List<DiscourseNotification>>(() {
  return RecentNotificationsNotifier();
});
