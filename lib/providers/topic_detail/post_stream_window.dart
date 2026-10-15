import 'dart:math' as math;

import '../../models/topic.dart';

/// 帖子流窗口的一次变化类型。
///
/// 由 [PostStreamWindow] 在应用变化时给出,消费方据此区分"尾部追加 /
/// 头部插入 / 中间拼接 / 整体替换",不必再比对首末帖 id 去猜。
enum PostWindowChange {
  /// 整体替换:首屏、刷新、跳楼层重载、切换视图模式
  reset,

  /// 已加载楼层之后追加:向下翻页、到底时新回复同帧落地、自己发的回复
  append,

  /// 已加载楼层之前插入:向上翻页
  prepend,

  /// gap 原位拼接(已加载楼层中间插入)
  gap,

  /// 楼层集合不变,只改了 stream 或边界:未到底时新回复 id 入 stream、
  /// 翻页没拿到新帖判定到头
  stream,

  /// 楼层集合不变,单帖内容替换:编辑、点赞、刷新单帖、采纳答案等
  update,

  /// 楼层被移除
  remove,
}

/// 话题详情的帖子流窗口:stream(当前视图全部帖子 id,有序)、已加载
/// 楼层(stream 的一段有序子集)、gaps,以及由它们推出的上下边界。
///
/// 窗口规则只写在这里:
/// - [hasMoreBefore] / [hasMoreAfter] 由首/末已加载帖在 stream 中的位置
///   推出,外加"服务端翻页没再给出新帖"的显式到头标记;
/// - 每种变化(上下翻页、gap 拼接、实时新回复、自己的回复、移除、单帖
///   替换)都由这里的方法应用,返回新窗口(不可变),[change] 标明类型。
///
/// 继承 [PostStream] 以便直接存进 `TopicDetail.postStream`:边界随 state
/// 走,不再是 notifier 上另行维护的可变字段;读方(`detail.postStream.posts`
/// 等)无需改动。notifier 一律在网络请求返回后**重新读取最新窗口**再应用
/// 结果,不回写请求前的快照。
class PostStreamWindow extends PostStream {
  PostStreamWindow._({
    required super.posts,
    required super.stream,
    super.gaps,
    this.exhaustedBefore = false,
    this.exhaustedAfter = false,
    this.change = PostWindowChange.reset,
  });

  /// 由服务端整页响应(首屏/刷新/跳楼层/切换视图)建窗口。
  ///
  /// [pinnedFirstPost]:视图不返回 1 楼但要常驻时(只看顶层回复)补到最前,
  /// id 不在 stream 里就同时补到 stream 开头。
  factory PostStreamWindow.fromPostStream(
    PostStream source, {
    Post? pinnedFirstPost,
  }) {
    var posts = source.posts;
    var stream = source.stream;
    if (pinnedFirstPost != null && !posts.any((p) => p.postNumber == 1)) {
      posts = [pinnedFirstPost, ...posts];
      if (!stream.contains(pinnedFirstPost.id)) {
        stream = [pinnedFirstPost.id, ...stream];
      }
    }
    return PostStreamWindow._(posts: posts, stream: stream, gaps: source.gaps);
  }

  /// 取 state 里的窗口;不是窗口的 [PostStream] 按整页响应包一层
  static PostStreamWindow of(PostStream source) => source is PostStreamWindow
      ? source
      : PostStreamWindow.fromPostStream(source);

  /// 向上翻页时服务端已不再给出新帖(显式到头,避免滚到顶反复空翻)
  final bool exhaustedBefore;

  /// 向下翻页时服务端已不再给出新帖(stream 尾部的 id 取不到内容,如已删帖;
  /// 不置此标记的话每次滚到底都会再发一次空翻页请求)
  final bool exhaustedAfter;

  /// 产生本窗口的那次变化
  final PostWindowChange change;

  /// 首个已加载帖在 stream 中的下标;未加载或不在 stream 中为 -1
  late final int firstLoadedIndex = posts.isEmpty
      ? -1
      : stream.indexOf(posts.first.id);

  /// 末个已加载帖在 stream 中的下标;未加载或不在 stream 中为 -1
  late final int lastLoadedIndex = posts.isEmpty
      ? -1
      : stream.lastIndexOf(posts.last.id);

  /// 首个已加载帖之前 stream 里还有帖子
  late final bool hasMoreBefore = !exhaustedBefore && firstLoadedIndex > 0;

  /// 末个已加载帖之后 stream 里还有帖子
  late final bool hasMoreAfter =
      !exhaustedAfter &&
      lastLoadedIndex != -1 &&
      lastLoadedIndex < stream.length - 1;

  static final Expando<Map<int, int>> _positionCache = Expando(
    'PostStreamWindow.streamPositions',
  );

  /// stream id → 下标。过滤视图每翻一页都要按 stream 顺序排新页;表随
  /// stream 列表实例缓存(stream 可达数千条,窗口常换实例而 stream 不变)。
  Map<int, int> get streamPositions => _positionCache[stream] ??= {
    for (var i = 0; i < stream.length; i++) stream[i]: i,
  };

  bool containsPostNumber(int postNumber) =>
      posts.any((p) => p.postNumber == postNumber);

  /// 按 stream id 向下翻页时要请求的下一段 id(最多 [count] 个)
  List<int> idsAfter(int count) {
    if (!hasMoreAfter) return const [];
    final start = lastLoadedIndex + 1;
    return stream.sublist(start, math.min(start + count, stream.length));
  }

  /// 按 stream id 向上翻页时要请求的上一段 id(最多 [count] 个)
  List<int> idsBefore(int count) {
    if (!hasMoreBefore) return const [];
    final end = firstLoadedIndex;
    return stream.sublist(math.max(0, end - count), end);
  }

  /// 向下翻页的一页落地:新帖接到已加载楼层之后,stream 里没有的 id 补到
  /// 末尾。只排序新页,已加载楼层保持原顺序(翻到数百楼成本不放大)。
  ///
  /// 页里没有任何未加载的帖 = 服务端已到头,置 [exhaustedAfter]。
  /// [orderByStream]:按 stream 下标排新页(过滤视图),否则按楼层号。
  PostStreamWindow appendPage(List<Post> page, {bool orderByStream = false}) {
    final fresh = _freshPosts(page, orderByStream: orderByStream);
    if (fresh.isEmpty) {
      if (exhaustedAfter) return this;
      return _copyWith(exhaustedAfter: true, change: PostWindowChange.stream);
    }
    return _copyWith(
      posts: [...posts, ...fresh],
      stream: _streamWithIdsOf(fresh, atEnd: true),
      change: PostWindowChange.append,
    );
  }

  /// 向上翻页的一页落地:新帖接到已加载楼层之前,stream 里没有的 id 补到
  /// 开头。页里没有任何未加载的帖 = 已到头,置 [exhaustedBefore]。
  PostStreamWindow prependPage(List<Post> page, {bool orderByStream = false}) {
    final fresh = _freshPosts(page, orderByStream: orderByStream);
    if (fresh.isEmpty) {
      if (exhaustedBefore) return this;
      return _copyWith(exhaustedBefore: true, change: PostWindowChange.stream);
    }
    return _copyWith(
      posts: [...fresh, ...posts],
      stream: _streamWithIdsOf(fresh, atEnd: false),
      change: PostWindowChange.prepend,
    );
  }

  /// gap 补齐(对齐网页版 fillGapBefore/fillGapAfter):拉到的帖与 id 都拼到
  /// 锚点帖**原位**(前/后),并去掉该 gap 条目。
  ///
  /// stream 只收实际拉到的 id(按服务端给的 gap 顺序)整段拼到锚点位置。
  /// 若一律追加到 stream 末尾,顺序一破坏,真正末帖的下标永远小于
  /// stream.length - 1,[hasMoreAfter] 永远为 true:底部 spinner 不停、
  /// 滚到底每次都发空翻页请求、最后几楼标不了已读。
  PostStreamWindow spliceGap(
    int anchorPostId, {
    required bool before,
    required List<int> gapPostIds,
    required List<Post> fetched,
  }) {
    // gap 帖只排自己(通常几条),不全量重排已加载的数百楼
    final fresh = _freshPosts(fetched, orderByStream: false);

    // 内容:插到锚点帖前/后;锚点帖已不在列表(极少)退化为追加后按楼层号排
    final mergedPosts = [...posts];
    final targetIndex = posts.indexWhere((p) => p.id == anchorPostId);
    if (targetIndex == -1) {
      mergedPosts
        ..addAll(fresh)
        ..sort(_byPostNumber);
    } else {
      mergedPosts.insertAll(before ? targetIndex : targetIndex + 1, fresh);
    }

    final fetchedIds = {for (final p in fetched) p.id};
    final positions = streamPositions;
    final newStreamIds = [
      for (final id in gapPostIds)
        if (fetchedIds.contains(id) && !positions.containsKey(id)) id,
    ];
    var mergedStream = stream;
    if (newStreamIds.isNotEmpty) {
      mergedStream = [...stream];
      final streamIndex = positions[anchorPostId];
      if (streamIndex == null) {
        mergedStream.addAll(newStreamIds);
      } else {
        mergedStream.insertAll(
          before ? streamIndex : streamIndex + 1,
          newStreamIds,
        );
      }
    }

    return _copyWith(
      posts: mergedPosts,
      stream: mergedStream,
      gaps: _gapsWithout(
        before: before ? anchorPostId : null,
        after: before ? null : anchorPostId,
      ),
      change: PostWindowChange.gap,
    );
  }

  /// 未到底时收到新回复:只把 id 记进 stream 末尾,内容等滚到底由翻页拉
  PostStreamWindow withLivePostId(int postId) {
    if (stream.contains(postId)) return this;
    return _copyWith(
      stream: [...stream, postId],
      change: PostWindowChange.stream,
    );
  }

  /// 到底时拉到的新回复落地:内容与 id **同帧**进窗口,被回复楼层本地
  /// replyCount + 1(与 Discourse 官方做法一致)。
  ///
  /// 防御:窗口此时若已不在底部,只把 id 记进 stream、内容交给翻页,
  /// 免得已加载楼层中间出现空洞。
  PostStreamWindow landLivePosts(List<Post> fetched) {
    final fresh = _freshPosts(fetched, orderByStream: false);
    if (fresh.isEmpty) return this;

    final mergedStream = _streamWithIdsOf(fresh, atEnd: true);
    if (hasMoreAfter) {
      if (identical(mergedStream, stream)) return this;
      return _copyWith(stream: mergedStream, change: PostWindowChange.stream);
    }

    final replyToNumbers = {
      for (final p in fresh)
        if (p.replyToPostNumber > 0) p.replyToPostNumber,
    };
    final updatedPosts = replyToNumbers.isEmpty
        ? posts
        : [
            for (final p in posts)
              replyToNumbers.contains(p.postNumber)
                  ? p.copyWith(replyCount: p.replyCount + 1)
                  : p,
          ];

    return _copyWith(
      posts: [...updatedPosts, ...fresh],
      stream: mergedStream,
      change: PostWindowChange.append,
    );
  }

  /// 自己发出的回复落地:窗口已到底,或打开回复面板时在底部
  /// ([wasAtBottom],防 MessageBus 先于接口响应把边界改掉)就按楼层号插进
  /// 已加载楼层;否则只把 id 记进 stream,内容由翻页拉。
  ///
  /// [loaded] 表示帖子是否已在已加载楼层里(含原本就在的情况)。
  ({PostStreamWindow window, bool loaded}) addOwnPost(
    Post post, {
    bool wasAtBottom = false,
  }) {
    if (posts.any((p) => p.id == post.id)) return (window: this, loaded: true);

    final mergedStream = stream.contains(post.id)
        ? stream
        : [...stream, post.id];
    if (!hasMoreAfter || wasAtBottom) {
      // 新帖通常就在末尾:从尾部找位置,不全量重排
      var insertAt = posts.length;
      while (insertAt > 0 && posts[insertAt - 1].postNumber > post.postNumber) {
        insertAt--;
      }
      return (
        window: _copyWith(
          posts: [...posts]..insert(insertAt, post),
          stream: mergedStream,
          change: PostWindowChange.append,
        ),
        loaded: true,
      );
    }

    if (identical(mergedStream, stream)) return (window: this, loaded: false);
    return (
      window: _copyWith(stream: mergedStream, change: PostWindowChange.stream),
      loaded: false,
    );
  }

  /// 移除帖子(MessageBus destroyed):已加载楼层与 stream 里一并删掉。
  /// 两处都没有时返回自身。
  PostStreamWindow removePost(int postId) {
    final loadedIndex = posts.indexWhere((p) => p.id == postId);
    final inStream = stream.contains(postId);
    if (loadedIndex == -1 && !inStream) return this;
    return _copyWith(
      posts: loadedIndex == -1 ? posts : ([...posts]..removeAt(loadedIndex)),
      stream: inStream ? stream.where((id) => id != postId).toList() : stream,
      change: PostWindowChange.remove,
    );
  }

  /// 按 id 更新单帖;帖子不在已加载楼层或 [update] 原样返回时返回自身
  PostStreamWindow updatePost(int postId, Post Function(Post post) update) {
    final index = posts.indexWhere((p) => p.id == postId);
    if (index == -1) return this;
    final oldPost = posts[index];
    final newPost = update(oldPost);
    if (identical(oldPost, newPost)) return this;
    return _copyWith(
      posts: [...posts]..[index] = newPost,
      change: PostWindowChange.update,
    );
  }

  /// 用新数据替换同 id 的已加载帖(编辑、刷新单帖等)
  PostStreamWindow replacePost(Post post) => updatePost(post.id, (_) => post);

  /// 批量映射已加载楼层(采纳答案会同时改多帖);一帖未变时返回自身
  PostStreamWindow mapPosts(Post Function(Post post) update) {
    var changed = false;
    final newPosts = <Post>[];
    for (final p in posts) {
      final next = update(p);
      if (!identical(next, p)) changed = true;
      newPosts.add(next);
    }
    if (!changed) return this;
    return _copyWith(posts: newPosts, change: PostWindowChange.update);
  }

  /// 页里尚未加载的帖(按 id 去重,含页内重复),排好序
  List<Post> _freshPosts(List<Post> page, {required bool orderByStream}) {
    if (page.isEmpty) return const [];
    final loadedIds = {for (final p in posts) p.id};
    final fresh = [
      for (final p in page)
        if (loadedIds.add(p.id)) p,
    ];
    if (orderByStream) {
      final positions = streamPositions;
      final end = stream.length;
      fresh.sort(
        (a, b) => (positions[a.id] ?? end).compareTo(positions[b.id] ?? end),
      );
    } else {
      fresh.sort(_byPostNumber);
    }
    return fresh;
  }

  /// stream 补上 [fresh] 中尚不在 stream 里的 id;都在时返回原实例
  /// (保住 [streamPositions] 缓存)
  List<int> _streamWithIdsOf(List<Post> fresh, {required bool atEnd}) {
    final positions = streamPositions;
    final seen = <int>{};
    final missing = [
      for (final p in fresh)
        if (!positions.containsKey(p.id) && seen.add(p.id)) p.id,
    ];
    if (missing.isEmpty) return stream;
    return atEnd ? [...stream, ...missing] : [...missing, ...stream];
  }

  /// 去掉已补齐的 gap 条目;全空时返回 null,与服务端「无 gap」的表示一致
  PostStreamGaps? _gapsWithout({int? before, int? after}) {
    final current = gaps;
    if (current == null) return null;

    final newBefore = Map<int, List<int>>.from(current.before);
    final newAfter = Map<int, List<int>>.from(current.after);
    if (before != null) newBefore.remove(before);
    if (after != null) newAfter.remove(after);

    final updated = PostStreamGaps(before: newBefore, after: newAfter);
    return updated.isEmpty ? null : updated;
  }

  static int _byPostNumber(Post a, Post b) =>
      a.postNumber.compareTo(b.postNumber);

  static const Object _keep = Object();

  PostStreamWindow _copyWith({
    List<Post>? posts,
    List<int>? stream,
    Object? gaps = _keep,
    bool? exhaustedBefore,
    bool? exhaustedAfter,
    required PostWindowChange change,
  }) {
    return PostStreamWindow._(
      posts: posts ?? this.posts,
      stream: stream ?? this.stream,
      gaps: identical(gaps, _keep) ? this.gaps : gaps as PostStreamGaps?,
      exhaustedBefore: exhaustedBefore ?? this.exhaustedBefore,
      exhaustedAfter: exhaustedAfter ?? this.exhaustedAfter,
      change: change,
    );
  }
}
