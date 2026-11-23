import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/startup/app_startup_fakes.dart';

/// CurrentUserNotifier 只读启动序列的会话判定，不再自己跑 isLoggedIn。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ProviderContainer containerFor(AppStartup startup) {
    final container = ProviderContainer(
      overrides: [
        appStartupProvider.overrideWithValue(startup),
        // 后台刷新用户资料不许真的发请求
        discourseServiceProvider.overrideWithValue(_AuthEvents()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('判定为未登录：返回 null 并清缓存，不另跑一次会话检查', () async {
    SharedPreferences.setMockInitialValues({
      'current_user_cache': jsonEncode(
        User(id: 7, username: 'alice', trustLevel: 2).toCacheJson(),
      ),
      'current_user_cache_username': 'alice',
    });
    final ports = FakeStartupPorts(storedSession: false);
    final startup = AppStartup(ports: ports)
      ..storesReady()
      ..launch();
    await settle();
    expect(ports.storedSessionChecks, 1);

    final container = containerFor(startup);
    final sub = container.listen(currentUserProvider, (_, _) {});
    addTearDown(sub.close);
    await settle();

    // 缓存先亮出来（.future 会先拿到它），终值以判定为准
    expect(container.read(currentUserProvider).value, isNull);
    expect(ports.storedSessionChecks, 1, reason: '读的是启动序列的判定');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('current_user_cache'), isNull);
  });

  test('判定带着预加载用户：同步返回，不经过 loading', () async {
    SharedPreferences.setMockInitialValues({});
    final ports = FakeStartupPorts(preloadedUser: aliceJson);
    final startup = AppStartup(ports: ports)
      ..storesReady()
      ..launch();
    await startup.ensurePreloaded();

    final container = containerFor(startup);
    final state = container.read(currentUserProvider);

    expect(state.isLoading, isFalse);
    expect(state.value?.username, 'alice');
    expect(ports.storedSessionChecks, 0);
  });

  test('判定还在进行：先亮缓存，等判定出结果再定终值', () async {
    SharedPreferences.setMockInitialValues({
      'current_user_cache': jsonEncode(
        User(id: 7, username: 'alice', trustLevel: 2).toCacheJson(),
      ),
      'current_user_cache_username': 'alice',
    });
    final ports = FakeStartupPorts()..storedSessionGate = Completer<bool>();
    final startup = AppStartup(ports: ports)
      ..storesReady()
      ..launch();
    await settle();

    final container = containerFor(startup);
    final sub = container.listen(currentUserProvider, (_, _) {});
    addTearDown(sub.close);
    await settle();
    expect(container.read(currentUserProvider).value?.username, 'alice');

    // 恢复链最终判定会话已失效
    ports.storedSessionGate!.complete(false);
    await settle();
    expect(container.read(currentUserProvider).value, isNull);
    expect(ports.storedSessionChecks, 1);
  });

  test('登出后调用方抢在广播送达前刷新：读到旧判定，广播到了自己纠正', () async {
    SharedPreferences.setMockInitialValues({});
    final ports = FakeStartupPorts(preloadedUser: aliceJson);
    final startup = AppStartup(ports: ports)
      ..storesReady()
      ..launch();
    await startup.ensurePreloaded();

    final container = containerFor(startup);
    final sub = container.listen(currentUserProvider, (_, _) {});
    addTearDown(sub.close);
    expect(container.read(currentUserProvider).value?.username, 'alice');

    // 登出：本机状态已经清掉，登出函数返回，调用方马上刷新界面状态——
    // 这时启动序列还没收到广播，手里仍是登出前的判定
    ports
      ..preloadedUser = null
      ..storedSession = false;
    container.invalidate(currentUserProvider);
    expect(
      container.read(currentUserProvider).value?.username,
      'alice',
      reason: '广播送达前，判定还是旧的',
    );

    ports.auth.add(null);
    await settle();
    expect(startup.verdictNow?.loggedIn, isFalse);
    expect(container.read(currentUserProvider).value, isNull);
  });

  test('启动快照里的用户先亮出来，这次运行的判定出来后跟上', () async {
    SharedPreferences.setMockInitialValues({});
    final ports = FakeStartupPorts(storedSession: false)
      ..hasSnapshot = true
      ..snapshotUser = aliceJson
      ..preloadGate = Completer<void>();
    final startup = AppStartup(ports: ports)
      ..storesReady()
      ..launch();
    await startup.ensureContentReady();

    final container = containerFor(startup);
    final sub = container.listen(currentUserProvider, (_, _) {});
    addTearDown(sub.close);
    expect(startup.verdictIsProvisional, isTrue);
    expect(container.read(currentUserProvider).value?.username, 'alice');

    // 这次运行的首页数据是匿名的，本地会话也没了：服务端说未登录
    ports.preloadGate!.complete();
    await settle();
    expect(startup.verdictIsProvisional, isFalse);
    expect(container.read(currentUserProvider).value, isNull);
  });

  test('登录状态广播每次都送到监听方', () async {
    final service = _AuthEvents();
    final container = ProviderContainer(
      overrides: [discourseServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    var notified = 0;
    final sub = container.listen(authStateProvider, (_, next) {
      if (next.hasValue) notified++;
    });
    addTearDown(sub.close);
    await settle();

    for (var i = 1; i <= 3; i++) {
      service.events.add(null);
      await settle();
      expect(notified, i, reason: '第 $i 次登录状态变化');
    }
  });
}


class _AuthEvents extends Fake implements DiscourseService {
  final events = StreamController<void>.broadcast();

  @override
  Stream<void> get authStateStream => events.stream;

  @override
  Future<User?> getCurrentUser() async => null;

  @override
  Future<User?> getPreloadedCurrentUser() async => null;
}
