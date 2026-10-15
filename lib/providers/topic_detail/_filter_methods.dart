part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 视图模式(过滤)相关方法
extension FilterMethods on TopicDetailNotifier {
  /// 切换视图模式并整体重载(热门回复/只看某人/只看顶层回复/按活动排序,
  /// [TopicViewMode.all] 即取消过滤)。
  ///
  /// [postNumber] 非空时在该楼层附近重载(取消过滤并跳楼层);为空且模式
  /// 未变时不做任何事。切换总会开新纪元并清空待拉的新回复:此前切换视图
  /// 不清队列,切换前安排的退避重试会把一条未过滤的新回复拼进过滤视图。
  Future<void> setViewMode(TopicViewMode mode, {int? postNumber}) async {
    if (mode == _viewMode && postNumber == null) return;
    await _reload(mode, postNumber: postNumber);
  }
}
