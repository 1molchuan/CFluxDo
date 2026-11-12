import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app_logger.dart';
import '../../site_context.dart';
import '../../webview_render_gone.dart';
import '../../webview_settings.dart';
import '../doh/network_settings_service.dart';
import 'doh_proxy_service.dart';

/// WebView 主动采样请求头顺序。
///
/// 网关按 WebView 的 fetch 请求给原生请求排头顺序，而 Chromium 的头顺序随头名组合变化，
/// 原生请求的组合 WebView 平时未必发过。核心把对不上的组合记下来（`probe_pending`），这里
/// 让隐藏 WebView 打开 `https://<论坛>/__cfluxdo_probe__/`，页面按这些组合各发一个同源 fetch，
/// 核心在 h2 MITM 里记下 WebView 的真实顺序（见 core/doh_proxy/src/fetch_probe.rs）。
///
/// 采样页里的 fetch 还会带上站点用 Accept-CH 要过的高熵 Client Hints，核心记下后网关道的请求
/// 照着带（原生请求冒充的正是论坛页面里的 fetch）。
///
/// 页面与这些请求都由本地核心直接应答，不出本机、不碰论坛。只在安卓网关模式、开了 h2 MITM
/// 与浏览器指纹、核心报告有待采组合时跑；两次之间至少隔 10 分钟，一个进程最多跑 6 次。
class FetchOrderProbeService {
  FetchOrderProbeService._()
    : _eligible = _defaultEligible,
      _pending = _defaultPending,
      _probe = _probeWithWebView;

  @visibleForTesting
  FetchOrderProbeService.forTesting({
    required bool Function() eligible,
    required int Function() pending,
    required Future<void> Function(Uri url) probe,
  }) : _eligible = eligible,
       _pending = pending,
       _probe = probe;

  static final FetchOrderProbeService instance = FetchOrderProbeService._();

  static const String probePath = '/__cfluxdo_probe__/';
  static const String _doneTitle = 'cfluxdo-probe-done';
  static const Duration _defaultDelay = Duration(seconds: 30);
  static const Duration _minInterval = Duration(minutes: 10);
  static const Duration _probeTimeout = Duration(seconds: 15);
  static const int _maxRunsPerProcess = 6;

  final bool Function() _eligible;
  final int Function() _pending;
  final Future<void> Function(Uri url) _probe;

  Timer? _timer;
  Future<void>? _inflight;
  DateTime? _lastRun;
  int _runs = 0;

  /// 过一会儿看看要不要采：启动预加载完、回前台时调。原生请求先发一阵，核心才知道缺哪些组合
  void schedule({required String reason, Duration delay = _defaultDelay}) {
    if (!Platform.isAndroid) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(maybeRun(reason: reason)));
  }

  /// 条件满足就采一次；并发调用合并
  Future<void> maybeRun({required String reason}) {
    return _inflight ??= _run(reason).whenComplete(() => _inflight = null);
  }

  Future<void> _run(String reason) async {
    if (!_eligible() || _runs >= _maxRunsPerProcess) return;
    final last = _lastRun;
    if (last != null && DateTime.now().difference(last) < _minInterval) return;
    final pending = _pending();
    if (pending <= 0) return;

    _lastRun = DateTime.now();
    _runs++;
    final started = DateTime.now();
    final url = Uri.https(SiteContext.current.host, probePath);
    try {
      await _probe(url);
      AppLogger.info(
        '请求头顺序采样完成',
        tag: 'Fingerprint',
        fields: {
          'reason': reason,
          'pendingBefore': pending,
          'pendingAfter': _pending(),
          'ms': DateTime.now().difference(started).inMilliseconds,
        },
      );
    } catch (error) {
      AppLogger.warning(
        '请求头顺序采样失败',
        tag: 'Fingerprint',
        fields: {'reason': reason, 'error': error.toString()},
      );
    }
    // 第一次采样多半会换一组 Client Hints，原生请求随之出现新的组合：用着用着再看一眼
    if (_runs < _maxRunsPerProcess) {
      schedule(
        reason: 'followup',
        delay: _minInterval + const Duration(seconds: 5),
      );
    }
  }

  static bool _defaultEligible() {
    if (!Platform.isAndroid) return false;
    final settings = NetworkSettingsService.instance;
    return settings.relaysWebViewThroughGateway &&
        settings.current.h2Mitm &&
        settings.current.browserTls;
  }

  static int _defaultPending() {
    final pending = DohProxyService.instance
        .fingerprintStatus()?['probe_pending'];
    return pending is int ? pending : 0;
  }

  /// 隐藏 WebView 打开采样页，等页面把标题改成完成标记（或超时）
  static Future<void> _probeWithWebView(Uri url) async {
    final done = Completer<void>();
    void finish([Object? error]) {
      if (done.isCompleted) return;
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error);
      }
    }

    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(url)),
      initialSettings: WebViewSettings.headlessCf,
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      onTitleChanged: (_, title) {
        if (title == _doneTitle) finish();
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame ?? true) {
          finish(StateError('load failed: ${error.description}'));
        }
      },
      onRenderProcessGone: (_, detail) {
        WebViewRenderGone.report('fetch_order_probe', detail);
        finish(StateError('render process gone'));
      },
    );
    try {
      await webView.run();
      await done.future.timeout(_probeTimeout);
    } finally {
      await webView.dispose();
    }
  }
}
