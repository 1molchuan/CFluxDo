import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「IP 协议」设置：老版本只有「IPv6 优先」开关，迁移规则见 [NetworkSettingsService.loadIpv6Mode]
void main() {
  Future<Ipv6Mode> load(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return NetworkSettingsService.loadIpv6Mode(
      await SharedPreferences.getInstance(),
    );
  }

  test('从没碰过开关的默认自动', () async {
    expect(await load({}), Ipv6Mode.auto);
  });

  test('开过「IPv6 优先」的保持 IPv6 优先，明确关掉过的保持 IPv4 优先', () async {
    expect(await load({'doh_prefer_ipv6': true}), Ipv6Mode.preferV6);
    expect(await load({'doh_prefer_ipv6': false}), Ipv6Mode.preferV4);
  });

  test('新设置优先于老开关，认不出的值回落到迁移规则', () async {
    expect(
      await load({'doh_ipv6_mode': 'auto', 'doh_prefer_ipv6': false}),
      Ipv6Mode.auto,
    );
    expect(await load({'doh_ipv6_mode': 'v4'}), Ipv6Mode.preferV4);
    expect(await load({'doh_ipv6_mode': 'v6'}), Ipv6Mode.preferV6);
    expect(await load({'doh_ipv6_mode': 'bogus'}), Ipv6Mode.auto);
  });

  test('传给 Rust 的两个开关', () {
    const base = NetworkSettings(
      dohEnabled: true,
      selectedServerUrl: 'https://edge.example/dns-query',
      customServers: [],
      proxyPort: 0,
    );
    expect(base.ipv6Mode, Ipv6Mode.auto);
    expect(base.ipv6Auto, isTrue);
    expect(base.preferIPv6, isFalse);
    final v6 = base.copyWith(ipv6Mode: Ipv6Mode.preferV6);
    expect(v6.preferIPv6, isTrue);
    expect(v6.ipv6Auto, isFalse);
    final v4 = base.copyWith(ipv6Mode: Ipv6Mode.preferV4);
    expect(v4.preferIPv6, isFalse);
    expect(v4.ipv6Auto, isFalse);
  });
}
