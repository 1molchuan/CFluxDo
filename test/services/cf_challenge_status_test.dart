import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

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
        CfChallengeService.isCfChallengeError(
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
        CfChallengeService.isCfChallengeError(
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
        CfChallengeService.isCfChallengeError(
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
          CfChallengeService.isCfChallengeError(
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
        CfChallengeService.isCfChallengeError(
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
        CfChallengeService.isCfChallengeError(
          response(503, data: 'service unavailable'),
        ),
        isFalse,
      );
      expect(
        CfChallengeService.isCfChallengeError(response(502)),
        isFalse,
      );
      expect(
        CfChallengeService.isCfChallengeError(
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
      expect(CfChallengeService.isCfChallengeError(null), isFalse);
    });
  });
}
