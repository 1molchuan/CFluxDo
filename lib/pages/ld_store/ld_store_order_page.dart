import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_description.dart';
import '../../services/ld_store/ld_store_models.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../services/ld_store/ld_store_shop_service.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/error_view.dart';
import '../webview_page.dart';
import 'ld_store_common.dart';
import 'ld_store_product_page.dart';

/// 订单详情：状态、金额、券、发货内容（卡密）、动态；待付款时可继续付款、
/// 检查支付状态、取消。
///
/// 付款在内置浏览器里打开 credit.linux.do（走 App 的网关、带论坛登录态）；
/// 支付页关掉回来先让商城去 Credit 对一次账（refresh）再读详情。待付款 / 支付中
/// 时，页面可见期间每 3 秒读一次详情，直到状态变化。
class LdStoreOrderPage extends ConsumerStatefulWidget {
  const LdStoreOrderPage({super.key, required this.orderNo, this.payNowUrl});

  final String orderNo;

  /// 刚下完单：进来就打开这个支付链接
  final String? payNowUrl;

  static Future<void> open(
    BuildContext context,
    String orderNo, {
    String? payNowUrl,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => LdStoreOrderPage(orderNo: orderNo, payNowUrl: payNowUrl),
    ),
  );

  @override
  ConsumerState<LdStoreOrderPage> createState() => _LdStoreOrderPageState();
}

enum _Action { pay, check, cancel }

class _LdStoreOrderPageState extends ConsumerState<LdStoreOrderPage>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 3);

  LdShopOrderDetail? _detail;
  bool _loading = true;
  bool _needsAuth = false;
  Object? _error;
  StackTrace? _errorStack;
  _Action? _action;
  bool _revealDelivery = false;

  Timer? _pollTimer;
  Timer? _deliveryFollowUp;
  bool _fetching = false;
  bool _resumed = true;

  /// 已经提示过的支付结果（轮询时不重复弹）
  String? _announcedStatus;

  LdShopService get _service => ref.read(ldShopServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _deliveryFollowUp?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
  }

  Future<void> _start() async {
    await _load();
    if (!mounted) return;
    final url = widget.payNowUrl;
    if (url != null && _detail?.order.isPending != false) {
      await _openPayment(url);
    }
  }

  Future<LdStoreToken?> _token() =>
      ref.read(ldStoreSessionProvider.notifier).currentToken();

  Future<void> _load({bool silent = false}) async {
    if (_fetching) return;
    _fetching = true;
    if (!silent) {
      setState(() {
        _loading = _detail == null;
        _error = null;
      });
    }
    try {
      final token = await _token();
      if (token == null) {
        if (mounted) setState(() => _needsAuth = true);
        return;
      }
      final detail = await _service.fetchOrder(widget.orderNo, token);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _needsAuth = false;
        _error = null;
      });
      _syncPolling();
      _scheduleDeliveryFollowUp();
    } catch (e, s) {
      if (!mounted) return;
      final expired = handleLdStoreAuthError(context, e);
      // 轮询失败不打断页面，等下一轮
      if (silent && !expired && _detail != null) return;
      setState(() {
        _needsAuth = expired;
        _error = expired ? null : e;
        _errorStack = s;
      });
    } finally {
      _fetching = false;
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 轮询与自动发货跟进
  // ---------------------------------------------------------------------------

  bool get _visible {
    if (!mounted || !_resumed) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  void _syncPolling() {
    final awaiting = _detail?.order.isAwaitingPayment ?? false;
    if (!awaiting) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    // 支付页叠在上面 / App 在后台时不读
    if (!_visible || _action != null) return;
    final before = _detail?.order.status;
    await _load(silent: true);
    _announceChange(before);
  }

  /// 已付款、自动发货但还没拿到内容：2 秒后再读一次
  void _scheduleDeliveryFollowUp() {
    final order = _detail?.order;
    if (order == null ||
        order.status != LdShopOrderStatus.paid ||
        !order.isAutoDelivery ||
        order.deliveryLines.isNotEmpty ||
        _deliveryFollowUp != null) {
      return;
    }
    _deliveryFollowUp = Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      if (_detail?.order.status == LdShopOrderStatus.paid) {
        await _load(silent: true);
      }
    });
  }

  void _announceChange(String? before) {
    final order = _detail?.order;
    if (order == null || before == null) return;
    if (before == LdShopOrderStatus.pending && order.status != before) {
      _announce(order.status);
    }
  }

  /// 支付结果提示（与商城网页 `toastPaymentSyncResult` 一致）。
  void _announce(String? status, {String? pendingMessage}) {
    final t = context.l10n;
    final order = _detail?.order;
    if (status != null &&
        status != LdShopOrderStatus.pending &&
        status == _announcedStatus) {
      return;
    }
    if (status != null && status != LdShopOrderStatus.pending) {
      _announcedStatus = status;
    }
    switch (status) {
      case LdShopOrderStatus.delivered:
        ToastService.showSuccess(
          order?.isAutoDelivery ?? true
              ? t.ldShop_paidDelivered
              : t.ldShop_paidSellerDelivered,
        );
      case LdShopOrderStatus.paid:
        ToastService.showSuccess(
          order?.productType == LdShopProductType.normal
              ? t.ldShop_paidContactSeller
              : t.ldShop_paidUpdated,
        );
      case LdShopOrderStatus.expired:
        ToastService.showInfo(t.ldShop_orderExpired);
      default:
        if (pendingMessage != null) ToastService.showInfo(pendingMessage);
    }
  }

  // ---------------------------------------------------------------------------
  // 付款
  // ---------------------------------------------------------------------------

  Future<void> _openPayment(String url) async {
    final uri = LdShopService.trustedPaymentUri(url);
    if (uri == null) {
      ToastService.showError(context.l10n.ldShop_paymentUrlInvalid);
      return;
    }
    // 付完 Credit 会跳回商城的 /pay/signal：到这一步自动关页，回来就对账
    await WebViewPage.open<void>(
      context,
      uri.toString(),
      title: context.l10n.ldShop_paymentTitle,
      closeWhen: (url) =>
          (url.host == 'ldcstore.com' || url.host == 'www.ldcstore.com') &&
          url.path == '/pay/signal',
    );
    if (!mounted) return;
    // 付完（或关掉）回来：先让商城主动对账，再读详情
    await _syncPayment(announcePending: false);
  }

  /// refresh 对账 + 重新读详情。[announcePending] 为 true 时（手动检查）
  /// 还没付也提示一下。
  Future<void> _syncPayment({required bool announcePending}) async {
    final token = await _token();
    if (token == null || !mounted) {
      if (mounted) setState(() => _needsAuth = true);
      return;
    }
    setState(() => _action = _Action.check);
    try {
      final before = _detail?.order.status;
      LdShopPaymentInfo? info;
      try {
        info = await _service.refreshOrder(widget.orderNo, token);
      } catch (e) {
        if (!mounted) return;
        if (handleLdStoreAuthError(context, e)) {
          setState(() => _needsAuth = true);
          return;
        }
        if (announcePending) {
          ToastService.showError(
            context.l10n.ldShop_checkFailed(ldShopErrorText(e)),
          );
        }
      }
      await _load(silent: true);
      if (!mounted) return;
      final after = _detail?.order.status;
      if (announcePending) {
        _announce(
          info?.status ?? after,
          pendingMessage: info?.message ?? context.l10n.ldShop_notPaidYet,
        );
      } else if (before == LdShopOrderStatus.pending &&
          after != null &&
          after != before) {
        _announce(after);
      }
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _continuePayment() async {
    final token = await _token();
    if (token == null || !mounted) return;
    setState(() => _action = _Action.pay);
    String? url;
    try {
      final info = await _service.fetchPaymentUrl(widget.orderNo, token);
      url = info.paymentUrl;
      if (url == null && mounted) {
        ToastService.showError(
          info.message ?? context.l10n.ldShop_noPaymentUrl,
        );
      }
    } catch (e) {
      if (mounted && !handleLdStoreAuthError(context, e)) {
        ToastService.showError(
          context.l10n.ldShop_paymentUrlFailed(ldShopErrorText(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _action = null);
    }
    if (url != null && mounted) await _openPayment(url);
  }

  Future<void> _cancel() async {
    final t = context.l10n;
    final order = _detail?.order;
    if (order == null) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.ldShop_cancelOrder),
        content: Text(
          t.ldShop_cancelConfirm(order.productName ?? order.orderNo),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.ldShop_keepOrder),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.ldShop_cancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = await _token();
    if (token == null || !mounted) return;
    setState(() => _action = _Action.cancel);
    try {
      await _service.cancelOrder(order.orderNo, token);
      if (!mounted) return;
      ToastService.showSuccess(t.ldShop_orderCancelled);
      await _load(silent: true);
    } catch (e) {
      if (mounted && !handleLdStoreAuthError(context, e)) {
        ToastService.showError(t.ldShop_cancelFailed(ldShopErrorText(e)));
      }
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  void _copy(String text, {required bool all}) {
    // 卡密只进剪贴板，不写日志
    Clipboard.setData(ClipboardData(text: text));
    ToastService.showSuccess(
      all
          ? context.l10n.ldShop_copiedAll
          : context.l10n.common_copiedToClipboard,
    );
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    Widget body;
    if (_loading && detail == null) {
      body = const Center(child: LoadingSpinner());
    } else if (_needsAuth) {
      body = LdShopAuthRequiredView(onAuthorized: _load);
    } else if (detail == null) {
      body = ErrorView(
        error: _error ?? Exception(),
        stackTrace: _errorStack,
        onRetry: _load,
      );
    } else {
      body = M3eRefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: _buildContent(theme, detail),
      );
    }
    final order = detail?.order;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.ldShop_orderTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.ldShop_openInBrowser,
            icon: const Icon(Symbols.open_in_browser_rounded),
            onPressed: () => openLdStoreInBrowser(
              context,
              '/order/${Uri.encodeComponent(widget.orderNo)}?role=buyer',
            ),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: order != null && !_needsAuth
          ? _buildActions(theme, order)
          : null,
    );
  }

  Widget _buildContent(ThemeData theme, LdShopOrderDetail detail) {
    final order = detail.order;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottom),
      children: [
        _buildStatus(theme, order),
        const SizedBox(height: 12),
        _buildItem(theme, order),
        const SizedBox(height: 12),
        if (order.deliveryLines.isNotEmpty ||
            order.status == LdShopOrderStatus.paid ||
            order.status == LdShopOrderStatus.delivered ||
            order.status == LdShopOrderStatus.completed) ...[
          _buildDelivery(theme, order),
          const SizedBox(height: 12),
        ],
        _buildInfo(theme, order),
        if (order.productDescription != null && !order.isAwaitingPayment) ...[
          const SizedBox(height: 20),
          LdShopSectionTitle(context.l10n.ldShop_usage),
          const SizedBox(height: 8),
          FluxdoRenderCallbacks.generic(
            heroTagNamespace: 'ld_shop_order_${order.orderNo}',
          ).render(
            cookedHtml: ldShopDescriptionHtml(order.productDescription!),
            baseTextStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
        ],
        if (detail.logs.isNotEmpty) ...[
          const SizedBox(height: 20),
          LdShopSectionTitle(context.l10n.ldShop_timeline),
          const SizedBox(height: 8),
          for (final log in detail.logs) _buildLog(theme, log),
        ],
      ],
    );
  }

  Widget _buildStatus(ThemeData theme, LdShopOrder order) {
    final t = context.l10n;
    final color = ldShopStatusColor(theme, order.displayStatus);
    final subtle = ldShopSubtle(theme);
    final icon = switch (order.status) {
      LdShopOrderStatus.pending => Symbols.schedule_rounded,
      LdShopOrderStatus.paying => Symbols.credit_card_rounded,
      LdShopOrderStatus.paid => Symbols.check_circle_rounded,
      LdShopOrderStatus.delivered => Symbols.inventory_2_rounded,
      LdShopOrderStatus.completed => Symbols.verified_rounded,
      LdShopOrderStatus.cancelled ||
      LdShopOrderStatus.expired => Symbols.cancel_rounded,
      LdShopOrderStatus.refunded ||
      LdShopOrderStatus.refundPending ||
      LdShopOrderStatus.refundFailed => Symbols.undo_rounded,
      _ => Symbols.receipt_long_rounded,
    };
    final deadline = order.isPending && !order.paymentConfirming
        ? order.paymentDeadline
        : null;
    return LdShopSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 28, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ldShopOrderStatusLabel(order),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_action == _Action.check)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (order.displayStatus != order.status) ...[
            const SizedBox(height: 4),
            Text(
              t.ldShop_fulfillment(ldShopStatusText(order.status)),
              style: theme.textTheme.bodySmall?.copyWith(color: subtle),
            ),
          ],
          if (order.paymentConfirming) ...[
            const SizedBox(height: 6),
            Text(
              order.paymentInitStatus == 'creating'
                  ? t.ldShop_paymentCreating
                  : t.ldShop_paymentConfirming,
              style: theme.textTheme.bodySmall,
            ),
            if (order.paymentResolutionDeadline != null)
              Text(
                t.ldShop_paymentResolveBy(
                  TimeUtils.formatClockTime(order.paymentResolutionDeadline),
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: subtle),
              ),
          ],
          if (deadline != null) ...[
            const SizedBox(height: 6),
            Text(
              t.ldShop_payBeforeDetail(TimeUtils.formatDetailTime(deadline)),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _copy(order.orderNo, all: false),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    t.ldShop_orderNo(order.orderNo),
                    style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Symbols.content_copy_rounded, size: 14, color: subtle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(ThemeData theme, LdShopOrder order) {
    final t = context.l10n;
    final subtle = ldShopSubtle(theme);
    final mj = theme.extension<MojianTokens>();
    Widget line(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: subtle),
            ),
          ),
          value,
        ],
      ),
    );
    final productId = order.productId;
    return LdShopSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: productId == null
                ? null
                : () => LdStoreProductPage.open(context, productId),
            child: Row(
              children: [
                LdShopImage(
                  url: order.productImage,
                  width: 56,
                  height: 56,
                  borderRadius: mj != null ? 4 : 10,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    order.productName ?? t.ldShop_unnamedProduct,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (productId != null)
                  Icon(Symbols.chevron_right_rounded, color: subtle),
              ],
            ),
          ),
          const Divider(height: 20),
          line(t.ldShop_quantity, Text('×${order.quantity}')),
          if (order.originalUnitPrice > 0)
            line(
              t.ldShop_unitPrice,
              order.hasProductDiscount
                  ? Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: ldShopAmount(order.originalUnitPrice),
                            style: TextStyle(
                              color: subtle,
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                          const TextSpan(text: '  '),
                          TextSpan(text: ldShopAmount(order.unitPrice)),
                        ],
                      ),
                      style: theme.textTheme.bodySmall,
                    )
                  : Text(
                      ldShopAmount(order.originalUnitPrice),
                      style: theme.textTheme.bodySmall,
                    ),
            ),
          if (order.hasCoupon || order.couponDiscountAmount > 0)
            line(
              order.couponName == null
                  ? t.ldShop_couponDiscount
                  : t.ldShop_couponNamed(order.couponName!),
              Text(
                '-${ldShopAmount(order.couponDiscountAmount)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ldShopAccent(theme),
                ),
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  t.ldShop_amountPaid,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              LdShopPriceText(price: order.amount, large: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDelivery(ThemeData theme, LdShopOrder order) {
    final t = context.l10n;
    final subtle = ldShopSubtle(theme);
    final lines = order.deliveryLines;
    if (lines.isEmpty) {
      final waiting = order.status == LdShopOrderStatus.paid;
      return LdShopSurface(
        child: Row(
          children: [
            Icon(
              waiting
                  ? Symbols.hourglass_top_rounded
                  : Symbols.inventory_2_rounded,
              size: 20,
              color: subtle,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                waiting
                    ? (order.isAutoDelivery
                          ? t.ldShop_autoDelivering
                          : t.ldShop_waitSeller)
                    : t.ldShop_noDeliveryContent,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono'],
    );
    return LdShopSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Symbols.key_rounded, size: 20, color: ldShopAccent(theme)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.ldShop_deliveryContent(lines.length),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: _revealDelivery ? t.ldShop_hide : t.ldShop_reveal,
                icon: Icon(
                  _revealDelivery
                      ? Symbols.visibility_off_rounded
                      : Symbols.visibility_rounded,
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => _revealDelivery = !_revealDelivery),
              ),
              TextButton(
                onPressed: () => _copy(lines.join('\n'), all: true),
                child: Text(t.ldShop_copyAll),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: _revealDelivery
                        ? SelectableText(line, style: mono)
                        : Text(
                            '•' * (line.length.clamp(6, 24)),
                            style: mono?.copyWith(color: subtle),
                          ),
                  ),
                  IconButton(
                    tooltip: t.common_copy,
                    icon: const Icon(Symbols.content_copy_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copy(line, all: false),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfo(ThemeData theme, LdShopOrder order) {
    final t = context.l10n;
    final subtle = ldShopSubtle(theme);
    final rows = <(String, String)>[
      if (order.sellerUsername != null)
        (t.ldShop_seller, '@${order.sellerUsername}'),
      if (order.deliveryType != null)
        (
          t.ldShop_deliveryType,
          order.isAutoDelivery ? t.ldShop_typeAuto : t.ldShop_typeManual,
        ),
      if (order.createdAt != null)
        (t.ldShop_createdAt, TimeUtils.formatDetailTime(order.createdAt)),
      if (order.paidAt != null)
        (t.ldShop_paidAt, TimeUtils.formatDetailTime(order.paidAt)),
      if (order.deliveredAt != null)
        (t.ldShop_deliveredAt, TimeUtils.formatDetailTime(order.deliveredAt)),
      if (order.completedAt != null)
        (t.ldShop_completedAt, TimeUtils.formatDetailTime(order.completedAt)),
      if (order.cancelledAt != null)
        (t.ldShop_cancelledAt, TimeUtils.formatDetailTime(order.cancelledAt)),
      if (order.refundedAt != null)
        (t.ldShop_refundedAt, TimeUtils.formatDetailTime(order.refundedAt)),
      if (order.ldcTradeNo != null) (t.ldShop_tradeNo, order.ldcTradeNo!),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return LdShopSurface(
      child: Column(
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLog(ThemeData theme, LdShopOrderLog log) {
    final subtle = ldShopSubtle(theme);
    final title = [
      _logText(log.action),
      if (log.operator != null) '(${log.operator})',
    ].join(' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Icon(
              Symbols.circle_rounded,
              size: 8,
              fill: 1,
              color: subtle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (log.note != null)
                  Text(
                    log.note!,
                    style: theme.textTheme.bodySmall?.copyWith(color: subtle),
                  ),
              ],
            ),
          ),
          if (log.createdAt != null)
            Text(
              TimeUtils.formatDetailTime(log.createdAt),
              style: theme.textTheme.labelSmall?.copyWith(color: subtle),
            ),
        ],
      ),
    );
  }

  String _logText(String action) {
    final t = context.l10n;
    return switch (action) {
      'create' => t.ldShop_logCreate,
      'pay' => t.ldShop_logPay,
      'repay' => t.ldShop_logRepay,
      'deliver' => t.ldShop_logDeliver,
      'complete' || 'completed' => t.ldShop_logComplete,
      'admin_complete' => t.ldShop_logAdminComplete,
      'refund_request' => t.ldShop_logRefundRequest,
      'refund_reject' => t.ldShop_logRefundReject,
      'refund_external_dispute' => t.ldShop_statusDispute,
      'refund' => t.ldShop_logRefund,
      'cancel' => t.ldShop_logCancel,
      'expire' => t.ldShop_logExpire,
      'lock_cdk' => t.ldShop_logLockCdk,
      'unlock_cdk' => t.ldShop_logUnlockCdk,
      '' => t.common_unknown,
      _ => action,
    };
  }

  Widget? _buildActions(ThemeData theme, LdShopOrder order) {
    final t = context.l10n;
    final mj = theme.extension<MojianTokens>();
    final busy = _action != null;
    Widget spinner() => const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    final buttons = <Widget>[];
    if (order.isAwaitingPayment) {
      if (order.isPending) {
        buttons.add(
          TextButton(
            onPressed: busy ? null : _cancel,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: _action == _Action.cancel
                ? spinner()
                : Text(t.ldShop_cancelOrder),
          ),
        );
      }
      buttons.add(
        OutlinedButton(
          onPressed: busy ? null : () => _syncPayment(announcePending: true),
          child: _action == _Action.check
              ? spinner()
              : Text(t.ldShop_checkPayment),
        ),
      );
      if (order.isPending && !order.paymentConfirming) {
        buttons.add(
          FilledButton(
            onPressed: busy ? null : _continuePayment,
            child: _action == _Action.pay ? spinner() : Text(t.ldShop_payNow),
          ),
        );
      }
    } else if ((order.status == LdShopOrderStatus.cancelled ||
            order.status == LdShopOrderStatus.expired) &&
        order.productId != null) {
      buttons.add(
        FilledButton.tonal(
          onPressed: () => LdStoreProductPage.open(context, order.productId!),
          child: Text(t.ldShop_viewProduct),
        ),
      );
    }
    if (buttons.isEmpty) return null;
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
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: buttons,
          ),
        ),
      ),
    );
  }
}
