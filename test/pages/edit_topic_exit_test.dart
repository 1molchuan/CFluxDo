// issue #3：三级用户编辑别人的话题（能改标题 / 分类 / 标签，不能改正文）时，
// 页面不挂正文编辑器，旧逻辑把「没有富文本编辑器」当成正文未同步，返回和保存
// 都被拦下，只能杀进程。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/edit_topic_page.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';

const _raw = '别人写的首贴正文，三级用户只能看不能改，用来验证返回不被拦下。';
const _title = '别人发的话题标题，三级用户可以改它';

Map<String, dynamic> _postJson({required bool canEdit}) => {
  'id': 21,
  'username': 'someone_else',
  'avatar_template': '',
  'cooked': '<p>正文</p>',
  'raw': _raw,
  'post_number': 1,
  'post_type': 1,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'can_edit': canEdit,
};

Future<void> _openEditPage(
  WidgetTester tester,
  List<RequestOptions> requests, {
  required bool canEditPost,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': true});
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final prefs = await SharedPreferences.getInstance();
  final dio = DiscourseService().dio;
  final post = _postJson(canEdit: canEditPost);
  final mock = InterceptorsWrapper(
    onRequest: (request, handler) {
      requests.add(request);
      handler.resolve(
        Response(
          requestOptions: request,
          data: request.path == '/posts/21.json'
              ? post
              : {'basic_topic': {'id': 11, 'title': _title}},
        ),
      );
    },
  );
  dio.interceptors.insert(0, mock);
  addTearDown(() => dio.interceptors.remove(mock));
  await tester.runAsync(() async {
    await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'min_topic_title_length': 6, 'min_first_post_length': 20, 'max_post_length': 10000},
        'site': {'categories': [], 'top_tags': []},
      })}</script>',
    );
    await DiscourseCookService().ensureInitialized();
  });
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      localDraftStoreProvider.overrideWithValue(MemoryDraftStore()),
      categoriesProvider.overrideWith(
        (_) async => [
          Category.fromJson({
            'id': 1,
            'name': '测试分类',
            'color': '4b73e6',
            'permission': 1,
          }),
        ],
      ),
      tagsProvider.overrideWith((_) async => []),
      canTagTopicsProvider.overrideWith((_) async => false),
    ],
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
          home: const Scaffold(body: Text('话题详情')),
        ),
      ),
    ),
  );
  navigatorKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => EditTopicPage(
        topicDetail: TopicDetail(
          id: 11,
          title: _title,
          slug: 'test',
          postsCount: 1,
          postStream: PostStream(posts: [], stream: [21]),
          categoryId: 1,
          closed: false,
          archived: false,
          canEdit: true,
        ),
        firstPost: Post.fromJson(post),
      ),
    ),
  );
  // 等首贴原文加载完（正文以只读渲染出现）
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (requests.any((r) => r.path == '/posts/21.json') &&
        find.byType(EditTopicPage).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
  fail('编辑页没有加载首贴');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('只能改元数据时，返回能退出编辑页', (tester) async {
    final requests = <RequestOptions>[];
    await _openEditPage(tester, requests, canEditPost: false);
    expect(find.byType(EditTopicPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);

    expect(find.byType(EditTopicPage), findsNothing);
    expect(find.text('话题详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只能改元数据时，改了标题能保存，不提交正文', (tester) async {
    final requests = <RequestOptions>[];
    await _openEditPage(tester, requests, canEditPost: false);

    await tester.enterText(find.byType(TextFormField).first, '$_title（改）');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-header-submit')));
    await _settle(tester);

    final writes = requests.where((r) => r.method == 'PUT').toList();
    expect(writes.map((r) => r.path), ['/t/-/11.json']);
    expect(find.byType(EditTopicPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
