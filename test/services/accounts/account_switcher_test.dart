import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/accounts/account_store.dart';
import 'package:fluxdo/services/accounts/account_switcher.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 切换刚结束、面板里的「当前」还没刷新时，用户点到的可能就是当前账号
/// （2026-11 佬友日志里有两次「切到自己」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    DiscourseService().currentUserNotifier.value = null;
  });

  test('点的是当前账号：不清 cookie、不重新核对，直接算已切换', () async {
    DiscourseService().currentUserNotifier.value = User.fromJson({
      'id': 7,
      'username': 'alice',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 要是往下走，第一步就会去读这个账号存下的凭据（测试里没有安全存储，
    // 会抛 / 判成要重新登录），所以返回「已切换」就说明什么都没碰
    final outcome = await AccountSwitcher.instance.switchTo(
      SavedAccount(userId: 7, username: 'alice', savedAt: DateTime(2026, 11)),
      container,
    );
    expect(outcome, AccountSwitchOutcome.switched);
    expect(AccountSwitcher.instance.isBusy, isFalse);
  });
}
