import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_app_dirs.dart';

void main() {
  group('cfluxdo 加速服务器', () {
    test('随机子域名为 12 位小写字母或数字', () {
      final random = Random(42);
      for (var i = 0; i < 200; i++) {
        final value = generateAccelSubdomain(random);
        expect(value, hasLength(12));
        expect(isValidAccelSubdomain(value), isTrue, reason: value);
      }
    });

    test('每次安装生成的子域名不同', () {
      final values = {for (var i = 0; i < 100; i++) generateAccelSubdomain()};
      expect(values, hasLength(100));
    });

    test('格式不对的子域名会被拒绝', () {
      for (final value in [
        '',
        'abc',
        'ABCDEFGHIJKL',
        'abcdefghijk-',
        'abcdefghijklm',
        'abc.efghijkl',
      ]) {
        expect(isValidAccelSubdomain(value), isFalse, reason: value);
      }
    });

    test('服务器地址与备用节点', () {
      final server = buildAccelDohServer('abcdef123456');
      expect(server.name, accelDohServerName);
      expect(server.url, 'https://abcdef123456.wq.1molchuan.top/v1/lookup');
      expect(server.bootstrapIps, accelDohBootstrapIps);
      expect(server.bootstrapIps, hasLength(4));
      expect(server.isCustom, isFalse);
    });
  });

  group('NetworkSettingsService 默认值', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late Directory appDirs;

    setUpAll(() => appDirs = useTempAppDirs());

    test('首次启动：默认开启 DoH、选中加速服务器；代理起不来时改为直连', () async {
      SharedPreferences.setMockInitialValues({'doh_proxy_port': 45678});
      final prefs = await SharedPreferences.getInstance();
      final service = NetworkSettingsService.instance;

      await service.initialize(prefs);

      final subdomain = prefs.getString('doh_accel_subdomain');
      expect(subdomain, isNotNull);
      expect(isValidAccelSubdomain(subdomain!), isTrue);

      final current = service.current;
      expect(current.dohEnabled, isTrue);
      expect(
        current.selectedServerUrl,
        'https://$subdomain.wq.1molchuan.top/v1/lookup',
      );
      expect(service.servers.first.name, accelDohServerName);
      expect(service.servers.first.url, current.selectedServerUrl);

      // 本机没编过 core/doh_proxy 时没有代理可执行文件，启动失败：端口要被清掉，HTTP 走直连
      if (service.lastStartFailed) {
        expect(current.proxyPort, isNull);
        expect(prefs.getInt('doh_proxy_port'), isNull);
      } else {
        expect(current.proxyPort, isNotNull);
      }
    });

    // 代理能起来时要关掉，不然测试结束后进程会留下
    tearDownAll(() async {
      await DohProxyService.instance.stop();
      appDirs.deleteSync(recursive: true);
    });
  });
}
