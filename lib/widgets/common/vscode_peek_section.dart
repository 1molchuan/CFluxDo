import 'package:flutter/material.dart';

import '../../theme/vscode_theme.dart';

/// 编辑器式辅助信息入口：默认折叠，只在用户展开后构建内容。
class VscodePeekSection extends StatefulWidget {
  const VscodePeekSection({
    super.key,
    required this.label,
    required this.builder,
    this.summary,
    this.initiallyExpanded = false,
  });

  final String label;
  final String? summary;
  final WidgetBuilder builder;
  final bool initiallyExpanded;

  @override
  State<VscodePeekSection> createState() => _VscodePeekSectionState();
}

class _VscodePeekSectionState extends State<VscodePeekSection> {
  late bool _expanded = widget.initiallyExpanded;
  late bool _built = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: _expanded,
          child: TextButton(
            onPressed: () => setState(() {
              _expanded = !_expanded;
              if (_expanded) _built = true;
            }),
            style: TextButton.styleFrom(
              foregroundColor: tokens.muted,
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: const RoundedRectangleBorder(),
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(widget.label),
                if (widget.summary != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.summary!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_built)
          Offstage(
            offstage: !_expanded,
            child: ExcludeFocus(
              excluding: !_expanded,
              child: TickerMode(
                enabled: _expanded,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: widget.builder(context),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
