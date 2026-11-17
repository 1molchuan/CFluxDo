import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_models.dart';
import '../../services/ld_store/ld_store_service.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/layout/master_detail_layout.dart';
import 'ld_store_common.dart';
import 'ld_store_order_page.dart';

/// 「我的订单」的筛选（与商城网页一致，另加「待付款」）。
enum LdShopOrderTab {
  all(''),
  pending('pending'),
  paid('paid'),
  cancelled('cancelled'),
  refund('refund_pending,refunded,refund_failed');

  const LdShopOrderTab(this.status);

  /// 传给接口的 status（逗号分隔多值）
  final String status;
}

/// 我的订单（买家）：按状态分 tab，每个 tab 下拉刷新、无限滚动。
class LdStoreOrdersPage extends ConsumerWidget {
  const LdStoreOrdersPage({super.key, this.initialTab = LdShopOrderTab.all});

  final LdShopOrderTab initialTab;

  static Future<void> open(
    BuildContext context, {
    LdShopOrderTab tab = LdShopOrderTab.all,
  }) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => LdStoreOrdersPage(initialTab: tab)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.l10n;
    final labels = {
      LdShopOrderTab.all: t.common_all,
      LdShopOrderTab.pending: t.ldShop_tabPending,
      LdShopOrderTab.paid: t.ldShop_tabPaid,
      LdShopOrderTab.cancelled: t.ldShop_tabCancelled,
      LdShopOrderTab.refund: t.ldShop_tabRefund,
    };
    return DefaultTabController(
      length: LdShopOrderTab.values.length,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.ldShop_myOrders),
          actions: [
            IconButton(
              tooltip: t.ldShop_openInBrowser,
              icon: const Icon(Symbols.open_in_browser_rounded),
              onPressed: () => openLdStoreInBrowser(context, '/user/orders'),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final tab in LdShopOrderTab.values) Tab(text: labels[tab]),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final tab in LdShopOrderTab.values) _OrderList(tab: tab),
          ],
        ),
      ),
    );
  }
}

class _OrderList extends ConsumerStatefulWidget {
  const _OrderList({required this.tab});

  final LdShopOrderTab tab;

  @override
  ConsumerState<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends ConsumerState<_OrderList>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  final List<LdShopOrder> _orders = [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _needsAuth = false;
  Object? _error;
  StackTrace? _errorStack;
  Object? _loadMoreError;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<LdStoreToken?> _token() =>
      ref.read(ldStoreSessionProvider.notifier).currentToken();

  Future<void> _reload({bool showSpinner = true}) async {
    final generation = ++_generation;
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
      _errorStack = null;
      _loadMoreError = null;
    });
    try {
      final token = await _token();
      if (token == null) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _needsAuth = true;
          _loading = false;
        });
        return;
      }
      final result = await ref
          .read(ldShopServiceProvider)
          .fetchOrders(
            token: token,
            status: widget.tab.status,
            pageSize: _pageSize,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _needsAuth = false;
        _orders
          ..clear()
          ..addAll(result.orders);
        _page = result.pagination.page;
        _hasMore = result.pagination.hasMore;
        _loading = false;
      });
    } catch (e, s) {
      if (!mounted || generation != _generation) return;
      final expired = handleLdStoreAuthError(context, e);
      setState(() {
        _needsAuth = expired;
        _error = expired ? null : e;
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
      final token = await _token();
      if (token == null) throw const LdStoreAuthExpiredException();
      final result = await ref
          .read(ldShopServiceProvider)
          .fetchOrders(
            token: token,
            status: widget.tab.status,
            page: _page + 1,
            pageSize: _pageSize,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        final seen = {for (final o in _orders) o.orderNo};
        _orders.addAll(result.orders.where((o) => seen.add(o.orderNo)));
        _page = result.pagination.page;
        _hasMore = result.pagination.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      final expired = handleLdStoreAuthError(context, e);
      setState(() {
        _needsAuth = expired;
        _loadMoreError = expired ? null : e;
        _loadingMore = false;
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadMoreError != null) return;
    if (_scrollController.position.extentAfter < 600) _loadMore();
  }

  Future<void> _openOrder(LdShopOrder order) async {
    await LdStoreOrderPage.open(context, order.orderNo);
    // 在详情里付了款 / 取消了：列表跟上
    if (mounted) _reload(showSpinner: false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    if (_loading) return const Center(child: LoadingSpinner());
    if (_needsAuth) {
      return LdShopAuthRequiredView(onAuthorized: _reload);
    }
    if (_error != null) {
      return ErrorView(
        error: _error!,
        stackTrace: _errorStack,
        onRetry: _reload,
      );
    }
    if (_orders.isEmpty) {
      return M3eRefreshIndicator(
        onRefresh: () => _reload(showSpinner: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: MasterDetailEmptyState(
                icon: Symbols.receipt_long_rounded,
                message: context.l10n.ldShop_noOrders,
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
          12,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _orders.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == _orders.length) return _buildFooter(theme);
          final order = _orders[index];
          return LdShopOrderTile(order: order, onTap: () => _openOrder(order));
        },
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
}

/// 订单列表的一行：商品图、名称、数量与金额、时间、状态。
class LdShopOrderTile extends StatelessWidget {
  const LdShopOrderTile({super.key, required this.order, required this.onTap});

  final LdShopOrder order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final subtle = ldShopSubtle(theme);
    final status = ldShopOrderStatusLabel(order);
    final statusColor = ldShopStatusColor(theme, order.displayStatus);
    final deadline = order.isPending ? order.paymentDeadline : null;
    return LdShopSurface(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LdShopImage(
            url: order.productImage,
            width: 56,
            height: 56,
            borderRadius: mj != null ? 4 : 10,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        order.productName ?? order.orderNo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: mj?.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    LdShopTag(label: status, color: statusColor, filled: true),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      '×${order.quantity}',
                      style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                    ),
                    const Spacer(),
                    Text(
                      ldShopAmount(order.amount),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (order.createdAt != null)
                      TimeUtils.formatDetailTime(order.createdAt),
                    if (order.sellerUsername != null)
                      '@${order.sellerUsername}',
                    if (deadline != null)
                      context.l10n.ldShop_payBefore(
                        TimeUtils.formatCompactTime(deadline),
                      ),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: subtle),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
