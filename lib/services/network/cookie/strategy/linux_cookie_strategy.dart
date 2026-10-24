import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../cookie_jar_service.dart';
import 'default_cookie_strategy.dart';

/// Linux (WPE WebView) cookie 策略
///
/// WPE WebView 的 getCookies(url:) URL 过滤不可靠，
/// 改用 getAllCookies() 读取全部再按 domain 过滤。
class LinuxCookieStrategy extends DefaultCookieStrategy {
  @override
  Future<List<Cookie>> readCookiesFromWebView(
    CookieManager cookieManager,
    String url,
  ) async {
    try {
      final allCookies = await cookieManager.getAllCookies();
      return allCookies
          .where((c) => CookieJarService.cookieDomainMatchesHost(c.domain, Uri.parse(url).host))
          .toList();
    } catch (e) {
      debugPrint('[CookieStrategy][Linux] getAllCookies failed, falling back: $e');
      return super.readCookiesFromWebView(cookieManager, url);
    }
  }
}
