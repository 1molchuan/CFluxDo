import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/cfhub_api.dart';

/// 记录一次假请求
class _Call {
  const _Call(this.path, this.body, this.bearer);

  final String path;
  final Map<String, Object?>? body;
  final String? bearer;
}

/// 固定返回某个状态码和正文的假 cfhub
CfhubApi _api(int status, String responseBody, {List<_Call>? calls}) {
  return CfhubApi(
    post: (path, {body, bearer}) async {
      calls?.add(_Call(path, body, bearer));
      return (status, responseBody);
    },
  );
}

/// 每次请求都抛异常的假 cfhub
CfhubApi _throwing() => CfhubApi(
  post: (path, {body, bearer}) async => throw StateError('boom'),
);

void main() {
  const authorizeUrl =
      'https://connect.linux.do/oauth2/authorize?client_id=x&state=s';

  group('CfhubApi.startConnect', () {
    test('200 且地址是 connect.linux.do 的授权页：返回地址', () async {
      final calls = <_Call>[];
      final result = await _api(
        200,
        jsonEncode({'authorize_url': authorizeUrl}),
        calls: calls,
      ).startConnect();
      expect(result.unavailable, isFalse);
      expect(result.url.toString(), authorizeUrl);
      expect(calls.single.path, '/api/v1/app/connect/start');
      expect(calls.single.body, isEmpty);
      expect(calls.single.bearer, isNull);
    });

    test('不是 connect.linux.do 的地址一律拒绝', () async {
      const bad = [
        'https://evil.example.com/oauth2/authorize?client_id=x',
        'https://connect.linux.do.evil.com/oauth2/authorize',
        'http://connect.linux.do/oauth2/authorize',
        'https://connect.linux.do/other',
        'https://linux.do/oauth2/authorize',
      ];
      for (final url in bad) {
        final result = await _api(
          200,
          jsonEncode({'authorize_url': url}),
        ).startConnect();
        expect(result.url, isNull, reason: url);
        expect(result.unavailable, isFalse, reason: url);
      }
    });

    test('缺字段或不是 JSON：当失败', () async {
      expect((await _api(200, '{}').startConnect()).url, isNull);
      expect((await _api(200, 'not json').startConnect()).url, isNull);
      expect((await _api(200, '[]').startConnect()).url, isNull);
    });

    test('404：hub 未开放', () async {
      final result = await _api(404, '').startConnect();
      expect(result.unavailable, isTrue);
      expect(result.url, isNull);
    });

    test('其他状态码或异常：失败但不是「未开放」', () async {
      for (final status in [401, 403, 500, 502]) {
        final result = await _api(status, '').startConnect();
        expect(result.unavailable, isFalse, reason: '$status');
        expect(result.url, isNull, reason: '$status');
      }
      final thrown = await _throwing().startConnect();
      expect(thrown.unavailable, isFalse);
      expect(thrown.url, isNull);
    });
  });

  group('CfhubApi.exchangeCode', () {
    test('200 且令牌以 cfp_ 开头：ok，并把 code/state 发过去', () async {
      final calls = <_Call>[];
      final result = await _api(
        200,
        jsonEncode({'token': 'cfp_abc123'}),
        calls: calls,
      ).exchangeCode('the-code', 'the-state');
      expect(result.outcome, CfhubTokenOutcome.ok);
      expect(result.token, 'cfp_abc123');
      expect(calls.single.path, '/api/v1/app/token');
      expect(calls.single.body, {'code': 'the-code', 'state': 'the-state'});
      expect(calls.single.bearer, isNull);
    });

    test('令牌格式不对：failed', () async {
      for (final body in [
        jsonEncode({'token': 'abc'}),
        jsonEncode({'token': 'cfp_'}),
        jsonEncode({'token': ''}),
        jsonEncode({'token': 42}),
        jsonEncode({'token': 'cfp_有中文'}),
        '{}',
        'nope',
      ]) {
        final result = await _api(200, body).exchangeCode('c', 's');
        expect(result.outcome, CfhubTokenOutcome.failed, reason: body);
        expect(result.token, isNull, reason: body);
      }
    });

    test('状态码映射：401/403 → rejected，404 → unavailable，其余 → failed', () async {
      expect(
        (await _api(401, '').exchangeCode('c', 's')).outcome,
        CfhubTokenOutcome.rejected,
      );
      expect(
        (await _api(403, '').exchangeCode('c', 's')).outcome,
        CfhubTokenOutcome.rejected,
      );
      expect(
        (await _api(404, '').exchangeCode('c', 's')).outcome,
        CfhubTokenOutcome.unavailable,
      );
      for (final status in [400, 429, 500, 503]) {
        expect(
          (await _api(status, '').exchangeCode('c', 's')).outcome,
          CfhubTokenOutcome.failed,
          reason: '$status',
        );
      }
      expect(
        (await _throwing().exchangeCode('c', 's')).outcome,
        CfhubTokenOutcome.failed,
      );
    });
  });

  group('CfhubApi.revoke', () {
    test('带 Bearer 发到作废接口', () async {
      final calls = <_Call>[];
      await _api(200, '', calls: calls).revoke('cfp_old');
      expect(calls.single.path, '/api/v1/app/token/revoke');
      expect(calls.single.bearer, 'cfp_old');
      expect(calls.single.body, isNull);
    });

    test('失败或异常都吞掉', () async {
      await _api(500, '').revoke('cfp_old');
      await _throwing().revoke('cfp_old');
    });
  });
}
