import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';
import 'package:fluxdo/services/session/webview_use.dart';

import 'session_token_fakes.dart';

/// [WebViewUses] 的接口测试：jar / WebView 的 `_t` 用 #8 的内存假存储，
/// WebView cookie 回写用假 cookie 源（只记录口径），准备用假 preparer，
/// authority 用记录对账次数的真实例。
void main() {
  late SessionTokenRig rig;
  late _SpyAuthority authority;
  late _FakeCookieSource source;
  late _FakePreparer preparer;
  late WebViewUses uses;

  setUp(() {
    rig = SessionTokenRig(jar: 'T1', webView: 'T1');
    authority = _SpyAuthority(rig);
    source = _FakeCookieSource();
    preparer = _FakePreparer();
    uses = WebViewUses(
      preparer: preparer,
      source: source,
      sessionToken: authority,
    );
  });

  group('登录', () {
    test('登录成功结束 → jar 持有 WebView 的新 _t（带过期时间），其余 cookie 全量可信回写', () async {
      rig.jarStore
        ..value = null
        ..expires = null;
      rig.webViewStore
        ..value = 'NEW'
        ..expires = DateTime.utc(2026, 12, 14);
      final use = uses.start(WebViewUsePurpose.login, reason: 'test_login');
      expect(await use.ready, isTrue);

      final report = await use.end(WebViewUseOutcome.loginSucceeded);

      expect(report.loginTokenAdopted, isTrue);
      expect(rig.jarStore.value, 'NEW');
      expect(rig.jarStore.expires, DateTime.utc(2026, 12, 14));
      expect(rig.jarStore.persisted, isTrue);
      expect(authority.agreedValueForTest, 'NEW');
      expect(
        source.specs.single,
        const WebViewCookieSyncSpec(
          trusted: true,
          allowLowConfidenceSessionCookies: true,
        ),
      );
      expect(authority.reconciles, isEmpty, reason: '登录是新血缘，不对账');
    });

    test('WebView 的 _t 没有过期时间 → 按 60 天兜底落盘', () async {
      rig.jarStore.value = null;
      rig.webViewStore.value = 'NEW';
      final use = uses.start(WebViewUsePurpose.login, reason: 'test');
      await use.end(WebViewUseOutcome.loginSucceeded);

      expect(rig.jarStore.value, 'NEW');
      expect(
        rig.jarStore.expires,
        rig.clock.now.add(CookieJarService.sessionTokenFallbackLifetime),
      );
    });

    test('登录未完成 → 只回写非登录 cookie，不写 _t', () async {
      rig.webViewStore.value = 'NEW';
      final use = uses.start(WebViewUsePurpose.login, reason: 'test');
      final report = await use.checkpoint(WebViewUseOutcome.loginPending);

      expect(report.loginTokenAdopted, isNull);
      expect(rig.jarStore.value, 'T1');
      expect(
        source.specs.single,
        const WebViewCookieSyncSpec(
          excludeCookieNames: CookieJarService.authCookieNames,
        ),
      );
    });

    test('会话代在登录期间过期 → 什么都不写', () async {
      rig.webViewStore.value = 'NEW';
      final use = uses.start(
        WebViewUsePurpose.login,
        reason: 'test',
        generation: AuthSession().generation - 1,
      );
      final report = await use.end(WebViewUseOutcome.loginSucceeded);

      expect(report.cookies?.skippedReason, 'stale_generation');
      expect(source.specs, isEmpty);
      expect(rig.jarStore.value, 'T1');
    });
  });

  group('CF 验证', () {
    test(
      '过盾结束、WebView _t ≠ jar → 结束时只问 authority 一次，cf_clearance 可信落地',
      () async {
        rig.webViewStore.value = 'T2';
        final use = uses.start(WebViewUsePurpose.cfVerification, reason: 'cf');
        await use.ready;
        // 过盾前：不探测、WebView 空才推 jar
        expect(authority.reconciles.single.reason, 'cf_challenge_prepare');
        expect(authority.reconciles.single.allowProbe, isFalse);
        expect(preparer.primes, isEmpty, reason: 'CF 验证不重灌');
        authority.reconciles.clear();

        final landed = await use.landVerifiedClearance('CF1');
        expect(landed.completed, isTrue);
        expect(
          source.specs.single,
          const WebViewCookieSyncSpec(
            cookieNames: {'cf_clearance'},
            trusted: true,
            acceptValues: {'cf_clearance': 'CF1'},
          ),
        );

        final report = await use.end(
          WebViewUseOutcome.cfPassed,
          reason: 'cf_challenge_passed',
        );
        await pumpEventQueue();

        expect(report.sessionTokenScheduled, isTrue);
        expect(authority.reconciles, hasLength(1));
        expect(authority.reconciles.single.reason, 'cf_challenge_passed');
        expect(authority.reconciles.single.pushIfWebViewEmpty, isTrue);
        expect(source.specs, hasLength(1), reason: '过盾本身不再回写别的');
        expect(rig.jarStore.value, 'T1', reason: '探测无结论，不盲目采纳');
      },
    );

    test('轮次失败（撤下验证页）→ 结束为 aborted，什么都不写也不对账', () async {
      final use = uses.start(WebViewUsePurpose.cfVerification, reason: 'cf');
      await use.ready;
      authority.reconciles.clear();

      await use.end(WebViewUseOutcome.aborted);
      await pumpEventQueue();
      expect(source.specs, isEmpty);
      expect(authority.reconciles, isEmpty);
    });
  });

  group('站内浏览', () {
    test('浏览结束且 WebView 的 _t 不同 → 交对账（WebView 空就推），不盲目采纳', () async {
      rig.webViewStore.value = 'T2';
      final use = uses.start(
        WebViewUsePurpose.browsing,
        url: 'https://linux.do/t/1',
        reason: 'in_app_browser',
      );
      await use.ready;

      final report = await use.end(
        WebViewUseOutcome.loaded,
        reason: 'in_app_browser_dispose',
      );
      await pumpEventQueue();

      expect(report.sessionTokenScheduled, isTrue);
      expect(source.specs, isEmpty, reason: '用户浏览不把页面 cookie 带回 jar');
      expect(authority.reconciles.single.pushIfWebViewEmpty, isTrue);
      expect(rig.server.candidateProbes, ['T2']);
      expect(rig.jarStore.value, 'T1');
      expect(rig.jarStore.writes, isEmpty);
    });

    test('探测确认 WebView 的新值 → 才由 authority 采纳', () async {
      rig.webViewStore.value = 'T2';
      rig.server.valid.add('T2');
      final use = uses.start(WebViewUsePurpose.browsing, reason: 'test');
      await use.end(WebViewUseOutcome.loaded);
      await pumpEventQueue();

      expect(rig.jarStore.value, 'T2');
    });
  });

  group('中止与重复结束', () {
    for (final purpose in WebViewUsePurpose.values) {
      test('${purpose.name}：aborted → 不回写、不碰 _t', () async {
        rig.webViewStore.value = 'T2';
        final use = uses.start(purpose, reason: 'test');
        await use.ready;
        authority.reconciles.clear();

        final report = await use.end(WebViewUseOutcome.aborted);
        await pumpEventQueue();

        expect(report.cookies, isNull);
        expect(source.specs, isEmpty);
        expect(authority.reconciles, isEmpty);
        expect(rig.jarStore.writes, isEmpty);
        expect(rig.jarStore.value, 'T1');
      });
    }

    test('结束只生效一次：之后的结束 / 阶段同步什么都不做', () async {
      final use = uses.start(WebViewUsePurpose.login, reason: 'test');
      await use.end(WebViewUseOutcome.aborted);

      final again = await use.end(WebViewUseOutcome.loginSucceeded);
      final checkpoint = await use.checkpoint(WebViewUseOutcome.loginPending);
      expect(again.alreadyEnded, isTrue);
      expect(checkpoint.alreadyEnded, isTrue);
      expect(source.specs, isEmpty);
    });
  });

  group('准备', () {
    test('重灌失败 → 使用照常进行（ready 为 false、记日志），结束照常回写', () async {
      preparer.failPrime = true;
      final use = uses.start(WebViewUsePurpose.startupPreload, reason: 'test');

      expect(await use.ready, isFalse);
      final report = await use.end(WebViewUseOutcome.loaded);
      expect(report.cookies?.completed, isTrue);
      expect(source.specs, hasLength(1));
    });

    final prepareCases =
        <
          ({
            WebViewUsePurpose purpose,
            String? primeUrl,
            bool fresh,
            bool sweep,
          })
        >[
          (
            purpose: WebViewUsePurpose.login,
            primeUrl: 'https://linux.do',
            fresh: false,
            sweep: false,
          ),
          (
            purpose: WebViewUsePurpose.adapterRequest,
            primeUrl: 'https://linux.do',
            fresh: false,
            sweep: true,
          ),
          (
            purpose: WebViewUsePurpose.adapterReadOnlyRequest,
            primeUrl: 'https://linux.do',
            fresh: false,
            sweep: false,
          ),
          (
            purpose: WebViewUsePurpose.sessionBootstrap,
            primeUrl: 'https://linux.do',
            fresh: true,
            sweep: false,
          ),
          (
            purpose: WebViewUsePurpose.clearanceRefresh,
            primeUrl: 'https://linux.do',
            fresh: true,
            sweep: false,
          ),
          (
            purpose: WebViewUsePurpose.cfVerification,
            primeUrl: null,
            fresh: false,
            sweep: false,
          ),
        ];
    for (final c in prepareCases) {
      test('${c.purpose.name} 的准备方式', () async {
        await uses.start(c.purpose, reason: 'test').ready;
        if (c.primeUrl == null) {
          expect(preparer.primes, isEmpty);
        } else {
          expect(preparer.primes, ['${c.primeUrl}|fresh=${c.fresh}']);
        }
        expect(preparer.sweeps, c.sweep ? ['https://linux.do'] : isEmpty);
      });
    }
  });

  group('适配器请求', () {
    test('服务端认可了 WebView 会话 → 回写关键 cookie 并等对账（webViewVerified）', () async {
      rig.webViewStore.value = 'T2';
      final generation = AuthSession().generation;
      final use = uses.start(
        WebViewUsePurpose.adapterRequest,
        url: 'https://linux.do/latest.json',
        reason: 'adapter',
        generation: generation,
      );
      final report = await use.end(
        WebViewUseOutcome.sessionAccepted,
        reason: 'adapter_back_sync',
      );

      expect(
        source.specs.single.cookieNames,
        CookieJarService.criticalCookieNames,
      );
      expect(source.specs.single.excludeCookieNames, isNull);
      expect(source.specs.single.trusted, isFalse);
      expect(source.generations.single, generation);
      expect(authority.reconciles.single.webViewVerified, isTrue);
      expect(report.sessionToken, SessionTokenReconcileOutcome.adoptedWebView);
      expect(rig.jarStore.value, 'T2');
    });

    test('没有登录态证明 → 登录 cookie 不回写，不对账', () async {
      final use = uses.start(WebViewUsePurpose.adapterRequest, reason: 'a');
      await use.end(WebViewUseOutcome.loaded);

      expect(
        source.specs.single.excludeCookieNames,
        CookieJarService.authCookieNames,
      );
      expect(authority.reconciles, isEmpty);
    });

    test('只读请求 → 不回写', () async {
      final use = uses.start(
        WebViewUsePurpose.adapterReadOnlyRequest,
        reason: 'a',
      );
      await use.end(WebViewUseOutcome.sessionAccepted);
      expect(source.specs, isEmpty);
      expect(authority.reconciles, isEmpty);
    });
  });

  group('会话 bootstrap / 启动预载 / 续期', () {
    test('bootstrap 跑完 → 全量可信回写（不含 _t），对账在后台', () async {
      rig.webViewStore.value = 'Tbad';
      final use = uses.start(WebViewUsePurpose.sessionBootstrap, reason: 'b');
      final report = await use.end(
        WebViewUseOutcome.loaded,
        reason: 'webview_session_refresh',
      );
      await pumpEventQueue();

      expect(report.sessionTokenScheduled, isTrue);
      expect(source.specs.single.trusted, isTrue);
      expect(authority.reconciles.single.reason, 'webview_session_refresh');
      expect(rig.jarStore.value, 'T1', reason: '探测无结论，不盲目采纳');
    });

    test('bootstrap 期间登出（会话代变了）→ 不回写旧会话的 cookie', () async {
      final use = uses.start(WebViewUsePurpose.sessionBootstrap, reason: 'b');
      AuthSession().advance();
      final report = await use.end(WebViewUseOutcome.loaded);
      await pumpEventQueue();

      expect(report.cookies?.skippedReason, 'stale_generation');
      expect(source.specs, isEmpty);
      expect(authority.reconciles, isEmpty);
    });

    test('续期 WebView 有动静 → 只可信回写 cf_clearance，不碰 _t', () async {
      final use = uses.start(WebViewUsePurpose.clearanceRefresh, reason: 'r');
      await use.checkpoint(WebViewUseOutcome.loaded);
      AuthSession().advance(); // 续期跨会话：不绑会话代
      await use.checkpoint(WebViewUseOutcome.loaded);

      expect(source.specs, hasLength(2));
      expect(
        source.specs.first,
        const WebViewCookieSyncSpec(
          cookieNames: {'cf_clearance'},
          trusted: true,
        ),
      );
      expect(authority.reconciles, isEmpty);
    });
  });

  test('一次性回写（原生登录页过 CF 后）与使用期内同口径', () async {
    await uses.syncOnce(
      WebViewUsePurpose.login,
      WebViewUseOutcome.loginPending,
      reason: 'login_page_cf',
    );
    expect(
      source.specs.single,
      const WebViewCookieSyncSpec(
        excludeCookieNames: CookieJarService.authCookieNames,
      ),
    );
    expect(preparer.primes, isEmpty);
  });

  test('回前台对账：WebView 没有 _t 时把 jar 的推过去', () async {
    rig.webViewStore.value = null;
    final outcome = await uses.reconcileAfterBackground();
    expect(outcome, SessionTokenReconcileOutcome.repushedJar);
    expect(rig.webViewStore.value, 'T1');
  });
}

class _SpyAuthority extends SessionTokenAuthority {
  _SpyAuthority(SessionTokenRig rig)
    : super(
        jar: rig.jarStore,
        webView: rig.webViewStore,
        clock: rig.clock.call,
      ) {
    attachAuth(probe: rig.server, userApiKey: rig.server, listener: rig.server);
  }

  final List<
    ({
      String reason,
      bool allowProbe,
      bool pushIfWebViewEmpty,
      bool webViewVerified,
    })
  >
  reconciles = [];

  @override
  Future<SessionTokenReconcileOutcome> reconcile({
    String? url,
    required String reason,
    int? requestGeneration,
    bool webViewVerified = false,
    bool allowProbe = true,
    bool pushIfWebViewEmpty = false,
    Duration? lockTimeout,
  }) {
    reconciles.add((
      reason: reason,
      allowProbe: allowProbe,
      pushIfWebViewEmpty: pushIfWebViewEmpty,
      webViewVerified: webViewVerified,
    ));
    return super.reconcile(
      url: url,
      reason: reason,
      requestGeneration: requestGeneration,
      webViewVerified: webViewVerified,
      allowProbe: allowProbe,
      pushIfWebViewEmpty: pushIfWebViewEmpty,
      lockTimeout: lockTimeout,
    );
  }
}

/// 假 WebView cookie 源：只记录回写口径。
class _FakeCookieSource implements WebViewCookieSource {
  final List<WebViewCookieSyncSpec> specs = [];
  final List<int?> generations = [];

  @override
  Future<WebViewCookieSyncReport> syncToJar(
    WebViewCookieSyncSpec spec, {
    required String url,
    InAppWebViewController? controller,
    int? generation,
  }) async {
    specs.add(spec);
    generations.add(generation);
    return WebViewCookieSyncReport.completed(
      spec.cookieNames?.toList() ?? const ['*'],
    );
  }
}

class _FakePreparer implements WebViewCookiePreparer {
  final List<String> primes = [];
  final List<String> sweeps = [];
  bool failPrime = false;

  @override
  Future<void> prime(String url, {required bool fresh}) async {
    primes.add('$url|fresh=$fresh');
    if (failPrime) throw StateError('priming failed');
  }

  @override
  Future<void> sweepAll(String url) async => sweeps.add(url);
}
