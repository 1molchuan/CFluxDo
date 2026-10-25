import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_detail_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/models.dart';
import 'package:fluxdo/providers/message_bus/topic_channel_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _params = TopicDetailParams(1, instanceId: 'layout-pagination');

List<int> _range(int first, int last) => [
  for (var id = first; id <= last; id++) id,
];

// 系统记录有真实、同步的列表布局，不受网络图片和正文异步排版影响。
Post _post(int id) => Post(
  id: id,
  username: 'user$id',
  avatarTemplate: '',
  cooked: '',
  postNumber: id,
  postType: 3,
  actionCode: 'closed.enabled',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);

PostStream _page(List<int> ids) =>
    PostStream(posts: [for (final id in ids) _post(id)], stream: ids);

TopicDetail _detail(List<int> loaded, {List<int>? stream}) => TopicDetail(
  id: 1,
  title: '布局补载',
  slug: 'layout-pagination',
  postsCount: (stream ?? _range(2, 200)).length,
  postStream: PostStream(
    posts: [for (final id in loaded) _post(id)],
    stream: stream ?? _range(2, 200),
  ),
  categoryId: 1,
  closed: false,
  archived: false,
);

class _PaginationService implements DiscourseService {
  _PaginationService(this.initial);

  final TopicDetail initial;
  final requests = <Completer<PostStream>>[];

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async => initial;

  @override
  Future<PostStream> getPostsByNumber(
    int topicId, {
    required int postNumber,
    required bool asc,
    bool includeSuggested = false,
  }) {
    if (!asc) throw StateError('布局补载不应触发头部分页');
    final request = Completer<PostStream>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietTopicChannel extends TopicChannelNotifier {
  _QuietTopicChannel() : super(1);

  @override
  TopicChannelState build() => const TopicChannelState();
}

/// 使用真实列表、控制器和分页 provider，仅替换网络响应。
class _PaginationHost extends ConsumerStatefulWidget {
  const _PaginationHost({required this.controller});

  final TopicDetailController controller;

  @override
  ConsumerState<_PaginationHost> createState() => _PaginationHostState();
}

class _PaginationHostState extends ConsumerState<_PaginationHost> {
  final _centerKey = GlobalKey();
  final _headerKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(topicDetailProvider(_params)).value;
    if (detail == null) return const SizedBox.shrink();
    final notifier = ref.read(topicDetailProvider(_params).notifier);
    final controller = widget.controller;
    return TopicPostList(
      detail: detail,
      scrollController: controller.scrollController,
      centerKey: _centerKey,
      headerKey: _headerKey,
      selectedPostNumber: null,
      highlightPostNumber: null,
      isLoggedIn: false,
      hasMoreBefore: notifier.hasMoreBefore,
      hasMoreAfter: notifier.hasMoreAfter,
      loadingPreviousListenable: notifier.loadingPreviousListenable,
      loadingMoreListenable: notifier.loadingMoreListenable,
      loadMoreFailedListenable: notifier.loadMoreFailedListenable,
      loadPreviousFailedListenable: notifier.loadPreviousFailedListenable,
      onRetryLoadMore: notifier.retryLoadMore,
      centerPostIndex: 0,
      dividerPostIndex: null,
      onFirstVisiblePostChanged: (_) {},
      onJumpToPost: (_) {},
      onReply: (_, {initialContent}) {},
      onEdit: (_) {},
      onRefreshPost: (_) {},
      onVoteChanged: (_, _) {},
      onScrollNotification: (_) => false,
      onLayout: () => controller.loadMoreAfterLayout(
        hasMoreAfter: notifier.hasMoreAfter,
        isLoadingMore: notifier.isLoadingMore,
        loadMore: notifier.loadMore,
      ),
    );
  }
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 60]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late _PaginationService service;
  late ProviderContainer container;
  late TopicDetailController controller;

  Future<void> open(
    WidgetTester tester,
    TopicDetail initial, {
    bool positioned = true,
    bool vscode = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    service = _PaginationService(initial);
    container = ProviderContainer(
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        sharedPreferencesProvider.overrideWithValue(preferences),
        topicChannelProvider(1).overrideWith(_QuietTopicChannel.new),
      ],
    );
    // 保持订阅至容器销毁，避免测试框架卸载组件时启动页面的延迟回收计时器。
    container.listen(topicDetailProvider(_params), (_, _) {});
    controller = TopicDetailController(
      scrollController: AutoScrollController(),
      screenTrack: ScreenTrack(service),
      trackEnabled: false,
    );
    if (positioned) controller.markPositioned();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      container.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: vscode
                ? ThemeData(
                    colorScheme: VscodeTheme.colorScheme(Brightness.light),
                    extensions: [VscodeTokens.of(Brightness.light)],
                  )
                : ThemeData(),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(body: _PaginationHost(controller: controller)),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);
  }

  testWidgets('不滚动也连续补载，等待在途请求且内容充足后停止', (tester) async {
    await open(tester, _detail([2]));
    expect(service.requests, hasLength(1));
    expect(controller.scrollController.position.pixels, 0);

    // 在途时放大窗口并反复布局，仍只有一条网络请求。
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(1));
    service.requests[0].complete(_page([3]));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(2));

    service.requests[1].complete(_page(_range(4, 43)));
    await _pumpFrames(tester);
    final notifier = container.read(topicDetailProvider(_params).notifier);
    expect(notifier.hasMoreAfter, isTrue);
    expect(controller.shouldLoadMore(true, false), isFalse);
    expect(controller.scrollController.position.pixels, 0);
    expect(service.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首批足够时不被渐进物化误触发，窗口放大后再补载', (tester) async {
    await open(tester, _detail(_range(2, 31)));
    expect(service.requests, isEmpty);
    expect(controller.shouldLoadMore(true, false), isFalse);

    await tester.binding.setSurfaceSize(const Size(1000, 2800));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(1));
    service.requests.single.complete(_page(_range(32, 81)));
    await _pumpFrames(tester);
    expect(controller.shouldLoadMore(true, false), isFalse);
    expect(service.requests, hasLength(1));
    expect(controller.scrollController.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  for (final emptyPage in [false, true]) {
    testWidgets(emptyPage ? '空页到头后停止补载' : '末页仍不足一屏也停止补载', (tester) async {
      await open(tester, _detail([2], stream: [2, 3]));
      expect(service.requests, hasLength(1));
      service.requests.single.complete(_page(emptyPage ? [] : [3]));
      await _pumpFrames(tester);
      final notifier = container.read(topicDetailProvider(_params).notifier);
      expect(notifier.hasMoreAfter, isFalse);
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      await _pumpFrames(tester);
      expect(service.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('失败后布局和放大都不自动重试，手动重试仍可继续', (tester) async {
    await open(tester, _detail([2]));
    service.requests.single.completeError(StateError('离线'));
    await _pumpFrames(tester);
    final notifier = container.read(topicDetailProvider(_params).notifier);
    expect(notifier.isLoadMoreFailed, isTrue);
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(1));

    final retry = notifier.retryLoadMore();
    expect(service.requests, hasLength(2));
    service.requests.last.complete(_page(_range(3, 52)));
    await retry;
    await _pumpFrames(tester);
    expect(notifier.isLoadMoreFailed, isFalse);
    expect(controller.shouldLoadMore(true, false), isFalse);
    expect(service.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始定位收尾前不根据临时布局补载', (tester) async {
    await open(tester, _detail([2]), positioned: false);
    expect(service.requests, isEmpty);
    controller.markPositioned();
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(1));
    service.requests.single.complete(_page(_range(3, 52)));
    await _pumpFrames(tester);
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通主题不因布局或窗口变化自动补载', (tester) async {
    await open(tester, _detail([2]), vscode: false);
    expect(service.requests, isEmpty);
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    await _pumpFrames(tester);
    expect(service.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
