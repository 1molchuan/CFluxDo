import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/navigation/nav_entry.dart';
import 'package:fluxdo/navigation/nav_entry_registry.dart';

void main() {
  test('「网页浏览」是可加入底栏的页面入口，不要求登录，默认不在底栏', () {
    final entry = NavEntryRegistry.byId(NavEntryIds.browser);

    expect(entry, isNotNull);
    expect(entry!.kind, NavEntryKind.page);
    expect(entry.pageBuilder, isNotNull);
    expect(entry.requiresLogin, isFalse);
    expect(entry.locked, isFalse);
    expect(NavEntryRegistry.isAvailable(entry, null), isTrue);
    expect(
      NavEntryRegistry.isAvailable(
        entry,
        User(id: 1, username: 'tester', trustLevel: 1),
      ),
      isTrue,
    );
    expect(
      NavEntryRegistry.defaultBottomNavIds(),
      isNot(contains(NavEntryIds.browser)),
    );
  });

  test('入口 id 不重复，默认底栏仍只有首页和我的', () {
    final ids = NavEntryRegistry.buildAll().map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(NavEntryRegistry.defaultBottomNavIds(), [
      NavEntryIds.home,
      NavEntryIds.profile,
    ]);
  });
}
