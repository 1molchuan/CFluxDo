import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 站点自己嵌入的公开 Turnstile 配置。Managed Challenge 的临时 widget
/// 不属于这个模型，不能拿挑战页里的内部 key 做长期续期。
class TurnstileConfiguration {
  const TurnstileConfiguration({required this.origin, required this.sitekey});

  final String origin;
  final String sitekey;

  static final _validKey = RegExp(r'^[A-Za-z0-9_-]{10,100}$');
  static final _managedPage = RegExp(r'\b_cf_chl_opt\s*=');
  static final _renderCall = RegExp(r'\bturnstile\s*\.\s*render\s*\(');
  static final _keyField = RegExp(
    r'''(?:["']sitekey["']|\bsitekey)\s*:\s*(["'])([A-Za-z0-9_-]{10,100})\1''',
  );

  static bool sameOrigin(Uri source, Uri expected) =>
      source.scheme == 'https' &&
      expected.scheme == 'https' &&
      source.hasAuthority &&
      expected.hasAuthority &&
      source.host.isNotEmpty &&
      source.userInfo.isEmpty &&
      source.origin == expected.origin;

  /// 仅查看本站的 HTML，不执行脚本、不抓取跨域 iframe、不读取任何 token。
  static TurnstileConfiguration? fromHtml(
    String html, {
    required Uri source,
    required Uri expected,
  }) {
    if (!sameOrigin(source, expected) || _managedPage.hasMatch(html)) {
      return null;
    }
    final document = html_parser.parse(html);
    final providerPresent = document.querySelectorAll('script[src]').any((tag) {
      final parsed = Uri.tryParse(tag.attributes['src'] ?? '');
      if (parsed == null) return false;
      final src = source.resolveUri(parsed);
      return src.scheme == 'https' &&
          src.host == 'challenges.cloudflare.com' &&
          src.path.startsWith('/turnstile/');
    });
    final candidates = <String>{};
    for (final tag in document.querySelectorAll('[data-sitekey]')) {
      if (_insideContent(tag)) continue;
      if (providerPresent ||
          tag.classes.contains('cf-turnstile') ||
          (tag.id.toLowerCase().contains('turnstile'))) {
        candidates.add(tag.attributes['data-sitekey'] ?? '');
      }
    }
    for (final script in document.querySelectorAll('script:not([src])')) {
      final type = (script.attributes['type'] ?? '').toLowerCase();
      if (type.isNotEmpty && type != 'text/javascript' && type != 'module') {
        continue;
      }
      if (_insideContent(script) || !_renderCall.hasMatch(script.text)) {
        continue;
      }
      for (final match in _keyField.allMatches(script.text)) {
        candidates.add(match.group(2)!);
      }
    }
    return _unique(source, candidates);
  }

  static bool _insideContent(Element tag) {
    Element? node = tag;
    while (node != null) {
      if (const {
            'article',
            'blockquote',
            'pre',
            'code',
          }.contains(node.localName) ||
          node.classes.contains('cooked') ||
          node.classes.contains('post-stream')) {
        return true;
      }
      node = node.parent;
    }
    return false;
  }

  static TurnstileConfiguration? _unique(Uri source, Iterable<String> keys) {
    final candidates = keys.where((key) => _validKey.hasMatch(key)).toSet();
    // 同一页多个 widget key 时不猜哪一个支持 pre-clearance。
    if (candidates.length != 1) return null;
    return TurnstileConfiguration(
      origin: source.origin,
      sitekey: candidates.single,
    );
  }

  /// WebView 主 frame 的只读快照。原生侧再次校验来源；不相信 iframe 的
  /// bridge 回调，也不把页面 HTML / 会话 token 传到原生层。
  static TurnstileConfiguration? fromSnapshot(
    Object? snapshot, {
    required Uri expected,
  }) {
    if (snapshot is String) {
      try {
        snapshot = jsonDecode(snapshot);
      } catch (_) {
        return null;
      }
    }
    if (snapshot is! Map || snapshot['managed'] != false) return null;
    final source = Uri.tryParse(snapshot['href']?.toString() ?? '');
    final keys = snapshot['keys'];
    if (source == null || !sameOrigin(source, expected) || keys is! List) {
      return null;
    }
    return _unique(source, keys.whereType<String>());
  }

  /// 公开配置缓存按 origin 独立保存，过期后重新发现。缓存里没有 Cookie。
  static const cacheLifetime = Duration(days: 1);
  static String cacheKey(Uri origin) =>
      'cf_turnstile_config_v1:${origin.origin}';

  String encode(DateTime observedAt) => jsonEncode({
    'origin': origin,
    'sitekey': sitekey,
    'observedAt': observedAt.millisecondsSinceEpoch,
  });

  static TurnstileConfiguration? decode(
    String? encoded, {
    required Uri expected,
    required DateTime now,
  }) {
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map ||
          value['observedAt'] is! int ||
          value['sitekey'] is! String) {
        return null;
      }
      final source = Uri.tryParse(value['origin']?.toString() ?? '');
      final age = now.millisecondsSinceEpoch - (value['observedAt'] as int);
      if (source == null ||
          !sameOrigin(source, expected) ||
          age < 0 ||
          age >= cacheLifetime.inMilliseconds ||
          !_validKey.hasMatch(value['sitekey'] as String)) {
        return null;
      }
      return TurnstileConfiguration(
        origin: source.origin,
        sitekey: value['sitekey'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  static const snapshotScript = r'''
(function () {
  var result = {href: location.href, managed: !!window._cf_chl_opt, keys: []};
  if (window.top !== window || result.managed) return result;
  function inContent(node) {
    return !!node.closest('article, blockquote, pre, code, .cooked, .post-stream');
  }
  var provider = Array.from(document.querySelectorAll('script[src]')).some(function (node) {
    try {
      var url = new URL(node.src, location.href);
      return url.protocol === 'https:' && url.hostname === 'challenges.cloudflare.com' &&
        url.pathname.indexOf('/turnstile/') === 0;
    } catch (_) { return false; }
  });
  document.querySelectorAll('[data-sitekey]').forEach(function (node) {
    if (inContent(node)) return;
    if (provider || node.classList.contains('cf-turnstile') || /turnstile/i.test(node.id)) {
      result.keys.push(node.getAttribute('data-sitekey'));
    }
  });
  document.querySelectorAll('script:not([src])').forEach(function (node) {
    var type = (node.getAttribute('type') || '').toLowerCase();
    if (inContent(node) || (type && type !== 'text/javascript' && type !== 'module')) return;
    var text = node.textContent || '';
    if (!/\bturnstile\s*\.\s*render\s*\(/.test(text)) return;
    var pattern = /(?:["']sitekey["']|\bsitekey)\s*:\s*(["'])([A-Za-z0-9_-]{10,100})\1/g;
    var match;
    while ((match = pattern.exec(text))) result.keys.push(match[2]);
  });
  return result;
})()
''';
}
