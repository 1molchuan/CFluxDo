part of 'discourse_service.dart';

/// 通知相关
mixin _NotificationsMixin on _DiscourseServiceBase {
  /// 获取最近通知（recent 模式，非分页，用于快捷面板）
  /// 会触发服务端 bump_last_seen_notification，重置未读计数。
  ///
  /// [silent]：后台预取用——带 silent 参数服务端不更新"已看到"位置（对齐
  /// 网页版 silent 拉取），请求本身也是低优先级、不触发过盾
  Future<NotificationListResponse> getRecentNotifications({
    bool silent = false,
  }) async {
    final response = await _dio.get(
      '/notifications',
      queryParameters: {
        'recent': true,
        'limit': 30,
        if (silent) 'silent': true else 'bump_last_seen_reviewable': true,
      },
      options: silent ? Options(extra: const {'isSilent': true}) : null,
    );
    return NotificationListResponse.fromJson(response.data);
  }

  /// 获取通知列表（默认模式，支持完整分页）
  Future<NotificationListResponse> getNotifications({int? offset}) async {
    final queryParams = <String, dynamic>{
      'limit': 60,
    };
    if (offset != null) {
      queryParams['offset'] = offset;
    }

    final response = await _dio.get(
      '/notifications',
      queryParameters: queryParams,
    );
    return NotificationListResponse.fromJson(response.data);
  }

  /// 标记所有通知为已读
  Future<void> markAllNotificationsRead() async {
    await _dio.put('/notifications/mark-read');
  }

  /// 标记单条通知为已读
  Future<void> markNotificationRead(int id) async {
    await _dio.put('/notifications/mark-read', data: {'id': id});
  }
}
