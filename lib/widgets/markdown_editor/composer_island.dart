import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../theme/vscode_theme.dart';
import 'composer_tools_anchor.dart';

const double kComposerIslandRadius = 20;
const double kComposerIslandInset = 8;
const double kComposerIslandBottomGap = 10;

/// 仅嵌入 VS Code 回复面板启用，不改变独立编辑器或其他主题。
class ComposerTerminalScope extends InheritedWidget {
  const ComposerTerminalScope({
    super.key,
    required this.tokens,
    required super.child,
  });

  final VscodeTokens tokens;

  static VscodeTokens? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ComposerTerminalScope>()
      ?.tokens;

  @override
  bool updateShouldNotify(ComposerTerminalScope oldWidget) =>
      tokens != oldWidget.tokens;
}

/// 只负责玻璃与裁切；覆盖正文的布局由 ComposerEditorLayout 提供。
/// 材质遵循全局玻璃开关和档位，高对比度实色策略由 GlassSurface 统一处理。
class ComposerIsland extends StatelessWidget {
  const ComposerIsland({
    super.key,
    required this.child,
    this.toolsAnchor,
    this.padding = const EdgeInsets.fromLTRB(
      kComposerIslandInset,
      0,
      kComposerIslandInset,
      kComposerIslandBottomGap,
    ),
    this.radius = kComposerIslandRadius,
    this.expansion = 0,
  });
  final Widget child;
  final ComposerToolsAnchor? toolsAnchor;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// 与浮岛几何共用 0–1 进度，保持展开与收起的材质连续。
  final double expansion;

  @override
  Widget build(BuildContext context) {
    final terminal = ComposerTerminalScope.maybeOf(context);
    if (terminal != null) {
      return KeyedSubtree(
        key: toolsAnchor?.surfaceKey,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: terminal.panel,
            border: Border.all(color: terminal.border),
          ),
          child: Material(color: Colors.transparent, child: child),
        ),
      );
    }
    return Padding(
      padding: padding,
      child: KeyedSubtree(
        key: toolsAnchor?.surfaceKey,
        child: GlassSurfaceFrame(
          key: const ValueKey('composer-island-surface'),
          radius: radius,
          recipe: GlassRecipe.lerp(
            GlassRecipe.toolbar,
            GlassRecipe.sheet,
            expansion,
          ),
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }
}
