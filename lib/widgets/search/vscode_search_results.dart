import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/category_provider.dart';
import '../../theme/vscode_theme.dart';
import '../common/morphing_dialog_anchor.dart';

/// 编辑器侧栏的搜索结果树；导航、预览和分页仍由搜索页负责。
class VscodeSearchResults extends ConsumerStatefulWidget {
  const VscodeSearchResults({
    super.key,
    required this.posts,
    required this.users,
    required this.scrollController,
    required this.footer,
    required this.onOpenPost,
    required this.onOpenUser,
    required this.hasMorePosts,
    this.onPreviewPost,
  });

  final List<SearchPost> posts;
  final List<SearchUser> users;
  final ScrollController scrollController;
  final Widget footer;
  final ValueChanged<SearchPost> onOpenPost;
  final ValueChanged<SearchUser> onOpenUser;
  final bool hasMorePosts;
  final void Function(SearchPost, BuildContext)? onPreviewPost;

  @override
  ConsumerState<VscodeSearchResults> createState() =>
      _VscodeSearchResultsState();
}

class _VscodeSearchResultsState extends ConsumerState<VscodeSearchResults> {
  static const _usersRow = 'users';
  final _collapsedGroups = <String>{};
  List<_SearchResultGroup> _groups = const [];
  List<Object> _rows = const [];
  bool _usersCollapsed = false;
  String? _selectedKey;

  @override
  void initState() {
    super.initState();
    _groupPosts();
  }

  @override
  void didUpdateWidget(covariant VscodeSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.posts, widget.posts)) {
      _groupPosts();
    } else if (!listEquals(oldWidget.users, widget.users)) {
      _rebuildRows();
    }
  }

  void _groupPosts() {
    final groups = <String, _SearchResultGroup>{};
    for (final post in widget.posts) {
      final topicId = post.topic?.id;
      final key = topicId == null ? 'post:${post.id}' : 'topic:$topicId';
      groups.putIfAbsent(key, () => _SearchResultGroup(key)).posts.add(post);
    }
    // Dart 的有序映射保留话题首个命中的排名，组内沿用服务端排名。
    _groups = groups.values.toList(growable: false);
    _collapsedGroups.removeWhere((key) => !groups.containsKey(key));
    _rebuildRows();
  }

  void _rebuildRows() {
    _rows = [
      for (final group in _groups) ...[
        group,
        if (!_collapsedGroups.contains(group.key)) ...group.posts,
      ],
      if (widget.users.isNotEmpty) ...[
        _usersRow,
        if (!_usersCollapsed) ...widget.users,
      ],
    ];
  }

  void _toggleGroup(String key) {
    setState(() {
      if (!_collapsedGroups.remove(key)) _collapsedGroups.add(key);
      _rebuildRows();
    });
  }

  void _setAllCollapsed(bool collapsed) {
    setState(() {
      _collapsedGroups.clear();
      if (collapsed) _collapsedGroups.addAll(_groups.map((group) => group.key));
      _usersCollapsed = collapsed;
      _rebuildRows();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        VscodeTokens.maybeOf(context) ?? VscodeTokens.of(theme.brightness);
    final categories = ref.watch(categoryMapProvider).value;
    final hasNodes = _groups.isNotEmpty || widget.users.isNotEmpty;
    final hasExpanded =
        _groups.any((group) => !_collapsedGroups.contains(group.key)) ||
        (widget.users.isNotEmpty && !_usersCollapsed);
    final hasCollapsed =
        _collapsedGroups.isNotEmpty ||
        (widget.users.isNotEmpty && _usersCollapsed);

    return Material(
      color: tokens.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.search_resultCount(
                      widget.posts.length + widget.users.length,
                      widget.hasMorePosts ? '+' : '',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.muted,
                    ),
                  ),
                ),
                _toolbarButton(
                  key: const ValueKey('vscode-search-expand-all'),
                  tooltip: context.l10n.common_expand,
                  icon: Icons.unfold_more,
                  onPressed: hasNodes && hasCollapsed
                      ? () => _setAllCollapsed(false)
                      : null,
                  tokens: tokens,
                ),
                _toolbarButton(
                  key: const ValueKey('vscode-search-collapse-all'),
                  tooltip: context.l10n.common_collapse,
                  icon: Icons.unfold_less,
                  onPressed: hasNodes && hasExpanded
                      ? () => _setAllCollapsed(true)
                      : null,
                  tokens: tokens,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              itemCount: _rows.length + 1,
              itemBuilder: (context, index) {
                if (index == _rows.length) return widget.footer;
                final row = _rows[index];
                if (row is _SearchResultGroup) {
                  return _buildGroup(context, row, categories, tokens);
                }
                if (row is SearchPost) return _buildPost(context, row, tokens);
                if (row is SearchUser) return _buildUser(context, row, tokens);
                return _buildUsersHeader(context, tokens);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    required VscodeTokens tokens,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    color: tokens.foreground,
    disabledColor: tokens.muted.withValues(alpha: 0.45),
    padding: const EdgeInsets.all(6),
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    style: IconButton.styleFrom(
      minimumSize: const Size(28, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(),
    ),
  );

  Widget _buildGroup(
    BuildContext context,
    _SearchResultGroup group,
    Map<int, Category>? categories,
    VscodeTokens tokens,
  ) {
    final firstPost = group.posts.first;
    final title = firstPost.topic?.title;
    final headline = firstPost.topicTitleHeadline;
    final displayTitle = title != null && title.isNotEmpty
        ? title
        : headline != null && headline.isNotEmpty
        ? headline
        : '#${firstPost.id}';
    final path = _categoryPath(firstPost.topic?.categoryId, categories);
    final expanded = !_collapsedGroups.contains(group.key);
    final metadata = [
      if (path.isNotEmpty) path,
      context.l10n.search_resultCount(group.posts.length, ''),
    ].join(' · ');

    return Semantics(
      key: ValueKey('vscode-search-group-${group.key}'),
      expanded: expanded,
      child: _surface(
        tokens: tokens,
        onTap: () => _toggleGroup(group.key),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: tokens.muted,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.description_outlined,
                size: 16,
                color: tokens.syntaxType,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((headline == null || headline.isEmpty) &&
                        title != null &&
                        title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: tokens.foreground),
                      )
                    else
                      _SearchHtmlText(
                        html: headline?.isNotEmpty == true
                            ? headline!
                            : displayTitle,
                        tokens: tokens,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 1,
                      ),
                    Text(
                      metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: tokens.muted),
                    ),
                  ],
                ),
              ),
              _toolbarButton(
                key: ValueKey('vscode-search-open-${group.key}'),
                tooltip:
                    '${context.l10n.common_viewDetails} #${firstPost.postNumber}',
                icon: Icons.open_in_new,
                onPressed: () => _openPost(firstPost),
                tokens: tokens,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _categoryPath(int? categoryId, Map<int, Category>? categories) {
    if (categoryId == null || categories == null) return '';
    final names = <String>[];
    final visited = <int>{};
    int? id = categoryId;
    while (id != null && visited.add(id)) {
      final category = categories[id];
      if (category == null) break;
      names.add(category.name);
      id = category.parentCategoryId;
    }
    return names.reversed.join(' / ');
  }

  void _openPost(SearchPost post) {
    setState(() => _selectedKey = 'post:${post.id}');
    widget.onOpenPost(post);
  }

  Widget _buildPost(
    BuildContext context,
    SearchPost post,
    VscodeTokens tokens,
  ) {
    return MorphingDialogAnchor(
      key: ValueKey('vscode-search-post-${post.id}'),
      enabled: widget.onPreviewPost != null,
      bottomGap: 0,
      builder: (anchorContext) {
        final preview = widget.onPreviewPost;
        return _surface(
          tokens: tokens,
          selected: _selectedKey == 'post:${post.id}',
          onTap: () => _openPost(post),
          onPreview: preview == null
              ? null
              : () => preview(post, anchorContext),
          child: _treeIndent(
            tokens: tokens,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 64),
                    child: Text(
                      '#${post.postNumber}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: tokens.lineNumber, height: 1.4),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: _SearchHtmlText(
                      html: post.blurb,
                      tokens: tokens,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUsersHeader(BuildContext context, VscodeTokens tokens) {
    return Semantics(
      key: const ValueKey('vscode-search-users'),
      expanded: !_usersCollapsed,
      child: _surface(
        tokens: tokens,
        onTap: () => setState(() {
          _usersCollapsed = !_usersCollapsed;
          _rebuildRows();
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              Icon(
                _usersCollapsed ? Icons.chevron_right : Icons.expand_more,
                size: 16,
                color: tokens.muted,
              ),
              const SizedBox(width: 4),
              Icon(Icons.folder_outlined, size: 16, color: tokens.syntaxType),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${context.l10n.search_users} (${widget.users.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: tokens.foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUser(
    BuildContext context,
    SearchUser user,
    VscodeTokens tokens,
  ) {
    final name = user.name;
    return KeyedSubtree(
      key: ValueKey('vscode-search-user-${user.id}'),
      child: _surface(
        tokens: tokens,
        selected: _selectedKey == 'user:${user.id}',
        onTap: () {
          setState(() => _selectedKey = 'user:${user.id}');
          widget.onOpenUser(user);
        },
        child: _treeIndent(
          tokens: tokens,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
            child: Row(
              children: [
                Icon(Icons.person_outline, size: 16, color: tokens.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name == null || name.isEmpty
                        ? '@${user.username}'
                        : '@${user.username} · $name',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: tokens.foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _treeIndent({required VscodeTokens tokens, required Widget child}) =>
      Padding(
        padding: const EdgeInsets.only(left: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: tokens.border)),
          ),
          child: child,
        ),
      );

  Widget _surface({
    required VscodeTokens tokens,
    required VoidCallback onTap,
    required Widget child,
    bool selected = false,
    VoidCallback? onPreview,
  }) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? tokens.selection : tokens.sidebar,
      child: InkWell(
        onTap: onTap,
        onLongPress: onPreview,
        onSecondaryTap: onPreview,
        hoverColor: tokens.hover,
        focusColor: tokens.hover,
        borderRadius: BorderRadius.zero,
        child: child,
      ),
    ),
  );
}

class _SearchResultGroup {
  _SearchResultGroup(this.key);

  final String key;
  final List<SearchPost> posts = [];
}

/// DOM 解析保留嵌套高亮与实体文本，不把摘要当作可信的原始标签显示。
class _SearchHtmlText extends StatefulWidget {
  const _SearchHtmlText({
    required this.html,
    required this.tokens,
    required this.style,
    required this.maxLines,
  });

  final String html;
  final VscodeTokens tokens;
  final TextStyle? style;
  final int maxLines;

  @override
  State<_SearchHtmlText> createState() => _SearchHtmlTextState();
}

class _SearchHtmlTextState extends State<_SearchHtmlText> {
  static final _whitespace = RegExp(r'\s+');
  static const _blocks = {
    'p',
    'div',
    'li',
    'ul',
    'ol',
    'blockquote',
    'pre',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'tr',
  };
  late List<(String, bool)> _runs;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant _SearchHtmlText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) _parse();
  }

  void _parse() {
    final runs = <(String, bool)>[];
    void visit(dom.Node node, bool highlighted) {
      if (node is dom.Text) {
        final text = node.data.replaceAll(_whitespace, ' ');
        if (text.isNotEmpty) runs.add((text, highlighted));
        return;
      }
      if (node is dom.Element) {
        final tag = node.localName;
        if (tag == 'script' || tag == 'style' || tag == 'template') return;
        if (tag == 'br') {
          runs.add((' ', false));
          return;
        }
        final block = _blocks.contains(tag);
        if (block && runs.isNotEmpty) runs.add((' ', false));
        final marked = highlighted || node.classes.contains('search-highlight');
        for (final child in node.nodes) {
          visit(child, marked);
        }
        if (block) runs.add((' ', false));
        return;
      }
      for (final child in node.nodes) {
        visit(child, highlighted);
      }
    }

    visit(html_parser.parseFragment(widget.html), false);
    _runs = runs;
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        for (final (text, highlighted) in _runs)
          TextSpan(
            text: text,
            style: highlighted
                ? TextStyle(
                    backgroundColor: widget.tokens.accent.withValues(
                      alpha: 0.25,
                    ),
                    fontWeight: FontWeight.w600,
                  )
                : null,
          ),
      ],
    ),
    style: widget.style?.copyWith(color: widget.tokens.foreground, height: 1.4),
    maxLines: widget.maxLines,
    overflow: TextOverflow.ellipsis,
  );
}
