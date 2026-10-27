import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/hashtag_suggestion.dart';
import 'hashtag_suggestion_tile.dart';

/// 源码模式（纯文本输入框）的 `#` 分类 / 标签补全。
///
/// 光标前是 `#查询` 时按 [dataSource] 搜索，点选后把 `#查询` 换成 `#ref `。
/// 富文本编辑器另有自己的实现（插入 hashtag 原子），两边共用候选行样式。
class HashtagAutocomplete extends StatefulWidget {
  const HashtagAutocomplete({
    super.key,
    required this.controller,
    required this.dataSource,
    required this.child,
    this.focusNode,
  });

  final TextEditingController controller;
  final HashtagDataSource dataSource;
  final FocusNode? focusNode;
  final Widget child;

  @override
  State<HashtagAutocomplete> createState() => _HashtagAutocompleteState();
}

class _HashtagAutocompleteState extends State<HashtagAutocomplete> {
  OverlayEntry? _overlay;
  Timer? _debounce;
  List<HashtagSuggestion> _results = const [];
  String? _query;

  /// `#` 在文本里的位置（选中候选时从这里替换到光标）
  int? _start;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.focusNode?.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    widget.focusNode?.removeListener(_onFocusChanged);
    _debounce?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _onFocusChanged() {
    if (widget.focusNode?.hasFocus != true) _dismiss();
  }

  void _onChanged() {
    final value = widget.controller.value;
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _dismiss();
      return;
    }
    final before = value.text.substring(0, selection.baseOffset);
    final m = hashtagQueryPattern.firstMatch(before);
    if (m == null) {
      _dismiss();
      return;
    }
    final query = m.group(1)!;
    _start = before.length - query.length - 1;
    if (query == _query) return;
    _query = query;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await widget.dataSource(query);
      if (!mounted || _query != query) return;
      _results = results;
      if (results.isEmpty) {
        _removeOverlay();
      } else if (_overlay == null) {
        _overlay = OverlayEntry(builder: _buildOverlay);
        Overlay.of(context).insert(_overlay!);
      } else {
        _overlay!.markNeedsBuild();
      }
    });
  }

  void _select(HashtagSuggestion suggestion) {
    final start = _start;
    final value = widget.controller.value;
    final cursor = value.selection.baseOffset;
    if (start == null || cursor < start) return;
    final insert = '${suggestion.insertText} ';
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(start, cursor, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _dismiss();
  }

  void _dismiss() {
    _debounce?.cancel();
    _query = null;
    _start = null;
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  /// 光标在屏幕上的位置（从输入框里的 RenderEditable 取，比估算准）
  Rect? _caretGlobalRect() {
    RenderEditable? editable;
    void visit(RenderObject node) {
      if (editable != null) return;
      if (node is RenderEditable) {
        editable = node;
        return;
      }
      node.visitChildren(visit);
    }

    final root = context.findRenderObject();
    if (root == null) return null;
    visit(root);
    final found = editable;
    final selection = widget.controller.selection;
    if (found == null || !found.attached || !selection.isValid) return null;
    final local = found.getLocalRectForCaret(
      TextPosition(offset: selection.baseOffset),
    );
    return MatrixUtils.transformRect(found.getTransformTo(null), local);
  }

  Widget _buildOverlay(BuildContext context) {
    final theme = Theme.of(context);
    final caret = _caretGlobalRect();
    if (caret == null) return const SizedBox.shrink();
    const width = 280.0;
    const maxHeight = 260.0;
    final screen = MediaQuery.sizeOf(context);
    final safeTop = MediaQuery.viewPaddingOf(context).top + 8;
    final safeBottom =
        screen.height - MediaQuery.viewInsetsOf(context).bottom - 8;
    final below = safeBottom - caret.bottom;
    final above = caret.top - safeTop;
    // 下方放得下就往下，否则往上（键盘弹起时多半是往上）
    final showBelow = below >= maxHeight + 16 || below >= above;
    return Positioned(
      left: caret.left.clamp(8.0, screen.width - width - 8),
      top: showBelow ? caret.bottom + 4 : null,
      bottom: showBelow ? null : screen.height - caret.top + 4,
      width: width,
      child: TapRegion(
        groupId: EditableText,
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 4,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: ((showBelow ? below : above) - 12).clamp(
                120.0,
                maxHeight,
              ),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _results.length,
              itemBuilder: (context, i) => HashtagSuggestionTile(
                suggestion: _results[i],
                selected: false,
                onTap: () => _select(_results[i]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
