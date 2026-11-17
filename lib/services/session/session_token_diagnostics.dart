import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config/forum_site.dart';
import '../log/log_writer.dart';
import '../network/cookie/boundary_sync_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../site_context.dart';
import 'session_token_authority.dart';

/// 把每个站点 CookieJar / WebView 里的 `_t` 摘要（长度 + 脱敏哈希）记进日志。
///
/// 2026-11 佬友日志：切到 2molchuan 后去 IDC Flare 待了 10 小时，切回来时
/// 这个账号已经被服务端拒绝；那段时间 App 没有碰过 linux.do，日志里却看
/// 不出 WebView 那边的 `_t` 有没有动过、两端是不是一致，没法判断是两端分叉
/// 还是服务端删了会话。切站、启动、切账号、被动登出时各记一份，下次就能
/// 顺着哈希看出是哪一边先变的。
abstract final class SessionTokenDiagnostics {
  static const _name = SessionTokenAuthority.cookieName;

  /// 各站点两端 `_t` 的摘要。读不到的一项记 `error`，整体不抛异常。
  @visibleForTesting
  static Future<Map<String, Object?>> Function() snapshotOverride =
      _snapshot;

  @visibleForTesting
  static void resetSnapshotForTesting() => snapshotOverride = _snapshot;

  static Future<Map<String, Object?>> snapshot() => snapshotOverride();

  static Future<Map<String, Object?>> _snapshot() async {
    final jar = CookieJarService();
    final result = <String, Object?>{};
    for (final site in ForumSite.values) {
      final entry = <String, Object?>{};
      try {
        final cookies = await jar.loadCanonicalCookiesForRequest(
          Uri.parse(site.baseUrl),
        );
        final values = [
          for (final cookie in cookies)
            if (cookie.name == _name && cookie.value.isNotEmpty) cookie.value,
        ];
        final value = values.isEmpty ? null : values.first;
        entry['jarTLen'] = value?.length;
        entry['jarTHash'] = SessionTokenAuthority.tokenHash(value);
        if (values.length > 1) entry['jarTCount'] = values.length;
        try {
          final webView = await BoundarySyncService.instance
              .readCookieValueFromWebView(
                currentUrl: site.baseUrl,
                name: _name,
                allowLowConfidenceSessionCookies: true,
              );
          entry['webViewTLen'] = webView?.length;
          entry['webViewTHash'] = SessionTokenAuthority.tokenHash(webView);
          entry['same'] = value != null && value == webView;
        } catch (e) {
          entry['webViewError'] = e.runtimeType.toString();
        }
      } catch (e) {
        entry['jarError'] = e.runtimeType.toString();
      }
      result[site.host] = entry;
    }
    return result;
  }

  /// 记一条 `session_tokens` 日志。最多等 [timeout]，超时就不记。
  static Future<void> log(
    String reason, {
    Map<String, Object?> extra = const {},
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final sites = await snapshot().timeout(timeout);
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'session_tokens',
        'message': '各站点两端的 _t 摘要（$reason）',
        'reason': reason,
        'site': SiteContext.current.host,
        ...extra,
        'sites': sites,
      });
    } catch (e) {
      debugPrint('[SessionTokenDiagnostics] $reason 记录失败: $e');
    }
  }
}
