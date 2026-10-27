import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

DiscourseNotification _notification(int id) => DiscourseNotification(
  id: id,
  userId: 1,
  notificationType: NotificationType.fromId(1),
  read: false,
  highPriority: false,
  createdAt: DateTime(2026, 10, 27),
  data: NotificationData.fromJson(const {}),
);

class _Service implements DiscourseService {
  final calls = <bool>[];
  List<int> ids = [1];

  @override
  Future<NotificationListResponse> getRecentNotifications({
    bool silent = false,
  }) async {
    calls.add(silent);
    return NotificationListResponse(
      notifications: [for (final id in ids) _notification(id)],
      totalRowsNotifications: ids.length,
      seenNotificationId: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Service service;
  late ProviderContainer container;

  setUp(() {
    RecentNotificationsNotifier.clearPrefetched();
    service = _Service();
    container = ProviderContainer(
      overrides: [discourseServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    addTearDown(RecentNotificationsNotifier.clearPrefetched);
  });

  test('预取用 silent；面板打开时先显示预取的，再正常拉一次', () async {
    await RecentNotificationsNotifier.prefetch(service);
    expect(service.calls, [true]);

    service.ids = [2, 1];
    final first = await container.read(recentNotificationsProvider.future);
    expect(first.map((n) => n.id), [1], reason: '先显示预取的那份');
    expect(service.calls, [true], reason: '建 provider 时不再请求');

    await container.read(recentNotificationsProvider.notifier).refreshOnOpen();
    expect(service.calls, [true, false], reason: '再正常拉一次，更新已看到位置');
    expect(
      container.read(recentNotificationsProvider).value!.map((n) => n.id),
      [2, 1],
    );
  });

  test('没有预取：建 provider 时正常拉，面板打开不重复拉', () async {
    await container.read(recentNotificationsProvider.future);
    await container.read(recentNotificationsProvider.notifier).refreshOnOpen();
    expect(service.calls, [false]);
  });

  test('30 秒内不重复预取；退出登录清掉预取', () async {
    await RecentNotificationsNotifier.prefetch(service);
    await RecentNotificationsNotifier.prefetch(service);
    expect(service.calls, [true]);
    RecentNotificationsNotifier.clearPrefetched();
    await container.read(recentNotificationsProvider.future);
    expect(service.calls, [true, false], reason: '清掉后不用旧账号那份');
  });
}
