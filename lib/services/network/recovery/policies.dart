import 'dart:io';

import 'package:dio/dio.dart';

import '../../log/log_writer.dart';
import '../cookie/cookie_jar_service.dart';
import '../cookie/csrf_token_service.dart';
import '../exceptions/api_exception.dart';
import 'recovery_action.dart';
import 'recovery_policy.dart';
import 'retry_after.dart';

/// 限流(429)恢复策略。
///
/// CF 的速率限制规则配 managed_challenge 时会返回
/// `429 + cf-mitigated: challenge` —— 那是挑战不是限流。能走到本策略的 429
/// 才是真正的服务端限流。
///
/// 分界靠 [isChallengeResponse] 钩子:命中即放行,交给 CfChallengeInterceptor。
/// 那条链**刻意留在恢复层之外**(它的重试后处置要换传输方式再放、失败还要
/// 回滚副作用,超出 [RecoveryDecision] 的表达力),详见该类的文档注释。
///
/// 决策:
/// - 服务端给出了可接受的等待时长 → 延迟后重放;
/// - 等待过长(超过 [maxWaitSeconds])或没给时长 → 不重放,包装成
///   [RateLimitException] 让业务层决定(它可能想提示用户而不是干等)。
class RateLimitPolicy implements RecoveryPolicy {
  const RateLimitPolicy({
    this.maxWaitSeconds = 30,
    this.isChallengeResponse,
  });

  /// 愿意自动等待的上限。超过则交回业务层。
  final int maxWaitSeconds;

  /// 判定"这个 429 其实是 CF 挑战"的钩子。
  ///
  /// 注入而非直接依赖 CfChallengeService,是为了让策略可单测,
  /// 同时避免恢复层反向依赖 CF 那一大坨 UI 代码。
  final bool Function(Response<dynamic>? response)? isChallengeResponse;

  @override
  String get name => 'rate-limit';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    if (outcome.statusCode != 429) return false;
    // 挑战型 429 不归本策略
    if (isChallengeResponse?.call(outcome.error!.response) == true) {
      return false;
    }
    return true;
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    final err = outcome.error!;
    final waitSeconds = extractRetryAfterSeconds(err.response);

    if (waitSeconds != null &&
        waitSeconds > 0 &&
        waitSeconds <= maxWaitSeconds) {
      return RecoveryDecision.retry(delay: Duration(seconds: waitSeconds));
    }

    // 不自动等待:交回业务层,但保留 response(业务层要读服务端文案)
    return RecoveryDecision.fail(
      err.copyWith(
        error: RateLimitException(
          waitSeconds,
          _errorMessageOf(err.response),
          err.response,
        ),
      ),
    );
  }

  static String? _errorMessageOf(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map<String, dynamic>) {
      return data['error'] as String? ??
          (data['errors'] as List?)?.firstOrNull?.toString();
    }
    return null;
  }
}

/// BAD CSRF 恢复策略。
///
/// 主站回 `403 ["BAD CSRF"]` 多半是会话 Cookie 刚轮换(过盾后采纳了 WebView 的
/// 会话),手上的 token 跟着失效。刷新 token 后重放一次;重放还是 BAD CSRF 就交回
/// 调用方。Discourse 前端为防循环不立刻重发,它的阅读时长遇到 403 也不重排、
/// 直接丢——这里只在首次失败时重放一次,且受尝试预算约束,不会成环。
class BadCsrfPolicy implements RecoveryPolicy {
  BadCsrfPolicy({
    Future<bool> Function()? refreshToken,
    bool Function(Uri uri)? isMainSite,
  }) : _action = _RefreshCsrfAction(refreshToken ?? _refreshMainSiteToken),
       _isMainSite = isMainSite ?? _defaultIsMainSite;

  final _RefreshCsrfAction _action;
  final bool Function(Uri uri) _isMainSite;

  @override
  String get name => 'bad-csrf';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess || outcome.statusCode != 403) return false;
    final error = outcome.error!;
    return _isMainSite(error.requestOptions.uri) &&
        isBadCsrfResponse(error.response?.data);
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    if (outcome.attemptIndex > 0) return const RecoveryDecision.complete();
    return RecoveryDecision.recoverThenRetry(_action);
  }

  /// Discourse 的 BAD CSRF 响应体(原文或已解码的 JSON 数组)
  static bool isBadCsrfResponse(dynamic data) {
    if (data is String) return data.trim() == '["BAD CSRF"]';
    if (data is List) return data.length == 1 && data.first == 'BAD CSRF';
    return false;
  }

  static bool _defaultIsMainSite(Uri uri) =>
      uri.host.toLowerCase() == CookieJarService.appBaseHost;

  static Future<bool> _refreshMainSiteToken() async {
    final csrf = CsrfTokenService();
    // 清 token 同时解除刷新失败冷却:BAD CSRF 说明请求到了服务端,不是被 CF 挡
    csrf.clearCsrfToken();
    await csrf.updateCsrfToken();
    final token = csrf.csrfToken;
    return token != null && token.isNotEmpty;
  }
}

/// 刷新 CSRF token;同时撞上 BAD CSRF 的请求共享一次刷新
class _RefreshCsrfAction extends RecoveryAction {
  _RefreshCsrfAction(this._refresh);

  final Future<bool> Function() _refresh;

  @override
  String get name => 'refresh-csrf';

  @override
  Future<bool> perform() async {
    final ok = await _refresh();
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': ok ? 'info' : 'warning',
      'type': 'auth',
      'event': 'csrf_bad_response_replay',
      'message': ok
          ? '收到 BAD CSRF，已刷新 token，原请求重放一次'
          : '收到 BAD CSRF，刷新 token 失败，不重放',
    });
    return ok;
  }
}

/// 瞬态故障恢复策略:5xx 与连接类错误(含连接在响应前被掐断)。
///
/// 只对幂等方法生效——POST 重放可能造成重复发帖/重复点赞,宁可失败也不
/// 冒这个风险(这也是为什么它不能简单等价于 dio_smart_retry 的默认行为:
/// 后者对所有方法一视同仁)。
///
/// 挑战型 503 同样经 [isChallengeResponse] 放行给 CfChallengeInterceptor:
/// 不过盾就重放只会再撞三次盾,白等 7 秒。
class TransientRetryPolicy implements RecoveryPolicy {
  const TransientRetryPolicy({
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.isChallengeResponse,
    this.onRetry,
  });

  /// 第 N 次重放前的等待时长(指数退避)。
  final List<Duration> delays;

  /// 判定"这个 5xx 其实是 CF 挑战"的钩子,语义同 [RateLimitPolicy]。
  final bool Function(Response<dynamic>? response)? isChallengeResponse;

  /// 决定重放时的通知钩子:启动页用它把「正在第 N 次重试」显示给用户。
  /// 只是旁观,抛错不影响重放。
  final void Function(AttemptOutcome outcome, Duration delay)? onRetry;

  static const _idempotentMethods = {'GET', 'HEAD', 'OPTIONS'};
  static const _retryableStatuses = {502, 503, 504};

  @override
  String get name => 'transient-retry';

  @override
  bool canHandle(AttemptOutcome outcome) {
    if (outcome.isSuccess) return false;
    final err = outcome.error!;
    if (!_idempotentMethods.contains(err.requestOptions.method.toUpperCase())) {
      return false;
    }
    final status = outcome.statusCode;
    if (status != null) {
      if (!_retryableStatuses.contains(status)) return false;
      return isChallengeResponse?.call(err.response) != true;
    }
    return _isTransientNetworkError(err);
  }

  @override
  Future<RecoveryDecision> decide(AttemptOutcome outcome) async {
    final index = outcome.attemptIndex.clamp(0, delays.length - 1);
    final delay = delays[index];
    final notify = onRetry;
    if (notify != null) {
      try {
        notify(outcome, delay);
      } catch (_) {
        // 旁观钩子出错不能影响重放
      }
    }
    return RecoveryDecision.retry(delay: delay);
  }

  static bool _isTransientNetworkError(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
        return false;
      case DioExceptionType.unknown:
        // HttpException：连接在收到响应（头或正文）之前被掐断，例如网络刚
        // 恢复时蜂窝→Wi-Fi 切换，系统销毁了旧网络上的 socket，本地网关随之
        // 断开下游连接（「Connection closed before full header was
        // received」）。与连接失败同属瞬态，幂等请求照常退避重放；以前它
        // 不在此列，启动预加载撞上就直接落到错误页。
        final inner = err.error;
        return inner is SocketException || inner is HttpException;
      default:
        return false;
    }
  }
}
