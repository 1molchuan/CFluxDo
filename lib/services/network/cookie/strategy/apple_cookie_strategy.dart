import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../../constants.dart';
import 'default_cookie_strategy.dart';

/// Apple (iOS / macOS) cookie 策略
///
/// WKWebView 的 sharedCookiesEnabled 会从 HTTPCookieStorage.shared 读 cookie。
/// 仅清 WKHTTPCookieStore 不够，需要同时清 HTTPCookieStorage.shared。
class AppleCookieStrategy extends DefaultCookieStrategy {
  static const _nativeCookieChannel = MethodChannel('com.fluxdo/cookie_storage');

  @override
  Future<void> clearWebViewCookies(
    CookieManager cookieManager,
    Set<String> knownHosts,
  ) async {
    // WKWebView 多域共存，不能清空整个 cookie store。
    await super.clearWebViewCookies(cookieManager, knownHosts);

    // 同时清除 HTTPCookieStorage.shared
    try {
      await _nativeCookieChannel.invokeMethod(
        'clearCookies',
        AppConstants.baseUrl,
      );
    } catch (e) {
      debugPrint('[CookieStrategy][Apple] HTTPCookieStorage clear failed: $e');
    }
  }
}
