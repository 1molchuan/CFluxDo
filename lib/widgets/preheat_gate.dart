import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/s.dart';
import '../pages/about_page.dart';
import '../pages/network_settings_page/network_settings_page.dart';
import '../providers/app_icon_provider.dart';
import '../services/network/doh/accel_doh_auth_service.dart';
import '../services/browser_trust_coordinator.dart';
import '../services/discourse/discourse_service.dart';
import '../services/log/log_writer.dart';
import '../services/migration_service.dart';
import '../services/startup/app_startup.dart';
import '../services/startup/startup_timeline.dart';
import '../services/startup_progress.dart';
import '../utils/dialog_utils.dart';
import '../widgets/common/ambient_background.dart';
import '../widgets/common/error_view.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'preheat_logo.dart';
import '../utils/platform_utils.dart';

class PreheatGate extends StatefulWidget {
  final Widget child;

  const PreheatGate({super.key, required this.child});

  @override
  State<PreheatGate> createState() => _PreheatGateState();
}

class _PreheatGateState extends State<PreheatGate> {
  late Future<bool> _loadFuture;
  Object? _error;
  AppIconStyle _iconStyle = AppIconStyle.classic;

  @override
  void initState() {
    super.initState();
    _readIconStyle();
    // 延迟到下一帧执行，确保 context 可用（_preload 内部可能弹 Dialog）
    _loadFuture = Future.microtask(() => _preload());
  }

  void _readIconStyle() {
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('pref_app_icon');
      final style = saved == 'modern'
          ? AppIconStyle.modern
          : AppIconStyle.classic;
      if (mounted && style != _iconStyle) {
        setState(() => _iconStyle = style);
      }
    });
  }

  Future<bool> _preload() async {
    try {
      // 迁移已在 main() 中执行完毕，这里展示提示
      if (MigrationService.requiresRelogin && mounted) {
        await _showReloginDialog();
      }

      // 只等预加载（复用 main() 里启动序列已在进行的那次）；预热、会话判定
      // 与登录后启动项都由启动序列自己接着做，不在这里
      await AppStartup.instance.ensurePreloaded(reason: 'preheat_gate');
      StartupTimeline.mark('preloaded');
      // 下一帧切到首页内容
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => StartupTimeline.finish('content'),
      );

      _error = null;
      return true;
    } catch (e) {
      debugPrint('[PreheatGate] Preload failed: $e');
      StartupTimeline.finish('preload_failed');
      _error = e;
      return false;
    }
  }

  /// 弹出重新登录提示，用户确认后继续
  Future<void> _showReloginDialog() async {
    MigrationService.requiresRelogin = false; // 只弹一次
    await showAppDialog(
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.migration_title),
        content: Text(S.current.migration_reloginRequired),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _retry() {
    setState(() {
      _loadFuture = _preload();
    });
  }

  void _skip() {
    setState(() {
      _error ??= TimeoutException(S.current.preheat_userSkipped);
      _loadFuture = Future.value(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _loadFuture,
      builder: (context, snapshot) {
        // 无论加载状态如何，都设置 context
        // 避免 CF 验证等待 context 而 context 等待加载完成导致的死锁
        BrowserTrustCoordinator.instance.setNavigatorContext(context);

        Widget currentWidget;
        if (snapshot.connectionState != ConnectionState.done) {
          currentWidget = _PreheatLoading(
            key: const ValueKey('loading'),
            onSkip: _skip,
            iconStyle: _iconStyle,
          );
        } else if (snapshot.data == true) {
          currentWidget = KeyedSubtree(
            key: const ValueKey('content'),
            child: widget.child,
          );
        } else {
          currentWidget = _PreheatFailed(
            key: const ValueKey('error'),
            error: _error,
            onRetry: _retry,
          );
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1.0).animate(animation),
                child: child,
              ),
            );
          },
          child: currentWidget,
        );
      },
    );
  }
}

class _PreheatLoading extends StatefulWidget {
  final VoidCallback? onSkip;
  final AppIconStyle iconStyle;

  const _PreheatLoading({super.key, this.onSkip, required this.iconStyle});

  @override
  State<_PreheatLoading> createState() => _PreheatLoadingState();
}

class _PreheatLoadingState extends State<_PreheatLoading> {
  bool _showSkip = false;
  Timer? _skipTimer;
  String? _version;

  @override
  void initState() {
    super.initState();
    if (widget.onSkip != null) {
      _skipTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _showSkip = true);
      });
    }
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  @override
  void dispose() {
    _skipTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasAcrylic = PlatformUtils.hasWindowAcrylic;

    return Scaffold(
      backgroundColor: hasAcrylic ? Colors.transparent : colorScheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PreheatLogo(style: widget.iconStyle, size: 108),
                const SizedBox(height: 24),
                Text(
                  'cfluxdo',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 56),
                const LoadingSpinner(size: 40),
                const SizedBox(height: 24),
                // 预加载当前阶段与异常原因:让用户知道卡在哪一步、为什么慢
                const _StartupStatus(),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 跳过按钮常驻树中,超时后淡入上移出现
                  IgnorePointer(
                    ignoring: !_showSkip,
                    child: AnimatedOpacity(
                      opacity: _showSkip ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      child: AnimatedSlide(
                        offset: _showSkip ? Offset.zero : const Offset(0, 0.4),
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                        child: TextButton(
                          onPressed: widget.onSkip,
                          child: Text(
                            context.l10n.common_skip,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _version != null ? 'v$_version' : '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 启动页上的预加载状态行:当前阶段 + 绕路原因 + 已等待时长。
///
/// 正常路径只显示「正在连接」一行;一旦走了内置浏览器、重试、撞盾、回退,
/// 就用醒目颜色把原因写出来,用户反馈「连接很久」时也能直接说出卡在哪一步。
class _StartupStatus extends StatefulWidget {
  const _StartupStatus();

  @override
  State<_StartupStatus> createState() => _StartupStatusState();
}

class _StartupStatusState extends State<_StartupStatus> {
  /// 等待超过这个时长才显示秒数,正常几秒内完成的启动不打扰用户
  static const _elapsedVisibleAfter = Duration(seconds: 5);

  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  String _stageText(BuildContext context, StartupProgress p) {
    final l10n = context.l10n;
    switch (p.stage) {
      case StartupStage.connecting:
        return l10n.preheat_stageConnecting;
      case StartupStage.retrying:
        return l10n.preheat_stageRetrying(
          p.attempt ?? 1,
          p.detail ?? l10n.preheat_detailConnectionError,
        );
      case StartupStage.cfChallenge:
        return l10n.preheat_stageCfChallenge(
          p.detail ?? l10n.preheat_detailConnectionError,
        );
      case StartupStage.webViewLoading:
        return l10n.preheat_stageWebViewLoading;
      case StartupStage.webViewSnapshot:
        return l10n.preheat_stageWebViewSnapshot;
      case StartupStage.webViewBootstrap:
        return l10n.preheat_stageWebViewBootstrap;
    }
  }

  String? _reasonText(BuildContext context, StartupProgress p) {
    final l10n = context.l10n;
    switch (p.reason) {
      case null:
        return null;
      case StartupDetourReason.noClearance:
        return l10n.preheat_reasonNoClearance;
      case StartupDetourReason.clearanceRejected:
        return l10n.preheat_reasonClearanceRejected;
      case StartupDetourReason.clearanceExpiring:
        return l10n.preheat_reasonClearanceExpiring;
      case StartupDetourReason.nativeFailed:
        return l10n.preheat_reasonNativeFailed(
          p.reasonDetail ?? l10n.preheat_detailConnectionError,
        );
      case StartupDetourReason.webViewNoData:
        return l10n.preheat_reasonWebViewNoData;
      case StartupDetourReason.webViewTimeout:
        return l10n.preheat_reasonWebViewTimeout;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final reporter = StartupProgressReporter.instance;

    return ValueListenableBuilder<StartupProgress?>(
      valueListenable: reporter.progress,
      builder: (context, progress, _) {
        final startedAt = reporter.startedAt;
        final elapsed = startedAt == null
            ? Duration.zero
            : DateTime.now().difference(startedAt);
        final showElapsed = elapsed >= _elapsedVisibleAfter;
        final reason = progress == null ? null : _reasonText(context, progress);
        // 没有单独原因行的异常阶段(重试、撞盾、回退、超时)把阶段行本身标红
        final stageHighlighted =
            progress != null && progress.isAbnormal && reason == null;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress != null)
                Text(
                  _stageText(context, progress),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: stageHighlighted
                        ? colorScheme.error
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              if (reason != null) ...[
                const SizedBox(height: 6),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
              if (showElapsed) ...[
                const SizedBox(height: 6),
                Text(
                  context.l10n.preheat_elapsedSeconds(elapsed.inSeconds),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PreheatFailed extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;

  const _PreheatFailed({super.key, required this.onRetry, this.error});

  void _openAbout(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AboutPage()));
  }

  void _openNetworkSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NetworkSettingsPage()));
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.common_logout),
        content: Text(context.l10n.preheat_logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_exit),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      // 记录主动退出日志（网络错误页面）
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'lifecycle',
        'event': 'logout_active',
        'message': S.current.preheat_logoutMessage,
      });
      await DiscourseService().logout(callApi: false, refreshPreload: false);
      await AccelDohAuthService.instance.revoke();
      onRetry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasAcrylic = PlatformUtils.hasWindowAcrylic;

    return Scaffold(
      backgroundColor: hasAcrylic ? Colors.transparent : colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            // 右上角：关于 + 网络设置 + 退出登录
            Positioned(
              top: 16,
              right: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AmbientIconButton(
                    icon: Symbols.info_rounded,
                    tooltip: context.l10n.common_about,
                    onPressed: () => _openAbout(context),
                  ),
                  const SizedBox(width: 8),
                  AmbientIconButton(
                    icon: Symbols.network_check_rounded,
                    tooltip: context.l10n.preheat_networkSettings,
                    onPressed: () => _openNetworkSettings(context),
                  ),
                  const SizedBox(width: 8),
                  AmbientIconButton(
                    icon: Symbols.logout_rounded,
                    tooltip: context.l10n.common_logout,
                    onPressed: () => _confirmLogout(context),
                  ),
                ],
              ),
            ),
            // 居中错误内容复用公共 ErrorView(含 CF 手动验证、网络设置、查看详情)
            ErrorView(
              error: error ?? TimeoutException(S.current.preheat_userSkipped),
              onRetry: onRetry,
              retryLabel: context.l10n.preheat_retryConnection,
            ),
          ],
        ),
      ),
    );
  }
}
