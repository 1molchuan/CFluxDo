import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../app_logger.dart';
import '../network/cf/cf_challenge_classifier.dart';
import '../network/discourse_dio.dart';
import '../network/flux_request_spec.dart';
import '../oauth_flow_helper.dart';
import '../site_context.dart';
import '../storage/secret_store.dart';
import '../storage/system_secret_store.dart';
import 'ld_store_models.dart';

/// LD士多的授权已失效（凭据到期或被商城拒绝），需要重新授权。
class LdStoreAuthExpiredException implements Exception {
  const LdStoreAuthExpiredException();

  @override
  String toString() => S.current.ldStore_authExpired;
}

/// 授权走到「等用户确认」这一步时的状态。
class LdStorePendingAuthorization {
  const LdStorePendingAuthorization._({this.approveUrl, this.callbackUrl});

  /// connect.linux.do 的同意链接；用户在确认框里点「允许」后才请求。
  final Uri? approveUrl;

  /// connect.linux.do 直接给了回调（以前同意过），确认后直接回调商城。
  final Uri? callbackUrl;
}

/// 「退出授权」时记下的凭据身份：内置浏览器里商城自己存的同一枚（或更早签发的）
/// 凭据下次打开时一并清掉，网页里重新登录拿到的新凭据不受影响。
class LdStoreRevocation {
  const LdStoreRevocation({
    required this.userId,
    required this.site,
    required this.expiresAt,
  });

  final String userId;
  final String site;
  final DateTime expiresAt;
}

typedef LdStoreGap = Future<void> Function({
  required int minMs,
  required int maxMs,
});

/// LD士多（ldcstore.com）接入：公开统计、经 LINUX DO Connect 授权拿商城凭据、
/// 读个人待办与未读消息，以及给内置浏览器准备登录态脚本。
///
/// 商城是社区成员开发的第三方站：
/// - 商城接口走独立的 Dio，**不带**论坛 Cookie、CSRF，不进论坛的调度与过盾；
/// - 只有 connect.linux.do 的授权页 / 同意请求走论坛 Dio（与 LDC / CDK 授权相同）；
/// - 凭据只存在系统安全存储里，按论坛账号分开，日志里不出现。
class LdStoreService {
  LdStoreService({
    Dio? storeDio,
    Dio? forumDio,
    SecretStore? secretStore,
    LdStoreGap? gap,
    DateTime Function()? clock,
  }) : _storeDio = storeDio ?? _createStoreDio(),
       _forumDioOverride = forumDio,
       _secretStore = secretStore ?? SystemSecretStore.instance,
       _gap = gap ?? OAuthFlowHelper.humanGap,
       _clock = clock ?? DateTime.now;

  static const siteUrl = 'https://ldcstore.com';
  static const apiBase = 'https://api2.ldspro.qzz.io';
  static const authApiBase = 'https://api1.ldspro.qzz.io';

  /// 商城在 LINUX DO Connect 登记的回调地址（由它的后端换 code）。
  static final Uri oauthCallback = Uri.parse(
    'https://api.ldspro.qzz.io/api/auth/callback',
  );

  /// 商城后端换完 code 后带着登录结果跳回的前端地址。
  static final Uri returnUrl = Uri.parse('$siteUrl/auth/callback?redirect=%2F');

  static const _connectHost = 'connect.linux.do';
  static const _forumHost = 'linux.do';
  static const _maxAuthRedirects = 8;
  static const _revocationKey = 'ld_store_web_revoked';
  static const _webTokenKey = 'ld_store_token';

  static const _authErrorCodes = {
    'AUTH_REQUIRED',
    'AUTH_INVALID',
    'AUTH_EXPIRED',
    'UNAUTHORIZED',
    'INVALID_TOKEN',
    'TOKEN_EXPIRED',
    'INVALID_OR_EXPIRED_TOKEN',
  };

  final Dio _storeDio;
  final Dio? _forumDioOverride;
  Dio? _forumDio;
  final SecretStore _secretStore;
  final LdStoreGap _gap;
  final DateTime Function() _clock;

  Dio get _forum => _forumDioOverride ?? (_forumDio ??= DiscourseDio.create());

  static Dio _createStoreDio() {
    final dio = DiscourseDio.create(
      kind: DiscourseDioKind.external,
      enableCookies: false,
      baseUrl: apiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    );
    // 每个请求都带上：论坛的 CSRF 不能发给第三方站，失败也不弹通用 toast，
    // 也不能被兼容模式（浏览器网络栈，运行在论坛 origin）接管
    dio.options.extra.addAll({
      FluxRequestKeys.skipCsrf: true,
      FluxRequestKeys.showErrorToast: false,
      FluxRequestKeys.skipWebViewAdapter: true,
    });
    return dio;
  }

  // ---------------------------------------------------------------------------
  // 公开数据
  // ---------------------------------------------------------------------------

  Future<LdStoreStats> fetchStats() async {
    final response = await _storeDio.get<dynamic>('$apiBase/api/shop/stats');
    return LdStoreStats.fromJson(_unwrap(response.data));
  }

  // ---------------------------------------------------------------------------
  // 凭据
  // ---------------------------------------------------------------------------

  /// 每个论坛账号一份 `{username, token}`（多账号切换后再切回来还在）；
  /// 论坛退出登录时删掉当前账号那份。
  static SecretKey _sessionKeyFor(String username) => SecretKey(
    namespace: 'ld_store',
    name: 'session',
    accountId: SiteContext.accountKey(username.toLowerCase()),
    fallbackPolicy: SecretFallbackPolicy.memoryOnly,
  );

  /// 旧版（单账号）只存一份的位置，读到就搬进它自己账号的槽
  static const _legacySessionKey = SecretKey(
    namespace: 'ld_store',
    name: 'session',
    fallbackPolicy: SecretFallbackPolicy.memoryOnly,
  );

  /// 最近读写过凭据的论坛账号（退出登录时论坛那边已经清掉用户名了）
  String? _lastUsername;

  Future<({String username, LdStoreToken token})?> _decodeSession(
    String? raw,
  ) async {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final token = LdStoreToken.decode(json['token'] as String?);
      final username = json['username'];
      if (token != null && username is String) {
        return (username: username, token: token);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _migrateLegacySession() async {
    final raw = await _secretStore.read(_legacySessionKey);
    if (raw == null) return;
    final legacy = await _decodeSession(raw);
    if (legacy != null) {
      await _secretStore.write(_sessionKeyFor(legacy.username), raw);
    }
    await _secretStore.delete(_legacySessionKey);
  }

  Future<LdStoreToken?> _readToken(String username) async {
    await _migrateLegacySession();
    final key = _sessionKeyFor(username);
    final raw = await _secretStore.read(key);
    final session = await _decodeSession(raw);
    if (session == null) {
      if (raw != null) await _secretStore.delete(key);
      return null;
    }
    return session.token;
  }

  /// 读论坛账号 [username] 的商城凭据。没有返回 null；存的值已到期抛
  /// [LdStoreAuthExpiredException]（并清掉）。
  Future<LdStoreToken?> loadToken(String username) async {
    _lastUsername = username;
    final token = await _readToken(username);
    if (token == null) return null;
    if (token.isExpired(_clock())) {
      await _secretStore.delete(_sessionKeyFor(username));
      throw const LdStoreAuthExpiredException();
    }
    return token;
  }

  Future<void> saveToken(String username, LdStoreToken token) async {
    _lastUsername = username;
    await _secretStore.write(
      _sessionKeyFor(username),
      jsonEncode({'username': username, 'token': token.value}),
    );
    await _clearRevocation();
  }

  /// 凭据被商城拒绝：直接丢掉（网页里那枚同样无效，不必记下）。
  Future<void> discardToken(String username) =>
      _secretStore.delete(_sessionKeyFor(username));

  /// 退出授权 / 论坛登出：删掉 [username]（默认最近用过的账号）的凭据，
  /// 并记下它的身份，让内置浏览器里的同一枚也失效。
  Future<void> signOut({String? username}) async {
    final target = username ?? _lastUsername;
    await _migrateLegacySession();
    if (target == null) return;
    final token = await _tokenOrNull(target);
    await _secretStore.delete(_sessionKeyFor(target));
    if (token != null) await _recordRevocation(token);
  }

  /// 切到别的论坛账号：[username] 的凭据留着（切回来还能用），只让内置
  /// 浏览器里那枚失效，免得新账号打开商城看到的还是上一个人。
  Future<void> revokeWebSessionFor(String username) async {
    final token = await _tokenOrNull(username);
    if (token != null) await _recordRevocation(token);
  }

  Future<LdStoreToken?> _tokenOrNull(String username) async {
    try {
      return await _readToken(username);
    } catch (_) {
      return null;
    }
  }

  Future<void> _recordRevocation(LdStoreToken token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _revocationKey,
      jsonEncode({
        'sub': token.userId,
        'site': token.site,
        'exp': token.expiresAt.millisecondsSinceEpoch ~/ 1000,
      }),
    );
  }

  Future<LdStoreRevocation?> loadRevocation() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_revocationKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (json['exp'] as int) * 1000,
      );
      // 那枚凭据自己到期了，商城网页会自己丢掉它
      if (!expiresAt.isAfter(_clock())) {
        await prefs.remove(_revocationKey);
        return null;
      }
      return LdStoreRevocation(
        userId: '${json['sub']}',
        site: '${json['site']}',
        expiresAt: expiresAt,
      );
    } catch (_) {
      await prefs.remove(_revocationKey);
      return null;
    }
  }

  Future<void> _clearRevocation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_revocationKey);
  }

  // ---------------------------------------------------------------------------
  // 个人数据
  // ---------------------------------------------------------------------------

  Future<LdStoreAccount> fetchAccount(LdStoreToken token) async {
    if (token.isExpired(_clock())) throw const LdStoreAuthExpiredException();
    final results = await Future.wait([
      _authedGet('/api/shop/user/attention', token),
      _authedGet('/api/shop/messages/unread-summary', token),
    ]);
    return LdStoreAccount(
      username: token.username,
      attention: LdStoreAttention.fromJson(results[0]),
      unreadMessages: LdStoreAccount.unreadFromJson(results[1]),
    );
  }

  Future<Object?> _authedGet(String path, LdStoreToken token) async {
    try {
      final response = await _storeDio.get<dynamic>(
        '$apiBase$path',
        options: Options(headers: _bearer(token)),
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || _isAuthError(e.response?.data)) {
        throw const LdStoreAuthExpiredException();
      }
      rethrow;
    }
  }

  static Map<String, String> _bearer(LdStoreToken token) => {
    'Authorization': 'Bearer ${token.value}',
    'Accept': 'application/json',
  };

  static Object? _unwrap(Object? body) {
    if (body is Map && body['success'] == true) return body['data'];
    if (_isAuthError(body)) throw const LdStoreAuthExpiredException();
    throw const FormatException('LD士多接口响应格式不对');
  }

  static bool _isAuthError(Object? body) {
    if (body is! Map) return false;
    final error = body['error'];
    final code = (error is Map ? error['code'] : null) ?? body['code'];
    return _authErrorCodes.contains('${code ?? ''}'.trim().toUpperCase());
  }

  // ---------------------------------------------------------------------------
  // 授权
  // ---------------------------------------------------------------------------

  /// 第一段：向商城要授权地址，打开 connect.linux.do 授权页，拿到同意链接。
  /// 不发出同意请求——那一步要等用户在确认框里点「允许」。
  Future<LdStorePendingAuthorization> beginAuthorization() async {
    final Uri authUrl;
    try {
      final response = await _storeDio.get<dynamic>(
        '$authApiBase/api/auth/init',
        queryParameters: {
          'site': 'linux.do',
          'return_url': returnUrl.toString(),
        },
      );
      final data = _unwrap(response.data);
      final raw = data is Map ? data['auth_url'] : null;
      authUrl = Uri.parse('$raw');
    } on DioException {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    } on FormatException {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    }
    _checkAuthUrl(authUrl);

    // 商城登录页加载完成 → 跳转授权页的导航延迟
    await _gap(minMs: 800, maxMs: 1500);

    var url = authUrl;
    for (var hop = 0; hop <= _maxAuthRedirects; hop++) {
      final Response<dynamic> response;
      try {
        response = await _forum.get<dynamic>(
          url.toString(),
          options: _forumOptions(),
        );
      } on DioException catch (e) {
        throw Exception(_failureMessage(e, S.current.oauth_networkError));
      }
      final location = _location(response, url);
      if (location == null) {
        final document = html_parser.parse('${response.data ?? ''}');
        final href = document
            .querySelector('a[href*="/oauth2/approve/"]')
            ?.attributes['href'];
        final approve = href == null ? null : url.resolve(href);
        if (approve == null ||
            approve.scheme != 'https' ||
            approve.host != _connectHost ||
            !approve.path.startsWith('/oauth2/approve/')) {
          throw Exception(S.current.oauth_approvePageParseFailed);
        }
        return LdStorePendingAuthorization._(approveUrl: approve);
      }
      if (_isOAuthCallback(location)) {
        return LdStorePendingAuthorization._(callbackUrl: location);
      }
      // 授权页可能先经论坛 SSO 换 connect 会话再跳回；只在这两个域名里跟随
      if (location.scheme != 'https' ||
          (location.host != _connectHost && location.host != _forumHost)) {
        throw Exception(S.current.oauth_approvePageParseFailed);
      }
      url = location;
    }
    throw Exception(S.current.oauth_approvePageParseFailed);
  }

  /// 第二段（用户已点「允许」）：发同意请求 → 商城后端换 code → 取回并校验
  /// 凭据 → 确认是 [expectedUsername] 本人 → 存起来。
  Future<LdStoreToken> completeAuthorization(
    LdStorePendingAuthorization pending, {
    required String expectedUsername,
  }) async {
    var callback = pending.callbackUrl;
    final approve = pending.approveUrl;
    if (approve != null) {
      // 手指反应 + 浏览器导航延迟
      await _gap(minMs: 600, maxMs: 1200);
      final Response<dynamic> response;
      try {
        response = await _forum.get<dynamic>(
          approve.toString(),
          options: _forumOptions(),
        );
      } on DioException catch (e) {
        throw Exception(_failureMessage(e, S.current.oauth_networkError));
      }
      callback = _location(response, approve);
      if (callback == null) throw Exception(S.current.oauth_noRedirectResponse);
    }
    if (callback == null || !_isOAuthCallback(callback)) {
      throw Exception(S.current.oauth_callbackFailed);
    }
    final params = callback.queryParameters;
    if ((params['code'] ?? '').isEmpty || (params['state'] ?? '').isEmpty) {
      throw Exception(S.current.oauth_missingParams);
    }

    // 浏览器跳回商城后端的延迟
    await _gap(minMs: 400, maxMs: 900);

    final Response<dynamic> response;
    try {
      response = await _storeDio.get<dynamic>(
        callback.toString(),
        options: Options(
          followRedirects: false,
          // 换 code 失败时后端回 4xx/5xx JSON，要读出它的说明
          validateStatus: (status) => status != null,
          extra: {FluxRequestKeys.skipRedirect: true},
        ),
      );
    } on DioException {
      throw Exception(S.current.oauth_callbackFailed);
    }
    final landing = _landingOf(response, callback);
    if (landing == null ||
        landing.origin != siteUrl ||
        landing.path != returnUrl.path) {
      // 只记页面形态，不记内容（里面就是凭据）
      final body = '${response.data ?? ''}';
      final marks = [
        'ldsp_oauth',
        'ldcstore.com',
        'location.replace',
        'returnBtn',
      ].where(body.contains).join(',');
      AppLogger.warning(
        'LD士多回调没有给出落点: status=${response.statusCode} '
        'type=${response.headers.value(Headers.contentTypeHeader)} '
        'length=${body.length} marks=[$marks]',
        tag: 'LdStore',
      );
      throw Exception(
        _callbackError(response.data) ?? S.current.oauth_callbackFailed,
      );
    }
    final token = LdStoreLoginPayload.fromRedirect(landing, now: _clock());
    if (token == null) {
      AppLogger.warning(
        'LD士多回调的登录结果解析不出: '
        'inFragment=${landing.fragment.contains('ldsp_oauth=')} '
        'inQuery=${landing.query.contains('ldsp_oauth=')}',
        tag: 'LdStore',
      );
      throw Exception(S.current.oauth_callbackFailed);
    }

    await _verify(token);
    if (token.site != 'linux.do' ||
        token.username.toLowerCase() != expectedUsername.toLowerCase()) {
      throw Exception(S.current.ldStore_accountMismatch);
    }
    await saveToken(expectedUsername, token);
    return token;
  }

  /// 凭据先给商城校验一遍再采用（与商城前端的登录回调一致）。
  Future<void> _verify(LdStoreToken token) async {
    try {
      final response = await _storeDio.get<dynamic>(
        '$apiBase/api/shop/auth/verify',
        options: Options(headers: _bearer(token)),
      );
      final data = _unwrap(response.data);
      final user = data is Map ? data['user'] : null;
      if (data is! Map ||
          data['authenticated'] != true ||
          user is! Map ||
          '${user['id']}' != token.userId ||
          '${user['site'] ?? 'linux.do'}' != token.site) {
        throw Exception(S.current.ldStore_verifyFailed);
      }
    } on DioException {
      throw Exception(S.current.ldStore_verifyFailed);
    } on LdStoreAuthExpiredException {
      throw Exception(S.current.ldStore_verifyFailed);
    } on FormatException {
      throw Exception(S.current.ldStore_verifyFailed);
    }
  }

  static Options _forumOptions() => Options(
    followRedirects: false,
    validateStatus: (status) => status != null && status < 500,
    extra: {
      FluxRequestKeys.skipCsrf: true,
      FluxRequestKeys.skipRedirect: true,
      FluxRequestKeys.allowRedirectSetCookie: true,
    },
  );

  static Uri? _location(Response<dynamic> response, Uri base) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value('location');
    if (location == null || location.isEmpty) return null;
    return base.resolve(location);
  }

  /// 商城后端换完 code 后的落点。302 时在 Location；线上实际回 200 的一页
  /// HTML「授权成功，正在跳转」，由脚本 `location.replace(redirectUrl)` 跳过去，
  /// 同一个地址也写在页面的「返回」按钮上。只认跳回商城登录回调页的地址。
  static Uri? _landingOf(Response<dynamic> response, Uri base) {
    final location = _location(response, base);
    if (location != null) return location;
    final body = response.data;
    if (body is! String) return null;
    final text = body
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll('&amp;', '&');
    for (final match in _landingPattern.allMatches(text)) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri != null &&
          (uri.fragment.contains('ldsp_oauth=') ||
              uri.query.contains('ldsp_oauth='))) {
        return uri;
      }
    }
    return null;
  }

  static final _landingPattern = RegExp(
    r'''https://ldcstore\.com/auth/callback[^"'<>\s\\]*''',
  );

  /// 回调失败时后端给的说明：JSON `{error: {message}}` 或失败页的 error-detail。
  static String? _callbackError(Object? body) {
    if (body is Map) {
      final error = body['error'];
      final message = error is Map ? error['message'] : null;
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
      return null;
    }
    if (body is! String) return null;
    final match = RegExp(r'class="error-detail">([^<]{1,200})<')
        .firstMatch(body);
    final message = match?.group(1)?.trim();
    return message == null || message.isEmpty ? null : message;
  }

  static bool _isOAuthCallback(Uri uri) =>
      uri.scheme == oauthCallback.scheme &&
      uri.host == oauthCallback.host &&
      uri.path == oauthCallback.path;

  /// 只认商城登记的回调：换成别的应用或别的回调地址都不授权。
  static void _checkAuthUrl(Uri url) {
    final params = url.queryParameters;
    final scopes = (params['scope'] ?? '')
        .split(' ')
        .where((s) => s.isNotEmpty);
    if (url.scheme != 'https' ||
        url.host != _connectHost ||
        url.path != '/oauth2/authorize' ||
        params['response_type'] != 'code' ||
        (params['client_id'] ?? '').isEmpty ||
        (params['state'] ?? '').isEmpty ||
        params['redirect_uri'] != oauthCallback.toString() ||
        scopes.any((s) => s != 'openid' && s != 'profile')) {
      throw Exception(S.current.oauth_getAuthUrlFailed);
    }
  }

  static String _failureMessage(DioException e, String fallback) =>
      CfChallengeClassifier.isChallengeFailure(e)
      ? S.current.cf_operationBlockedByChallenge
      : fallback;

  // ---------------------------------------------------------------------------
  // 内置浏览器
  // ---------------------------------------------------------------------------

  /// 内置浏览器打开商城时注入的登录态脚本（只在 ldcstore.com 主框架里跑）。
  ///
  /// - 已授权：网页没登录、登录已到期或登录的不是同一个人时，写入 App 的凭据
  ///   （格式同商城前端 `ld_store_token`）；网页自己登录着同一个人就不动。
  /// - 未授权但刚退出过：清掉网页里那枚（或更早签发的）凭据。
  static UserScript? webSessionScript({
    LdStoreToken? token,
    LdStoreRevocation? revocation,
  }) {
    if (token == null && revocation == null) return null;
    final config = jsonEncode({
      'key': _webTokenKey,
      if (token != null)
        'token': {
          'value': token.value,
          'sub': token.userId,
          'site': token.site,
          'exp': token.expiresAt.millisecondsSinceEpoch ~/ 1000,
        },
      if (revocation != null)
        'revoked': {
          'sub': revocation.userId,
          'site': revocation.site,
          'exp': revocation.expiresAt.millisecondsSinceEpoch ~/ 1000,
        },
    });
    return UserScript(
      source: _webSessionSource.replaceFirst('__CONFIG__', config),
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: true,
      allowedOriginRules: {siteUrl},
    );
  }

  static const _webSessionSource = r'''
(function () {
  try {
    if (location.origin !== 'https://ldcstore.com') return;
    var config = __CONFIG__;
    var key = config.key;
    function claims(jwt) {
      try {
        var part = String(jwt).split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
        while (part.length % 4) part += '=';
        var data = JSON.parse(atob(part));
        return {
          sub: String(data.sub != null ? data.sub : data.id),
          site: data.site || 'linux.do',
          exp: typeof data.exp === 'number' ? data.exp : 0
        };
      } catch (e) { return null; }
    }
    var stored = null;
    try {
      var item = JSON.parse(localStorage.getItem(key) || 'null');
      if (item && typeof item.value === 'string') stored = item.value;
    } catch (e) {}
    var current = stored ? claims(stored) : null;
    var mine = config.token;
    if (mine) {
      if (stored === mine.value) return;
      if (current && current.sub === mine.sub && current.site === mine.site &&
          current.exp * 1000 > Date.now() + 30000) return;
      localStorage.setItem(key, JSON.stringify({
        value: mine.value, timestamp: Date.now(), expire: mine.exp * 1000
      }));
      return;
    }
    var revoked = config.revoked;
    if (revoked && current && current.sub === revoked.sub &&
        current.site === revoked.site && current.exp <= revoked.exp) {
      localStorage.removeItem(key);
    }
  } catch (e) {}
})();
''';
}
