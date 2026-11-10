import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../app_logger.dart';
import '../local_notification_service.dart';
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
/// 检测到 VPN 开启时自动关闭 DOH 和上游代理，VPN 关闭后自动恢复。
/// 采用"压制标记"模式：通过 SharedPreferences 标记哪些项是被 VPN 自动关闭的，
/// VPN 关闭后根据标记恢复，不修改 NetworkSettingsService / ProxySettingsService 内部逻辑。
///
/// 让路期间论坛一直连不上时，本次 VPN 期间恢复连接加速（见 [reportForumTransport]）。
class VpnAutoToggleService {
  VpnAutoToggleService._();
  static final VpnAutoToggleService instance = VpnAutoToggleService._();

  static const _keyEnabled = 'vpn_auto_toggle_enabled';
  static const _keySuppressedDoh = 'vpn_suppressed_doh';
  static const _keySuppressedProxy = 'vpn_suppressed_proxy';
  static const _keyDetectionMode = 'vpn_detection_mode';
  static const _keyAccelResumed = 'vpn_accel_resumed';

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

  /// 防重入标记
  bool _isSuppressing = false;

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

  bool get enabled => enabledNotifier.value;
  bool get vpnActive => vpnActiveNotifier.value;
  VpnDetectionMode get detectionMode => detectionModeNotifier.value;
  bool get accelResumed => accelResumedNotifier.value;

  /// 连接加速开关此刻由让路接管（拨动只记 VPN 断开后的意图）：VPN 连着、
  /// 且本次没有因连不上论坛恢复加速
  bool get locksAcceleration => enabled && vpnActive && !accelResumed;

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
      await _restore();
    } else if (_shouldSuppress) {
      // 开启功能且当前 VPN 活跃，立即压制
      await _suppress();
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
  }

  /// 由 ConnectivityService 调用
  void handleConnectivityChanged(List<ConnectivityResult> results) {
    _lastConnectivityResults = results;
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

    if (!enabled) return;

    if (effectiveShouldSuppress) {
      _suppress();
    } else {
      _restore();
    }
  }

  void _applyLastKnownState() {
    _applyVpnState(
      resolveVpnActive(
        connectivityResults: _lastConnectivityResults,
        hasWindowsVpnAdapter: _lastHasWindowsVpnAdapter,
        systemProxyEnabled: Platform.isWindows &&
            SystemProxyService.instance.effectiveProxyUrl != null,
      ),
      shouldSuppress: shouldAutoSuppress(_lastConnectivityResults),
    );
  }

  /// 启动时同步一次 VPN 状态，避免首个请求发出后再切换网络配置。
  Future<void> syncInitialState(List<ConnectivityResult> results) async {
    _lastConnectivityResults = results;
    _ensureWindowsSignalWatch();
    final hasWindowsVpnAdapter = Platform.isWindows
        ? (await WindowsVpnAdapterDetector.detect()).active
        : false;
    _lastHasWindowsVpnAdapter = hasWindowsVpnAdapter;
    final hasVpn = resolveVpnActive(
      connectivityResults: results,
      hasWindowsVpnAdapter: hasWindowsVpnAdapter,
      systemProxyEnabled: Platform.isWindows &&
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

    if (!enabled) return;
    if (_shouldSuppress) {
      await _suppress();
    } else {
      await _restore();
    }
  }

  /// VPN 开启时压制 DOH 和代理
  Future<void> _suppress() async {
    if (_isSuppressing) return;
    _isSuppressing = true;

    try {
      final dohService = NetworkSettingsService.instance;
      final proxyService = ProxySettingsService.instance;

      // 检查 DOH 是否开启，开启则压制。冷启动时网络设置还没初始化（还没起代理）：
      // 直接改偏好，初始化时就按关着来，不用先起代理再关掉。
      // 本次 VPN 期间已因连不上论坛恢复了加速的，不再暂停
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
        debugPrint('[VpnAutoToggle] 压制 DOH');
      }

      // 检查代理是否开启，开启则压制
      if (proxyService.notifier.value.enabled) {
        await _prefs.setBool(_keySuppressedProxy, true);
        await proxyService.setEnabled(false);
        debugPrint('[VpnAutoToggle] 压制上游代理');
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
  }

  /// VPN 关闭后恢复被压制的项
  Future<void> _restore() async {
    if (_isSuppressing) return;
    _isSuppressing = true;

    try {
      // 「本次 VPN 期间已恢复加速」到此为止：下次连 VPN 照常先让路
      _resetUnreachableWatch();
      if (accelResumed) {
        accelResumedNotifier.value = false;
        await _prefs.remove(_keyAccelResumed);
        debugPrint('[VpnAutoToggle] 清除本次 VPN 期间恢复加速的记号');
      }

      // 恢复 DOH（冷启动时网络设置还没初始化：直接改偏好）
      if (isDohSuppressed) {
        await _prefs.remove(_keySuppressedDoh);
        final dohService = NetworkSettingsService.instance;
        if (dohService.isInitialized) {
          await dohService.setDohEnabled(true);
        } else {
          await NetworkSettingsService.storeDohEnabled(_prefs, true);
        }
        debugPrint('[VpnAutoToggle] 恢复 DOH');
      }

      // 恢复代理
      if (isProxySuppressed) {
        await _prefs.remove(_keySuppressedProxy);
        await ProxySettingsService.instance.setEnabled(true);
        debugPrint('[VpnAutoToggle] 恢复上游代理');
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
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
      enabled && _shouldSuppress && !accelResumed && isDohSuppressed;

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
