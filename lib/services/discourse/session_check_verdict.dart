import 'package:dio/dio.dart';

import '../network/cf/cf_challenge_classifier.dart';

/// 登录态检查（`/session/current.json`）失败响应的判定结果。
enum SessionCheckVerdict {
  /// 服务端明确确认会话已失效，应登出
  sessionInvalid,

  /// 被 CF 挑战页拦截，与会话本身无关
  cfChallenge,

  /// 无法确认（站点风控 403、网关错误、网络异常等），应保留本地登录态
  inconclusive,
}

/// 判定登录态检查的失败响应是否**确认**会话已失效。
///
/// 事故形态：启动时 `/session/current.json` 撞 CF 盾，过盾成功后重试仍被
/// 拦（clearance 对 Dio 无效、出口 IP 不一致等），CfChallengeInterceptor
/// 把带 403 响应的原异常透传出来，旧逻辑把"403 = 明确拒绝"直接登出——
/// 用户只是被盾挡了一下，却被踢回未登录。
///
/// 口径：
/// - CF 挑战页无论什么状态码都不是会话问题；
/// - 404 是 Discourse 对"无当前用户"的标准回应（session_controller#current）；
/// - 401/403 必须带会话失效信号（`discourse-logged-out` 头或
///   `error_type: not_logged_in`）才算确认，否则多半是站点风控/WAF；
/// - 其余一律无法确认。真失效时后续业务请求会经 strike → probe 机制收口，
///   这里保守放过不会造成"假在线"长期滞留。
SessionCheckVerdict classifySessionCheckFailure(Response? response) {
  if (response == null) return SessionCheckVerdict.inconclusive;
  if (CfChallengeClassifier.isChallengeResponse(response)) {
    return SessionCheckVerdict.cfChallenge;
  }

  final status = response.statusCode;
  if (status == 404) return SessionCheckVerdict.sessionInvalid;
  if (status == 401 || status == 403) {
    final hasLoggedOutHeader =
        response.headers.value('discourse-logged-out')?.isNotEmpty == true;
    final data = response.data;
    final isNotLoggedIn = data is Map && data['error_type'] == 'not_logged_in';
    if (hasLoggedOutHeader || isNotLoggedIn) {
      return SessionCheckVerdict.sessionInvalid;
    }
  }
  return SessionCheckVerdict.inconclusive;
}
