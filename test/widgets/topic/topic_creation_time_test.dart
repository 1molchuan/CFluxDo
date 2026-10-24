import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:fluxdo/theme/claude_theme.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/utils/relative_time_clock.dart';
import 'package:fluxdo/utils/time_utils.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card_layout.dart';
import 'package:fluxdo/widgets/topic/topic_creation_time.dart';
import 'package:fluxdo/widgets/topic/topic_item_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _category = Category(
  id: 1,
  name: '开发',
  color: '3E6C8F',
  textColor: 'FFFFFF',
  slug: 'dev',
);

Topic _topic({DateTime? createdAt, bool pinned = false}) => Topic(
  id: 7301,
  title: '用于检验窄窗口中的真实话题列表卡片',
  slug: 'creation-time',
  postsCount: 23,
  replyCount: 22,
  views: 1200,
  likeCount: 20,
  categoryId: '1',
  lastPosterUsername: '一位名字很长的楼主',
  createdAt: createdAt,
  lastPostedAt: DateTime.now().subtract(const Duration(minutes: 2)),
  pinned: pinned,
);

ThemeData _theme(String style, Brightness brightness) {
  if (style == '墨笺') {
    return MojianTheme.build(
      scheme: MojianTheme.colorScheme(brightness, MojianAccent.cinnabar),
      accent: MojianAccent.cinnabar,
      fontFamily: null,
      pageTransitionsTheme: const PageTransitionsTheme(),
      iconTheme: const IconThemeData(),
      primaryIconTheme: const IconThemeData(),
    );
  }
  return ThemeData(
    colorScheme: style == 'Claude'
        ? ClaudeTheme.colorScheme(brightness)
        : ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness),
  );
}

void _tick() {
  // 手动发送生产分钟心跳，避免依赖测试执行时刻恰好跨过午夜。
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  RelativeTimeClock.instance.notifyListeners();
}

void main() {
  late SharedPreferences prefs;
  late ProviderContainer container;
  late DateTime now;

  void keepClockAlive() {}
  setUpAll(() => RelativeTimeClock.instance.addListener(keepClockAlive));
  tearDownAll(() => RelativeTimeClock.instance.removeListener(keepClockAlive));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    container.read(preferencesProvider);
    now = DateTime(2026, 3, 1, 0, 1);
    TopicCreationTimeScope.debugNow = () => now;
    TopicCardLayout.evictAll();
  });
  tearDown(() {
    container.dispose();
    TopicCreationTimeScope.enabled.value = true;
    TopicCreationTimeScope.debugNow = null;
    TopicCardLayout.evictAll();
  });

  Widget app(Widget child, {ThemeData? theme}) => UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: theme,
        themeAnimationDuration: Duration.zero,
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );

  Widget listItem(Topic topic, {bool ordinary = false}) => SizedBox(
    width: 280,
    child: Builder(
      builder: (context) => buildTopicItem(
        context: context,
        topic: topic,
        isSelected: false,
        onTap: () {},
        enableLongPress: false,
        categoryMap: {1: _category},
        middleWidget: ordinary ? const Text('书签摘要') : null,
      ),
    ),
  );

  testWidgets('四档按本地日历划分，跨月、未来时间和三套主题明暗均可辨', (tester) async {
    for (final style in ['经典', 'Claude', '墨笺']) {
      for (final brightness in Brightness.values) {
        final theme = _theme(style, brightness);
        final dates = [
          DateTime(2026, 3, 1),
          DateTime(2026, 2, 28, 23, 59),
          DateTime(2026, 2, 22),
          DateTime(2026, 2, 21),
          DateTime(2026, 1, 30),
          DateTime(2026, 1, 29),
          DateTime(2026, 3, 2),
        ];
        final colors = <Color>[];
        for (final createdAt in dates) {
          await tester.pumpWidget(
            app(
              TopicCard(
                topic: _topic(createdAt: createdAt),
                categoryMap: {1: _category},
                statsAvailableWidth: 240,
              ),
              theme: theme,
            ),
          );
          final text = createdAt.month == 3
              ? TimeUtils.formatClockTime(createdAt)
              : TimeUtils.formatShortDate(createdAt);
          final creation = find.text(text);
          expect(creation, findsOneWidget);
          final color = tester.widget<Text>(creation).style!.color!;
          colors.add(color);
          final activeTheme = Theme.of(tester.element(creation));
          expect(activeTheme.brightness, brightness);
          final surface =
              activeTheme.cardTheme.color ?? activeTheme.colorScheme.surface;
          final contrast =
              (math.max(color.computeLuminance(), surface.computeLuminance()) +
                  .05) /
              (math.min(color.computeLuminance(), surface.computeLuminance()) +
                  .05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$style $brightness $createdAt',
          );
        }
        expect(colors[1], colors[2]);
        expect(colors[3], colors[4]);
        expect(colors[6], colors[0]);
        expect({colors[0], colors[1], colors[3], colors[5]}, hasLength(4));
      }
    }
  });

  testWidgets('实际显示开关即时更新自绘卡和普通卡，并恢复作者宽度和持久化', (tester) async {
    final topic = _topic(createdAt: DateTime(2026, 2, 21, 8, 30));
    final theme = _theme('经典', Brightness.light);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            Builder(
              builder: (context) {
                final setting = buildAppearanceGroups(context)
                    .expand((group) => group.items)
                    .singleWhere((item) => item.id == 'showTopicCreationTime');
                return SettingsRenderer(model: setting);
              },
            ),
            listItem(topic),
            listItem(topic, ordinary: true),
          ],
        ),
        theme: theme,
      ),
    );
    final painted = tester.widget<PaintedTopicCard>(
      find.byType(PaintedTopicCard),
    );
    final layout = painted.layout;
    final authorWidth = layout.author!.width;
    expect(layout.creationTime, isNotNull);
    expect(layout.creationTimeOffset.dx, lessThan(layout.timeOffset.dx));
    expect(
      find.text(TimeUtils.formatShortDate(topic.createdAt)),
      findsOneWidget,
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(container.read(preferencesProvider).showTopicCreationTime, isFalse);
    expect(prefs.getBool('pref_show_topic_creation_time'), isFalse);
    expect(layout.creationTime, isNull);
    expect(layout.author!.width, greaterThan(authorWidth));
    expect(find.text(TimeUtils.formatShortDate(topic.createdAt)), findsNothing);
    expect(find.byType(TopicListTimes), findsOneWidget);
    expect(tester.takeException(), isNull);

    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    expect(reloaded.read(preferencesProvider).showTopicCreationTime, isFalse);
    reloaded.dispose();

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(layout.creationTime, isNotNull);
    expect(layout.author!.width, closeTo(authorWidth, .01));
    expect(
      find.text(TimeUtils.formatShortDate(topic.createdAt)),
      findsOneWidget,
    );
  });

  testWidgets('鼠标停留在帖子卡片和发帖日期上不弹出创建时间，日期仍直接显示', (tester) async {
    final topic = _topic(createdAt: DateTime(2026, 2, 21, 8, 30));
    await tester.pumpWidget(
      app(Column(children: [listItem(topic), listItem(topic, ordinary: true)])),
    );
    final date = find.text(TimeUtils.formatShortDate(topic.createdAt));
    final details =
        '${S.current.topic_createdAt}${TimeUtils.formatDetailTime(topic.createdAt)}';
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final target in [find.byType(PaintedTopicCard), date]) {
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(details), findsNothing);
      expect(date, findsOneWidget);
    }
  });

  testWidgets('缺失创建日期不显示，置顶和私信列表同样支持日期，窄窗口不溢出', (tester) async {
    for (final style in ['经典', 'Claude', '墨笺']) {
      final theme = _theme(style, Brightness.dark);
      for (final pinned in [false, true]) {
        await tester.pumpWidget(
          app(listItem(_topic(pinned: pinned)), theme: theme),
        );
        expect(find.text(' · '), findsNothing);
        expect(tester.takeException(), isNull);
        final topic = _topic(createdAt: DateTime(2026, 2, 21), pinned: pinned);
        await tester.pumpWidget(
          app(
            Column(
              children: [
                listItem(topic),
                listItem(topic, ordinary: true),
                SizedBox(
                  width: 240,
                  child: TopicCard(
                    topic: topic,
                    messageStyle: true,
                    categoryMap: {1: _category},
                  ),
                ),
              ],
            ),
            theme: theme,
          ),
        );
        expect(
          find.text(TimeUtils.formatShortDate(topic.createdAt)),
          findsAtLeastNWidgets(2),
        );
        expect(tester.takeException(), isNull);
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(TopicListTimes),
            matching: find.byType(Text),
          ),
        )) {
          if (text.data != ' · ') expect(text.maxLines, 1);
        }
        for (final card in tester.widgetList<PaintedTopicCard>(
          find.byType(PaintedTopicCard),
        )) {
          final layout = card.layout;
          expect(
            layout.creationTimeOffset.dx,
            greaterThanOrEqualTo(layout.avatarRect.right),
          );
          expect(
            layout.timeOffset.dx + layout.time!.longestLine,
            lessThanOrEqualTo(layout.layoutWidth),
          );
        }
      }
    }
  });

  testWidgets('置顶行标题使用剩余宽度，时间和回复数靠右且窄屏大字不溢出', (tester) async {
    for (final scenario in [
      (width: 560.0, scale: 1.2, hasCreatedAt: true),
      (width: 280.0, scale: 1.5, hasCreatedAt: true),
      (width: 560.0, scale: 1.2, hasCreatedAt: false),
    ]) {
      final topic = _topic(
        pinned: true,
        createdAt: scenario.hasCreatedAt ? DateTime(2026, 2, 21) : null,
      );
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: Center(
                child: SizedBox(
                  width: scenario.width,
                  child: CompactTopicCard(
                    topic: topic,
                    categoryMap: {1: _category},
                  ),
                ),
              ),
            ),
          ),
          theme: _theme('Claude', Brightness.light),
        ),
      );
      final card = tester.getRect(find.byType(CompactTopicCard));
      final title = tester.getRect(find.text(topic.title));
      final times = tester.getRect(find.byType(TopicListTimes));
      final replies = tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.textSpan?.toPlainText().endsWith('22') ?? false),
        ),
      );
      expect(replies.right, closeTo(card.right - 12, .01));
      expect(title.right, closeTo(times.left - 8, .01));
      expect(title.width, greaterThan(0));
      expect(times.right, lessThanOrEqualTo(replies.left - 8));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('同一在屏卡跨月午夜随心跳切换时间和日期，隐藏普通卡不刷新', (tester) async {
    now = DateTime(2026, 2, 28, 23, 59);
    final topic = _topic(createdAt: DateTime(2026, 2, 28, 12));
    await tester.pumpWidget(
      app(
        Column(
          children: [
            listItem(topic),
            TickerMode(enabled: false, child: listItem(topic, ordinary: true)),
            listItem(topic, ordinary: true),
          ],
        ),
      ),
    );
    final layout = tester
        .widget<PaintedTopicCard>(find.byType(PaintedTopicCard))
        .layout;
    final revision = layout.revision;
    expect(
      find.text(TimeUtils.formatClockTime(topic.createdAt)),
      findsNWidgets(2),
    );
    now = DateTime(2026, 3, 1, 0, 1);
    _tick();
    await tester.pump();
    expect(
      find.text(TimeUtils.formatClockTime(topic.createdAt)),
      findsOneWidget,
    );
    expect(
      find.text(TimeUtils.formatShortDate(topic.createdAt)),
      findsOneWidget,
    );
    expect(layout.revision, greaterThan(revision));
    expect(
      layout.creationTimeOffset.dx,
      greaterThanOrEqualTo(layout.avatarRect.right),
    );
    expect(
      layout.creationTimeOffset.dx + layout.creationTime!.longestLine,
      closeTo(layout.timeOffset.dx, .01),
    );
    expect(
      layout.timeOffset.dx + layout.time!.longestLine,
      lessThanOrEqualTo(layout.layoutWidth - 12),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存随显示开关和主题更新，窗口改宽重新约束日期簇', (tester) async {
    final topic = _topic(createdAt: DateTime(2026, 2, 21));
    Future<TopicCardLayout> mount(ThemeData theme, double width) async {
      await tester.pumpWidget(
        app(
          SizedBox(
            width: width,
            child: Builder(
              builder: (context) => PaintedTopicCard(
                layout: TopicCardLayout.obtain(
                  identity: 'bookmark:creation-time',
                  topic: topic,
                  width: width,
                  theme: Theme.of(context),
                  category: _category,
                  emojiUrlOf: (_) => '',
                  statsAvailableWidth: width - 64,
                ),
              ),
            ),
          ),
          theme: theme,
        ),
      );
      return tester
          .widget<PaintedTopicCard>(find.byType(PaintedTopicCard))
          .layout;
    }

    final light = _theme('Claude', Brightness.light);
    final first = await mount(light, 400);
    _tick();
    final nextMinute = await mount(light, 400);
    expect(nextMinute, isNot(same(first)));
    final narrow = await mount(light, 240);
    expect(narrow.layoutWidth, 240);
    expect(
      narrow.creationTimeOffset.dx,
      greaterThanOrEqualTo(narrow.avatarRect.right),
    );
    expect(
      narrow.timeOffset.dx + narrow.time!.longestLine,
      lessThanOrEqualTo(228),
    );
    await container
        .read(preferencesProvider.notifier)
        .setShowTopicCreationTime(false);
    final hidden = await mount(light, 400);
    expect(hidden, isNot(same(first)));
    expect(hidden.creationTime, isNull);
    await container
        .read(preferencesProvider.notifier)
        .setShowTopicCreationTime(true);
    final dark = await mount(_theme('墨笺', Brightness.dark), 240);
    expect(dark, isNot(same(hidden)));
    expect(dark.creationTime, isNotNull);
    expect(dark.layoutWidth, 240);
    expect(
      dark.creationTimeOffset.dx,
      greaterThanOrEqualTo(dark.avatarRect.right),
    );
    expect(dark.timeOffset.dx + dark.time!.longestLine, lessThanOrEqualTo(228));
    expect(tester.takeException(), isNull);
  });
}
