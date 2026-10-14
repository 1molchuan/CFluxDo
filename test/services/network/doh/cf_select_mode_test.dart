import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';

void main() {
  group('CfSelectMode', () {
    test('wire 往返', () {
      expect(CfSelectMode.localAtlas.wire, 'local_atlas');
      expect(CfSelectMode.atlasOnly.wire, 'atlas_only');
      for (final mode in CfSelectMode.values) {
        expect(CfSelectMode.fromWire(mode.wire), mode);
      }
    });

    test('非法 / 空值回落到 localAtlas', () {
      expect(CfSelectMode.fromWire(null), CfSelectMode.localAtlas);
      expect(CfSelectMode.fromWire(''), CfSelectMode.localAtlas);
      expect(CfSelectMode.fromWire('bogus'), CfSelectMode.localAtlas);
      // 大小写敏感，别把手改的值当合法
      expect(CfSelectMode.fromWire('ATLAS_ONLY'), CfSelectMode.localAtlas);
    });
  });

  group('NetworkSettings 的优选字段', () {
    const base = NetworkSettings(
      dohEnabled: true,
      selectedServerUrl: 'https://doh.pub/dns-query',
      customServers: [],
      proxyPort: 1080,
    );

    test('默认 localAtlas、不上报', () {
      expect(base.selectMode, CfSelectMode.localAtlas);
      expect(base.shareMeasurements, isFalse);
    });

    test('copyWith 只改指定字段，其余原样保留', () {
      final changed = base.copyWith(
        selectMode: CfSelectMode.atlasOnly,
        shareMeasurements: true,
      );
      expect(changed.selectMode, CfSelectMode.atlasOnly);
      expect(changed.shareMeasurements, isTrue);
      expect(changed.dohEnabled, base.dohEnabled);
      expect(changed.selectedServerUrl, base.selectedServerUrl);
      expect(changed.proxyPort, base.proxyPort);

      // 不传就沿用（_touch() 靠空 copyWith 触发监听，字段不能丢）
      final untouched = changed.copyWith();
      expect(untouched.selectMode, CfSelectMode.atlasOnly);
      expect(untouched.shareMeasurements, isTrue);

      final other = changed.copyWith(dohEnabled: false);
      expect(other.selectMode, CfSelectMode.atlasOnly);
      expect(other.shareMeasurements, isTrue);
      expect(other.dohEnabled, isFalse);
    });
  });
}
