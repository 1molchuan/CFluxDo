import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ld_store/ld_store_checkout.dart';
import 'package:fluxdo/services/ld_store/ld_store_description.dart';
import 'package:fluxdo/services/ld_store/ld_store_models.dart';
import 'package:fluxdo/services/ld_store/ld_store_service.dart';
import 'package:fluxdo/services/ld_store/ld_store_shop_models.dart';
import 'package:fluxdo/services/ld_store/ld_store_shop_service.dart';

import 'ld_store_test_support.dart';

const _api = 'https://api2.ldspro.qzz.io';
const _orders = '$_api/api/shop/orders';
const _quote = '$_api/api/shop/orders/quote';

/// 一个路由的处理：返回 [FakeRoute]，或抛 [DioException] 模拟没拿到响应。
typedef _Handler = FakeRoute Function(RequestOptions request);

/// 比 [RoutingAdapter] 多一样：handler 可以抛异常（断网 / 超时）。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.routes);

  final Map<String, _Handler> routes;
  final requests = <RequestOptions>[];

  Iterable<RequestOptions> hits(String url, [String method = 'GET']) =>
      requests.where(
        (r) =>
            '${r.uri.scheme}://${r.uri.host}${r.uri.path}' == url &&
            r.method == method,
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    final uri = request.uri;
    final key = '${uri.scheme}://${uri.host}${uri.path}';
    final handler = routes[key];
    if (handler == null) return ResponseBody.fromString('not found', 404);
    final route = handler(request);
    return ResponseBody.fromString(
      route.body is String ? route.body as String : jsonEncode(route.body),
      route.status,
      headers: {
        Headers.contentTypeHeader: [
          route.body is String ? 'text/html' : Headers.jsonContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryStore implements LdShopSubmissionStore {
  final values = <String, String>{};
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('disk full');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Map<String, Object?> _ok(Object? data) => {'success': true, 'data': data};

Map<String, Object?> _fail(String code, String message, int status) => {
  'success': false,
  'error': {'code': code, 'message': message, 'status': status},
};

Map<String, Object?> _body(RequestOptions request) {
  final data = request.data;
  if (data is Map) return data.cast<String, Object?>();
  return (jsonDecode('$data') as Map).cast<String, Object?>();
}

DioException _networkError(RequestOptions request) => DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
  message: 'connection reset',
);

void main() {
  final token = LdStoreToken.parse(
    ldStoreJwt(expiresAt: DateTime.now().add(const Duration(days: 7))),
  )!;

  group('模型解析', () {
    test('商品：snake_case 与 camelCase 都认，id 一律字符串', () {
      final snake = LdShopProduct.fromJson({
        'id': 11584,
        'name': '咕咕嘎嘎公益站注册码',
        'price': 999,
        'discount': 0.35,
        'final_price': 349.65,
        'image_url': 'https://imgbed.example.com/a.png',
        'product_type': 'cdk',
        'stock': 19,
        'sold_count': 591,
        'availableStock': 19,
        'cdkStats': {'available': 19, 'total': 610},
        'seller_username': 'feng_li',
        'seller_user_id': 253951,
        'seller_trust_level': 3,
        'purchase_trust_level': 1,
        'auto_delivery': true,
        'purchase_limit': {'mode': 'per_user', 'quantity': 1, 'periodDays': 0},
        'created_at': '2026-08-21T07:28:53.172Z',
      })!;
      final camel = LdShopProduct.fromJson({
        'id': '11584',
        'name': '咕咕嘎嘎公益站注册码',
        'price': '999',
        'discount': '0.35',
        'finalPrice': 349.65,
        'imageUrl': 'https://imgbed.example.com/a.png',
        'productType': 'cdk',
        'soldCount': '591',
        'availableStock': 19,
        'sellerUsername': 'feng_li',
        'sellerUserId': '253951',
        'purchaseTrustLevel': 1,
        'purchaseLimit': {'mode': 'per_user', 'quantity': 1},
      })!;
      for (final p in [snake, camel]) {
        expect(p.id, '11584');
        expect(p.type, LdShopProductType.cdk);
        expect(p.finalPrice, closeTo(349.65, 1e-9));
        expect(p.hasDiscount, isTrue);
        expect(p.availableStock, 19);
        expect(p.soldCount, 591);
        expect(p.sellerUserId, '253951');
        expect(p.purchaseLimit.mode, LdShopLimitMode.perUser);
        expect(p.maxQuantity(), 1);
      }
      expect(snake.createdAt, isNotNull);
    });

    test('商品：详情没有 final_price 时按 price × discount；UUID 原样；库存 -1 = 不限', () {
      final p = LdShopProduct.fromJson({
        'id': '79d70132-d298-4db5-95a4-228e5abf999f',
        'name': '小店',
        'price': 400,
        'discount': 0.9,
        'product_type': 'store',
        'stock': -1,
      })!;
      expect(p.id, '79d70132-d298-4db5-95a4-228e5abf999f');
      expect(p.finalPrice, closeTo(360, 1e-9));
      expect(p.unlimitedStock, isTrue);
      expect(p.isOutOfStock, isFalse);
      expect(p.type.isPlatformOrder, isFalse);

      // 普通物品没给 availableStock：退回原始 stock；售罄
      final normal = LdShopProduct.fromJson({
        'id': 4806,
        'name': '普通',
        'product_type': 'normal',
        'stock': 0,
        'max_purchase_quantity': 3,
      })!;
      expect(normal.isOutOfStock, isTrue);
      expect(normal.purchaseLimit.mode, LdShopLimitMode.perOrder);
      expect(normal.purchaseLimit.quantity, 3);
      // 缺 id / name 的条目直接丢掉
      expect(LdShopProduct.fromJson({'name': 'x'}), isNull);
    });

    test('分页：total 可能是字符串；没有 hasMore 时按页数算', () {
      final page = LdShopProductPage.fromJson(
        {
          'products': [
            {'id': 1, 'name': 'a'},
          ],
          'pagination': {
            'total': '223',
            'page': 1,
            'pageSize': 4,
            'totalPages': 56,
          },
        },
        page: 1,
        pageSize: 4,
      );
      expect(page.pagination.total, 223);
      expect(page.pagination.hasMore, isTrue);
      final last = LdShopPagination.fromJson(
        {'total': 5, 'page': 2, 'pageSize': 4, 'totalPages': 2},
        page: 2,
        pageSize: 4,
        received: 1,
      );
      expect(last.hasMore, isFalse);
    });

    test('订单：两种写法、pending_payment 读成 pending、卡密按行拆且不进 toString', () {
      final snake = LdShopOrder.fromJson({
        'order_no': 'LD123',
        'status': 'pending_payment',
        'product': {'id': 9, 'name': '注册码', 'price': 10, 'discount': 0.5},
        'quantity': 2,
        'amount': '10',
        'payment_url': 'https://credit.linux.do/pay/abc',
        'payment_init_status': 'unknown',
        'created_at': 1763350000,
      })!;
      expect(snake.orderNo, 'LD123');
      expect(snake.status, LdShopOrderStatus.pending);
      expect(snake.productId, '9');
      expect(snake.unitPrice, closeTo(5, 1e-9));
      expect(snake.hasProductDiscount, isTrue);
      expect(snake.paymentConfirming, isTrue);
      expect(snake.createdAt, isNotNull);

      final camel = LdShopOrder.fromJson({
        'orderNo': 'LD456',
        'status': 'delivered',
        'displayStatus': 'refund_failed',
        'productName': '卡',
        'deliveryType': 'auto',
        'cdk': 'AAAA-1111\r\n\n  BBBB-2222  \n',
        'couponSnapshot': '{"name":"新人券","couponDiscountAmount":1.5}',
      })!;
      expect(camel.displayStatus, 'refund_failed');
      expect(camel.deliveryLines, ['AAAA-1111', 'BBBB-2222']);
      expect(camel.couponName, '新人券');
      expect(camel.couponDiscountAmount, 1.5);
      expect(camel.toString(), isNot(contains('AAAA')));
      expect(LdShopOrder.fromJson({'status': 'paid'}), isNull);
    });

    test('时间：不带时区的串按 UTC，秒级时间戳也认', () {
      final a = ldShopTime('2026-11-17 05:21:55');
      final b = ldShopTime('2026-11-17T05:21:55Z');
      final c = ldShopTime(1794892915);
      final d = ldShopTime('1794892915000');
      expect(a, isNotNull);
      expect(a!.isAtSameMomentAs(b!), isTrue);
      expect(c!.isAtSameMomentAs(b), isTrue);
      expect(d!.isAtSameMomentAs(b), isTrue);
      expect(ldShopTime(''), isNull);
      expect(ldShopTime(null), isNull);
    });

    test('核价与选券：手动选的还能用就保留，失效了换成最优券', () {
      final quote = LdShopQuote.fromJson({
        'productId': 9,
        'quantity': 1,
        'payableAmount': 10,
        'coupons': [
          {
            'claimId': 'c1',
            'eligible': true,
            'campaign': {'name': '满减', 'discountType': 'fixed_amount'},
            'couponDiscountAmount': 3,
            'payableAmount': 7,
          },
          {
            'claimId': 'c2',
            'eligible': false,
            'campaign': {'name': '过期'},
            'reason': '未达门槛',
          },
        ],
      });
      expect(quote.payableWith(null), 10);
      expect(quote.payableWith('c1'), 7);
      // 不可用的券不能拿来算价
      expect(quote.payableWith('c2'), 10);

      final auto = LdShopCouponSelection.resolve(
        quote: quote,
        mode: LdShopCouponMode.auto,
        selectedClaimId: null,
      );
      expect(auto.claimId, 'c1');
      final optOut = LdShopCouponSelection.resolve(
        quote: quote,
        mode: LdShopCouponMode.manual,
        selectedClaimId: null,
      );
      expect(optOut.claimId, isNull);
      final gone = LdShopCouponSelection.resolve(
        quote: quote,
        mode: LdShopCouponMode.manual,
        selectedClaimId: 'c2',
      );
      expect(gone.claimId, 'c1');
      expect(gone.replacedManualSelection, isTrue);

      expect(
        evaluateLdShopFinalQuote(
          requestedClaimId: 'c1',
          currentClaimId: null,
          amountBefore: 7,
          amountNow: 10,
        ),
        LdShopFinalQuoteCheck.couponInvalidated,
      );
      expect(
        evaluateLdShopFinalQuote(
          requestedClaimId: null,
          currentClaimId: null,
          amountBefore: 10,
          amountNow: 12,
        ),
        LdShopFinalQuoteCheck.confirmationRequired,
      );
      expect(
        evaluateLdShopFinalQuote(
          requestedClaimId: 'c1',
          currentClaimId: 'c1',
          amountBefore: 7,
          amountNow: 7,
        ),
        LdShopFinalQuoteCheck.ok,
      );
    });
  });

  group('接口', () {
    test('浏览不带凭据；需要登录的带 Bearer；401 当作授权失效', () async {
      final adapter = _Adapter({
        '$_api/api/shop/products': (_) =>
            FakeRoute(200, body: _ok({'products': [], 'pagination': {}})),
        '$_api/api/shop/my-coupons': (_) =>
            FakeRoute(401, body: _fail('AUTH_EXPIRED', '登录已过期', 401)),
      });
      final service = LdShopService(dio: Dio()..httpClientAdapter = adapter);
      await service.fetchProducts(search: ' 注册码 ', inStockOnly: true);
      final list = adapter.requests.single;
      expect(list.headers.containsKey('Authorization'), isFalse);
      expect(list.uri.queryParameters['search'], '注册码');
      expect(list.uri.queryParameters['inStock'], 'true');
      expect(list.uri.queryParameters['sortBy'], 'updated_at');

      await expectLater(
        service.fetchMyCoupons(token: token),
        throwsA(isA<LdStoreAuthExpiredException>()),
      );
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer ${token.value}',
      );
    });

    test('业务失败带出状态码与错误码；200 + success:false 也算失败', () async {
      final adapter = _Adapter({
        _quote: (_) =>
            FakeRoute(409, body: _fail('PURCHASE_LIMIT_EXCEEDED', '已达限购', 409)),
        '$_api/api/shop/orders/LD1/cancel': (_) =>
            FakeRoute(200, body: _fail('ORDER_NOT_PENDING', '订单不能取消', 400)),
      });
      final service = LdShopService(dio: Dio()..httpClientAdapter = adapter);
      await expectLater(
        service.quote(productId: '9', quantity: 1, token: token),
        throwsA(
          isA<LdShopException>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.code, 'code', 'PURCHASE_LIMIT_EXCEEDED')
              .having((e) => e.message, 'message', '已达限购'),
        ),
      );
      // 数字 id 按数字发
      expect(_body(adapter.requests.first)['productId'], 9);
      await expectLater(
        service.cancelOrder('LD1', token),
        throwsA(isA<LdShopException>().having((e) => e.status, 'status', 400)),
      );
    });

    test('支付链接只认 https 的 credit.linux.do', () {
      expect(
        LdShopService.trustedPaymentUri('https://credit.linux.do/pay/abc?x=1'),
        isNotNull,
      );
      for (final url in [
        null,
        'http://credit.linux.do/pay/abc',
        'https://credit.linux.do.evil.com/pay',
        'https://evil.com/credit.linux.do',
        'https://credit.linux.do@evil.com/pay',
        'https://user@credit.linux.do/pay',
        'https://credit.linux.do:8443/pay',
        'javascript:alert(1)',
        'https://linux.do/pay',
      ]) {
        expect(LdShopService.trustedPaymentUri(url), isNull, reason: url);
      }
    });
  });

  group('下单幂等', () {
    late _MemoryStore store;

    LdShopCheckout checkout(
      _Adapter adapter, {
      String productId = '9',
      DateTime Function()? clock,
    }) => LdShopCheckout(
      service: LdShopService(dio: Dio()..httpClientAdapter = adapter),
      token: token,
      productId: productId,
      store: store,
      wait: () async {},
      clock: clock,
    );

    Map<String, Object?> created({String? paymentState}) => _ok({
      'orderNo': 'LD100',
      'orderId': 'b1e2',
      'paymentUrl': 'https://credit.linux.do/pay/LD100',
      'status': 'pending',
      'paymentState': ?paymentState,
    });

    setUp(() => store = _MemoryStore());

    test('先落盘再下单；成功后清掉记录', () async {
      String? savedAtPost;
      final adapter = _Adapter({
        _orders: (request) {
          savedAtPost = store.values.values.single;
          return FakeRoute(200, body: created());
        },
      });
      final c = checkout(adapter);
      final result = await c.submit(
        quantity: 2,
        expectedAmount: 19.5,
        couponClaimId: 'claim-1',
      );
      expect(result, isA<LdShopSubmitCreated>());
      final body = _body(adapter.hits(_orders, 'POST').single);
      final submissionToken = body['submissionToken'] as String;
      expect(submissionToken, matches(RegExp(r'^ord_[0-9a-f]{32}$')));
      expect(body['expectedAmount'], 19.5);
      expect(body['quantity'], 2);
      expect(body['couponClaimId'], 'claim-1');
      // 发出请求时 token 已经在盘上
      expect(savedAtPost, contains(submissionToken));
      expect(store.values, isEmpty);
    });

    test('落盘失败就不发请求', () async {
      final adapter = _Adapter({
        _orders: (_) => FakeRoute(200, body: created()),
      });
      store.failWrites = true;
      await expectLater(
        checkout(adapter).submit(quantity: 1, expectedAmount: 1),
        throwsStateError,
      );
      expect(adapter.requests, isEmpty);
    });

    test('断网：用同一个 token 查回订单', () async {
      late String postedToken;
      final adapter = _Adapter({
        _orders: (request) {
          postedToken = _body(request)['submissionToken'] as String;
          throw _networkError(request);
        },
      });
      var lookups = 0;
      final wrapped = _LookupAdapter(adapter, (request) {
        lookups++;
        expect(request.uri.pathSegments.last, postedToken);
        // 第一次还没查到，第二次查到
        return lookups < 2
            ? FakeRoute(200, body: _ok({'exists': false, 'order': null}))
            : FakeRoute(
                200,
                body: _ok({'exists': true, 'order': created()['data']}),
              );
      });
      final c = LdShopCheckout(
        service: LdShopService(dio: Dio()..httpClientAdapter = wrapped),
        token: token,
        productId: '9',
        store: store,
        wait: () async {},
      );
      final result = await c.submit(quantity: 1, expectedAmount: 10);
      expect(result, isA<LdShopSubmitCreated>());
      expect((result as LdShopSubmitCreated).order.orderNo, 'LD100');
      expect(lookups, 2);
      // 只发过一次下单
      expect(adapter.hits(_orders, 'POST'), hasLength(1));
      expect(store.values, isEmpty);
    });

    test('5xx 且查不到：保留记录，不换 token 重发；核对时按原 token 原样重发', () async {
      final posted = <Map<String, Object?>>[];
      var failCreate = true;
      final adapter = _Adapter({
        _orders: (request) {
          posted.add(_body(request));
          return failCreate
              ? FakeRoute(502, body: '<html>bad gateway</html>')
              : FakeRoute(200, body: created());
        },
      });
      var lookups = 0;
      final wrapped = _LookupAdapter(adapter, (_) {
        lookups++;
        return FakeRoute(200, body: _ok({'exists': false, 'order': null}));
      });
      LdShopCheckout make() => LdShopCheckout(
        service: LdShopService(dio: Dio()..httpClientAdapter = wrapped),
        token: token,
        productId: '9',
        store: store,
        wait: () async {},
      );

      final first = await make().submit(quantity: 1, expectedAmount: 10);
      expect(first, isA<LdShopSubmitUncertain>());
      expect(lookups, LdShopCheckout.lookupAttempts);
      expect(store.values, hasLength(1));
      final pending = await make().pending();
      expect(pending!.token, posted.single['submissionToken']);

      // 再点提交：有没核对清楚的记录，不发新请求
      final again = await make().submit(quantity: 1, expectedAmount: 10);
      expect(again, isA<LdShopSubmitUncertain>());
      expect(posted, hasLength(1));

      // 只查询：还是不确定，也不发请求
      final checked = await make().recover();
      expect(checked, isA<LdShopSubmitUncertain>());
      expect(posted, hasLength(1));

      // 用户点「核对本次结果」：查不到就按原样重发，token 不变
      failCreate = false;
      final replayed = await make().recover(replay: true);
      expect(replayed, isA<LdShopSubmitCreated>());
      expect(posted, hasLength(2));
      expect(posted[1], posted[0]);
      expect(store.values, isEmpty);
    });

    test('ORDER_SUBMISSION_CONFLICT 当作不确定，去查而不是清记录', () async {
      final adapter = _Adapter({
        _orders: (_) => FakeRoute(
          409,
          body: _fail('ORDER_SUBMISSION_CONFLICT', '同一提交处理中', 409),
        ),
      });
      final wrapped = _LookupAdapter(
        adapter,
        (_) => FakeRoute(
          200,
          body: _ok({'exists': true, 'order': created()['data']}),
        ),
      );
      final c = LdShopCheckout(
        service: LdShopService(dio: Dio()..httpClientAdapter = wrapped),
        token: token,
        productId: '9',
        store: store,
        wait: () async {},
      );
      final result = await c.submit(quantity: 1, expectedAmount: 10);
      expect(result, isA<LdShopSubmitCreated>());
    });

    test('明确的 4xx 业务失败：清记录，下一次用新 token', () async {
      final tokens = <String>[];
      var reject = true;
      final adapter = _Adapter({
        _orders: (request) {
          tokens.add(_body(request)['submissionToken'] as String);
          return reject
              ? FakeRoute(
                  400,
                  body: _fail('AMOUNT_MISMATCH', '金额已变化，请重新确认', 400),
                )
              : FakeRoute(200, body: created());
        },
      });
      final c = checkout(adapter);
      final result = await c.submit(quantity: 1, expectedAmount: 10);
      expect(result, isA<LdShopSubmitRejected>());
      expect(
        (result as LdShopSubmitRejected).error,
        isA<LdShopException>().having(
          (e) => e.message,
          'message',
          '金额已变化，请重新确认',
        ),
      );
      expect(store.values, isEmpty);
      expect(adapter.requests.where((r) => r.method == 'GET'), isEmpty);

      reject = false;
      await c.submit(quantity: 1, expectedAmount: 12);
      expect(tokens, hasLength(2));
      expect(tokens[0], isNot(tokens[1]));
    });

    test('401：没有建单，清记录并报授权失效', () async {
      final adapter = _Adapter({
        _orders: (_) => FakeRoute(401, body: _fail('AUTH_EXPIRED', '过期', 401)),
      });
      await expectLater(
        checkout(adapter).submit(quantity: 1, expectedAmount: 1),
        throwsA(isA<LdStoreAuthExpiredException>()),
      );
      expect(store.values, isEmpty);
    });

    test('支付结果确认中（paymentState=creating）：订单已建，但记录留着', () async {
      final adapter = _Adapter({
        _orders: (_) => FakeRoute(200, body: created(paymentState: 'creating')),
      });
      final result = await checkout(adapter)
          .submit(quantity: 1, expectedAmount: 1);
      expect(result, isA<LdShopSubmitCreated>());
      expect((result as LdShopSubmitCreated).order.paymentUnsettled, isTrue);
      expect(store.values, hasLength(1));
    });

    test('响应缺 orderNo：按不确定处理去查', () async {
      final adapter = _Adapter({
        _orders: (_) => FakeRoute(200, body: _ok({'message': 'ok'})),
      });
      var lookups = 0;
      final wrapped = _LookupAdapter(adapter, (_) {
        lookups++;
        return FakeRoute(500, body: {'error': 'boom'});
      });
      final c = LdShopCheckout(
        service: LdShopService(dio: Dio()..httpClientAdapter = wrapped),
        token: token,
        productId: '9',
        store: store,
        wait: () async {},
      );
      final result = await c.submit(quantity: 1, expectedAmount: 1);
      expect(result, isA<LdShopSubmitUncertain>());
      expect(lookups, LdShopCheckout.lookupAttempts);
      expect(store.values, hasLength(1));
    });

    test('记录放久了、商城明确说没有这笔：清掉', () async {
      var now = DateTime(2026, 11, 17, 10);
      final adapter = _Adapter({
        _orders: (request) => throw _networkError(request),
      });
      final wrapped = _LookupAdapter(
        adapter,
        (_) => FakeRoute(200, body: _ok({'exists': false, 'order': null})),
      );
      LdShopCheckout make() => LdShopCheckout(
        service: LdShopService(dio: Dio()..httpClientAdapter = wrapped),
        token: token,
        productId: '9',
        store: store,
        wait: () async {},
        clock: () => now,
      );
      expect(
        await make().submit(quantity: 1, expectedAmount: 1),
        isA<LdShopSubmitUncertain>(),
      );
      // 刚过一会儿：不清
      now = now.add(const Duration(minutes: 3));
      expect(await make().recover(), isA<LdShopSubmitUncertain>());
      expect(store.values, hasLength(1));
      now = now.add(LdShopCheckout.staleAfter);
      final stale = await make().recover();
      expect(stale, isA<LdShopSubmitAbsent>());
      expect((stale as LdShopSubmitAbsent).staleCleared, isTrue);
      expect(store.values, isEmpty);
    });

    test('记录按商城账号 + 商品分开', () {
      final a = checkout(_Adapter({}), productId: '9');
      final b = checkout(_Adapter({}), productId: '10');
      expect(a.storageKey, isNot(b.storageKey));
      expect(a.storageKey, contains(token.userId));
    });
  });

  group('商品描述', () {
    test('图片变链接、原始 HTML 当文本、单个换行就是换行', () {
      final html = ldShopDescriptionHtml(
        '第一行\n第二行\n\n![示意图](https://img.example.com/a.png)\n\n'
        '<img src="https://evil.example.com/x.png"> <script>alert(1)</script>\n\n'
        '打开 https://example.com/login',
      );
      expect(html, matches(RegExp(r'第一行<br />\s*第二行')));
      expect(html, isNot(contains('<img')));
      expect(html, contains('<a href="https://img.example.com/a.png">示意图</a>'));
      expect(html, isNot(contains('<script')));
      expect(html, contains('&lt;script&gt;'));
      expect(html, contains('<a href="https://example.com/login">'));
      expect(ldShopDescriptionHtml('  '), '');
    });
  });
}

/// 把 `/api/shop/order-submissions/{token}` 都交给 [onLookup]，其余转给 [inner]。
class _LookupAdapter implements HttpClientAdapter {
  _LookupAdapter(this.inner, this.onLookup);

  final _Adapter inner;
  final _Handler onLookup;

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    final segments = request.uri.pathSegments;
    if (segments.length == 4 && segments[2] == 'order-submissions') {
      inner.requests.add(request);
      final route = onLookup(request);
      return Future.value(
        ResponseBody.fromString(
          route.body is String ? route.body as String : jsonEncode(route.body),
          route.status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
    }
    return inner.fetch(request, stream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
