import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:fluxdo/services/startup_progress.dart';

import '../session/session_token_fakes.dart';
import 'app_startup_fakes.dart';

/// 冷启动序列的阶段顺序契约（全部用假端口，不碰真实网络 / WebView）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStartupPorts ports;
  late AppStartup startup;

  AppStartup build(FakeStartupPorts p) => AppStartup(ports: p);

  /// 等后台的会话判定等异步尾巴跑完
  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('冷启动阶段顺序', () {
    test('存储就绪 → 会话接线 → priming → 预加载 → 会话判定 → 登录后启动项', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson);
      startup = build(ports);
      final phases = <StartupPhase?>[];
      startup.phase.addListener(() => phases.add(startup.phase.value));
      startup.registerPostLogin(FakePostLoginStart(ports.log));

      startup.storesReady();
      startup.launch();
      await startup.ensurePreloaded(reason: 'preheat_gate');
      await settle();

      expect(phases, [
        StartupPhase.storesReady,
        StartupPhase.sessionHooks,
        StartupPhase.prime,
        StartupPhase.preload,
        StartupPhase.sessionVerdict,
        StartupPhase.postLogin,
      ]);
      expect(ports.log, [
        'attachSessionHooks',
        'prime',
        'preload',
        'preload:done',
        'afterPreload',
        'publishUser:alice',
        // 浏览器会话补同步先于续期（续期会顺延到同步结束）
        'settleAfterNativePreload:startup:native_preload_settle',
        'startClearanceRefresh:current_user_ready',
        'message_bus:start',
      ]);
    });

    test('启动页放行时会话判定已同步得出（预加载带当前用户）', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson);
      startup = build(ports);
      startup.storesReady();
      startup.launch();

      await startup.ensurePreloaded(reason: 'preheat_gate');

      final verdict = startup.verdictNow;
      expect(verdict, isNotNull);
      expect(verdict!.loggedIn, isTrue);
      expect(verdict.source, SessionVerdictSource.preload);
      expect(verdict.user?.username, 'alice');
      expect(ports.storedSessionChecks, 0, reason: '预加载带用户时不再查本地会话');
    });

    test('标准站点：WebView 有用户但原生会话不可用时，不能发布假登录态', () async {
      ports = FakeStartupPorts(
        preloadedUser: aliceJson,
        storedSession: false,
        path: StartupPreloadPath.webView,
      )..validatePreloadedSession = true;
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await startup.ensurePreloaded();
      await settle();
      expect(ports.storedSessionChecks, 1);
      expect(startup.isLoggedIn, isFalse);
      expect(ports.log, isNot(contains('publishUser:alice')));
      expect(ports.log, isNot(contains('message_bus:start')));
      expect(ports.log.where((e) => e.startsWith('startClearanceRefresh:')), isEmpty);
    });

    test('标准站点：jar 丢失登录 Cookie 时，先经会话权威从 WebView 恢复再发布用户', () async {
      final rig = SessionTokenRig(webView: 'test-session', forumSession: 'test-forum');
      rig.server.valid.add('test-session');
      ports = FakeStartupPorts(
        preloadedUser: aliceJson,
        path: StartupPreloadPath.webView,
      )
        ..validatePreloadedSession = true
        ..storedSessionBody = () async {
          final verdict = await rig.authority.recoverMissingJarToken();
          return verdict.kind == SessionTokenVerdictKind.valid;
        };
      startup = build(ports);
      startup.storesReady();
      startup.launch();
      await startup.ensurePreloaded();
      await settle();
      expect(rig.jarStore.value, 'test-session');
      expect(rig.jarStore.forumSessionAdoptions, ['test-forum']);
      expect(startup.verdictNow?.user?.username, 'alice');
      expect(ports.storedSessionChecks, 1);
    });

    test('标准站点：原生会话恢复确认前不提前发布用户或启动登录后任务', () async {
      ports = FakeStartupPorts(
        preloadedUser: aliceJson,
        path: StartupPreloadPath.webView,
      )
        ..validatePreloadedSession = true
        ..storedSessionGate = Completer<bool>();
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await startup.ensurePreloaded();
      expect(startup.verdictNow, isNull);
      expect(ports.log, isNot(contains('publishUser:alice')));
      ports.storedSessionGate!.complete(true);
      await settle();
      expect(startup.isLoggedIn, isTrue);
      expect(startup.verdictNow!.user?.username, 'alice');
      expect(ports.log, contains('publishUser:alice'));
      expect(ports.log, contains('message_bus:start'));
    });

    test('priming 不等预加载，预加载不等会话判定（不加串行等待）', () async {
      ports = FakeStartupPorts(storedSession: true)
        ..storedSessionGate = Completer<bool>();
      startup = build(ports);
      startup.storesReady();
      startup.launch();

      // 启动页等的预加载在会话检查还没回来时就完成了
      await startup.ensurePreloaded(reason: 'preheat_gate');
      expect(ports.log, contains('checkStoredSession'));
      expect(startup.verdictNow, isNull);
      expect(startup.isLoggedIn, isFalse);

      ports.storedSessionGate!.complete(true);
      await settle();
      expect(startup.isLoggedIn, isTrue);
    });

    test('WebView 预加载路径不补浏览器会话同步，只启动续期', () async {
      ports = FakeStartupPorts(
        preloadedUser: aliceJson,
        path: StartupPreloadPath.webView,
      );
      startup = build(ports);
      startup.storesReady();
      startup.launch();
      await startup.ensurePreloaded();
      await settle();

      expect(
        ports.log.where((e) => e.startsWith('settleAfterNativePreload')),
        isEmpty,
      );
      expect(ports.log, contains('startClearanceRefresh:current_user_ready'));
    });

    test('预加载失败：不判定会话、不启动登录后启动项；重试成功后才继续', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..preloadError = Exception('offline');
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await settle();

      expect(ports.log, contains('preload:failed'));
      expect(startup.phase.value, StartupPhase.preload);
      expect(startup.verdictNow, isNull);
      expect(ports.log, isNot(contains('message_bus:start')));

      await startup.ensurePreloaded(reason: 'preheat_gate');
      await settle();
      expect(startup.isLoggedIn, isTrue);
      expect(ports.log, contains('message_bus:start'));
    });
  });

  group('会话接线先于 priming', () {
    test('漏调 storesReady 时 launch 也先接线再 priming', () {
      ports = FakeStartupPorts();
      startup = build(ports);

      startup.launch();

      expect(ports.log.take(2), ['attachSessionHooks', 'prime']);
    });

    test('priming 时探测已接上，与谁先构造 DiscourseService 无关', () {
      final authority = SessionTokenAuthority(
        jar: FakeJarStore(),
        webView: FakeWebViewStore(),
        clock: FakeClock().call,
      );
      final probeAtPrime = <bool>[];
      ports = FakeStartupPorts()
        // 生产接线：惰性解析服务单例，不需要 cfhub 初始化先把 DiscourseService 构造出来
        ..onAttach = () {
          DiscourseService.attachSessionTokenAuthority(authority: authority);
        }
        ..onPrime = () => probeAtPrime.add(authority.hasProbe);
      startup = build(ports);

      startup.storesReady();
      startup.launch();

      expect(probeAtPrime, [isTrue]);
    });
  });

  group('「是否已登录」只有一个来源', () {
    test('预加载是匿名的：启动恢复链在没有任何 widget 监听时也会跑，且只跑一次', () async {
      ports = FakeStartupPorts(storedSession: true);
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));

      startup.storesReady();
      startup.launch();
      await settle();

      expect(ports.storedSessionChecks, 1);
      expect(startup.isLoggedIn, isTrue);
      expect(startup.verdictNow!.source, SessionVerdictSource.storedSession);
      expect(ports.log, contains('message_bus:start'));

      // 之后的读取复用同一判定，不再各自跑一次会话检查
      final again = await startup.verdict();
      expect(again.loggedIn, isTrue);
      expect(ports.storedSessionChecks, 1);
    });

    test('预加载完成前读判定：等启动序列的判定，不另起一次', () async {
      ports = FakeStartupPorts(storedSession: false)
        ..preloadGate = Completer<void>();
      startup = build(ports);
      startup.storesReady();
      startup.launch();

      final early = startup.verdict();
      await settle();
      expect(ports.storedSessionChecks, 0, reason: '预加载没完成时不判定');

      ports.preloadGate!.complete();
      final verdict = await early;
      expect(verdict.loggedIn, isFalse);
      expect(ports.storedSessionChecks, 1);
    });

    test('判定为未登录：不启动登录后启动项', () async {
      ports = FakeStartupPorts(storedSession: false);
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await settle();

      expect(startup.isLoggedIn, isFalse);
      expect(ports.log, isNot(contains('message_bus:start')));
      expect(
        ports.log.where((e) => e.startsWith('startClearanceRefresh')),
        isEmpty,
      );
    });

    test('登出 / 登录广播开启新纪元重新判定，启动项随之停 / 启', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson);
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await settle();
      expect(startup.isLoggedIn, isTrue);

      // 登出：预加载换成匿名、本地会话检查为否
      ports.preloadedUser = null;
      ports.storedSession = false;
      ports.log.clear();
      ports.auth.add(null);
      await settle();
      expect(startup.isLoggedIn, isFalse);
      expect(ports.log, ['checkStoredSession', 'message_bus:stop']);

      // 再登录：登录收口先备好预加载再广播
      ports.preloadedUser = aliceJson;
      ports.log.clear();
      ports.auth.add(null);
      await settle();
      expect(startup.isLoggedIn, isTrue);
      expect(ports.log, [
        'publishUser:alice',
        // 运行期登录不补启动期的浏览器会话同步（登录流程自己同步）
        'startClearanceRefresh:current_user_ready',
        'message_bus:start',
      ]);
    });

    test('判定期间登录态又变了：旧判定作废，以新纪元为准', () async {
      ports = FakeStartupPorts(storedSession: true)
        ..storedSessionGate = Completer<bool>();
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await settle();
      final staleGate = ports.storedSessionGate!;

      // 启动检查还没回来就登出了
      ports.storedSessionGate = null;
      ports.storedSession = false;
      ports.auth.add(null);
      await settle();
      expect(startup.isLoggedIn, isFalse);

      // 迟到的旧结果不能把状态翻回「已登录」
      staleGate.complete(true);
      await settle();
      expect(startup.isLoggedIn, isFalse);
      expect(ports.log, isNot(contains('message_bus:start')));
    });

    test('预加载完成前的登录 / 登出广播不另起判定，由启动判定读最新状态', () async {
      ports = FakeStartupPorts(storedSession: false)
        ..preloadGate = Completer<void>();
      startup = build(ports);
      startup.storesReady();
      startup.launch();

      // 例如首启引导页里登录：登录收口备好预加载数据后广播
      ports.auth.add(null);
      await settle();
      expect(ports.storedSessionChecks, 0);

      ports.preloadedUser = aliceJson;
      ports.preloadGate!.complete();
      await settle();
      expect(startup.isLoggedIn, isTrue);
      expect(startup.verdictNow!.source, SessionVerdictSource.preload);
      expect(ports.storedSessionChecks, 0);
    });

    test('启动页错误页上退出登录再重试：匿名预加载 → 判定未登录，不启动登录后启动项', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..preloadError = Exception('offline');
      startup = build(ports);
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();
      await settle();
      expect(ports.log, contains('preload:failed'));

      // 错误页「退出登录」：清掉用户名与 _t，广播登出（启动判定还没开始，不另起）
      ports.preloadedUser = null;
      ports.storedSession = false;
      ports.auth.add(null);
      await settle();
      expect(ports.storedSessionChecks, 0);

      // 「重试连接」
      await startup.ensurePreloaded(reason: 'preheat_gate');
      await settle();
      expect(startup.isLoggedIn, isFalse);
      expect(ports.storedSessionChecks, 1);
      expect(ports.log, isNot(contains('message_bus:start')));
      expect(
        ports.log.where((e) => e.startsWith('startClearanceRefresh')),
        isEmpty,
      );
    });

    test('首启引导页里登录：登录广播后判定为已登录；引导结束后不重复预加载，频道注册即启动', () async {
      // 全新安装：启动预加载是匿名的，本地也没有会话
      ports = FakeStartupPorts(storedSession: false);
      startup = build(ports);
      startup.storesReady();
      startup.launch();
      await settle();
      expect(startup.isLoggedIn, isFalse);

      // 引导页上登录：登录收口先备好预加载数据再广播
      ports.preloadedUser = aliceJson;
      ports.auth.add(null);
      await settle();
      expect(startup.isLoggedIn, isTrue);
      expect(ports.log, contains('startClearanceRefresh:current_user_ready'));

      // 引导结束：PreheatGate 等预加载（已加载过，不再请求），MainPage 注册频道
      ports.log.clear();
      await startup.ensurePreloaded(reason: 'preheat_gate');
      startup.registerPostLogin(FakePostLoginStart(ports.log));
      expect(ports.log, ['message_bus:start']);
    });

    test('已登录后注册的启动项立即启动，注销时停止', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson);
      startup = build(ports);
      startup.storesReady();
      startup.launch();
      await settle();

      final unregister = startup.registerPostLogin(
        FakePostLoginStart(ports.log),
      );
      expect(ports.log.last, 'message_bus:start');
      unregister();
      expect(ports.log.last, 'message_bus:stop');
    });
  });

  group('回前台只跑子集', () {
    test('顺序与以前一致，不重新接线 / priming / 预加载 / 判定会话', () async {
      ports = FakeStartupPorts(preloadedUser: aliceJson);
      startup = build(ports);
      startup.storesReady();
      startup.launch();
      await settle();
      ports.log.clear();

      await startup.resumeFromBackground(
        afterSessionReady: () => ports.log.add('ui:refresh'),
      );

      expect(ports.log, [
        'disableBackgroundKeepAlive',
        'reloadStoresAfterBackground',
        'reconcileAfterBackground',
        'exitBackgroundPolling',
        'ui:refresh',
        'ensureNetworkAlive',
        'resumeBrowserTrust:resume',
      ]);
    });

    test('中途出错也会恢复浏览器信任', () async {
      ports = FakeStartupPorts()..reconcileError = StateError('boom');
      startup = build(ports);

      await startup.resumeFromBackground();

      expect(ports.log, [
        'disableBackgroundKeepAlive',
        'reloadStoresAfterBackground',
        'reconcileAfterBackground',
        'resumeBrowserTrust:resume',
      ]);
    });
  });

  group('启动页进度', () {
    testWidgets('预加载各阶段按顺序报给启动页，开始前重置、结束后清空', (tester) async {
      await tester.pumpWidget(_l10nHarness());
      final reporter = StartupProgressReporter.instance;
      final seen = <StartupProgress?>[];
      void listener() => seen.add(reporter.progress.value);
      reporter.progress.addListener(listener);
      addTearDown(() => reporter.progress.removeListener(listener));

      DateTime? startedAtDuringPreload;
      ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..onPreload = (progress) {
          startedAtDuringPreload = reporter.startedAt;
          progress.stage(StartupStage.connecting);
          progress.onRetry(
            1,
            DioException(
              requestOptions: RequestOptions(path: '/'),
              response: Response(
                requestOptions: RequestOptions(path: '/'),
                statusCode: 502,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
          progress.onCfChallenge(403);
          progress.stage(
            StartupStage.webViewLoading,
            reason: StartupDetourReason.nativeFailed,
            detail: 'HTTP 403',
          );
          progress.stage(StartupStage.webViewSnapshot);
          progress.stage(StartupStage.webViewBootstrap);
        };
      startup = build(ports);
      startup.storesReady();

      await tester.runAsync(() async {
        startup.launch();
        await startup.ensurePreloaded();
      });

      expect(startedAtDuringPreload, isNotNull, reason: '预加载开始前已 begin');
      final stages = seen.whereType<StartupProgress>().map((p) => p.stage);
      expect(stages, [
        StartupStage.connecting,
        StartupStage.retrying,
        StartupStage.cfChallenge,
        StartupStage.webViewLoading,
        StartupStage.webViewSnapshot,
        StartupStage.webViewBootstrap,
      ]);
      final progresses = seen.whereType<StartupProgress>().toList();
      // 重试：第几次 + 简短原因
      expect(progresses[1].attempt, 1);
      expect(progresses[1].detail, isNotNull);
      expect(progresses[1].isAbnormal, isTrue);
      // 撞盾：状态码
      expect(progresses[2].detail, contains('403'));
      // 绕路原因在后续阶段保留（启动页红字）
      expect(progresses[3].reason, StartupDetourReason.nativeFailed);
      expect(progresses[4].reason, StartupDetourReason.nativeFailed);
      expect(progresses[5].reason, StartupDetourReason.nativeFailed);
      // 结束后清空，并停止接受更新
      expect(seen.last, isNull);
      expect(reporter.startedAt, isNull);
      expect(reporter.isActive, isFalse);
    });
  });
}

Widget _l10nHarness() {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      navigatorKey: navigatorKey,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: const SizedBox.shrink(),
    ),
  );
}
