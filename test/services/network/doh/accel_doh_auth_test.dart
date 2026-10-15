import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/network/doh/accel_doh_api.dart';
import 'package:fluxdo/services/network/doh/accel_doh_auth_service.dart';
import 'package:fluxdo/services/network/doh/connect_code_flow.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_token_fakes.dart';

/// 假的加速服务端：换码默认发 connect-token（7 天），续期一律 500
class _FakeServer extends FakeTokenServer {
  _FakeServer() : super(AccelDohApi.policy) {
    issue('connect-token');
  }

  int get startCalls => count(policy.startPath);
  int get refreshCalls => count(policy.refreshPath!);
  String? get lastCode => lastCall(policy.tokenPath)?.body?['code'] as String?;
  String? get lastState =>
      lastCall(policy.tokenPath)?.body?['state'] as String?;

  void issue(String token) => respond(policy.tokenPath, 200, {
    'token': token,
    'expires_in': const Duration(days: 7).inSeconds,
  });
}

/// 授权说明：null 表示现在弹不了窗
class _FakeConsent {
  bool? answer;
  int asks = 0;

  Future<bool?> ask() async {
    asks++;
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例在同一个文件里共享状态，下面的用例按顺序执行
  group('加速 DoH 账号令牌（Connect 核验）', () {
    late SharedPreferences prefs;
    final auth = AccelDohAuthService.instance;
    final service = NetworkSettingsService.instance;
    final api = _FakeServer();
    final flow = FakeConnectFlow();
    final consent = _FakeConsent();
    final sleeps = <Duration>[];

    late DohServer accelServer;

    String activeUrl() => service.latencyTestTarget(accelServer).url;
    String? activeToken() => service.latencyTestTarget(accelServer).authToken;

    setUpAll(() async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'doh_accel_token': jsonEncode({
          'token': 'stored-token',
          'user_id': 7,
          'issued_at': now.millisecondsSinceEpoch,
          'expires_at': now.add(const Duration(days: 7)).millisecondsSinceEpoch,
        }),
        'doh_accel_member': true,
        'doh_accel_consent': jsonEncode({'user_id': 7, 'granted': true}),
        'doh_accel_last_connect': jsonEncode({
          'user_id': 7,
          'at': now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
        }),
        // 旧版自报身份的令牌，启动时要被清掉
        'doh_accel_auth': '{"token":"old"}',
      });
      prefs = await SharedPreferences.getInstance();
      auth
        ..debugTransport = api.transport()
        ..debugConnectFlow = flow
        ..debugAskConsent = consent.ask
        ..debugSleep = (delay) async {
          sleeps.add(delay);
        }
        ..consentPromptDelay = Duration.zero
        ..rejectCooldown = Duration.zero;
      await service.initialize(prefs);
      accelServer = service.servers.first;
    });

    // 本机编过代理可执行文件时会真的起进程：等防抖的重启跑完再关，免得留下进程
    tearDownAll(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      while (service.isApplying.value) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await DohProxyService.instance.stop();
    });

    test('冷启动读回已存的令牌，直接走专属加速', () async {
      await pumpEventQueue();
      expect(prefs.getString('doh_accel_auth'), isNull);
      expect(auth.token, 'stored-token');
      expect(auth.status, AccelDohAuthStatus.ready);
      expect(service.current.selectedServerUrl, service.accelServerUrl);
      expect(service.accelFallbackHint, isNull);
      expect(activeUrl(), service.accelServerUrl);
      expect(activeToken(), 'stored-token');
    });

    test('同一账号拿到用户信息后不重新授权', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 2));
      await pumpEventQueue();
      expect(auth.token, 'stored-token');
      expect(api.startCalls, 0);
      expect(api.refreshCalls, 0);
    });

    test('会话失效（用户变成 null）不动令牌', () async {
      auth.onUserChanged(null);
      await pumpEventQueue();
      expect(auth.token, 'stored-token');
    });

    test('令牌被收回、上次授权已过很久：马上重新走 Connect', () async {
      await auth.handleRejected();
      await pumpEventQueue();
      expect(api.startCalls, 1);
      expect(api.lastCode, 'the-code');
      expect(api.lastState, 'the-state');
      expect(auth.token, 'connect-token');
      expect(auth.status, AccelDohAuthStatus.ready);
      expect(activeToken(), 'connect-token');
      final last = jsonDecode(prefs.getString('doh_accel_last_connect')!);
      expect(
        DateTime.now().millisecondsSinceEpoch - (last['at'] as int),
        lessThan(const Duration(minutes: 1).inMilliseconds),
      );
    });

    test('等级降到 0：作废令牌，改走公共加速（不落 DNSPod）', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 0));
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(auth.isMember, isFalse);
      expect(auth.status, AccelDohAuthStatus.notEligible);
      expect(api.revoked, contains('connect-token'));
      expect(prefs.getString('doh_accel_token'), isNull);
      // 等级回升后不受 6 小时限制
      expect(prefs.getString('doh_accel_last_connect'), isNull);
      expect(service.current.selectedServerUrl, service.accelServerUrl);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(activeToken(), isNull);
      expect(service.accelFallbackHint, contains('公共加速'));
    });

    test('等级回到 1、之前同意过：自动走 Connect 换到新令牌', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 1));
      await pumpEventQueue();
      expect(api.startCalls, 2);
      expect(auth.token, 'connect-token');
      expect(auth.status, AccelDohAuthStatus.ready);
      expect(activeUrl(), service.accelServerUrl);
      expect(activeToken(), 'connect-token');
    });

    test('刚授权不久令牌就被收回：不自动抢回来，走公共加速；手动授权不受限', () async {
      await auth.handleRejected();
      await pumpEventQueue();
      expect(api.startCalls, 2);
      expect(auth.token, isNull);
      expect(auth.status, AccelDohAuthStatus.displaced);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(activeToken(), isNull);
      expect(service.accelFallbackHint, contains('3 台'));
      final backoff = jsonDecode(prefs.getString('doh_accel_backoff')!);
      expect(backoff['reason'], 'displaced');

      // 手动授权照样走 Connect；这次服务端拒绝了（比如 3 台都在用）
      api.respond(api.policy.tokenPath, 403);
      final status = await auth.authorizeNow();
      expect(api.startCalls, 3);
      expect(status, AccelDohAuthStatus.denied);
      expect(auth.token, isNull);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(service.accelFallbackHint, contains('拒绝'));
      final denied = jsonDecode(prefs.getString('doh_accel_backoff')!);
      expect(denied['reason'], 'denied');
    });

    test('换成用不了 Connect 的账号（青春版）：同意后仍走公共加速', () async {
      consent.answer = true;
      flow.result = const ConnectCodeResult.unavailable();
      final asksBefore = consent.asks;
      auth.onUserChanged(User(id: 8, username: 'bob', trustLevel: 1));
      await pumpEventQueue();
      expect(consent.asks, asksBefore + 1);
      expect(auth.token, isNull);
      expect(auth.status, AccelDohAuthStatus.unavailable);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(service.accelFallbackHint, contains('无法使用 Connect'));
    });

    test('选了暂不：走公共加速；之后在设置里手动授权就切到专属加速', () async {
      consent.answer = false;
      flow.result = const ConnectCodeResult.code('code-9', 'state-9');
      api.issue('token-9');
      final startsBefore = api.startCalls;
      auth.onUserChanged(User(id: 9, username: 'carol', trustLevel: 3));
      await pumpEventQueue();
      expect(auth.status, AccelDohAuthStatus.notAuthorized);
      expect(api.startCalls, startsBefore);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(service.accelFallbackHint, contains('未授权'));

      consent.answer = true;
      final status = await auth.authorizeNow();
      expect(status, AccelDohAuthStatus.ready);
      expect(api.lastCode, 'code-9');
      expect(auth.token, 'token-9');
      expect(activeUrl(), service.accelServerUrl);
      expect(activeToken(), 'token-9');
    });

    test('主动退出：作废令牌、清掉授权记录，改回公共加速', () async {
      await auth.revoke();
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(auth.isMember, isFalse);
      expect(auth.status, AccelDohAuthStatus.notEligible);
      expect(api.revoked, contains('token-9'));
      expect(prefs.getString('doh_accel_consent'), isNull);
      expect(prefs.getBool('doh_accel_member'), isNull);
      expect(prefs.getString('doh_accel_last_connect'), isNull);
      expect(activeUrl(), accelDohPublicServer.url);
    });

    test('网络类失败：后台自动授权只走一次，菜单里手动授权整条链路重来 2 次', () async {
      api.calls.clear();
      api.reply(
        api.policy.startPath,
        (_) => throw const SocketException('offline'),
      );
      consent.answer = true;
      auth.onUserChanged(User(id: 10, username: 'dave', trustLevel: 2));
      await pumpEventQueue();
      // 同意后的自动授权：失败交给原来的退避（1 分钟后再试），不在这里重来
      expect(api.startCalls, 1);
      expect(sleeps, isEmpty);
      expect(auth.status, AccelDohAuthStatus.pending);

      final status = await auth.authorizeNow();
      expect(api.startCalls, 4);
      expect(sleeps, const [Duration(seconds: 2), Duration(seconds: 4)]);
      expect(status, AccelDohAuthStatus.pending);
      expect(auth.token, isNull);

      // 网络恢复后再点一次：成功
      api.respond(api.policy.startPath, 200, {
        'authorize_url': FakeTokenServer.authorizeUrl,
      });
      api.issue('token-10');
      expect(await auth.authorizeNow(), AccelDohAuthStatus.ready);
      expect(auth.token, 'token-10');
    });
  });
}
