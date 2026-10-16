import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'session/webview_use.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import 'cf_clearance_authority.dart';
import 'cf_clearance_refresh_service.dart';
import 'cf_verification_round.dart';
import 'embedded_browser_controller_pool.dart';
import 'toast_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';
import '../l10n/s.dart';
import '../providers/preferences_provider.dart';
import '../utils/blur_config.dart';
import '../widgets/draggable_floating_pill.dart';

CookieManager get _cfCookieManager =>
    WindowsWebViewEnvironmentService.instance.cookieManager;

/// 「切兼容模式」询问的三种去向。
enum _CompatPromptChoice {
  /// 本次会话改用浏览器网络栈发主站请求。
  enableCompat,

  /// 关掉自动过盾,改为撞盾时手动点验证。
  disableAutoVerify,

  /// 什么都不做(含关闭弹窗)。
  dismiss,
}

/// CF 验证服务
/// 处理 Cloudflare Turnstile 验证（仅手动模式）
class CfChallengeService {
  static final CfChallengeService _instance = CfChallengeService._internal();
  factory CfChallengeService() => _instance;
  CfChallengeService._internal();

  Completer<void>? _manualTeardownCompleter;

  /// 验证轮次的生命周期（冷却判定、合流、起轮、定稿落值、收尾）。
  /// 本服务只提供它的外部能力（验证页、overlay、续期服务、jar），
  /// 见 [_ServiceRoundEnvironment]。
  late final CfVerificationRounds _rounds = CfVerificationRounds(
    environment: _ServiceRoundEnvironment(this),
    onVerifyingChanged: _onVerifyingChanged,
  );

  /// CF 验证是否正在进行中（含验证页析构冷却期；用于外部判断是否应
  /// 忽略路由变化、冻结业务请求）
  bool get isVerifying => _rounds.active != null;

  /// 等待进行中的这一轮验证产生结果。
  ///
  /// 返回 true=通过（定稿值已在 jar），false=失败/取消/超时；当前没有
  /// 进行中的验证时返回 null。只等结果，不发起验证，也不参与失败计数。
  Future<bool?> waitForActiveVerification({required Duration timeout}) async {
    final outcome = await waitForActiveRound(timeout: timeout);
    return outcome?.passed;
  }

  /// 同 [waitForActiveVerification]，但给出完整结果（超时按 timeout 失败）。
  Future<CfRoundOutcome?> waitForActiveRound({required Duration timeout}) async {
    final round = _rounds.active;
    if (round == null) return null;
    return round.outcome.timeout(
      timeout,
      onTimeout: () =>
          CfRoundFailed(round: round.id, reason: CfRoundFailure.timeout),
    );
  }

  /// 测试用：模拟一轮验证开始（不建 WebView）。
  @visibleForTesting
  void debugBeginVerification() => _rounds.debugBegin();

  /// 测试用：模拟一轮验证产生结果并结束。
  @visibleForTesting
  void debugFinishVerification(bool success) {
    final round = _rounds.active;
    if (round == null) return;
    round.debugComplete(
      success
          ? CfRoundPassed(round: round.id, clearance: 'debug')
          : CfRoundFailed(round: round.id, reason: CfRoundFailure.cancelled),
    );
    _rounds.release(round);
  }

  /// 等待当前手动验证 WebView 从 Widget 树移除并走完原生析构冷却。
  ///
  /// BrowserTrust 在拿到 clearance 后仍需要创建 Session Headless WebView；
  /// 不能只等验证结果，因为结果会早于 Windows WebView2 Controller 完全析构。
  Future<void> waitForManualTeardown() async {
    while (true) {
      final teardown = _manualTeardownCompleter;
      if (teardown == null) return;
      await teardown.future;
      if (!isVerifying) return;
    }
  }

  /// CF 验证状态变化通知（true=进行中, false=空闲）。
  /// 拦截器 / ScreenTrack 等订阅它来在 CF 期间冻结业务流量与数据采集。
  final ValueNotifier<bool> inProgressNotifier = ValueNotifier<bool>(false);

  /// CF 挑战被成功解决、新 cf_clearance 已落 CookieJar 的时刻广播。
  /// 唯一写入方是验证轮次通过时（定稿值已确认在 jar）。
  /// [BrowserTrustCoordinator] 订阅它:WebView session bootstrap 因 CF 失败后,
  /// 等待 Dio 侧(或主动发起的)验证完成,再 force 重跑 bootstrap,避免两条线各自为政。
  final ValueNotifier<DateTime?> clearanceResolvedAt = ValueNotifier<DateTime?>(
    null,
  );

  void _onVerifyingChanged(bool value) {
    if (value) {
      final current = _manualTeardownCompleter;
      if (current == null || current.isCompleted) {
        _manualTeardownCompleter = Completer<void>();
      }
    }
    if (io.Platform.isWindows) {
      if (value) {
        // 不等待的第一阶段：立即阻止新的帖子 WebView 获取槽位，并通知
        // 已有 Controller 撤下；验证入口随后会 await 完整 drain。
        unawaited(EmbeddedBrowserControllerPool.instance.suspendAndDrain());
      } else {
        EmbeddedBrowserControllerPool.instance.resume();
      }
    }
    inProgressNotifier.value = value;
    if (!value) {
      final teardown = _manualTeardownCompleter;
      if (teardown != null && !teardown.isCompleted) {
        teardown.complete();
      }
      _manualTeardownCompleter = null;
    }
  }

  /// 验证 WebView 关闭后，原生 WebView2 控制器的销毁是异步的（发生在插件
  /// 的后台线程），比 Flutter 侧 OverlayEntry.remove() 慢一截。如果上一个
  /// 还没销毁干净就立刻起下一个 InAppWebView，在 Windows 上会撞上
  /// flutter_inappwebview_windows_plugin 的一个原生崩溃（0xc0000005 访问越
  /// 界），连续多次 CF 验证失败重试（如连续重新授权触发盾）时复现过。
  /// 这里让「验证进行中」多扛一小段时间，这段时间内的新验证请求合流到
  /// 刚结束的一轮（直接拿它的结果），不需要额外状态。
  static const _postCleanupCooldown = Duration(milliseconds: 1200);
  static const _refreshRestartCooldown = Duration(milliseconds: 300);

  /// 是否在拦截到 CF 盾时自动弹出验证 UI（默认 true）
  /// 关闭后 [CfChallengeInterceptor] 命中 CF 盾时会静默 reject，
  /// 交给 ErrorView 提供"手动验证"入口。由 PreferencesNotifier 同步维护。
  bool autoVerifyEnabled = true;

  /// 请求把「自动过盾」开关持久化关闭。
  ///
  /// 服务层拿不到 Riverpod 容器,由 PreferencesNotifier 在初始化时注入
  /// (它才是这个开关的真正归属方,要写 SharedPreferences)。
  /// 未注入时只改内存态,不持久化 —— 不阻塞功能。
  Future<void> Function()? disableAutoVerifyRequest;

  BuildContext? _context;
  static DateTime? _lastToastAt;
  Future<bool>? _activeSessionCompatPrompt;
  /// 上次拒绝「切兼容」的时刻;超过 [_sessionCompatDeclineTtl] 后可再问。
  DateTime? _sessionCompatDeclinedAt;
  Completer<BuildContext>? _contextReadyCompleter;
  VoidCallback? _activePromoteToForeground;
  bool _pendingPromoteToForeground = false;

  /// 冷却与失败计数按 host 记在 cf_clearance 账本里（验证失败是全站口径，
  /// 记在主站；定稿值对某个子域无效只冷却那个子域）。
  CfClearanceAuthority get _ledger => CfClearanceAuthority.instance;
  static const _toastCooldown = Duration(seconds: 2);

  /// 等待 navigator context 就绪的上限。
  ///
  /// 启动早期 context 通常几百毫秒内到位;等不到说明当前环境根本没有前台
  /// UI(后台 isolate 等),此时应放弃验证而不是挂死。
  static const _contextWaitTimeout = Duration(seconds: 10);

  /// "切兼容模式"询问被拒绝后的静默期。
  ///
  /// 此前一旦拒绝就沉默到登出,用户启动时随手点了取消,之后哪怕盾天天触发
  /// 也不再询问。给它加时效:既不反复打扰,也不永久放弃。
  static const _sessionCompatDeclineTtl = Duration(minutes: 30);

  /// 主站（也就是能否起验证）是否在冷却期
  bool get isInCooldown => _ledger.isCoolingDown(CfClearanceAuthority.mainHost);

  /// [host] 是否在冷却期（它自己的冷却，或全站的验证冷却）。
  bool isCoolingDown(String host) => _ledger.isCoolingDown(host);

  /// 主站冷却截止时刻(仅供诊断快照读取,不参与判定——判定请用 [isInCooldown])。
  DateTime? get cooldownUntil =>
      _ledger.cooldownUntil(CfClearanceAuthority.mainHost);

  /// 连续验证失败次数(诊断用)。
  int get consecutiveFailures =>
      _ledger.consecutiveFailures(CfClearanceAuthority.mainHost);

  /// 本次会话是否已被用户拒绝过"切兼容模式"询问(诊断用)。
  /// 当前是否处于「已拒绝切兼容」的静默期内(诊断用)。
  bool get sessionCompatPromptDeclined {
    final declinedAt = _sessionCompatDeclinedAt;
    if (declinedAt == null) return false;
    return DateTime.now().difference(declinedAt) < _sessionCompatDeclineTtl;
  }

  /// 重置所有 host 的冷却期和失败计数（验证成功、用户主动验证时调用）
  void resetCooldown() => _ledger.resetCooldown();

  /// 最近一轮验证的轮次号（每真正起一轮验证递增）。
  ///
  /// 多个并发请求撞盾会合流到同一轮验证,失败计数按轮次去重(见
  /// [startCooldown]),否则一次时序抖动会被记成 N 次失败。
  int get verifyRound => _rounds.roundCounter;

  /// 记录一次验证失败，连续达到上限后进入冷却期（全站口径）。
  ///
  /// [round] 传入触发本次失败的验证轮次号(见 [verifyRound])，同一轮只记一次；
  /// 不传则按独立失败计数。详见 [CfClearanceAuthority.recordVerifyFailure]。
  void startCooldown({int? round}) => _ledger.recordVerifyFailure(round: round);

  static void showGlobalMessage(String message, {bool isError = true}) {
    final now = DateTime.now();
    if (_lastToastAt != null &&
        now.difference(_lastToastAt!) < _toastCooldown) {
      return;
    }
    _lastToastAt = now;
    if (isError) {
      ToastService.showError(message);
    } else {
      ToastService.showInfo(message);
    }
  }

  /// 原生链路在完成验证后仍被 CF 拒绝时，询问用户是否仅在本次会话
  /// 使用浏览器网络栈。并发失败请求共享同一个弹窗结果。
  Future<bool> confirmSessionCompatibilityMode() {
    if (sessionCompatPromptDeclined) return Future.value(false);
    final active = _activeSessionCompatPrompt;
    if (active != null) return active;

    late final Future<bool> future;
    future = _confirmSessionCompatibilityModeInternal().whenComplete(() {
      if (identical(_activeSessionCompatPrompt, future)) {
        _activeSessionCompatPrompt = null;
      }
    });
    _activeSessionCompatPrompt = future;
    return future;
  }

  Future<bool> _confirmSessionCompatibilityModeInternal() async {
    BuildContext? context = _context;
    if (context == null || !context.mounted) {
      context = navigatorKey.currentContext;
    }
    if (context == null || !context.mounted) return false;

    final choice = await showDialog<_CompatPromptChoice>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(S.current.cf_sessionCompatTitle),
          // 三个动作横排放不下(中文约 360px、英文约 500px,而对话框可用宽度
          // 只有 280~320px,OverflowBar 会自动竖排,把"取消"顶到最上面、
          // 主次层级反过来)。故把第三条出路降级为正文里的文字链接:
          // 主次分明,且它紧跟在解释文字后面,阅读顺序自然。
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(S.current.cf_sessionCompatMessage),
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop(_CompatPromptChoice.disableAutoVerify),
                  child: Text(
                    S.current.cf_sessionCompatDisableAuto,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_CompatPromptChoice.dismiss),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CompatPromptChoice.enableCompat),
              child: Text(S.current.cf_sessionCompatEnable),
            ),
          ],
        );
      },
    );

    switch (choice) {
      case _CompatPromptChoice.enableCompat:
        return true;

      case _CompatPromptChoice.disableAutoVerify:
        autoVerifyEnabled = false;
        // 持久化交给设置层(它持有 SharedPreferences);未注入时只改内存态。
        await disableAutoVerifyRequest?.call();
        // 关掉自动过盾后不必再问兼容模式 —— 后续撞盾会静默 reject 并由
        // ErrorView 给出手动验证入口,不再走到本询问。
        _sessionCompatDeclinedAt = DateTime.now();
        showGlobalMessage(
          S.current.cf_autoVerifyDisabledHint,
          isError: false,
        );
        CfChallengeLogger.log(
          '[PROMPT] User disabled auto verify from compat prompt',
        );
        return false;

      case _CompatPromptChoice.dismiss:
      case null:
        // 用户明确拒绝:进入静默期不再打扰。带时效而非永久——盾的成因
        // (出口 IP、代理配置)可能在半小时内就变了,那时值得再问一次。
        _sessionCompatDeclinedAt = DateTime.now();
        return false;
    }
  }

  void resetSessionCompatibilityDecision() {
    _sessionCompatDeclinedAt = null;
  }

  void setContext(BuildContext context) {
    _context = context;
    if (context.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      if (!_contextReadyCompleter!.isCompleted) {
        _contextReadyCompleter!.complete(context);
      }
    }
  }

  // 「响应是不是 CF 挑战」的判定统一在 CfChallengeClassifier，这里只保留
  // 验证页自身用到的 DOM 状态判定（挑战是否仍在运行、是否落到源站 404）。

  /// 检测页面 HTML 中是否有活跃的 CF 验证盾
  /// 用于判断已加载的页面是否仍在展示验证挑战
  static bool hasActiveCfChallenge(String html) {
    return html.contains('cf-turnstile') ||
        html.contains('challenge-running') ||
        html.contains('challenge-stage') ||
        html.contains('cf_chl_opt');
  }

  /// 检测页面 HTML 是否是源站返回的 404 / 非挑战内容
  /// 用于在 onReceivedHttpError 不可靠的平台上识别 Discourse 404 等非挑战页面
  static bool isOriginNotFound(String html) {
    if (html.isEmpty) return false;
    final lower = html.toLowerCase();
    // 仅保留稳定的 Discourse 自身特征，避免论坛名含 "404" 等场景误判
    return lower.contains('page-not-found') ||
        lower.contains('discourse-no-results') ||
        lower.contains('"errortype":"notfound"') ||
        lower.contains('404-body') ||
        lower.contains('exist or is private') ||
        lower.contains('page you requested');
  }

  /// 页面数据/操作请求撞盾时，先在后台静默尝试的宽限期。
  ///
  /// 非交互式挑战（JS / managed 无需点击）多数能在这段时间内自动通过，
  /// 用户全程只看到一个「正在自动验证」胶囊；仍未通过再转前台交给用户。
  /// 此前这类请求一撞盾就直接全屏弹验证页，哪怕挑战几秒后会自己过。
  static const silentFirstGrace = Duration(seconds: 6);

  /// 发起或加入一轮验证，返回这一轮的结果。
  ///
  /// [CfRoundPassed] 表示定稿值**已经在 jar 里**，调用方直接重放即可，
  /// 不需要再「等 1.5 秒 → 同步 → 重试」；失败带类型化原因（冷却 / 无 UI /
  /// 取消 / 超时 / 未落值 / 无从判断）。
  Future<CfRoundOutcome> verify({
    CfVerifyMode mode = CfVerifyMode.foreground,
    BuildContext? context,
  }) {
    return _rounds.verify(mode: mode, context: context);
  }

  /// 显示手动验证页面（旧口径包装，新代码请用 [verify]）。
  /// 返回值：true=验证通过且定稿值已在 jar, false=验证失败/取消,
  /// null=冷却期内暂不可用或没有前台 UI
  /// [forceForeground] 是否强制前台显示（默认为 true）
  Future<bool?> showManualVerify([
    BuildContext? context,
    bool forceForeground = true,
  ]) {
    return verify(
      mode: forceForeground ? CfVerifyMode.foreground : CfVerifyMode.background,
      context: context,
    ).then(_legacyResult);
  }

  /// 先后台静默验证，[silentFirstGrace] 内未通过再转前台（旧口径包装）。
  ///
  /// 供页面数据/操作请求等自动发起的撞盾恢复使用；用户主动点击的验证入口
  /// 仍应直接前台展示（[showManualVerify] / [showManualVerifyNow]）。
  Future<bool?> showVerifySilentFirst([BuildContext? context]) {
    return verify(
      mode: CfVerifyMode.silentFirst,
      context: context,
    ).then(_legacyResult);
  }

  static bool? _legacyResult(CfRoundOutcome outcome) => switch (outcome) {
    CfRoundPassed() => true,
    CfRoundFailed(reason: CfRoundFailure.cooldown || CfRoundFailure.noUi) =>
      null,
    CfRoundFailed() => false,
  };

  /// 用户主动触发的验证入口：允许绕过冷却期。
  Future<bool?> showManualVerifyNow([
    BuildContext? context,
    bool forceForeground = true,
  ]) {
    resetCooldown();
    return showManualVerify(context, forceForeground);
  }

  static String get _verifyUrl => '${AppConstants.baseUrl}/challenge';

  /// 每一轮验证页的展示状态（overlay、页面 key、收尾动作）。
  final Map<int, _VerifyPresentation> _presentations = {};

  /// 找到可用的前台 UI：传入的 > 已设置的 > 全局 navigatorKey。
  Future<_VerifyUi?> _resolveUi(BuildContext? context) async {
    CfChallengeLogger.logVerifyStart(_verifyUrl);

    BuildContext? ctx = context ?? _context;
    if (ctx == null || !ctx.mounted) {
      // 使用全局 navigatorKey 作为备用
      final navState = navigatorKey.currentState;
      if (navState != null && navState.context.mounted) {
        ctx = navState.context;
        debugPrint('[CfChallenge] Using global navigatorKey context');
      }
    }

    // 启动时可能还没有可用的 context，等到 context 可用后立即弹出。
    //
    // 但这个等待必须有上限:后台 isolate(iOS 后台拉取)与无 UI 环境里
    // context 永远不会到来,无限等待会让请求挂死,只能靠系统任务超时收尸
    // (历史上后台拉取撞盾就是这个形态)。启动早期的等待仍然有效——那时
    // context 通常在几百毫秒内就绪。
    if (ctx == null || !ctx.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      debugPrint('[CfChallenge] Waiting for context to be ready...');
      try {
        ctx = await _contextReadyCompleter!.future.timeout(
          _contextWaitTimeout,
        );
      } on TimeoutException {
        debugPrint(
          '[CfChallenge] 等待 context 超时 '
          '(${_contextWaitTimeout.inSeconds}s),按无 UI 环境处理',
        );
        CfChallengeLogger.log(
          '[VERIFY] Skipped: no UI available after '
          '${_contextWaitTimeout.inSeconds}s',
          level: 'warning',
        );
        return null;
      }
    }
    if (!ctx.mounted) {
      debugPrint('[CfChallenge] Context no longer mounted');
      return null;
    }

    // ignore: use_build_context_synchronously
    final overlayState =
        Overlay.maybeOf(ctx, rootOverlay: true) ??
        navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      return null;
    }
    return _VerifyUi(ctx, overlayState);
  }

  /// 有调用方合流进进行中的一轮：前台入口立刻转前台；页面数据/操作请求
  /// 同样只给宽限期，到点仍未通过再转前台。
  void _onJoin(CfVerificationRound round, CfVerifyMode mode) {
    switch (mode) {
      case CfVerifyMode.foreground:
        _requestPromote();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _activePromoteToForeground?.call();
        });
      case CfVerifyMode.silentFirst:
        // 按轮次校验，避免旧计时器把之后新起的一轮误转前台。
        Timer(silentFirstGrace, () {
          if (!identical(_rounds.active, round) || round.isDone) return;
          _requestPromote();
        });
      case CfVerifyMode.background:
        break;
    }
  }

  void _requestPromote() {
    final promote = _activePromoteToForeground;
    if (promote == null) {
      _pendingPromoteToForeground = true;
    } else {
      promote();
    }
  }

  /// 在 [ui] 上展示验证页并把它接到 [round]。overlay 已失效返回 false。
  bool _present(
    CfVerificationRound round,
    CfVerifyMode mode,
    _VerifyUi ui,
    String? oldClearanceValue,
  ) {
    final overlayState = ui.overlay;
    if (!overlayState.mounted) {
      debugPrint('[CfChallenge] Overlay no longer mounted');
      CfChallengeLogger.log('[VERIFY] Overlay not mounted');
      _pendingPromoteToForeground = false;
      return false;
    }
    final forceForeground = mode == CfVerifyMode.foreground;
    final foregroundAfter = mode == CfVerifyMode.silentFirst
        ? silentFirstGrace
        : null;

    late final OverlayEntry entry;
    // 引用当前的拦截 Route，用于 cleanup
    ModalRoute? interceptorRoute;

    /// 验证结束清理时放行 interceptorRoute 的 PopScope（见 cleanup 内注释）。
    final interceptorRoutePopAllowed = ValueNotifier<bool>(false);

    // Page Key 用于触发内部弹窗
    final pageKey = GlobalKey<_CfChallengePageState>();
    _activePromoteToForeground = () {
      pageKey.currentState?._promoteToForeground();
    };
    if (_pendingPromoteToForeground) {
      _pendingPromoteToForeground = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _activePromoteToForeground?.call();
      });
    }

    // 清理资源
    void cleanup() {
      void removeEntry() {
        if (entry.mounted) {
          entry.remove();
        }
      }

      // Windows 插件会在 evaluateJavascript 返回后继续派发原生回调。
      // 先让页面停止所有探测，再延迟销毁 PlatformView，避免回调命中已经
      // 释放的 UserContentController（0xc0000005）。其他平台保持原时序。
      if (io.Platform.isWindows) {
        Future.delayed(_postCleanupCooldown, removeEntry);
      } else {
        removeEntry();
      }
      final routeToClose = interceptorRoute;
      if (routeToClose != null && routeToClose.isActive) {
        // 绝不能 removeRoute：框架 _flushHistoryUpdates 的 remove 分支不会
        // 给下方路由补发 didPopNext（RouteObserver 也没有 didRemove 实现），
        // 下方页面的 RouteAware 订阅者（话题详情 ScreenTrack、视频、iframe）
        // 会永远停在「被覆盖」状态——曾表现为 CF 验证通过后 ScreenTrack 不再
        // start，阅读时长怎么滑动都不上报。放行 PopScope 后走正常 pop，让
        // 路由生命周期通知完整派发。canPop 变更要等下一帧重建才生效，pop
        // 放到 post-frame。
        interceptorRoutePopAllowed.value = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!routeToClose.isActive) return;
          final nav = routeToClose.navigator;
          if (nav == null) return;
          if (routeToClose.isCurrent) {
            nav.pop();
          } else {
            // 极端兜底：验证期间有别的路由压到它上面（正常不会发生——前台
            // 验证时全屏 Overlay 拦截所有交互）。pop 动画是异步的，无法同步
            // 回收到本 route，退化为 removeRoute。
            nav.removeRoute(routeToClose);
          }
        });
      }
      _activePromoteToForeground = null;
      _pendingPromoteToForeground = false;
      // 延迟结束这一轮：给原生 WebView2 控制器留出真正销毁的时间，
      // 这段时间内的新验证请求合流到刚结束的一轮，而不是立刻起新
      // WebView 撞上销毁中的旧实例（见 _postCleanupCooldown 处注释）。
      Future.delayed(_postCleanupCooldown, () => _rounds.release(round));
    }

    // 创建 OverlayEntry
    // 我们需要传递一个 promoteCallback 给 Page，让 Page 能调用 Service 来 push route
    void onPromoteToForeground(BuildContext pageContext) {
      if (interceptorRoute != null && interceptorRoute!.isActive) {
        return; // 已经有 Route 了
      }

      // Push 透明 Route 用于拦截返回键
      interceptorRoute = PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, _, _) {
          // canPop 由 cleanup 在验证结束时放行：验证期间拦截系统返回键
          // 弹退出确认；结束时必须让本 route 走正常 pop（而非 removeRoute），
          // 否则下方路由永远收不到 didPopNext（见 cleanup 内注释）。
          return ValueListenableBuilder<bool>(
            valueListenable: interceptorRoutePopAllowed,
            builder: (context, canPop, _) {
              return PopScope(
                canPop: canPop,
                onPopInvokedWithResult: (didPop, result) async {
                  if (didPop) return;
                  if (!isVerifying) return;

                  // 触发内部弹窗 via GlobalKey
                  pageKey.currentState?.showExitConfirmation();
                },
                // 使用 IgnorePointer 让点击事件穿透到下层的 Overlay (WebView)
                child: const IgnorePointer(child: SizedBox.expand()),
              );
            },
          );
        },
      );

      Navigator.of(pageContext).push(interceptorRoute!).then((_) {
        // Route 被 pop（cleanup 走正常 pop 后在这里完成）
        interceptorRoutePopAllowed.dispose();
      });
    }

    entry = OverlayEntry(
      builder: (context) => CfChallengePage(
        key: pageKey,
        verifyUrl: _verifyUrl,
        signals: round,
        startInBackground: !forceForeground,
        foregroundAfter: forceForeground ? null : foregroundAfter,
        onPromoteRequest: () => onPromoteToForeground(context),
        oldCfClearanceValue: oldClearanceValue,
      ),
    );
    overlayState.insert(entry);
    _presentations[round.id] = _VerifyPresentation(
      pageKey: pageKey,
      cleanup: cleanup,
    );

    // 如果初始就是前台，立即执行 promote
    if (forceForeground) {
      // Post frame callback to ensure overlay is mounted and context is valid
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 使用解析 UI 时拿到的 context：Navigator.of(ctx) 能找到正确的 Navigator
        onPromoteToForeground(ui.context);
      });
    }
    return true;
  }

  /// 一轮出了结果：撤下验证页（没有展示过就直接结束这一轮）。
  void _dismiss(CfVerificationRound round) {
    final presentation = _presentations.remove(round.id);
    if (presentation == null) {
      _activePromoteToForeground = null;
      _pendingPromoteToForeground = false;
      _rounds.release(round);
      return;
    }
    presentation.cleanup();
  }

  /// 验证页的 WebView 控制器（Windows 落值要经它走 CDP 读实时 cookie）。
  InAppWebViewController? _pageControllerFor(CfVerificationRound round) =>
      _presentations[round.id]?.pageKey.currentState?._controller;
}

/// 解析出的前台 UI。
class _VerifyUi {
  const _VerifyUi(this.context, this.overlay);

  final BuildContext context;
  final OverlayState overlay;
}

class _VerifyPresentation {
  const _VerifyPresentation({required this.pageKey, required this.cleanup});

  final GlobalKey<_CfChallengePageState> pageKey;
  final void Function() cleanup;
}

/// 验证轮次在本服务上的外部能力：验证页、overlay、续期服务、jar。
class _ServiceRoundEnvironment implements CfRoundEnvironment {
  _ServiceRoundEnvironment(this._service);

  final CfChallengeService _service;

  /// 当前这一轮的 WebView 使用期（同一时间只有一轮）：过盾前对账 `_t`，
  /// 定稿值落地，过盾后再交 `_t`；轮次撤下时结束。
  WebViewUse? _webViewUse;

  @override
  Future<Object?> ensureUi(BuildContext? context) =>
      _service._resolveUi(context);

  @override
  Future<void> stopRefresh() async {
    if (io.Platform.isWindows) {
      await EmbeddedBrowserControllerPool.instance.suspendAndDrain();
    }
    // 停止自动续期服务，避免与手动验证冲突。必须 await 到它的 headless
    // WebView 真正销毁完毕再继续——之前这里不等待，紧接着往下建自己的验证
    // WebView，两个 WebView 短暂共存，实测会撞上 flutter_inappwebview_windows
    // 的一处原生崩溃（0xc0000005）。
    await CfClearanceRefreshService().stop();
  }

  @override
  void restartRefreshLater() {
    // 验证页移除后，Windows WebView2 的原生 Controller 仍会异步析构。
    // 等验证冷却完成、帖子 WebView 池恢复后再错峰启动续期 WebView。
    Future.delayed(
      CfChallengeService._postCleanupCooldown +
          CfChallengeService._refreshRestartCooldown,
      () {
        if (!_service.isVerifying) {
          CfClearanceRefreshService().start();
        }
      },
    );
  }

  @override
  Future<Object?> backupAndClear() async {
    // 备份旧 cf_clearance，验证失败时恢复（避免误删仍有效的值）
    final cookieJarService = CookieJarService();
    final backup = await cookieJarService.getCfClearanceCookie();

    // Dio 请求已经撞盾，说明当前 cf_clearance 可能失效了。
    // 必须确保 WebView 中也没有旧的 cf_clearance，否则 CF 直接放行不显示盾。
    await cookieJarService.deleteCookie('cf_clearance');
    await cookieJarService.deleteWebViewCookie('cf_clearance');
    return backup;
  }

  @override
  Future<void> restore(Object? backup) async {
    if (backup is! io.Cookie) return;
    await CookieJarService().restoreCfClearance(backup);
    debugPrint('[CfChallenge] 验证未通过，已恢复备份 cf_clearance');
  }

  @override
  Future<void> primeSession() async {
    // 一轮验证的 WebView 使用期开始。验证 WebView 与 App 共用 CookieManager，
    // 过盾后它会带着 WebView 里的 _t 去加载站内页：准备阶段只做 _t 的对账
    // （WebView 没有 _t 就把 jar 的推过去；不一致只按血缘判断、不探测——
    // 探测请求此刻自己也会被 CF 拦下），有时限，不阻塞验证流程。
    unawaited(_webViewUse?.end(WebViewUseOutcome.aborted));
    final use = _webViewUse = WebViewUses.instance.start(
      WebViewUsePurpose.cfVerification,
      url: CfChallengeService._verifyUrl,
      reason: 'cf_verification',
    );
    await use.ready;
  }

  @override
  Future<bool> present(
    CfVerificationRound round,
    CfVerifyMode mode,
    Object ui,
    Object? backup,
  ) async {
    return _service._present(
      round,
      mode,
      ui as _VerifyUi,
      backup is io.Cookie ? CookieValueCodec.decode(backup.value) : null,
    );
  }

  @override
  void onJoin(CfVerificationRound round, CfVerifyMode mode) =>
      _service._onJoin(round, mode);

  @override
  void dismiss(CfVerificationRound round) {
    // 过盾的已在 onPassed 结束；失败 / 撤下的这一轮什么都不再写
    unawaited(_webViewUse?.end(WebViewUseOutcome.aborted));
    _webViewUse = null;
    _service._dismiss(round);
  }

  @override
  Future<String?> land(CfVerificationRound round, String value) async {
    final authority = CfClearanceAuthority.instance;
    // 定稿值是本会话最新、经挑战确认的值：闸门对它放行（即便验证期间有别的
    // 同步往空 jar 里写过一枚"健康"值）。
    authority.expectVerifiedSuccessor(value);
    try {
      // 只接受这一枚定稿值、可信写入（口径在 WebViewUses）。轮次会读回
      // 校验、失败重试，所以这是使用期内的阶段同步，不是结束。
      final use = _webViewUse ??= WebViewUses.instance.start(
        WebViewUsePurpose.cfVerification,
        url: CfChallengeService._verifyUrl,
        reason: 'cf_verification',
      );
      await use.landVerifiedClearance(
        value,
        controller: _service._pageControllerFor(round),
      );
    } finally {
      authority.expectVerifiedSuccessor(null);
    }
    return CookieJarService().getCfClearance();
  }

  @override
  void onPassed(CfVerificationRound round, String value) {
    // 广播:一次 CF 挑战被成功解决,定稿 cf_clearance 已落 jar。
    _service.clearanceResolvedAt.value = DateTime.now();
    // 过盾：这一轮的使用期结束，_t 交 SessionTokenAuthority（在后台对账，
    // 不阻塞：对账可能正等着另一次对账的探测，而那个探测恰恰在等这次验证
    // 结束；WebView 的 _t 被服务端删了就把 jar 的推回去）。
    final use = _webViewUse;
    _webViewUse = null;
    if (use != null) {
      unawaited(
        use.end(WebViewUseOutcome.cfPassed, reason: 'cf_challenge_passed'),
      );
    }
  }

  @override
  bool isCoolingDown() => _service.isInCooldown;

  @override
  void recordFailure(int round) => _service.startCooldown(round: round);

  @override
  void resetFailures() => _service.resetCooldown();
}

/// CF 验证页面
class CfChallengePage extends StatefulWidget {
  const CfChallengePage({
    super.key,
    required this.verifyUrl,
    required this.signals,
    this.startInBackground = false,
    this.foregroundAfter,
    this.onPromoteRequest,
    this.oldCfClearanceValue,
  });

  final String verifyUrl;

  /// 先后台尝试验证，超时后再切到前台
  final bool startInBackground;

  /// 后台尝试的时限（覆盖默认的后台超时）。非空表示调用方在等结果：
  /// 后台提前判定失败时转前台交给用户，而不是直接放弃。
  final Duration? foregroundAfter;

  /// 这一轮验证：页面只向它上报原始信号（读到的新值、完成迹象、放弃），
  /// 定稿与落值由它负责。
  final CfVerificationSignals signals;
  final VoidCallback? onPromoteRequest;

  /// 验证开始前备份的旧 cf_clearance 值（已解码）
  /// 用于可靠过滤 Windows 上 WebView 中未完全删除的残留旧值
  final String? oldCfClearanceValue;

  @override
  State<CfChallengePage> createState() => _CfChallengePageState();
}

class _CfChallengePageState extends State<CfChallengePage> {
  InAppWebViewController? _controller;
  final _webViewKey = GlobalKey();
  bool _isLoading = true;
  double _progress = 0;
  bool _hasMarkedPageReady = false;
  bool _hasPopped = false; // 防止重复 pop
  late bool _isBackground;
  late bool _needsManualAttention;
  bool _challengeWebViewVisible = false;
  bool _hasSeenChallenge = false;
  bool _hideOriginFallbackPage = false;
  bool _checkingOriginFallback = false;
  bool _originFallbackNeedsAction = false;
  /// 已把完成交给验证轮次定稿（页面盖住 WebView、停掉自己的探测，等轮次
  /// 收口后被撤下）。
  bool _handedOff = false;
  int _loadGeneration = 0;
  int _challengeRevealProbeGeneration = 0;
  bool _hasTimedOut = false;
  int _checkCount = 0;

  /// 前台预算用尽但挑战仍可见时已记过一次「等待用户」日志（每轮只记一次）。
  bool _loggedForegroundWaitingForUser = false;
  Timer? _timeoutTimer;
  Timer? _noChallengeCheckTimer;
  Timer? _loadStopFallbackTimer;
  Timer? _pageReadyFallbackTimer;

  /// 后台验证的「正在自动验证」胶囊是否已露出。多数非交互挑战一两秒就过，
  /// 这时不打扰用户；过了 [_backgroundPillDelay] 还在验证才显示。
  bool _pillVisible = false;
  Timer? _pillDelayTimer;
  static const _backgroundPillDelay = Duration(seconds: 2);
  static const _backgroundMaxCheckCount = 10;
  static const _foregroundMaxCheckCount = 60;
  static const _noChallengeCheckDelay = Duration(milliseconds: 1200);
  static const _revealStateWatchInterval = Duration(milliseconds: 150);
  static const _loadStopFallbackDelay = Duration(milliseconds: 1200);
  static const _pageReadyFallbackDelay = Duration(seconds: 4);
  static const _completionProbeTimeout = Duration(seconds: 8);
  static const _noChallengeProbeTimeout = Duration(milliseconds: 1800);

  /// 验证页面加载时 WebView 中的 cf_clearance 快照
  /// 用于区分「旧值残留」和「验证后新设的值」
  String? _initialCfClearance;

  int get _activeMaxCheckCount => _isBackground
      ? (widget.foregroundAfter?.inSeconds ?? _backgroundMaxCheckCount)
      : _foregroundMaxCheckCount;

  @override
  void initState() {
    super.initState();
    _isBackground = widget.startInBackground;
    if (_isBackground) {
      _pillDelayTimer = Timer(_backgroundPillDelay, () {
        if (!mounted || !_isBackground || _handedOff) return;
        CfChallengeLogger.log(
          '[VERIFY] Background verify still running after '
          '${_backgroundPillDelay.inSeconds}s, showing pill',
        );
        setState(() => _pillVisible = true);
      });
    }
    _needsManualAttention = false;
    _snapshotInitialClearance();
    widget.signals.attachReader(_readFreshClearance);
  }

  /// 轮次定稿期间主动读值的入口：只返回与初始快照不同的新值。
  Future<String?> _readFreshClearance() async {
    final value = await _readCookieValue('cf_clearance');
    return _isFreshClearance(value) ? value : null;
  }

  /// 记录验证开始时的旧 cf_clearance 值
  /// 优先使用 showManualVerify 传入的备份值（可靠），WebView 读取作为补充
  /// 解决 Windows 上 initState 时 controller 为 null 导致 _initialCfClearance
  /// 为 null，进而无法过滤残留旧值、误判为验证成功的问题
  Future<void> _snapshotInitialClearance() async {
    // 优先使用从 showManualVerify 传入的备份旧值（最可靠）
    if (widget.oldCfClearanceValue != null &&
        widget.oldCfClearanceValue!.isNotEmpty) {
      _initialCfClearance = widget.oldCfClearanceValue;
      debugPrint(
        '[CfChallenge] 使用备份的旧 cf_clearance 作为初始快照 '
        '(${_initialCfClearance!.length} chars)',
      );
      return;
    }

    // 兜底：从 WebView 读取（可能不可靠，但聊胜于无）
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      _initialCfClearance = cookieValue;
      if (_initialCfClearance != null && _initialCfClearance!.isNotEmpty) {
        debugPrint(
          '[CfChallenge] ⚠️ 验证页加载时 WebView 仍存在旧 cf_clearance '
          '(${_initialCfClearance!.length} chars)，将忽略该值',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 快照 cf_clearance 失败: $e');
    }
  }

  @override
  void dispose() {
    widget.signals.attachReader(null);
    _pillDelayTimer?.cancel();
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    // InAppWebView 自身会随 Widget 销毁平台 Controller；这里再次手动
    // dispose 会让 Windows 插件对同一个原生对象执行双重释放。
    _controller = null;
    super.dispose();
  }

  /// 读取 cookie 值：先尝试 CookieManager，Windows 上 fallback 到 DevTools
  Future<String?> _readCookieValue(String name) async {
    try {
      final cookie = await _cfCookieManager.getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: name,
      );
      if (cookie != null && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    } catch (e) {
      debugPrint('[CfChallenge] CookieManager 读取 $name 失败: $e');
    }

    // Windows：通过当前页面 controller 读取实时 cookie，再回退到 CookieJar
    if (io.Platform.isWindows && _controller != null) {
      final liveValue = await CookieJarService().readCookieValueFromController(
        _controller!,
        name,
        currentUrl: widget.verifyUrl,
      );
      if (liveValue != null && liveValue.isNotEmpty) {
        return liveValue;
      }
      return CookieJarService().getCookieValue(name);
    }

    if (io.Platform.isWindows) {
      return CookieJarService().getCookieValue(name);
    }

    // Linux WPE: getCookie() 内部已调 getCookies(url) 做 URL 过滤，
    // 若 URL 匹配有问题，改用 getAllCookies() 绕过 URL 过滤
    if (io.Platform.isLinux) {
      try {
        final allCookies = await _cfCookieManager.getAllCookies();
        for (final c in allCookies) {
          if (c.name == name && c.value.isNotEmpty) {
            return c.value;
          }
        }
      } catch (e) {
        debugPrint(
          '[CfChallenge] Linux getAllCookies fallback 读取 $name 失败: $e',
        );
      }
    }

    return null;
  }

  /// 把完成交给验证轮次定稿：盖住 WebView（显示「正在完成验证」）、
  /// 停掉页面自己的所有探测。落值与 `_t` 对账都由轮次负责。
  void _handOff(String reason) {
    if (_handedOff || _hasPopped) return;
    _coverWebViewForOriginFallback();
    _handedOff = true;
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _revealStateWatchGeneration++;
    debugPrint('[CfChallenge] $reason，交给验证轮次定稿');
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // JS 注入：拦截 XHR/fetch 对 cdn-cgi/challenge-platform 的响应
  // 当 challenge-platform 请求完成时，通过 JS Handler 通知 Flutter 侧
  // Flutter 侧用 CookieManager（可读 HttpOnly cookie）检查 cf_clearance
  // ---------------------------------------------------------------------------

  /// 注入 XHR/fetch 拦截 + 页面内 DOM 遮罩脚本
  ///
  /// 两层防线，确保跳转期间一帧 404 都不露：
  /// 1. JS 层：在 `beforeunload` / `pagehide` 的同一个 tick 里，立即往 DOM 里塞一个
  ///    `position:fixed;z-index:max` 的全屏 div，挡住当前页面剩余的渲染。
  /// 2. Flutter 层：通过 `onChallengeNavigation` Handler 通知 Dart 端 setState，
  ///    在 PlatformView 完成新页面渲染前用 Flutter 遮罩盖住。
  Future<void> _injectChallengeInterceptor(
    InAppWebViewController controller,
  ) async {
    final maskColorHex = _resolveMaskColorHex();
    await controller.evaluateJavascript(
      source:
          '''
(function() {
  if (window._cfInterceptorInstalled) return;
  window._cfInterceptorInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

  var CP = 'cdn-cgi/challenge-platform';

  // 拦截 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this._cfUrl = url;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    var self = this;
    if (self._cfUrl && self._cfUrl.indexOf(CP) !== -1) {
      self.addEventListener('load', function() {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', self._cfUrl, self.status);
        } catch(e) {}
      });
    }
    return origSend.apply(this, arguments);
  };

  // 拦截 fetch
  var origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
    return origFetch.apply(this, arguments).then(function(resp) {
      if (url.indexOf(CP) !== -1) {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', url, resp.status);
        } catch(e) {}
      }
      return resp;
    });
  };

  // 页面内 DOM 遮罩：CF 跳走的瞬间立刻挡住，不依赖 Flutter rebuild
  function showCfMask() {
    var root = document.body || document.documentElement;
    if (!root) return;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) {
      mask.style.display = 'block';
      return;
    }
    mask = document.createElement('div');
    mask.id = '__fluxdoCfMask';
    mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
      (window.__fluxdoCfMaskColor || '#ffffff') +
      '!important;z-index:2147483647!important;pointer-events:auto!important;';
    root.appendChild(mask);
  }
  window.__fluxdoShowCfMask = showCfMask;

  // 仅监听真正的"页面即将卸载"事件。
  // 不要 hook history.pushState/replaceState：CF Turnstile 验证过程中
  // 会用 history API 更新 URL 但不真正导航，hook 会在验证未完成时误触发 fallback。
  function notifyNav(reason) {
    showCfMask();
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });
})();
''',
    );
  }

  /// 取当前主题的 surface 色作为页面内 mask 颜色，深色模式下不会闪白
  String _resolveMaskColorHex() {
    if (!mounted) return '#ffffff';
    final color = Theme.of(context).colorScheme.surface;
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  UnmodifiableListView<UserScript> _initialChallengeScripts() {
    final maskColorHex = _resolveMaskColorHex();
    return UnmodifiableListView([
      UserScript(
        source: _documentStartMaskScript(maskColorHex),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
      ...WebViewSettings.compatPolyfillScripts,
    ]);
  }

  String _documentStartMaskScript(String maskColorHex) {
    return '''
(function() {
  if (window.__fluxdoCfDocumentMaskInstalled) return;
  window.__fluxdoCfDocumentMaskInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

  function root() {
    return document.body || document.documentElement;
  }

  function ensureMask() {
    var r = root();
    if (!r) return null;
    var mask = document.getElementById('__fluxdoCfMask');
    if (!mask) {
      mask = document.createElement('div');
      mask.id = '__fluxdoCfMask';
      mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
        (window.__fluxdoCfMaskColor || '#ffffff') +
        '!important;z-index:2147483647!important;pointer-events:auto!important;';
      r.appendChild(mask);
    }
    return mask;
  }

  window.__fluxdoCfMaskSuppressed = false;

  window.__fluxdoShowCfMask = function(force) {
    if (window.__fluxdoCfMaskSuppressed && !force) return;
    window.__fluxdoCfMaskSuppressed = false;
    var mask = ensureMask();
    if (mask) mask.style.display = 'block';
  };

  window.__fluxdoHideCfMask = function() {
    window.__fluxdoCfMaskSuppressed = true;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) mask.style.display = 'none';
  };

  function notifyNav(reason) {
    window.__fluxdoShowCfMask(true);
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }

  function looksLikeOrigin404() {
    try {
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      var title = document.title || '';
      var haystack = (html + ' ' + title).toLowerCase();
      return haystack.indexOf('page-not-found') !== -1 ||
        haystack.indexOf('discourse-no-results') !== -1 ||
        haystack.indexOf('"errortype":"notfound"') !== -1 ||
        haystack.indexOf('404-body') !== -1 ||
        haystack.indexOf('exist or is private') !== -1 ||
        haystack.indexOf('page you requested') !== -1 ||
        title.indexOf('404') !== -1;
    } catch(e) {
      return false;
    }
  }

  var origin404Notified = false;
  function probeOrigin404() {
    if (origin404Notified || !looksLikeOrigin404()) return;
    origin404Notified = true;
    notifyNav('origin-404-dom');
  }

  function installOrigin404Observer() {
    probeOrigin404();
    try {
      var observer = new MutationObserver(probeOrigin404);
      observer.observe(document.documentElement || document, {
        childList: true,
        subtree: true,
        characterData: true
      });
    } catch(e) {}
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      window.__fluxdoShowCfMask(false);
      installOrigin404Observer();
    }, { once: true });
  } else {
    window.__fluxdoShowCfMask();
    installOrigin404Observer();
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });
})();
''';
  }

  /// challenge-platform 响应到达时的回调
  ///
  /// 不再主动 reveal WebView：reveal 完全交给 _startChallengeRevealProbe，
  /// 避免「完成响应到达 → reveal → 紧接着 CF 跳转回 /challenge 加载源站 404」
  /// 期间 404 闪现。此处只负责 cf_clearance 探测，读到新值上报给轮次定稿。
  Future<void> _onChallengeComplete(List<dynamic> args) async {
    if (_hasPopped) return;
    final url = args.isNotEmpty ? args[0] : '';
    final status = args.length > 1 ? args[1] : 0;
    debugPrint('[CfChallenge] challenge-platform 响应: url=$url, status=$status');
    CfChallengeLogger.log(
      '[VERIFY] Challenge response: url=$url, status=$status',
    );

    try {
      final cookieValue = await _readCookieValue('cf_clearance');

      if (cookieValue == null || cookieValue.isEmpty) {
        debugPrint('[CfChallenge] 未检测到 cf_clearance，等待后续响应');
        return;
      }

      // 关键：对比初始快照，过滤掉未被清除干净的旧值
      if (!_isFreshClearance(cookieValue)) {
        debugPrint('[CfChallenge] cf_clearance 与初始值相同（旧值残留），忽略');
        return;
      }

      // cf_clearance 是新值，但需要确认页面已真正通过验证
      // challenge-platform 在验证过程中有多次请求（脚本加载、初始化、提交等），
      // 只有最终完成时页面才不再包含验证标记
      final html = await _controller?.evaluateJavascript(
        source: 'document.body ? document.body.innerHTML : ""',
      );
      if (html != null && CfChallengeService.hasActiveCfChallenge(html)) {
        debugPrint('[CfChallenge] 检测到新 cf_clearance 但页面仍在验证中，继续等待');
        return;
      }

      debugPrint(
        '[CfChallenge] ✓ 新 cf_clearance (${cookieValue.length} chars) 且页面已无挑战标记',
      );
      CfChallengeLogger.log(
        '[VERIFY] Completion signal: new cf_clearance and page passed challenge',
      );
      widget.signals.clearanceSeen(cookieValue, source: 'challenge hook');
      widget.signals.completionHint('challenge-platform response, no markers');
      _handOff('challenge-platform 响应后页面已通过');
    } catch (e) {
      debugPrint('[CfChallenge] cookie 检查异常: $e');
    }
  }

  /// 页面 unload/pagehide/history 变化时回调
  ///
  /// CF 验证完成后会跳到源 URL（/challenge → 404）。在 Android 上 `onLoadStart`
  /// 对部分 location.replace 跳转触发时机晚于 PlatformView 渲染，导致 404 闪现。
  /// 借助 JS 在跳走的最早时刻通知 Flutter，立即重置 reveal 状态、覆盖 WebView。
  Future<void> _onChallengeNavigation(List<dynamic> args) async {
    if (_hasPopped || !mounted || _handedOff) return;
    final reason = args.isNotEmpty ? args.first.toString() : 'unknown';
    if (!_challengeWebViewVisible && _hideOriginFallbackPage) {
      // 已经覆盖中，不必重复触发 fallback 流程
      return;
    }
    debugPrint('[CfChallenge] JS 导航事件 ($reason)，立刻覆盖 WebView');
    CfChallengeLogger.log('[VERIFY] JS navigation: $reason');
    await _handleVerifyOriginFallback(
      _loadGeneration,
      reason: 'js navigation: $reason',
      completionLikely: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 超时计时器（兜底机制）
  // ---------------------------------------------------------------------------

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _checkCount = 0;
    _hasTimedOut = false;
    _loggedForegroundWaitingForUser = false;
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _handedOff) {
        timer.cancel();
        return;
      }
      _checkCount++;
      if (!_isBackground && !_hasTimedOut) setState(() {}); // 更新计数显示

      // 兜底轮询：验证通过后页面重定向会销毁 JS 上下文，
      // 导致 onChallengeComplete 回调丢失（macOS 上尤为明显），
      // 每秒主动检查 cf_clearance 变化来弥补
      _pollCfClearance();

      if (_checkCount > _activeMaxCheckCount) {
        if (_isBackground) {
          if (widget.foregroundAfter == null &&
              !widget.signals.hasForegroundWaiter) {
            // 纯静默轮次（只有轮询等后台请求撞盾，没人等结果）：超时就按
            // 失败收口，让静默请求自己失败。此前这里会把全屏验证页弹到
            // 正在阅读的用户脸上，而用户并没有做任何会失败的操作。
            // 轮次正在定稿（已见新值）时不放弃，等定稿收口。
            if (widget.signals.isSettling) return;
            CfChallengeLogger.log(
              '[VERIFY] Silent background timeout after '
              '$_activeMaxCheckCount seconds, giving up without prompting',
            );
            timer.cancel();
            _giveUp(CfRoundFailure.timeout, detail: 'silent background timeout');
            return;
          }
          CfChallengeLogger.log(
            '[VERIFY] Background timeout after $_activeMaxCheckCount seconds, prompting manual verify',
          );
          _promoteToForeground(dueToTimeout: true);
          return;
        }
        // 交互式挑战已经露出（勾选框等着用户点）：这不是失败，是在等人。
        // 此前这里会在 60 秒整记一条 FAILED、把横幅换成红色超时并弹提示，
        // 而用户随后一点就能过（2026-10-12 实测：68 秒点击，成功）。只记一次
        // 信息日志，计时继续，超时 UI 留给页面没露出挑战的卡死场景。
        if (_challengeWebViewVisible || _checkingOriginFallback) {
          if (_checkingOriginFallback) return; // 完成探测有自己的时限
          if (!_loggedForegroundWaitingForUser) {
            _loggedForegroundWaitingForUser = true;
            CfChallengeLogger.log(
              '[VERIFY] Foreground budget ($_activeMaxCheckCount s) elapsed '
              'while interactive challenge is visible, waiting for user',
            );
          }
          return;
        }
        if (!_hasTimedOut) {
          CfChallengeLogger.log(
            '[VERIFY] Foreground timeout after $_activeMaxCheckCount seconds '
            'without a visible challenge, prompting refresh',
            level: 'warning',
          );
          if (mounted) {
            setState(() {
              _hasTimedOut = true;
              _needsManualAttention = true;
            });
            _showInfo(S.current.cf_verifyTimeout);
          }
        }
        return;
      }
    });
  }

  /// 延迟检测页面是否存在 CF 验证盾
  /// 如果页面加载完成后没有盾，立刻走 fallback 流程，避免源站 404 露出
  void _scheduleNoChallengeCheck(InAppWebViewController controller) {
    _noChallengeCheckTimer?.cancel();
    final generation = _loadGeneration;
    _noChallengeCheckTimer = Timer(_noChallengeCheckDelay, () async {
      if (_hasPopped ||
          !mounted ||
          _handedOff ||
          generation != _loadGeneration) {
        return;
      }

      try {
        final hasChallenge = await _hasVisibleChallenge(controller);
        if (_hasPopped ||
            _handedOff ||
            generation != _loadGeneration) {
          return;
        }
        if (hasChallenge) {
          _revealChallengeWebView();
          return; // 页面有盾，等待正常验证流程
        }

        // 页面无盾：统一交给 fallback 处理（先轮询 cf_clearance，无果再给重试）
        await _handleVerifyOriginFallback(
          generation,
          reason:
              'no challenge after ${_noChallengeCheckDelay.inMilliseconds}ms',
          completionLikely: _hasSeenChallenge,
        );
      } catch (e) {
        debugPrint('[CfChallenge] 检测 challenge 状态异常: $e');
      }
    });
  }

  /// 处理「页面没有 CF 挑战」的统一入口
  ///
  /// 触发场景：源站 404 / onReceivedHttpError / reveal 后页面退化 / noChallengeCheck 命中。
  /// 行为：立刻覆盖 WebView 显示「正在完成验证…」overlay，短期轮询 cf_clearance；
  /// 拿到新 cf_clearance 则 finish(true)，否则前台显示「重试/退出」操作，后台直接 finish(false)。
  Future<void> _handleVerifyOriginFallback(
    int generation, {
    String? reason,
    bool completionLikely = false,
  }) async {
    if (_hasPopped || _handedOff) return;
    _coverWebViewForOriginFallback();
    if (_checkingOriginFallback) return;

    _checkingOriginFallback = true;
    final isCompletionProbe = completionLikely || _hasSeenChallenge;
    // 取消其余探测路径：状态已经收敛到 fallback，避免重复 evaluateJavascript
    _challengeRevealProbeGeneration++;
    _noChallengeCheckTimer?.cancel();
    if (reason != null) {
      debugPrint('[CfChallenge] fallback triggered: $reason');
    }

    try {
      final startedAt = DateTime.now();
      var attempt = 0;
      while (DateTime.now().difference(startedAt) <
          (isCompletionProbe
              ? _completionProbeTimeout
              : _noChallengeProbeTimeout)) {
        if (_hasPopped || _handedOff) return;
        if (!isCompletionProbe && generation != _loadGeneration) return;
        final cookieValue = await _readCookieValue('cf_clearance');
        if (_isFreshClearance(cookieValue)) {
          debugPrint(
            '[CfChallenge] fallback/completion 期间检测到新 cf_clearance，交给轮次定稿',
          );
          CfChallengeLogger.log(
            '[VERIFY] Completion signal: '
            '${reason ?? 'fresh cf_clearance during completion probe'}',
          );
          widget.signals.clearanceSeen(cookieValue!, source: 'completion probe');
          widget.signals.completionHint(reason ?? 'completion probe');
          _handOff('完成探测读到新值');
          return;
        }
        attempt++;
        await Future.delayed(
          attempt < 12
              ? const Duration(milliseconds: 150)
              : const Duration(milliseconds: 400),
        );
      }

      // 轮次已在定稿别处读到的新值：等它收口，不放弃也不提示重试
      if (widget.signals.isSettling) return;
      debugPrint('[CfChallenge] fallback/completion 结束仍无新 cf_clearance');
      CfChallengeLogger.log(
        '[VERIFY] No fresh cf_clearance after completion probe: '
        '${reason ?? '-'}',
        level: 'warning',
      );
      if (_isBackground && widget.foregroundAfter == null) {
        _giveUp(
          CfRoundFailure.timeout,
          detail: 'no fresh cf_clearance after completion probe',
        );
        return;
      }
      // 调用方在等结果：转前台展示「重试/退出」，与直接前台验证的处置一致
      if (_isBackground) _promoteToForeground();
      if (mounted && !_hasPopped) {
        setState(() {
          _originFallbackNeedsAction = true;
          _needsManualAttention = false;
        });
      }
    } catch (e) {
      debugPrint('[CfChallenge] 处理 fallback 异常: $e');
    } finally {
      _checkingOriginFallback = false;
      if (mounted &&
          !_hasPopped &&
          (isCompletionProbe || generation == _loadGeneration)) {
        setState(() {});
      }
    }
  }

  void _coverWebViewForOriginFallback() {
    if (!mounted || _hasPopped) return;
    if (!_challengeWebViewVisible &&
        _hideOriginFallbackPage &&
        !_originFallbackNeedsAction &&
        !_needsManualAttention &&
        !_isLoading) {
      return;
    }
    setState(() {
      _challengeWebViewVisible = false;
      // 挑战刚被盖住 = 完成导航/探测进行中，前台预算重新起算：用户点完勾选框
      // 后计数早已超过 60，不清零的话旧计时器下一拍就会误报「无挑战超时」
      // 并弹超时提示（2026-10-12 实测，距成功仅 0.15 秒）。
      _checkCount = 0;
      _loggedForegroundWaitingForUser = false;
      _hideOriginFallbackPage = true;
      _originFallbackNeedsAction = false;
      _needsManualAttention = false;
      _isLoading = false;
    });
  }

  /// 轮询检测 cf_clearance 变化（兜底 JS 回调被重定向吞掉的场景）
  ///
  /// 读到新值只上报给轮次：「稳定 1.5 秒才收口」的定稿规则已统一收到
  /// CfVerificationRound，对所有完成迹象一视同仁。
  bool _polling = false;

  Future<void> _pollCfClearance() async {
    if (_hasPopped || _handedOff || _polling) return;
    _polling = true;
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      if (_hasPopped || _handedOff) return;
      if (!_isFreshClearance(cookieValue)) return;
      widget.signals.clearanceSeen(cookieValue!, source: 'polling');
    } catch (e) {
      debugPrint('[CfChallenge] 轮询检查异常: $e');
    } finally {
      _polling = false;
    }
  }

  // ---------------------------------------------------------------------------
  // UI 操作
  // ---------------------------------------------------------------------------

  bool _showExitDialog = false;
  bool _showHelpDialog = false;

  Future<void> showExitConfirmation() async {
    if (!mounted) return;
    setState(() {
      _showExitDialog = true;
    });
  }

  void _dismissExitConfirmation() {
    if (!mounted) return;
    setState(() {
      _showExitDialog = false;
    });
  }

  void _confirmExit() {
    if (!mounted) return;
    _giveUp(CfRoundFailure.cancelled, detail: 'user exit');
  }

  void _refresh() {
    if (!mounted) return;
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _hasMarkedPageReady = false;
    _checkCount = 0;
    _hasTimedOut = false;
    _loggedForegroundWaitingForUser = false;
    _needsManualAttention = true;
    _challengeWebViewVisible = false;
    _hasSeenChallenge = false;
    _hideOriginFallbackPage = false;
    _checkingOriginFallback = false;
    _originFallbackNeedsAction = false;
    _handedOff = false;
    setState(() {
      _isLoading = true;
      _progress = 0;
    });
    _controller?.reload();
  }

  void _promoteToForeground({bool dueToTimeout = false}) {
    if (!_isBackground || !mounted) return;
    setState(() {
      _isBackground = false;
      _needsManualAttention = true;
      _hasTimedOut = false;
      _checkCount = 0;
      _loggedForegroundWaitingForUser = false;
    });
    widget.onPromoteRequest?.call();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showInfo(
        dueToTimeout
            ? S.current.cf_autoVerifyTimeout
            : S.current.cf_manualVerifyBannerMessage,
      );
    });
  }

  /// 页面放弃这一轮（用户退出 / 静默超时 / 无挑战也无新值）。结果由轮次
  /// 收口；轮次正在落值时会忽略这次放弃，页面随后照常被撤下。
  void _giveUp(CfRoundFailure reason, {required String detail}) {
    if (_hasPopped) return;
    _hasPopped = true;
    _timeoutTimer?.cancel();
    widget.signals.giveUp(reason, detail: detail);
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ToastService.showInfo(message);
  }

  void _showHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = true;
    });
  }

  void _dismissHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ToastService.showError(message);
  }

  bool get _shouldCoverWebView =>
      !_challengeWebViewVisible || _hideOriginFallbackPage;

  bool _isFreshClearance(String? cookieValue) {
    if (cookieValue == null || cookieValue.isEmpty) return false;
    if (_initialCfClearance != null &&
        _initialCfClearance!.isNotEmpty &&
        cookieValue == _initialCfClearance) {
      return false;
    }
    return true;
  }

  bool _isVerifyUrl(WebUri? url) {
    if (url == null) return false;
    final actual = Uri.tryParse(url.toString());
    final expected = Uri.tryParse(widget.verifyUrl);
    if (actual == null || expected == null) return false;
    return actual.scheme == expected.scheme &&
        actual.host == expected.host &&
        actual.path == expected.path;
  }

  bool _isBareVerifyUrl(WebUri? url) {
    if (!_isVerifyUrl(url)) return false;
    final actual = Uri.tryParse(url.toString());
    if (actual == null) return false;
    return actual.query.isEmpty;
  }

  Future<NavigationActionPolicy> _shouldOverrideVerifyNavigation(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (navigationAction.isForMainFrame == true &&
        _hasSeenChallenge &&
        _isBareVerifyUrl(url)) {
      debugPrint('[CfChallenge] 验证完成后准备加载 /challenge，提前覆盖并等待状态码');
      CfChallengeLogger.log(
        '[VERIFY] Post-challenge navigation to ${url?.toString() ?? ''}',
      );
      _coverWebViewForOriginFallback();
      unawaited(
        _handleVerifyOriginFallback(
          _loadGeneration,
          reason: 'post-challenge /challenge navigation pending status',
          completionLikely: true,
        ),
      );
    }

    return NavigationActionPolicy.ALLOW;
  }

  bool _isVerifyOriginFallback(
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (response.statusCode != 404) return false;
    if (request.isForMainFrame != true) return false;
    return _isVerifyUrl(request.url);
  }

  bool _isCfMitigatedChallengeHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return false;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'cf-mitigated' &&
          entry.value.toLowerCase().contains('challenge')) {
        return true;
      }
    }
    return false;
  }

  bool _isVerifyPassedResponse(
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    if (request.isForMainFrame != true) return false;
    if (!_isBareVerifyUrl(request.url)) return false;
    if (_isCfMitigatedChallengeHeaders(response.headers)) return false;

    // /challenge 是站点专用的 CF 验证入口：
    // 未通过时 Cloudflare 接管并返回 challenge；通过后请求会落到源站，
    // 源站没有这个业务页面，所以 404 本身就是“已通过 CF”的完成信号。
    return response.statusCode == 404;
  }

  bool _isVerifyPassedNavigationResponse(NavigationResponse response) {
    final urlResponse = response.response;
    if (response.isForMainFrame != true || urlResponse == null) return false;
    if (!_isBareVerifyUrl(urlResponse.url)) return false;
    if (_isCfMitigatedChallengeHeaders(urlResponse.headers)) return false;

    return urlResponse.statusCode == 404;
  }

  Future<NavigationResponseAction> _handleVerifyNavigationResponse(
    InAppWebViewController controller,
    NavigationResponse navigationResponse,
  ) async {
    final response = navigationResponse.response;
    if (navigationResponse.isForMainFrame == true &&
        _isVerifyUrl(response?.url)) {
      CfChallengeLogger.log(
        '[VERIFY] Main frame /challenge navigation response: '
        'status=${response?.statusCode}, '
        'headers=${response?.headers}',
      );
    }

    if (_isVerifyPassedNavigationResponse(navigationResponse)) {
      await _finishVerifiedFromNetworkStatus(
        reason: 'main frame /challenge navigation response returned source 404',
        headers: response?.headers,
      );
      return NavigationResponseAction.CANCEL;
    }

    return NavigationResponseAction.ALLOW;
  }

  /// 网络层确认通过（`/challenge` 落到源站 404 且不带 cf-mitigated）：
  /// 交给轮次在限期内定稿。以前这里直接收口、Cookie 同步不等
  /// （unawaited），调用方重放时 jar 里可能还没有新值。
  Future<void> _finishVerifiedFromNetworkStatus({
    required String reason,
    Map<String, String>? headers,
  }) async {
    if (_hasPopped) return;
    if (!_handedOff) {
      CfChallengeLogger.log('[VERIFY] Completion signal (network): $reason');
      if (headers != null) {
        CfChallengeLogger.log('[VERIFY] Passed response headers: $headers');
      }
    }
    _handOff('$reason，按网络状态判定挑战已通过');
    widget.signals.completionHint(reason, conclusive: true);
  }

  Future<bool> _hasVisibleChallenge(InAppWebViewController controller) async {
    final html = await controller.evaluateJavascript(
      source:
          'document.documentElement ? document.documentElement.innerHTML : ""',
    );
    if (html == null) return false;
    return CfChallengeService.hasActiveCfChallenge(html.toString());
  }

  int _revealStateWatchGeneration = 0;

  void _revealChallengeWebView() {
    if (_hasPopped ||
        !mounted ||
        _handedOff ||
        _challengeWebViewVisible) {
      return;
    }
    _hasSeenChallenge = true;
    widget.signals.challengeShown();
    unawaited(
      _controller
              ?.evaluateJavascript(source: 'window.__fluxdoHideCfMask?.();')
              .catchError((Object e) {
                debugPrint('[CfChallenge] 隐藏 DOM mask 失败: $e');
              }) ??
          Future<void>.value(),
    );
    setState(() {
      _challengeWebViewVisible = true;
      _hideOriginFallbackPage = false;
      _originFallbackNeedsAction = false;
    });
    _startRevealedStateWatcher();
  }

  /// reveal 后持续监测：若页面内容退化为非挑战（典型为源站 404），立即重新覆盖
  ///
  /// 触发场景：CF 在 reveal 期间内联跳走（替换 location 而未触发 onLoadStart）、
  /// SPA 路由切换、或 onReceivedHttpError 在当前平台未触发但页面已渲染源站 404。
  void _startRevealedStateWatcher() {
    final watcherGeneration = ++_revealStateWatchGeneration;
    final loadGeneration = _loadGeneration;
    unawaited(() async {
      while (true) {
        await Future.delayed(_revealStateWatchInterval);
        if (_hasPopped || !mounted || _handedOff) return;
        if (watcherGeneration != _revealStateWatchGeneration) return;
        if (loadGeneration != _loadGeneration) return;
        if (!_challengeWebViewVisible) return;
        // 超时后不再做主动监测，留给已有超时 UI / 用户操作
        if (_hasTimedOut) return;

        final controller = _controller;
        if (controller == null) continue;

        try {
          final html = await controller.evaluateJavascript(
            source:
                'document.documentElement ? document.documentElement.innerHTML : ""',
          );
          if (_hasPopped || !mounted || _handedOff) return;
          if (watcherGeneration != _revealStateWatchGeneration) return;
          if (loadGeneration != _loadGeneration) return;
          if (html == null) continue;

          final htmlStr = html.toString();
          if (CfChallengeService.hasActiveCfChallenge(htmlStr)) continue;

          // 页面无挑战。要么是 CF 已完成跳走，要么是源站 404 渲染出来。
          // 统一交给 fallback 流程：先轮询 cf_clearance，没拿到再给用户重试入口。
          debugPrint('[CfChallenge] reveal 后检测到页面无挑战，主动覆盖并探测 cf_clearance');
          unawaited(
            _handleVerifyOriginFallback(
              loadGeneration,
              reason: 'reveal watcher: page lost CF challenge markers',
              completionLikely: true,
            ),
          );
          return;
        } catch (e) {
          debugPrint('[CfChallenge] reveal watcher 检测异常: $e');
        }
      }
    }());
  }

  void _startChallengeRevealProbe(
    InAppWebViewController controller,
    int generation,
  ) {
    final probeGeneration = ++_challengeRevealProbeGeneration;
    unawaited(() async {
      for (var i = 0; i < 20; i++) {
        if (_hasPopped ||
            !mounted ||
            _handedOff ||
            generation != _loadGeneration ||
            probeGeneration != _challengeRevealProbeGeneration) {
          return;
        }

        try {
          if (await _hasVisibleChallenge(controller)) {
            _revealChallengeWebView();
            return;
          }
        } catch (e) {
          debugPrint('[CfChallenge] 检测验证页可见状态异常: $e');
        }

        await Future.delayed(const Duration(milliseconds: 250));
      }
    }());
  }

  bool get _shouldShowStatusBanner =>
      _hasTimedOut ||
      _needsManualAttention ||
      (_checkCount > _activeMaxCheckCount - 10 &&
          _checkCount <= _activeMaxCheckCount);

  Widget _buildStatusBanner(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    late final Color backgroundColor;
    late final Color foregroundColor;
    late final IconData icon;
    late final String title;
    late final String message;

    if (_hasTimedOut) {
      backgroundColor = colorScheme.errorContainer;
      foregroundColor = colorScheme.onErrorContainer;
      icon = Symbols.error_rounded;
      title = context.l10n.cf_verifyTimedOutTitle;
      message = context.l10n.cf_verifyTimedOutMessage;
    } else if (_needsManualAttention) {
      backgroundColor = colorScheme.secondaryContainer;
      foregroundColor = colorScheme.onSecondaryContainer;
      icon = Symbols.touch_app_rounded;
      title = context.l10n.cf_manualVerifyBannerTitle;
      message = context.l10n.cf_manualVerifyBannerMessage;
    } else {
      backgroundColor = colorScheme.tertiaryContainer;
      foregroundColor = colorScheme.onTertiaryContainer;
      icon = Symbols.hourglass_bottom_rounded;
      title = context.l10n.cf_manualVerifyBannerTitle;
      message = context.l10n.cf_verifyLonger(
        _activeMaxCheckCount - _checkCount,
      );
    }

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: foregroundColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foregroundColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_hasTimedOut) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(context.l10n.cf_retryVerify),
                  ),
                  TextButton(
                    onPressed: _confirmExit,
                    child: Text(context.l10n.common_exit),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOriginFallbackOverlay(ThemeData theme) {
    final _FallbackState state;
    if (_originFallbackNeedsAction) {
      state = _FallbackState.noChallenge;
    } else if (_checkingOriginFallback || _handedOff) {
      state = _FallbackState.completing;
    } else {
      state = _FallbackState.opening;
    }

    return _ChallengeFallbackOverlay(
      state: state,
      onRetry: _refresh,
      onExit: _confirmExit,
    );
  }

  void _handlePageReady(InAppWebViewController controller, {String? reason}) {
    if (_hasMarkedPageReady || _hasPopped || _handedOff) {
      return;
    }
    _hasMarkedPageReady = true;
    final generation = _loadGeneration;
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();

    if (mounted && _isLoading) {
      setState(() => _isLoading = false);
    }

    if (reason != null) {
      debugPrint('[CfChallenge] 页面进入可验证状态: $reason');
    }

    _injectChallengeInterceptor(controller);
    _startTimeout();
    _startChallengeRevealProbe(controller, generation);
    _scheduleNoChallengeCheck(controller);
    // 同步立刻探一次内容：识别明确的源站 404 / 非挑战页面时直接覆盖，
    // 避免等到 _noChallengeCheckDelay 才决断，挤压可能的 404 露出窗口
    unawaited(_probeContentImmediately(controller, generation));
  }

  /// 页面就绪后立刻探一次内容
  ///
  /// 命中明确的源站 404 → 直接走 fallback 覆盖；命中 CF 挑战 → reveal；
  /// 介于两者之间（白屏/加载中）就交给 reveal probe + noChallengeCheck 兜底。
  Future<void> _probeContentImmediately(
    InAppWebViewController controller,
    int generation,
  ) async {
    if (_hasPopped || !mounted || _handedOff) return;
    if (generation != _loadGeneration) return;
    try {
      final html = await controller.evaluateJavascript(
        source:
            'document.documentElement ? document.documentElement.innerHTML : ""',
      );
      if (_hasPopped ||
          !mounted ||
          _handedOff ||
          generation != _loadGeneration) {
        return;
      }
      if (html == null) return;
      final htmlStr = html.toString();
      if (CfChallengeService.hasActiveCfChallenge(htmlStr)) {
        _revealChallengeWebView();
        return;
      }
      if (CfChallengeService.isOriginNotFound(htmlStr)) {
        await _handleVerifyOriginFallback(
          generation,
          reason: 'immediate probe: origin 404 markers',
          completionLikely: _hasSeenChallenge,
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 即时内容探测异常: $e');
    }
  }

  void _schedulePageReadyFallback(InAppWebViewController controller) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady) {
      return;
    }
    _pageReadyFallbackTimer?.cancel();
    _pageReadyFallbackTimer = Timer(_pageReadyFallbackDelay, () {
      _pageReadyFallbackTimer = null;
      if (_hasMarkedPageReady || _hasPopped || _handedOff) {
        return;
      }
      _handlePageReady(controller, reason: 'timed fallback');
    });
  }

  void _scheduleLoadStopFallback(
    InAppWebViewController controller,
    int progress,
  ) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady ||
        progress < 95) {
      return;
    }
    _loadStopFallbackTimer ??= Timer(_loadStopFallbackDelay, () {
      _loadStopFallbackTimer = null;
      if (_hasMarkedPageReady ||
          _hasPopped ||
          _handedOff ||
          _progress < 0.95) {
        return;
      }
      _handlePageReady(controller, reason: 'progress fallback');
    });
  }

  Widget _buildChallengeWebView({required bool showUi}) {
    return IgnorePointer(
      ignoring: _isBackground,
      child: WebViewSettings.wrapWithScrollFix(
        InAppWebView(
          key: _webViewKey,
          webViewEnvironment:
              WindowsWebViewEnvironmentService.instance.environment,
          initialUrlRequest: URLRequest(url: WebUri(widget.verifyUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            userAgent: AppConstants.webViewUserAgentOverride,
            mediaPlaybackRequiresUserGesture: false,
            useShouldOverrideUrlLoading: true,
            useOnNavigationResponse: true,
          ),
          initialUserScripts: _initialChallengeScripts(),
          shouldOverrideUrlLoading: _shouldOverrideVerifyNavigation,
          onNavigationResponse: _handleVerifyNavigationResponse,
          onReceivedServerTrustAuthRequest: (_, challenge) =>
              WebViewSettings.handleServerTrustAuthRequest(challenge),
          onWebViewCreated: (controller) {
            _controller = controller;
            WebViewSettings.registerJsErrorReporter(controller);
            // 注册 JS Handler，challenge-platform 响应到达时触发
            controller.addJavaScriptHandler(
              handlerName: 'onChallengeComplete',
              callback: _onChallengeComplete,
            );
            // 注册 JS Handler，CF 验证完成后即将跳走时触发，立刻覆盖避免 404 露出
            controller.addJavaScriptHandler(
              handlerName: 'onChallengeNavigation',
              callback: _onChallengeNavigation,
            );
          },
          onLoadStart: (controller, url) {
            if (_hasPopped || _handedOff) return;
            final isCompletionNavigation = _hasSeenChallenge;
            _loadGeneration++;
            _challengeRevealProbeGeneration++;
            _loadStopFallbackTimer?.cancel();
            _pageReadyFallbackTimer?.cancel();
            _hasMarkedPageReady = false;
            // 新一次导航重新起算预算：只清 _hasTimedOut 不清计数，旧计时器
            // 下一拍会立刻再记一次超时（2026-10-12 实测两条 FAILED 相隔 3 秒）。
            _hasTimedOut = false;
            _checkCount = 0;
            _loggedForegroundWaitingForUser = false;
            _needsManualAttention = false;
            _challengeWebViewVisible = false;
            _hideOriginFallbackPage = isCompletionNavigation;
            if (!isCompletionNavigation) {
              _checkingOriginFallback = false;
            }
            _originFallbackNeedsAction = false;
            _schedulePageReadyFallback(controller);
            setState(() {
              _isLoading = true;
              _progress = 0;
            });
            if (isCompletionNavigation) {
              unawaited(
                _handleVerifyOriginFallback(
                  _loadGeneration,
                  reason: 'loadStart after challenge: ${url?.toString() ?? ''}',
                  completionLikely: true,
                ),
              );
            }
          },
          onPageCommitVisible: (controller, url) {
            if (_handedOff) return;
            _handlePageReady(controller, reason: 'onPageCommitVisible');
          },
          onProgressChanged: (controller, progress) {
            // 验证结束后 WebView 仍可能回调进度；页面已经弹出就不能再 setState
            if (_hasPopped || !mounted || _handedOff) return;
            _progress = progress / 100;
            _scheduleLoadStopFallback(controller, progress);
            if (showUi) {
              setState(() {});
            }
          },
          onLoadStop: (controller, url) {
            if (_handedOff) return;
            WebViewSettings.injectScrollFix(controller);
            _handlePageReady(controller, reason: 'onLoadStop');
          },
          onReceivedError: (controller, request, error) {
            // _hasPopped:验证已收场,但 Windows 上 PlatformView 延迟 1.2s
            // 才销毁(见 _postCleanupCooldown)。这段窗口里 WebView2 掐掉
            // 在途主文档导航会上报 CONNECTION_ABORTED,不能再弹「加载失败」
            // ——用户看到的将是验证成功后凭空冒出的错误 toast。
            if (_hasPopped || _handedOff) return;

            final uri = Uri.tryParse(request.url.toString());
            final isMainFrame = request.isForMainFrame == true;
            CfChallengeLogger.log(
              '[VERIFY] WebView load error: '
              'mainFrame=$isMainFrame '
              'host=${uri?.host ?? '-'} path=${uri?.path ?? '-'} '
              'type=${error.type} description=${error.description}',
              level: isMainFrame ? 'warning' : 'info',
              fields: {
                'isMainFrame': isMainFrame,
                'host': uri?.host,
                'path': uri?.path,
                'errorType': error.type.toString(),
                'description': error.description,
              },
            );

            // WebView 会把脚本、图片、CF challenge-platform 等子资源错误也
            // 上报到这里。子资源连接被刷新流程关闭时，主验证页通常仍可正常
            // 使用；不要因此结束加载态或向用户显示整页加载失败。
            if (!isMainFrame) return;

            // WebView2 在 CF 完成验证并切换主文档时，会把被替换的旧导航
            // 上报为 CONNECTION_ABORTED。此时完成探测已经接管流程，不应把
            // 浏览器主动停止旧连接误报成直连 DoH 加载失败。
            final isExpectedCompletionAbort =
                io.Platform.isWindows &&
                error.type == WebResourceErrorType.CONNECTION_ABORTED &&
                (_hasSeenChallenge ||
                    _checkingOriginFallback ||
                    _hideOriginFallbackPage);
            if (isExpectedCompletionAbort) return;

            // 主文档加载失败：之后若以超时/退出收场，轮次按「无从判断」处理
            // （不计失败、不覆盖旧值）
            widget.signals.networkTrouble(
              'main frame load error: ${error.type}',
            );
            _pageReadyFallbackTimer?.cancel();
            if (mounted) {
              setState(() => _isLoading = false);
            }
            if (showUi) {
              _showError(context.l10n.cf_loadFailed(error.description));
            }
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            if (_hasPopped) return;
            if (request.isForMainFrame == true && _isVerifyUrl(request.url)) {
              CfChallengeLogger.log(
                '[VERIFY] Main frame /challenge HTTP response: '
                'status=${errorResponse.statusCode}, '
                'headers=${errorResponse.headers}',
              );
              if ((errorResponse.statusCode ?? 0) >= 500 &&
                  !_isCfMitigatedChallengeHeaders(errorResponse.headers)) {
                // 502/504 等网关错误：不是挑战结果，轮次据此不下定论
                widget.signals.networkTrouble(
                  'main frame http ${errorResponse.statusCode}',
                );
              }
            }
            // 已交给轮次定稿后仍要转达网络层的通过信号（它决定定稿时限）
            if (_isVerifyPassedResponse(request, errorResponse)) {
              unawaited(
                _finishVerifiedFromNetworkStatus(
                  reason: 'main frame /challenge returned source 404',
                  headers: errorResponse.headers,
                ),
              );
              return;
            }
            if (_handedOff) return;
            if (_isVerifyOriginFallback(request, errorResponse)) {
              unawaited(
                _handleVerifyOriginFallback(
                  _loadGeneration,
                  reason: 'main frame /challenge returned 404',
                  completionLikely: _hasSeenChallenge,
                ),
              );
            }
          },
        ),
        getController: () => _controller,
      ),
    );
  }

  Widget _buildPanelHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final iconColor = colorScheme.onSurfaceVariant;

    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Symbols.close_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.common_exit,
              onPressed: showExitConfirmation,
            ),
            const SizedBox(width: 4),
            Icon(Symbols.shield_rounded, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.l10n.cf_securityVerifyTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Symbols.refresh_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.common_refresh,
              onPressed: _refresh,
            ),
            IconButton(
              icon: const Icon(Symbols.help_rounded, size: 20),
              color: iconColor,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.common_help,
              onPressed: _showHelp,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerifyPanel(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surface,
      elevation: 0,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildPanelHeader(theme),
          SizedBox(
            height: 2,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _isLoading
                  ? LinearProgressIndicator(
                      key: const ValueKey('loading'),
                      value: _progress > 0 ? _progress : null,
                      minHeight: 2,
                      backgroundColor: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      color: colorScheme.primary.withValues(alpha: 0.75),
                    )
                  : SizedBox.shrink(
                      key: const ValueKey('idle'),
                      child: ColoredBox(
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final coverWebView = _shouldCoverWebView;
                final webViewWidth = math.max(1.0, constraints.maxWidth);
                final webViewHeight = math.max(1.0, constraints.maxHeight);

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // 隐藏态不再把 WebView 挪到屏幕外——那是对一个由
                    // WebView2/ANGLE D3D11 swapchain 支撑的原生 platform
                    // view 做瞬时大幅度位移,和下面的不透明覆盖层在同一帧
                    // 生效,曾经在 reveal 那一刻(_challengeWebViewVisible
                    // 从 false→true)稳定触发 flutter_windows.dll 内部的
                    // native crash(illegal instruction / 访问越界,Dart
                    // 层 try/catch、Catcher2 都拦不住)。位置固定不动,
                    // 隐藏完全交给下面的不透明覆盖层 + IgnorePointer。
                    //
                    // 注:后台静默验证(startInBackground)路径的 WebView
                    // 仍常驻屏幕外(见 build 里的负坐标 Positioned),但
                    // promote 到前台是重建整棵前台子树(showUi 切换),
                    // 不是对同一个 platform view 做同帧「大位移 + 覆盖层
                    // 翻转」,与此处崩溃的触发组合不同,暂不改动。
                    Positioned(
                      left: 0,
                      top: 0,
                      width: webViewWidth,
                      height: webViewHeight,
                      child: IgnorePointer(
                        ignoring: coverWebView,
                        child: _buildChallengeWebView(showUi: true),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !coverWebView,
                        child: AnimatedOpacity(
                          // 盖上必须瞬时:WebView 此刻可能正是验证完成后
                          // 跳转的源站 404,200ms 淡入会让它在半透明覆盖
                          // 下露出(即 b0964381 修过的 404 闪现)。只在
                          // 揭开方向保留淡出动画。
                          duration: coverWebView
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          opacity: coverWebView ? 1 : 0,
                          curve: Curves.easeOut,
                          child: _buildOriginFallbackOverlay(theme),
                        ),
                      ),
                    ),
                    if (!coverWebView && _shouldShowStatusBanner)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: _buildStatusBanner(theme),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextualBarrier(ThemeData theme, bool dialogBlur) {
    final barrierColor = dialogBlur
        ? blurBarrierColor(theme.brightness)
        : Colors.black.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.42 : 0.24,
          );
    final barrier = ModalBarrier(dismissible: false, color: barrierColor);

    if (!dialogBlur) return barrier;

    return BackdropFilter(filter: createBlurFilter(blurSigma), child: barrier);
  }

  Widget _buildContextualVerifyLayer(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return Consumer(
      builder: (context, ref, _) {
        final dialogBlur = ref.watch(
          preferencesProvider.select((prefs) => prefs.dialogBlur),
        );

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildContextualBarrier(theme, dialogBlur),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 640;
                    final horizontalMargin = isCompact ? 12.0 : 24.0;
                    final verticalMargin = isCompact ? 12.0 : 24.0;
                    final availableHeight = math.max(
                      360.0,
                      constraints.maxHeight - verticalMargin * 2,
                    );
                    final targetHeight = isCompact
                        ? availableHeight * 0.88
                        : math.min(720.0, availableHeight);
                    final minHeight = math.min(460.0, availableHeight);
                    final panelHeight = math.max(minHeight, targetHeight);

                    return Align(
                      alignment: isCompact
                          ? Alignment.bottomCenter
                          : Alignment.center,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalMargin,
                          verticalMargin,
                          horizontalMargin,
                          verticalMargin,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: SizedBox(
                            width: double.infinity,
                            height: panelHeight,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: theme.brightness == Brightness.dark
                                          ? 0.45
                                          : 0.12,
                                    ),
                                    blurRadius: 32,
                                    offset: const Offset(0, 12),
                                  ),
                                ],
                                border: Border.all(
                                  color: colorScheme.outlineVariant.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                              ),
                              child: _buildVerifyPanel(theme),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Size _resolveBackgroundWebViewSize(BuildContext context) {
    final media = MediaQuery.of(context);
    final safeWidth = math.max(
      1.0,
      media.size.width - media.padding.horizontal,
    );
    final safeHeight = math.max(
      1.0,
      media.size.height - media.padding.vertical,
    );
    final isCompact = safeWidth < 640;
    final horizontalMargin = isCompact ? 12.0 : 24.0;
    final verticalMargin = isCompact ? 12.0 : 24.0;
    final panelWidth = math.max(
      1.0,
      math.min(720.0, safeWidth - horizontalMargin * 2),
    );
    final availableHeight = math.max(360.0, safeHeight - verticalMargin * 2);
    final targetHeight = isCompact
        ? availableHeight * 0.88
        : math.min(720.0, availableHeight);
    final minHeight = math.min(460.0, availableHeight);
    final panelHeight = math.max(minHeight, targetHeight);
    const chromeHeight = 46.0; // header 44 + progress bar 2
    return Size(panelWidth, math.max(1.0, panelHeight - chromeHeight));
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground;
    final backgroundWebViewSize = showUi
        ? Size.zero
        : _resolveBackgroundWebViewSize(context);

    return Stack(
      children: [
        if (showUi)
          Positioned.fill(child: _buildContextualVerifyLayer(theme))
        else
          Positioned(
            left: -backgroundWebViewSize.width - 64,
            top: -backgroundWebViewSize.height - 64,
            width: backgroundWebViewSize.width,
            height: backgroundWebViewSize.height,
            child: _buildChallengeWebView(showUi: false),
          ),

        // 内部弹窗层
        if (_showExitDialog)
          Stack(
            children: [
              GestureDetector(
                onTap: _dismissExitConfirmation,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(context.l10n.cf_abandonVerifyTitle),
                  content: Text(context.l10n.cf_abandonVerifyMessage),
                  actions: [
                    TextButton(
                      onPressed: _dismissExitConfirmation,
                      child: Text(context.l10n.cf_continueVerify),
                    ),
                    TextButton(
                      onPressed: _confirmExit,
                      child: Text(
                        context.l10n.common_exit,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

        if (_showHelpDialog)
          Stack(
            children: [
              GestureDetector(
                onTap: _dismissHelp,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(context.l10n.cf_helpTitle),
                  content: Text(context.l10n.cf_helpContent),
                  actions: [
                    TextButton(
                      onPressed: _dismissHelp,
                      child: Text(context.l10n.common_gotIt),
                    ),
                  ],
                ),
              ),
            ],
          ),

        // 悬浮验证胶囊：默认收起，点击展开，再次点击进入前台
        if (_isBackground && _pillVisible)
          DraggableFloatingPill(
            initialTop: 100,
            onTap: _promoteToForeground,
            child: Text(S.current.cf_backgroundVerifying),
          ),
      ],
    );
  }
}

/// Fallback overlay 的三种状态
enum _FallbackState {
  /// 正在打开验证页（默认初始态、加载中）
  opening,

  /// 验证响应已到达，正在做最后的 cookie 同步
  completing,

  /// 没有需要完成的验证（极少出现，留给用户重试或退出）
  noChallenge,
}

/// 验证遮罩层
///
/// CF 官方风：左上角小 logo + 中心三点波纹 + 底部署名。
/// 负责盖住 WebView 在加载/完成/无挑战时可能闪现的源站 404。
class _ChallengeFallbackOverlay extends StatefulWidget {
  const _ChallengeFallbackOverlay({
    required this.state,
    required this.onRetry,
    required this.onExit,
  });

  final _FallbackState state;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  State<_ChallengeFallbackOverlay> createState() =>
      _ChallengeFallbackOverlayState();
}

class _ChallengeFallbackOverlayState extends State<_ChallengeFallbackOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _dotsController;
  AppLifecycleState? _lifecycleState;
  bool _tickerModeEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _syncDotsAnimation();
  }

  @override
  void didUpdateWidget(covariant _ChallengeFallbackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _syncDotsAnimation();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncDotsAnimation();
  }

  void _syncDotsAnimation() {
    final shouldAnimate =
        _lifecycleState == AppLifecycleState.resumed &&
        _tickerModeEnabled &&
        widget.state != _FallbackState.noChallenge;
    if (shouldAnimate) {
      if (!_dotsController.isAnimating) {
        _dotsController.repeat();
      }
    } else if (_dotsController.isAnimating) {
      _dotsController.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = widget.state;

    return ColoredBox(
      color: colorScheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Stack(
          children: [
            // 中心：动画 + 文案（panel 头部已有「安全验证」title，这里不重复）
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(state),
                      child: _buildCenter(theme, colorScheme, state),
                    ),
                  ),
                ),
              ),
            ),

            // 底部：Powered by Cloudflare
            Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                'Powered by Cloudflare',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenter(
    ThemeData theme,
    ColorScheme colorScheme,
    _FallbackState state,
  ) {
    final l10n = context.l10n;

    if (state == _FallbackState.noChallenge) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primary.withValues(alpha: 0.12),
            ),
            alignment: Alignment.center,
            child: Icon(
              Symbols.verified_user_rounded,
              size: 28,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            l10n.cf_noChallengeTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.cf_noChallengeMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                onPressed: widget.onRetry,
                icon: const Icon(Symbols.refresh_rounded, size: 18),
                label: Text(l10n.cf_retryVerificationAction),
              ),
              TextButton(
                onPressed: widget.onExit,
                child: Text(l10n.common_exit),
              ),
            ],
          ),
        ],
      );
    }

    // opening / completing
    final isCompleting = state == _FallbackState.completing;
    final title = isCompleting
        ? l10n.cf_verifyCompletingTitle
        : l10n.cf_verifyOpeningTitle;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 24,
          child: _BouncingDots(
            controller: _dotsController,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurface,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}

/// 三点波纹：每个点按相位轮流"亮起 + 略放大"
class _BouncingDots extends StatelessWidget {
  const _BouncingDots({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  Widget _dot(double phaseOffset) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final local = (controller.value + phaseOffset) % 1.0;
        // sin(πx) 在 [0,1] 上是 0→1→0 的平滑波形
        final wave = math.sin(local * math.pi);
        final scale = 0.75 + 0.35 * wave;
        final alpha = 0.3 + 0.7 * wave;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: alpha),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _dot(0.0),
        const SizedBox(width: 10),
        _dot(-0.16),
        const SizedBox(width: 10),
        _dot(-0.32),
      ],
    );
  }
}
