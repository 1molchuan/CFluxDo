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
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../../l10n/s.dart';
import '../exceptions/api_exception.dart';
import '../flux_request_spec.dart';
import '../health/network_health_controller.dart';

/// Cloudflare 验证拦截器
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
/// 所以现状是**终态**:恢复层管无状态重放,本拦截器管需要 UI 交互与传输
/// 切换的有状态恢复。分界由 RateLimitPolicy 的 isChallengeResponse 钩子
/// 划定——挑战型 429 放行给这里,真限流归恢复层。
class CfChallengeInterceptor extends Interceptor {
  CfChallengeInterceptor({required this.dio, required this.cookieJarService});

  final Dio dio;
  final CookieJarService cookieJarService;

  /// 共享的 cookie 同步 Future：验证成功后只执行一次 sync
  static Future<bool>? _activeSyncFuture;

  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

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
    String? cfClearance = await cookieJarService.getCfClearance();
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
      cfClearance = await cookieJarService.getCfClearance();
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

  bool _shouldShowActionPrompt(RequestOptions options) {
    final spec = options.spec;
    if (spec.isSilent) return false;
    if (spec.hasExplicitErrorToast) {
      return spec.showErrorToast;
    }
    return _mutationMethods.contains(options.method.toUpperCase());
  }

  String _requestMode(RequestOptions options) {
    if (options.spec.isSilent) return 'silent';
    return _shouldShowActionPrompt(options) ? 'action' : 'data';
  }

  Future<void> _refreshCookieHeader(RequestOptions options) async {
    options.headers.remove('cookie');
    options.headers.remove('Cookie');

    final cookieHeader = await cookieJarService.getCookieHeaderForRequest(
      options.uri,
    );
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      options.headers['Cookie'] = cookieHeader;
    }
  }

  /// 撞盾后用 WebView 持有的另一枚 cf_clearance 换值重放。
  ///
  /// 返回 null 表示没有可换的值或换值未生效（调用方继续走验证流程）；
  /// 否则 [_WebViewClearanceReplay.response] 为重放成功的响应，
  /// [_WebViewClearanceReplay.error] 为非 CF 原因的失败（如实上抛，不再验证）；
  /// 两者皆空表示重放仍撞盾（已登记该值被撞，调用方继续验证）。
  Future<_WebViewClearanceReplay?> _tryReplayWithWebViewClearance({
    required DioException err,
    required String? challengedClearance,
    required String requestMethod,
    required String requestUrl,
  }) async {
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
      if (CfClearanceAuthority.isSameValue(value, challengedClearance)) continue;
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
    final swappedIn = await cookieJarService.getCfClearance();
    if (!CfClearanceAuthority.isSameValue(swappedIn, candidate)) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] WebView cf_clearance (${candidate.length} chars) '
        'not adopted by sync gate, falling back to verify',
      );
      return null;
    }

    final replayOptions = err.requestOptions.copyWith();
    replayOptions.extra[FluxRequestKeys.skipCfChallenge] = true;
    replayOptions.extra[FluxRequestKeys.skipCfBlock] = true;
    await _refreshCookieHeader(replayOptions);
    CfChallengeLogger.log(
      '[INTERCEPTOR] Swapped in WebView cf_clearance '
      '(challenged=${challengedClearance?.length ?? 0} chars, '
      'webview=${candidate.length} chars), replaying: '
      '$requestMethod $requestUrl',
    );
    try {
      final response = await dio.fetch(replayOptions);
      CfChallengeLogger.logInterceptorRetry(
        url: requestUrl,
        success: true,
        statusCode: response.statusCode,
      );
      return _WebViewClearanceReplay(response: response);
    } catch (e) {
      if (e is DioException && CfChallengeService.isCfChallengeError(e.response)) {
        // 换上的值也被撞：登记为已死，继续走验证流程
        authority.noteIncumbentChallenged(candidate);
        CfChallengeLogger.log(
          '[INTERCEPTOR] Replay with WebView cf_clearance still '
          'challenged (${e.response?.statusCode}), falling back to verify',
        );
        return const _WebViewClearanceReplay();
      }
      CfChallengeLogger.logInterceptorRetry(
        url: requestUrl,
        success: false,
        error: e.toString(),
      );
      return _WebViewClearanceReplay(
        error: e is DioException
            ? e
            : DioException(
                requestOptions: replayOptions,
                error: e,
                type: DioExceptionType.unknown,
              ),
      );
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;

    // 检查是否标记跳过 CF 验证（防止重试后再次触发）
    final skipCfChallenge = err.requestOptions.spec.skipCfChallenge;

    // CF 速率限制规则的 action 配为 managed_challenge / js_challenge / challenge 时,
    // 触发后返回 429 + cf-mitigated: challenge + 挑战页,而不是 403;
    // Under Attack 等模式还会用 503。状态码判定统一收口在 isCfChallengeError。
    if (!skipCfChallenge &&
        CfChallengeService.isCfChallengeError(err.response)) {
      // 备选提取 sitekey（从 403 响应体中）
      CfClearanceRefreshService().extractAndUpdateSitekey(
        err.response?.data?.toString() ?? '',
      );
      // 403 说明 cf_clearance 已失效，停止自动续期（避免与手动验证冲突）。
      // 这里不需要 await——真正要建验证 WebView 前，showManualVerify 内部
      // 会自己再 await 一次 stop()，确保销毁完成。
      unawaited(CfClearanceRefreshService().stop());

      final requestUrl = err.requestOptions.uri.toString();
      final requestMethod = err.requestOptions.method.toUpperCase();
      final requestTag = err.requestOptions.spec.requestTag;
      final logMessage =
          'CF Challenge detected: $requestMethod $requestUrl '
          '(status=$statusCode, silent=${err.requestOptions.spec.isSilent}, '
          'tag=${requestTag ?? '-'}, skipCsrf=${err.requestOptions.spec.skipCsrf})';
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
        url: requestUrl,
        statusCode: statusCode ?? 0,
      );

      // 过期 403 直接换 cookie 重放：本次请求携带的 cf_clearance 若已不是 jar
      // 里的当前值（请求在途期间另一轮验证换上了新值，或同批排队请求仍带着
      // 验证前的旧 Cookie 头），这个 403 针对的是旧值，jar 里的新值很可能
      // 本来就能过。先用新值重放一次，省掉一轮多余的验证；重放仍撞盾再走
      // 正常验证流程。
      final carriedClearance = CfClearanceAuthority.extractFromCookieHeader(
        err.requestOptions.headers['Cookie']?.toString() ??
            err.requestOptions.headers['cookie']?.toString(),
      );
      final currentClearance = await cookieJarService.getCfClearance();
      final carriedIsStale =
          currentClearance != null &&
          currentClearance.isNotEmpty &&
          !CfClearanceAuthority.isSameValue(carriedClearance, currentClearance);
      if (carriedIsStale) {
        final replayOptions = err.requestOptions.copyWith();
        replayOptions.extra[FluxRequestKeys.skipCfChallenge] = true;
        replayOptions.extra[FluxRequestKeys.skipCfBlock] = true;
        await _refreshCookieHeader(replayOptions);
        CfChallengeLogger.log(
          '[INTERCEPTOR] Carried cf_clearance is stale '
          '(carried=${carriedClearance?.length ?? 0} chars, '
          'current=${currentClearance.length} chars), replaying with current: '
          '$requestMethod $requestUrl',
        );
        try {
          final response = await dio.fetch(replayOptions);
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: true,
            statusCode: response.statusCode,
          );
          return handler.resolve(response);
        } catch (e) {
          if (e is DioException &&
              CfChallengeService.isCfChallengeError(e.response)) {
            // jar 里的当前值也被撞了：按它在位被撞处理，继续走验证流程
            CfChallengeLogger.log(
              '[INTERCEPTOR] Replay with current cf_clearance still '
              'challenged (${e.response?.statusCode}), falling back to verify',
            );
          } else {
            // 不是 CF 问题（网络错误、其他状态码）：如实返回，不再发起验证
            CfChallengeLogger.logInterceptorRetry(
              url: requestUrl,
              success: false,
              error: e.toString(),
            );
            if (e is DioException) return handler.reject(e);
            return handler.reject(
              DioException(
                requestOptions: replayOptions,
                error: e,
                type: DioExceptionType.unknown,
              ),
            );
          }
        }
      }

      // 记录在位值被撞：本次请求（或刚才的重放）实际携带的 cf_clearance 已被
      // CF 挑战（= 已死），打开换届窗口——之后 sync 可以替换它（过盾新值
      // 继位，或 Turnstile 最新铸值无缝补位）。这里不做任何候选值判定、
      // 不分 403/429：撞了就过盾，语义见 CfClearanceAuthority。
      final challengedClearance = carriedIsStale
          ? currentClearance
          : carriedClearance;
      CfClearanceAuthority.instance.noteIncumbentChallenged(
        challengedClearance,
      );
      final cfService = CfChallengeService();

      // 撞盾先换值重放：WebView 若已持有一枚与被撞值不同、且本会话未被撞过的
      // cf_clearance（典型：站点在 WebView 里刚签了新值，但 sync 闸门因在位值
      // 当时还健康而把它挡在 jar 外），直接换进 jar 重放一次，省掉一轮验证
      // WebView 导航（实测可把 3～6 秒的恢复缩到一个请求往返）。在位值刚登记
      // 为已撞，闸门此时放行。验证进行中不做（验证页自己会同步新值，避免
      // 两边抢写）；WebView 值也撞盾则按它在位被撞处理，继续走验证流程。
      if (!cfService.isVerifying) {
        final swapped = await _tryReplayWithWebViewClearance(
          err: err,
          challengedClearance: challengedClearance,
          requestMethod: requestMethod,
          requestUrl: requestUrl,
        );
        if (swapped != null) {
          if (swapped.response != null) return handler.resolve(swapped.response!);
          if (swapped.error != null) return handler.reject(swapped.error!);
        }
      }

      final isSilent = err.requestOptions.spec.isSilent;
      final shouldShowActionPrompt = _shouldShowActionPrompt(
        err.requestOptions,
      );
      final requestMode = _requestMode(err.requestOptions);

      DioException cfException(CfChallengeException error) {
        return DioException(
          requestOptions: err.requestOptions,
          error: error,
          type: DioExceptionType.unknown,
        );
      }

      if (!cfService.autoVerifyEnabled) {
        CfChallengeLogger.log(
          '[INTERCEPTOR] Auto verify disabled, rejecting: '
          '$requestMethod $requestUrl mode=$requestMode',
        );
        return handler.reject(
          cfException(CfChallengeException(autoVerifyDisabled: true)),
        );
      }

      // 注:这里刻意**不**用 NetworkHealthController.hasForegroundUi 提前判掉
      // 无 UI 环境。它的判据是 navigatorKey.currentContext,而主 isolate 启动
      // 早期那也是 null —— 提前 reject 会毁掉"启动时撞盾、等 context 就绪后
      // 补弹验证"这条路径(启动窗口恰恰是验证最该成功的时候)。
      // 无 UI 环境由 showManualVerify 内部的 10s context 等待上限收口。

      if (cfService.isInCooldown) {
        debugPrint('[Dio] CF Challenge in cooldown, rejecting request');
        CfChallengeLogger.log(
          '[INTERCEPTOR] Cooldown after 403: $requestMethod $requestUrl '
          'mode=$requestMode',
        );
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_operationBlockedByChallenge,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(inCooldown: true)),
        );
      }

      // 静默请求只在后台尝试验证；页面数据/操作请求也先后台静默尝试
      // silentFirstGrace，多数非交互式挑战会在这段时间内自动通过，过不了
      // 再转前台展示验证。
      // (Windows 曾因插件析构竞态崩溃 0xc0000005 禁用过静默后台验证;
      // vendored 插件的 aliveGuard/TextureBridge 修复落地后恢复。)
      var result = isSilent
          ? await cfService.showManualVerify(null, false)
          : await cfService.showVerifySilentFirst();

      // 本次验证的轮次号。多个并发请求撞盾会合流到同一轮验证,却各自走下面
      // 的处置分支 —— 失败计数必须带上轮次去重,否则一次时序抖动会被记成
      // N 次失败(实测:启动时五个首屏请求同时撞盾,cookie 同步慢一拍,
      // 计数瞬间打满阈值 → 进冷却 + 弹切兼容询问,而 9 秒后一切自愈,
      // 用户全程无感却被弹窗打断)。
      var verifyRound = cfService.verifyRound;

      // 验证「成功」但铸出的 clearance 重试仍被撞时,用户可见请求再给一轮验证
      // 机会(只一轮)。实测(2026-10-13,元宇宙「我的服务」开启失败)这类
      // clearance 多是挑战流程被提前收口的半成品,下一轮验证就能铸出有效值;
      // 以前这里直接熔断 60s 冷却,用户连点几次全是「获取授权链接失败」。
      var reverified = false;

      while (result == true) {
        final syncOk = await _syncCookiesOnce();
        if (!syncOk) {
          cfService.startCooldown(round: verifyRound);
          debugPrint(
            '[Dio] cf_clearance not found after sync, entering cooldown',
          );
          if (shouldShowActionPrompt) {
            CfChallengeService.showGlobalMessage(
              S.current.cf_challengeNotEffective,
            );
          }
          return handler.reject(
            cfException(
              CfChallengeException(cause: 'cf_clearance cookie 同步失败'),
            ),
          );
        }

        // 各自重试自己的原始请求（每个请求 URL/参数不同，无法共享）
        final retryOptions = err.requestOptions;
        try {
          retryOptions.extra[FluxRequestKeys.skipCfChallenge] = true;
          // 绕过 RequestScheduler 的 CF 冻结判定。retry 时序上 isVerifying 已经
          // 复位为 false，但加这个标记是双保险，防止未来逻辑变更引入 race。
          retryOptions.extra[FluxRequestKeys.skipCfBlock] = true;
          // 清除原始请求中残留的 cookie header，并补上最新 Cookie。
          // 这样即使 dio.fetch 不重新经过 CookieManager，也不会继续发送旧值。
          await _refreshCookieHeader(retryOptions);
          // 诊断：记录 CookieJar 中的 cookie 名称和 cf_clearance 状态
          final cookieHeader =
              retryOptions.headers['Cookie']?.toString() ??
              retryOptions.headers['cookie']?.toString();
          final hasCfClearance =
              cookieHeader?.contains('cf_clearance=') ?? false;
          final cookieNames = cookieHeader
              ?.split('; ')
              .map((c) => c.split('=').first)
              .join(', ');
          debugPrint(
            '[Dio] Retry cookies: ${hasCfClearance ? "✓ 包含 cf_clearance" : "⚠️ 缺少 cf_clearance"}, '
            'names=[$cookieNames], total=${cookieHeader?.length ?? 0} chars',
          );
          final response = await dio.fetch(retryOptions);
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: true,
            statusCode: response.statusCode,
          );
          // 广播:Dio 侧重试成功 = 新 cf_clearance 已生效。供 BrowserTrustCoordinator
          // 感知"CF 已解决",从而 force 重跑因同一 CF 失败的 WebView session bootstrap。
          cfService.clearanceResolvedAt.value = DateTime.now();
          return handler.resolve(response);
        } catch (e) {
          final retryStillBlockedByCf =
              e is DioException &&
              CfChallengeService.isCfChallengeError(e.response);

          if (retryStillBlockedByCf &&
              !isSilent &&
              !reverified &&
              !cfService.isInCooldown) {
            reverified = true;
            // 刚铸出的值已确认对 Dio 无效：登记为已撞,放开换届,下一轮验证
            // 铸出的新值才能过 sync 闸门进 jar。
            CfClearanceAuthority.instance.noteIncumbentChallenged(
              CfClearanceAuthority.extractFromCookieHeader(
                retryOptions.headers['Cookie']?.toString() ??
                    retryOptions.headers['cookie']?.toString(),
              ),
            );
            CfChallengeLogger.log(
              '[INTERCEPTOR] Verified clearance rejected on retry '
              '(${e.response?.statusCode}), '
              're-verifying once: $requestMethod $requestUrl',
              level: 'warning',
            );
            result = await cfService.showVerifySilentFirst();
            verifyRound = cfService.verifyRound;
            continue;
          }

          // 验证拿到新 clearance 后，原生链路仍被 CF 拒绝，说明问题不只是
          // Cookie，而是当前原生网络身份未被信任。仅对用户可见请求询问一次，
          // 用户确认后本次会话改用浏览器网络栈，并立即重放原请求。
          if (retryStillBlockedByCf &&
              !isSilent &&
              requestCanUseWebViewAdapter(retryOptions)) {
            final webViewSettings = WebViewAdapterSettingsService.instance;
            final shouldFallback =
                webViewSettings.effectiveEnabled ||
                await cfService.confirmSessionCompatibilityMode();
            if (shouldFallback) {
              webViewSettings.enableSessionFallback();
              // 撤销原请求的"禁走 WebView 适配器"标记,这一行才是让重放
              // 真正改走浏览器网络栈的开关。
              retryOptions.extra.remove(FluxRequestKeys.skipWebViewAdapter);
              try {
                final fallbackResponse = await dio.fetch(retryOptions);
                CfChallengeService.showGlobalMessage(
                  S.current.cf_sessionCompatEnabled,
                  isError: false,
                );
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Native retry still blocked; '
                  'session WebView fallback succeeded',
                );
                return handler.resolve(fallbackResponse);
              } catch (fallbackError) {
                // 会话级兼容必须以首次真实请求成功为准；失败时立即回滚，
                // 避免所有后续请求被锁在一个坏掉的 WebView 传输状态里。
                if (!webViewSettings.persistentEnabled) {
                  webViewSettings.disableSessionFallback();
                }
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Session WebView fallback failed: '
                  '$fallbackError',
                  level: 'warning',
                );
                if (fallbackError is DioException) {
                  return handler.reject(fallbackError);
                }
                return handler.reject(
                  DioException(
                    requestOptions: retryOptions,
                    error: fallbackError,
                    type: DioExceptionType.unknown,
                  ),
                );
              }
            }
          }

          // 诊断：记录完整的重试失败信息
          if (e is DioException) {
            debugPrint(
              '[Dio] Retry failed: status=${e.response?.statusCode}, '
              'type=${e.type}, url=${e.requestOptions.uri}',
            );
            if (e.response?.statusCode == 403 ||
                e.response?.statusCode == 429 ||
                e.response?.statusCode == 503) {
              debugPrint(
                '[Dio] Retry got ${e.response?.statusCode} again — cf_clearance may not have been sent or already expired',
              );
              // 验证刚「成功」、cookie 也带上了,重试却仍被 CF 拦——铸出的
              // clearance 对 Dio 无效。这是确定性环境问题(典型:系统代理
              // 只对 WebView2 生效,Dio 直连,两侧出口 IP 不一致),再验证
              // 多少次都一样,立即熔断进入冷却,阻断验证无限循环。
              if (retryStillBlockedByCf) {
                cfService.startIneffectiveClearanceCooldown();
                // 刚铸出的 clearance 重试仍被撞：同样标记为已死（它可能是
                // IP 绑定类的确定性无效），放开换届，让下一次验证/新铸值
                // 补位，而不是把它留在 jar 里反复撞。
                CfClearanceAuthority.instance.noteIncumbentChallenged(
                  CfClearanceAuthority.extractFromCookieHeader(
                    retryOptions.headers['Cookie']?.toString() ??
                        retryOptions.headers['cookie']?.toString(),
                  ),
                );
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Verified clearance ineffective for Dio '
                  '(retry ${e.response?.statusCode}), entering cooldown: '
                  '$requestMethod $requestUrl',
                  level: 'warning',
                );
                if (shouldShowActionPrompt) {
                  CfChallengeService.showGlobalMessage(
                    S.current.cf_challengeNotEffective,
                  );
                }
              }
            }
          } else {
            debugPrint('[Dio] Retry failed (non-Dio): $e');
          }
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: false,
            error: e.toString(),
          );
          // CF 验证已成功，重试失败是其他原因，传递实际错误以便排查
          if (e is DioException) {
            return handler.reject(e);
          }
          return handler.reject(
            DioException(
              requestOptions: err.requestOptions,
              error: e,
              type: DioExceptionType.unknown,
            ),
          );
        }
      }

      if (result == null) {
        if (cfService.isInCooldown) {
          CfChallengeLogger.log(
            '[INTERCEPTOR] Verification skipped by cooldown: '
            '$requestMethod $requestUrl mode=$requestMode',
          );
          if (shouldShowActionPrompt) {
            CfChallengeService.showGlobalMessage(
              S.current.cf_operationBlockedByChallenge,
            );
          }
          return handler.reject(
            cfException(CfChallengeException(inCooldown: true)),
          );
        }

        // 无 context（应用刚启动，context 还没设置好）
        debugPrint(
          '[Dio] CF Challenge: no context available, cannot show verify page',
        );
        CfChallengeLogger.log('[INTERCEPTOR] No context available');
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_cannotOpenVerifyPage,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(cause: '无法获取 context，验证页面未展示')),
        );
      }

      // 用户取消或验证失败。页面数据请求交给 ErrorView 展示按钮；操作请求给即时提示；静默请求不打扰。
      CfChallengeLogger.log(
        '[INTERCEPTOR] User cancelled or verify failed: '
        '$requestMethod $requestUrl mode=$requestMode',
      );
      if (shouldShowActionPrompt) {
        CfChallengeService.showGlobalMessage(S.current.cf_verifyIncomplete);
      }
      return handler.reject(
        cfException(CfChallengeException(userCancelled: true)),
      );
    }

    handler.next(err);
  }
}

/// 「撞盾先换值重放」的结果：成功响应 / 非 CF 失败 / 两者皆空（仍撞盾）。
class _WebViewClearanceReplay {
  const _WebViewClearanceReplay({this.response, this.error});

  final Response<dynamic>? response;
  final DioException? error;
}
