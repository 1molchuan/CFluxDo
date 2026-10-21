/// 会话与站点级 MessageBus 频道
///
/// 对齐 Discourse 网页版的 instance-initializers/logout.js 与
/// subscribe-user-notifications.js 中的站点级订阅。这些频道的共同点是
/// 「与某个具体话题无关、影响整个客户端会话」，所以集中放在这里，
/// 不混进 topic_tracking_providers。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/message_bus_service.dart';
import '../../utils/time_utils.dart';
import '../category_provider.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';
import 'topic_tracking_providers.dart';

/// 服务端强制登出频道（`/logout/:user_id`）
///
/// 触发场景：管理员在后台登出该用户的设备、账号被删除
/// （服务端 `app/models/user.rb` 与 `app/services/user_destroyer.rb` 发布）。
///
/// 注意频道名带 user_id 后缀，不是裸 `/logout`——订阅错频道会永远收不到消息。
class LogoutChannelNotifier extends Notifier<void> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;

  /// 一次会话只处理一次：服务端可能连发多条，或退出流程中又有消息抵达。
  /// 对齐网页版 logout.js 的 `_showingLogout` 闩锁。
  bool _handled = false;

  @override
  void build() {
    // 确保 MessageBus 已 configure（域名配置），避免用主站域名轮询
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }

    if (currentUser == null) {
      // 已登出：闩锁复位，下一个会话可以再次响应
      _handled = false;
      return;
    }

    final channel = '/logout/${currentUser.id}';
    debugPrint('[LogoutChannel] 订阅频道: $channel');

    void onLogout(MessageBusMessage message) {
      if (_handled) return;
      _handled = true;

      debugPrint('[LogoutChannel] 收到服务端登出推送');
      // 不 await：回调在轮询循环里同步执行，登出会走网络与存储清理，
      // 阻塞在这里会拖住整条消息投递链。
      unawaited(
        ref
            .read(discourseServiceProvider)
            .handleServerForcedLogout(source: 'message_bus'),
      );
    }

    _subscribedChannel = channel;
    _callback = onLogout;
    messageBus.subscribe(channel, onLogout);

    ref.onDispose(() {
      if (_subscribedChannel != null && _callback != null) {
        debugPrint('[LogoutChannel] 取消订阅: $_subscribedChannel');
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
    });
  }
}

final logoutChannelProvider = NotifierProvider<LogoutChannelNotifier, void>(
  LogoutChannelNotifier.new,
);

/// 勿扰模式结束时间（`/do-not-disturb/:user_id`，上游 d3e91680）
///
/// payload 是 `{ends_at: <httpdate 字符串或 null>}`；null 表示已退出勿扰。
/// 处于勿扰时不弹本地通知，在别的端开启勿扰也能立即生效。
class DoNotDisturbNotifier extends Notifier<DateTime?> {
  String? _channel;
  MessageBusCallback? _callback;

  @override
  DateTime? build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_channel != null && _callback != null) {
      messageBus.unsubscribe(_channel!, _callback);
      _channel = null;
      _callback = null;
    }

    if (currentUser == null) return null;

    final channel = '/do-not-disturb/${currentUser.id}';

    void onDoNotDisturb(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      // ends_at 为 null 是合法值（退出勿扰），不能当成「没字段」忽略
      final endsAt = TimeUtils.parseUtcTime(data['ends_at'] as String?);
      debugPrint('[DoNotDisturb] 勿扰结束时间: $endsAt');
      state = endsAt;
    }

    _channel = channel;
    _callback = onDoNotDisturb;
    messageBus.subscribe(channel, onDoNotDisturb);

    ref.onDispose(() {
      if (_channel != null && _callback != null) {
        messageBus.unsubscribe(_channel!, _callback);
      }
    });

    return null;
  }

  /// 当前是否处于勿扰中
  bool get isActive {
    final endsAt = state;
    return endsAt != null && endsAt.isAfter(DateTime.now());
  }
}

final doNotDisturbProvider =
    NotifierProvider<DoNotDisturbNotifier, DateTime?>(DoNotDisturbNotifier.new);

/// 分类变更频道（`/categories`，取自上游 77188753）
///
/// 管理员改了分类才会推，频率极低，收到就让分类列表重拉。上游同一提交里
/// 的 `/client_settings`、`/refresh_client` 会重拉首页 HTML（GET /），
/// 所有在线客户端同时去拉，正撞人机验证高发路径，这里不订。
class CategoryChangesNotifier extends Notifier<void> {
  MessageBusCallback? _callback;

  static const String _channel = '/categories';

  @override
  void build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);

    if (_callback != null) {
      messageBus.unsubscribe(_channel, _callback);
      _callback = null;
    }

    void onCategories(MessageBusMessage message) {
      debugPrint('[CategoryChanges] 分类变更，刷新分类列表');
      ref.invalidate(categoriesProvider);
    }

    _callback = onCategories;
    messageBus.subscribe(_channel, onCategories);

    ref.onDispose(() {
      if (_callback != null) {
        messageBus.unsubscribe(_channel, _callback);
      }
    });
  }
}

final categoryChangesProvider = NotifierProvider<CategoryChangesNotifier, void>(
  CategoryChangesNotifier.new,
);
