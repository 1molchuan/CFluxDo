import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

Post _post(int id, {String? cooked, bool read = false, int likeCount = 0}) {
  return Post(
    id: id,
    username: 'user$id',
    avatarTemplate: '',
    cooked: cooked ?? '<p>$id</p>',
    postNumber: id,
    postType: 1,
    updatedAt: DateTime(2026),
    createdAt: DateTime(2026),
    likeCount: likeCount,
    replyCount: 0,
    read: read,
  );
}

TopicDetail _detail() {
  return TopicDetail(
    id: 1,
    title: 'Topic',
    slug: 'topic',
    postsCount: 3,
    postStream: PostStream(
      posts: [
        for (final id in [1, 2, 3]) _post(id, read: true),
      ],
      stream: const [1, 2, 3],
    ),
    categoryId: 1,
    closed: false,
    archived: false,
  );
}

/// getPost 每次调用挂一个 Completer,由用例决定何时、以什么结果落地
class _FakeDiscourseService implements DiscourseService {
  final postRequests = <Completer<Post>>[];

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async => _detail();

  @override
  Future<Post> getPost(int postId) {
    final completer = Completer<Post>();
    postRequests.add(completer);
    return completer.future;
  }

  @override
  Future<Post> getPostByNumber(int topicId, int postNumber) async =>
      _post(postNumber);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  // AnchorGuardSliver.arm 需要 SchedulerBinding
  TestWidgetsFlutterBinding.ensureInitialized();

  const pageA = TopicDetailParams(1, instanceId: 'refresh-a');
  const pageB = TopicDetailParams(1, instanceId: 'refresh-b');

  late _FakeDiscourseService service;
  late ProviderContainer container;

  Future<TopicDetailNotifier> open(TopicDetailParams params) async {
    container.listen(topicDetailProvider(params), (_, _) {});
    await container.read(topicDetailProvider(params).future);
    return container.read(topicDetailProvider(params).notifier);
  }

  Post postOf(TopicDetailParams params, int id) => container
      .read(topicDetailProvider(params))
      .value!
      .postStream
      .posts
      .firstWhere((p) => p.id == id);

  setUp(() {
    service = _FakeDiscourseService();
    container = ProviderContainer(
      overrides: [discourseServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
  });

  test('同一话题开两页:两页各自刷新同一帖子,后一页的请求不被前一页吞掉', () async {
    final a = await open(pageA);
    final b = await open(pageB);

    final refreshA = a.refreshPost(2);
    final refreshB = b.refreshPost(2);
    await _settle();
    expect(service.postRequests, hasLength(2), reason: '每页各发一次单帖请求');

    service.postRequests[0].complete(_post(2, likeCount: 5));
    service.postRequests[1].complete(_post(2, likeCount: 5));
    await Future.wait([refreshA, refreshB]);
    await _settle();

    expect(postOf(pageA, 2).likeCount, 5);
    expect(postOf(pageB, 2).likeCount, 5);
    expect(service.postRequests, hasLength(2), reason: '各自没有多余的尾部重试');
  });

  test('同一页在途期间再来消息:只发一次,落地后尾部重试一次且保留 preserveCooked 语义', () async {
    final a = await open(pageA);

    final first = a.refreshPost(2, preserveCooked: true);
    unawaited(a.refreshPost(2, preserveCooked: true));
    await _settle();
    expect(service.postRequests, hasLength(1));

    service.postRequests[0].complete(
      _post(2, cooked: '<p>new</p>', likeCount: 1),
    );
    await first;
    await _settle();
    // 窗口内两条都要求保留 cooked:尾部重试也保留
    expect(service.postRequests, hasLength(2));
    service.postRequests[1].complete(
      _post(2, cooked: '<p>newer</p>', likeCount: 2),
    );
    await _settle();
    await _settle();

    final post = postOf(pageA, 2);
    expect(post.likeCount, 2);
    expect(post.cooked, '<p>2</p>');
    expect(post.read, isTrue);
  });
}
