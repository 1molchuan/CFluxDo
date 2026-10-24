import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../cookie_jar_service.dart';
import '../raw_cookie_writer.dart';
import 'platform_cookie_strategy.dart';

/// 默认 cookie 策略（Windows 等）
class DefaultCookieStrategy implements PlatformCookieStrategy {
  @override
  Future<List<Cookie>> readCookiesFromWebView(
    CookieManager cookieManager,
    String url,
  ) async {
    return cookieManager.getCookies(url: WebUri(url));
  }

  @override
  Future<void> clearWebViewCookies(
    CookieManager cookieManager,
    Set<String> knownHosts,
  ) async {
    // Cookie store 由各域共享，只删除当前论坛，不触碰另一站或 OAuth 域。
    final host = CookieJarService.appBaseHost;
    final url = WebUri('https://$host');
    final cookies = await readCookiesFromWebView(cookieManager, url.toString());
    for (final cookie in cookies) {
      final domain = CookieJarService.normalizeWebViewCookieDomain(cookie.domain);
      if (domain != null && domain.toLowerCase() != host) continue;
      await cookieManager.deleteCookie(
        url: url,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      );
    }
  }

  @override
  Future<int> writeRawCookiesToWebView(
    List<(String url, String rawHeader)> entries,
  ) async {
    final writer = RawCookieWriter.instance;
    if (!writer.isSupported) return 0;

    var written = 0;
    for (final (url, raw) in entries) {
      try {
        if (await writer.setRawCookie(url, raw)) written++;
      } catch (e) {
        debugPrint('[CookieStrategy] 写入 WebView 失败: $e');
      }
    }
    return written;
  }
}
