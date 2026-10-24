import 'dart:io' as io;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'android_cookie_strategy.dart';
import 'apple_cookie_strategy.dart';
import 'default_cookie_strategy.dart';
import 'linux_cookie_strategy.dart';

/// 平台 cookie 策略抽象基类。
///
/// 只封装真正有平台差异的操作，不包含业务同步逻辑。
abstract class PlatformCookieStrategy {
  /// 工厂方法：根据平台返回对应策略
  factory PlatformCookieStrategy.create() {
    if (io.Platform.isAndroid) return AndroidCookieStrategy();
    if (io.Platform.isIOS || io.Platform.isMacOS) return AppleCookieStrategy();
    if (io.Platform.isLinux) return LinuxCookieStrategy();
    return DefaultCookieStrategy();
  }

  /// 从 WebView 读取指定 URL 的 cookie 列表
  /// 默认用 CookieManager.getCookies(url:)，Linux 覆写为 getAllCookies() 过滤
  Future<List<Cookie>> readCookiesFromWebView(CookieManager cookieManager, String url);

  /// 仅清除当前论坛域 Cookie，保留其他站点和 OAuth 身份域。
  Future<void> clearWebViewCookies(CookieManager cookieManager, Set<String> knownHosts);

  /// 将原始 Set-Cookie 头批量写入 WebView
  /// 返回成功写入的条数
  Future<int> writeRawCookiesToWebView(List<(String url, String rawHeader)> entries);
}
