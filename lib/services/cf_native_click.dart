import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'cf_challenge_logger.dart';
import 'network/cf/cf_tap_policy.dart';

class CfNativeClick {
  const CfNativeClick._();

  static const _channel = MethodChannel('com.fluxdo/cf_native_click');

  static bool get isSupported => io.Platform.isAndroid;

  static Future<({double nx, double ny, String source})?> locate(
    InAppWebViewController controller,
  ) async {
    for (var attempt = 0; attempt < CfTapPolicy.locateAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(CfTapPolicy.locateRetryDelay);
      }
      try {
        final raw = await controller.evaluateJavascript(source: _locatorScript);
        final rect = _decodeRect(raw);
        if (rect == null) continue;
        final point = CfTapPolicy.normalize(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          viewportWidth: rect.viewportWidth,
          viewportHeight: rect.viewportHeight,
        );
        return (nx: point.nx, ny: point.ny, source: rect.source);
      } catch (e) {
        CfChallengeLogger.log('[VERIFY] 定位 Turnstile 失败: $e');
      }
    }
    return null;
  }

  static Future<bool> tap({
    required int? viewId,
    required String? host,
    required double nx,
    required double ny,
  }) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('tap', {
        'viewId': viewId,
        'host': host,
        'nx': nx,
        'ny': ny,
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      CfChallengeLogger.log('[VERIFY] 原生触摸通道异常: ${e.message}');
      return false;
    }
  }

  static _WidgetRect? _decodeRect(Object? raw) {
    Object? value = raw;
    for (var depth = 0; depth < 2 && value is String; depth++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    final map = value;
    double? number(String key) => (map[key] as num?)?.toDouble();
    final left = number('left');
    final top = number('top');
    final width = number('width');
    final height = number('height');
    final viewportWidth = number('vw');
    final viewportHeight = number('vh');
    if (left == null ||
        top == null ||
        width == null ||
        height == null ||
        viewportWidth == null ||
        viewportHeight == null ||
        width < 8 ||
        height < 8 ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      return null;
    }
    return _WidgetRect(
      left: left,
      top: top,
      width: width,
      height: height,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      source: map['source']?.toString() ?? 'iframe',
    );
  }

  static const _locatorScript = r'''
(function () {
  function metrics() {
    var vv = window.visualViewport;
    if (vv && vv.width > 0 && vv.height > 0) {
      return {
        ox: vv.offsetLeft || 0,
        oy: vv.offsetTop || 0,
        vw: vv.width,
        vh: vv.height
      };
    }
    var vw = innerWidth || (document.documentElement && document.documentElement.clientWidth) || 0;
    var vh = innerHeight || (document.documentElement && document.documentElement.clientHeight) || 0;
    return {ox: 0, oy: 0, vw: vw, vh: vh};
  }
  var m = metrics();
  if (m.vw <= 0 || m.vh <= 0) return null;
  var isChallenge = typeof window._cf_chl_opt !== 'undefined' ||
    !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage');
  if (!isChallenge) return null;
  function usable(el) {
    if (!el) return false;
    if (el.closest && el.closest('#__fluxdo_preclearance')) return false;
    var r = el.getBoundingClientRect();
    if (!(r.width >= 8 && r.height >= 8)) return false;
    if (r.right <= m.ox || r.bottom <= m.oy ||
        r.left >= m.ox + m.vw || r.top >= m.oy + m.vh) {
      return false;
    }
    var s = window.getComputedStyle ? getComputedStyle(el) : null;
    if (s && (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0')) {
      return false;
    }
    return true;
  }
  function describe(el, source) {
    var r = el.getBoundingClientRect();
    return {
      left: r.left - m.ox, top: r.top - m.oy,
      width: r.width, height: r.height,
      vw: m.vw, vh: m.vh, source: source
    };
  }
  var selectors = [
    ['#challenge-stage iframe', 'stage-iframe'],
    ['#challenge-form iframe', 'form-iframe'],
    ['#cf-challenge-running iframe', 'running-iframe'],
    ['iframe[src*="challenges.cloudflare.com"]', 'turnstile-iframe'],
    ['iframe[src*="challenge-platform"]', 'challenge-iframe'],
    ['.cf-turnstile iframe', 'widget-iframe']
  ];
  for (var i = 0; i < selectors.length; i++) {
    var nodes = document.querySelectorAll(selectors[i][0]);
    for (var j = 0; j < nodes.length; j++) {
      if (usable(nodes[j])) return describe(nodes[j], selectors[i][1]);
    }
  }
  var stage = document.querySelector('#challenge-stage, #cf-challenge-running, .cf-turnstile');
  if (usable(stage)) return describe(stage, 'challenge-stage');
  return null;
})()
''';
}

class _WidgetRect {
  const _WidgetRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.source,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final double viewportWidth;
  final double viewportHeight;
  final String source;
}
