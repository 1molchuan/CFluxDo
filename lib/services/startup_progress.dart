import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../l10n/s.dart';
import 'network/flux_request_spec.dart';

/// 启动预加载当前所处的阶段。
///
/// 只描述「现在在干什么」,顺序不固定:直连失败会跳到内置浏览器,
/// 内置浏览器拿不到数据又会改回直连。
enum StartupStage {
  /// 直连 linux.do 拉取首页。
  connecting,

  /// 直连失败后由恢复策略自动重试。
  retrying,

  /// 直连撞上 Cloudflare 验证,正在处理(换值重放或等用户过盾)。
  cfChallenge,

  /// 内置浏览器正在加载首页。
  webViewLoading,

  /// 内置浏览器已加载完首页,正在等它交出页面数据。
  webViewSnapshot,

  /// 内置浏览器拿到数据后同步登录会话。
  webViewBootstrap,
}

/// 为什么没有走最快的直连路径,或者为什么又从内置浏览器退回直连。
///
/// 这是启动变慢的根因,启动页会单独用醒目颜色显示,并在后续阶段里保留。
enum StartupDetourReason {
  /// 本地没有可用的 cf_clearance,只能靠内置浏览器获取。
  noClearance,

  /// cf_clearance 刚被服务端拒绝,需要重新获取。
  clearanceRejected,

  /// cf_clearance 即将过期,提前换新。
  clearanceExpiring,

  /// 直连本身失败,转内置浏览器。
  nativeFailed,

  /// 内置浏览器没拿到页面数据,已改回直连。
  webViewNoData,

  /// 内置浏览器整体超时,已改回直连。
  webViewTimeout,
}

/// 启动预加载的一次状态快照。
@immutable
class StartupProgress {
  const StartupProgress({
    required this.stage,
    required this.since,
    this.reason,
    this.reasonDetail,
    this.detail,
    this.attempt,
  });

  final StartupStage stage;

  /// 绕路原因;为 null 表示目前走的是正常路径。
  final StartupDetourReason? reason;

  /// 绕路原因的附加说明(已本地化),与 [reason] 一起跨阶段保留。
  final String? reasonDetail;

  /// 当前阶段的附加说明(已本地化),例如重试时的「HTTP 502」;不跨阶段保留。
  final String? detail;

  /// 重试序号(从 1 起),仅 [StartupStage.retrying] 使用。
  final int? attempt;

  /// 进入这个阶段的时刻。
  final DateTime since;

  /// 是否属于异常的预启动现象(绕路、重试、撞盾、回退)。
  bool get isAbnormal =>
      reason != null ||
      stage == StartupStage.retrying ||
      stage == StartupStage.cfChallenge;
}

/// 启动预加载进度的发布者。
///
/// 预加载链路经 [StartupPreloadProgress] 往这里写,启动页监听 [progress]
/// 把当前阶段和异常原因显示出来。
///
/// 只在 [begin] 与 [clear] 之间接受更新:启动页消失后迟到的进度不会再写上去。
class StartupProgressReporter {
  StartupProgressReporter._();

  static final StartupProgressReporter instance = StartupProgressReporter._();

  final ValueNotifier<StartupProgress?> progress = ValueNotifier(null);

  /// 本轮预加载开始的时刻,用于启动页显示总等待时长;未开始时为 null。
  DateTime? _startedAt;

  DateTime? get startedAt => _startedAt;

  bool get isActive => _startedAt != null;

  /// 一轮预加载开始:重置计时并清掉上一轮残留的阶段。
  void begin() {
    _startedAt = DateTime.now();
    progress.value = null;
  }

  /// 进入新阶段;未 [begin] 时忽略。
  ///
  /// [reason] 不传时沿用上一阶段的原因和原因说明:绕路原因在整个绕路
  /// 过程中都成立,不应该因为阶段推进而消失。传了 [reason] 则本次的
  /// [detail] 同时作为新的原因说明。
  /// [detail] 与 [attempt] 只属于当前阶段,不沿用。
  void set(
    StartupStage stage, {
    StartupDetourReason? reason,
    String? detail,
    int? attempt,
  }) {
    if (!isActive) return;
    final previous = progress.value;
    progress.value = StartupProgress(
      stage: stage,
      reason: reason ?? previous?.reason,
      reasonDetail: reason != null ? detail : previous?.reasonDetail,
      detail: detail,
      attempt: attempt,
      since: DateTime.now(),
    );
  }

  /// 预加载结束(成功或失败),清空状态并停止接受更新。
  void clear() {
    _startedAt = null;
    progress.value = null;
  }
}

/// 预加载链路向启动序列报告进度的出口。
///
/// 阶段推进由 BrowserTrust 的预加载路径报告;重试与撞盾由挂在首页请求上的
/// [FluxRequestObserver] 报告(网络层只认旁观者接口,不认启动页)。
abstract interface class StartupPreloadProgress implements FluxRequestObserver {
  void stage(StartupStage stage, {StartupDetourReason? reason, String? detail});
}

/// 把预加载进度写到启动页([StartupProgressReporter])。
///
/// 文案口径与 d53a2f82 一致:重试显示「第几次 + 简短原因」,撞盾显示 HTTP 状态码。
class ReporterPreloadProgress implements StartupPreloadProgress {
  ReporterPreloadProgress(this._reporter);

  final StartupProgressReporter _reporter;

  @override
  void stage(
    StartupStage stage, {
    StartupDetourReason? reason,
    String? detail,
  }) {
    _reporter.set(stage, reason: reason, detail: detail);
  }

  @override
  void onRetry(int attempt, DioException error) {
    if (!_reporter.isActive) return;
    _reporter.set(
      StartupStage.retrying,
      attempt: attempt,
      detail: describeStartupFailure(error),
    );
  }

  @override
  void onCfChallenge(int? statusCode) {
    if (!_reporter.isActive) return;
    _reporter.set(
      StartupStage.cfChallenge,
      detail: statusCode != null
          ? S.current.preheat_detailHttp(statusCode)
          : null,
    );
  }
}

/// 把预加载抛出的异常压成一句可展示的简短说明。
///
/// 不带 URL、不带响应体,避免把任何账号信息带到界面上。
String describeStartupFailure(Object error) {
  final l10n = S.current;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (code != null) return l10n.preheat_detailHttp(code);
        return l10n.preheat_detailConnectionError;
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return l10n.preheat_detailTimeout;
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return l10n.preheat_detailConnectionError;
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        final inner = error.error;
        if (inner != null && inner is! DioException) {
          return describeStartupFailure(inner);
        }
        return l10n.preheat_detailConnectionError;
    }
  }
  if (error is FormatException) return l10n.preheat_detailParseFailed;
  // 其他异常只给类型名,不展开 toString(),以免把请求细节带上界面
  return error.runtimeType.toString();
}
