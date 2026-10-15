import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/network/doh/accel_doh_connect_flow.dart';
import 'package:fluxdo/services/network/doh/cfhub_api.dart';
import 'package:fluxdo/services/network/doh/cfhub_probe_auth_service.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的 cfhub：记录调用，按设定返回
class _FakeApi implements CfhubApi {
  @override
  String? lastFailure;

  int startCalls = 0;
  CfhubStartResult startResult = CfhubStartResult.ok(
    Uri.parse('https://connect.linux.do/oauth2/authorize?client_id=x'),
  );
  CfhubTokenResult tokenResult = const CfhubTokenResult.ok('cfp_first');
  String? lastCode;
  String? lastState;
  final List<String> revoked = [];

  @override
  Future<CfhubStartResult> startConnect() async {
    startCalls++;
    return startResult;
  }

  @override
  Future<CfhubTokenResult> exchangeCode(String code, String state) async {
    lastCode = code;
    lastState = state;
    return tokenResult;
  }

  @override
  Future<void> revoke(String token) async => revoked.add(token);
}

/// 假的 Connect 授权：不弹窗、不发请求
class _FakeConnectFlow implements AccelDohConnectFlow {
  AccelDohConnectResult result = const AccelDohConnectResult.code(
    'the-code',
    'the-state',
  );

  @override
  Future<bool?> askConsent() async => true;

  @override
  Future<AccelDohConnectResult> fetchCode(
    Uri authorizeUrl, {
    bool silent = true,
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例在同一个文件里共享状态，下面的用例按顺序执行
  group('cfhub 探针令牌', () {
    late SharedPreferences prefs;
    final service = NetworkSettingsService.instance;
    final api = _FakeApi();
    final flow = _FakeConnectFlow();
    final user = ValueNotifier<User?>(null);
    late CfhubProbeAuthService auth;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      CfhubProbeAuthService.retryDelays = const [Duration.zero, Duration.zero];
      CfhubProbeAuthService.resetForTest(
        api: api,
        flow: flow,
        userNotifier: user,
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
      api.startResult = const CfhubStartResult.unavailable();
      expect(await auth.enable(), CfhubEnableResult.hubUnavailable);
      expect(api.startCalls, 1);
      expect(auth.token, isNull);
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(service.current.shareMeasurements, isFalse);
      expect(prefs.getBool('doh_select_share'), isFalse);
    });

    test('授权成功：存令牌与账号 id，打开上报', () async {
      api.startResult = CfhubStartResult.ok(
        Uri.parse('https://connect.linux.do/oauth2/authorize?client_id=x'),
      );
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
      api.tokenResult = const CfhubTokenResult.rejected();
      expect(await auth.enable(), CfhubEnableResult.rejected);
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
    });

    test('Connect 没拿到 code：cancelled，上报关', () async {
      api.tokenResult = const CfhubTokenResult.ok('cfp_second');
      flow.result = const AccelDohConnectResult.unavailable();
      expect(await auth.enable(), CfhubEnableResult.cancelled);
      expect(auth.token, isNull);
      expect(service.current.shareMeasurements, isFalse);
      flow.result = const AccelDohConnectResult.code('code-2', 'state-2');
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
      api.tokenResult = const CfhubTokenResult.ok('cfp_third');
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
      api.tokenResult = const CfhubTokenResult.ok('cfp_fourth');
      expect(await auth.enable(), CfhubEnableResult.ok);
      await auth.disable();
      expect(auth.token, isNull);
      expect(api.revoked, contains('cfp_fourth'));
      expect(prefs.getString('cfhub_probe_token'), isNull);
      expect(prefs.getInt('cfhub_probe_user_id'), isNull);
      expect(service.current.shareMeasurements, isFalse);
    });
  });
}
