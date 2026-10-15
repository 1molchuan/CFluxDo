import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../cf_challenge_service.dart';
import '../../cf_challenge_logger.dart';
import '../../cf_clearance_refresh_service.dart';
import '../../cf_clearance_authority.dart';
import '../../app_logger.dart';
import '../../startup_progress.dart';
import '../adapters/platform_adapter.dart';
import '../cf/cf_challenge_classifier.dart';
import '../cf/cf_challenge_recovery.dart';
import '../cf/cf_round_outcome.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../../l10n/s.dart';
import '../flux_request_spec.dart';
import '../health/network_health_controller.dart';

/// Cloudflare 验证拦截器：撞盾请求的 Dio 适配层。
///
/// 只做三件事：识别挑战（统一分类器）、记录撞盾现场、把恢复结果交回 Dio。
/// 恢复的顺序与副作用（过期重放 → 登记被撞 → 换值重放 → 验证轮次 →
/// 兼容模式与回滚）在 [CfChallengeRecovery]，这里只提供它的端口实现。
///
/// 挑战页无论被请求的 validateStatus 判成失败（onError）还是放行
/// （onResponse，如 OAuth 授权页的 `status < 500`）都进同一条恢复；
/// 确实要检视挑战页的请求须显式声明
/// [FluxRequestKeys.allowCfChallengeResponse]。
///
/// **为什么它不在恢复层里**(2026-08 评估结论,别再迁):
///
/// 恢复层的契约是"策略只产决策、Coordinator 统一执行重放",这对无状态恢复
/// (限流等待、瞬态重放、会话自愈、引擎降级)成立,但 CF 的重试**之后**还有
/// 三段有状态处置:
/// 1. 重试成功 → 广播 [CfChallengeService.clearanceResolvedAt],
///    BrowserTrustCoordinator 靠它 force 重跑被同一次 CF 挡下的 bootstrap;
/// 2. 重试仍被拦 → 在同一上下文里判断能否切兼容、弹询问、撤 skipWebViewAdapter,
///    **换传输方式再重放一次**;
/// 3. 兼容重放失败 → 回滚 sessionFallback,否则后续请求全锁死在坏通道上。
///
/// 第 2、3 步要求"拿到重试结果后决定下一次用什么传输方式,并在失败时回滚
/// 副作用",而策略拿不到重试结果——重放执行权在 Coordinator 手里。硬迁的
/// 三条路都有害:为单个策略给 RecoveryDecision 加变体会污染通用抽象;策略
/// 自己调 dio.fetch 违反"重放只有一处"这条铁律(等于把六个重放入口的病灶
/// 重新引入);拆成多策略靠预算串联会丢掉回滚的时序保证。
///
/// 所以现状是**终态**:恢复层管无状态重放,本拦截器(经 [CfChallengeRecovery])
/// 管需要 UI 交互与传输切换的有状态恢复。分界由 RateLimitPolicy 的
/// isChallengeResponse 钩子划定——挑战型 429 放行给这里,真限流归恢复层。
class CfChallengeInterceptor extends Interceptor {
  CfChallengeInterceptor({
    required this.dio,
    required this.cookieJarService,
    CfChallengeRecovery? recovery,
    void Function(DioException err)? onChallengeDetected,
  }) : _onChallengeDetected = onChallengeDetected ?? _reportChallengeDetected {
    _recovery =
        recovery ??
        CfChallengeRecovery(
          replay: _DioReplayPort(dio, cookieJarService),
          clearance: _JarClearancePort(cookieJarService),
          round: _ServiceRoundPort(cookieJarService),
          compat: _SessionCompatPort(),
          notify: _showNotice,
        );
  }

  final Dio dio;
  final CookieJarService cookieJarService;
  late final CfChallengeRecovery _recovery;
  final void Function(DioException err) _onChallengeDetected;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 重放请求带 skipCfChallenge（防验证死循环）
    if (err.requestOptions.spec.skipCfChallenge ||
        !CfChallengeClassifier.isChallengeResponse(err.response)) {
      handler.next(err);
      return;
    }
    _onChallengeDetected(err);
    switch (await _recovery.recover(err)) {
      case CfRecovered(:final response):
        handler.resolve(response);
      case CfRecoveryFailed(:final error):
        handler.reject(error);
    }
  }

  /// 被 validateStatus 放行的挑战页：不能当正常响应交给调用方（它会把
  /// 挑战页当业务数据解析，表现成莫名其妙的「解析失败」），转成同一条恢复。
  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final spec = response.requestOptions.spec;
    if (spec.skipCfChallenge ||
        spec.allowCfChallengeResponse ||
        !CfChallengeClassifier.isChallengeResponse(response)) {
      handler.next(response);
      return;
    }
    final err = DioException.badResponse(
      statusCode: response.statusCode ?? 0,
      requestOptions: response.requestOptions,
      response: response,
    );
    CfChallengeLogger.log(
      '[INTERCEPTOR] Challenge accepted by validateStatus, routing to '
      'recovery: ${response.requestOptions.method.toUpperCase()} '
      '${response.requestOptions.uri}',
    );
    _onChallengeDetected(err);
    switch (await _recovery.recover(err)) {
      case CfRecovered(:final response):
        handler.resolve(response);
      case CfRecoveryFailed(:final error):
        handler.reject(error);
    }
  }

  /// 撞盾现场：日志、诊断快照、启动页提示等与恢复结果无关的副作用。
  static void _reportChallengeDetected(DioException err) {
    final statusCode = err.response?.statusCode;
    // 备选提取 sitekey（从挑战响应体中）
    CfClearanceRefreshService().extractAndUpdateSitekey(
      err.response?.data?.toString() ?? '',
    );
    // 撞盾说明 cf_clearance 已失效，停止自动续期（避免与手动验证冲突）。
    // 这里不需要 await——真正要建验证 WebView 前，验证入口内部会自己再
    // await 一次 stop()，确保销毁完成。
    unawaited(CfClearanceRefreshService().stop());

    final options = err.requestOptions;
    final requestTag = options.spec.requestTag;
    final logMessage =
        'CF Challenge detected: ${options.method.toUpperCase()} ${options.uri} '
        '(status=$statusCode, silent=${options.spec.isSilent}, '
        'tag=${requestTag ?? '-'}, skipCsrf=${options.spec.skipCsrf})';
    debugPrint('[Dio] $logMessage');
    AppLogger.warning(logMessage, tag: 'CfChallengeInterceptor');
    // 启动预加载撞盾是启动变慢最常见的原因之一,让启动页把它显示出来
    if (requestTag == 'preload-home') {
      StartupProgressReporter.instance.set(
        StartupStage.cfChallenge,
        detail: statusCode != null
            ? S.current.preheat_detailHttp(statusCode)
            : null,
      );
    }
    // 撞盾是排查网络问题的关键时刻:把此刻的通道健康全貌拍进日志,
    // 免得事后只有"某请求 403"这一条结果、没有引擎/降级/凭证状态。
    NetworkHealthController.instance.dumpToLog('cf_challenge_detected');
    // 命中 CF 盾时立即重读系统代理状态:若用户刚开/关了系统代理,
    // 下一个请求就能用一致的出口重试,而不是等 10s 周期刷新。
    SystemProxyService.instance.refresh();
    CfChallengeLogger.logInterceptorDetected(
      url: options.uri.toString(),
      statusCode: statusCode ?? 0,
    );
  }

  static void _showNotice(CfRecoveryNotice notice) {
    switch (notice) {
      case CfRecoveryNotice.blockedByChallenge:
        CfChallengeService.showGlobalMessage(
          S.current.cf_operationBlockedByChallenge,
        );
      case CfRecoveryNotice.cannotOpenVerifyPage:
        CfChallengeService.showGlobalMessage(S.current.cf_cannotOpenVerifyPage);
      case CfRecoveryNotice.notEffective:
        CfChallengeService.showGlobalMessage(S.current.cf_challengeNotEffective);
      case CfRecoveryNotice.verifyIncomplete:
        CfChallengeService.showGlobalMessage(S.current.cf_verifyIncomplete);
      case CfRecoveryNotice.compatEnabled:
        CfChallengeService.showGlobalMessage(
          S.current.cf_sessionCompatEnabled,
          isError: false,
        );
    }
  }
}

/// 重放：清掉原请求残留的 Cookie 头、补上 jar 当前值再整链重发。
/// 即使 dio.fetch 不重新经过 CookieManager，也不会继续发送旧值。
class _DioReplayPort implements CfReplayPort {
  _DioReplayPort(this._dio, this._jar);

  final Dio _dio;
  final CookieJarService _jar;

  @override
  Future<Response<dynamic>> replay(RequestOptions options) async {
    options.headers.remove('cookie');
    options.headers.remove('Cookie');
    final cookieHeader = await _jar.getCookieHeaderForRequest(options.uri);
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      options.headers['Cookie'] = cookieHeader;
    }
    // 诊断：重放是否带上了 cf_clearance
    final hasCfClearance = cookieHeader?.contains('cf_clearance=') ?? false;
    debugPrint(
      '[Dio] Retry cookies: '
      '${hasCfClearance ? "✓ 包含 cf_clearance" : "⚠️ 缺少 cf_clearance"}, '
      'total=${cookieHeader?.length ?? 0} chars',
    );
    return _dio.fetch<dynamic>(options);
  }
}

class _JarClearancePort implements CfClearancePort {
  _JarClearancePort(this._jar);

  final CookieJarService _jar;

  @override
  Future<String?> currentInJar() => _jar.getCfClearance();

  @override
  Future<String?> swapInWebViewCandidate({required String? challenged}) async {
    final authority = CfClearanceAuthority.instance;
    List<String> candidates;
    try {
      candidates = await BoundarySyncService.instance
          .readCfClearanceCandidatesFromWebView();
    } catch (e) {
      // WebView cookie 管理器未就绪等情况：不是本路径该处理的问题，跳过。
      debugPrint('[Dio] 读取 WebView cf_clearance 失败，跳过换值重放: $e');
      return null;
    }
    String? candidate;
    for (final value in candidates) {
      if (CfClearanceAuthority.isSameValue(value, challenged)) continue;
      if (authority.isKnownChallenged(value)) continue;
      candidate = value;
      break;
    }
    if (candidate == null) return null;

    // 经 BoundarySync 正常写入（domain/path 处理、日志口径都复用），
    // acceptValues 锁定只写这一枚，避免把 WebView 里的其他变体一并带进来。
    await BoundarySyncService.instance.syncFromWebView(
      cookieNames: const {CfClearanceAuthority.cookieName},
      acceptValues: {CfClearanceAuthority.cookieName: candidate},
      trusted: true,
    );
    final swappedIn = await _jar.getCfClearance();
    if (!CfClearanceAuthority.isSameValue(swappedIn, candidate)) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] WebView cf_clearance (${candidate.length} chars) '
        'not adopted by sync gate, falling back to verify',
      );
      return null;
    }
    return candidate;
  }
}

class _ServiceRoundPort implements CfRoundPort {
  _ServiceRoundPort(this._jar);

  final CookieJarService _jar;

  CfChallengeService get _cf => CfChallengeService();

  /// 共享的 cookie 同步 Future：验证成功后只执行一次 sync
  static Future<bool>? _activeSyncFuture;

  @override
  bool get isVerifying => _cf.isVerifying;

  @override
  bool get autoVerifyEnabled => _cf.autoVerifyEnabled;

  @override
  bool isCoolingDown(String host) => _cf.isInCooldown;

  @override
  Future<CfRoundOutcome> acquire(CfVerifyMode mode) async {
    final result = switch (mode) {
      CfVerifyMode.background => await _cf.showManualVerify(null, false),
      CfVerifyMode.silentFirst => await _cf.showVerifySilentFirst(),
      CfVerifyMode.foreground => await _cf.showManualVerify(null, true),
    };
    // 多个并发请求撞盾会合流到同一轮验证,却各自走后续处置 —— 失败计数
    // 必须带上轮次去重,否则一次时序抖动会被记成 N 次失败。
    final round = _cf.verifyRound;
    if (result == null) {
      return CfRoundFailed(
        round: 0,
        reason: _cf.isInCooldown ? CfRoundFailure.cooldown : CfRoundFailure.noUi,
      );
    }
    if (!result) {
      return CfRoundFailed(round: round, reason: CfRoundFailure.cancelled);
    }
    if (!await _syncCookiesOnce()) {
      _cf.startCooldown(round: round);
      debugPrint('[Dio] cf_clearance not found after sync, entering cooldown');
      return CfRoundFailed(round: round, reason: CfRoundFailure.notLanded);
    }
    final clearance = await _jar.getCfClearance();
    return CfRoundPassed(round: round, clearance: clearance ?? '');
  }

  @override
  void noteIneffective(String host) =>
      _cf.startIneffectiveClearanceCooldown();

  @override
  void noteResolved() {
    // 广播:Dio 侧重试成功 = 新 cf_clearance 已生效。供 BrowserTrustCoordinator
    // 感知"CF 已解决",从而 force 重跑因同一 CF 失败的 WebView session bootstrap。
    _cf.clearanceResolvedAt.value = DateTime.now();
  }

  /// 验证成功后的共享 Cookie 同步（只执行一次）
  Future<bool> _syncCookiesOnce() async {
    // 如果已有同步任务在进行，复用结果
    if (_activeSyncFuture != null) return _activeSyncFuture!;

    _activeSyncFuture = _doSync();
    try {
      return await _activeSyncFuture!;
    } finally {
      _activeSyncFuture = null;
    }
  }

  Future<bool> _doSync() async {
    // showManualVerify 内部已通过 CDP 将新 cf_clearance 同步到 CookieJar，
    // 先检查是否已存在，避免后续 syncFromWebView 在 Windows 上通过
    // CookieManager.getCookies() 读取到旧值并覆盖（Bug #5 fix 会先删后写）。
    String? cfClearance = await _jar.getCfClearance();
    if (cfClearance != null && cfClearance.isNotEmpty) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] cf_clearance already in CookieJar: ${cfClearance.length} chars',
      );
      return true;
    }

    // CookieJar 中未找到 cf_clearance，走 WebView 同步兜底
    await Future.delayed(const Duration(milliseconds: 1500));
    await BoundarySyncService.instance.syncFromWebView(
      cookieNames: {'cf_clearance'},
    );

    for (var i = 0; i < 3; i++) {
      cfClearance = await _jar.getCfClearance();
      if (cfClearance != null && cfClearance.isNotEmpty) break;
      debugPrint('[Dio] cf_clearance not found, retry ${i + 1}/3...');
      await Future.delayed(const Duration(milliseconds: 500));
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: {'cf_clearance'},
      );
    }

    if (cfClearance == null || cfClearance.isEmpty) {
      CfChallengeLogger.log('[INTERCEPTOR] cf_clearance not found after sync');
      return false;
    }
    CfChallengeLogger.log(
      '[INTERCEPTOR] cf_clearance verified: ${cfClearance.length} chars',
    );
    return true;
  }
}

class _SessionCompatPort implements CfCompatPort {
  WebViewAdapterSettingsService get _settings =>
      WebViewAdapterSettingsService.instance;

  @override
  bool canUse(RequestOptions options) => requestCanUseWebViewAdapter(options);

  @override
  Future<bool> enable() async {
    final ok =
        _settings.effectiveEnabled ||
        await CfChallengeService().confirmSessionCompatibilityMode();
    if (ok) _settings.enableSessionFallback();
    return ok;
  }

  @override
  void rollback() {
    // 会话级兼容必须以首次真实请求成功为准；失败时立即回滚
    if (!_settings.persistentEnabled) _settings.disableSessionFallback();
  }
}
