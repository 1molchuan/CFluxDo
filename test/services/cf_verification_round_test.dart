import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_verification_round.dart';

import 'cf_round_fakes.dart';

/// 一轮 CF 验证的契约：结果要么是「定稿值 V 已在 jar」，要么是带类型的
/// 失败原因；所有完成信号走同一条定稿规则（新值稳定 1.5 秒）。
void main() {
  late FakeRoundClock clock;
  late FakeRoundEnvironment env;
  late CfVerificationRounds rounds;

  setUp(() {
    clock = FakeRoundClock();
    env = FakeRoundEnvironment(clock);
    rounds = CfVerificationRounds(environment: env, clock: clock);
    env.rounds = rounds;
  });

  /// 发起一轮并等到验证页展示出来。
  Future<(Future<CfRoundOutcome>, CfVerificationRound)> start({
    CfVerifyMode mode = CfVerifyMode.silentFirst,
  }) async {
    final outcome = rounds.verify(mode: mode);
    await pumpEventQueue();
    return (outcome, env.presented!);
  }

  group('定稿', () {
    test('v1@0s、v2@0.6s、404@0.8s → 定稿 v2，jar 里是 v2', () async {
      final (outcome, round) = await start();

      env.webView = 'v1';
      round.clearanceSeen('v1', source: 'polling');
      await clock.advance(const Duration(milliseconds: 600));
      env.webView = 'v2';
      round.clearanceSeen('v2', source: 'polling');
      await clock.advance(const Duration(milliseconds: 200));
      // /challenge 落到源站 404：网络层确认通过，但半成品期的值不能直接收口
      round.completionHint('main frame /challenge 404', conclusive: true);
      expect(round.isDone, isFalse, reason: '404 本身不能让一轮通过');

      await clock.advance(const Duration(seconds: 3));

      final result = await outcome;
      expect(result, isA<CfRoundPassed>());
      expect((result as CfRoundPassed).clearance, 'v2');
      expect(env.jar, 'v2', reason: '通过 = 定稿值已在 jar');
      expect(env.landed, ['v2'], reason: '半成品 v1 从未落 jar');
      expect(
        env.landedAt.single,
        greaterThanOrEqualTo(const Duration(milliseconds: 2100)),
        reason: 'v2 在 0.6s 出现，稳定 1.5s 后才定稿',
      );
      expect(env.recordedFailures, isEmpty);
      expect(env.resets, 1);
      expect(env.calls, containsAllInOrder(['stopRefresh', 'backup', 'prime', 'present']));
      expect(env.calls, containsAllInOrder(['land', 'passed', 'dismiss', 'restartRefresh']));
    });

    test('轮次自己读 WebView：只收到完成迹象也能定稿', () async {
      final (outcome, round) = await start();
      env.webView = 'fresh';

      round.completionHint('challenge-platform response, no markers');
      await clock.advance(const Duration(seconds: 2));

      final result = await outcome;
      expect((result as CfRoundPassed).clearance, 'fresh');
      expect(env.jar, 'fresh');
    });

    test('网络层确认通过却始终读不到新值 → notLanded，计一次失败并恢复旧值', () async {
      final (outcome, round) = await start();

      round.completionHint('main frame /challenge 404', conclusive: true);
      await clock.advance(const Duration(seconds: 9));

      final result = await outcome;
      expect((result as CfRoundFailed).reason, CfRoundFailure.notLanded);
      expect(env.recordedFailures, [round.id]);
      expect(env.jar, 'old', reason: '失败要恢复备份，别让 jar 空着');
    });

    test('/challenge 直接 404、没有下发挑战 → 宽限后落 WebView 现有的值并通过', () async {
      // WebView 里早就有一枚有效值（不算新值），jar 里是另一枚
      env.webView = 'wv-live';
      env.staleWebView = 'wv-live';
      final (outcome, round) = await start();

      round.completionHint('main frame /challenge 404', conclusive: true);
      await clock.advance(const Duration(seconds: 2));
      expect(round.isDone, isFalse, reason: '宽限期内仍先等新值');
      await clock.advance(const Duration(seconds: 2));

      final result = await outcome;
      expect((result as CfRoundPassed).clearance, 'wv-live');
      expect(env.jar, 'wv-live');
      expect(env.recordedFailures, isEmpty, reason: '不再按 notLanded 计失败');
      expect(
        clock.elapsed,
        lessThan(const Duration(seconds: 8)),
        reason: '不用白等 8 秒',
      );
    });

    test('WebView 现值就是 jar 原来那枚 → 照样落值通过，交给重放判断是否有效', () async {
      env.webView = 'old';
      final (outcome, round) = await start();

      round.completionHint('main frame /challenge 404', conclusive: true);
      await clock.advance(const Duration(seconds: 4));

      final result = await outcome;
      expect((result as CfRoundPassed).clearance, 'old');
      expect(env.jar, 'old');
      expect(env.recordedFailures, isEmpty);
    });

    test('宽限期内来了新值（跳转后第二枚）→ 落新值，不落旧值', () async {
      env.webView = 'wv-live';
      env.staleWebView = 'wv-live';
      final (outcome, round) = await start();

      round.completionHint('main frame /challenge 404', conclusive: true);
      await clock.advance(const Duration(seconds: 1));
      env.webView = 'fresh';
      round.clearanceSeen('fresh', source: 'polling');
      await clock.advance(const Duration(seconds: 3));

      final result = await outcome;
      expect((result as CfRoundPassed).clearance, 'fresh');
      expect(env.landed, ['fresh']);
    });

    test('闸门始终不采纳定稿值 → 重试后 notLanded', () async {
      env.gateAccepts = false;
      final (outcome, round) = await start();
      env.webView = 'fresh';
      round.clearanceSeen('fresh', source: 'polling');

      await clock.advance(const Duration(seconds: 4));

      final result = await outcome;
      expect((result as CfRoundFailed).reason, CfRoundFailure.notLanded);
      expect(env.landed, hasLength(3), reason: '落值确认 3 次');
    });

    test('定稿后站点又签一枚（第二枚晚到）→ 落值失败后改落最新值并通过', () async {
      env.landOnlyCurrentWebView = true;
      // 定稿窗口已过、正在落 v1 时，/challenge 跳转又签了 v2
      env.onLand = (value) {
        if (value == 'v1') env.webView = 'v2';
      };
      final (outcome, round) = await start();
      env.webView = 'v1';
      round.clearanceSeen('v1', source: 'polling');
      await clock.advance(const Duration(seconds: 3));

      final result = await outcome;
      expect((result as CfRoundPassed).clearance, 'v2');
      expect(env.jar, 'v2');
      expect(env.landed.first, 'v1');
      expect(env.landed.last, 'v2');
    });

    test('值一直在变、稳定不下来 → 不落值，按超时收口', () async {
      final (outcome, round) = await start();
      var n = 0;
      // 每 1 秒换一枚值，永远不满 1.5 秒
      for (var i = 0; i < 12 && !round.isDone; i++) {
        env.webView = 'v${n++}';
        round.clearanceSeen(env.webView!, source: 'polling');
        await clock.advance(const Duration(seconds: 1));
      }

      final result = await outcome;
      expect((result as CfRoundFailed).reason, CfRoundFailure.timeout);
      expect(env.landed, isEmpty, reason: '还在变的值不落 jar');
    });

    test('定稿期间的自动放弃被忽略（用户退出除外）', () async {
      final (outcome, round) = await start();
      env.webView = 'fresh';
      round.clearanceSeen('fresh', source: 'polling');
      await clock.advance(const Duration(milliseconds: 500));

      round.giveUp(CfRoundFailure.timeout, detail: 'silent background timeout');
      expect(round.isDone, isFalse);

      await clock.advance(const Duration(seconds: 2));
      expect((await outcome).passed, isTrue);
    });
  });

  group('失败原因', () {
    test('冷却期内 → cooldown，不起轮、不计数', () async {
      env.cooling = true;

      final result = await rounds.verify(mode: CfVerifyMode.background);

      expect((result as CfRoundFailed).reason, CfRoundFailure.cooldown);
      expect(result.round, 0);
      expect(env.calls, isEmpty);
      expect(env.recordedFailures, isEmpty);
    });

    test('没有前台 UI → noUi，不碰 jar', () async {
      env.hasUi = false;

      final result = await rounds.verify(mode: CfVerifyMode.background);

      expect((result as CfRoundFailed).reason, CfRoundFailure.noUi);
      expect(env.calls, isEmpty);
    });

    test('overlay 在准备期间失效 → noUi，恢复旧值、不计数', () async {
      env.presentOk = false;

      final result = await rounds.verify(mode: CfVerifyMode.foreground);

      expect((result as CfRoundFailed).reason, CfRoundFailure.noUi);
      expect(env.jar, 'old');
      expect(env.recordedFailures, isEmpty);
      expect(rounds.active, isNull);
    });

    test('用户退出 → cancelled，计一次失败、恢复旧值', () async {
      final (outcome, round) = await start(mode: CfVerifyMode.foreground);

      round.giveUp(CfRoundFailure.cancelled, detail: 'user exit');

      final result = await outcome;
      expect((result as CfRoundFailed).reason, CfRoundFailure.cancelled);
      expect(env.recordedFailures, [round.id]);
      expect(env.jar, 'old');
    });

    test('静默超时 → timeout，计一次失败', () async {
      final (outcome, round) = await start(mode: CfVerifyMode.background);

      round.giveUp(CfRoundFailure.timeout, detail: 'silent background timeout');

      expect(((await outcome) as CfRoundFailed).reason, CfRoundFailure.timeout);
      expect(env.recordedFailures, [round.id]);
    });

    test('502/加载失败后超时 → inconclusive：不计失败、不覆盖旧值', () async {
      final (outcome, round) = await start(mode: CfVerifyMode.background);

      round.networkTrouble('main frame http 502');
      round.giveUp(CfRoundFailure.timeout, detail: 'silent background timeout');

      final result = await outcome;
      expect((result as CfRoundFailed).reason, CfRoundFailure.inconclusive);
      expect(env.recordedFailures, isEmpty);
      expect(env.jar, 'old');
    });

    test('网络恢复、挑战露出后再超时 → 仍按 timeout 计', () async {
      final (outcome, round) = await start(mode: CfVerifyMode.background);

      round.networkTrouble('main frame load error');
      round.challengeShown();
      round.giveUp(CfRoundFailure.timeout, detail: 'silent background timeout');

      expect(((await outcome) as CfRoundFailed).reason, CfRoundFailure.timeout);
    });
  });

  group('合流', () {
    test('N 个合流者拿到同一个结果，只记一次失败', () async {
      final first = rounds.verify(mode: CfVerifyMode.background);
      await pumpEventQueue();
      final joiners = [
        for (var i = 0; i < 4; i++)
          rounds.verify(
            mode: i.isEven ? CfVerifyMode.silentFirst : CfVerifyMode.background,
          ),
      ];
      await pumpEventQueue();
      final round = env.presented!;
      expect(env.presentations, 1, reason: '只起一轮');
      expect(round.hasForegroundWaiter, isTrue, reason: '有用户可见请求合流');

      round.giveUp(CfRoundFailure.cancelled, detail: 'user exit');

      final results = await Future.wait([first, ...joiners]);
      expect(results.toSet(), hasLength(1), reason: '所有人拿到同一个结果对象');
      expect(env.recordedFailures, [round.id], reason: '一轮只记一次失败');
      expect(env.restores, 1);
    });

    test('结果已出、验证页仍在析构时加入：直接拿刚出的结果', () async {
      // 不立即 release：模拟析构冷却期
      env.rounds = null;
      final (outcome, round) = await start();
      env.webView = 'fresh';
      round.clearanceSeen('fresh', source: 'polling');
      await clock.advance(const Duration(seconds: 2));
      expect((await outcome).passed, isTrue);
      expect(rounds.active, same(round));

      final joined = await rounds.verify(mode: CfVerifyMode.foreground);

      expect(joined, same(await outcome));
      expect(env.presentations, 1);
      rounds.release(round);
      expect(rounds.active, isNull);
    });
  });
}
