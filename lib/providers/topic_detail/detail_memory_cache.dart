import 'package:flutter/foundation.dart';

import '../../models/topic.dart';

/// 最近看过的话题详情（内存，进程内有效）。
///
/// 从列表退出再点进同一个话题时，如果列表上的最高楼层没超过缓存里的，
/// 说明这段时间没有新回复，直接用离开时的那份（已加载的楼层、点赞、书签
/// 状态都在），不再发请求、不出骨架屏。有新回复、过了 [ttl]、目标楼层
/// 不在缓存的窗口里时照常请求。
///
/// 只在离开页面（最后一个监听者移除）时存，取出即作废：同一份不会被用两次，
/// 下拉刷新等重建也不会读到它。
class TopicDetailMemoryCache {
  TopicDetailMemoryCache._();

  static const ttl = Duration(minutes: 3);
  static const maxEntries = 16;

  static final Map<int, ({TopicDetail detail, DateTime storedAt})> _entries =
      {};

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static void put(TopicDetail detail) {
    _entries.remove(detail.id);
    _entries[detail.id] = (detail: detail, storedAt: now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 取出可以直接复用的一份；不能用（没有 / 过期 / 有新回复 / 不含目标楼层）
  /// 返回 null。无论能否复用，这一份都作废。
  ///
  /// [expectedHighestPostNumber]：打开时列表上的最高楼层，没给就不复用——
  /// 不知道期间有没有新回复。[targetPostNumber]：要定位的楼层，null 为从头看。
  static TopicDetail? take(
    int topicId, {
    required int? expectedHighestPostNumber,
    required int? targetPostNumber,
  }) {
    final entry = _entries.remove(topicId);
    if (entry == null || expectedHighestPostNumber == null) return null;
    if (now().difference(entry.storedAt) > ttl) return null;
    final detail = entry.detail;
    if (expectedHighestPostNumber > detail.highestPostNumber) return null;
    final target = targetPostNumber == null || targetPostNumber < 1
        ? 1
        : targetPostNumber;
    final hasTarget = detail.postStream.posts.any(
      (post) => post.postNumber == target,
    );
    return hasTarget ? detail : null;
  }

  static void forget(int topicId) => _entries.remove(topicId);

  /// 退出登录 / 换账号时清空：缓存里有当前账号的已读、点赞等状态
  static void clear() => _entries.clear();
}
