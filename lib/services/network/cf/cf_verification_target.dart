import 'dart:convert';

/// 一轮验证使用的同站入口。首页可用于展示站点的真实挑战；当首页无需
/// 挑战且没有签发新 Cookie 时，最多转入一次既有的 /challenge 探测入口。
/// 普通首页 200 不是通过信号，完成仍由验证轮次定稿并确认 Cookie 入 jar。
class CfVerificationTarget {
  CfVerificationTarget({required Uri primary, Uri? fallback})
    : _current = primary,
      _primary = primary,
      _fallback = fallback;

  Uri _current;
  Uri get current => _current;
  bool get canUseFallback => !_usedFallback && _fallback != null;
  final Uri _primary;
  final Uri? _fallback;
  bool _usedFallback = false;

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == 'https' &&
      b.scheme == 'https' &&
      a.hasAuthority &&
      b.hasAuthority &&
      a.host.isNotEmpty &&
      b.host.isNotEmpty &&
      a.userInfo.isEmpty &&
      b.userInfo.isEmpty &&
      a.origin == b.origin;

  static String _path(Uri url) => url.path.isEmpty ? '/' : url.path;

  bool matches(Uri url, {bool bare = false}) =>
      _sameOrigin(url, current) &&
      _path(url) == _path(current) &&
      (!bare || url.query.isEmpty);

  /// 本站首页（入口同源的 `/`，不带查询与片段）。
  Uri get home => Uri(
    scheme: _primary.scheme,
    host: _primary.host,
    port: _primary.hasPort ? _primary.port : null,
    path: '/',
  );

  /// [url] 是否就是本站首页（允许 CF 跳转残留的查询参数）。
  bool isHome(Uri url) => _sameOrigin(url, _primary) && _path(url) == '/';

  bool isConclusiveResponse({
    required Uri url,
    required int? statusCode,
    required bool isMainFrame,
    required bool cfMitigated,
  }) =>
      isMainFrame &&
      !cfMitigated &&
      matches(url, bare: true) &&
      _path(current) == '/challenge' &&
      statusCode == 404;

  Uri? useFallback(Object? snapshot) {
    if (snapshot is String) {
      try {
        snapshot = jsonDecode(snapshot);
      } catch (_) {
        return null;
      }
    }
    if (_usedFallback || _fallback == null || snapshot is! Map) {
      return null;
    }
    final actual = Uri.tryParse(snapshot['href']?.toString() ?? '');
    if (actual == null ||
        !matches(actual, bare: true) ||
        _path(_primary) != '/' ||
        snapshot['hasChallenge'] != false ||
        (snapshot['hasBootstrap'] != true &&
            snapshot['originNotFound'] != true) ||
        !_sameOrigin(_fallback, _primary) ||
        _path(_fallback) != '/challenge' ||
        _fallback.hasQuery ||
        _fallback.hasFragment) {
      return null;
    }
    _usedFallback = true;
    _current = _fallback;
    return current;
  }

  /// 正常 Discourse 首页可能嵌着用于后台 pre-clearance 的 Turnstile，
  /// 它不等于整页 Managed Challenge。只有完整首页标记齐全时才排除它。
  static bool hasActiveChallenge(String html) {
    if (html.contains('cf_chl_opt') ||
        html.contains('challenge-running') ||
        html.contains('challenge-stage')) {
      return true;
    }
    if (!html.contains('cf-turnstile')) return false;
    final setup = RegExp(
      r'''<meta\b[^>]*\bid=["']data-discourse-setup["']''',
      caseSensitive: false,
    );
    final preload = RegExp(
      r'''<(?:script|meta|div)\b[^>]*(?:\bid=["']data-preloaded["']|\bdata-preloaded\s*=)''',
      caseSensitive: false,
    );
    return !(setup.hasMatch(html) && preload.hasMatch(html));
  }

  /// 只读主 frame 的同源文档特征，不读取或传回会话数据。
  static const fallbackSnapshotScript = r'''
(function () {
  var html = document.documentElement ? document.documentElement.innerHTML : '';
  var bootstrap = !!document.querySelector('#data-discourse-setup') &&
    !!document.querySelector('#data-preloaded, [data-preloaded]');
  var challenge = html.indexOf('cf_chl_opt') !== -1 ||
    html.indexOf('challenge-running') !== -1 || html.indexOf('challenge-stage') !== -1 ||
    (!bootstrap && html.indexOf('cf-turnstile') !== -1);
  return {
    href: location.href,
    hasBootstrap: bootstrap,
    hasChallenge: challenge,
    originNotFound: /page-not-found|discourse-no-results|404-body|exist or is private|page you requested/i.test(html)
  };
})()
''';
}
