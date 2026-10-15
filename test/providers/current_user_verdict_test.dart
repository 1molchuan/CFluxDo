import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
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
      overrides: [appStartupProvider.overrideWithValue(startup)],
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
}
