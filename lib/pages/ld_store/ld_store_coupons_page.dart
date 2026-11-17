import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_service.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/layout/master_detail_layout.dart';
import 'ld_store_common.dart';
import 'ld_store_order_page.dart';
import 'ld_store_product_page.dart';

enum LdShopCouponTab {
  unused('unused'),
  used('used'),
  expired('expired');

  const LdShopCouponTab(this.status);

  final String status;
}

/// 我的优惠券：未使用 / 已使用 / 已过期。领券走卖家分享的网页链接，这里只看。
class LdStoreCouponsPage extends StatelessWidget {
  const LdStoreCouponsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LdStoreCouponsPage()));

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final labels = {
      LdShopCouponTab.unused: t.ldShop_couponUnused,
      LdShopCouponTab.used: t.ldShop_couponUsed,
      LdShopCouponTab.expired: t.ldShop_couponExpired,
    };
    return DefaultTabController(
      length: LdShopCouponTab.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.ldShop_myCoupons),
          bottom: TabBar(
            tabs: [
              for (final tab in LdShopCouponTab.values) Tab(text: labels[tab]),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final tab in LdShopCouponTab.values) _CouponList(tab: tab),
          ],
        ),
      ),
    );
  }
}

class _CouponList extends ConsumerStatefulWidget {
  const _CouponList({required this.tab});

  final LdShopCouponTab tab;

  @override
  ConsumerState<_CouponList> createState() => _CouponListState();
}

class _CouponListState extends ConsumerState<_CouponList>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  final List<LdShopCoupon> _items = [];
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

  Future<void> _reload({bool showSpinner = true}) async {
    final generation = ++_generation;
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
      _loadMoreError = null;
    });
    try {
      final token = await ref
          .read(ldStoreSessionProvider.notifier)
          .currentToken();
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
          .fetchMyCoupons(
            token: token,
            status: widget.tab.status,
            pageSize: _pageSize,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _needsAuth = false;
        _items
          ..clear()
          ..addAll(result.items);
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
      final token = await ref
          .read(ldStoreSessionProvider.notifier)
          .currentToken();
      if (token == null) throw const LdStoreAuthExpiredException();
      final result = await ref
          .read(ldShopServiceProvider)
          .fetchMyCoupons(
            token: token,
            status: widget.tab.status,
            page: _page + 1,
            pageSize: _pageSize,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        final seen = {for (final c in _items) c.claimId};
        _items.addAll(result.items.where((c) => seen.add(c.claimId)));
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: LoadingSpinner());
    if (_needsAuth) return LdShopAuthRequiredView(onAuthorized: _reload);
    if (_error != null) {
      return ErrorView(
        error: _error!,
        stackTrace: _errorStack,
        onRetry: _reload,
      );
    }
    if (_items.isEmpty) {
      return M3eRefreshIndicator(
        onRefresh: () => _reload(showSpinner: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: MasterDetailEmptyState(
                  icon: Symbols.confirmation_number_rounded,
                  message: widget.tab == LdShopCouponTab.unused
                      ? context.l10n.ldShop_noCouponsUnused
                      : context.l10n.ldShop_noCoupons,
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
          12,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == _items.length) {
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
            return const SizedBox(height: 24);
          }
          return _CouponTile(coupon: _items[index], tab: widget.tab);
        },
      ),
    );
  }
}

class _CouponTile extends StatelessWidget {
  const _CouponTile({required this.coupon, required this.tab});

  final LdShopCoupon coupon;
  final LdShopCouponTab tab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.l10n;
    final mj = theme.extension<MojianTokens>();
    final subtle = ldShopSubtle(theme);
    final campaign = coupon.campaign;
    final scheduled =
        campaign.startsAt != null && campaign.startsAt!.isAfter(DateTime.now());
    final dimmed = tab != LdShopCouponTab.unused;
    final accent = dimmed ? subtle : ldShopAccent(theme);

    String? stateBadge;
    if (coupon.isReserved) {
      stateBadge = t.ldShop_couponReserved;
    } else if (scheduled) {
      stateBadge = t.ldShop_couponScheduled;
    }

    final meta = <(String, String)>[
      (
        t.ldShop_couponThreshold,
        campaign.minSpend > 0
            ? t.ldShop_couponMinSpend(ldShopPrice(campaign.minSpend))
            : t.ldShop_couponNoThreshold,
      ),
      if (tab == LdShopCouponTab.used)
        (t.ldShop_couponUsedAt, TimeUtils.formatDetailTime(coupon.usedAt))
      else if (campaign.expiresAt != null)
        (
          t.ldShop_couponValidUntil,
          TimeUtils.formatDetailTime(campaign.expiresAt),
        ),
      if (tab == LdShopCouponTab.used)
        (
          t.ldShop_couponActualDiscount,
          ldShopAmount(coupon.actualDiscountAmount),
        ),
      if (tab == LdShopCouponTab.expired)
        (
          t.ldShop_couponInvalidReason,
          coupon.invalidReason ?? t.ldShop_couponExpired,
        ),
    ];

    final orderNo = coupon.isReserved
        ? coupon.reservedOrderNo
        : (tab == LdShopCouponTab.used ? coupon.usedOrderNo : null);
    final productId = campaign.scopeIsProduct ? campaign.productId : null;

    Widget? action;
    if (orderNo != null) {
      action = TextButton(
        onPressed: () => LdStoreOrderPage.open(context, orderNo),
        child: Text(
          coupon.isReserved ? t.ldShop_viewReservedOrder : t.ldShop_viewOrder,
        ),
      );
    } else if (tab == LdShopCouponTab.unused && productId != null) {
      action = FilledButton.tonal(
        onPressed: () => LdStoreProductPage.open(context, productId),
        child: Text(t.ldShop_useCoupon),
      );
    }

    return LdShopSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LdShopTag(
                label: campaign.scopeIsProduct
                    ? t.ldShop_couponProductScope
                    : t.ldShop_couponShopScope,
                color: accent,
              ),
              if (stateBadge != null) ...[
                const SizedBox(width: 6),
                LdShopTag(
                  label: stateBadge,
                  color: mj?.gold ?? Colors.orange.shade700,
                  filled: true,
                ),
              ],
              const Spacer(),
              Text(
                ldShopCouponRule(campaign),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            campaign.name.isEmpty ? t.ldShop_couponGeneric : campaign.name,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: dimmed ? subtle : mj?.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              ?campaign.sellerUsername,
              campaign.scopeIsProduct
                  ? (campaign.productName ?? t.ldShop_couponProductScope)
                  : t.ldShop_couponShopProducts,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: subtle),
          ),
          const SizedBox(height: 8),
          for (final (label, value) in meta)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: subtle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(value, style: theme.textTheme.labelSmall),
                  ),
                ],
              ),
            ),
          if (action != null)
            Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }
}
