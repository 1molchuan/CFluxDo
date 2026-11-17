import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/core_providers.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_models.dart';
import '../../services/ld_store/ld_store_service.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../services/ld_store/ld_store_shop_service.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/dialog_utils.dart';
import '../../widgets/common/mojian_section_label.dart';
import '../../widgets/content/discourse_image.dart';
import '../webview_page.dart';

// -----------------------------------------------------------------------------
// 授权
// -----------------------------------------------------------------------------

/// 走一遍 LINUX DO Connect 授权：先拿到同意链接，用户在确认框里点「允许」
/// 才发同意请求。成功返回凭据（入口卡同步刷新）；失败或取消返回 null，
/// 失败原因已用 toast 提示。
Future<LdStoreToken?> authorizeLdStore(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final username = container.read(currentUserProvider).value?.username;
  if (username == null) {
    ToastService.showInfo(S.current.common_pleaseLogin);
    return null;
  }
  try {
    final service = container.read(ldStoreServiceProvider);
    final pending = await service.beginAuthorization();
    if (!context.mounted) return null;
    // 确认框关闭时带回凭据（成功）或错误（同意链接只能用一次，失败后
    // 不能在原框里重试，要重新走一遍）
    final result = await showAppDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LdStoreAuthDialog(
        onApprove: () =>
            service.completeAuthorization(pending, expectedUsername: username),
      ),
    );
    if (result == null) return null;
    if (result is! LdStoreToken) throw result;
    await container.read(ldStoreSessionProvider.notifier).adopt();
    ToastService.showSuccess(S.current.ldStore_authSuccess);
    return result;
  } catch (e) {
    ToastService.showError(S.current.metaverse_authFailed(_plainMessage(e)));
    return null;
  }
}

/// 当前凭据；没有（未授权 / 已失效）就先走授权。
Future<LdStoreToken?> ensureLdStoreToken(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final token = await container
      .read(ldStoreSessionProvider.notifier)
      .currentToken();
  if (token != null) return token;
  if (!context.mounted) return null;
  return authorizeLdStore(context);
}

/// 商城说凭据失效时作废它（入口卡显示「授权已过期」）。返回是不是这类错误。
bool handleLdStoreAuthError(BuildContext context, Object error) {
  if (error is! LdStoreAuthExpiredException) return false;
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(ldStoreSessionProvider.notifier).markExpired();
  return true;
}

/// 授权确认框：讲清楚是第三方、拿到什么；点「允许」才发同意请求。
class LdStoreAuthDialog extends StatefulWidget {
  const LdStoreAuthDialog({super.key, required this.onApprove});

  final Future<LdStoreToken> Function() onApprove;

  @override
  State<LdStoreAuthDialog> createState() => _LdStoreAuthDialogState();
}

class _LdStoreAuthDialogState extends State<LdStoreAuthDialog> {
  bool _loading = false;

  Future<void> _approve() async {
    setState(() => _loading = true);
    Object result;
    try {
      result = await widget.onApprove();
    } catch (e) {
      result = e;
    }
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.ldStore_confirmTitle),
      content: Text(context.l10n.ldStore_confirmMessage),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: Text(context.l10n.common_deny),
        ),
        FilledButton(
          onPressed: _loading ? null : _approve,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.common_allow),
        ),
      ],
    );
  }
}

/// 需要授权才能看的页面（订单、优惠券）在没授权 / 授权失效时的占位。
class LdShopAuthRequiredView extends ConsumerStatefulWidget {
  const LdShopAuthRequiredView({super.key, required this.onAuthorized});

  final VoidCallback onAuthorized;

  @override
  ConsumerState<LdShopAuthRequiredView> createState() =>
      _LdShopAuthRequiredViewState();
}

class _LdShopAuthRequiredViewState
    extends ConsumerState<LdShopAuthRequiredView> {
  bool _busy = false;

  Future<void> _authorize() async {
    setState(() => _busy = true);
    final token = await authorizeLdStore(context);
    if (!mounted) return;
    setState(() => _busy = false);
    if (token != null) widget.onAuthorized();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expired =
        ref.watch(ldStoreSessionProvider).error is LdStoreAuthExpiredException;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.lock_rounded, size: 48, color: ldShopSubtle(theme)),
            const SizedBox(height: 16),
            Text(
              expired
                  ? context.l10n.ldStore_authExpired
                  : context.l10n.ldShop_authRequired,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _authorize,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      expired
                          ? context.l10n.common_reAuth
                          : context.l10n.ldStore_authorize,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 兜底入口：在内置浏览器里打开商城网页 [path]（带上 App 的登录态，支付
/// 弹窗作为新窗口叠上来）。求购、评论、卖家后台这些原生页没做的也走这里。
Future<void> openLdStoreInBrowser(
  BuildContext context, [
  String path = '/',
]) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final service = container.read(ldStoreServiceProvider);
  final token = await container
      .read(ldStoreSessionProvider.notifier)
      .currentToken();
  final revocation = token == null ? await service.loadRevocation() : null;
  final script = LdStoreService.webSessionScript(
    token: token,
    revocation: revocation,
  );
  if (!context.mounted) return;
  await WebViewPage.open<void>(
    context,
    '${LdStoreService.siteUrl}$path',
    title: S.current.ldStore_title,
    extraUserScripts: [?script],
    allowPopups: true,
  );
  // 回来时订单 / 消息可能变了
  if (token != null) {
    await container.read(ldStoreSessionProvider.notifier).refresh();
  }
}

// -----------------------------------------------------------------------------
// 文案
// -----------------------------------------------------------------------------

String _plainMessage(Object e) {
  final text = e.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

/// 给 toast / 行内提示用的错误说明。
String ldShopErrorText(Object error) {
  if (error is LdShopException || error is LdStoreAuthExpiredException) {
    return error.toString();
  }
  if (error is DioException) return S.current.common_checkNetworkRetry;
  if (error is FormatException) return S.current.ldShop_errorFormat;
  return _plainMessage(error);
}

/// 价格：整数不带小数，否则最多两位（去掉末尾 0）。
String ldShopPrice(double value) {
  if (!value.isFinite) return '0';
  final rounded = (value * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) return rounded.toStringAsFixed(0);
  final text = rounded.toStringAsFixed(2);
  return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
}

/// `349.65 LDC`
String ldShopAmount(double value) => '${ldShopPrice(value)} LDC';

/// 折扣（0.35 → 「3.5 折」）
String ldShopDiscountLabel(double discount) {
  final tenths = (discount * 100).round() / 10;
  final text = tenths == tenths.roundToDouble()
      ? tenths.toStringAsFixed(0)
      : tenths.toStringAsFixed(1);
  return S.current.ldShop_discount(text);
}

String ldShopProductTypeLabel(LdShopProductType type, {bool? autoDelivery}) {
  final t = S.current;
  return switch (type) {
    LdShopProductType.cdk => t.ldShop_typeCdk,
    LdShopProductType.normal =>
      autoDelivery == true ? t.ldShop_typeAuto : t.ldShop_typeManual,
    LdShopProductType.link => t.ldShop_typeLink,
    LdShopProductType.store => t.ldShop_typeStore,
  };
}

String ldShopStockLabel(LdShopProduct product) {
  final t = S.current;
  if (!product.type.isPlatformOrder) return '';
  if (product.unlimitedStock) return t.ldShop_stockUnlimited;
  if (product.isOutOfStock) return t.ldShop_soldOut;
  return t.ldShop_stock(product.availableStock);
}

/// 限购说明（移植自 `formatPurchaseLimitLabel`）。null = 不限。
String? ldShopLimitLabel(LdShopPurchaseLimit limit, {required bool loggedIn}) {
  final t = S.current;
  switch (limit.mode) {
    case LdShopLimitMode.none:
      return null;
    case LdShopLimitMode.perOrder:
      return t.ldShop_limitPerOrder(limit.quantity);
    case LdShopLimitMode.perUser:
      final title = limit.periodDays > 0
          ? t.ldShop_limitPeriod(limit.periodDays, limit.quantity)
          : t.ldShop_limitTotal(limit.quantity);
      if (limit.isReached) return t.ldShop_limitReachedDetail(title);
      final remaining = limit.remainingQuantity;
      if (!loggedIn || remaining == null) return title;
      return t.ldShop_limitRemaining(title, remaining);
  }
}

/// 优惠券规则（「减 5 LDC」「8.5 折 · 仅优惠 1 件」）。
String ldShopCouponRule(LdShopCouponCampaign campaign) {
  final t = S.current;
  switch (campaign.discountType) {
    case LdShopDiscountType.fixedAmount:
      return t.ldShop_couponFixed(ldShopPrice(campaign.fixedAmount));
    case LdShopDiscountType.percentage:
      final tenths = campaign.discountTenths;
      final text = tenths == tenths.roundToDouble()
          ? tenths.toStringAsFixed(0)
          : tenths.toStringAsFixed(1);
      return t.ldShop_couponPercent(text);
    case LdShopDiscountType.unknown:
      return t.ldShop_couponGeneric;
  }
}

/// 订单状态文案。
String ldShopOrderStatusLabel(LdShopOrder order) {
  final t = S.current;
  if (order.paymentConfirming) {
    return order.paymentInitStatus == 'creating'
        ? t.ldShop_statusCreating
        : t.ldShop_statusConfirming;
  }
  return ldShopStatusText(order.displayStatus);
}

String ldShopStatusText(String status) {
  final t = S.current;
  return switch (status) {
    LdShopOrderStatus.pending => t.ldShop_statusPending,
    LdShopOrderStatus.paying => t.ldShop_statusPaying,
    LdShopOrderStatus.paid => t.ldShop_statusPaid,
    LdShopOrderStatus.delivered => t.ldShop_statusDelivered,
    LdShopOrderStatus.completed => t.ldShop_statusCompleted,
    LdShopOrderStatus.cancelled => t.ldShop_statusCancelled,
    LdShopOrderStatus.expired => t.ldShop_statusExpired,
    LdShopOrderStatus.refundPending => t.ldShop_statusRefundPending,
    LdShopOrderStatus.refunded => t.ldShop_statusRefunded,
    LdShopOrderStatus.refundFailed => t.ldShop_statusRefundFailed,
    LdShopOrderStatus.externalDispute => t.ldShop_statusDispute,
    '' => t.common_unknown,
    _ => status,
  };
}

// -----------------------------------------------------------------------------
// 视觉
// -----------------------------------------------------------------------------

Color ldShopSubtle(ThemeData theme) =>
    theme.extension<MojianTokens>()?.ink3 ?? theme.colorScheme.onSurfaceVariant;

Color ldShopAccent(ThemeData theme) =>
    theme.extension<MojianTokens>()?.accent ?? theme.colorScheme.primary;

/// 卡片底：墨笺是纸笺底 + 发丝线框的小圆角卡，经典是 M3 Card。
class LdShopSurface extends StatelessWidget {
  const LdShopSurface({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final content = Padding(padding: padding, child: child);
    final body = onTap == null
        ? content
        : InkWell(onTap: onTap, child: content);
    if (mj != null) {
      return Material(
        color: mj.paper3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: mj.rule),
        ),
        clipBehavior: Clip.antiAlias,
        child: body,
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

/// 分组小标题（墨笺用宋体字距标题）。
class LdShopSectionTitle extends StatelessWidget {
  const LdShopSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MojianTokens>() != null) {
      return MojianSectionLabel(text, trailing: trailing);
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 商品图：外链任意域名，加载失败画占位。
class LdShopImage extends StatelessWidget {
  const LdShopImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.lightbox = false,
  });

  final String? url;
  final double? width;
  final double? height;
  final double borderRadius;
  final bool lightbox;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final fallback = Center(
      child: Icon(
        Symbols.local_mall_rounded,
        size: 28,
        color: (mj?.ink4 ?? theme.colorScheme.outline),
      ),
    );
    final url = this.url;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: mj?.paper2 ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? fallback
          : DiscourseImage(
              url: url,
              width: width,
              height: height,
              enableLightbox: lightbox,
              placeholderBuilder: (_) => const SizedBox.shrink(),
              errorBuilder: (_) => fallback,
            ),
    );
  }
}

/// 小标签（类型、分类、状态）。
class LdShopTag extends StatelessWidget {
  const LdShopTag({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.filled = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final tint = color ?? ldShopSubtle(theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? tint.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(mj != null ? 3 : 8),
        border: filled ? null : Border.all(color: tint.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 3),
          ],
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: tint)),
        ],
      ),
    );
  }
}

/// 订单状态的颜色。
Color ldShopStatusColor(ThemeData theme, String status) {
  final mj = theme.extension<MojianTokens>();
  final cs = theme.colorScheme;
  return switch (status) {
    LdShopOrderStatus.pending ||
    LdShopOrderStatus.paying => mj?.gold ?? Colors.orange.shade700,
    LdShopOrderStatus.paid ||
    LdShopOrderStatus.delivered ||
    LdShopOrderStatus.completed => mj?.jade ?? Colors.green.shade600,
    LdShopOrderStatus.refundPending ||
    LdShopOrderStatus.refundFailed ||
    LdShopOrderStatus.externalDispute => cs.error,
    _ => ldShopSubtle(theme),
  };
}

/// 价格：现价（强调色）+ 原价划线。
class LdShopPriceText extends StatelessWidget {
  const LdShopPriceText({
    super.key,
    required this.price,
    this.original,
    this.large = false,
  });

  final double price;

  /// 有折扣时传原价
  final double? original;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = ldShopAccent(theme);
    final subtle = ldShopSubtle(theme);
    final main =
        (large ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
            ?.copyWith(color: accent, fontWeight: FontWeight.w700, height: 1.1);
    final unit = theme.textTheme.labelSmall?.copyWith(color: accent);
    final original = this.original;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: ldShopPrice(price), style: main),
          TextSpan(text: ' LDC', style: unit),
          if (original != null) ...[
            const TextSpan(text: '  '),
            TextSpan(
              text: ldShopPrice(original),
              style: theme.textTheme.labelSmall?.copyWith(
                color: subtle,
                decoration: TextDecoration.lineThrough,
                decorationColor: subtle,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
