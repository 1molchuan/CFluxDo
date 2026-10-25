import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';

import '../../helpers/memory_draft_store.dart';

import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_view_mode_switcher.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_header_actions.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_desktop_workbench.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:fluxdo/widgets/layout/vscode_terminal_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpReply(
  WidgetTester tester, {
  bool rich = false,
  bool review = false,
  Widget? sheet,
  double? width,
  double height = 760,
  double scale = 1,
  bool dark = false,
  bool desktop = false,
  bool vscode = false,
  Draft? Function()? remoteDraft,
  MemoryDraftStore? draftStore,
  List<Map>? draftWrites,
  List<String>? requests,
  Map<String, dynamic>? createdPost,
  List<Map>? postWrites,
  Future<void>? postBarrier,
}) async {
  PlatformUtils.debugDesktopOverride = desktop;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  if (width != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }
  addTearDown(tester.view.resetViewInsets);
  SharedPreferences.setMockInitialValues({
    'pref_use_rich_composer': rich,
    'pref_ai_post_review_enabled': review,
  });
  final prefs = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final mock = InterceptorsWrapper(
    onRequest: (options, handler) async {
      requests?.add('${options.method} ${options.path}');
      final draft = remoteDraft?.call();
      if (options.method == 'POST' && options.path == '/posts.json') {
        postWrites?.add(Map.of(options.data as Map));
        if (postBarrier != null) await postBarrier;
        if (createdPost == null) {
          handler.reject(
            DioException(
              requestOptions: options,
              error: StateError('测试未配置发帖响应，已阻止发送'),
            ),
          );
        } else {
          handler.resolve(
            Response(requestOptions: options, data: {'post': createdPost}),
          );
        }
        return;
      }
      if (options.method == 'POST' && options.path == '/drafts.json') {
        draftWrites?.add(Map.of(options.data as Map));
        if (draft != null &&
            (options.data as Map)['sequence'] != draft.sequence) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 409,
                data: {
                  'errors': ['sequence conflict'],
                },
              ),
            ),
          );
          return;
        }
      }
      handler.resolve(
        Response(
          requestOptions: options,
          data: {
            'success': 'OK',
            'draft': draft?.data.toJsonString(),
            'draft_sequence': draft?.sequence ?? 0,
          },
        ),
      );
    },
  );
  DiscourseService().dio.interceptors.insert(0, mock);
  addTearDown(() => DiscourseService().dio.interceptors.remove(mock));
  await tester.runAsync(() async {
    final loaded = await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup">'
      '<script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
        'site': {'categories': [], 'top_tags': []},
      })}</script>',
    );
    expect(loaded, isTrue);
    await DiscourseCookService().ensureInitialized();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        localDraftStoreProvider.overrideWithValue(
          draftStore ?? MemoryDraftStore(),
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
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            extensions: vscode
                ? [VscodeTokens.of(dark ? Brightness.dark : Brightness.light)]
                : null,
            platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: sheet ?? const ReplySheet()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // 草稿的本地存储读取需要让平台异步回调完成，再操作被遮罩覆盖的页头。
  for (
    var i = 0;
    i < 20 &&
        find
            .byKey(const ValueKey('composer-header-submit'))
            .hitTestable()
            .evaluate()
            .isEmpty;
    i++
  ) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    find.byKey(const ValueKey('composer-header-submit')).hitTestable(),
    findsOneWidget,
  );
}

Future<void> _waitForRichDraft(WidgetTester tester, String text) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final editors = find.byType(FluxdoEditor).evaluate();
    if (editors.length == 1 &&
        docToMarkdown((editors.single.widget as FluxdoEditor).state.blocks)
                .trim() ==
            text) {
      return;
    }
  }
  fail('富文本内部文档没有同步到云端内容');
}

Widget _terminalReply({
  required ReplySheetController controller,
  required ValueChanged<Post?> onClosed,
  Post? replyToPost,
}) {
  var open = true;
  return StatefulBuilder(
    builder: (context, setState) => VscodeTerminalPanel(
      reader: const Center(child: Text('宿主话题正文')),
      targetLabel: '回复话题',
      onClose: () => controller.close(),
      composer: open
          ? ReplySheet(
              embedded: true,
              controller: controller,
              topicId: 1,
              replyToPost: replyToPost,
              preloadedDraftFuture: Future.value(null),
              onClosed: (post) {
                onClosed(post);
                setState(() => open = false);
              },
            )
          : null,
    ),
  );
}

void main() {
  testWidgets('VS Code终端收起最大化和预览往返保留真实富文本输入与选区', (tester) async {
    final controller = ReplySheetController();
    final closed = <Post?>[];
    await _pumpReply(
      tester,
      rich: true,
      desktop: true,
      vscode: true,
      width: 800,
      height: 760,
      sheet: _terminalReply(controller: controller, onClosed: closed.add),
    );
    await _waitForRichDraft(tester, '');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('保留终端中的即时输入');
    final selection = editor.selection;
    await tester.tap(find.byTooltip(S.current.post_terminalCollapse));
    await tester.pump();
    expect(closed, isEmpty);
    await tester.tap(find.byTooltip(S.current.post_terminalExpand));
    await tester.pump();
    await tester.tap(find.byTooltip(S.current.post_terminalMaximize));
    await tester.pump();
    await tester.tap(find.byTooltip(S.current.post_terminalRestore));
    await tester.pump();
    expect(
      tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state,
      same(editor),
    );
    expect(editor.selection, selection);
    await tester.tap(find.byTooltip(S.current.common_preview));
    await tester.pump();
    final preview = find.byKey(const ValueKey('reply-preview'));
    expect(
      tester
          .widget<MarkdownBody>(
            find.descendant(of: preview, matching: find.byType(MarkdownBody)),
          )
          .data,
      '保留终端中的即时输入',
    );
    await tester.tap(find.byTooltip(S.current.common_exitPreview));
    await tester.pump();
    expect(
      tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state,
      same(editor),
    );
    expect(docToMarkdown(editor.blocks).trim(), '保留终端中的即时输入');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('VS Code窄窗大字号源码回复可编辑预览并按真实楼层发送', (tester) async {
    final controller = ReplySheetController();
    final writes = <Map>[];
    final closed = <Post?>[];
    final submission = Completer<void>();
    final target = Post.fromJson({
      'id': 22,
      'username': 'target_user',
      'post_number': 7,
    });
    await _pumpReply(
      tester,
      desktop: true,
      vscode: true,
      width: 360,
      height: 760,
      scale: 2,
      postWrites: writes,
      postBarrier: submission.future,
      createdPost: {
        'id': 88,
        'topic_id': 1,
        'post_number': 8,
        'username': 'tester',
        'raw': '窄窗真实回复',
      },
      sheet: _terminalReply(
        controller: controller,
        onClosed: closed.add,
        replyToPost: target,
      ),
    );
    final field = find.descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '窄窗真实回复');
    await tester.pump();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('composer-writing-canvas')))
          .height,
      greaterThan(140),
    );
    await tester.tap(find.byTooltip(S.current.common_preview));
    await tester.pump();
    expect(
      tester
          .widget<MarkdownBody>(
            find.descendant(
              of: find.byKey(const ValueKey('reply-preview')),
              matching: find.byType(MarkdownBody),
            ),
          )
          .data,
      '窄窗真实回复',
    );
    await tester.tap(find.byTooltip(S.current.common_exitPreview));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '窄窗真实回复');
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    for (var i = 0; i < 100 && writes.isEmpty; i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.close(), isFalse);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('composer-header-submit')),
          )
          .onPressed,
      isNull,
    );
    expect(writes, hasLength(1));
    submission.complete();
    for (var i = 0; i < 100 && closed.isEmpty; i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(writes, hasLength(1));
    expect(writes.single['raw'], '窄窗真实回复');
    expect(writes.single['reply_to_post_number'], 7);
    expect(closed.single?.id, 88);
    expect(find.text('宿主话题正文').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('终端内真实富文本追加引用并关闭后保留宿主与完整草稿', (tester) async {
    final controller = ReplySheetController();
    final store = MemoryDraftStore();
    final closed = <Post?>[];
    await _pumpReply(
      tester,
      rich: true,
      desktop: true,
      width: 1200,
      height: 1000,
      draftStore: store,
      sheet: _terminalReply(controller: controller, onClosed: closed.add),
    );
    await tester.drag(
      find.byKey(const ValueKey('vscode-terminal-divider')),
      const Offset(0, 1000),
    );
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(ReplySheet)))!;
    await _waitForRichDraft(tester, '');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('追加前即时正文');
    // 不等待镜像 debounce，追加必须先从真实文档同步刚输入的正文。
    expect(controller.appendContent('\n\n追加引用'), isTrue);
    await tester.pump();
    await _waitForRichDraft(tester, '追加前即时正文\n\n追加引用');
    final appended = tester
        .widget<FluxdoEditor>(find.byType(FluxdoEditor))
        .state;
    appended.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: appended.blocks.last.id, offset: '追加引用'.length),
      ),
    );
    appended.insertText('末尾即时修改');
    // 同样不等待 debounce，通过终端关闭按钮走控制器安全关闭路径。
    await tester.tap(find.byTooltip('关闭回复面板'));
    expect(controller.close(), isFalse);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(closed, <Post?>[null]);
    expect(find.byType(ReplySheet), findsNothing);
    expect(find.text('宿主话题正文').hitTestable(), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(VscodeTerminalPanel))),
      same(route),
    );
    expect(route.isCurrent, isTrue);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(store.entry?.data.reply?.trim(), '追加前即时正文\n\n追加引用末尾即时修改');
    expect(store.entry?.data.replyToPostNumber, isNull);
    expect(controller.close(), isFalse);
    controller.focus();
    await tester.pump();
    expect(closed, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('宿主直接移除终端仍保存富文本最后一次即时输入', (tester) async {
    final controller = ReplySheetController();
    final store = MemoryDraftStore();
    final closed = <Post?>[];
    var visible = true;
    late StateSetter updateHost;
    final terminal = _terminalReply(
      controller: controller,
      onClosed: closed.add,
    );
    await _pumpReply(
      tester,
      rich: true,
      desktop: true,
      width: 1200,
      height: 1000,
      draftStore: store,
      sheet: StatefulBuilder(
        builder: (context, setState) {
          updateHost = setState;
          return visible ? terminal : const Center(child: Text('切换后的宿主正文'));
        },
      ),
    );
    final route = ModalRoute.of(tester.element(find.byType(ReplySheet)))!;
    await _waitForRichDraft(tester, '');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('切换话题前最后一次尚未同步的输入');
    // 不走 close、不等待 debounce，模拟宿主关闭分栏或切换话题。
    updateHost(() => visible = false);
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(VscodeTerminalPanel), findsNothing);
    expect(find.byType(ReplySheet), findsNothing);
    expect(find.text('切换后的宿主正文').hitTestable(), findsOneWidget);
    expect(route.isCurrent, isTrue);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(store.entry?.data.reply?.trim(), '切换话题前最后一次尚未同步的输入');
    expect(closed, isEmpty);
    expect(controller.close(), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('终端内真实富文本发送提交楼层目标并将帖子交还宿主', (tester) async {
    final controller = ReplySheetController();
    final store = MemoryDraftStore();
    final writes = <Map>[];
    final closed = <Post?>[];
    final target = Post.fromJson({
      'id': 22,
      'username': 'target_user',
      'post_number': 7,
      'cooked': '<p>被回复的帖子</p>',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    final createdPost = <String, dynamic>{
      'id': 88,
      'topic_id': 1,
      'username': 'tester',
      'post_number': 8,
      'reply_to_post_number': 7,
      'raw': '真实编辑器发送正文',
      'cooked': '<p>真实编辑器发送正文</p>',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };
    await _pumpReply(
      tester,
      rich: true,
      desktop: true,
      width: 1200,
      height: 1000,
      draftStore: store,
      createdPost: createdPost,
      postWrites: writes,
      sheet: _terminalReply(
        controller: controller,
        onClosed: closed.add,
        replyToPost: target,
      ),
    );
    final route = ModalRoute.of(tester.element(find.byType(ReplySheet)))!;
    await _waitForRichDraft(tester, '');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('真实编辑器发送正文');
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    // 提交仍在处理时不能从外部关闭编辑器。
    expect(controller.close(), isFalse);
    for (
      var i = 0;
      i < 50 && find.byType(ReplySheet).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(writes, hasLength(1));
    expect(writes.single['topic_id'], 1);
    expect(writes.single['reply_to_post_number'], 7);
    expect((writes.single['raw'] as String).trim(), '真实编辑器发送正文');
    expect(closed, hasLength(1));
    expect(closed.single?.id, createdPost['id']);
    expect(closed.single?.postNumber, createdPost['post_number']);
    expect(closed.single?.replyToPostNumber, 7);
    expect(closed.single?.cooked, createdPost['cooked']);
    expect(find.byType(ReplySheet), findsNothing);
    expect(find.text('宿主话题正文').hitTestable(), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(VscodeTerminalPanel))),
      same(route),
    );
    expect(route.isCurrent, isTrue);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(store.entry, isNull);
    expect(controller.close(), isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(closed, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final (width, scale, username) in [
    (320.0, 1.0, 'IG2018'),
    (390.0, 1.0, 'IG2018'),
    (390.0, 2.0, 'IG2018'),
    (320.0, 2.0, 'a_very_long_reply_recipient_username'),
    (700.0, 1.0, 'a_very_long_reply_recipient_username'),
  ]) {
    testWidgets('手机回复对象完整显示且不挤压操作按钮 $width/$scale/$username', (tester) async {
      await _pumpReply(
        tester,
        width: width,
        scale: scale,
        dark: scale == 2,
        review: true,
        sheet: ReplySheet(
          topicId: 1,
          preloadedDraftFuture: Future.value(null),
          replyToPost: Post(
            id: 2,
            username: username,
            avatarTemplate: '',
            cooked: '<p>reply target</p>',
            postNumber: 2,
            postType: 1,
            updatedAt: DateTime(2026),
            createdAt: DateTime(2026),
            likeCount: 0,
            replyCount: 0,
          ),
        ),
      );
      final title = find.byKey(const ValueKey('reply-composer-title-text'));
      void expectComplete() {
        expect(title, findsOneWidget);
        expect(tester.widget<Text>(title).data, contains('@$username'));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: title, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: '回复对象不应被省略');
        final rect = tester.getRect(title);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
        final send = find.byKey(const ValueKey('composer-header-submit'));
        expect(tester.getSize(send), const Size(48, 48));
        expect(tester.getSize(find.byType(CloseButton)), const Size(48, 48));
        final more = find.byKey(const ValueKey('composer-header-more'));
        if (more.evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('reply-composer-recipient-row'))
                .evaluate()
                .isEmpty) {
          expect(rect.right, lessThanOrEqualTo(tester.getRect(more).left));
        }
        expect(tester.takeException(), isNull);
      }

      expectComplete();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump(const Duration(milliseconds: 300));
      expectComplete();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('富文本冲突菜单使用云端后重建实际文档，旧编辑器卸载不会回写本地版本', (tester) async {
    var remote = const Draft(
      draftKey: 'topic_1',
      sequence: 1,
      data: DraftData(reply: '共同正文', action: 'reply'),
    );
    final store = MemoryDraftStore();
    final writes = <Map>[];
    await _pumpReply(
      tester,
      rich: true,
      sheet: const ReplySheet(topicId: 1),
      remoteDraft: () => remote,
      draftStore: store,
      draftWrites: writes,
    );
    await _waitForRichDraft(tester, remote.data.reply!);
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('本机修改');
    remote = const Draft(
      draftKey: 'topic_1',
      sequence: 2,
      data: DraftData(reply: '另一设备的最新版本', action: 'reply'),
    );
    tester
        .widget<ComposerHeaderActions>(find.byType(ComposerHeaderActions))
        .onRetryDraft!();
    await tester.pump();
    final status = tester
        .widget<ComposerHeaderActions>(find.byType(ComposerHeaderActions))
        .draftStatus!;
    for (var i = 0; i < 30 && status.value == DraftSaveStatus.saving; i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(status.value, DraftSaveStatus.conflict);
    await tester.tap(find.byKey(const ValueKey('composer-header-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('composer-draft-status-item')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(S.current.composer_draftUseRemote));
    await tester.pump();
    await _waitForRichDraft(tester, remote.data.reply!);
    await tester.pump(const Duration(seconds: 3));
    expect(status.value, DraftSaveStatus.saved);
    expect(store.entry?.data.reply, remote.data.reply);
    expect(store.entry?.synced, isTrue);
    expect(writes, hasLength(1));
    expect(writes.single['force_save'], isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(writes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final rich in [false, true]) {
    testWidgets('回复草稿恢复不回写旧内容，回到前台同步另一设备正文 rich=$rich', (tester) async {
      var remote = const Draft(
        draftKey: 'topic_1',
        sequence: 1,
        data: DraftData(reply: '另一设备保存的正文', action: 'reply'),
      );
      final store = MemoryDraftStore();
      final writes = <Map>[];
      await _pumpReply(
        tester,
        rich: rich,
        sheet: const ReplySheet(topicId: 1),
        remoteDraft: () => remote,
        draftStore: store,
        draftWrites: writes,
      );
      Future<void> waitForDocument() async {
        if (!rich) return;
        await _waitForRichDraft(tester, remote.data.reply!);
      }

      await waitForDocument();
      await tester.pump(const Duration(seconds: 3));
      TextEditingController content() => rich
          ? tester
                .widget<RichComposerEditor>(find.byType(RichComposerEditor))
                .controller
          : tester
                .widget<MarkdownEditor>(find.byType(MarkdownEditor))
                .controller;
      expect(content().text, remote.data.reply);
      expect(writes, isEmpty, reason: '恢复不是用户编辑，不能产生重复保存');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      remote = const Draft(
        draftKey: 'topic_1',
        sequence: 2,
        data: DraftData(reply: '另一设备更新后的正文', action: 'reply'),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await waitForDocument();
      await tester.pump(const Duration(seconds: 3));
      expect(content().text, remote.data.reply);
      expect(store.entry?.data.reply, remote.data.reply);
      expect(store.entry?.sequence, 2);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('桌面回复使用实际可用空间切换侧栏和横栏，预览往返保留正文', (tester) async {
    await _pumpReply(tester, width: 1200, desktop: true);
    expect(find.byType(ComposerDesktopWorkbench), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-desktop-rail')), findsOneWidget);
    final field = find.byType(EditableText).first;
    await tester.enterText(field, 'desktop reply');
    await tester.pump();
    final controller = tester.widget<EditableText>(field).controller;
    await tester.tap(find.byTooltip(S.current.composer_expandToolbar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('composer-tools-panel')), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.text, 'desktop reply');
    expect(find.byKey(const ValueKey('composer-tools-panel')), findsNothing);
    tester.view.physicalSize = const Size(600, 760);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('composer-desktop-rail')), findsNothing);
    expect(find.byKey(const ValueKey('composer-format-row')), findsOneWidget);
    expect(controller.text, 'desktop reply');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (width, scale, dark) in [
    (320.0, 1.0, false),
    (390.0, 1.0, false),
    (700.0, 1.0, true),
    (390.0, 2.0, false),
  ]) {
    testWidgets('回复页头统一尺寸、次级操作收纳且不收键盘 $width/$scale', (tester) async {
      await _pumpReply(
        tester,
        width: width,
        scale: scale,
        dark: dark,
        review: true,
        sheet: ReplySheet(topicId: 1, preloadedDraftFuture: Future.value(null)),
      );
      expect(tester.takeException(), isNull);
      final header = find.byKey(const ValueKey('reply-composer-header'));
      expect(tester.getSize(header).height, kToolbarHeight);
      expect(find.byType(ComposerHeaderActions), findsOneWidget);
      expect(find.byType(CloseButton), findsOneWidget);
      final send = find.byKey(const ValueKey('composer-header-submit'));
      final more = find.byKey(const ValueKey('composer-header-more'));
      expect(tester.getSize(send), const Size(48, 48));
      expect(find.byTooltip(S.current.common_send), findsOneWidget);
      if (width < 480) expect(tester.getSize(more), const Size(44, 44));
      expect(width - tester.getRect(send).right, 16);
      final lastAction = more;
      expect(tester.getRect(send).left - tester.getRect(lastAction).right, 8);
      expect(
        find.byType(ComposerPreviewButton),
        width >= 390 && scale == 1 ? findsOneWidget : findsNothing,
      );

      final field = find.descendant(
        of: find.byType(MarkdownEditor),
        matching: find.byType(TextField),
      );
      if (width < 480) {
        await tester.showKeyboard(field);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        tester.testTextInput.log.clear();
        await tester.tap(more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.byKey(const ValueKey('composer-header-discard')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-header-review')),
          findsOneWidget,
        );
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.hide',
          ),
          isEmpty,
        );
        if (width >= 390 && scale == 1) {
          await tester.tapAt(const Offset(2, 300));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('composer-header-preview-inline')),
          );
        } else {
          await tester.tap(
            find.byKey(const ValueKey('composer-header-preview')),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
      } else {
        expect(more, findsOneWidget);
        expect(
          find.byKey(const ValueKey('composer-header-review-inline')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-header-discard-inline')),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('实际回复弹框：预览往返保留编辑器、选区和撤销历史', (tester) async {
    await _pumpReply(tester);
    final source = tester.state<MarkdownEditorState>(
      find.byType(MarkdownEditor),
    );
    final textField = find.descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    );
    await tester.showKeyboard(textField);
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello world');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final controller = tester.widget<TextField>(textField).controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(find.byType(MarkdownEditor), findsNothing);
    expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(
      tester.state<MarkdownEditorState>(find.byType(MarkdownEditor)),
      same(source),
    );
    expect(controller.text, 'hello world');
    expect(controller.selection.extentOffset, 5);
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.toolbar_undo));
    await tester.pumpAndSettle();
    expect(controller.text, 'hello');
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.toolbar_redo));
    await tester.pumpAndSettle();
    expect(controller.text, 'hello world');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('富文本失效时真实发送与预览按钮均停止消费旧镜像', (tester) async {
    final requests = <String>[];
    await _pumpReply(
      tester,
      rich: true,
      requests: requests,
      sheet: const ReplySheet(topicId: 1),
    );
    await _waitForRichDraft(tester, '');
    final host = tester.state<RichComposerEditorState>(
      find.byType(RichComposerEditor),
    );
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('旧镜像正文');
    expect(host.flushToController(), isTrue);
    await tester.pump();
    editor.insertText('未同步的新内容');
    // 注入真实导出异常，保留语义树而不是退回旧镜像。
    RichComposerEditorState.debugBeforeExport = () =>
        throw StateError('测试导出失败');
    addTearDown(() => RichComposerEditorState.debugBeforeExport = null);
    requests.clear();
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    await tester.pump();
    expect(requests.where((request) => request.contains('/posts')), isEmpty);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(find.byKey(const ValueKey('reply-preview')), findsNothing);
    expect(find.byType(RichComposerEditor), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    final prefs = await SharedPreferences.getInstance();
    final backups = prefs.getStringList(
      RichComposerEditorState.recoveryStorageKey,
    );
    expect(backups, isNotEmpty);
    expect(backups!.join(), contains('未同步的新内容'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('富文本关闭前同步 debounce 窗口中的最新草稿', (tester) async {
    final writes = <Map>[];
    await _pumpReply(
      tester,
      rich: true,
      draftWrites: writes,
      sheet: const ReplySheet(topicId: 1),
    );
    await _waitForRichDraft(tester, '');
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('关闭前尚未 debounce 的最新正文');
    await tester.tap(find.byType(CloseButton));
    await tester.pump();
    // 测试根路由不能被 pop，强制卸载模拟路由最终移除。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(writes, isNotEmpty);
    expect(
      writes.map((write) => jsonDecode(write['data'] as String)['reply']),
      contains(contains('关闭前尚未 debounce 的最新正文')),
    );
  });

  testWidgets('富文本实际回复：预览使用最新内容并保留内核历史', (tester) async {
    await _pumpReply(tester, rich: true);
    final host = tester.state<RichComposerEditorState>(
      find.byType(RichComposerEditor),
    );
    final editor = tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 0),
      ),
    );
    editor.insertText('first');
    editor.sealHistory();
    editor.insertText(' second');
    editor.sealHistory();
    await tester.pump();
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(find.byType(RichComposerEditor), findsNothing);
    expect(find.byKey(const ValueKey('reply-preview')), findsOneWidget);
    await tester.tap(find.byType(ComposerPreviewButton));
    await tester.pump();
    expect(
      tester.state<RichComposerEditorState>(find.byType(RichComposerEditor)),
      same(host),
    );
    expect(
      tester.widget<FluxdoEditor>(find.byType(FluxdoEditor)).state,
      same(editor),
    );
    expect(docToMarkdown(editor.blocks), contains('first second'));
    await tester.tap(find.byType(ContentActionsButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(S.current.toolbar_undo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(docToMarkdown(editor.blocks).trim(), 'first');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('快捷面板搜索并执行格式，保持原正文选区', (tester) async {
    await _pumpReply(tester);
    final field = find.descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    );
    final controller = tester.widget<TextField>(field).controller!;
    await tester.showKeyboard(field);
    tester.testTextInput.enterText('hello');
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text(S.current.composer_quickPanel), findsOneWidget);
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == S.current.composer_searchTools,
    );
    await tester.enterText(search, S.current.toolPanel_bold);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, S.current.toolPanel_bold));
    await tester.pumpAndSettle();
    expect(controller.text, '**hello**');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
