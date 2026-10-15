import 'package:dio/dio.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';

/// [SessionTokenAuthority] 场景测试用的内存假实现：jar、WebView、服务端
/// （探测 / User API Key / 认证层回调）都在内存里，时钟可拨。

class FakeClock {
  DateTime now = DateTime.utc(2026, 10, 15, 8);

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

/// CookieJar 的 `_t`。带过期时间才算「落盘」（与 EnhancedPersistCookieJar 一致）。
class FakeJarStore implements SessionTokenJarStore {
  FakeJarStore({this.value, this.expires});

  String? value;
  DateTime? expires;
  bool ready = true;
  bool failWrites = false;

  final List<({String value, DateTime expires})> writes = [];
  final List<String> forumSessionAdoptions = [];

  /// 冷启动后还在不在：会话 cookie（无过期时间）只活在内存里。
  bool get persisted => value != null && expires != null;

  @override
  bool get isReady => ready;

  @override
  Future<String?> read() async => value;

  @override
  Future<DateTime?> readExpiry() async => value == null ? null : expires;

  @override
  Future<bool> writeTrusted(
    String newValue, {
    required DateTime expires,
  }) async {
    writes.add((value: newValue, expires: expires));
    if (failWrites) return false;
    value = newValue;
    this.expires = expires;
    return true;
  }

  @override
  Future<void> adoptForumSessionFromWebView(
    String value, {
    int? requestGeneration,
    bool allowLowConfidence = false,
  }) async {
    forumSessionAdoptions.add(value);
  }
}

/// WebView cookie store 的 `_t`（只建模「选优后的那一枚」）。
class FakeWebViewStore implements SessionTokenWebViewStore {
  FakeWebViewStore({this.value, this.expires, this.forumSession});

  String? value;
  DateTime? expires;
  String? forumSession;
  bool failWrites = false;
  bool throwOnRead = false;

  final List<({String value, String reason, bool clearVariantsFirst})> writes =
      [];

  @override
  Future<String?> read() async {
    if (throwOnRead) throw StateError('WebView cookie manager 不可用');
    return value;
  }

  @override
  Future<DateTime?> readExpiry(String v) async => v == value ? expires : null;

  @override
  Future<String?> readForumSession() async => forumSession;

  @override
  Future<bool> write(
    String newValue, {
    required String reason,
    String? url,
    String? rawSetCookie,
    DateTime? expires,
    bool clearVariantsFirst = false,
  }) async {
    writes.add((
      value: newValue,
      reason: reason,
      clearVariantsFirst: clearVariantsFirst,
    ));
    if (failWrites) return false;
    value = newValue;
    this.expires = expires;
    return true;
  }
}

/// 服务端：哪些 `_t` 有效 / 被拒，其余一律无结论；[challenged] 时（CF 盾
/// 窗口）所有探测都无结论。同时扮演 User API Key 与认证层回调。
class FakeServer
    implements
        SessionTokenProbe,
        SessionTokenUserApiKey,
        SessionTokenAuthListener {
  FakeServer(this.jar);

  final FakeJarStore jar;
  final Set<String> valid = {};
  final Set<String> rejected = {};
  bool challenged = false;

  final List<String> candidateProbes = [];
  final List<String?> jarProbes = [];
  final List<String> replaced = [];
  final List<RequestOptions> deletionSignals = [];

  /// User API Key 自愈：给了就把它写进 jar（相当于 Set-Cookie 落 jar）。
  String? healIssues;
  int heals = 0;

  SessionTokenProbeResult judge(String? token) {
    if (challenged || token == null) {
      return const SessionTokenProbeResult.inconclusive(networkFailure: true);
    }
    if (valid.contains(token)) {
      return const SessionTokenProbeResult.valid({'username': 'alice'});
    }
    if (rejected.contains(token)) {
      return const SessionTokenProbeResult.rejected(statusCode: 404);
    }
    return const SessionTokenProbeResult.inconclusive(networkFailure: true);
  }

  @override
  Future<SessionTokenProbeResult> probeCandidate(
    String token, {
    String? forumSession,
    int? requestGeneration,
  }) async {
    candidateProbes.add(token);
    return judge(token);
  }

  @override
  Future<SessionTokenProbeResult> probeJarSession({
    required String source,
    String? triggerInfo,
  }) async {
    jarProbes.add(jar.value);
    return judge(jar.value);
  }

  @override
  Future<Map<String, dynamic>?> heal() async {
    heals++;
    final issued = healIssues;
    if (issued == null) return null;
    jar.value = issued;
    jar.expires = DateTime.utc(2026, 12, 14);
    return {'username': 'alice'};
  }

  @override
  void onTokenReplaced(String token) => replaced.add(token);

  @override
  void onDeletionDeferred(RequestOptions requestOptions, int? statusCode) =>
      deletionSignals.add(requestOptions);
}

/// 一套接好线的 authority + 假存储 + 假服务端。
class SessionTokenRig {
  SessionTokenRig({
    String? jar,
    DateTime? jarExpires,
    String? webView,
    DateTime? webViewExpires,
    String? forumSession,
  }) : clock = FakeClock(),
       jarStore = FakeJarStore(value: jar, expires: jarExpires),
       webViewStore = FakeWebViewStore(
         value: webView,
         expires: webViewExpires,
         forumSession: forumSession,
       ) {
    server = FakeServer(jarStore);
    authority = SessionTokenAuthority(
      jar: jarStore,
      webView: webViewStore,
      clock: clock.call,
    )..attachAuth(probe: server, userApiKey: server, listener: server);
  }

  final FakeClock clock;
  final FakeJarStore jarStore;
  final FakeWebViewStore webViewStore;
  late final FakeServer server;
  late final SessionTokenAuthority authority;

  /// 越过同一分叉的 2 秒去抖，模拟「之后又来了一次对账」。
  void later([Duration by = const Duration(seconds: 3)]) => clock.advance(by);
}

/// 带着 [token] 发出的请求（Cookie 头里有 `_t`）。
RequestOptions requestCarrying(String? token, {int status = 200}) {
  return RequestOptions(
    path: '/latest.json',
    baseUrl: 'https://linux.do',
    headers: {if (token != null) 'cookie': '_t=$token; other=1'},
  );
}
