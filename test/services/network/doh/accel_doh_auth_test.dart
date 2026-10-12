import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/network/doh/accel_doh_api.dart';
import 'package:fluxdo/services/network/doh/accel_doh_auth_service.dart';
import 'package:fluxdo/services/network/doh/accel_doh_connect_flow.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的加速服务端：记录调用，按设定返回
class _FakeApi implements AccelDohApi {
  int startCalls = 0;
  int refreshCalls = 0;
  String? lastCode;
  String? lastState;
  final List<String> revoked = [];
  AccelDohIssueResult exchangeResult = const AccelDohIssueResult.issued(
    'connect-token',
    Duration(days: 7),
  );

  @override
  Future<Uri?> startConnect() async {
    startCalls++;
    return Uri.parse('https://connect.linux.do/oauth2/authorize?client_id=x');
  }

  @override
  Future<AccelDohIssueResult> exchangeCode({
    required String code,
    required String state,
  }) async {
    lastCode = code;
    lastState = state;
    return exchangeResult;
  }

  @override
  Future<AccelDohIssueResult> refresh(String token) async {
    refreshCalls++;
    return const AccelDohIssueResult.failed();
  }

  @override
  Future<void> revoke(String token) async => revoked.add(token);
}

/// 假的 Connect 授权：不弹窗、不发请求
class _FakeConnectFlow implements AccelDohConnectFlow {
  /// null 表示现在弹不了窗
  bool? consentAnswer;
  int consentAsks = 0;
  AccelDohConnectResult result = const AccelDohConnectResult.code(
    'the-code',
    'the-state',
  );

  @override
  Future<bool?> askConsent() async {
    consentAsks++;
    return consentAnswer;
  }

  @override
  Future<AccelDohConnectResult> fetchCode(
    Uri authorizeUrl, {
    bool silent = true,
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单例在同一个文件里共享状态，下面的用例按顺序执行
  group('加速 DoH 账号令牌（Connect 核验）', () {
    late SharedPreferences prefs;
    final auth = AccelDohAuthService.instance;
    final service = NetworkSettingsService.instance;
    final api = _FakeApi();
    final flow = _FakeConnectFlow();
    const dnsPodUrl = 'https://doh.pub/dns-query';

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
        // 旧版自报身份的令牌，启动时要被清掉
        'doh_accel_auth': '{"token":"old"}',
      });
      prefs = await SharedPreferences.getInstance();
      auth
        ..debugApi = api
        ..debugConnectFlow = flow
        ..consentPromptDelay = Duration.zero;
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

    test('等级降到 0：作废令牌，改走 DNSPod', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 0));
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(auth.isMember, isFalse);
      expect(auth.status, AccelDohAuthStatus.notEligible);
      expect(api.revoked, contains('stored-token'));
      expect(prefs.getString('doh_accel_token'), isNull);
      expect(service.current.selectedServerUrl, service.accelServerUrl);
      expect(activeUrl(), dnsPodUrl);
      expect(activeToken(), isNull);
      expect(service.accelFallbackHint, contains('DNSPod'));
    });

    test('等级回到 1、之前同意过：自动走 Connect 换到新令牌', () async {
      auth.onUserChanged(User(id: 7, username: 'alice', trustLevel: 1));
      await pumpEventQueue();
      expect(api.startCalls, 1);
      expect(api.lastCode, 'the-code');
      expect(api.lastState, 'the-state');
      expect(auth.token, 'connect-token');
      expect(auth.status, AccelDohAuthStatus.ready);
      expect(activeUrl(), service.accelServerUrl);
      expect(activeToken(), 'connect-token');
    });

    test('令牌被拒、服务端也不再发：降到公共加速', () async {
      api.exchangeResult = const AccelDohIssueResult.rejected();
      await auth.handleRejected();
      await pumpEventQueue();
      expect(auth.token, isNull);
      expect(auth.status, AccelDohAuthStatus.denied);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(activeToken(), isNull);
      expect(service.accelFallbackHint, contains('拒绝'));
      expect(prefs.getString('doh_accel_backoff'), isNotNull);
    });

    test('换成用不了 Connect 的账号（青春版）：同意后仍走公共加速', () async {
      flow
        ..consentAnswer = true
        ..result = const AccelDohConnectResult.unavailable();
      final asksBefore = flow.consentAsks;
      auth.onUserChanged(User(id: 8, username: 'bob', trustLevel: 1));
      await pumpEventQueue();
      expect(flow.consentAsks, asksBefore + 1);
      expect(auth.token, isNull);
      expect(auth.status, AccelDohAuthStatus.unavailable);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(service.accelFallbackHint, contains('无法使用 Connect'));
    });

    test('选了暂不：走公共加速；之后在设置里手动授权就切到专属加速', () async {
      flow
        ..consentAnswer = false
        ..result = const AccelDohConnectResult.code('code-9', 'state-9');
      api.exchangeResult = const AccelDohIssueResult.issued(
        'token-9',
        Duration(days: 7),
      );
      final startsBefore = api.startCalls;
      auth.onUserChanged(User(id: 9, username: 'carol', trustLevel: 3));
      await pumpEventQueue();
      expect(auth.status, AccelDohAuthStatus.notAuthorized);
      expect(api.startCalls, startsBefore);
      expect(activeUrl(), accelDohPublicServer.url);
      expect(service.accelFallbackHint, contains('未授权'));

      flow.consentAnswer = true;
      final status = await auth.authorizeNow();
      expect(status, AccelDohAuthStatus.ready);
      expect(api.lastCode, 'code-9');
      expect(auth.token, 'token-9');
      expect(activeUrl(), service.accelServerUrl);
      expect(activeToken(), 'token-9');
    });

    test('主动退出：作废令牌、清掉授权记录，改回 DNSPod', () async {
      await auth.revoke();
      expect(auth.token, isNull);
      expect(auth.isMember, isFalse);
      expect(auth.status, AccelDohAuthStatus.notEligible);
      expect(api.revoked, contains('token-9'));
      expect(prefs.getString('doh_accel_consent'), isNull);
      expect(prefs.getBool('doh_accel_member'), isNull);
      expect(activeUrl(), dnsPodUrl);
    });
  });
}
