import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/cf_verification_round.dart';
import 'package:fluxdo/services/network/cf/cf_challenge_recovery.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/interceptors/cf_challenge_interceptor.dart';

import '../../cf_round_fakes.dart';

/// 单个撞盾请求的恢复流程（[CfChallengeRecovery]）契约。
///
/// 用脚本化的假重放驱动：每次重放按脚本返回 200 / 挑战 / 网络错误，
/// 验证轮次、兼容模式、jar 都是可观察的替身。
void main() {
  late _FakeJar jar;
  late _ScriptedReplay replay;
  late _FakeClearance clearance;
  late _FakeRound round;
  late _FakeCompat compat;
  late CfClearanceAuthority ledger;
  late List<CfRecoveryNotice> notices;

  CfChallengeRecovery recovery() => CfChallengeRecovery(
    replay: replay,
    clearance: clearance,
    round: round,
    compat: compat,
    ledger: ledger,
    notify: notices.add,
  );

  setUp(() {
    jar = _FakeJar('old');
    replay = _ScriptedReplay(jar);
    clearance = _FakeClearance(jar);
    round = _FakeRound(jar);
    compat = _FakeCompat();
    ledger = CfClearanceAuthority.instance..reset();
    ledger.debugCookieReader = () async => jar.value == null
        ? null
        : CanonicalCookie(
            name: 'cf_clearance',
            value: jar.value!,
            expiresAt: DateTime.now().add(const Duration(days: 7)),
          );
    notices = [];
  });

  tearDown(() {
    ledger.debugCookieReader = null;
    ledger.reset();
  });

  test('403 + cf-mitigated → 恰好一轮验证 → 重放 200', () async {
    round.outcomes.add(_passed('new'));
    replay.script.add(_ok);

    final result = await recovery().recover(_challenge(_request('old')));

    expect(result, isA<CfRecovered>());
    expect((result as CfRecovered).response.statusCode, 200);
    expect(round.acquired, 1, reason: '一个撞盾请求只起一轮验证');
    expect(replay.calls, hasLength(1));
    final sent = replay.calls.single;
    expect(sent.spec.skipCfChallenge, isTrue, reason: '重放不得再次触发验证');
    expect(sent.spec.skipCfBlock, isTrue, reason: '重放绕过验证期冻结');
    expect(
      sent.headers['Cookie'],
      contains('cf_clearance=new'),
      reason: '重放带的是这一轮定稿的值',
    );
  });

  test('在位旧值先登记为被撞，新值才落 jar（权威闸门放行）', () async {
    // 换值重放与验证轮次都是"新值落 jar"的路径：两处落值时旧值都必须
    // 已登记被撞，否则闸门以「在位值健康」为由挡掉新值。
    clearance.candidate = 'webview-mint';
    clearance.onSwap = () async {
      expect(ledger.isKnownChallenged('old'), isTrue);
      expect(
        await ledger.evaluateReplacement('webview-mint'),
        CfClearanceReplaceDecision.allow,
      );
    };
    replay.script.add(_challengeOf); // 换上的值也被撞
    round.onAcquire = () async {
      expect(ledger.isKnownChallenged('old'), isTrue);
      expect(ledger.isKnownChallenged('webview-mint'), isTrue);
      expect(
        await ledger.evaluateReplacement('new'),
        CfClearanceReplaceDecision.allow,
        reason: '在位值（换上的那枚）已登记被撞，验证新值可以继位',
      );
    };
    round.outcomes.add(_passed('new'));
    replay.script.add(_ok);

    final result = await recovery().recover(_challenge(_request('old')));

    expect(result, isA<CfRecovered>());
    expect(clearance.swaps, 1);
    expect(round.acquired, 1);
    expect(round.assertionsRan, isTrue);
    expect(clearance.assertionsRan, isTrue);
  });

  test('携带值已过期(≠ jar 当前值)时先用当前值重放,不起验证', () async {
    jar.value = 'current';
    replay.script.add(_ok);

    final result = await recovery().recover(_challenge(_request('stale')));

    expect(result, isA<CfRecovered>());
    expect(round.acquired, 0);
    expect(ledger.isKnownChallenged('stale'), isFalse);
  });

  test('兼容模式重放失败时回滚', () async {
    round.outcomes
      ..add(_passed('v1'))
      ..add(_passed('v2'));
    replay.script
      ..add(_challengeOf) // 第一轮定稿值仍被撞 → 用户可见请求再验证一轮
      ..add(_challengeOf) // 第二轮仍被撞 → 询问兼容模式
      ..add(_networkError); // 兼容重放失败
    compat.enableResult = true;

    final result = await recovery().recover(
      _challenge(_request('old', method: 'POST')),
    );

    expect(result, isA<CfRecoveryFailed>());
    expect(
      (result as CfRecoveryFailed).error.type,
      DioExceptionType.connectionError,
      reason: '兼容重放的真实失败原因如实上抛',
    );
    expect(round.acquired, 2);
    expect(compat.enabled, 1);
    expect(compat.rollbacks, 1, reason: '首次真实请求失败必须回滚兼容模式');
    expect(
      replay.calls.last.extra.containsKey(FluxRequestKeys.skipWebViewAdapter),
      isFalse,
    );
    expect(round.ineffectiveHosts, isEmpty, reason: '兼容路径不再记确定性无效');
    expect(notices, isNot(contains(CfRecoveryNotice.compatEnabled)));
  });

  test('兼容模式重放成功时保留并提示', () async {
    round.outcomes
      ..add(_passed('v1'))
      ..add(_passed('v2'));
    replay.script
      ..add(_challengeOf)
      ..add(_challengeOf)
      ..add(_ok);
    compat.enableResult = true;

    final result = await recovery().recover(_challenge(_request('old')));

    expect(result, isA<CfRecovered>());
    expect(compat.rollbacks, 0);
    expect(notices, contains(CfRecoveryNotice.compatEnabled));
  });

  test('不走兼容时定稿值对本 host 无效 → 记确定性无效并标记该值已死', () async {
    round.outcomes
      ..add(_passed('v1'))
      ..add(_passed('v2'));
    replay.script
      ..add(_challengeOf)
      ..add(_challengeOf);
    compat.enableResult = false;

    final result = await recovery().recover(
      _challenge(_request('old', host: 'cdk.linux.do')),
    );

    expect(result, isA<CfRecoveryFailed>());
    expect(round.ineffectiveHosts, ['cdk.linux.do']);
    expect(ledger.isKnownChallenged('v1'), isTrue);
    expect(ledger.isKnownChallenged('v2'), isTrue);
  });

  test('静默请求不再验证第二轮、也不问兼容模式', () async {
    round.outcomes.add(_passed('v1'));
    replay.script.add(_challengeOf);

    final result = await recovery().recover(
      _challenge(_request('old', extra: {FluxRequestKeys.isSilent: true})),
    );

    expect(result, isA<CfRecoveryFailed>());
    expect(round.acquired, 1);
    expect(round.modes, [CfVerifyMode.background]);
    expect(compat.enabled, 0);
    expect(round.ineffectiveHosts, ['linux.do']);
  });

  test('验证轮次失败按原因映射成 CfChallengeException', () async {
    final cases = {
      CfRoundFailure.cooldown: (CfChallengeException e) => e.inCooldown,
      CfRoundFailure.cancelled: (CfChallengeException e) => e.userCancelled,
      CfRoundFailure.timeout: (CfChallengeException e) => e.userCancelled,
      CfRoundFailure.inconclusive: (CfChallengeException e) => e.userCancelled,
      CfRoundFailure.noUi: (CfChallengeException e) => e.cause != null,
      CfRoundFailure.notLanded: (CfChallengeException e) => e.cause != null,
    };
    for (final entry in cases.entries) {
      round = _FakeRound(jar)
        ..outcomes.add(CfRoundFailed(round: 1, reason: entry.key));
      final result = await recovery().recover(_challenge(_request('old')));
      final error = (result as CfRecoveryFailed).error.error;
      expect(error, isA<CfChallengeException>(), reason: entry.key.name);
      expect(
        entry.value(error as CfChallengeException),
        isTrue,
        reason: entry.key.name,
      );
    }
    expect(replay.calls, isEmpty, reason: '没拿到定稿值就不重放');
  });

  test('N 个并发撞盾请求共享一轮验证（真实轮次合流）', () async {
    final clock = FakeRoundClock();
    final env = FakeRoundEnvironment(clock)..jar = 'old';
    final rounds = CfVerificationRounds(environment: env, clock: clock);
    env.rounds = rounds;
    // 重放读的是轮次环境里的 jar
    final replayFromEnv = _ScriptedReplay(_FakeJar(null), jarOf: () => env.jar);
    for (var i = 0; i < 5; i++) {
      replayFromEnv.script.add(_ok);
    }
    final shared = CfChallengeRecovery(
      replay: replayFromEnv,
      clearance: _EnvClearance(env),
      round: _RoundsPort(rounds),
      compat: compat,
      ledger: ledger,
    );

    final results = Future.wait([
      for (var i = 0; i < 5; i++)
        shared.recover(_challenge(_request('old', path: '/t/$i.json'))),
    ]);
    await pumpEventQueue();
    expect(env.presentations, 1, reason: '五个请求合流到同一轮');

    env.webView = 'new';
    env.presented!.clearanceSeen('new', source: 'polling');
    await clock.advance(const Duration(seconds: 2));

    final all = await results;
    expect(all.whereType<CfRecovered>(), hasLength(5));
    expect(env.landed, ['new'], reason: '只落一次值');
    expect(
      replayFromEnv.calls.map((o) => o.headers['Cookie']).toSet(),
      {'_t=token; cf_clearance=new'},
      reason: '每个请求都用定稿值重放自己的原请求',
    );
    expect(replayFromEnv.calls.map((o) => o.uri.path).toSet(), hasLength(5));
  });

  group('Dio 适配层', () {
    late _SequenceAdapter adapter;
    late Dio dio;

    setUp(() {
      // 请求本身不带 Cookie 头:jar 为空才不会被当成"携带值过期"先重放
      jar.value = null;
      adapter = _SequenceAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://connect.linux.do'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        CfChallengeInterceptor(
          dio: dio,
          cookieJarService: CookieJarService(),
          onChallengeDetected: (_) {},
          recovery: CfChallengeRecovery(
            replay: _DioFetchReplay(dio),
            clearance: clearance,
            round: round,
            compat: compat,
            ledger: ledger,
          ),
        ),
      );
    });

    test('validateStatus <500 的 OAuth 式请求撞盾仍会过盾重放', () async {
      // cdk/ldc 授权页请求放行 4xx 自己解析;以前挑战页被当成授权页解析,
      // 表现成「授权页面解析失败」。
      adapter.responses
        ..add(_challengeBody)
        ..add(_approvePage);
      round.outcomes.add(_passed('new'));

      final response = await dio.get<dynamic>(
        '/oauth2/authorize',
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          extra: {'skipCsrf': true},
        ),
      );

      expect(response.statusCode, 200);
      expect(response.data.toString(), contains('/oauth2/approve/'));
      expect(round.acquired, 1);
      expect(adapter.calls, 2);
    });

    test('声明 allowCfChallengeResponse 的请求拿到原样挑战页', () async {
      adapter.responses.add(_challengeBody);

      final response = await dio.get<dynamic>(
        '/challenge-probe',
        options: Options(
          validateStatus: (_) => true,
          extra: {FluxRequestKeys.allowCfChallengeResponse: true},
        ),
      );

      expect(response.statusCode, 403);
      expect(round.acquired, 0);
    });

    test('普通 403 业务响应不受影响', () async {
      adapter.responses.add(
        ResponseBody.fromString(
          '{"error_type":"invalid_access"}',
          403,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );

      final response = await dio.get<dynamic>(
        '/u/hidden.json',
        options: Options(validateStatus: (s) => s != null && s < 500),
      );

      expect(response.statusCode, 403);
      expect(round.acquired, 0);
    });
  });
}

// ---------------------------------------------------------------------------
// 请求/响应构造
// ---------------------------------------------------------------------------

RequestOptions _request(
  String carried, {
  String method = 'GET',
  String host = 'linux.do',
  String path = '/latest.json',
  Map<String, dynamic>? extra,
}) {
  return RequestOptions(
    path: 'https://$host$path',
    method: method,
    headers: {'Cookie': '_t=token; cf_clearance=$carried'},
    extra: {...?extra},
  );
}

Headers get _cfHeaders => Headers.fromMap({
  'cf-mitigated': ['challenge'],
  'content-type': ['text/html'],
});

DioException _challenge(RequestOptions options) => DioException.badResponse(
  statusCode: 403,
  requestOptions: options,
  response: Response<dynamic>(
    requestOptions: options,
    statusCode: 403,
    headers: _cfHeaders,
    data: '<title>Just a moment...</title>',
  ),
);

Object _ok(RequestOptions options) =>
    Response<dynamic>(requestOptions: options, statusCode: 200, data: 'ok');

Object _challengeOf(RequestOptions options) => _challenge(options);

Object _networkError(RequestOptions options) => DioException(
  requestOptions: options,
  type: DioExceptionType.connectionError,
  error: 'connection reset',
);

CfRoundOutcome _passed(String value) =>
    CfRoundPassed(round: 1, clearance: value);

ResponseBody get _challengeBody => ResponseBody.fromString(
  '<html><title>Just a moment...</title><script>window._cf_chl_opt={}</script></html>',
  403,
  headers: {
    'cf-mitigated': ['challenge'],
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
  },
);

ResponseBody get _approvePage => ResponseBody.fromString(
  '<html><a href="/oauth2/approve/abc">同意</a></html>',
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
  },
);

// ---------------------------------------------------------------------------
// 替身
// ---------------------------------------------------------------------------

class _FakeJar {
  _FakeJar(this.value);

  String? value;
}

/// 按脚本逐次返回结果；像真实端口一样用 jar 当前值改写 Cookie 头。
class _ScriptedReplay implements CfReplayPort {
  _ScriptedReplay(this.jar, {this.jarOf});

  final _FakeJar jar;
  final String? Function()? jarOf;
  final List<Object Function(RequestOptions)> script = [];
  final List<RequestOptions> calls = [];

  @override
  Future<Response<dynamic>> replay(RequestOptions options) async {
    final current = jarOf != null ? jarOf!() : jar.value;
    options.headers['Cookie'] = '_t=token; cf_clearance=$current';
    calls.add(options);
    final result = script.removeAt(0)(options);
    if (result is DioException) throw result;
    return result as Response<dynamic>;
  }
}

class _FakeClearance implements CfClearancePort {
  _FakeClearance(this.jar);

  final _FakeJar jar;
  String? candidate;
  int swaps = 0;
  Future<void> Function()? onSwap;
  bool assertionsRan = false;

  @override
  Future<String?> currentInJar() async => jar.value;

  @override
  Future<String?> swapInWebViewCandidate({required String? challenged}) async {
    final value = candidate;
    if (value == null || value == challenged) return null;
    if (onSwap != null) {
      await onSwap!();
      assertionsRan = true;
    }
    swaps++;
    candidate = null;
    jar.value = value;
    return value;
  }
}

class _FakeRound implements CfRoundPort {
  _FakeRound(this.jar);

  final _FakeJar jar;
  final List<CfRoundOutcome> outcomes = [];
  final List<CfVerifyMode> modes = [];
  final Set<String> coolingDown = {};
  final List<String> ineffectiveHosts = [];
  Future<void> Function()? onAcquire;
  bool assertionsRan = false;
  int acquired = 0;

  @override
  bool get isVerifying => false;

  @override
  bool get autoVerifyEnabled => true;

  @override
  bool isCoolingDown(String host) => coolingDown.contains(host);

  @override
  Future<CfRoundOutcome> acquire(CfVerifyMode mode) async {
    acquired++;
    modes.add(mode);
    if (onAcquire != null) {
      await onAcquire!();
      assertionsRan = true;
    }
    final outcome = outcomes.removeAt(0);
    // 轮次的契约：通过 = 定稿值已在 jar
    if (outcome case CfRoundPassed(:final clearance)) jar.value = clearance;
    return outcome;
  }

  @override
  void noteIneffective(String host) => ineffectiveHosts.add(host);
}

/// 用真实的 [CfVerificationRounds] 实现轮次端口（合流语义来自它）。
class _RoundsPort implements CfRoundPort {
  _RoundsPort(this.rounds);

  final CfVerificationRounds rounds;

  @override
  bool get isVerifying => rounds.active != null;

  @override
  bool get autoVerifyEnabled => true;

  @override
  bool isCoolingDown(String host) => false;

  @override
  Future<CfRoundOutcome> acquire(CfVerifyMode mode) =>
      rounds.verify(mode: mode);

  @override
  void noteIneffective(String host) {}
}

class _EnvClearance implements CfClearancePort {
  _EnvClearance(this.env);

  final FakeRoundEnvironment env;

  @override
  Future<String?> currentInJar() async => env.jar;

  @override
  Future<String?> swapInWebViewCandidate({required String? challenged}) async =>
      null;
}

class _FakeCompat implements CfCompatPort {
  bool enableResult = false;
  int enabled = 0;
  int rollbacks = 0;

  @override
  bool canUse(RequestOptions options) => true;

  @override
  Future<bool> enable() async {
    if (enableResult) enabled++;
    return enableResult;
  }

  @override
  void rollback() => rollbacks++;
}

/// 真实整链重放（不经 jar）：用于 Dio 适配层测试。
class _DioFetchReplay implements CfReplayPort {
  _DioFetchReplay(this.dio);

  final Dio dio;

  @override
  Future<Response<dynamic>> replay(RequestOptions options) =>
      dio.fetch<dynamic>(options);
}

class _SequenceAdapter implements HttpClientAdapter {
  final List<ResponseBody> responses = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}
