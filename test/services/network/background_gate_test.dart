import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/background_gate.dart';

/// 假时钟：sleep 直接把时钟往前拨，记下每次睡了多久
class _FakeClock {
  DateTime now = DateTime(2026, 10, 27, 12);
  final sleeps = <Duration>[];

  DateTime read() => now;

  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    now = now.add(d);
  }

  void advance(Duration d) => now = now.add(d);
}

/// 抖动固定为 0，便于断言
class _ZeroRandom implements math.Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

void main() {
  late _FakeClock clock;
  final gate = BackgroundGate.instance;

  setUp(() {
    clock = _FakeClock();
    gate.resetForTest(
      random: _ZeroRandom(),
      now: clock.read,
      delay: clock.sleep,
    );
  });

  tearDown(() => gate.resetForTest());

  test('没有前台请求、没有限流时立即放行', () async {
    await gate.waitForTurn();
    expect(clock.sleeps, isEmpty);
  });

  test('前台刚发过请求：后台等满 3 秒再走', () async {
    gate.markForeground();
    clock.advance(const Duration(seconds: 1));
    await gate.waitForTurn();
    expect(clock.sleeps, [const Duration(seconds: 2)]);
  });

  test('前台一直有请求：后台最多让 10 秒，不饿死', () async {
    var calls = 0;
    gate.resetForTest(
      random: _ZeroRandom(),
      now: clock.read,
      delay: (d) async {
        await clock.sleep(d);
        // 每次醒来前台都又发了一个
        if (++calls < 20) gate.markForeground();
      },
    );
    gate.markForeground();
    await gate.waitForTurn();
    final total = clock.sleeps.fold(Duration.zero, (a, b) => a + b);
    expect(total, BackgroundGate.maxYieldWait);
  });

  test('429 没给 Retry-After：退避 10 秒，同一窗口内再撞只续期不升级', () {
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 10));
    clock.advance(const Duration(seconds: 4));
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 6));
  });

  test('退避刚过又撞：翻倍；安静 2 分钟后重新从 10 秒算', () {
    gate.reportRateLimited();
    clock.advance(const Duration(seconds: 11));
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 20));
    clock.advance(const Duration(seconds: 21));
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 40));
    clock.advance(const Duration(seconds: 41));
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 60), reason: '封顶');
    clock.advance(const Duration(minutes: 5));
    gate.reportRateLimited();
    expect(gate.backoffRemaining, const Duration(seconds: 10));
  });

  test('服务端要等更久就照办，但不超过 5 分钟', () {
    gate.reportRateLimited(retryAfter: const Duration(seconds: 30));
    expect(gate.backoffRemaining, const Duration(seconds: 30));
    clock.advance(const Duration(minutes: 3));
    gate.reportRateLimited(retryAfter: const Duration(hours: 1));
    expect(gate.backoffRemaining, const Duration(minutes: 5));
  });

  test('退避中的后台请求等到退避结束，再加抖动', () async {
    gate.resetForTest(
      random: _FixedRandom(700),
      now: clock.read,
      delay: clock.sleep,
    );
    gate.reportRateLimited();
    await gate.waitForTurn();
    expect(clock.sleeps, [
      const Duration(seconds: 10),
      const Duration(milliseconds: 700),
    ]);
  });

  test('取消后立即返回', () async {
    final token = CancelToken()..cancel();
    gate.reportRateLimited();
    await gate.waitForTurn(cancelToken: token);
    expect(clock.sleeps, isEmpty);
  });
}

class _FixedRandom implements math.Random {
  _FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}
