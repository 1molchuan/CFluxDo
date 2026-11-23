import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_logger.dart';
import '../site_context.dart';
import 'system_proxy_detector.dart';

/// 系统代理跟随服务（Windows、安卓）。
///
/// 背景:WebView2 默认跟随系统代理(如 Clash「系统代理」模式),而 Dio
/// 走直连。两者出口 IP 不一致时,验证 WebView 铸出的 cf_clearance 绑定的是
/// 代理节点 IP,对 Dio 的直连请求永远无效 → CF 验证无限循环。
///
/// 本服务周期读取系统代理:
/// - Windows：注册表（WinINet）；
/// - 安卓：`ConnectivityManager.getDefaultProxy()`（Wi-Fi 手动代理 / PAC，或
///   VPN 下发的 HTTP 代理），经原生通道 `fluxdo/system_proxy`。以前安卓完全
///   不看系统代理：用户靠 Wi-Fi 代理上论坛时，网关照样直连，内置网页也被
///   指到网关，代理形同虚设（2026-11-23 对照 xuemk/linuxdo-android 补上）。
///
/// - 已启用固定代理 → [effectiveProxyUrl] 返回代理地址,网关上游跟随,与
///   内置网页保持同一出口;代理进程若已死,请求显式失败(与系统浏览器一致),
///   不做可达性探测——探测无法区分翻墙代理与校园网等普通代理,不能作为
///   任何语义判定依据。
/// - 未启用 / PAC-only(无法在 Dart 侧求值) / 其他平台 → 直连。
///
/// VPN 虚拟网卡(TUN)模式不写系统代理,Dio 与 WebView 都经 TUN 出站,
/// 天然一致,无需本服务干预。
class SystemProxyService {
  SystemProxyService._();

  static final instance = SystemProxyService._();

  static const _refreshInterval = Duration(seconds: 10);
  static const _channel = MethodChannel('fluxdo/system_proxy');

  /// 状态版本号。系统代理配置（固定代理或 PAC）变化时自增,网络设置据此重启网关换上游出口。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  String? _effectiveProxyUrl;
  SystemProxyConfig _lastConfig = const SystemProxyConfig();
  Timer? _refreshTimer;
  bool _started = false;
  Future<void>? _androidRead;
  bool _androidChannelMissing = false;

  /// 测试替身：安卓原生读数
  @visibleForTesting
  static Future<Map<Object?, Object?>?> Function()? androidReaderOverride;

  /// 测试替身：当作安卓
  @visibleForTesting
  static bool? isAndroidOverride;

  static bool get isAndroid => isAndroidOverride ?? Platform.isAndroid;
  static bool get _supported => Platform.isWindows || isAndroid;

  /// 当前系统代理地址(已启用的固定代理),未启用时为 null。
  String? get effectiveProxyUrl {
    _ensureStarted();
    return _effectiveProxyUrl;
  }

  /// 系统层面的代理配置（含 PAC）,供诊断 UI 与 VPN 让路判断使用。
  SystemProxyConfig get registryConfig => _lastConfig;

  /// 系统代理是否启用（固定代理或 PAC）
  bool get isEnabled {
    _ensureStarted();
    return _lastConfig.isEnabled;
  }

  /// 启动周期刷新。不支持的平台为 no-op。
  void start() => _ensureStarted();

  /// 安卓首读是异步的：启动时网关要按它选上游，最多等 [timeout]
  Future<void> ready({Duration timeout = const Duration(milliseconds: 300)}) {
    _ensureStarted();
    final pending = _androidRead;
    if (pending == null) return Future.value();
    return pending.timeout(timeout, onTimeout: () {});
  }

  void _ensureStarted() {
    if (_started || !_supported) return;
    _started = true;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
    refresh();
  }

  /// 立即重读系统代理（安卓为异步，结果到了再更新 [version]）。
  void refresh() {
    if (isAndroid) {
      if (_androidChannelMissing) return;
      _androidRead ??= _readAndroid().whenComplete(() => _androidRead = null);
      return;
    }
    if (!Platform.isWindows) return;
    _apply(SystemProxyDetector.read());
  }

  Future<void> _readAndroid() async {
    Map<Object?, Object?>? raw;
    try {
      final reader = androidReaderOverride;
      raw = reader != null
          ? await reader()
          : await _channel.invokeMethod<Map<Object?, Object?>>('read');
    } on MissingPluginException {
      // 后台引擎（通知、工作管理器）没有注册这个通道：当成没有系统代理，别再问
      _androidChannelMissing = true;
      return;
    } catch (e) {
      debugPrint('[SystemProxy] 读取安卓系统代理失败: $e');
      return;
    }
    _apply(
      SystemProxyDetector.parseAndroid(
        raw,
        forumHost: SiteContext.current.host,
      ),
    );
  }

  void _apply(SystemProxyConfig config) {
    final previous = _lastConfig;
    _lastConfig = config;
    final effective = config.proxyUrl;
    if (config == previous && effective == _effectiveProxyUrl) return;
    debugPrint(
      '[SystemProxy] 系统代理变化: ${describe(previous)} -> ${describe(config)}',
    );
    if (isAndroid) {
      // 只记有没有、是不是回环，不记地址（日志会被分享出去）
      AppLogger.info(
        config.isEnabled
            ? '检测到系统代理（${config.proxyUrl == null ? 'PAC，无法跟随' : '固定代理'}），'
                  '${config.proxyUrl == null ? '' : '网关上游跟随，'}按 VPN 一样实测要不要让路'
            : '系统代理已关闭',
        tag: 'SystemProxy',
        fields: {'proxy': describe(config)},
      );
    }
    _effectiveProxyUrl = effective;
    version.value++;
  }

  /// 诊断用的脱敏描述：`none` / `pac` / `http@loopback` / `http@lan` / `http@remote`
  static String describe(SystemProxyConfig config) {
    if (!config.isEnabled) return 'none';
    final url = config.proxyUrl;
    if (url == null) return 'pac';
    final uri = Uri.tryParse(url);
    if (uri == null) return 'invalid';
    final host = uri.host.replaceAll('[', '').replaceAll(']', '');
    final addr = InternetAddress.tryParse(host);
    final where = host == 'localhost' || (addr?.isLoopback ?? false)
        ? 'loopback'
        : (addr != null && _isPrivate(addr) ? 'lan' : 'remote');
    return '${uri.scheme}@$where';
  }

  static bool _isPrivate(InternetAddress a) {
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254);
    }
    return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
  }

  @visibleForTesting
  void resetForTest() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _started = false;
    _effectiveProxyUrl = null;
    _lastConfig = const SystemProxyConfig();
    _androidRead = null;
    _androidChannelMissing = false;
  }
}
