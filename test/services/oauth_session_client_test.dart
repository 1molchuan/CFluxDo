import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';
import 'package:fluxdo/services/oauth_session_client.dart';

// 取自上游 v0.2.29。业务 Cookie 轮换/有效期的几条用例依赖上游的 CookieJar
// 测试平台，cfluxdo 的 Cookie 同步是另一套，这里只保留会话读取策略的用例。
class _SessionAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  Object body = {
    'data': {'username': 'alice'},
  };
  final headers = <String, List<String>>{};
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    entered?.complete();
    await gate?.future;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, origin) in [
    ('LDC', 'https://credit.linux.do'),
    ('CDK', 'https://cdk.linux.do'),
  ]) {
    group(name, () {
      late _SessionAdapter adapter;
      late OAuthSessionClient client;
      final uri = Uri.parse('$origin/api/v1/oauth/user-info');

      setUp(() {
        adapter = _SessionAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        client = OAuthSessionClient(
          dio: dio,
          baseUrl: origin,
          serviceName: name,
          state: OAuthSessionState(),
        );
      });
      tearDown(() => client.cancel());

      void onlyUserInfoRequests() {
        expect(adapter.requests, isNotEmpty);
        expect(
          adapter.requests.every((r) => r.uri == uri && r.method == 'GET'),
          isTrue,
        );
      }

      test('正常读取只请求业务接口', () async {
        expect(
          (await client.getUserInfo(expectedUsername: 'alice'))['username'],
          'alice',
        );
        expect(adapter.requests, hasLength(1));
        onlyUserInfoRequests();
      });

      test('业务 401 直接报告过期，不发起自动重新授权', () async {
        adapter.status = 401;
        await expectLater(
          client.getUserInfo(),
          throwsA(isA<OAuthExpiredException>()),
        );
        expect(adapter.requests, hasLength(1));
        onlyUserInfoRequests();
      });

      for (final status in [401, 403, 429]) {
        test('CF 挑战 $status 不误报为授权过期', () async {
          adapter.status = status;
          adapter.headers['cf-mitigated'] = ['challenge'];
          await expectLater(
            client.getUserInfo(),
            throwsA(predicate<Object>(OAuthErrorPolicy.isCfChallenge)),
          );
          onlyUserInfoRequests();
        });
      }

      test('普通 403 保留权限错误，不误报为授权过期', () async {
        adapter.status = 403;
        await expectLater(
          client.getUserInfo(),
          throwsA(
            isA<DioException>()
                .having((e) => e.response?.statusCode, 'status', 403)
                .having(OAuthErrorPolicy.isCfChallenge, 'CF', isFalse),
          ),
        );
        onlyUserInfoRequests();
      });

      test('服务端错误不触发重新授权', () async {
        adapter.status = 500;
        await expectLater(client.getUserInfo(), throwsA(isA<DioException>()));
        onlyUserInfoRequests();
      });

      test('重定向不被当作成功用户信息或自动跳转授权页', () async {
        adapter.status = 302;
        adapter.headers['location'] = [
          'https://connect.linux.do/oauth2/authorize',
        ];
        await expectLater(client.getUserInfo(), throwsA(isA<DioException>()));
        onlyUserInfoRequests();
      });

      test('无效响应不被当作登录过期', () async {
        adapter.body = {'data': null};
        await expectLater(
          client.getUserInfo(),
          throwsA(isA<FormatException>()),
        );
      });

      test('其他账号的业务会话不能覆盖当前账号', () async {
        await expectLater(
          client.getUserInfo(expectedUsername: 'bob'),
          throwsA(isA<OAuthExpiredException>()),
        );
        onlyUserInfoRequests();
      });

      test('取消后旧请求失效，新的用户信息请求仍可正常执行', () async {
        adapter.gate = Completer<void>();
        adapter.entered = Completer<void>();
        final old = client.getUserInfo();
        final rejected = expectLater(
          old,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await adapter.entered!.future;
        client.cancel();
        adapter.gate!.complete();
        await rejected;
        adapter.gate = null;
        adapter.entered = null;
        expect((await client.getUserInfo())['username'], 'alice');
      });

      test('主站切换账号后丢弃旧账号的业务响应', () async {
        adapter.gate = Completer<void>();
        adapter.entered = Completer<void>();
        final old = client.getUserInfo();
        final rejected = expectLater(
          old,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await adapter.entered!.future;
        AuthSession().advance();
        adapter.gate!.complete();
        await rejected;
      });

      test('通过 CF 后立即重试读取，不受后台授权冷却限制', () async {
        adapter.status = 403;
        adapter.headers['cf-mitigated'] = ['challenge'];
        await expectLater(
          client.getUserInfo(),
          throwsA(predicate<Object>(OAuthErrorPolicy.isCfChallenge)),
        );
        adapter.status = 200;
        adapter.headers.clear();
        expect((await client.getUserInfo())['username'], 'alice');
        onlyUserInfoRequests();
      });
    });
  }
}
