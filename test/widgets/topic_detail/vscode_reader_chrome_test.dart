import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_detail_overlay.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_segment_frame.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_post_source.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/widgets/layout/vscode_editor_title_bar.dart';
import 'package:fluxdo/widgets/layout/vscode_reader_status_scope.dart';
import 'package:fluxdo/widgets/layout/vscode_workbench_chrome.dart';

void main() {
  testWidgets('窄阅读区大字号下楼层跳转和回复仍可操作，楼层随阅读更新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final index = ValueNotifier(123);
    final visible = ValueNotifier(true);
    addTearDown(index.dispose);
    addTearDown(visible.dispose);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final detail = TopicDetail.fromJson({
      'id': 1,
      'title': '窄阅读区',
      'posts_count': 9999,
      'post_stream': {'posts': [], 'stream': []},
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(
              colorScheme: VscodeTheme.colorScheme(Brightness.light),
              extensions: [VscodeTokens.of(Brightness.light)],
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(
              body: TopicDetailOverlay(
                showBottomBarListenable: visible,
                isLoggedIn: true,
                streamIndexListenable: index,
                totalCount: 9999,
                detail: detail,
                onScrollToTop: () {},
                onShare: () {},
                onOpenInBrowser: () {},
                onReply: () {},
                onProgressTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('123 / 9999').hitTestable(), findsOneWidget);
    expect(find.text('回复').hitTestable(), findsOneWidget);
    index.value = 124;
    visible.value = false;
    await tester.pump();
    expect(find.text('124 / 9999').hitTestable(), findsOneWidget);
    expect(find.text('回复').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分栏标题长文本不挤出右侧动作，同组命中区域保持一致', (tester) async {
    for (final width in [360.0, 1120.0]) {
      await tester.binding.setSurfaceSize(Size(width + 240, 640));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 240),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: VscodeEditorTitleBar(
                        title: '非常长的话题标题' * 20,
                        onClose: () {},
                        actions: [
                          TopicBottomBar(
                            onScrollToTop: () {},
                            onShare: () {},
                            onOpenInBrowser: () {},
                          ),
                          IconButton(
                            key: const ValueKey('search'),
                            onPressed: () {},
                            icon: const Icon(Icons.search),
                          ),
                          PopupMenuButton<int>(
                            key: const ValueKey('menu'),
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 1, child: Text('菜单')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final title = tester.getRect(find.byType(VscodeEditorTitleBar));
      final menu = find.descendant(
        of: find.byKey(const ValueKey('menu')),
        matching: find.byType(IconButton),
      );
      expect(tester.getRect(menu).right, title.right);
      expect(tester.getSize(menu), const Size(32, 32));
      expect(
        tester.getSize(find.byKey(const ValueKey('search'))),
        const Size(32, 32),
      );
      expect(tester.takeException(), isNull);
      final tools = find.descendant(
        of: find.byType(TopicBottomBar),
        matching: find.byType(IconButton),
      );
      expect(tools, findsNWidgets(4));
      for (final tool in tools.evaluate()) {
        final bounds = tester.getRect(find.byWidget(tool.widget));
        expect(bounds.left, greaterThanOrEqualTo(title.left));
        expect(bounds.right, lessThanOrEqualTo(title.right));
        expect(bounds.top, greaterThanOrEqualTo(title.top));
        expect(bounds.bottom, lessThanOrEqualTo(title.bottom));
        expect(find.byWidget(tool.widget).hitTestable(), findsOneWidget);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('缓存阅读页失活或退栈后状态栏不保留过期楼层工具', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final active = ValueNotifier(1);
    addTearDown(active.dispose);
    Widget binding(int floor) => VscodeReaderStatusBinding(
      key: ValueKey(floor),
      active: active.value == floor,
      controls: Text('操作 #$floor'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
          home: VscodeReaderStatusHost(
            child: Column(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: active,
                  builder: (_, value, _) =>
                      Column(children: [binding(1), binding(2)]),
                ),
                const VscodeStatusBar(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('操作 #1'), findsOneWidget);
    active.value = 2;
    await tester.pump();
    await tester.pump();
    expect(find.text('操作 #1'), findsNothing);
    expect(find.text('操作 #2'), findsOneWidget);
    active.value = 0;
    await tester.pump();
    await tester.pump();
    expect(find.text('操作 #2'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('状态栏操作左边界随实际阅读面板和分栏宽度变化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final leading = ValueNotifier(240.0);
    addTearDown(leading.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
          home: Row(
            children: [
              const SizedBox(width: 50),
              Expanded(
                child: VscodeReaderStatusHost(
                  child: Column(
                    children: [
                      Expanded(
                        child: ValueListenableBuilder<double>(
                          valueListenable: leading,
                          builder: (_, width, _) => Row(
                            children: [
                              SizedBox(width: width),
                              Expanded(
                                child: Stack(
                                  children: [
                                    const Positioned.fill(
                                      child: ColoredBox(
                                        key: ValueKey('reading-pane'),
                                        color: Colors.white,
                                      ),
                                    ),
                                    VscodeReaderStatusBinding(
                                      active: true,
                                      controls: Row(
                                        children: [
                                          SizedBox(
                                            key: const ValueKey(
                                              'first-reading-action',
                                            ),
                                            width: 32,
                                            height: 32,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const VscodeStatusBar(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    for (final inset in [240.0, 320.0, 0.0]) {
      leading.value = inset;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('first-reading-action')))
            .dx,
        tester.getTopLeft(find.byKey(const ValueKey('reading-pane'))).dx,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('$kind 点击正文选择对应楼层，拖选文字和滚动不会切换操作目标', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final selection = ValueNotifier<int?>(null);
      addTearDown(selection.dispose);
      await tester.binding.setSurfaceSize(const Size(640, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final posts = [
        for (final number in [1, 2])
          Post.fromJson({
            'id': number,
            'post_number': number,
            'username': 'author$number',
            'cooked': '<p>第 $number 层可选择的正文内容</p>',
          }),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
          child: TranslationProvider(
            child: MaterialApp(
              theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
              home: Scaffold(
                body: VscodeReaderFlowScope(
                  selectedPost: selection,
                  child: ListView(
                    children: [
                      for (final post in posts)
                        PostSegmentFrame(
                          post: post,
                          selected: true,
                          highlight: false,
                          child: SizedBox(
                            height: 320,
                            child: VscodePostSource(
                              post: post,
                              topicId: 1,
                              document: VscodeSourceDocument.forHtml(
                                post.cooked,
                              ),
                              richTextBuilder: (_) =>
                                  Text('原文 ${post.postNumber}'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder text(int number) => find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText().trim() == '第 $number 层可选择的正文内容',
      );
      expect(selection.value, isNull);
      await tester.drag(text(1), const Offset(90, 0), kind: kind);
      await tester.pumpAndSettle();
      expect(selection.value, isNull);
      await tester.tap(text(1), kind: kind);
      await tester.pumpAndSettle();
      expect(selection.value, 1);
      await tester.dragFrom(const Offset(500, 260), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(selection.value, 1);
      if (kind == PointerDeviceKind.mouse) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(text(2), kind: kind);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(selection.value, 1);
      }
      await tester.tap(text(2), kind: kind);
      await tester.pumpAndSettle();
      expect(selection.value, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
