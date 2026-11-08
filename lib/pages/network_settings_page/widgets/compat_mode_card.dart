import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh/webview_mitm_policy.dart';
import '../../../services/network/webview/webview_adapter_settings_service.dart';
import 'doh_settings_card.dart' show ensureWindowsCertTrusted;

/// 打开兼容模式前确认 CA 已就绪（目前各平台都不需要，保留入口）
Future<bool> _ensureWebViewCanBeEnabled(BuildContext context) async {
  final requiresCa = WebViewMitmPolicy.requiresTrustedCa(
    isWindows: Platform.isWindows,
    dohEnabled: NetworkSettingsService.instance.current.dohEnabled,
    webViewAdapterEnabled: true,
  );
  if (!requiresCa) return true;
  return ensureWindowsCertTrusted(context);
}

/// 兼容模式的两个开关（常开 / 本次临时），状态卡和兼容模式卡跟着它刷新
Listenable compatModeListenable() {
  final webview = WebViewAdapterSettingsService.instance;
  return Listenable.merge([webview.notifier, webview.sessionFallbackNotifier]);
}

/// 兼容模式现在开着时的一行说明（连接状态卡、兼容模式卡里用），没开时返回 null
///
/// 常开优先：常开时临时兼容也被它盖住，只说常开。叉号关掉的就是这一行说的那个
Widget? compatModeHintRow(BuildContext context) {
  final theme = Theme.of(context);
  final l10n = context.l10n;
  final webview = WebViewAdapterSettingsService.instance;
  final persistent = webview.enabled;
  if (!persistent && !webview.sessionFallbackEnabled) return null;
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
    child: Row(
      children: [
        Icon(
          persistent ? Symbols.language_rounded : Symbols.call_split_rounded,
          size: 18,
          color: theme.colorScheme.tertiary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            persistent
                ? l10n.compatMode_onHint
                : l10n.engineStatus_sessionCompat,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        IconButton(
          tooltip: persistent
              ? l10n.compatMode_turnOff
              : l10n.cf_sessionCompatDisable,
          icon: const Icon(Symbols.close_rounded, size: 18),
          visualDensity: VisualDensity.compact,
          onPressed: persistent
              ? () => _setCompatEnabled(false)
              : webview.disableSessionFallback,
        ),
      ],
    ),
  );
}

/// 用户自己拨开关：常开与临时兼容一起定下来，免得关了开关请求还在走内置浏览器
Future<void> _setCompatEnabled(bool value) async {
  final webview = WebViewAdapterSettingsService.instance;
  webview.disableSessionFallback();
  await webview.setEnabled(value);
}

/// 兼容模式卡片（高级设置）：主站接口请求交给内置浏览器发送
///
/// 平时用不着：过了人机验证请求仍被拒时，App 会问要不要本次临时切换
/// （[WebViewAdapterSettingsService.enableSessionFallback]）。这里是常开的开关，留给排查用
class CompatModeCard extends StatelessWidget {
  const CompatModeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final webview = WebViewAdapterSettingsService.instance;

    return AnimatedBuilder(
      animation: compatModeListenable(),
      builder: (context, _) {
        final enabled = webview.enabled;
        // 常开时说明就是开关本身，不再重复一行
        final sessionHint = enabled ? null : compatModeHintRow(context);
        return SegmentedCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(
                l10n.compatMode_desc,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SwitchListTile(
              secondary: Icon(
                Symbols.language_rounded,
                fill: enabled ? 1 : 0,
                color: enabled ? theme.colorScheme.primary : null,
              ),
              title: Text(l10n.webviewAdapter_title),
              subtitle: Text(l10n.webviewAdapter_enabledDesc),
              value: enabled,
              onChanged: (value) async {
                if (value && !await _ensureWebViewCanBeEnabled(context)) {
                  return;
                }
                await _setCompatEnabled(value);
              },
            ),
            ?sessionHint,
          ],
        );
      },
    );
  }
}
