import 'package:dio/dio.dart';

import '../exceptions/api_exception.dart';

/// 「这是不是 Cloudflare 挑战？」的**唯一判定口**。
///
/// 此前至少有四套口径各自为政：拦截器的 `isCfChallengeError`（限定状态码）、
/// 会话检查的 `isCfChallengeResponse`（不限状态码）、WebView session bootstrap
/// 脚本里的 `403 || 429`、关注列表轮询的 `403 || 429`。后两者把 Discourse
/// 自己的 403（BAD CSRF、资料隐藏）和真限流 429 也当成撞盾，前两者又对同一
/// 个响应可能给出不同答案。现在所有调用方（Dio 拦截器、恢复策略、会话检查、
/// bootstrap 结果、业务层退避）都只问这里。
///
/// 判定规则：
/// - `cf-mitigated: challenge` 是 CF 官方权威信号，任意状态码命中都算；
///   CF 按请求的 Accept 决定挑战页形态（HTML / text/plain），但两者都带这个头。
/// - 没有该头时只在 403/429/503 上用响应体兜底：挑战页一定是 text/html，
///   content-type 明确是别的类型就排除（Discourse 的 JSON/纯文本 403）；
///   content-type 缺失时放行到响应体判定（部分传输通道会丢头），
///   [hasChallengeMarkers] 的标记足够特异，不会误伤业务响应。
/// - 其他状态码的 HTML（如 404 页面恰好引用了挑战脚本）不算挑战。
class CfChallengeClassifier {
  CfChallengeClassifier._();

  /// CF 挑战可能使用的状态码：
  /// - 403：普通 CF 盾（WAF / bot fight / managed challenge）
  /// - 429：速率限制规则配 challenge 类动作
  /// - 503：「I'm Under Attack」等 JS 挑战的历史形态
  ///
  /// 历史上只认 403/429，503 挑战会先被 TransientRetry 白白重放三轮，
  /// 再以"服务器暂不可用"收场，永远进不了验证。
  static const Set<int> challengeStatusCodes = {403, 429, 503};

  /// 基于原始信号判定（WebView 脚本回传、测试替身等拿不到 Dio [Response] 的场景）。
  static bool isChallenge({
    int? statusCode,
    String? cfMitigated,
    String? contentType,
    Object? body,
  }) {
    if ((cfMitigated ?? '').toLowerCase().contains('challenge')) return true;
    if (!challengeStatusCodes.contains(statusCode)) return false;
    final type = (contentType ?? '').toLowerCase();
    if (type.isNotEmpty && !type.contains('text/html')) return false;
    return hasChallengeMarkers(body);
  }

  /// Dio 响应是否是 CF 挑战（无论它是被 validateStatus 放行还是进了错误链）。
  static bool isChallengeResponse(Response<dynamic>? response) {
    if (response == null) return false;
    final headers = response.headers;
    return isChallenge(
      statusCode: response.statusCode,
      cfMitigated: headers.value('cf-mitigated'),
      contentType: headers.value('content-type'),
      body: response.data,
    );
  }

  /// 一次失败是否由 CF 挑战造成。
  ///
  /// 覆盖两种形态：带挑战响应的 [DioException]，以及 CF 拦截器/调度器
  /// 收口后 reject 的**没有 response** 的异常（error 里才是
  /// [CfChallengeException]）——只看 statusCode 会把后者当普通失败。
  static bool isChallengeFailure(Object? error) {
    if (error is CfChallengeException) return true;
    if (error is! DioException) return false;
    if (error.error is CfChallengeException) return true;
    return isChallengeResponse(error.response);
  }

  /// 响应体里是否有 CF 挑战页的特征标记。
  static bool hasChallengeMarkers(Object? body) {
    if (body == null) return false;
    final str = body.toString();
    // cf_chl_opt 是 CF 验证页面的可靠标记（challenge options JS 变量）
    if (str.contains('cf_chl_opt')) return true;
    // challenge-platform 路径需配合 cloudflare 标记，避免误匹配
    if (str.contains('challenge-platform') && str.contains('cloudflare')) {
      return true;
    }
    // "Just a moment" 需配合 CF 特征，避免误匹配用户内容
    if (str.contains('Just a moment') &&
        (str.contains('cloudflare') || str.contains('cf-challenge'))) {
      return true;
    }
    return false;
  }
}
