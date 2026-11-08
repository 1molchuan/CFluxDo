import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../theme/mojian_theme.dart';
import '../../widgets/content/discourse_image.dart';

/// 微应用图标：圆角方块（图标可能是 SVG），没有或加载失败时画个占位
class MiniAppIcon extends StatelessWidget {
  const MiniAppIcon({super.key, required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final radius = BorderRadius.circular(size * (mj != null ? 0.16 : 0.24));
    final fallback = Center(
      child: Icon(
        Symbols.widgets_rounded,
        size: size * 0.5,
        color: mj?.ink3 ?? theme.colorScheme.onSurfaceVariant,
      ),
    );
    final url = this.url;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: mj?.paper2 ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: radius,
        border: mj != null ? Border.all(color: mj.rule) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? fallback
          : DiscourseImage(
              url: url,
              width: size,
              height: size,
              placeholderBuilder: (_) => const SizedBox.shrink(),
              errorBuilder: (_) => fallback,
            ),
    );
  }
}
