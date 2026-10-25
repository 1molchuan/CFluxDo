import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/vscode_theme.dart';
import '../../l10n/s.dart';

/// 阅读区与回复终端共用高度；收起或最大化只隐藏内容，不销毁状态。
class VscodeTerminalPanel extends StatefulWidget {
  const VscodeTerminalPanel({
    super.key,
    required this.reader,
    this.composer,
    required this.targetLabel,
    required this.onClose,
  });

  final Widget reader;
  final Widget? composer;
  final String targetLabel;
  final VoidCallback onClose;

  @override
  State<VscodeTerminalPanel> createState() => VscodeTerminalPanelState();
}

class VscodeTerminalPanelState extends State<VscodeTerminalPanel> {
  double _heightFraction = 0.4;
  bool _collapsed = false;
  bool _maximized = false;

  /// 恢复拖拽前设定的普通面板高度，不改变编辑器或阅读区状态。
  void reveal() {
    if (!mounted || (!_collapsed && !_maximized)) return;
    setState(() {
      _collapsed = false;
      _maximized = false;
    });
  }

  @override
  void didUpdateWidget(covariant VscodeTerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.composer != null && widget.composer == null) {
      _collapsed = false;
      _maximized = false;
      _heightFraction = 0.4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        VscodeTokens.maybeOf(context) ?? VscodeTokens.of(theme.brightness);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final width = constraints.maxWidth;
        final hasComposer = widget.composer != null;
        final headerHeight = math.min(
          height,
          math.max(32.0, MediaQuery.textScalerOf(context).scale(12) + 14),
        );
        final dividerHeight = math.min(
          4.0,
          math.max(0.0, height - headerHeight),
        );
        final chromeHeight = headerHeight + dividerHeight;
        final minPanelHeight = math.min(
          height,
          chromeHeight + math.min(160.0, height * 0.4),
        );
        final maxPanelHeight = math.max(
          minPanelHeight,
          height - math.min(96.0, height * 0.25),
        );
        final normalPanelHeight = (height * _heightFraction)
            .clamp(minPanelHeight, maxPanelHeight)
            .toDouble();
        final panelHeight = !hasComposer
            ? 0.0
            : _collapsed
            ? chromeHeight
            : _maximized
            ? height
            : normalPanelHeight;
        final readerHeight = height - panelHeight;
        final composerHeight = math.max(0.0, panelHeight - chromeHeight);

        return SizedBox(
          height: height,
          child: Column(
            children: [
              _retainedPane(
                visibleHeight: readerHeight,
                contentHeight: readerHeight > 0
                    ? readerHeight
                    : height - normalPanelHeight,
                width: width,
                child: widget.reader,
              ),
              if (hasComposer)
                SizedBox(
                  height: panelHeight,
                  child: ColoredBox(
                    color: tokens.panel,
                    child: Column(
                      children: [
                        MouseRegion(
                          cursor: !_collapsed && !_maximized
                              ? SystemMouseCursors.resizeUpDown
                              : MouseCursor.defer,
                          child: GestureDetector(
                            key: const ValueKey('vscode-terminal-divider'),
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: _collapsed || _maximized
                                ? null
                                : (details) {
                                    if (height <= 0) return;
                                    setState(() {
                                      _heightFraction =
                                          (normalPanelHeight - details.delta.dy)
                                              .clamp(
                                                minPanelHeight,
                                                maxPanelHeight,
                                              ) /
                                          height;
                                    });
                                  },
                            child: SizedBox(
                              height: dividerHeight,
                              width: double.infinity,
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Container(
                                  height: 1,
                                  color: tokens.border,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: headerHeight,
                          child: _buildHeader(context, tokens),
                        ),
                        _retainedPane(
                          visibleHeight: composerHeight,
                          contentHeight: composerHeight > 0
                              ? composerHeight
                              : math.max(0.0, normalPanelHeight - chromeHeight),
                          width: width,
                          child: widget.composer!,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // 隐藏内容仍按正常尺寸布局，避免零高度约束破坏输入框或滚动位置。
  Widget _retainedPane({
    required double visibleHeight,
    required double contentHeight,
    required double width,
    required Widget child,
  }) {
    final hidden = visibleHeight <= 0;
    return SizedBox(
      height: visibleHeight,
      width: width,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: contentHeight,
          maxHeight: contentHeight,
          child: Offstage(
            offstage: hidden,
            child: TickerMode(enabled: !hidden, child: child),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, VscodeTokens tokens) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final buttonSize = math.min(
          28.0,
          math.min(constraints.maxHeight, constraints.maxWidth / 3),
        );
        Widget action(String tooltip, IconData icon, VoidCallback onPressed) {
          return SizedBox.square(
            dimension: buttonSize,
            child: IconButton(
              tooltip: tooltip,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                shape: const RoundedRectangleBorder(),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: Size.zero,
              ),
              iconSize: math.min(16.0, buttonSize),
              color: tokens.muted,
              onPressed: onPressed,
              icon: Icon(icon),
            ),
          );
        }

        return Material(
          color: tokens.panel,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: math.min(
                        64.0 * MediaQuery.textScalerOf(context).scale(12) / 12,
                        (constraints.maxWidth - buttonSize * 3) * 0.35,
                      ),
                      child: Container(
                        height: double.infinity,
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(
                          horizontal: math.min(10.0, constraints.maxWidth / 20),
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: tokens.accent, width: 2),
                          ),
                        ),
                        child: Text(
                          context.l10n.post_terminalTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: 12,
                                color: tokens.foreground,
                              ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: math.min(8.0, constraints.maxWidth / 20),
                        ),
                        child: Tooltip(
                          message: widget.targetLabel,
                          child: Text(
                            widget.targetLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontSize: 12, color: tokens.muted),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              action(
                _collapsed
                    ? context.l10n.post_terminalExpand
                    : context.l10n.post_terminalCollapse,
                _collapsed ? Icons.expand_less : Icons.expand_more,
                () => setState(() {
                  _collapsed = !_collapsed;
                  _maximized = false;
                }),
              ),
              action(
                _maximized
                    ? context.l10n.post_terminalRestore
                    : context.l10n.post_terminalMaximize,
                _maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                () => setState(() {
                  _maximized = !_maximized;
                  _collapsed = false;
                }),
              ),
              action(
                context.l10n.post_terminalClose,
                Icons.close,
                widget.onClose,
              ),
            ],
          ),
        );
      },
    );
  }
}
