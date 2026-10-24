import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/models/nested_reading_position.dart';
import 'package:fluxdo/models/read_later_item.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/nested_reading_provider.dart';
import 'package:fluxdo/providers/pinned_categories_provider.dart';
import 'package:fluxdo/providers/read_later_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/services/site_data_lifecycle.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:hive_ce/hive.dart';
import 'package:fluxdo/storage/app_database.dart';
import 'package:fluxdo/storage/chat_cache_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_draft_store.dart';
import 'startup/app_startup_fakes.dart';

class _UnusedDiscourseService extends Fake implements DiscourseService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      SiteContext.selectionKey: ForumSite.idcFlare.id,
    });
    await SiteContext.initialize(await SharedPreferences.getInstance());
  });

  test('同名用户缓存只展示当前站且失效时不清另一站', () async {
    final linuxCache = jsonEncode(User(id: 7, username: 'alice', trustLevel: 2).toCacheJson());
    SharedPreferences.setMockInitialValues({
      'current_user_cache': linuxCache,
      'current_user_cache_username': 'alice',
      'site:idcflare:current_user_cache': jsonEncode(User(id: 9, username: 'alice', trustLevel: 1).toCacheJson()),
      'site:idcflare:current_user_cache_username': 'alice',
    });
    final ports = FakeStartupPorts()..storedSessionGate = Completer<bool>();
    final startup = AppStartup(ports: ports)..storesReady()..launch();
    final container = ProviderContainer(overrides: [appStartupProvider.overrideWithValue(startup)]);
    addTearDown(container.dispose);
    final subscription = container.listen(currentUserProvider, (_, _) {});
    addTearDown(subscription.close);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(currentUserProvider).value?.id, 9);
    ports.storedSessionGate!.complete(false);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(currentUserProvider).value, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('current_user_cache'), linuxCache);
    expect(prefs.getString('site:idcflare:current_user_cache'), isNull);
  });

  test('同名账号同话题的阅读落点与排序不读取或覆盖旧站', () async {
    SharedPreferences.setMockInitialValues({
      'nested_reading_v1_alice': jsonEncode({
        '42': const NestedReadingPosition(
          postNumber: 9,
          rootPostNumber: 9,
        ).toJson(),
      }),
      'nested_sort_alice': 'top',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = NestedReadingStore(prefs, 'alice');
    expect(store.position(42), isNull);
    expect(store.sort, 'old');
    store.save(42, const NestedReadingPosition(postNumber: 2, rootPostNumber: 2));
    await store.setSort('new');
    await SiteDataLifecycle.flushBeforeSwitch();
    final reopened = NestedReadingStore(prefs, 'alice');
    expect(reopened.position(42)?.postNumber, 2);
    reopened.dispose();
    expect(prefs.getString('nested_sort_alice'), 'top');
    expect(prefs.getString('nested_sort_idcflare::alice'), 'new');
    final old = jsonDecode(prefs.getString('nested_reading_v1_alice')!) as Map;
    expect((old['42'] as Map)['post'], 9);
    store.dispose();
  });

  test('相同话题与分类ID的稍后阅读和固定分类保留两站归属', () async {
    final linuxItem = ReadLaterItem(
      topicId: 42,
      title: '旧站话题',
      addedAt: DateTime(2026),
    );
    SharedPreferences.setMockInitialValues({
      'read_later_items': jsonEncode([linuxItem.toJson()]),
      'pinned_category_ids': ['7'],
    });
    final prefs = await SharedPreferences.getInstance();
    final later = ReadLaterNotifier(prefs);
    final pinned = PinnedCategoriesNotifier(prefs);
    expect(later.state, isEmpty);
    expect(pinned.state, isEmpty);
    later.add(ReadLaterItem(topicId: 42, title: '新站话题', addedAt: DateTime(2026)));
    pinned.add(8);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getStringList('pinned_category_ids'), ['7']);
    expect(prefs.getStringList('site:idcflare:pinned_category_ids'), ['8']);
    expect((jsonDecode(prefs.getString('read_later_items')!) as List).single['title'], '旧站话题');
    expect((jsonDecode(prefs.getString('site:idcflare:read_later_items')!) as List).single['title'], '新站话题');
    later.dispose();
    pinned.dispose();
  });

  test('草稿在相同box中仍按站点账号隔离且保留LinuxDO原键', () async {
    final directory = await Directory.systemTemp.createTemp('site_drafts_');
    final box = await Hive.openBox<Map>('site_isolation_drafts', path: directory.path);
    addTearDown(() async {
      await box.close();
      await directory.delete(recursive: true);
    });
    final oldKey = jsonEncode(['alice', 'topic_42']);
    await box.put(oldKey, {
      'data': const DraftData(reply: '旧站草稿').toJsonString(),
      'sequence': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    final store = LocalDraftStore(boxFactory: () async => box);
    expect(await store.read('alice', 'topic_42'), isNull);
    await store.write(
      accountId: 'alice',
      draftKey: 'topic_42',
      data: const DraftData(reply: '新站草稿'),
      sequence: 2,
    );
    expect((await store.read('alice', 'topic_42'))?.data.reply, '新站草稿');
    expect((await store.list('alice')).keys, ['topic_42']);
    final legacy = jsonDecode(box.get(oldKey)!['data'] as String) as Map;
    expect(legacy['reply'], '旧站草稿');
    expect(box.containsKey(jsonEncode(['idcflare::alice', 'topic_42'])), isTrue);
  });

  test('同名账号的书签box与聊天快照不命中旧站文件', () async {
    final directory = await Directory.systemTemp.createTemp('site_boxes_');
    Hive.init(directory.path);
    AppDatabase.debugMarkInitialized();
    final oldBookmarks = await Hive.openBox<Map>('bookmark_cache_alice');
    final oldChat = await Hive.openBox<Map>('chat_cache_alice');
    await oldBookmarks.put(42, {'name_normalized': '旧站书签'});
    await oldChat.put('dm_channels_snapshot', {'channels': '[{"id":42}]'});
    final bookmarks = await AppDatabase.bookmarkBox('alice');
    final chat = ChatCacheDao();
    expect(bookmarks.get(42), isNull);
    expect(await chat.readSnapshot('alice'), isNull);
    await bookmarks.put(42, {'name_normalized': '新站书签'});
    await chat.writeSnapshot('alice', channels: [{'id': 9}], tracking: {});
    await SiteDataLifecycle.flushBeforeSwitch();
    expect(oldBookmarks.get(42)!['name_normalized'], '旧站书签');
    expect((await chat.readSnapshot('alice'))!.channels.single['id'], 9);
    expect(oldChat.get('dm_channels_snapshot')!['channels'], '[{"id":42}]');
    await AppDatabase.closeBookmarkBox('alice');
    final currentChat = await AppDatabase.namedBox('chat_cache_idcflare__alice');
    await currentChat.close();
    await oldBookmarks.close();
    await oldChat.close();
    await AppDatabase.debugReset();
    await directory.delete(recursive: true);
  });

  test('切站收取编辑器最新现场而不等待云端保存', () async {
    final store = MemoryDraftStore();
    var collected = false;
    final controller = DraftController(
      draftKey: 'topic_42',
      service: _UnusedDiscourseService(),
      localStore: store,
      accountIdResolver: () async => 'alice',
      connectionStream: const Stream.empty(),
      isConnected: () => false,
      currentEditorData: () {
        collected = true;
        return const DraftData(reply: '尚未触发防抖的富文本');
      },
    );
    addTearDown(controller.dispose);
    await SiteDataLifecycle.flushBeforeSwitch();
    expect(collected, isTrue);
    expect(store.entry?.data.reply, '尚未触发防抖的富文本');
  });

  test('无法收取编辑现场时拒绝切站', () async {
    final controller = DraftController(
      draftKey: 'topic_42',
      service: _UnusedDiscourseService(),
      localStore: MemoryDraftStore(),
      accountIdResolver: () async => 'alice',
      connectionStream: const Stream.empty(),
      isConnected: () => false,
      currentEditorData: () => null,
    );
    addTearDown(controller.dispose);
    await expectLater(SiteDataLifecycle.flushBeforeSwitch(), throwsStateError);
  });
}
