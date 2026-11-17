import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/core_providers.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_description.dart';
import '../../services/ld_store/ld_store_models.dart';
import '../../services/ld_store/ld_store_service.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/link_launcher.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/common/smart_avatar.dart';
import '../user_profile_page.dart';
import 'ld_store_checkout_sheet.dart';
import 'ld_store_common.dart';
import 'ld_store_order_page.dart';

/// 商品详情：大图、价格、库存 / 已售、类型、卖家、限购与信任等级、描述。
/// 底部「立即购买」打开确认弹层；外链 / 小店类商品是「前往」。
class LdStoreProductPage extends ConsumerStatefulWidget {
  const LdStoreProductPage({super.key, required this.productId, this.initial});

  final String productId;

  /// 列表里已有的数据，先显示着
  final LdShopProduct? initial;

  static Future<void> open(
    BuildContext context,
    String productId, {
    LdShopProduct? initial,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          LdStoreProductPage(productId: productId, initial: initial),
    ),
  );

  @override
  ConsumerState<LdStoreProductPage> createState() => _LdStoreProductPageState();
}

class _LdStoreProductPageState extends ConsumerState<LdStoreProductPage> {
  LdShopProduct? _product;

  /// 详情（带 description、canPurchase）读到了没有
  bool _detailLoaded = false;
  bool _loading = true;
  Object? _error;
  StackTrace? _errorStack;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _product = widget.initial;
    _load();
  }

  Future<LdStoreToken?> _token() =>
      ref.read(ldStoreSessionProvider.notifier).currentToken();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(ldShopServiceProvider);
      final token = await _token();
      LdShopProduct product;
      try {
        product = await service.fetchProduct(widget.productId, token: token);
      } on LdStoreAuthExpiredException catch (e) {
        if (mounted) handleLdStoreAuthError(context, e);
        // 凭据失效不影响浏览：匿名再读一次
        product = await service.fetchProduct(widget.productId);
      }
      if (!mounted) return;
      setState(() {
        _product = product;
        _detailLoaded = true;
        _loading = false;
      });
    } catch (e, s) {
      if (!mounted) return;
      // 已经有内容（列表带进来的 / 上次读到的）：保留着，只提示
      if (_product != null) {
        ToastService.showError(ldShopErrorText(e));
      }
      setState(() {
        _error = e;
        _errorStack = s;
        _loading = false;
      });
    }
  }

  /// 不能下单的原因（null = 可以买）。外链 / 小店类商品只检查信任等级。
  String? _blockReason(LdShopProduct product, LdStoreToken? token) {
    final t = context.l10n;
    final trustLevel = ref.read(currentUserProvider).value?.trustLevel ?? 0;
    final trustBlocked = product.purchaseTrustLevel > trustLevel;
    if (!product.type.isPlatformOrder) {
      return trustBlocked
          ? t.ldShop_needTrustLevel(product.purchaseTrustLevel)
          : null;
    }
    if (product.isOutOfStock) return t.ldShop_soldOut;
    if (product.purchaseLimit.isReached) return t.ldShop_limitReached;
    if (product.canPurchase == false) return t.ldShop_notForSale;
    if (trustBlocked) {
      return t.ldShop_needTrustLevel(product.purchaseTrustLevel);
    }
    final isSeller =
        token != null &&
        product.sellerUserId != null &&
        product.sellerUserId == token.userId;
    if (product.isTestMode && !isSeller) return t.ldShop_testModeOnly;
    if (!product.isTestMode && isSeller) return t.ldShop_ownProduct;
    return null;
  }

  Future<void> _buy() async {
    final product = _product;
    if (product == null || _busy) return;
    setState(() => _busy = true);
    try {
      final token = await ensureLdStoreToken(context);
      if (token == null || !mounted) return;
      // 带着凭据重新读一遍：canPurchase、限购余量这些买家字段要最新的
      await _load();
      if (!mounted) return;
      final fresh = _product;
      if (fresh == null || _error != null) return;
      final reason = _blockReason(fresh, token);
      if (reason != null) {
        ToastService.showInfo(reason);
        return;
      }
      final created = await LdStoreCheckoutSheet.show(
        context,
        product: fresh,
        token: token,
      );
      if (created == null || !mounted) return;
      if (created.paymentUnsettled && !created.isSettled) {
        ToastService.showInfo(context.l10n.ldShop_paymentConfirming);
      }
      await LdStoreOrderPage.open(
        context,
        created.orderNo,
        payNowUrl: created.needsPayment ? created.paymentUrl : null,
      );
      // 回来时库存、限购余量可能变了
      if (mounted) _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goExternal() async {
    final product = _product;
    if (product == null || _busy) return;
    final reason = _blockReason(product, null);
    if (reason != null) {
      ToastService.showInfo(reason);
      return;
    }
    setState(() => _busy = true);
    try {
      final service = ref.read(ldShopServiceProvider);
      final uri = await service.fetchExternalLink(
        product.id,
        token: await _token(),
      );
      if (!mounted) return;
      await launchExternalLink(context, uri.toString());
    } catch (e) {
      if (mounted && !handleLdStoreAuthError(context, e)) {
        ToastService.showError(
          context.l10n.ldShop_openLinkFailed(ldShopErrorText(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.ldShop_productTitle),
        actions: [
          PopupMenuButton<void>(
            tooltip: context.l10n.common_more,
            icon: const Icon(Symbols.more_vert_rounded),
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                onTap: () => _openWeb(),
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
      body: product == null
          ? (_loading
                ? const Center(child: LoadingSpinner())
                : ErrorView(
                    error: _error ?? Exception(),
                    stackTrace: _errorStack,
                    onRetry: _load,
                  ))
          : M3eRefreshIndicator(
              onRefresh: _load,
              child: _buildContent(theme, product),
            ),
      bottomNavigationBar: product == null
          ? null
          : _buildBottomBar(theme, product),
    );
  }

  void _openWeb() {
    // 商城网页的商品页路由：/product/:id
    openLdStoreInBrowser(
      context,
      '/product/${Uri.encodeComponent(widget.productId)}',
    );
  }

  Widget _buildContent(ThemeData theme, LdShopProduct product) {
    final mj = theme.extension<MojianTokens>();
    final subtle = ldShopSubtle(theme);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final loggedIn = ref.watch(
      ldStoreSessionProvider.select((s) => s.value != null),
    );
    final limit = ldShopLimitLabel(product.purchaseLimit, loggedIn: loggedIn);
    final trustLevel = ref.watch(
      currentUserProvider.select((u) => u.value?.trustLevel ?? 0),
    );

    final children = <Widget>[
      if (product.imageUrl != null)
        AspectRatio(
          aspectRatio: 16 / 10,
          child: LdShopImage(url: product.imageUrl, lightbox: true),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              product.name,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                fontFamily: mj == null
                    ? null
                    : MojianTokens.titleFamilyFor(context),
                color: mj?.ink,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: LdShopPriceText(
                    price: product.finalPrice,
                    original: product.hasDiscount ? product.price : null,
                    large: true,
                  ),
                ),
                if (product.hasDiscount) ...[
                  const SizedBox(width: 8),
                  LdShopTag(
                    label: ldShopDiscountLabel(product.discount),
                    color: ldShopAccent(theme),
                    filled: true,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                LdShopTag(
                  icon: switch (product.type) {
                    LdShopProductType.cdk => Symbols.key_rounded,
                    LdShopProductType.normal => Symbols.local_shipping_rounded,
                    LdShopProductType.link => Symbols.link_rounded,
                    LdShopProductType.store => Symbols.storefront_rounded,
                  },
                  label: ldShopProductTypeLabel(
                    product.type,
                    autoDelivery: product.autoDelivery,
                  ),
                ),
                if (product.categoryName != null)
                  LdShopTag(
                    label: product.categoryIcon == null
                        ? product.categoryName!
                        : '${product.categoryIcon} ${product.categoryName}',
                  ),
                if (product.isTestMode)
                  LdShopTag(
                    label: context.l10n.ldShop_testMode,
                    color: theme.colorScheme.error,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              [
                if (ldShopStockLabel(product).isNotEmpty)
                  ldShopStockLabel(product),
                if (product.type.isPlatformOrder)
                  context.l10n.ldShop_sold(product.soldCount),
                context.l10n.ldShop_views(product.viewCount),
                if (product.createdAt != null)
                  context.l10n.ldShop_listedAt(
                    TimeUtils.formatShortDate(product.createdAt),
                  ),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: subtle),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (product.sellerUsername != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildSeller(theme, product),
        ),
      if (limit != null || product.purchaseTrustLevel > 0) ...[
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LdShopSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (limit != null)
                  _ruleRow(
                    theme,
                    Symbols.production_quantity_limits_rounded,
                    limit,
                    warn: product.purchaseLimit.isReached,
                  ),
                if (limit != null && product.purchaseTrustLevel > 0)
                  const SizedBox(height: 8),
                if (product.purchaseTrustLevel > 0)
                  _ruleRow(
                    theme,
                    trustLevel >= product.purchaseTrustLevel
                        ? Symbols.verified_user_rounded
                        : Symbols.shield_lock_rounded,
                    context.l10n.ldShop_trustRequirement(
                      product.purchaseTrustLevel,
                      trustLevel,
                    ),
                    warn: trustLevel < product.purchaseTrustLevel,
                  ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LdShopSectionTitle(context.l10n.ldShop_description),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _buildDescription(theme, product),
      ),
      SizedBox(height: 24 + bottom),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
  }

  Widget _ruleRow(
    ThemeData theme,
    IconData icon,
    String text, {
    bool warn = false,
  }) {
    final color = warn ? theme.colorScheme.error : ldShopSubtle(theme);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: warn ? theme.colorScheme.error : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSeller(ThemeData theme, LdShopProduct product) {
    final username = product.sellerUsername!;
    final name = product.sellerName;
    final subtle = ldShopSubtle(theme);
    return LdShopSurface(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
      ),
      child: Row(
        children: [
          SmartAvatar(
            imageUrl: product.sellerAvatar,
            radius: 20,
            fallbackText: username,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name == null || name == username ? username : name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    '@$username',
                    if (product.sellerTrustLevel != null)
                      'TL${product.sellerTrustLevel}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                ),
              ],
            ),
          ),
          Text(
            context.l10n.ldShop_seller,
            style: theme.textTheme.labelSmall?.copyWith(color: subtle),
          ),
          Icon(Symbols.chevron_right_rounded, color: subtle),
        ],
      ),
    );
  }

  Widget _buildDescription(ThemeData theme, LdShopProduct product) {
    final subtle = ldShopSubtle(theme);
    if (!_detailLoaded && product.description.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: LoadingSpinner(size: 24)),
      );
    }
    if (product.description.isEmpty) {
      return Text(
        context.l10n.ldShop_noDescription,
        style: theme.textTheme.bodyMedium?.copyWith(color: subtle),
      );
    }
    return FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'ld_shop_product_${product.id}',
    ).render(
      cookedHtml: ldShopDescriptionHtml(product.description),
      baseTextStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
    );
  }

  Widget _buildBottomBar(ThemeData theme, LdShopProduct product) {
    final mj = theme.extension<MojianTokens>();
    final token = ref.watch(ldStoreSessionProvider).value?.token;
    final reason = _blockReason(product, token);
    final external = !product.type.isPlatformOrder;
    final Widget button;
    final label = external
        ? context.l10n.ldShop_goExternal
        : (reason ?? context.l10n.ldShop_buyNow);
    final onPressed = _busy || reason != null
        ? null
        : (external ? _goExternal : _buy);
    final child = _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);
    button = FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size(140, 44)),
      child: child,
    );
    return Material(
      color: mj?.paper ?? theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: mj?.rule ?? theme.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LdShopPriceText(price: product.finalPrice, large: true),
                    if (external && reason != null)
                      Text(
                        reason,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              button,
            ],
          ),
        ),
      ),
    );
  }
}
