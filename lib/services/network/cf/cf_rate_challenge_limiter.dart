import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_logger.dart';
import '../background_gate.dart';

/// 挑战型 429（`429 + cf-mitigated: challenge`）的冷却与熔断。
///
/// 这是 CF 的**速率限制规则**配了质询动作：请求太密就对超额的请求出质询。
/// 它和普通的盾不一样——惩罚窗口没过之前，重新过盾、换线都不管用，只能等请求
/// 速率降下来（xuemk/linuxdo-android 实测惩罚窗约 60 s，见其 v1.6.0～1.6.2；
/// 我们 beta.9 的日志里三分之一的验证「过了白过」，也对得上）。以前一撞上就
/// 弹验证页、过完立刻重放，等于在惩罚窗里继续加码。
///
/// 规则（按 host 各算各的；主站另外让后台请求一起停）：
/// - 冷却按 [steps] 逐级加长（60 → 90 → 180 → 300 s），[streakReset] 内没再撞
///   就从第一档重新算；冷却期间并发撞上的只续期、不升档；
/// - [circuitWindow] 内撞满 [circuitThreshold] 轮 → 熔断 [circuitOpen]：后台
///   请求全部停发，前台请求照常发（用户点了才发，本身就是低速的手动重试）；
/// - 冷却到期后后台请求逐个放出（[BackgroundGate] 的恢复期，1 s 一个）；
/// - 主站状态落盘，杀掉重开不会一启动就把冷却清零、接着撞。
///
/// 只管请求**带着** cf_clearance 撞上的 429：一枚凭据都没有时（新装、刚清过
/// Cookie），质询确实要先拿到凭据，仍走原来的验证流程。
class CfRateChallengeLimiter {
  CfRateChallengeLimiter({
    DateTime Function()? now,
    BackgroundGate? gate,
    this.mainHost = 'linux.do',
  }) : _now = now ?? DateTime.now,
       _gate = gate ?? BackgroundGate.instance;

  static final CfRateChallengeLimiter instance = CfRateChallengeLimiter();

  static const steps = [
    Duration(seconds: 60),
    Duration(seconds: 90),
    Duration(seconds: 180),
    Duration(seconds: 300),
  ];
  static const streakReset = Duration(minutes: 10);
  static const circuitWindow = Duration(minutes: 5);
  static const circuitThreshold = 3;
  static const circuitOpen = Duration(minutes: 10);

  /// 落盘冷却的上限：时钟被改、或者存了个离谱的值，别把 App 锁死
  static const _maxRestored = Duration(minutes: 15);
  static const _prefsKey = 'cf_rate_challenge_v1';

  final DateTime Function() _now;
  final BackgroundGate _gate;

  /// 让后台请求一起停的 host（主站）
  String mainHost;

  final Map<String, _HostState> _hosts = {};
  SharedPreferences? _prefs;

  /// 启动时恢复上次的主站冷却
  void initialize(SharedPreferences prefs, {required String mainHost}) {
    _prefs = prefs;
    this.mainHost = mainHost;
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['host'] != mainHost) return;
      final now = _now();
      DateTime? at(String key) {
        final ms = map[key];
        if (ms is! int || ms <= 0) return null;
        final t = DateTime.fromMillisecondsSinceEpoch(ms);
        final limit = now.add(_maxRestored);
        return t.isAfter(limit) ? limit : t;
      }

      final state = _HostState()
        ..until = at('until')
        ..circuitUntil = at('circuitUntil')
        ..lastRoundAt = at('lastRoundAt')
        ..streak = (map['streak'] as int?) ?? 0;
      _hosts[mainHost] = state;
      final until = state.until;
      if (until != null && until.isAfter(now)) {
        _gate.holdForRateChallenge(until);
        AppLogger.info(
          '恢复上次的挑战型 429 冷却，还剩 ${until.difference(now).inSeconds} s',
          tag: 'CfRateChallenge',
          fields: {'streak': state.streak, 'circuit': state.circuitOpenAt(now)},
        );
      }
    } catch (e) {
      debugPrint('[CfRateChallenge] 恢复冷却失败: $e');
    }
  }

  /// [host] 还要冷却多久（没有冷却返回 [Duration.zero]）
  Duration remaining(String host) {
    final until = _hosts[host.toLowerCase()]?.until;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    return left > Duration.zero ? left : Duration.zero;
  }

  /// 是否在熔断中
  bool isCircuitOpen(String host) =>
      _hosts[host.toLowerCase()]?.circuitOpenAt(_now()) ?? false;

  /// 记一次挑战型 429，返回这次要冷却多久
  Duration report(String host, {required String path}) {
    final key = host.toLowerCase();
    final now = _now();
    final state = _hosts.putIfAbsent(key, _HostState.new);
    final until = state.until;
    if (until != null && until.isAfter(now)) {
      // 同一轮冷却里并发 / 前台手动撞上的：不升档，冷却也不续
      return until.difference(now);
    }

    final last = state.lastRoundAt;
    state.streak = last == null || now.difference(last) > streakReset
        ? 1
        : state.streak + 1;
    state.lastRoundAt = now;
    state.rounds
      ..add(now)
      ..removeWhere((t) => now.difference(t) > circuitWindow);
    final wasOpen = state.circuitOpenAt(now);
    if (wasOpen || state.rounds.length >= circuitThreshold) {
      state.circuitUntil = now.add(circuitOpen);
    }
    final step = steps[(state.streak - 1).clamp(0, steps.length - 1)];
    var next = now.add(step);
    final circuitUntil = state.circuitUntil;
    if (circuitUntil != null && circuitUntil.isAfter(next)) next = circuitUntil;
    state.until = next;

    final wait = next.difference(now);
    final circuit = state.circuitOpenAt(now);
    AppLogger.warning(
      circuit
          ? '挑战型 429（$path）：${circuitWindow.inMinutes} 分钟内撞了 '
                '${state.rounds.length} 轮，熔断 ${wait.inSeconds} s，期间后台请求全停、不弹验证'
          : '挑战型 429（$path）：第 ${state.streak} 轮，冷却 ${wait.inSeconds} s，'
                '期间后台请求暂停、不弹验证',
      tag: 'CfRateChallenge',
      fields: {
        'host': key,
        'streak': state.streak,
        'roundsInWindow': state.rounds.length,
        'circuit': circuit,
        'waitSeconds': wait.inSeconds,
      },
    );
    if (key == mainHost) {
      _gate.holdForRateChallenge(next);
      _persist(state);
    }
    return wait;
  }

  void _persist(_HostState state) {
    final prefs = _prefs;
    if (prefs == null) return;
    int ms(DateTime? t) => t?.millisecondsSinceEpoch ?? 0;
    prefs.setString(
      _prefsKey,
      jsonEncode({
        'host': mainHost,
        'until': ms(state.until),
        'circuitUntil': ms(state.circuitUntil),
        'lastRoundAt': ms(state.lastRoundAt),
        'streak': state.streak,
      }),
    );
  }

  Map<String, Object?> diagnostics() {
    final now = _now();
    return {
      for (final e in _hosts.entries)
        e.key: {
          'remainingSeconds': remaining(e.key).inSeconds,
          'streak': e.value.streak,
          'circuit': e.value.circuitOpenAt(now),
        },
    };
  }

  @visibleForTesting
  void resetForTest() {
    _hosts.clear();
    _prefs = null;
  }
}

class _HostState {
  DateTime? until;
  DateTime? circuitUntil;
  DateTime? lastRoundAt;
  int streak = 0;
  final List<DateTime> rounds = [];

  bool circuitOpenAt(DateTime now) {
    final c = circuitUntil;
    return c != null && c.isAfter(now);
  }
}
