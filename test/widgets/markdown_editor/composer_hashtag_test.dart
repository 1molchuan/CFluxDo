import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/models/hashtag_suggestion.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/hashtag/hashtag_autocomplete.dart';
import 'package:fluxdo/widgets/hashtag/hashtag_suggestion_tile.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _develop = HashtagSuggestion(
  type: 'category',
  text: '开发调优',
  ref: 'develop',
  relativeUrl: '/c/develop/4',
  icon: 'code',
  styleType: 'icon',
  colors: ['32c3c3'],
);

const _devTag = HashtagSuggestion(
  type: 'tag',
  text: 'devops',
  ref: 'devops',
  relativeUrl: '/tag/devops',
  icon: 'tag',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  tester.view.physicalSize = const Size(390, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const keyboardChannel = MethodChannel('com.fluxdo/interactive_keyboard');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    keyboardChannel,
    (call) async => call.method == 'begin' ? {'supported': false} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      keyboardChannel,
      null,
    ),
  );
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    if (!PreloadedDataService().isLoaded) {
      await PreloadedDataService().hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
          'currentUser': {'id': 1, 'username': 'tester'},
          'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
          'site': {'categories': [], 'top_tags': []},
        })}</script>',
      );
      await DiscourseCookService().ensureInitialized();
    }
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        emojiGroupsProvider.overrideWith(
          (ref) => Stream.value(<String, List<Emoji>>{}),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(resizeToAvoidBottomInset: false, body: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('富文本：#查询 弹出分类/标签候选，点选插入 #ref 并写回源码', (tester) async {
    final queries = <String>[];
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        hashtagDataSource: (term) async {
          queries.add(term);
          return const [_develop, _devTag];
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.insertText('看看 #de');
    await tester.pump();
    // 防抖期间不发请求
    expect(queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(queries, ['de']);
    expect(find.byType(HashtagSuggestionTile), findsNWidgets(2));
    expect(find.text('开发调优'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);

    await tester.tap(find.text('开发调优'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HashtagSuggestionTile), findsNothing);

    final state = tester.state<RichComposerEditorState>(
      find.byType(RichComposerEditor),
    );
    expect(state.flushToController(), isTrue);
    expect(controller.text, '看看 #develop ');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('富文本：键盘上下选择、回车确认；词中的 # 不触发', (tester) async {
    final queries = <String>[];
    final controller = TextEditingController();
    await _pump(
      tester,
      RichComposerEditor(
        controller: controller,
        hashtagDataSource: (term) async {
          queries.add(term);
          return const [_develop, _devTag];
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor));
    editor.state.insertText('a#b');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(queries, isEmpty);
    expect(find.byType(HashtagSuggestionTile), findsNothing);

    editor.state.insertText(' #dev');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(HashtagSuggestionTile), findsNWidgets(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HashtagSuggestionTile), findsNothing);

    final state = tester.state<RichComposerEditorState>(
      find.byType(RichComposerEditor),
    );
    expect(state.flushToController(), isTrue);
    expect(controller.text, 'a#b #devops ');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('源码模式：#查询 候选点选后替换为 #ref 并把光标放到空格后', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    await _pump(
      tester,
      HashtagAutocomplete(
        controller: controller,
        focusNode: focusNode,
        dataSource: (term) async => term.startsWith('dev')
            ? const [_develop, _devTag]
            : const <HashtagSuggestion>[],
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: null,
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '你好 #dev');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(HashtagSuggestionTile), findsNWidgets(2));

    await tester.tap(find.text('devops'));
    await tester.pump();
    expect(controller.text, '你好 #devops ');
    expect(controller.selection.baseOffset, controller.text.length);
    expect(find.byType(HashtagSuggestionTile), findsNothing);

    // 没有候选时不弹
    await tester.enterText(find.byType(TextField), '你好 #zz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(HashtagSuggestionTile), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focusNode.dispose();
  });
}
