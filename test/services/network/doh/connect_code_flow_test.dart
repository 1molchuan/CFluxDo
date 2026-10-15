import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/connect_code_flow.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';

DioException _bad(
  int status, {
  Map<String, List<String>>? headers,
  Object? body,
}) {
  final options = RequestOptions(
    path: 'https://connect.linux.do/oauth2/authorize',
  );
  return DioException.badResponse(
    statusCode: status,
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      headers: Headers.fromMap(headers ?? const {}),
      data: body,
    ),
  );
}

DioException _cf(CfChallengeException error) => DioException(
  requestOptions: RequestOptions(path: 'https://connect.linux.do/'),
  error: error,
);

void main() {
  group('ConnectCodeFlow.classifyFailure', () {
    test('关掉了过盾验证页：cancelled', () {
      final result = ConnectCodeFlow.classifyFailure(
        _cf(CfChallengeException(userCancelled: true)),
      );
      expect(result.outcome, ConnectCodeOutcome.cancelled);
      expect(result.retryable, isFalse);
    });

    test('过盾恢复走完仍被拦（冷却中 / 关了自动验证 / 仍是挑战页）：challenge，不重来', () {
      for (final e in [
        _cf(CfChallengeException(inCooldown: true)),
        _cf(CfChallengeException(autoVerifyDisabled: true)),
        _bad(
          403,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      ]) {
        final result = ConnectCodeFlow.classifyFailure(e);
        expect(result.outcome, ConnectCodeOutcome.failed);
        expect(result.failureDetail, 'challenge');
        expect(result.retryable, isFalse);
      }
    });

    test('普通 4xx/5xx（含 Discourse 自己的 JSON 403）：带状态码，可重来', () {
      for (final (status, type) in [
        (403, 'application/json'),
        (404, 'text/html'),
        (502, 'text/html'),
      ]) {
        final result = ConnectCodeFlow.classifyFailure(
          _bad(
            status,
            headers: {
              'content-type': [type],
            },
            body: '{"errors":["x"]}',
          ),
        );
        expect(result.outcome, ConnectCodeOutcome.failed);
        expect(result.failureDetail, 'HTTP $status');
        expect(result.retryable, isTrue);
      }
    });

    test('没有响应的网络错误：带错误类型，可重来', () {
      final result = ConnectCodeFlow.classifyFailure(
        DioException.connectionTimeout(
          timeout: const Duration(seconds: 30),
          requestOptions: RequestOptions(path: 'https://connect.linux.do/'),
        ),
      );
      expect(result.outcome, ConnectCodeOutcome.failed);
      expect(result.failureDetail, 'connectionTimeout');
      expect(result.retryable, isTrue);
    });
  });
}
