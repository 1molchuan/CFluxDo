import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/cdk_user_info.dart';
import 'package:fluxdo/models/ldc_user_info.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/cdk_providers.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/ldc_providers.dart';
import 'package:fluxdo/services/cdk_oauth_service.dart';
import 'package:fluxdo/services/ldc_oauth_service.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userInfo = <String, dynamic>{
  'id': 1,
  'username': 'alice',
  'nickname': 'Alice',
  'trust_level': 2,
  'avatar_url': '',
  'score': 12,
  'total_receive': '12.34',
  'total_payment': '0',
  'total_transfer': '0',
  'total_community': '12.34',
  'community_balance': '12.34',
  'available_balance': '12.34',
  'pay_score': 0,
  'is_pay_key': false,
  'is_admin': false,
  'remain_quota': '-1',
  'pay_level': 0,
  'daily_limit': null,
};

class _CurrentUser extends CurrentUserNotifier {
  @override
  User? build() => User(id: 1, username: 'alice', trustLevel: 2);
}

class _LdcService extends LdcOAuthService {
  _LdcService(this.load) : super(dio: Dio());
  final Future<Map<String, dynamic>> Function() load;
  final List<bool> afterVerificationFlags = [];
  @override
  Future<LdcUserInfo?> getUserInfo({
    String? expectedUsername,
    bool afterVerification = false,
  }) async {
    expect(expectedUsername, 'alice');
    afterVerificationFlags.add(afterVerification);
    return LdcUserInfo.fromJson(await load());
  }

  @override
  void cancelPendingRequests() {}
}

class _CdkService extends CdkOAuthService {
  _CdkService(this.load) : super(dio: Dio());
  final Future<Map<String, dynamic>> Function() load;
  final List<bool> afterVerificationFlags = [];
  @override
  Future<CdkUserInfo?> getUserInfo({
    String? expectedUsername,
    bool afterVerification = false,
  }) async {
    expect(expectedUsername, 'alice');
    afterVerificationFlags.add(afterVerification);
    return CdkUserInfo.fromJson(await load());
  }

  @override
  void cancelPendingRequests() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final isLdc in [true, false]) {
    final name = isLdc ? 'ldc' : 'cdk';
    final cacheKey = '${name}_user_info';
    group(name, () {
      late ProviderContainer container;
      late SharedPreferences prefs;
      late Future<Map<String, dynamic>> Function() load;
      late _LdcService ldcService;
      late _CdkService cdkService;

      Future<void> initialize() async {
        SharedPreferences.setMockInitialValues({
          '${name}_enabled': true,
          cacheKey: jsonEncode(_userInfo),
          '${cacheKey}_username': 'alice',
        });
        prefs = await SharedPreferences.getInstance();
        load = () async => _userInfo;
        ldcService = _LdcService(() => load());
        cdkService = _CdkService(() => load());
        container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            currentUserProvider.overrideWith(_CurrentUser.new),
            ldcOAuthServiceProvider.overrideWithValue(ldcService),
            cdkOAuthServiceProvider.overrideWithValue(cdkService),
          ],
        );
        addTearDown(container.dispose);
      }

      Future<Object?> read() => isLdc
          ? container.read(ldcUserInfoProvider.future)
          : container.read(cdkUserInfoProvider.future);
      Future<void> refresh() => isLdc
          ? container.read(ldcUserInfoProvider.notifier).refresh()
          : container.read(cdkUserInfoProvider.notifier).refresh();
      AsyncValue<Object?> current() => isLdc
          ? container.read(ldcUserInfoProvider)
          : container.read(cdkUserInfoProvider);

      DioException challenge() => DioException(
        requestOptions: RequestOptions(path: '/api/v1/oauth/user-info'),
        error: CfChallengeException(userCancelled: true),
      );

      test('初次加载遇到 CF 不删除缓存，也不隐藏验证状态', () async {
        await initialize();
        load = () async => throw challenge();
        await expectLater(read(), throwsA(isA<DioException>()));
        expect(OAuthErrorPolicy.isCfChallenge(current().error), isTrue);
        expect(prefs.getString(cacheKey), isNotNull);
      });

      test('刷新遇到 CF 保留旧数据与缓存，同时暴露验证错误', () async {
        await initialize();
        final previous = await read();
        load = () async => throw challenge();
        await refresh();
        expect(OAuthErrorPolicy.isCfChallenge(current().error), isTrue);
        expect(current().value, same(previous));
        expect(prefs.getString(cacheKey), isNotNull);
      });

      test('卡片手动验证后的刷新带上验证后标记（仍被拦不再自动起验证）', () async {
        await initialize();
        await read();
        if (isLdc) {
          await container
              .read(ldcUserInfoProvider.notifier)
              .refreshAfterCfVerification();
        } else {
          await container
              .read(cdkUserInfoProvider.notifier)
              .refreshAfterCfVerification();
        }
        await refresh();
        final flags = isLdc
            ? ldcService.afterVerificationFlags
            : cdkService.afterVerificationFlags;
        expect(flags, [false, true, false]);
      });

      test('确认授权过期才清除余额缓存', () async {
        await initialize();
        await read();
        load = () async => throw OAuthExpiredException(serviceName: name);
        await refresh();
        expect(current().error, isA<OAuthExpiredException>());
        expect(prefs.getString(cacheKey), isNull);
      });

      test('初次加载期间停用，晚到的过期错误不恢复错误卡片', () async {
        await initialize();
        final pending = Completer<Map<String, dynamic>>();
        final entered = Completer<void>();
        load = () {
          entered.complete();
          return pending.future;
        };
        final initializing = read();
        final initialResult = initializing.then<Object?>(
          (value) => value,
          onError: (Object _) => null,
        );
        await entered.future;
        if (isLdc) {
          await container.read(ldcUserInfoProvider.notifier).disable();
        } else {
          await container.read(cdkUserInfoProvider.notifier).disable();
        }
        pending.completeError(OAuthExpiredException(serviceName: name));
        await initialResult;
        await Future<void>.delayed(Duration.zero);
        expect(current().value, isNull);
        expect(current().hasError, isFalse);
        expect(prefs.getString(cacheKey), isNull);
      });

      test('停用服务后，晚到的刷新响应不能恢复余额或写回缓存', () async {
        await initialize();
        await read();
        final pending = Completer<Map<String, dynamic>>();
        final entered = Completer<void>();
        load = () {
          entered.complete();
          return pending.future;
        };
        final refreshing = refresh();
        await entered.future;
        if (isLdc) {
          await container.read(ldcUserInfoProvider.notifier).disable();
        } else {
          await container.read(cdkUserInfoProvider.notifier).disable();
        }
        pending.complete(_userInfo);
        await refreshing;
        expect(current().value, isNull);
        expect(current().hasError, isFalse);
        expect(prefs.getString(cacheKey), isNull);
        expect(prefs.getBool('${name}_enabled'), isFalse);
      });
    });
  }
}
