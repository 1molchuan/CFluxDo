import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 冷启动在网络设置初始化（起代理）之前同步 VPN 状态：要压制就直接改偏好，
  /// 网络设置初始化时读到的就是压制后的值
  test('起代理前检测到 VPN：直接把 DoH 偏好改成关闭，VPN 断开后恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(NetworkSettingsService.instance.isInitialized, isFalse);
    final toggle = VpnAutoToggleService.instance..initialize(prefs);

    await toggle.syncInitialState([
      ConnectivityResult.wifi,
      ConnectivityResult.vpn,
    ]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.isDohSuppressed, isTrue);

    await toggle.syncInitialState([ConnectivityResult.wifi]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('DoH 本来就关着：不记压制，VPN 断开后也不擅自打开', () async {
    SharedPreferences.setMockInitialValues({'doh_enabled': false});
    final prefs = await SharedPreferences.getInstance();
    final toggle = VpnAutoToggleService.instance..initialize(prefs);

    await toggle.syncInitialState([ConnectivityResult.vpn]);
    expect(toggle.isDohSuppressed, isFalse);
    await toggle.syncInitialState([ConnectivityResult.mobile]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
  });

  group('让路期间论坛一直连不上', () {
    const vpnOn = [ConnectivityResult.wifi, ConnectivityResult.vpn];
    const vpnOff = [ConnectivityResult.wifi];

    /// 让计时器和 prefs 写入都跑完
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('本次 VPN 期间恢复加速，网络变化不再暂停，VPN 断开后清掉记号、下次照常让路', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final toggle = VpnAutoToggleService.instance..initialize(prefs);
      await toggle.syncInitialState(vpnOn);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      expect(toggle.locksAcceleration, isTrue);

      expect(await toggle.resumeAccelerationForVpn('test'), isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
      expect(toggle.isDohSuppressed, isFalse);
      expect(toggle.accelResumed, isTrue);
      expect(toggle.locksAcceleration, isFalse);

      // VPN 还连着时的网络变化（含重启 App 重新同步）不再暂停加速
      await toggle.syncInitialState(vpnOn);
      VpnAutoToggleService.instance.initialize(prefs);
      expect(toggle.accelResumed, isTrue);
      await toggle.syncInitialState(vpnOn);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);

      await toggle.syncInitialState(vpnOff);
      expect(toggle.accelResumed, isFalse);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);

      await toggle.syncInitialState(vpnOn);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      expect(toggle.isDohSuppressed, isTrue);
      await toggle.syncInitialState(vpnOff);
    });

    test('用户自己关的加速：连不上也不擅自打开', () async {
      SharedPreferences.setMockInitialValues({'doh_enabled': false});
      final prefs = await SharedPreferences.getInstance();
      final toggle = VpnAutoToggleService.instance..initialize(prefs);
      await toggle.syncInitialState(vpnOn);

      expect(await toggle.resumeAccelerationForVpn('test'), isFalse);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      expect(toggle.accelResumed, isFalse);
      await toggle.syncInitialState(vpnOff);
    });

    test('连续失败够数且持续够久才恢复，中间拿到响应就作废', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final toggle = VpnAutoToggleService.instance..initialize(prefs);
      var now = DateTime(2026, 11, 10, 8);
      toggle.unreachableStreak = ForumUnreachableStreak(clock: () => now);
      await toggle.syncInitialState(vpnOn);

      // 两次失败后拿到响应：作废
      toggle.reportForumTransport(reachable: false);
      now = now.add(const Duration(seconds: 1));
      toggle.reportForumTransport(reachable: false);
      toggle.reportForumTransport(reachable: true);
      now = now.add(const Duration(seconds: 3));
      toggle.reportForumTransport(reachable: false);
      await settle();
      expect(toggle.accelResumed, isFalse);

      // 再连着两次、跨过 2 秒：恢复
      now = now.add(const Duration(seconds: 1));
      toggle.reportForumTransport(reachable: false);
      now = now.add(const Duration(seconds: 2));
      toggle.reportForumTransport(reachable: false, detail: 'reset');
      await settle();
      expect(toggle.accelResumed, isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);

      await toggle.syncInitialState(vpnOff);
      expect(toggle.accelResumed, isFalse);
    });

    test('一起失败的几个请求要等满 2 秒、期间没拿到响应才算', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final toggle = VpnAutoToggleService.instance..initialize(prefs);
      toggle.unreachableStreak = ForumUnreachableStreak(
        minSpan: const Duration(milliseconds: 40),
      );
      await toggle.syncInitialState(vpnOn);

      for (var i = 0; i < 3; i++) {
        toggle.reportForumTransport(reachable: false);
      }
      toggle.reportForumTransport(reachable: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(toggle.accelResumed, isFalse);

      for (var i = 0; i < 3; i++) {
        toggle.reportForumTransport(reachable: false);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(toggle.accelResumed, isTrue);
      await toggle.syncInitialState(vpnOff);
    });
  });

  group('ForumUnreachableStreak', () {
    test('不够数不算；够数后按持续时间给出还要等多久；超出窗口重新计', () {
      var now = DateTime(2026, 11, 10, 8);
      final streak = ForumUnreachableStreak(clock: () => now);
      expect(streak.recordFailure(), isNull);
      expect(streak.recordFailure(), isNull);
      now = now.add(const Duration(milliseconds: 500));
      expect(streak.recordFailure(), const Duration(milliseconds: 1500));
      now = now.add(const Duration(seconds: 2));
      expect(streak.recordFailure(), Duration.zero);
      expect(streak.confirm(), isTrue);
      expect(streak.confirm(), isFalse);

      expect(streak.recordFailure(), isNull);
      expect(streak.recordFailure(), isNull);
      now = now.add(const Duration(minutes: 2));
      expect(streak.recordFailure(), isNull);
    });
  });
}
