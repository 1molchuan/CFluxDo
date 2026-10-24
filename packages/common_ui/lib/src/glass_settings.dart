import 'package:flutter/widgets.dart';

/// 效果能力档位，不代表模糊浓淡或设备性能跑分。
enum GlassEffectLevel {
  auto,
  basic,
  full;

  static GlassEffectLevel fromStorage(String? value) =>
      GlassEffectLevel.values.firstWhere(
        (level) => level.name == value,
        orElse: () => GlassEffectLevel.auto,
      );
}

/// 不要玻璃、改用实色时的外观（界面风格自带的纸面：底色、细线、无落影）。
@immutable
class GlassSolidStyle {
  const GlassSolidStyle({required this.fill, this.border});

  final Color fill;

  /// 细描边色；null 不描边
  final Color? border;

  @override
  bool operator ==(Object other) =>
      other is GlassSolidStyle && other.fill == fill && other.border == border;

  @override
  int get hashCode => Object.hash(fill, border);
}

/// 应用级玻璃策略。common_ui 只依赖此配置，不依赖应用偏好存储。
@immutable
class GlassSettings {
  const GlassSettings({
    this.enabled = true,
    this.level = GlassEffectLevel.auto,
    this.solid,
  });

  final bool enabled;
  final GlassEffectLevel level;

  /// 非 null 时所有玻璃组件一律画成这个实色外观（无模糊、无光学边、无落影），
  /// 优先于 [enabled] / [level]
  final GlassSolidStyle? solid;

  bool allowsBlur({required bool highContrast, bool locallyEnabled = true}) =>
      solid == null && enabled && locallyEnabled && !highContrast;

  bool allowsOptics({
    required bool shaderSupported,
    required bool highContrast,
    bool locallyEnabled = true,
  }) =>
      allowsBlur(highContrast: highContrast, locallyEnabled: locallyEnabled) &&
      level != GlassEffectLevel.basic &&
      shaderSupported;

  @override
  bool operator ==(Object other) =>
      other is GlassSettings &&
      other.enabled == enabled &&
      other.level == level &&
      other.solid == solid;

  @override
  int get hashCode => Object.hash(enabled, level, solid);
}

/// 放在 Navigator 之上，页面、弹出的编辑器与新玻璃组件自动遵循同一策略。
/// 没有作用域的独立预览或测试默认自动开启。
class GlassSettingsScope extends InheritedWidget {
  const GlassSettingsScope({
    super.key,
    required this.settings,
    required super.child,
  });

  final GlassSettings settings;

  static GlassSettings of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassSettingsScope>()
          ?.settings ??
      const GlassSettings();

  @override
  bool updateShouldNotify(GlassSettingsScope oldWidget) =>
      settings != oldWidget.settings;
}
