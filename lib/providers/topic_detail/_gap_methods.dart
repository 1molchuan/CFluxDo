part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Gaps 相关方法（拉黑用户的帖子加载）
extension GapMethods on TopicDetailNotifier {
  /// 加载某个帖子前面的 gap 帖子
  Future<void> fillGapBefore(int postId) => _fillGap(postId, before: true);

  /// 加载某个帖子后面的 gap 帖子
  Future<void> fillGapAfter(int postId) => _fillGap(postId, before: false);

  /// 对齐网页版 fillGapBefore/fillGapAfter:gap 的 id 与内容都拼接到锚点帖
  /// **原位**(规则见 [PostStreamWindow.spliceGap]),应用到返回时的最新窗口。
  Future<void> _fillGap(int postId, {required bool before}) async {
    final gaps = state.value?.postStream.gaps;
    if (gaps == null) return;

    final gapPostIds = (before ? gaps.before : gaps.after)[postId];
    if (gapPostIds == null || gapPostIds.isEmpty) return;

    final epoch = _epoch;
    try {
      final service = ref.read(discourseServiceProvider);
      final newPostStream = await service.getPosts(arg.topicId, gapPostIds);

      // 期间整体重载过:gap 属于旧窗口,丢弃(新窗口的 gap 入口仍在)
      _applyWindow(
        (window) => window.spliceGap(
          postId,
          before: before,
          gapPostIds: gapPostIds,
          fetched: newPostStream.posts,
        ),
        epoch: epoch,
      );
    } catch (e) {
      debugPrint(
        '[TopicDetail] ${before ? 'fillGapBefore' : 'fillGapAfter'}($postId) 失败: $e',
      );
    }
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
