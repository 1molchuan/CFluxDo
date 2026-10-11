import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/session_check_verdict.dart';

/// 启动时的登录态检查不能把"被盾挡住"当成"会话失效"。
///
/// 事故形态:启动 `/session/current.json` 撞 CF 盾,过盾成功后重试仍被拦,
/// CfChallengeInterceptor 把带 403 的原异常透传出来,`isLoggedIn` 按
/// "403 = 明确拒绝"直接登出。用户的 `_t` 其实完好,却被踢回未登录,
/// 只能重新走一遍登录 + 过盾。
void main() {
  Response<dynamic> response(
    int status, {
    Map<String, List<String>> headers = const {},
    dynamic data,
  }) {
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/session/current.json'),
      statusCode: status,
      headers: Headers.fromMap(headers),
      data: data,
    );
  }

  group('会话确认失效', () {
    test('404 是 Discourse 对无当前用户的标准回应', () {
      expect(
        classifySessionCheckFailure(response(404)),
        SessionCheckVerdict.sessionInvalid,
      );
    });

    test('403 + error_type: not_logged_in', () {
      expect(
        classifySessionCheckFailure(
          response(
            403,
            headers: {
              'content-type': ['application/json'],
            },
            data: {'error_type': 'not_logged_in'},
          ),
        ),
        SessionCheckVerdict.sessionInvalid,
      );
    });

    test('401 + discourse-logged-out 头', () {
      expect(
        classifySessionCheckFailure(
          response(
            401,
            headers: {
              'discourse-logged-out': ['1'],
            },
          ),
        ),
        SessionCheckVerdict.sessionInvalid,
      );
    });
  });

  group('不能据此登出', () {
    test('403 + cf-mitigated: challenge 是 CF 挑战', () {
      expect(
        classifySessionCheckFailure(
          response(
            403,
            headers: {
              'cf-mitigated': ['challenge'],
              'content-type': ['text/plain'],
            },
            data: 'challenge',
          ),
        ),
        SessionCheckVerdict.cfChallenge,
      );
    });

    test('403 挑战页 HTML(缺 cf-mitigated 头)仍识别为 CF 挑战', () {
      expect(
        classifySessionCheckFailure(
          response(
            403,
            headers: {
              'content-type': ['text/html; charset=UTF-8'],
            },
            data: '<html><title>Just a moment...</title>'
                '<script>window._cf_chl_opt={}</script></html>',
          ),
        ),
        SessionCheckVerdict.cfChallenge,
      );
    });

    test('CF 挑战页即使带了登出信号也不算会话失效', () {
      // 挑战页由 CF 边缘直接返回,不可能携带真实的 Discourse 会话结论
      expect(
        classifySessionCheckFailure(
          response(
            403,
            headers: {
              'cf-mitigated': ['challenge'],
              'discourse-logged-out': ['1'],
            },
          ),
        ),
        SessionCheckVerdict.cfChallenge,
      );
    });

    test('无登出信号的 403 视为站点风控,无法确认', () {
      expect(
        classifySessionCheckFailure(
          response(
            403,
            headers: {
              'content-type': ['application/json'],
            },
            data: {'errors': ['您的请求被拒绝']},
          ),
        ),
        SessionCheckVerdict.inconclusive,
        reason: '风控 403 不代表 _t 失效,登出只会让用户白白重登',
      );
    });

    test('5xx 与无响应(网络异常)无法确认', () {
      expect(
        classifySessionCheckFailure(response(502)),
        SessionCheckVerdict.inconclusive,
      );
      expect(
        classifySessionCheckFailure(null),
        SessionCheckVerdict.inconclusive,
      );
    });
  });
}
