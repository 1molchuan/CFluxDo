import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_full_info.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/session_cookie_sentinel.dart';

/// 只记录写入的假 jar：Sentinel 反向同步只会调 setCookie / setSessionTokenTrusted
/// （`_t` 两者都不该调）
class _RecordingJar implements CookieJarService {
  final List<Map<String, Object?>> setCookieCalls = [];
  final List<Map<String, Object?>> trustedTokenCalls = [];

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
    setCookieCalls.add({
      'name': name,
      'value': value,
      'expires': expires,
      'trusted': trusted,
    });
  }

  @override
  Future<void> setSessionTokenTrusted(String value, {DateTime? expires}) async {
    trustedTokenCalls.add({'value': value, 'expires': expires});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final sentinel = SessionCookieSentinel.instance;
  late _RecordingJar jar;

  setUp(() {
    jar = _RecordingJar();
    sentinel.replaceDependenciesForTest(jar: jar);
  });

  tearDown(() {
    sentinel.replaceDependenciesForTest(jar: CookieJarService());
  });

  group('Sentinel winner 反向同步到 jar', () {
    test(
      'WebView 的 _t 不由 Sentinel 写进 jar（采纳与否只由 SessionTokenAuthority 决定）',
      () async {
        await sentinel.syncWinnerToJarForTest(
          'https://linux.do',
          CookieFullInfo(name: '_t', value: 'token-v2', domain: 'linux.do'),
        );
        await sentinel.syncWinnerToJarForTest(
          'https://linux.do',
          CookieFullInfo(
            name: '_t',
            value: 'token-v3',
            expiresMillis: DateTime.utc(2026, 12, 14, 8).millisecondsSinceEpoch,
          ),
        );

        expect(jar.setCookieCalls, isEmpty);
        expect(jar.trustedTokenCalls, isEmpty);
      },
    );

    test('其他 cookie 行为不变：_forum_session 仍可信写入、不补过期时间', () async {
      await sentinel.syncWinnerToJarForTest(
        'https://linux.do',
        CookieFullInfo(name: '_forum_session', value: 'fs'),
      );

      expect(jar.trustedTokenCalls, isEmpty);
      expect(jar.setCookieCalls, [
        {
          'name': '_forum_session',
          'value': 'fs',
          'expires': null,
          'trusted': true,
        },
      ]);
    });
  });
}
