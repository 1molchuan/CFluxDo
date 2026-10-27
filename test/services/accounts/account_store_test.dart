import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/accounts/account_store.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../ld_store/ld_store_test_support.dart';

SavedAccount _account(int id, String username) => SavedAccount(
  userId: id,
  username: username,
  avatarTemplate: '/user_avatar/linux.do/$username/{size}/1.png',
  savedAt: DateTime(2026, 10, 27),
);

List<CanonicalCookie> _cookies(String token) => [
  CanonicalCookie(name: '_t', value: token, domain: 'linux.do'),
  CanonicalCookie(
    name: '_forum_session',
    value: 'fs-$token',
    domain: 'linux.do',
  ),
];

void main() {
  late MemorySecretStore secrets;
  late AccountStore store;

  setUp(() {
    secrets = MemorySecretStore();
    store = AccountStore(secretStore: secrets);
  });

  test('保存、读出、更新、移除账号与它的凭据', () async {
    await store.save(_account(1, 'alice'), _cookies('a1'));
    await store.save(_account(2, 'bob'), _cookies('b1'));
    expect((await store.list()).map((a) => a.username), ['alice', 'bob']);

    final alice = (await store.list()).first;
    expect((await store.cookiesOf(alice))!.map((c) => '${c.name}=${c.value}'), [
      '_t=a1',
      '_forum_session=fs-a1',
    ]);

    // 同一个账号再存：更新凭据，不重复
    await store.save(_account(1, 'alice'), _cookies('a2'));
    expect(await store.list(), hasLength(2));
    expect((await store.cookiesOf(alice))!.first.value, 'a2');

    await store.markNeedsLogin(2, needsLogin: true);
    expect((await store.list()).last.needsLogin, isTrue);

    await store.remove(1);
    expect((await store.list()).map((a) => a.username), ['bob']);
    expect(await store.cookiesOf(alice), isNull, reason: '凭据一并删掉');
  });

  test('凭据按账号分槽存，列表里只有展示信息', () async {
    await store.save(_account(1, 'alice'), _cookies('secret-a'));
    final index = secrets.values.entries
        .where((e) => !e.key.contains(':cookies'))
        .map((e) => e.value)
        .join();
    expect(index, isNot(contains('secret-a')));
    expect(
      secrets.values.keys.where((k) => k.contains(':cookies')),
      hasLength(1),
    );
  });

  test('最多保存 ${AccountStore.maxAccounts} 个，满了再加新的会被拒', () async {
    for (var i = 1; i <= AccountStore.maxAccounts; i++) {
      await store.save(_account(i, 'user$i'), _cookies('t$i'));
    }
    await expectLater(
      store.save(_account(99, 'extra'), _cookies('x')),
      throwsA(isA<AccountLimitException>()),
    );
    // 已有的照样能更新
    await store.save(_account(1, 'user1'), _cookies('new'));
  });

  test('账号 cookie 只认本站及其子域', () {
    bool belongs(String? domain, {String? origin}) =>
        CookieJarService.belongsToSiteForTest(
          CanonicalCookie(
            name: '_t',
            value: 'v',
            domain: domain,
            originUrl: origin,
          ),
          'linux.do',
        );
    expect(belongs('linux.do'), isTrue);
    expect(belongs('.linux.do'), isTrue);
    expect(belongs('connect.linux.do'), isTrue);
    expect(belongs('evil-linux.do'), isFalse);
    expect(belongs('idcflare.com'), isFalse);
    expect(belongs(null, origin: 'https://credit.linux.do/x'), isTrue);
  });
}
