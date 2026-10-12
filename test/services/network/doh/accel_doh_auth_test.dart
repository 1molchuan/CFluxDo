import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/network/doh/accel_doh_auth_service.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例在同一个文件里共享状态，下面的用例按顺序执行
  group('加速 DoH 账号令牌', () {
    late SharedPreferences prefs;
    final auth = AccelDohAuthService.instance;
    final service = NetworkSettingsService.instance;

    setUpAll(() async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'doh_accel_auth': jsonEncode({
          'token': 'test-token',
          'user_id': 7,
          'username': 'alice',
          'trust_level': 2,
          'issued_at': now.millisecondsSinceEpoch,
          'expires_at': now.add(const Duration(days: 7)).millisecondsSinceEpoch,
        }),
      });
      prefs = await SharedPreferences.getInstance();
      await service.initialize(prefs);
    });

    // 本机编过代理可执行文件时会真的起进程，结束要关掉
    tearDownAll(() => DohProxyService.instance.stop());

    test('启动时读回已存的令牌，加速可直接使用', () {
      expect(auth.token, 'test-token');
      expect(service.current.selectedServerUrl, service.accelServerUrl);
      expect(service.isAccelWaitingForAuth, isFalse);
    });

    test('同一账号状态未变时不重新申请，令牌保留', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 2));
      await pumpEventQueue();
      expect(auth.token, 'test-token');
    });

    test('会话失效（用户变成 null）不动令牌', () async {
      auth.onUserChanged(null);
      await pumpEventQueue();
      expect(auth.token, 'test-token');
    });

    test('等级降到 0：丢掉令牌，改用公共 DoH，选择仍是加速', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 0));
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(prefs.getString('doh_accel_auth'), isNull);
      expect(service.current.selectedServerUrl, service.accelServerUrl);
      expect(service.isAccelWaitingForAuth, isTrue);
    });

    test('主动退出后没有令牌', () async {
      await auth.revoke();
      expect(auth.token, isNull);
      expect(service.isAccelWaitingForAuth, isTrue);
    });
  });
}
