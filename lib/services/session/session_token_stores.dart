import 'dart:io' as io;

import '../../constants.dart';
import '../network/cookie/boundary_sync_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../network/cookie/webview_cookie_push.dart';
import 'session_token_ports.dart';

/// `_t` 的 CookieJar 端口生产实现（[CookieJarService] 之上的薄适配）。
class CookieJarSessionTokenStore implements SessionTokenJarStore {
  CookieJarSessionTokenStore({CookieJarService? jar})
    : _jar = jar ?? CookieJarService();

  final CookieJarService _jar;

  static const String _name = '_t';
  static const String _forumSession = '_forum_session';

  @override
  bool get isReady => _jar.isInitialized;

  @override
  Future<String?> read() => _jar.getTToken();

  @override
  Future<DateTime?> readExpiry() async =>
      (await _jar.getCanonicalCookie(_name))?.expiresAt;

  @override
  Future<bool> writeTrusted(String value, {required DateTime expires}) async {
    // 可信写入：jar 旧值的版本号可能已被之前的可信轮换抬高，非可信写入会被
    // isFresherThan 丢弃。过期时间由 authority 决定后传入（保证落盘）。
    await _jar.setSessionTokenTrusted(value, expires: expires);
    return await _jar.getTToken() == value;
  }

  @override
  Future<void> adoptForumSessionFromWebView(
    String value, {
    int? requestGeneration,
    bool allowLowConfidence = false,
  }) {
    return BoundarySyncService.instance.syncFromWebView(
      currentUrl: AppConstants.baseUrl,
      cookieNames: const {_forumSession},
      acceptValues: {_forumSession: value},
      allowLowConfidenceSessionCookies: allowLowConfidence,
      requestGeneration: requestGeneration,
      trusted: true,
    );
  }
}

/// `_t` 的 WebView cookie store 端口生产实现。
///
/// 读：[BoundarySyncService] 的会话 cookie 选优（多变体时 host-only 优先）；
/// 写：[WebViewCookiePush]（可选先清变体、读回确认、失败重试一次）。
class WebViewSessionTokenStore implements SessionTokenWebViewStore {
  WebViewSessionTokenStore({
    BoundarySyncService? boundary,
    CookieJarService? jar,
    WebViewCookiePush? push,
  }) : _boundaryOverride = boundary,
       _jarOverride = jar,
       _pushOverride = push;

  final BoundarySyncService? _boundaryOverride;
  final CookieJarService? _jarOverride;
  final WebViewCookiePush? _pushOverride;

  BoundarySyncService get _boundary =>
      _boundaryOverride ?? BoundarySyncService.instance;
  CookieJarService get _jar => _jarOverride ?? CookieJarService();
  WebViewCookiePush get _push => _pushOverride ?? WebViewCookiePush.instance;

  static const String _name = '_t';

  @override
  Future<String?> read() => _boundary.readCookieValueFromWebView(
    currentUrl: AppConstants.baseUrl,
    name: _name,
    allowLowConfidenceSessionCookies: true,
  );

  @override
  Future<DateTime?> readExpiry(String value) =>
      _boundary.readCookieExpiresFromWebView(
        currentUrl: AppConstants.baseUrl,
        name: _name,
        expectedValue: value,
        allowLowConfidenceSessionCookies: true,
      );

  @override
  Future<String?> readForumSession() => _boundary.readCookieValueFromWebView(
    currentUrl: AppConstants.baseUrl,
    name: '_forum_session',
    allowLowConfidenceSessionCookies: true,
  );

  @override
  Future<bool> write(
    String value, {
    required String reason,
    String? url,
    String? rawSetCookie,
    DateTime? expires,
    bool clearVariantsFirst = false,
  }) async {
    var header = rawSetCookie;
    if (header == null) {
      // jar 里正好是这个值：用它的 canonical（hostOnly / SameSite / 过期时间
      // 都与服务端一致）；否则按主站 host-only 规范形式现拼一条。
      final canonical = await _jar.getCanonicalCookie(_name);
      header = canonical != null && canonical.value == value
          ? canonical.toSetCookieHeader()
          : _hostOnlyHeader(value, expires);
    }
    return _push.push(
      name: _name,
      reason: reason,
      url: url,
      rawSetCookie: header,
      expectedValue: value,
      clearVariantsFirst: clearVariantsFirst,
    );
  }

  static String _hostOnlyHeader(String value, DateTime? expires) {
    final buf = StringBuffer('$_name=$value; Path=/; Secure; HttpOnly');
    if (expires != null) {
      buf.write('; Expires=${io.HttpDate.format(expires.toUtc())}');
    }
    return buf.toString();
  }
}
