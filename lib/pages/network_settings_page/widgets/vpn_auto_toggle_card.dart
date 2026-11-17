import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// VPN 自动切换设置卡片
class VpnAutoToggleCard extends StatelessWidget {
  const VpnAutoToggleCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = VpnAutoToggleService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        service.enabledNotifier,
        service.vpnActiveNotifier,
        service.detectionModeNotifier,
        service.accelResumedNotifier,
        service.directReachableNotifier,
        service.probingNotifier,
        service.suppressionNotifier,
        NetworkSettingsService.instance.notifier,
      ]),
      builder: (context, _) {
        final enabled = service.enabled;
        final vpnActive = service.vpnActive;
        final dohSuppressed = enabled && service.isDohSuppressed;
        final proxySuppressed = enabled && service.isProxySuppressed;
        final hasSuppressed = dohSuppressed || proxySuppressed;
        final accelResumed = enabled && service.accelResumed;
        final probeDriven = enabled && service.probeDriven;

        return SegmentedCardGroup(
          children: [
            SwitchListTile(
              title: Text(context.l10n.vpnToggle_title),
              // 安卓按实测决定加速让不让路，桌面仍按 VPN 网卡
              subtitle: Text(
                VpnAutoToggleService.probeCapable
                    ? context.l10n.vpnToggle_subtitleProbe
                    : context.l10n.vpnToggle_subtitle,
              ),
              secondary: Icon(
                Symbols.swap_horiz_rounded,
                fill: enabled ? 1 : 0,
                color: enabled ? theme.colorScheme.primary : null,
              ),
              value: enabled,
              onChanged: (value) => service.setEnabled(value),
            ),
            if (enabled)
              ListTile(
                leading: const Icon(Symbols.rule_rounded),
                title: Text(context.l10n.vpnToggle_detectionMode),
                subtitle: service.detectionMode == VpnDetectionMode.automatic
                    ? null
                    : Text(_detectionDescription(context, service)),
                trailing: SwipeDismissiblePopupMenuButton<VpnDetectionMode>(
                  tooltip: context.l10n.vpnToggle_detectionMode,
                  offset: const Offset(0, 36),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: service.setDetectionMode,
                  itemBuilder: (context) => [
                    for (final mode in VpnDetectionMode.values)
                      PopupMenuItem(
                        value: mode,
                        child: Row(
                          children: [
                            if (mode == service.detectionMode)
                              Icon(
                                Symbols.check_rounded,
                                size: 18,
                                color: theme.colorScheme.primary,
                              )
                            else
                              const SizedBox(width: 18),
                            const SizedBox(width: 8),
                            Text(_detectionLabel(context, mode)),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_detectionLabel(context, service.detectionMode)),
                        const SizedBox(width: 4),
                        const Icon(Symbols.arrow_drop_down_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Symbols.vpn_lock_rounded,
                      fill: vpnActive ? 1 : 0,
                      size: 16,
                      color: vpnActive
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      vpnActive
                          ? context.l10n.vpnToggle_connected
                          : context.l10n.vpnToggle_disconnected,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: vpnActive
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: vpnActive ? FontWeight.w500 : null,
                      ),
                    ),
                  ],
                ),
              ),
            if (probeDriven) _probeRow(context, theme, service),
            if (enabled && hasSuppressed)
              _hintRow(
                theme,
                _buildSuppressedText(
                  dohSuppressed,
                  proxySuppressed,
                  probeDriven: probeDriven,
                ),
              ),
            if (accelResumed)
              _hintRow(theme, context.l10n.vpnToggle_accelResumed),
          ],
        );
      },
    );
  }

  /// 实测结果：能直连（已让路）/ 连不上（保持加速）/ 检测中，可点「重新检测」
  Widget _probeRow(
    BuildContext context,
    ThemeData theme,
    VpnAutoToggleService service,
  ) {
    final probing = service.probingNotifier.value;
    final direct = service.directReachableNotifier.value;
    final (icon, text, color) = probing || direct == null
        ? (
            Symbols.network_check_rounded,
            context.l10n.vpnToggle_probing,
            theme.colorScheme.onSurfaceVariant,
          )
        : direct
        ? (
            Symbols.public_rounded,
            context.l10n.vpnToggle_probeReachable,
            theme.colorScheme.tertiary,
          )
        : (
            Symbols.bolt_rounded,
            context.l10n.vpnToggle_probeUnreachable,
            theme.colorScheme.primary,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          TextButton(
            onPressed: probing ? null : service.recheck,
            child: Text(context.l10n.vpnToggle_recheck),
          ),
        ],
      ),
    );
  }

  Widget _hintRow(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.info_rounded, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _detectionLabel(BuildContext context, VpnDetectionMode mode) {
    return switch (mode) {
      VpnDetectionMode.automatic => context.l10n.vpnToggle_detectionAutomatic,
      VpnDetectionMode.forceActive =>
        context.l10n.vpnToggle_detectionForceActive,
      VpnDetectionMode.forceInactive =>
        context.l10n.vpnToggle_detectionForceInactive,
    };
  }

  String _detectionDescription(
    BuildContext context,
    VpnAutoToggleService service,
  ) {
    return switch (service.detectionMode) {
      VpnDetectionMode.automatic =>
        context.l10n.vpnToggle_detectionAutomaticDesc,
      VpnDetectionMode.forceActive =>
        context.l10n.vpnToggle_detectionForceActiveDesc,
      VpnDetectionMode.forceInactive =>
        context.l10n.vpnToggle_detectionForceInactiveDesc,
    };
  }

  String _buildSuppressedText(
    bool dohSuppressed,
    bool proxySuppressed, {
    required bool probeDriven,
  }) {
    final paused = dohSuppressed && proxySuppressed
        ? S.current.vpnToggle_pausedBoth
        : dohSuppressed
        ? (probeDriven
              ? S.current.vpnToggle_pausedAccelProbe
              : S.current.vpnToggle_pausedAccel)
        : S.current.vpnToggle_pausedProxy;
    // 加速让路后安卓仍为浏览器指纹起本机网关，说一声，免得以为 App 完全不经网关
    if (NetworkSettingsService.instance.fingerprintOnlyGateway) {
      return '$paused\n${S.current.vpnToggle_fingerprintKept}';
    }
    return paused;
  }
}
