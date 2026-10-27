import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

/// 测试约定:帖子 id == 楼层号
Post _post(int id) => Post(
  id: id,
  username: 'user$id',
  avatarTemplate: '',
  cooked: '<p>$id</p>',
  postNumber: id,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);

TopicDetail _detail({
  int id = 7,
  List<int> loaded = const [1, 2, 3],
  int highest = 3,
}) => TopicDetail(
  id: id,
  title: 'Topic',
  slug: 'topic',
  postsCount: highest,
  highestPostNumber: highest,
  postStream: PostStream(
    posts: [for (final n in loaded) _post(n)],
    stream: [for (var n = 1; n <= highest; n++) n],
  ),
  categoryId: 1,
  closed: false,
  archived: false,
);

class _FakeDiscourseService implements DiscourseService {
  int detailRequests = 0;
  TopicDetail Function() next = _detail;

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async {
    detailRequests++;
    return next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var clock = DateTime(2026, 10, 27, 12);
  setUp(() {
    TopicDetailMemoryCache.clear();
    clock = DateTime(2026, 10, 27, 12);
    TopicDetailMemoryCache.now = () => clock;
  });
  tearDown(() {
    TopicDetailMemoryCache.clear();
    TopicDetailMemoryCache.now = DateTime.now;
  });

  group('TopicDetailMemoryCache.take', () {
    test('列表最高楼层没超过缓存：复用', () {
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNotNull,
      );
    });

    test('有新回复 / 没给列表楼层 / 过期 / 目标楼层不在窗口：不复用', () {
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 4,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: null,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail());
      clock = clock.add(const Duration(minutes: 4));
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail(loaded: [2, 3], highest: 3));
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
        reason: '从头看但缓存里没有 1 楼',
      );
    });

    test('取一次就作废', () {
      TopicDetailMemoryCache.put(_detail());
      TopicDetailMemoryCache.take(
        7,
        expectedHighestPostNumber: 3,
        targetPostNumber: 2,
      );
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: 2,
        ),
        isNull,
      );
    });

    test('超过上限时丢最旧的', () {
      for (var id = 1; id <= TopicDetailMemoryCache.maxEntries + 1; id++) {
        TopicDetailMemoryCache.put(_detail(id: id));
      }
      expect(
        TopicDetailMemoryCache.take(
          1,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
      );
      expect(
        TopicDetailMemoryCache.take(
          2,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNotNull,
      );
    });
  });

  group('详情 provider', () {
    late _FakeDiscourseService service;
    late ProviderContainer container;

    setUp(() {
      service = _FakeDiscourseService();
      container = ProviderContainer(
        overrides: [discourseServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
    });

    Future<TopicDetail> open(TopicDetailParams params) async {
      final sub = container.listen(topicDetailProvider(params), (_, _) {});
      final detail = await container.read(topicDetailProvider(params).future);
      // 离开页面
      sub.close();
      await Future<void>.delayed(Duration.zero);
      return detail;
    }

    test('离开后马上从列表点回来、没有新回复：不再请求', () async {
      await open(
        const TopicDetailParams(
          7,
          instanceId: 'a',
          expectedHighestPostNumber: 3,
        ),
      );
      expect(service.detailRequests, 1);
      final again = await open(
        const TopicDetailParams(
          7,
          instanceId: 'b',
          expectedHighestPostNumber: 3,
        ),
      );
      expect(service.detailRequests, 1);
      expect(again.postStream.posts.map((p) => p.postNumber), [1, 2, 3]);
    });

    test('列表显示有新回复：照常请求', () async {
      await open(
        const TopicDetailParams(
          7,
          instanceId: 'a',
          expectedHighestPostNumber: 3,
        ),
      );
      service.next = () => _detail(loaded: [1, 2, 3, 4], highest: 4);
      final again = await open(
        const TopicDetailParams(
          7,
          instanceId: 'b',
          expectedHighestPostNumber: 4,
        ),
      );
      expect(service.detailRequests, 2);
      expect(again.highestPostNumber, 4);
    });

    test('页面里下拉刷新（重建）不读缓存', () async {
      const params = TopicDetailParams(
        7,
        instanceId: 'a',
        expectedHighestPostNumber: 3,
      );
      container.listen(topicDetailProvider(params), (_, _) {});
      await container.read(topicDetailProvider(params).future);
      // 另一个实例离开时留下了一份
      TopicDetailMemoryCache.put(_detail());
      container.invalidate(topicDetailProvider(params));
      await container.read(topicDetailProvider(params).future);
      expect(service.detailRequests, 2);
    });
  });
}
