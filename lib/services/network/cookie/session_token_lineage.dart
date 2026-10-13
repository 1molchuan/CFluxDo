import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../../../constants.dart';
import '../../auth_session.dart';
import '../../log/log_writer.dart';
import 'boundary_sync_service.dart';
import 'cookie_jar_service.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// 用候选 `_t` 向服务端探测会话是否有效（由 DiscourseService 注册）。
///
/// true/false 是服务端的明确答复；null 表示探测本身没结论（网关错误、超时、
/// 撞 CF 盾、会话代已变），对账方不得据此采纳或推回，两端都不能动。
typedef SessionTokenProbe =
    Future<bool?> Function(String candidate, {int? requestGeneration});

/// jar 采纳了 WebView 的 `_t` 之后的回调：`adopted` 是新值，`previous` 是
/// 被替换掉的 jar 旧值（可能为空）。
typedef SessionTokenAdopted = void Function(String adopted, String? previous);

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

/// `_t` 血缘对账。
///
/// 背景：Discourse 每约 10 分钟轮换一次 `_t`，同时接受当前值和上一枚值。
/// App 里有两份存储——Dio 的 CookieJar 和 WebView 的 CookieManager，各自都
/// 可能收到轮换。只要两边分叉超过轮换窗口，其中一边手里的值就会被服务端
/// 判死，表现为「无征兆掉登录，原地重登立刻恢复」。
///
/// 以前的同步规则是「jar 永远赢」，遇到 WebView 已经拿到新值、jar 还是旧值
/// 的场景会把旧值灌回 WebView，把分叉固定下来。这里改为记住两端最后一次
/// 一致的值（血缘），分叉时判断是哪一边往前走了：
///
/// - WebView 变了、jar 没变 → 探测 WebView 的值，有效就采纳进 jar；
/// - jar 变了、WebView 没变 → 把 jar 的值推回 WebView；
/// - 两边都变 / 没有血缘信息 → 探测 WebView 的值，有效采纳，无效推回 jar。
///
/// 任何采纳都必须经过服务端探测（或调用方已证明服务端刚刚接受了该值），
/// 绝不把未验证的值写进 jar，避免把死值带进 App 主链路。
class SessionTokenLineage {
  SessionTokenLineage._();
  static final SessionTokenLineage instance = SessionTokenLineage._();

  static const String cookieName = '_t';
  static const Duration _noDiffThrottle = Duration(seconds: 2);
  static const Duration _probeTimeout = Duration(seconds: 8);
  static const Duration _candidateTtl = Duration(minutes: 20);
  static const int _maxCandidates = 4;
  static const Duration _pushRetryDelay = Duration(milliseconds: 150);

  CookieJarService _jar = CookieJarService();
  BoundarySyncService _boundary = BoundarySyncService.instance;
  RawCookieWriter _writer = RawCookieWriter.instance;
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;
  AuthSession _auth = AuthSession();

  /// 仅测试用：替换内部依赖。
  @visibleForTesting
  void replaceDependenciesForTest({
    CookieJarService? jar,
    BoundarySyncService? boundary,
    RawCookieWriter? writer,
    SessionCookieSentinel? sentinel,
    AuthSession? auth,
  }) {
    if (jar != null) _jar = jar;
    if (boundary != null) _boundary = boundary;
    if (writer != null) _writer = writer;
    if (sentinel != null) _sentinel = sentinel;
    if (auth != null) _auth = auth;
  }

  SessionTokenProbe? _probe;
  SessionTokenAdopted? _onAdopted;

  /// 两端最后一次确认一致的 `_t`。只放内存，不落盘。
  String? _lastAgreed;

  /// 最近在 WebView 里见过、但与 jar 不同的 `_t` 候选（新的在前）。
  /// 登出恢复路径在 WebView 当前值不可用时可以拿它们逐个探测。
  final List<_SeenCandidate> _recentWebViewCandidates = [];

  final Lock _lock = Lock();
  String? _lastNoDiffSignature;
  DateTime? _lastNoDiffAt;

  /// 注册探测与采纳回调。探测缺省不可用时只按血缘规则处理，不会采纳。
  void registerHooks({
    required SessionTokenProbe probe,
    required SessionTokenAdopted onAdopted,
  }) {
    _probe = probe;
    _onAdopted = onAdopted;
  }

  /// 仅测试用：清空状态。
  @visibleForTesting
  void resetForTest() {
    _probe = null;
    _onAdopted = null;
    _lastAgreed = null;
    _recentWebViewCandidates.clear();
    _lastNoDiffSignature = null;
    _lastNoDiffAt = null;
  }

  /// 两端最后一次一致值的脱敏哈希（仅用于日志/诊断）。
  String? get lastAgreedHash => tokenHash(_lastAgreed);

  /// 标记某个值已在两端一致。
  void markAgreed(String? value) {
    if (value == null || value.isEmpty) return;
    _lastAgreed = value;
    _recentWebViewCandidates.removeWhere((c) => c.value == value);
  }

  /// 登出时清空血缘（新登录的 `_t` 与旧值无关）。
  void clear() {
    _lastAgreed = null;
    _recentWebViewCandidates.clear();
    _lastNoDiffSignature = null;
    _lastNoDiffAt = null;
  }

  /// 记一笔在 WebView 里见到的 `_t` 候选（与 jar 不同的值才有意义）。
  void noteWebViewCandidate(String? value) {
    if (value == null || value.isEmpty) return;
    if (value == _lastAgreed) return;
    _recentWebViewCandidates.removeWhere((c) => c.value == value);
    _recentWebViewCandidates.insert(0, _SeenCandidate(value, DateTime.now()));
    _pruneCandidates();
  }

  /// 最近见过的 WebView `_t` 候选（新的在前，已过期的不返回）。
  List<String> recentWebViewCandidates({Iterable<String?> exclude = const []}) {
    _pruneCandidates();
    final excluded = exclude.whereType<String>().toSet();
    return _recentWebViewCandidates
        .map((c) => c.value)
        .where((v) => !excluded.contains(v))
        .toList(growable: false);
  }

  void _pruneCandidates() {
    final now = DateTime.now();
    _recentWebViewCandidates.removeWhere(
      (c) => now.difference(c.seenAt) > _candidateTtl,
    );
    if (_recentWebViewCandidates.length > _maxCandidates) {
      _recentWebViewCandidates.removeRange(
        _maxCandidates,
        _recentWebViewCandidates.length,
      );
    }
  }

  /// 对账 jar 与 WebView 的 `_t`。
  ///
  /// [url] 只用来判断是否站点域名（站外 WebView 直接跳过）；读写一律针对
  /// [AppConstants.baseUrl]。[webViewVerified] 表示调用方刚拿到服务端对
  /// WebView 会话的肯定答复（成功的登录态请求），此时 WebView 的新值无需再
  /// 探测即可采纳。
  ///
  /// [allowProbe] 为 false 时不向服务端探测（例如正要过 CF 盾、探测请求
  /// 自己也会被拦）：只按血缘能判定方向的才动手，否则记为无结论。
  /// [pushIfWebViewEmpty] 为 true 时，WebView 没有 `_t` 就直接把 jar 的推
  /// 过去。[lockTimeout] 限定等待前一次对账的时长，超时按跳过处理。
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
    if (!_jar.isInitialized) return SessionTokenReconcileOutcome.skipped;
    if (requestGeneration != null && !_auth.isValid(requestGeneration)) {
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
      debugPrint('[TokenLineage] reconcile($reason) 等锁超时，跳过');
      return SessionTokenReconcileOutcome.skipped;
    } catch (e) {
      debugPrint('[TokenLineage] reconcile($reason) 异常: $e');
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
    final entryGen = _auth.generation;
    if (requestGeneration != null && !_auth.isValid(requestGeneration)) {
      return SessionTokenReconcileOutcome.skipped;
    }

    final jarValue = await _jar.getTToken();
    if (jarValue == null || jarValue.isEmpty) {
      // 未登录 / 已登出：不采纳任何东西。
      return SessionTokenReconcileOutcome.skipped;
    }

    String? webViewValue;
    try {
      webViewValue = await _boundary.readCookieValueFromWebView(
        currentUrl: AppConstants.baseUrl,
        name: cookieName,
        allowLowConfidenceSessionCookies: true,
      );
    } catch (e) {
      debugPrint('[TokenLineage] 读取 WebView _t 失败($reason): $e');
      return SessionTokenReconcileOutcome.skipped;
    }
    if (webViewValue == null || webViewValue.isEmpty) {
      if (!pushIfWebViewEmpty) {
        // WebView 还没灌过 cookie（priming 会补），没有分叉可言。
        return SessionTokenReconcileOutcome.webViewEmpty;
      }
      final pushed = await pushJarCookieToWebView(
        name: cookieName,
        reason: 'lineage_${reason}_empty',
      );
      _log(
        result: pushed ? 'pushed_to_empty_webview' : 'push_empty_failed',
        reason: reason,
        jarValue: jarValue,
        webViewValue: '',
        agreed: _lastAgreed,
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
    noteWebViewCandidate(webViewValue);

    final signature = '${tokenHash(jarValue)}|${tokenHash(webViewValue)}';
    final lastAt = _lastNoDiffAt;
    if (_lastNoDiffSignature == signature &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < _noDiffThrottle) {
      return SessionTokenReconcileOutcome.skipped;
    }
    _lastNoDiffSignature = signature;
    _lastNoDiffAt = DateTime.now();

    final agreed = _lastAgreed;
    final jarMoved = agreed != null && jarValue != agreed;
    final webViewMoved = agreed != null && webViewValue != agreed;
    final hasLineage = agreed != null;

    // 决策：
    // 1. WebView 没动、jar 动了 → jar 更新（Dio 收到轮换 / 恢复路径写入），
    //    直接推回，不探测。即便调用方说 WebView 刚被服务端接受也一样：
    //    上一枚值在轮换窗口内仍被接受，不代表它比 jar 新。
    // 2. 其余情况 → 以 WebView 值探测服务端；有效采纳，无效推回 jar。
    final decision = (hasLineage && jarMoved && !webViewMoved)
        ? _LineageDecision.repushJar
        : _LineageDecision.probeWebView;

    bool? probeResult;
    var adoptWebView = false;
    if (decision == _LineageDecision.probeWebView) {
      if (webViewVerified) {
        adoptWebView = true;
      } else {
        final probe = allowProbe ? _probe : null;
        if (probe == null) {
          // 不能探测时只按血缘走：jar 自上次一致后没动、WebView 动了，
          // WebView 的值只可能来自服务端 Set-Cookie（我们自己的推送都会
          // 标记一致），可以直接采纳；没有血缘则无从判断，记无结论。
          if (hasLineage && !jarMoved && webViewMoved) {
            adoptWebView = true;
          } else if (hasLineage && jarMoved && !webViewMoved) {
            adoptWebView = false;
          } else {
            _log(
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
          try {
            probeResult = await probe(
              webViewValue,
              requestGeneration: requestGeneration,
            ).timeout(_probeTimeout);
          } on TimeoutException {
            probeResult = null;
          } catch (e) {
            debugPrint('[TokenLineage] 探测异常($reason): $e');
            probeResult = null;
          }
          if (probeResult == null) {
            _log(
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
    }

    if (!_auth.isValid(entryGen) ||
        (requestGeneration != null && !_auth.isValid(requestGeneration))) {
      return SessionTokenReconcileOutcome.skipped;
    }

    // 探测期间 jar 可能已被别的路径改掉，重新核对。
    final jarNow = await _jar.getTToken();
    if (jarNow != jarValue) {
      if (jarNow == webViewValue) {
        markAgreed(webViewValue);
        return SessionTokenReconcileOutcome.agreed;
      }
      _log(
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
      // 带上 WebView 里这枚值自己的过期时间。jar 只落盘带过期时间的 cookie，
      // 丢了它，采纳的值只活在内存里，下次冷启动 jar 为空就直接判未登录。
      DateTime? webViewExpires;
      try {
        webViewExpires = await _boundary.readCookieExpiresFromWebView(
          currentUrl: AppConstants.baseUrl,
          name: cookieName,
          expectedValue: webViewValue,
          allowLowConfidenceSessionCookies: true,
        );
      } catch (e) {
        debugPrint('[TokenLineage] 读取 WebView _t 过期时间失败($reason): $e');
      }
      await _jar.setSessionTokenTrusted(webViewValue, expires: webViewExpires);
      final afterJar = await _jar.getTToken();
      final ok = afterJar == webViewValue;
      if (ok) {
        markAgreed(webViewValue);
        _onAdopted?.call(webViewValue, jarValue);
      }
      _log(
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

    final pushed = await pushJarCookieToWebView(
      name: cookieName,
      reason: 'lineage_$reason',
      nukeVariantsFirst: true,
    );
    _log(
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

  /// 把 jar 里某个 cookie 的 canonical 形式推进 WebView，并读回确认。
  ///
  /// 失败重试一次；最终仍不符则写告警日志返回 false。[rawSetCookie] 与
  /// [expectedValue] 不传时从 jar 读 canonical。成功推送 `_t` 时顺带标记
  /// 两端一致。
  Future<bool> pushJarCookieToWebView({
    required String name,
    required String reason,
    String? url,
    String? rawSetCookie,
    String? expectedValue,
    bool nukeVariantsFirst = false,
  }) async {
    final targetUrl = url ?? AppConstants.baseUrl;
    var header = rawSetCookie;
    var expected = expectedValue;
    if (header == null || expected == null) {
      final canonical = await _jar.getCanonicalCookie(name);
      if (canonical == null || canonical.value.isEmpty) return false;
      header ??= canonical.toSetCookieHeader();
      expected ??= canonical.value;
    }

    var setResult = false;
    String? readBack;
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (nukeVariantsFirst || attempt > 1) {
        try {
          await _sentinel.sweep(
            targetUrl,
            name,
            intent: SweepIntent.delete,
            force: true,
          );
        } catch (e) {
          debugPrint('[TokenLineage] 推送前清理 $name 变体失败: $e');
        }
      }
      setResult = await _writer.setRawCookie(
        targetUrl,
        header,
        writeSharedStorage: name != 'cf_clearance',
      );
      readBack = await _readBackWebViewValue(targetUrl, name, expected);
      if (readBack == expected) {
        if (name == cookieName) markAgreed(expected);
        if (attempt > 1) {
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': 'info',
            'type': 'cookie_trace',
            'event': 'webview_cookie_push_recovered',
            'message': '$name 推送 WebView 首次读回不符，重试后已一致',
            'name': name,
            'reason': reason,
            'valueLength': expected.length,
            'valueHash': tokenHash(expected),
          });
        }
        return true;
      }
      debugPrint(
        '[TokenLineage] $name 推送 WebView 后读回不符 '
        '(attempt=$attempt, set=$setResult, reason=$reason)',
      );
      if (attempt == 1) await Future<void>.delayed(_pushRetryDelay);
    }

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_trace',
      'event': 'webview_cookie_push_failed',
      'message': '$name 推送 WebView 两次后读回仍不符，WebView 可能仍持旧值',
      'name': name,
      'reason': reason,
      'setRawCookieResult': setResult,
      'expectedLength': expected.length,
      'expectedHash': tokenHash(expected),
      'readBackLength': readBack?.length,
      'readBackHash': tokenHash(readBack),
    });
    return false;
  }

  /// 读回 WebView 中 [name] 的值：只要任一变体等于 [expected] 就视为写入成功
  /// （多变体由随后的 sweep 收敛），否则返回「最佳」变体的值用于日志。
  Future<String?> _readBackWebViewValue(
    String url,
    String name,
    String expected,
  ) async {
    try {
      final infos = await _writer.getAllCookieInfos(url);
      for (final info in infos) {
        if (info.name == name && info.value == expected) return expected;
      }
    } catch (e) {
      debugPrint('[TokenLineage] getAllCookieInfos 失败: $e');
    }
    try {
      return await _boundary.readCookieValueFromWebView(
        currentUrl: url,
        name: name,
        allowLowConfidenceSessionCookies: true,
      );
    } catch (e) {
      debugPrint('[TokenLineage] 读回 $name 失败: $e');
      return null;
    }
  }

  bool _isSiteUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    final siteHost = Uri.parse(AppConstants.baseUrl).host.toLowerCase();
    return host == siteHost || host.endsWith('.$siteHost');
  }

  void _log({
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
    debugPrint('[TokenLineage] $result ($reason): $message');
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

enum _LineageDecision { repushJar, probeWebView }

class _SeenCandidate {
  const _SeenCandidate(this.value, this.seenAt);
  final String value;
  final DateTime seenAt;
}
