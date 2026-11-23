import 'dart:async';

import 'cf_tap_policy.dart';

/// 定位脚本的结果：要么是能点的点（视口归一化坐标），要么是点不了的原因。
class CfTapLocation {
  const CfTapLocation.point({
    required double this.nx,
    required double this.ny,
    required this.source,
  }) : reason = null;

  const CfTapLocation.unavailable(String this.reason)
    : nx = null,
      ny = null,
      source = null;

  final double? nx;
  final double? ny;
  final String? source;

  /// `masked`（被我们自己的遮罩盖着）/ `occluded`（被别的元素挡着）/
  /// `not_found` / `not_challenge` / `odd_size` 等
  final String? reason;

  bool get found => reason == null;
}

/// 原生端注入触摸的结果。`ok` 只代表整套 down/move/up 送进了目标 WebView，
/// 点没点中要看 Turnstile 的反馈。
class CfTapDispatch {
  const CfTapDispatch.ok() : ok = true, reason = null;
  const CfTapDispatch.failed(String this.reason) : ok = false;

  final bool ok;
  final String? reason;
}

enum CfTapOutcome {
  /// 点下去后 Turnstile 上报了 `interactiveEnd`
  effective,

  /// 点了，额度内一直没反馈
  noEffect,

  /// 定位不到能点的勾选框（没消耗额度）
  notLocated,

  /// 原生端没能把触摸送进目标 WebView（不重试）
  dispatchFailed,

  /// 条件不满足 / 额度用完 / 文档已换 / 本回合已结束
  skipped,
}

/// 验证页替用户点 Turnstile 勾选框的流程：定位 → 注入触摸 → 等反馈 → 有限重试。
///
/// 页面只负责把事件转进来（[newDocument] / [newRound] / [interactionEnded]）
/// 并在合适的时机调 [run]；何时能点由 [canTap] 决定（见 [CfTapPolicy.shouldAttempt]）。
/// 定位与注入由调用方注入，便于单测。
class CfAutoTapper {
  CfAutoTapper({
    required Future<CfTapLocation> Function() locate,
    required Future<CfTapDispatch> Function(double nx, double ny) dispatch,
    required bool Function() canTap,
    void Function(String message)? log,
    Future<void> Function(Duration duration)? delay,
  }) : _locate = locate,
       _dispatch = dispatch,
       _canTap = canTap,
       _log = log ?? _noLog,
       _delay = delay ?? Future<void>.delayed;

  final Future<CfTapLocation> Function() _locate;
  final Future<CfTapDispatch> Function(double nx, double ny) _dispatch;
  final bool Function() _canTap;
  final void Function(String message) _log;
  final Future<void> Function(Duration duration) _delay;

  static void _noLog(String _) {}

  int _epoch = 0;
  int _roundAttempts = 0;
  int _documentAttempts = 0;
  bool _roundEnded = false;
  Completer<void>? _effect;
  Future<CfTapOutcome>? _inFlight;

  int get documentAttempts => _documentAttempts;

  /// 新文档（导航 / 重载）：额度清零，进行中的流程在下一个检查点作废
  void newDocument() {
    _epoch++;
    _roundAttempts = 0;
    _documentAttempts = 0;
    _roundEnded = false;
    _completeEffect();
  }

  /// Turnstile 又要人工操作（`interactiveBegin` / `interactiveTimeout`）：开新回合
  void newRound() {
    _roundAttempts = 0;
    _roundEnded = false;
  }

  /// Turnstile 上报 `interactiveEnd`：勾选框被点了（我们或用户），本回合不再点
  void interactionEnded() {
    _roundEnded = true;
    _completeEffect();
  }

  void _completeEffect() {
    final effect = _effect;
    if (effect != null && !effect.isCompleted) effect.complete();
  }

  /// 同一时间只跑一个流程，重复调用拿到同一个结果
  Future<CfTapOutcome> run() =>
      _inFlight ??= _run().whenComplete(() => _inFlight = null);

  Future<CfTapOutcome> _run() async {
    final epoch = _epoch;
    bool alive() => epoch == _epoch && !_roundEnded && _canTap();

    while (true) {
      if (!alive()) return CfTapOutcome.skipped;
      if (!CfTapPolicy.hasBudget(
        roundAttempts: _roundAttempts,
        documentAttempts: _documentAttempts,
      )) {
        return CfTapOutcome.skipped;
      }

      final location = await _locateWithRetry(alive);
      if (location == null) return CfTapOutcome.skipped;
      if (!location.found) {
        _log('[VERIFY][TAP] 没有可点的勾选框: ${location.reason}');
        return CfTapOutcome.notLocated;
      }

      final effect = _effect = Completer<void>();
      _roundAttempts++;
      _documentAttempts++;
      final attempt = _documentAttempts;
      final result = await _dispatch(location.nx!, location.ny!);
      if (!result.ok) {
        _log('[VERIFY][TAP] #$attempt 注入触摸失败: ${result.reason}');
        return CfTapOutcome.dispatchFailed;
      }
      _log(
        '[VERIFY][TAP] #$attempt 已注入触摸 (${location.source}, '
        '${location.nx!.toStringAsFixed(3)}, ${location.ny!.toStringAsFixed(3)})',
      );

      final ended = await Future.any<bool>([
        effect.future.then((_) => true),
        _delay(CfTapPolicy.effectWindow).then((_) => false),
      ]);
      if (epoch != _epoch) return CfTapOutcome.skipped;
      if (ended || _roundEnded) {
        _log('[VERIFY][TAP] #$attempt Turnstile 已响应');
        return CfTapOutcome.effective;
      }
      _log('[VERIFY][TAP] #$attempt 没等到 Turnstile 响应');
      if (!CfTapPolicy.hasBudget(
        roundAttempts: _roundAttempts,
        documentAttempts: _documentAttempts,
      )) {
        return CfTapOutcome.noEffect;
      }
      await _delay(CfTapPolicy.retryDelay);
    }
  }

  /// 定位不到时隔一会儿再试（遮罩刚揭开 / widget 刚渲染）；条件失效返回 null
  Future<CfTapLocation?> _locateWithRetry(bool Function() alive) async {
    CfTapLocation? last;
    for (var i = 0; i < CfTapPolicy.locateAttempts; i++) {
      if (i > 0) await _delay(CfTapPolicy.locateRetryDelay);
      if (!alive()) return null;
      last = await _locate();
      if (!alive()) return null;
      if (last.found) return last;
    }
    return last;
  }
}
