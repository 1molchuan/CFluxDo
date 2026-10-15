import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
import '../auth_session.dart';
import '../log/log_writer.dart';
import '../network/cookie/boundary_sync_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../network/cookie/session_cookie_sentinel.dart';
import '../network/cookie/webview_cookie_priming.dart';
import 'session_token_authority.dart';

export '../network/cookie/boundary_sync_service.dart'
    show WebViewCookieSyncReport;

/// 一段 WebView 使用的用途。决定开始时怎么准备 WebView 的 cookie、结束时
/// 回写哪些、`_t` 怎么交给 [SessionTokenAuthority]。
enum WebViewUsePurpose {
  /// 登录页 / 登录对话框。
  login,

  /// 站内浏览器页（用户自己浏览）。
  browsing,

  /// WebView 适配器的一次请求（响应后回写关键 cookie）。
  adapterRequest,

  /// WebView 适配器的只读请求（只准备、不回写）。
  adapterReadOnlyRequest,

  /// WebView 会话 bootstrap（WebViewSessionCookieRefreshService）。
  sessionBootstrap,

  /// BrowserTrust 冷启动经 WebView 预载首页。
  startupPreload,

  /// cf_clearance 自动续期（常驻的 Turnstile WebView）。
  clearanceRefresh,

  /// 一轮 CF 验证（验证页与 App 共用 cookie store）。
  cfVerification,
}

/// 调用方在这段使用里观察到的结果。
enum WebViewUseOutcome {
  /// 中途放弃 / 失败 / 被取消 / 本次不必回写：什么都不写，不碰 `_t`。
  aborted,

  /// WebView 跑完了（页面加载 / 会话 bootstrap / Turnstile 有动静 / 普通
  /// 响应），但没有任何东西证明登录态。
  loaded,

  /// 服务端刚认可了 WebView 的登录态（适配器：带 Discourse-Logged-In 的
  /// 请求 2xx 且没有登出头）。
  sessionAccepted,

  /// 登录进行中（刚过 CF / 已见 currentUser 但还没见到 `_t`）。
  loginPending,

  /// 登录成功：WebView 里是刚登录的新会话。
  loginSucceeded,

  /// CF 验证通过（定稿值已经由 [WebViewUse.landVerifiedClearance] 落 jar）。
  cfPassed,
}

/// 一次 WebView → jar 同步的口径（只由本模块按用途与结果决定）。
@immutable
class WebViewCookieSyncSpec {
  const WebViewCookieSyncSpec({
    this.cookieNames,
    this.excludeCookieNames,
    this.trusted = false,
    this.allowLowConfidenceSessionCookies = false,
    this.acceptValues,
  });

  /// 只同步这些 cookie；null 表示全部（`_t` 永远不在其中）。
  final Set<String>? cookieNames;
  final Set<String>? excludeCookieNames;

  /// 权威写入（升 version 盖过 WebView 泛读到的旧值）。
  final bool trusted;
  final bool allowLowConfidenceSessionCookies;

  /// cookie 名 → 只接受的值（CF 定稿值落地，排除 WebView 里的残留旧变体）。
  final Map<String, String>? acceptValues;

  @override
  bool operator ==(Object other) =>
      other is WebViewCookieSyncSpec &&
      setEquals(other.cookieNames, cookieNames) &&
      setEquals(other.excludeCookieNames, excludeCookieNames) &&
      other.trusted == trusted &&
      other.allowLowConfidenceSessionCookies ==
          allowLowConfidenceSessionCookies &&
      mapEquals(other.acceptValues, acceptValues);

  @override
  int get hashCode => Object.hash(
    cookieNames == null ? null : Object.hashAllUnordered(cookieNames!),
    excludeCookieNames == null
        ? null
        : Object.hashAllUnordered(excludeCookieNames!),
    trusted,
    allowLowConfidenceSessionCookies,
    acceptValues == null
        ? null
        : Object.hashAllUnordered(acceptValues!.entries.map((e) => e.key)),
  );

  @override
  String toString() =>
      'WebViewCookieSyncSpec(names=${cookieNames ?? '*'}, '
      'exclude=${excludeCookieNames ?? '-'}, trusted=$trusted, '
      'lowConfidence=$allowLowConfidenceSessionCookies, '
      'accept=${acceptValues?.keys.toList() ?? '-'})';
}

/// 「灌」：使用前从 jar 准备 WebView 的 cookie。
abstract interface class WebViewCookiePreparer {
  /// 重灌（[fresh] 为 true 时先作废「已就绪」标记，强制重来一遍）。
  Future<void> prime(String url, {required bool fresh});

  /// 清理 WebView 里同名 cookie 的多变体。
  Future<void> sweepAll(String url);
}

/// 「回写」：把 WebView cookie store 里的 cookie 按口径写回 jar。
abstract interface class WebViewCookieSource {
  Future<WebViewCookieSyncReport> syncToJar(
    WebViewCookieSyncSpec spec, {
    required String url,
    InAppWebViewController? controller,
    int? generation,
  });
}

/// 一次阶段同步 / 结束的结果。
class WebViewUseReport {
  const WebViewUseReport({
    this.cookies,
    this.sessionToken,
    this.sessionTokenScheduled = false,
    this.loginTokenAdopted,
    this.alreadyEnded = false,
  });

  /// cookie 回写结果（这一结果不回写时为 null）。
  final WebViewCookieSyncReport? cookies;

  /// 当场等到的 `_t` 对账结论（不对账或对账在后台进行时为 null）。
  final SessionTokenReconcileOutcome? sessionToken;

  /// `_t` 对账已安排在后台进行（不阻塞调用方）。
  final bool sessionTokenScheduled;

  /// 登录成功时新 `_t` 是否已写进 jar（其他结果为 null）。
  final bool? loginTokenAdopted;

  /// 这段使用早已结束，本次调用什么都没做。
  final bool alreadyEnded;

  @override
  String toString() =>
      'WebViewUseReport(cookies=$cookies, sessionToken=$sessionToken, '
      'scheduled=$sessionTokenScheduled, loginToken=$loginTokenAdopted'
      '${alreadyEnded ? ', alreadyEnded' : ''})';
}

/// WebView 使用期的唯一入口：开始时准备 cookie，期间 / 结束时按「用途 +
/// 观察到的结果」回写，并把 `_t` 交给 [SessionTokenAuthority]。
///
/// 以前 8 个 WebView 使用方各自拼「灌 → 用 → 回写 → 对账」的一部分，约 19 处
/// syncFromWebView、7 处对账、6 种参数组合，谁该可信写、谁该对账、谁该带
/// 会话代全靠各自记得（eb044395 的修 3、修 4 就是「给更多调用方补对账」）。
/// 现在调用方只说用途和结果，口径全在 [specFor] 与 [_handOffSessionToken]。
class WebViewUses {
  WebViewUses({
    WebViewCookiePreparer? preparer,
    WebViewCookieSource? source,
    SessionTokenAuthority? sessionToken,
    AuthSession? session,
  }) : _preparer = preparer ?? const _PrimingPreparer(),
       _source = source ?? const _BoundarySyncSource(),
       _sessionTokenOverride = sessionToken,
       _session = session ?? AuthSession();

  static final WebViewUses instance = WebViewUses();

  final WebViewCookiePreparer _preparer;
  final WebViewCookieSource _source;
  final SessionTokenAuthority? _sessionTokenOverride;
  final AuthSession _session;

  SessionTokenAuthority get _sessionToken =>
      _sessionTokenOverride ?? SessionTokenAuthority.instance;

  static const Duration _cfPrepareLockTimeout = Duration(seconds: 3);
  static const Duration _cfPrepareTimeout = Duration(seconds: 5);
  static const Duration _adapterReconcileLockTimeout = Duration(seconds: 3);
  static const Duration _resumeReconcileTimeout = Duration(seconds: 5);

  /// 开始一段 WebView 使用：立即开始准备 cookie，返回的 [WebViewUse.ready]
  /// 在准备完成时给出结果。准备失败**不阻止使用**（记日志，ready 为 false）。
  ///
  /// [generation] 是这段使用所属的会话代：过期（期间登出 / 换号）后结束时
  /// 什么都不写。登录、适配器请求由调用方给；会话 bootstrap、启动预载取
  /// 开始时的会话代；浏览、续期、CF 验证不绑会话代（cf_clearance 跨会话）。
  WebViewUse start(
    WebViewUsePurpose purpose, {
    String? url,
    required String reason,
    int? generation,
  }) {
    final effectiveGeneration =
        generation ??
        switch (purpose) {
          WebViewUsePurpose.sessionBootstrap ||
          WebViewUsePurpose.startupPreload => _session.generation,
          _ => null,
        };
    final use = WebViewUse._(
      this,
      purpose,
      url: url ?? AppConstants.baseUrl,
      reason: reason,
      generation: effectiveGeneration,
    );
    use._ready = _prepare(use);
    return use;
  }

  /// 不属于任何 WebView 使用期的一次性回写（例如原生登录页过 CF 后，把验证
  /// 页留下的非登录 cookie 带进 jar）。口径与使用期内同一用途 / 结果一致。
  Future<WebViewUseReport> syncOnce(
    WebViewUsePurpose purpose,
    WebViewUseOutcome outcome, {
    required String reason,
    String? url,
    int? generation,
  }) {
    final use = WebViewUse._(
      this,
      purpose,
      url: url ?? AppConstants.baseUrl,
      reason: reason,
      generation: generation,
    ).._ready = Future.value(true);
    return use.end(outcome);
  }

  /// App 回到前台：后台期间 WebView（站内页 / 适配器）可能自己轮换过 `_t`
  /// 而 jar 没跟上，先对账再恢复原生请求；WebView 没有 `_t`（后台被服务端
  /// 删掉 / 存储被清）时把 jar 的推过去。有上限时长，超时按原流程继续。
  Future<SessionTokenReconcileOutcome?> reconcileAfterBackground() async {
    try {
      return await _sessionToken
          .reconcile(reason: 'app_resume', pushIfWebViewEmpty: true)
          .timeout(_resumeReconcileTimeout);
    } catch (e) {
      debugPrint('[WebViewUse] 回前台 _t 对账跳过: $e');
      return null;
    }
  }

  /// 各用途开始时的准备。
  Future<bool> _prepare(WebViewUse use) async {
    switch (use.purpose) {
      case WebViewUsePurpose.cfVerification:
        // 验证 WebView 与 App 共用 cookie store，不重灌（重灌会把 jar 的值
        // 写回去，而 cf_clearance 刚被清掉）。过盾后它会带着 WebView 里的
        // _t 去加载站内页：WebView 没有 _t 就先把 jar 的推过去；与 jar 不一致
        // 时只按血缘判断，不探测（探测请求此刻自己也会被 CF 拦下）。
        try {
          await _sessionToken
              .reconcile(
                reason: 'cf_challenge_prepare',
                allowProbe: false,
                pushIfWebViewEmpty: true,
                lockTimeout: _cfPrepareLockTimeout,
              )
              .timeout(_cfPrepareTimeout);
        } catch (e) {
          debugPrint('[WebViewUse] 过盾前 _t 对账跳过: $e');
        }
        return true;
      case WebViewUsePurpose.login:
      case WebViewUsePurpose.browsing:
      case WebViewUsePurpose.adapterRequest:
      case WebViewUsePurpose.adapterReadOnlyRequest:
      case WebViewUsePurpose.sessionBootstrap:
      case WebViewUsePurpose.startupPreload:
      case WebViewUsePurpose.clearanceRefresh:
        break;
    }

    final primeUrl = switch (use.purpose) {
      // 后台 WebView 都落在主站
      WebViewUsePurpose.sessionBootstrap ||
      WebViewUsePurpose.startupPreload ||
      WebViewUsePurpose.clearanceRefresh => AppConstants.baseUrl,
      _ => use.url,
    };
    // 后台长期 / 重建的 WebView 每次都重灌一遍（期间 jar 可能变了）；其余
    // 用途共用进程内已就绪的 store（Dio 收到的新值会增量推进去）。
    final fresh = switch (use.purpose) {
      WebViewUsePurpose.sessionBootstrap ||
      WebViewUsePurpose.clearanceRefresh => true,
      _ => false,
    };
    var ok = true;
    try {
      await _preparer.prime(primeUrl, fresh: fresh);
    } catch (e) {
      ok = false;
      _logPrepareFailure(use, 'prime', e);
    }
    if (use.purpose == WebViewUsePurpose.adapterRequest) {
      // 适配器请求马上就要用 cookie：兜底清一遍多变体
      try {
        await _preparer.sweepAll(use.url);
      } catch (e) {
        ok = false;
        _logPrepareFailure(use, 'sweep', e);
      }
    }
    return ok;
  }

  void _logPrepareFailure(WebViewUse use, String step, Object error) {
    debugPrint('[WebViewUse] ${use.purpose.name} 准备失败($step)，继续使用: $error');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_trace',
      'event': 'webview_use_prepare_failed',
      'message': 'WebView 使用前准备 cookie 失败，继续使用',
      'purpose': use.purpose.name,
      'step': step,
      'reason': use.reason,
      'error': error.toString(),
    });
  }

  /// 用途 + 结果 → 回写口径；null 表示不回写。
  @visibleForTesting
  static WebViewCookieSyncSpec? specFor(
    WebViewUsePurpose purpose,
    WebViewUseOutcome outcome,
  ) {
    if (outcome == WebViewUseOutcome.aborted) return null;
    switch (purpose) {
      case WebViewUsePurpose.login:
        return switch (outcome) {
          // 登录未完成：只带非登录 cookie（验证码、CF 等），旧会话不能回写
          WebViewUseOutcome.loginPending => const WebViewCookieSyncSpec(
            excludeCookieNames: CookieJarService.authCookieNames,
          ),
          // 登录成功：全量可信回写（_t 另由 authority 写）
          WebViewUseOutcome.loginSucceeded => const WebViewCookieSyncSpec(
            trusted: true,
            allowLowConfidenceSessionCookies: true,
          ),
          _ => null,
        };
      case WebViewUsePurpose.adapterRequest:
        return switch (outcome) {
          // 服务端认可了 WebView 登录态：关键 cookie 全带（含 _forum_session）
          WebViewUseOutcome.sessionAccepted => WebViewCookieSyncSpec(
            cookieNames: CookieJarService.criticalCookieNames,
          ),
          // 没有登录态证明：登录 cookie 不回写，避免旧会话回灌
          WebViewUseOutcome.loaded => WebViewCookieSyncSpec(
            cookieNames: CookieJarService.criticalCookieNames,
            excludeCookieNames: CookieJarService.authCookieNames,
          ),
          _ => null,
        };
      case WebViewUsePurpose.sessionBootstrap:
      case WebViewUsePurpose.startupPreload:
        return outcome == WebViewUseOutcome.loaded
            // 页面 / bootstrap 产生的运行态 cookie（_rt 等）全量可信回写
            ? const WebViewCookieSyncSpec(
                trusted: true,
                allowLowConfidenceSessionCookies: true,
              )
            : null;
      case WebViewUsePurpose.clearanceRefresh:
        return outcome == WebViewUseOutcome.loaded
            ? const WebViewCookieSyncSpec(
                cookieNames: {'cf_clearance'},
                trusted: true,
              )
            : null;
      case WebViewUsePurpose.browsing:
      // 用户自己浏览：不把页面里的任意 cookie 带回 jar（变体由 Sentinel 收敛）
      case WebViewUsePurpose.adapterReadOnlyRequest:
      case WebViewUsePurpose.cfVerification:
        // CF 定稿值走 landVerifiedClearance；过盾本身不再回写别的
        return null;
    }
  }

  /// 用途 + 结果 → `_t` 交给 authority 的方式。
  Future<WebViewUseReport> _handOffSessionToken(
    WebViewUse use,
    WebViewUseOutcome outcome, {
    required String reason,
    required String url,
    required int? generation,
    required WebViewCookieSyncReport? cookies,
  }) async {
    switch ((use.purpose, outcome)) {
      case (WebViewUsePurpose.login, WebViewUseOutcome.loginSucceeded):
        final adopted = await _sessionToken.adoptLoginToken(
          reason: reason,
          generation: generation,
        );
        return WebViewUseReport(cookies: cookies, loginTokenAdopted: adopted);
      case (
        WebViewUsePurpose.adapterRequest,
        WebViewUseOutcome.sessionAccepted,
      ):
        // 服务端刚认可了 WebView 的登录态：WebView 的 _t 若与 jar 不同，由
        // authority 决定采纳（WebView 轮换到了新值）还是推回（jar 刚轮换）。
        // 等它完成再把响应交回去；别让一次正在探测的对账拖住适配器太久。
        final outcome = await _sessionToken.reconcile(
          url: url,
          reason: reason,
          requestGeneration: generation,
          webViewVerified: true,
          lockTimeout: _adapterReconcileLockTimeout,
        );
        return WebViewUseReport(cookies: cookies, sessionToken: outcome);
      case (WebViewUsePurpose.browsing, WebViewUseOutcome.loaded):
        // 站内页长时间停留时 XHR 会让 WebView 自己轮换 _t；页内请求带了
        // 死值被服务端删掉时，把 jar 里仍有效的值推过去
        _schedule(
          _sessionToken.reconcile(
            url: url,
            reason: reason,
            pushIfWebViewEmpty: true,
          ),
          reason,
        );
        return WebViewUseReport(cookies: cookies, sessionTokenScheduled: true);
      case (WebViewUsePurpose.sessionBootstrap, WebViewUseOutcome.loaded):
      case (WebViewUsePurpose.startupPreload, WebViewUseOutcome.loaded):
        // 页面 / bootstrap 期间 WebView 可能轮换了 _t：服务端探测决定谁对，
        // 无结论两端都不动。不等：探测可能要几秒，别拖住启动 / bootstrap。
        _schedule(_sessionToken.reconcile(reason: reason), reason);
        return WebViewUseReport(cookies: cookies, sessionTokenScheduled: true);
      case (WebViewUsePurpose.cfVerification, WebViewUseOutcome.cfPassed):
        // 过盾后验证页会加载站内页，Discourse 可能借此轮换了 _t；WebView
        // 若带着坏值 / 旧值去加载、被服务端删了 _t，就把 jar 的推回去。
        // 不等：对账可能正等着另一次对账的探测，而那个探测恰恰在等这次
        // 验证结束。
        _schedule(
          _sessionToken.reconcile(
            url: url,
            reason: reason,
            pushIfWebViewEmpty: true,
          ),
          reason,
        );
        return WebViewUseReport(cookies: cookies, sessionTokenScheduled: true);
      default:
        return WebViewUseReport(cookies: cookies);
    }
  }

  void _schedule(Future<SessionTokenReconcileOutcome> task, String reason) {
    unawaited(
      task.catchError((Object e) {
        debugPrint('[WebViewUse] _t 对账失败($reason): $e');
        return SessionTokenReconcileOutcome.skipped;
      }),
    );
  }

  void _logSyncProblem(
    WebViewUse use,
    WebViewUseOutcome outcome,
    WebViewCookieSyncReport report,
  ) {
    if (report.completed || report.skippedReason == 'stale_generation') return;
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_trace',
      'event': 'webview_use_sync_failed',
      'message': 'WebView 使用结束时回写 cookie 失败',
      'purpose': use.purpose.name,
      'outcome': outcome.name,
      'reason': use.reason,
      'error': report.error?.toString() ?? report.skippedReason,
    });
  }
}

/// 一段 WebView 使用：[WebViewUses.start] 开始，[end] 结束（只结束一次）。
class WebViewUse {
  WebViewUse._(
    this._owner,
    this.purpose, {
    required this.url,
    required this.reason,
    required int? generation,
  }) : _generation = generation;

  final WebViewUses _owner;
  final WebViewUsePurpose purpose;

  /// 这段使用的站点 url（准备 / 回写都针对它）。
  final String url;

  /// 日志用的触发原因。
  final String reason;

  int? _generation;
  late final Future<bool> _ready;
  bool _ended = false;

  /// 准备完成：true 成功；false 准备失败（已记日志，**仍可使用**）。
  /// 不会抛异常。
  Future<bool> get ready => _ready;

  bool get isEnded => _ended;

  /// 这段使用所属的会话代（null 表示不绑定）。
  int? get generation => _generation;

  /// 会话代变了但这段使用仍属于新会话（登录收口：先推进会话代再回写）。
  void rebindGeneration(int generation) => _generation = generation;

  /// 使用期间的阶段性回写（会话 bootstrap 前后、续期 WebView 有动静、
  /// 站内页定期对账、登录收口的中间步骤）。结束后再调用不做任何事。
  Future<WebViewUseReport> checkpoint(
    WebViewUseOutcome outcome, {
    String? reason,
    String? url,
    InAppWebViewController? controller,
  }) {
    if (_ended) {
      return Future.value(const WebViewUseReport(alreadyEnded: true));
    }
    return _apply(outcome, reason: reason, url: url, controller: controller);
  }

  /// 结束这段使用：按 [outcome] 回写并把 `_t` 交给 authority。只生效一次，
  /// 之后的调用直接返回 `alreadyEnded`。
  Future<WebViewUseReport> end(
    WebViewUseOutcome outcome, {
    String? reason,
    String? url,
    InAppWebViewController? controller,
  }) {
    if (_ended) {
      return Future.value(const WebViewUseReport(alreadyEnded: true));
    }
    _ended = true;
    return _apply(outcome, reason: reason, url: url, controller: controller);
  }

  /// CF 验证轮的定稿 cf_clearance 落 jar：只接受这一枚值（排除 WebView 里
  /// 残留的旧变体），可信写入（仍过 CfClearanceAuthority 的在位值闸门）。
  /// 轮次会读回校验、失败重试，所以这是阶段性同步而不是结束。
  Future<WebViewCookieSyncReport> landVerifiedClearance(
    String value, {
    String? url,
    InAppWebViewController? controller,
  }) {
    final spec = WebViewCookieSyncSpec(
      cookieNames: const {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': value},
    );
    return _owner._source.syncToJar(
      spec,
      url: url ?? this.url,
      controller: controller,
      generation: _generation,
    );
  }

  Future<WebViewUseReport> _apply(
    WebViewUseOutcome outcome, {
    String? reason,
    String? url,
    InAppWebViewController? controller,
  }) async {
    final effectiveReason = reason ?? this.reason;
    final effectiveUrl = url ?? this.url;
    final generation = _generation;
    if (outcome != WebViewUseOutcome.aborted &&
        generation != null &&
        !_owner._session.isValid(generation)) {
      // 这段使用属于已经过去的会话（期间登出 / 换号）：什么都不写
      return const WebViewUseReport(
        cookies: WebViewCookieSyncReport.skipped('stale_generation'),
      );
    }

    WebViewCookieSyncReport? cookies;
    final spec = WebViewUses.specFor(purpose, outcome);
    if (spec != null) {
      try {
        cookies = await _owner._source.syncToJar(
          spec,
          url: effectiveUrl,
          controller: controller,
          generation: generation,
        );
      } catch (e) {
        cookies = WebViewCookieSyncReport.failed(e);
      }
      _owner._logSyncProblem(this, outcome, cookies);
    }
    if (outcome == WebViewUseOutcome.aborted) {
      return const WebViewUseReport();
    }
    return _owner._handOffSessionToken(
      this,
      outcome,
      reason: effectiveReason,
      url: effectiveUrl,
      generation: generation,
      cookies: cookies,
    );
  }
}

/// 生产实现：WebViewCookiePriming 重灌 + Sentinel 清多变体。
class _PrimingPreparer implements WebViewCookiePreparer {
  const _PrimingPreparer();

  @override
  Future<void> prime(String url, {required bool fresh}) async {
    if (fresh) WebViewCookiePriming.instance.invalidate();
    await WebViewCookiePriming.instance.prime(url);
  }

  @override
  Future<void> sweepAll(String url) =>
      SessionCookieSentinel.instance.sweepAll(url);
}

/// 生产实现：BoundarySyncService 回写。
class _BoundarySyncSource implements WebViewCookieSource {
  const _BoundarySyncSource();

  @override
  Future<WebViewCookieSyncReport> syncToJar(
    WebViewCookieSyncSpec spec, {
    required String url,
    InAppWebViewController? controller,
    int? generation,
  }) {
    return BoundarySyncService.instance.syncFromWebView(
      currentUrl: url,
      controller: controller,
      cookieNames: spec.cookieNames,
      excludeCookieNames: spec.excludeCookieNames,
      allowLowConfidenceSessionCookies: spec.allowLowConfidenceSessionCookies,
      requestGeneration: generation,
      trusted: spec.trusted,
      acceptValues: spec.acceptValues,
    );
  }
}
