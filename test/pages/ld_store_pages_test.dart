import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/ld_store/ld_store_home_page.dart';
import 'package:fluxdo/pages/ld_store/ld_store_order_page.dart';
import 'package:fluxdo/pages/ld_store/ld_store_orders_page.dart';
import 'package:fluxdo/pages/ld_store/ld_store_product_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/ld_store_providers.dart';
import 'package:fluxdo/services/ld_store/ld_store_models.dart';
import 'package:fluxdo/services/ld_store/ld_store_shop_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ld_store/ld_store_test_support.dart';

const _api = 'https://api2.ldspro.qzz.io';

class _User extends CurrentUserNotifier {
  @override
  FutureOr<User?> build() => User(id: 12345, username: 'alice', trustLevel: 2);
}

class _Session extends LdStoreSessionNotifier {
  _Session(this.session);

  final LdStoreSession? session;

  @override
  Future<LdStoreSession?> build() async => session;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.routes);

  final Map<String, Object? Function(RequestOptions)> routes;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    final key =
        '${request.uri.scheme}://${request.uri.host}${request.uri.path}';
    final handler = routes[key];
    if (handler == null) return ResponseBody.fromString('{}', 404);
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': handler(request)}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _product(int id, {int stock = 5, double discount = 1}) => {
  'id': id,
  'name': '公益站注册码 $id',
  'price': 100,
  'discount': discount,
  'final_price': 100 * discount,
  'product_type': 'cdk',
  'availableStock': stock,
  'sold_count': 12,
  'seller_username': 'seller$id',
  'seller_name': '卖家$id',
  'purchase_limit': {'mode': 'none', 'quantity': 0},
};

Widget _app(
  Widget home, {
  required _Adapter adapter,
  LdStoreSession? session,
  bool mojian = false,
  SharedPreferences? prefs,
}) {
  final container = ProviderContainer(
    overrides: [
      if (prefs != null) sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(_User.new),
      ldStoreSessionProvider.overrideWith(() => _Session(session)),
      ldShopServiceProvider.overrideWithValue(
        LdShopService(dio: Dio()..httpClientAdapter = adapter),
      ),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          extensions: [
            if (mojian)
              MojianTokens.of(Brightness.light, MojianAccent.cinnabar),
          ],
        ),
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final token = LdStoreToken.parse(
    ldStoreJwt(expiresAt: DateTime.now().add(const Duration(days: 7))),
  )!;

  for (final mojian in [false, true]) {
    final style = mojian ? '墨笺' : '经典';

    testWidgets('$style 首页：分类、排序、商品卡片', (tester) async {
      final adapter = _Adapter({
        '$_api/api/shop/categories': (_) => {
          'categories': [
            {'id': 2, 'name': '公益站', 'icon': '💻', 'sort_order': 2},
          ],
        },
        '$_api/api/shop/products': (request) => {
          'products': [
            _product(1, discount: 0.5),
            _product(2, stock: 0),
            _product(3),
          ],
          'pagination': {
            'total': '3',
            'page': 1,
            'pageSize': 20,
            'totalPages': 1,
          },
        },
      });
      await tester.pumpWidget(
        _app(const LdStoreHomePage(), adapter: adapter, mojian: mojian),
      );
      await _settle(tester);
      expect(find.text('💻 公益站'), findsOneWidget);
      expect(find.text('默认排序'), findsOneWidget);
      expect(find.text('只看有货'), findsOneWidget);
      expect(find.text('公益站注册码 1'), findsOneWidget);
      expect(find.text('5 折'), findsOneWidget);
      // 售罄遮罩 + 库存文案
      expect(find.text('已售罄'), findsWidgets);
      expect(find.text('共 3 件物品'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 点分类：带 categoryId 重新读
      await tester.tap(find.text('💻 公益站'));
      await _settle(tester);
      final last = adapter.requests.lastWhere(
        (r) => r.uri.path == '/api/shop/products',
      );
      expect(last.uri.queryParameters['categoryId'], '2');
    });

    testWidgets('$style 订单详情：卡密默认遮住，可逐行复制', (tester) async {
      final adapter = _Adapter({
        '$_api/api/shop/orders/LD1': (_) => {
          'order': {
            'order_no': 'LD1',
            'status': 'delivered',
            'product': {'id': 9, 'name': '注册码', 'price': 10, 'discount': 1},
            'quantity': 2,
            'amount': 20,
            'delivery_type': 'auto',
            'cdk': 'CODE-AAAA\nCODE-BBBB',
            'created_at': '2026-11-17T05:21:55Z',
          },
          'logs': [
            {'action': 'create', 'created_at': '2026-11-17T05:21:55Z'},
            {'action': 'deliver', 'created_at': '2026-11-17T05:22:10Z'},
          ],
        },
      });
      await tester.pumpWidget(
        _app(
          const LdStoreOrderPage(orderNo: 'LD1'),
          adapter: adapter,
          session: LdStoreSession(token: token),
          mojian: mojian,
        ),
      );
      await _settle(tester);
      expect(find.text('已发货'), findsOneWidget);
      expect(find.text('发货内容（2 条）'), findsOneWidget);
      expect(find.text('CODE-AAAA'), findsNothing);
      await tester.tap(find.byTooltip('显示'));
      await tester.pump();
      expect(find.text('CODE-AAAA'), findsOneWidget);
      // 时间线在下面
      await tester.dragUntilVisible(
        find.text('创建订单'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('发货完成'), findsOneWidget);
      // 已发货的订单没有付款按钮
      expect(find.text('继续付款'), findsNothing);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer ${token.value}',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('待付款订单：继续付款、检查支付状态、取消', (tester) async {
    final adapter = _Adapter({
      '$_api/api/shop/orders/LD2': (_) => {
        'order': {
          'orderNo': 'LD2',
          'status': 'pending',
          'productName': '注册码',
          'amount': 10,
          'paymentUrl': 'https://credit.linux.do/pay/LD2',
        },
      },
    });
    await tester.pumpWidget(
      _app(
        const LdStoreOrderPage(orderNo: 'LD2'),
        adapter: adapter,
        session: LdStoreSession(token: token),
      ),
    );
    await _settle(tester);
    expect(find.text('待付款'), findsWidgets);
    expect(find.text('继续付款'), findsOneWidget);
    expect(find.text('检查支付状态'), findsOneWidget);
    expect(find.text('取消订单'), findsOneWidget);
    // 离开页面，停掉轮询
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('商品页 → 确认弹层核价 → 下单（先核价再提交，带同一金额）→ 订单详情', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var quotes = 0;
    final adapter = _Adapter({
      '$_api/api/shop/products/9': (_) => {
        'product': {
          ..._product(9, discount: 0.5),
          'description': '第一行\n第二行',
          'canPurchase': true,
          'purchase_limit': {'mode': 'per_order', 'quantity': 3},
        },
      },
      '$_api/api/shop/orders/quote': (request) {
        quotes++;
        return {
          'productId': 9,
          'quantity': (request.data as Map)['quantity'],
          'payableAmount': 50,
          'coupons': [],
        };
      },
      '$_api/api/shop/orders': (_) => {
        'orderNo': 'LD9',
        'orderId': 'uuid-9',
        'status': 'pending',
      },
      '$_api/api/shop/orders/LD9': (_) => {
        'order': {
          'orderNo': 'LD9',
          'status': 'pending',
          'productName': '公益站注册码 9',
          'amount': 50,
        },
      },
    });
    await tester.pumpWidget(
      _app(
        const LdStoreProductPage(productId: '9'),
        adapter: adapter,
        session: LdStoreSession(token: token),
        prefs: prefs,
      ),
    );
    await _settle(tester);
    expect(find.text('公益站注册码 9'), findsOneWidget);
    expect(find.text('每单最多 3 件'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '立即兑换'));
    await _settle(tester);
    expect(find.text('确认订单'), findsOneWidget);
    expect(find.text('确认兑换 · 50 LDC'), findsOneWidget);
    expect(quotes, 1);

    await tester.tap(find.text('确认兑换 · 50 LDC'));
    await _settle(tester);
    // 提交前又核了一次价
    expect(quotes, 2);
    final post = adapter.requests.singleWhere(
      (r) => r.method == 'POST' && r.uri.path == '/api/shop/orders',
    );
    final body = post.data as Map;
    expect(body['productId'], 9);
    expect(body['quantity'], 1);
    expect(body['expectedAmount'], 50);
    expect('${body['submissionToken']}', startsWith('ord_'));
    // 成功后提交记录清掉了
    expect(
      prefs.getKeys().where((k) => k.startsWith('ld_shop_submission:')),
      isEmpty,
    );
    // 进了订单详情
    expect(find.text('订单详情'), findsOneWidget);
    expect(find.text('继续付款'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没授权时订单页给授权入口', (tester) async {
    await tester.pumpWidget(
      _app(const LdStoreOrdersPage(), adapter: _Adapter({})),
    );
    await _settle(tester);
    expect(find.text('授权 LD士多后才能查看订单和优惠券'), findsWidgets);
    expect(find.widgetWithText(FilledButton, '授权登录'), findsWidgets);
  });
}
