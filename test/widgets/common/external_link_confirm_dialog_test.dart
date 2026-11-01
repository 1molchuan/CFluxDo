import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/site_customization.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/common/external_link_confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外链确认弹层：主按钮跟「外部链接使用内置浏览器」偏好走
void main() {
  const primary = ValueKey('external-link-primary');
  const secondary = ValueKey('external-link-secondary');

  Future<Future<ExternalLinkOpenChoice?>> open(
    WidgetTester tester,
    String url, {
    required bool preferInApp,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      ),
    );
    final result = showExternalLinkConfirmDialog(
      navigatorKey.currentContext!,
      url,
      LinkRiskLevel.normal,
      preferInApp: preferInApp,
    );
    await tester.pumpAndSettle();
    return result;
  }

  String labelOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      )
      .first
      .data!;

  testWidgets('偏好系统浏览器：主按钮是系统浏览器，内置浏览器是次选', (tester) async {
    final result = await open(
      tester,
      'https://example.com/a',
      preferInApp: false,
    );
    expect(
      labelOf(tester, primary),
      S.current.externalLink_openInSystemBrowser,
    );
    expect(labelOf(tester, secondary), S.current.externalLink_openInAppBrowser);

    await tester.tap(find.byKey(primary));
    await tester.pumpAndSettle();
    expect(await result, ExternalLinkOpenChoice.systemBrowser);
  });

  testWidgets('偏好内置浏览器：主按钮是内置浏览器，系统浏览器是次选', (tester) async {
    final result = await open(
      tester,
      'https://example.com/a',
      preferInApp: true,
    );
    expect(labelOf(tester, primary), S.current.externalLink_openInAppBrowser);
    expect(
      labelOf(tester, secondary),
      S.current.externalLink_openInSystemBrowser,
    );

    await tester.tap(find.byKey(secondary));
    await tester.pumpAndSettle();
    expect(await result, ExternalLinkOpenChoice.systemBrowser);
  });

  testWidgets('非 http(s) 链接只给系统打开，不出内置浏览器选项', (tester) async {
    final result = await open(
      tester,
      'magnet:?xt=urn:btih:abc',
      preferInApp: true,
    );
    expect(
      labelOf(tester, primary),
      S.current.externalLink_openInSystemBrowser,
    );
    expect(find.byKey(secondary), findsNothing);

    await tester.tap(find.byKey(primary));
    await tester.pumpAndSettle();
    expect(await result, ExternalLinkOpenChoice.systemBrowser);
  });

  testWidgets('取消返回 null', (tester) async {
    final result = await open(
      tester,
      'https://example.com/a',
      preferInApp: true,
    );
    await tester.tap(find.text(S.current.common_cancel));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
