import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';

import 'session_token_fakes.dart';

/// [SessionTokenAuthority] 的场景表测试：jar / WebView 用内存假存储，服务端用
/// 假探测 + 假 User API Key，只经模块的公开接口驱动。
///
/// 核心不变量（每个场景都在验）：
/// - 服务端探测决定谁赢；探测无结论时两端都不动；
/// - 采纳 / 恢复写进 jar 的 `_t` 一定带过期时间（否则不落盘、冷启动又丢）。
void main() {
  final fallbackExpiry = FakeClock().now.add(
    CookieJarService.sessionTokenFallbackLifetime,
  );

  group('对账：jar T1、WebView T2 分叉', () {
    final cases = <_ReconcileCase>[
      _ReconcileCase(
        name: '探测无结论 → 两端都不动，jar 不写任何东西',
        setup: (rig) {},
        expectOutcome: SessionTokenReconcileOutcome.inconclusive,
        expectJar: 'T1',
        expectWebView: 'T2',
        expectJarWrites: 0,
        expectWebViewWrites: 0,
      ),
      _ReconcileCase(
        name: '探测 T2 有效、WebView 没给过期时间 → 两端都是 T2，jar 按 60 天兜底落盘',
        setup: (rig) => rig.server.valid.add('T2'),
        expectOutcome: SessionTokenReconcileOutcome.adoptedWebView,
        expectJar: 'T2',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectJarExpiry: fallbackExpiry,
        expectAgreed: 'T2',
      ),
      _ReconcileCase(
        name: '探测 T2 有效、WebView 带过期时间 → jar 用 WebView 自己的',
        setup: (rig) {
          rig.server.valid.add('T2');
          rig.webViewStore.expires = DateTime.utc(2026, 11, 30);
        },
        expectOutcome: SessionTokenReconcileOutcome.adoptedWebView,
        expectJar: 'T2',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectJarExpiry: DateTime.utc(2026, 11, 30),
        expectAgreed: 'T2',
      ),
      _ReconcileCase(
        name: '探测 T2 有效、WebView 没给过期时间但 jar 原值有 → 继承 jar 原值的',
        setup: (rig) {
          rig.server.valid.add('T2');
          rig.jarStore.expires = DateTime.utc(2026, 12, 1);
        },
        expectOutcome: SessionTokenReconcileOutcome.adoptedWebView,
        expectJar: 'T2',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectJarExpiry: DateTime.utc(2026, 12, 1),
        expectAgreed: 'T2',
      ),
      _ReconcileCase(
        name: '探测 T2 被拒 → jar 不动，把 T1 推回 WebView（先清变体）',
        setup: (rig) => rig.server.rejected.add('T2'),
        expectOutcome: SessionTokenReconcileOutcome.repushedJar,
        expectJar: 'T1',
        expectWebView: 'T1',
        expectJarWrites: 0,
        expectWebViewWrites: 1,
        expectAgreed: 'T1',
      ),
      _ReconcileCase(
        name: '血缘：两端曾一致于 T2、之后 jar 才变成 T1 → 不探测直接推回 T1',
        setup: (rig) => rig.authority.markAgreed('T2'),
        expectOutcome: SessionTokenReconcileOutcome.repushedJar,
        expectJar: 'T1',
        expectWebView: 'T1',
        expectJarWrites: 0,
        expectWebViewWrites: 1,
        expectProbes: 0,
      ),
      _ReconcileCase(
        name: '不许探测（过盾前）且没有血缘 → 无结论，两端都不动',
        allowProbe: false,
        setup: (rig) => rig.server.valid.add('T2'),
        expectOutcome: SessionTokenReconcileOutcome.inconclusive,
        expectJar: 'T1',
        expectWebView: 'T2',
        expectJarWrites: 0,
        expectWebViewWrites: 0,
        expectProbes: 0,
      ),
      _ReconcileCase(
        name: '不许探测但血缘显示 jar 没动、WebView 动了 → 按血缘采纳（沿用原规则）',
        allowProbe: false,
        setup: (rig) => rig.authority.markAgreed('T1'),
        expectOutcome: SessionTokenReconcileOutcome.adoptedWebView,
        expectJar: 'T2',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectJarExpiry: fallbackExpiry,
        expectProbes: 0,
      ),
      _ReconcileCase(
        name: '调用方刚证明服务端接受了 WebView 会话 → 不探测直接采纳',
        webViewVerified: true,
        setup: (rig) {},
        expectOutcome: SessionTokenReconcileOutcome.adoptedWebView,
        expectJar: 'T2',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectProbes: 0,
      ),
      _ReconcileCase(
        name: '采纳写入 jar 读回不符 → failed，不标记一致',
        setup: (rig) {
          rig.server.valid.add('T2');
          rig.jarStore.failWrites = true;
        },
        expectOutcome: SessionTokenReconcileOutcome.failed,
        expectJar: 'T1',
        expectWebView: 'T2',
        expectJarWrites: 1,
        expectWebViewWrites: 0,
        expectAgreed: null,
      ),
    ];

    for (final c in cases) {
      test(c.name, () async {
        final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
        c.setup(rig);
        final outcome = await rig.authority.reconcile(
          reason: 'test',
          allowProbe: c.allowProbe,
          webViewVerified: c.webViewVerified,
        );

        expect(outcome, c.expectOutcome);
        expect(rig.jarStore.value, c.expectJar);
        expect(rig.webViewStore.value, c.expectWebView);
        expect(rig.jarStore.writes, hasLength(c.expectJarWrites));
        expect(rig.webViewStore.writes, hasLength(c.expectWebViewWrites));
        if (c.expectJarExpiry != null) {
          expect(rig.jarStore.expires, c.expectJarExpiry);
          expect(rig.jarStore.persisted, isTrue);
        }
        if (c.expectProbes != null) {
          expect(rig.server.candidateProbes, hasLength(c.expectProbes!));
        }
        if (c.expectAgreed != _unset) {
          expect(rig.authority.agreedValueForTest, c.expectAgreed);
        }
      });
    }

    test('采纳后被替换的 T1 留作上一枚候选，认证层收到新值', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.server.valid.add('T2');
      await rig.authority.reconcile(reason: 'test');

      expect(rig.authority.recoveryCandidates(), contains('T1'));
      expect(rig.server.replaced, ['T2']);
    });

    test('WebView 读失败 → 跳过，什么都不动', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.webViewStore.throwOnRead = true;
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.skipped,
      );
      expect(rig.jarStore.writes, isEmpty);
    });

    test('jar 没有 _t → 对账不采纳任何东西（只有冷启动恢复能这么做）', () async {
      final rig = SessionTokenRig(webView: 'T2');
      rig.server.valid.add('T2');
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.skipped,
      );
      expect(rig.jarStore.value, isNull);
      expect(rig.server.candidateProbes, isEmpty);
    });

    test('WebView 没有 _t：默认不推；要求推时把 jar 的推过去', () async {
      final rig = SessionTokenRig(jar: 'T1');
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.webViewEmpty,
      );
      expect(rig.webViewStore.writes, isEmpty);

      expect(
        await rig.authority.reconcile(reason: 'test', pushIfWebViewEmpty: true),
        SessionTokenReconcileOutcome.repushedJar,
      );
      expect(rig.webViewStore.value, 'T1');
      expect(rig.authority.agreedValueForTest, 'T1');
    });

    test('priming：对账无结论 → 这一轮不重灌 _t；有结论 → 重灌', () async {
      final held = SessionTokenRig(jar: 'T1', webView: 'T2');
      final heldPlan = await held.authority.planPriming('https://linux.do');
      expect(heldPlan.injectJarToken, isFalse);
      expect(heldPlan.outcome, SessionTokenReconcileOutcome.inconclusive);
      expect(held.webViewStore.value, 'T2');

      final empty = SessionTokenRig(jar: 'T1');
      expect(
        (await empty.authority.planPriming('https://linux.do')).injectJarToken,
        isTrue,
      );

      final adopted = SessionTokenRig(jar: 'T1', webView: 'T2');
      adopted.server.valid.add('T2');
      final adoptedPlan = await adopted.authority.planPriming(
        'https://linux.do',
      );
      expect(adoptedPlan.injectJarToken, isTrue);
      expect(adopted.jarStore.value, 'T2');
    });
  });

  group('冷启动：jar 没有 _t、用户名还在', () {
    test('WebView T2 探测无结论 → 先采纳 T2（带过期时间落盘），但不标记一致', () async {
      final rig = SessionTokenRig(webView: 'T2', forumSession: 'fs');
      final verdict = await rig.authority.recoverMissingJarToken();

      expect(verdict.kind, SessionTokenVerdictKind.inconclusive);
      expect(verdict.token, 'T2');
      expect(verdict.source, SessionTokenSource.unverifiedWebView);
      expect(rig.jarStore.value, 'T2');
      expect(rig.jarStore.expires, fallbackExpiry);
      expect(rig.jarStore.forumSessionAdoptions, ['fs']);
      expect(rig.authority.agreedValueForTest, isNull);
    });

    test('WebView T2 探测有效 → 采纳并标记一致', () async {
      final rig = SessionTokenRig(
        webView: 'T2',
        webViewExpires: DateTime.utc(2026, 12, 1),
      );
      rig.server.valid.add('T2');
      final verdict = await rig.authority.recoverMissingJarToken();

      expect(verdict.kind, SessionTokenVerdictKind.valid);
      expect(verdict.source, SessionTokenSource.webView);
      expect(rig.jarStore.value, 'T2');
      expect(rig.jarStore.expires, DateTime.utc(2026, 12, 1));
      expect(rig.authority.agreedValueForTest, 'T2');
    });

    test('WebView T2 被拒 → 依次试候选环 / 上一枚值 / User API Key，都不行 → dead', () async {
      final rig = SessionTokenRig(webView: 'T2');
      rig.server.rejected.addAll({'T2', 'R1', 'P0'});
      // 进程内 jar 丢值的情形：候选池里还有东西（真冷启动时两者都是空的）
      rig.authority.noteWebViewValues(['R1']);
      rig.authority.notePreviousToken('P0', reason: 'test');

      final verdict = await rig.authority.recoverMissingJarToken();

      expect(verdict.kind, SessionTokenVerdictKind.dead);
      expect(rig.server.candidateProbes, ['T2', 'R1', 'P0']);
      expect(rig.server.heals, 1);
      expect(rig.jarStore.value, isNull);
      expect(rig.jarStore.writes, isEmpty);
    });

    test('WebView T2 被拒、User API Key 换到新值 → valid(userApiKey)', () async {
      final rig = SessionTokenRig(webView: 'T2');
      rig.server.rejected.add('T2');
      rig.server.healIssues = 'K1';

      final verdict = await rig.authority.recoverMissingJarToken();

      expect(verdict.kind, SessionTokenVerdictKind.valid);
      expect(verdict.source, SessionTokenSource.userApiKey);
      expect(verdict.token, 'K1');
    });

    test('WebView 也没有 _t、自愈失败 → absent（静默按未登录，不弹登出）', () async {
      final rig = SessionTokenRig();
      final verdict = await rig.authority.recoverMissingJarToken();
      expect(verdict.kind, SessionTokenVerdictKind.absent);
      expect(rig.server.heals, 1);
    });
  });

  group('恢复链（auth 信号 / 启动检查被拒）', () {
    final cases = <_RecoverCase>[
      _RecoverCase(
        name: 'jar T1 主探测有效 → valid(jarSession)，什么都不写',
        setup: (rig) => rig.server.valid.add('T1'),
        expectKind: SessionTokenVerdictKind.valid,
        expectSource: SessionTokenSource.jarSession,
        expectJar: 'T1',
      ),
      _RecoverCase(
        name: '主探测无结论 → inconclusive（带网络失败标记），什么都不写',
        setup: (rig) {},
        expectKind: SessionTokenVerdictKind.inconclusive,
        expectJar: 'T1',
      ),
      _RecoverCase(
        name: 'WebView T2 有效 → 先于主探测采纳 T2（jar 带过期时间）',
        webView: 'T2',
        setup: (rig) {
          rig.server.valid.add('T2');
          rig.server.rejected.add('T1');
        },
        expectKind: SessionTokenVerdictKind.valid,
        expectSource: SessionTokenSource.webView,
        expectJar: 'T2',
        expectJarProbes: 0,
      ),
      _RecoverCase(
        name: 'WebView 与 jar 相同、环里 R1 有效 → 用 R1 并推回 WebView',
        webView: 'T1',
        setup: (rig) {
          rig.server.rejected.add('T1');
          rig.server.valid.add('R1');
          rig.authority.noteWebViewValues(['R1']);
        },
        expectKind: SessionTokenVerdictKind.valid,
        expectSource: SessionTokenSource.recentWebView,
        expectJar: 'R1',
        expectWebView: 'R1',
      ),
      _RecoverCase(
        name: 'jar T1 被拒、上一枚 P0 有效 → 用 P0 并推回 WebView',
        webView: 'T1',
        setup: (rig) {
          rig.server.rejected.add('T1');
          rig.server.valid.add('P0');
          rig.authority.notePreviousToken('P0', reason: 'test');
        },
        expectKind: SessionTokenVerdictKind.valid,
        expectSource: SessionTokenSource.previous,
        expectJar: 'P0',
        expectWebView: 'P0',
      ),
      _RecoverCase(
        name: '全被拒、User API Key 成功 → valid(userApiKey)',
        webView: 'T1',
        setup: (rig) {
          rig.server.rejected.add('T1');
          rig.server.healIssues = 'K1';
        },
        expectKind: SessionTokenVerdictKind.valid,
        expectSource: SessionTokenSource.userApiKey,
        expectJar: 'K1',
      ),
      _RecoverCase(
        name: '全被拒、自愈失败 → dead（被动登出）',
        webView: 'T1',
        setup: (rig) => rig.server.rejected.add('T1'),
        expectKind: SessionTokenVerdictKind.dead,
        expectJar: 'T1',
      ),
    ];

    for (final c in cases) {
      test(c.name, () async {
        final rig = SessionTokenRig(jar: 'T1', webView: c.webView);
        c.setup(rig);
        final verdict = await rig.authority.recover(
          source: 'test',
          signalRequestOptions: requestCarrying('T1'),
        );

        expect(verdict.kind, c.expectKind);
        if (c.expectSource != null) expect(verdict.source, c.expectSource);
        expect(rig.jarStore.value, c.expectJar);
        if (c.expectWebView != null) {
          expect(rig.webViewStore.value, c.expectWebView);
        }
        if (c.expectJarProbes != null) {
          expect(rig.server.jarProbes, hasLength(c.expectJarProbes!));
        }
        for (final write in rig.jarStore.writes) {
          expect(write.expires.isAfter(rig.clock.now), isTrue);
        }
      });
    }

    test('信号来自已经过去的会话代 → 什么都不做', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      final options = requestCarrying('T1')..extra['_sessionGeneration'] = -1;
      final verdict = await rig.authority.recover(
        source: 'test',
        signalRequestOptions: options,
      );
      expect(verdict.kind, SessionTokenVerdictKind.inconclusive);
      expect(verdict.staleGeneration, isTrue);
      expect(rig.server.candidateProbes, isEmpty);
      expect(rig.server.jarProbes, isEmpty);
    });
  });

  group('2xx 响应静默删 _t（无登出头）', () {
    test('分类为 deferToProbe：jar 不动，请认证层探测且只请求一次', () {
      expect(
        AppCookieManager.classifySessionCookieDeletion(
          name: '_t',
          statusCode: 200,
          hasLoggedOutHeader: false,
          hasNotLoggedInError: false,
        ),
        SessionCookieDeletionPolicy.deferToProbe,
      );

      final rig = SessionTokenRig(jar: 'T1', webView: 'T1');
      rig.authority.onServerDeletedToken(requestCarrying('T1'), 200);

      expect(rig.server.deletionSignals, hasLength(1));
      expect(rig.jarStore.value, 'T1');
      expect(rig.jarStore.writes, isEmpty);
    });

    test('请求本来就没带 _t → 不当信号', () {
      final rig = SessionTokenRig(jar: 'T1');
      rig.authority.onServerDeletedToken(requestCarrying(null), 200);
      expect(rig.server.deletionSignals, isEmpty);
    });

    test('随后的探测：T1 有效 → 保留；T1 被拒 → 走恢复链换到 WebView 的 T2', () async {
      final keep = SessionTokenRig(jar: 'T1', webView: 'T1');
      keep.server.valid.add('T1');
      final kept = await keep.authority.recover(
        source: 'response_t_deleted',
        signalRequestOptions: requestCarrying('T1'),
      );
      expect(kept.source, SessionTokenSource.jarSession);
      expect(keep.jarStore.value, 'T1');
      expect(keep.jarStore.writes, isEmpty);

      final heal = SessionTokenRig(jar: 'T1', webView: 'T2');
      heal.server.rejected.add('T1');
      heal.server.valid.add('T2');
      final healed = await heal.authority.recover(
        source: 'response_t_deleted',
        signalRequestOptions: requestCarrying('T1'),
      );
      expect(healed.source, SessionTokenSource.webView);
      expect(heal.jarStore.value, 'T2');
    });
  });

  group('被拒候选冷却', () {
    test('冷却期内不再探测、不再采纳；过了冷却期才重新探测', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.server.rejected.add('T2');

      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.repushedJar,
      );
      expect(rig.server.candidateProbes, ['T2']);
      expect(rig.authority.isRejectedInCooldown('T2'), isTrue);

      // WebView 又冒出 T2（比如旧页面恢复），此时服务端「改口」说有效也不采纳
      rig.webViewStore.value = 'T2';
      rig.server
        ..rejected.remove('T2')
        ..valid.add('T2');
      rig.later();
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.repushedJar,
      );
      expect(rig.server.candidateProbes, ['T2'], reason: '冷却期内不再探测');
      expect(rig.jarStore.value, 'T1');

      // 恢复链同样跳过它
      rig.authority.noteWebViewValues(['T2']);
      rig.server.rejected.add('T1');
      await rig.authority.recover(
        source: 'test',
        signalRequestOptions: requestCarrying('T1'),
      );
      expect(rig.server.candidateProbes, ['T2']);

      // 冷却过后重新探测
      rig.clock.advance(SessionTokenAuthority.rejectedCandidateCooldown);
      rig.later();
      rig.webViewStore.value = 'T2';
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.adoptedWebView,
      );
      expect(rig.jarStore.value, 'T2');
    });
  });

  group('服务端轮换（2xx Set-Cookie 新 _t）', () {
    test('新值推进 WebView 后成为一致值，旧值进候选池', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T1');
      rig.authority.markAgreed('T1');

      // AppCookieManager 已把 T2 落 jar；认证层记下被换掉的 T1；
      // AppCookieManager 再把 T2 推进 WebView。
      rig.jarStore.value = 'T2';
      rig.authority.notePreviousToken(
        'T1',
        reason: 'response_session_cookie_changed',
        replacement: 'T2',
      );
      expect(await rig.authority.onServerIssuedToken(value: 'T2'), isTrue);

      expect(rig.webViewStore.value, 'T2');
      expect(rig.authority.agreedValueForTest, 'T2');
      expect(rig.authority.recoveryCandidates(), contains('T1'));

      // T2 之后被判死时，T1 还能救回来
      rig.server
        ..rejected.add('T2')
        ..valid.add('T1');
      final verdict = await rig.authority.recover(
        source: 'test',
        signalRequestOptions: requestCarrying('T2'),
      );
      expect(verdict.source, SessionTokenSource.previous);
      expect(rig.jarStore.value, 'T1');
    });

    test('推不进 WebView 时血缘不前移：下次对账把 jar 的推回去而不是采纳旧值', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T1');
      rig.authority.markAgreed('T1');
      rig.jarStore.value = 'T2';
      rig.webViewStore.failWrites = true;

      expect(await rig.authority.onServerIssuedToken(value: 'T2'), isFalse);
      expect(rig.authority.agreedValueForTest, 'T1');

      rig.webViewStore.failWrites = false;
      rig.server.valid.add('T1'); // 旧值仍在轮换窗口内：探测会说有效
      expect(
        await rig.authority.reconcile(reason: 'test'),
        SessionTokenReconcileOutcome.repushedJar,
      );
      expect(rig.server.candidateProbes, isEmpty);
      expect(rig.jarStore.value, 'T2');
      expect(rig.webViewStore.value, 'T2');
    });
  });

  group('Sentinel / Nuclear Reset 的 _t 规则（不探测、不加锁）', () {
    final variantCases = <_ChoiceCase>[
      _ChoiceCase(
        name: 'WebView 选优那枚与 jar 相同 → 保留 jar 的',
        jar: 'T1',
        webViewBest: 'T1',
        expectKeepJar: true,
        expectReconcile: false,
      ),
      _ChoiceCase(
        name: '没有血缘、WebView 那枚可能更新 → 保留 WebView 的、jar 不动，收敛后对账',
        jar: 'T1',
        webViewBest: 'T2',
        expectKeepJar: false,
        expectReconcile: true,
      ),
      _ChoiceCase(
        name: 'WebView 那枚是两端此前一致过的旧值（jar 已前移）→ 保留 jar 的',
        jar: 'T1',
        webViewBest: 'T0',
        agreed: 'T0',
        expectKeepJar: true,
        expectReconcile: false,
      ),
      _ChoiceCase(
        name: 'WebView 那枚刚被服务端拒绝 → 保留 jar 的',
        jar: 'T1',
        webViewBest: 'T2',
        rejectFirst: 'T2',
        expectKeepJar: true,
        expectReconcile: false,
      ),
      _ChoiceCase(
        name: 'jar 没有 _t → 保留 WebView 的（只去重，不采纳）',
        jar: null,
        webViewBest: 'T2',
        expectKeepJar: false,
        expectReconcile: false,
      ),
    ];

    for (final c in variantCases) {
      test('多变体收敛：${c.name}', () async {
        final rig = SessionTokenRig(jar: c.jar, webView: c.webViewBest);
        if (c.agreed != null) rig.authority.markAgreed(c.agreed);
        if (c.rejectFirst != null) {
          rig.server.rejected.add(c.rejectFirst!);
          await rig.authority.reconcile(reason: 'seed');
          rig.jarStore.value = c.jar;
          rig.webViewStore.value = c.webViewBest;
        }
        final choice = rig.authority.chooseVariantToKeep(
          jarValue: c.jar,
          webViewBest: c.webViewBest,
        );
        expect(choice.keepJarValue, c.expectKeepJar);
        expect(choice.needsReconcile, c.expectReconcile);
      });
    }

    test('收敛保留 WebView 的 T2 后对账：探测确认 T2 → 两端都是 T2（旧 jar 值不再赢）', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.server.valid.add('T2');
      final choice = rig.authority.chooseVariantToKeep(
        jarValue: 'T1',
        webViewBest: 'T2',
      );
      expect(choice.keepJarValue, isFalse);

      await rig.authority.reconcile(reason: 'sentinel_variants');
      expect(rig.jarStore.value, 'T2');
      expect(rig.webViewStore.value, 'T2');
    });

    final overwriteCases =
        <
          ({
            String name,
            String? jar,
            List<String?> wv,
            String? agreed,
            bool expect,
          })
        >[
          (
            name: 'WebView 没有 _t → 可以重灌',
            jar: 'T1',
            wv: [],
            agreed: null,
            expect: true,
          ),
          (
            name: 'WebView 与 jar 相同 → 可以',
            jar: 'T1',
            wv: ['T1'],
            agreed: null,
            expect: true,
          ),
          (
            name: 'WebView 有未知值 → 不动 _t',
            jar: 'T1',
            wv: ['T1', 'T2'],
            agreed: null,
            expect: false,
          ),
          (
            name: 'WebView 是旧的一致值、jar 已前移 → 可以',
            jar: 'T1',
            wv: ['T0'],
            agreed: 'T0',
            expect: true,
          ),
          (
            name: 'jar 没有 _t → 不动 WebView 的',
            jar: null,
            wv: ['T2'],
            agreed: null,
            expect: false,
          ),
        ];
    for (final c in overwriteCases) {
      test('Nuclear Reset：${c.name}', () {
        final rig = SessionTokenRig(jar: c.jar);
        if (c.agreed != null) rig.authority.markAgreed(c.agreed);
        expect(
          rig.authority.mayOverwriteWebViewToken(
            jarValue: c.jar,
            webViewValues: c.wv,
          ),
          c.expect,
        );
      });
    }
  });

  group('线上复现：只改坏 WebView 的 _t（Tbad）、jar 仍是 T1，冷启动撞上 CF 盾', () {
    test(
      '盾期间所有探测无结论 → jar 的 T1 始终不被替换；过盾后 Tbad 被拒 → WebView 修回 T1，不登出',
      () async {
        final jarExpiry = DateTime.utc(2026, 12, 10);
        final rig = SessionTokenRig(
          jar: 'T1',
          jarExpires: jarExpiry,
          webView: 'Tbad',
          webViewExpires: jarExpiry,
        );
        rig.server.challenged = true;

        // 冷启动 priming：对账无结论，本轮不碰 WebView 的 _t
        final plan = await rig.authority.planPriming('https://linux.do');
        expect(plan.injectJarToken, isFalse);

        // 启动期间各路报告 WebView 的 _t：BrowserTrust 首页 / bootstrap、
        // WebView 会话刷新、Sentinel 单变体（以前前三处会把 Tbad 可信写进 jar）
        for (final reason in [
          'browser_trust_home',
          'browser_trust_bootstrap',
          'webview_session_refresh',
          'sentinel_noop',
        ]) {
          rig.later();
          expect(
            await rig.authority.reconcile(reason: reason),
            SessionTokenReconcileOutcome.inconclusive,
            reason: reason,
          );
        }
        // 过盾前：不许探测，没有血缘 → 无结论
        rig.later();
        expect(
          await rig.authority.reconcile(
            reason: 'cf_challenge_prepare',
            allowProbe: false,
            pushIfWebViewEmpty: true,
          ),
          SessionTokenReconcileOutcome.inconclusive,
        );
        // 盾期间的登录态检查 / auth 信号：恢复链也无结论，什么都不写
        final during = await rig.authority.recover(
          source: 'startup_session_check',
          signalRequestOptions: requestCarrying('T1'),
        );
        expect(during.kind, SessionTokenVerdictKind.inconclusive);

        // 整个盾期间 jar 的 T1 原封不动：值、过期时间都没变，没有任何写入
        expect(rig.jarStore.value, 'T1');
        expect(rig.jarStore.expires, jarExpiry);
        expect(rig.jarStore.writes, isEmpty);
        expect(rig.webViewStore.value, 'Tbad');
        expect(rig.webViewStore.writes, isEmpty);

        // 过盾：探测恢复，Tbad 被拒、T1 有效
        rig.server
          ..challenged = false
          ..valid.add('T1')
          ..rejected.add('Tbad');
        rig.later();
        expect(
          await rig.authority.reconcile(
            reason: 'cf_challenge_passed',
            pushIfWebViewEmpty: true,
          ),
          SessionTokenReconcileOutcome.repushedJar,
        );
        expect(rig.webViewStore.value, 'T1');
        expect(rig.jarStore.value, 'T1');
        expect(rig.jarStore.writes, isEmpty);
        expect(rig.authority.agreedValueForTest, 'T1');

        // 之后的登录态检查：T1 有效，不登出
        final after = await rig.authority.recover(
          source: 'startup_session_check',
          signalRequestOptions: requestCarrying('T1'),
        );
        expect(after.kind, SessionTokenVerdictKind.valid);
        expect(after.source, SessionTokenSource.jarSession);
      },
    );

    test(
      '验证页带着 Tbad 加载、服务端删了 WebView 的 _t → 过盾后把 jar 的 T1 推回空 WebView',
      () async {
        final rig = SessionTokenRig(jar: 'T1', webView: 'Tbad');
        rig.server.challenged = true;
        await rig.authority.planPriming('https://linux.do');

        rig.webViewStore.value = null;
        rig.server
          ..challenged = false
          ..valid.add('T1');
        rig.later();
        expect(
          await rig.authority.reconcile(
            reason: 'cf_challenge_passed',
            pushIfWebViewEmpty: true,
          ),
          SessionTokenReconcileOutcome.repushedJar,
        );
        expect(rig.webViewStore.value, 'T1');
        expect(rig.jarStore.writes, isEmpty);
      },
    );

    test('对照：Tbad 实际上是 WebView 轮换到的活值 → 过盾后探测确认才采纳', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.server.challenged = true;
      rig.later();
      await rig.authority.reconcile(reason: 'browser_trust_home');
      expect(rig.jarStore.value, 'T1');

      rig.server
        ..challenged = false
        ..valid.add('T2');
      rig.later();
      await rig.authority.reconcile(reason: 'cf_challenge_passed');
      expect(rig.jarStore.value, 'T2');
      expect(rig.jarStore.persisted, isTrue);
    });
  });

  group('候选环与一致记录', () {
    test('环保留最近 4 枚，新的在前，重复值移到最前', () {
      final rig = SessionTokenRig();
      rig.authority.noteWebViewValues(['t1', 't2', 't3', 't4', 't2', 't5']);
      expect(rig.authority.recentWebViewCandidates(), ['t5', 't2', 't4', 't3']);
    });

    test('exclude 与空值被忽略', () {
      final rig = SessionTokenRig();
      rig.authority.noteWebViewValues(['old', 'new', null, '']);
      expect(rig.authority.recentWebViewCandidates(exclude: ['new', null]), [
        'old',
      ]);
    });

    test('标记一致的值从环中移除，之后再记也不进环', () {
      final rig = SessionTokenRig();
      rig.authority.noteWebViewValues(['a', 'b']);
      rig.authority.markAgreed('a');
      expect(rig.authority.recentWebViewCandidates(), ['b']);
      expect(
        rig.authority.lastAgreedHash,
        SessionTokenAuthority.tokenHash('a'),
      );
      rig.authority.noteWebViewValues(['a']);
      expect(rig.authority.recentWebViewCandidates(), ['b']);
    });

    test('环里的候选 20 分钟后过期，上一枚值 15 分钟后过期', () {
      final rig = SessionTokenRig();
      rig.authority.noteWebViewValues(['ring']);
      rig.authority.notePreviousToken('prev', reason: 'test');
      expect(rig.authority.recoveryCandidates(), ['ring', 'prev']);

      rig.clock.advance(const Duration(minutes: 16));
      expect(rig.authority.recoveryCandidates(), ['ring']);
      rig.clock.advance(const Duration(minutes: 5));
      expect(rig.authority.recoveryCandidates(), isEmpty);
    });

    test('登录 / 登出清掉血缘与候选，但不清被拒冷却', () async {
      final rig = SessionTokenRig(jar: 'T1', webView: 'T2');
      rig.server.rejected.add('T2');
      await rig.authority.reconcile(reason: 'test');
      rig.authority.noteWebViewValues(['x']);
      rig.authority.notePreviousToken('p', reason: 'test');

      rig.authority.resetLineage();
      expect(rig.authority.agreedValueForTest, isNull);
      expect(rig.authority.recoveryCandidates(), isEmpty);
      expect(rig.authority.isRejectedInCooldown('T2'), isTrue);
    });

    test('tokenHash：空值为 null，12 位十六进制，同值同哈希', () {
      expect(SessionTokenAuthority.tokenHash(null), isNull);
      expect(SessionTokenAuthority.tokenHash(''), isNull);
      final hash = SessionTokenAuthority.tokenHash('token-a');
      expect(hash, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(SessionTokenAuthority.tokenHash('token-a'), hash);
      expect(SessionTokenAuthority.tokenHash('token-b'), isNot(hash));
    });
  });
}

const Object _unset = Object();

class _ReconcileCase {
  _ReconcileCase({
    required this.name,
    required this.setup,
    required this.expectOutcome,
    required this.expectJar,
    required this.expectWebView,
    required this.expectJarWrites,
    required this.expectWebViewWrites,
    this.expectJarExpiry,
    this.expectProbes,
    this.expectAgreed = _unset,
    this.allowProbe = true,
    this.webViewVerified = false,
  });

  final String name;
  final void Function(SessionTokenRig rig) setup;
  final SessionTokenReconcileOutcome expectOutcome;
  final String? expectJar;
  final String? expectWebView;
  final int expectJarWrites;
  final int expectWebViewWrites;
  final DateTime? expectJarExpiry;
  final int? expectProbes;
  final Object? expectAgreed;
  final bool allowProbe;
  final bool webViewVerified;
}

class _RecoverCase {
  _RecoverCase({
    required this.name,
    required this.setup,
    required this.expectKind,
    required this.expectJar,
    this.webView,
    this.expectSource,
    this.expectWebView,
    this.expectJarProbes,
  });

  final String name;
  final String? webView;
  final void Function(SessionTokenRig rig) setup;
  final SessionTokenVerdictKind expectKind;
  final SessionTokenSource? expectSource;
  final String? expectJar;
  final String? expectWebView;
  final int? expectJarProbes;
}

class _ChoiceCase {
  _ChoiceCase({
    required this.name,
    required this.jar,
    required this.webViewBest,
    required this.expectKeepJar,
    required this.expectReconcile,
    this.agreed,
    this.rejectFirst,
  });

  final String name;
  final String? jar;
  final String webViewBest;
  final String? agreed;
  final String? rejectFirst;
  final bool expectKeepJar;
  final bool expectReconcile;
}
