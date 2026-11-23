import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/background_gate.dart';
import 'package:fluxdo/services/network/cf/cf_rate_challenge_limiter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 挑战型 429 的冷却档位、熔断与落盘（[CfRateChallengeLimiter]）。
void main() {
  late DateTime now;
  late BackgroundGate gate;
  late CfRateChallengeLimiter limiter;

  void advance(Duration d) => now = now.add(d);

  setUp(() {
    now = DateTime(2026, 11, 23, 12);
    gate = BackgroundGate.instance..resetForTest(now: () => now);
    limiter = CfRateChallengeLimiter(now: () => now, gate: gate);
  });

  tearDown(() => gate.resetForTest());

  test('逐轮升档 60 → 90 → 180 → 300 s；同一轮里并发撞上的不升档', () {
    expect(limiter.report('linux.do', path: '/a'), const Duration(seconds: 60));
    advance(const Duration(seconds: 10));
    expect(
      limiter.report('linux.do', path: '/b'),
      const Duration(seconds: 50),
      reason: '冷却中撞上的只报剩余时间',
    );
    expect(gate.backoffRemaining, const Duration(seconds: 50));

    // 熔断门槛是 5 分钟内 3 轮：每轮之间隔开 3 分钟，只看升档
    final expected = [90, 180, 300, 300];
    for (final seconds in expected) {
      advance(const Duration(minutes: 6));
      expect(
        limiter.report('linux.do', path: '/c'),
        Duration(seconds: seconds),
      );
    }
    expect(limiter.isCircuitOpen('linux.do'), isFalse);
  });

  test('10 分钟没再撞，从第一档重新算', () {
    limiter.report('linux.do', path: '/a');
    advance(const Duration(minutes: 2));
    expect(limiter.report('linux.do', path: '/a'), const Duration(seconds: 90));
    advance(const Duration(minutes: 11));
    expect(limiter.report('linux.do', path: '/a'), const Duration(seconds: 60));
  });

  test('5 分钟内撞满 3 轮 → 熔断 10 分钟，后台请求一起停', () {
    limiter.report('linux.do', path: '/a'); // 60 s
    advance(const Duration(seconds: 61));
    limiter.report('linux.do', path: '/a'); // 90 s
    advance(const Duration(seconds: 91));
    final wait = limiter.report('linux.do', path: '/a');

    expect(limiter.isCircuitOpen('linux.do'), isTrue);
    expect(wait, CfRateChallengeLimiter.circuitOpen);
    expect(gate.backoffRemaining, CfRateChallengeLimiter.circuitOpen);
  });

  test('子站各算各的，不让主站的后台请求停', () {
    final wait = limiter.report('credit.linux.do', path: '/api');

    expect(wait, const Duration(seconds: 60));
    expect(limiter.remaining('credit.linux.do'), const Duration(seconds: 60));
    expect(limiter.remaining('linux.do'), Duration.zero);
    expect(gate.backoffRemaining, Duration.zero);
  });

  test('主站冷却落盘，重开后接着冷却（并给后台请求续上）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    limiter.initialize(prefs, mainHost: 'linux.do');
    limiter.report('linux.do', path: '/a');
    await Future<void>.delayed(Duration.zero);

    advance(const Duration(seconds: 20));
    gate.resetForTest(now: () => now);
    final restarted = CfRateChallengeLimiter(now: () => now, gate: gate)
      ..initialize(prefs, mainHost: 'linux.do');

    expect(restarted.remaining('linux.do'), const Duration(seconds: 40));
    expect(gate.backoffRemaining, const Duration(seconds: 40));
    // 档位也接着算
    advance(const Duration(seconds: 41));
    expect(
      restarted.report('linux.do', path: '/a'),
      const Duration(seconds: 90),
    );
  });

  test('落盘的冷却不信超过 15 分钟的值（时钟被改等）', () async {
    SharedPreferences.setMockInitialValues({
      'cf_rate_challenge_v1':
          '{"host":"linux.do","until":${now.add(const Duration(days: 3)).millisecondsSinceEpoch},'
          '"circuitUntil":0,"lastRoundAt":${now.millisecondsSinceEpoch},"streak":2}',
    });
    final prefs = await SharedPreferences.getInstance();
    limiter.initialize(prefs, mainHost: 'linux.do');

    expect(limiter.remaining('linux.do'), const Duration(minutes: 15));
  });
}
