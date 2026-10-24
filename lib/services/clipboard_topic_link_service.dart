import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/discourse_url_parser.dart';
import '../config/forum_site.dart';

class ClipboardTopicLinkCandidate {
  final Uri uri;
  final String normalizedUrl;
  final int normalizedHash;

  const ClipboardTopicLinkCandidate({
    required this.uri,
    required this.normalizedUrl,
    required this.normalizedHash,
  });
}

class ClipboardTopicLinkService {
  ClipboardTopicLinkService._();

  static final ClipboardTopicLinkService instance =
      ClipboardTopicLinkService._();
  static const String lastPromptedHashPrefsKey =
      'pref_clipboard_topic_link_last_prompted_hash';

  static final RegExp _forumUrlRegex = RegExp(
    r'(?:(?:https?:)?//)?(?:www\.)?(?:linux\.do|idcflare\.com)(?::\d+)?/[^\s<>"\]\)）}】》]+',
    caseSensitive: false,
  );

  /// 进程内已提示过的链接 hash。
  /// 与持久化的 [lastPromptedHashPrefsKey] 配合使用：持久化只记最近一次，
  /// 而本集合用于在同一进程内挡掉历史提示链接，避免来回切换前后台时反复弹。
  /// 上限保护避免长生命周期累积。
  static const int _maxSeenHashes = 64;
  final Set<int> _seenHashes = <int>{};

  void _rememberSeen(int hash) {
    _seenHashes.add(hash);
    if (_seenHashes.length > _maxSeenHashes) {
      _seenHashes.remove(_seenHashes.first);
    }
  }

  Future<ClipboardTopicLinkCandidate?> checkClipboard({
    required bool enabled,
    int? lastPromptedHash,
  }) async {
    if (!enabled) return null;

    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text;
      if (text == null || text.isEmpty) return null;

      final candidate = findFirstTopicLink(text);
      if (candidate == null ||
          candidate.normalizedHash == lastPromptedHash ||
          _seenHashes.contains(candidate.normalizedHash)) {
        return null;
      }

      return candidate;
    } catch (_) {
      return null;
    }
  }

  Future<void> markPrompted(
    ClipboardTopicLinkCandidate candidate, {
    SharedPreferences? prefs,
  }) async {
    _rememberSeen(candidate.normalizedHash);
    await prefs?.setInt(lastPromptedHashPrefsKey, candidate.normalizedHash);
  }

  ClipboardTopicLinkCandidate? findFirstTopicLink(String text) {
    for (final match in _forumUrlRegex.allMatches(text)) {
      final rawUrl = _trimTrailingPunctuation(match.group(0)!);
      if (!_hasValidLeadingBoundary(text, match.start)) continue;

      final uri = _parseUri(rawUrl);
      if (uri == null || !_isAllowedHost(uri.host)) continue;
      if (!_isSupportedTopicPath(uri.path)) continue;
      if (DiscourseUrlParser.parseTopic(uri.path) == null) continue;

      final normalizedUri = _normalize(uri);
      final normalizedUrl = normalizedUri.toString();
      return ClipboardTopicLinkCandidate(
        uri: normalizedUri,
        normalizedUrl: normalizedUrl,
        normalizedHash: _stableHash(normalizedUrl),
      );
    }

    return null;
  }

  static bool _hasValidLeadingBoundary(String text, int start) {
    if (start == 0) return true;
    if (_looksEmbeddedInAnotherUrl(text, start)) return false;

    final previous = text.codeUnitAt(start - 1);
    // 前一个字符是冒号一律拒绝，覆盖 ://linux.do 与 mailto:linux.do 等情况
    if (previous == 0x3a) return false;
    if (previous == 0x3d || previous == 0x26) return false;

    return !_isAsciiLetterOrDigit(previous) &&
        previous != 0x2e &&
        previous != 0x2d &&
        previous != 0x2f &&
        previous != 0x5f;
  }

  static bool _looksEmbeddedInAnotherUrl(String text, int start) {
    var tokenStart = start;
    while (tokenStart > 0 && !_isWhitespace(text.codeUnitAt(tokenStart - 1))) {
      tokenStart--;
    }

    final prefix = text.substring(tokenStart, start).toLowerCase();
    return prefix.contains('://') ||
        prefix.contains('?') ||
        prefix.contains('&') ||
        prefix.contains('=');
  }

  static bool _isWhitespace(int codeUnit) {
    return codeUnit == 0x09 ||
        codeUnit == 0x0a ||
        codeUnit == 0x0b ||
        codeUnit == 0x0c ||
        codeUnit == 0x0d ||
        codeUnit == 0x20 ||
        codeUnit == 0x85 ||
        codeUnit == 0xa0 ||
        codeUnit == 0x1680 ||
        (codeUnit >= 0x2000 && codeUnit <= 0x200a) ||
        codeUnit == 0x2028 ||
        codeUnit == 0x2029 ||
        codeUnit == 0x202f ||
        codeUnit == 0x205f ||
        codeUnit == 0x3000;
  }

  static bool _isAsciiLetterOrDigit(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7a);
  }

  void clearSeenForTest() {
    _seenHashes.clear();
  }

  static Uri? _parseUri(String rawUrl) {
    if (rawUrl.startsWith('//')) {
      return Uri.tryParse('https:$rawUrl');
    }

    if (!rawUrl.contains('://')) {
      return Uri.tryParse('https://$rawUrl');
    }

    return Uri.tryParse(rawUrl);
  }

  static bool _isAllowedHost(String host) {
    final normalizedHost = host.toLowerCase();
    return ForumSite.values.any((site) =>
        normalizedHost == site.host || normalizedHost == 'www.${site.host}');
  }

  static bool _isSupportedTopicPath(String path) {
    final segments = Uri(path: path).pathSegments;
    if (segments.isEmpty || segments.first.toLowerCase() != 't') {
      return false;
    }

    if (segments.length == 2) {
      return _isPositiveInt(segments[1]);
    }

    if (segments.length == 3) {
      return (_isPositiveInt(segments[1]) && _isPositiveInt(segments[2])) ||
          (!_isPositiveInt(segments[1]) && _isPositiveInt(segments[2]));
    }

    if (segments.length == 4) {
      return !_isPositiveInt(segments[1]) &&
          _isPositiveInt(segments[2]) &&
          _isPositiveInt(segments[3]);
    }

    return false;
  }

  static bool _isPositiveInt(String value) {
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 0;
  }

  static Uri _normalize(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final keepPort = uri.hasPort && !_isDefaultPort(scheme, uri.port);
    return Uri(
      scheme: scheme,
      host: host,
      port: keepPort ? uri.port : null,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    );
  }

  static bool _isDefaultPort(String scheme, int port) {
    return (scheme == 'http' && port == 80) ||
        (scheme == 'https' && port == 443);
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  static String _trimTrailingPunctuation(String value) {
    var end = value.length;
    while (end > 0 && _isTrailingPunctuation(value.codeUnitAt(end - 1))) {
      end--;
    }
    return value.substring(0, end);
  }

  static bool _isTrailingPunctuation(int codeUnit) {
    return codeUnit == 0x2e ||
        codeUnit == 0x2c ||
        codeUnit == 0x3b ||
        codeUnit == 0x3a ||
        codeUnit == 0x21 ||
        codeUnit == 0x3f ||
        codeUnit == 0x27 ||
        codeUnit == 0x2019 ||
        codeUnit == 0x201d ||
        codeUnit == 0x3001 ||
        codeUnit == 0x3002 ||
        codeUnit == 0xff0c ||
        codeUnit == 0xff1b ||
        codeUnit == 0xff1a ||
        codeUnit == 0xff01 ||
        codeUnit == 0xff1f;
  }
}
