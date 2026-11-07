import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../services/eruda_settings_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// Eruda 设备内 DevTools 开关卡片（调试用）。
///
/// 开启后, 主站 WebView 页面右下角出现 ⚙ 悬浮按钮, 可打开
/// Console / Network / Elements / Sources 面板。默认关闭。
/// 见 [ErudaSettingsService]。
class ErudaCard extends StatelessWidget {
  const ErudaCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final service = ErudaSettingsService.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: service.notifier,
      builder: (context, enabled, _) {
        return SegmentedCardGroup(
          children: [
            SwitchListTile(
              title: Text(l10n.eruda_title),
              subtitle: Text(
                enabled
                    ? '${l10n.eruda_onDesc}\n${l10n.eruda_reloadHint}'
                    : l10n.eruda_offDesc,
              ),
              secondary: Icon(
                Symbols.terminal_rounded,
                fill: enabled ? 1 : 0,
                color: enabled ? theme.colorScheme.primary : null,
              ),
              value: enabled,
              onChanged: (value) => service.setEnabled(value),
            ),
          ],
        );
      },
    );
  }
}
