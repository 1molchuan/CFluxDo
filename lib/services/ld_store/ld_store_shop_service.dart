import 'package:dio/dio.dart';

import '../../l10n/s.dart';
import 'ld_store_models.dart';
import 'ld_store_service.dart';
import 'ld_store_shop_models.dart';

/// 商城接口返回的业务失败（4xx / `success: false`），或 5xx。
///
/// [message] 是商城给的说明（可能为空）；为空时 [toString] 按状态码给通用文案。
class LdShopException implements Exception {
  const LdShopException({this.message, this.status = 0, this.code});

  final String? message;

  /// HTTP 状态码（或 `success: false` 外壳里的 status）；0 = 没拿到
  final int status;

  /// 商城错误码（`error.code`），如 `PURCHASE_LIMIT_EXCEEDED`
  final String? code;

  bool get isMaintenance => status == 503;

  @override
  String toString() {
    final text = message;
    if (text != null && text.isNotEmpty) return text;
    final t = S.current;
    return switch (status) {
      400 => t.ldShop_errorBadRequest,
      403 => t.ldShop_errorForbidden,
      404 => t.ldShop_errorNotFound,
      409 => t.ldShop_errorConflict,
      429 => t.ldShop_errorTooFrequent,
      503 => t.ldShop_maintenance,
      >= 500 => t.ldShop_errorServer,
      _ => t.ldShop_errorRequestFailed,
    };
  }
}

/// 商品列表排序（与商城前端 `productSortMapping` 一致）。
enum LdShopSort {
  /// 默认（最近更新）
  defaults('updated_at', 'DESC'),
  newest('created_at', 'DESC'),
  priceAsc('final_price', 'ASC'),
  priceDesc('final_price', 'DESC'),
  sales('sold_count', 'DESC');

  const LdShopSort(this.sortBy, this.sortOrder);

  final String sortBy;
  final String sortOrder;
}

/// LD士多商城：浏览（匿名可读）、核价、下单、订单、优惠券。
///
/// 走商城专用的 Dio（[LdStoreService.createStoreDio]：不带论坛 Cookie、强制
/// 不发 CSRF、不过论坛的盾）。需要登录的接口带 `Authorization: Bearer`；
/// 401 或认证类错误码抛 [LdStoreAuthExpiredException]，其余业务失败抛
/// [LdShopException]；没拿到响应的网络错误原样抛 [DioException]（页面的
/// ErrorView 会按网络错误展示）。
///
/// 下单的幂等与恢复在 `ld_store_checkout.dart`，这里只发请求。
class LdShopService {
  LdShopService({Dio? dio, DateTime Function()? clock})
    : _dio = dio ?? LdStoreService.createStoreDio(),
      _clock = clock ?? DateTime.now;

  static const apiBase = LdStoreService.apiBase;

  /// 支付页只认这个域名（与商城前端 `isValidLdcPaymentUrl` 一致）
  static const paymentHost = 'credit.linux.do';

  final Dio _dio;
  final DateTime Function() _clock;

  /// 支付链接必须是 https 的 credit.linux.do，别的一概不打开。
  static Uri? trustedPaymentUri(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != paymentHost ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    return uri;
  }

  // ---------------------------------------------------------------------------
  // 浏览
  // ---------------------------------------------------------------------------

  Future<List<LdShopCategory>> fetchCategories() async {
    final data = await _send('GET', '/api/shop/categories');
    return LdShopCategory.listFromJson(data);
  }

  /// 商品列表。只用 page 翻页（不用 cursor / rotationId）。
  Future<LdShopProductPage> fetchProducts({
    int page = 1,
    int pageSize = 20,
    String? categoryId,
    String? search,
    LdShopSort sort = LdShopSort.defaults,
    bool inStockOnly = false,
    LdStoreToken? token,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'pageSize': pageSize,
      if (categoryId != null && categoryId.isNotEmpty) 'categoryId': categoryId,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      'sortBy': sort.sortBy,
      'sortOrder': sort.sortOrder,
      if (inStockOnly) 'inStock': 'true',
    };
    final data = await _send(
      'GET',
      '/api/shop/products',
      query: query,
      token: _usable(token),
    );
    return LdShopProductPage.fromJson(data, page: page, pageSize: pageSize);
  }

  /// 商品详情。登录后带上凭据才有 canPurchase / isFavorited 等买家字段。
  Future<LdShopProduct> fetchProduct(String id, {LdStoreToken? token}) async {
    final data = await _send(
      'GET',
      '/api/shop/products/${Uri.encodeComponent(id)}',
      token: _usable(token),
    );
    final product = LdShopProduct.fromJson(
      data is Map ? data['product'] : null,
    );
    if (product == null) throw const LdShopException(status: 404);
    return product;
  }

  /// 外链 / 小店类商品的跳转地址（只认 http(s)）。
  Future<Uri> fetchExternalLink(String id, {LdStoreToken? token}) async {
    final data = await _send(
      'GET',
      '/api/shop/products/${Uri.encodeComponent(id)}/external-link',
      token: _usable(token),
    );
    final raw = data is Map ? data['paymentLink'] ?? data['url'] : null;
    final uri = raw is String ? Uri.tryParse(raw.trim()) : null;
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const FormatException('LD士多外链地址格式不对');
    }
    return uri;
  }

  // ---------------------------------------------------------------------------
  // 下单
  // ---------------------------------------------------------------------------

  /// 核价（不产生订单）。限购时是 409 + `PURCHASE_LIMIT_EXCEEDED`。
  Future<LdShopQuote> quote({
    required String productId,
    required int quantity,
    required LdStoreToken token,
  }) async {
    final data = await _send(
      'POST',
      '/api/shop/orders/quote',
      body: {'productId': ldShopWireId(productId), 'quantity': quantity},
      token: token,
    );
    return LdShopQuote.fromJson(data);
  }

  /// 创建订单。**不要直接调**：经 `LdShopCheckout` 调，它负责先把
  /// [submissionToken] 落盘、结果不确定时按同一个 token 查询。
  ///
  /// 响应缺 orderNo / orderId 时抛 [FormatException]（按「结果不确定」处理）。
  Future<LdShopOrderCreated> createOrder({
    required String productId,
    required int quantity,
    required String submissionToken,
    required double expectedAmount,
    String? couponClaimId,
    required LdStoreToken token,
  }) async {
    final data = await _send(
      'POST',
      '/api/shop/orders',
      body: {
        'productId': ldShopWireId(productId),
        'quantity': quantity,
        'submissionToken': submissionToken,
        'expectedAmount': expectedAmount,
        if (couponClaimId != null) 'couponClaimId': ldShopWireId(couponClaimId),
      },
      token: token,
    );
    final created = LdShopOrderCreated.fromJson(data);
    if (created == null) {
      throw const FormatException('LD士多创建订单的响应格式不对');
    }
    return created;
  }

  /// 按提交 token 查这次下单有没有生成订单。
  Future<LdShopSubmissionLookup> lookupSubmission(
    String submissionToken,
    LdStoreToken token,
  ) async {
    final data = await _send(
      'GET',
      '/api/shop/order-submissions/${Uri.encodeComponent(submissionToken)}',
      token: token,
    );
    return LdShopSubmissionLookup.fromJson(data);
  }

  // ---------------------------------------------------------------------------
  // 订单
  // ---------------------------------------------------------------------------

  /// 买家订单。[status] 为空 = 全部；可逗号分隔多个（退款类）。
  Future<LdShopOrderPage> fetchOrders({
    required LdStoreToken token,
    String status = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    final size = pageSize.clamp(1, 50);
    final data = await _send(
      'GET',
      '/api/shop/orders',
      query: {
        'role': 'buyer',
        'page': page,
        'pageSize': size,
        if (status.isNotEmpty) 'status': status,
      },
      token: token,
    );
    return LdShopOrderPage.fromJson(data, page: page, pageSize: size);
  }

  Future<LdShopOrderDetail> fetchOrder(
    String orderNo,
    LdStoreToken token,
  ) async {
    final data = await _send(
      'GET',
      '/api/shop/orders/${Uri.encodeComponent(orderNo)}',
      query: {'role': 'buyer'},
      token: token,
    );
    return LdShopOrderDetail.fromJson(data);
  }

  /// 让商城主动去 Credit 对一次账（付款回来先调它再读详情）。
  Future<LdShopPaymentInfo> refreshOrder(
    String orderNo,
    LdStoreToken token,
  ) async {
    final data = await _send(
      'POST',
      '/api/shop/orders/${Uri.encodeComponent(orderNo)}/refresh',
      token: token,
    );
    return LdShopPaymentInfo.fromJson(data);
  }

  /// 「继续付款」用的支付链接。
  Future<LdShopPaymentInfo> fetchPaymentUrl(
    String orderNo,
    LdStoreToken token,
  ) async {
    final data = await _send(
      'GET',
      '/api/shop/orders/${Uri.encodeComponent(orderNo)}/payment-url',
      token: token,
    );
    return LdShopPaymentInfo.fromJson(data);
  }

  /// 取消待付款订单。
  Future<void> cancelOrder(String orderNo, LdStoreToken token) async {
    await _send(
      'POST',
      '/api/shop/orders/${Uri.encodeComponent(orderNo)}/cancel',
      token: token,
    );
  }

  // ---------------------------------------------------------------------------
  // 优惠券
  // ---------------------------------------------------------------------------

  /// [status]：unused / used / expired。
  Future<LdShopCouponPage> fetchMyCoupons({
    required LdStoreToken token,
    String status = 'unused',
    int page = 1,
    int pageSize = 20,
  }) async {
    final data = await _send(
      'GET',
      '/api/shop/my-coupons',
      query: {'status': status, 'page': page, 'pageSize': pageSize},
      token: token,
    );
    return LdShopCouponPage.fromJson(data, page: page, pageSize: pageSize);
  }

  // ---------------------------------------------------------------------------
  // 请求
  // ---------------------------------------------------------------------------

  /// 浏览接口：凭据到期了就当匿名读，不报错。
  LdStoreToken? _usable(LdStoreToken? token) =>
      token == null || token.isExpired(_clock()) ? null : token;

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    LdStoreToken? token,
  }) async {
    if (token != null && token.isExpired(_clock())) {
      throw const LdStoreAuthExpiredException();
    }
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        '$apiBase$path',
        queryParameters: query,
        data: body,
        options: Options(
          method: method,
          contentType: body == null ? null : Headers.jsonContentType,
          headers: {
            'Accept': 'application/json',
            if (token != null) 'Authorization': 'Bearer ${token.value}',
          },
        ),
      );
    } on DioException catch (e) {
      final res = e.response;
      // 没拿到响应（断网、超时、连接被重置）：原样抛，交给调用方当网络错误
      if (res == null) rethrow;
      throw _failure(res.statusCode ?? 0, res.data, authed: token != null);
    }
    return _unwrap(response.statusCode ?? 200, response.data, token != null);
  }

  /// 成功外壳 `{success: true, data}`（偶有两层外壳）取出 data；
  /// `success: false` 按失败处理。
  static Object? _unwrap(int status, Object? body, bool authed) {
    if (body is Map) {
      if (body['success'] == false) {
        final error = body['error'];
        final payloadStatus =
            _intStatus(body['status']) ??
            _intStatus(error is Map ? error['status'] : null) ??
            status;
        throw _failure(payloadStatus, body, authed: authed);
      }
      if (body['success'] == true) {
        if (!body.containsKey('data')) {
          return {
            for (final entry in body.entries)
              if (entry.key != 'success' && entry.key != 'status')
                entry.key: entry.value,
          };
        }
        final data = body['data'];
        if (data is Map &&
            data['success'] == true &&
            data.containsKey('data')) {
          return data['data'];
        }
        return data;
      }
      return body;
    }
    if (body is List) return body;
    // 2xx 却不是 JSON（被劫持的页面、网关错误页）
    throw const FormatException('LD士多接口响应格式不对');
  }

  static Object _failure(int status, Object? body, {required bool authed}) {
    if (authed && (status == 401 || LdStoreService.isAuthError(body))) {
      return const LdStoreAuthExpiredException();
    }
    return LdShopException(
      message: _errorMessage(body),
      status: status,
      code: _errorCode(body),
    );
  }

  static int? _intStatus(Object? value) {
    final parsed = value is int ? value : int.tryParse('${value ?? ''}');
    return parsed != null && parsed >= 100 && parsed <= 599 ? parsed : null;
  }

  static String? _errorMessage(Object? body) {
    String? clean(Object? value) {
      if (value is! String) return null;
      final text = value.trim();
      // HTML 错误页不当说明
      if (text.isEmpty || text.startsWith('<')) return null;
      return text.length > 200 ? '${text.substring(0, 200)}…' : text;
    }

    if (body is String) return clean(body);
    if (body is! Map) return null;
    final error = body['error'];
    return clean(error is Map ? error['message'] : null) ??
        clean(error) ??
        clean(body['message']);
  }

  static String? _errorCode(Object? body) {
    if (body is! Map) return null;
    final error = body['error'];
    final code =
        (error is Map ? error['code'] : null) ??
        body['errorCode'] ??
        body['code'];
    final text = code == null ? '' : '$code'.trim();
    return text.isEmpty ? null : text;
  }
}
