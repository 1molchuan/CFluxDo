import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../app_logger.dart';
import '../connectivity_service.dart';
import '../local_notification_service.dart';
import '../site_context.dart';
import '../toast_service.dart';
import 'doh/network_settings_service.dart';
import 'proxy/proxy_settings_service.dart';
import 'system_proxy_service.dart';
import 'windows_vpn_adapter_detector.dart';

/// VPN 自动切换的判定方式。
enum VpnDetectionMode {
  automatic,
  forceActive,
  forceInactive;

  static VpnDetectionMode fromString(String? value) {
    return VpnDetectionMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => VpnDetectionMode.automatic,
    );
  }
}

/// 论坛连接层的连续失败：拿到任何 HTTP 响应就清零；[window] 内连续 [threshold] 次
/// 连不上、且这串失败至少持续了 [minSpan] 才算数——换网瞬间一起失败的几个请求不算
class ForumUnreachableStreak {
  ForumUnreachableStreak({
    this.threshold = 3,
    this.minSpan = const Duration(seconds: 2),
    this.window = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int threshold;
  final Duration minSpan;
  final Duration window;
  final DateTime Function() _clock;

  int _count = 0;
  DateTime? _since;

  /// 这一串里已记的失败次数
  int get count => _count;

  void reset() {
    _count = 0;
    _since = null;
  }

  /// 记一次连不上。不够数返回 null；够数返回还要再等多久才能确认
  /// （[Duration.zero] 即现在就算），等的期间拿到任何响应就作废
  Duration? recordFailure() {
    final now = _clock();
    final since = _since;
    if (since == null || now.difference(since) > window) {
      _since = now;
      _count = 0;
    }
    _count++;
    if (_count < threshold) return null;
    final lasted = now.difference(_since!);
    return lasted >= minSpan ? Duration.zero : minSpan - lasted;
  }

  /// 等待期满时确认：这期间没拿到过响应就算连不上，并清零（一串失败只触发一次）
  bool confirm() {
    if (_count < threshold) return false;
    reset();
    return true;
  }
}

/// VPN 自动切换服务
///
/// 连接加速让不让路：安卓「自动」判定下按**实测**——网络形态变了（含 VPN 开关）就绕开
/// 加速、用系统网络对论坛发一次普通请求（[probeDirect]），能直连就让路、不能就保持加速。
/// 只看 VPN 网卡两头都会错（2026-11 佬友反馈）：路由器（OpenWrt）分流的手机没有 VPN
/// 网卡却能直连；Tailscale 有网卡却不翻墙。桌面端与「强制」两档仍按 VPN 网卡。
/// 上游代理始终按 VPN 网卡让路（用户自己配的代理，常就是这个 VPN 的本地端口）。
///
/// 采用"压制标记"模式：通过 SharedPreferences 标记哪些项是被自动关闭的，
/// 条件消失后根据标记恢复，不修改 NetworkSettingsService / ProxySettingsService 内部逻辑。
///
/// 让路期间论坛一直连不上时恢复连接加速（见 [reportForumTransport]），并把这个网络记成
/// 不能直连。
class VpnAutoToggleService {
  VpnAutoToggleService._();
  static final VpnAutoToggleService instance = VpnAutoToggleService._();

  static const _keyEnabled = 'vpn_auto_toggle_enabled';
  static const _keySuppressedDoh = 'vpn_suppressed_doh';
  static const _keySuppressedProxy = 'vpn_suppressed_proxy';
  static const _keyDetectionMode = 'vpn_detection_mode';
  static const _keyAccelResumed = 'vpn_accel_resumed';
  static const _keyDirectProbe = 'vpn_direct_probe';

  /// 实测结果按「网络形态@站点」缓存，只当下次同一网络启动时的初值；最多留这么多条
  static const _probeCacheLimit = 12;
  static const _probeCacheTtl = Duration(days: 7);

  late SharedPreferences _prefs;

  /// 本次 VPN 期间已因连不上论坛恢复了连接加速：之后的网络变化不再暂停它，
  /// VPN 断开或关掉让路时清掉。落盘，VPN 一直连着时重启 App 也照旧
  final accelResumedNotifier = ValueNotifier<bool>(false);

  /// 让路期间论坛连接层的连续失败
  @visibleForTesting
  ForumUnreachableStreak unreachableStreak = ForumUnreachableStreak();

  /// 连续失败够数后等确认的计时
  Timer? _unreachableConfirmTimer;

  /// 功能是否启用
  final enabledNotifier = ValueNotifier<bool>(false);

  /// 当前是否检测到 VPN
  final vpnActiveNotifier = ValueNotifier<bool>(false);

  /// 自动判定 / 强制视为 VPN / 强制视为非 VPN。
  final detectionModeNotifier = ValueNotifier<VpnDetectionMode>(
    VpnDetectionMode.automatic,
  );

  /// 压制标记变化通知（UI 据此刷新"VPN 断开后是否启用"的意图显示）
  final suppressionNotifier = ValueNotifier<int>(0);

  /// 当前网络实测能否直连论坛：null 表示还没测（或刚换网），见 [probeDirect]
  final directReachableNotifier = ValueNotifier<bool?>(null);

  /// 正在实测
  final probingNotifier = ValueNotifier<bool>(false);

  /// 测试替身：实测函数（默认 [probeDirect]）与是否按实测（默认只有安卓）
  @visibleForTesting
  static Future<bool> Function(Uri url) directProber = probeDirect;
  @visibleForTesting
  static bool? probeSupportedOverride;
  @visibleForTesting
  static Duration probeDelay = const Duration(milliseconds: 1500);

  /// 防重入标记；进行中又来了新判断就记下，做完再按最新状态对一遍
  bool _isSuppressing = false;
  bool _reconcileAgain = false;

  /// 加速此刻该不该让路（见 [_recomputeYield]）
  bool _yieldAccel = false;

  /// 当前网络形态（[ConnectivityService.signatureOf]）与实测
  String _networkSig = '';
  Timer? _probeTimer;
  int _probeGeneration = 0;
  DateTime? _probedAt;

  /// Windows 网卡枚举是异步的。只允许最后一次网络变化的结果生效，避免较慢的
  /// 旧枚举覆盖较新的连接状态。
  int _windowsDetectionGeneration = 0;
  List<ConnectivityResult> _lastConnectivityResults = const [];
  bool _lastHasWindowsVpnAdapter = false;
  bool _shouldSuppress = false;

  /// Windows 开关 TUN 网卡 / 系统代理常常不产生 connectivity 事件,单靠事件
  /// 驱动会漏检(用户开了网卡界面却一直显示"VPN 未连接")。补两条信号:
  /// - 订阅 [SystemProxyService.version](其内部已有 10s 注册表节拍);
  /// - 低频异步兜底重检网卡。检测本身是异步枚举,不落在 UI 帧上,
  ///   与曾导致周期性卡顿的 3s 同步轮询不同。
  Timer? _windowsFallbackTimer;
  static const _windowsFallbackInterval = Duration(seconds: 15);

  void _ensureWindowsSignalWatch() {
    if (_windowsFallbackTimer != null || !Platform.isWindows) return;
    SystemProxyService.instance.version.addListener(_redetectWindows);
    _windowsFallbackTimer = Timer.periodic(
      _windowsFallbackInterval,
      (_) => _redetectWindows(),
    );
  }

  void _redetectWindows() {
    final generation = ++_windowsDetectionGeneration;
    unawaited(_detectWindowsVpnAndApply(_lastConnectivityResults, generation));
  }

  void _bumpSuppression() => suppressionNotifier.value++;

  /// 上一次写进日志的网络形态，网络事件常成串重复，只在变化时记一条
  String? _lastLoggedNetworkState;

  /// 分享日志 / 网络健康快照里的 VPN 让路状态。2026-11 佬友报「开梯子要全局才连得上」，
  /// 当时日志里看不出 App 有没有识别到 VPN、有没有让路，所以把这些都带上
  Map<String, Object?> diagnostics() => {
    'autoToggle': enabled,
    'detection': detectionMode.name,
    'vpnActive': vpnActive,
    'shouldSuppress': _shouldSuppress,
    'yieldAccel': _yieldAccel,
    'probeDriven': _probeDriven,
    'directReachable': directReachableNotifier.value,
    'probedAt': _probedAt?.toIso8601String(),
    'networkSig': _networkSig,
    'dohSuppressed': _prefsReady ? isDohSuppressed : null,
    'proxySuppressed': _prefsReady ? isProxySuppressed : null,
    'accelResumed': accelResumed,
    'connectivity': [for (final r in _lastConnectivityResults) r.name],
    if (Platform.isWindows) 'windowsVpnAdapter': _lastHasWindowsVpnAdapter,
  };

  bool _prefsReady = false;

  /// 网络形态或让路判断变了才写一条（connectivity 事件、启动同步都会走到这里）
  void _logNetworkState(String source) {
    final direct = directReachableNotifier.value;
    final state =
        '${_lastConnectivityResults.map((r) => r.name).join(',')}'
        '|vpn=$vpnActive|suppress=$_shouldSuppress|yield=$_yieldAccel'
        '|direct=$direct|on=$enabled|mode=${detectionMode.name}';
    if (state == _lastLoggedNetworkState) return;
    _lastLoggedNetworkState = state;
    final probeText = !_probeDriven
        ? ''
        : direct == null
        ? '，未实测'
        : (direct ? '，实测能直连' : '，实测不能直连');
    AppLogger.info(
      '网络形态：${_lastConnectivityResults.map((r) => r.name).join('+')}，'
      '${vpnActive ? '有 VPN 网卡' : '无 VPN 网卡'}$probeText'
      '${enabled ? (_yieldAccel ? '，加速让路' : '，保持加速') : '（自动让路已关）'}',
      tag: 'VpnAutoToggle',
      fields: {'source': source, ...diagnostics()},
    );
  }

  bool get enabled => enabledNotifier.value;
  bool get vpnActive => vpnActiveNotifier.value;
  VpnDetectionMode get detectionMode => detectionModeNotifier.value;
  bool get accelResumed => accelResumedNotifier.value;

  /// 连接加速开关此刻由让路接管（拨动只记让路结束后的意图）：正在让路、
  /// 且本次没有因连不上论坛恢复加速
  bool get locksAcceleration => enabled && _yieldAccel && !accelResumed;

  /// 这个平台按实测决定加速让不让路（安卓）
  static bool get probeCapable => probeSupportedOverride ?? Platform.isAndroid;

  /// 加速让路按实测：安卓、「自动」判定
  bool get _probeDriven =>
      probeCapable && detectionMode == VpnDetectionMode.automatic;

  /// 设置页显示实测结果与「重新检测」
  bool get probeDriven => _probeDriven;

  /// 用户点「重新检测」
  void recheck() => _scheduleProbe(delay: Duration.zero);

  /// 加速该不该让路：按实测时用本网络的实测结果，没测过先用上次同一网络的缓存，
  /// 都没有就按 VPN 网卡（旧行为）；其余情况就是 VPN 网卡 / 强制档
  void _recomputeYield() {
    _yieldAccel = _probeDriven
        ? (directReachableNotifier.value ?? _cachedProbe() ?? _shouldSuppress)
        : _shouldSuppress;
  }

  /// 网络形态变了：作废上一个网络的实测，「本次已恢复加速」也到此为止
  void _onNetworkSig(String sig) {
    if (sig == _networkSig) return;
    _networkSig = sig;
    _probeGeneration++;
    directReachableNotifier.value = null;
    probingNotifier.value = false;
    _probedAt = null;
    if (accelResumed && _probeDriven) {
      accelResumedNotifier.value = false;
      unawaited(_prefs.remove(_keyAccelResumed));
    }
  }

  @visibleForTesting
  static bool resolveVpnActive({
    required List<ConnectivityResult> connectivityResults,
    required bool hasWindowsVpnAdapter,
    bool systemProxyEnabled = false,
  }) {
    return connectivityResults.contains(ConnectivityResult.vpn) ||
        hasWindowsVpnAdapter ||
        systemProxyEnabled;
  }

  /// TUN 名称识别目前仅补充状态展示，不扩大自动压制的触发范围。
  ///
  /// Windows 上部分 TUN 被报告为以太网；若仅因名称命中就立即关闭 DoH/上游
  /// 代理，会让正在使用的传输适配器在启动阶段切换，改变 Dio 的 TLS/CF 信任
  /// 上下文。先保持上游原有语义：只有 connectivity_plus 明确报告 VPN 时才
  /// 执行自动压制。
  @visibleForTesting
  static bool shouldAutoSuppress(List<ConnectivityResult> connectivityResults) {
    return connectivityResults.contains(ConnectivityResult.vpn);
  }

  @visibleForTesting
  static bool resolveDetection({
    required bool automaticValue,
    required VpnDetectionMode mode,
  }) {
    return switch (mode) {
      VpnDetectionMode.automatic => automaticValue,
      VpnDetectionMode.forceActive => true,
      VpnDetectionMode.forceInactive => false,
    };
  }

  /// DOH 是否被 VPN 压制
  bool get isDohSuppressed => _prefs.getBool(_keySuppressedDoh) ?? false;

  /// 代理是否被 VPN 压制
  bool get isProxySuppressed => _prefs.getBool(_keySuppressedProxy) ?? false;

  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _prefsReady = true;
    // 默认开启:per-device CA/DoH 网关在 VPN 活跃时容易拖慢连接,VPN 用户
    // 不该还得手动来这页找开关。
    enabledNotifier.value = prefs.getBool(_keyEnabled) ?? true;
    detectionModeNotifier.value = VpnDetectionMode.fromString(
      prefs.getString(_keyDetectionMode),
    );
    accelResumedNotifier.value = prefs.getBool(_keyAccelResumed) ?? false;
    _resetUnreachableWatch();
  }

  /// 开关控制
  Future<void> setEnabled(bool value) async {
    enabledNotifier.value = value;
    await _prefs.setBool(_keyEnabled, value);

    // 开关功能时立即重检一次,不等兜底周期
    if (value && Platform.isWindows) {
      SystemProxyService.instance.refresh();
      _redetectWindows();
    }

    if (!value) {
      // 关闭功能时，如果有活跃压制则立即恢复
      _probeTimer?.cancel();
      await _restoreAll();
    } else {
      _recomputeYield();
      await _reconcile();
      _scheduleProbe(delay: Duration.zero);
    }
  }

  Future<void> setDetectionMode(VpnDetectionMode mode) async {
    if (detectionModeNotifier.value == mode) return;
    detectionModeNotifier.value = mode;
    await _prefs.setString(_keyDetectionMode, mode.name);
    // 先按缓存信号立即刷新 UI,再发起一次真实重检(异步),
    // 避免用户切回"自动"后要等下一个兜底周期才看到真实状态。
    _applyLastKnownState();
    if (Platform.isWindows) {
      SystemProxyService.instance.refresh();
      _redetectWindows();
    }
    _scheduleProbe(delay: Duration.zero);
  }

  /// 由 ConnectivityService 调用
  void handleConnectivityChanged(List<ConnectivityResult> results) {
    _lastConnectivityResults = results;
    final sig = ConnectivityService.signatureOf(results);
    final changed = sig != _networkSig;
    _onNetworkSig(sig);
    // 同一形态的重复事件不重测；换了网、或这个网还没测过（也没在测）才测
    if (changed ||
        (directReachableNotifier.value == null && !probingNotifier.value)) {
      _scheduleProbe();
    }
    if (Platform.isWindows) {
      final generation = ++_windowsDetectionGeneration;
      unawaited(_detectWindowsVpnAndApply(results, generation));
      return;
    }
    final hasVpn = results.contains(ConnectivityResult.vpn);
    _applyVpnState(hasVpn, shouldSuppress: hasVpn);
  }

  Future<void> _detectWindowsVpnAndApply(
    List<ConnectivityResult> results,
    int generation,
  ) async {
    final adapterStatus = await WindowsVpnAdapterDetector.detect();
    if (generation != _windowsDetectionGeneration) return;
    _lastHasWindowsVpnAdapter = adapterStatus.active;
    _applyVpnState(
      resolveVpnActive(
        connectivityResults: results,
        hasWindowsVpnAdapter: adapterStatus.active,
        systemProxyEnabled:
            SystemProxyService.instance.effectiveProxyUrl != null,
      ),
      shouldSuppress: shouldAutoSuppress(results),
    );
  }

  void _applyVpnState(bool hasVpn, {required bool shouldSuppress}) {
    final mode = detectionMode;
    final effectiveVpnActive = resolveDetection(
      automaticValue: hasVpn,
      mode: mode,
    );
    final effectiveShouldSuppress = resolveDetection(
      automaticValue: shouldSuppress,
      mode: mode,
    );
    vpnActiveNotifier.value = effectiveVpnActive;
    _shouldSuppress = effectiveShouldSuppress;
    _recomputeYield();
    _logNetworkState('connectivity');

    if (!enabled) return;
    unawaited(_reconcile());
  }

  void _applyLastKnownState() {
    _applyVpnState(
      resolveVpnActive(
        connectivityResults: _lastConnectivityResults,
        hasWindowsVpnAdapter: _lastHasWindowsVpnAdapter,
        systemProxyEnabled:
            Platform.isWindows &&
            SystemProxyService.instance.effectiveProxyUrl != null,
      ),
      shouldSuppress: shouldAutoSuppress(_lastConnectivityResults),
    );
  }

  /// 启动时同步一次 VPN 状态，避免首个请求发出后再切换网络配置。
  Future<void> syncInitialState(List<ConnectivityResult> results) async {
    _lastConnectivityResults = results;
    _onNetworkSig(ConnectivityService.signatureOf(results));
    _ensureWindowsSignalWatch();
    final hasWindowsVpnAdapter = Platform.isWindows
        ? (await WindowsVpnAdapterDetector.detect()).active
        : false;
    _lastHasWindowsVpnAdapter = hasWindowsVpnAdapter;
    final hasVpn = resolveVpnActive(
      connectivityResults: results,
      hasWindowsVpnAdapter: hasWindowsVpnAdapter,
      systemProxyEnabled:
          Platform.isWindows &&
          SystemProxyService.instance.effectiveProxyUrl != null,
    );
    final mode = detectionMode;
    vpnActiveNotifier.value = resolveDetection(
      automaticValue: hasVpn,
      mode: mode,
    );
    _shouldSuppress = resolveDetection(
      automaticValue: shouldAutoSuppress(results),
      mode: mode,
    );
    // 先按上次同一网络的实测（或 VPN 网卡）定初值，赶在网络设置初始化之前；
    // 真正的实测随后在后台做，结果不同再切
    _recomputeYield();
    _logNetworkState('startup');

    if (!enabled) return;
    await _reconcile();
    _scheduleProbe(delay: Duration.zero);
  }

  /// 按当前判断对齐加速与上游代理：加速看 [_yieldAccel]，上游代理看 VPN 网卡
  /// （[_shouldSuppress]）。进行中又来了新判断，做完再对一遍，不丢最后的状态
  Future<void> _reconcile() async {
    if (!enabled) return;
    if (_isSuppressing) {
      _reconcileAgain = true;
      return;
    }
    _isSuppressing = true;
    try {
      do {
        _reconcileAgain = false;
        await _reconcileAccel();
        await _reconcileProxy();
      } while (_reconcileAgain && enabled);
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
  }

  Future<void> _reconcileAccel() async {
    final dohService = NetworkSettingsService.instance;
    if (_yieldAccel) {
      // 冷启动时网络设置还没初始化（还没起代理）：直接改偏好，初始化时就按关着来，
      // 不用先起代理再关掉。本次已因连不上论坛恢复了加速的，不再暂停
      final dohEnabled = dohService.isInitialized
          ? dohService.notifier.value.dohEnabled
          : NetworkSettingsService.storedDohEnabled(_prefs);
      if (dohEnabled && !accelResumed) {
        _resetUnreachableWatch();
        await _prefs.setBool(_keySuppressedDoh, true);
        if (dohService.isInitialized) {
          await dohService.setDohEnabled(false);
        } else {
          await NetworkSettingsService.storeDohEnabled(_prefs, false);
        }
        AppLogger.info(
          _probeDriven ? '系统网络能直连论坛，暂停连接加速' : 'VPN 让路：暂停连接加速',
          tag: 'VpnAutoToggle',
        );
      }
      return;
    }

    _resetUnreachableWatch();
    // 按 VPN 网卡判断时，「本次 VPN 期间已恢复加速」随 VPN 断开结束；按实测时它随换网结束
    if (accelResumed && !_probeDriven) {
      accelResumedNotifier.value = false;
      await _prefs.remove(_keyAccelResumed);
    }
    if (isDohSuppressed) {
      await _prefs.remove(_keySuppressedDoh);
      if (dohService.isInitialized) {
        await dohService.setDohEnabled(true);
      } else {
        await NetworkSettingsService.storeDohEnabled(_prefs, true);
      }
      AppLogger.info(
        _probeDriven ? '系统网络不能直连论坛，恢复连接加速' : 'VPN 断开或不再让路：恢复连接加速',
        tag: 'VpnAutoToggle',
      );
    }
  }

  Future<void> _reconcileProxy() async {
    final proxyService = ProxySettingsService.instance;
    if (_shouldSuppress) {
      if (proxyService.notifier.value.enabled) {
        await _prefs.setBool(_keySuppressedProxy, true);
        await proxyService.setEnabled(false);
        AppLogger.info('VPN 让路：暂停上游代理', tag: 'VpnAutoToggle');
      }
    } else if (isProxySuppressed) {
      await _prefs.remove(_keySuppressedProxy);
      await proxyService.setEnabled(true);
      AppLogger.info('VPN 断开或不再让路：恢复上游代理', tag: 'VpnAutoToggle');
    }
  }

  /// 关掉自动让路：恢复所有被暂停的项，清掉「本次已恢复加速」
  Future<void> _restoreAll() async {
    // 进行中的对齐看到 enabled 已关会自己停下，这里直接恢复
    _isSuppressing = true;
    try {
      _resetUnreachableWatch();
      if (accelResumed) {
        accelResumedNotifier.value = false;
        await _prefs.remove(_keyAccelResumed);
      }
      if (isDohSuppressed) {
        await _prefs.remove(_keySuppressedDoh);
        final dohService = NetworkSettingsService.instance;
        if (dohService.isInitialized) {
          await dohService.setDohEnabled(true);
        } else {
          await NetworkSettingsService.storeDohEnabled(_prefs, true);
        }
        AppLogger.info('关闭自动让路：恢复连接加速', tag: 'VpnAutoToggle');
      }
      if (isProxySuppressed) {
        await _prefs.remove(_keySuppressedProxy);
        await ProxySettingsService.instance.setEnabled(true);
        AppLogger.info('关闭自动让路：恢复上游代理', tag: 'VpnAutoToggle');
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
  }

  // ---------------------------------------------------------------------------
  // 实测：系统网络能否直连论坛
  // ---------------------------------------------------------------------------

  /// 绕开加速、用系统网络（随 VPN / 路由器）对 [url] 发一次 HEAD：拿到任何 HTTP 响应
  /// （含 CF 质询的 403）就说明 TLS 握手过了、没被重置；连接被重置、证书不对（DNS 被
  /// 污染到别家 IP）、超时都算不能。只打论坛自己，不经第三方
  static Future<bool> probeDirect(Uri url) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .openUrl('HEAD', url)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      await response.drain<void>().catchError((_) {});
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  String get _probeKey => '$_networkSig@${SiteContext.current.host}';

  Map<String, dynamic> _readProbeCache() {
    if (!_prefsReady) return {};
    try {
      final raw = _prefs.getString(_keyDirectProbe);
      if (raw == null) return {};
      final map = jsonDecode(raw);
      return map is Map<String, dynamic> ? map : {};
    } catch (_) {
      return {};
    }
  }

  /// 上次同一网络形态、同一站点的实测结果（过期或没有返回 null）
  bool? _cachedProbe() {
    if (_networkSig.isEmpty) return null;
    final entry = _readProbeCache()[_probeKey];
    if (entry is! Map) return null;
    final at = entry['at'];
    final ok = entry['ok'];
    if (at is! int || ok is! bool) return null;
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    return age > _probeCacheTtl ? null : ok;
  }

  Future<void> _storeProbe(bool ok) async {
    if (!_prefsReady || _networkSig.isEmpty) return;
    final cache = _readProbeCache()
      ..[_probeKey] = {'ok': ok, 'at': DateTime.now().millisecondsSinceEpoch};
    if (cache.length > _probeCacheLimit) {
      final keys = cache.keys.toList()
        ..sort(
          (a, b) => ((cache[a] as Map?)?['at'] as int? ?? 0).compareTo(
            (cache[b] as Map?)?['at'] as int? ?? 0,
          ),
        );
      for (final k in keys.take(cache.length - _probeCacheLimit)) {
        cache.remove(k);
      }
    }
    await _prefs.setString(_keyDirectProbe, jsonEncode(cache));
  }

  /// 换网 / VPN 开关时网络事件常成串到达、VPN 也要一会儿才接管，稍等再测
  void _scheduleProbe({Duration? delay}) {
    if (!_probeDriven || !enabled || _networkSig.isEmpty) return;
    _probeTimer?.cancel();
    _probeTimer = Timer(delay ?? probeDelay, () => unawaited(runProbe()));
  }

  /// 实测一次并按结果对齐（换网后旧结果作废）
  @visibleForTesting
  Future<void> runProbe() async {
    if (!_probeDriven || !enabled || _networkSig.isEmpty) return;
    final generation = ++_probeGeneration;
    final sig = _networkSig;
    final host = SiteContext.current.host;
    probingNotifier.value = true;
    final watch = Stopwatch()..start();
    final ok = await directProber(Uri.https(host, '/srv/status'));
    if (generation != _probeGeneration || sig != _networkSig) return;
    probingNotifier.value = false;
    _probedAt = DateTime.now();
    directReachableNotifier.value = ok;
    await _storeProbe(ok);
    AppLogger.info(
      '实测系统网络${ok ? '能' : '不能'}直连 $host（${watch.elapsedMilliseconds} ms，网络 $sig）',
      tag: 'VpnAutoToggle',
    );
    _recomputeYield();
    _logNetworkState('probe');
    await _reconcile();
  }

  /// 网络适配器报告论坛请求在连接层的结果（[reachable]：拿到了 HTTP 响应）。
  ///
  /// 只在让路正暂停着用户开着的加速时计数。一直连不上说明这个 VPN 没接管论坛的连接：
  /// 去广告 / 防火墙 / DNS 类应用也占着 VPN 接口，或分流规则把论坛设成了直连。国内明文
  /// 域名会被重置、系统 DNS 还常被污染，只留浏览器指纹的网关也连不上，于是本次 VPN 期间
  /// 恢复完整加速（ECH + 优选）。[detail] 是失败原因，只进日志
  void reportForumTransport({required bool reachable, String? detail}) {
    if (!_watchingStepAside) return;
    if (reachable) {
      _resetUnreachableWatch();
      return;
    }
    final wait = unreachableStreak.recordFailure();
    if (unreachableStreak.count == 1) {
      AppLogger.warning(
        'VPN 让路期间论坛连不上（${detail ?? 'unreachable'}）',
        tag: 'VpnAutoToggle',
      );
    }
    if (wait == null) return;
    _unreachableConfirmTimer?.cancel();
    _unreachableConfirmTimer = Timer(wait, () {
      if (_watchingStepAside && unreachableStreak.confirm()) {
        unawaited(resumeAccelerationForVpn(detail ?? 'unreachable'));
      }
    });
  }

  /// 让路正在暂停用户本来开着的加速，且本次还没恢复过
  bool get _watchingStepAside =>
      enabled && _yieldAccel && !accelResumed && isDohSuppressed;

  void _resetUnreachableWatch() {
    _unreachableConfirmTimer?.cancel();
    _unreachableConfirmTimer = null;
    unreachableStreak.reset();
  }

  /// 本次 VPN 期间恢复连接加速：去掉暂停记号、打开加速，记下「本次已恢复」
  @visibleForTesting
  Future<bool> resumeAccelerationForVpn(String reason) async {
    if (!_watchingStepAside || _isSuppressing) return false;
    _isSuppressing = true;
    try {
      accelResumedNotifier.value = true;
      await _prefs.setBool(_keyAccelResumed, true);
      // 按实测时：实际请求推翻了「能直连」，这个网络记成不能直连，下次启动直接加速
      if (_probeDriven) {
        directReachableNotifier.value = false;
        await _storeProbe(false);
        _recomputeYield();
      }
      await _prefs.remove(_keySuppressedDoh);
      final dohService = NetworkSettingsService.instance;
      if (dohService.isInitialized) {
        await dohService.setDohEnabled(true);
      } else {
        await NetworkSettingsService.storeDohEnabled(_prefs, true);
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
    AppLogger.warning(
      'VPN 让路期间论坛一直连不上（$reason），本次 VPN 期间恢复连接加速',
      tag: 'VpnAutoToggle',
    );
    // 没有界面时（单测、启动早期）不弹
    if (navigatorKey.currentContext != null) {
      ToastService.showInfo(S.current.vpnToggle_accelResumedToast);
    }
    return true;
  }

  /// 当用户在 VPN 活跃期间手动开启被压制的项时，清除对应标记
  ///
  /// 由 UI 层在检测到手动开启时调用
  void clearDohSuppression() {
    _prefs.remove(_keySuppressedDoh);
    debugPrint('[VpnAutoToggle] 清除 DOH 压制标记（用户手动开启）');
  }

  void clearProxySuppression() {
    _prefs.remove(_keySuppressedProxy);
    debugPrint('[VpnAutoToggle] 清除代理压制标记（用户手动开启）');
  }

  /// VPN 活跃期间用户拨动开关：仅记录"VPN 断开后是否启用"的意图，
  /// 不改动实际设置、不立即生效（UI 与功能分离）。
  Future<void> setDohSuppressed(bool wantEnabled) async {
    if (wantEnabled) {
      await _prefs.setBool(_keySuppressedDoh, true);
    } else {
      await _prefs.remove(_keySuppressedDoh);
    }
    _bumpSuppression();
  }

  Future<void> setProxySuppressed(bool wantEnabled) async {
    if (wantEnabled) {
      await _prefs.setBool(_keySuppressedProxy, true);
    } else {
      await _prefs.remove(_keySuppressedProxy);
    }
    _bumpSuppression();
  }
}
