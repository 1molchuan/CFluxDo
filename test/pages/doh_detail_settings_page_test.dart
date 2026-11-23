import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/pages/network_settings_page/doh_detail_settings_page.dart';
import 'package:fluxdo/services/local_notification_service.dart';

void main() {
  testWidgets('DNS 与网关详情页：没有网关模式、内置网页 HTTP/2、服务端 IP 三项，其余分区照常', (
    tester,
  ) async {
    // 手机竖屏尺寸，顺带确认去掉三行后没有溢出
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          // 页面里有些文案走 S.current，要靠全局导航键取 context
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: const DohDetailSettingsPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('DNS 与网关'), findsOneWidget);
    for (final gone in ['网关模式', '内置网页 HTTP/2（实验）', '服务端 IP']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // 留下的分区
    expect(find.text('服务器'), findsOneWidget);
    expect(find.text('ECH'), findsOneWidget);
    expect(find.text('DNS 缓存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
