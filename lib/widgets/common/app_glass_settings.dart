import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import '../../theme/mojian_theme.dart';
import '../../theme/vscode_theme.dart';

/// 只订阅玻璃偏好，避免调整档位时重建 MainApp 的其他主题/窗口逻辑。
///
/// 墨笺使用纸色底与细线，VS Code 使用固定色实底；其他风格保留原有玻璃偏好。
class AppGlassSettings extends ConsumerWidget {
  const AppGlassSettings({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mj = Theme.of(context).extension<MojianTokens>();
    final vscode = VscodeTokens.maybeOf(context);
    final settings = ref.watch(
      preferencesProvider.select(
        (p) =>
            GlassSettings(enabled: p.glassEnabled, level: p.glassEffectLevel),
      ),
    );
    return GlassSettingsScope(
      settings: vscode != null
          ? GlassSettings(
              enabled: false,
              level: settings.level,
              solid: GlassSolidStyle(fill: vscode.panel, border: vscode.border),
            )
          : mj == null
          ? settings
          : GlassSettings(
              enabled: settings.enabled,
              level: settings.level,
              solid: GlassSolidStyle(fill: mj.paper, border: mj.ruleStrong),
            ),
      child: child,
    );
  }
}
