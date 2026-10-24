import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../raw_cookie_writer.dart';
import 'default_cookie_strategy.dart';

/// Android cookie 策略
///
/// - 读取走自有 raw_cookie 通道:handler 在 app 的 cookie HandlerThread 上
///   执行(MainActivity.onCookieThread),平台主线程零占用。插件的
///   CookieManager.getCookies 通道 handler 注册在平台主线程,cf_clearance
///   周期轮询/边界同步高频调用时会与 vsync 分发抢线程(ov 型掉帧来源)。
///   字段能力与插件路径等同(都是 GET_COOKIE_INFO,旧 WebView 同样退化到
///   name+value)。
/// - 清理复用默认策略，只删除当前论坛域，不清除 OAuth 或另一站会话。
class AndroidCookieStrategy extends DefaultCookieStrategy {
  @override
  Future<List<Cookie>> readCookiesFromWebView(
    CookieManager cookieManager,
    String url,
  ) async {
    try {
      final infos = await RawCookieWriter.instance.getAllCookieInfos(url);
      return infos
          .map(
            (info) => Cookie(
              name: info.name,
              value: info.value,
              domain: info.domain,
              path: info.path,
              isSecure: info.isSecure,
              isHttpOnly: info.isHttpOnly,
              expiresDate: info.expiresMillis,
              sameSite: _sameSiteFromString(info.sameSite),
            ),
          )
          .toList(growable: false);
    } catch (e) {
      debugPrint(
        '[CookieStrategy][Android] raw_cookie 读取失败,回退插件通道: $e',
      );
      return super.readCookiesFromWebView(cookieManager, url);
    }
  }

  /// getCookieInfo 的 SameSite 属性值大小写不定(Lax/lax/LAX),
  /// 归一成枚举要求的首字母大写形式再解析。
  HTTPCookieSameSitePolicy? _sameSiteFromString(String? value) {
    if (value == null || value.isEmpty) return null;
    final normalized =
        value[0].toUpperCase() + value.substring(1).toLowerCase();
    return HTTPCookieSameSitePolicy.fromValue(normalized);
  }

}
