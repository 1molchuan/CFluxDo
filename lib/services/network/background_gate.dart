import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 后台请求给前台让路的共享闸门。
///
/// 只管后台（低优先级）请求，两条规则：
/// - 前台刚发过请求的 [foregroundYield] 内，后台请求先等一等，把并发槽位
///   和速率窗口留给用户正在等的内容；前台一直有请求时最多让 [maxYieldWait]，
///   不让后台饿死；
/// - 主站回了真限流的 429（不是 CF 挑战）后，所有后台请求一起退避，
///   短时间内连着撞上就翻倍；退避结束时各自加一点随机抖动，免得同一刻齐发。
///
/// - 主站回了挑战型 429（CF 速率规则的质询，见 CfRateChallengeLimiter）后，
///   后台请求停到冷却结束（[holdForRateChallenge]），之后的 [recoveryPeriod]
///   内一秒只放一个，不让攒下的请求一齐涌出去再撞一次。
///
/// 前台请求的 429 仍由恢复层按 Retry-After 自己重放，这里不拦。
class BackgroundGate {
  BackgroundGate._();

  static final BackgroundGate instance = BackgroundGate._();

  static const foregroundYield = Duration(seconds: 3);
  static const maxYieldWait = Duration(seconds: 10);
  static const _baseBackoff = Duration(seconds: 10);
  static const _maxBackoff = Duration(seconds: 60);

  /// 服务端明说要等更久时照办，但不超过这个数（后台任务各自还有退避）
  static const _maxRetryAfter = Duration(minutes: 5);

  /// 距上次 429 超过这么久，连撞计数清零
  static const _strikeReset = Duration(minutes: 2);
  static const _maxJitterMs = 1500;

  /// 挑战型 429 冷却结束后的低速恢复期与其中后台请求的间隔
  static const recoveryPeriod = Duration(seconds: 20);
  static const recoverySpacing = Duration(seconds: 1);

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _lastForegroundAt = _epoch;
  DateTime _backoffUntil = _epoch;
  DateTime _lastRateLimitedAt = _epoch;
  int _strikes = 0;
  DateTime _challengeHoldUntil = _epoch;
  DateTime _recoveryUntil = _epoch;
  DateTime _nextRecoverySlot = _epoch;
  math.Random _random = math.Random();
  DateTime Function() _now = DateTime.now;
  Future<void> Function(Duration) _delay = Future<void>.delayed;

  /// 前台（用户可见）请求发出时调用（赋值级开销）
  void markForeground() => _lastForegroundAt = _now();

  /// 主站回了真限流的 429。[retryAfter] 为服务端给的等待时长。
  void reportRateLimited({Duration? retryAfter}) {
    final now = _now();
    final asked = retryAfter == null
        ? Duration.zero
        : (retryAfter > _maxRetryAfter ? _maxRetryAfter : retryAfter);
    if (now.isBefore(_backoffUntil)) {
      // 同一退避窗口里并发撞上的 429 只续期，不升级
      final until = now.add(asked);
      if (until.isAfter(_backoffUntil)) _backoffUntil = until;
      _lastRateLimitedAt = now;
      return;
    }
    _strikes = now.difference(_lastRateLimitedAt) > _strikeReset
        ? 1
        : _strikes + 1;
    _lastRateLimitedAt = now;
    var penalty = _baseBackoff * (1 << (_strikes - 1).clamp(0, 3));
    if (penalty > _maxBackoff) penalty = _maxBackoff;
    _backoffUntil = now.add(asked > penalty ? asked : penalty);
    debugPrint('[BackgroundGate] 429 → 后台请求退避到 $_backoffUntil (第 $_strikes 次)');
  }

  /// 主站撞了挑战型 429：后台请求停到 [until]，之后进 [recoveryPeriod]
  void holdForRateChallenge(DateTime until) {
    if (until.isAfter(_challengeHoldUntil)) _challengeHoldUntil = until;
    final recovery = _challengeHoldUntil.add(recoveryPeriod);
    if (recovery.isAfter(_recoveryUntil)) _recoveryUntil = recovery;
    debugPrint('[BackgroundGate] 挑战型 429 → 后台请求停到 $_challengeHoldUntil');
  }

  DateTime get _holdUntil =>
      _challengeHoldUntil.isAfter(_backoffUntil)
          ? _challengeHoldUntil
          : _backoffUntil;

  /// 后台请求还要因为限流再等多久（不含抖动）
  Duration get backoffRemaining {
    final left = _holdUntil.difference(_now());
    return left > Duration.zero ? left : Duration.zero;
  }

  /// 一次随机抖动（0～1.5 s）
  Duration jitter() => Duration(milliseconds: _random.nextInt(_maxJitterMs));

  /// 后台请求发出前调用：等到没有退避、前台也让过了再返回。
  /// [cancelToken] 取消时立即返回，由调用方按取消处理。
  Future<void> waitForTurn({CancelToken? cancelToken}) async {
    final start = _now();
    var backedOff = false;
    while (!(cancelToken?.isCancelled ?? false)) {
      final now = _now();
      final backoff = _holdUntil.difference(now);
      if (backoff > Duration.zero) {
        backedOff = true;
        await _sleep(backoff, cancelToken);
        continue;
      }
      final yieldLeft = foregroundYield - now.difference(_lastForegroundAt);
      final budget = maxYieldWait - now.difference(start);
      if (yieldLeft > Duration.zero && budget > Duration.zero) {
        await _sleep(yieldLeft < budget ? yieldLeft : budget, cancelToken);
        continue;
      }
      // 挑战型 429 刚冷却完：一秒放一个
      if (now.isBefore(_recoveryUntil)) {
        final slotWait = _nextRecoverySlot.difference(now);
        if (slotWait > Duration.zero) {
          await _sleep(slotWait, cancelToken);
          continue;
        }
        _nextRecoverySlot = now.add(recoverySpacing);
        return;
      }
      break;
    }
    if (backedOff) await _sleep(jitter(), cancelToken);
  }

  Future<void> _sleep(Duration duration, CancelToken? cancelToken) {
    final delay = _delay(duration);
    if (cancelToken == null) return delay;
    return Future.any<void>([delay, cancelToken.whenCancel.then((_) {})]);
  }

  @visibleForTesting
  void resetForTest({
    math.Random? random,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) {
    _lastForegroundAt = _epoch;
    _backoffUntil = _epoch;
    _lastRateLimitedAt = _epoch;
    _strikes = 0;
    _challengeHoldUntil = _epoch;
    _recoveryUntil = _epoch;
    _nextRecoverySlot = _epoch;
    _random = random ?? math.Random();
    _now = now ?? DateTime.now;
    _delay = delay ?? Future<void>.delayed;
  }
}
