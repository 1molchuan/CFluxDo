part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 加载相关方法
///
/// 统一套路:先发请求,返回后经 [TopicDetailNotifier._applyWindow] 把结果
/// 应用到**最新**窗口。请求期间落进 state 的新 id、postsCount、点赞、
/// boost 都不会被请求前的快照盖掉;期间发生过整体重载(纪元变了)则丢弃。
extension LoadingMethods on TopicDetailNotifier {
  /// 加载更早的帖子（向上滚动）
  Future<void> loadPrevious() async {
    if (_isLoadPreviousFailed) return; // 失败后需手动重试
    if (!hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
    final window = _window;
    if (window == null) return;

    final mode = _viewMode;
    final epoch = _epoch;
    // 不再发射 AsyncLoading.copyWithPrevious:顶部 spinner 由
    // loadingPreviousListenable 驱动,分页起止不触发整页 rebuild。
    _isLoadingPrevious = true;
    try {
      final service = ref.read(discourseServiceProvider);
      final byStreamIds = mode.paging == TopicPagingStrategy.byStreamIds;
      // asc=false 返回的都是当前首帖之前的数据;过滤视图按 stream id 取上一段
      final page = byStreamIds
          ? await service.getPosts(
              arg.topicId,
              window.idsBefore(TopicDetailNotifier._streamPageSize),
            )
          : await service.getPostsByNumber(
              arg.topicId,
              postNumber: window.posts.first.postNumber,
              asc: false,
            );
      _applyWindow(
        (latest) => latest.prependPage(page.posts, orderByStream: byStreamIds),
        epoch: epoch,
      );
    } catch (e) {
      // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复;
      // 失败重试按钮由 loadPreviousFailedListenable 驱动
      debugPrint('[TopicDetail] 加载更早的帖子失败: $e');
      if (epoch == _epoch) _isLoadPreviousFailed = true;
    } finally {
      // 期间开了新纪元:分页状态已由 _beginEpoch 清零,可能已有新请求在途
      if (epoch == _epoch) _isLoadingPrevious = false;
    }
  }

  /// 手动重试加载更早的帖子
  Future<void> retryLoadPrevious() async {
    _isLoadPreviousFailed = false;
    await loadPrevious();
  }

  /// 加载更多回复（向下滚动）
  Future<void> loadMore() async {
    if (_isLoadMoreFailed) return; // 失败后需手动重试
    if (!hasMoreAfter ||
        state.isLoading ||
        _isLoadingMore ||
        _isLoadingNewPosts) {
      return;
    }
    final detail = state.value;
    if (detail == null) return;
    final window = PostStreamWindow.of(detail.postStream);

    final mode = _viewMode;
    final epoch = _epoch;
    // 不再发射 AsyncLoading.copyWithPrevious:底部 spinner 由
    // loadingMoreListenable 驱动,分页起止不触发整页 rebuild。
    _isLoadingMore = true;
    try {
      final service = ref.read(discourseServiceProvider);
      final byStreamIds = mode.paging == TopicPagingStrategy.byStreamIds;
      // 首屏未到末尾时服务端不下发推荐话题,由向下翻页补一次
      // (过滤视图同样不下发,也靠翻页补)
      final includeSuggested = detail.suggestedTopics.isEmpty;
      final page = byStreamIds
          ? await service.getPosts(
              arg.topicId,
              window.idsAfter(TopicDetailNotifier._streamPageSize),
              includeSuggested: includeSuggested,
            )
          : await service.getPostsByNumber(
              arg.topicId,
              postNumber: window.posts.last.postNumber,
              asc: true,
              includeSuggested: includeSuggested,
            );
      _applyWindow(
        (latest) => latest.appendPage(page.posts, orderByStream: byStreamIds),
        epoch: epoch,
        detail: (latest) => _withSuggestedCache(
          latest.copyWith(
            suggestedTopics: page.suggestedTopics.isNotEmpty
                ? page.suggestedTopics
                : null,
            relatedTopics: page.relatedTopics.isNotEmpty
                ? page.relatedTopics
                : null,
          ),
        ),
      );
    } catch (e) {
      // 未发射过 AsyncLoading,state 仍是原 AsyncData,无需恢复
      debugPrint('[TopicDetail] 加载更多回复失败: $e');
      if (epoch == _epoch) _isLoadMoreFailed = true;
    } finally {
      if (epoch == _epoch) _isLoadingMore = false;
    }
  }

  /// 手动重试加载更多
  Future<void> retryLoadMore() async {
    _isLoadMoreFailed = false;
    await loadMore();
  }

  /// 收到新回复通知（MessageBus created 消息）
  /// 对齐 Discourse triggerNewPostsInStream：不在底部时只更新 stream，
  /// 在底部时批量加载帖子内容
  void onNewPostCreated(int postId) {
    if (state.isLoading) return;
    if (!_viewMode.acceptsLivePosts) return;

    final currentDetail = state.value;
    if (currentDetail == null) return;
    final window = PostStreamWindow.of(currentDetail.postStream);

    if (window.stream.contains(postId)) return; // 已在 stream 中
    if (_pendingNewPostIds.contains(postId)) return; // 已在待加载队列
    if (_loadingNewPostIds.contains(postId)) return; // 正在拉取

    if (!window.hasMoreAfter) {
      // 已加载到底部:对齐网页版 loadedAllPosts 分支 —— 新 id **不先进
      // stream**,只入待加载队列,内容拉到后与 posts 同帧落地(见
      // _loadPendingNewPosts)。若 id 先行入 stream,"最后一帖是否为
      // stream 末尾"的边界判定会出现幽灵窗口:hasMoreAfter 瞬间翻
      // true,挂在 !hasMoreAfter 下的底部 sliver(推荐区/typing/待审块)
      // 被整段拆掉 → maxScrollExtent 骤减,正在看底部的视口被 clamp 到
      // 最后一帖;内容到达后又装回,闪两次。同帧落地则边界判定全程
      // 自洽,失败时 stream 也不留幽灵 id。
      // postsCount 先行 +1:进度条分母即时反映新回复。
      state = AsyncValue.data(
        currentDetail.copyWith(postsCount: currentDetail.postsCount + 1),
      );
      _pendingNewPostIds.add(postId);
      _loadPendingNewPosts();
    } else {
      // 未到底部:只把 id 记入 stream,内容等用户滚到底由 loadMore 拉;
      // 边界随窗口一起落地,不存在"先发 state 后算边界"的中间态
      state = AsyncValue.data(
        currentDetail.copyWith(
          postsCount: currentDetail.postsCount + 1,
          postStream: window.withLivePostId(postId),
        ),
      );
    }
  }

  /// 批量加载待处理的新帖子（对齐 Discourse triggerNewPostsInStream）
  Future<void> _loadPendingNewPosts() async {
    if (_isLoadingNewPosts) return;
    if (_pendingNewPostIds.isEmpty) return;
    // 过滤视图不并入新回复(切换视图时队列已清空,这里是兜底)
    if (!_viewMode.acceptsLivePosts) {
      _pendingNewPostIds.clear();
      return;
    }

    _isLoadingNewPosts = true;
    final epoch = _epoch;
    final postIds = List<int>.from(_pendingNewPostIds);
    _pendingNewPostIds.clear();
    _loadingNewPostIds.addAll(postIds);

    try {
      final service = ref.read(discourseServiceProvider);
      final postStream = await service.getPosts(arg.topicId, postIds);
      // 期间整体重载/切换过视图:新数据已包含它们(或视图不收新回复),丢弃
      if (epoch != _epoch) return;
      _newPostLoadFailures = 0;

      // 新帖 id 与内容**同帧**入 stream(onNewPostCreated 底部分支特意
      // 未先入,避免边界判定的幽灵窗口);按楼层号顺序追加
      final applied = _applyWindow(
        (window) => window.landLivePosts(postStream.posts),
        epoch: epoch,
      );

      // 新帖落地会在帖子流末尾长出新内容;用户视口停在其下方(推荐区/
      // 待审块)时属于"锚上方高度变化",武装哨兵做同帧补偿,避免被推跳
      if (applied) AnchorGuardSliver.arm();
    } catch (e) {
      // 失败时将 post IDs 放回队列,由 finally 按指数退避安排重试;
      // 期间开了新纪元则不放回 —— 那是旧视图的请求
      if (epoch == _epoch) {
        _pendingNewPostIds.insertAll(0, postIds);
        _newPostLoadFailures++;
      }
      debugPrint('[TopicDetail] 加载新回复失败(第 $_newPostLoadFailures 次): $e');
    } finally {
      if (epoch == _epoch) {
        _isLoadingNewPosts = false;
        _loadingNewPostIds.removeAll(postIds);
        _scheduleNextNewPostLoad(epoch);
      }
    }
  }

  /// 新回复队列非空时安排下一次拉取:刚成功就立即续拉,失败则指数退避
  void _scheduleNextNewPostLoad(int epoch) {
    if (!ref.mounted || _pendingNewPostIds.isEmpty) return;
    if (_newPostLoadFailures == 0) {
      // 加载期间又有新帖子进入队列,继续加载
      _loadPendingNewPosts();
    } else if (_newPostLoadFailures <=
        TopicDetailNotifier._maxNewPostLoadRetries) {
      // 3s、6s、12s、24s、48s;退避期间不占 _isLoadingNewPosts,
      // 不挡用户自己的翻页。到点时纪元已变(刷新/切换视图)就作罢
      final delay = Duration(seconds: 3 << (_newPostLoadFailures - 1));
      Future.delayed(delay, () {
        if (ref.mounted && epoch == _epoch) _loadPendingNewPosts();
      });
    } else {
      debugPrint('[TopicDetail] 新回复加载连续失败,停止自动重试,待下一条消息再拉');
    }
  }

  /// 整体重载帖子流,开新纪元。[keepVisible] 为 true 时保留旧列表可见
  /// (下拉刷新),否则先进入加载态(跳楼层/切换视图)。
  Future<void> _reload(
    TopicViewMode mode, {
    int? postNumber,
    bool keepVisible = false,
  }) async {
    final firstPost = _loadedFirstPost;
    _viewMode = mode;
    final epoch = _beginEpoch();

    if (keepVisible) {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);
    } else {
      state = const AsyncValue.loading();
      if (postNumber != null) await Future.delayed(Duration.zero);
    }

    final result = await AsyncValue.guard(
      () => _fetchDetail(mode, postNumber: postNumber, firstPost: firstPost),
    );
    // 期间又开始了别的整体重载(如刷新在途时切换视图):以后发起的为准
    if (!ref.mounted || epoch != _epoch) return;
    // 落地时再开一个纪元:刷新在途时旧列表仍可见,期间若有单帖更新把
    // state 翻回 AsyncData,用户还能基于旧窗口翻页 —— 那一页不能拼进新窗口
    _beginEpoch();
    state = result;
  }

  /// 使用新的起始帖子号重新加载数据(保持当前视图模式)
  Future<void> reloadWithPostNumber(int postNumber) =>
      _reload(_viewMode, postNumber: postNumber);

  /// 刷新当前话题详情（保持列表可见）
  ///
  /// 分页不再发射 AsyncLoading,这里的 isLoading 只挡得住并发的整体重载;
  /// 与在途翻页的并发靠纪元:刷新开新纪元,旧翻页结果返回时直接丢弃。
  Future<void> refreshWithPostNumber(int postNumber) async {
    if (state.isLoading) return;
    final mode = _viewMode;
    await _reload(
      mode,
      // 过滤视图从头重载
      postNumber: mode.refreshesNearAnchor ? postNumber : null,
      keepVisible: true,
    );
  }
}
