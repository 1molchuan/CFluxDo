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
}
