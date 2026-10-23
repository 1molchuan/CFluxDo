import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inappwebview;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../../connectivity_service.dart';
import '../../preloaded_data_service.dart';
import '../doh_proxy/cert_preference_service.dart';
import '../doh_proxy/doh_proxy_ffi.dart';
import '../doh_proxy/doh_proxy_service.dart';
import '../doh_proxy/per_device_cert_service.dart';
import '../doh_proxy/proxy_certificate.dart';
import '../doh_proxy/windows_cert_trust_service.dart';
import '../proxy/gateway_upstream.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../windows_webview_environment_service.dart';
import 'accel_doh_auth_service.dart';
import 'accel_doh_nodes.dart';
import 'cfhub_api.dart';
import 'cfhub_probe_auth_service.dart';
import 'doh_resolver.dart';
import 'webview_mitm_policy.dart';
import '../doh_proxy/proxy_leaf_trust.dart';

/// 本地动态优选的模式（只在 Android 网关模式下生效）
enum CfSelectMode {
  /// 本地优选一等：atlas 路由表的候选也参与竞速，赢家直接用
  localAtlas('local_atlas'),

  /// 只用 atlas 下发的路由，不自己竞速
  atlasOnly('atlas_only');

  const CfSelectMode(this.wire);

  /// 传给 Rust / 存进 prefs 的字符串形式
  final String wire;

  /// 非法 / 空值回落到 [localAtlas]
  static CfSelectMode fromWire(String? value) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    return localAtlas;
  }
}

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    this.echServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.preferIPv6 = false,
    this.serverIp,
    this.gatewayEnabled = true,
    this.h2Mitm = false,
    this.selectMode = CfSelectMode.localAtlas,
    this.shareMeasurements = false,
  });

  final bool dohEnabled;

  /// DNS 解析服务器（A/AAAA 查询）
  final String selectedServerUrl;

  /// ECH 配置服务器（HTTPS 记录查询），null = 与 DNS 相同
  final String? echServerUrl;
  final List<DohServer> customServers;

  /// 代理端口（Rust 代理统一处理 DOH + ECH）
  final int? proxyPort;

  /// 优先使用 IPv6
  final bool preferIPv6;

  /// 全局 server IP（指定后跳过 DNS 解析直接连接）
  final String? serverIp;

  /// Gateway（反向代理）模式开关，关闭时回退为 MITM
  final bool gatewayEnabled;

  /// WebView MITM 是否启用 HTTP/2 多路复用（实验性，默认关闭；需实测 CF 指纹）
  final bool h2Mitm;

  /// 本地动态优选的模式
  final CfSelectMode selectMode;

  /// 「帮助优选」：把本地竞速的测量结果上报 cfhub（默认关，需 Connect 授权拿探针令牌）
  final bool shareMeasurements;

  NetworkSettings copyWith({
    bool? dohEnabled,
    String? selectedServerUrl,
    String? Function()? echServerUrl,
    List<DohServer>? customServers,
    int? Function()? proxyPort,
    bool? preferIPv6,
    String? Function()? serverIp,
    bool? gatewayEnabled,
    bool? h2Mitm,
    CfSelectMode? selectMode,
    bool? shareMeasurements,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      echServerUrl: echServerUrl != null ? echServerUrl() : this.echServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort != null ? proxyPort() : this.proxyPort,
      preferIPv6: preferIPv6 ?? this.preferIPv6,
      gatewayEnabled: gatewayEnabled ?? this.gatewayEnabled,
      serverIp: serverIp != null ? serverIp() : this.serverIp,
      h2Mitm: h2Mitm ?? this.h2Mitm,
      selectMode: selectMode ?? this.selectMode,
      shareMeasurements: shareMeasurements ?? this.shareMeasurements,
    );
  }
}

class DohServer {
  const DohServer({
    required this.name,
    required this.url,
    this.bootstrapIps = const [],
    this.isCustom = false,
  });

  final String name;
  final String url;

  /// Bootstrap IP 地址列表，用于直接连接 DOH 服务器（解决鸡蛋问题）
  /// Chrome 也是这样做的：预置 DOH 服务器的 IP，直接用 IP 连接
  final List<String> bootstrapIps;
  final bool isCustom;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    if (bootstrapIps.isNotEmpty) 'bootstrapIps': bootstrapIps,
  };

  static DohServer fromJson(Map<String, dynamic> json) {
    final ips = json['bootstrapIps'];
    return DohServer(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      bootstrapIps: ips is List ? ips.cast<String>() : const [],
      isCustom: true,
    );
  }
}

class ResolvedHostConfig {
  const ResolvedHostConfig({
    required this.dnsOverrides,
    this.preferredIp,
    this.echConfig,
  });

  const ResolvedHostConfig.empty()
    : dnsOverrides = const [],
      preferredIp = null,
      echConfig = null;

  final List<String> dnsOverrides;
  final String? preferredIp;
  final Uint8List? echConfig;
}

class _ResolvedHostEntry {
  _ResolvedHostEntry({
    required this.ips,
    required this.preferredIp,
    required this.echConfig,
    required this.ttl,
    required this.resolvedAt,
    this.pinned = false,
  }) : expiresAt = resolvedAt.add(ttl);

  final List<String> ips;
  final String? preferredIp;
  final Uint8List? echConfig;
  final Duration ttl;
  final DateTime resolvedAt;
  final DateTime expiresAt;

  /// Rust（EdgePin）把该域名钉在本地优选赢家上，[ips] 按原样用
  final bool pinned;

  bool get hasData => ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
  bool get isExpired => !expiresAt.isAfter(DateTime.now());

  Duration get remaining {
    final value = expiresAt.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  Duration get refreshLeadTime {
    final byRatio = Duration(milliseconds: (ttl.inMilliseconds / 5).round());
    if (byRatio < _minDnsRefreshLeadTime) {
      return _minDnsRefreshLeadTime;
    }
    if (byRatio > _maxDnsRefreshLeadTime) {
      return _maxDnsRefreshLeadTime;
    }
    return byRatio;
  }

  bool get shouldRefreshSoon => remaining <= refreshLeadTime;
}

const Duration _defaultDnsCacheTtl = Duration(minutes: 5);
const Duration _missDnsCacheTtl = Duration(minutes: 1);
const Duration _minDnsRefreshLeadTime = Duration(seconds: 30);
const Duration _maxDnsRefreshLeadTime = Duration(minutes: 2);
const Duration _failedHostIpPenaltyTtl = Duration(minutes: 2);

class NetworkSettingsService {
  NetworkSettingsService._internal() {
    _proxyService.notifier.addListener(_handleProxySettingsChanged);
    RhttpSettingsService.instance.notifier.addListener(
      _handleRhttpSettingsChanged,
    );
    WebViewAdapterSettingsService.instance.notifier.addListener(
      _handleWebViewAdapterSettingsChanged,
    );
    SystemProxyService.instance.version.addListener(_handleSystemProxyChanged);
  }

  static final NetworkSettingsService instance =
      NetworkSettingsService._internal();

  static const _dohEnabledKey = 'doh_enabled';
  static const _dohSelectedKey = 'doh_selected';
  static const _dohCustomKey = 'doh_custom';
  static const _proxyPortKey = 'doh_proxy_port';
  static const _preferIPv6Key = 'doh_prefer_ipv6';
  static const _serverIpKey = 'doh_server_ip';
  static const _echServerKey = 'doh_ech_server';
  static const _gatewayEnabledKey = 'doh_gateway_enabled';
  static const _h2MitmKey = 'doh_h2_mitm';
  static const _accelSubdomainKey = 'doh_accel_subdomain';

  /// 加速服务端下发的路由表（原始响应 JSON），启动时回传给 Rust 直接用
  static const _accelRoutesKey = 'doh_accel_routes';

  /// 加速节点列表的签名信封 `{"kid","payload","sig"}`，启动时回传给 Rust 重新验签
  static const _accelNodesKey = 'doh_accel_nodes';

  /// 本地动态优选的模式（[CfSelectMode.wire]）
  static const _selectModeKey = 'doh_select_mode';

  /// 「帮助优选」开关
  static const _selectShareKey = 'doh_select_share';

  /// Rust 的优选状态 JSON（赢家 + ECH 钥匙），启动时回灌给 Rust
  static const _selectStateKey = 'doh_select_state';

  /// 本地优选首次说明已弹过的版本（见 CfSelectNotice）
  static const selectNoticeVersionKey = 'doh_select_notice_version';

  /// atlas（CF 橙云入口）的路由表接口，只回源 hk2，表按线路选池
  static const _linuxDoHost = 'linux.do';
  static const _atlasHost = 'atlas.1molchuan.top';
  static const accelAtlasRoutesUrl = 'https://$_atlasHost/v1/routes';

  /// cfhub：众包 ECH 测速分池，探针上报与探针令牌都在这里
  static const cfhubHost = CfhubApi.host;
  static const cfhubReportUrl = 'https://$cfhubHost/api/v1/probe/report';

  /// 本地优选用来解析大厂域名的公共 DoH（国内可达的两家），带引导 IP 免鸡蛋问题
  static const _publicDohUrls = [
    'https://doh.pub/dns-query',
    'https://dns.alidns.com/dns-query',
  ];

  final ValueNotifier<NetworkSettings> notifier = ValueNotifier(
    NetworkSettings(
      dohEnabled: false,
      selectedServerUrl: _defaultServers.first.url,
      customServers: const [],
      proxyPort: null,
    ),
  );

  /// Rust 代理服务（处理 DOH + ECH）
  final DohProxyService _rustProxyService = DohProxyService.instance;
  final ProxySettingsService _proxyService = ProxySettingsService.instance;
  final ValueNotifier<DohDnsCacheStats> dnsCacheStatsNotifier = ValueNotifier(
    const DohDnsCacheStats.empty(),
  );

  late DohResolver _resolver;
  SharedPreferences? _prefs;

  /// cfluxdo 加速服务器，initialize 时按本机的随机子域名生成
  DohServer? _accelServer;
  int _version = 0;
  int _applyDepth = 0;
  Timer? _applyDebounce;
  bool _lastStartFailed = false;
  bool _wasRunningBeforeApply = false;
  bool _pendingStart = false;
  final Map<String, _ResolvedHostEntry> _resolvedHostCache = {};
  final Map<String, Future<_ResolvedHostEntry?>> _hostLookupInflight = {};
  final Set<String> _backgroundRefreshingHosts = <String>{};
  final Map<String, Map<String, DateTime>> _hostIpPenaltyCache = {};
  String? _resolvedHostCacheSignature;
  Timer? _accelPollTimer;
  String? _accelRouteSignature;

  /// 加速服务端下发、Rust 已验签的节点列表，给 Dart 侧建连当引导 IP 用
  final AccelNodeStore _nodeStore = AccelNodeStore();

  final ValueNotifier<bool> isApplying = ValueNotifier(false);

  /// 本地优选的最新状态（定时从 Rust 拉），没在跑时为 null
  final ValueNotifier<DohSelectStatus?> selectStatusNotifier = ValueNotifier(
    null,
  );

  /// 应用版本，启动时读一次，随优选探针带给 Rust
  String? _appVersion;

  int get version => _version;

  /// 本地优选当前有没有验证通过的赢家
  bool get selectorHasWinner => selectStatusNotifier.value?.hasWinner ?? false;
  DohResolver get resolver => _resolver;
  bool get lastStartFailed => _lastStartFailed;
  bool get wasRunningBeforeApply => _wasRunningBeforeApply;
  bool get pendingStart => _pendingStart;
  int get dnsCacheEntryCount => dnsCacheStatsNotifier.value.visibleHostEntries;

  /// 获取代理服务（优先使用 Rust 代理）
  DohProxyService get proxyService => _rustProxyService;

  NetworkSettings get current => notifier.value;

  /// 当前是否使用 gateway（反向代理）模式
  /// Gateway 模式：DOH 开启 + 用户开关开启 + 代理运行中
  bool get isGatewayMode =>
      current.dohEnabled &&
      current.gatewayEnabled &&
      _rustProxyService.isRunning;

  /// 本地动态优选只在 Android / Linux / Windows 网关模式下跑：DoH 开着、没有上游代理、网关开关开着
  /// （网关/上游的判断和 [_applyProxyState] 里启动代理时用的一致）
  bool get selectorEligible =>
      (Platform.isAndroid || Platform.isLinux || Platform.isWindows) &&
      current.dohEnabled &&
      !_proxyService.current.isValid &&
      WebViewMitmPolicy.useGatewayMode(
        isWindows: false,
        dohEnabled: current.dohEnabled,
        gatewayEnabled: current.gatewayEnabled,
        webViewAdapterEnabled: WebViewAdapterSettingsService.instance.enabled,
      );

  /// 交给 Rust 的公共 DoH 种子：`[{'url': ..., 'bootstrap_ips': [...]}]`
  List<Map<String, Object>> get _publicDohSeeds => [
    for (final server in _defaultServers)
      if (_publicDohUrls.contains(server.url))
        {
          'url': server.url,
          'bootstrap_ips': List<String>.of(server.bootstrapIps),
        },
  ];

  String? get _effectiveEchServerUrl =>
      current.dohEnabled ? (_activeEchServerUrl ?? _activeServerUrl) : null;

  /// 实际用来解析的 DNS 服务器（选中加速但没有令牌时是 DNSPod）
  String get _activeServerUrl => _activeDohUrl(current.selectedServerUrl);

  /// 实际用来查 ECH 的服务器，null = 与 DNS 相同
  String? get _activeEchServerUrl {
    final url = current.echServerUrl;
    return url == null ? null : _activeDohUrl(url);
  }

  /// 本机的 cfluxdo 加速服务器地址
  String? get accelServerUrl => _accelServer?.url;

  /// 选中了 cfluxdo 加速但没有专属令牌时，说明当前实际用的是哪个
  String? get accelFallbackHint {
    final accelUrl = _accelServer?.url;
    if (accelUrl == null || current.selectedServerUrl != accelUrl) {
      return null;
    }
    return switch (AccelDohAuthService.instance.status) {
      AccelDohAuthStatus.ready => null,
      AccelDohAuthStatus.notEligible => '登录且信任等级 ≥ 1 后可授权专属加速，当前使用公共加速',
      AccelDohAuthStatus.notAuthorized => '未授权 L 站 Connect，当前使用公共加速',
      AccelDohAuthStatus.unavailable => '此账号无法使用 Connect，当前使用公共加速',
      AccelDohAuthStatus.denied => '加速服务端拒绝了此账号，当前使用公共加速',
      AccelDohAuthStatus.displaced => '授权被收回（可能是设备超过 3 台），稍后自动重试，当前使用公共加速',
      AccelDohAuthStatus.pending => '等待 Connect 授权，当前使用公共加速',
    };
  }

  /// 选中加速时按账号分档：有令牌走专属加速，没令牌（登录佬友、游客/TL0）一律走公共加速。
  /// 游客不能落到 DNSPod：国内公共 DoH 对 linux.do 的应答已被污染（解析到 Twitter/Facebook
  /// 段 IP，TLS 握手挂死），未登录就连不上，也就永远登不进去拿不到加速。
  String _activeDohUrl(String url) {
    if (url != _accelServer?.url) return url;
    if (AccelDohAuthService.instance.token != null) return url;
    return accelDohPublicServer.url;
  }

  /// 测速时测实际会用的那个服务器（加速按当前档位，带上令牌）
  ({String url, List<String> bootstrapIps, String? authToken})
  latencyTestTarget(DohServer server) {
    final url = _activeDohUrl(server.url);
    if (url == server.url) {
      return (
        url: url,
        bootstrapIps: _mergeAccelNodes(url, server.bootstrapIps),
        authToken: _authTokenFor(url),
      );
    }
    return (url: url, bootstrapIps: _getBootstrapIps(url), authToken: null);
  }

  /// 只有加速服务器才带令牌，其他 DoH 一律不带
  String? _authTokenFor(String? url) => url != null && url == _accelServer?.url
      ? AccelDohAuthService.instance.token
      : null;

  /// 按实际使用的服务器和令牌更新 Dart 侧解析器
  void _updateResolverServer() {
    _accelRouteSignature = _currentAccelRouteSignature;
    final url = _activeServerUrl;
    _resolver.updateServer(
      url,
      bootstrapIps: _getBootstrapIps(url),
      authToken: _authTokenFor(url),
    );
  }

  // Rust 代理始终为 WebView 提供 DOH/代理支持，不受 rhttp 影响
  // rhttp 只改变 Dio 用哪个适配器，不改变代理生命周期
  bool get shouldRunLocalProxy =>
      current.dohEnabled || _proxyService.current.isValid;

  List<DohServer> get servers => [
    ..._builtInServers,
    ...notifier.value.customServers,
  ];

  /// 内置服务器：cfluxdo 加速排第一，作为默认服务器
  List<DohServer> get _builtInServers => [
    ?_accelServer,
    ..._defaultServers,
  ];

  String get _defaultServerUrl => _builtInServers.first.url;

  /// 是否已初始化（读过偏好、起过代理）
  bool get isInitialized => _prefs != null;

  /// 初始化之前读「DoH 开关」偏好：VPN 自动切换要在起代理前决定是否压制
  static bool storedDohEnabled(SharedPreferences prefs) =>
      prefs.getBool(_dohEnabledKey) ?? true;

  /// 初始化之前写「DoH 开关」偏好（初始化时按它起不起代理）
  static Future<void> storeDohEnabled(SharedPreferences prefs, bool enabled) =>
      prefs.setBool(_dohEnabledKey, enabled);

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    _accelServer = buildAccelDohServer(await _loadAccelSubdomain(prefs));
    // 上次下发的节点列表先预热，后面的引导 IP 都带上它（信封会原样交给 Rust 重新验签）
    if (_nodeStore.loadEnvelopeJson(prefs.getString(_accelNodesKey))) {
      debugPrint('[DOH] 已载入加速节点列表 serial=${_nodeStore.serial}');
    }
    AccelDohAuthService.instance.initialize(
      prefs,
      serverUrl: _accelServer!.url,
      bootstrapIps: _getBootstrapIps(_accelServer!.url),
    );
    // 探针令牌要在起代理前读回来，start() 才能带上
    CfhubProbeAuthService.instance.initialize(prefs);
    final dohEnabled = prefs.getBool(_dohEnabledKey) ?? true;
    final selectMode = CfSelectMode.fromWire(prefs.getString(_selectModeKey));
    final shareMeasurements = prefs.getBool(_selectShareKey) ?? false;
    final selected = prefs.getString(_dohSelectedKey) ?? _defaultServerUrl;
    final customRaw = prefs.getString(_dohCustomKey);
    final custom = _decodeServers(customRaw);
    final proxyPort = prefs.getInt(_proxyPortKey);
    await prefs.remove('doh_multi_ip');
    final preferIPv6 = prefs.getBool(_preferIPv6Key) ?? false;
    final serverIp = prefs.getString(_serverIpKey);
    final echServer = prefs.getString(_echServerKey);
    final gatewayEnabled = prefs.getBool(_gatewayEnabledKey) ?? true;
    final h2Mitm = prefs.getBool(_h2MitmKey) ?? false;
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      echServerUrl: echServer,
      customServers: custom,
      proxyPort: proxyPort,
      preferIPv6: preferIPv6,
      serverIp: serverIp,
      gatewayEnabled: gatewayEnabled,
      h2Mitm: h2Mitm,
      selectMode: selectMode,
      shareMeasurements: shareMeasurements,
    );
    final activeUrl = _activeServerUrl;
    _resolver = DohResolver(
      serverUrl: activeUrl,
      bootstrapIps: _getBootstrapIps(activeUrl),
      preferIPv6: preferIPv6,
      authToken: _authTokenFor(activeUrl),
      onAuthRejected: _handleAccelAuthRejected,
      // 有 Rust 库的平台统一走 Rust 的 DoH 客户端，Dart 侧不再自己握手
      nativeLookup: DohProxyFfi.isAvailable ? _lookupIpViaRust : null,
    );
    _accelRouteSignature = _currentAccelRouteSignature;
    AccelDohAuthService.instance.addListener(_handleAccelAuthChanged);
    _appVersion = await _loadAppVersion();
    // 换网（Wi-Fi ↔ 蜂窝）时让 Rust 重新核验优选赢家
    ConnectivityService().networkSignature.addListener(
      _handleNetworkSignatureChanged,
    );
    await _applyProxyState(startup: true);
    _touch();
  }

  Future<void> setDohEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _beginApply(enabled: enabled || _proxyService.current.isValid);
    notifier.value = notifier.value.copyWith(dohEnabled: enabled);
    if (!enabled) {
      _clearResolvedHostCache();
    }
    if (!enabled && _lastStartFailed) {
      _setStartFailed(false);
    }
    await prefs.setBool(_dohEnabledKey, enabled);
    await _applyProxyState();
    _touch();
  }

  Future<void> setSelectedServer(String url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(selectedServerUrl: url);
    _updateResolverServer();
    if (current.dohEnabled) {
      _clearResolvedHostCache();
    }
    await prefs.setString(_dohSelectedKey, url);
    _scheduleApplyProxyState();
    _touch(); // 在代理状态更新完成后触发
  }

  Future<void> addCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = [...notifier.value.customServers, server];
    notifier.value = notifier.value.copyWith(customServers: updated);
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> updateCustomServer(
    DohServer oldServer,
    DohServer newServer,
  ) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .map((s) => s.url == oldServer.url ? newServer : s)
        .toList();
    final selectedUrl = notifier.value.selectedServerUrl;
    final newSelected = selectedUrl == oldServer.url
        ? newServer.url
        : selectedUrl;
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: newSelected,
    );
    if (newSelected != selectedUrl) {
      _updateResolverServer();
      _clearResolvedHostCache();
      _scheduleApplyProxyState();
    }
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    if (newSelected != selectedUrl) {
      await prefs.setString(_dohSelectedKey, newSelected);
    }
    _touch();
  }

  Future<void> removeCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .where((s) => s.url != server.url)
        .toList();
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      updated,
    );
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: resolvedSelected,
    );
    _updateResolverServer();
    _clearResolvedHostCache();
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> resetDefaultServers() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      const [],
    );
    notifier.value = notifier.value.copyWith(
      customServers: const [],
      selectedServerUrl: resolvedSelected,
    );
    _updateResolverServer();
    _clearResolvedHostCache();
    await prefs.setString(_dohCustomKey, jsonEncode([]));
    _touch();
  }

  Future<void> setPreferIPv6(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(preferIPv6: enabled);
    _resolver.preferIPv6 = enabled;
    _clearResolvedHostCache();
    await prefs.setBool(_preferIPv6Key, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setServerIp(String? ip) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = ip?.trim();
    final value = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    notifier.value = notifier.value.copyWith(serverIp: () => value);
    _clearResolvedHostCache();
    if (value != null) {
      await prefs.setString(_serverIpKey, value);
    } else {
      await prefs.remove(_serverIpKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setEchServer(String? url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(echServerUrl: () => url);
    _clearResolvedHostCache();
    if (url != null) {
      await prefs.setString(_echServerKey, url);
    } else {
      await prefs.remove(_echServerKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setGatewayEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(gatewayEnabled: enabled);
    await prefs.setBool(_gatewayEnabledKey, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 切换 WebView h2 MITM（实验性）。切换后重启代理生效，需实测 CF 指纹。
  Future<void> setH2Mitm(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(h2Mitm: enabled);
    await prefs.setBool(_h2MitmKey, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 切换本地优选模式；网关要按新模式重启
  Future<void> setSelectMode(CfSelectMode mode) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (current.selectMode == mode) return;
    notifier.value = notifier.value.copyWith(selectMode: mode);
    await prefs.setString(_selectModeKey, mode.wire);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 开关「帮助优选」（把本地竞速的测量结果上报 cfhub）；Rust 侧热更新，不重启网关
  ///
  /// [bearer] 是 cfhub 的探针令牌，没给时取 [CfhubProbeAuthService] 当前的；
  /// 没有令牌时 Rust 侧一律不上报，开关只是记住用户意愿
  Future<void> setShareMeasurements(bool on, {String? bearer}) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(shareMeasurements: on);
    await prefs.setBool(_selectShareKey, on);
    final token = on ? (bearer ?? CfhubProbeAuthService.instance.token) : null;
    try {
      await _rustProxyService.setShareMeasurements(on && token != null, token);
    } catch (e) {
      debugPrint('[DOH] 更新探针上报开关失败: $e');
    }
    _touch();
  }

  /// 立刻重新竞速一次（设置页「重新优选」）
  Future<bool> reraceSelection() async {
    if (!_rustProxyService.isRunning) return false;
    try {
      final ok = await _rustProxyService.reraceSelection();
      unawaited(refreshSelectStatus());
      return ok;
    } catch (e) {
      debugPrint('[DOH] 触发重新优选失败: $e');
      return false;
    }
  }

  /// 问 Rust 要一次本地优选状态并发布到 [selectStatusNotifier]
  Future<DohSelectStatus?> refreshSelectStatus() async {
    DohSelectStatus? status;
    if (_rustProxyService.isRunning) {
      try {
        status = await _rustProxyService.selectStatus();
      } catch (e) {
        debugPrint('[DOH] 读取本地优选状态失败: $e');
      }
    }
    final previousWinner = selectStatusNotifier.value?.winnerIp;
    selectStatusNotifier.value = status;
    // 优选赢家换了：钉在旧赢家上的条目作废，rhttp 下一个请求就跟上新赢家
    if (status?.winnerIp != previousWinner) {
      _dropPinnedHostEntries();
    }
    return status;
  }

  /// 网络环境变了（换 Wi-Fi / 蜂窝）：告诉 Rust 重新核验赢家
  void _handleNetworkSignatureChanged() {
    if (_prefs == null) return;
    final sig = ConnectivityService().networkSignature.value;
    if (sig == null || sig.isEmpty) return;
    unawaited(
      _rustProxyService.networkChanged(sig).catchError((Object e) {
        debugPrint('[DOH] 通知网络变化失败: $e');
      }),
    );
  }

  /// 应用版本只在启动时读一次，随优选探针一起带给 Rust（上报时标明客户端版本）
  Future<String?> _loadAppVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (e) {
      debugPrint('[DOH] 读取应用版本失败: $e');
      return null;
    }
  }

  /// [startup] 为冷启动：没有界面在等 Loading，跳过给 UI 留的一帧和最短 400 ms，
  /// DNS 缓存统计也不等（冷启动这里排在首个请求之前）
  Future<void> _applyProxyState({bool startup = false}) async {
    final startedAt = DateTime.now();
    _syncAccelPolling();
    _applyDepth++;
    if (_applyDepth == 1) {
      if (!isApplying.value) {
        _wasRunningBeforeApply = _rustProxyService.isRunning;
        isApplying.value = true;
      }
      // 给 UI 一帧时间渲染 Loading
      if (!startup) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    if (!shouldRunLocalProxy) {
      try {
        await _stopLocalProxyUnlessRequiredByWebView();
        if (_pendingStart) {
          _setPendingStart(false);
        }
        await _clearProxyPort();
        if (_lastStartFailed) {
          _setStartFailed(false);
        }
      } finally {
        _applyDepth--;
        if (_applyDepth == 0) {
          final elapsed = DateTime.now().difference(startedAt);
          const minDuration = Duration(milliseconds: 400);
          if (!startup && elapsed < minDuration) {
            await Future<void>.delayed(minDuration - elapsed);
          }
          isApplying.value = false;
          if (startup) {
            unawaited(refreshDnsCacheStats());
          } else {
            await refreshDnsCacheStats();
          }
        }
      }
      return;
    }

    try {
      final webViewAdapterEnabled =
          WebViewAdapterSettingsService.instance.enabled;
      final requiresWindowsCa = WebViewMitmPolicy.requiresTrustedCa(
        isWindows: Platform.isWindows,
        dohEnabled: current.dohEnabled,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );
      // 历史配置可能绕过 UI 留下「WebView + DoH 但 CA 未安装」状态。
      // 不再静默篡改 DoH 偏好；只阻止 MITM 启动，避免证书失败重试风暴。
      if (requiresWindowsCa &&
          !await WindowsCertTrustService.instance.isInstalled()) {
        debugPrint('[DOH] Windows WebView MITM 缺少受信任 CA，跳过代理启动');
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        return;
      }

      final upstream = GatewayUpstream.resolve(
        applicationProxy: _proxyService.current,
        systemProxyUrl: Platform.isWindows
            ? SystemProxyService.instance.effectiveProxyUrl
            : null,
      );
      final effectiveEchServer = _effectiveEchServerUrl;
      final mitmConnect = WebViewMitmPolicy.useMitmConnect(
        isWindows: Platform.isWindows,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );

      // ECH 场景：rhttp 按请求 host 查询 ECH；gateway 模式仅作为 WebView 后备。
      // Windows 高性能模式不使用 CA，公开 doh_proxy 的非 gateway CONNECT
      // 路径无法表达 mitm_connect=false；此时复用 gateway 的纯隧道分支，
      // 保持端到端 TLS，同时不改变 WebView MITM 模式的既有开关语义。
      final shouldTryEch = effectiveEchServer != null;
      final useGateway = WebViewMitmPolicy.useGatewayMode(
        isWindows: Platform.isWindows,
        dohEnabled: current.dohEnabled,
        gatewayEnabled: current.gatewayEnabled,
        webViewAdapterEnabled: webViewAdapterEnabled,
      );

      if (!shouldTryEch) {
        _clearResolvedHostCache();
      }

      // macOS: 启动前确保 CA 在钥匙串中被信任
      if (Platform.isMacOS && current.dohEnabled) {
        final trusted = await ProxyCertificate.ensureKeychainTrust();
        if (!trusted) {
          debugPrint('[DOH] macOS: CA 未被钥匙串信任，无法启动代理');
          _setStartFailed(true);
          _setPendingStart(false);
          return;
        }
      }

      // per-device CA: 读取证书传给代理（iOS/macOS 强制，其他平台可选）
      String? caCertPem;
      String? caKeyPem;
      if (mitmConnect && await CertPreferenceService.usePerDevice()) {
        final certService = PerDeviceCertService.instance;
        if (certService.isLoaded || await certService.ensureCaCert()) {
          caCertPem = certService.certPem;
          caKeyPem = certService.keyPem;
        }
      }

      // 加速服务器没有令牌时这里已经换成公共加速或 DNSPod，令牌只随加速服务器下发
      final dohServer = _activeServerUrl;
      final dohServerEch = _activeEchServerUrl;
      // 加速服务器才有路由表接口；上次存下的表和节点列表作为启动种子回传给 Rust
      final dohRoutesUrl = current.dohEnabled
          ? accelRoutesUrlFor(dohServer)
          : null;
      final prefsForSeed = _prefs;
      final dohRouteTableJson = dohRoutesUrl != null
          ? prefsForSeed?.getString(_accelRoutesKey)
          : null;
      final dohNodeListJson = current.dohEnabled
          ? prefsForSeed?.getString(_accelNodesKey)
          : null;

      // Rust 代理始终为 WebView 提供 DOH/代理支持，enableDoh 不受 rhttp 影响
      final success = await _rustProxyService.start(
        preferredPort:
            WindowsWebViewEnvironmentService.instance.activeLocalProxyPort ??
            _activeProxyPort ??
            current.proxyPort ??
            0,
        enableDoh: current.dohEnabled,
        gatewayMode: useGateway,
        preferIPv6: current.preferIPv6,
        dohServer: current.dohEnabled ? dohServer : null,
        dohServerEch: current.dohEnabled ? dohServerEch : null,
        dohBootstrapIps: current.dohEnabled
            ? _getBootstrapIps(dohServer)
            : const [],
        dohEchBootstrapIps: current.dohEnabled && dohServerEch != null
            ? _getBootstrapIps(dohServerEch)
            : const [],
        dohAuthToken: current.dohEnabled ? _authTokenFor(dohServer) : null,
        dohEchAuthToken: current.dohEnabled
            ? _authTokenFor(dohServerEch)
            : null,
        serverIp: current.serverIp,
        upstreamProtocol: upstream?.protocol,
        upstreamHost: upstream?.host,
        upstreamPort: upstream?.port,
        upstreamUsername: upstream?.username,
        upstreamPassword: upstream?.password,
        upstreamCipher: upstream?.cipher,
        caCertPem: caCertPem,
        caKeyPem: caKeyPem,
        mitmConnect: mitmConnect,
        h2Mitm: current.h2Mitm,
        dohRoutesUrl: dohRoutesUrl,
        dohRouteTableJson: dohRouteTableJson,
        dohNodeListJson: dohNodeListJson,
        // 本地动态优选：只在 Android / Linux / Windows 网关模式下开；上次的赢家状态回灌给 Rust
        selectMode: selectorEligible ? current.selectMode.wire : 'off',
        selectStateJson: prefsForSeed?.getString(_selectStateKey),
        shareMeasurements:
            current.shareMeasurements &&
            CfhubProbeAuthService.instance.token != null,
        atlasRoutesUrl: accelAtlasRoutesUrl,
        publicDoh: _publicDohSeeds,
        reportUrl: cfhubReportUrl,
        reportBearer: CfhubProbeAuthService.instance.token,
        extraCoveredHosts: const [_atlasHost, cfhubHost],
        appVersion: _appVersion,
        networkSig: ConnectivityService().networkSignature.value,
        // 优选出结果后先预建一条到 linux.do 的上游连接，首个请求不用再等握手
        preconnectHosts: const [_linuxDoHost],
      );

      if (!success) {
        debugPrint('[DOH] Failed to start Rust proxy，改为直连');
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        // 代理没起来时清掉端口，Dio 不再指向 127.0.0.1，改用系统网络直连，
        // 避免所有请求打到不存在的本地端口导致 App 无法使用
        await _clearProxyPort();
        return;
      }

      // start 耗时较长(读证书/绑端口),期间设置可能已被改为无需本地代理
      // (如 VPN 自动压制关闭了 DoH 与上游代理)。此时并发的 stop 分支先于
      // start 完成,会留下"开关已关、代理仍在跑"的孤儿网关,这里必须复查。
      if (!shouldRunLocalProxy) {
        debugPrint('[DOH] 启动期间设置已变更为无需本地代理,重新核对 WebView 路由');
        await _stopLocalProxyUnlessRequiredByWebView();
        _setPendingStart(false);
        return;
      }

      if (_lastStartFailed) {
        _setStartFailed(false);
      }
      if (_pendingStart) {
        _setPendingStart(false);
      }

      // 获取实际使用的端口（Rust 代理）
      final activePort = _rustProxyService.port;
      if (current.proxyPort != activePort) {
        final prefs = _prefs;
        if (prefs != null && activePort != null) {
          await prefs.setInt(_proxyPortKey, activePort);
          notifier.value = notifier.value.copyWith(proxyPort: () => activePort);
          _touch(); // 触发 HttpClient 重建
        }
      }

      await _applyWebViewProxy();
    } finally {
      _applyDepth--;
      if (_applyDepth == 0) {
        final elapsed = DateTime.now().difference(startedAt);
        const minDuration = Duration(milliseconds: 400);
        if (!startup && elapsed < minDuration) {
          await Future<void>.delayed(minDuration - elapsed);
        }
        isApplying.value = false;
        if (startup) {
          unawaited(refreshDnsCacheStats());
        } else {
          await refreshDnsCacheStats();
        }
        unawaited(refreshSelectStatus());
        _touch();
      }
    }
  }

  /// 清掉本地代理端口，HTTP 客户端随之改为直连
  Future<void> _clearProxyPort() async {
    if (current.proxyPort == null) return;
    notifier.value = notifier.value.copyWith(proxyPort: () => null);
    await _prefs?.remove(_proxyPortKey);
    _touch();
  }

  void _setStartFailed(bool value) {
    if (_lastStartFailed == value) return;
    _lastStartFailed = value;
    _touch();
  }

  void _setPendingStart(bool value) {
    if (_pendingStart == value) return;
    _pendingStart = value;
    _touch();
  }

  Future<void> restartProxy() async {
    _beginApply(enabled: shouldRunLocalProxy);
    await _applyProxyState();
    _touch();
  }

  /// 检查代理是否仍然存活，若已意外停止则自动重启
  ///
  /// 用于 App 从后台恢复时调用：iOS 挂起进程后 Rust 代理的 TCP listener
  /// 可能失效，需要检测并重启。
  Future<void> ensureProxyAlive() async {
    // 回到前台顺带检查加速令牌：过期就降到公共加速，快到期就续期
    AccelDohAuthService.instance.checkNow();
    unawaited(_checkAuthRejected());
    unawaited(_checkAccelUpdate());
    if (!shouldRunLocalProxy) return;
    if (!_rustProxyService.isRunning) {
      // 上次启动失败、当前处于直连状态：回到前台时再试一次
      if (_lastStartFailed && !isApplying.value) {
        debugPrint('[DOH] 上次代理启动失败，重新尝试');
        await restartProxy();
      }
      return;
    }
    final alive = await _rustProxyService.checkAlive();
    if (!alive) {
      debugPrint('[DOH] 代理已失效，自动重启');
      await restartProxy();
    }
  }

  void _scheduleApplyProxyState() {
    _beginApply(enabled: shouldRunLocalProxy);
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 350), () async {
      await _applyProxyState();
      _touch();
    });
  }

  void _beginApply({required bool enabled}) {
    _wasRunningBeforeApply = _rustProxyService.isRunning;
    if (enabled) {
      _setPendingStart(true);
    }
    if (!isApplying.value) {
      isApplying.value = true;
    }
  }

  /// 获取当前活动的代理端口
  int? get _activeProxyPort => _rustProxyService.port;

  bool _webViewProxySet = false;

  Future<void> _stopLocalProxyUnlessRequiredByWebView() async {
    var retainForWindowsWebView = false;
    if (Platform.isWindows) {
      final runningPort = _rustProxyService.port;
      final clearApplied = await _clearWebViewProxy();
      retainForWindowsWebView =
          WindowsWebViewEnvironmentService.shouldRetainLocalProxy(
            clearApplied: clearApplied,
            activeEnvironmentPort:
                WindowsWebViewEnvironmentService.instance.activeLocalProxyPort,
            runningProxyPort: runningPort,
          );
    } else {
      await _clearWebViewProxy();
    }

    if (retainForWindowsWebView) {
      debugPrint('[DOH] WebView2 当前仍使用本地代理，保留端口直到应用重启');
      return;
    }
    await _rustProxyService.stop();
  }

  Future<void> _applyWebViewProxy() async {
    if (!shouldRunLocalProxy) return;
    final port = _activeProxyPort;
    if (port == null) return;

    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy('http://127.0.0.1:$port');
        _webViewProxySet = true;
        debugPrint(
          applied
              ? '[DOH] WebView2 代理已设置 -> 127.0.0.1:$port'
              : '[DOH] WebView2 代理已登记，重启应用后生效 -> '
                    '127.0.0.1:$port',
        );
      } catch (e) {
        debugPrint('[DOH] WebView2 代理设置失败: $e');
      }
      return;
    }

    // macOS 14 以下 / iOS 17 以下调用 setProxyOverride 可能报错
    if (!Platform.isAndroid &&
        !Platform.isLinux &&
        !await _isMacOS14OrAbove() &&
        !await _isiOS17OrAbove()) {
      return;
    }

    try {
      await inappwebview.ProxyController.instance().setProxyOverride(
        settings: inappwebview.ProxySettings(
          proxyRules: [inappwebview.ProxyRule(url: 'http://127.0.0.1:$port')],
        ),
      );
      _webViewProxySet = true;
      debugPrint('[DOH] WebView 代理已设置 -> 127.0.0.1:$port');
      // Linux：代理每次启动叶子证书都会换，设代理的同时重新放行
      await ProxyLeafTrust.preallowProxyLeaves();
    } catch (e) {
      debugPrint('[DOH] WebView 代理设置失败: $e');
    }
  }

  Future<bool> _clearWebViewProxy() async {
    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy(null);
        _webViewProxySet = false;
        debugPrint(
          applied ? '[DOH] WebView2 代理已清除' : '[DOH] WebView2 代理清除已登记，重启应用后生效',
        );
        return applied;
      } catch (e) {
        debugPrint('[DOH] WebView2 代理清除失败: $e');
        return false;
      }
    }

    if (!_webViewProxySet) return true;

    if (!Platform.isAndroid &&
        !Platform.isLinux &&
        !await _isMacOS14OrAbove() &&
        !await _isiOS17OrAbove()) {
      return true;
    }
    try {
      await inappwebview.ProxyController.instance().clearProxyOverride();
      _webViewProxySet = false;
      debugPrint('[DOH] WebView 代理已清除');
      return true;
    } catch (e) {
      debugPrint('[DOH] WebView 代理清除失败: $e');
      return false;
    }
  }

  static bool? _isMacOS14OrAboveCache;

  Future<bool> _isMacOS14OrAbove() async {
    if (!Platform.isMacOS) return false;
    if (_isMacOS14OrAboveCache != null) return _isMacOS14OrAboveCache!;
    final info = await DeviceInfoPlugin().macOsInfo;
    // 修复：majorVersion 对应 macOS 大版本，如 macOS 14 (Sonoma) => majorVersion == 14 ≠ Darwin 23
    _isMacOS14OrAboveCache = info.majorVersion >= 14;
    return _isMacOS14OrAboveCache!;
  }

  static bool? _isiOS17OrAboveCache;

  Future<bool> _isiOS17OrAbove() async {
    if (!Platform.isIOS) return false;
    if (_isiOS17OrAboveCache != null) return _isiOS17OrAboveCache!;
    final info = await DeviceInfoPlugin().iosInfo;
    final major = int.tryParse(info.systemVersion.split('.').first) ?? 0;
    _isiOS17OrAboveCache = major >= 17;
    return _isiOS17OrAboveCache!;
  }

  void _touch() {
    _version++;
    // 通过重新赋值触发监听器更新
    notifier.value = notifier.value.copyWith();
  }

  void _handleProxySettingsChanged() {
    if (_prefs == null) return;
    _clearResolvedHostCache();
    _scheduleApplyProxyState();
    _touch();
  }

  /// 实际使用的服务器和令牌，变了才需要重启代理
  String get _currentAccelRouteSignature {
    final dns = _activeServerUrl;
    final ech = _activeEchServerUrl;
    return '$dns|${_authTokenFor(dns) ?? ""}|${ech ?? ""}|${_authTokenFor(ech) ?? ""}';
  }

  /// 加速档位变了（拿到/续期/作废/过期令牌、登录状态变化）：切换实际使用的服务器并按需重启代理
  void _handleAccelAuthChanged() {
    if (_prefs == null) return;
    final signature = _currentAccelRouteSignature;
    if (signature != _accelRouteSignature) {
      _updateResolverServer();
      if (current.dohEnabled) {
        debugPrint('[DOH] 加速档位变化，当前使用 $_activeServerUrl');
        // 服务器地址变了时，下次解析会按签名自动清掉旧缓存
        _scheduleApplyProxyState();
      }
      _touch();
      return;
    }
    // 只是提示文字变了（回前台时的令牌检查都会走到这里）：只刷新设置页，不动版本号——
    // 版本号一变 Dart 侧会重建 HTTP 客户端、丢掉所有连接
    notifier.value = notifier.value.copyWith();
  }

  /// 正在用加速服务器（专属或公共）时，定时问 Rust 代理：令牌有没有被拒、有没有新拉到路由表 / 节点列表
  void _syncAccelPolling() {
    final needPoll =
        (current.dohEnabled &&
            (accelRoutesUrlFor(_activeServerUrl) != null ||
                _authTokenFor(_activeEchServerUrl) != null)) ||
        selectorEligible;
    if (!needPoll) {
      _accelPollTimer?.cancel();
      _accelPollTimer = null;
      return;
    }
    _accelPollTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_checkAuthRejected());
      unawaited(_checkAccelUpdate());
      unawaited(refreshSelectStatus());
    });
  }

  Future<void> _checkAuthRejected() async {
    if (!_rustProxyService.isRunning) return;
    try {
      if (await _rustProxyService.takeAuthRejected()) {
        _handleAccelAuthRejected();
      }
    } catch (e) {
      debugPrint('[DOH] 读取令牌被拒标记失败: $e');
    }
  }

  /// 取走 Rust 新拉到的路由表 / 节点列表并持久化；节点变了只刷新 Dart 侧引导 IP，不重启代理
  Future<void> _checkAccelUpdate() async {
    final prefs = _prefs;
    if (prefs == null || !_rustProxyService.isRunning) return;
    final DohAccelUpdate? update;
    try {
      update = await _rustProxyService.takeAccelUpdate();
    } catch (e) {
      debugPrint('[DOH] 读取加速更新失败: $e');
      return;
    }
    if (update == null) return;

    final routeTable = update.routeTable;
    if (routeTable != null && routeTable.isNotEmpty) {
      await prefs.setString(_accelRoutesKey, routeTable);
      debugPrint('[DOH] 加速路由表已更新 (${routeTable.length} bytes)');
    }

    final envelope = update.nodesEnvelopeJson;
    if (envelope != null && envelope.isNotEmpty) {
      await prefs.setString(_accelNodesKey, envelope);
    }
    final nodes = update.nodes;
    if (nodes != null && nodes.isNotEmpty && _nodeStore.loadPayloadJson(nodes)) {
      debugPrint(
        '[DOH] 加速节点列表已更新 serial=${_nodeStore.serial} '
        'hosts=${_nodeStore.hosts.join(", ")}',
      );
      _updateResolverServer();
    }

    // 本地优选的赢家 / ECH 钥匙变了：落盘，下次启动回灌给 Rust
    final selectState = update.selectState;
    if (selectState != null && selectState.isNotEmpty) {
      await prefs.setString(_selectStateKey, selectState);
    }
    // 探针上报被 cfhub 拒绝：令牌已失效，关掉「帮助优选」并提示用户
    if (update.reportAuthRejected) {
      unawaited(CfhubProbeAuthService.instance.onRejected());
    }
  }

  void _handleAccelAuthRejected() {
    unawaited(AccelDohAuthService.instance.handleRejected());
  }

  void _handleWebViewAdapterSettingsChanged() {
    if (_prefs == null || !shouldRunLocalProxy) return;
    _scheduleApplyProxyState();
    _touch();
  }

  void _handleSystemProxyChanged() {
    if (_prefs == null || !Platform.isWindows) return;
    // 应用内代理拥有更高优先级；只有走系统代理回退时才需要重启网关。
    if (_proxyService.current.isValid || !shouldRunLocalProxy) return;
    _scheduleApplyProxyState();
  }

  Future<ResolvedHostConfig> resolveHostForRequest(
    String host, {
    bool forceRefresh = false,
  }) async {
    final normalizedHost = _normalizeHost(host);
    if (normalizedHost == null) {
      return const ResolvedHostConfig.empty();
    }

    final serverIpOverride = _parseServerIpOverride();
    if (!current.dohEnabled) {
      _clearResolvedHostCache();
      return ResolvedHostConfig(
        dnsOverrides: serverIpOverride != null
            ? <String>[serverIpOverride]
            : const [],
        preferredIp: serverIpOverride,
      );
    }

    final entry = await _resolveHostEntry(
      normalizedHost,
      forceRefresh: forceRefresh,
    );
    // 钉在优选赢家上的域名原样用 Rust 给的地址（赢家在前、只有同族兜底），不叠加本地的
    // 失败惩罚和粘性挑选：linux.do 各子域换 IP / 换地址族会让 cf_clearance 对不上出口
    if (entry != null && entry.pinned && serverIpOverride == null) {
      return ResolvedHostConfig(
        dnsOverrides: entry.ips,
        preferredIp: entry.preferredIp,
        echConfig: entry.echConfig,
      );
    }
    final orderedIps = _applyHostIpPenalties(
      normalizedHost,
      entry?.ips ?? const [],
      preferredIp: entry?.preferredIp,
    );
    final stickyIp = _selectUsablePreferredIp(
      normalizedHost,
      entry?.preferredIp,
      orderedIps,
    );
    return ResolvedHostConfig(
      dnsOverrides: serverIpOverride != null
          ? <String>[serverIpOverride]
          : stickyIp != null
          ? <String>[stickyIp]
          : orderedIps,
      preferredIp: serverIpOverride ?? stickyIp,
      echConfig: entry?.echConfig,
    );
  }

  void reportHostConnectionFailure(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    if (_resolvedHostCache[normalizedHost]?.pinned ?? false) {
      // 钉住的域名不在本地记惩罚：失败报给 Rust 计入赢家连败（达阈值 Rust 解除钉住、重新优选），
      // 并丢掉所有钉住的条目，下一个请求重新问 Rust，覆盖域名一起换
      _dropPinnedHostEntries();
    } else {
      _evictExpiredHostIpPenalties();
      final penalties = _hostIpPenaltyCache.putIfAbsent(
        normalizedHost,
        () => <String, DateTime>{},
      );
      penalties[normalizedIp] = DateTime.now().add(_failedHostIpPenaltyTtl);
    }
    if (current.dohEnabled) {
      final dohServer = _activeServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? _activeServerUrl;
      unawaited(
        _rustProxyService.reportHostFailure(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
          ip: normalizedIp,
        ),
      );
    }
  }

  /// 丢掉钉在优选赢家上的缓存条目：赢家连不上或换了时，下一个请求重新问 Rust
  void _dropPinnedHostEntries() {
    final before = _resolvedHostCache.length;
    _resolvedHostCache.removeWhere((_, entry) => entry.pinned);
    if (_resolvedHostCache.length != before) {
      _updateLocalDnsCacheStats();
    }
  }

  void reportHostConnectionSuccess(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    final penalties = _hostIpPenaltyCache[normalizedHost];
    if (penalties == null) {
      return;
    }
    penalties.remove(normalizedIp);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(normalizedHost);
    }

    if (current.dohEnabled) {
      final dohServer = _activeServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? _activeServerUrl;
      unawaited(
        _rustProxyService.recordHostSuccess(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
          ip: normalizedIp,
        ),
      );
    }
  }

  Future<List<String>> getDnsOverridesForHost(String host) async {
    return (await resolveHostForRequest(host)).dnsOverrides;
  }

  Future<Uint8List?> getEchConfigForHost(String host) async {
    return (await resolveHostForRequest(host)).echConfig;
  }

  Future<void> refreshDnsCacheStats() async {
    var stats = const DohDnsCacheStats.empty();
    try {
      stats = await _rustProxyService.dnsCacheStats() ?? stats;
    } catch (e) {
      debugPrint('[DOH] DNS cache stats refresh failed: $e');
    }
    _setDnsCacheStats(stats);
  }

  Future<List<DohDnsCacheRecord>> dnsCacheRecords() async {
    final records = <DohDnsCacheRecord>[];
    try {
      records.addAll(await _rustProxyService.dnsCacheRecords() ?? const []);
    } catch (e) {
      debugPrint('[DOH] DNS cache records load failed: $e');
    }

    final seen = records.map(_dnsCacheRecordKey).toSet();
    for (final item in _resolvedHostCache.entries) {
      final host = item.key;
      final entry = item.value;
      if (entry.isExpired) {
        continue;
      }

      void addLocalRecord(DohDnsCacheRecord record) {
        if (seen.add(_dnsCacheRecordKey(record))) {
          records.add(record);
        }
      }

      if (entry.ips.isNotEmpty) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'ip',
            values: entry.ips,
            ttl: entry.remaining,
          ),
        );
      }
      if (entry.echConfig?.isNotEmpty ?? false) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'ech',
            values: [base64Encode(entry.echConfig!)],
            ttl: entry.remaining,
          ),
        );
      }
      if (entry.preferredIp != null) {
        addLocalRecord(
          DohDnsCacheRecord(
            host: host,
            kind: 'preferred_ip',
            values: [entry.preferredIp!],
            ttl: entry.remaining,
          ),
        );
      }
    }

    records.sort((a, b) {
      final hostOrder = a.host.compareTo(b.host);
      if (hostOrder != 0) {
        return hostOrder;
      }
      return _dnsCacheRecordKindOrder(
        a.kind,
      ).compareTo(_dnsCacheRecordKindOrder(b.kind));
    });
    return records;
  }

  Future<void> clearDnsCache() async {
    _clearResolvedHostCache();
    await _rustProxyService.clearDnsCache();
    await refreshDnsCacheStats();
  }

  Future<int> forceRefreshDnsCache() async {
    final hosts = _collectCommonHosts();
    await clearDnsCache();
    if (!current.dohEnabled || hosts.isEmpty) {
      return 0;
    }

    await Future.wait(
      hosts.map((host) => _resolveHostEntry(host, forceRefresh: true)),
    );
    await refreshDnsCacheStats();
    return hosts.length;
  }

  Future<_ResolvedHostEntry?> _resolveHostEntry(
    String host, {
    bool forceRefresh = false,
  }) {
    _ensureResolvedHostCacheSignature();

    if (!forceRefresh) {
      final cached = _resolvedHostCache[host];
      if (cached != null) {
        if (!cached.isExpired) {
          if (cached.shouldRefreshSoon) {
            _refreshHostInBackground(host);
          }
          return Future.value(cached);
        }
        _resolvedHostCache.remove(host);
        _updateLocalDnsCacheStats();
        unawaited(refreshDnsCacheStats());
      }
    } else {
      if (_resolvedHostCache.remove(host) != null) {
        _updateLocalDnsCacheStats();
        unawaited(refreshDnsCacheStats());
      }
    }

    final inflight = _hostLookupInflight[host];
    if (inflight != null) {
      return inflight;
    }

    final future = _loadHostEntry(host, forceRefresh: forceRefresh);
    _hostLookupInflight[host] = future;
    return future.whenComplete(() {
      if (identical(_hostLookupInflight[host], future)) {
        _hostLookupInflight.remove(host);
      }
    });
  }

  Future<_ResolvedHostEntry?> _loadHostEntry(
    String host, {
    required bool forceRefresh,
  }) async {
    final dohServer = _activeServerUrl;
    final dohServerEch = _effectiveEchServerUrl ?? _activeServerUrl;
    final resolvedAt = DateTime.now();

    final rustResult = await _rustProxyService.lookupHost(
      host,
      dohServer,
      dohServerEch: dohServerEch,
      preferIpv6: current.preferIPv6,
      forceRefresh: forceRefresh,
    );
    if (rustResult != null && rustResult.hasData) {
      final entry = _ResolvedHostEntry(
        ips: _normalizeIpList(rustResult.ips),
        preferredIp: _normalizeSingleIp(rustResult.preferredIp),
        echConfig: rustResult.echConfig,
        ttl: _clampDnsTtl(rustResult.ttl),
        resolvedAt: resolvedAt,
        pinned: rustResult.pinned,
      );
      _resolvedHostCache[host] = entry;
      _updateLocalDnsCacheStats();
      unawaited(refreshDnsCacheStats());
      debugPrint(
        '[DOH] Host 已解析 $host '
        '(DNS: ${entry.preferredIp ?? (entry.ips.isEmpty ? "none" : entry.ips.join(", "))}, '
        'ECH: ${entry.echConfig == null ? "off" : "on"}, '
        'TTL: ${entry.ttl.inSeconds}s)',
      );
      return entry;
    }

    final fallbackResults = await Future.wait<dynamic>([
      _lookupIpViaRust(host, dohServer, current.preferIPv6),
      _rustProxyService.lookupEchConfig(host, dohServerEch),
    ]);

    var ips = fallbackResults[0] as List<String>;
    final echConfig = fallbackResults[1] as Uint8List?;

    if (ips.isEmpty) {
      // Rust 两次都没解析出来，再发 DoH 没有意义，直接走系统 DNS 兜底
      final fallback = await resolver.resolveSystemOnly(host);
      ips = _normalizeIpList(fallback.map((address) => address.address));
      if (ips.isNotEmpty) {
        debugPrint('[DOH] 系统 DNS 已解析 $host -> ${ips.join(', ')}');
      }
    }

    final hasData = ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
    // fallback 路径同样不要在真正连通前提前 pin 单 IP。
    // 让 rhttp 先拿完整候选集，避免把错误/不稳定边缘节点缓存成 sticky。
    final preferredIp = null;
    final entry = _ResolvedHostEntry(
      ips: ips,
      preferredIp: preferredIp,
      echConfig: echConfig != null && echConfig.isEmpty ? null : echConfig,
      ttl: hasData ? _defaultDnsCacheTtl : _missDnsCacheTtl,
      resolvedAt: resolvedAt,
    );
    _resolvedHostCache[host] = entry;
    _updateLocalDnsCacheStats();
    unawaited(refreshDnsCacheStats());

    if (!hasData) {
      debugPrint('[DOH] Host 解析失败或为空: $host');
    }
    return entry;
  }

  void _ensureResolvedHostCacheSignature() {
    final signature = _currentResolvedHostCacheSignature;
    if (_resolvedHostCacheSignature == signature) {
      return;
    }
    _clearResolvedHostCache();
    _resolvedHostCacheSignature = signature;
  }

  void _refreshHostInBackground(String host) {
    if (!_backgroundRefreshingHosts.add(host)) {
      return;
    }
    unawaited(
      _resolveHostEntry(host, forceRefresh: true).whenComplete(() {
        _backgroundRefreshingHosts.remove(host);
      }),
    );
  }

  void _setDnsCacheStats(DohDnsCacheStats stats) {
    dnsCacheStatsNotifier.value = stats.copyWith(
      dartEntryCount: _resolvedHostCache.length,
    );
  }

  void _updateLocalDnsCacheStats() {
    _setDnsCacheStats(dnsCacheStatsNotifier.value);
  }

  String _dnsCacheRecordKey(DohDnsCacheRecord record) =>
      '${record.host}|${record.kind}';

  int _dnsCacheRecordKindOrder(String kind) {
    switch (kind) {
      case 'ip':
        return 0;
      case 'ech':
        return 1;
      case 'ech_negative':
        return 2;
      case 'preferred_ip':
        return 3;
      default:
        return 4;
    }
  }

  void _clearResolvedHostCache({bool touch = false}) {
    final changed =
        _resolvedHostCache.isNotEmpty ||
        _hostLookupInflight.isNotEmpty ||
        _backgroundRefreshingHosts.isNotEmpty ||
        _hostIpPenaltyCache.isNotEmpty ||
        _resolvedHostCacheSignature != null;
    _resolvedHostCache.clear();
    _hostLookupInflight.clear();
    _backgroundRefreshingHosts.clear();
    _hostIpPenaltyCache.clear();
    _resolvedHostCacheSignature = null;
    if (changed) {
      _updateLocalDnsCacheStats();
    }
    if (touch && changed) {
      _touch();
    }
  }

  void _handleRhttpSettingsChanged() {
    if (_prefs == null) return;
    _scheduleApplyProxyState();
    _touch();
  }

  String _resolveSelected(String selected, List<DohServer> customServers) {
    final allServers = [..._builtInServers, ...customServers];
    final found = allServers.any((s) => s.url == selected);
    return found ? selected : _defaultServerUrl;
  }

  /// 根据 URL 查找服务器配置（公共加速不在列表里，但也要能查到）
  DohServer? _findServer(String url) {
    for (final server in [...servers, accelDohPublicServer]) {
      if (server.url == url) return server;
    }
    return null;
  }

  /// 读取本机的加速子域名，没有或格式不对时生成一个新的并保存
  Future<String> _loadAccelSubdomain(SharedPreferences prefs) async {
    final saved = prefs.getString(_accelSubdomainKey);
    if (saved != null && isValidAccelSubdomain(saved)) {
      return saved;
    }
    final created = generateAccelSubdomain();
    await prefs.setString(_accelSubdomainKey, created);
    return created;
  }

  /// 获取选中服务器的 Bootstrap IP（加速服务器会并上已下发的节点）
  List<String> _getBootstrapIps(String url) {
    return _mergeAccelNodes(url, _findServer(url)?.bootstrapIps ?? const []);
  }

  /// 加速服务器：已下发节点在前、内置种子在后；其他服务器原样返回
  List<String> _mergeAccelNodes(String url, List<String> seeds) {
    final host = Uri.tryParse(url)?.host;
    if (host == null || !isAccelDohHost(host) || _nodeStore.isEmpty) {
      return seeds;
    }
    return mergeAccelBootstrapIps(_nodeStore.ipsFor(host), seeds);
  }

  String? _normalizeHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty ||
        InternetAddress.tryParse(normalizedHost) != null) {
      return null;
    }
    return normalizedHost;
  }

  String? _parseServerIpOverride() {
    final serverIp = current.serverIp?.trim();
    if (serverIp == null || serverIp.isEmpty) {
      return null;
    }
    return InternetAddress.tryParse(serverIp)?.address;
  }

  Duration _clampDnsTtl(Duration ttl) {
    if (ttl <= Duration.zero) {
      return _defaultDnsCacheTtl;
    }
    if (ttl < _missDnsCacheTtl) {
      return _missDnsCacheTtl;
    }
    if (ttl > const Duration(minutes: 30)) {
      return const Duration(minutes: 30);
    }
    return ttl;
  }

  String? get _currentResolvedHostCacheSignature => current.dohEnabled
      ? '$_activeServerUrl|${_effectiveEchServerUrl ?? ""}|${current.preferIPv6 ? "v6" : "v4"}'
      : null;

  List<String> _collectCommonHosts() {
    final preloaded = PreloadedDataService();
    final hosts = <String>{
      'connect.linux.do',
      'ping.linux.do',
      'cdn.linux.do',
      'credit.linux.do',
      'cdk.linux.do',
    };

    for (final value in [
      AppConstants.baseUrl,
      preloaded.longPollingBaseUrl,
      preloaded.cdnUrl,
      preloaded.s3CdnUrl,
      preloaded.s3BaseUrl,
    ]) {
      final host = _extractHost(value);
      if (host != null) {
        hosts.add(host);
      }
    }

    final result = hosts.toList()..sort();
    return result;
  }

  String? _extractHost(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final normalized = raw.startsWith('//') ? 'https:$raw' : raw;
    final host = Uri.tryParse(normalized)?.host.trim().toLowerCase();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  Future<List<String>> _lookupIpViaRust(
    String host,
    String dohServer,
    bool preferIpv6,
  ) async {
    final result = await _rustProxyService.lookupIp(
      host,
      dohServer,
      preferIpv6: preferIpv6,
    );
    return _normalizeIpList(result);
  }

  List<String> _normalizeIpList(Iterable<String> raw) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      final ip = InternetAddress.tryParse(value.trim())?.address;
      if (ip == null || !seen.add(ip)) {
        continue;
      }
      normalized.add(ip);
    }
    return normalized;
  }

  String? _normalizeSingleIp(String? raw) {
    if (raw == null) {
      return null;
    }
    return InternetAddress.tryParse(raw.trim())?.address;
  }

  List<String> _applyHostIpPenalties(
    String host,
    List<String> ips, {
    String? preferredIp,
  }) {
    if (ips.isEmpty) {
      return const [];
    }

    _evictExpiredHostIpPenalties();
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null || penalties.isEmpty) {
      return ips;
    }

    final preferred = _normalizeSingleIp(preferredIp);
    final available = <String>[];
    final penalized = <String>[];

    for (final ip in ips) {
      if (_isHostIpPenalized(host, ip)) {
        penalized.add(ip);
      } else {
        available.add(ip);
      }
    }

    if (preferred != null && available.remove(preferred)) {
      available.insert(0, preferred);
    }

    if (available.isNotEmpty) {
      return <String>[...available, ...penalized];
    }
    return penalized;
  }

  String? _selectUsablePreferredIp(
    String host,
    String? preferredIp,
    List<String> orderedIps,
  ) {
    final normalizedPreferred = _normalizeSingleIp(preferredIp);
    if (normalizedPreferred == null || orderedIps.isEmpty) {
      return null;
    }
    if (_isHostIpPenalized(host, normalizedPreferred)) {
      return null;
    }
    return orderedIps.first == normalizedPreferred ? normalizedPreferred : null;
  }

  bool _isHostIpPenalized(String host, String ip) {
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null) {
      return false;
    }
    final expiresAt = penalties[ip];
    if (expiresAt == null) {
      return false;
    }
    if (expiresAt.isAfter(DateTime.now())) {
      return true;
    }
    penalties.remove(ip);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(host);
    }
    return false;
  }

  void _evictExpiredHostIpPenalties() {
    if (_hostIpPenaltyCache.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final emptyHosts = <String>[];
    for (final entry in _hostIpPenaltyCache.entries) {
      entry.value.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
      if (entry.value.isEmpty) {
        emptyHosts.add(entry.key);
      }
    }
    for (final host in emptyHosts) {
      _hostIpPenaltyCache.remove(host);
    }
  }

  List<DohServer> _decodeServers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => DohServer.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  String get testHost {
    final baseUri = Uri.tryParse(AppConstants.baseUrl);
    return baseUri?.host ?? 'example.com';
  }
}

/// cfluxdo 加速（Edge Smart DoH）
///
/// 每个安装用一个随机子域名访问，服务端借此区分安装。
/// 查询要带账号令牌（见 [AccelDohAuthService]）：用 L 站 Connect 核验过的账号才发令牌。
/// 没有令牌时（登录佬友、游客/TL0）一律走 [accelDohPublicServer]。
/// 节点 IP 作为 bootstrap：系统 DNS 解析不出加速域名时直接连这些节点（SNI 不变）。
const String accelDohServerName = 'cfluxdo 加速';

/// 公共加速：不需要令牌，给没授权 Connect 或用不了 Connect 的佬友（如青春版）
/// 以及游客/TL0 用。不在服务器列表里显示，只在选中加速且没有令牌时顶上。
const DohServer accelDohPublicServer = DohServer(
  name: 'cfluxdo 公共加速',
  url: 'https://edge.1molchuan.top/linuxdo',
  bootstrapIps: accelDohBootstrapIps,
);

const String _accelDohHostSuffix = 'wq.1molchuan.top';
const String _accelDohPath = '/v1/lookup';

/// 路由表接口：同一 host 下的 `/v1/routes`，专属档带令牌、公共档不带
const String accelRoutesPath = '/v1/routes';

/// 是否是加速服务器的 host（本机专属子域或公共加速）
bool isAccelDohHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  final publicHost = Uri.parse(accelDohPublicServer.url).host;
  return normalized == publicHost ||
      normalized == _accelDohHostSuffix ||
      normalized.endsWith('.$_accelDohHostSuffix');
}

/// 给定 DoH 地址对应的路由表接口；不是加速服务器时返回 null（第三方 DoH 不查表）
String? accelRoutesUrlFor(String dohUrl) {
  final uri = Uri.tryParse(dohUrl);
  if (uri == null || uri.scheme != 'https' || !isAccelDohHost(uri.host)) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: accelRoutesPath,
  ).toString();
}
const int _accelSubdomainLength = 12;
const String _accelSubdomainAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
const List<String> accelDohBootstrapIps = [
  '156.239.232.8',
  '156.239.232.72',
  '203.168.131.145',
  '103.199.103.204',
];

final RegExp _accelSubdomainPattern = RegExp(
  '^[a-z0-9]{$_accelSubdomainLength}\$',
);

@visibleForTesting
bool isValidAccelSubdomain(String value) =>
    _accelSubdomainPattern.hasMatch(value);

@visibleForTesting
String generateAccelSubdomain([Random? random]) {
  final rng = random ?? Random.secure();
  return List.generate(
    _accelSubdomainLength,
    (_) => _accelSubdomainAlphabet[rng.nextInt(_accelSubdomainAlphabet.length)],
  ).join();
}

@visibleForTesting
DohServer buildAccelDohServer(String subdomain) => DohServer(
  name: accelDohServerName,
  url: 'https://$subdomain.$_accelDohHostSuffix$_accelDohPath',
  bootstrapIps: accelDohBootstrapIps,
);

/// 默认 DOH 服务器列表
/// Bootstrap IP 来源：各 DNS 提供商官方文档
/// Chrome 也是这样实现的：预置 IP 地址，直接连接，不需要先 DNS 解析
const List<DohServer> _defaultServers = [
  DohServer(
    name: 'DNSPod',
    url: 'https://doh.pub/dns-query',
    bootstrapIps: ['1.12.12.12', '120.53.53.53'],
  ),
  DohServer(
    name: '腾讯 DNS',
    url: 'https://dns.pub/dns-query',
    bootstrapIps: ['119.29.29.29', '119.28.28.28'],
  ),
  DohServer(
    name: 'Cloudflare',
    url: 'https://cloudflare-dns.com/dns-query',
    bootstrapIps: [
      '1.1.1.1',
      '1.0.0.1',
      '2606:4700:4700::1111',
      '2606:4700:4700::1001',
    ],
  ),
  DohServer(
    name: 'Canadian Shield',
    url: 'https://private.canadianshield.cira.ca/dns-query',
  ),
  DohServer(
    name: '阿里 DNS',
    url: 'https://dns.alidns.com/dns-query',
    bootstrapIps: [
      '223.5.5.5',
      '223.6.6.6',
      '2400:3200::1',
      '2400:3200:baba::1',
    ],
  ),
  DohServer(
    name: 'Quad9',
    url: 'https://dns.quad9.net/dns-query',
    bootstrapIps: ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
  ),
  DohServer(
    name: 'Google',
    url: 'https://dns.google/dns-query',
    bootstrapIps: [
      '8.8.8.8',
      '8.8.4.4',
      '2001:4860:4860::8888',
      '2001:4860:4860::8844',
    ],
  ),
];
