import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../services/ld_store/ld_store_shop_service.dart';
import '../../theme/mojian_theme.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/layout/master_detail_layout.dart';
import 'ld_store_common.dart';
import 'ld_store_coupons_page.dart';
import 'ld_store_orders_page.dart';
import 'ld_store_product_page.dart';

/// LD士多首页：搜索、分类、排序、只看有货，商品双列卡片，无限滚动。
///
/// 浏览是匿名的；右上角「我的订单」「优惠券」要授权，没授权时先走授权。
class LdStoreHomePage extends ConsumerStatefulWidget {
  const LdStoreHomePage({super.key, this.initialQuery, this.initialCategoryId});

  final String? initialQuery;
  final String? initialCategoryId;

  static Future<void> open(
    BuildContext context, {
    String? query,
    String? categoryId,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          LdStoreHomePage(initialQuery: query, initialCategoryId: categoryId),
    ),
  );

  @override
  ConsumerState<LdStoreHomePage> createState() => _LdStoreHomePageState();
}

class _LdStoreHomePageState extends ConsumerState<LdStoreHomePage> {
  static const _pageSize = 20;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _searchDebounce;

  String _query = '';
  String? _categoryId;
  LdShopSort _sort = LdShopSort.defaults;
  bool _inStockOnly = false;

  final List<LdShopProduct> _products = [];
  int _page = 0;
  int _total = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  StackTrace? _errorStack;
  Object? _loadMoreError;

  /// 条件变了就作废进行中的请求
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery?.trim() ?? '';
    _searchController.text = _query;
    _categoryId = widget.initialCategoryId;
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

  LdShopService get _service => ref.read(ldShopServiceProvider);

  Future<void> _reload({bool showSpinner = true}) async {
    final generation = ++_generation;
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
      _errorStack = null;
      _loadMoreError = null;
    });
    try {
      final result = await _service.fetchProducts(
        page: 1,
        pageSize: _pageSize,
        categoryId: _categoryId,
        search: _query,
        sort: _sort,
        inStockOnly: _inStockOnly,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _products
          ..clear()
          ..addAll(result.products);
        _page = result.pagination.page;
        _total = result.pagination.total;
        _hasMore = result.pagination.hasMore;
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
      final result = await _service.fetchProducts(
        page: _page + 1,
        pageSize: _pageSize,
        categoryId: _categoryId,
        search: _query,
        sort: _sort,
        inStockOnly: _inStockOnly,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        // 翻页期间排序变动，同一件商品可能在两页里各出现一次
        final seen = {for (final p in _products) p.id};
        _products.addAll(result.products.where((p) => seen.add(p.id)));
        _page = result.pagination.page;
        _total = result.pagination.total;
        _hasMore = result.pagination.hasMore;
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

  Future<void> _refresh() async {
    if (ref.read(ldShopCategoriesProvider).hasError) {
      ref.invalidate(ldShopCategoriesProvider);
    }
    await _reload(showSpinner: false);
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadMoreError != null) return;
    if (_scrollController.position.extentAfter < 600) _loadMore();
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

  void _selectCategory(String? id) {
    if (id == _categoryId) return;
    _categoryId = id;
    _restart();
  }

  void _changeSort(LdShopSort sort) {
    if (sort == _sort) return;
    _sort = sort;
    _restart();
  }

  void _toggleInStock() {
    _inStockOnly = !_inStockOnly;
    _restart();
  }

  void _restart() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _reload();
  }

  Future<void> _openOrders() async {
    final token = await ensureLdStoreToken(context);
    if (token == null || !mounted) return;
    await LdStoreOrdersPage.open(context);
  }

  Future<void> _openCoupons() async {
    final token = await ensureLdStoreToken(context);
    if (token == null || !mounted) return;
    await LdStoreCouponsPage.open(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.ldStore_title),
        actions: [
          IconButton(
            tooltip: context.l10n.ldShop_myOrders,
            icon: const Icon(Symbols.receipt_long_rounded),
            onPressed: _openOrders,
          ),
          IconButton(
            tooltip: context.l10n.ldShop_myCoupons,
            icon: const Icon(Symbols.confirmation_number_rounded),
            onPressed: _openCoupons,
          ),
          PopupMenuButton<void>(
            tooltip: context.l10n.common_more,
            icon: const Icon(Symbols.more_vert_rounded),
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                onTap: () => openLdStoreInBrowser(this.context),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Symbols.open_in_browser_rounded),
                  title: Text(context.l10n.ldShop_openInBrowser),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilters(theme),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildFilters(ThemeData theme) {
    final mj = theme.extension<MojianTokens>();
    final radius = BorderRadius.circular(mj != null ? 6 : 24);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color),
    );
    final categories = ref.watch(ldShopCategoriesProvider).value ?? const [];
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
                hintText: context.l10n.ldShop_searchHint,
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              ChoiceChip(
                label: Text(context.l10n.common_all),
                selected: _categoryId == null,
                onSelected: (_) => _selectCategory(null),
              ),
              for (final category in categories) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(
                    category.icon == null
                        ? category.name
                        : '${category.icon} ${category.name}',
                  ),
                  selected: _categoryId == category.id,
                  onSelected: (_) => _selectCategory(category.id),
                ),
              ],
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              PopupMenuButton<LdShopSort>(
                tooltip: context.l10n.ldShop_sort,
                initialValue: _sort,
                onSelected: _changeSort,
                itemBuilder: (context) => [
                  for (final sort in LdShopSort.values)
                    CheckedPopupMenuItem<LdShopSort>(
                      value: sort,
                      checked: sort == _sort,
                      child: Text(_sortLabel(sort)),
                    ),
                ],
                child: IgnorePointer(
                  child: InputChip(
                    avatar: const Icon(Symbols.sort_rounded, size: 18),
                    label: Text(_sortLabel(_sort)),
                    deleteIcon: const Icon(
                      Symbols.arrow_drop_down_rounded,
                      size: 18,
                    ),
                    onDeleted: () {},
                    onPressed: () {},
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: Text(context.l10n.ldShop_inStockOnly),
                selected: _inStockOnly,
                onSelected: (_) => _toggleInStock(),
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
    if (_products.isEmpty) {
      return M3eRefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: MasterDetailEmptyState(
                  icon: Symbols.local_mall_rounded,
                  message:
                      _query.isNotEmpty || _inStockOnly || _categoryId != null
                      ? context.l10n.ldShop_noMatches
                      : context.l10n.ldShop_empty,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final bottom = MediaQuery.paddingOf(context).bottom;
    return M3eRefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 12.0;
          const horizontal = 16.0;
          final width = constraints.maxWidth - horizontal * 2;
          final columns = (width / 220).floor().clamp(2, 6);
          final tileWidth = (width - spacing * (columns - 1)) / columns;
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final tileHeight = tileWidth * 0.75 + 116 * textScale;
          return CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    context.l10n.ldShop_productCount(_total),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ldShopSubtle(theme),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: horizontal),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: tileHeight,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final product = _products[index];
                    return LdShopProductCard(
                      product: product,
                      onTap: () => LdStoreProductPage.open(
                        context,
                        product.id,
                        initial: product,
                      ),
                    );
                  }, childCount: _products.length),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + bottom),
                sliver: SliverToBoxAdapter(child: _buildFooter(theme)),
              ),
            ],
          );
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

  String _sortLabel(LdShopSort sort) => switch (sort) {
    LdShopSort.defaults => context.l10n.ldShop_sortDefault,
    LdShopSort.newest => context.l10n.ldShop_sortNewest,
    LdShopSort.priceAsc => context.l10n.ldShop_sortPriceAsc,
    LdShopSort.priceDesc => context.l10n.ldShop_sortPriceDesc,
    LdShopSort.sales => context.l10n.ldShop_sortSales,
  };
}

/// 商品卡片：图、名、现价 / 原价、库存 / 已售、卖家。
class LdShopProductCard extends StatelessWidget {
  const LdShopProductCard({
    super.key,
    required this.product,
    required this.onTap,
  });

  final LdShopProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final subtle = ldShopSubtle(theme);
    final meta = theme.textTheme.labelSmall?.copyWith(color: subtle);
    final stock = ldShopStockLabel(product);
    final metaText = [
      if (stock.isNotEmpty) stock,
      if (product.type.isPlatformOrder)
        context.l10n.ldShop_sold(product.soldCount)
      else
        ldShopProductTypeLabel(product.type),
    ].join(' · ');
    final seller = product.sellerName ?? product.sellerUsername;

    return LdShopSurface(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 按格子尺寸解码，免得每张图都按整屏宽度解
                LayoutBuilder(
                  builder: (context, constraints) => LdShopImage(
                    url: product.imageUrl,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                  ),
                ),
                if (product.isOutOfStock)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.45),
                    child: Center(
                      child: Text(
                        context.l10n.ldShop_soldOut,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (product.hasDiscount)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: ldShopAccent(theme),
                        borderRadius: BorderRadius.circular(mj != null ? 3 : 6),
                      ),
                      child: Text(
                        ldShopDiscountLabel(product.discount),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: mj?.paper ?? theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: mj?.ink,
                      height: 1.3,
                    ),
                  ),
                  const Spacer(),
                  LdShopPriceText(
                    price: product.finalPrice,
                    original: product.hasDiscount ? product.price : null,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    metaText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                  if (seller != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        SmartAvatar(
                          imageUrl: product.sellerAvatar,
                          radius: 8,
                          fallbackText: product.sellerUsername ?? seller,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            seller,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: meta,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
