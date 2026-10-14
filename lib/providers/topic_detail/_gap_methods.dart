part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Gaps 相关方法（拉黑用户的帖子加载）
extension GapMethods on TopicDetailNotifier {
  /// 加载某个帖子前面的 gap 帖子
  Future<void> fillGapBefore(int postId) => _fillGap(postId, before: true);

  /// 加载某个帖子后面的 gap 帖子
  Future<void> fillGapAfter(int postId) => _fillGap(postId, before: false);

  /// 对齐网页版 fillGapBefore/fillGapAfter:gap 的 id 与内容都拼接到锚点帖
  /// **原位**。此前 id 一律追加到 stream 末尾,stream 顺序一破坏,真正末帖
  /// 的下标永远小于 stream.length - 1,_hasMoreAfter 永远为 true:底部
  /// spinner 不停、滚到底每次都发一次空翻页请求、最后几楼标不了已读。
  Future<void> _fillGap(int postId, {required bool before}) async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final gaps = currentDetail.postStream.gaps;
    if (gaps == null) return;

    final gapPostIds = (before ? gaps.before : gaps.after)[postId];
    if (gapPostIds == null || gapPostIds.isEmpty) return;

    try {
      final service = ref.read(discourseServiceProvider);
      final newPostStream = await service.getPosts(arg.topicId, gapPostIds);

      if (!ref.mounted) return;
      final updatedDetail = state.value;
      if (updatedDetail == null) return;

      final currentPosts = updatedDetail.postStream.posts;
      final currentStream = updatedDetail.postStream.stream;
      final existingIds = currentPosts.map((p) => p.id).toSet();
      // gap 帖只排自己(通常几条),不再全量重排已加载的数百楼
      final newPosts = newPostStream.posts
          .where((p) => !existingIds.contains(p.id))
          .toList()
        ..sort((a, b) => a.postNumber.compareTo(b.postNumber));

      // 内容:插到锚点帖前/后;锚点帖已不在列表(极少)退化为追加后按楼层号排
      final mergedPosts = [...currentPosts];
      final targetIndex = currentPosts.indexWhere((p) => p.id == postId);
      if (targetIndex == -1) {
        mergedPosts
          ..addAll(newPosts)
          ..sort((a, b) => a.postNumber.compareTo(b.postNumber));
      } else {
        mergedPosts.insertAll(before ? targetIndex : targetIndex + 1, newPosts);
      }

      // stream:只收实际拉到的 id(服务端给的 gap 顺序),整段拼到锚点位置,
      // 这样 stream 顺序与楼层顺序一致,边界判定才正确
      final fetchedIds = newPostStream.posts.map((p) => p.id).toSet();
      final existingStreamIds = currentStream.toSet();
      final newStreamIds = gapPostIds
          .where((id) => fetchedIds.contains(id) && !existingStreamIds.contains(id))
          .toList();
      final mergedStream = [...currentStream];
      final streamIndex = currentStream.indexOf(postId);
      if (streamIndex == -1) {
        mergedStream.addAll(newStreamIds);
      } else {
        mergedStream.insertAll(before ? streamIndex : streamIndex + 1, newStreamIds);
      }

      _updateBoundaryState(mergedPosts, mergedStream);

      state = AsyncValue.data(updatedDetail.copyWith(
        postStream: PostStream(
          posts: mergedPosts,
          stream: mergedStream,
          gaps: _gapsWithout(
            updatedDetail.postStream.gaps,
            before: before ? postId : null,
            after: before ? null : postId,
          ),
        ),
      ));
    } catch (e) {
      debugPrint(
        '[TopicDetail] ${before ? 'fillGapBefore' : 'fillGapAfter'}($postId) 失败: $e',
      );
    }
  }

  /// 去掉已补齐的 gap 条目;全空时返回 null,与服务端「无 gap」的表示一致
  PostStreamGaps? _gapsWithout(PostStreamGaps? gaps, {int? before, int? after}) {
    if (gaps == null) return null;

    final newBefore = Map<int, List<int>>.from(gaps.before);
    final newAfter = Map<int, List<int>>.from(gaps.after);
    if (before != null) newBefore.remove(before);
    if (after != null) newAfter.remove(after);

    final updated = PostStreamGaps(before: newBefore, after: newAfter);
    return updated.isEmpty ? null : updated;
  }

  /// 展开隐藏帖子的原始内容
  Future<void> expandHiddenPost(int postId) async {
    try {
      final service = ref.read(discourseServiceProvider);
      final cooked = await service.getPostCooked(postId);
      if (!ref.mounted) return;
      _updatePostById(postId, (post) => post.copyWith(
        cooked: cooked,
        cookedHidden: false,
      ));
    } catch (e) {
      debugPrint('[TopicDetail] expandHiddenPost($postId) 失败: $e');
    }
  }
}
