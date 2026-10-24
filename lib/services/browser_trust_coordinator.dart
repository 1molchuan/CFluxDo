import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../constants.dart';
import '../utils/frame_jank_monitor.dart';
import 'app_logger.dart';
import 'cf_challenge_logger.dart';
import 'cf_challenge_service.dart';
import 'cf_clearance_authority.dart';
import 'cf_clearance_refresh_service.dart';
import 'network/cf/cf_round_outcome.dart';
import 'discourse/discourse_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'preloaded_data_service.dart';
import 'session/webview_use.dart';
import 'startup/app_startup.dart';
import 'startup_progress.dart';
import 'webview_session_cookie_refresh_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';

enum BrowserTrustPreloadPath { native, webView }

/// 启动期临时 WebView 的协作式取消令牌。
@visibleForTesting
class BrowserTrustRunCancellation {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
  }
}

/// 超时后取消后续工作，但仍等待原任务完成 finally 清理，避免留下孤儿 WebView。
@visibleForTesting
Future<T?> runBrowserTrustTaskWithSafeTimeout<T>({
  required Future<T> task,
  required Duration timeout,
  required BrowserTrustRunCancellation cancellation,
  Duration cleanupTimeout = const Duration(seconds: 30),
}) async {
  try {
    return await task.timeout(timeout);
  } on TimeoutException {
    cancellation.cancel();
    try {
      await task.timeout(cleanupTimeout);
    } on TimeoutException {
      // 协作式取消无法中断已经卡在原生 WebView2 调用里的 Future。排水也必须
      // 有上限，否则为了避免孤儿 WebView 反而会让整个启动链永久挂死。
      debugPrint(
        '[BrowserTrust] cancelled WebView task did not finish cleanup within '
        '${cleanupTimeout.inSeconds}s; continuing startup',
      );
    } catch (_) {
      // 原任务错误不覆盖“已超时”结果；正常情况下 finally 已完成清理。
    }
    return null;
  }
}

/// 浏览器信任编排器。
///
/// 负责启动/恢复阶段的浏览器态准备，避免 WebView priming、session bootstrap、
/// cf_clearance 维护、预加载请求在 main / widget 中散落。
class BrowserTrustCoordinator {
  BrowserTrustCoordinator._();
  static final BrowserTrustCoordinator instance = BrowserTrustCoordinator._();

  static const Duration _webViewPreloadTimeout = Duration(seconds: 25);
  static const Duration _domSnapshotTimeout = Duration(seconds: 12);
  static const Duration _originLoadTimeout = Duration(seconds: 8);
  static const Duration _backgroundPauseDelay = Duration(seconds: 8);
  static const Duration _requestGateTimeout = Duration(seconds: 6);
  static const Duration _diagnosticBackgroundPauseDelay = Duration(seconds: 60);

  /// bootstrap 被挡时只等进行中那一轮验证的上限（不发起、不转前台）。
  static const Duration _activeRoundWaitTimeout = Duration(seconds: 12);
  static const Duration _webViewTeardownCooldown = Duration(milliseconds: 1200);

  final CookieJarService _jar = CookieJarService();
  final PreloadedDataService _preload = PreloadedDataService();

  Future<void>? _activePreload;
  Future<bool>? _activeBrowserTrust;
  Future<bool>? _activeBrowserTrustGate;
  Timer? _backgroundPauseTimer;
  String? _pendingClearanceRefreshReason;

  /// 导航 context,供 bootstrap 被 CF 挡下时主动发起 CF 验证(showManualVerify)。
  BuildContext? _navigatorContext;

  /// cf_clearance 能不能用（被拒窗口、有效期门槛、被撞标记）统一由账本
  /// 判定，这里只读。
  CfClearanceAuthority get _ledger => CfClearanceAuthority.instance;

  BrowserTrustPreloadPath? _lastPreloadPath;

  BrowserTrustPreloadPath? get lastPreloadPath => _lastPreloadPath;

  /// 最近一次 [_isNativePreloadTrusted] 判定为不可信的原因;可信时为 null。
  /// 只用于启动页向用户解释为什么没走直连。
  StartupDetourReason? _nativeUntrustedReason;

  /// 本轮预加载的进度出口(启动序列传入):阶段推进写这里,首页请求也挂上
  /// 它旁观重试与撞盾。启动页的开始 / 结束由启动序列负责。
  StartupPreloadProgress? _preloadProgress;

  void setNavigatorContext(BuildContext context) {
    _navigatorContext = context;
    DiscourseService().setNavigatorContext(context);
    _preload.setNavigatorContext(context);
  }

  /// 启动期轻量准备：只做 cookie priming，不加载首页，不阻塞 runApp。
  void prepareStartup({String reason = 'startup'}) {
    unawaited(
      _primeWebViewCookies(reason: reason).catchError((Object e) {
        _log('startup priming failed: $e', level: 'warning');
      }),
    );
  }

  void pauseForBackground() {
    _backgroundPauseTimer?.cancel();
    final delay = CfChallengeLogger.isEnabled
        ? _diagnosticBackgroundPauseDelay
        : _backgroundPauseDelay;
    _log('schedule cf_clearance refresh pause: delay=${delay.inSeconds}s');
    _backgroundPauseTimer = Timer(delay, () {
      _backgroundPauseTimer = null;
      _log('execute delayed cf_clearance refresh pause');
      CfClearanceRefreshService().pause();
    });
  }

  /// 前台恢复：恢复 cf_clearance 维护，并在后台补一次浏览器 session bootstrap。
  void resumeFromBackground({String reason = 'resume', bool force = false}) {
    final hadPendingPause = _backgroundPauseTimer != null;
    _backgroundPauseTimer?.cancel();
    _backgroundPauseTimer = null;
    if (hadPendingPause) {
      _log('cancel scheduled cf_clearance refresh pause: reason=$reason');
    }
    CfClearanceRefreshService().resume();
    unawaited(
      ensureBrowserTrust(reason: reason, force: force).catchError((Object e) {
        _log('resume browser trust failed: $e', level: 'warning');
        return false;
      }),
    );
  }

  /// 确保预加载完成。可信时走 native Dio；不可信时只在启动期临时 WebView 中
  /// 加载一次首页并复用 HTML hydrate。
  ///
  /// 只由启动序列（AppStartup）调用：它负责启动页的开始 / 结束，[progress]
  /// 是它给的进度出口。预加载之后的登录后启动项（浏览器会话补同步、
  /// cf_clearance 续期）也由它在会话判定之后启动，这里不再按预加载里的
  /// 当前用户自行判定。
  Future<void> ensurePreloaded({
    String reason = 'unknown',
    required StartupPreloadProgress progress,
  }) {
    if (_preload.isLoaded) return Future.value();

    final active = _activePreload;
    if (active != null) {
      _log('reuse active preload: reason=$reason');
      return active;
    }

    late final Future<void> future;
    _preloadProgress = progress;
    future = _ensurePreloadedInternal(reason: reason, progress: progress)
        .whenComplete(() {
          if (identical(_activePreload, future)) {
            _activePreload = null;
          }
          if (identical(_preloadProgress, progress)) {
            _preloadProgress = null;
          }
        });
    _activePreload = future;
    return future;
  }

  /// 直连预加载（含 WebView 预加载失败后的直连回退）拿到登录态后，补一次
  /// 浏览器会话同步（priming + session bootstrap）。由启动序列在会话判定为
  /// 已登录后调用；预加载没完成时不做。
  void settleAfterNativePreload({required String reason}) {
    if (!_preload.isLoaded) return;
    unawaited(() async {
      try {
        final synced = await ensureBrowserTrust(reason: reason);
        _log('native preload browser trust settled=$synced reason=$reason');
      } catch (e) {
        _log(
          'native preload browser trust settle failed: $e',
          level: 'warning',
        );
      }
    }());
  }

  Future<bool> ensureBrowserTrust({
    String reason = 'unknown',
    bool force = false,
  }) {
    if (!force) {
      final active = _activeBrowserTrust;
      if (active != null) return active;
    }

    final gateCompleter = Completer<bool>();
    late final Future<bool> gateFuture;
    gateFuture = gateCompleter.future.whenComplete(() {
      if (identical(_activeBrowserTrustGate, gateFuture)) {
        _activeBrowserTrustGate = null;
      }
    });

    late final Future<bool> future;
    future =
        _ensureBrowserTrustInternal(
          reason: reason,
          requestGate: gateCompleter,
          forceSessionSync: force,
        ).whenComplete(() {
          _completeRequestGate(gateCompleter, false);
          if (_pendingClearanceRefreshReason != null) {
            _startClearanceRefreshIfLoggedIn(reason: 'browser_trust_settled');
          }
          if (identical(_activeBrowserTrust, future)) {
            _activeBrowserTrust = null;
          }
        });
    _activeBrowserTrustGate = gateFuture;
    _activeBrowserTrust = future;
    return future;
  }

  /// 仅等待当前已经在跑的浏览器信任同步，不主动创建新的 WebView。
  ///
  /// 用于启动/恢复后的首波业务请求：UI 可以先进入首页，但这些请求如果
  /// 抢在 WebView session bootstrap / cf_clearance 同步之前发出，容易把
  /// 本来可恢复的状态打成 403。等待是有上限的，超时后仍放行。
  Future<bool?> waitForActiveBrowserTrust({
    String reason = 'unknown',
    Duration timeout = _requestGateTimeout,
  }) async {
    final active = _activeBrowserTrustGate;
    if (active == null) return null;

    try {
      _log('wait active browser trust gate begin reason=$reason');
      final ready = await active.timeout(timeout);
      _log('wait active browser trust gate end reason=$reason ready=$ready');
      return ready;
    } on TimeoutException {
      _log(
        'wait active browser trust gate timeout reason=$reason '
        'timeout=${timeout.inSeconds}s',
        level: 'warning',
      );
      return false;
    } catch (e) {
      _log(
        'wait active browser trust gate failed reason=$reason: $e',
        level: 'warning',
      );
      return false;
    }
  }

  void startClearanceRefresh({String reason = 'unknown'}) {
    if (_activeBrowserTrust != null) {
      _pendingClearanceRefreshReason = reason;
      _log(
        'defer cf_clearance refresh until browser trust settles: reason=$reason',
      );
      return;
    }
    _startClearanceRefreshNow(reason: reason);
  }

  void _startClearanceRefreshNow({required String reason}) {
    _log('start cf_clearance refresh: reason=$reason');
    CfClearanceRefreshService().start();
  }

  Future<void> _ensurePreloadedInternal({
    required String reason,
    required StartupPreloadProgress progress,
  }) async {
    final nativeTrusted = await _isNativePreloadTrusted();
    if (nativeTrusted) {
      _lastPreloadPath = BrowserTrustPreloadPath.native;
      _log('preload path=native reason=$reason');
      progress.stage(StartupStage.connecting);
      try {
        await _preload.ensureLoaded(observer: progress);
        _log('native preload success reason=$reason');
        return;
      } catch (e) {
        _log(
          'trusted native preload failed, switching to startup WebView: $e',
          level: 'warning',
        );
        progress.stage(
          StartupStage.webViewLoading,
          reason: StartupDetourReason.nativeFailed,
          detail: describeStartupFailure(e),
        );
      }
    } else {
      progress.stage(
        StartupStage.webViewLoading,
        reason: _nativeUntrustedReason ?? StartupDetourReason.noClearance,
      );
    }

    _log('preload path=startup_webview reason=$reason');
    var hydrated = false;
    final cancellation = BrowserTrustRunCancellation();
    final hydrateTask = _hydratePreloadThroughWebView(
      reason: reason,
      cancellation: cancellation,
    );
    final hydrateResult = await runBrowserTrustTaskWithSafeTimeout<bool>(
      task: hydrateTask,
      timeout: _webViewPreloadTimeout,
      cancellation: cancellation,
    );
    if (hydrateResult == null) {
      _log('startup WebView preload timeout', level: 'warning');
    } else {
      hydrated = hydrateResult;
    }
    if (hydrated) {
      _lastPreloadPath = BrowserTrustPreloadPath.webView;
      _log('startup WebView preload success reason=$reason');
      return;
    }

    _lastPreloadPath = BrowserTrustPreloadPath.native;
    _log(
      'startup WebView preload unavailable, fallback native reason=$reason',
      level: 'warning',
    );
    // 回退直连:原因行换成「内置浏览器没拿到数据 / 超时」,阶段回到直连
    progress.stage(
      StartupStage.connecting,
      reason: hydrateResult == null
          ? StartupDetourReason.webViewTimeout
          : StartupDetourReason.webViewNoData,
    );
    await _preload.ensureLoaded(observer: progress);
    _log('fallback native preload success reason=$reason');
  }

  Future<bool> _ensureBrowserTrustInternal({
    required String reason,
    Completer<bool>? requestGate,
    required bool forceSessionSync,
  }) async {
    final stopwatch = Stopwatch()..start();
    _log('browser trust sync begin reason=$reason');
    try {
      final gateStartedAt = stopwatch.elapsedMilliseconds;
      _log('browser trust request gate priming begin reason=$reason');
      await _primeWebViewCookies(reason: reason);
      final requestTrusted = await _isRequestGateTrusted();
      _completeRequestGate(requestGate, requestTrusted);
      _log(
        'browser trust request gate ready reason=$reason '
        'trusted=$requestTrusted elapsedMs=${stopwatch.elapsedMilliseconds} '
        'gateElapsedMs=${stopwatch.elapsedMilliseconds - gateStartedAt}',
        level: requestTrusted ? 'info' : 'warning',
      );
      if (!WebViewSessionCookieRefreshService.instance.supportsBootstrap) {
        _log('当前站点使用标准 Discourse 会话，跳过专属 fingerprint bootstrap');
        _startClearanceRefreshIfLoggedIn();
        return requestTrusted;
      }
    } catch (e) {
      _completeRequestGate(requestGate, false);
      rethrow;
    }

    final sessionStartedAt = stopwatch.elapsedMilliseconds;
    _log(
      'browser trust session bootstrap begin reason=$reason '
      'force=$forceSessionSync',
    );
    var bootstrap = await WebViewSessionCookieRefreshService.instance
        .ensureSynced(reason: reason, force: forceSessionSync);
    // bootstrap 被 CF(403/429)挡下:作废本地假阳性信任,复用/发起 CF 验证拿到
    // 新 cf_clearance 后 force 重跑一次,避免与 Dio 侧的 CF 自愈各自为政。
    if (bootstrap.cfBlocked) {
      bootstrap = await _recoverBootstrapFromCfBlock(
        reason: reason,
        blocked: bootstrap,
      );
    }
    final synced = bootstrap.ok;
    _log(
      'browser trust session bootstrap end reason=$reason '
      'synced=$synced cfBlocked=${bootstrap.cfBlocked} '
      'elapsedMs=${stopwatch.elapsedMilliseconds} '
      'sessionElapsedMs=${stopwatch.elapsedMilliseconds - sessionStartedAt}',
      level: synced ? 'info' : 'warning',
    );
    _log(
      'browser trust sync end reason=$reason synced=$synced '
      'elapsedMs=${stopwatch.elapsedMilliseconds}',
    );
    _startClearanceRefreshIfLoggedIn();
    return synced;
  }

  /// WebView session bootstrap 被 CF(403/429)挡下后的统一恢复:
  /// 作废本地假阳性信任 → 复用 Dio 侧正在进行的验证(没有则主动发起)→
  /// 成功后 force 重跑一次 bootstrap。只重试一次,避免与 CF 拉锯/死循环。
  Future<SessionBootstrapResult> _recoverBootstrapFromCfBlock({
    required String reason,
    required SessionBootstrapResult blocked,
  }) async {
    final cycleStartAt = DateTime.now();
    // 记进账本：窗口内原生预加载/请求门都不再盲信本地 clearance。被拒时
    // jar 里的值一并记下，jar 换上别的值即解除。
    _ledger.noteRejected(
      CfClearanceAuthority.mainHost,
      value: await _jar.getCfClearance(),
    );
    _log(
      'bootstrap blocked by CF status=${blocked.status} phase=${blocked.phase}; '
      'invalidate native trust, coordinate clearance reason=$reason',
      level: 'warning',
    );
    AppLogger.warning(
      'WebView bootstrap 被 CF 挡下(status=${blocked.status}),开始统一恢复',
      tag: 'BrowserTrust',
    );

    final cf = CfChallengeService();
    var gotClearance = false;

    final resolvedAt = cf.clearanceResolvedAt.value;
    if (resolvedAt != null && resolvedAt.isAfter(cycleStartAt)) {
      // 本周期内已经有一轮验证把 cf_clearance 重新拿到,直接重跑即可。
      gotClearance = true;
    } else if (cf.isVerifying) {
      // Dio 侧(或其它入口)正在验证 → 只等这一轮的结果,不重复弹验证、
      // 也不把它转前台。通过即定稿值已在 jar。
      final outcome = await cf.waitForActiveRound(
        timeout: _activeRoundWaitTimeout,
      );
      gotClearance = outcome?.passed ?? false;
    } else if (cf.autoVerifyEnabled && !cf.isInCooldown) {
      // 没有进行中的验证 → coordinator 主动发起(期间出现的进行中验证会被
      // 合流)。自动恢复不是用户发起的,先后台静默尝试再转前台。
      final outcome = await cf.verify(
        mode: CfVerifyMode.silentFirst,
        context: _navigatorContext,
      );
      gotClearance = outcome.passed;
    }

    if (!gotClearance) {
      _log(
        'CF clearance not obtained, give up bootstrap retry reason=$reason',
        level: 'warning',
      );
      AppLogger.warning(
        'CF 未拿到新 clearance,放弃 bootstrap 重跑',
        tag: 'BrowserTrust',
      );
      return blocked;
    }

    _ledger.clearRejection(CfClearanceAuthority.mainHost);
    // 验证结果会早于 Windows WebView2 Controller 的真实析构完成。
    // 等 CF teardown gate（内部含 1.2 秒冷却）后才能创建 Session WebView。
    await cf.waitForManualTeardown();
    _log('CF clearance obtained, force re-run bootstrap reason=$reason');
    final retry = await WebViewSessionCookieRefreshService.instance
        .ensureSynced(reason: '$reason:cf_recover', force: true);
    _log(
      'bootstrap re-run after CF: ok=${retry.ok} cfBlocked=${retry.cfBlocked} '
      'reason=$reason',
      level: retry.ok ? 'info' : 'warning',
    );
    AppLogger.warning(
      'CF 恢复后 bootstrap 重跑 ok=${retry.ok} cfBlocked=${retry.cfBlocked}',
      tag: 'BrowserTrust',
    );
    // 即使重跑仍被 CF 挡下也直接返回,不再递归(本周期只恢复一次)。
    return retry;
  }

  void _completeRequestGate(Completer<bool>? gate, bool ready) {
    if (gate == null || gate.isCompleted) return;
    gate.complete(ready);
  }

  Future<void> _primeWebViewCookies({required String reason}) async {
    try {
      await WebViewCookiePriming.instance.prime(AppConstants.baseUrl);
    } catch (e) {
      _log(
        'WebView cookie priming failed: reason=$reason $e',
        level: 'warning',
      );
      rethrow;
    }
  }

  Future<bool> _hydratePreloadThroughWebView({
    required String reason,
    required BrowserTrustRunCancellation cancellation,
  }) async {
    // WebView 使用期：开始时从 jar 重灌（失败照常预载、记日志），首页加载
    // 完与 bootstrap 跑完各回写一次，结束时不再回写
    final webViewUse = WebViewUses.instance.start(
      WebViewUsePurpose.startupPreload,
      reason: '$reason:webview_preload',
    );
    try {
      return await _runPreloadWebView(
        webViewUse,
        reason: reason,
        cancellation: cancellation,
      );
    } finally {
      unawaited(webViewUse.end(WebViewUseOutcome.aborted));
    }
  }

  Future<bool> _runPreloadWebView(
    WebViewUse webViewUse, {
    required String reason,
    required BrowserTrustRunCancellation cancellation,
  }) async {
    if (!await webViewUse.ready) {
      _log(
        'WebView cookie priming failed: reason=$reason:webview_preload, '
        'continue preload',
        level: 'warning',
      );
    }
    if (cancellation.isCancelled) return false;
    _log('startup WebView create reason=$reason');

    var loadCompleter = Completer<void>();
    HeadlessInAppWebView? webView;

    webView = HeadlessInAppWebView(
      webViewEnvironment: io.Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: WebViewSettings.headless,
      initialUserScripts: _startupPreloadScripts(),
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onWebViewCreated: (createdController) {
        WebViewSettings.applyWindowsHeadlessMemoryTarget(createdController);
        WebViewSettings.registerJsErrorReporter(createdController);
      },
      onLoadStop: (_, _) {
        if (!loadCompleter.isCompleted) {
          loadCompleter.complete();
        }
      },
      onReceivedError: (_, request, error) {
        _log(
          'startup WebView error: url=${request.url}, ${error.description}',
          level: 'warning',
        );
      },
    );

    var platformViewStarted = false;
    try {
      // WebView 创建/销毁占用平台主线程,与掉帧时间轴对齐归因
      FrameJankMonitor.logEvent('WEBVIEW', 'BrowserTrust run(): $reason');
      platformViewStarted = true;
      await webView.run();
      if (cancellation.isCancelled) return false;
      final c = webView.webViewController;
      if (c == null) return false;

      if (io.Platform.isWindows) {
        await c.loadUrl(
          urlRequest: URLRequest(url: WebUri(_windowsBootstrapUrl)),
        );
        if (cancellation.isCancelled) return false;
        try {
          await Future.any<void>([
            loadCompleter.future.timeout(_originLoadTimeout),
            cancellation.whenCancelled,
          ]);
        } on TimeoutException {
          debugPrint('[BrowserTrust] Windows origin bootstrap timeout');
        }
        if (cancellation.isCancelled) return false;
        await _writeStartupShell(c);
        if (cancellation.isCancelled) return false;
      } else {
        await c.loadData(
          data: _startupShellHtml,
          baseUrl: WebUri(AppConstants.baseUrl),
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
        if (cancellation.isCancelled) return false;
      }

      loadCompleter = Completer<void>();
      await _navigateToHome(c);
      if (cancellation.isCancelled) return false;
      await _waitForLoad(loadCompleter, cancellation: cancellation);
      if (cancellation.isCancelled) return false;
      _log('startup WebView home loaded, syncing cookies reason=$reason');
      await webViewUse.checkpoint(
        WebViewUseOutcome.loaded,
        reason: 'browser_trust_home',
        controller: c,
      );
      if (cancellation.isCancelled) return false;

      _preloadProgress?.stage(StartupStage.webViewSnapshot);
      final html = await _readPreloadedSnapshot(c, cancellation: cancellation);
      if (cancellation.isCancelled) return false;
      final hydrated =
          html != null &&
          html.isNotEmpty &&
          await _preload.hydrateFromHtml(html);
      if (cancellation.isCancelled) return false;
      _log(
        'startup WebView snapshot html=${html != null && html.isNotEmpty} hydrated=$hydrated reason=$reason',
        level: hydrated ? 'info' : 'warning',
      );

      final tToken = await _jar.getTToken();
      if (tToken != null &&
          tToken.isNotEmpty &&
          WebViewSessionCookieRefreshService.instance.supportsBootstrap) {
        if (cancellation.isCancelled) return false;
        _log('startup WebView session bootstrap begin reason=$reason');
        _preloadProgress?.stage(StartupStage.webViewBootstrap);
        final bootstrapResult = await WebViewSessionCookieRefreshService
            .instance
            .runOnController(
              c,
              reason: '$reason:startup_webview',
              pluginCandidates: _preload.pluginCandidatesSync,
              isCancelled: () => cancellation.isCancelled,
              cancellationSignal: cancellation.whenCancelled,
            );
        if (cancellation.isCancelled) return false;
        final bootstrapped = bootstrapResult.ok;
        await webViewUse.checkpoint(
          WebViewUseOutcome.loaded,
          reason: 'browser_trust_bootstrap',
          controller: c,
        );
        if (cancellation.isCancelled) return false;
        final runtimeDetails = await _jar.getCookieDiagnosticsForRequest(
          Uri.parse(AppConstants.baseUrl),
          names: const {'_rt'},
        );
        final hasRuntimeCookie = runtimeDetails.any(
          (cookie) => (cookie['valueLength'] as int? ?? 0) > 0,
        );
        if (bootstrapped && hasRuntimeCookie) {
          WebViewSessionCookieRefreshService.instance.markSynced(
            reason: '$reason:startup_webview',
            tToken: await _jar.getTToken(),
            hasRuntimeCookie: hasRuntimeCookie,
          );
        }
        _log('startup WebView session bootstrap end reason=$reason');
      } else {
        _log('startup WebView session bootstrap skipped: no _t or unsupported site');
      }

      return hydrated;
    } catch (e) {
      _log('startup WebView preload failed: $e', level: 'warning');
      return false;
    } finally {
      try {
        await webView.dispose();
      } catch (e) {
        _log('dispose startup WebView failed: $e', level: 'warning');
      }
      if (platformViewStarted) {
        await Future<void>.delayed(_webViewTeardownCooldown);
      }
      FrameJankMonitor.logEvent('WEBVIEW', 'BrowserTrust dispose');
    }
  }

  Future<void> _navigateToHome(InAppWebViewController controller) async {
    await controller.loadUrl(
      urlRequest: URLRequest(
        url: WebUri(AppConstants.baseUrl),
        headers: const {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
  }

  Future<void> _waitForLoad(
    Completer<void> loadCompleter, {
    required BrowserTrustRunCancellation cancellation,
  }) async {
    try {
      await Future.any<void>([
        loadCompleter.future.timeout(_originLoadTimeout),
        cancellation.whenCancelled,
      ]);
    } on TimeoutException {
      _log('startup WebView load timeout, continue', level: 'warning');
    }
  }

  Future<String?> _readPreloadedSnapshot(
    InAppWebViewController controller, {
    required BrowserTrustRunCancellation cancellation,
  }) async {
    final deadline = DateTime.now().add(_domSnapshotTimeout);
    while (!cancellation.isCancelled && DateTime.now().isBefore(deadline)) {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'window.__rawPreloaded || null',
        );
        if (cancellation.isCancelled) return null;
        final html = raw?.toString();
        if (html != null && html.isNotEmpty && html != 'null') {
          return html;
        }
      } catch (_) {}
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 250)),
        cancellation.whenCancelled,
      ]);
    }
    return null;
  }

  /// 冷启动能否直接走原生链路预加载首页（剩余有效期门槛见
  /// [CfClearancePurpose.nativePreload]）。
  Future<bool> _isNativePreloadTrusted() async {
    final status = await _clearanceStatus(CfClearancePurpose.nativePreload);
    _nativeUntrustedReason = switch (status.verdict) {
      CfClearanceVerdict.usable => null,
      CfClearanceVerdict.recentlyRejected ||
      CfClearanceVerdict.challenged => StartupDetourReason.clearanceRejected,
      CfClearanceVerdict.expiring ||
      CfClearanceVerdict.expired => StartupDetourReason.clearanceExpiring,
      CfClearanceVerdict.missing ||
      CfClearanceVerdict.foreignDomain => StartupDetourReason.noClearance,
    };
    _log(
      'native trust check: trusted=${status.usable} $status',
      level: status.usable ? 'info' : 'warning',
    );
    return status.usable;
  }

  /// 首波业务请求的信任门（剩余有效期门槛见 [CfClearancePurpose.requestGate]）。
  Future<bool> _isRequestGateTrusted() async {
    final status = await _clearanceStatus(CfClearancePurpose.requestGate);
    _log(
      'request gate trust check: trusted=${status.usable} $status',
      level: status.usable ? 'info' : 'warning',
    );
    return status.usable;
  }

  Future<CfClearanceStatus> _clearanceStatus(CfClearancePurpose purpose) async {
    if (!_jar.isInitialized) {
      await _jar.initialize();
    }
    return _ledger.status(CfClearanceAuthority.mainHost, purpose: purpose);
  }

  /// 是否已登录只读启动序列的会话判定（以前读预加载里的当前用户，与
  /// CurrentUserNotifier / MainPage 各判各的）。
  void _startClearanceRefreshIfLoggedIn({String reason = 'preload_logged_in'}) {
    if (AppStartup.instance.isLoggedIn) {
      final pendingReason = _pendingClearanceRefreshReason;
      _pendingClearanceRefreshReason = null;
      _startClearanceRefreshNow(
        reason: pendingReason == null ? reason : '$reason:$pendingReason',
      );
    } else {
      _log('skip cf_clearance refresh: not logged in');
    }
  }

  void _log(String message, {String level = 'info'}) {
    CfChallengeLogger.log('[BrowserTrust] $message', level: level);
  }

  UnmodifiableListView<UserScript> _startupPreloadScripts() {
    return UnmodifiableListView([
      ...WebViewSettings.compatPolyfillScripts,
      UserScript(
        source: _preloadedSnapshotScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]);
  }

  Future<void> _writeStartupShell(InAppWebViewController controller) async {
    final html = jsonEncode(_startupShellHtml);
    await controller.evaluateJavascript(
      source:
          '''
document.open();
document.write($html);
document.close();
''',
    );
  }

  String get _windowsBootstrapUrl => '${AppConstants.baseUrl}/robots.txt';

  String get _startupShellHtml =>
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body></body></html>';

  String get _preloadedSnapshotScript => '''
(function() {
  if (window.__fluxdoPreloadedSnapshotInstalled) return;
  window.__fluxdoPreloadedSnapshotInstalled = true;

  function capture() {
    var el = document.querySelector('#data-preloaded, [data-preloaded]');
    if (!el) return false;
    var parts = [el.outerHTML];
    document.querySelectorAll('meta[name]').forEach(function(m) {
      parts.push(m.outerHTML);
    });
    var setup = document.getElementById('data-discourse-setup');
    if (setup) parts.push(setup.outerHTML);
    window.__rawPreloaded = parts.join('\\n');
    return true;
  }

  if (capture()) return;
  var observer = new MutationObserver(function() {
    if (capture()) observer.disconnect();
  });
  function observe() {
    var root = document.documentElement || document;
    observer.observe(root, { childList: true, subtree: true });
    capture();
  }
  if (document.documentElement) {
    observe();
  } else {
    document.addEventListener('DOMContentLoaded', observe, { once: true });
  }
})();
''';
}
