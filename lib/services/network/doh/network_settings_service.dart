import '../../../config/forum_site.dart';
import '../../site_context.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inappwebview;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
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

/// 连接时偏好的地址族（「IP 协议」设置）
enum Ipv6Mode {
  /// 自动（默认）：本机有 IPv6 时优先用 IPv6，IPv6 不通或明显更慢时用 IPv4。
  /// 双栈网络的 IPv4 出口多是运营商共享地址，CF 风险分高、弹盾多；IPv6 多为独享地址
  auto('auto'),

  /// IPv6 优先：有能用的 IPv6 就用，不论快慢
  preferV6('v6'),

  /// IPv4 优先（1.2.2 之前的默认）
  preferV4('v4');

  const Ipv6Mode(this.wire);

  /// 存进 prefs 的字符串形式
  final String wire;

  static Ipv6Mode? fromWire(String? value) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }
}

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    this.echServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.ipv6Mode = Ipv6Mode.auto,
    this.serverIp,
    this.gatewayEnabled = true,
    this.h2Mitm = false,
    this.browserTls = false,
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

  /// 连接时偏好的地址族
  final Ipv6Mode ipv6Mode;

  /// IPv6 优先（传给 Rust 的 prefer_ipv6：解析结果、兜底地址都先排 IPv6）
  bool get preferIPv6 => ipv6Mode == Ipv6Mode.preferV6;

  /// 自动：由 Rust 本地优选按本机网络决定用哪一族
  bool get ipv6Auto => ipv6Mode == Ipv6Mode.auto;

  /// 全局 server IP（指定后跳过 DNS 解析直接连接）
  final String? serverIp;

  /// Gateway（反向代理）模式开关，关闭时回退为 MITM
  final bool gatewayEnabled;

  /// WebView MITM 是否启用 HTTP/2 多路复用（按请求转发到上游；安卓默认开，其余平台默认关）
  final bool h2Mitm;

  /// 浏览器指纹：网关的上游握手（TLS 与 HTTP/2）照 WebView 复刻（安卓默认开；
  /// 其余平台的原生库没编进这个能力，开了也不生效）
  final bool browserTls;

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
    Ipv6Mode? ipv6Mode,
    String? Function()? serverIp,
    bool? gatewayEnabled,
    bool? h2Mitm,
    bool? browserTls,
    CfSelectMode? selectMode,
    bool? shareMeasurements,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      echServerUrl: echServerUrl != null ? echServerUrl() : this.echServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort != null ? proxyPort() : this.proxyPort,
      ipv6Mode: ipv6Mode ?? this.ipv6Mode,
      gatewayEnabled: gatewayEnabled ?? this.gatewayEnabled,
      serverIp: serverIp != null ? serverIp() : this.serverIp,
      h2Mitm: h2Mitm ?? this.h2Mitm,
      browserTls: browserTls ?? this.browserTls,
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

class NetworkSettingsService {
  NetworkSettingsService._internal() {
    _proxyService.notifier.addListener(_handleProxySettingsChanged);
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
  /// 老版本的「IPv6 优先」开关（bool），只用来迁移到 [_ipv6ModeKey]
  static const _preferIPv6Key = 'doh_prefer_ipv6';
  static const _ipv6ModeKey = 'doh_ipv6_mode';
  static const _serverIpKey = 'doh_server_ip';
  static const _echServerKey = 'doh_ech_server';
  static const _gatewayEnabledKey = 'doh_gateway_enabled';
  static const _h2MitmKey = 'doh_h2_mitm';
  static const _browserTlsKey = 'doh_browser_tls';
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
  static const _atlasHost = 'atlas.1molchuan.top';

  /// linux.do 的静态资源域（cdn / cdn3 / ping / linuxdo-uploads.s3 都在它下面）
  static const _ldstaticHost = 'ldstatic.com';
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
  /// Gateway 模式：DOH 开启 + 用户开关开启 + 代理运行中。内置网页也经它中转（MITM），
  /// WebView 的证书放行以此为准
  bool get isGatewayMode =>
      current.dohEnabled &&
      current.gatewayEnabled &&
      _rustProxyService.isRunning;

  /// 加速关着（含 VPN 自动让路）、也没有上游代理时，安卓仍为浏览器指纹起本地网关：
  /// 系统 DNS（开着 VPN 就是 VPN 的）、不做 ECH 和优选，内置网页不经它。
  ///
  /// CF 对原生连接收紧的站点（2026-11-10 实测 IDC Flare）认握手不认 cf_clearance：
  /// 同一枚值浏览器指纹的连接 200，Dart 自己握手的连接（含关掉指纹的网关）验证多少轮
  /// 都 403，登录时兑换令牌也就过不去
  bool get fingerprintOnlyGateway =>
      Platform.isAndroid &&
      !current.dohEnabled &&
      !_proxyService.current.isValid &&
      current.browserTls &&
      current.gatewayEnabled;

  /// App 的请求是否改写成明文发给本地网关（加速网关，或只为浏览器指纹起的网关）
  bool get routesAppThroughGateway =>
      isGatewayMode ||
      (fingerprintOnlyGateway && _rustProxyService.isRunning);

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

  // Rust 代理同时服务 App 自己的请求（网关）和 WebView（MITM 代理）
  /// 需要本地代理中转（内置网页也经它）：加速或上游代理开着
  bool get shouldRunLocalProxy =>
      current.dohEnabled || _proxyService.current.isValid;

  /// 本地网关要不要跑：中转之外，还有只为浏览器指纹的情形（见 [fingerprintOnlyGateway]）
  bool get _shouldRunProxyProcess =>
      shouldRunLocalProxy || fingerprintOnlyGateway;

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
    // 只剩网关一个引擎：「高性能」（rhttp 直连）的开关与模式不再有用，选过的也照常走网关
    await prefs.remove('rhttp_enabled');
    await prefs.remove('rhttp_mode');
    final ipv6Mode = _loadIpv6Mode(prefs);
    final serverIp = prefs.getString(_serverIpKey);
    final echServer = prefs.getString(_echServerKey);
    final gatewayEnabled = prefs.getBool(_gatewayEnabledKey) ?? true;
    // 安卓默认开：内置网页按请求转发到上游，和 App 自己的请求走同一种连接（h2 + 同一指纹）；
    // 原样字节拷贝的 h1 MITM 上游只能谈 HTTP/1.1，指纹与原生请求对不上
    final h2Mitm = prefs.getBool(_h2MitmKey) ?? Platform.isAndroid;
    final browserTls = prefs.getBool(_browserTlsKey) ?? Platform.isAndroid;
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      echServerUrl: echServer,
      customServers: custom,
      proxyPort: proxyPort,
      ipv6Mode: ipv6Mode,
      serverIp: serverIp,
      gatewayEnabled: gatewayEnabled,
      h2Mitm: h2Mitm,
      browserTls: browserTls,
      selectMode: selectMode,
      shareMeasurements: shareMeasurements,
    );
    final activeUrl = _activeServerUrl;
    _resolver = DohResolver(
      serverUrl: activeUrl,
      bootstrapIps: _getBootstrapIps(activeUrl),
      preferIPv6: ipv6Mode == Ipv6Mode.preferV6,
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
    notifier.value = notifier.value.copyWith(dohEnabled: enabled);
    _beginApply(enabled: _shouldRunProxyProcess);
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
    await prefs.setString(_dohCustomKey, jsonEncode([]));
    _touch();
  }

  Future<void> setIpv6Mode(Ipv6Mode mode) async {
    final prefs = _prefs;
    if (prefs == null || mode == current.ipv6Mode) return;
    notifier.value = notifier.value.copyWith(ipv6Mode: mode);
    _resolver.preferIPv6 = mode == Ipv6Mode.preferV6;
    await prefs.setString(_ipv6ModeKey, mode.wire);
    await prefs.remove(_preferIPv6Key);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 读「IP 协议」设置。老版本只有「IPv6 优先」开关：开过 → IPv6 优先；明确关掉过 →
  /// 尊重当时的选择，IPv4 优先；从没碰过 → 自动（新默认）
  @visibleForTesting
  static Ipv6Mode loadIpv6Mode(SharedPreferences prefs) => _loadIpv6Mode(prefs);

  static Ipv6Mode _loadIpv6Mode(SharedPreferences prefs) {
    final stored = Ipv6Mode.fromWire(prefs.getString(_ipv6ModeKey));
    if (stored != null) return stored;
    return switch (prefs.getBool(_preferIPv6Key)) {
      true => Ipv6Mode.preferV6,
      false => Ipv6Mode.preferV4,
      null => Ipv6Mode.auto,
    };
  }

  Future<void> setServerIp(String? ip) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = ip?.trim();
    final value = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    notifier.value = notifier.value.copyWith(serverIp: () => value);
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

  /// 切换浏览器指纹（实验性）。切换后重启代理生效
  Future<void> setBrowserTls(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(browserTls: enabled);
    await prefs.setBool(_browserTlsKey, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  /// 指纹模板的落盘位置（应用支持目录下，卸载即清）
  static Future<String?> _fingerprintCachePath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}/net/fingerprint_template.json';
    } catch (_) {
      return null;
    }
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
    selectStatusNotifier.value = status;
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
    if (!_shouldRunProxyProcess) {
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
      // 只为浏览器指纹起的网关不中转内置网页，也就没有 MITM
      final fingerprintOnly = fingerprintOnlyGateway;
      final mitmConnect =
          !fingerprintOnly &&
          WebViewMitmPolicy.useMitmConnect(
            isWindows: Platform.isWindows,
            webViewAdapterEnabled: webViewAdapterEnabled,
          );
      final useGateway =
          fingerprintOnly ||
          WebViewMitmPolicy.useGatewayMode(
            isWindows: Platform.isWindows,
            dohEnabled: current.dohEnabled,
            gatewayEnabled: current.gatewayEnabled,
            webViewAdapterEnabled: webViewAdapterEnabled,
          );

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

      // Rust 代理同时是 App 请求的网关和 WebView 的代理
      final success = await _rustProxyService.start(
        preferredPort:
            WindowsWebViewEnvironmentService.instance.activeLocalProxyPort ??
            _activeProxyPort ??
            current.proxyPort ??
            0,
        enableDoh: current.dohEnabled,
        gatewayMode: useGateway,
        preferIPv6: current.preferIPv6,
        ipv6Auto: current.ipv6Auto,
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
        // 两个论坛共用同一个赢家：另一站（含子域）也纳入本地优选覆盖，
        // 走同一个边缘 IP + ECH，与 linux.do 一样不查公共 DNS 的明文答案
        extraCoveredHosts: [
          _atlasHost,
          cfhubHost,
          for (final site in ForumSite.values)
            if (!site.isLinuxDo) site.host,
          // linux.do 的静态资源域（图片 / 表情 / 消息总线 / 直传）：和主站同一个
          // 赢家 + ECH，高墙地区的明文 SNI 会被 RST（福建实测图片全 502）
          _ldstaticHost,
        ],
        appVersion: _appVersion,
        networkSig: ConnectivityService().networkSignature.value,
        // 优选出结果后先预建一条到 linux.do 的上游连接，首个请求不用再等握手
        preconnectHosts: [SiteContext.current.host],
        browserTls: current.browserTls,
        fingerprintCachePath: current.browserTls
            ? await _fingerprintCachePath()
            : null,
        // 冷启动时 UA 还没探（探测排在起代理之后），用上次记下的
        webviewUserAgent: prefsForSeed == null
            ? AppConstants.webViewUserAgentIfKnown
            : AppConstants.lastKnownWebViewUserAgent(prefsForSeed),
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
      if (!_shouldRunProxyProcess) {
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
    _beginApply(enabled: _shouldRunProxyProcess);
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
    if (!_shouldRunProxyProcess) return;
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
    _beginApply(enabled: _shouldRunProxyProcess);
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
    if (!shouldRunLocalProxy) {
      // 只为浏览器指纹起的网关：内置网页照常直连（VPN 开着就走 VPN），之前设过的代理要撤掉
      await _clearWebViewProxy();
      return;
    }
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
    await _rustProxyService.clearDnsCache();
    await refreshDnsCacheStats();
  }

  /// 清掉 DNS 缓存后让 Rust 重新解析常用域名（IP + ECH），网关之后的请求直接用
  Future<int> forceRefreshDnsCache() async {
    final hosts = _collectCommonHosts();
    await clearDnsCache();
    if (!current.dohEnabled || hosts.isEmpty) {
      return 0;
    }

    final dohServer = _activeServerUrl;
    final dohServerEch = _effectiveEchServerUrl ?? dohServer;
    await Future.wait(
      hosts.map(
        (host) => _rustProxyService.lookupHost(
          host,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
          forceRefresh: true,
        ),
      ),
    );
    await refreshDnsCacheStats();
    return hosts.length;
  }

  void _setDnsCacheStats(DohDnsCacheStats stats) {
    dnsCacheStatsNotifier.value = stats;
  }

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

  List<String> _collectCommonHosts() {
    final preloaded = PreloadedDataService();
    final hosts = <String>{
      if (SiteContext.isLinuxDo) ...[
        'connect.linux.do',
        'ping.linux.do',
        'cdn.linux.do',
        'credit.linux.do',
        'cdk.linux.do',
      ],
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
const String accelDohServerName = 'CFluxDo 加速';

/// 公共加速：不需要令牌，给没授权 Connect 或用不了 Connect 的佬友（如青春版）
/// 以及游客/TL0 用。不在服务器列表里显示，只在选中加速且没有令牌时顶上。
const DohServer accelDohPublicServer = DohServer(
  name: 'CFluxDo 公共加速',
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
