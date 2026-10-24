import 'dart:async';

import 'package:flutter/widgets.dart';

import 'cf_challenge_logger.dart';
import 'cf_clearance_authority.dart';
import 'network/cf/cf_round_outcome.dart';

export 'network/cf/cf_round_outcome.dart';

// ---------------------------------------------------------------------------
// 时钟
// ---------------------------------------------------------------------------

/// 定稿计时用的时钟（测试注入假时钟，按需推进）。
abstract interface class CfRoundClock {
  DateTime now();

  /// [delay] 后执行一次 [callback]；返回值用于取消。
  CfRoundTimer schedule(Duration delay, void Function() callback);
}

abstract interface class CfRoundTimer {
  void cancel();
}

class SystemCfRoundClock implements CfRoundClock {
  const SystemCfRoundClock();

  @override
  DateTime now() => DateTime.now();

  @override
  CfRoundTimer schedule(Duration delay, void Function() callback) =>
      _SystemTimer(Timer(delay, callback));
}

class _SystemTimer implements CfRoundTimer {
  _SystemTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

// ---------------------------------------------------------------------------
// 验证页 → 轮次：原始信号
// ---------------------------------------------------------------------------

/// 读 WebView 当前 cf_clearance：只返回与验证开始前旧值**不同**的新值，
/// 没有新值返回 null（旧值过滤由验证页负责，它知道哪枚是残留）。
typedef CfFreshClearanceReader = Future<String?> Function();

/// 读 WebView 当前 cf_clearance，不管是不是验证开始前就有的旧值。
typedef CfCurrentClearanceReader = Future<String?> Function();

/// 验证页上报给轮次的原始信号。
///
/// 页面只报告看到了什么，不再自己判定「完成」：此前四个完成出口各有一套
/// 口径（JS 钩子「新值且无挑战标记」、兜底探测「任意新值」、轮询「稳定
/// 1.5 秒」、`/challenge` 404「先收口、Cookie 同步不等」），后两者都出过
/// 拿半成品值收口的事故。现在定稿规则只有一条，写在 [CfVerificationRound]。
abstract interface class CfVerificationSignals {
  /// 挂上（或摘下）读取 WebView 新值的入口；定稿期间轮次会主动轮询它。
  void attachReader(CfFreshClearanceReader? reader);

  /// 挂上（或摘下）读取 WebView 当前值（含旧值）的入口：网络层确认通过、
  /// 却一直没有新值时用它兜底（见 [CfVerificationRound.conclusiveGrace]）。
  void attachCurrentReader(CfCurrentClearanceReader? reader);

  /// 页面读到一枚新值（[source] 只用于日志）。
  void clearanceSeen(String value, {required String source});

  /// 完成迹象：挑战脚本拿到放行响应、页面离开挑战、`/challenge` 落到源站等。
  ///
  /// [conclusive] 表示网络层已确认通过（`/challenge` 返回源站 404 且不带
  /// cf-mitigated）：此后在限期内必须定稿，读不到新值按 notLanded 收口。
  void completionHint(String reason, {bool conclusive = false});

  /// 页面露出了可交互的挑战（说明网络是通的）。
  void challengeShown();

  /// 主文档加载失败 / 5xx：之后若以超时或退出收场，按 inconclusive 处理。
  void networkTrouble(String detail);

  /// 页面放弃：用户退出（cancelled）、静默超时 / 无挑战也无新值（timeout）。
  /// 已经在定稿时，非用户发起的放弃会被忽略。
  void giveUp(CfRoundFailure reason, {required String detail});

  /// 已见到新值、正在等它稳定或正在落值。
  bool get isSettling;

  /// 有调用方在等结果（页面数据/操作请求）：纯静默轮次超时直接失败，
  /// 有人等结果时超时转前台交给用户。
  bool get hasForegroundWaiter;

  bool get isDone;
}

// ---------------------------------------------------------------------------
// 一轮验证
// ---------------------------------------------------------------------------

/// 一轮验证的定稿与落值。
///
/// **唯一定稿规则**：页面上报（或轮次自己从 WebView 读到）的最新新值，
/// 连续 [settleWindow]（1.5 秒）没有再变，才算定稿；定稿后经
/// [landing]（BoundarySync + 权威闸门）写进 jar 并读回确认，确认后才以
/// [CfRoundPassed] 收口。所有完成迹象都只是让轮次更积极地去读值，
/// 不能单独让一轮通过。
///
/// 1.5 秒的来由：挑战脚本拿到放行响应后还要跳转/补最后一步，这时立刻收口
/// 会拿到一枚对 Dio 无效的半成品（2026-10-13 实测：放行响应 0.6 秒后
/// 轮询抢先收口，重试仍 403；2c07fe7b 只修了轮询这一个出口）。
class CfVerificationRound implements CfVerificationSignals {
  CfVerificationRound({
    required this.id,
    required Future<String?> Function(String value) landing,
    CfRoundClock clock = const SystemCfRoundClock(),
    this.settleWindow = const Duration(milliseconds: 1500),
    this.probeInterval = const Duration(milliseconds: 250),
    this.completionDeadline = const Duration(seconds: 8),
    this.conclusiveGrace = const Duration(seconds: 3),
    this.landingAttempts = 3,
    this.landingRetryDelay = const Duration(milliseconds: 500),
  }) : _landing = landing,
       _clock = clock;

  final int id;

  /// 新值需要保持不变的时长。
  final Duration settleWindow;

  /// 定稿期间主动读 WebView 的间隔。
  final Duration probeInterval;

  /// 完成迹象出现后最多等多久见到新值（与验证页完成探测的 8 秒一致）。
  final Duration completionDeadline;

  /// 网络层确认通过后等新值的宽限。过了还没有新值，说明这次根本没有下发
  /// 挑战（`/challenge` 直接落到源站 404，WebView 现有的值本来就有效）：
  /// 把 WebView 现有的值落进 jar 交给重放。jar 里原来就是这枚而重放仍被拦，
  /// 由调用方按「验证通过但对 Dio 无效」处理（冷却、询问改用浏览器网络栈），
  /// 不再每次白等 [completionDeadline] 再按 notLanded 计失败、反复弹验证。
  /// 宽限期内仍优先等新值：CF 常在挑战提交和 /challenge 跳转各签一次。
  final Duration conclusiveGrace;

  /// 落值确认的尝试次数与间隔（取代各调用方「等 1.5 秒 → 同步 → 重试
  /// 3×500ms」的配方）。
  final int landingAttempts;
  final Duration landingRetryDelay;

  final Future<String?> Function(String value) _landing;
  final CfRoundClock _clock;
  final Completer<CfRoundOutcome> _completer = Completer<CfRoundOutcome>();

  CfFreshClearanceReader? _reader;
  CfCurrentClearanceReader? _currentReader;
  bool _triedCurrentValue = false;
  String? _pendingValue;
  DateTime? _pendingSince;

  /// 本轮第一次见到新值的时刻：值一直在变、迟迟不稳定时据此兜底收口。
  DateTime? _firstSeenAt;
  DateTime? _hintAt;
  DateTime? _conclusiveAt;
  bool _networkTrouble = false;
  bool _reading = false;
  bool _landingInProgress = false;
  CfRoundTimer? _ticker;
  CfRoundOutcome? _result;

  @override
  bool hasForegroundWaiter = false;

  /// 这一轮的结果；所有合流者拿到的是同一个 Future。
  Future<CfRoundOutcome> get outcome => _completer.future;

  /// 已出结果时同步读取（未出结果为 null）。
  CfRoundOutcome? get result => _result;

  @override
  bool get isDone => _completer.isCompleted;

  @override
  bool get isSettling =>
      !isDone && (_pendingValue != null || _landingInProgress);

  @override
  void attachReader(CfFreshClearanceReader? reader) {
    _reader = reader;
  }

  @override
  void attachCurrentReader(CfCurrentClearanceReader? reader) {
    _currentReader = reader;
  }

  @override
  void clearanceSeen(String value, {required String source}) {
    if (isDone || _landingInProgress) return;
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    _networkTrouble = false;
    if (normalized != _pendingValue) {
      final replaced = _pendingValue != null;
      _pendingValue = normalized;
      _pendingSince = _clock.now();
      _firstSeenAt ??= _pendingSince;
      CfChallengeLogger.log(
        '[ROUND $id] ${replaced ? 'cf_clearance changed' : 'new cf_clearance'} '
        '(${normalized.length} chars, via $source), waiting '
        '${settleWindow.inMilliseconds}ms to settle',
      );
    }
    _ensureTicking();
  }

  @override
  void completionHint(String reason, {bool conclusive = false}) {
    if (isDone) return;
    _networkTrouble = false;
    final now = _clock.now();
    _hintAt = now;
    if (conclusive && _conclusiveAt == null) _conclusiveAt = now;
    CfChallengeLogger.log(
      '[ROUND $id] completion hint${conclusive ? ' (conclusive)' : ''}: $reason',
    );
    // 立刻读一次，而不是等下一拍
    _cancelTicker();
    unawaited(_tick());
  }

  @override
  void challengeShown() {
    _networkTrouble = false;
  }

  @override
  void networkTrouble(String detail) {
    if (isDone) return;
    _networkTrouble = true;
    CfChallengeLogger.log('[ROUND $id] network trouble: $detail');
  }

  @override
  void giveUp(CfRoundFailure reason, {required String detail}) {
    if (isDone) return;
    if (_landingInProgress) {
      // 落值只需一两秒，且值已确认通过：不让任何放弃打断它
      CfChallengeLogger.log('[ROUND $id] give up ($detail) ignored: landing');
      return;
    }
    if (reason != CfRoundFailure.cancelled && isSettling) {
      CfChallengeLogger.log('[ROUND $id] give up ($detail) ignored: settling');
      return;
    }
    // 网络层故障之后的超时/退出无从判断验证本身成败：不计失败、不覆盖
    final effective =
        _networkTrouble &&
            (reason == CfRoundFailure.timeout ||
                reason == CfRoundFailure.cancelled)
        ? CfRoundFailure.inconclusive
        : reason;
    _complete(
      CfRoundFailed(round: id, reason: effective),
      detail: detail,
    );
  }

  /// 宿主侧收口（没有 overlay、验证页被撤下等）。
  void abort(CfRoundFailure reason, {required String detail}) {
    if (isDone) return;
    _complete(CfRoundFailed(round: id, reason: reason), detail: detail);
  }

  /// 测试钩子用：直接以给定结果收口（不经定稿）。
  /// 只供 CfChallengeService.debugFinishVerification 与测试调用。
  void debugComplete(CfRoundOutcome outcome) =>
      _complete(outcome, detail: 'debug');

  void _ensureTicking() {
    if (_ticker != null || isDone || _landingInProgress) return;
    _ticker = _clock.schedule(probeInterval, () {
      _ticker = null;
      unawaited(_tick());
    });
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _tick() async {
    if (isDone || _landingInProgress) return;
    final reader = _reader;
    if (reader != null && !_reading) {
      _reading = true;
      try {
        final value = await reader();
        if (value != null && value.isNotEmpty) {
          clearanceSeen(value, source: 'round probe');
        }
      } catch (e) {
        debugPrint('[CfRound] 读取 WebView cf_clearance 失败: $e');
      } finally {
        _reading = false;
      }
    }
    if (isDone || _landingInProgress) return;

    final now = _clock.now();
    final pending = _pendingValue;
    if (pending != null) {
      if (now.difference(_pendingSince!) >= settleWindow) {
        await _land(pending);
        return;
      }
      // 值一直在变、始终稳定不下来（定稿期间自动放弃会被忽略）：不能让
      // 一轮卡死，也不能落一枚还在变的值——按超时收口。
      if (now.difference(_firstSeenAt!) >= settleWindow + completionDeadline) {
        _complete(
          CfRoundFailed(round: id, reason: CfRoundFailure.timeout),
          detail: 'cf_clearance kept changing for '
              '${now.difference(_firstSeenAt!).inMilliseconds}ms',
        );
        return;
      }
      _ensureTicking();
      return;
    }

    final conclusiveAt = _conclusiveAt;
    if (conclusiveAt != null &&
        !_triedCurrentValue &&
        now.difference(conclusiveAt) >= conclusiveGrace) {
      _triedCurrentValue = true;
      final current = await _readCurrent();
      if (isDone || _landingInProgress) return;
      if (current != null && _pendingValue == null) {
        CfChallengeLogger.log(
          '[ROUND $id] conclusive pass without a fresh cf_clearance after '
          '${conclusiveGrace.inSeconds}s; no challenge was issued, landing the '
          'current WebView value (${current.length} chars)',
          level: 'warning',
        );
        await _land(current);
        return;
      }
    }
    if (conclusiveAt != null &&
        now.difference(conclusiveAt) >= completionDeadline) {
      // 网络层已确认通过，却始终读不到新值：值没法交给请求用
      _complete(
        CfRoundFailed(round: id, reason: CfRoundFailure.notLanded),
        detail: 'no fresh cf_clearance within '
            '${completionDeadline.inSeconds}s after conclusive pass',
      );
      return;
    }
    final hintAt = _hintAt;
    if (conclusiveAt != null ||
        (hintAt != null && now.difference(hintAt) < completionDeadline)) {
      _ensureTicking();
    }
  }

  Future<void> _land(String settled) async {
    _landingInProgress = true;
    _cancelTicker();
    var value = settled;
    var switched = false;
    for (var attempt = 1; attempt <= landingAttempts; attempt++) {
      String? inJar;
      try {
        inJar = await _landing(value);
      } catch (e) {
        debugPrint('[CfRound] 落值异常: $e');
      }
      if (isDone) return;
      if (CfClearanceAuthority.isSameValue(inJar, value)) {
        _complete(
          CfRoundPassed(round: id, clearance: value),
          detail: 'settled and landed (attempt $attempt)',
        );
        return;
      }
      CfChallengeLogger.log(
        '[ROUND $id] landing attempt $attempt/$landingAttempts not confirmed '
        '(jar=${inJar?.length ?? 0} chars)',
        level: 'warning',
      );
      // 定稿后站点又签了一枚（CF 常在挑战提交和随后的 /challenge 跳转各签一次，
      // 第二枚晚到时定稿窗口已过）：落值只收 WebView 现有的那枚，死等旧值必败。
      // 改落最新值、重新计次，只换一次，免得来回换卡住
      if (!switched) {
        final latest = await _readLatest();
        if (isDone) return;
        if (latest != null && !CfClearanceAuthority.isSameValue(latest, value)) {
          switched = true;
          CfChallengeLogger.log(
            '[ROUND $id] cf_clearance changed during landing '
            '(${latest.length} chars), landing the newer value',
          );
          value = latest;
          _pendingValue = latest;
          attempt = 0;
          continue;
        }
      }
      if (attempt < landingAttempts) await _delay(landingRetryDelay);
      if (isDone) return;
    }
    _complete(
      CfRoundFailed(round: id, reason: CfRoundFailure.notLanded),
      detail: 'settled value not confirmed in jar',
    );
  }

  /// 读 WebView 当前值，不论新旧（读不到 / 出错返回 null）
  Future<String?> _readCurrent() async {
    final reader = _currentReader;
    if (reader == null) return null;
    try {
      final value = (await reader())?.trim();
      return value == null || value.isEmpty ? null : value;
    } catch (e) {
      debugPrint('[CfRound] 读取 WebView 当前 cf_clearance 失败: $e');
      return null;
    }
  }

  /// 落值期间读一次 WebView 当前的新值（读不到 / 出错返回 null）
  Future<String?> _readLatest() async {
    final reader = _reader;
    if (reader == null) return null;
    try {
      final value = (await reader())?.trim();
      return value == null || value.isEmpty ? null : value;
    } catch (e) {
      debugPrint('[CfRound] 落值期间读取 WebView cf_clearance 失败: $e');
      return null;
    }
  }

  Future<void> _delay(Duration duration) {
    final completer = Completer<void>();
    _clock.schedule(duration, completer.complete);
    return completer.future;
  }

  void _complete(CfRoundOutcome outcome, {required String detail}) {
    if (isDone) return;
    _cancelTicker();
    _landingInProgress = false;
    _result = outcome;
    CfChallengeLogger.log(
      '[ROUND $id] outcome: $outcome ($detail)',
      level: outcome.passed ? 'info' : 'warning',
    );
    _completer.complete(outcome);
  }
}

// ---------------------------------------------------------------------------
// 起轮 / 合流 / 收尾
// ---------------------------------------------------------------------------

/// 一轮验证依赖的外部能力。生产实现在 CfChallengeService（验证页、
/// overlay、续期服务、jar），测试用替身。
abstract interface class CfRoundEnvironment {
  /// 等待前台 UI（navigator context + overlay）就绪，返回 UI 句柄；
  /// 没有前台 UI（后台 isolate、等不到 context、没有 overlay）返回 null。
  Future<Object?> ensureUi(BuildContext? context);

  /// 停掉续期服务并等它的 WebView 真正销毁——必须先于验证 WebView 创建
  /// （两个 WebView 短暂共存会撞上 Windows 插件的原生崩溃）。
  Future<void> stopRefresh();

  /// 验证通过后错峰重启续期服务（等验证 WebView 析构完）。
  void restartRefreshLater();

  /// 备份并清空 jar 与 WebView 里的 cf_clearance（不清 WebView 的话 CF
  /// 直接放行、不展示挑战）。
  Future<Object?> backupAndClear();

  /// 失败时恢复备份（不丢掉可能仍有效的旧值）。
  Future<void> restore(Object? backup);

  /// 过盾前对账 `_t`（验证 WebView 与 App 共用 CookieManager）。不阻塞。
  Future<void> primeSession();

  /// 在 [ui] 上展示验证页并接到 [round]；overlay 已不可用时返回 false。
  /// [backup] 是 [backupAndClear] 的返回值（验证页据此过滤残留旧值）。
  Future<bool> present(
    CfVerificationRound round,
    CfVerifyMode mode,
    Object ui,
    Object? backup,
  );

  /// 有调用方合流进进行中的一轮（可能需要转前台）。
  void onJoin(CfVerificationRound round, CfVerifyMode mode);

  /// 一轮出了结果：撤下验证页。宿主在验证 WebView 析构完后调用
  /// [CfVerificationRounds.release] 结束这一轮。
  void dismiss(CfVerificationRound round);

  /// 把定稿值经 BoundarySync（权威闸门）写进 jar，返回写后 jar 里的值。
  Future<String?> land(CfVerificationRound round, String value);

  /// 通过：广播「CF 已解决」、过盾后 `_t` 对账等。
  void onPassed(CfVerificationRound round, String value);

  /// 冷却与失败计数（同一轮只记一次）。
  bool isCoolingDown();
  void recordFailure(int round);
  void resetFailures();
}

/// 验证轮次的生命周期：冷却判定、合流、起轮、收尾。
///
/// 此前这些散在 `_showVerify`、`_verifyCompleter` 列表、`_roundOutcome`、
/// `_completedVerificationResult` 与拦截器的失败计数里；冷却 / 无 context /
/// 无 overlay 都是 `null`，调用方得再读服务状态去猜。现在每个入口
/// （拦截器、登录页、登录对话框、BrowserTrust、手动验证按钮）拿到的都是
/// 同一个 [CfRoundOutcome]。
class CfVerificationRounds {
  CfVerificationRounds({
    required this.environment,
    this.clock = const SystemCfRoundClock(),
    this.onVerifyingChanged,
  });

  final CfRoundEnvironment environment;
  final CfRoundClock clock;

  /// 进入/离开「验证进行中」（含析构冷却期）。
  final void Function(bool verifying)? onVerifyingChanged;

  CfVerificationRound? _active;
  int _counter = 0;

  /// 进行中（或已出结果、验证页还在析构）的一轮。
  CfVerificationRound? get active => _active;

  /// 最近一轮的轮次号。
  int get roundCounter => _counter;

  /// 发起或加入一轮验证。
  Future<CfRoundOutcome> verify({
    required CfVerifyMode mode,
    BuildContext? context,
  }) async {
    if (environment.isCoolingDown()) {
      debugPrint('[CfChallenge] In cooldown, skipping manual verify');
      CfChallengeLogger.log('[VERIFY] Skipped: in cooldown');
      return const CfRoundFailed(round: 0, reason: CfRoundFailure.cooldown);
    }
    final ui = await environment.ensureUi(context);
    if (ui == null) {
      return const CfRoundFailed(round: 0, reason: CfRoundFailure.noUi);
    }

    final active = _active;
    if (active != null) {
      // 结果已出但验证页仍在析构：直接复用刚出的结果
      if (!active.isDone) {
        if (mode != CfVerifyMode.background) active.hasForegroundWaiter = true;
        environment.onJoin(active, mode);
      }
      return active.outcome;
    }
    return _start(mode, ui);
  }

  Future<CfRoundOutcome> _start(CfVerifyMode mode, Object ui) async {
    late final CfVerificationRound round;
    round = CfVerificationRound(
      id: ++_counter,
      clock: clock,
      landing: (value) => environment.land(round, value),
    );
    round.hasForegroundWaiter = mode != CfVerifyMode.background;
    _active = round;
    onVerifyingChanged?.call(true);

    Object? backup;
    var cleared = false;
    try {
      await environment.stopRefresh();
      backup = await environment.backupAndClear();
      cleared = true;
      await environment.primeSession();
      if (!await environment.present(round, mode, ui, backup)) {
        round.abort(CfRoundFailure.noUi, detail: 'overlay not mounted');
      }
    } catch (e) {
      debugPrint('[CfChallenge] 起轮失败: $e');
      round.abort(CfRoundFailure.noUi, detail: 'start failed: $e');
    }

    final outcome = await round.outcome;
    switch (outcome) {
      case CfRoundPassed(:final clearance):
        CfChallengeLogger.logVerifyResult(
          success: true,
          reason: 'round ${round.id} settled and landed',
        );
        environment.resetFailures();
        environment.onPassed(round, clearance);
        environment.dismiss(round);
        environment.restartRefreshLater();
      case CfRoundFailed(:final reason):
        CfChallengeLogger.logVerifyResult(
          success: false,
          reason: 'round ${round.id} ${reason.name}',
        );
        environment.dismiss(round);
        // 失败：恢复备份的旧值（可能仍有效，别让 jar 空着）
        if (cleared) await environment.restore(backup);
        // 同一轮只记一次失败（合流者共享结果，不各自记账）
        if (reason.countsAsFailure) environment.recordFailure(round.id);
    }
    return outcome;
  }

  /// 宿主在验证页析构冷却结束后调用，结束 [round]。
  void release(CfVerificationRound round) {
    if (!identical(_active, round)) return;
    // 没出结果就被撤下（宿主异常收口）：按无 UI 收口，不让等待者挂起
    round.abort(CfRoundFailure.noUi, detail: 'released before outcome');
    _active = null;
    onVerifyingChanged?.call(false);
  }

  /// 测试钩子用：起一轮不带 UI 的验证（只进入「验证进行中」）。
  /// 只供 CfChallengeService.debugBeginVerification 与测试调用。
  CfVerificationRound debugBegin() {
    final active = _active;
    if (active != null) return active;
    final round = CfVerificationRound(
      id: ++_counter,
      clock: clock,
      landing: (value) async => value,
    );
    _active = round;
    onVerifyingChanged?.call(true);
    return round;
  }
}
