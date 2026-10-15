import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../../session/session_token_fakes.dart';

void main() {
  group('AppCookieManager.loadCookies', () {
    test('忽略 RequestOptions 上残留的旧 Cookie 头，始终使用 CookieJar 最新值', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [Cookie('_t', 'new-token')..path = '/']);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
        headers: {HttpHeaders.cookieHeader: '_t=old-token; other=legacy'},
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=new-token');
      expect(cookieHeader, isNot(contains('old-token')));
      expect(cookieHeader, isNot(contains('other=legacy')));
    });

    test('同名同 path 冲突时优先使用 host-only 会话 Cookie', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('_t', 'host-token')..path = '/',
        Cookie('_t', 'domain-token')
          ..domain = '.linux.do'
          ..path = '/',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=host-token');
      expect(cookieHeader, isNot(contains('domain-token')));
    });

    test('会话 Cookie 即使 path 不同也只发送主站根路径 winner', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('_t', 'root-token')..path = '/',
        Cookie('_t', 'scoped-token')..path = '/session',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, '_t=root-token');
      expect(cookieHeader, isNot(contains('scoped-token')));
    });

    test('会话 Cookie 的 domain 污染副本不会发送到子域名', () async {
      final jar = CookieJar();
      await jar.saveFromResponse(Uri.parse('https://linux.do'), [
        Cookie('_t', 'polluted-token')
          ..domain = '.linux.do'
          ..path = '/',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/api/v1/oauth/user-info',
        baseUrl: 'https://cdk.linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, isEmpty);
    });

    test('非会话同名不同 path Cookie 仍按 RFC 同时发送', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/session/csrf');
      await jar.saveFromResponse(uri, [
        Cookie('theme', 'root')..path = '/',
        Cookie('theme', 'scoped')..path = '/session',
      ]);

      final manager = AppCookieManager(jar);
      final options = RequestOptions(
        path: '/session/csrf',
        baseUrl: 'https://linux.do',
        method: 'GET',
      );

      final cookieHeader = await manager.loadCookies(options);

      expect(cookieHeader, contains('theme=scoped'));
      expect(cookieHeader, contains('theme=root'));
    });

    test('cf_clearance 同名多枚时取过期最新那枚(取新兜底),与顺序无关', () {
      // cf_clearance 单向流(WV→jar),正常只有一枚;万一 jar 里同名多枚,
      // 兜底按过期时间取最新(后签发=当前有效),与值长度/插入顺序无关。
      final now = DateTime.now();
      final older = Cookie('cf_clearance', 'older-value')
        ..domain = '.linux.do'
        ..path = '/'
        ..secure = true
        ..httpOnly = true
        ..expires = now.add(const Duration(hours: 1));
      final newer = Cookie('cf_clearance', 'newer-value')
        ..domain = '.linux.do'
        ..path = '/'
        ..secure = true
        ..httpOnly = true
        ..expires = now.add(const Duration(days: 30));

      for (final cookies in [
        [older, newer],
        [newer, older],
      ]) {
        final selected = AppCookieManager.selectCookiesForTest(
          cookies,
          Uri.parse('https://linux.do/topics/timings'),
        );
        final clearance = selected.where((c) => c.name == 'cf_clearance');
        expect(clearance, hasLength(1));
        expect(clearance.first.value, 'newer-value');
      }
    });
  });

  group('CookieJarService.buildCookieHeaderForRequest', () {
    test('CDK retry header 保留业务 domain cookie 且不带主站登录 cookie', () {
      final header = CookieJarService.buildCookieHeaderForRequest([
        Cookie('cf_clearance', 'cf-token')
          ..domain = '.linux.do'
          ..path = '/',
        Cookie('linux_do_cdk_session_id', 'cdk-token')
          ..domain = '.linux.do'
          ..path = '/',
        Cookie('_t', 'polluted-token')
          ..domain = '.linux.do'
          ..path = '/',
      ], Uri.parse('https://cdk.linux.do/api/v1/oauth/user-info'));

      expect(header, contains('cf_clearance=cf-token'));
      expect(header, contains('linux_do_cdk_session_id=cdk-token'));
      expect(header, isNot(contains('_t=')));
    });

    test('cf_clearance 同名多枚时取过期最新那枚(取新兜底),与顺序无关', () {
      final now = DateTime.now();
      final older = Cookie('cf_clearance', 'older-value')
        ..domain = '.linux.do'
        ..path = '/'
        ..expires = now.add(const Duration(hours: 1));
      final newer = Cookie('cf_clearance', 'newer-value')
        ..domain = '.linux.do'
        ..path = '/'
        ..expires = now.add(const Duration(days: 30));

      for (final cookies in [
        [older, newer],
        [newer, older],
      ]) {
        final header = CookieJarService.buildCookieHeaderForRequest(
          cookies,
          Uri.parse('https://linux.do/topics/timings'),
        );
        expect(header, contains('newer-value'));
        expect(header, isNot(contains('older-value')));
      }
    });
  });

  group('AppCookieManager.classifySessionCookieDeletion', () {
    SessionCookieDeletionPolicy classify({
      String name = '_t',
      int statusCode = 200,
      bool loggedOutHeader = false,
      bool notLoggedIn = false,
    }) => AppCookieManager.classifySessionCookieDeletion(
      name: name,
      statusCode: statusCode,
      hasLoggedOutHeader: loggedOutHeader,
      hasNotLoggedInError: notLoggedIn,
    );

    test('4xx 或 not_logged_in 的删除指令照常执行', () {
      expect(classify(statusCode: 403), SessionCookieDeletionPolicy.apply);
      expect(
        classify(statusCode: 403, loggedOutHeader: true),
        SessionCookieDeletionPolicy.apply,
      );
      expect(
        classify(statusCode: 200, notLoggedIn: true),
        SessionCookieDeletionPolicy.apply,
      );
      expect(
        classify(name: '_forum_session', statusCode: 404),
        SessionCookieDeletionPolicy.apply,
      );
    });

    test('2xx + discourse-logged-out 矛盾信号对两种会话 cookie 都拦下', () {
      expect(
        classify(loggedOutHeader: true),
        SessionCookieDeletionPolicy.blockMixedSignal,
      );
      expect(
        classify(name: '_forum_session', loggedOutHeader: true),
        SessionCookieDeletionPolicy.blockMixedSignal,
      );
    });

    test('2xx 静默删 _t：jar 里的值不动，交 SessionTokenAuthority 请求一次探测', () async {
      final jar = CookieJar();
      final uri = Uri.parse('https://linux.do/latest.json');
      await jar.saveFromResponse(uri, [Cookie('_t', 'T1')..path = '/']);
      final rig = SessionTokenRig(jar: 'T1', webView: 'T1');
      final manager = AppCookieManager(jar, sessionToken: rig.authority);
      final options = RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
        headers: {HttpHeaders.cookieHeader: '_t=T1'},
      );

      await manager.saveCookies(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          headers: Headers.fromMap({
            HttpHeaders.setCookieHeader: [
              '_t=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
            ],
          }),
          data: const {},
        ),
      );

      final cookies = await jar.loadForRequest(uri);
      expect(cookies.singleWhere((c) => c.name == '_t').value, 'T1');
      expect(rig.server.deletionSignals, hasLength(1));
    });

    test('2xx 无登出头删 _t 交 probe 判定，_forum_session 照常删', () {
      expect(classify(), SessionCookieDeletionPolicy.deferToProbe);
      expect(classify(statusCode: 302), SessionCookieDeletionPolicy.deferToProbe);
      expect(
        classify(name: '_forum_session'),
        SessionCookieDeletionPolicy.apply,
      );
    });
  });
}
