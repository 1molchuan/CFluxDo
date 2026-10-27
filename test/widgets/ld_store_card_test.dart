import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/ld_store_providers.dart';
import 'package:fluxdo/services/ld_store/ld_store_models.dart';
import 'package:fluxdo/services/ld_store/ld_store_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/ld_store_card.dart';

import '../services/ld_store/ld_store_test_support.dart';

class _User extends CurrentUserNotifier {
  _User(this.user);

  final User? user;

  @override
  FutureOr<User?> build() => user;
}

class _Session extends LdStoreSessionNotifier {
  _Session(this.result);

  final Object? result;

  @override
  Future<LdStoreSession?> build() async {
    final value = result;
    if (value is Exception) throw value;
    return value as LdStoreSession?;
  }
}

Widget _app({
  required Object? session,
  bool loggedIn = true,
  LdStoreStats? stats,
  bool mojian = false,
}) {
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWith(
        () => _User(
          loggedIn ? User(id: 12345, username: 'alice', trustLevel: 2) : null,
        ),
      ),
      ldStoreSessionProvider.overrideWith(() => _Session(session)),
      ldStoreStatsProvider.overrideWith((ref) async => stats),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(
          extensions: [
            if (mojian)
              MojianTokens.of(Brightness.light, MojianAccent.cinnabar),
          ],
        ),
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: SingleChildScrollView(child: LdStoreCard())),
      ),
    ),
  );
}

void main() {
  final token = LdStoreToken.parse(
    ldStoreJwt(expiresAt: DateTime.now().add(const Duration(days: 7))),
  )!;
  const stats = LdStoreStats(onlineProducts: 120, ordersToday: 45, stores: 18);

  for (final mojian in [false, true]) {
    final style = mojian ? '墨笺' : '经典';

    testWidgets('$style 未授权：介绍、公开统计、进入商城与授权登录', (tester) async {
      await tester.pumpWidget(
        _app(session: null, stats: stats, mojian: mojian),
      );
      await tester.pumpAndSettle();
      expect(find.text('LD士多'), findsOneWidget);
      expect(find.text('社区成员开发的积分商城（第三方）'), findsOneWidget);
      expect(find.text('在售 120 · 今日成交 45 · 小店 18'), findsOneWidget);
      expect(find.text('进入商城'), findsOneWidget);
      final authorize = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '授权登录'),
      );
      expect(authorize.onPressed, isNotNull);
    });

    testWidgets('$style 已授权：账号、四项待办与退出授权', (tester) async {
      await tester.pumpWidget(
        _app(
          mojian: mojian,
          session: LdStoreSession(
            token: token,
            account: const LdStoreAccount(
              username: 'alice',
              attention: LdStoreAttention(
                pendingPayment: 1,
                awaitingDelivery: 2,
                unusedCoupons: 4,
              ),
              unreadMessages: 3,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('@alice'), findsOneWidget);
      for (final (label, value) in [
        ('待付款', '1'),
        ('待收货', '2'),
        ('未读消息', '3'),
        ('可用券', '4'),
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(find.text(value), findsOneWidget);
      }
      expect(find.text('授权登录'), findsNothing);
      expect(find.byTooltip('退出授权'), mojian ? findsNothing : findsOneWidget);
    });

    testWidgets('$style 授权失效：提示并给重新授权', (tester) async {
      await tester.pumpWidget(
        _app(session: const LdStoreAuthExpiredException(), mojian: mojian),
      );
      await tester.pumpAndSettle();
      expect(find.text('LD士多授权已过期，请重新授权'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重新授权'), findsOneWidget);
      expect(find.text('@alice'), findsNothing);
    });
  }

  testWidgets('已授权但这次没读到：显示加载失败与重试，入口照常', (tester) async {
    await tester.pumpWidget(
      _app(
        session: LdStoreSession(token: token, loadError: Exception('timeout')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('进入商城'), findsOneWidget);
  });

  testWidgets('没登录论坛时不能授权', (tester) async {
    await tester.pumpWidget(_app(session: null, loggedIn: false, stats: stats));
    await tester.pumpAndSettle();
    final authorize = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '授权登录'),
    );
    expect(authorize.onPressed, isNull);
  });
}
