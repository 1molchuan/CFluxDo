import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/cdk_project.dart';
import '../../models/cdk_user_info.dart';
import '../../providers/cdk_providers.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/layout/master_detail_layout.dart';
import '../webview_page.dart';
import 'cdk_project_page.dart';
import 'cdk_widgets.dart';

/// LINUX DO CDK 原生首页：积分 + 领取记录（可搜索、逐条复制）。
///
/// 以前点 CDK 卡片是用内置浏览器打开 cdk.linux.do/dashboard，佬友反馈要开梯子；
/// 现在走原生接口，网页只留右上角的兜底入口。
class CdkHomePage extends StatelessWidget {
  const CdkHomePage({super.key});

  static const String dashboardUrl = 'https://cdk.linux.do/dashboard';

  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CdkHomePage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LINUX DO CDK'),
        actions: [
          IconButton(
            tooltip: S.current.cdkPage_openInBrowser,
            icon: const Icon(Symbols.open_in_browser_rounded),
            onPressed: () =>
                WebViewPage.open(context, dashboardUrl, title: 'LINUX DO CDK'),
          ),
        ],
      ),
      body: CdkSessionGate(
        builder: (context, user) => _ReceivedHistoryView(user: user),
      ),
    );
  }
}

class _ReceivedHistoryView extends ConsumerStatefulWidget {
  const _ReceivedHistoryView({required this.user});

  final CdkUserInfo user;

  @override
  ConsumerState<_ReceivedHistoryView> createState() =>
      _ReceivedHistoryViewState();
}

class _ReceivedHistoryViewState extends ConsumerState<_ReceivedHistoryView> {
  static const _pageSize = 20;

  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  final List<CdkReceivedItem> _items = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  StackTrace? _errorStack;
  String _query = '';
  int _generation = 0;

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _loading || !_hasMore) return;
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _reload({bool showSpinner = true}) async {
    final generation = ++_generation;
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(cdkApiServiceProvider)
          .receivedHistory(page: 1, size: _pageSize, search: _query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _page = 1;
        _loading = false;
      });
    } catch (e, st) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _errorStack = st;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(cdkApiServiceProvider)
          .receivedHistory(page: _page + 1, size: _pageSize, search: _query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _page++;
      });
    } catch (_) {
      // 翻页失败不打断已有列表，滚到底会再试
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      final q = value.trim();
      if (q == _query) return;
      _query = q;
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return M3eRefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          _reload(showSpinner: false),
          ref.read(cdkUserInfoProvider.notifier).refresh(),
        ]);
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            sliver: SliverToBoxAdapter(child: _UserHeader(user: widget.user)),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverToBoxAdapter(child: _buildSearchField(context)),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                _total > 0
                    ? S.current.cdkPage_receivedCount(_total)
                    : S.current.cdkPage_received,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          ..._buildList(context),
          SliverToBoxAdapter(child: SizedBox(height: 24 + bottom)),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: S.current.cdkPage_searchHint,
        prefixIcon: const Icon(Symbols.search_rounded, size: 20),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Symbols.close_rounded, size: 18),
                onPressed: () {
                  _searchController.clear();
                  _onSearchChanged('');
                  setState(() {});
                },
              ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
    );
  }

  List<Widget> _buildList(BuildContext context) {
    if (_loading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: LoadingSpinner()),
          ),
        ),
      ];
    }
    final error = _error;
    if (error != null) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: ErrorView(
              error: error,
              stackTrace: _errorStack,
              onRetry: _reload,
            ),
          ),
        ),
      ];
    }
    if (_items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 48),
            child: MasterDetailEmptyState(
              icon: Symbols.redeem_rounded,
              message: _query.isEmpty
                  ? S.current.cdkPage_receivedEmpty
                  : S.current.cdkPage_noMatches,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: _items.length + (_hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index >= _items.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: LoadingSpinner(size: 24)),
              );
            }
            return _ReceivedTile(item: _items[index]);
          },
        ),
      ),
    ];
  }
}

class _UserHeader extends StatelessWidget {
  const _UserHeader({required this.user});

  final CdkUserInfo user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final subtle = mj?.ink3 ?? theme.colorScheme.onSurfaceVariant;
    final name = user.nickname.isNotEmpty ? user.nickname : user.username;
    return CdkSurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SmartAvatar(
              imageUrl: user.avatarUrl,
              radius: 22,
              fallbackText: user.username,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@${user.username} · ${S.current.cdkPage_trustLevel(user.trustLevel)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${user.score}',
                  style: mj != null
                      ? TextStyle(
                          fontFamily: MojianTokens.titleFamilyFor(context),
                          fontSize: 26,
                          color: mj.ink,
                        )
                      : theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                ),
                Text(
                  S.current.cdk_points,
                  style: theme.textTheme.labelSmall?.copyWith(color: subtle),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceivedTile extends StatelessWidget {
  const _ReceivedTile({required this.item});

  final CdkReceivedItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtle =
        theme.extension<MojianTokens>()?.ink3 ??
        theme.colorScheme.onSurfaceVariant;
    final creator = item.creatorNickname.isNotEmpty
        ? item.creatorNickname
        : item.creatorUsername;
    final receivedAt = item.receivedAt;
    return CdkSurfaceCard(
      onTap: item.projectId.isEmpty
          ? null
          : () => CdkProjectPage.open(context, item.projectId),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.projectName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (creator.isNotEmpty) creator,
                if (receivedAt != null) TimeUtils.formatDetailTime(receivedAt),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: subtle),
            ),
            if (item.content.isNotEmpty) ...[
              const SizedBox(height: 8),
              CdkContentBox(content: item.content, maxLines: 4),
            ],
          ],
        ),
      ),
    );
  }
}
