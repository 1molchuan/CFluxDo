import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/s.dart';
import '../models/topic.dart';
import '../models/pending_post.dart';
import '../models/user.dart';
import '../plugins/plugins.dart';
import '../services/preloaded_data_service.dart';
import '../widgets/common/anchor_guard_sliver.dart';
import 'bookmark_sync_controller.dart';
import 'core_providers.dart';
import 'message_bus/models.dart';
import 'topic_detail/post_stream_window.dart';
import 'topic_detail/topic_view_mode.dart';

export 'topic_detail/post_stream_window.dart';
export 'topic_detail/topic_view_mode.dart';

part 'topic_detail/_loading_methods.dart';
part 'topic_detail/_filter_methods.dart';
part 'topic_detail/_post_updates.dart';
part 'topic_detail/_gap_methods.dart';

/// 话题详情参数
/// 使用 instanceId 确保每次打开页面都是独立的 provider 实例
/// 解决：打开话题 -> 点击用户 -> 再进入同一话题时应该是新的页面状态
class TopicDetailParams {
  final int topicId;
  final int? postNumber;
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  /// 默认为空字符串，用于 MessageBus 等不需要精确匹配的场景
  final String instanceId;

  const TopicDetailParams(this.topicId, {this.postNumber, this.instanceId = ''});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicDetailParams &&
          topicId == other.topicId &&
          instanceId == other.instanceId;

  @override
  int get hashCode => Object.hash(topicId, instanceId);
}

/// 话题详情 Notifier (支持双向加载)
class TopicDetailNotifier extends AsyncNotifier<TopicDetail> {
  TopicDetailNotifier(this.arg);
  final TopicDetailParams arg;

  /// 活跃实例注册表:topicId → 该话题当前存活的 provider 参数(后注册在后)。
  ///
  /// 页面实例的 params 携带 UUID instanceId,深层组件(帖脚的 boost/
  /// reaction 本地操作落地)只知道 topicId —— 直接 new 一个空 instanceId
  /// 的 params 与页面实例不相等,只会凭空创建并 fetch 一个孤儿实例,
  /// 更新永远落不到在显示的那份数据上。经注册表找回真实实例。
  static final Map<int, List<TopicDetailParams>> _activeParams = {};

  /// 该话题最近激活的 provider 参数(同话题叠开多页时取最上层);无活跃
  /// 实例(如个人页等无话题上下文)返回 null,调用方自行跳过同步。
  static TopicDetailParams? activeParamsFor(int topicId) =>
      _activeParams[topicId]?.lastOrNull;

  /// 分页状态改由 ValueNotifier 驱动:加载指示器/重试按钮由列表内
  /// ValueListenableBuilder 就地切换,分页起止不再发射
  /// AsyncLoading.copyWithPrevious(那会触发整页 rebuild,滚动中掉帧)。
  final ValueNotifier<bool> loadingPreviousListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadingMoreListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadMoreFailedListenable = ValueNotifier(false);
  final ValueNotifier<bool> loadPreviousFailedListenable = ValueNotifier(false);

  // 私有 getter/setter 对:既有赋值点(_isLoadingMore = true 等)零改动。
  bool get _isLoadingPrevious => loadingPreviousListenable.value;
  set _isLoadingPrevious(bool v) => loadingPreviousListenable.value = v;
  bool get _isLoadingMore => loadingMoreListenable.value;
  set _isLoadingMore(bool v) => loadingMoreListenable.value = v;
  bool get _isLoadMoreFailed => loadMoreFailedListenable.value;
  set _isLoadMoreFailed(bool v) => loadMoreFailedListenable.value = v;
  bool get _isLoadPreviousFailed => loadPreviousFailedListenable.value;
  set _isLoadPreviousFailed(bool v) => loadPreviousFailedListenable.value = v;

  /// 推荐话题缓存(对齐网页版 post-stream `_setSuggestedTopics`:响应没带
  /// 这两组就保留旧值)。服务端只在"帖子流已到末尾"的请求里下发,过滤模式
  /// 切换、跳楼层重载都拿不到 —— 不缓存的话底部推荐会莫名其妙消失。
  List<Topic> _cachedSuggestedTopics = const [];
  List<Topic> _cachedRelatedTopics = const [];

  /// 当前视图模式(热门回复/只看某人/顶层回复/按活动排序/全部)。所有
  /// 整体重载点都按它取请求参数,见 [TopicViewMode]。
  TopicViewMode _viewMode = TopicViewMode.all;

  /// 整体重载纪元:首屏、刷新、跳楼层、切换视图在发起与落地时各开一个新
  /// 纪元。翻页/补 gap/新回复请求发出时记下纪元,返回时纪元已变就丢弃
  /// 结果 —— 旧窗口的一页不能拼进新窗口,也不能盖掉新窗口。
  int _epoch = 0;

  /// 待加载的新帖子 ID 队列（对齐 Discourse _newPostsInStream）
  final List<int> _pendingNewPostIds = [];
  /// 正在拉取内容的新帖子 ID(已出队、未落地)
  final Set<int> _loadingNewPostIds = {};
  bool _isLoadingNewPosts = false;
  /// 新回复拉取的连续失败次数:指数退避,超过上限停止自动重试(队列保留,
  /// 下一条 created 消息或刷新再拉)。无上限时断网会每 3 秒打一次请求直到
  /// 离开页面,期间还挡住用户自己的翻页。
  int _newPostLoadFailures = 0;
  static const int _maxNewPostLoadRetries = 5;
  /// 过滤视图按 stream id 翻页时每页条数
  static const int _streamPageSize = 20;

  /// 当前帖子流窗口(state 无数据时为 null)
  PostStreamWindow? get _window {
    final detail = state.value;
    return detail == null ? null : PostStreamWindow.of(detail.postStream);
  }

  /// 边界由 state 里的窗口推出;无数据(整体重载中)时视为两侧都还有
  bool get hasMoreAfter => _window?.hasMoreAfter ?? true;
  bool get hasMoreBefore => _window?.hasMoreBefore ?? true;
  bool get isLoadingPrevious => _isLoadingPrevious;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadMoreFailed => _isLoadMoreFailed;
  bool get isLoadPreviousFailed => _isLoadPreviousFailed;
  TopicViewMode get viewMode => _viewMode;

  /// 把一次窗口变化应用到**最新** state 并发射;窗口没变时不发射。
  ///
  /// 网络请求一律在返回后经这里落地:[epoch] 传发起请求时的纪元,期间
  /// 发生过整体重载就丢弃。[detail] 顺带改话题级字段(推荐话题、
  /// postsCount 等),同样基于最新 detail。返回是否发射了新 state。
  bool _applyWindow(
    PostStreamWindow Function(PostStreamWindow window) change, {
    int? epoch,
    TopicDetail Function(TopicDetail detail)? detail,
  }) {
    if (!ref.mounted) return false;
    if (epoch != null && epoch != _epoch) return false;
    final current = state.value;
    if (current == null) return false;
    final window = PostStreamWindow.of(current.postStream);
    final next = change(window);
    if (identical(next, window)) return false;
    var updated = current.copyWith(postStream: next);
    if (detail != null) updated = detail(updated);
    state = AsyncValue.data(updated);
    return true;
  }

  /// 开始一次整体重载:纪元 +1,在途的翻页/补 gap/新回复结果随之作废,
  /// 分页状态与待拉新回复一并清零(新数据本身就包含它们)。
  int _beginEpoch() {
    _epoch++;
    _isLoadingMore = false;
    _isLoadingPrevious = false;
    _isLoadMoreFailed = false;
    _isLoadPreviousFailed = false;
    _isLoadingNewPosts = false;
    _pendingNewPostIds.clear();
    _loadingNewPostIds.clear();
    _newPostLoadFailures = 0;
    return _epoch;
  }

  /// 当前已加载的 1 楼(只看顶层回复补 1 楼时复用,省一次请求)
  Post? get _loadedFirstPost =>
      state.value?.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;

  /// 按视图模式整页拉取话题详情并建窗口。
  ///
  /// 所有整体重载点(首屏、跳楼层、刷新、切换视图)都经这里,请求参数
  /// 一律取自 [mode]:此前三个过滤参数在各处手传,刷新漏过顶层过滤、
  /// 取消过滤跳楼层也漏传。只看顶层回复的视图不含 1 楼,在这里统一补回
  /// (此前只有切入该视图时补,下拉刷新后 1 楼就没了)。
  Future<TopicDetail> _fetchDetail(
    TopicViewMode mode, {
    int? postNumber,
    bool trackVisit = false,
    Post? firstPost,
  }) async {
    final service = ref.read(discourseServiceProvider);
    // 手上没有 1 楼就与详情并发单独拉;拉不到不影响主流程
    final firstPostFuture = mode.restoresFirstPost && firstPost == null
        ? service
              .getPostByNumber(arg.topicId, 1)
              .then<Post?>((post) => post, onError: (_) => null)
        : null;
    final detail = await service.getTopicDetail(
      arg.topicId,
      postNumber: postNumber,
      trackVisit: trackVisit,
      filter: mode.filter,
      usernameFilters: mode.usernameFilters,
      filterTopLevelReplies: mode.filterTopLevelReplies,
    );
    final pinnedFirstPost = mode.restoresFirstPost
        ? firstPost ?? await firstPostFuture
        : null;
    return _withSuggestedCache(
      detail.copyWith(
        postStream: PostStreamWindow.fromPostStream(
          detail.postStream,
          pinnedFirstPost: pinnedFirstPost,
        ),
      ),
    );
  }

  /// 用缓存补齐详情里的推荐话题(新响应带了就刷新缓存,没带就回填)
  TopicDetail _withSuggestedCache(TopicDetail detail) {
    if (detail.suggestedTopics.isNotEmpty) {
      _cachedSuggestedTopics = detail.suggestedTopics;
    }
    if (detail.relatedTopics.isNotEmpty) {
      _cachedRelatedTopics = detail.relatedTopics;
    }
    final needSuggested =
        detail.suggestedTopics.isEmpty && _cachedSuggestedTopics.isNotEmpty;
    final needRelated =
        detail.relatedTopics.isEmpty && _cachedRelatedTopics.isNotEmpty;
    if (!needSuggested && !needRelated) return detail;
    return detail.copyWith(
      suggestedTopics: needSuggested ? _cachedSuggestedTopics : null,
      relatedTopics: needRelated ? _cachedRelatedTopics : null,
    );
  }

  /// 更新单个帖子的辅助方法
  void _updatePostById(int postId, Post Function(Post) updater) {
    final applied = _applyWindow(
      (window) => window.updatePost(postId, (oldPost) {
        final newPost = updater(oldPost);
        // 数据没变则跳过，避免触发不必要的 rebuild
        return oldPost == newPost ? oldPost : newPost;
      }),
    );

    // 单帖状态落地(msgbus liked/boost 本地更新等):武装锚定哨兵,
    // 视口上方帖子的高度位移在下一帧被同帧补偿。用户主动操作(自己
    // 点赞/书签)也会经过这里 —— 无害:被操作的帖子必然可见,高度
    // 变化发生在锚(视口上沿 segment)的盒内或下方,锚不动、不修正。
    if (applied) AnchorGuardSliver.arm();
  }

  /// 将成员移出当前私信，并同步首楼与底部的成员面板。
  Future<void> removePrivateMessageParticipant(TopicUser participant) async {
    final currentDetail = state.value;
    if (currentDetail == null || !currentDetail.isPrivateMessage) return;

    final service = ref.read(discourseServiceProvider);
    await service.removePrivateMessageParticipant(
      currentDetail.id,
      participant.username,
    );

    // 请求期间可能收到新回复或其他 MessageBus 更新，必须基于
    // 最新 detail 删成员，否则会用请求前的快照把新状态整体覆盖掉。
    final latestDetail = state.value;
    if (latestDetail == null || latestDetail.id != currentDetail.id) return;

    AnchorGuardSliver.arm();
    state = AsyncValue.data(
      latestDetail.copyWith(
        allowedUsers: latestDetail.allowedUsers
            .where((user) => user.id != participant.id)
            .toList(growable: false),
        clearCanRemoveSelfId: latestDetail.canRemoveSelfId == participant.id,
      ),
    );
  }

  /// 将群组移出当前私信，并同步成员面板。
  Future<void> removePrivateMessageGroup(TopicGroup group) async {
    final currentDetail = state.value;
    if (currentDetail == null || !currentDetail.isPrivateMessage) return;

    final service = ref.read(discourseServiceProvider);
    await service.removePrivateMessageGroup(currentDetail.id, group.name);

    final latestDetail = state.value;
    if (latestDetail == null || latestDetail.id != currentDetail.id) return;

    AnchorGuardSliver.arm();
    state = AsyncValue.data(
      latestDetail.copyWith(
        allowedGroups: latestDetail.allowedGroups
            .where((item) => item.name != group.name)
            .toList(growable: false),
      ),
    );
  }

  /// 邀请用户/群组加入当前私信，并把新成员并入面板名单。
  ///
  /// 逐个提交:官方 invite 接口一次只收一个收件人(用户走 invite、群组走
  /// invite-group),这里保持同样粒度,部分成功也把已成功的并进名单,失败
  /// 名单原样抛给调用方提示。
  Future<List<String>> invitePrivateMessageParticipants({
    required List<String> usernames,
    required List<String> groupNames,
  }) async {
    final currentDetail = state.value;
    if (currentDetail == null || !currentDetail.isPrivateMessage) {
      return const [];
    }

    final service = ref.read(discourseServiceProvider);
    final topicId = currentDetail.id;
    final invitedUsers = <TopicUser>[];
    final invitedGroups = <TopicGroup>[];
    final failed = <String>[];

    for (final username in usernames) {
      try {
        final user = await service.invitePrivateMessageUser(topicId, username);
        if (user != null) invitedUsers.add(user);
      } catch (_) {
        failed.add(username);
      }
    }
    for (final groupName in groupNames) {
      try {
        await service.invitePrivateMessageGroup(topicId, groupName);
        invitedGroups.add(TopicGroup(name: groupName));
      } catch (_) {
        failed.add(groupName);
      }
    }

    if (invitedUsers.isEmpty && invitedGroups.isEmpty) return failed;

    // 同 removePrivateMessageParticipant:请求期间可能有别的更新落到 state,
    // 必须基于最新 detail 追加。
    final latestDetail = state.value;
    if (latestDetail == null || latestDetail.id != topicId) return failed;

    final existingUserIds = latestDetail.allowedUsers
        .map((user) => user.id)
        .toSet();
    final existingGroupNames = latestDetail.allowedGroups
        .map((group) => group.name)
        .toSet();

    AnchorGuardSliver.arm();
    state = AsyncValue.data(
      latestDetail.copyWith(
        allowedUsers: [
          ...latestDetail.allowedUsers,
          ...invitedUsers.where((user) => !existingUserIds.contains(user.id)),
        ],
        allowedGroups: [
          ...latestDetail.allowedGroups,
          ...invitedGroups.where(
            (group) => !existingGroupNames.contains(group.name),
          ),
        ],
      ),
    );
    return failed;
  }

  /// 归档 / 取消归档当前私信，并把 `message_archived` 同步进 detail。
  ///
  /// 返回操作后的归档态。调用方据此决定是留在页面还是退回私信列表。
  Future<bool> toggleArchivePrivateMessage() async {
    final currentDetail = state.value;
    if (currentDetail == null || !currentDetail.isPrivateMessage) {
      return false;
    }

    final service = ref.read(discourseServiceProvider);
    final archive = !currentDetail.messageArchived;
    if (archive) {
      await service.archivePrivateMessage(currentDetail.id);
    } else {
      await service.movePrivateMessageToInbox(currentDetail.id);
    }

    // 同 removePrivateMessageParticipant:请求期间可能有别的更新落到 state。
    final latestDetail = state.value;
    if (latestDetail == null || latestDetail.id != currentDetail.id) {
      return archive;
    }

    AnchorGuardSliver.arm();
    state = AsyncValue.data(latestDetail.copyWith(messageArchived: archive));
    return archive;
  }

  /// MessageBus 的 archived / move_to_inbox 通知（在别的端归档时会收到）
  /// 落到 detail 上，让菜单里的双态入口跟着翻。
  void applyMessageArchived(bool archived) {
    final currentDetail = state.value;
    if (currentDetail == null ||
        !currentDetail.isPrivateMessage ||
        currentDetail.messageArchived == archived) {
      return;
    }
    state = AsyncValue.data(currentDetail.copyWith(messageArchived: archived));
  }

  @override
  Future<TopicDetail> build() async {
    debugPrint('[TopicDetailNotifier] build called with topicId=${arg.topicId}, postNumber=${arg.postNumber}');

    // 注册活跃实例(见 _activeParams);autoDispose 时反注册。
    // build 重跑(refresh)会重复进入,先去重再追加保持"最近激活在尾"。
    final registered = _activeParams.putIfAbsent(arg.topicId, () => []);
    registered.remove(arg);
    registered.add(arg);
    ref.onDispose(() {
      final list = _activeParams[arg.topicId];
      if (list == null) return;
      list.remove(arg);
      if (list.isEmpty) {
        _activeParams.remove(arg.topicId);
        // 该话题已无存活实例，同步丢弃插件扩展字段缓存
        TopicPluginData.forget(arg.topicId);
      }
    });

    // 保持存活，防止布局切换的短暂间隙被 autoDispose 清理
    // 使用 onCancel/onResume 模式：最后一个 watcher 移除后才开始倒计时
    final link = ref.keepAlive();
    Timer? disposeTimer;
    ref.onCancel(() {
      // 最后一个 watcher 移除后，延迟 30 秒再允许 dispose
      disposeTimer = Timer(const Duration(seconds: 30), link.close);
    });
    ref.onResume(() {
      // 新的 watcher 出现，取消清理定时器
      disposeTimer?.cancel();
    });
    ref.onDispose(() {
      disposeTimer?.cancel();
    });

    // build 重跑(invalidate / 出错重试)沿用当前视图模式:此前固定拉未过滤
    // 数据,过滤标记却还亮着,翻页又按过滤视图的 stream id 走
    final mode = _viewMode;
    final epoch = _beginEpoch();
    final detail = await _fetchDetail(
      mode,
      postNumber: mode.refreshesNearAnchor ? arg.postNumber : null,
      trackVisit: true,
      firstPost: _loadedFirstPost,
    );
    // 记录话题级插件扩展字段，供分散在深层组件里的回复入口按 topicId 取用
    // （如 linux.do 回复扣积分的 reply_cost）
    TopicPluginData.put(arg.topicId, detail.pluginExtras);

    if (epoch != _epoch) {
      // 首屏在途时已开始新的整体重载(跳楼层/切换视图):build 的返回值
      // 仍会写进 state,新数据已落地就交回它,别让旧响应盖掉
      return state.value ?? detail;
    }
    // 落地时再开一个纪元(同 _reload):重建期间旧列表可见,基于旧窗口
    // 发出的翻页不能拼进新窗口
    _beginEpoch();
    return detail;
  }
}

final topicDetailProvider = AsyncNotifierProvider.family.autoDispose<TopicDetailNotifier, TopicDetail, TopicDetailParams>(
  TopicDetailNotifier.new,
);

/// 话题内「只看某用户」请求(用户卡片/头像长按菜单发起,话题详情页消费)。
///
/// 发起方是深层弹层组件,不持有页面 State,没法直接调页面的过滤 action
/// (那里除了改 notifier 还要做整套 UI 复位:退出嵌套视图/跳 1 楼/切换
/// spinner)。经此桥广播,由当前活跃的详情页实例 ref.listen 消费。
/// [username] 为 null 表示取消过滤;[seq] 单调递增,保证连续两次相同
/// 请求也能触发 listener。
class TopicUserFilterRequest {
  final int seq;
  final int topicId;
  final String? username;

  const TopicUserFilterRequest({
    required this.seq,
    required this.topicId,
    this.username,
  });
}

class TopicUserFilterRequestNotifier extends Notifier<TopicUserFilterRequest?> {
  int _seq = 0;

  @override
  TopicUserFilterRequest? build() => null;

  void request({required int topicId, String? username}) {
    state = TopicUserFilterRequest(
      seq: ++_seq,
      topicId: topicId,
      username: username,
    );
  }
}

final topicUserFilterRequestProvider =
    NotifierProvider<TopicUserFilterRequestNotifier, TopicUserFilterRequest?>(
      TopicUserFilterRequestNotifier.new,
    );

/// 话题 AI 摘要 Provider。
///
/// 普通展开优先复用 Discourse AI 的缓存摘要；没有缓存时服务层才会触发生成。
final topicSummaryProvider = StreamProvider.autoDispose
    .family<TopicSummary?, int>((ref, topicId) {
  final service = ref.read(discourseServiceProvider);
  return service.watchTopicSummary(topicId);
});

/// 话题 AI 摘要重新生成 Provider。
///
/// 与普通加载分开，确保「重新生成」明确携带 skip_age_check=true，而不是
/// 仅 invalidate 普通 Provider 后再次读回旧缓存。
final topicSummaryRegenerationProvider = StreamProvider.autoDispose
    .family<TopicSummary?, int>((ref, topicId) {
  final service = ref.read(discourseServiceProvider);
  return service.watchTopicSummary(topicId, skipAgeCheck: true);
});
