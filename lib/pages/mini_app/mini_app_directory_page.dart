import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/mini_app.dart';
import '../../providers/core_providers.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/number_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/layout/master_detail_layout.dart';
import 'mini_app_icon.dart';
import 'mini_app_page.dart';

/// 微应用广场：linux.do 的 `/apps`（discourse-mini-app 插件）做成原生列表，
/// 排序、搜索、只看收藏与网页端一致；点开的应用在 [MiniAppPage] 里运行
class MiniAppDirectoryPage extends ConsumerStatefulWidget {
  const MiniAppDirectoryPage({super.key, this.initialSort, this.initialQuery});

  final MiniAppSort? initialSort;
  final String? initialQuery;

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const MiniAppDirectoryPage()));

  @override
  ConsumerState<MiniAppDirectoryPage> createState() =>
      _MiniAppDirectoryPageState();
}

class _MiniAppDirectoryPageState extends ConsumerState<MiniAppDirectoryPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _searchDebounce;

  /// 为空时用站点默认排序，首页回来后填成服务端实际用的
  MiniAppSort? _sort;
  String _query = '';
  bool _favorite = false;

  final List<MiniApp> _apps = [];
  int _page = 0;
  int _total = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  StackTrace? _errorStack;
  Object? _loadMoreError;

  /// 排序 / 搜索 / 收藏变了就作废进行中的请求
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _sort = widget.initialSort;
    _query = widget.initialQuery?.trim() ?? '';
    _searchController.text = _query;
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 按当前条件从第一页重新加载。[showSpinner] 为 false 时保留旧列表（下拉刷新）
  Future<void> _reload({bool showSpinner = true}) async {
    final generation = ++_generation;
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
      _errorStack = null;
      _loadMoreError = null;
    });
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .getMiniAppDirectory(sort: _sort, query: _query, favorite: _favorite);
      if (!mounted || generation != _generation) return;
      setState(() {
        _apps
          ..clear()
          ..addAll(result.apps);
        _page = result.page;
        _total = result.total;
        _hasMore = result.hasMore && result.apps.isNotEmpty;
        _sort ??= result.sort;
        _loading = false;
      });
    } catch (e, s) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _errorStack = s;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _error != null) return;
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .getMiniAppDirectory(
            sort: _sort,
            query: _query,
            page: _page + 1,
            favorite: _favorite,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        // 翻页期间排名变动，同一个应用可能在两页里各出现一次
        final seen = {for (final app in _apps) app.appId};
        _apps.addAll(result.apps.where((app) => seen.add(app.appId)));
        _page = result.page;
        _total = result.total;
        _hasMore = result.hasMore && result.apps.isNotEmpty;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadMoreError = e;
        _loadingMore = false;
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadMoreError != null) return;
    if (_scrollController.position.extentAfter < 600) _loadMore();
  }

  void _changeSort(MiniAppSort sort) {
    if (sort == _sort) return;
    _sort = sort;
    _restart();
  }

  void _toggleFavorite() {
    _favorite = !_favorite;
    _restart();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(value),
    );
  }

  void _search(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query == _query) return;
    _query = query;
    _restart();
  }

  void _clearSearch() {
    _searchController.clear();
    _search('');
  }

  /// 条件变了：回到顶部，从第一页重来
  void _restart() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _reload();
  }

  Future<void> _openApp(MiniApp app) async {
    await MiniAppPage.open(
      context,
      app.appId,
      name: app.name,
      iconUrl: app.iconUrl,
    );
    // 在应用里取消了收藏：「已收藏」列表要跟上
    if (mounted && _favorite) _reload(showSpinner: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loggedIn = ref.watch(currentUserProvider).value != null;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.miniApp_plaza)),
      body: Column(
        children: [
          _buildFilters(theme, loggedIn),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildFilters(ThemeData theme, bool loggedIn) {
    final mj = theme.extension<MojianTokens>();
    final radius = BorderRadius.circular(mj != null ? 6 : 24);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) => TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: mj?.paper3 ?? theme.colorScheme.surfaceContainerHigh,
                hintText: context.l10n.miniApp_search,
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Symbols.close_rounded, size: 18),
                        tooltip: context.l10n.common_clear,
                        onPressed: _clearSearch,
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: border(mj?.rule ?? Colors.transparent),
                enabledBorder: border(mj?.rule ?? Colors.transparent),
                focusedBorder: border(mj?.ink3 ?? theme.colorScheme.primary),
              ),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              for (final sort in MiniAppSort.values) ...[
                ChoiceChip(
                  label: Text(_sortLabel(sort)),
                  selected: _sort == sort,
                  onSelected: (_) => _changeSort(sort),
                ),
                const SizedBox(width: 8),
              ],
              if (loggedIn)
                FilterChip(
                  label: Text(context.l10n.miniApp_favorites),
                  selected: _favorite,
                  onSelected: (_) => _toggleFavorite(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: LoadingSpinner());
    if (_error != null) {
      return ErrorView(
        error: _error!,
        stackTrace: _errorStack,
        onRetry: _reload,
      );
    }
    if (_apps.isEmpty) {
      final message = _favorite
          ? context.l10n.miniApp_noFavorites
          : _query.isNotEmpty
          ? context.l10n.miniApp_noMatches
          : context.l10n.miniApp_empty;
      return M3eRefreshIndicator(
        onRefresh: () => _reload(showSpinner: false),
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: MasterDetailEmptyState(
                  icon: _favorite
                      ? Symbols.bookmark_rounded
                      : Symbols.widgets_rounded,
                  message: message,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return M3eRefreshIndicator(
      onRefresh: () => _reload(showSpinner: false),
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _apps.length + 2,
        separatorBuilder: (_, index) => SizedBox(height: index == 0 ? 8 : 12),
        itemBuilder: (context, index) {
          if (index == 0) return _buildSummary(theme);
          if (index == _apps.length + 1) return _buildFooter(theme);
          final app = _apps[index - 1];
          return _MiniAppTile(app: app, onTap: () => _openApp(app));
        },
      ),
    );
  }

  /// 列表头：总数 + 当前排序的含义
  Widget _buildSummary(ThemeData theme) {
    final sort = _sort;
    final parts = [
      context.l10n.miniApp_count(_total),
      if (sort != null) _sortDescription(sort),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        parts.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color:
              theme.extension<MojianTokens>()?.ink3 ??
              theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: LoadingSpinner(size: 24)),
      );
    }
    if (_loadMoreError != null) {
      return Center(
        child: TextButton.icon(
          onPressed: _loadMore,
          icon: const Icon(Symbols.refresh_rounded, size: 18),
          label: Text(context.l10n.common_retry),
        ),
      );
    }
    if (_hasMore) return const SizedBox(height: 48);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          context.l10n.common_noMore,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  String _sortLabel(MiniAppSort sort) => switch (sort) {
    MiniAppSort.hot => context.l10n.miniApp_sortHot,
    MiniAppSort.latest => context.l10n.miniApp_sortLatest,
    MiniAppSort.rating => context.l10n.miniApp_sortRating,
    MiniAppSort.used => context.l10n.miniApp_sortUsed,
  };

  String _sortDescription(MiniAppSort sort) => switch (sort) {
    MiniAppSort.hot => context.l10n.miniApp_sortHotDesc,
    MiniAppSort.latest => context.l10n.miniApp_sortLatestDesc,
    MiniAppSort.rating => context.l10n.miniApp_sortRatingDesc,
    MiniAppSort.used => context.l10n.miniApp_sortUsedDesc,
  };
}

/// 广场里的一个应用：图标、名称、简介，下面一行作者 · 评分 · 使用量
class _MiniAppTile extends StatelessWidget {
  const _MiniAppTile({required this.app, required this.onTap});

  final MiniApp app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final subtle = mj?.ink3 ?? theme.colorScheme.onSurfaceVariant;
    final metaStyle = theme.textTheme.labelSmall?.copyWith(
      color: subtle,
      fontSize: 12,
    );
    final author = app.author;
    final average = app.ratingAverage;

    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiniAppIcon(url: app.iconUrl, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFamily: mj == null
                              ? null
                              : MojianTokens.titleFamilyFor(context),
                          color: mj?.ink,
                        ),
                      ),
                    ),
                    if (app.isFavorited)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(
                          Symbols.bookmark_rounded,
                          size: 16,
                          fill: 1,
                          color: mj?.accent ?? theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                if (app.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    app.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: subtle,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (author != null && author.username.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SmartAvatar(
                            imageUrl: author.getAvatarUrl(size: 32),
                            radius: 8,
                            fallbackText: author.username,
                          ),
                          const SizedBox(width: 4),
                          Text(author.username, style: metaStyle),
                        ],
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.star_rounded,
                          size: 14,
                          fill: average == null ? 0 : 1,
                          color: average == null
                              ? subtle
                              : (mj?.gold ?? Colors.amber.shade700),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          average == null
                              ? context.l10n.miniApp_unrated
                              : '${average.toStringAsFixed(1)} (${app.ratingCount})',
                          style: metaStyle,
                        ),
                      ],
                    ),
                    Text(
                      context.l10n.miniApp_uses(
                        NumberUtils.formatCount(app.usageCount),
                      ),
                      style: metaStyle,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (mj != null) {
      // 墨笺：纸笺底 + 发丝线框的小圆角卡，与元宇宙页的账本卡一致
      return Material(
        color: mj.paper3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: mj.rule),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}
