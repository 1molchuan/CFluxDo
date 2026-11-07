import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh/webview_mitm_policy.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/rhttp/rhttp_settings_service.dart';
import '../../../services/network/webview/webview_adapter_settings_service.dart';
import '../network_advanced_settings_page.dart';
import 'doh_settings_card.dart' show ensureWindowsCertTrusted;
import 'ip_family_card.dart' show CardTitleRow;

/// 引擎预设。不在三种预设里的组合算「自定义」，在高级设置的「引擎组合」里调
enum EnginePreset { standard, performance, compat }

/// 当前开关组合对应哪个预设；对不上任何预设时返回 null（自定义）
EnginePreset? enginePresetOf({
  required bool rhttpEnabled,
  required RhttpMode rhttpMode,
  required bool webViewEnabled,
}) {
  if (!rhttpEnabled && !webViewEnabled) return EnginePreset.standard;
  if (rhttpEnabled && rhttpMode == RhttpMode.always && !webViewEnabled) {
    return EnginePreset.performance;
  }
  if (!rhttpEnabled && webViewEnabled) return EnginePreset.compat;
  return null;
}

/// 打开 WebView 引擎前确认 CA 已就绪（目前各平台都不需要，保留入口）
Future<bool> _ensureWebViewCanBeEnabled(BuildContext context) async {
  final requiresCa = WebViewMitmPolicy.requiresTrustedCa(
    isWindows: Platform.isWindows,
    dohEnabled: NetworkSettingsService.instance.current.dohEnabled,
    webViewAdapterEnabled: true,
  );
  if (!requiresCa) return true;
  return ensureWindowsCertTrusted(context);
}

Listenable _engineListenable() {
  final webview = WebViewAdapterSettingsService.instance;
  return Listenable.merge([
    RhttpSettingsService.instance.notifier,
    NetworkSettingsService.instance.notifier,
    ProxySettingsService.instance.notifier,
    webview.notifier,
    webview.effectiveNotifier,
    webview.sessionFallbackNotifier,
  ]);
}

/// 网络引擎卡片（主页面）：标准 / 高性能 / 兼容 三选一
///
/// 只放预设和需要用户知道的异常（临时兼容模式、Rust 引擎暂时回退或初始化失败）；
/// 逐项开关在高级设置的 [EngineMixCard]。
class EngineCard extends StatelessWidget {
  const EngineCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final rhttp = RhttpSettingsService.instance;
    final webview = WebViewAdapterSettingsService.instance;

    return AnimatedBuilder(
      animation: _engineListenable(),
      builder: (context, _) {
        final rhttpSettings = rhttp.current;
        final preset = enginePresetOf(
          rhttpEnabled: rhttpSettings.enabled,
          rhttpMode: rhttpSettings.mode,
          webViewEnabled: webview.enabled,
        );
        final hints = <Widget>[
          if (webview.sessionFallbackEnabled)
            _HintRow(
              icon: Symbols.call_split_rounded,
              color: theme.colorScheme.tertiary,
              text: l10n.engineStatus_sessionCompat,
              trailing: IconButton(
                tooltip: l10n.cf_sessionCompatDisable,
                icon: const Icon(Symbols.close_rounded, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: webview.disableSessionFallback,
              ),
            ),
          if (rhttpSettings.enabled && rhttpSettings.forceDisabled)
            _HintRow(
              icon: Symbols.error_rounded,
              color: theme.colorScheme.error,
              text: l10n.rhttpEngine_initFailedHint,
            )
          else if (rhttpSettings.enabled && rhttpSettings.isDegraded)
            _HintRow(
              icon: Symbols.warning_rounded,
              color: Colors.orange,
              text: l10n.engineStatus_degraded(
                _minutesLeft(rhttpSettings.degradedUntil),
              ),
              trailing: TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: rhttp.clearDegrade,
                child: Text(l10n.engineStatus_retryNow),
              ),
            ),
        ];

        // 分段卡片组：经典风格是圆角卡片，墨笺是平铺细线，与页面其余分组一致
        return SegmentedCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CardTitleRow(
                    icon: Symbols.speed_rounded,
                    title: l10n.networkSettings_engine,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: M3eButtonGroup<EnginePreset?>(
                      itemPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      items: [
                        M3eButtonGroupItem(
                          value: EnginePreset.standard,
                          label: Text(l10n.enginePreset_standard),
                        ),
                        M3eButtonGroupItem(
                          value: EnginePreset.performance,
                          label: Text(l10n.enginePreset_performance),
                        ),
                        M3eButtonGroupItem(
                          value: EnginePreset.compat,
                          label: Text(l10n.enginePreset_compat),
                        ),
                      ],
                      selected: preset,
                      onSelected: (value) {
                        if (value != null) _applyPreset(context, value);
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (preset) {
                      EnginePreset.standard => l10n.enginePreset_standardDesc,
                      EnginePreset.performance =>
                        l10n.enginePreset_performanceDesc,
                      EnginePreset.compat => l10n.enginePreset_compatDesc,
                      null => l10n.enginePreset_customDesc,
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 自定义组合：给一个直达高级设置「引擎组合」的入口
            if (preset == null)
              ListTile(
                dense: true,
                leading: const Icon(Symbols.tune_rounded, size: 20),
                title: Text(l10n.engineMix_title),
                trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NetworkAdvancedSettingsPage(
                      highlightId: 'engineMix',
                    ),
                  ),
                ),
              ),
            if (hints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                child: Column(children: hints),
              ),
          ],
        );
      },
    );
  }

  static int _minutesLeft(DateTime? until) {
    if (until == null) return 1;
    final left = until.difference(DateTime.now()).inSeconds;
    return left <= 60 ? 1 : (left / 60).ceil();
  }

  Future<void> _applyPreset(BuildContext context, EnginePreset preset) async {
    final rhttp = RhttpSettingsService.instance;
    final webview = WebViewAdapterSettingsService.instance;
    switch (preset) {
      case EnginePreset.standard:
        webview.disableSessionFallback();
        await rhttp.setEnabled(false);
        await webview.setEnabled(false);
      case EnginePreset.performance:
        webview.disableSessionFallback();
        await rhttp.setMode(RhttpMode.always);
        await rhttp.setEnabled(true);
        await webview.setEnabled(false);
      case EnginePreset.compat:
        if (!await _ensureWebViewCanBeEnabled(context)) return;
        webview.disableSessionFallback();
        await rhttp.setEnabled(false);
        await webview.setEnabled(true);
    }
  }
}

/// 引擎组合卡片（高级设置）：Rust 引擎与内置浏览器发送逐项开关
class EngineMixCard extends StatelessWidget {
  const EngineMixCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final rhttp = RhttpSettingsService.instance;
    final webview = WebViewAdapterSettingsService.instance;

    return AnimatedBuilder(
      animation: _engineListenable(),
      builder: (context, _) {
        final rhttpSettings = rhttp.current;
        final rhttpEnabled = rhttpSettings.enabled;
        final webviewEnabled = webview.enabled;

        return SegmentedCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(
                l10n.engineMix_desc,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  secondary: Icon(
                    Symbols.rocket_launch_rounded,
                    fill: rhttpEnabled ? 1 : 0,
                    color: rhttpEnabled ? theme.colorScheme.primary : null,
                  ),
                  title: Text(l10n.rhttpEngine_title),
                  subtitle: Text(l10n.rhttpEngine_enabledDesc),
                  value: rhttpEnabled,
                  onChanged: (value) => rhttp.setEnabled(value),
                ),
                if (rhttpEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: M3eButtonGroup<RhttpMode>(
                            itemPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                            items: [
                              M3eButtonGroupItem(
                                value: RhttpMode.always,
                                label: Text(l10n.rhttpEngine_alwaysUse),
                              ),
                              M3eButtonGroupItem(
                                value: RhttpMode.proxyOnly,
                                label: Text(l10n.rhttpEngine_proxyDohOnly),
                              ),
                            ],
                            selected: rhttpSettings.mode,
                            onSelected: (mode) => rhttp.setMode(mode),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _HintRow(
                          icon: Symbols.info_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                          text: l10n.rhttpEngine_echFallbackHint,
                          dense: true,
                        ),
                        if (rhttpSettings.forceDisabled)
                          _HintRow(
                            icon: Symbols.error_rounded,
                            color: theme.colorScheme.error,
                            text: l10n.rhttpEngine_initFailedHint,
                            dense: true,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              secondary: Icon(
                Symbols.language_rounded,
                fill: webviewEnabled ? 1 : 0,
                color: webviewEnabled ? theme.colorScheme.primary : null,
              ),
              title: Text(l10n.webviewAdapter_title),
              subtitle: Text(l10n.webviewAdapter_enabledDesc),
              value: webviewEnabled,
              onChanged: (value) async {
                if (value && !await _ensureWebViewCanBeEnabled(context)) {
                  return;
                }
                await webview.setEnabled(value);
              },
            ),
          ],
        );
      },
    );
  }
}

/// 卡片里的一行提示：小图标 + 文字 + 可选的操作
class _HintRow extends StatelessWidget {
  const _HintRow({
    required this.icon,
    required this.color,
    required this.text,
    this.trailing,
    this.dense = false,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 3 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: dense ? 14 : 18, color: color),
          SizedBox(width: dense ? 6 : 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: dense ? 11 : null,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
