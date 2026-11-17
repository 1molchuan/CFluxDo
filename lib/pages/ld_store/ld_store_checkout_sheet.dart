import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/ld_store_providers.dart';
import '../../services/ld_store/ld_store_checkout.dart';
import '../../services/ld_store/ld_store_models.dart';
import '../../services/ld_store/ld_store_service.dart';
import '../../services/ld_store/ld_store_shop_models.dart';
import '../../services/ld_store/ld_store_shop_service.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import 'ld_store_common.dart';
import 'ld_store_orders_page.dart';

/// 确认兑换的底部弹层：数量、可用券、核价金额，提交。
///
/// 返回创建好的订单（调用方进订单详情、打开支付页）；关掉 / 失败返回 null。
/// 不重复扣款靠 [LdShopCheckout]：先落盘 token 再下单，结果不确定只用同一个
/// token 核对；有没核对清楚的提交时不允许再发新的。
class LdStoreCheckoutSheet extends ConsumerStatefulWidget {
  const LdStoreCheckoutSheet({
    super.key,
    required this.product,
    required this.token,
  });

  final LdShopProduct product;
  final LdStoreToken token;

  static Future<LdShopOrderCreated?> show(
    BuildContext context, {
    required LdShopProduct product,
    required LdStoreToken token,
  }) {
    return AppBottomSheet.show<LdShopOrderCreated>(
      context: context,
      style: AppSheetStyle.card,
      title: context.l10n.ldShop_confirmOrder,
      builder: (_) => LdStoreCheckoutSheet(product: product, token: token),
    );
  }

  @override
  ConsumerState<LdStoreCheckoutSheet> createState() =>
      _LdStoreCheckoutSheetState();
}

class _LdStoreCheckoutSheetState extends ConsumerState<LdStoreCheckoutSheet> {
  late final LdShopCheckout _checkout;
  late LdShopProduct _product;
  final _quantityController = TextEditingController(text: '1');
  int _quantity = 1;

  LdShopQuote? _quote;
  bool _quoteLoading = false;
  Object? _quoteError;
  int _quoteRequestId = 0;
  Timer? _quoteTimer;

  String? _selectedClaimId;
  LdShopCouponMode _couponMode = LdShopCouponMode.auto;
  String? _couponNotice;

  /// 打开时先看有没有没核对清楚的提交
  bool _initializing = true;
  LdShopPendingSubmission? _pending;
  bool _checkingPending = false;

  /// 核对时查到的、之前那次提交建的订单
  LdShopOrderCreated? _previousOrder;

  bool _submitting = false;
  String? _submitError;

  LdShopService get _service => ref.read(ldShopServiceProvider);

  @override
  void initState() {
    super.initState();
    _product = widget.product;
    _checkout = LdShopCheckout(
      service: _service,
      token: widget.token,
      productId: widget.product.id,
    );
    _init();
  }

  @override
  void dispose() {
    _quoteTimer?.cancel();
    _quoteRequestId++;
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final pending = await _checkout.pending();
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _initializing = false;
    });
    if (pending != null) {
      await _recover(replay: false);
    } else {
      await _loadQuote();
    }
  }

  // ---------------------------------------------------------------------------
  // 数量与核价
  // ---------------------------------------------------------------------------

  int get _maxQuantity => _product.maxQuantity(_quote?.purchaseLimit);

  LdShopPurchaseLimit get _limit =>
      _quote?.purchaseLimit ?? _product.purchaseLimit;

  int _clamp(int value) {
    final max = _maxQuantity;
    if (value < 1) return 1;
    return value > max ? max : value;
  }

  void _setQuantity(int value, {bool fromField = false}) {
    final next = _clamp(value);
    if (!fromField || next != value) {
      final text = '$next';
      if (_quantityController.text != text) {
        _quantityController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }
    if (next == _quantity) return;
    setState(() => _quantity = next);
    _scheduleQuote();
  }

  void _scheduleQuote() {
    _quoteTimer?.cancel();
    // 立刻作废进行中的核价，免得它在防抖期间回来盖掉新数量的金额
    _quoteRequestId++;
    setState(() => _quoteLoading = true);
    _quoteTimer = Timer(const Duration(milliseconds: 180), _loadQuote);
  }

  /// 核价；返回是否成功。
  Future<bool> _loadQuote() async {
    _quoteTimer?.cancel();
    final requestId = ++_quoteRequestId;
    final requestedClaimId = _selectedClaimId;
    final requestedMode = _couponMode;
    setState(() {
      _quoteLoading = true;
      _quoteError = null;
      _couponNotice = null;
    });
    try {
      final quote = await _service.quote(
        productId: _product.id,
        quantity: _quantity,
        token: widget.token,
      );
      if (!mounted || requestId != _quoteRequestId) return false;
      final selection = LdShopCouponSelection.resolve(
        quote: quote,
        mode: requestedMode,
        selectedClaimId: requestedClaimId,
      );
      setState(() {
        _quote = quote;
        _quoteLoading = false;
        _selectedClaimId = selection.claimId;
        _couponMode = selection.mode;
        if (selection.replacedManualSelection) {
          _couponNotice = selection.claimId == null
              ? context.l10n.ldShop_couponGoneNone
              : context.l10n.ldShop_couponGoneReplaced;
        }
      });
      // 核价带回了这个账号的限购余量：数量超了就收回来
      final clamped = _clamp(_quantity);
      if (clamped != _quantity) {
        _setQuantity(clamped);
        ToastService.showInfo(context.l10n.ldShop_quantityAdjusted(clamped));
        return false;
      }
      return true;
    } catch (e) {
      if (!mounted || requestId != _quoteRequestId) return false;
      if (e is LdStoreAuthExpiredException) {
        _onAuthExpired(e);
        return false;
      }
      setState(() {
        _quote = null;
        _quoteLoading = false;
        _quoteError = e;
        // 核价失败：手动选了「不用券」的保留，其余回到自动
        final keepOptOut =
            _couponMode == LdShopCouponMode.manual && requestedClaimId == null;
        _selectedClaimId = null;
        _couponMode = keepOptOut
            ? LdShopCouponMode.manual
            : LdShopCouponMode.auto;
      });
      if (e is LdShopException &&
          e.status == 409 &&
          e.code == 'PURCHASE_LIMIT_EXCEEDED') {
        await _refreshProduct();
      }
      return false;
    }
  }

  Future<void> _refreshProduct() async {
    try {
      final product = await _service.fetchProduct(
        _product.id,
        token: widget.token,
      );
      if (!mounted) return;
      setState(() => _product = product);
      _setQuantity(_quantity);
    } catch (_) {}
  }

  void _onAuthExpired(Object error) {
    handleLdStoreAuthError(context, error);
    ToastService.showError(error.toString());
    Navigator.of(context).pop();
  }

  double? get _payable => _quote?.payableWith(_selectedClaimId);

  LdShopQuoteCoupon? get _selectedCoupon =>
      _quote?.eligibleCoupon(_selectedClaimId);

  // ---------------------------------------------------------------------------
  // 提交
  // ---------------------------------------------------------------------------

  String? get _blockMessage {
    final t = context.l10n;
    if (_product.isOutOfStock) return t.ldShop_soldOut;
    if (_limit.isReached) return t.ldShop_limitReached;
    if (_product.canPurchase == false) return t.ldShop_notForSale;
    return null;
  }

  bool get _canSubmit =>
      !_initializing &&
      _pending == null &&
      _previousOrder == null &&
      !_submitting &&
      !_quoteLoading &&
      _quote != null &&
      _blockMessage == null &&
      _quantity >= 1 &&
      _quantity <= _maxQuantity;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final requestedClaimId = _selectedClaimId;
      final amountBefore = _payable!;
      // 提交前强制再核一次价：金额或用券变了就不下单，让用户确认后再点
      final ok = await _loadQuote();
      if (!mounted) return;
      if (!ok || _payable == null) {
        setState(() {
          // 没有错误却没通过：数量被限购余量收回了，金额随之变化
          _submitError = _quoteError == null
              ? context.l10n.ldShop_amountChanged
              : ldShopErrorText(_quoteError!);
        });
        return;
      }
      final check = evaluateLdShopFinalQuote(
        requestedClaimId: requestedClaimId,
        currentClaimId: _selectedClaimId,
        amountBefore: amountBefore,
        amountNow: _payable!,
      );
      if (check != LdShopFinalQuoteCheck.ok) {
        setState(() {
          _submitError = check == LdShopFinalQuoteCheck.couponInvalidated
              ? context.l10n.ldShop_couponChanged
              : context.l10n.ldShop_amountChanged;
        });
        return;
      }
      final result = await _checkout.submit(
        quantity: _quantity,
        expectedAmount: _payable!,
        couponClaimId: _selectedClaimId,
      );
      if (!mounted) return;
      await _handleResult(result, navigate: true);
    } on LdStoreAuthExpiredException catch (e) {
      if (mounted) _onAuthExpired(e);
    } catch (e) {
      // 落盘失败等：什么都没发出去
      if (mounted) setState(() => _submitError = ldShopErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 核对上一次提交。[replay] = 查不到时按原样（同一个 token）重发。
  Future<void> _recover({required bool replay}) async {
    if (_checkingPending) return;
    setState(() {
      _checkingPending = true;
      _submitError = null;
    });
    try {
      final result = await _checkout.recover(replay: replay);
      if (!mounted) return;
      // 用户点了「核对本次结果」：查到就直接进订单（与商城网页一致）；
      // 打开时的自动核对只亮出提示，让用户自己选
      await _handleResult(result, navigate: replay);
    } on LdStoreAuthExpiredException catch (e) {
      if (mounted) _onAuthExpired(e);
    } catch (e) {
      if (mounted) setState(() => _submitError = ldShopErrorText(e));
    } finally {
      if (mounted) setState(() => _checkingPending = false);
    }
  }

  Future<void> _handleResult(
    LdShopSubmitResult result, {
    required bool navigate,
  }) async {
    final t = context.l10n;
    switch (result) {
      case LdShopSubmitCreated(:final order):
        final cancelled =
            order.status == LdShopOrderStatus.cancelled ||
            order.status == LdShopOrderStatus.expired;
        if (navigate && !cancelled) {
          Navigator.of(context).pop(order);
          return;
        }
        final pending = await _checkout.pending();
        if (!mounted) return;
        if (cancelled) {
          // 之前那笔已经取消了：可以重新下单
          ToastService.showInfo(t.ldShop_previousOrderCancelled);
          setState(() => _pending = pending);
          await _loadQuote();
          return;
        }
        setState(() {
          _pending = pending;
          _previousOrder = order;
        });
      case LdShopSubmitRejected(:final error):
        setState(() {
          _pending = null;
          _submitError = ldShopErrorText(error);
        });
        await _refreshProduct();
        await _loadQuote();
      case LdShopSubmitUncertain(:final inFlight):
        final pending = await _checkout.pending();
        if (!mounted) return;
        setState(() {
          _pending = pending;
          _submitError = inFlight
              ? t.ldShop_submitInFlight
              : t.ldShop_submitUncertain;
        });
      case LdShopSubmitAbsent():
        setState(() => _pending = null);
        if (_quote == null) await _loadQuote();
    }
  }

  // ---------------------------------------------------------------------------
  // 选券
  // ---------------------------------------------------------------------------

  Future<void> _pickCoupon() async {
    final quote = _quote;
    if (quote == null || _submitting) {
      if (_quoteError != null) await _loadQuote();
      return;
    }
    final choice = await AppBottomSheet.show<_CouponChoice>(
      context: context,
      title: context.l10n.ldShop_chooseCoupon,
      builder: (_) => _CouponPicker(quote: quote, selected: _selectedClaimId),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _selectedClaimId = quote.eligibleCoupon(choice.claimId)?.claimId;
      _couponMode = LdShopCouponMode.manual;
      _couponNotice = _selectedClaimId == null
          ? context.l10n.ldShop_couponNoneChosen
          : context.l10n.ldShop_couponApplied;
    });
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _submitting || _checkingPending;
    return PopScope(
      // 提交中不让关：关了也不会丢单，但用户看不到结果
      canPop: !busy,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _initializing
                    ? const [
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ]
                    : [
                        _buildProduct(theme),
                        const SizedBox(height: 12),
                        if (_pending != null || _previousOrder != null) ...[
                          _buildPendingBanner(theme),
                          const SizedBox(height: 12),
                        ],
                        _buildQuantity(theme),
                        const SizedBox(height: 8),
                        _buildCoupon(theme),
                        const SizedBox(height: 8),
                        _buildAmount(theme),
                        const SizedBox(height: 12),
                        _buildNotice(theme),
                        if (_submitError != null) ...[
                          const SizedBox(height: 12),
                          _buildError(theme, _submitError!),
                        ],
                        const SizedBox(height: 16),
                      ],
              ),
            ),
          ),
          if (!_initializing) _buildSubmit(theme),
        ],
      ),
    );
  }

  Widget _buildProduct(ThemeData theme) {
    final product = _product;
    return Row(
      children: [
        LdShopImage(
          url: product.imageUrl,
          width: 56,
          height: 56,
          borderRadius: theme.extension<MojianTokens>() != null ? 4 : 10,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              LdShopPriceText(
                price: product.finalPrice,
                original: product.hasDiscount ? product.price : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPendingBanner(ThemeData theme) {
    final t = context.l10n;
    final previous = _previousOrder;
    final color = previous != null
        ? ldShopAccent(theme)
        : (theme.extension<MojianTokens>()?.gold ?? Colors.orange.shade700);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(
          theme.extension<MojianTokens>() != null ? 4 : 12,
        ),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                previous != null
                    ? Symbols.receipt_long_rounded
                    : Symbols.hourglass_top_rounded,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  previous != null
                      ? t.ldShop_previousOrderTitle
                      : t.ldShop_pendingTitle,
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            previous != null
                ? t.ldShop_previousOrderBody(previous.orderNo)
                : t.ldShop_pendingBody,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: previous != null
                ? [
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context).pop(previous),
                      child: Text(t.ldShop_viewOrder),
                    ),
                    // 记录已清（有定论）才允许再买一单
                    if (_pending == null)
                      TextButton(
                        onPressed: () {
                          setState(() => _previousOrder = null);
                          _loadQuote();
                        },
                        child: Text(t.ldShop_buyAgain),
                      ),
                  ]
                : [
                    FilledButton.tonal(
                      onPressed: _checkingPending
                          ? null
                          : () => _recover(replay: true),
                      child: _checkingPending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t.ldShop_checkResult),
                    ),
                    TextButton(
                      // 叠在弹层上面看订单，回来还能接着核对
                      onPressed: _checkingPending
                          ? null
                          : () => LdStoreOrdersPage.open(context),
                      child: Text(t.ldShop_myOrders),
                    ),
                  ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuantity(ThemeData theme) {
    final t = context.l10n;
    final limit = ldShopLimitLabel(_limit, loggedIn: true);
    final max = _maxQuantity;
    final enabled = !_submitting && _pending == null && _previousOrder == null;
    return _Row(
      label: t.ldShop_quantity,
      hint: limit ?? (max > 1 ? t.ldShop_quantityMax(max) : null),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.outlined(
            onPressed: enabled && _quantity > 1
                ? () => _setQuantity(_quantity - 1)
                : null,
            icon: const Icon(Symbols.remove_rounded, size: 18),
            visualDensity: VisualDensity.compact,
          ),
          SizedBox(
            width: 56,
            child: TextField(
              controller: _quantityController,
              enabled: enabled && max > 1,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed != null) _setQuantity(parsed, fromField: true);
              },
              onSubmitted: (_) => _setQuantity(_quantity),
            ),
          ),
          IconButton.outlined(
            onPressed: enabled && _quantity < max
                ? () => _setQuantity(_quantity + 1)
                : null,
            icon: const Icon(Symbols.add_rounded, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildCoupon(ThemeData theme) {
    final t = context.l10n;
    final quote = _quote;
    final selected = _selectedCoupon;
    final String summary;
    if (quote == null) {
      summary = _quoteLoading ? t.common_loading : t.ldShop_couponUnavailable;
    } else if (selected != null) {
      summary = _couponMode == LdShopCouponMode.auto
          ? t.ldShop_couponAutoSelected(selected.campaign.name)
          : t.ldShop_couponSelected(selected.campaign.name);
    } else if (quote.eligibleCoupons.isNotEmpty) {
      summary = t.ldShop_couponAvailableUnused(quote.eligibleCoupons.length);
    } else {
      summary = t.ldShop_couponNone;
    }
    return InkWell(
      onTap: _pending == null && _previousOrder == null ? _pickCoupon : null,
      borderRadius: BorderRadius.circular(8),
      child: _Row(
        label: t.ldShop_coupon,
        hint: _couponNotice,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected != null ? ldShopAccent(theme) : null,
                ),
              ),
            ),
            Icon(
              Symbols.chevron_right_rounded,
              size: 20,
              color: ldShopSubtle(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmount(ThemeData theme) {
    final t = context.l10n;
    final quote = _quote;
    final subtle = ldShopSubtle(theme);
    final original = quote?.originalPrice ?? _product.price * _quantity;
    final subtotal = quote?.productSubtotal ?? _product.finalPrice * _quantity;
    final productDiscount = original - subtotal;
    final couponDiscount = _selectedCoupon?.couponDiscountAmount ?? 0;
    final payable = _payable;
    Widget line(String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: subtle),
            ),
          ),
          Text(value, style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
    return LdShopSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line(t.ldShop_originalSubtotal, ldShopAmount(original)),
          if (productDiscount > 0.009)
            line(
              t.ldShop_productDiscount,
              '-${ldShopAmount(productDiscount)}',
              color: ldShopAccent(theme),
            ),
          if (couponDiscount > 0)
            line(
              t.ldShop_couponDiscount,
              '-${ldShopAmount(couponDiscount)}',
              color: ldShopAccent(theme),
            ),
          const Divider(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  t.ldShop_payable(_quantity),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (_quoteLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (payable == null)
                TextButton(
                  onPressed: _submitting ? null : _loadQuote,
                  child: Text(t.ldShop_requote),
                )
              else
                LdShopPriceText(price: payable, large: true),
            ],
          ),
          if (_quoteError != null && !_quoteLoading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                ldShopErrorText(_quoteError!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNotice(ThemeData theme) {
    final t = context.l10n;
    final auto =
        _product.type == LdShopProductType.cdk || _product.autoDelivery;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Symbols.info_rounded, size: 16, color: ldShopSubtle(theme)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${auto ? t.ldShop_deliveryAutoNotice : t.ldShop_deliveryManualNotice}'
            '${t.ldShop_paymentNotice}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: ldShopSubtle(theme),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(ThemeData theme, String message) {
    final color = theme.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Symbols.error_rounded, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildSubmit(ThemeData theme) {
    final t = context.l10n;
    final block = _blockMessage;
    final payable = _payable;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: FilledButton(
        onPressed: _canSubmit ? _submit : null,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: _submitting
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(t.ldShop_submitting),
                ],
              )
            : Text(
                block ??
                    (payable == null
                        ? t.ldShop_confirmExchange
                        : t.ldShop_confirmExchangeAmount(
                            ldShopAmount(payable),
                          )),
              ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.trailing, this.hint});

  final String label;
  final String? hint;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (hint != null)
                  Text(
                    hint!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ldShopSubtle(theme),
                    ),
                  ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

/// 选券结果（claimId 为 null = 不用券）。
class _CouponChoice {
  const _CouponChoice(this.claimId);

  final String? claimId;
}

class _CouponPicker extends StatelessWidget {
  const _CouponPicker({required this.quote, required this.selected});

  final LdShopQuote quote;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.l10n;
    final subtle = ldShopSubtle(theme);
    final eligible = quote.eligibleCoupons;
    final ineligible = quote.ineligibleCoupons;
    Widget option({
      required String? claimId,
      required String title,
      String? subtitle,
      String? saving,
    }) {
      final checked = claimId == selected;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          checked
              ? Symbols.radio_button_checked_rounded
              : Symbols.radio_button_unchecked_rounded,
          color: checked ? ldShopAccent(theme) : subtle,
        ),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: saving == null
            ? null
            : Text(
                saving,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ldShopAccent(theme),
                ),
              ),
        onTap: () => Navigator.of(context).pop(_CouponChoice(claimId)),
      );
    }

    return ListView(
      shrinkWrap: true,
      children: [
        option(claimId: null, title: t.ldShop_couponDontUse),
        for (final coupon in eligible)
          option(
            claimId: coupon.claimId,
            title: coupon.campaign.name,
            subtitle: [
              ldShopCouponRule(coupon.campaign),
              if (coupon.campaign.expiresAt != null)
                t.ldShop_couponExpiresAt(
                  TimeUtils.formatDetailTime(coupon.campaign.expiresAt),
                ),
            ].join(' · '),
            saving: '-${ldShopAmount(coupon.couponDiscountAmount)}',
          ),
        if (ineligible.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            t.ldShop_couponIneligible,
            style: theme.textTheme.labelMedium?.copyWith(color: subtle),
          ),
          for (final coupon in ineligible)
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: false,
              leading: const Icon(Symbols.block_rounded),
              title: Text(coupon.campaign.name),
              subtitle: Text(coupon.reason ?? t.ldShop_couponNotApplicable),
            ),
        ],
      ],
    );
  }
}
