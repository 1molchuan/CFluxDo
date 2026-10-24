import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/topic.dart';
import '../../providers/category_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/message_bus/topic_list_events.dart';
import '../../providers/message_bus/topic_tracking_providers.dart';
import '../../services/app_error_handler.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/topic_list_updates.dart';

export '../../utils/topic_list_updates.dart';

mixin TopicListUpdatesMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  final topicUpdates = TopicListUpdates();
  int? _loadingUpdatesGeneration;

  /// 自动载入：新话题攒一会儿再拉，连着来几条只拉一次
  static const autoApplyBatchDelay = Duration(seconds: 2);

  /// 两次自动载入至少隔这么久（每次是一个按话题 ID 的增量请求）
  static const autoApplyMinInterval = Duration(seconds: 30);

  Timer? _autoApplyTimer;
  DateTime? _lastAutoApplyAt;
  ValueListenable<TickerModeData>? _tickerMode;
  AppLifecycleListener? _lifecycleListener;

  /// 现在能不能替用户点提示条：由页面判断列表是否停在顶部、没在加载、
  /// 是不是当前标签等。页面不可见（被详情页盖住、在后台标签）由本 mixin 判断
  bool get canAutoApplyTopicUpdates;

  /// 载入新话题，与点提示条走同一条路径
  Future<void> applyTopicUpdates();

  bool get newNewViewEnabled =>
      PreloadedDataService().currentUserSync?['new_new_view_enabled'] == true;

  bool get isLoadingTopicUpdates =>
      _loadingUpdatesGeneration == topicUpdates.generation;

  Map<int, int> get topicUpdateSnapshot => topicUpdates.snapshot({
    for (final category in (ref.read(categoryMapProvider).value ?? {}).values)
      category.id: category.parentCategoryId,
  });

  void watchTopicUpdates(
    TopicListUpdateQuery query, {
    Iterable<Tag> tags = const [],
  }) {
    topicUpdates.configure(query);
    topicUpdates.rememberTags(tags);
    ref.watch(messageBusInitProvider);
    ref.watch(categoryMapProvider);
    ref.listen(topicListEventsProvider, (_, event) {
      if (event == null) return;
      final before = topicUpdateSnapshot.length;
      if (topicUpdates.add(event) && topicUpdateSnapshot.length != before) {
        setState(() {});
      }
    });
    // 新事件触发的 rebuild、打开开关都会走到这里
    if (ref.watch(
      preferencesProvider.select((p) => p.autoLoadTopicUpdates),
    )) {
      scheduleAutoApplyTopicUpdates();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_onTickerModeChanged);
      _tickerMode = notifier..addListener(_onTickerModeChanged);
    }
    _lifecycleListener ??= AppLifecycleListener(
      onResume: scheduleAutoApplyTopicUpdates,
    );
  }

  @override
  void dispose() {
    _autoApplyTimer?.cancel();
    _tickerMode?.removeListener(_onTickerModeChanged);
    _lifecycleListener?.dispose();
    super.dispose();
  }

  // 从详情页返回、切回这个标签时补一次
  void _onTickerModeChanged() {
    if (_tickerMode?.value.enabled ?? false) scheduleAutoApplyTopicUpdates();
  }

  /// 有待载入的新话题且开了「自动载入新话题」时排一次自动载入。
  /// 页面在列表滚回顶部时也应调用。条件在计时器到点时才判断，
  /// 不满足就作罢（提示条照常显示），等下一个新事件或回到顶部再排
  void scheduleAutoApplyTopicUpdates() {
    if (_autoApplyTimer?.isActive ?? false) return;
    if (!mounted || !ref.read(preferencesProvider).autoLoadTopicUpdates) {
      return;
    }
    if (isLoadingTopicUpdates || topicUpdateSnapshot.isEmpty) return;
    var wait = autoApplyBatchDelay;
    final last = _lastAutoApplyAt;
    if (last != null) {
      final remaining = autoApplyMinInterval - DateTime.now().difference(last);
      if (remaining > wait) wait = remaining;
    }
    _autoApplyTimer = Timer(wait, _runAutoApply);
  }

  Future<void> _runAutoApply() async {
    if (!mounted || isLoadingTopicUpdates) return;
    if (!ref.read(preferencesProvider).autoLoadTopicUpdates) return;
    if (topicUpdateSnapshot.isEmpty) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (!(_tickerMode?.value.enabled ?? true)) return;
    if (!canAutoApplyTopicUpdates) return;
    _lastAutoApplyAt = DateTime.now();
    await applyTopicUpdates();
  }

  /// 列表是否停在顶部且手指没在拖：自动载入只在这时进行，往下读时不打扰
  static bool scrolledToTop(ScrollController controller) {
    if (!controller.hasClients || controller.positions.length != 1) {
      return false;
    }
    final position = controller.position;
    return position.pixels <= position.minScrollExtent + 1 &&
        !position.isScrollingNotifier.value;
  }

  ({int generation, Map<int, int> snapshot}) beginTopicUpdatesRefresh(
    TopicListUpdateQuery query,
  ) {
    topicUpdates.configure(query);
    topicUpdates.generation++;
    return (generation: topicUpdates.generation, snapshot: topicUpdateSnapshot);
  }

  bool isCurrentTopicUpdatesRefresh(int generation) =>
      mounted && generation == topicUpdates.generation;

  void completeTopicUpdatesRefresh(
    Map<int, int> snapshot,
    TopicListResponse response,
  ) {
    topicUpdates.rememberTags([
      ...response.tags,
      for (final topic in response.topics) ...topic.tags,
    ]);
    topicUpdates.acknowledge(snapshot);
  }

  Future<List<int>> loadTopicUpdates(
    Future<List<int>?> Function(List<int> ids) load,
  ) async {
    if (isLoadingTopicUpdates) return [];
    final snapshot = topicUpdateSnapshot;
    if (snapshot.isEmpty) return [];
    final generation = ++topicUpdates.generation;
    setState(() => _loadingUpdatesGeneration = generation);
    try {
      final inserted = await load(snapshot.keys.toList());
      if (!mounted ||
          generation != topicUpdates.generation ||
          inserted == null) {
        return [];
      }
      topicUpdates.acknowledge(snapshot);
      return inserted;
    } on DioException catch (_) {
      // 网络层负责显示错误，保留队列以便再次点击重试。
      return [];
    } catch (error, stack) {
      AppErrorHandler.handleUnexpected(error, stack);
      return [];
    } finally {
      if (mounted && _loadingUpdatesGeneration == generation) {
        setState(() => _loadingUpdatesGeneration = null);
      }
    }
  }
}
