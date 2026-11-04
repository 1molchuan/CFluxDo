import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/rhttp_adapter.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';
import 'package:fluxdo/services/network/rhttp/rhttp_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _options = RequestOptions(path: 'https://linux.do/latest.json');

NetworkSettings _networkSettings() => const NetworkSettings(
  dohEnabled: true,
  selectedServerUrl: 'https://edge.example/dns-query',
  customServers: [],
  proxyPort: 18080,
);

/// rhttp 直连的 ECH 钥匙过期：识别、取 retry_configs、临时回退网关
void main() {
  group('RhttpAdapter.isEchSuspect', () {
    test('rhttp_plus 明确报的 ECH 被拒算', () {
      final error = DioException.connectionError(
        requestOptions: _options,
        reason:
            '${RhttpAdapter.echRejectedPrefix}none: Some(hyper_util::client::legacy::Error(Connect, ...))',
      );
      expect(RhttpAdapter.isEchSuspect(error, echEnabled: true), isTrue);
    });

    test('老 rustls 伪装成的证书域名错误算（证书只对 cloudflare-ech.com 有效）', () {
      final error = DioException.badCertificate(
        requestOptions: _options,
        error: Exception(
          'RhttpInvalidCertificateError: Custom { kind: InvalidData, error: '
          'InvalidCertificate(NotValidForName) }',
        ),
      );
      expect(RhttpAdapter.isEchSuspect(error, echEnabled: true), isTrue);
    });

    test('没开 ECH 的连接出证书错误不算：那是真的证书问题', () {
      final error = DioException.badCertificate(
        requestOptions: _options,
        error: Exception('InvalidCertificate(NotValidForName)'),
      );
      expect(RhttpAdapter.isEchSuspect(error, echEnabled: false), isFalse);
    });

    test('普通连接超时 / 被重置不算', () {
      expect(
        RhttpAdapter.isEchSuspect(
          DioException.connectionTimeout(
            requestOptions: _options,
            timeout: const Duration(seconds: 5),
          ),
          echEnabled: true,
        ),
        isFalse,
      );
      expect(
        RhttpAdapter.isEchSuspect(
          DioException.connectionError(
            requestOptions: _options,
            reason: 'Connection reset by peer',
          ),
          echEnabled: true,
        ),
        isFalse,
      );
    });
  });

  group('RhttpAdapter.echRetryConfigsFrom', () {
    test('取出服务端随拒绝下发的新钥匙', () {
      final key = List<int>.generate(71, (i) => i);
      final error = DioException.connectionError(
        requestOptions: _options,
        reason:
            '${RhttpAdapter.echRejectedPrefix}${base64Encode(key)}: Some(...)',
      );
      expect(RhttpAdapter.echRetryConfigsFrom(error), key);
    });

    test('没有 retry_configs 或不是 ECH 错误时为 null', () {
      expect(
        RhttpAdapter.echRetryConfigsFrom(
          DioException.connectionError(
            requestOptions: _options,
            reason: '${RhttpAdapter.echRejectedPrefix}none: x',
          ),
        ),
        isNull,
      );
      expect(RhttpAdapter.echRetryConfigsFrom(Exception('timed out')), isNull);
    });
  });

  group('RhttpSettingsService 临时回退', () {
    late RhttpSettingsService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'rhttp_enabled': true});
      service = RhttpSettingsService.instance..resetForTest();
      await service.initialize(await SharedPreferences.getInstance());
    });

    test('回退期内不选 rhttp，到点自动恢复', () async {
      final ns = _networkSettings();
      final ps = const ProxySettings();
      expect(service.shouldUseRhttp(ns, ps), isTrue);

      final version = service.version;
      service.degradeTemporarily(
        const Duration(milliseconds: 50),
        reason: 'ECH rejected',
      );
      expect(service.shouldUseRhttp(ns, ps), isFalse);
      expect(service.current.isDegraded, isTrue);
      expect(service.current.degradeReason, 'ECH rejected');
      // 设置版本号变了，适配器会按新选择重建
      expect(service.version, version + 1);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.current.isDegraded, isFalse);
      expect(service.shouldUseRhttp(ns, ps), isTrue);
    });

    test('回退期内再次回退只延长，不重复触发重建', () {
      service.degradeTemporarily(const Duration(minutes: 1), reason: 'a');
      final version = service.version;
      service.degradeTemporarily(const Duration(minutes: 5), reason: 'b');
      expect(service.version, version);
      expect(service.current.degradeReason, 'b');
      expect(
        service.current.degradedUntil!.isAfter(
          DateTime.now().add(const Duration(minutes: 4)),
        ),
        isTrue,
      );
    });

    test('手动结束回退', () {
      service.degradeTemporarily(const Duration(minutes: 5), reason: 'a');
      service.clearDegrade();
      expect(service.current.isDegraded, isFalse);
      expect(service.current.degradeReason, isNull);
    });
  });
}
