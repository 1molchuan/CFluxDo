import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/raw_cookie_writer.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';
import 'package:fluxdo/services/network/recovery/session_heal_policy.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';

import '../../session/session_token_fakes.dart';

/// Sentinel / Nuclear Reset / 会话自愈不再自己判 `_t` 谁赢：只报告看到的
/// 变体、按 [SessionTokenAuthority] 的结论动手。核心回归：jar 里的旧值不能
/// 再压过经服务端探测确认有效的 WebView 值。
void main() {
  const url = 'https://linux.do';
  final sentinel = SessionCookieSentinel.instance;
  late _MemoryWebViewCookies webView;
  late _MemoryJar jar;
  late SessionTokenRig rig;

  setUp(() {
    webView = _MemoryWebViewCookies();
    jar = _MemoryJar();
    rig = SessionTokenRig(jar: 'T1', webView: 'T2');
    sentinel
      ..resetForTest()
      ..replaceDependenciesForTest(
        writer: webView,
        jar: jar,
        sessionToken: rig.authority,
      );
  });

  tearDown(() {
    sentinel
      ..resetForTest()
      ..replaceDependenciesForTest(
        writer: RawCookieWriter.instance,
        jar: CookieJarService(),
        sessionToken: SessionTokenAuthority.instance,
      );
  });

  final now = DateTime.now();
  CookieFullInfo tVariant(String value, {required int days, String? domain}) {
    return CookieFullInfo(
      name: '_t',
      value: value,
      domain: domain,
      path: '/',
      expiresMillis: now.add(Duration(days: days)).millisecondsSinceEpoch,
    );
  }

  group('Sentinel 收敛 WebView 里多枚 _t', () {
    setUp(() {
      jar.put('_t', 'T1', expires: now.add(const Duration(days: 30)));
      webView.cookies.addAll([
        tVariant('T1', days: 30, domain: '.linux.do'),
        // WebView 刚轮换到的值：选优排第一（过期更远）
        tVariant('T2', days: 60, domain: 'linux.do'),
      ]);
    });

    test('WebView 那枚可能更新 → 留 T2、jar 不写；随后对账，探测确认 T2 → jar 采纳 T2', () async {
      rig.server.valid.add('T2');

      await sentinel.sweep(url, '_t', force: true);

      expect(webView.valuesOf('_t'), ['T2']);
      expect(jar.tokenWrites, isEmpty, reason: 'Sentinel 不再把 _t 写进 jar');
      await pumpEventQueue();
      expect(rig.server.candidateProbes, ['T2']);
      expect(rig.jarStore.value, 'T2', reason: '探测确认的 WebView 值胜出');
    });

    test('探测无结论 → WebView 留它自己的 T2，jar 仍是 T1（两端都不改判）', () async {
      await sentinel.sweep(url, '_t', force: true);
      await pumpEventQueue();

      expect(webView.valuesOf('_t'), ['T2']);
      expect(jar.tokenWrites, isEmpty);
      expect(rig.jarStore.value, 'T1');
      expect(rig.jarStore.writes, isEmpty);
    });

    test('T2 刚被服务端拒绝（冷却中）→ 留 jar 的 T1，不再对账', () async {
      rig.server.rejected.add('T2');
      await rig.authority.reconcile(reason: 'seed');
      final probesBefore = rig.server.candidateProbes.length;

      await sentinel.sweep(url, '_t', force: true);
      await pumpEventQueue();

      expect(webView.valuesOf('_t'), ['T1']);
      expect(rig.server.candidateProbes, hasLength(probesBefore));
    });

    test('T2 是两端此前一致过的旧值、jar 已前移到 T1 → 留 jar 的 T1', () async {
      rig.authority.markAgreed('T2');

      await sentinel.sweep(url, '_t', force: true);

      expect(webView.valuesOf('_t'), ['T1']);
      expect(jar.tokenWrites, isEmpty);
    });

    test('jar 没有 _t → 只去重留 WebView 选优那枚，不写进 jar', () async {
      jar.cookies.clear();

      await sentinel.sweep(url, '_t', force: true);

      expect(webView.valuesOf('_t'), ['T2']);
      expect(jar.tokenWrites, isEmpty);
    });
  });

  group('Nuclear Reset 的 _t', () {
    test('WebView 里有可能更新的 T2 → 不清不灌 _t（其余 cookie 照常），交对账决定', () async {
      jar
        ..put('_t', 'T1', expires: now.add(const Duration(days: 30)))
        ..put('foo', 'jar-foo');
      webView.cookies.addAll([
        tVariant('T2', days: 60),
        CookieFullInfo(name: 'foo', value: 'stale-foo'),
      ]);
      rig.server.valid.add('T2');

      await sentinel.nuclearReset(url);

      expect(webView.valuesOf('_t'), ['T2']);
      expect(webView.valuesOf('foo'), ['jar-foo']);
      await pumpEventQueue();
      expect(rig.jarStore.value, 'T2');
    });

    test('WebView 的 _t 与 jar 相同 → 照旧清空并从 jar 重灌', () async {
      jar.put('_t', 'T1', expires: now.add(const Duration(days: 30)));
      webView.cookies.addAll([
        tVariant('T1', days: 30, domain: '.linux.do'),
        tVariant('T1', days: 30),
      ]);

      await sentinel.nuclearReset(url);

      expect(webView.valuesOf('_t'), ['T1']);
      expect(webView.setCount('_t'), 1);
    });
  });

  group('会话自愈', () {
    test('先交 SessionTokenAuthority 对账 _t，再 sweep / Nuclear Reset', () async {
      final calls = <String>[];
      final fake = _RecordingSentinel(calls);

      await SessionSweepAction(
        origin: url,
        sentinel: fake,
        reconcileSessionToken: (origin, reason) async =>
            calls.add('reconcile:$reason'),
      ).perform();
      await SessionSweepAction(
        origin: url,
        nuclear: true,
        sentinel: fake,
        reconcileSessionToken: (origin, reason) async =>
            calls.add('reconcile:$reason'),
      ).perform();

      expect(calls, [
        'reconcile:self_heal',
        'sweepAll',
        'reconcile:self_heal_nuclear',
        'nuclearReset',
      ]);
    });

    test('对账确认 WebView 的 T2 → 重放前 jar 已是 T2（旧 jar 值不再赢）', () async {
      rig.server.valid.add('T2');

      await SessionSweepAction(
        origin: url,
        sentinel: _RecordingSentinel([]),
        reconcileSessionToken: (origin, reason) async {
          await rig.authority.reconcile(url: origin, reason: reason);
        },
      ).perform();

      expect(rig.jarStore.value, 'T2');
      expect(rig.webViewStore.value, 'T2');
    });
  });
}

/// 内存版 WebView cookie store（Sentinel 只通过 RawCookieWriter 碰它）。
class _MemoryWebViewCookies implements RawCookieWriter {
  final List<CookieFullInfo> cookies = [];
  final Map<String, int> _sets = {};

  List<String> valuesOf(String name) =>
      cookies.where((c) => c.name == name).map((c) => c.value).toList();

  int setCount(String name) => _sets[name] ?? 0;

  @override
  Future<List<CookieFullInfo>> getAllCookieInfos(String url) async =>
      List.of(cookies);

  @override
  Future<int> countCookiesByName(String url, String name) async =>
      cookies.where((c) => c.name == name).length;

  @override
  Future<int> nukeAllVariants({
    required String url,
    required String name,
    required List<String?> domainCandidates,
    required List<String> pathCandidates,
  }) async {
    final before = cookies.length;
    cookies.removeWhere((c) => c.name == name);
    return before - cookies.length;
  }

  @override
  Future<bool> setRawCookie(
    String url,
    String rawSetCookie, {
    bool writeSharedStorage = true,
  }) async {
    final parts = rawSetCookie.split(';').map((p) => p.trim()).toList();
    final eq = parts.first.indexOf('=');
    final name = parts.first.substring(0, eq);
    final value = parts.first.substring(eq + 1);
    String? domain;
    for (final attr in parts.skip(1)) {
      if (attr.toLowerCase().startsWith('domain=')) {
        domain = attr.substring(7);
      }
    }
    cookies.removeWhere((c) => c.name == name && c.domain == domain);
    cookies.add(CookieFullInfo(name: name, value: value, domain: domain));
    _sets[name] = setCount(name) + 1;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存版 CookieJar：只实现 Sentinel 用到的读取；记录对 `_t` 的任何写入。
class _MemoryJar implements CookieJarService {
  final Map<String, CanonicalCookie> cookies = {};
  final List<String> tokenWrites = [];

  void put(String name, String value, {DateTime? expires}) {
    cookies[name] = CanonicalCookie(
      name: name,
      value: value,
      domain: 'linux.do',
      expiresAt: expires,
      secure: true,
      httpOnly: true,
      originUrl: 'https://linux.do',
    );
  }

  @override
  Future<CanonicalCookie?> getCanonicalCookie(
    String name, {
    String? host,
  }) async => cookies[name];

  @override
  Future<List<CanonicalCookie>> loadCanonicalCookiesForRequest(Uri uri) async =>
      cookies.values.toList();

  @override
  Future<int> enforceAuthCookiePolicy({
    String reason = 'unknown',
    Iterable<String>? names,
  }) async => 0;

  @override
  Future<void> setSessionTokenTrusted(String value, {DateTime? expires}) async {
    tokenWrites.add(value);
  }

  @override
  Future<void> setCookie(
    String name,
    String value, {
    String? url,
    String? domain,
    String? path,
    DateTime? expires,
    bool secure = true,
    bool httpOnly = false,
    bool trusted = false,
  }) async {
    if (name == '_t') tokenWrites.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSentinel implements SessionCookieSentinel {
  _RecordingSentinel(this.calls);
  final List<String> calls;

  @override
  Future<List<SweepResult>> sweepAll(String url) async {
    calls.add('sweepAll');
    return const [];
  }

  @override
  Future<NuclearResetResult> nuclearReset(String url) async {
    calls.add('nuclearReset');
    return NuclearResetResult(success: true, elapsed: Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
