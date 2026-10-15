import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/topic_detail/topic_view_mode.dart';

Post _post(int number, String username) {
  return Post(
    id: 100 + number,
    username: username,
    avatarTemplate: '',
    cooked: '',
    postNumber: number,
    postType: 1,
    updatedAt: DateTime(2026),
    createdAt: DateTime(2026),
    likeCount: 0,
    replyCount: 0,
  );
}

TopicDetail _detail({
  List<Post> posts = const [],
  int streamLength = 0,
  int postsCount = 0,
  bool hasSummary = true,
}) {
  return TopicDetail(
    id: 1,
    title: 'Topic',
    slug: 'topic',
    postsCount: postsCount,
    postStream: PostStream(
      posts: posts,
      stream: [for (var i = 0; i < streamLength; i++) 100 + i],
    ),
    categoryId: 1,
    closed: false,
    archived: false,
    hasSummary: hasSummary,
  );
}

/// 每种模式一行:请求参数与行为开关
typedef _Row = ({
  TopicViewMode mode,
  String? filter,
  String? usernameFilters,
  bool topLevel,
  bool isFiltered,
  TopicPagingStrategy paging,
  bool acceptsLivePosts,
  bool refreshesNearAnchor,
  bool pinsFirstPost,
  bool restoresFirstPost,
  TopicJumpPolicy jumpPolicy,
});

const List<_Row> _table = [
  (
    mode: TopicViewMode.all,
    filter: null,
    usernameFilters: null,
    topLevel: false,
    isFiltered: false,
    paging: TopicPagingStrategy.byPostNumber,
    acceptsLivePosts: true,
    refreshesNearAnchor: true,
    pinsFirstPost: false,
    restoresFirstPost: false,
    jumpPolicy: TopicJumpPolicy.reloadInPlace,
  ),
  (
    mode: TopicViewMode.summary,
    filter: 'summary',
    usernameFilters: null,
    topLevel: false,
    isFiltered: true,
    paging: TopicPagingStrategy.byStreamIds,
    acceptsLivePosts: false,
    refreshesNearAnchor: false,
    pinsFirstPost: false,
    restoresFirstPost: false,
    jumpPolicy: TopicJumpPolicy.reloadThenVerify,
  ),
  (
    mode: TopicViewMode.activity,
    filter: 'activity',
    usernameFilters: null,
    topLevel: false,
    isFiltered: true,
    paging: TopicPagingStrategy.byStreamIds,
    acceptsLivePosts: false,
    refreshesNearAnchor: false,
    pinsFirstPost: false,
    restoresFirstPost: false,
    jumpPolicy: TopicJumpPolicy.reloadInPlace,
  ),
  (
    mode: TopicViewMode.user('alice'),
    filter: null,
    usernameFilters: 'alice',
    topLevel: false,
    isFiltered: true,
    paging: TopicPagingStrategy.byStreamIds,
    acceptsLivePosts: false,
    refreshesNearAnchor: false,
    pinsFirstPost: true,
    restoresFirstPost: false,
    jumpPolicy: TopicJumpPolicy.reloadThenVerify,
  ),
  (
    mode: TopicViewMode.topLevel,
    filter: null,
    usernameFilters: null,
    topLevel: true,
    isFiltered: true,
    paging: TopicPagingStrategy.byStreamIds,
    acceptsLivePosts: false,
    refreshesNearAnchor: false,
    pinsFirstPost: true,
    restoresFirstPost: true,
    jumpPolicy: TopicJumpPolicy.cancelFilter,
  ),
];

void main() {
  group('视图模式表', () {
    for (final row in _table) {
      test('${row.mode}', () {
        final mode = row.mode;
        expect(mode.filter, row.filter, reason: 'filter');
        expect(mode.usernameFilters, row.usernameFilters);
        expect(mode.filterTopLevelReplies, row.topLevel);
        expect(mode.isFiltered, row.isFiltered, reason: 'isFiltered');
        expect(mode.paging, row.paging, reason: 'paging');
        expect(mode.acceptsLivePosts, row.acceptsLivePosts);
        expect(mode.refreshesNearAnchor, row.refreshesNearAnchor);
        expect(mode.pinsFirstPost, row.pinsFirstPost);
        expect(mode.restoresFirstPost, row.restoresFirstPost);
        expect(mode.jumpPolicy, row.jumpPolicy, reason: 'jumpPolicy');
      });
    }

    test('五种模式两两不同,用户过滤按用户名区分', () {
      final modes = _table.map((r) => r.mode).toSet();
      expect(modes, hasLength(5));
      expect(TopicViewMode.user('alice'), TopicViewMode.user('alice'));
      expect(TopicViewMode.user('alice') == TopicViewMode.user('bob'), isFalse);
      expect(TopicViewMode.user('alice').username, 'alice');
      expect(TopicViewMode.summary.username, isNull);
    });
  });

  group('跳楼层后是否退回全部回复', () {
    test('热门回复:话题不支持热门回复时退回', () {
      final detail = _detail(
        hasSummary: false,
        streamLength: 3,
        postsCount: 50,
      );
      expect(TopicViewMode.summary.shouldFallbackAfterJump(detail), isTrue);
    });

    test('热门回复:服务端其实返回了全量时退回', () {
      final detail = _detail(streamLength: 50, postsCount: 50);
      expect(TopicViewMode.summary.shouldFallbackAfterJump(detail), isTrue);
    });

    test('热门回复:真正过滤生效时保留', () {
      final detail = _detail(streamLength: 10, postsCount: 50);
      expect(TopicViewMode.summary.shouldFallbackAfterJump(detail), isFalse);
    });

    test('只看某人:常驻的 1 楼不算"别人的帖"', () {
      final detail = _detail(
        posts: [_post(1, 'op'), _post(5, 'alice'), _post(9, 'alice')],
      );
      expect(
        TopicViewMode.user('alice').shouldFallbackAfterJump(detail),
        isFalse,
      );
    });

    test('只看某人:混进其他人的帖说明过滤没生效', () {
      final detail = _detail(posts: [_post(5, 'alice'), _post(6, 'bob')]);
      expect(
        TopicViewMode.user('alice').shouldFallbackAfterJump(detail),
        isTrue,
      );
    });

    test('只看顶层回复总是退回;全部/按活动排序从不退回', () {
      final detail = _detail();
      expect(TopicViewMode.topLevel.shouldFallbackAfterJump(detail), isTrue);
      expect(TopicViewMode.all.shouldFallbackAfterJump(detail), isFalse);
      expect(TopicViewMode.activity.shouldFallbackAfterJump(detail), isFalse);
    });
  });
}
