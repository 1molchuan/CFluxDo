import 'package:flutter/foundation.dart';

import '../../models/topic.dart';

/// 视图模式种类(服务端过滤,互斥,同时只有一种生效)
enum TopicViewModeKind {
  /// 全部回复(未过滤)
  all,

  /// 热门回复(filter=summary)
  summary,

  /// 问答话题按活动排序(filter=activity,post-voting 默认按票排序)
  activity,

  /// 只看某用户(username_filters;「只看作者」是它的特例)
  user,

  /// 只看顶层回复(filter_top_level_replies)
  topLevel,
}

/// 帖子流翻页方式
enum TopicPagingStrategy {
  /// 按楼层号:`posts.json?post_number=&asc=`(未过滤视图,stream 即楼层顺序)
  byPostNumber,

  /// 按 stream id 取下一段:过滤视图的 stream 不连续,只能按 id 拉
  byStreamIds,
}

/// 跳到不在当前窗口的楼层时如何重载
enum TopicJumpPolicy {
  /// 保持当前视图按楼层号重载(视图本身包含全部楼层)
  reloadInPlace,

  /// 先按当前视图重载,目标不在结果里或过滤并未生效,再退回全部回复
  reloadThenVerify,

  /// 直接退回全部回复再跳(只看顶层回复:跳转目标多是楼中楼,不在视图里)
  cancelFilter,
}

/// 话题详情的视图模式:一个不可变值回答"这个视图怎么请求、怎么翻页、
/// 实时新回复要不要并入、1 楼是否常驻、跳楼层要不要退回全部回复"。
///
/// notifier 只持有一个模式值,所有整体重载点都从这里取请求参数;页面、
/// 底栏、用户卡片判断"是否在过滤中"也统一读它,不再各自拼条件。
@immutable
class TopicViewMode {
  const TopicViewMode._(this.kind, [this.username]);

  /// 只看指定用户的帖子
  const TopicViewMode.user(String username)
    : this._(TopicViewModeKind.user, username);

  static const all = TopicViewMode._(TopicViewModeKind.all);
  static const summary = TopicViewMode._(TopicViewModeKind.summary);
  static const activity = TopicViewMode._(TopicViewModeKind.activity);
  static const topLevel = TopicViewMode._(TopicViewModeKind.topLevel);

  final TopicViewModeKind kind;

  /// 用户过滤的用户名;其他模式为 null
  final String? username;

  /// 是否处于服务端过滤视图(含按活动排序)
  bool get isFiltered => kind != TopicViewModeKind.all;
  bool get isSummary => kind == TopicViewModeKind.summary;
  bool get isActivity => kind == TopicViewModeKind.activity;
  bool get isUserFilter => kind == TopicViewModeKind.user;
  bool get isTopLevel => kind == TopicViewModeKind.topLevel;

  /// 请求参数 `filter`
  String? get filter => switch (kind) {
    TopicViewModeKind.summary => 'summary',
    TopicViewModeKind.activity => 'activity',
    _ => null,
  };

  /// 请求参数 `username_filters`
  String? get usernameFilters => username;

  /// 请求参数 `filter_top_level_replies`
  bool get filterTopLevelReplies => isTopLevel;

  /// 翻页方式
  TopicPagingStrategy get paging => isFiltered
      ? TopicPagingStrategy.byStreamIds
      : TopicPagingStrategy.byPostNumber;

  /// MessageBus 的新回复是否并入当前视图。过滤视图不知道新帖是否命中
  /// 过滤条件,一律不并入(刷新时随服务端结果带回)。
  bool get acceptsLivePosts => !isFiltered;

  /// 刷新是否在当前阅读楼层附近重载;过滤视图从头重载
  bool get refreshesNearAnchor => !isFiltered;

  /// 1 楼是否常驻:用户过滤时服务端恒保留 1 楼(主帖作者未必是被过滤
  /// 用户);只看顶层回复时服务端不返回 1 楼,由客户端补回
  bool get pinsFirstPost => isUserFilter || isTopLevel;

  /// 服务端响应不含 1 楼、需要客户端补回(见 [pinsFirstPost])
  bool get restoresFirstPost => isTopLevel;

  /// 跳到不在当前窗口的楼层时如何重载
  TopicJumpPolicy get jumpPolicy => switch (kind) {
    TopicViewModeKind.all ||
    TopicViewModeKind.activity => TopicJumpPolicy.reloadInPlace,
    TopicViewModeKind.summary ||
    TopicViewModeKind.user => TopicJumpPolicy.reloadThenVerify,
    TopicViewModeKind.topLevel => TopicJumpPolicy.cancelFilter,
  };

  /// [TopicJumpPolicy.reloadThenVerify] 下按当前视图重载后,结果是否说明
  /// 过滤并未生效、应退回全部回复再跳
  bool shouldFallbackAfterJump(TopicDetail detail) {
    switch (kind) {
      case TopicViewModeKind.summary:
        // 话题不支持热门回复,或服务端其实返回了全量
        if (!detail.hasSummary) return true;
        return detail.postsCount > 0 &&
            detail.postStream.stream.length >= detail.postsCount;
      case TopicViewModeKind.user:
        // 常驻的 1 楼不算:判定"过滤是否真的生效"时要把主帖排除在外
        return detail.postStream.posts.any(
          (p) =>
              !(pinsFirstPost && p.postNumber == 1) && p.username != username,
        );
      case TopicViewModeKind.topLevel:
        return true;
      case TopicViewModeKind.all:
      case TopicViewModeKind.activity:
        return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicViewMode &&
          kind == other.kind &&
          username == other.username;

  @override
  int get hashCode => Object.hash(kind, username);

  @override
  String toString() => username == null
      ? 'TopicViewMode.${kind.name}'
      : 'TopicViewMode.${kind.name}($username)';
}
