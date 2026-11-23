import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/pages/data_management_page.dart';
import 'package:fluxdo/pages/progress_gesture_settings_page.dart';
import 'package:fluxdo/pages/reading_settings_page.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/settings/definitions/preferences_defs.dart';
import 'package:fluxdo/settings/definitions/reading_defs.dart';
import 'package:fluxdo/settings/search/settings_search_index.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/widgets/settings/settings_group_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 在带多语言与偏好的环境里跑 [body]
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Map<String, Object> prefsValues = const {},
  required Widget Function(BuildContext context, WidgetRef ref) body,
}) async {
  SharedPreferences.setMockInitialValues({'ui_style': 'mojian', ...prefsValues});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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
          home: Consumer(builder: (context, ref, _) => body(context, ref)),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('阅读设置：三组，进度条手势收成一个入口，子页里五项齐全', (tester) async {
    late List<SettingsGroup> reading;
    late List<SettingsGroup> gestures;
    await _pump(
      tester,
      body: (context, ref) {
        reading = buildReadingGroups(context);
        gestures = buildProgressGestureGroups(context);
        return const SizedBox();
      },
    );

    expect(reading, hasLength(3));
    final readingIds = reading.expand((g) => g.items).map((i) => i.id).toSet();
    expect(readingIds, contains('progressGestures'));
    // 收进子页的、和固定成默认行为的，主页上都不该再有
    for (final id in [
      'progressGesturesEnabled',
      'progressGestureSwipeLeft',
      'progressGestureMenuActions',
      'adaptiveSignatureFrameRate',
      'nestedLineStyle',
    ]) {
      expect(readingIds, isNot(contains(id)), reason: id);
    }
    expect(gestures.expand((g) => g.items).map((i) => i.id), [
      'progressGesturesEnabled',
      'progressGestureSwipeLeft',
      'progressGestureSwipeRight',
      'progressGestureSwipeUp',
      'progressGestureMenuActions',
    ]);
  });

  testWidgets('搜索：进度条手势进子页、Notion 同步进数据管理页', (tester) async {
    late Map<String, SettingsSearchResult> index;
    await _pump(
      tester,
      body: (context, ref) {
        index = {
          for (final r in buildSearchIndex(context, ref)) r.model.id: r,
        };
        return const SizedBox();
      },
    );

    expect(
      index['progressGestureSwipeLeft']!.pageBuilder(
        highlightId: 'progressGestureSwipeLeft',
      ),
      isA<ProgressGestureSettingsPage>(),
    );
    expect(
      index['progressGestures']!.pageBuilder(highlightId: 'progressGestures'),
      isA<ReadingSettingsPage>(),
    );
    expect(
      index['notionSync']!.pageBuilder(highlightId: 'notionSync'),
      isA<DataManagementPage>(),
    );
    expect(index, isNot(contains('networkLogs')));
    expect(index, isNot(contains('glassSettings')));
  });

  testWidgets('AI 的模型与目标语言只在对应开关打开后出现', (tester) async {
    Set<String> visibleAiIds(BuildContext context, WidgetRef ref) =>
        buildPreferencesGroups(context)
            .expand((g) => g.items)
            .where((item) => item.isVisible(ref))
            .map((item) => item.id)
            .where((id) => id.startsWith('ai'))
            .toSet();

    late Set<String> ids;
    final container = await _pump(
      tester,
      body: (context, ref) {
        ids = visibleAiIds(context, ref);
        return const SizedBox();
      },
    );
    expect(ids, {'aiPostReview', 'aiTranslation'});

    await container
        .read(preferencesProvider.notifier)
        .setAiTranslationEnabled(true);
    await tester.pump();
    expect(ids, {
      'aiPostReview',
      'aiTranslation',
      'aiTranslationTargetLanguage',
      'aiTranslationModel',
    });
  });

  testWidgets('标题为空的分组不起小标题，贴在上一组下面', (tester) async {
    await _pump(
      tester,
      body: (context, ref) => SettingsGroupPage(
        title: '测试页',
        groupsBuilder: (_) => [
          SettingsGroup(
            title: '第一组',
            icon: Icons.tune,
            items: [
              ActionModel(
                id: 'a',
                title: '甲',
                icon: Icons.tune,
                onTap: (_, _) {},
              ),
            ],
          ),
          SettingsGroup(
            title: '',
            icon: Icons.tune,
            items: [
              ActionModel(
                id: 'b',
                title: '乙',
                icon: Icons.tune,
                onTap: (_, _) {},
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    // 两组之间是 12 的间距：乙的卡片紧跟在甲的卡片下面
    final gap =
        tester.getTopLeft(find.text('乙')).dy -
        tester.getBottomLeft(find.text('甲')).dy;
    expect(gap, lessThan(48));
    expect(tester.takeException(), isNull);
  });

  test('旧的「服务端 IP」改记为自定义节点', () {
    List<String> migrate(String? ip, List<String> nodes) =>
        NetworkSettingsService.migrateLegacyServerIp(ip, nodes);

    expect(migrate('104.16.1.1', const []), ['104.16.1.1']);
    expect(migrate(' 104.16.1.1 ', const []), ['104.16.1.1']);
    // 已经填了自定义节点的，不动
    expect(migrate('104.16.1.1', const ['cf.example.com']), ['cf.example.com']);
    // 没填过、或写法不对的，不迁
    expect(migrate(null, const []), isEmpty);
    expect(migrate('', const []), isEmpty);
    expect(migrate('不是地址', const []), isEmpty);
  });

  test('已从设置里拿掉的偏好：旧值被清掉，行为回到默认', () async {
    SharedPreferences.setMockInitialValues({
      'pref_adaptive_signature_frame_rate': false,
      'pref_nested_line_style': 'lLine',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final state = container.read(preferencesProvider);
    expect(state.adaptiveSignatureFrameRate, isTrue);
    expect(state.nestedLineStyle, NestedLineStyle.auto);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.containsKey('pref_adaptive_signature_frame_rate'), isFalse);
    expect(prefs.containsKey('pref_nested_line_style'), isFalse);
  });
}
