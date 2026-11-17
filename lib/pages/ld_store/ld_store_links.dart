import 'package:flutter/widgets.dart';

import '../../services/site_context.dart';
import 'ld_store_coupons_page.dart';
import 'ld_store_home_page.dart';
import 'ld_store_order_page.dart';
import 'ld_store_orders_page.dart';
import 'ld_store_product_page.dart';

/// 商城网页地址能不能用原生页打开（只认 https://ldcstore.com）。
///
/// 路由形态取自商城前端 `src/router/index.js`：
/// - `/`、`/search?q=…`、`/category/:name` → 首页（搜索词 / 分类名不预选分类）
/// - `/product/:id`、`/checkout/:productId` → 商品详情
/// - `/order/:id`（可带 `?role=buyer`）→ 订单详情（`role=seller` 不接）
/// - `/user/orders`（`?status=`）→ 我的订单；`/user/coupons` → 我的优惠券
/// - `/pay/signal?orderNo=…&result=…`（付款后 Credit 跳回的结果页）→ 订单详情
///
/// 其余（`/merchant/:username` 商家主页、`/shop/:id` 小店、`/coupon/:token`
/// 领券、`/buy-request/*` 求购、`/seller/*` 卖家后台、`/user/messages` 等）返回
/// false，由调用方照旧用内置浏览器打开。
bool isLdStoreNativeLink(Uri uri) => _route(uri) != null;

/// 用原生页打开商城链接；打不开（不是商城或原生没做）返回 false。
bool openLdStoreLink(BuildContext context, Uri uri) {
  final route = _route(uri);
  if (route == null) return false;
  route(context);
  return true;
}

void Function(BuildContext)? _route(Uri uri) {
  if (!SiteContext.isLinuxDo) return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  final host = uri.host.toLowerCase();
  if (host != 'ldcstore.com' && host != 'www.ldcstore.com') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return (context) => LdStoreHomePage.open(context);
  }
  switch (segments) {
    case ['search']:
      final query = uri.queryParameters['q']?.trim();
      return (context) => LdStoreHomePage.open(context, query: query);
    case ['category', final name]:
      // 网页按分类名路由，原生按 id 筛选：拿名字当搜索词兜底
      return (context) => LdStoreHomePage.open(context, query: name);
    case ['product', final id] || ['checkout', final id]:
      return (context) => LdStoreProductPage.open(context, id);
    case ['order', final orderNo]:
      if ((uri.queryParameters['role'] ?? 'buyer') != 'buyer') return null;
      return (context) => LdStoreOrderPage.open(context, orderNo);
    case ['user', 'orders']:
      final tab = switch (uri.queryParameters['status']) {
        'pending' => LdShopOrderTab.pending,
        'paid' => LdShopOrderTab.paid,
        'cancelled' => LdShopOrderTab.cancelled,
        'refund' => LdShopOrderTab.refund,
        _ => LdShopOrderTab.all,
      };
      // 网页的「求购订单」(tab=buy) / 「卖家订单」(tab=seller) 不接
      final role = uri.queryParameters['tab'];
      if (role != null && role != 'buyer') return null;
      return (context) => LdStoreOrdersPage.open(context, tab: tab);
    case ['user', 'coupons']:
      return (context) => LdStoreCouponsPage.open(context);
    case ['pay', 'signal']:
      // 支付完成后 Credit 跳回的结果页：直接看那张订单
      final orderNo = uri.queryParameters['orderNo']?.trim() ?? '';
      if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(orderNo)) return null;
      return (context) => LdStoreOrderPage.open(context, orderNo);
  }
  return null;
}
