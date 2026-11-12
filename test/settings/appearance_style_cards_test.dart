import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观页「界面风格」那一组卡片的排布。
Future<void> _pumpStyleCards(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final item = buildAppearanceGroups(context)
                    .expand((group) => group.items)
                    .firstWhere((item) => item.id == 'uiStyle');
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [SettingsRenderer(model: item)],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('手机宽度下三张风格卡排成一行，不折成 2 + 1', (tester) async {
    await _pumpStyleCards(tester, const Size(411, 900));
    final l10n = tester.element(find.byType(ListView)).l10n;
    final tops = [
      l10n.appearance_styleMojian,
      l10n.appearance_styleClaude,
      l10n.appearance_styleClassic,
      // 预览图里也会出现风格名，取卡片标题（后出现的那个）
    ].map((title) => tester.getTopLeft(find.text(title).last).dy).toList();
    // 选中的那张描边略粗，标题会差零点几像素；同一行即可
    expect(tops[1], closeTo(tops[0], 4));
    expect(tops[2], closeTo(tops[0], 4));
    expect(find.text(l10n.appearance_styleVscode), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有 VS Code 的平台窄窗口下四张卡按宽度换行', (tester) async {
    ThemeState.debugSupportsVscodeOverride = true;
    addTearDown(() => ThemeState.debugSupportsVscodeOverride = null);
    await _pumpStyleCards(tester, const Size(411, 900));
    final l10n = tester.element(find.byType(ListView)).l10n;
    final mojian = tester.getTopLeft(
      find.text(l10n.appearance_styleMojian).last,
    );
    final vscode = tester.getTopLeft(
      find.text(l10n.appearance_styleVscode).last,
    );
    expect(vscode.dy, greaterThan(mojian.dy));
    expect(tester.takeException(), isNull);
  });
}
