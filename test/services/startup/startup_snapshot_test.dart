import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:fluxdo/services/startup/startup_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_startup_fakes.dart';

/// 一份够启动用的首页 HTML：预加载数据 + discourse-setup + 会话相关的 meta
String _home(
  Map<String, dynamic> data, {
  String csrf = 'csrf-live',
  String sharedKey = 'shared-live',
}) =>
    '<html><head>'
    '<meta name="csrf-token" content="$csrf">'
    '<meta name="shared_session_key" content="$sharedKey">'
    '<meta name="discourse-base-uri" content="/">'
    '<meta id="data-discourse-setup" data-cdn="https://cdn.example">'
    '</head><body>'
    '<script type="application/json" id="data-preloaded">'
    '${jsonEncode(data)}</script>'
    '<p>页面正文不该进快照</p></body></html>';

Map<String, dynamic> _data({
  Map<String, dynamic>? user,
  String title = '站点',
  int categoryId = 1,
}) => {
  'currentUser': ?user,
  'siteSettings': {'title': title},
  'site': {
    'categories': [
      {'id': categoryId, 'name': '分类$categoryId'},
    ],
  },
};

const _alice = {'id': 7, 'username': 'alice'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StartupSnapshotStore', () {
    late Directory dir;
    late StartupSnapshotStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('startup_snapshot_test');
      store = StartupSnapshotStore(directory: () async => dir);
    });
    tearDown(() => dir.delete(recursive: true));

    test('片段只留启动要用的几段，不留 CSRF、会话钥匙和页面正文', () {
      final fragment = StartupSnapshotStore.buildFragment(
        _home(_data(user: _alice)),
      )!;

      expect(fragment, contains('id="data-preloaded"'));
      expect(fragment, contains('"username":"alice"'));
      expect(fragment, contains('data-discourse-setup'));
      expect(fragment, contains('data-cdn="https://cdn.example"'));
      expect(fragment, contains('discourse-base-uri'));
      expect(fragment, isNot(contains('csrf-live')));
      expect(fragment, isNot(contains('shared-live')));
      expect(fragment, isNot(contains('页面正文')));
    });

    test('旧版属性形态的预加载数据也能抽出来', () {
      final fragment = StartupSnapshotStore.buildFragment(
        '<meta id="data-discourse-setup">'
        '<div class="hidden" id="data-preloaded" '
        'data-preloaded="{&quot;site&quot;:&quot;{}&quot;}"></div>',
      );
      expect(fragment, contains('data-preloaded="{&quot;site&quot;'));
    });

    test('缺预加载数据或缺 discourse-setup 时不出片段', () {
      expect(StartupSnapshotStore.buildFragment('<html></html>'), isNull);
      expect(
        StartupSnapshotStore.buildFragment(
          '<script id="data-preloaded" type="application/json">{}</script>',
        ),
        isNull,
      );
    });

    test('存取往返，清掉后读不到，坏文件按没有处理', () async {
      expect(await store.load(), isNull);

      final savedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await store.save(
        StartupSnapshot(
          fragment: '<x>',
          savedAt: savedAt,
          host: 'linux.do',
          userId: 7,
        ),
      );
      final loaded = await store.load();
      expect(loaded!.fragment, '<x>');
      expect(loaded.savedAt, savedAt);
      expect(loaded.host, 'linux.do');
      expect(loaded.userId, 7);
      expect(loaded.loggedIn, isTrue);
      // 没有留下临时文件
      expect(dir.listSync().map((e) => e.path.split('/').last), [
        StartupSnapshotStore.fileName,
      ]);

      await File(
        '${dir.path}/${StartupSnapshotStore.fileName}',
      ).writeAsString('{"v":1,"fragment":');
      expect(await store.load(), isNull);

      await store.clear();
      expect(dir.listSync(), isEmpty);
    });
  });

  group('预加载数据：启动快照', () {
    late Directory dir;
    late StartupSnapshotStore store;
    late PreloadedDataService preload;

    Future<void> seedSnapshot(Map<String, dynamic> data, {int? userId}) =>
        store.save(
          StartupSnapshot(
            fragment: StartupSnapshotStore.buildFragment(_home(data))!,
            savedAt: DateTime.now().subtract(const Duration(hours: 9)),
            host: 'linux.do',
            userId: userId,
          ),
        );

    /// 等落盘之类不被 await 的尾巴跑完
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('preload_snapshot_test');
      store = StartupSnapshotStore(directory: () async => dir);
      preload = PreloadedDataService()
        ..reset()
        ..debugSnapshotStore = store;
      await settle();
    });
    tearDown(() async {
      preload.reset();
      await settle();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('读回登录快照：有数据可用，但不算这次运行拿到的', () async {
      await seedSnapshot(_data(user: _alice, title: '昨晚'), userId: 7);

      expect(await preload.restoreFromSnapshot(hasSession: true), isTrue);

      expect(preload.isLoaded, isTrue);
      expect(preload.isStale, isTrue);
      expect(preload.isFresh, isFalse);
      expect(preload.currentUserSync?['username'], 'alice');
      expect(preload.siteSettingsSync?['title'], '昨晚');
      expect(preload.cdnUrl, 'https://cdn.example');
      // 快照里没有会话钥匙
      expect(preload.sharedSessionKey, isNull);
    });

    test('登录状态对不上的快照不用，并且删掉', () async {
      // 快照是登录态，原生这边已经没有登录 Cookie（登出后残留）
      await seedSnapshot(_data(user: _alice), userId: 7);
      expect(await preload.restoreFromSnapshot(hasSession: false), isFalse);
      expect(preload.isLoaded, isFalse);
      expect(await store.load(), isNull);

      // 快照是游客，原生这边有登录 Cookie（登录后还没存过）
      preload.reset();
      await settle();
      await seedSnapshot(_data());
      expect(await preload.restoreFromSnapshot(hasSession: true), isFalse);
      expect(preload.isLoaded, isFalse);
      expect(await store.load(), isNull);
    });

    test('游客快照配游客状态可以用', () async {
      await seedSnapshot(_data(title: '游客首页'));

      expect(await preload.restoreFromSnapshot(hasSession: false), isTrue);
      expect(preload.isStale, isTrue);
      expect(preload.currentUserSync, isNull);
      expect(preload.siteSettingsSync?['title'], '游客首页');
    });

    test('这次运行的首页到了：整份替换、通知一次、存成新的快照', () async {
      await seedSnapshot(
        _data(user: _alice, title: '昨晚', categoryId: 1),
        userId: 7,
      );
      await preload.restoreFromSnapshot(hasSession: true);
      var notified = 0;
      void listener() => notified++;
      preload.freshRevision.addListener(listener);
      addTearDown(() => preload.freshRevision.removeListener(listener));

      final ok = await preload.hydrateFromHtml(
        _home(
          _data(
            user: {'id': 7, 'username': 'alice', 'unread_notifications': 3},
            title: '今天',
            categoryId: 42,
          ),
        ),
      );

      expect(ok, isTrue);
      expect(preload.isFresh, isTrue);
      expect(preload.isStale, isFalse);
      expect(preload.siteSettingsSync?['title'], '今天');
      expect(preload.categoryIdsSync, {42});
      expect(preload.currentUserSync?['unread_notifications'], 3);
      expect(preload.sharedSessionKey, 'shared-live');
      expect(notified, 1);

      await settle();
      final saved = await store.load();
      expect(saved!.userId, 7);
      expect(saved.fragment, contains('今天'));
      expect(saved.fragment, isNot(contains('昨晚')));
    });

    test('这次运行回来的是游客首页（会话失效）：快照里的用户不能留着', () async {
      await seedSnapshot(_data(user: _alice), userId: 7);
      await preload.restoreFromSnapshot(hasSession: true);
      expect(preload.currentUserSync, isNotNull);

      final ok = await preload.hydrateFromHtml(
        _home(_data(title: '游客首页')),
        allowAnonymous: true,
      );

      expect(ok, isTrue);
      expect(preload.isFresh, isTrue);
      expect(preload.currentUserSync, isNull);
      await settle();
      expect((await store.load())!.loggedIn, isFalse);
    });

    test('正显示着快照时，交来的首页不完整：不采用，快照原样留着', () async {
      await seedSnapshot(_data(user: _alice, title: '昨晚'), userId: 7);
      await preload.restoreFromSnapshot(hasSession: true);

      // 登录收口要求带当前用户，这份是游客首页
      expect(await preload.hydrateFromHtml(_home(_data(title: '游客'))), isFalse);
      // 根本没有预加载数据
      expect(await preload.hydrateFromHtml('<html>挑战页</html>'), isFalse);

      expect(preload.isLoaded, isTrue);
      expect(preload.isStale, isTrue);
      expect(preload.currentUserSync?['username'], 'alice');
      expect(preload.siteSettingsSync?['title'], '昨晚');
    });

    test('没有快照时一切照旧：不完整的首页会清空数据', () async {
      expect(await preload.restoreFromSnapshot(hasSession: true), isFalse);
      expect(await preload.hydrateFromHtml(_home(_data(title: '游客'))), isFalse);
      expect(preload.isLoaded, isFalse);
    });

    test('登出（reset）会删掉快照', () async {
      await preload.hydrateFromHtml(_home(_data(user: _alice)));
      await settle();
      expect(await store.load(), isNotNull);

      preload.reset();
      await settle();
      expect(await store.load(), isNull);
    });
  });

  group('启动序列：启动快照', () {
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('有快照：启动页立刻放行，登录判定先按快照给，登录后启动项等这次运行确认', () async {
      final ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..hasSnapshot = true
        ..snapshotUser = aliceJson
        ..preloadGate = Completer<void>();
      final startup = AppStartup(ports: ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));

      startup.storesReady();
      startup.launch();
      final source = await startup.ensureContentReady(reason: 'preheat_gate');

      expect(source, StartupContentSource.snapshot);
      expect(ports.isPreloaded, isFalse);
      expect(startup.verdictNow?.loggedIn, isTrue);
      expect(startup.verdictNow?.user?.username, 'alice');
      expect(startup.verdictNow?.source, SessionVerdictSource.snapshot);
      expect(startup.verdictIsProvisional, isTrue);
      expect((await startup.verdict()).source, SessionVerdictSource.snapshot);
      expect(ports.log, contains('publishUser:alice'));
      expect(ports.log, isNot(contains('message_bus:start')));

      var confirmed = false;
      final confirmedVerdict = startup.confirmedVerdict()
        ..then((_) => confirmed = true);
      await settle();
      expect(confirmed, isFalse);

      ports.preloadGate!.complete();
      final verdict = await confirmedVerdict;
      await settle();

      expect(verdict.source, SessionVerdictSource.preload);
      expect(startup.verdictIsProvisional, isFalse);
      expect(ports.log, contains('message_bus:start'));
      expect(ports.log, isNot(contains('notifyShowingSnapshot')));
    });

    test('没有快照：启动页照旧等预加载', () async {
      final ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..preloadGate = Completer<void>();
      final startup = AppStartup(ports: ports);

      startup.storesReady();
      startup.launch();
      var ready = false;
      final content = startup.ensureContentReady(reason: 'preheat_gate')
        ..then((_) => ready = true);
      await settle();
      expect(ready, isFalse);
      expect(startup.verdictNow, isNull);

      ports.preloadGate!.complete();
      expect(await content, StartupContentSource.preload);
    });

    test('游客快照：临时判定为未登录', () async {
      final ports = FakeStartupPorts()
        ..hasSnapshot = true
        ..preloadGate = Completer<void>();
      final startup = AppStartup(ports: ports);

      startup.storesReady();
      startup.launch();
      await startup.ensureContentReady();

      expect(startup.verdictNow?.loggedIn, isFalse);
      expect(startup.verdictIsProvisional, isTrue);
      ports.preloadGate!.complete();
      await settle();
    });

    test('快照说已登录，这次运行确认会话已经失效：以这次运行为准', () async {
      final ports = FakeStartupPorts(storedSession: false)
        ..hasSnapshot = true
        ..snapshotUser = aliceJson;
      final startup = AppStartup(ports: ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));

      startup.storesReady();
      startup.launch();
      await startup.ensureContentReady();
      final verdict = await startup.confirmedVerdict();
      await settle();

      expect(verdict.loggedIn, isFalse);
      expect(startup.verdictNow?.loggedIn, isFalse);
      expect(startup.verdictIsProvisional, isFalse);
      expect(ports.log, isNot(contains('message_bus:start')));
    });

    test('靠快照出了内容后预加载失败：提示一次，按间隔重试，成功后停', () {
      fakeAsync((async) {
        final ports = FakeStartupPorts(preloadedUser: aliceJson)
          ..hasSnapshot = true
          ..snapshotUser = aliceJson
          ..preloadError = StateError('连不上');
        final startup = AppStartup(ports: ports);

        startup.storesReady();
        startup.launch();
        StartupContentSource? source;
        startup.ensureContentReady().then((value) => source = value);
        async.flushMicrotasks();

        expect(source, StartupContentSource.snapshot);
        int count(String entry) => ports.log.where((e) => e == entry).length;
        expect(count('preload:failed'), 1);
        expect(count('notifyShowingSnapshot'), 1);

        // 第一次重试也失败
        ports.preloadError = StateError('还是连不上');
        async.elapse(const Duration(seconds: 5));
        expect(count('preload'), 2);
        expect(count('preload:failed'), 2);
        expect(count('notifyShowingSnapshot'), 1);

        // 第二次重试成功
        async.elapse(const Duration(seconds: 15));
        expect(count('preload'), 3);
        expect(count('preload:done'), 1);
        expect(ports.isPreloaded, isTrue);
        expect(startup.verdictIsProvisional, isFalse);

        // 之后不再重试
        async.elapse(const Duration(minutes: 10));
        expect(count('preload'), 3);
      });
    });

    test('没有快照时预加载失败：不提示也不自己重试（启动页有重试按钮）', () {
      fakeAsync((async) {
        final ports = FakeStartupPorts()..preloadError = StateError('连不上');
        final startup = AppStartup(ports: ports);

        startup.storesReady();
        startup.launch();
        Object? error;
        startup.ensureContentReady().catchError((Object e) {
          error = e;
          return StartupContentSource.preload;
        });
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));

        expect(error, isA<StateError>());
        expect(ports.log.where((e) => e == 'preload').length, 1);
        expect(ports.log, isNot(contains('notifyShowingSnapshot')));
      });
    });

    test('回前台时这次运行的首页还没拿到：再试一次', () async {
      final ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..hasSnapshot = true
        ..snapshotUser = aliceJson
        ..preloadError = StateError('连不上');
      final startup = AppStartup(ports: ports);

      startup.storesReady();
      startup.launch();
      await startup.ensureContentReady();
      await settle();
      expect(ports.isPreloaded, isFalse);

      await startup.resumeFromBackground();
      await settle();

      expect(ports.isPreloaded, isTrue);
      expect(ports.log.where((e) => e == 'preload').length, 2);
    });
  });
}
