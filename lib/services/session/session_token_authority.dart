import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../../constants.dart';
import '../auth_session.dart';
import '../log/log_writer.dart';
import '../network/cookie/cookie_jar_service.dart';
import 'session_token_ports.dart';
import 'session_token_stores.dart';

export 'session_token_ports.dart';

/// 一次对账的结论。
enum SessionTokenReconcileOutcome {
  /// 两端一致（或刚刚被确认一致）。
  agreed,

  /// WebView 的值经确认有效，已采纳进 jar。
  adoptedWebView,

  /// jar 的值已重新推回 WebView 并读回确认。
  repushedJar,

  /// 探测拿不到结论（网络超时等），两端都没动。
  inconclusive,

  /// WebView 还没有 `_t`（调用方没要求推送），无分叉可言，两端都没动。
  /// 与 [skipped] 分开，让 priming 这类随后要重灌的调用方知道可以放心写。
  webViewEmpty,

  /// 本次没有做任何事（未登录 / 节流 / 会话代变化 / 等锁超时 /
  /// url 不是站点域名 / 读 WebView 失败）。
  skipped,

  /// 想采纳或推回，但写入后读回不符。
  failed,
}

/// 认证层拿到的结论。
enum SessionTokenVerdictKind {
  /// 会话有效（jar 里的值本来就有效，或已恢复出一枚有效值）。
  valid,

  /// 所有候选都被服务端明确拒绝、User API Key 也救不回：走被动登出。
  dead,

  /// 没有结论（网络 / 网关 / 撞盾 / 会话代变化）：什么都不动，交给 strike。
  inconclusive,

  /// 根本没有可判的东西（冷启动 jar 与 WebView 都没有 `_t`）：静默按未登录。
  absent,
}

/// 有效会话的来源。
enum SessionTokenSource {
  /// jar 当前的值经主探测确认有效。
  jarSession,

  /// WebView 当前的值（探测确认后可信写回 jar）。
  webView,

  /// 最近在 WebView 里见过、已被清掉的值（候选环）。
  recentWebView,

  /// 被轮换 / 替换掉的上一枚值。
  previous,

  /// User API Key 兑换的全新值。
  userApiKey,

  /// 冷启动 jar 丢值、WebView 的值探测无结论时先采纳（交给随后的检查裁决）。
  unverifiedWebView,
}

/// [SessionTokenAuthority.recover] / [SessionTokenAuthority.recoverMissingJarToken]
/// 交给认证层的结论。
class SessionTokenVerdict {
  const SessionTokenVerdict._({
    required this.kind,
    this.token,
    this.currentUser,
    this.source,
    this.networkFailure = false,
    this.staleGeneration = false,
    this.jarProbe,
    this.failedJarToken,
  });

  const SessionTokenVerdict.valid({
    required String? token,
    required SessionTokenSource source,
    Map<String, dynamic>? currentUser,
  }) : this._(
         kind: SessionTokenVerdictKind.valid,
         token: token,
         source: source,
         currentUser: currentUser,
       );

  const SessionTokenVerdict.dead({
    SessionTokenProbeResult? jarProbe,
    String? failedJarToken,
  }) : this._(
         kind: SessionTokenVerdictKind.dead,
         jarProbe: jarProbe,
         failedJarToken: failedJarToken,
       );

  const SessionTokenVerdict.inconclusive({
    String? token,
    SessionTokenSource? source,
    bool networkFailure = false,
    bool staleGeneration = false,
  }) : this._(
         kind: SessionTokenVerdictKind.inconclusive,
         token: token,
         source: source,
         networkFailure: networkFailure,
         staleGeneration: staleGeneration,
       );

  const SessionTokenVerdict.absent()
    : this._(kind: SessionTokenVerdictKind.absent);

  final SessionTokenVerdictKind kind;

  /// 结论成立后 jar 里的 `_t`（valid / 冷启动先采纳的 inconclusive）。
  final String? token;

  /// 探测拿到的 current_user（来源不同时可能为 null）。
  final Map<String, dynamic>? currentUser;
  final SessionTokenSource? source;

  /// 主探测因网络类失败没有结论（认证层据此决定 strike 是否升级）。
  final bool networkFailure;

  /// 触发信号的请求属于已经过去的会话代，什么都没做。
  final bool staleGeneration;

  /// dead 时 jar 当前值的主探测结果（日志用）。
  final SessionTokenProbeResult? jarProbe;

  /// dead 时被判死的值（日志用）。
  final String? failedJarToken;

  bool get isValid => kind == SessionTokenVerdictKind.valid;

  @override
  String toString() =>
      'SessionTokenVerdict(${kind.name}'
      '${source == null ? '' : ', ${source!.name}'}'
      '${staleGeneration ? ', stale' : ''})';
}

/// priming 对 `_t` 的处理方式。
class SessionTokenPrimingPlan {
  const SessionTokenPrimingPlan({
    required this.injectJarToken,
    required this.outcome,
  });

  /// 可以把 jar 的 `_t` 重灌进 WebView（对账有明确结论）；
  /// false 时这一轮不碰 WebView 的 `_t`。
  final bool injectJarToken;

  /// 对账结论（日志用；超时 / 异常为 null）。
  final SessionTokenReconcileOutcome? outcome;
}

/// Sentinel 收敛 WebView 里多枚 `_t` 时保留哪一枚。
class SessionTokenVariantChoice {
  const SessionTokenVariantChoice._({
    required this.keepJarValue,
    required this.needsReconcile,
  });

  /// 保留 jar 的值（WebView 那一枚不可能更新：与 jar 相同 / 是两端此前已
  /// 一致、之后 jar 才往前走的旧值 / 刚被服务端明确拒绝）。
  const SessionTokenVariantChoice.keepJar()
    : this._(keepJarValue: true, needsReconcile: false);

  /// 保留 WebView 的值、jar 不动。[needsReconcile] 为 true 时由服务端探测
  /// 决定最终谁对（收敛完之后再对账，不在 Sentinel 的锁里探测）。
  const SessionTokenVariantChoice.keepWebView({required bool needsReconcile})
    : this._(keepJarValue: false, needsReconcile: needsReconcile);

  final bool keepJarValue;
  final bool needsReconcile;
}

/// `_t`（Discourse 登录会话 token）的唯一真相来源。
///
/// 背景：Discourse 约每 10 分钟轮换一次 `_t`，同时接受当前值和上一枚值。
/// App 里有两份存储——Dio 的 CookieJar 和 WebView 的 CookieManager，各自都
/// 可能收到轮换。只要两边分叉超过轮换窗口，其中一边手里的值就会被服务端
/// 判死：带着它的请求在 2xx 响应里被静默删 `_t`，App 无征兆地变成匿名。
///
/// 这里收拢了原先散在 8 个模块里的 `_t` 状态与规则：
/// - 血缘：两端最后一次确认一致的值（[markAgreed]）；
/// - 候选池：最近在 WebView 里见过的值（环）+ 被替换掉的上一枚值；
/// - 被服务端明确拒绝的候选冷却；
/// - 唯一的 winner 规则（[reconcile]）：服务端探测决定；探测无结论时两端
///   都不动；jar / WebView 只在探测不可用或无需探测的情形下按血缘决胜；
/// - 恢复链（[recover]）：WebView 当前值 → 候选环 → jar 主探测 → 上一枚值
///   → User API Key，都不行才判死；
/// - 冷启动 jar 丢值（[recoverMissingJarToken]）；
/// - 所有可信写入 jar 都带过期时间（WebView 自带的 → jar 原值的 → 60 天）。
///
/// Sentinel / Priming / Nuclear Reset / 会话自愈 / BrowserTrust / WebView 会话
/// 刷新只报告看到了什么、按这里的结论动手，不再自己判 `_t` 谁赢。
class SessionTokenAuthority {
  SessionTokenAuthority({
    required SessionTokenJarStore jar,
    required SessionTokenWebViewStore webView,
    AuthSession? session,
    DateTime Function()? clock,
  }) : _jar = jar,
       _webView = webView,
       _session = session ?? AuthSession(),
       _now = clock ?? DateTime.now;

  static final SessionTokenAuthority instance = SessionTokenAuthority(
    jar: CookieJarSessionTokenStore(),
    webView: WebViewSessionTokenStore(),
  );

  static const String cookieName = '_t';
  static const Duration _noDiffThrottle = Duration(seconds: 2);
  static const Duration _probeTimeout = Duration(seconds: 8);
  static const Duration _webViewCandidateTtl = Duration(minutes: 20);
  static const int _maxWebViewCandidates = 4;
  static const Duration _previousTokenTtl = Duration(minutes: 15);
  static const Duration rejectedCandidateCooldown = Duration(minutes: 5);
  static const int _maxRecoveryCandidates = 3;
  static const Duration _primingReconcileTimeout = Duration(seconds: 10);

  final SessionTokenJarStore _jar;
  final SessionTokenWebViewStore _webView;
  final AuthSession _session;
  final DateTime Function() _now;

  SessionTokenProbe? _probe;
  SessionTokenUserApiKey? _userApiKey;
  SessionTokenAuthListener? _listener;

  /// 两端最后一次确认一致的 `_t`。只放内存，不落盘。
  String? _agreed;

  /// 最近在 WebView 里见过、但与 jar 不同的 `_t`（新的在前）。
  final List<_SeenCandidate> _webViewCandidates = [];

  /// 被轮换 / 替换掉的上一枚 `_t`（服务端在轮换窗口内仍接受它）。
  String? _previous;
  DateTime? _previousAt;

  /// 最近一次被服务端明确拒绝的候选（只记哈希）。
  String? _rejectedHash;
  DateTime? _rejectedAt;

  final Lock _lock = Lock();
  String? _lastNoDiffSignature;
  DateTime? _lastNoDiffAt;

  // ---------------------------------------------------------------------------
  // 接线
  // ---------------------------------------------------------------------------

  /// 认证层接入：服务端探测、User API Key 自愈、回调。
  ///
  /// 由 DiscourseService 构造时调用。没接入时 [reconcile] 只按血缘处理
  /// （不会采纳任何需要探测的值），[recover] 一律无结论。
  void attachAuth({
    required SessionTokenProbe probe,
    required SessionTokenUserApiKey userApiKey,
    required SessionTokenAuthListener listener,
  }) {
    _probe = probe;
    _userApiKey = userApiKey;
    _listener = listener;
  }

  /// 是否已有服务端探测可用。
  bool get hasProbe => _probe != null;

  /// 仅测试用：清空全部状态与接线。
  @visibleForTesting
  void resetForTest() {
    _probe = null;
    _userApiKey = null;
    _listener = null;
    _rejectedHash = null;
    _rejectedAt = null;
    resetLineage();
  }

  // ---------------------------------------------------------------------------
  // 血缘与候选池
  // ---------------------------------------------------------------------------

  /// 两端最后一次一致值的脱敏哈希（仅用于日志/诊断）。
  String? get lastAgreedHash => tokenHash(_agreed);

  /// 仅测试用：两端最后一次一致的值。
  @visibleForTesting
  String? get agreedValueForTest => _agreed;

  /// 标记某个值已在两端一致。只有确认两端都持有它（写进 WebView 并读回、
  /// 或从 WebView 采纳进 jar 并读回）之后才能调用。
  void markAgreed(String? value) {
    if (!_has(value)) return;
    _agreed = value;
    _webViewCandidates.removeWhere((c) => c.value == value);
  }

  /// 登录 / 登出：新会话的 `_t` 与旧血缘无关，清掉一致记录、候选环与
  /// 上一枚值（被拒冷却保留：它只针对具体的值）。
  void resetLineage() {
    _agreed = null;
    _webViewCandidates.clear();
    _previous = null;
    _previousAt = null;
    _lastNoDiffSignature = null;
    _lastNoDiffAt = null;
  }

  /// 记下在 WebView 里见到的 `_t`（Sentinel 清多变体 / Nuclear Reset 前）。
  /// 与已一致的值相同的不记。
  void noteWebViewValues(Iterable<String?> values) {
    for (final value in values) {
      _noteWebViewCandidate(value);
    }
  }

  void _noteWebViewCandidate(String? value) {
    if (!_has(value) || value == _agreed) return;
    _webViewCandidates.removeWhere((c) => c.value == value);
    _webViewCandidates.insert(0, _SeenCandidate(value!, _now()));
    _pruneWebViewCandidates();
  }

  /// 最近见过的 WebView `_t` 候选（新的在前，已过期的不返回）。
  List<String> recentWebViewCandidates({Iterable<String?> exclude = const []}) {
    _pruneWebViewCandidates();
    final excluded = exclude.whereType<String>().toSet();
    return _webViewCandidates
        .map((c) => c.value)
        .where((v) => !excluded.contains(v))
        .toList(growable: false);
  }

  void _pruneWebViewCandidates() {
    final now = _now();
    _webViewCandidates.removeWhere(
      (c) => now.difference(c.seenAt) > _webViewCandidateTtl,
    );
    if (_webViewCandidates.length > _maxWebViewCandidates) {
      _webViewCandidates.removeRange(
        _maxWebViewCandidates,
        _webViewCandidates.length,
      );
    }
  }

  /// 恢复链手里的全部候选（环在前、上一枚值在后），诊断与测试用。
  List<String> recoveryCandidates() {
    final ring = recentWebViewCandidates();
    final previous = _readPrevious();
    return [
      ...ring,
      if (previous != null && !ring.contains(previous)) previous,
    ];
  }

  /// 记下被替换掉的上一枚 `_t`（Dio 响应轮换、请求前发现 jar 变了等）。
  void notePreviousToken(
    String? token, {
    required String reason,
    String? replacement,
    RequestOptions? requestOptions,
  }) {
    if (!_has(token) || token == replacement) return;
    _previous = token;
    _previousAt = _now();

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'previous_t_token_fallback_stored',
      'message': '已临时保存上一枚 _t，供登录失效 probe 回退使用',
      'reason': reason,
      'previousTLen': _len(token),
      'previousTHash': tokenHash(token),
      'replacementTLen': _len(replacement),
      'replacementTHash': tokenHash(replacement),
      if (requestOptions != null) 'method': requestOptions.method,
      if (requestOptions != null) 'url': requestOptions.uri.toString(),
    });
  }

  String? _readPrevious({String? sentToken, String? jarToken}) {
    final token = _previous;
    final storedAt = _previousAt;
    if (!_has(token) || storedAt == null) return null;
    if (_now().difference(storedAt) > _previousTokenTtl) {
      _clearPrevious();
      return null;
    }
    if (token == sentToken || token == jarToken) return null;
    return token;
  }

  void _clearPrevious() {
    _previous = null;
    _previousAt = null;
  }

  /// 该值是否刚被服务端明确拒绝（冷却期内不再探测、不再采纳）。
  bool isRejectedInCooldown(String? token) {
    final hash = tokenHash(token);
    final rejectedAt = _rejectedAt;
    if (hash == null || rejectedAt == null || hash != _rejectedHash) {
      return false;
    }
    return _now().difference(rejectedAt) <= rejectedCandidateCooldown;
  }

  void _markRejected(String? token) {
    final hash = tokenHash(token);
    if (hash == null) return;
    _rejectedHash = hash;
    _rejectedAt = _now();
  }

  void _clearRejected() {
    _rejectedHash = null;
    _rejectedAt = null;
  }

  // ---------------------------------------------------------------------------
  // 唯一的 winner 规则：对账
  // ---------------------------------------------------------------------------

  /// 对账 jar 与 WebView 的 `_t`。
  ///
  /// 决策（血缘规则）：
  /// - 两端相同 → 标记一致；
  /// - WebView 没动、jar 动了（jar 刚收到轮换 / 恢复写入）→ 把 jar 的推回，
  ///   不探测：上一枚值在轮换窗口内仍被接受，不代表它比 jar 新；
  /// - 其余情况 → 以 WebView 的值探测服务端：有效采纳进 jar，被拒推回 jar
  ///   的值，**无结论两端都不动**。
  ///
  /// [url] 只用来判断是否站点域名（站外 WebView 直接跳过）。
  /// [webViewVerified] 表示调用方刚拿到服务端对 WebView 会话的肯定答复，
  /// WebView 的新值无需再探测即可采纳。[allowProbe] 为 false 时不探测
  /// （正要过 CF 盾，探测请求自己也会被拦）：只按血缘能判定方向的才动手。
  /// [pushIfWebViewEmpty] 为 true 时 WebView 没有 `_t` 就把 jar 的推过去。
  /// [lockTimeout] 限定等待前一次对账的时长，超时按跳过处理。
  Future<SessionTokenReconcileOutcome> reconcile({
    String? url,
    required String reason,
    int? requestGeneration,
    bool webViewVerified = false,
    bool allowProbe = true,
    bool pushIfWebViewEmpty = false,
    Duration? lockTimeout,
  }) async {
    if (url != null && !_isSiteUrl(url)) {
      return SessionTokenReconcileOutcome.skipped;
    }
    if (!_jar.isReady) return SessionTokenReconcileOutcome.skipped;
    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return SessionTokenReconcileOutcome.skipped;
    }

    try {
      return await _lock.synchronized(
        () => _reconcileLocked(
          reason: reason,
          requestGeneration: requestGeneration,
          webViewVerified: webViewVerified,
          allowProbe: allowProbe,
          pushIfWebViewEmpty: pushIfWebViewEmpty,
        ),
        timeout: lockTimeout,
      );
    } on TimeoutException {
      debugPrint('[SessionToken] reconcile($reason) 等锁超时，跳过');
      return SessionTokenReconcileOutcome.skipped;
    } catch (e) {
      debugPrint('[SessionToken] reconcile($reason) 异常: $e');
      return SessionTokenReconcileOutcome.skipped;
    }
  }

  Future<SessionTokenReconcileOutcome> _reconcileLocked({
    required String reason,
    required int? requestGeneration,
    required bool webViewVerified,
    required bool allowProbe,
    required bool pushIfWebViewEmpty,
  }) async {
    final stopwatch = Stopwatch()..start();
    final entryGen = _session.generation;
    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return SessionTokenReconcileOutcome.skipped;
    }

    final jarValue = await _jar.read();
    if (jarValue == null || jarValue.isEmpty) {
      // 未登录 / 已登出 / jar 丢值：不采纳任何东西。冷启动 jar 丢值由
      // recoverMissingJarToken 带探测处理。
      return SessionTokenReconcileOutcome.skipped;
    }

    String? webViewValue;
    try {
      webViewValue = await _webView.read();
    } catch (e) {
      debugPrint('[SessionToken] 读取 WebView _t 失败($reason): $e');
      return SessionTokenReconcileOutcome.skipped;
    }
    if (webViewValue == null || webViewValue.isEmpty) {
      if (!pushIfWebViewEmpty) {
        // WebView 还没灌过 cookie（priming 会补），没有分叉可言。
        return SessionTokenReconcileOutcome.webViewEmpty;
      }
      final pushed = await _pushToWebView(
        jarValue,
        reason: 'lineage_${reason}_empty',
      );
      _logReconcile(
        result: pushed ? 'pushed_to_empty_webview' : 'push_empty_failed',
        reason: reason,
        jarValue: jarValue,
        webViewValue: '',
        agreed: _agreed,
        probe: null,
        requestGeneration: requestGeneration,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return pushed
          ? SessionTokenReconcileOutcome.repushedJar
          : SessionTokenReconcileOutcome.failed;
    }

    if (webViewValue == jarValue) {
      markAgreed(jarValue);
      return SessionTokenReconcileOutcome.agreed;
    }

    // 分叉。先把 WebView 的值记进候选环，后续登出恢复可用。
    _noteWebViewCandidate(webViewValue);

    final signature = '${tokenHash(jarValue)}|${tokenHash(webViewValue)}';
    final lastAt = _lastNoDiffAt;
    if (_lastNoDiffSignature == signature &&
        lastAt != null &&
        _now().difference(lastAt) < _noDiffThrottle) {
      return SessionTokenReconcileOutcome.skipped;
    }
    _lastNoDiffSignature = signature;
    _lastNoDiffAt = _now();

    final agreed = _agreed;
    final jarMoved = agreed != null && jarValue != agreed;
    final webViewMoved = agreed != null && webViewValue != agreed;
    final hasLineage = agreed != null;

    bool? probeResult;
    var adoptWebView = false;
    // WebView 没动、jar 动了 → 推回，不探测（见方法注释）。
    final repushByLineage = hasLineage && jarMoved && !webViewMoved;
    if (!repushByLineage) {
      if (webViewVerified) {
        adoptWebView = true;
      } else if (!allowProbe || _probe == null) {
        // 不能探测时只按血缘走：jar 自上次一致后没动、WebView 动了，
        // WebView 的值只可能来自服务端 Set-Cookie（我们自己的推送都会
        // 标记一致），可以直接采纳；没有血缘则无从判断，记无结论。
        if (hasLineage && !jarMoved && webViewMoved) {
          adoptWebView = true;
        } else {
          _logReconcile(
            result: 'inconclusive',
            reason: reason,
            jarValue: jarValue,
            webViewValue: webViewValue,
            agreed: agreed,
            probe: null,
            requestGeneration: requestGeneration,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          return SessionTokenReconcileOutcome.inconclusive;
        }
      } else {
        probeResult = await _probeForReconcile(
          webViewValue,
          requestGeneration: requestGeneration,
          reason: reason,
        );
        if (probeResult == null) {
          _logReconcile(
            result: 'inconclusive',
            reason: reason,
            jarValue: jarValue,
            webViewValue: webViewValue,
            agreed: agreed,
            probe: probeResult,
            requestGeneration: requestGeneration,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          return SessionTokenReconcileOutcome.inconclusive;
        }
        adoptWebView = probeResult;
      }
    }

    if (!_session.isValid(entryGen) ||
        (requestGeneration != null && !_session.isValid(requestGeneration))) {
      return SessionTokenReconcileOutcome.skipped;
    }

    // 探测期间 jar 可能已被别的路径改掉，重新核对。
    final jarNow = await _jar.read();
    if (jarNow != jarValue) {
      if (jarNow == webViewValue) {
        markAgreed(webViewValue);
        return SessionTokenReconcileOutcome.agreed;
      }
      _logReconcile(
        result: 'raced',
        reason: reason,
        jarValue: jarValue,
        webViewValue: webViewValue,
        agreed: agreed,
        probe: probeResult,
        requestGeneration: requestGeneration,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return SessionTokenReconcileOutcome.skipped;
    }

    if (adoptWebView) {
      // 带上 WebView 里这枚值自己的过期时间（jar 只落盘带过期时间的 cookie）。
      DateTime? webViewExpires;
      try {
        webViewExpires = await _webView.readExpiry(webViewValue);
      } catch (e) {
        debugPrint('[SessionToken] 读取 WebView _t 过期时间失败($reason): $e');
      }
      final ok = await _writeJarTrusted(
        webViewValue,
        candidateExpires: webViewExpires,
      );
      if (ok) {
        markAgreed(webViewValue);
        // 被替换掉的 jar 旧值留作上一枚候选（轮换窗口内服务端仍接受）。
        notePreviousToken(
          jarValue,
          reason: 'lineage_adopt_webview',
          replacement: webViewValue,
        );
        _listener?.onTokenReplaced(webViewValue);
      }
      _logReconcile(
        result: ok ? 'adopted_webview' : 'adopt_failed',
        reason: reason,
        jarValue: jarValue,
        webViewValue: webViewValue,
        agreed: agreed,
        probe: probeResult,
        webViewVerified: webViewVerified,
        requestGeneration: requestGeneration,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return ok
          ? SessionTokenReconcileOutcome.adoptedWebView
          : SessionTokenReconcileOutcome.failed;
    }

    final pushed = await _pushToWebView(
      jarValue,
      reason: 'lineage_$reason',
      clearVariantsFirst: true,
    );
    _logReconcile(
      result: pushed ? 'repushed_jar' : 'repush_failed',
      reason: reason,
      jarValue: jarValue,
      webViewValue: webViewValue,
      agreed: agreed,
      probe: probeResult,
      webViewVerified: webViewVerified,
      requestGeneration: requestGeneration,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
    return pushed
        ? SessionTokenReconcileOutcome.repushedJar
        : SessionTokenReconcileOutcome.failed;
  }

  /// 对账用的探测：true/false 是服务端的明确答复，null 是没结论。
  /// 冷却期内的候选直接按拒绝处理、不再打扰服务端。
  Future<bool?> _probeForReconcile(
    String candidate, {
    required int? requestGeneration,
    required String reason,
  }) async {
    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return null;
    }
    if (isRejectedInCooldown(candidate)) return false;
    final probe = _probe;
    if (probe == null) return null;
    SessionTokenProbeResult result;
    try {
      result = await probe
          .probeCandidate(candidate, requestGeneration: requestGeneration)
          .timeout(_probeTimeout);
    } on TimeoutException {
      return null;
    } catch (e) {
      debugPrint('[SessionToken] 探测异常($reason): $e');
      return null;
    }
    if (result.isValid) {
      _clearRejected();
      return true;
    }
    if (!result.isConclusive) return null;
    _markRejected(candidate);
    return false;
  }

  // ---------------------------------------------------------------------------
  // 各路观察者的入口
  // ---------------------------------------------------------------------------

  /// priming 前问：这一轮能否把 jar 的 `_t` 重灌进 WebView。
  ///
  /// 先对账：WebView 的值经确认有效就先采纳进 jar 再重灌。只有对账给出明确
  /// 结论（两端一致 / 已采纳 / 已推回 / WebView 本来就没有）才重灌 `_t`；
  /// 无结论（探测撞上网关 502、超时、等锁超时、读 WebView 失败）时这一轮不碰
  /// WebView 的 `_t`：它可能正是唯一还活着的那枚，覆盖掉就两边全死。
  Future<SessionTokenPrimingPlan> planPriming(String url) async {
    SessionTokenReconcileOutcome? outcome;
    try {
      outcome = await reconcile(
        url: url,
        reason: 'webview_priming',
      ).timeout(_primingReconcileTimeout);
    } catch (e) {
      debugPrint('[SessionToken] priming 前对账跳过: $e');
    }
    final inject = switch (outcome) {
      SessionTokenReconcileOutcome.agreed ||
      SessionTokenReconcileOutcome.adoptedWebView ||
      SessionTokenReconcileOutcome.repushedJar ||
      SessionTokenReconcileOutcome.webViewEmpty => true,
      _ => false,
    };
    return SessionTokenPrimingPlan(injectJarToken: inject, outcome: outcome);
  }

  /// 登录收口：WebView 里是刚登录的新会话，把它的 `_t` 可信写进 jar。
  ///
  /// 除冷启动 jar 丢值的恢复外，这是唯一不经探测就把 WebView 的 `_t` 写进
  /// jar 的地方：登录成功本身就是服务端对这枚值的认可（以前由各登录入口经
  /// BoundarySync 的 includeSessionToken 写，有的可信有的不可信）。
  /// 新会话与旧血缘无关——先清血缘，写入
  /// （带过期时间：WebView 自带的 → jar 原值的 → 60 天）读回一致后标记两端
  /// 一致。[generation] 是登录流程的会话代，已过期（期间登出 / 再次登录）
  /// 就什么都不写。返回是否写入成功。
  Future<bool> adoptLoginToken({
    required String reason,
    int? generation,
  }) async {
    if (!_jar.isReady) return false;
    if (generation != null && !_session.isValid(generation)) return false;

    String? value;
    DateTime? expires;
    try {
      value = await _webView.read();
      if (value != null && value.isNotEmpty) {
        expires = await _webView.readExpiry(value);
      }
    } catch (e) {
      debugPrint('[SessionToken] 登录收口读取 WebView _t 失败($reason): $e');
      value = null;
    }
    if (value == null || value.isEmpty) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'login_session_token_missing',
        'message': '登录收口时 WebView 里没有 _t',
        'reason': reason,
      });
      return false;
    }
    if (generation != null && !_session.isValid(generation)) return false;

    final before = await _readJarSafely();
    resetLineage();
    final ok = await _writeJarTrusted(value, candidateExpires: expires);
    if (ok) markAgreed(value);
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': ok ? 'info' : 'warning',
      'type': 'auth',
      'event': ok
          ? 'login_session_token_adopted'
          : 'login_session_token_write_failed',
      'message': ok ? '登录收口：WebView 的新 _t 已可信写进 jar' : '登录收口：新 _t 写入 jar 后读回不符',
      'reason': reason,
      'tLen': _len(value),
      'tHash': tokenHash(value),
      'replacedJarTHash': tokenHash(before),
      'hasWebViewExpiry': expires != null,
    });
    return ok;
  }

  /// Dio（路径 A）收到服务端新发的 `_t` 并已写进 jar：推进 WebView、读回
  /// 确认后两端一致。推不进去时保持原血缘（下次对账会把 jar 的推回去，
  /// 而不是把 WebView 里的旧值当成「WebView 往前走了」）。
  Future<bool> onServerIssuedToken({
    required String value,
    String? rawSetCookie,
    String? url,
  }) async {
    if (!_has(value)) return false;
    bool ok;
    try {
      ok = await _webView.write(
        value,
        reason: 'dio_response',
        url: url,
        rawSetCookie: rawSetCookie,
      );
    } catch (e) {
      debugPrint('[SessionToken] 推送服务端新发的 _t 失败: $e');
      ok = false;
    }
    if (ok) markAgreed(value);
    return ok;
  }

  /// Sentinel 收敛 WebView 里多枚 `_t` 时保留哪一枚（不探测、不加锁：
  /// Sentinel 持有 per-name 锁时不能等网络，也不能反过来等对账锁）。
  ///
  /// [webViewBest] 是按会话 cookie 选优规则排第一的那枚。WebView 那一枚
  /// 只有在「不可能比 jar 新」时才让 jar 赢；否则 WebView 留着自己的值、
  /// jar 不动，收敛后再对账交服务端探测决定（以前这里一律 jar 赢，会把
  /// WebView 刚轮换到的活值抹成 jar 里的旧值）。
  SessionTokenVariantChoice chooseVariantToKeep({
    required String? jarValue,
    required String webViewBest,
  }) {
    if (jarValue == null || jarValue.isEmpty) {
      // jar 没有 _t：不采纳任何东西，WebView 留它自己的值（只去重）。
      return const SessionTokenVariantChoice.keepWebView(needsReconcile: false);
    }
    if (_cannotBeNewerThanJar(webViewBest, jarValue)) {
      return const SessionTokenVariantChoice.keepJar();
    }
    return const SessionTokenVariantChoice.keepWebView(needsReconcile: true);
  }

  /// Nuclear Reset 能否清掉 WebView 的 `_t` 再用 jar 的重灌（不探测、不加锁）。
  ///
  /// 只有 WebView 里每一枚 `_t` 都「不可能比 jar 新」（WebView 没有 `_t` 也算）
  /// 才放行；否则这一轮不动 `_t`，由随后的对账交服务端探测决定。jar 没有
  /// `_t` 时也不动（不能把 WebView 里可能唯一活着的那枚清掉）。
  bool mayOverwriteWebViewToken({
    required String? jarValue,
    required Iterable<String?> webViewValues,
  }) {
    if (jarValue == null || jarValue.isEmpty) return false;
    for (final value in webViewValues) {
      if (value == null || value.isEmpty) continue;
      if (!_cannotBeNewerThanJar(value, jarValue)) return false;
    }
    return true;
  }

  /// 无需探测就能确定 WebView 的值不比 jar 新：与 jar 相同；是两端此前已
  /// 一致、之后 jar 才往前走的旧值（血缘）；或刚被服务端明确拒绝。
  bool _cannotBeNewerThanJar(String webViewValue, String jarValue) {
    if (webViewValue == jarValue) return true;
    final agreed = _agreed;
    if (agreed != null && jarValue != agreed && webViewValue == agreed) {
      return true;
    }
    return isRejectedInCooldown(webViewValue);
  }

  /// AppCookieManager 拦下了 2xx 响应里静默删 `_t` 的指令（jar 不动）。
  ///
  /// Discourse 的 `refresh_session` 只在「请求带了 `_t` 却找不到用户」时这么
  /// 做，等价于「你手里这枚 token 已死」。请求确实带了 `_t` 时请认证层按强
  /// 信号走一次 probe：jar 的值若真死，恢复链会依次试 WebView 候选、上一枚
  /// 值、User API Key，都不行才登出；若只是 jar 落后于 WebView，恢复链顺手
  /// 就把活值捞回来。
  void onServerDeletedToken(RequestOptions requestOptions, int? statusCode) {
    if (!_has(sentTokenFromRequest(requestOptions))) return;
    final listener = _listener;
    if (listener == null) return;
    try {
      listener.onDeletionDeferred(requestOptions, statusCode);
    } catch (e) {
      debugPrint('[SessionToken] _t 删除回调异常: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 恢复链
  // ---------------------------------------------------------------------------

  /// 收到 auth 信号（或启动登录态检查被拒）后的恢复链，给认证层一个结论。
  ///
  /// 顺序：WebView 当前值 / 候选环（仅当触发请求带了 `_t`）→ jar 主探测 →
  /// 上一枚值 → User API Key。只有服务端明确拒绝才往下走；主探测无结论
  /// 立即返回 inconclusive（什么都不动）。
  Future<SessionTokenVerdict> recover({
    required String source,
    String? triggerInfo,
    RequestOptions? signalRequestOptions,
  }) async {
    final requestGeneration = _generationOf(signalRequestOptions);
    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return const SessionTokenVerdict.inconclusive(staleGeneration: true);
    }
    final probe = _probe;
    if (probe == null) {
      return const SessionTokenVerdict.inconclusive();
    }

    final fromWebView = await _recoverFromWebViewCandidates(
      source: source,
      triggerInfo: triggerInfo,
      signalRequestOptions: signalRequestOptions,
      requestGeneration: requestGeneration,
    );
    if (fromWebView != null) return fromWebView;

    final failedJarToken = await _readJarSafely();
    SessionTokenProbeResult jarProbe;
    try {
      jarProbe = await probe.probeJarSession(
        source: source,
        triggerInfo: triggerInfo,
        requestGeneration: requestGeneration,
      );
    } catch (e) {
      debugPrint('[SessionToken] 主探测异常: $e');
      jarProbe = const SessionTokenProbeResult.inconclusive();
    }
    if (jarProbe.isValid) {
      _clearPrevious();
      final live = await _readJarSafely();
      return SessionTokenVerdict.valid(
        token: _has(live) ? live : failedJarToken,
        source: SessionTokenSource.jarSession,
        currentUser: jarProbe.currentUser,
      );
    }
    if (!jarProbe.isConclusive) {
      return SessionTokenVerdict.inconclusive(
        networkFailure: jarProbe.networkFailure,
      );
    }

    final fromPrevious = await _recoverFromPrevious(
      source: source,
      triggerInfo: triggerInfo,
      signalRequestOptions: signalRequestOptions,
      requestGeneration: requestGeneration,
      failedJarToken: failedJarToken,
    );
    if (fromPrevious != null) return fromPrevious;

    final healed = await _healWithUserApiKey(
      source: source,
      triggerInfo: triggerInfo,
    );
    if (healed != null) return healed;

    return SessionTokenVerdict.dead(
      jarProbe: jarProbe,
      failedJarToken: failedJarToken,
    );
  }

  /// 恢复链第一级：jar 的值可能只是落后于 WebView。WebView 当前值优先，
  /// 其后是候选环里最近见过的值（合计最多 3 枚），逐个单独探测，服务端确认
  /// 有效才可信写回 jar。
  Future<SessionTokenVerdict?> _recoverFromWebViewCandidates({
    required String source,
    required String? triggerInfo,
    required RequestOptions? signalRequestOptions,
    required int? requestGeneration,
  }) async {
    final sentToken = signalRequestOptions == null
        ? null
        : sentTokenFromRequest(signalRequestOptions);
    if (!_has(sentToken)) return null;
    final probe = _probe;
    if (probe == null) return null;

    final beforeJar = await _readJarSafely();
    String? live;
    try {
      live = await _webView.read();
    } catch (e) {
      debugPrint('[SessionToken] probe 前读取 WebView session 失败: $e');
      live = null;
    }

    final liveUsable =
        _has(live) &&
        live != beforeJar &&
        live != sentToken &&
        !isRejectedInCooldown(live);

    // 候选顺序：WebView 当前值优先，其后是环里最近见过的值。
    final candidates = <String>[if (liveUsable) live!];
    for (final ring in recentWebViewCandidates(
      exclude: [beforeJar, sentToken, live],
    )) {
      if (candidates.length >= _maxRecoveryCandidates) break;
      if (isRejectedInCooldown(ring)) continue;
      candidates.add(ring);
    }
    if (candidates.isEmpty) return null;

    String? forumSession;
    if (liveUsable) {
      try {
        forumSession = await _webView.readForumSession();
      } catch (e) {
        debugPrint('[SessionToken] probe 前读取 WebView _forum_session 失败: $e');
      }
    }

    String? accepted;
    Map<String, dynamic>? acceptedUser;
    var acceptedIsLive = false;
    var rejected = 0;
    var inconclusive = 0;
    for (final candidate in candidates) {
      final isLive = liveUsable && candidate == live;
      SessionTokenProbeResult result;
      try {
        result = await probe.probeCandidate(
          candidate,
          forumSession: isLive && _has(forumSession) ? forumSession : null,
          requestGeneration: requestGeneration,
        );
      } catch (e) {
        debugPrint('[SessionToken] 候选探测异常: $e');
        result = const SessionTokenProbeResult.inconclusive();
      }
      if (result.isValid) {
        accepted = candidate;
        acceptedUser = result.currentUser;
        acceptedIsLive = isLive;
        break;
      }
      if (result.isConclusive) {
        rejected++;
        _markRejected(candidate);
      } else {
        // 网关错误 / 网络异常 / 撞盾：不是服务端拒绝，不打入冷却，
        // 下一次信号再试。
        inconclusive++;
      }
    }
    if (accepted == null) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_probe_session_candidates_exhausted',
        'message': 'probe 前的 WebView/血缘候选都没能确认有效',
        'source': source,
        'trigger': ?triggerInfo,
        'candidatesTried': candidates.length,
        'rejected': rejected,
        'inconclusive': inconclusive,
        'liveUsable': liveUsable,
      });
      return null;
    }
    _clearRejected();

    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return null;
    }

    // WebView 当前值带上它自己的过期时间；环里的候选只有值，由 jar 原值 /
    // 60 天兜底。都走可信写入，否则 jar 里版本号更高的旧值会让写入被丢弃。
    DateTime? candidateExpires;
    if (acceptedIsLive) {
      try {
        candidateExpires = await _webView.readExpiry(accepted);
      } catch (e) {
        debugPrint('[SessionToken] 读取 WebView _t 过期时间失败: $e');
      }
    }
    final ok = await _writeJarTrusted(
      accepted,
      candidateExpires: candidateExpires,
    );
    if (!ok) {
      final afterJar = await _readJarSafely();
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_probe_session_cookie_recover_write_failed',
        'message': '已验证的候选 _t 写入 CookieJar 后读回不符，放弃恢复',
        'source': source,
        'candidateIsLive': acceptedIsLive,
        'candidateTLen': _len(accepted),
        'candidateTHash': tokenHash(accepted),
        'afterJarTLen': _len(afterJar),
        'afterJarTHash': tokenHash(afterJar),
      });
      return null;
    }
    if (acceptedIsLive && _has(forumSession)) {
      try {
        await _jar.adoptForumSessionFromWebView(
          forumSession!,
          requestGeneration: requestGeneration,
        );
      } catch (e) {
        debugPrint('[SessionToken] 采纳 WebView _forum_session 失败: $e');
      }
    }

    notePreviousToken(
      beforeJar,
      reason: 'webview_session_recovered',
      replacement: accepted,
      requestOptions: signalRequestOptions,
    );
    if (acceptedIsLive) {
      // WebView 本来就持有这枚值，现在 jar 也有了：两端一致。
      markAgreed(accepted);
    } else {
      // 来自候选环：WebView 当前值已不是它，推回去让两端收敛。
      unawaited(
        _pushToWebView(
          accepted,
          reason: 'auth_recover_ring_candidate',
          clearVariantsFirst: true,
        ),
      );
    }
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_probe_session_cookie_recovered',
      'message': acceptedIsLive
          ? 'probe 前从 WebView 恢复了不同的 session cookie'
          : 'probe 前用最近在 WebView 见过的 _t 恢复了 session cookie',
      'source': source,
      'trigger': ?triggerInfo,
      'candidateIsLive': acceptedIsLive,
      'candidatesTried': candidates.length,
      'sentTLen': _len(sentToken),
      'sentTHash': tokenHash(sentToken),
      'beforeJarTLen': _len(beforeJar),
      'beforeJarTHash': tokenHash(beforeJar),
      'afterJarTLen': _len(accepted),
      'afterJarTHash': tokenHash(accepted),
      'afterMatchesSentT': accepted == sentToken,
      'requestGeneration': ?requestGeneration,
    });
    return SessionTokenVerdict.valid(
      token: accepted,
      source: acceptedIsLive
          ? SessionTokenSource.webView
          : SessionTokenSource.recentWebView,
      currentUser: acceptedUser,
    );
  }

  /// 恢复链第三级：被轮换 / 替换掉的上一枚值（服务端轮换窗口内仍接受）。
  Future<SessionTokenVerdict?> _recoverFromPrevious({
    required String source,
    required String? triggerInfo,
    required RequestOptions? signalRequestOptions,
    required int? requestGeneration,
    required String? failedJarToken,
  }) async {
    final sentToken = signalRequestOptions == null
        ? null
        : sentTokenFromRequest(signalRequestOptions);
    final candidate = _readPrevious(
      sentToken: sentToken,
      jarToken: failedJarToken,
    );
    if (candidate == null) return null;
    final probe = _probe;
    if (probe == null) return null;
    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return null;
    }
    if (isRejectedInCooldown(candidate)) return null;

    SessionTokenProbeResult result;
    try {
      result = await probe.probeCandidate(
        candidate,
        requestGeneration: requestGeneration,
      );
    } catch (e) {
      debugPrint('[SessionToken] 上一枚 _t 探测异常: $e');
      result = const SessionTokenProbeResult.inconclusive();
    }
    if (!result.isValid) {
      // 只有服务端明确拒绝才打入冷却；网关/网络无结论时留给下次再试。
      if (result.isConclusive) _markRejected(candidate);
      return null;
    }
    _clearRejected();

    if (requestGeneration != null && !_session.isValid(requestGeneration)) {
      return null;
    }

    // 上一枚值只有值没有过期时间，由 jar 原值 / 60 天兜底（否则不落盘）。
    final ok = await _writeJarTrusted(candidate);
    if (!ok) return null;

    _clearPrevious();
    // WebView 里多半还是那枚已死的值，推回去让两端收敛（读回校验、失败记日志）。
    unawaited(
      _pushToWebView(
        candidate,
        reason: 'auth_recover_previous_t',
        clearVariantsFirst: true,
      ),
    );
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_probe_previous_session_cookie_recovered',
      'message': '登录失效前用上一枚 _t 候选恢复了 session cookie',
      'source': source,
      'trigger': ?triggerInfo,
      'sentTLen': _len(sentToken),
      'sentTHash': tokenHash(sentToken),
      'failedJarTLen': _len(failedJarToken),
      'failedJarTHash': tokenHash(failedJarToken),
      'afterJarTLen': _len(candidate),
      'afterJarTHash': tokenHash(candidate),
      'afterMatchesSentT': candidate == sentToken,
      'requestGeneration': ?requestGeneration,
    });
    return SessionTokenVerdict.valid(
      token: candidate,
      source: SessionTokenSource.previous,
      currentUser: result.currentUser,
    );
  }

  /// 最后一级：已授权的 User API Key 静默补发 OTP 兑换全新 `_t`
  /// （新值由 Set-Cookie 落 jar，与密码登录同源）。
  Future<SessionTokenVerdict?> _healWithUserApiKey({
    required String source,
    String? triggerInfo,
  }) async {
    final userApiKey = _userApiKey;
    if (userApiKey == null) return null;
    try {
      final currentUser = await userApiKey.heal();
      if (currentUser == null) return null;

      final newToken = await _readJarSafely();
      if (!_has(newToken)) return null;

      _clearPrevious();
      _clearRejected();

      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_probe_user_api_key_recovered',
        'message': 'User API Key 自愈成功,已兑换新 _t,取消本次登出',
        'source': source,
        'trigger': ?triggerInfo,
        'username': currentUser['username']?.toString(),
        'newTLen': _len(newToken),
        'newTHash': tokenHash(newToken),
      });
      return SessionTokenVerdict.valid(
        token: newToken,
        source: SessionTokenSource.userApiKey,
        currentUser: currentUser,
      );
    } catch (e) {
      debugPrint('[SessionToken] User API Key 自愈异常: $e');
      return null;
    }
  }

  /// 冷启动时 jar 没有 `_t` 但用户名还在（jar 异常丢值，不是用户登出）：
  /// 从 WebView 找回会话。
  ///
  /// WebView 的值探测有效 → 可信写回并标记两端一致；探测无结论 → 也先采纳
  /// （交给随后的登录态检查和 strike 机制裁决，与「网络异常保守保留本地
  /// 状态」一致）——这是唯一允许未验证的 WebView 值进 jar 的地方，且只在
  /// jar 为空时；服务端明确拒绝 → 冷却，再试 User API Key，仍不行判死
  /// （被动登出，不悄悄变匿名）。WebView 根本没有 `_t` 且自愈失败 → absent。
  Future<SessionTokenVerdict> recoverMissingJarToken({
    String source = 'startup_jar_token_missing',
  }) async {
    String? webViewToken;
    String? forumSession;
    try {
      webViewToken = await _webView.read();
      if (_has(webViewToken)) {
        forumSession = await _webView.readForumSession();
      }
    } catch (e) {
      debugPrint('[SessionToken] 启动恢复读取 WebView session 失败: $e');
      webViewToken = null;
    }

    var webViewRejected = false;
    if (webViewToken != null && webViewToken.isNotEmpty) {
      final candidate = webViewToken;
      SessionTokenProbeResult result;
      final probe = _probe;
      if (probe == null) {
        result = const SessionTokenProbeResult.inconclusive();
      } else {
        try {
          result = await probe.probeCandidate(
            candidate,
            forumSession: _has(forumSession) ? forumSession : null,
          );
        } catch (e) {
          debugPrint('[SessionToken] 启动恢复探测异常: $e');
          result = const SessionTokenProbeResult.inconclusive();
        }
      }
      final verified = result.isValid;
      if (verified || !result.isConclusive) {
        DateTime? expires;
        try {
          expires = await _webView.readExpiry(candidate);
        } catch (e) {
          debugPrint('[SessionToken] 读取 WebView _t 过期时间失败: $e');
        }
        final ok = await _writeJarTrusted(candidate, candidateExpires: expires);
        if (ok && _has(forumSession)) {
          try {
            await _jar.adoptForumSessionFromWebView(
              forumSession!,
              allowLowConfidence: true,
            );
          } catch (e) {
            debugPrint('[SessionToken] 启动恢复写回 _forum_session 失败: $e');
          }
        }
        if (ok) {
          if (verified) {
            _clearRejected();
            markAgreed(candidate);
          }
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': verified ? 'info' : 'warning',
            'type': 'auth',
            'event': verified
                ? 'auth_startup_session_recovered_from_webview'
                : 'auth_startup_session_adopted_unverified',
            'message': verified
                ? 'jar 没有 _t 但 WebView 持有有效会话，已可信写回 jar'
                : 'jar 没有 _t，WebView 的 _t 探测无结论，先采纳交给后续检查裁决',
            'source': source,
            'webViewTLen': _len(candidate),
            'webViewTHash': tokenHash(candidate),
            'hasForumSession': _has(forumSession),
          });
          return verified
              ? SessionTokenVerdict.valid(
                  token: candidate,
                  source: SessionTokenSource.webView,
                  currentUser: result.currentUser,
                )
              : SessionTokenVerdict.inconclusive(
                  token: candidate,
                  source: SessionTokenSource.unverifiedWebView,
                );
        }
        final afterJar = await _readJarSafely();
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_startup_session_recover_write_failed',
          'message': 'WebView 的 _t 写入 CookieJar 后读回不符，继续尝试自愈',
          'source': source,
          'verified': verified,
          'webViewTLen': _len(candidate),
          'webViewTHash': tokenHash(candidate),
          'afterJarTLen': _len(afterJar),
          'afterJarTHash': tokenHash(afterJar),
        });
      } else {
        webViewRejected = true;
        _markRejected(candidate);
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_startup_webview_token_rejected',
          'message': 'jar 没有 _t，WebView 的 _t 被服务端明确拒绝',
          'source': source,
          'webViewTLen': _len(candidate),
          'webViewTHash': tokenHash(candidate),
        });
      }
    }

    // 候选环与上一枚值只在内存里：真正的冷启动时两者都是空的，这一步什么
    // 都不做；进程内 jar 丢值后再走到这里时才可能救回来。
    final fromStored = await _recoverFromStoredCandidates(
      source: source,
      exclude: [webViewToken],
    );
    if (fromStored != null) return fromStored;

    final healed = await _healWithUserApiKey(
      source: source,
      triggerInfo: 'startup jar _t missing',
    );
    if (healed != null) return healed;

    if (webViewRejected) {
      // 两端都是死值：会话确实已失效，按被动登出收尾，不要悄悄变匿名。
      return SessionTokenVerdict.dead(failedJarToken: webViewToken);
    }

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'auth',
      'event': 'auth_startup_jar_token_missing',
      'message': 'jar 没有 _t 且 WebView 也没有可用会话，按未登录处理',
      'source': source,
      'webViewHasT': _has(webViewToken),
    });
    return const SessionTokenVerdict.absent();
  }

  /// jar 为空时试候选环与上一枚值（合计最多 3 枚）：服务端确认有效才可信
  /// 写回 jar 并推回 WebView。
  Future<SessionTokenVerdict?> _recoverFromStoredCandidates({
    required String source,
    Iterable<String?> exclude = const [],
  }) async {
    final probe = _probe;
    if (probe == null) return null;
    final excluded = exclude.whereType<String>().toSet();
    final previous = _readPrevious();
    final candidates = <String>[];
    for (final candidate in recoveryCandidates()) {
      if (candidates.length >= _maxRecoveryCandidates) break;
      if (excluded.contains(candidate) || isRejectedInCooldown(candidate)) {
        continue;
      }
      candidates.add(candidate);
    }
    for (final candidate in candidates) {
      SessionTokenProbeResult result;
      try {
        result = await probe.probeCandidate(candidate);
      } catch (e) {
        debugPrint('[SessionToken] 候选探测异常: $e');
        result = const SessionTokenProbeResult.inconclusive();
      }
      if (!result.isValid) {
        if (result.isConclusive) _markRejected(candidate);
        continue;
      }
      _clearRejected();
      if (!await _writeJarTrusted(candidate)) return null;
      final isPrevious = candidate == previous;
      if (isPrevious) _clearPrevious();
      unawaited(
        _pushToWebView(
          candidate,
          reason: 'startup_recover_stored_candidate',
          clearVariantsFirst: true,
        ),
      );
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_startup_session_recovered_from_candidate',
        'message': 'jar 没有 _t，用候选环 / 上一枚值恢复了会话',
        'source': source,
        'fromPrevious': isPrevious,
        'tLen': _len(candidate),
        'tHash': tokenHash(candidate),
      });
      return SessionTokenVerdict.valid(
        token: candidate,
        source: isPrevious
            ? SessionTokenSource.previous
            : SessionTokenSource.recentWebView,
        currentUser: result.currentUser,
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  /// 可信写入 jar，保证带过期时间：候选自带的 → jar 原值的 → 兜底 60 天
  /// （Discourse 默认 maximum_session_age）。返回写入后读回是否一致。
  Future<bool> _writeJarTrusted(
    String value, {
    DateTime? candidateExpires,
  }) async {
    DateTime? existing;
    try {
      existing = await _jar.readExpiry();
    } catch (e) {
      debugPrint('[SessionToken] 读取 jar _t 过期时间失败: $e');
    }
    final expires = CookieJarService.resolveSessionTokenExpiry(
      candidate: candidateExpires,
      existing: existing,
      now: _now(),
    );
    try {
      return await _jar.writeTrusted(value, expires: expires);
    } catch (e) {
      debugPrint('[SessionToken] 可信写入 jar _t 失败: $e');
      return false;
    }
  }

  /// 把 [value] 推进 WebView 并读回确认；成功且 jar 仍是它时两端一致。
  Future<bool> _pushToWebView(
    String value, {
    required String reason,
    bool clearVariantsFirst = false,
  }) async {
    bool ok;
    try {
      ok = await _webView.write(
        value,
        reason: reason,
        clearVariantsFirst: clearVariantsFirst,
      );
    } catch (e) {
      debugPrint('[SessionToken] 推送 _t 到 WebView 失败($reason): $e');
      ok = false;
    }
    if (ok && await _readJarSafely() == value) markAgreed(value);
    return ok;
  }

  Future<String?> _readJarSafely() async {
    try {
      return await _jar.read();
    } catch (e) {
      debugPrint('[SessionToken] 读取 jar _t 失败: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static bool _has(String? token) => token != null && token.isNotEmpty;

  static int? _len(String? token) =>
      token != null && token.isNotEmpty ? token.length : null;

  static int? _generationOf(RequestOptions? options) =>
      options?.extra['_sessionGeneration'] as int?;

  /// 请求实际带出去的 `_t`（从 Cookie 头里解析）。
  static String? sentTokenFromRequest(RequestOptions requestOptions) {
    final sentCookieHeader =
        requestOptions.headers[HttpHeaders.cookieHeader]?.toString() ??
        requestOptions.headers['Cookie']?.toString() ??
        '';
    return RegExp(
      r'(?:^|;\s*)_t=([^;]*)',
    ).firstMatch(sentCookieHeader)?.group(1);
  }

  bool _isSiteUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    final siteHost = Uri.parse(AppConstants.baseUrl).host.toLowerCase();
    return host == siteHost || host.endsWith('.$siteHost');
  }

  void _logReconcile({
    required String result,
    required String reason,
    required String jarValue,
    required String webViewValue,
    required String? agreed,
    required bool? probe,
    bool webViewVerified = false,
    int? requestGeneration,
    required int elapsedMs,
  }) {
    final isFailure = result.endsWith('failed');
    final message = switch (result) {
      'adopted_webview' => 'WebView 的 _t 经服务端确认有效，已采纳进 CookieJar',
      'repushed_jar' => 'CookieJar 的 _t 更新，已重新推回 WebView',
      'pushed_to_empty_webview' => 'WebView 没有 _t，已把 CookieJar 的推过去',
      'push_empty_failed' => 'WebView 没有 _t，推送 CookieJar 的值后读回不符',
      'inconclusive' => '两端 _t 不一致但探测无结论，暂不处理',
      'raced' => '探测期间 CookieJar 的 _t 已被其他路径更新，放弃本次对账',
      'adopt_failed' => '采纳 WebView 的 _t 写入 CookieJar 后读回不符',
      'repush_failed' => '推回 CookieJar 的 _t 后 WebView 读回不符',
      _ => result,
    };
    debugPrint('[SessionToken] $result ($reason): $message');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': isFailure ? 'warning' : 'info',
      'type': 'auth',
      'event': 'session_token_reconcile',
      'result': result,
      'message': message,
      'reason': reason,
      'jarTLen': jarValue.length,
      'jarTHash': tokenHash(jarValue),
      'webViewTLen': webViewValue.isEmpty ? null : webViewValue.length,
      'webViewTHash': tokenHash(webViewValue),
      'agreedTHash': tokenHash(agreed),
      'jarMoved': agreed == null ? null : jarValue != agreed,
      'webViewMoved': agreed == null ? null : webViewValue != agreed,
      'probe': probe,
      'webViewVerified': webViewVerified,
      'requestGeneration': ?requestGeneration,
      'elapsedMs': elapsedMs,
    });
  }

  /// 12 位 FNV-1a 脱敏哈希，只用于日志里区分不同 token，不可逆。
  static String? tokenHash(String? token) {
    if (token == null || token.isEmpty) return null;

    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;

    for (final byte in utf8.encode(token)) {
      hash = (hash ^ BigInt.from(byte)) * prime & mask;
    }

    return hash.toRadixString(16).padLeft(16, '0').substring(0, 12);
  }
}

class _SeenCandidate {
  const _SeenCandidate(this.value, this.seenAt);
  final String value;
  final DateTime seenAt;
}
