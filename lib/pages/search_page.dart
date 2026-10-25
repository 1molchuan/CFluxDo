import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/shortcut_binding.dart';
import '../providers/discourse_providers.dart';
import '../models/search_filter.dart';
import '../models/search_result.dart';
import '../services/preloaded_data_service.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/common/error_view.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/search/search_filter_panel.dart';
import '../widgets/search/search_list_skeleton.dart';
import '../widgets/search/search_post_card.dart';
import '../widgets/search/search_preview_dialog.dart';
import '../providers/preferences_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/shortcut_provider.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../utils/responsive.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'package:dio/dio.dart';
import '../services/app_error_handler.dart';
import '../l10n/s.dart';
import 'user_profile_page.dart';
import '../utils/dialog_utils.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/blocked_user_filter.dart';
import '../utils/discourse_url_parser.dart';
import '../widgets/common/search_capsule.dart';
import '../utils/link_launcher.dart';
import 'settings_page.dart';
import '../theme/mojian_theme.dart';
import '../widgets/common/mojian_section_label.dart';
import '../widgets/topic/topic_card.dart' show mojianCardDecoration;
import '../config/forum_site.dart';
import '../services/site_context.dart';
import '../utils/url_helper.dart';
import '../theme/vscode_theme.dart';
import '../utils/time_utils.dart';
import '../widgets/search/vscode_search_results.dart';

/// 搜索框中的站内直达链接标准化。支持两站完整 URL、主域裸链接和相对路径；
/// 普通关键词原样返回，后续由 [isInternalUrlString] 判定后继续普通搜索。
@visibleForTesting
String normalizeDirectSearchLink(String rawValue) {
  final value = rawValue.trim();
  if (value.startsWith('/')) return value;
  if (RegExp(
    r'^(?:www\.)?(?:linux\.do|idcflare\.com)(?::\d+)?/',
    caseSensitive: false,
  ).hasMatch(value)) {
    return 'https://$value';
  }
  return value;
}

/// 搜索页面
class SearchPage extends ConsumerStatefulWidget {
  static const double parallelMasterWidth = PaneBreakpoints.wideMasterWidth;
  static const double parallelMinDetailWidth =
      PaneBreakpoints.wideMinDetailWidth;

  final String? initialQuery;
  final SearchFilter? initialFilter;

  /// 首页搜索胶囊入口：搜索框包同 tag Hero 做跨页 morph（一镜到底），
  /// 键盘等 Hero 飞行结束再弹（飞行中弹出会顶起布局撕裂动画）
  final bool heroCapsule;

  const SearchPage({
    super.key,
    this.initialQuery,
    this.initialFilter,
    this.embeddedMaster = false,
    this.stackProvider,
    this.onClose,
    this.heroCapsule = false,
    this.parentActive = true,
  });

  final bool embeddedMaster;
  final SelectedTopicProvider? stackProvider;
  final VoidCallback? onClose;

  /// 宿主 tab 是否活跃(嵌入首页左栏时传入:IndexedStack 常驻页共享
  /// 根路由,非活跃 tab 的 surface 注册会截胡活跃 tab 的按键)。
  final bool parentActive;

  @visibleForTesting
  static bool canShowParallelFor(BuildContext context) {
    return MasterDetailLayout.canShowBothPanesFor(
      context,
      masterWidth: parallelMasterWidth,
      minDetailWidth: parallelMinDetailWidth,
    );
  }

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  SelectedTopicProvider get _stackProvider =>
      widget.stackProvider ?? selectedSearchProvider;
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();
  late final ShortcutSurfaceBinding _shortcutSurfaceBinding =
      ShortcutSurfaceBinding(
        ref: ref,
        id: ShortcutSurfaceIds.search,
        triggerAction: ShortcutAction.openSearch,
        kind: ShortcutSurfaceKind.route,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
        passthroughActions: ShortcutSurfaceActionSets.globalRoutePassthrough,
        // 嵌入首页左栏(embeddedMaster)时挂在 IndexedStack 常驻 tab 里,
        // 宿主不活跃则不参与分发,否则拦掉其他 tab 的按键。
        enabled: () => !widget.embeddedMaster || widget.parentActive,
      );
  ModalRoute<dynamic>? _route;

  String _currentQuery = '';
  int _currentPage = 1;
  bool _isLoadingMore = false;
  List<SearchPost> _standardPosts = []; // 标准搜索结果（原始）
  List<SearchPost> _allPosts = []; // 最终展示列表（融合后）
  List<SearchUser> _allUsers = [];
  bool _hasMorePosts = false;
  bool _hasMoreUsers = false;
  bool _hasError = false;
  Object? _searchError;
  StackTrace? _searchErrorStack;
  bool _isLoadMoreFailed = false;
  bool _isSearching = false;
  bool _vscodeOptionsExpanded = false;

  // 最近搜索记录
  List<String> _recentSearches = [];
  bool _isLoadingRecentSearches = true;
  bool _isClearingRecentSearches = false;

  // 高级过滤器
  late SearchFilter _filter;

  // AI 语义搜索
  bool _siteAiSearchAvailable = false;
  List<SearchPost> _aiPosts = []; // AI 搜索结果（原始）
  bool _isSearchingAi = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter ?? const SearchFilter();
    PreloadedDataService().isAiSemanticSearchEnabled().then((enabled) {
      if (mounted) setState(() => _siteAiSearchAvailable = enabled);
    });
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _searchController.text = widget.initialQuery!;
      _currentQuery = widget.initialQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performInitialSearchAfterTransition();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _requestFocusAfterTransition();
        _loadRecentSearches();
      });
    }
    _scrollController.addListener(_onScroll);
  }

  /// 个人资料页等入口会携带初始查询打开搜索页。等待路由转场结束后再启动
  /// 普通搜索与站内 AI 搜索，避免两路结果状态更新和页面入场动画争抢帧预算。
  void _performInitialSearchAfterTransition() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _performSearch();
      return;
    }

    void listener(AnimationStatus status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(listener);
      if (mounted && status == AnimationStatus.completed) {
        _performSearch();
      }
    }

    animation.addStatusListener(listener);
  }

  /// Hero 入场时等转场（含 Hero 飞行）结束再聚焦弹键盘；普通入场立即聚焦
  void _requestFocusAfterTransition() {
    final route = ModalRoute.of(context);
    if (!widget.heroCapsule ||
        route == null ||
        route.animation == null ||
        route.animation!.isCompleted) {
      _focusNode.requestFocus();
      return;
    }
    final animation = route.animation!;
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        animation.removeStatusListener(listener);
        if (mounted) _focusNode.requestFocus();
      }
    }

    animation.addStatusListener(listener);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    _shortcutSurfaceBinding.registerDeferred(
      context,
      onClose: widget.onClose ?? () => Navigator.of(context).maybePop(),
      onFocus: _revealSelf,
    );
  }

  void _revealSelf() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || route.isCurrent) return;
    navigator.popUntil((candidate) => identical(candidate, route));
  }

  /// 加载最近搜索记录
  Future<void> _loadRecentSearches() async {
    try {
      final service = ref.read(discourseServiceProvider);
      final searches = await service.getRecentSearches();
      if (mounted) {
        setState(() {
          _recentSearches = searches;
          _isLoadingRecentSearches = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingRecentSearches = false;
        });
      }
    }
  }

  /// 清空最近搜索记录
  Future<void> _clearRecentSearches() async {
    if (_isClearingRecentSearches) return;
    setState(() => _isClearingRecentSearches = true);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.clearRecentSearches();
      if (mounted) {
        setState(() {
          _recentSearches = [];
          _isClearingRecentSearches = false;
        });
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      if (mounted) {
        setState(() => _isClearingRecentSearches = false);
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        setState(() => _isClearingRecentSearches = false);
      }
    }
  }

  @override
  void dispose() {
    _shortcutSurfaceBinding.disposeDeferred();
    // 独立搜索页拥有自己的平行视界栈，退出时应清理；嵌入首页左栏时复用
    // selectedTopicProvider，搜索页被信息流/分类替换不代表右栏详情也应消失。
    if (widget.stackProvider == null) {
      ref.read(selectedSearchProvider.notifier).clear();
    }
    _searchController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  void _onSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (_tryOpenInternalLink(trimmed)) return;
    if (trimmed != _currentQuery || _allPosts.isEmpty) {
      setState(() {
        _currentQuery = trimmed;
        _currentPage = 1;
        _standardPosts = [];
        _allPosts = [];
        _aiPosts = [];
        _allUsers = [];
        _hasMorePosts = false;
        _hasMoreUsers = false;
        _hasError = false;
        _isLoadMoreFailed = false;
      });
      _performSearch();
    }
  }

  bool _tryOpenInternalLink(String rawValue) {
    final normalized = normalizeDirectSearchLink(rawValue);
    final uri = Uri.tryParse(UrlHelper.resolveUrl(normalized));
    final target = uri == null ? null : ForumSite.fromUri(uri);
    if (target != null && target != SiteContext.current) {
      launchContentLink(context, uri.toString());
      _focusNode.unfocus();
      return true;
    }
    if (!isInternalUrlString(normalized)) return false;

    final topic = DiscourseUrlParser.parseTopic(normalized);
    if (topic != null) {
      if (widget.embeddedMaster || SearchPage.canShowParallelFor(context)) {
        ref
            .read(_stackProvider.notifier)
            .select(
              topicId: topic.topicId,
              initialTitle: topic.slug,
              scrollToPostNumber: topic.postNumber,
            );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topic.topicId,
              initialTitle: topic.slug,
              scrollToPostNumber: topic.postNumber,
            ),
          ),
        );
      }
      _focusNode.unfocus();
      return true;
    }

    final user = DiscourseUrlParser.parseUser(normalized);
    if (user == null) return false;
    if (widget.embeddedMaster || SearchPage.canShowParallelFor(context)) {
      ref.read(_stackProvider.notifier).selectProfile(user.username);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserProfilePage(username: user.username),
        ),
      );
    }
    _focusNode.unfocus();
    return true;
  }

  void _onSortChanged(SearchSortOrder? order) {
    final currentOrder = ref.read(searchSettingsProvider).sortOrder;
    if (order != null && order != currentOrder) {
      ref.read(searchSettingsProvider.notifier).setSortOrder(order);
      setState(() {
        _currentPage = 1;
        _standardPosts = [];
        _allPosts = [];
        _allUsers = [];
        // 切换排序时清空 AI 结果
        _aiPosts = [];
        _isSearchingAi = false;
      });
      _performSearch();
    }
  }

  void _onFilterChanged(SearchFilter newFilter) {
    setState(() {
      _filter = newFilter;
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _openFilterPanel() {
    final vscode = VscodeTokens.maybeOf(context);
    if (vscode != null) {
      showAppDialog<void>(
        context: context,
        builder: (context) => Theme(
          data: VscodeTheme.toolbarTheme(Theme.of(context)),
          child: Dialog(
            shape: const RoundedRectangleBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
              child: SearchFilterPanel(
                filter: _filter,
                onFilterChanged: _onFilterChanged,
                hideInType: true,
              ),
            ),
          ),
        ),
      );
      return;
    }
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SearchFilterPanel(
          filter: _filter,
          onFilterChanged: _onFilterChanged,
          hideInType: true,
        ),
      ),
    );
  }

  /// 从查询字符串中移除 order:xxx 部分，返回纯净的查询
  String _stripOrderFromQuery(String query) {
    return query
        .replaceAll(
          RegExp(r'\s*order:(relevance|latest|likes|views|latest_topic)\s*'),
          ' ',
        )
        .trim();
  }

  /// 从查询字符串中提取排序方式
  SearchSortOrder? _extractOrderFromQuery(String query) {
    final match = RegExp(
      r'order:(relevance|latest|likes|views|latest_topic)',
    ).firstMatch(query);
    if (match == null) return null;
    final orderValue = match.group(1);
    return SearchSortOrder.values.firstWhere(
      (e) => e.value == orderValue,
      orElse: () => SearchSortOrder.relevance,
    );
  }

  /// RRF（Reciprocal Rank Fusion）算法，与 Discourse 前端一致
  /// 将标准搜索结果和 AI 搜索结果按倒数排名融合
  List<SearchPost> _mergeWithRRF(
    List<SearchPost> standard,
    List<SearchPost> ai,
  ) {
    if (ai.isEmpty) return standard;
    if (standard.isEmpty) return ai;

    const k = 5; // RRF 常数，与 Discourse 一致

    // 为每个结果计算 RRF 分数，key 为 topic_id
    final scoreMap = <int, double>{};
    final postMap = <int, SearchPost>{};

    for (var i = 0; i < standard.length; i++) {
      final topicId = standard[i].topic?.id;
      if (topicId == null) continue;
      scoreMap[topicId] = 1.0 / (i + k);
      postMap[topicId] = standard[i];
    }

    for (var i = 0; i < ai.length; i++) {
      final topicId = ai[i].topic?.id;
      if (topicId == null) continue;
      if (scoreMap.containsKey(topicId)) {
        // 两个列表都有的结果，分数累加（排名更靠前）
        scoreMap[topicId] = scoreMap[topicId]! + 1.0 / (i + k);
      } else {
        scoreMap[topicId] = 1.0 / (i + k);
        postMap[topicId] = ai[i];
      }
    }

    // 按 RRF 分数降序排列
    final sortedIds = scoreMap.keys.toList()
      ..sort((a, b) => scoreMap[b]!.compareTo(scoreMap[a]!));

    return sortedIds.map((id) => postMap[id]!).toList();
  }

  /// 根据当前 AI 开关状态重新构建展示列表
  void _rebuildDisplayPosts() {
    final settings = ref.read(searchSettingsProvider);
    final showAi =
        _siteAiSearchAvailable &&
        settings.aiSearchEnabled &&
        settings.sortOrder == SearchSortOrder.relevance &&
        _aiPosts.isNotEmpty;

    if (showAi) {
      _allPosts = _mergeWithRRF(_standardPosts, _aiPosts);
    } else {
      _allPosts = List.of(_standardPosts);
    }
  }

  bool _shouldTriggerAiSearch() {
    final sortOrder = ref.read(searchSettingsProvider).sortOrder;
    final aiEnabled = ref.read(searchSettingsProvider).aiSearchEnabled;
    return _siteAiSearchAvailable &&
        aiEnabled &&
        sortOrder == SearchSortOrder.relevance;
  }

  void _triggerAiSearch(String query) async {
    setState(() => _isSearchingAi = true);
    try {
      final service = ref.read(discourseServiceProvider);
      final aiResult = await service.semanticSearch(query: query);
      if (!mounted) return;

      // 标记为 AI 生成
      _aiPosts = aiResult.posts
          .map((p) => p.copyWith(isAiGenerated: true))
          .toList();

      setState(() {
        _isSearchingAi = false;
        _rebuildDisplayPosts();
      });
    } catch (e) {
      // 静默失败，404/403/429 都不影响标准搜索
      if (mounted) setState(() => _isSearchingAi = false);
    }
  }

  Future<void> _performSearch() async {
    if (_currentQuery.isEmpty) return;

    final isLoadMore = _currentPage > 1;
    if (!isLoadMore) {
      _loadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _isSearching = true;
      _hasError = false;
      _isLoadMoreFailed = false;
      if (!isLoadMore) {
        _isLoadingMore = false;
      }
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final sortOrder = ref.read(searchSettingsProvider).sortOrder;

      // 构建查询字符串
      final cleanQuery = _stripOrderFromQuery(_currentQuery);
      String searchQuery = cleanQuery;

      // 添加过滤条件
      final filterQuery = _filter.toQueryString();
      if (filterQuery.isNotEmpty) {
        searchQuery = '$searchQuery $filterQuery';
      }

      // 添加排序
      if (sortOrder.value != null) {
        searchQuery = '$searchQuery order:${sortOrder.value}';
      }

      // 首页搜索时并行触发 AI 语义搜索
      if (_currentPage == 1 && _shouldTriggerAiSearch()) {
        _triggerAiSearch(cleanQuery);
      }

      final result = await service.search(
        query: searchQuery,
        page: _currentPage,
        typeFilter: 'topic',
      );

      setState(() {
        _isSearching = false;
        if (_currentPage == 1) {
          _standardPosts = result.posts;
          _allUsers = result.users;
        } else {
          _standardPosts.addAll(result.posts);
        }
        _hasMorePosts = result.hasMorePosts && result.posts.isNotEmpty;
        _hasMoreUsers = result.hasMoreUsers;
        _isLoadingMore = false;
        _rebuildDisplayPosts();
      });
    } catch (e, s) {
      setState(() {
        _isSearching = false;
        _isLoadingMore = false;
        if (isLoadMore) {
          // 加载更多失败：回退页码，显示重试
          _currentPage--;
          _isLoadMoreFailed = true;
        } else {
          // 首次搜索失败：显示全局错误
          _hasError = true;
          _searchError = e;
          _searchErrorStack = s;
        }
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadMoreFailed) return;
    await _loadMoreCoordinator.loadMore(
      loadMore: _loadMorePage,
      hasMore: () => _hasMorePosts,
      isActive: () => mounted,
      progressCount: () => _allPosts.length,
    );
  }

  Future<void> _loadMorePage() async {
    if (_isLoadingMore || !_hasMorePosts || _isLoadMoreFailed) return;

    setState(() {
      _isLoadingMore = true;
      _currentPage++;
    });

    await _performSearch();
  }

  void _clearSearch() {
    _searchController.clear();
    _loadMoreCoordinator.resetCooldown();
    setState(() {
      _currentQuery = '';
      _isSearching = false;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
      _isSearchingAi = false;
      _hasMorePosts = false;
      _hasMoreUsers = false;
      _currentPage = 1;
    });
    _focusNode.requestFocus();
  }

  void _clearCategory() {
    setState(() {
      _filter = _filter.copyWith(clearCategory: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _filter = _filter.copyWith(
        tags: _filter.tags.where((t) => t != tag).toList(),
      );
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearStatus() {
    setState(() {
      _filter = _filter.copyWith(clearStatus: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearDateRange() {
    setState(() {
      _filter = _filter.copyWith(clearDateRange: true);
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _clearAllFilters() {
    setState(() {
      _filter = _filter.clear();
      _currentPage = 1;
      _standardPosts = [];
      _allPosts = [];
      _aiPosts = [];
      _allUsers = [];
    });
    if (_currentQuery.isNotEmpty) {
      _performSearch();
    }
  }

  void _openTopicResult(SearchPost searchPost) {
    final topic = searchPost.topic;
    if (topic == null) return;
    if (widget.embeddedMaster || SearchPage.canShowParallelFor(context)) {
      ref
          .read(_stackProvider.notifier)
          .select(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: searchPost.postNumber,
          );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          scrollToPostNumber: searchPost.postNumber,
        ),
      ),
    );
  }

  void _openUserResult(SearchUser user) {
    if (widget.embeddedMaster || SearchPage.canShowParallelFor(context)) {
      ref.read(_stackProvider.notifier).selectProfile(user.username);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfilePage(username: user.username),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = ref.watch(_stackProvider);
    final canShowParallel =
        widget.embeddedMaster || SearchPage.canShowParallelFor(context);

    final master = _buildSearchScaffold(theme);
    if (widget.embeddedMaster) return master;
    if (!canShowParallel) return master;

    return MasterDetailLayout(
      masterWidth: SearchPage.parallelMasterWidth,
      minDetailWidth: SearchPage.parallelMinDetailWidth,
      // 列表态与其他双栏页同语义:初始=masterWidth(440,结果卡片比首页
      // 话题卡宽一点),比例只在超大窗口放宽。旧参数(min 0.32/preferred
      // 0.4)让搜索初始就占四成屏宽,明显宽于其他页。
      maxMasterRatio: selected.isStacked ? 0.8 : 0.52,
      preferredMasterRatio: selected.isStacked ? 0.5 : null,
      // 胶片带:搜索列表也在带上,压栈被顶出左侧,倒二层格作预览。
      pinMaster: false,
      master: master,
      panes: [
        for (var i = 0; i < selected.stack.length; i++)
          KeyedSubtree(
            key: _cellKey(selected.stack[i]),
            child: _buildParallelPane(
              selected.stack[i],
              truncateOnPush: i < selected.stack.length - 1,
              // 回调内重读 provider:嵌入面板在注册 ESC 时会捕获这个闭包
              // 且不随宿主 rebuild 刷新,捕获 build 快照的 selected 会让
              // 后续按键用过期的 isStacked 判断 pop/clear。
              onBack: () {
                final notifier = ref.read(_stackProvider.notifier);
                if (ref.read(_stackProvider).isStacked) {
                  notifier.pop();
                } else {
                  notifier.clear();
                }
              },
            ),
          ),
      ],
      emptyDetail: MasterDetailEmptyState(
        icon: Symbols.preview_rounded,
        iconSize: 56,
        message: context.l10n.search_selectResultHint,
      ),
    );
  }

  Key _cellKey(PaneEntry entry) => ValueKey(
    'search_cell_${entry.kind}_'
    '${entry.instanceId ?? entry.username ?? entry.topicId}',
  );

  Widget _buildVscodeSearchScaffold(ThemeData theme, VscodeTokens tokens) {
    final canClose = widget.onClose != null || Navigator.of(context).canPop();
    return Theme(
      data: VscodeTheme.toolbarTheme(theme),
      child: Scaffold(
        backgroundColor: tokens.sidebar,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 6, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.common_search,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 12,
                          color: tokens.muted,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.common_refresh,
                      icon: const Icon(Icons.refresh, size: 17),
                      onPressed: _currentQuery.isEmpty || _isSearching
                          ? null
                          : () => _onFilterChanged(_filter),
                    ),
                    if (canClose)
                      IconButton(
                        tooltip: context.l10n.common_close,
                        icon: const Icon(Icons.close, size: 17),
                        onPressed:
                            widget.onClose ??
                            () => Navigator.of(context).maybePop(),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: TextField(
                  key: const ValueKey('vscode-search-input'),
                  controller: _searchController,
                  focusNode: _focusNode,
                  onSubmitted: _onSearch,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: context.l10n.common_search,
                    filled: true,
                    fillColor: tokens.background,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(2),
                      borderSide: BorderSide(color: tokens.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(2),
                      borderSide: BorderSide(color: tokens.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(2),
                      borderSide: BorderSide(color: tokens.accent),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minHeight: 30,
                      minWidth: 30,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            tooltip: context.l10n.common_clear,
                            icon: const Icon(Icons.close, size: 15),
                            onPressed: _clearSearch,
                          ),
                        IconButton(
                          tooltip: context.l10n.common_search,
                          icon: const Icon(Icons.keyboard_return, size: 17),
                          onPressed: () => _onSearch(_searchController.text),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('vscode-search-options'),
                onTap: () => setState(
                  () => _vscodeOptionsExpanded = !_vscodeOptionsExpanded,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _vscodeOptionsExpanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 16,
                        color: tokens.muted,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          context.l10n.search_advancedSearch,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                      ),
                      if (_filter.isNotEmpty)
                        Text(
                          '${_filter.activeFilterCount}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.accent,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_vscodeOptionsExpanded)
                _buildVscodeSearchOptions(theme, tokens),
              if (_filter.isNotEmpty) _buildVscodeActiveFilters(theme, tokens),
              if (_isSearching) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _currentQuery.isEmpty
                    ? _buildEmptyState(theme)
                    : _buildSearchResults(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVscodeSearchOptions(ThemeData theme, VscodeTokens tokens) {
    final settings = ref.watch(searchSettingsProvider);
    final aiEnabled =
        settings.aiSearchEnabled &&
        settings.sortOrder == SearchSortOrder.relevance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.search_hintText,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: tokens.muted,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              DropdownButton<SearchSortOrder>(
                value: settings.sortOrder,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.foreground,
                ),
                items: [
                  for (final order in SearchSortOrder.values)
                    DropdownMenuItem(value: order, child: Text(order.label)),
                ],
                onChanged: _onSortChanged,
              ),
              TextButton.icon(
                onPressed: _openFilterPanel,
                icon: const Icon(Icons.folder_open_outlined, size: 15),
                label: Text(context.l10n.search_currentFilter),
              ),
              if (_siteAiSearchAvailable)
                IconButton(
                  tooltip: 'AI',
                  isSelected: aiEnabled,
                  icon: _isSearchingAi
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      : const Icon(Icons.auto_awesome_outlined, size: 16),
                  onPressed: settings.sortOrder == SearchSortOrder.relevance
                      ? () => _onAiSearchChanged(!aiEnabled)
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVscodeActiveFilters(ThemeData theme, VscodeTokens tokens) {
    Widget entry(String label, VoidCallback remove) => TextButton(
      onPressed: remove,
      style: TextButton.styleFrom(
        foregroundColor: tokens.foreground,
        backgroundColor: tokens.background,
        side: BorderSide(color: tokens.border),
        shape: const RoundedRectangleBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        minimumSize: Size.zero,
        textStyle: theme.textTheme.bodySmall,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          const Icon(Icons.close, size: 12),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          if (_filter.categoryId != null)
            entry(
              '#${_filter.categoryName ?? _filter.categorySlug ?? _filter.categoryId}',
              _clearCategory,
            ),
          for (final tag in _filter.tags)
            entry('tags:$tag', () => _removeTag(tag)),
          if (_filter.status != null)
            entry(_filter.status!.label, _clearStatus),
          if (_filter.afterDate != null)
            entry(
              context.l10n.search_afterDate(
                TimeUtils.formatShortDate(_filter.afterDate),
              ),
              _clearDateRange,
            ),
          if (_filter.beforeDate != null)
            entry(
              context.l10n.search_beforeDate(
                TimeUtils.formatShortDate(_filter.beforeDate),
              ),
              _clearDateRange,
            ),
          entry(context.l10n.search_clearAll, _clearAllFilters),
        ],
      ),
    );
  }

  void _onAiSearchChanged(bool value) {
    ref.read(searchSettingsProvider.notifier).setAiSearchEnabled(value);
    setState(() {
      _rebuildDisplayPosts();
      if (value && _aiPosts.isEmpty && _currentQuery.isNotEmpty) {
        _triggerAiSearch(_stripOrderFromQuery(_currentQuery));
      }
    });
  }

  Widget _buildSearchScaffold(ThemeData theme) {
    final vscode = VscodeTokens.maybeOf(context);
    if (vscode != null) return _buildVscodeSearchScaffold(theme, vscode);
    final searchField = TextField(
      controller: _searchController,
      focusNode: _focusNode,
      onSubmitted: _onSearch,
      textInputAction: TextInputAction.search,
      textAlignVertical: TextAlignVertical.center,
      // 胶囊模式对齐首页胶囊 hint 的 14px（SearchCapsule 同参）
      style: widget.heroCapsule
          ? theme.textTheme.bodyMedium
          : theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        // 胶囊模式 hint 自绘（下方 Stack 覆盖层）：InputDecorator 的
        // hint 垂直对齐在定高容器里不可控（isDense 偏上 / isCollapsed
        // 偏下，均已翻车），不再依赖
        hintText: widget.heroCapsule ? null : context.l10n.search_hintText,
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: widget.heroCapsule ? 8 : 12,
        ),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Symbols.close_rounded, size: 20),
                onPressed: _clearSearch,
              )
            : null,
      ),
      onChanged: (value) {
        setState(() {});
      },
    );

    // Hero 入场：搜索框套胶囊容器（与首页胶囊同视觉），跨页 morph 的
    // 落点;flight 用静态胶囊（TextField 不参与飞行，避免光标闪烁）。
    // 40px 定高胶囊须钳制系统字体缩放（HyperOS 大字体档会撑破胶囊）
    final Widget titleField = widget.heroCapsule
        ? Hero(
            tag: kSearchCapsuleHeroTag,
            // 预测返回(user gesture)时胶囊也要 morph 回首页
            transitionOnUserGestures: true,
            flightShuttleBuilder: searchCapsuleFlightShuttle,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.2,
              child: Container(
                height: 40,
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                // Hero child 需要 Material 语境（飞行时脱离原位）。
                // hint 自绘覆盖层：普通 Text + Stack 居中对齐（与首页
                // 胶囊 hint 同布局方式），彻底绕开 InputDecorator 的
                // hint 垂直对齐黑盒
                child: Material(
                  type: MaterialType.transparency,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (_searchController.text.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: IgnorePointer(
                            child: Text(
                              context.l10n.search_hintText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      searchField,
                    ],
                  ),
                ),
              ),
            ),
          )
        : searchField;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: widget.onClose == null
            ? null
            : IconButton(
                tooltip: context.l10n.common_close,
                icon: const Icon(Symbols.close_rounded),
                onPressed: widget.onClose,
              ),
        titleSpacing: 0,
        title: titleField,
        actions: [
          IconButton(
            icon: const Icon(Symbols.search_rounded),
            onPressed: () => _onSearch(_searchController.text),
            tooltip: context.l10n.common_search,
          ),
          // 过滤器按钮
          Stack(
            children: [
              IconButton(
                icon: const Icon(Symbols.tune_rounded),
                onPressed: _openFilterPanel,
                tooltip: context.l10n.search_advancedSearch,
              ),
              if (_filter.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 已激活的过滤条件（始终显示，便于查看和取消）
          if (_filter.isNotEmpty)
            ActiveSearchFiltersBar(
              filter: _filter,
              onClearCategory: _clearCategory,
              onRemoveTag: _removeTag,
              onClearStatus: _clearStatus,
              onClearDateRange: _clearDateRange,
              onClearAll: _clearAllFilters,
            ),
          Expanded(
            child: _currentQuery.isEmpty
                ? _buildEmptyState(theme)
                : _buildSearchResults(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildParallelPane(
    PaneEntry entry, {
    VoidCallback? onBack,
    bool truncateOnPush = false,
  }) {
    switch (entry.kind) {
      case PaneKind.topic:
        return TopicDetailPage(
          key: ValueKey('search_topic_${entry.instanceId}'),
          topicId: entry.topicId!,
          instanceId: entry.instanceId,
          initialTitle: entry.initialTitle,
          scrollToPostNumber: entry.scrollToPostNumber,
          embeddedMode: true,
          truncateOnPush: truncateOnPush,
          onEmbeddedBack: onBack,
          parentActive: true,
          stackProvider: _stackProvider,
        );
      case PaneKind.profile:
        return EmbeddedStackScope(
          stackProvider: _stackProvider,
          truncateOnPush: truncateOnPush,
          child: UserProfilePage(
            key: ValueKey('search_profile_${entry.username}'),
            username: entry.username!,
            embeddedMode: true,
            onEmbeddedBack: onBack,
            parentActive: widget.parentActive,
          ),
        );
      case PaneKind.settings:
        return EmbeddedStackScope(
          stackProvider: _stackProvider,
          truncateOnPush: truncateOnPush,
          child: SettingsPage(
            embeddedMode: true,
            onEmbeddedBack: onBack,
            parentActive: widget.parentActive,
          ),
        );
    }
  }

  Widget _buildEmptyState(ThemeData theme) {
    // 正在加载最近搜索记录
    if (_isLoadingRecentSearches) {
      return const Center(child: LoadingSpinner());
    }

    final vscode = VscodeTokens.maybeOf(context);
    if (vscode != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          if (_recentSearches.isEmpty)
            Text(
              context.l10n.search_emptyHint,
              style: theme.textTheme.bodySmall?.copyWith(color: vscode.muted),
            )
          else ...[
            Row(
              children: [
                const Icon(Icons.expand_more, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    context.l10n.search_recentSearches,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.common_clear,
                  onPressed: _isClearingRecentSearches
                      ? null
                      : _clearRecentSearches,
                  icon: const Icon(Icons.delete_outline, size: 15),
                ),
              ],
            ),
            for (final query in _recentSearches)
              _buildRecentSearchItem(query, theme),
          ],
        ],
      );
    }

    // 有最近搜索记录时显示记录列表
    if (_recentSearches.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 最近搜索标题行
          if (theme.extension<MojianTokens>() != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 0, 8),
              child: MojianSectionLabel(
                context.l10n.search_recentSearches,
                trailing: TextButton(
                  onPressed: _isClearingRecentSearches
                      ? null
                      : _clearRecentSearches,
                  child: _isClearingRecentSearches
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      : Text(context.l10n.common_clear),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.l10n.search_recentSearches,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  GestureDetector(
                    onTap: _isClearingRecentSearches
                        ? null
                        : _clearRecentSearches,
                    child: _isClearingRecentSearches
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.primary,
                            ),
                          )
                        : Text(
                            context.l10n.common_clear,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          // 搜索记录列表
          ..._recentSearches.map(
            (query) => _buildRecentSearchItem(query, theme),
          ),
        ],
      );
    }

    // 默认空状态
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.search_rounded,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.search_emptyHint,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建最近搜索项
  Widget _buildRecentSearchItem(String query, ThemeData theme) {
    // 提取纯净查询
    final cleanQuery = _stripOrderFromQuery(query);
    final vscode = VscodeTokens.maybeOf(context);

    return InkWell(
      onTap: () {
        // 如果历史记录中有排序设置，恢复它
        final extractedOrder = _extractOrderFromQuery(query);
        if (extractedOrder != null) {
          ref
              .read(searchSettingsProvider.notifier)
              .setSortOrder(extractedOrder);
        }
        _searchController.text = cleanQuery;
        _onSearch(cleanQuery);
      },
      borderRadius: BorderRadius.circular(vscode == null ? 8 : 0),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: vscode == null ? 12 : 6,
          horizontal: 8,
        ),
        child: Row(
          children: [
            Icon(
              Symbols.history_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                query,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Symbols.north_west_rounded,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    final posts = _allPosts
        .where(
          (post) => !BlockedUserFilter.isBlockedUsername(
            post.username,
            blockedUsernames,
          ),
        )
        .toList(growable: false);
    final users = _allUsers
        .where(
          (user) => !BlockedUserFilter.isBlockedUsername(
            user.username,
            blockedUsernames,
          ),
        )
        .toList(growable: false);

    if (_hasError && posts.isEmpty) {
      return ErrorView(
        error: _searchError ?? Exception(context.l10n.search_error),
        stackTrace: _searchErrorStack,
        onRetry: _performSearch,
      );
    }

    if (posts.isEmpty && users.isEmpty && !_isLoadingMore) {
      // 只有原始结果也为空才可能是首页请求仍在途；
      // 原始结果非空但过滤后为空 = 全部被本地屏蔽，必须显示空态而非转圈
      if (_currentPage == 1 &&
          _allPosts.isEmpty &&
          _allUsers.isEmpty &&
          (VscodeTokens.maybeOf(context) == null || _isSearching)) {
        return VscodeTokens.maybeOf(context) == null
            ? const SearchListSkeleton()
            : const SizedBox.shrink();
      }
      return _buildNoResults();
    }

    if (VscodeTokens.maybeOf(context) != null) {
      final hasMore = _hasMorePosts || _hasMoreUsers;
      return VscodeSearchResults(
        key: ValueKey((
          _currentQuery,
          _filter,
          ref.watch(searchSettingsProvider).sortOrder,
        )),
        posts: posts,
        users: users,
        scrollController: _scrollController,
        hasMorePosts: _hasMorePosts,
        onOpenPost: _openTopicResult,
        onOpenUser: _openUserResult,
        onPreviewPost: ref.watch(preferencesProvider).longPressPreview
            ? (post, anchorContext) => SearchPreviewDialog.show(
                context,
                post: post,
                onOpen: () => _openTopicResult(post),
                sourceContext: anchorContext,
              )
            : null,
        footer: Column(
          children: [
            PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: _isLoadingMore,
              isLoadMoreFailed: _isLoadMoreFailed,
              onRetry: () {
                _loadMoreCoordinator.resetCooldown();
                setState(() => _isLoadMoreFailed = false);
                _loadMore();
              },
            ),
            // 收起后的树可能不足一屏，仍需保留主动翻页入口。
            if (hasMore && !_isLoadingMore && !_isLoadMoreFailed)
              TextButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.expand_more, size: 16),
                label: Text(context.l10n.common_searchMore),
              ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 排序选项
        if (posts.isNotEmpty || users.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  context.l10n.search_sortLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<SearchSortOrder>(
                  value: ref.watch(searchSettingsProvider).sortOrder,
                  isDense: true,
                  underline: const SizedBox(),
                  items: SearchSortOrder.values.map((order) {
                    return DropdownMenuItem(
                      value: order,
                      child: Text(order.label),
                    );
                  }).toList(),
                  onChanged: _onSortChanged,
                ),
                const Spacer(),
                // AI 搜索开关（仅当站点支持时显示）
                if (_siteAiSearchAvailable) ...[
                  if (_isSearchingAi)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.tertiary,
                        ),
                      ),
                    ),
                  Icon(
                    Symbols.auto_awesome_rounded,
                    size: 16,
                    color:
                        ref.watch(searchSettingsProvider).sortOrder ==
                            SearchSortOrder.relevance
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.outline,
                  ),
                  SizedBox(
                    height: 32,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Switch(
                        value:
                            ref.watch(searchSettingsProvider).aiSearchEnabled &&
                            ref.watch(searchSettingsProvider).sortOrder ==
                                SearchSortOrder.relevance,
                        onChanged:
                            ref.watch(searchSettingsProvider).sortOrder ==
                                SearchSortOrder.relevance
                            ? _onAiSearchChanged
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  context.l10n.search_resultCount(
                    posts.length,
                    _hasMorePosts ? '+' : '',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: SearchPostPrewarmScope(
            posts: posts,
            child: ListView.builder(
              controller: _scrollController,
              addAutomaticKeepAlives: false,
              padding: const EdgeInsets.all(16),
              itemCount:
                  posts.length + (users.isNotEmpty ? users.length + 1 : 0) + 1,
              itemBuilder: (context, index) {
                // 帖子结果（标准 + AI 混合）
                if (index < posts.length) {
                  final searchPost = posts[index];
                  final enableLongPress = ref
                      .watch(preferencesProvider)
                      .longPressPreview;

                  return SearchPostCard(
                    post: searchPost,
                    onTap: () => _openTopicResult(searchPost),
                    onLongPress: enableLongPress
                        ? (cardContext) => SearchPreviewDialog.show(
                            context,
                            post: searchPost,
                            onOpen: () => _openTopicResult(searchPost),
                            sourceContext: cardContext,
                          )
                        : null,
                  );
                }

                // 用户标题
                final userStartIndex = posts.length;
                if (users.isNotEmpty && index == userStartIndex) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: _buildSectionHeader(
                      context.l10n.search_users,
                      users.length,
                      _hasMoreUsers,
                    ),
                  );
                }

                // 用户结果
                if (users.isNotEmpty && index > userStartIndex) {
                  final userIndex = index - userStartIndex - 1;
                  if (userIndex < users.length) {
                    return _SearchUserCard(
                      user: users[userIndex],
                      onTap: () => _openUserResult(users[userIndex]),
                    );
                  }
                }

                return PagedListFooter(
                  hasMore: _hasMorePosts,
                  isLoadingMore:
                      _loadMoreCoordinator.isRunning && _isLoadingMore,
                  isLoadMoreFailed: _isLoadMoreFailed,
                  onRetry: () {
                    _loadMoreCoordinator.resetCooldown();
                    setState(() => _isLoadMoreFailed = false);
                    _loadMore();
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoResults() {
    final theme = Theme.of(context);
    final vscode = VscodeTokens.maybeOf(context);
    if (vscode != null) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            context.l10n.search_noResults,
            style: theme.textTheme.bodySmall?.copyWith(
              color: vscode.foreground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.search_tryOtherKeywords,
            style: theme.textTheme.bodySmall?.copyWith(color: vscode.muted),
          ),
        ],
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.search_off_rounded,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.search_noResults,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.search_tryOtherKeywords,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, bool hasMore) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    if (mj != null) {
      return MojianSectionLabel(
        title,
        trailing: Text(
          hasMore ? '$count+' : '$count',
          style: TextStyle(fontSize: 12, color: mj.ink3),
        ),
      );
    }
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          hasMore ? '$count+' : '$count',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

/// 搜索结果用户卡片
class _SearchUserCard extends StatelessWidget {
  final SearchUser user;
  final VoidCallback? onTap;

  const _SearchUserCard({required this.user, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final content = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SmartAvatar(
              imageUrl: user.getAvatarUrl().isNotEmpty
                  ? user.getAvatarUrl(size: 80)
                  : null,
              radius: 20,
              fallbackText: user.username,
              backgroundColor: theme.colorScheme.secondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.username,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (user.name != null && user.name!.isNotEmpty)
                    Text(
                      user.name!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Symbols.chevron_right_rounded,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
    // 墨笺:平铺行 + 发丝线分隔,不要卡片
    if (mj != null) {
      return DecoratedBox(
        decoration: mojianCardDecoration(theme, isSelected: false)!,
        child: content,
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
