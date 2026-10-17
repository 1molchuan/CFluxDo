import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/discourse_providers.dart';
import '../providers/preferences_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../utils/notification_navigation.dart';
import '../widgets/notification/notification_item.dart';
import '../widgets/notification/notification_list_skeleton.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../l10n/s.dart';
import '../utils/blocked_user_filter.dart';
import '../utils/time_utils.dart';
import '../theme/mojian_theme.dart';
import '../widgets/layout/master_detail_layout.dart';

/// 通知历史列表页面（独立分页，不受 messageBus 干扰）
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  final ScrollController _scrollController = ScrollController();
  final LoadMoreCoordinator _loadMoreCoordinator = LoadMoreCoordinator();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final distance =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final notifier = ref.read(notificationListProvider.notifier);
    await _loadMoreCoordinator.loadMore(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      progressCount: () =>
          ref.read(notificationListProvider).value?.length ?? 0,
    );
  }

  Future<void> _onRefresh() async {
    _loadMoreCoordinator.resetCooldown();
    await ref.read(notificationListProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(notificationListProvider);
    final systemAvatarTemplate = ref
        .watch(systemUserAvatarTemplateProvider)
        .value;
    // 墨笺:标题靠左(宋体随主题),列表按天分组,每组上方一条宋体日期细线
    final mj = Theme.of(context).extension<MojianTokens>();

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.common_notification),
        centerTitle: mj == null,
        actions: [
          IconButton(
            icon: const Icon(Symbols.done_all_rounded),
            onPressed: () async {
              await ref.read(notificationListProvider.notifier).markAllAsRead();
              // 快捷面板下次打开时会自动 silentRefresh 同步已读状态
            },
            tooltip: context.l10n.notification_markAllRead,
          ),
        ],
      ),
      body: DesktopRefreshIndicator(
        onRefresh: _onRefresh,
        child: notificationsAsync.when(
          data: (notifications) {
            final blockedUsernames = ref.watch(
              preferencesProvider.select((p) => p.normalizedBlockedUsernames),
            );
            final visibleNotifications = notifications
                .where(
                  (notification) => !BlockedUserFilter.isBlockedNotification(
                    notification,
                    blockedUsernames,
                  ),
                )
                .toList(growable: false);
            final notifier = ref.read(notificationListProvider.notifier);
            // 已加载页全部被本地屏蔽时列表不可滚，滚动触发的翻页永远不会
            // 发生；主动补载下一页（coordinator 自带冷却，不会打转）
            if (visibleNotifications.isEmpty &&
                notifications.isNotEmpty &&
                notifier.hasMore) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _loadMore();
              });
            }
            if (visibleNotifications.isEmpty &&
                (notifications.isEmpty || !notifier.hasMore)) {
              return mojianEmptyState(
                    context,
                    Symbols.notifications_rounded,
                    context.l10n.notification_empty,
                  ) ??
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Symbols.notifications_rounded,
                          size: 64,
                          color: mj?.ink4 ?? Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.notification_empty,
                          style: mj == null
                              ? const TextStyle(color: Colors.grey)
                              : TextStyle(
                                  fontFamily: MojianTokens.serifFamily,
                                  fontSize: 16,
                                  color: mj.ink2,
                                ),
                        ),
                      ],
                    ),
                  );
            }

            return ListView.builder(
              controller: _scrollController,
              itemCount: visibleNotifications.length + 1,
              itemBuilder: (context, index) {
                if (index == visibleNotifications.length) {
                  final notifier = ref.read(notificationListProvider.notifier);
                  return PagedListFooter(
                    hasMore: notifier.hasMore,
                    isLoadingMore: notifier.isLoadingMore,
                    isLoadMoreFailed: notifier.isLoadMoreFailed,
                    onRetry: notifier.retryLoadMore,
                  );
                }
                final notification = visibleNotifications[index];
                final item = NotificationItem(
                  notification: notification,
                  systemAvatarTemplate: systemAvatarTemplate,
                  // siblings = 当前已加载列表,大屏弹窗内可上一条/下一条
                  onTap: () => handleNotificationTap(
                    context,
                    ref,
                    notification,
                    siblings: visibleNotifications,
                  ),
                );
                if (mj == null) return item;
                final day = TimeUtils.formatSmartDate(notification.createdAt);
                final isFirstOfDay =
                    index == 0 ||
                    TimeUtils.formatSmartDate(
                          visibleNotifications[index - 1].createdAt,
                        ) !=
                        day;
                if (!isFirstOfDay) return item;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MojianDayHead(label: day, tokens: mj),
                    item,
                  ],
                );
              },
            );
          },
          loading: () => const NotificationListSkeleton(),
          error: (error, stack) =>
              ErrorView(error: error, stackTrace: stack, onRetry: _onRefresh),
        ),
      ),
    );
  }
}

/// 墨笺通知列表的日期分组头:宋体小字 + 向右延伸的细线
class _MojianDayHead extends StatelessWidget {
  const _MojianDayHead({required this.label, required this.tokens});

  final String label;
  final MojianTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: MojianTokens.serifFamily,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              letterSpacing: 2.4,
              color: tokens.ink3,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Container(height: 1, color: tokens.rule)),
        ],
      ),
    );
  }
}
