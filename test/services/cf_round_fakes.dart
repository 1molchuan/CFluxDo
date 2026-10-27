import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_verification_round.dart';

/// 验证轮次测试用的假时钟：只有 [advance] 才推进时间、触发到期的计时器。
class FakeRoundClock implements CfRoundClock {
  FakeRoundClock() : _start = DateTime(2026, 10, 15, 12) {
    _now = _start;
  }

  final DateTime _start;
  late DateTime _now;
  final List<_FakeTimer> _timers = [];

  /// 自构造以来经过的时间。
  Duration get elapsed => _now.difference(_start);

  @override
  DateTime now() => _now;

  @override
  CfRoundTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(_now.add(delay), callback);
    _timers.add(timer);
    return timer;
  }

  /// 推进 [duration]：按到期顺序逐个触发计时器，每步之间排空微任务。
  Future<void> advance(Duration duration) async {
    final end = _now.add(duration);
    while (true) {
      await pumpEventQueue();
      _timers.removeWhere((t) => t.cancelled);
      final due = _timers.where((t) => !t.dueAt.isAfter(end)).toList()
        ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
      if (due.isEmpty) break;
      final next = due.first;
      _timers.remove(next);
      if (next.dueAt.isAfter(_now)) _now = next.dueAt;
      next.callback();
    }
    _now = end;
    await pumpEventQueue();
  }
}

class _FakeTimer implements CfRoundTimer {
  _FakeTimer(this.dueAt, this.callback);

  final DateTime dueAt;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

/// 轮次的外部能力替身：一个 jar、一个 WebView 当前值、一张调用流水。
class FakeRoundEnvironment implements CfRoundEnvironment {
  FakeRoundEnvironment(this.clock);

  final FakeRoundClock clock;

  /// 由测试在构造 [CfVerificationRounds] 后挂上（dismiss 时立即结束这一轮）。
  CfVerificationRounds? rounds;

  bool cooling = false;
  bool hasUi = true;
  bool presentOk = true;

  /// 权威闸门是否采纳落值。
  bool gateAccepts = true;

  /// 像真实落值一样：只收 WebView 里当前那枚值（acceptValues 口径）
  bool landOnlyCurrentWebView = false;

  /// 落值开始时回调（模拟落值期间站点又签了新值）
  void Function(String value)? onLand;

  /// App 侧 jar 里的 cf_clearance。
  String? jar = 'old';

  /// 验证 WebView 里当前的 cf_clearance。
  String? webView;

  /// 验证开始前 WebView 里就有的值：真实验证页会把它和 jar 备份一起当旧值
  String? staleWebView;

  final List<String> calls = [];
  final List<int> recordedFailures = [];
  final List<CfVerifyMode> joins = [];
  final List<String> landed = [];
  final List<Duration> landedAt = [];
  int resets = 0;
  int restores = 0;
  int presentations = 0;
  CfVerificationRound? presented;

  @override
  Future<Object?> ensureUi(BuildContext? context) async =>
      hasUi ? Object() : null;

  @override
  Future<void> stopRefresh() async => calls.add('stopRefresh');

  @override
  void restartRefreshLater() => calls.add('restartRefresh');

  @override
  Future<Object?> backupAndClear() async {
    calls.add('backup');
    final backup = jar;
    jar = null;
    return backup;
  }

  @override
  Future<void> restore(Object? backup) async {
    calls.add('restore');
    restores++;
    jar = backup as String?;
  }

  @override
  Future<void> primeSession() async => calls.add('prime');

  @override
  Future<bool> present(
    CfVerificationRound round,
    CfVerifyMode mode,
    Object ui,
    Object? backup,
  ) async {
    calls.add('present');
    if (!presentOk) return false;
    presentations++;
    presented = round;
    // 像验证页一样：只把与旧值不同的值当作新值
    round.attachReader(() async {
      final value = webView;
      return value != null && value != backup && value != staleWebView
          ? value
          : null;
    });
    round.attachCurrentReader(() async => webView);
    return true;
  }

  @override
  void onJoin(CfVerificationRound round, CfVerifyMode mode) => joins.add(mode);

  @override
  void dismiss(CfVerificationRound round) {
    calls.add('dismiss');
    rounds?.release(round);
  }

  @override
  Future<String?> land(CfVerificationRound round, String value) async {
    calls.add('land');
    landed.add(value);
    onLand?.call(value);
    landedAt.add(clock.elapsed);
    if (gateAccepts && (!landOnlyCurrentWebView || webView == value)) {
      jar = value;
    }
    return jar;
  }

  /// 落值确认后的收尾回调（模拟验证页回首页期间站点又签了新值）
  Future<void> Function(String value)? onAfterLanded;

  @override
  Future<void> afterLanded(CfVerificationRound round, String value) async {
    calls.add('afterLanded');
    await onAfterLanded?.call(value);
  }

  @override
  void onPassed(CfVerificationRound round, String value) => calls.add('passed');

  @override
  bool isCoolingDown() => cooling;

  @override
  void recordFailure(int round) => recordedFailures.add(round);

  @override
  void resetFailures() => resets++;
}
