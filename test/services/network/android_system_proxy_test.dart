import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 安卓系统 HTTP 代理（Wi-Fi 代理 / VPN 下发）与自动让路的配合。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<Object?, Object?>? reading;

  setUp(() {
    reading = null;
    SystemProxyService.isAndroidOverride = true;
    SystemProxyService.androidReaderOverride = () async => reading;
    SystemProxyService.instance.resetForTest();
  });

  tearDown(() {
    SystemProxyService.isAndroidOverride = null;
    SystemProxyService.androidReaderOverride = null;
    SystemProxyService.instance.resetForTest();
  });

  test('读到固定代理：网关上游地址可用，诊断只记类别不记地址', () async {
    reading = {'host': '127.0.0.1', 'port': 7890, 'exclusions': <String>[]};
    final versionBefore = SystemProxyService.instance.version.value;
    await SystemProxyService.instance.ready();

    expect(
      SystemProxyService.instance.effectiveProxyUrl,
      'http://127.0.0.1:7890',
    );
    expect(SystemProxyService.instance.isEnabled, isTrue);
    expect(
      SystemProxyService.instance.version.value,
      greaterThan(versionBefore),
    );
    expect(
      SystemProxyService.describe(SystemProxyService.instance.registryConfig),
      'http@loopback',
    );
  });

  test('开着系统代理：算作要实测的网络，签名单独一份（实测缓存不和不开代理时混用）', () async {
    reading = {'host': '192.168.1.5', 'port': 3128};
    await SystemProxyService.instance.ready();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final toggle = VpnAutoToggleService.instance
      ..resetForTest()
      ..initialize(prefs);

    await toggle.syncInitialState([ConnectivityResult.wifi]);

    final d = toggle.diagnostics();
    expect(d['networkSig'], 'wifi+sysproxy');
    expect(d['vpnActive'], isTrue);
    expect(d['shouldSuppress'], isFalse, reason: '应用内上游代理只随 VPN 网卡压制');
    expect(d['systemProxy'], 'http@lan');

    // 关掉代理：签名回到普通 Wi-Fi
    reading = const {};
    SystemProxyService.instance.refresh();
    await SystemProxyService.instance.ready();
    expect(toggle.diagnostics()['networkSig'], 'wifi');
    expect(toggle.diagnostics()['vpnActive'], isFalse);
  });

  test('实测经系统代理走：代理收到的是到论坛的 CONNECT', () async {
    // 测试绑定会把 HttpClient 换成一律回 400 的假货，这里要真连
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final firstLine = Completer<String>();
    server.listen((socket) {
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .then((line) {
            if (!firstLine.isCompleted) firstLine.complete(line);
            socket.destroy();
          }, onError: (_) {});
    });
    addTearDown(server.close);
    reading = {'host': '127.0.0.1', 'port': server.port};
    await SystemProxyService.instance.ready();

    final result = await VpnAutoToggleService.probeDirect(
      Uri.https('linux.do', '/srv/status'),
    );

    expect(await firstLine.future, startsWith('CONNECT linux.do:443'));
    expect(result, isNot(DirectProbeResult.reachable));
  });

  test('后台引擎没有这个通道：当成没有系统代理', () async {
    SystemProxyService.androidReaderOverride = null; // 走真通道 → MissingPlugin
    await SystemProxyService.instance.ready();
    expect(SystemProxyService.instance.isEnabled, isFalse);
    expect(SystemProxyService.instance.effectiveProxyUrl, isNull);
  });
}
