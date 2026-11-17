import 'dart:convert';

import '../../utils/time_utils.dart';
import 'ld_store_models.dart';

/// LD士多商城（浏览、下单、订单、优惠券）的数据模型。
///
/// 字段来自商城开源前端（caigg188/LDStatusPro 的 ld-store）与公开接口的实测。
/// 接口 snake_case 与 camelCase 混用：统一先用 [camelizeLdStoreWire] 转成
/// camelCase 再读（同名 camelCase 优先）。订单、优惠券这些需要登录的接口没有
/// 真实样本，解析一律宽松：缺字段给默认值，不抛异常。
///
/// 注意：订单里的发货内容（卡密）只放在 [LdShopOrder.deliveryContent]，
/// 任何 `toString` / 日志都不能带上它。

// -----------------------------------------------------------------------------
// 解析工具
// -----------------------------------------------------------------------------

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

/// 非空字符串（数字也转成字符串，`id` 可能是数字也可能是 UUID）。
String? _str(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  if (value is num || value is bool) return '$value';
  return null;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : null;
  if (value is String) {
    final text = value.trim();
    return int.tryParse(text) ?? double.tryParse(text)?.toInt();
  }
  return null;
}

int _int(Object? value, [int fallback = 0]) => _intOrNull(value) ?? fallback;

int _nonNegative(int value) => value < 0 ? 0 : value;

double? _doubleOrNull(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) return double.tryParse(value.trim());
  return null;
}

double _double(Object? value, [double fallback = 0]) =>
    _doubleOrNull(value) ?? fallback;

bool? _boolOrNull(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true' || '1':
        return true;
      case 'false' || '0':
        return false;
    }
  }
  return null;
}

final _naiveDateTime = RegExp(
  r'^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)$',
);
final _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _epochDigits = RegExp(r'^\d{10}(?:\d{3})?$');

/// 商城时间的统一入口（与商城前端 `normalizeTimestampMs` 同口径）：
/// - 带时区的 ISO 串（线上实测是 `2026-11-17T05:21:55.805Z`）直接交给
///   [TimeUtils.parseUtcTime]；
/// - 秒 / 毫秒时间戳、`YYYY-MM-DD`、不带时区的 `YYYY-MM-DD HH:mm[:ss]`
///   一律按 UTC 处理（商城前端也是这样），先规整成 ISO UTC 串再交给它。
DateTime? ldShopTime(Object? value) {
  if (value == null) return null;
  if (value is num) return _fromEpoch(value);
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  if (_epochDigits.hasMatch(text)) return _fromEpoch(int.parse(text));
  if (_dateOnly.hasMatch(text)) {
    return TimeUtils.parseUtcTime('${text}T00:00:00Z');
  }
  final naive = _naiveDateTime.firstMatch(text);
  if (naive != null) {
    return TimeUtils.parseUtcTime('${naive.group(1)}T${naive.group(2)}Z');
  }
  return TimeUtils.parseUtcTime(text);
}

DateTime? _fromEpoch(num value) {
  if (!value.isFinite || value <= 0) return null;
  final ms = value < 10000000000 ? value * 1000 : value;
  return TimeUtils.parseUtcTime(
    DateTime.fromMillisecondsSinceEpoch(
      ms.toInt(),
      isUtc: true,
    ).toIso8601String(),
  );
}

/// 发往商城的资源 id：纯数字的旧 id 按数字发（与商城前端 normalizeResourceId
/// 一致），UUID 原样发字符串。
Object ldShopWireId(String id) {
  final text = id.trim();
  if (RegExp(r'^[1-9]\d{0,15}$').hasMatch(text)) {
    return int.parse(text);
  }
  return text;
}

// -----------------------------------------------------------------------------
// 分页
// -----------------------------------------------------------------------------

class LdShopPagination {
  const LdShopPagination({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.totalPages,
    required this.hasMore,
  });

  /// [received] 是这一页实际拿到的条数（没有分页信息时用来猜是否还有下一页）。
  factory LdShopPagination.fromJson(
    Object? data, {
    required int page,
    required int pageSize,
    required int received,
  }) {
    final json = _map(data);
    final currentPage = _intOrNull(json['page']) ?? page;
    final size = _intOrNull(json['pageSize']) ?? pageSize;
    // total 可能是字符串数字（PostgreSQL count）
    final total = _intOrNull(json['total']) ?? 0;
    final totalPages =
        _intOrNull(json['totalPages']) ??
        (size > 0 ? (total / size).ceil() : 0);
    final hasMore =
        _boolOrNull(json['hasMore']) ??
        (json.isEmpty ? received >= size : currentPage < totalPages);
    return LdShopPagination(
      page: currentPage,
      pageSize: size,
      total: total,
      totalPages: totalPages,
      hasMore: hasMore && received > 0,
    );
  }

  final int page;
  final int pageSize;
  final int total;
  final int totalPages;
  final bool hasMore;
}

// -----------------------------------------------------------------------------
// 分类与商品
// -----------------------------------------------------------------------------

class LdShopCategory {
  const LdShopCategory({
    required this.id,
    required this.name,
    this.icon,
    this.sortOrder = 0,
    this.productCount = 0,
  });

  static LdShopCategory? fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final id = _str(json['id']);
    final name = _str(json['name']);
    if (id == null || name == null) return null;
    return LdShopCategory(
      id: id,
      name: name,
      icon: _str(json['icon']),
      sortOrder: _int(json['sortOrder']),
      productCount: _int(json['productCount']),
    );
  }

  final String id;
  final String name;

  /// 分类图标（一个 emoji）
  final String? icon;
  final int sortOrder;
  final int productCount;

  static List<LdShopCategory> listFromJson(Object? data) {
    final json = _map(data);
    final items = _list(json['categories'] ?? data)
        .map(LdShopCategory.fromJson)
        .whereType<LdShopCategory>()
        .toList();
    items.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return items;
  }
}

enum LdShopProductType {
  /// 普通物品：卖家手动发货
  normal,

  /// 自动发卡
  cdk,

  /// 外链物品：没有站内订单，跳卖家给的链接
  link,

  /// 小店：没有站内订单，跳小店
  store;

  static LdShopProductType parse(Object? value) {
    final text = '${value ?? ''}'.trim().toLowerCase();
    return LdShopProductType.values.firstWhere(
      (type) => type.name == text,
      orElse: () => LdShopProductType.normal,
    );
  }

  /// 有站内订单（能在 App 里下单）
  bool get isPlatformOrder =>
      this == LdShopProductType.normal || this == LdShopProductType.cdk;
}

enum LdShopLimitMode { none, perOrder, perUser }

/// 限购规则（移植自商城前端 `utils/purchaseLimit.js`）。
class LdShopPurchaseLimit {
  const LdShopPurchaseLimit({
    this.mode = LdShopLimitMode.none,
    this.quantity = 0,
    this.periodDays = 0,
    this.purchasedQuantity,
    this.reservedQuantity,
    this.remainingQuantity,
    this.reached = false,
    this.bypassed = false,
    this.nextAvailableAt,
  });

  static const none = LdShopPurchaseLimit();

  /// [source] 是商品（或核价结果）本身：`purchaseLimit` 没给时退回
  /// `purchaseLimitType` / `maxPurchaseQuantity` / `purchaseLimitPeriodDays`。
  factory LdShopPurchaseLimit.fromSource(Map<String, Object?> source) {
    final raw = _map(source['purchaseLimit']);
    final sharedCdk =
        _boolOrNull(source['sharedCdkEnabled']) == true &&
        LdShopProductType.parse(source['productType']) == LdShopProductType.cdk;
    final fallbackQuantity = _int(source['maxPurchaseQuantity']);
    var modeText =
        _str(raw['mode']) ??
        _str(source['purchaseLimitType']) ??
        (fallbackQuantity > 0 ? 'per_order' : 'none');
    var quantity = _intOrNull(raw['quantity']) ?? fallbackQuantity;
    var periodDays =
        _intOrNull(raw['periodDays']) ??
        _int(source['purchaseLimitPeriodDays']);
    if (sharedCdk) {
      // 共享卡密：每人限 1 件
      modeText = 'per_user';
      quantity = 1;
      periodDays = 0;
    }
    var mode = switch (modeText) {
      'per_order' => LdShopLimitMode.perOrder,
      'per_user' => LdShopLimitMode.perUser,
      'none' => LdShopLimitMode.none,
      _ => quantity > 0 ? LdShopLimitMode.perOrder : LdShopLimitMode.none,
    };
    if (quantity < 1) {
      quantity = 0;
      mode = LdShopLimitMode.none;
    }
    if (mode != LdShopLimitMode.perUser || periodDays < 0 || periodDays > 365) {
      periodDays = 0;
    }
    int? optional(Object? value) {
      final parsed = _intOrNull(value);
      return parsed == null || parsed < 0 ? null : parsed;
    }

    return LdShopPurchaseLimit(
      mode: mode,
      quantity: quantity,
      periodDays: periodDays,
      purchasedQuantity: optional(raw['purchasedQuantity']),
      reservedQuantity: optional(raw['reservedQuantity']),
      remainingQuantity: optional(raw['remainingQuantity']),
      reached: _boolOrNull(raw['reached']) ?? false,
      bypassed: _boolOrNull(raw['bypassed']) ?? false,
      nextAvailableAt: ldShopTime(raw['nextAvailableAt']),
    );
  }

  final LdShopLimitMode mode;
  final int quantity;
  final int periodDays;
  final int? purchasedQuantity;
  final int? reservedQuantity;

  /// 登录后才有：这个账号还能买几件
  final int? remainingQuantity;
  final bool reached;
  final bool bypassed;
  final DateTime? nextAvailableAt;

  /// 本单最多可买几件；0 = 不限。
  int get maximum {
    switch (mode) {
      case LdShopLimitMode.none:
        return 0;
      case LdShopLimitMode.perUser:
        final remaining = remainingQuantity;
        if (remaining != null) return remaining < 0 ? 0 : remaining;
        return quantity;
      case LdShopLimitMode.perOrder:
        return quantity;
    }
  }

  bool get isReached =>
      mode == LdShopLimitMode.perUser &&
      !bypassed &&
      (reached || (remainingQuantity != null && remainingQuantity! <= 0));
}

/// 商品（列表项与详情共用；详情多 description、canPurchase 等字段）。
class LdShopProduct {
  const LdShopProduct({
    required this.id,
    required this.name,
    this.description = '',
    this.imageUrl,
    this.type = LdShopProductType.normal,
    this.price = 0,
    this.discount = 1,
    this.finalPrice = 0,
    this.availableStock = 0,
    this.unlimitedStock = false,
    this.totalStock,
    this.soldCount = 0,
    this.autoDelivery = false,
    this.categoryId,
    this.categoryName,
    this.categoryIcon,
    this.sellerUsername,
    this.sellerName,
    this.sellerAvatar,
    this.sellerTrustLevel,
    this.sellerUserId,
    this.purchaseLimit = LdShopPurchaseLimit.none,
    this.purchaseTrustLevel = 0,
    this.canPurchase,
    this.isFavorited,
    this.isTestMode = false,
    this.viewCount = 0,
    this.createdAt,
  });

  static LdShopProduct? fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final id = _str(json['id']);
    final name = _str(json['name']);
    if (id == null || name == null) return null;
    final type = LdShopProductType.parse(json['productType'] ?? json['type']);
    final price = _double(json['price']);
    final rawDiscount = _doubleOrNull(json['discount']);
    final discount = rawDiscount != null && rawDiscount > 0 && rawDiscount <= 1
        ? rawDiscount
        : 1.0;
    final cdkStats = _map(json['cdkStats']);
    final stock = _stockOf(json, type, cdkStats);
    final trust = _int(json['purchaseTrustLevel']);
    return LdShopProduct(
      id: id,
      name: name,
      description: _str(json['description']) ?? '',
      imageUrl: _httpUrl(json['imageUrl']),
      type: type,
      price: price,
      discount: discount,
      // 详情接口不给 final_price，按 price × discount 算
      finalPrice: _doubleOrNull(json['finalPrice']) ?? price * discount,
      availableStock: stock.available,
      unlimitedStock: stock.unlimited,
      totalStock: _intOrNull(cdkStats['total']),
      soldCount: _nonNegative(_int(json['soldCount'])),
      autoDelivery:
          _boolOrNull(json['autoDelivery']) ?? type == LdShopProductType.cdk,
      categoryId: _str(json['categoryId']),
      categoryName: _str(json['categoryName']),
      categoryIcon: _str(json['categoryIcon']),
      sellerUsername: _str(json['sellerUsername']),
      sellerName: _str(json['sellerName']),
      sellerAvatar: _httpUrl(json['sellerAvatar']),
      sellerTrustLevel: _intOrNull(json['sellerTrustLevel']),
      sellerUserId: _str(json['sellerUserId']),
      purchaseLimit: LdShopPurchaseLimit.fromSource(json),
      purchaseTrustLevel: trust < 0 ? 0 : (trust > 4 ? 4 : trust),
      canPurchase: _boolOrNull(json['canPurchase']),
      isFavorited: _boolOrNull(json['isFavorited']),
      isTestMode: _boolOrNull(json['isTestMode']) ?? false,
      viewCount: _int(json['viewCount']),
      createdAt: ldShopTime(json['createdAt']),
    );
  }

  /// 库存（移植自商城前端 `getAvailableStock` / `isUnlimitedStock`）：
  /// 详情接口算好的 availableStock 是买家侧的权威值，-1 表示不限；
  /// 没给时看卡密统计，再退回原始 stock。
  static ({int available, bool unlimited}) _stockOf(
    Map<String, Object?> json,
    LdShopProductType type,
    Map<String, Object?> cdkStats,
  ) {
    final direct = _intOrNull(json['availableStock']);
    if (direct != null) {
      return direct == -1
          ? (available: -1, unlimited: true)
          : (available: direct < 0 ? 0 : direct, unlimited: false);
    }
    final cdkAvailable = _intOrNull(cdkStats['available']);
    if (cdkAvailable != null) {
      return cdkAvailable == -1
          ? (available: -1, unlimited: true)
          : (available: cdkAvailable < 0 ? 0 : cdkAvailable, unlimited: false);
    }
    if (type == LdShopProductType.cdk && _intOrNull(cdkStats['total']) == -1) {
      return (available: -1, unlimited: true);
    }
    final stock = _int(json['stock']);
    return stock == -1
        ? (available: -1, unlimited: true)
        : (available: stock < 0 ? 0 : stock, unlimited: false);
  }

  final String id;
  final String name;

  /// Markdown；图片不内嵌（见 `ld_store_description.dart`）
  final String description;

  /// 单张商品图，任意外链域名，要容忍加载失败
  final String? imageUrl;
  final LdShopProductType type;

  /// 原价（LDC）
  final double price;

  /// 折扣 0-1，1 = 不打折
  final double discount;

  /// 现价（LDC）
  final double finalPrice;

  /// 可买库存；[unlimitedStock] 时为 -1
  final int availableStock;
  final bool unlimitedStock;
  final int? totalStock;
  final int soldCount;
  final bool autoDelivery;
  final String? categoryId;
  final String? categoryName;
  final String? categoryIcon;
  final String? sellerUsername;
  final String? sellerName;
  final String? sellerAvatar;
  final int? sellerTrustLevel;
  final String? sellerUserId;
  final LdShopPurchaseLimit purchaseLimit;

  /// 购买需要的最低信任等级（0 = 不限）
  final int purchaseTrustLevel;

  /// 登录后才有；null = 不知道
  final bool? canPurchase;
  final bool? isFavorited;
  final bool isTestMode;
  final int viewCount;
  final DateTime? createdAt;

  bool get hasDiscount => discount < 1 && finalPrice < price;

  bool get isOutOfStock =>
      type.isPlatformOrder && !unlimitedStock && availableStock <= 0;

  /// 本单可选的最大数量（移植自 `resolveCheckoutQuantityMaximum`）。
  /// [limit] 默认用商品自己的限购，核价结果里有更准的（带剩余额度）时传它。
  int maxQuantity([LdShopPurchaseLimit? limit]) {
    final effective = limit ?? purchaseLimit;
    final limits = <int>[platformMaxQuantity];
    final byLimit = effective.maximum;
    if (byLimit > 0 || effective.isReached) limits.add(byLimit);
    if (!unlimitedStock || availableStock > 0) {
      limits.add(availableStock < 0 ? 0 : availableStock);
    }
    final maximum = limits.reduce((a, b) => a < b ? a : b);
    return maximum > 0 ? maximum : 1;
  }

  /// 商城平台单笔上限
  static const platformMaxQuantity = 5000;
}

class LdShopProductPage {
  const LdShopProductPage({required this.products, required this.pagination});

  factory LdShopProductPage.fromJson(
    Object? data, {
    required int page,
    required int pageSize,
  }) {
    final json = _map(data);
    final products = _list(json['products'])
        .map(LdShopProduct.fromJson)
        .whereType<LdShopProduct>()
        .toList();
    return LdShopProductPage(
      products: products,
      pagination: LdShopPagination.fromJson(
        json['pagination'],
        page: page,
        pageSize: pageSize,
        received: products.length,
      ),
    );
  }

  final List<LdShopProduct> products;
  final LdShopPagination pagination;
}

String? _httpUrl(Object? value) {
  final text = _str(value);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  if (uri.host.isEmpty) return null;
  return text;
}

// -----------------------------------------------------------------------------
// 优惠券与核价
// -----------------------------------------------------------------------------

enum LdShopDiscountType { fixedAmount, percentage, unknown }

/// 优惠券活动（券面信息）。
class LdShopCouponCampaign {
  const LdShopCouponCampaign({
    this.id,
    this.name = '',
    this.discountType = LdShopDiscountType.unknown,
    this.fixedAmount = 0,
    this.percentageBps = 0,
    this.minSpend = 0,
    this.scopeIsProduct = false,
    this.productId,
    this.productName,
    this.sellerUsername,
    this.startsAt,
    this.expiresAt,
  });

  factory LdShopCouponCampaign.fromJson(Object? data) {
    final json = _map(data);
    return LdShopCouponCampaign(
      id: _str(json['id']),
      name: _str(json['name']) ?? '',
      discountType: switch (_str(json['discountType'])) {
        'fixed_amount' => LdShopDiscountType.fixedAmount,
        'percentage' => LdShopDiscountType.percentage,
        _ => LdShopDiscountType.unknown,
      },
      fixedAmount: _double(json['fixedAmount']),
      percentageBps: _int(json['percentageBps']),
      minSpend: _double(json['minSpend']),
      scopeIsProduct: _str(json['scopeType']) == 'product',
      productId: _str(json['productId']),
      productName: _str(json['productName']),
      sellerUsername: _str(json['sellerUsername']),
      startsAt: ldShopTime(json['startsAt']),
      expiresAt: ldShopTime(json['expiresAt']),
    );
  }

  final String? id;
  final String name;
  final LdShopDiscountType discountType;

  /// 满减券减多少 LDC（整单一次）
  final double fixedAmount;

  /// 折扣券：万分比（8500 = 8.5 折），只优惠 1 件
  final int percentageBps;
  final double minSpend;

  /// true = 指定物品券；false = 店铺券
  final bool scopeIsProduct;
  final String? productId;
  final String? productName;
  final String? sellerUsername;
  final DateTime? startsAt;
  final DateTime? expiresAt;

  /// 折扣券的「几折」（8500 → 8.5）
  double get discountTenths => percentageBps / 1000;
}

/// 核价结果里的一张券（可用或不可用）。
class LdShopQuoteCoupon {
  const LdShopQuoteCoupon({
    required this.claimId,
    required this.eligible,
    required this.campaign,
    this.couponDiscountAmount = 0,
    this.payableAmount,
    this.reason,
  });

  static LdShopQuoteCoupon? fromJson(Object? data) {
    final json = _map(data);
    final claimId = _str(json['claimId']);
    if (claimId == null) return null;
    return LdShopQuoteCoupon(
      claimId: claimId,
      eligible: _boolOrNull(json['eligible']) ?? false,
      campaign: LdShopCouponCampaign.fromJson(json['campaign']),
      couponDiscountAmount: _double(json['couponDiscountAmount']),
      payableAmount: _doubleOrNull(json['payableAmount']),
      reason: _str(json['reason']),
    );
  }

  final String claimId;
  final bool eligible;
  final LdShopCouponCampaign campaign;
  final double couponDiscountAmount;

  /// 用了这张券之后的应付
  final double? payableAmount;

  /// 不可用的原因
  final String? reason;
}

/// `POST /api/shop/orders/quote` 的核价结果（不产生订单）。
class LdShopQuote {
  const LdShopQuote({
    required this.productId,
    required this.quantity,
    required this.payableAmount,
    this.originalPrice,
    this.productSubtotal,
    this.coupons = const [],
    this.purchaseLimit,
  });

  factory LdShopQuote.fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final payable = _doubleOrNull(json['payableAmount']);
    final quantity = _intOrNull(json['quantity']);
    if (payable == null || quantity == null || quantity < 1) {
      throw const FormatException('LD士多核价结果格式不对');
    }
    return LdShopQuote(
      productId: _str(json['productId']) ?? '',
      quantity: quantity,
      payableAmount: payable,
      originalPrice: _doubleOrNull(json['originalPrice']),
      productSubtotal: _doubleOrNull(json['productSubtotal']),
      coupons: _list(json['coupons'])
          .map(LdShopQuoteCoupon.fromJson)
          .whereType<LdShopQuoteCoupon>()
          .toList(),
      purchaseLimit: json['purchaseLimit'] is Map
          ? LdShopPurchaseLimit.fromSource(json)
          : null,
    );
  }

  final String productId;
  final int quantity;

  /// 不用券时的应付
  final double payableAmount;
  final double? originalPrice;
  final double? productSubtotal;
  final List<LdShopQuoteCoupon> coupons;

  /// 核价时带回的限购（含这个账号的剩余额度）
  final LdShopPurchaseLimit? purchaseLimit;

  List<LdShopQuoteCoupon> get eligibleCoupons =>
      coupons.where((c) => c.eligible).toList();

  List<LdShopQuoteCoupon> get ineligibleCoupons =>
      coupons.where((c) => !c.eligible).toList();

  LdShopQuoteCoupon? eligibleCoupon(String? claimId) {
    if (claimId == null) return null;
    for (final coupon in coupons) {
      if (coupon.eligible && coupon.claimId == claimId) return coupon;
    }
    return null;
  }

  /// 选了 [claimId]（可为 null）时的应付
  double payableWith(String? claimId) =>
      eligibleCoupon(claimId)?.payableAmount ?? payableAmount;
}

/// 「我的优惠券」里的一张。
class LdShopCoupon {
  const LdShopCoupon({
    required this.claimId,
    required this.campaign,
    this.claimStatus,
    this.status,
    this.actualDiscountAmount = 0,
    this.usedAt,
    this.usedOrderNo,
    this.reservedOrderNo,
    this.invalidReason,
  });

  static LdShopCoupon? fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final claimId = _str(json['claimId'] ?? json['id']);
    if (claimId == null) return null;
    return LdShopCoupon(
      claimId: claimId,
      campaign: LdShopCouponCampaign.fromJson(json['campaign']),
      claimStatus: _str(json['claimStatus']),
      status: _str(json['status']),
      actualDiscountAmount: _double(json['actualDiscountAmount']),
      usedAt: ldShopTime(json['usedAt']),
      usedOrderNo: _str(json['usedOrderNo']),
      reservedOrderNo: _str(json['reservedOrderNo']),
      invalidReason: _str(json['invalidReason']),
    );
  }

  final String claimId;
  final LdShopCouponCampaign campaign;

  /// `reserved` = 被一笔待付款订单占用中
  final String? claimStatus;
  final String? status;
  final double actualDiscountAmount;
  final DateTime? usedAt;
  final String? usedOrderNo;
  final String? reservedOrderNo;
  final String? invalidReason;

  bool get isReserved => claimStatus == 'reserved';
}

class LdShopCouponPage {
  const LdShopCouponPage({required this.items, required this.pagination});

  factory LdShopCouponPage.fromJson(
    Object? data, {
    required int page,
    required int pageSize,
  }) {
    final json = _map(data);
    final items = _list(json['items'] ?? json['coupons'])
        .map(LdShopCoupon.fromJson)
        .whereType<LdShopCoupon>()
        .toList();
    return LdShopCouponPage(
      items: items,
      pagination: LdShopPagination.fromJson(
        json['pagination'],
        page: page,
        pageSize: pageSize,
        received: items.length,
      ),
    );
  }

  final List<LdShopCoupon> items;
  final LdShopPagination pagination;
}

// -----------------------------------------------------------------------------
// 订单
// -----------------------------------------------------------------------------

/// 订单状态的字符串常量（`pending_payment` 读成 [pending]）。
abstract final class LdShopOrderStatus {
  static const pending = 'pending';
  static const paying = 'paying';
  static const paid = 'paid';
  static const delivered = 'delivered';
  static const completed = 'completed';
  static const cancelled = 'cancelled';
  static const expired = 'expired';
  static const refundPending = 'refund_pending';
  static const refunded = 'refunded';
  static const refundFailed = 'refund_failed';
  static const externalDispute = 'external_dispute';

  /// 不会再变成「待付款」的终态（这些状态下不再打开支付页）
  static const settled = {cancelled, expired, paid, delivered, completed};

  /// 支付链接还在生成 / 支付结果还在核对
  static const paymentUnsettled = {'pending', 'creating', 'unknown'};

  static String normalize(Object? value) {
    final text = '${value ?? ''}'.trim().toLowerCase();
    return text == 'pending_payment' ? pending : text;
  }
}

/// 订单（列表与详情共用）。没有真实样本，字段名按商城前端用到的全收。
class LdShopOrder {
  const LdShopOrder({
    required this.orderNo,
    required this.status,
    required this.displayStatus,
    this.id,
    this.refundStatus,
    this.productId,
    this.productName,
    this.productImage,
    this.productType = LdShopProductType.normal,
    this.productDescription,
    this.quantity = 1,
    this.amount = 0,
    this.originalUnitPrice = 0,
    this.unitPrice = 0,
    this.productSubtotal = 0,
    this.hasProductDiscount = false,
    this.couponDiscountAmount = 0,
    this.hasCoupon = false,
    this.couponName,
    this.sellerUsername,
    this.deliveryType,
    this.deliveryContent,
    this.paymentUrl,
    this.paymentInitStatus,
    this.paymentResolutionDeadline,
    this.expireAt,
    this.createdAt,
    this.paidAt,
    this.deliveredAt,
    this.completedAt,
    this.cancelledAt,
    this.refundedAt,
    this.updatedAt,
    this.ldcTradeNo,
  });

  static LdShopOrder? fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final orderNo = _str(json['orderNo'] ?? json['orderNumber']);
    if (orderNo == null) return null;
    final product = _map(json['product']);
    final status = LdShopOrderStatus.normalize(json['status']);
    final quantity = _intOrNull(json['quantity'] ?? json['productQuantity']);
    final safeQuantity = quantity == null || quantity < 1 ? 1 : quantity;

    // 单价（移植自商城前端 `resolveOrderItemPricing`）
    final snapshotPrice = _double(product['price']);
    final originalPrice = _double(json['originalPrice']);
    final originalUnit = snapshotPrice > 0
        ? snapshotPrice
        : (originalPrice > 0 ? originalPrice / safeQuantity : 0.0);
    final rawDiscount = _doubleOrNull(product['discount']);
    final listedDiscount = rawDiscount != null && rawDiscount > 0
        ? rawDiscount
        : 1.0;
    final amount = _double(json['amount'] ?? json['totalPrice']);
    final subtotal = _double(json['productSubtotal'] ?? json['amount']);
    final subtotalDiscounted =
        originalPrice > 0 &&
        subtotal > 0 &&
        (originalPrice - subtotal).abs() > 0.009;
    final unitPrice = listedDiscount < 1
        ? originalUnit * listedDiscount
        : (subtotalDiscounted ? subtotal / safeQuantity : originalUnit);

    final snapshot = _couponSnapshot(json['couponSnapshot']);

    return LdShopOrder(
      orderNo: orderNo,
      id: _str(json['id'] ?? json['orderId']),
      status: status,
      displayStatus: LdShopOrderStatus.normalize(
        json['displayStatus'] ?? json['status'],
      ),
      refundStatus: _str(json['refundStatus']),
      productId: _str(json['productId'] ?? product['id']),
      productName: _str(
        product['name'] ?? json['productName'] ?? json['requestTitle'],
      ),
      productImage: _httpUrl(
        product['imageUrl'] ??
            json['productImage'] ??
            json['productImageUrl'] ??
            json['imageUrl'],
      ),
      productType: LdShopProductType.parse(
        json['productType'] ?? product['productType'] ?? product['type'],
      ),
      productDescription: _str(
        product['description'] ?? json['productDescription'],
      ),
      quantity: safeQuantity,
      amount: amount,
      originalUnitPrice: originalUnit,
      unitPrice: unitPrice,
      productSubtotal: subtotal,
      hasProductDiscount: listedDiscount < 1 || subtotalDiscounted,
      couponDiscountAmount: _double(
        json['couponDiscountAmount'] ?? snapshot['couponDiscountAmount'],
      ),
      hasCoupon:
          _str(json['couponClaimId']) != null ||
          _str(snapshot['campaignId']) != null,
      couponName: _str(snapshot['name']),
      sellerUsername: _str(
        json['sellerUsername'] ?? _map(json['seller'])['username'],
      ),
      deliveryType: _str(json['deliveryType']),
      deliveryContent: _deliveryText(json['cdk'] ?? json['deliveryContent']),
      paymentUrl: _str(json['paymentUrl']),
      paymentInitStatus: _str(json['paymentInitStatus']),
      paymentResolutionDeadline: ldShopTime(json['paymentResolutionDeadline']),
      expireAt:
          ldShopTime(json['payExpiredAt'] ?? json['expireAt']) ??
          ldShopTime(json['expiredAt']),
      createdAt: ldShopTime(json['createdAt']),
      paidAt: ldShopTime(json['paidAt'] ?? json['paidTime']),
      deliveredAt: ldShopTime(json['deliveredAt']),
      completedAt: ldShopTime(json['completedAt']),
      cancelledAt: ldShopTime(json['cancelledAt']),
      refundedAt: ldShopTime(json['refundedAt']),
      updatedAt: ldShopTime(json['updatedAt']),
      ldcTradeNo: _str(json['ldcTradeNo']),
    );
  }

  static Map<String, Object?> _couponSnapshot(Object? value) {
    if (value is Map) return _map(camelizeLdStoreWire(value));
    if (value is String && value.trim().isNotEmpty) {
      try {
        return _map(camelizeLdStoreWire(jsonDecode(value)));
      } catch (_) {}
    }
    return const {};
  }

  static String? _deliveryText(Object? value) {
    if (value is List) {
      final lines = value.map(_str).whereType<String>().toList();
      return lines.isEmpty ? null : lines.join('\n');
    }
    return _str(value);
  }

  final String orderNo;
  final String? id;

  /// 订单真实状态（`pending_payment` 已读成 `pending`）
  final String status;

  /// 展示用状态（商城给了 displayStatus 就用它，如 refund_failed）
  final String displayStatus;
  final String? refundStatus;
  final String? productId;
  final String? productName;
  final String? productImage;
  final LdShopProductType productType;
  final String? productDescription;
  final int quantity;

  /// 实付（LDC）
  final double amount;
  final double originalUnitPrice;
  final double unitPrice;
  final double productSubtotal;
  final bool hasProductDiscount;
  final double couponDiscountAmount;
  final bool hasCoupon;
  final String? couponName;
  final String? sellerUsername;

  /// `auto` = 自动发货，`manual` = 手动发货
  final String? deliveryType;

  /// 发货内容（卡密）。**不能写进日志。**
  final String? deliveryContent;
  final String? paymentUrl;

  /// 支付链接创建状态：pending / creating / unknown 时不要重复付款
  final String? paymentInitStatus;
  final DateTime? paymentResolutionDeadline;
  final DateTime? expireAt;
  final DateTime? createdAt;
  final DateTime? paidAt;
  final DateTime? deliveredAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final DateTime? refundedAt;
  final DateTime? updatedAt;
  final String? ldcTradeNo;

  bool get isPending => status == LdShopOrderStatus.pending;

  bool get isAwaitingPayment =>
      status == LdShopOrderStatus.pending || status == LdShopOrderStatus.paying;

  /// 待付款但支付结果还在核对（此时不能再「继续付款」）
  bool get paymentConfirming =>
      isPending &&
      LdShopOrderStatus.paymentUnsettled.contains(paymentInitStatus ?? '');

  bool get isAutoDelivery =>
      deliveryType == 'auto' ||
      (deliveryType == null && productType == LdShopProductType.cdk);

  /// 发货内容按行拆开（去空行），每行一个卡密
  List<String> get deliveryLines {
    final content = deliveryContent;
    if (content == null) return const [];
    return content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// 待付款的过期时间；没给时按商城前端的兜底（创建后 5 分钟）
  DateTime? get paymentDeadline =>
      expireAt ?? createdAt?.add(const Duration(minutes: 5));

  @override
  String toString() => 'LdShopOrder($orderNo, $status)';
}

class LdShopOrderPage {
  const LdShopOrderPage({required this.orders, required this.pagination});

  factory LdShopOrderPage.fromJson(
    Object? data, {
    required int page,
    required int pageSize,
  }) {
    final json = _map(data);
    final orders = _list(json['orders'])
        .map(LdShopOrder.fromJson)
        .whereType<LdShopOrder>()
        .toList();
    return LdShopOrderPage(
      orders: orders,
      pagination: LdShopPagination.fromJson(
        json['pagination'],
        page: page,
        pageSize: pageSize,
        received: orders.length,
      ),
    );
  }

  final List<LdShopOrder> orders;
  final LdShopPagination pagination;
}

/// 订单动态（时间线一条）。
class LdShopOrderLog {
  const LdShopOrderLog({
    required this.action,
    this.operator,
    this.note,
    this.createdAt,
  });

  factory LdShopOrderLog.fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    return LdShopOrderLog(
      action: (_str(json['action']) ?? '').toLowerCase(),
      operator: _str(json['operatorName'] ?? json['operatorType']),
      note: _str(json['remark'] ?? json['note'] ?? json['message']),
      createdAt: ldShopTime(json['createdAt'] ?? json['time']),
    );
  }

  final String action;
  final String? operator;
  final String? note;
  final DateTime? createdAt;
}

class LdShopOrderDetail {
  const LdShopOrderDetail({required this.order, this.logs = const []});

  factory LdShopOrderDetail.fromJson(Object? data) {
    final json = _map(data);
    final order = LdShopOrder.fromJson(json['order']);
    if (order == null) throw const FormatException('LD士多订单详情格式不对');
    final logs = _list(json['logs']).map(LdShopOrderLog.fromJson).toList()
      ..sort((a, b) {
        final at = a.createdAt, bt = b.createdAt;
        if (at == null || bt == null) return at == null ? 1 : -1;
        return bt.compareTo(at);
      });
    return LdShopOrderDetail(order: order, logs: logs);
  }

  final LdShopOrder order;

  /// 新的在前
  final List<LdShopOrderLog> logs;
}

/// `POST /api/shop/orders` 创建结果（也是 order-submissions 查询里的 order）。
class LdShopOrderCreated {
  const LdShopOrderCreated({
    required this.orderNo,
    required this.orderId,
    this.paymentUrl,
    this.status,
    this.paymentState,
    this.expireAt,
    this.paymentResolutionDeadline,
  });

  /// 缺 orderNo / orderId 返回 null（调用方按「结果不确定」处理）。
  static LdShopOrderCreated? fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    final orderNo = _str(json['orderNo']);
    final orderId = _str(json['orderId'] ?? json['id']);
    if (orderNo == null || orderId == null) return null;
    return LdShopOrderCreated(
      orderNo: orderNo,
      orderId: orderId,
      paymentUrl: _str(json['paymentUrl']),
      status: json['status'] == null
          ? null
          : LdShopOrderStatus.normalize(json['status']),
      paymentState: _str(json['paymentState']),
      expireAt: ldShopTime(json['expireAt']),
      paymentResolutionDeadline: ldShopTime(json['paymentResolutionDeadline']),
    );
  }

  final String orderNo;
  final String orderId;
  final String? paymentUrl;
  final String? status;

  /// 支付链接创建状态（pending / creating / unknown = 还没定）
  final String? paymentState;
  final DateTime? expireAt;
  final DateTime? paymentResolutionDeadline;

  bool get isSettled => LdShopOrderStatus.settled.contains(status);

  /// 支付结果确认中，请勿重复兑换
  bool get paymentUnsettled =>
      LdShopOrderStatus.paymentUnsettled.contains(paymentState ?? '');

  /// 这笔提交已有定论（与商城前端 `confirmedIsResolved` 一致）
  bool get isResolved => isSettled || !paymentUnsettled;

  /// 还要去付款：有支付链接、且不是已结束的状态
  bool get needsPayment => paymentUrl != null && !isSettled;
}

/// `payment-url` / `refresh` 的返回。
class LdShopPaymentInfo {
  const LdShopPaymentInfo({this.paymentUrl, this.status, this.message});

  factory LdShopPaymentInfo.fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    return LdShopPaymentInfo(
      paymentUrl: _str(json['paymentUrl']),
      status: json['status'] == null
          ? null
          : LdShopOrderStatus.normalize(json['status']),
      message: _str(json['message']),
    );
  }

  final String? paymentUrl;
  final String? status;
  final String? message;
}

/// `GET /api/shop/order-submissions/{token}` 的结果。
class LdShopSubmissionLookup {
  const LdShopSubmissionLookup({required this.exists, this.order});

  factory LdShopSubmissionLookup.fromJson(Object? data) {
    final json = _map(data);
    final exists = _boolOrNull(json['exists']);
    if (exists == null) throw const FormatException('LD士多订单查询结果格式不对');
    return LdShopSubmissionLookup(
      exists: exists,
      order: exists ? LdShopOrderCreated.fromJson(json['order']) : null,
    );
  }

  final bool exists;
  final LdShopOrderCreated? order;
}
