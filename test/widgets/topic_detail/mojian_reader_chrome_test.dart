import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/mojian_reader_chrome.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _mojian() => MojianTheme.build(
  scheme: MojianTheme.colorScheme(Brightness.light, MojianAccent.cinnabar),
  accent: MojianAccent.cinnabar,
  fontFamily: null,
  pageTransitionsTheme: const PageTransitionsTheme(),
  iconTheme: const IconThemeData(),
  primaryIconTheme: const IconThemeData(),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: _mojian(),
          // S.current(时间轴的日期格式化)经全局 navigatorKey 取 context
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('阅读控件形态', () {
    testWidgets('手机恒为阅读条;非手机按阅读区宽度切换', (tester) async {
      late BuildContext ctx;
      await _pump(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      // 400 宽 = 手机
      expect(mojianReaderModeFor(ctx, 2000), MojianReaderMode.bar);

      await _pump(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
        size: const Size(1600, 900),
      );
      expect(
        mojianReaderModeFor(ctx, kMojianTimelineMinWidth),
        MojianReaderMode.timeline,
      );
      expect(
        mojianReaderModeFor(ctx, kMojianTimelineMinWidth - 1),
        MojianReaderMode.bar,
      );
    });
  });

  testWidgets('阅读条:楼层随 listenable 更新,未赞首帖时显示空心赞', (tester) async {
    final index = ValueNotifier<int>(3);
    var replies = 0;
    var progressTaps = 0;
    await _pump(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: MojianReaderBar(
          streamIndexListenable: index,
          totalCount: 10,
          isLoggedIn: true,
          showFloor: true,
          liked: false,
          bookmarked: false,
          onReply: () => replies++,
          onLike: () {},
          onBookmark: () {},
          onProgressTap: () => progressTaps++,
        ),
      ),
    );
    expect(find.text('3 / 10'), findsOneWidget);
    expect(find.text(t.topic.topic_detail_write_reply), findsOneWidget);
    expect(find.byTooltip(t.topic.topic_detail_like_topic), findsOneWidget);

    index.value = 7;
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('7 / 10'), findsOneWidget);

    await tester.tap(find.text(t.topic.topic_detail_write_reply));
    await tester.tap(find.text('7 / 10'));
    await tester.pump();
    expect(replies, 1);
    expect(progressTaps, 1);
  });

  testWidgets('阅读条:未登录只留楼层;赞为 null 时不显示赞', (tester) async {
    await _pump(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: MojianReaderBar(
          streamIndexListenable: ValueNotifier<int>(1),
          totalCount: 5,
          isLoggedIn: false,
          showFloor: true,
          liked: null,
          bookmarked: false,
          onReply: () {},
          onLike: () {},
          onBookmark: () {},
          onProgressTap: () {},
        ),
      ),
    );
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.text(t.topic.topic_detail_write_reply), findsNothing);
    expect(find.byTooltip(t.topic.topic_detail_like_topic), findsNothing);
    expect(find.byTooltip(t.topic.topic_detail_bookmark_topic), findsNothing);
  });

  testWidgets('时间轴:点轨道按比例跳到对应序号', (tester) async {
    final seeks = <int>[];
    var jumps = 0;
    await _pump(
      tester,
      Center(
        child: MojianTimeline(
          streamIndexListenable: ValueNotifier<int>(1),
          totalCount: 101,
          startDate: DateTime(2026, 10, 1),
          endDate: null,
          isLoggedIn: true,
          bookmarked: false,
          trackHeight: 200,
          onSeekIndex: seeks.add,
          onReply: () {},
          onBookmark: () {},
          onProgressTap: () => jumps++,
          liked: false,
          onLike: () {},
        ),
      ),
      size: const Size(1600, 900),
    );
    // 轨道 = 宽 kMojianTimelineWidth、高 200 的那块;点在 3/4 处 → 第 76 个
    final track = find.byWidgetPredicate(
      (w) =>
          w is SizedBox && w.height == 200 && w.width == kMojianTimelineWidth,
    );
    expect(track, findsOneWidget);
    final topLeft = tester.getTopLeft(track);
    await tester.tapAt(topLeft + const Offset(20, 150));
    await tester.pump();
    expect(seeks, [76]);
    // 松手后圆钮先停在目标处,等楼层真正变化(或超时)才回到当前楼层
    expect(find.text('76 / 101'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('1 / 101'), findsOneWidget);

    // 「跳转楼层」= 原楼层胶囊的单击(打开时间线弹窗);首帖可赞时有赞按钮
    await tester.tap(find.text(t.topic.topic_detail_jump_floor));
    await tester.pump();
    expect(jumps, 1);
    expect(find.text(t.topic.topic_detail_like), findsOneWidget);
  });

  testWidgets('时间轴:三个按钮 + 跳转楼层的整列高度在预留之内,不压底部工具行', (tester) async {
    // 与 topic_detail_overlay 的算法一致:可用高 700,预留 440 → 轨道 260;
    // 列顶在 96,底部工具行 80 高
    const available = 700.0;
    const trackHeight = available - 440;
    await _pump(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: MojianTimeline(
          streamIndexListenable: ValueNotifier<int>(1),
          totalCount: 40,
          startDate: DateTime(2026, 10, 1),
          endDate: DateTime(2026, 10, 17),
          isLoggedIn: true,
          bookmarked: false,
          trackHeight: trackHeight,
          onSeekIndex: (_) {},
          onReply: () {},
          onBookmark: () {},
          onProgressTap: () {},
          liked: false,
          onLike: () {},
        ),
      ),
      size: const Size(1600, 900),
    );
    final h = tester.getSize(find.byType(MojianTimeline)).height;
    expect(96 + h, lessThanOrEqualTo(available - 80));
  });
}
