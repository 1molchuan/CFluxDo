import 'package:flutter/material.dart';

/// 宿主经 [ThemeData.extensions] 注入的分段卡片组样式。
///
/// 不注入时保持 M3E 分段卡片原样;[flat] 为 true 时(如 cfluxdo 的「墨笺」)
/// 改成平铺细线列表:无圆角、无块间缝,首项上方与每项下方各一条发丝线,
/// 底色透明(调用方显式传了 color 的条目仍按 color 填充)。
@immutable
class SegmentedCardStyle extends ThemeExtension<SegmentedCardStyle> {
  const SegmentedCardStyle({
    this.flat = false,
    this.dividerColor,
    this.background,
  });

  final bool flat;

  /// 平铺模式的分隔线颜色(默认 dividerColor)
  final Color? dividerColor;

  /// 平铺模式的条目底色(默认透明)
  final Color? background;

  static SegmentedCardStyle? of(BuildContext context) =>
      Theme.of(context).extension<SegmentedCardStyle>();

  @override
  SegmentedCardStyle copyWith({
    bool? flat,
    Color? dividerColor,
    Color? background,
  }) {
    return SegmentedCardStyle(
      flat: flat ?? this.flat,
      dividerColor: dividerColor ?? this.dividerColor,
      background: background ?? this.background,
    );
  }

  @override
  SegmentedCardStyle lerp(covariant SegmentedCardStyle? other, double t) {
    if (other == null) return this;
    return SegmentedCardStyle(
      flat: t < 0.5 ? flat : other.flat,
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t),
      background: Color.lerp(background, other.background, t),
    );
  }
}

/// M3 Expressive 风格分段卡片组
///
/// 参照最新 Material 3 Expressive 列表规范（Chrome / Android 系统设置）：
/// 每个条目独立成块，组首/组尾用大圆角、相邻处用小圆角，块间以细缝分隔，
/// 取代旧式「整卡 + Divider」布局。
class SegmentedCardGroup extends StatelessWidget {
  final List<Widget> children;

  /// 组首/组尾的大圆角
  final double outerRadius;

  /// 相邻条目之间的小圆角
  final double innerRadius;

  /// 条目间距
  final double gap;

  /// 块背景色，默认跟随 cardTheme（surfaceContainerLow）
  final Color? color;

  const SegmentedCardGroup({
    super.key,
    required this.children,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.gap = 3,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final flat = SegmentedCardStyle.of(context)?.flat ?? false;
    return Column(
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0 && !flat) SizedBox(height: gap),
          SegmentedCardItem(
            index: i,
            count: children.length,
            outerRadius: outerRadius,
            innerRadius: innerRadius,
            color: color,
            child: children[i],
          ),
        ],
      ],
    );
  }
}

/// 分段卡片组中的单个条目块
///
/// 根据 [index] / [count] 决定上下圆角。供 [SegmentedCardGroup] 内部使用；
/// 懒加载列表（ListView.builder）中也可直接按索引使用。
class SegmentedCardItem extends StatelessWidget {
  final int index;
  final int count;
  final double outerRadius;
  final double innerRadius;
  final Color? color;
  final Widget child;

  const SegmentedCardItem({
    super.key,
    required this.index,
    required this.count,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = SegmentedCardStyle.of(context);
    if (style != null && style.flat) {
      final line = BorderSide(color: style.dividerColor ?? theme.dividerColor);
      return Material(
        color: color ?? style.background ?? Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: Border(top: index == 0 ? line : BorderSide.none, bottom: line),
        child: child,
      );
    }
    final background =
        color ?? theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;

    return Material(
      color: background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(index == 0 ? outerRadius : innerRadius),
          bottom: Radius.circular(index == count - 1 ? outerRadius : innerRadius),
        ),
      ),
      child: child,
    );
  }
}
