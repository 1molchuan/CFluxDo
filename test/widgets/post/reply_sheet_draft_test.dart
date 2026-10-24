import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/rich_composer/rich_composer_editor.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/memory_draft_store.dart';

/// 对照上游 v0.2.29 reply_sheet_preview_test 的草稿用例，换成 cfluxdo
/// 回复框的页头（草稿状态图标直出，没有「更多」菜单）。
Future<void> _pumpReply(
  WidgetTester tester, {
  required bool rich,
  required Draft? Function() remoteDraft,
  required MemoryDraftStore draftStore,
  required List<Map> draftWrites,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': rich});
  final prefs = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final mock = InterceptorsWrapper(
    onRequest: (options, handler) {
      final draft = remoteDraft();
      if (options.method == 'POST' && options.path == '/drafts.json') {
        draftWrites.add(Map.of(options.data as Map));
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
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        localDraftStoreProvider.overrideWithValue(draftStore),
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
          home: const Scaffold(body: ReplySheet(topicId: 1)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _hydrateSite() async {
  final loaded = await PreloadedDataService().hydrateFromHtml(
    '<meta id="data-discourse-setup">'
    '<script id="data-preloaded" type="application/json">${jsonEncode({
      'currentUser': {'id': 1, 'username': 'tester'},
      'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
      'site': {'categories': [], 'top_tags': []},
    })}</script>',
  );
  expect(loaded, isTrue);
}

Future<void> _settleAsync(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

String? _richText(WidgetTester tester) {
  final editors = find.byType(FluxdoEditor).evaluate();
  if (editors.length != 1) return null;
  return docToMarkdown(
    (editors.single.widget as FluxdoEditor).state.blocks,
  ).trim();
}

Future<void> _waitForRichDraft(WidgetTester tester, String text) async {
  await _settleAsync(tester, () => _richText(tester) == text);
  expect(_richText(tester), text, reason: '富文本内部文档没有同步到云端内容');
}

/// 富文本导入要过 cook 门禁，宿主没有 QuickJS 动态库时富文本用例跳过。
String? _richSkipReason() {
  if (!Platform.isLinux) return null;
  try {
    DynamicLibrary.open('libquickjs_c_bridge_plugin.so');
    return null;
  } catch (_) {
    return '宿主加载不了 libquickjs_c_bridge_plugin.so（LD_LIBRARY_PATH 指向桌面构建的 lib/ 后可跑）';
  }
}

void main() {
  final richSkip = _richSkipReason();

  // cook 引擎（QuickJS）是单例：在真实异步里初始化一次，免得第一个用例的
  // FakeAsync 里留下的初始化 Future 把后面的用例卡死。宿主上需要能加载
  // libquickjs_c_bridge_plugin.so（Linux 用桌面构建产物，LD_LIBRARY_PATH 指过去）。
  setUpAll(() async {
    await _hydrateSite();
    if (richSkip == null) {
      expect(await DiscourseCookService().ensureInitialized(), isTrue);
    }
  });

  for (final rich in [false, true]) {
    testWidgets(
      '回复草稿恢复不回写旧内容，回到前台同步另一设备正文 rich=$rich',
      skip: rich && richSkip != null,
      (tester) async {
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
          remoteDraft: () => remote,
          draftStore: store,
          draftWrites: writes,
        );
        TextEditingController? content() {
          final finder = rich
              ? find.byType(RichComposerEditor)
              : find.byType(MarkdownEditor);
          if (finder.evaluate().isEmpty) return null;
          return rich
              ? tester.widget<RichComposerEditor>(finder).controller
              : tester.widget<MarkdownEditor>(finder).controller;
        }

        Future<void> waitForContent(String text) async {
          await _settleAsync(tester, () => content()?.text == text);
          if (rich) await _waitForRichDraft(tester, text);
        }

        await waitForContent(remote.data.reply!);
        await tester.pump(const Duration(seconds: 3));
        expect(content()?.text, remote.data.reply);
        expect(writes, isEmpty, reason: '恢复不是用户编辑，不能产生重复保存');

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        remote = const Draft(
          draftKey: 'topic_1',
          sequence: 2,
          data: DraftData(reply: '另一设备更新后的正文', action: 'reply'),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await waitForContent(remote.data.reply!);
        await tester.pump(const Duration(seconds: 3));
        expect(content()?.text, remote.data.reply);
        expect(store.entry?.data.reply, remote.data.reply);
        expect(store.entry?.sequence, 2);
        expect(writes, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('富文本冲突时从更多菜单选云端，重建文档且旧编辑器卸载不回写', skip: richSkip != null, (
    tester,
  ) async {
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
    // 富文本 800ms 镜像 + 草稿 2s 防抖后发出保存，撞 409 后核对云端 → 冲突，
    // 页头「更多」入口挂上提醒红点
    final attention = find.byKey(const ValueKey('composer-draft-attention'));
    for (var i = 0; i < 6 && attention.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
      await _settleAsync(tester, () => attention.evaluate().isNotEmpty);
    }
    expect(attention, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('composer-header-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text(
        '${S.current.composer_draftConflict} · ${S.current.composer_draftResolve}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('composer-draft-status-item')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(S.current.composer_draftUseRemote));
    await tester.pump();
    await _waitForRichDraft(tester, remote.data.reply!);
    await tester.pump(const Duration(seconds: 3));
    expect(store.entry?.data.reply, remote.data.reply);
    expect(store.entry?.synced, isTrue);
    expect(writes, hasLength(1));
    expect(writes.single['force_save'], isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(writes, hasLength(1), reason: '旧编辑器卸载不能把本机版本写回去');
    expect(tester.takeException(), isNull);
  });
}
