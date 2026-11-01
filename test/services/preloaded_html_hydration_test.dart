// 游客快照复用测试参考 liansishen/fluxdo@223f75af，原作者 liansishen。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _snapshot(Map<String, dynamic> data, {bool hasSetup = true}) =>
    '${hasSetup ? '<meta id="data-discourse-setup">' : ''}'
    '<script id="data-preloaded" type="application/json">'
    '${jsonEncode(data)}</script>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PreloadedDataService preload;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preload = PreloadedDataService()..reset();
  });
  tearDown(() => preload.reset());

  // 访客页面可能省略 currentUser，也可能显式输出 null，两种形式都要覆盖。
  const anonymousUsers = <String, Map<String, dynamic>>{
    '缺失': {},
    '为 null': {'currentUser': null},
  };

  for (final anonymousUser in anonymousUsers.entries) {
    test('启动允许访客时复用 currentUser ${anonymousUser.key}的完整快照并清除旧用户', () async {
      // 先确认旧快照确实带着登录用户，避免清理断言在空缓存上误通过。
      expect(
        await preload.hydrateFromHtml(
          _snapshot({
            'currentUser': {'id': 1, 'username': 'previous'},
            'siteSettings': {'title': '旧快照'},
            'site': {
              'categories': [
                {'id': 1, 'name': '旧分类'},
              ],
            },
          }),
        ),
        isTrue,
      );
      expect(preload.currentUserSync?['username'], 'previous');
      expect(preload.categoryIdsSync, {1});

      final hydrated = await preload.hydrateFromHtml(
        _snapshot({
          ...anonymousUser.value,
          'siteSettings': {'title': '访客首页'},
          'site': {
            'categories': [
              {'id': 42, 'name': '公开分类'},
            ],
          },
        }),
        allowAnonymous: true,
      );

      expect(hydrated, isTrue);
      expect(preload.isLoaded, isTrue);
      expect(preload.currentUserSync, isNull);
      expect(preload.siteSettingsSync?['title'], '访客首页');
      expect(preload.categoryIdsSync, {42});
    });

    test('登录收口默认拒绝 currentUser ${anonymousUser.key}的匿名快照', () async {
      // 故意不传 allowAnonymous，锁住登录收口默认必须有用户的约束。
      final hydrated = await preload.hydrateFromHtml(
        _snapshot({
          ...anonymousUser.value,
          'siteSettings': {'title': '访客首页'},
          'site': {'categories': []},
        }),
      );

      expect(hydrated, isFalse);
      expect(preload.isLoaded, isFalse);
      expect(preload.currentUserSync, isNull);
      expect(preload.siteSettingsSync, isNull);
      expect(preload.siteSync, isNull);
      expect(preload.categoryIdsSync, isNull);
    });
  }

  test('两轮快照恢复交叠时首页列表与用户一致，不抛 Future already completed', () async {
    String withTopic(int id) => _snapshot({
      'currentUser': {'id': id, 'username': 'user$id'},
      'siteSettings': {'title': '首页'},
      'site': {'categories': []},
      'topicList': jsonEncode({
        'topic_list': {
          'topics': [
            {
              'id': id,
              'title': 'topic $id',
              'slug': 'topic-$id',
              'posts_count': 1,
              'reply_count': 0,
              'views': 0,
              'like_count': 0,
            },
          ],
        },
      }),
    });

    // 两轮的异步解析谁先回来不确定；以前它们共用一个 completer，后回来的
    // 那轮再 complete 一次就抛 StateError（在没人等的 Future 链里，成了
    // 未捕获异常）
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final first = preload.hydrateFromHtml(withTopic(1));
      final second = preload.hydrateFromHtml(withTopic(2));
      expect(await first, isTrue);
      expect(await second, isTrue);
      final list = await preload.getInitialTopicList();
      expect(list?.topics.map((t) => t.id), [preload.currentUserSync?['id']]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (error, _) => errors.add(error));
    expect(errors, isEmpty);
  });

  // 允许匿名只放宽用户要求，不能绕过站点引导数据的完整性检查。
  final incompleteSnapshots = <String, String>{
    '缺少 setup 的快照': _snapshot({
      'siteSettings': {},
      'site': {},
    }, hasSetup: false),
    '缺少 site 的快照': _snapshot({'siteSettings': {}}),
    '缺少 siteSettings 的快照': _snapshot({'site': {}}),
    'Cloudflare 挑战页': '<html><title>Just a moment...</title></html>',
  };

  for (final snapshot in incompleteSnapshots.entries) {
    test('允许访客时仍拒绝${snapshot.key}', () async {
      final hydrated = await preload.hydrateFromHtml(
        snapshot.value,
        allowAnonymous: true,
      );

      expect(hydrated, isFalse);
      expect(preload.isLoaded, isFalse);
      expect(preload.currentUserSync, isNull);
      expect(preload.siteSettingsSync, isNull);
      expect(preload.siteSync, isNull);
      expect(preload.categoryIdsSync, isNull);
    });
  }
}
