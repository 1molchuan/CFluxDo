import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/pages/topics_screen.dart';
import 'package:fluxdo/pages/search_page.dart';
import 'package:fluxdo/widgets/layout/draggable_divider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/message_bus_service_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/relative_time_clock.dart';
import 'package:fluxdo/widgets/topic/vscode_topic_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic _topic(int id) => Topic(
  id: id,
  title: '左栏真实帖子 $id',
  slug: 'topic-$id',
  postsCount: 1,
  replyCount: 0,
  views: 1,
  likeCount: 0,
  categoryId: '1',
);

TopicListResponse _page(int first, int last, {bool more = true}) =>
    TopicListResponse(
      topics: [for (var id = first; id <= last; id++) _topic(id)],
      moreTopicsUrl: more ? '/latest.json?page=${last + 1}' : null,
    );

// 仅控制网络响应，不替换真实列表、provider、滚动控制器或分页回调。
class _Network extends Fake implements DiscourseService {
  _Network(this.initial);
  final TopicListResponse initial;
  final requests = <({int page, Completer<TopicListResponse> response})>[];

  @override
  Stream<void> get authStateStream => const Stream<void>.empty();
  @override
  Future<List<Category>> getCategories() async => [];
  @override
  Future<Map<String, dynamic>?> getPreloadedTopicTrackingMeta() async => {};
  @override
  Future<TopicListResponse> getLatestTopics({
    int page = 0,
    String? order,
    bool? ascending,
  }) {
    if (page == 0) return Future.value(initial);
    final response = Completer<TopicListResponse>();
    requests.add((page: page, response: response));
    return response.future;
  }
}

class _GuestStartup extends Fake implements AppStartup {
  @override
  SessionVerdict? get verdictNow => null;
  @override
  Future<SessionVerdict> verdict() async => const SessionVerdict.loggedOut();
}

class _MessageBusNetwork extends Fake implements MessageBusService {
  final subscriptions = <String, Set<MessageBusCallback>>{};
  @override
  void configure({String? baseUrl, String? sharedSessionKey}) {}
  @override
  void subscribe(
    String channel,
    MessageBusCallback callback, {
    int lastMessageId = -1,
  }) => subscriptions.putIfAbsent(channel, () => {}).add(callback);
  @override
  void subscribeWithMessageId(
    String channel,
    MessageBusCallback callback,
    int messageId,
  ) => subscribe(channel, callback, lastMessageId: messageId);
  @override
  void unsubscribe(String channel, [MessageBusCallback? callback]) {
    if (callback == null) {
      subscriptions.remove(channel);
    } else {
      subscriptions[channel]?.remove(callback);
      if (subscriptions[channel]?.isEmpty ?? false) {
        subscriptions.remove(channel);
      }
    }
  }
}

Future<void> _frames(WidgetTester tester, [int count = 45]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> Function()? _disposePage;

// 在 testWidgets 的不变量检查之前清理，不能延迟到 addTearDown。
void _testPage(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      final dispose = _disposePage;
      _disposePage = null;
      await dispose?.call();
    }
  });
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Network network, {
  Size size = const Size(330, 1000),
  bool active = true,
  List<String> filterKeywords = const [],
  bool vscode = true,
  Widget? workspace,
}) async {
  // 预加载引导快照只隔离网络边界；不注入话题，首批仍走真实列表 provider。
  // 快照解析内部使用 compute；仅此平台边界离开假时钟，布局仍由 pump 驱动。
  final hydrated = await tester.runAsync(
    () => PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup">'
      '<script id="data-preloaded" type="application/json">'
      '{"currentUser":{},"siteSettings":{},"site":{"categories":[]}}</script>',
    ),
  );
  expect(hydrated, isTrue);
  SharedPreferences.setMockInitialValues({
    'pref_topic_filter_keywords': filterKeywords,
  });
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      aiSharedPreferencesProvider.overrideWithValue(preferences),
      discourseServiceProvider.overrideWithValue(network),
      appStartupProvider.overrideWithValue(_GuestStartup()),
      messageBusServiceProvider.overrideWithValue(_MessageBusNetwork()),
    ],
  );
  PlatformUtils.debugDesktopOverride = true;
  _disposePage = () async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
    } finally {
      container.dispose();
      PreloadedDataService().reset();
      PlatformUtils.debugDesktopOverride = null;
      await tester.pump(Duration.zero);
      await tester.binding.setSurfaceSize(null);
    }
  };
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: vscode
              ? ThemeData(
                  colorScheme: VscodeTheme.colorScheme(Brightness.light),
                  extensions: [VscodeTokens.of(Brightness.light)],
                )
              : ThemeData(),
          home: Scaffold(body: workspace ?? TopicsPage(isActive: active)),
        ),
      ),
    ),
  );
  await _frames(tester);
  return container;
}

ScrollPosition _position(WidgetTester tester) =>
    Scrollable.of(tester.element(find.byType(VscodeTopicRow).first)).position;

void main() {
  // 全局分钟心跳必须在测试假时钟外创建，并在整组测试结束时清理。
  void keepClockAlive() {}
  setUpAll(() => RelativeTimeClock.instance.addListener(keepClockAlive));
  tearDownAll(() => RelativeTimeClock.instance.removeListener(keepClockAlive));

  _testPage('其他风格保留上游行为，不启用资源管理器的自动缺屏补页', (tester) async {
    final network = _Network(_page(1, 1));
    await _mount(tester, network, vscode: false);
    await _frames(tester);
    expect(network.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _testPage('真实左栏无需滚动或改窗口，连续补页直到够屏且在途不重复', (tester) async {
    final network = _Network(_page(1, 1));
    final container = await _mount(tester, network);
    expect(find.byType(VscodeTopicRow), findsOneWidget);
    final position = _position(tester);
    expect(
      tester.getSize(find.byType(VscodeTopicRow)).width,
      lessThanOrEqualTo(330),
    );
    expect(
      tester.getSize(find.byType(VscodeTopicRow)).height,
      lessThan(position.viewportDimension),
    );
    expect(position.extentAfter, lessThanOrEqualTo(1));
    expect(position.pixels, 0);
    expect(network.requests, hasLength(1));
    await _frames(tester);
    expect(network.requests, hasLength(1));
    network.requests[0].response.complete(_page(2, 2));
    await _frames(tester);
    expect(network.requests, hasLength(2));
    expect(position.extentAfter, lessThanOrEqualTo(1));
    expect(position.pixels, 0);
    network.requests[1].response.complete(_page(3, 3));
    await _frames(tester);
    expect(network.requests, hasLength(3));
    expect(position.extentAfter, lessThanOrEqualTo(1));
    network.requests[2].response.complete(_page(4, 80));
    await _frames(tester);
    expect(container.read(topicListProvider(null)).requireValue, hasLength(80));
    expect(container.read(topicListProvider(null).notifier).hasMore, isTrue);
    expect(find.byType(VscodeTopicRow), findsWidgets);
    expect(position.extentAfter, greaterThan(500));
    expect(position.pixels, 0);
    await _frames(tester);
    expect(network.requests, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  _testPage('初始足屏即使存在后页也不额外拉取', (tester) async {
    final network = _Network(_page(1, 80));
    await _mount(tester, network);
    expect(find.byType(VscodeTopicRow), findsWidgets);
    expect(_position(tester).extentAfter, greaterThan(500));
    await _frames(tester);
    expect(network.requests, isEmpty);
    expect(_position(tester).pixels, 0);
    expect(tester.takeException(), isNull);
  });

  _testPage('扩大窗口后由足屏变缺屏自动补载', (tester) async {
    final network = _Network(_page(1, 10));
    await _mount(tester, network, size: const Size(330, 300));
    final position = _position(tester);
    expect(position.extentAfter, greaterThan(1));
    expect(network.requests, isEmpty);
    await tester.binding.setSurfaceSize(const Size(330, 1000));
    await _frames(tester);
    expect(position.extentAfter, lessThanOrEqualTo(1));
    expect(network.requests, hasLength(1));
    network.requests.single.response.complete(_page(11, 80));
    await _frames(tester);
    expect(position.extentAfter, greaterThan(500));
    expect(position.pixels, 0);
    expect(network.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  _testPage('失败后不自动重试，点击真实重试入口后继续补足', (tester) async {
    final network = _Network(_page(1, 1));
    final container = await _mount(tester, network);
    expect(network.requests, hasLength(1));
    network.requests.single.response.completeError(StateError('网络分页失败'));
    await _frames(tester);
    expect(
      container.read(topicListProvider(null).notifier).isLoadMoreFailed,
      isTrue,
    );
    await _frames(tester, 180);
    expect(network.requests, hasLength(1));
    await tester.tap(find.text(S.current.common_loadFailedTapRetry));
    await _frames(tester);
    expect(network.requests, hasLength(2));
    expect(network.requests[1].page, network.requests[0].page);
    network.requests[1].response.complete(_page(2, 2));
    await _frames(tester);
    expect(network.requests, hasLength(3));
    network.requests[2].response.complete(_page(3, 80));
    await _frames(tester);
    expect(_position(tester).extentAfter, greaterThan(500));
    expect(_position(tester).pixels, 0);
    expect(network.requests, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  _testPage('仍然缺屏但网络到头后停止', (tester) async {
    final network = _Network(_page(1, 1));
    final container = await _mount(tester, network);
    expect(network.requests, hasLength(1));
    network.requests.single.response.complete(_page(2, 2, more: false));
    await _frames(tester);
    expect(container.read(topicListProvider(null)).requireValue, hasLength(2));
    expect(container.read(topicListProvider(null).notifier).hasMore, isFalse);
    expect(_position(tester).extentAfter, lessThanOrEqualTo(1));
    await _frames(tester);
    expect(network.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  _testPage('非活跃页面不自动续载', (tester) async {
    final network = _Network(_page(1, 1));
    await _mount(tester, network, active: false);
    expect(find.byType(VscodeTopicRow), findsOneWidget);
    expect(_position(tester).extentAfter, lessThanOrEqualTo(1));
    await _frames(tester);
    expect(network.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _testPage('折叠左栏期间不接续，重新展开后继续', (tester) async {
    final network = _Network(_page(1, 1));
    await _mount(tester, network);
    expect(network.requests, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('vscode-explorer-toggle')));
    await _frames(tester);
    network.requests.single.response.complete(_page(2, 2));
    await _frames(tester);
    expect(find.byType(VscodeTopicRow), findsNothing);
    expect(network.requests, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('vscode-explorer-toggle')));
    await _frames(tester);
    expect(find.byType(VscodeTopicRow), findsNWidgets(2));
    expect(network.requests, hasLength(2));
    network.requests[1].response.complete(_page(3, 80));
    await _frames(tester);
    expect(_position(tester).extentAfter, greaterThan(500));
    expect(network.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });
  _testPage('重复页未增加帖子时停止补载，避免缺屏请求循环', (tester) async {
    final network = _Network(_page(1, 1));
    final container = await _mount(tester, network);
    expect(network.requests, hasLength(1));
    network.requests.single.response.complete(_page(1, 1));
    await _frames(tester, 180);
    expect(container.read(topicListProvider(null)).requireValue.single.id, 1);
    expect(container.read(topicListProvider(null).notifier).hasMore, isTrue);
    expect(_position(tester).extentAfter, lessThanOrEqualTo(1));
    expect(network.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  _testPage('帖子全部被本地过滤时补载有界，不因布局重检绕过冷却', (tester) async {
    final network = _Network(_page(1, 1));
    final container = await _mount(tester, network, filterKeywords: ['左栏真实帖子']);
    expect(find.byType(VscodeTopicRow), findsNothing);
    for (var page = 1; page <= 4; page++) {
      expect(network.requests, hasLength(page));
      network.requests[page - 1].response.complete(_page(page + 1, page + 1));
      await _frames(tester);
    }
    expect(container.read(topicListProvider(null)).requireValue, hasLength(5));
    expect(container.read(topicListProvider(null).notifier).hasMore, isTrue);
    expect(find.byType(VscodeTopicRow), findsNothing);
    await _frames(tester, 180);
    expect(network.requests, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  _testPage('搜索保留导航栏和拖拽后的列表宽度，关闭后恢复原列表位置', (tester) async {
    tester.view.physicalSize =
        const Size(1400, 900) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await _mount(
      tester,
      _Network(_page(1, 80, more: false)),
      size: const Size(1400, 900),
      workspace: Row(
        children: [
          NavigationRail(
            selectedIndex: 0,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home),
                label: Text('首页'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          const Expanded(child: TopicsScreen()),
        ],
      ),
    );
    final rail = find.byType(NavigationRail);
    final railRect = tester.getRect(rail);
    final originalWidth = tester.getSize(find.byType(TopicsPage)).width;
    await tester.drag(find.byType(DraggableDivider), const Offset(48, 0));
    await _frames(tester);
    final listRect = tester.getRect(find.byType(TopicsPage));
    expect(listRect.width, greaterThan(originalWidth));
    final position = _position(tester);
    position.jumpTo(300);
    await _frames(tester);
    final scrollOffset = position.pixels;
    await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
    await _frames(tester);
    expect(rail.hitTestable(), findsOneWidget);
    expect(tester.getRect(rail), railRect);
    expect(tester.getRect(find.byType(SearchPage)), listRect);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
    await _frames(tester);
    expect(find.byType(SearchPage), findsNothing);
    expect(tester.getRect(find.byType(TopicsPage)), listRect);
    expect(_position(tester).pixels, closeTo(scrollOffset, 0.1));
    expect(tester.takeException(), isNull);
  });
}
