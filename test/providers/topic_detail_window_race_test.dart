import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

/// 测试约定:帖子 id == 楼层号
Post _post(int id) {
  return Post(
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
}

List<int> _range(int from, int to) => [for (var i = from; i <= to; i++) i];

TopicDetail _detail(List<int> stream, List<int> loaded) {
  return TopicDetail(
    id: 1,
    title: 'Topic',
    slug: 'topic',
    postsCount: stream.length,
    postStream: PostStream(
      posts: [for (final id in loaded) _post(id)],
      stream: stream,
    ),
    categoryId: 1,
    closed: false,
    archived: false,
  );
}

PostStream _page(List<int> ids) =>
    PostStream(posts: [for (final id in ids) _post(id)], stream: ids);

typedef _DetailRequest = ({
  int? postNumber,
  String? filter,
  String? usernameFilters,
  bool filterTopLevelReplies,
});

/// 只实现 notifier 用到的几个接口;响应由各用例按需挂上
class _FakeDiscourseService implements DiscourseService {
  final detailRequests = <_DetailRequest>[];
  final postsRequests = <List<int>>[];

  late Future<TopicDetail> Function(_DetailRequest request) onTopicDetail;
  Future<PostStream> Function(int postNumber, bool asc)? onPostsByNumber;
  Future<PostStream> Function(List<int> ids)? onPosts;

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) {
    final request = (
      postNumber: postNumber,
      filter: filter,
      usernameFilters: usernameFilters,
      filterTopLevelReplies: filterTopLevelReplies,
    );
    detailRequests.add(request);
    return onTopicDetail(request);
  }

  @override
  Future<PostStream> getPostsByNumber(
    int topicId, {
    required int postNumber,
    required bool asc,
    bool includeSuggested = false,
  }) => onPostsByNumber!(postNumber, asc);

  @override
  Future<PostStream> getPosts(
    int topicId,
    List<int> postIds, {
    bool includeSuggested = false,
  }) {
    postsRequests.add(postIds);
    return onPosts!(postIds);
  }

  @override
  Future<Post> getPostByNumber(int topicId, int postNumber) async =>
      _post(postNumber);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 让已排队的微任务/零延迟定时器跑完
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  // AnchorGuardSliver.arm 需要 SchedulerBinding
  TestWidgetsFlutterBinding.ensureInitialized();

  const params = TopicDetailParams(1, instanceId: 'race-test');

  late _FakeDiscourseService service;
  late ProviderContainer container;

  Future<TopicDetailNotifier> open(TopicDetail initial) async {
    service.onTopicDetail = (_) async => initial;
    container.listen(topicDetailProvider(params), (_, _) {});
    await container.read(topicDetailProvider(params).future);
    return container.read(topicDetailProvider(params).notifier);
  }

  TopicDetail current() => container.read(topicDetailProvider(params)).value!;

  setUp(() {
    service = _FakeDiscourseService();
    container = ProviderContainer(
      overrides: [discourseServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
  });

  test('翻页在途时新回复 id 入 stream:页落地后 id 与 postsCount 都还在', () async {
    final notifier = await open(_detail(_range(1, 10), _range(4, 6)));
    final page = Completer<PostStream>();
    service.onPostsByNumber = (_, _) => page.future;

    final loading = notifier.loadMore();
    // 未到底分支:只记 id、postsCount + 1
    notifier.onNewPostCreated(11);
    expect(current().postStream.stream.last, 11);

    page.complete(_page(_range(7, 10)));
    await loading;

    final detail = current();
    expect(detail.postStream.posts.map((p) => p.id), _range(4, 10));
    expect(detail.postStream.stream, _range(1, 11));
    expect(detail.postsCount, 11);
    expect(notifier.hasMoreAfter, isTrue, reason: '11 还没加载内容');
    expect(notifier.isLoadingMore, isFalse);
  });

  test('翻页在途时点赞落地:页落地后点赞不被回滚', () async {
    final notifier = await open(_detail(_range(1, 10), _range(4, 6)));
    final page = Completer<PostStream>();
    service.onPostsByNumber = (_, _) => page.future;

    final loading = notifier.loadMore();
    notifier.updatePostLikes(5, likesCount: 7);

    page.complete(_page(_range(7, 10)));
    await loading;

    expect(current().postStream.posts[1].likeCount, 7);
  });

  test('刷新在途时的旧翻页结果被丢弃', () async {
    final notifier = await open(_detail(_range(1, 30), _range(4, 6)));
    final page = Completer<PostStream>();
    service.onPostsByNumber = (_, _) => page.future;

    final loading = notifier.loadMore();
    service.onTopicDetail = (_) async => _detail(_range(1, 30), _range(20, 22));
    await notifier.refreshWithPostNumber(21);

    page.complete(_page(_range(7, 10)));
    await loading;

    expect(current().postStream.posts.map((p) => p.id), _range(20, 22));
    expect(notifier.isLoadingMore, isFalse);
  });

  test('翻页拿不到新帖时到头,不再反复空翻', () async {
    final notifier = await open(_detail(_range(1, 10), _range(4, 8)));
    var calls = 0;
    service.onPostsByNumber = (_, _) async {
      calls++;
      return _page(const []);
    };

    await notifier.loadMore();
    await notifier.loadMore();

    expect(calls, 1);
    expect(notifier.hasMoreAfter, isFalse);
  });

  test('切换视图后,切换前安排的新回复退避重试不再拼进过滤视图', () async {
    final notifier = await open(_detail(_range(1, 5), _range(1, 5)));
    service.onPosts = (_) async => throw Exception('offline');

    // 已到底:新回复入待拉队列,拉取失败 → 3 秒后退避重试
    notifier.onNewPostCreated(6);
    await _settle();
    expect(service.postsRequests, [
      [6],
    ]);

    service.onTopicDetail = (_) async => _detail(const [1, 3], const [1, 3]);
    await notifier.setViewMode(TopicViewMode.summary);
    expect(service.detailRequests.last.filter, 'summary');

    service.onPosts = (ids) async => _page(ids);
    // 等过第一次退避(3 秒)
    await Future<void>.delayed(const Duration(milliseconds: 3500));

    expect(service.postsRequests, hasLength(1));
    expect(current().postStream.posts.map((p) => p.id), [1, 3]);
    expect(current().postStream.stream, [1, 3]);
  });

  test('过滤视图不收实时新回复', () async {
    final notifier = await open(_detail(_range(1, 5), _range(1, 5)));
    service.onTopicDetail = (_) async => _detail(const [1, 3], const [1, 3]);
    await notifier.setViewMode(TopicViewMode.user('user3'));

    notifier.onNewPostCreated(6);
    await _settle();

    expect(service.postsRequests, isEmpty);
    expect(current().postStream.stream, [1, 3]);
  });

  test('只看顶层回复:下拉刷新带上过滤参数并保留 1 楼', () async {
    final notifier = await open(_detail(_range(1, 8), _range(1, 8)));
    service.onTopicDetail = (_) async =>
        _detail(const [2, 5, 7], const [2, 5, 7]);

    await notifier.setViewMode(TopicViewMode.topLevel);
    expect(current().postStream.posts.map((p) => p.id), [1, 2, 5, 7]);

    await notifier.refreshWithPostNumber(5);

    final request = service.detailRequests.last;
    expect(request.filterTopLevelReplies, isTrue);
    expect(request.postNumber, isNull, reason: '过滤视图刷新从头重载');
    expect(current().postStream.posts.map((p) => p.id), [1, 2, 5, 7]);
    expect(notifier.hasMoreBefore, isFalse);
  });

  test('取消过滤并跳楼层不再带任何过滤参数', () async {
    final notifier = await open(_detail(_range(1, 8), _range(1, 8)));
    service.onTopicDetail = (_) async => _detail(const [2, 5], const [2, 5]);
    await notifier.setViewMode(TopicViewMode.topLevel);

    service.onTopicDetail = (_) async => _detail(_range(1, 8), _range(5, 8));
    await notifier.setViewMode(TopicViewMode.all, postNumber: 6);

    final request = service.detailRequests.last;
    expect(request.postNumber, 6);
    expect(request.filter, isNull);
    expect(request.usernameFilters, isNull);
    expect(request.filterTopLevelReplies, isFalse);
    expect(notifier.viewMode, TopicViewMode.all);
  });
}
