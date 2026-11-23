import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'network/cf/cf_auto_tapper.dart';
import 'network/cf/cf_tap_policy.dart';

/// 替用户点 Turnstile 勾选框的平台层：页面里定位勾选框、经原生通道往
/// 指定的 WebView 注入一次触摸。流程控制见 [CfAutoTapper]。
class CfNativeClick {
  const CfNativeClick._();

  static const _channel = MethodChannel('com.fluxdo/cf_native_click');

  static bool get isSupported => io.Platform.isAndroid;

  /// 在挑战页里找勾选框，并确认那个点上没被别的东西盖住
  static Future<CfTapLocation> locate(InAppWebViewController controller) async {
    try {
      final raw = await controller.evaluateJavascript(source: locatorScript);
      return decodeLocation(raw);
    } catch (e) {
      return CfTapLocation.unavailable('script_error: $e');
    }
  }

  /// 往 [viewId] 对应的 WebView 注入一次触摸；找不到这个 WebView 就不点
  static Future<CfTapDispatch> tap({
    required int viewId,
    required double nx,
    required double ny,
  }) async {
    if (!isSupported) return const CfTapDispatch.failed('unsupported');
    try {
      final raw = await _channel.invokeMethod<Object?>('tap', {
        'viewId': viewId,
        'nx': nx,
        'ny': ny,
      });
      if (raw is Map && raw['ok'] == true) return const CfTapDispatch.ok();
      final reason = raw is Map ? raw['reason']?.toString() : null;
      return CfTapDispatch.failed(reason ?? 'unknown');
    } on MissingPluginException {
      return const CfTapDispatch.failed('no_plugin');
    } on PlatformException catch (e) {
      return CfTapDispatch.failed('${e.code}: ${e.message}');
    }
  }

  /// 解析定位脚本的返回值。Android 上 evaluateJavascript 可能多包一层 JSON 字符串。
  static CfTapLocation decodeLocation(Object? raw) {
    Object? value = raw;
    for (var depth = 0; depth < 2 && value is String; depth++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const CfTapLocation.unavailable('bad_result');
      }
    }
    if (value is! Map) return const CfTapLocation.unavailable('bad_result');
    if (value['ok'] != true) {
      return CfTapLocation.unavailable(
        value['reason']?.toString() ?? 'unknown',
      );
    }
    final x = (value['x'] as num?)?.toDouble();
    final y = (value['y'] as num?)?.toDouble();
    final vw = (value['vw'] as num?)?.toDouble();
    final vh = (value['vh'] as num?)?.toDouble();
    if (x == null ||
        y == null ||
        vw == null ||
        vh == null ||
        vw <= 0 ||
        vh <= 0) {
      return const CfTapLocation.unavailable('bad_result');
    }
    final nx = x / vw;
    final ny = y / vh;
    if (nx <= 0 || nx >= 1 || ny <= 0 || ny >= 1) {
      return const CfTapLocation.unavailable('out_of_viewport');
    }
    return CfTapLocation.point(
      nx: nx,
      ny: ny,
      source: value['source']?.toString() ?? 'unknown',
    );
  }

  /// 勾选框的点击点只在这里算：找 widget → 按 [CfTapPolicy.checkboxOffset] 的规则
  /// 取勾选框中心 → 用 elementFromPoint 确认这个点落在 widget 上（没被我们的遮罩
  /// 或别的元素盖住）。返回相对 visualViewport 的 CSS 像素坐标。
  ///
  /// 挑战页的 Turnstile iframe 可能在 closed shadow root 里，querySelector 找不到；
  /// 这时从挑战容器里找标准尺寸的宿主元素，elementFromPoint 也会落在宿主上。
  static final String locatorScript =
      '''
(function () {
  var MIN_W = ${CfTapPolicy.checkboxMinWidth}, MAX_H = ${CfTapPolicy.checkboxMaxHeight};
  var LEFT = ${CfTapPolicy.checkboxLeft}, LEFT_RATIO = ${CfTapPolicy.checkboxLeftRatio};
  var CHALLENGE = '#challenge-form, #challenge-running, #challenge-stage';
  function fail(reason) { return JSON.stringify({ok: false, reason: reason}); }
  if (typeof window._cf_chl_opt === 'undefined' && !document.querySelector(CHALLENGE)) {
    return fail('not_challenge');
  }
  // 页面里我们自己的 DOM 遮罩会挡住勾选框；用户看到的是 Flutter 层的覆盖，
  // 撤掉它不会露出页面（导航时 notifyNav 会再强制盖上）
  try { if (window.__fluxdoHideCfMask) window.__fluxdoHideCfMask(); } catch (_) {}
  var vv = window.visualViewport;
  var ox = vv ? (vv.offsetLeft || 0) : 0, oy = vv ? (vv.offsetTop || 0) : 0;
  var vw = vv && vv.width > 0 ? vv.width : (innerWidth || 0);
  var vh = vv && vv.height > 0 ? vv.height : (innerHeight || 0);
  if (vw <= 0 || vh <= 0) return fail('no_viewport');

  function shown(el) {
    if (!el || (el.closest && el.closest('#__fluxdo_preclearance'))) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return false;
    var s = getComputedStyle(el);
    return s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
  }
  function standard(el) {
    var r = el.getBoundingClientRect();
    return r.width >= MIN_W && r.height > 0 && r.height <= MAX_H;
  }
  var candidates = [];
  var iframes = document.querySelectorAll(
    '#challenge-stage iframe, #challenge-form iframe, #challenge-running iframe, ' +
    'iframe[src*="challenges.cloudflare.com"], iframe[src*="challenge-platform"], ' +
    '.cf-turnstile iframe');
  for (var i = 0; i < iframes.length; i++) candidates.push([iframes[i], 'iframe']);
  // closed shadow root 的宿主：没有 light DOM 子节点、尺寸是标准 widget。
  // 挑战页的容器类名会变（2026-11 实测在 .main-content 下），所以扫整页，
  // 误选由下面的 elementFromPoint 兜住。
  var hosts = document.querySelectorAll('div');
  for (var j = 0; j < hosts.length; j++) {
    if (hosts[j].children.length === 0 && standard(hosts[j])) {
      candidates.push([hosts[j], 'shadow-host']);
    }
  }
  var sawWidget = false, lastReason = 'not_found';
  for (var k = 0; k < candidates.length; k++) {
    var el = candidates[k][0];
    if (!shown(el)) continue;
    sawWidget = true;
    if (!standard(el)) { lastReason = 'odd_size'; continue; }
    var r = el.getBoundingClientRect();
    var cx = r.left + Math.min(LEFT, r.width * LEFT_RATIO);
    var cy = r.top + r.height / 2;
    if (cx < ox || cy < oy || cx >= ox + vw || cy >= oy + vh) {
      lastReason = 'out_of_viewport';
      continue;
    }
    var hit = document.elementFromPoint(cx, cy);
    if (hit !== el && !(hit && el.contains(hit))) {
      lastReason = hit && hit.id === '__fluxdoCfMask' ? 'masked' : 'occluded';
      continue;
    }
    return JSON.stringify({
      ok: true, x: cx - ox, y: cy - oy, vw: vw, vh: vh, source: candidates[k][1]
    });
  }
  return fail(sawWidget ? lastReason : 'not_found');
})()
''';
}
