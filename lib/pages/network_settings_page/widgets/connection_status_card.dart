import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh_proxy/doh_proxy_ffi.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/toast_service.dart';
import '../../../services/windows_webview_environment_service.dart';
import '../../../utils/time_utils.dart';
import 'compat_mode_card.dart';

/// 连接状态的几种情形，按优先级从上往下判断，见 [resolveNetStatusKind]
enum NetStatusKind {
  /// 网关正在启动 / 重启（改设置后也会短暂出现）
  starting,

  /// 网关没起来
  startFailed,

  /// VPN 连着，「VPN 自动让路」把加速暂停了
  vpnPaused,

  /// 用户关了加速（国内一般连不上）
  accelOff,

  /// 经上游代理连接，不做节点优选
  viaProxy,

  /// 加速开着但不做优选（网关模式关了 / 平台不支持）
  accelOnNoSelect,

  /// 优选：正在检查上次的节点
  checking,

  /// 优选：正在竞速
  racing,

  /// 优选：已连接
  ready,

  /// 优选：失败，走备用线路
  selectFailed,

  /// 优选：还没开始
  idle,
}

/// 由各服务的当前状态推出卡片该显示哪种情形（纯函数，便于测试）
NetStatusKind resolveNetStatusKind({
  required bool dohEnabled,
  required bool proxyActive,
  required bool applying,
  required bool running,
  required bool startFailed,
  required bool vpnPausedAccel,
  required bool selectorEligible,
  required String? phase,
}) {
  final gatewayWanted = dohEnabled || proxyActive;
  if (!gatewayWanted) {
    return vpnPausedAccel ? NetStatusKind.vpnPaused : NetStatusKind.accelOff;
  }
  if (applying || (!running && !startFailed)) return NetStatusKind.starting;
  if (!running) return NetStatusKind.startFailed;
  if (proxyActive) return NetStatusKind.viaProxy;
  if (!selectorEligible) return NetStatusKind.accelOnNoSelect;
  return switch (phase) {
    // 还没拉到第一份快照时按「正在检查」显示，免得先闪一下「还没开始」
    null || 'verifying' => NetStatusKind.checking,
    'racing' => NetStatusKind.racing,
    'ready' => NetStatusKind.ready,
    'failed' => NetStatusKind.selectFailed,
    _ => NetStatusKind.idle,
  };
}

/// 网络设置最上方的连接状态卡：现在怎么连上 linux.do、有没有问题、能做什么
///
/// 把原来分散在「连接方式」「DNS over HTTPS」卡片里的状态（优选进度、
/// 赢家节点、网关启动失败、VPN 接管、Windows 需重启）收拢成一句话 + 一个操作；
/// 兼容模式开着（主站接口改由内置浏览器发送）时多一行说明，可直接关掉。
/// 优选状态由 Rust 侧维护，这里每 3 秒拉一次快照。
class ConnectionStatusCard extends StatefulWidget {
  const ConnectionStatusCard({super.key});

  @override
  State<ConnectionStatusCard> createState() => _ConnectionStatusCardState();
}

class _ConnectionStatusCardState extends State<ConnectionStatusCard> {
  static const _refreshInterval = Duration(seconds: 3);

  Timer? _refreshTimer;

  /// 正在请求重新优选（防止连点）
  bool _reracing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      await NetworkSettingsService.instance.refreshSelectStatus();
    } catch (e) {
      // 代理未起或 FFI 暂不可用时拉不到快照，下个周期再试即可
      debugPrint('[NetStatus] 刷新优选状态失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = NetworkSettingsService.instance;
    final vpn = VpnAutoToggleService.instance;
    final windowsEnv = WindowsWebViewEnvironmentService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        service.notifier,
        service.isApplying,
        service.selectStatusNotifier,
        ProxySettingsService.instance.notifier,
        vpn.enabledNotifier,
        vpn.vpnActiveNotifier,
        vpn.suppressionNotifier,
        windowsEnv.proxyRestartRequiredNotifier,
        compatModeListenable(),
      ]),
      builder: (context, _) {
        final settings = service.current;
        final status = service.selectStatusNotifier.value;
        final proxy = ProxySettingsService.instance.current;
        final vpnLocked = vpn.enabled && vpn.vpnActive;
        final kind = resolveNetStatusKind(
          dohEnabled: settings.dohEnabled,
          proxyActive: proxy.isValid,
          applying: service.isApplying.value || service.pendingStart,
          running: service.proxyService.isRunning,
          startFailed: service.lastStartFailed,
          vpnPausedAccel: vpnLocked && vpn.isDohSuppressed,
          selectorEligible: service.selectorEligible,
          phase: status?.phase,
        );
        final restartHint =
            Platform.isWindows && windowsEnv.proxyRestartRequired;
        return _buildCard(
          context,
          kind: kind,
          status: status,
          proxy: proxy,
          vpnLocked: vpnLocked,
          restartHint: restartHint,
        );
      },
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required NetStatusKind kind,
    required DohSelectStatus? status,
    required ProxySettings proxy,
    required bool vpnLocked,
    required bool restartHint,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    final service = NetworkSettingsService.instance;

    late final _Tone tone;
    late final String title;
    final details = <String>[];
    String? errorText;
    Widget? action;

    switch (kind) {
      case NetStatusKind.starting:
        tone = _Tone.busy;
        title = service.wasRunningBeforeApply
            ? l10n.netStatus_restarting
            : l10n.netStatus_starting;
      case NetStatusKind.startFailed:
        tone = _Tone.error;
        title = l10n.netStatus_startFailed;
        details.add(l10n.netStatus_startFailedHint);
        errorText = service.proxyService.lastError;
        action = _actionButton(
          icon: Symbols.refresh_rounded,
          label: l10n.common_retry,
          onPressed: service.isApplying.value ? null : service.restartProxy,
        );
      case NetStatusKind.vpnPaused:
        tone = _Tone.info;
        title = l10n.netStatus_vpnPaused;
        details.add(l10n.netStatus_vpnPausedHint);
      case NetStatusKind.accelOff:
        tone = _Tone.warning;
        title = l10n.netStatus_accelOff;
        details.add(l10n.netStatus_accelOffHint);
        // VPN 接管期间开关只记「断开后开不开」，这里不给直接开启的按钮
        if (!vpnLocked) {
          action = _actionButton(
            icon: Symbols.power_settings_new_rounded,
            label: l10n.netStatus_turnOn,
            filled: true,
            onPressed: () => service.setDohEnabled(true),
          );
        }
      case NetStatusKind.viaProxy:
        tone = _Tone.ok;
        title = l10n.netStatus_viaProxy;
        details.add(
          '${proxy.protocol.displayName} · ${proxy.host}:${proxy.port}',
        );
        details.add(l10n.httpProxy_dohProxyHint);
      case NetStatusKind.accelOnNoSelect:
        tone = _Tone.ok;
        title = l10n.netStatus_accelOn;
        final platformSupported =
            Platform.isAndroid || Platform.isLinux || Platform.isWindows;
        details.add(
          platformSupported
              ? l10n.netStatus_noSelectGateway
              : l10n.netStatus_noSelectPlatform,
        );
      case NetStatusKind.checking:
        tone = _Tone.busy;
        title = l10n.cfSelect_statusVerifying;
        final ip = status?.winnerIp;
        if (ip != null) details.add(l10n.netStatus_node(ip));
      case NetStatusKind.racing:
        tone = _Tone.busy;
        title = l10n.cfSelect_statusRacing;
      case NetStatusKind.ready:
        tone = _Tone.ok;
        title = l10n.netStatus_ready;
        final ip = status?.winnerIp;
        if (ip != null) {
          final family = ip.contains(':') ? 'IPv6' : 'IPv4';
          final latency = status?.latencyMs;
          details.add(
            [
              l10n.netStatus_node(ip),
              family,
              if (latency != null && latency > 0) '$latency ms',
            ].join(' · '),
          );
        }
        final raced = _lastRaceText(status);
        if (raced != null) details.add(raced);
        action = _reraceButton();
      case NetStatusKind.selectFailed:
        tone = _Tone.error;
        title = l10n.cfSelect_statusFailed;
        final lastError = status?.lastError;
        if (lastError != null && lastError.isNotEmpty) errorText = lastError;
        action = _reraceButton();
      case NetStatusKind.idle:
        tone = _Tone.neutral;
        title = l10n.cfSelect_statusIdle;
        action = _reraceButton();
    }

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final line in details)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        if (errorText != null && errorText.isNotEmpty)
          _ErrorLine(text: errorText),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: action),
      ],
    );

    final compatHint = compatModeHintRow(context);

    // 用分段卡片组：经典风格是圆角卡片，墨笺是平铺细线，与页面其余分组一致
    return SegmentedCardGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusBadge(tone: tone),
              const SizedBox(width: 14),
              Expanded(child: textColumn),
            ],
          ),
        ),
        if (restartHint)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Symbols.restart_alt_rounded, size: 18, color: cs.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.dohSettings_webViewRestartRequired,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ?compatHint,
      ],
    );
  }

  String? _lastRaceText(DohSelectStatus? status) {
    final at = status?.lastRaceAt ?? 0;
    if (at <= 0) return null;
    return context.l10n.cfSelect_lastRace(
      TimeUtils.formatRelativeTime(
        DateTime.fromMillisecondsSinceEpoch(at * 1000),
      ),
    );
  }

  Widget _reraceButton() => _actionButton(
    icon: Symbols.refresh_rounded,
    label: context.l10n.cfSelect_rerace,
    onPressed: _reracing ? null : _rerace,
  );

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool filled = false,
  }) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14),
      ),
    );
    final iconWidget = Icon(icon, size: 18);
    final text = Text(label);
    return Align(
      alignment: Alignment.centerLeft,
      child: filled
          ? FilledButton.tonalIcon(
              style: style,
              onPressed: onPressed,
              icon: iconWidget,
              label: text,
            )
          : OutlinedButton.icon(
              style: style,
              onPressed: onPressed,
              icon: iconWidget,
              label: text,
            ),
    );
  }

  Future<void> _rerace() async {
    setState(() => _reracing = true);
    try {
      final started = await NetworkSettingsService.instance.reraceSelection();
      if (started) {
        ToastService.showInfo(S.current.cfSelect_reraceStarted);
        unawaited(_refreshStatus());
      } else {
        ToastService.showInfo(S.current.cfSelect_reraceCooldown);
      }
    } catch (e) {
      ToastService.showError(S.current.common_operationFailed('$e'));
    } finally {
      if (mounted) setState(() => _reracing = false);
    }
  }
}

enum _Tone { ok, busy, info, warning, error, neutral }

/// 左侧的状态徽标：圆形色块 + 图标（进行中是转圈）
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.tone});

  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (Color color, IconData? icon) = switch (tone) {
      _Tone.ok => (Colors.green, Symbols.check_rounded),
      _Tone.busy => (cs.primary, null),
      _Tone.info => (cs.tertiary, Symbols.vpn_lock_rounded),
      _Tone.warning => (Colors.orange, Symbols.warning_rounded),
      _Tone.error => (cs.error, Symbols.priority_high_rounded),
      _Tone.neutral => (cs.onSurfaceVariant, Symbols.hourglass_top_rounded),
    };
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: icon == null
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          : Icon(icon, size: 20, color: color, fill: 1),
    );
  }
}

/// 失败原因：小字 + 复制按钮
class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              Clipboard.setData(ClipboardData(text: text));
              ToastService.showInfo(S.current.dohSettings_errorCopied);
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Symbols.content_copy_rounded, size: 14, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
