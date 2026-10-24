import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../constants.dart';
import '../../config/forum_site.dart';
import '../site_context.dart';
import '../app_logger.dart';
import 'adapters/platform_adapter.dart';
import 'cookie/app_cookie_manager.dart';
import 'cookie/cookie_jar_service.dart';
import 'cookie/csrf_token_service.dart';
import 'cf/cf_challenge_classifier.dart';
import 'flux_request_spec.dart';
import 'interceptors/cf_challenge_interceptor.dart';
import 'interceptors/request_scheduler_interceptor.dart';
import 'interceptors/session_guard_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/network_log_interceptor.dart';
import 'interceptors/redirect_interceptor.dart';
import 'interceptors/request_header_interceptor.dart';
import 'recovery/policies.dart';
import 'recovery/recovery_coordinator.dart';
import 'recovery/recovery_policy.dart';
import 'recovery/session_heal_policy.dart';

/// Dio 实例的链路种类：在工厂处声明一次，拦截器装配全部由它推导。
///
/// 此前工厂有五个松散开关（maxConcurrent / enableRetry / enableCfChallenge /
/// enableCookies / enableNetworkLog），组合靠调用点各自拼，其中
/// `maxConcurrent: null` 还**暗中**关掉了「CF 验证期间冻结业务请求」（冻结
/// 挂在调度器上）——读调用点完全看不出来。现在每种链路的 CF 处置
/// （是否过盾恢复、验证期是否冻结）与其余装配一起显式声明在这里。
///
/// Cookie 是否启用不属于链路种类（同一种类可能对不同域名开关，如图片的
/// 主站/CDN、MessageBus 的共享会话），仍由 [DiscourseDio.create] 的
/// `enableCookies` 单独决定。
enum DiscourseDioKind {
  /// 业务 API（默认）：调度（并发/速率）+ 验证期冻结 + 恢复 + CF 过盾恢复 + 日志。
  api(
    scheduled: true,
    freezeDuringCfVerification: true,
    recovery: true,
    cfRecovery: true,
    networkLog: true,
  ),

  /// MessageBus 长轮询：不进调度器（不占并发槽），验证期也不冻结——
  /// 冻结会把轮询取消掉，轮询器按「客户端中止」立即重连，验证期间空转。
  /// 撞盾仍走过盾恢复（静默请求只在后台验证）。
  longPoll(
    scheduled: false,
    freezeDuringCfVerification: false,
    recovery: true,
    cfRecovery: true,
    networkLog: true,
  ),

  /// 文件下载：不限并发，不过盾（下载链接撞盾交给页面层提示）。
  download(
    scheduled: false,
    freezeDuringCfVerification: false,
    recovery: true,
    cfRecovery: false,
    networkLog: true,
  ),

  /// 图片/媒体探测：几百个请求，不调度、不恢复、不过盾、不记网络日志。
  media(
    scheduled: false,
    freezeDuringCfVerification: false,
    recovery: false,
    cfRecovery: false,
    networkLog: false,
  ),

  /// 连通性探测：结果就是"通不通"，不调度、不恢复、不过盾。
  probe(
    scheduled: false,
    freezeDuringCfVerification: false,
    recovery: false,
    cfRecovery: false,
    networkLog: true,
  );

  const DiscourseDioKind({
    required this.scheduled,
    required this.freezeDuringCfVerification,
    required this.recovery,
    required this.cfRecovery,
    required this.networkLog,
  }) : assert(
         !freezeDuringCfVerification || scheduled,
         '验证期冻结由调度器执行，必须同时启用调度',
       );

  /// 并发 + 滑动窗口速率调度（参数从 RequestSchedulerConfig 动态读取）。
  final bool scheduled;

  /// CF 验证进行中时冻结本实例的业务请求（用户可见请求排队等结果，静默请求取消）。
  final bool freezeDuringCfVerification;

  /// 恢复协调器（会话自愈 / 限流等待 / 瞬态重试）。
  final bool recovery;

  /// 撞 CF 盾时换值重放 / 发起验证 / 兼容模式兜底（见 CfChallengeInterceptor）。
  final bool cfRecovery;

  /// 网络日志。
  final bool networkLog;
}

/// 统一封装的 Dio 工厂
class DiscourseDio {
  static Dio create({
    DiscourseDioKind kind = DiscourseDioKind.api,
    Duration connectTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
    Map<String, dynamic>? defaultHeaders,
    String? baseUrl,
    bool enableCookies = true,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ?? AppConstants.baseUrl,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        headers: defaultHeaders,
        // 禁用自动重定向，手动处理以确保重定向时使用正确的 cookie
        followRedirects: false,
        // 包含重定向状态码，让我们手动处理
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    // 大响应(>50KB)的 JSON 解码移入 isolate:话题列表/详情等大 JSON
    // 在主线程解码实测把 DartIsolate::HandleMessage 顶到 50~100ms,
    // 滚动/返回列表时直接掉帧。小响应仍同步解码(isolate 往返不划算)。
    dio.transformer = BackgroundTransformer();

    // 1. 配置平台适配器
    //
    // 需要绕开 rhttp 走系统栈的场景(如 MessageBus 长轮询依赖系统级省电)
    // 由请求侧的 FluxRequestKeys.skipRhttpAdapter 逐请求声明,不在这里分档。
    configurePlatformAdapter(dio);

    // 论坛引擎只服务一个站点，另一站（含子域）不能进入会话拦截器链。
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      final host = options.uri.host.toLowerCase();
      final otherSite = ForumSite.values.any((site) =>
          site != SiteContext.current &&
          (host == site.host || host.endsWith('.${site.host}')));
      if (otherSite) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: '跨站请求须先切换到对应站点',
        ));
        return;
      }
      handler.next(options);
    }));

    // 2. 会话代守卫（最先执行，确保过期请求不进入后续拦截器）
    dio.interceptors.add(SessionGuardInterceptor());

    // 3. 并发限制 + 滑动窗口速率限制 + CF 验证期冻结（按链路种类）
    // 实际参数从 RequestSchedulerConfig 动态读取
    if (kind.scheduled) {
      dio.interceptors.add(
        RequestSchedulerInterceptor(
          freezeDuringCfVerification: kind.freezeDuringCfVerification,
        ),
      );
    }

    // 4. 恢复协调器:全项目唯一的重放引擎
    //
    // 策略顺序即失败归属(首个 canHandle 者独占决策权):
    //   会话自愈 → 限流等待 → 瞬态重试
    //
    // 必须注册在 AppCookieManager **之前**:dio 5.11 三相全 FIFO,先注册者
    // 先看到响应。服务端拒绝时常带 Set-Cookie 清 _t,自愈判定要读的是那条
    // 删除指令**落库前**的 jar 快照——顺序颠倒会让它误判"真登出"跳过自愈。
    // 契约测试: test/services/network/recovery/session_heal_test.dart
    //
    // 取代 dio_smart_retry + SelfHealingInterceptor。
    // 与 dio_smart_retry 的行为差异是刻意的:
    // - 5xx 只对幂等方法重放,POST 重放会造成重复发帖;
    // - 429 区分挑战型(交 CF 盾)与真限流,并尊重 Retry-After;
    // - 尝试预算集中防环,不再靠各重放点自觉打 skip 标记。
    //
    // Cookie 管理与会话自愈只看调用方要不要 cookie，不看 jar 此刻是否已初始化：
    // 以前 jar 没就绪就**静默**少装这两个拦截器，这个 Dio 一辈子不带 cookie、
    // 也不自愈，而调用点完全看不出来（单例在启动早期被提前构造就会中招）。
    // 现在 jar 未就绪时由 [JarReadyCookieManager] 先等 jar 初始化再处理请求。
    final cookieJarService = CookieJarService();
    if (kind.recovery) {
      dio.interceptors.add(
        RecoveryCoordinator(
          dio: dio,
          policies: [
            // 自愈读 jar 快照时会自行等待 jar 初始化
            if (enableCookies) SessionSelfHealPolicy(),
            RateLimitPolicy(
              isChallengeResponse: CfChallengeClassifier.isChallengeResponse,
            ),
            TransientRetryPolicy(
              isChallengeResponse: CfChallengeClassifier.isChallengeResponse,
              onRetry: _notifyRetryObserver,
            ),
          ],
        ),
      );
    }

    // 5. Cookie 管理
    if (enableCookies) {
      if (cookieJarService.isInitialized) {
        dio.interceptors.add(AppCookieManager(cookieJarService.cookieJar));
      } else {
        // 启动顺序出了偏差：留下记录，但链路照常完整（等 jar 就绪）
        AppLogger.warning(
          'Dio 在 cookie jar 初始化前创建（baseUrl=${dio.options.baseUrl}），'
          'Cookie 管理改为等 jar 就绪后再处理请求',
          tag: 'DiscourseDio',
        );
        dio.interceptors.add(JarReadyCookieManager(cookieJarService));
      }
    }

    // 6. 请求头拦截器
    dio.interceptors.add(RequestHeaderInterceptor(CsrfTokenService()));

    // 7. 重定向拦截器
    dio.interceptors.add(RedirectInterceptor(dio));

    // 8. 错误拦截器
    dio.interceptors.add(ErrorInterceptor());

    // 9. CF 验证拦截器
    if (kind.cfRecovery) {
      dio.interceptors.add(
        CfChallengeInterceptor(dio: dio, cookieJarService: cookieJarService),
      );
    }

    // 10. 网络日志拦截器（最后一个，记录最终结果）
    // 注意：Gateway URL 改写已移至 HttpClientAdapter 层（_GatewayAdapterWrapper），
    // 所有拦截器始终看到原始 URL，无需额外处理。
    if (kind.networkLog) {
      dio.interceptors.add(NetworkLogInterceptor());
    }

    return dio;
  }

  /// 瞬态重试决定重放时,告诉请求上挂的旁观者「第几次重试、为什么」
  /// (启动预加载借此把重试显示在启动页上);没挂旁观者的请求不受影响。
  static void _notifyRetryObserver(AttemptOutcome outcome, Duration delay) {
    final err = outcome.error;
    if (err == null) return;
    err.requestOptions.spec.observer?.onRetry(outcome.attemptIndex + 1, err);
  }
}

/// jar 尚未初始化时建出的 Dio 用的 Cookie 管理：第一次经过时等 jar 初始化
/// 完成，之后把请求 / 响应 / 错误原样交给真正的 [AppCookieManager]。
///
/// 位置与 [AppCookieManager] 相同（恢复协调器之后），所以拦截器顺序契约不变。
@visibleForTesting
class JarReadyCookieManager extends Interceptor {
  JarReadyCookieManager(this._jarService);

  final CookieJarService _jarService;
  AppCookieManager? _inner;

  Future<AppCookieManager> _resolve() async {
    final inner = _inner;
    if (inner != null) return inner;
    await _jarService.initialize();
    return _inner ??= AppCookieManager(_jarService.cookieJar);
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final AppCookieManager inner;
    try {
      inner = await _resolve();
    } catch (e, s) {
      // 等不到 jar 也不能把请求挂死：按 AppCookieManager 加载失败的口径拒绝
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: e,
          stackTrace: s,
          message: 'Cookie jar is not available for the request.',
        ),
        true,
      );
      return;
    }
    await inner.onRequest(options, handler);
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final inner = _inner;
    if (inner == null) {
      // 请求阶段没经过本拦截器（例如被前面的拦截器直接 resolve）
      handler.next(response);
      return;
    }
    await inner.onResponse(response, handler);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final inner = _inner;
    if (inner == null) {
      handler.next(err);
      return;
    }
    await inner.onError(err, handler);
  }
}
