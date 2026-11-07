import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/pages/network_settings_page/network_advanced_settings_page.dart';
import 'package:fluxdo/pages/network_settings_page/network_settings_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/settings/search/settings_search_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 建一次搜索索引，返回 id → 搜索结果
Future<Map<String, SettingsSearchResult>> _index(
  WidgetTester tester, {
  bool developerMode = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'ui_style': 'mojian',
    'developer_mode': developerMode,
  });
  final prefs = await SharedPreferences.getInstance();
  late Map<String, SettingsSearchResult> results;
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
              results = {
                for (final r in buildSearchIndex(context, ref)) r.model.id: r,
              };
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );
  return results;
}

void main() {
  testWidgets('网络设置：主页面和高级子页的项都能搜到，并跳到各自的页面', (tester) async {
    final index = await _index(tester);

    const mainIds = [
      'connectionStatus',
      'ipFamily',
      'engine',
      'autoCfChallenge',
      'cfVerify',
      'httpProxy',
      'vpnAutoToggle',
      'networkAdvanced',
      'appLogs',
      'networkLogs',
    ];
    const advancedIds = [
      'cfSelect',
      'dohSettings',
      'engineMix',
      'rateLimit',
      'forceDisableMultipartUpload',
      'erudaConsole',
    ];
    for (final id in mainIds) {
      expect(index, contains(id), reason: id);
      expect(
        index[id]!.pageBuilder(highlightId: id),
        isA<NetworkSettingsPage>(),
        reason: id,
      );
    }
    for (final id in advancedIds) {
      expect(index, contains(id), reason: id);
      expect(
        index[id]!.pageBuilder(highlightId: id),
        isA<NetworkAdvancedSettingsPage>(),
        reason: id,
      );
    }

    // 搜「IPv6」能找到 IP 协议，搜「VPN」能找到自动让路
    expect(index['ipFamily']!.model.matchesQuery('ipv6'), isTrue);
    expect(index['vpnAutoToggle']!.model.matchesQuery('VPN'), isTrue);
  });

  testWidgets('CF 验证日志入口只在开发者模式下出现', (tester) async {
    expect(await _index(tester), isNot(contains('cfLogs')));
    expect(await _index(tester, developerMode: true), contains('cfLogs'));
  });
}
