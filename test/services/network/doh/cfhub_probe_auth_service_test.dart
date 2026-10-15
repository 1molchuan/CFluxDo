import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/network/doh/cfhub_api.dart';
import 'package:fluxdo/services/network/doh/cfhub_probe_auth_service.dart';
import 'package:fluxdo/services/network/doh/connect_code_flow.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_token_fakes.dart';

/// 假的 cfhub：换码默认发 cfp_first
class _FakeServer extends FakeTokenServer {
  _FakeServer() : super(CfhubApi.policy) {
    issue('cfp_first');
  }

  int get startCalls => count(policy.startPath);
  String? get lastCode => lastCall(policy.tokenPath)?.body?['code'] as String?;
  String? get lastState =>
      lastCall(policy.tokenPath)?.body?['state'] as String?;

  void issue(String token) =>
      respond(policy.tokenPath, 200, {'token': token});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例在同一个文件里共享状态，下面的用例按顺序执行
  group('cfhub 探针令牌', () {
    late SharedPreferences prefs;
    final service = NetworkSettingsService.instance;
    final api = _FakeServer();
    final flow = FakeConnectFlow();
    final user = ValueNotifier<User?>(null);
    late CfhubProbeAuthService auth;
    final sleeps = <Duration>[];
    void Function()? onSleep;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      CfhubProbeAuthService.resetForTest(
        transport: api.transport(),
        flow: flow,
        userNotifier: user,
        // 重试不真等
        sleep: (delay) async {
          sleeps.add(delay);
          onSleep?.call();
        },
      );
      auth = CfhubProbeAuthService.instance;
      // 网络设置服务初始化时会顺带初始化探针服务
      await service.initialize(prefs);
      auth.initialize(prefs);
    });

    // 本机编过代理可执行文件时会真的起进程：等防抖的重启跑完再关，免得留下进程
    tearDownAll(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      while (service.isApplying.value) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await DohProxyService.instance.stop();
    });

    test('冷启动没有记录：未授权，上报关', () {
      expect(auth.token, isNull);
      expect(auth.isAuthorized, isFalse);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('未登录：不发起 Connect', () async {
      expect(await auth.enable(), CfhubEnableResult.needLogin);
      expect(api.startCalls, 0);
      expect(auth.isAuthorized, isFalse);
    });

    test('信任等级不够：不发起 Connect', () async {
      user.value = User(id: 7, username: 'alice', trustLevel: 0);
      expect(await auth.enable(), CfhubEnableResult.needTrust);
      expect(api.startCalls, 0);
      expect(auth.isAuthorized, isFalse);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('cfhub 未开放（404）：hubUnavailable，上报保持关', () async {
      user.value = User(id: 7, username: 'alice', trustLevel: 2);
      api.respond(api.policy.startPath, 404);
      expect(await auth.enable(), CfhubEnableResult.hubUnavailable);
      expect(api.startCalls, 1);
      expect(auth.token, isNull);
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(service.current.shareMeasurements, isFalse);
      expect(prefs.getBool('doh_select_share'), isFalse);
    });

    test('授权成功：存令牌与账号 id，打开上报', () async {
      api.respond(api.policy.startPath, 200, {
        'authorize_url': FakeTokenServer.authorizeUrl,
      });
      expect(await auth.enable(), CfhubEnableResult.ok);
      expect(api.startCalls, 2);
      expect(api.lastCode, 'the-code');
      expect(api.lastState, 'the-state');
      expect(auth.token, 'cfp_first');
      expect(auth.isAuthorized, isTrue);
      expect(prefs.getString('cfhub_probe_token'), 'cfp_first');
      expect(prefs.getInt('cfhub_probe_user_id'), 7);
      expect(service.current.shareMeasurements, isTrue);
      expect(prefs.getBool('doh_select_share'), isTrue);
    });

    test('已有本账号的令牌再 enable：不重新授权，只把上报打开', () async {
      await service.setShareMeasurements(false);
      expect(service.current.shareMeasurements, isFalse);
      expect(await auth.enable(), CfhubEnableResult.ok);
      expect(api.startCalls, 2);
      expect(auth.token, 'cfp_first');
      expect(service.current.shareMeasurements, isTrue);
    });

    test('cfhub 拒绝令牌：清掉令牌、关上报、提示一次', () async {
      await auth.onRejected();
      expect(auth.rejectedNotifier.value, 1);
      expect(auth.token, isNull);
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(prefs.getInt('cfhub_probe_user_id'), isNull);
      expect(service.current.shareMeasurements, isFalse);
      expect(prefs.getBool('doh_select_share'), isFalse);
      // 轮询重复拿到同一个拒绝标记：不再提示
      await auth.onRejected();
      expect(auth.rejectedNotifier.value, 1);
    });

    test('cfhub 拒绝此账号：rejected，上报关', () async {
      api.respond(api.policy.tokenPath, 403);
      expect(await auth.enable(), CfhubEnableResult.rejected);
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('Connect 没拿到 code：cancelled，上报关', () async {
      api.issue('cfp_second');
      flow.result = const ConnectCodeResult.unavailable();
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
      flow.result = const ConnectCodeResult.code('code-2', 'state-2');
    });

    test('换账号：令牌作废、上报关', () async {
      expect(await auth.enable(), CfhubEnableResult.ok);
      expect(auth.token, 'cfp_second');
      expect(service.current.shareMeasurements, isTrue);

      user.value = User(id: 8, username: 'bob', trustLevel: 2);
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(api.revoked, contains('cfp_second'));
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('登出：令牌作废、上报关', () async {
      api.issue('cfp_third');
      expect(await auth.enable(), CfhubEnableResult.ok);
      expect(prefs.getInt('cfhub_probe_user_id'), 8);

      user.value = null;
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(api.revoked, contains('cfp_third'));
      expect(service.current.shareMeasurements, isFalse);
    });

    test('手动关闭：作废令牌、清记录', () async {
      user.value = User(id: 8, username: 'bob', trustLevel: 2);
      api.issue('cfp_fourth');
      expect(await auth.enable(), CfhubEnableResult.ok);
      await auth.disable();
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(api.revoked, contains('cfp_fourth'));
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(prefs.getInt('cfhub_probe_user_id'), isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('网络类失败：整条链路重来 2 次（2 s / 4 s），提示带上卡在哪一步', () async {
      api.calls.clear();
      api.respond(api.policy.startPath, 403);
      expect(await auth.enable(), CfhubEnableResult.failed);
      expect(api.startCalls, 3);
      expect(sleeps, const [Duration(seconds: 2), Duration(seconds: 4)]);
      expect(auth.lastFailureDetail, 'start HTTP 403');
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
      api.respond(api.policy.startPath, 200, {
        'authorize_url': FakeTokenServer.authorizeUrl,
      });
    });

    test('Connect 期间换号又换回来：结果丢弃，不换码', () async {
      api.calls.clear();
      api.issue('cfp_aba');
      flow.onFetch = () {
        user.value = User(id: 9, username: 'carol', trustLevel: 2);
        user.value = User(id: 8, username: 'bob', trustLevel: 2);
      };
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      flow.onFetch = null;
      expect(api.count(api.policy.tokenPath), 0);
      expect(auth.token, isNull);
      expect(auth.lastFailureDetail, isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('换码期间登出又登回同一账号：结果丢弃，刚拿到的令牌作废', () async {
      api.calls.clear();
      api.once(api.policy.tokenPath, (_) {
        user.value = null;
        user.value = User(id: 8, username: 'bob', trustLevel: 2);
        return (200, '{"token":"cfp_relogin"}');
      });
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(api.revoked, contains('cfp_relogin'));
      expect(service.current.shareMeasurements, isFalse);
    });

    test('重试前的等待期间换了号：不再重来', () async {
      api.calls.clear();
      api.reply(api.policy.startPath, (_) => throw const SocketException('x'));
      onSleep = () => user.value = User(id: 9, username: 'carol', trustLevel: 2);
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      onSleep = null;
      expect(api.startCalls, 1);
      expect(auth.token, isNull);
      api.respond(api.policy.startPath, 200, {
        'authorize_url': FakeTokenServer.authorizeUrl,
      });
    });

    test('开启途中关掉：结果丢弃，上报保持关', () async {
      api.calls.clear();
      api.issue('cfp_late');
      flow.onFetch = () => auth.disable();
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      flow.onFetch = null;
      expect(api.count(api.policy.tokenPath), 0);
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('作废还没落地时重新开启：先等作废，再取授权地址', () async {
      api.issue('cfp_fifth');
      expect(await auth.enable(), CfhubEnableResult.ok);
      final gate = api.hold(api.policy.revokePath);
      api.calls.clear();
      await auth.disable();
      api.issue('cfp_sixth');
      final enabling = auth.enable();
      await pumpEventQueue();
      expect(api.startCalls, 0);
      gate.complete();
      expect(await enabling, CfhubEnableResult.ok);
      expect(api.paths, [
        api.policy.revokePath,
        api.policy.startPath,
        api.policy.tokenPath,
      ]);
      expect(api.revoked, ['cfp_fifth']);
      expect(auth.token, 'cfp_sixth');
    });
  });
}
