import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/ld_store/ld_store_models.dart';
import 'package:fluxdo/services/ld_store/ld_store_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ld_store_test_support.dart';

const _init = 'https://api1.ldspro.qzz.io/api/auth/init';
const _authorize = 'https://connect.linux.do/oauth2/authorize';
const _approve = 'https://connect.linux.do/oauth2/approve/abc123';
const _callback = 'https://api.ldspro.qzz.io/api/auth/callback';
const _verify = 'https://api2.ldspro.qzz.io/api/shop/auth/verify';
const _attention = 'https://api2.ldspro.qzz.io/api/shop/user/attention';
const _unread = 'https://api2.ldspro.qzz.io/api/shop/messages/unread-summary';

String _authUrl({String redirect = _callback}) => Uri.parse(_authorize)
    .replace(
      queryParameters: {
        'client_id': 'client',
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid profile',
        'state': 'linux.do:state',
      },
    )
    .toString();

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const SizedBox.shrink(),
      ),
    ),
  );
}

void main() {
  final now = DateTime.now();
  final jwt = ldStoreJwt(expiresAt: now.add(const Duration(days: 7)));
  final landing =
      'https://ldcstore.com/auth/callback?redirect=%2F#ldsp_oauth=${ldStoreLoginParam(jwt)}';

  late RoutingAdapter store;
  late RoutingAdapter forum;
  late MemorySecretStore secrets;
  late LdStoreService service;

  Map<String, FakeRoute Function(RequestOptions)> storeRoutes({
    String? authUrl,
    String? landingUrl,
    Object verifiedUser = const {'id': 12345, 'site': 'linux.do'},
  }) => {
    _init: (_) => FakeRoute(
      200,
      body: {
        'success': true,
        'data': {'auth_url': authUrl ?? _authUrl(), 'state': 'linux.do:state'},
      },
    ),
    _callback: (_) => FakeRoute(302, location: landingUrl ?? landing),
    _verify: (_) => FakeRoute(
      200,
      body: {
        'success': true,
        'data': {'authenticated': true, 'user': verifiedUser},
      },
    ),
  };

  Map<String, FakeRoute Function(RequestOptions)> forumRoutes({
    String approveLocation = '$_callback?code=thecode&state=linux.do:state',
  }) => {
    _authorize: (_) => FakeRoute(
      200,
      body: '<html><a href="/oauth2/approve/abc123">允许</a></html>',
    ),
    _approve: (_) => FakeRoute(302, location: approveLocation),
  };

  void build({
    Map<String, FakeRoute Function(RequestOptions)>? storeRoutesOverride,
    Map<String, FakeRoute Function(RequestOptions)>? forumRoutesOverride,
  }) {
    store = RoutingAdapter(storeRoutesOverride ?? storeRoutes());
    forum = RoutingAdapter(forumRoutesOverride ?? forumRoutes());
    secrets = MemorySecretStore();
    service = LdStoreService(
      storeDio: Dio()..httpClientAdapter = store,
      forumDio: Dio()..httpClientAdapter = forum,
      secretStore: secrets,
      gap: ({required minMs, required maxMs}) async {},
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('授权：确认前不发同意请求，确认后取回、校验并存好凭据', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build();
      final pending = await service.beginAuthorization();
      expect(pending.approveUrl.toString(), _approve);
      expect(forum.requests.map((r) => r.uri.path), ['/oauth2/authorize']);
      expect(store.requests.single.uri.queryParameters, {
        'site': 'linux.do',
        'return_url': 'https://ldcstore.com/auth/callback?redirect=%2F',
      });

      final token = await service.completeAuthorization(
        pending,
        expectedUsername: 'Alice',
      );
      expect(token.value, jwt);
      expect(forum.requests.last.uri.toString(), _approve);
      // 回调与校验都走商城 Dio，且不带论坛 Cookie
      final callback = store.requests.firstWhere(
        (r) => r.uri.path == '/api/auth/callback',
      );
      expect(callback.uri.queryParameters['code'], 'thecode');
      expect(callback.extra[FluxRequestKeys.skipRedirect], isTrue);
      final verify = store.requests.last;
      expect(verify.uri.toString(), _verify);
      expect(verify.headers['Authorization'], 'Bearer $jwt');
      expect(store.requests.every((r) => r.headers['cookie'] == null), isTrue);

      expect((await service.loadToken('alice'))?.value, jwt);
    });
  });

  testWidgets('商城后端回 200 的「正在跳转」页时，从页面里取落点', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      // 与商城后端的回调页同一写法：base64(quote(json)) 再 quote，
      // 地址同时出现在「返回」按钮与 location.replace 的参数里
      final encoded = base64.encode(
        utf8.encode(
          Uri.encodeComponent(
            jsonEncode({
              't': jwt,
              'u': {'id': 12345, 'site': 'linux.do', 'username': 'alice'},
              'j': 1,
              'e': 604800,
              'ts': 1,
            }),
          ),
        ),
      );
      final redirect =
          'https://ldcstore.com/auth/callback?redirect=%2F#ldsp_oauth='
          '${Uri.encodeComponent(encoded).replaceAll('%2F', '/')}';
      final page =
          '''<!DOCTYPE html><html><head><title>LDStatus Pro - 授权完成</title></head>
<body><div class="container"><div class="title">授权成功</div>
<a class="action-btn hidden" id="returnBtn" href="$redirect">返回</a></div>
<script>(function() { const success = true; const redirectUrl = ${jsonEncode(redirect)};
setTimeout(() => { window.location.replace(redirectUrl); }, 500); })();</script>
</body></html>''';
      build(
        storeRoutesOverride: {
          ...storeRoutes(),
          _callback: (_) => FakeRoute(200, body: page),
        },
      );
      final pending = await service.beginAuthorization();
      final token = await service.completeAuthorization(
        pending,
        expectedUsername: 'alice',
      );
      expect(token.value, jwt);
      expect((await service.loadToken('alice'))?.value, jwt);
    });
  });

  testWidgets('商城后端换 code 失败时带出它的说明', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build(
        storeRoutesOverride: {
          ...storeRoutes(),
          _callback: (_) => FakeRoute(
            500,
            body: {
              'success': false,
              'error': {
                'code': 'OAUTH_CALLBACK_ERROR',
                'message': '使用授权码换取访问令牌失败',
              },
            },
          ),
        },
      );
      final pending = await service.beginAuthorization();
      await expectLater(
        service.completeAuthorization(pending, expectedUsername: 'alice'),
        throwsA(predicate((e) => e.toString().contains('使用授权码换取访问令牌失败'))),
      );
      expect(secrets.values, isEmpty);
    });
  });

  testWidgets('授权页先经论坛 SSO 跳转时跟到底；以前同意过时直接拿到回调', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      var authorizeCalls = 0;
      build(
        forumRoutesOverride: {
          ...forumRoutes(),
          _authorize: (_) => authorizeCalls++ == 0
              ? FakeRoute(
                  302,
                  location: 'https://linux.do/session/sso_provider?sso=x',
                )
              : FakeRoute(
                  302,
                  location: '$_callback?code=direct&state=linux.do:state',
                ),
          'https://linux.do/session/sso_provider': (_) =>
              FakeRoute(302, location: _authUrl()),
        },
      );
      final pending = await service.beginAuthorization();
      expect(pending.approveUrl, isNull);
      expect(pending.callbackUrl?.queryParameters['code'], 'direct');
      expect(forum.requests.map((r) => r.uri.host), [
        'connect.linux.do',
        'linux.do',
        'connect.linux.do',
      ]);
      final token = await service.completeAuthorization(
        pending,
        expectedUsername: 'alice',
      );
      expect(token.value, jwt);
    });
  });

  testWidgets('授权地址不是商城登记的回调就不打开授权页', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build(
        storeRoutesOverride: storeRoutes(
          authUrl: _authUrl(redirect: 'https://evil.example/callback'),
        ),
      );
      await expectLater(service.beginAuthorization(), throwsException);
      expect(forum.requests, isEmpty);
    });
  });

  testWidgets('授权页跳到别的域名就停下', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build(
        forumRoutesOverride: {
          _authorize: (_) =>
              FakeRoute(302, location: 'https://evil.example/phish'),
        },
      );
      await expectLater(service.beginAuthorization(), throwsException);
      expect(forum.requests.length, 1);
    });
  });

  testWidgets('同意后跳去的不是商城回调、或回跳落点不是商城，都不存凭据', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build(
        forumRoutesOverride: forumRoutes(
          approveLocation: 'https://evil.example/cb?code=x&state=y',
        ),
      );
      var pending = await service.beginAuthorization();
      await expectLater(
        service.completeAuthorization(pending, expectedUsername: 'alice'),
        throwsException,
      );
      expect(
        store.requests.where((r) => r.uri.path == '/api/auth/callback'),
        isEmpty,
      );

      build(
        storeRoutesOverride: storeRoutes(
          landingUrl:
              'https://evil.example/auth/callback#ldsp_oauth=${ldStoreLoginParam(jwt)}',
        ),
      );
      pending = await service.beginAuthorization();
      await expectLater(
        service.completeAuthorization(pending, expectedUsername: 'alice'),
        throwsException,
      );
      expect(secrets.values, isEmpty);
    });
  });

  testWidgets('商城校验不通过或不是当前论坛账号，都不存凭据', (tester) async {
    await _pumpApp(tester);
    await tester.runAsync(() async {
      build(
        storeRoutesOverride: storeRoutes(
          verifiedUser: const {'id': 999, 'site': 'linux.do'},
        ),
      );
      var pending = await service.beginAuthorization();
      await expectLater(
        service.completeAuthorization(pending, expectedUsername: 'alice'),
        throwsException,
      );

      build();
      pending = await service.beginAuthorization();
      await expectLater(
        service.completeAuthorization(pending, expectedUsername: 'bob'),
        throwsException,
      );
      expect(secrets.values, isEmpty);
    });
  });

  group('凭据与个人数据', () {
    testWidgets('读待办与未读；401 当作授权失效', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        var unauthorized = false;
        build(
          storeRoutesOverride: {
            _attention: (_) => unauthorized
                ? FakeRoute(401, body: {'success': false})
                : FakeRoute(
                    200,
                    body: {
                      'success': true,
                      'data': {
                        'pending_payment_count': 1,
                        'awaitingDeliveryCount': 2,
                        'unusedCouponCount': 3,
                      },
                    },
                  ),
            _unread: (_) => FakeRoute(
              200,
              body: {
                'success': true,
                'data': {'totalUnread': 4},
              },
            ),
          },
        );
        final token = LdStoreToken.parse(jwt)!;
        final account = await service.fetchAccount(token);
        expect(account.attention.pendingPayment, 1);
        expect(account.attention.awaitingDelivery, 2);
        expect(account.attention.unusedCoupons, 3);
        expect(account.unreadMessages, 4);
        expect(
          store.requests.every(
            (r) => r.headers['Authorization'] == 'Bearer $jwt',
          ),
          isTrue,
        );

        unauthorized = true;
        await expectLater(
          service.fetchAccount(token),
          throwsA(isA<LdStoreAuthExpiredException>()),
        );
      });
    });

    testWidgets('凭据按论坛账号分开存：切到别的账号读不到，切回来还在', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        build();
        await service.saveToken('alice', LdStoreToken.parse(jwt)!);
        expect(await service.loadToken('bob'), isNull);
        expect((await service.loadToken('alice'))?.value, jwt);
        expect(await service.loadRevocation(), isNull);
      });
    });

    testWidgets('切走账号：凭据留着，只让内置浏览器里那枚失效', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        build();
        await service.saveToken('alice', LdStoreToken.parse(jwt)!);
        await service.revokeWebSessionFor('alice');
        final revocation = (await service.loadRevocation())!;
        expect(revocation.userId, '12345');
        expect(revocation.site, 'linux.do');
        expect((await service.loadToken('alice'))?.value, jwt);

        // 重新授权后不再清网页里的凭据
        await service.saveToken('bob', LdStoreToken.parse(jwt)!);
        expect(await service.loadRevocation(), isNull);
      });
    });

    testWidgets('论坛退出登录：删掉最近用过的那个账号的凭据并记下', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        build();
        await service.saveToken('alice', LdStoreToken.parse(jwt)!);
        await service.signOut();
        expect(secrets.values, isEmpty);
        expect((await service.loadRevocation())?.userId, '12345');
      });
    });

    testWidgets('旧版只存一份的凭据搬进它自己账号的槽', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        build();
        await secrets.write(
          const SecretKey(
            namespace: 'ld_store',
            name: 'session',
            fallbackPolicy: SecretFallbackPolicy.memoryOnly,
          ),
          jsonEncode({'username': 'alice', 'token': jwt}),
        );
        expect(await service.loadToken('bob'), isNull);
        expect((await service.loadToken('alice'))?.value, jwt);
        expect(secrets.values, hasLength(1));
      });
    });

    testWidgets('存的凭据已到期：清掉并报授权失效', (tester) async {
      await _pumpApp(tester);
      await tester.runAsync(() async {
        build();
        final expired = ldStoreJwt(
          expiresAt: now.subtract(const Duration(minutes: 1)),
        );
        await service.saveToken('alice', LdStoreToken.decode(expired)!);
        await expectLater(
          service.loadToken('alice'),
          throwsA(isA<LdStoreAuthExpiredException>()),
        );
        expect(secrets.values, isEmpty);
        expect(await service.loadToken('alice'), isNull);
      });
    });
  });

  group('内置浏览器登录态脚本', () {
    test('只在商城主框架、文档开始时跑，带上凭据身份', () {
      final token = LdStoreToken.parse(jwt)!;
      final script = LdStoreService.webSessionScript(token: token)!;
      expect(script.forMainFrameOnly, isTrue);
      expect(script.allowedOriginRules, {'https://ldcstore.com'});
      expect(
        script.source,
        contains("location.origin !== 'https://ldcstore.com'"),
      );
      final config = jsonDecode(
        RegExp(r'var config = (\{.*?\});').firstMatch(script.source)!.group(1)!,
      );
      expect(config['key'], 'ld_store_token');
      expect(config['token']['value'], jwt);
      expect(config['token']['sub'], '12345');
      expect(config.containsKey('revoked'), isFalse);
    });

    test('没授权也没退出过就不注入', () {
      expect(LdStoreService.webSessionScript(), isNull);
      final revoked = LdStoreService.webSessionScript(
        revocation: LdStoreRevocation(
          userId: '12345',
          site: 'linux.do',
          expiresAt: now.add(const Duration(days: 1)),
        ),
      )!;
      expect(revoked.source, contains('"revoked"'));
      expect(revoked.source, isNot(contains('"token"')));
    });
  });
}
