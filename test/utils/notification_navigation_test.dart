import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/notification_providers.dart';
import 'package:fluxdo/providers/notification_list_provider.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/utils/notification_navigation.dart';

// 移植自上游 PR #250 的回归测试:点开单条通知后,快捷面板、历史页列表
// 和角标计数要一起变,不能只改快捷面板。

final _highPriorityUnread = DiscourseNotification(
  id: 1001,
  userId: 42,
  notificationType: NotificationType.privateMessage,
  read: false,
  highPriority: true,
  createdAt: DateTime.utc(2026, 5, 12, 1, 2, 3),
  data: NotificationData(topicTitle: '有一条新私信', username: 'tester'),
);

final _regularUnread = DiscourseNotification(
  id: 1002,
  userId: 42,
  notificationType: NotificationType.liked,
  read: false,
  highPriority: false,
  createdAt: DateTime.utc(2026, 5, 12, 1, 2, 4),
  data: NotificationData(topicTitle: '有人赞了你', username: 'tester'),
);

Future<ProviderContainer> _buildContainer() async {
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWith(_FakeCurrentUserNotifier.new),
      recentNotificationsProvider.overrideWith(
        _FakeRecentNotificationsNotifier.new,
      ),
      notificationListProvider.overrideWith(
        _FakeNotificationListNotifier.new,
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(currentUserProvider.future);
  await container.read(recentNotificationsProvider.future);
  return container;
}

void main() {
  test('本地标记高优先级通知已读:三处列表/角标一起同步', () async {
    final container = await _buildContainer();
    // 历史页已加载时也要跟着变;保持一个监听让 autoDispose 的它活着
    final keepAlive = container.listen(notificationListProvider, (_, _) {});
    addTearDown(keepAlive.close);
    await container.read(notificationListProvider.future);

    var count = container.read(notificationCountStateProvider);
    expect(count.allUnread, 2);
    expect(count.unread, 1);
    expect(count.highPriority, 1);

    syncNotificationReadLocally(container, _highPriorityUnread);

    count = container.read(notificationCountStateProvider);
    expect(count.allUnread, 1);
    expect(count.unread, 1, reason: '普通通知计数不受高优先级已读影响');
    expect(count.highPriority, 0);
    expect(
      container
          .read(recentNotificationsProvider)
          .requireValue
          .firstWhere((n) => n.id == 1001)
          .read,
      isTrue,
    );
    expect(
      container
          .read(notificationListProvider)
          .requireValue
          .firstWhere((n) => n.id == 1001)
          .read,
      isTrue,
    );
  });

  test('本地标记普通通知已读:只减普通计数,历史页未加载时不去创建它', () async {
    final container = await _buildContainer();
    expect(container.exists(notificationListProvider), isFalse);

    syncNotificationReadLocally(container, _regularUnread);

    final count = container.read(notificationCountStateProvider);
    expect(count.allUnread, 1);
    expect(count.unread, 0);
    expect(count.highPriority, 1);
    expect(
      container.exists(notificationListProvider),
      isFalse,
      reason: '不能为了同步已读态触发历史页的列表请求',
    );
  });

  test('已读通知不重复递减,计数不低于 0', () async {
    final container = await _buildContainer();

    syncNotificationReadLocally(container, _regularUnread);
    syncNotificationReadLocally(
      container,
      _regularUnread.copyWith(read: true),
    );
    syncNotificationReadLocally(container, _highPriorityUnread);
    syncNotificationReadLocally(container, _highPriorityUnread);

    final count = container.read(notificationCountStateProvider);
    expect(count.allUnread, 0);
    expect(count.unread, 0);
    expect(count.highPriority, 0);
  });
}

class _FakeCurrentUserNotifier extends CurrentUserNotifier {
  @override
  FutureOr<User?> build() {
    return User(
      id: 42,
      username: 'tester',
      trustLevel: 2,
      unreadNotifications: 1,
      unreadHighPriorityNotifications: 1,
      allUnreadNotificationsCount: 2,
      seenNotificationId: 1000,
      notificationChannelPosition: 1,
    );
  }
}

class _FakeRecentNotificationsNotifier extends RecentNotificationsNotifier {
  @override
  Future<List<DiscourseNotification>> build() async => [
    _highPriorityUnread,
    _regularUnread,
  ];
}

class _FakeNotificationListNotifier extends NotificationListNotifier {
  @override
  Future<List<DiscourseNotification>> build() async => [
    _highPriorityUnread,
    _regularUnread,
  ];
}
