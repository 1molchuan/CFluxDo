import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/settings/search/settings_search_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按界面风格建一次搜索索引,返回所有条目 id
Future<Set<String>> _indexIds(WidgetTester tester, String uiStyle) async {
  SharedPreferences.setMockInitialValues({'ui_style': uiStyle});
  final prefs = await SharedPreferences.getInstance();
  late Set<String> ids;
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
          home: Consumer(
            builder: (context, ref, _) {
              ids = buildSearchIndex(
                context,
                ref,
              ).map((r) => r.model.id).toSet();
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  return ids;
}

void main() {
  testWidgets('设置搜索与页面同一套可见性:墨笺下搜不到只属于经典的选项', (tester) async {
    final classic = await _indexIds(tester, 'classic');
    expect(classic, containsAll(['neutral', 'black', 'themeColor']));

    final mojian = await _indexIds(tester, 'mojian');
    expect(mojian, contains('black'));
    expect(mojian, isNot(contains('neutral')));
    expect(mojian, isNot(contains('themeColor')));
    expect(mojian, isNot(contains('customBackground')));
  });
}
