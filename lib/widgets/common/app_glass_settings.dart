import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import '../../theme/mojian_theme.dart';

/// 只订阅玻璃偏好，避免调整档位时重建 MainApp 的其他主题/窗口逻辑。
///
/// 墨笺不用玻璃：所有玻璃组件画成纸色底 + 细线（无模糊、无落影），
/// 与墨笺的纸面一致；玻璃开关与档位只对经典风格生效。
class AppGlassSettings extends ConsumerWidget {
  const AppGlassSettings({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mj = Theme.of(context).extension<MojianTokens>();
    final settings = ref.watch(
      preferencesProvider.select(
        (p) =>
            GlassSettings(enabled: p.glassEnabled, level: p.glassEffectLevel),
      ),
    );
    return GlassSettingsScope(
      settings: mj == null
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
