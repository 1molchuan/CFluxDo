import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../pages/webview_login_page.dart';
import 'app_logger.dart';
import 'discourse/discourse_service.dart';
import 'local_notification_service.dart' show navigatorKey;
import 'cf_challenge_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'otp_login_race.dart';
import 'toast_service.dart';
import 'user_api_key_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 浏览器授权登录流程编排
///
/// 发起:登录页按钮 → [preflight] 先确认原生这边连得上论坛、过得了人机验证
/// → [start] 拉起系统浏览器打开 /user-api-key/new。
/// 回程:系统浏览器授权后 302 到 discourse://auth_redirect,OS 深链拉回 App,
/// DeepLinkService 分发到 [handleCallback]:
/// 1. 解密 payload,校验 nonce(key 先暂存)
/// 2. App 无登录态时,把随行的一次性口令先落盘(10 分钟内有效),再拿它换会话:
///    - 先走原生(主 dio,经网关过 CF),通常一秒左右换完;
///    - 原生被人机验证拦下或连不上时,口令还在:自动改到内置网页里换
///      (真浏览器,过盾的就是它),换到的 _t 由登录页原有的收口搬回原生;
///    - 原生 2 秒还没结果(连接卡住):内置网页在遮罩后面同时起跑,谁先换到
///      用谁(错峰竞速,见 OtpLoginRace);
///    - 两条路都没成:口令留着,登录页上可以「继续完成登录」,不用重新授权;
///    - 服务端明确不认这枚口令(过期/用过):清掉,提示重新授权。
/// 3. 登录成功后 key 用完即焚(burnAfterLoginIfUseless);撤销没发成就先留着下次再撤
///
/// 冷启动回调(App 被杀后从浏览器深链拉起)同样成立——流程不依赖登录页存活。
class UserApiKeyLoginFlow {
  UserApiKeyLoginFlow._();
  static final UserApiKeyLoginFlow instance = UserApiKeyLoginFlow._();

  /// 流程完成回调(仅 UI 用途:登录页借此 pop 自己),参数=是否成功
  ValueChanged<bool>? onFlowFinished;

  bool _handling = false;
  OverlayEntry? _loadingEntry;

  /// 深链回到 App 后,兑换+收口这段有网络耗时(可能还含 CF 验证),
  /// 用全局 overlay 给用户一个"正在完成登录"的反馈,避免看起来卡死。
  void _showLoading(String message) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _loadingEntry?.remove();
    _loadingEntry = OverlayEntry(
      builder: (_) => _AuthLoadingOverlay(message: message),
    );
    overlay.insert(_loadingEntry!);
  }

  void _hideLoading() {
    _loadingEntry?.remove();
    _loadingEntry = null;
  }

  /// 构建授权 URL 并拉起系统浏览器。返回是否成功拉起。
  /// 首次调用会懒生成 RSA 密钥对(isolate,可能耗时数秒)。
  Future<bool> start() async {
    final authorizeUrl = await UserApiKeyService().buildAuthorizeUrl();
    try {
      // Android 用 Custom Tabs(inAppBrowserView),不用 externalApplication:
      // Chrome 对已建立 App Links 关联的域名(fluxdo 已 autoVerify linux.do)会把
      // externalApplication 打开的链接直接弹回本 app,表现为"浏览器一闪就跳回"
      // (仅 Chrome 有此行为,换其他浏览器正常)。Custom Tabs 在 app 上下文内打开,
      // 不触发该回弹,且共享 Chrome cookie 复用浏览器登录态(OAuth 标准做法)。
      // 其他平台 externalApplication 已验证正常,保持不变。
      final mode = Platform.isAndroid
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication;
      return await launchUrl(authorizeUrl, mode: mode);
    } catch (e) {
      debugPrint('[UserApiKeyLoginFlow] 拉起浏览器失败: $e');
      return false;
    }
  }

  /// 发起授权前的预检:原生这边现在连不连得上论坛、过不过得了人机验证。
  /// 撞盾时会像平常一样弹验证页;返回 false 说明现在换会话多半会卡住。
  Future<bool> preflight() =>
      UserApiKeyService().canReachForum(DiscourseService().dio);

  /// 上次授权已经成功、口令还在有效期内但没换成会话
  Future<bool> hasPendingLogin() async =>
      await UserApiKeyService().readPendingOtp() != null;

  /// 接着完成上次没换成的登录(登录页的「继续完成登录」)。没有可用的口令返回 false。
  Future<bool> resumePending() async {
    if (_handling) return false;
    _handling = true;
    try {
      final pending = await UserApiKeyService().readPendingOtp();
      if (pending == null) return false;
      final ok = await _exchange(pending.otp);
      onFlowFinished?.call(ok);
      return ok;
    } finally {
      _handling = false;
    }
  }

  /// 处理 discourse://auth_redirect 深链回调(由 DeepLinkService 分发)
  Future<void> handleCallback(Uri uri) async {
    if (_handling) return;
    _handling = true;
    try {
      final userApiKeyService = UserApiKeyService();
      final result = await userApiKeyService.handleAuthRedirect(uri);
      // 冷启动 getInitialLink 会重放上次的 auth_redirect 深链;非本次授权流程
      // (nonce 已消费/不匹配)静默忽略,不弹 toast、不通知登录页。
      if (result.stale) {
        debugPrint('[UserApiKeyLoginFlow] 忽略残留授权回调');
        return;
      }
      if (!result.ok) {
        ToastService.showError(S.current.login_authCallbackInvalid);
        onFlowFinished?.call(false);
        return;
      }

      // 已有登录态:只是补授权。scopes 含 write 才值得留 key 做自愈;
      // 否则(linux.do 现状)立即焚毁,不留永久零权限凭据
      final existingToken = await CookieJarService().getTToken();
      if (existingToken != null && existingToken.isNotEmpty) {
        await userApiKeyService.burnAfterLoginIfUseless(DiscourseService().dio);
        ToastService.showSuccess(S.current.login_authorized);
        onFlowFinished?.call(true);
        return;
      }

      // 无登录态:用随行 OTP 兑换 _t 完成登录
      final otp = result.otp;
      if (otp == null) {
        await userApiKeyService.burnAfterLoginIfUseless(DiscourseService().dio);
        ToastService.showError(S.current.login_noOtp);
        onFlowFinished?.call(false);
        return;
      }

      // 口令先落盘:换会话这一步撞盾、断网、App 被杀都可以接着来
      await userApiKeyService.savePendingOtp(otp);
      onFlowFinished?.call(await _exchange(otp));
    } finally {
      _handling = false;
    }
  }

  /// 拿口令换会话并完成登录收口。成功返回 true;失败时该提示的已经提示过。
  ///
  /// 原生和内置网页错峰竞速(见 [OtpLoginRace]):原生先跑,到点没结果网页在
  /// 遮罩后面起跑,谁先换到用谁;原生很快失败而口令还在时直接改走网页。
  Future<bool> _exchange(String otp) async {
    final userApiKeyService = UserApiKeyService();
    final service = DiscourseService();

    // 兑换 + 收口有网络耗时,显示全局 loading 反馈
    _showLoading(S.current.login_finishing);
    final OtpLoginOutcome outcome;
    try {
      outcome = await OtpLoginRace(
        redeemNative: (cancelToken, onProgress) =>
            userApiKeyService.redeemOtpDetailed(
              service.dio,
              otp,
              cancelToken: cancelToken,
              onProgress: onProgress,
            ),
        host: _WebLegHost(this, otp),
        // 原生撞盾、正开着验证页让用户点的时候不起网页
        holdWeb: () => CfChallengeService().isVerifying,
        log: (message) =>
            AppLogger.info('换会话：$message', tag: 'UserApiKeyLoginFlow'),
      ).run();
      if (outcome == OtpLoginOutcome.nativeSucceeded) {
        // 口令已经用掉
        await userApiKeyService.clearPendingOtp();
        return await _finishNativeLogin(service);
      }
    } finally {
      _hideLoading();
    }

    switch (outcome) {
      case OtpLoginOutcome.nativeSucceeded:
        return true; // 上面已经处理
      case OtpLoginOutcome.webSucceeded:
        // 登录页自己已经做完收口、提示过「登录成功」
        await userApiKeyService.clearPendingOtp();
        await userApiKeyService.burnAfterLoginIfUseless(service.dio);
        return true;
      case OtpLoginOutcome.rejected:
        // 服务端不认这枚口令(过期 / 已用过):留着也没用
        await userApiKeyService.clearPendingOtp();
        await userApiKeyService.burnAfterLoginIfUseless(service.dio);
        ToastService.showError(S.current.login_otpRejected);
        return false;
      case OtpLoginOutcome.unfinished:
        // 网页里登录上之后被用户关掉:收口在后台照样做完了,会话已经在手
        final token = await CookieJarService().getTToken();
        if (token != null && token.isNotEmpty) {
          await userApiKeyService.clearPendingOtp();
          await userApiKeyService.burnAfterLoginIfUseless(service.dio);
          return true;
        }
        // 口令留着(有效期内),登录页上可以接着来
        ToastService.showError(S.current.login_pendingHint);
        return false;
    }
  }

  /// 新 _t 已落 jar:取 username 后走与密码登录同一套收口
  Future<bool> _finishNativeLogin(DiscourseService service) async {
    final userApiKeyService = UserApiKeyService();
    var username = '';
    try {
      final response = await service.dio.get(
        '/session/current.json',
        options: Options(
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );
      final data = response.data;
      final currentUser = data is Map<String, dynamic>
          ? data['current_user']
          : null;
      if (currentUser is Map<String, dynamic>) {
        username = currentUser['username']?.toString() ?? '';
      }
    } catch (e) {
      debugPrint('[UserApiKeyLoginFlow] 取 current_user 失败: $e');
    }

    if (username.isEmpty) {
      // _t 已落 jar 但确认请求失败;不带空用户名走收口(会写坏本地状态)
      await userApiKeyService.burnAfterLoginIfUseless(service.dio);
      ToastService.showError(S.current.login_confirmFailed);
      return false;
    }

    await service.finalizeNativeLoginSuccess(username);
    // _t 已到手且与 key 存活解耦;零 scope key 用完即焚
    await userApiKeyService.burnAfterLoginIfUseless(service.dio);
    ToastService.showSuccess(S.current.login_success);
    return true;
  }
}

/// 竞速里内置网页那条路的界面:登录页压在「正在完成登录」的遮罩下面开着,
/// 需要用户看见时撤掉遮罩。
class _WebLegHost implements OtpWebLegHost {
  _WebLegHost(this._flow, this._otp);

  final UserApiKeyLoginFlow _flow;
  final String _otp;
  Route<bool>? _route;

  @override
  Future<bool?> open(OtpWebLeg leg) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return null;
    // 那是真浏览器,过盾的就是它;换到的会话由登录页原有的收口搬回原生
    final route = MaterialPageRoute<bool>(
      builder: (_) => WebViewLoginPage(
        initialUrl: '${AppConstants.baseUrl}/session/otp/$_otp',
        confirmOtp: true,
        otpLeg: leg,
      ),
    );
    _route = route;
    try {
      return await navigator.push(route);
    } finally {
      _route = null;
    }
  }

  @override
  void close() {
    final route = _route;
    if (route == null || !route.isActive) return;
    navigatorKey.currentState?.removeRoute(route);
  }

  @override
  void reveal() => _flow._hideLoading();

  @override
  void conceal() => _flow._showLoading(S.current.login_finishing);
}

/// 授权收口期间的全局 loading 遮罩(经 navigatorKey overlay 插入)
class _AuthLoadingOverlay extends StatelessWidget {
  const _AuthLoadingOverlay({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LoadingSpinner(),
                const SizedBox(height: 16),
                Text(message, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
