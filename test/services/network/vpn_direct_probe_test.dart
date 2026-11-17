import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 安卓「自动」判定下，加速让不让路按实测（系统网络能否直连论坛），不只看 VPN 网卡。
/// 2026-11 佬友反馈：路由器分流的手机没有 VPN 网卡却能直连；Tailscale 有网卡却不翻墙
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wifi = [ConnectivityResult.wifi];
  const wifiVpn = [ConnectivityResult.wifi, ConnectivityResult.vpn];
  const mobile = [ConnectivityResult.mobile];
  const none = [ConnectivityResult.none];

  late SharedPreferences prefs;
  late VpnAutoToggleService toggle;
  final probed = <Uri>[];
  Future<bool> Function() answer = () async => false;

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    VpnAutoToggleService.probeSupportedOverride = true;
    VpnAutoToggleService.probeDelay = Duration.zero;
    probed.clear();
    VpnAutoToggleService.directProber = (url) {
      probed.add(url);
      return answer();
    };
    toggle = VpnAutoToggleService.instance..initialize(prefs);
    // 单例：先回到「无网络」，把上一个用例的网络形态清掉
    await toggle.syncInitialState(none);
    await settle();
  });

  tearDown(() {
    VpnAutoToggleService.probeSupportedOverride = null;
    VpnAutoToggleService.directProber = VpnAutoToggleService.probeDirect;
    VpnAutoToggleService.probeDelay = const Duration(milliseconds: 1500);
  });

  test('Tailscale 一类：有 VPN 网卡但实测连不上 → 先按网卡让路，测完恢复加速', () async {
    answer = () async => false;
    await toggle.syncInitialState(wifiVpn);
    // 没有缓存：初值按 VPN 网卡（旧行为）
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    await settle();
    expect(probed.single.path, '/srv/status');
    expect(toggle.directReachableNotifier.value, isFalse);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
    expect(toggle.vpnActive, isTrue);
    expect(toggle.locksAcceleration, isFalse);
  });

  test('路由器分流一类：没有 VPN 网卡但实测能直连 → 让路', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    await settle();
    expect(toggle.directReachableNotifier.value, isTrue);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.isDohSuppressed, isTrue);
    expect(toggle.vpnActive, isFalse);
    expect(toggle.locksAcceleration, isTrue);
  });

  test('同一网络再启动：先用上次实测结果，不等这次测完', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    // 重启：这次实测一直不回来
    final never = Completer<bool>();
    answer = () => never.future;
    await toggle.syncInitialState(none);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.directReachableNotifier.value, isNull);
  });

  test('换网作废旧结果：Wi-Fi 能直连，换到流量测出不能 → 恢复加速', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    answer = () async => false;
    toggle.handleConnectivityChanged(mobile);
    await settle();
    expect(toggle.directReachableNotifier.value, isFalse);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('同一形态的重复网络事件不重测', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    toggle.handleConnectivityChanged(wifi);
    toggle.handleConnectivityChanged(wifi);
    await settle();
    expect(probed, hasLength(1));
  });

  test('实测能直连但实际一直连不上 → 恢复加速，并把这个网络记成不能直连', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    expect(await toggle.resumeAccelerationForVpn('test'), isTrue);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.directReachableNotifier.value, isFalse);

    // 下次启动同一网络：缓存是「不能」，直接保持加速
    final never = Completer<bool>();
    answer = () => never.future;
    await toggle.syncInitialState(none);
    await settle();
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('强制档不实测：强制非 VPN 时即使能直连也保持加速', () async {
    answer = () async => true;
    await toggle.setDetectionMode(VpnDetectionMode.forceInactive);
    await toggle.syncInitialState(wifiVpn);
    await settle();
    expect(probed, isEmpty);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    await toggle.setDetectionMode(VpnDetectionMode.automatic);
    await settle();
  });
}
