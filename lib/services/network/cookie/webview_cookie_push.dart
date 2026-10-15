import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../constants.dart';
import '../../log/log_writer.dart';
import '../../session/session_token_authority.dart';
import 'boundary_sync_service.dart';
import 'cookie_jar_service.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// 把一枚 cookie 推进 WebView 并读回确认（失败重试一次、记日志）。
///
/// 只管「写进去了没有」这一个机械动作，不判断该不该写：`_t` 该写哪个值由
/// [SessionTokenAuthority] 决定，其他会话 cookie（`_forum_session`）由
/// AppCookieManager 在 Dio 收到服务端新值时直接推。
class WebViewCookiePush {
  WebViewCookiePush._();
  static final WebViewCookiePush instance = WebViewCookiePush._();

  static const Duration _retryDelay = Duration(milliseconds: 150);

  CookieJarService _jar = CookieJarService();
  BoundarySyncService _boundary = BoundarySyncService.instance;
  RawCookieWriter _writer = RawCookieWriter.instance;
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;

  /// 仅测试用：替换内部依赖。
  @visibleForTesting
  void replaceDependenciesForTest({
    CookieJarService? jar,
    BoundarySyncService? boundary,
    RawCookieWriter? writer,
    SessionCookieSentinel? sentinel,
  }) {
    if (jar != null) _jar = jar;
    if (boundary != null) _boundary = boundary;
    if (writer != null) _writer = writer;
    if (sentinel != null) _sentinel = sentinel;
  }

  /// 把 [name] 推进 WebView，读回到 [expectedValue] 才算成功。
  ///
  /// [rawSetCookie] 与 [expectedValue] 不传时从 jar 读 canonical。
  /// [clearVariantsFirst] 先清掉同名所有变体（第二次尝试总会先清）。
  Future<bool> push({
    required String name,
    required String reason,
    String? url,
    String? rawSetCookie,
    String? expectedValue,
    bool clearVariantsFirst = false,
  }) async {
    final targetUrl = url ?? AppConstants.baseUrl;
    var header = rawSetCookie;
    var expected = expectedValue;
    if (header == null || expected == null) {
      final canonical = await _jar.getCanonicalCookie(name);
      if (canonical == null || canonical.value.isEmpty) return false;
      header ??= canonical.toSetCookieHeader();
      expected ??= canonical.value;
    }

    var setResult = false;
    String? readBack;
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (clearVariantsFirst || attempt > 1) {
        try {
          await _sentinel.sweep(
            targetUrl,
            name,
            intent: SweepIntent.delete,
            force: true,
          );
        } catch (e) {
          debugPrint('[WebViewCookiePush] 推送前清理 $name 变体失败: $e');
        }
      }
      setResult = await _writer.setRawCookie(
        targetUrl,
        header,
        writeSharedStorage: name != 'cf_clearance',
      );
      readBack = await _readBack(targetUrl, name, expected);
      if (readBack == expected) {
        if (attempt > 1) {
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': 'info',
            'type': 'cookie_trace',
            'event': 'webview_cookie_push_recovered',
            'message': '$name 推送 WebView 首次读回不符，重试后已一致',
            'name': name,
            'reason': reason,
            'valueLength': expected.length,
            'valueHash': SessionTokenAuthority.tokenHash(expected),
          });
        }
        return true;
      }
      debugPrint(
        '[WebViewCookiePush] $name 推送 WebView 后读回不符 '
        '(attempt=$attempt, set=$setResult, reason=$reason)',
      );
      if (attempt == 1) await Future<void>.delayed(_retryDelay);
    }

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'cookie_trace',
      'event': 'webview_cookie_push_failed',
      'message': '$name 推送 WebView 两次后读回仍不符，WebView 可能仍持旧值',
      'name': name,
      'reason': reason,
      'setRawCookieResult': setResult,
      'expectedLength': expected.length,
      'expectedHash': SessionTokenAuthority.tokenHash(expected),
      'readBackLength': readBack?.length,
      'readBackHash': SessionTokenAuthority.tokenHash(readBack),
    });
    return false;
  }

  /// 读回 WebView 中 [name] 的值：只要任一变体等于 [expected] 就视为写入成功
  /// （多变体由随后的 sweep 收敛），否则返回「最佳」变体的值用于日志。
  Future<String?> _readBack(String url, String name, String expected) async {
    try {
      final infos = await _writer.getAllCookieInfos(url);
      for (final info in infos) {
        if (info.name == name && info.value == expected) return expected;
      }
    } catch (e) {
      debugPrint('[WebViewCookiePush] getAllCookieInfos 失败: $e');
    }
    try {
      return await _boundary.readCookieValueFromWebView(
        currentUrl: url,
        name: name,
        allowLowConfidenceSessionCookies: true,
      );
    } catch (e) {
      debugPrint('[WebViewCookiePush] 读回 $name 失败: $e');
      return null;
    }
  }
}
