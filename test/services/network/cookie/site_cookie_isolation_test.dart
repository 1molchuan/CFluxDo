import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/strategy/default_cookie_strategy.dart';
import 'package:fluxdo/services/network/cookie/strategy/linux_cookie_strategy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _SiteCookiePlatform();
  InAppWebViewPlatform.instance = platform;

  test('域匹配拒绝另一站、相似后缀、无域与不属于请求的子域', () {
    expect(CookieJarService.cookieDomainMatchesHost('.linux.do', 'linux.do'), isTrue);
    expect(CookieJarService.cookieDomainMatchesHost('.linux.do', 'connect.linux.do'), isTrue);
    expect(CookieJarService.cookieDomainMatchesHost('connect.linux.do', 'linux.do'), isFalse);
    expect(CookieJarService.cookieDomainMatchesHost('.idcflare.com', 'linux.do'), isFalse);
    expect(CookieJarService.cookieDomainMatchesHost('.linux.do', 'notlinux.do'), isFalse);
    expect(CookieJarService.cookieDomainMatchesHost('.linux.do', 'linux.do.attacker.test'), isFalse);
    expect(CookieJarService.cookieDomainMatchesHost(null, 'linux.do'), isFalse);
  });

  test('Linux WPE 全域枚举只返回请求域实际可见的 Cookie', () async {
    platform.cookies.values = [
      Cookie(name: 'cf_clearance', value: 'linux', domain: '.linux.do'),
      Cookie(name: 'cf_clearance', value: 'idc', domain: '.idcflare.com'),
      Cookie(name: '_t', value: 'oauth', domain: 'connect.linux.do'),
      Cookie(name: '_t', value: 'unknown'),
    ];

    final cookies = await LinuxCookieStrategy().readCookiesFromWebView(
      CookieManager.instance(),
      'https://idcflare.com/login',
    );
    expect(cookies.map((cookie) => cookie.value), ['idc']);
  });

  test('退出当前论坛不会全局清空另一站与 OAuth 身份域', () async {
    platform.cookies.values = [
      Cookie(name: '_t', value: 'linux', domain: 'linux.do'),
      Cookie(name: 'cf_clearance', value: 'linux-cf', domain: '.linux.do'),
      Cookie(name: '_t', value: 'idc', domain: 'idcflare.com'),
      Cookie(name: 'auth.session-token', value: 'oauth', domain: 'connect.linux.do'),
    ];

    await DefaultCookieStrategy().clearWebViewCookies(
      CookieManager.instance(),
      {'linux.do', 'connect.linux.do', 'idcflare.com'},
    );

    expect(platform.cookies.values.map((cookie) => cookie.value), ['idc', 'oauth']);
    expect(platform.cookies.deleteAllCalls, 0);
  });
}

class _SiteCookiePlatform extends InAppWebViewPlatform {
  final cookies = _SiteCookieManager();

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;
}

class _SiteCookieManager extends PlatformCookieManager {
  _SiteCookieManager()
    : super.implementation(const PlatformCookieManagerCreationParams());

  List<Cookie> values = [];
  int deleteAllCalls = 0;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => [...values];

  @override
  Future<List<Cookie>> getAllCookies() async => [...values];

  @override
  Future<bool> deleteAllCookies() async {
    deleteAllCalls++;
    values.clear();
    return true;
  }

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    values.removeWhere((cookie) => cookie.name == name && cookie.domain == domain);
    return true;
  }
}
