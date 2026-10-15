import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_challenge_classifier.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';

/// 挑战识别不能只认 403/429。
///
/// CF 的 Under Attack 等模式会用 503 返回挑战页。此前拦截器只认 403/429,
/// 503 挑战先被 TransientRetry 白白重放三轮(撞三次盾),最后 ErrorInterceptor
/// 把它包装成"服务器暂不可用",用户永远等不到验证页。
void main() {
  Response<dynamic> response(
    int status, {
    Map<String, List<String>> headers = const {},
    dynamic data,
  }) {
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/latest.json'),
      statusCode: status,
      headers: Headers.fromMap(headers),
      data: data,
    );
  }

  const challengeHtml =
      '<html><title>Just a moment...</title>'
      '<script>window._cf_chl_opt={}</script></html>';

  group('识别为挑战', () {
    test('503 + cf-mitigated: challenge', () {
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(
            503,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          ),
        ),
        isTrue,
      );
    });

    test('503 挑战页 HTML(缺 cf-mitigated 头)', () {
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(
            503,
            headers: {
              'content-type': ['text/html'],
            },
            data: challengeHtml,
          ),
        ),
        isTrue,
      );
    });

    test('cf-mitigated 是权威信号,任意状态码命中都算', () {
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(
            400,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          ),
        ),
        isTrue,
      );
    });

    test('原有 403/429 识别不受影响', () {
      for (final status in [403, 429]) {
        expect(
          CfChallengeClassifier.isChallengeResponse(
            response(
              status,
              headers: {
                'content-type': ['text/html'],
              },
              data: challengeHtml,
            ),
          ),
          isTrue,
          reason: 'status=$status',
        );
      }
    });
  });

  group('不识别为挑战', () {
    test('非挑战状态码的 HTML 即使引用挑战脚本也不算', () {
      // 例如 404 页面或帖子内容恰好包含 cf_chl_opt 字样
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(
            404,
            headers: {
              'content-type': ['text/html'],
            },
            data: challengeHtml,
          ),
        ),
        isFalse,
      );
    });

    test('普通 503 / 502 / Discourse 自己的 403', () {
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(503, data: 'service unavailable'),
        ),
        isFalse,
      );
      expect(
        CfChallengeClassifier.isChallengeResponse(response(502)),
        isFalse,
      );
      expect(
        CfChallengeClassifier.isChallengeResponse(
          response(
            403,
            headers: {
              'content-type': ['application/json'],
            },
            data: {'error_type': 'invalid_access'},
          ),
        ),
        isFalse,
      );
    });

    test('无响应', () {
      expect(CfChallengeClassifier.isChallengeResponse(null), isFalse);
    });
  });

  // 以前 WebView bootstrap 脚本与关注列表轮询各自写死 `403 || 429`,
  // 把 Discourse 的 BAD CSRF 403、真限流 429 也当成撞盾。现在它们与拦截器
  // 问的是同一个分类器。
  group('原始信号与失败判定(bootstrap / 业务层共用口径)', () {
    test('Discourse 自己的 403 / 真限流 429 不是挑战', () {
      expect(
        CfChallengeClassifier.isChallenge(
          statusCode: 403,
          contentType: 'application/json; charset=utf-8',
          body: '["BAD CSRF"]',
        ),
        isFalse,
      );
      expect(
        CfChallengeClassifier.isChallenge(
          statusCode: 429,
          contentType: 'application/json',
          body: '{"error_type":"rate_limit"}',
        ),
        isFalse,
      );
    });

    test('cf-mitigated 头或挑战页标记命中即是挑战', () {
      expect(
        CfChallengeClassifier.isChallenge(
          statusCode: 403,
          cfMitigated: 'challenge',
        ),
        isTrue,
      );
      expect(
        CfChallengeClassifier.isChallenge(
          statusCode: 429,
          contentType: 'text/html; charset=UTF-8',
          body: challengeHtml,
        ),
        isTrue,
      );
    });

    test('CF 拦截器收口后的无 response 异常也算撞盾', () {
      final options = RequestOptions(path: '/u/a.json');
      expect(
        CfChallengeClassifier.isChallengeFailure(
          DioException(
            requestOptions: options,
            error: CfChallengeException(inCooldown: true),
          ),
        ),
        isTrue,
      );
      expect(
        CfChallengeClassifier.isChallengeFailure(
          CfChallengeException(userCancelled: true),
        ),
        isTrue,
      );
      expect(
        CfChallengeClassifier.isChallengeFailure(
          DioException.badResponse(
            statusCode: 403,
            requestOptions: options,
            response: response(
              403,
              headers: {
                'content-type': ['application/json'],
              },
              data: {'error_type': 'invalid_access'},
            ),
          ),
        ),
        isFalse,
        reason: '资料隐藏等业务 403 不该让轮询整体挂起',
      );
      expect(CfChallengeClassifier.isChallengeFailure(StateError('x')), isFalse);
    });
  });
}
