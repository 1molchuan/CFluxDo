import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../theme/vscode_theme.dart';
import '../../../layout/vscode_reader_status_scope.dart';

class PostSegmentFrame extends StatelessWidget {
  final Post post;
  final bool selected;
  final bool highlight;
  final Widget child;
  final bool showTopDateSeparator;
  final String? topDateSeparatorLabel;
  final bool showBottomDateSeparator;
  final String? bottomDateSeparatorLabel;
  final bool showDivider;
  final bool showBottomBorder;
  final BoxConstraints? constraints;

  const PostSegmentFrame({
    super.key,
    required this.post,
    required this.selected,
    required this.highlight,
    required this.child,
    this.showTopDateSeparator = false,
    this.topDateSeparatorLabel,
    this.showBottomDateSeparator = false,
    this.bottomDateSeparatorLabel,
    this.showDivider = false,
    this.showBottomBorder = true,
    this.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final selection = VscodeTokens.maybeOf(context) != null
        ? VscodeReaderFlowScope.maybeOf(context)?.selectedPost
        : null;
    if (selection == null) return _buildFrame(context, selected);
    return _PostTapSelector(
      onSelect: () => selection.value = post.postNumber,
      child: ValueListenableBuilder<int?>(
        valueListenable: selection,
        builder: (context, number, _) => Semantics(
          selected: number == post.postNumber,
          onTap: () => selection.value = post.postNumber,
          child: _buildFrame(context, number == post.postNumber),
        ),
      ),
    );
  }

  Widget _buildFrame(BuildContext context, bool isSelected) {
    final theme = Theme.of(context);
    final targetColor = buildPostTargetColor(theme, post, highlight);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.5);

    // 删除/隐藏帖才降透明,常规帖不挂 Opacity 节点(1.0 也要占一个
    // RenderObject 位)
    final dimmed = post.isDeleted || post.hidden;
    Widget body = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          constraints: constraints,
          decoration: BoxDecoration(
            color: targetColor,
            border: Border(
              bottom: showBottomBorder
                  ? BorderSide(color: borderColor, width: 0.5)
                  : BorderSide.none,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: theme.extension<VscodeTokens>() != null
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.start,
                children: [
                  if (showDivider)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 12,
                      ),
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.3,
                      ),
                      child: Text(
                        context.l10n.post_lastReadHere,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  child,
                ],
              ),
              if (showTopDateSeparator && topDateSeparatorLabel != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FractionalTranslation(
                    translation: const Offset(0, -0.5),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 1,
                        ),
                        color: targetColor,
                        child: Text(
                          topDateSeparatorLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (showBottomDateSeparator && bottomDateSeparatorLabel != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: FractionalTranslation(
                    translation: const Offset(0, 0.5),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 1,
                        ),
                        color: targetColor,
                        child: Text(
                          bottomDateSeparatorLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (isSelected)
          _PostSelectionIndicator(
            color: buildPostSelectionIndicatorColor(theme),
          ),
      ],
    );
    return RepaintBoundary(
      child: dimmed ? Opacity(opacity: 0.6, child: body) : body,
    );
  }
}

/// 旁听完成的点击，不参与 SelectionArea 的手势竞争，也不把拖选和滚动当点击。
class _PostTapSelector extends StatefulWidget {
  const _PostTapSelector({required this.onSelect, required this.child});

  final VoidCallback onSelect;
  final Widget child;

  @override
  State<_PostTapSelector> createState() => _PostTapSelectorState();
}

class _PostTapSelectorState extends State<_PostTapSelector> {
  PointerDownEvent? _press;

  bool get _hasLinkModifier =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _onDown(PointerDownEvent event) {
    if (_press != null || event.buttons != kPrimaryButton || _hasLinkModifier) {
      _press = null;
      return;
    }
    _press = event;
  }

  void _onMove(PointerMoveEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    final slop = press.kind == PointerDeviceKind.mouse
        ? kPrecisePointerHitSlop
        : kTouchSlop;
    if ((event.position - press.position).distanceSquared > slop * slop) {
      _press = null;
    }
  }

  void _onUp(PointerUpEvent event) {
    final press = _press;
    _press = null;
    if (press != null &&
        press.pointer == event.pointer &&
        !_hasLinkModifier &&
        event.timeStamp - press.timeStamp < kLongPressTimeout) {
      widget.onSelect();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: _onUp,
    onPointerCancel: (_) => _press = null,
    onPointerSignal: (_) => _press = null,
    child: widget.child,
  );
}

class _PostSelectionIndicator extends StatelessWidget {
  const _PostSelectionIndicator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: color),
          child: const SizedBox(width: 3),
        ),
      ),
    );
  }
}

Color buildPostTargetColor(ThemeData theme, Post post, bool highlight) {
  final backgroundColor = theme.colorScheme.surface;
  final highlightColor = theme.colorScheme.primaryContainer.withValues(
    alpha: 0.3,
  );
  return highlight
      ? Color.alphaBlend(highlightColor, backgroundColor)
      : post.isDeleted
      ? theme.colorScheme.errorContainer.withValues(alpha: 0.15)
      : post.hidden
      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
      : backgroundColor;
}

Color buildPostSelectionIndicatorColor(ThemeData theme) {
  return theme.colorScheme.primary;
}
