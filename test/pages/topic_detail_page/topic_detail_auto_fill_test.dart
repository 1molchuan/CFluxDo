import 'dart:async';

import 'package:flutter/services.dart';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_detail_page.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_post_list.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/message_bus_service_provider.dart';
import 'package:fluxdo/providers/message_bus/models.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/relative_time_clock.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_post_source.dart';
import 'package:fluxdo/widgets/topic_detail/vscode_post_jump_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _params = TopicDetailParams(1, instanceId: 'real-page-auto-fill');
const _windowSize = Size(1100, 900);

List<int> _range(int first, int last) => [
  for (var number = first; number <= last; number++) number,
];

Post _post(int number) => Post(
  id: number,
  username: 'reader$number',
  avatarTemplate: '',
  cooked: '<p>这是第 $number 楼的普通正文，打开话题后应自动补足阅读区域。</p>',
  postNumber: number,
  postType: 1,
  createdAt: DateTime(2026, 5, 15),
  updatedAt: DateTime(2026, 5, 15),
  likeCount: 0,
  replyCount: 0,
);

PostStream _page(List<int> numbers) => PostStream(
  posts: [for (final number in numbers) _post(number)],
  stream: numbers,
);

/// 只控制 HTTP 服务的响应；话题 provider、页面和分页回调均使用生产实现。
class _TopicNetwork extends Fake implements DiscourseService {
  _TopicNetwork({this.highestPostNumber = 100});

  final int highestPostNumber;
  final topicLoads = <int?>[];
  final requests = <({int postNumber, Completer<PostStream> response})>[];

  @override
  Stream<void> get authStateStream => const Stream<void>.empty();

  @override
  Future<List<Category>> getCategories() async => [];

  @override
  Future<Map<String, dynamic>?> getPreloadedTopicTrackingMeta() async => {};

  @override
  Future<PresenceResponse> getPresence(int topicId) async =>
      const PresenceResponse(users: [], messageId: -1);

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async {
    topicLoads.add(postNumber);
    return TopicDetail(
      id: id,
      title: '普通正文首屏自动补载',
      slug: 'real-page-auto-fill',
      postsCount: 100,
      highestPostNumber: highestPostNumber,
      postStream: PostStream(
        posts: [_post(postNumber ?? 1)],
        stream: [..._range(1, 99), highestPostNumber],
      ),
      categoryId: 1,
      closed: false,
      archived: false,
    );
  }

  @override
  Future<PostStream> getPostsByNumber(
    int topicId, {
    required int postNumber,
    required bool asc,
    bool includeSuggested = false,
  }) {
    if (!asc) throw StateError('从第一楼打开不应请求前页');
    final response = Completer<PostStream>();
    requests.add((postNumber: postNumber, response: response));
    return response.future;
  }
}

/// 启动会话是页面外的平台边界，保留真实 CurrentUserNotifier 的访客路径。
class _GuestStartup extends Fake implements AppStartup {
  @override
  SessionVerdict? get verdictNow => null;

  @override
  Future<SessionVerdict> verdict() async => const SessionVerdict.loggedOut();
}

/// 不连接长轮询服务器，但保留真实频道 provider 的订阅和清理流程。
class _MessageBusNetwork extends Fake implements MessageBusService {
  final subscriptions = <String, Set<MessageBusCallback>>{};

  @override
  void configure({String? baseUrl, String? sharedSessionKey}) {}

  @override
  void subscribe(
    String channel,
    MessageBusCallback callback, {
    int lastMessageId = -1,
  }) {
    subscriptions.putIfAbsent(channel, () => {}).add(callback);
  }

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

Future<void> _pumpFrames(WidgetTester tester, [int count = 90]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  // 与完整书签页测试一致，将排版缓存的全局分钟心跳放在真实时钟中。
  void keepClockAlive() {}
  setUpAll(() => RelativeTimeClock.instance.addListener(keepClockAlive));
  tearDownAll(() => RelativeTimeClock.instance.removeListener(keepClockAlive));

  testWidgets('点击真实阅读进度打开快速跳转，删楼后的末楼仍能按 Enter 准确到达', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final network = _TopicNetwork(highestPostNumber: 120);
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
    try {
      await tester.binding.setSurfaceSize(_windowSize);
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
              theme: ThemeData(
                colorScheme: VscodeTheme.colorScheme(Brightness.light),
                extensions: [VscodeTokens.of(Brightness.light)],
              ),
              home: const TopicDetailPage(
                topicId: 1,
                instanceId: 'real-page-auto-fill',
              ),
            ),
          ),
        ),
      );
      await _pumpFrames(tester);
      await tester.tap(find.textContaining('/ 100'));
      await _pumpFrames(tester, 20);
      await tester.enterText(find.byType(TextField), ':120');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpFrames(tester);
      expect(find.byType(VscodePostJumpDialog), findsNothing);
      expect(network.topicLoads.last, 120);
      expect(
        container
            .read(topicDetailProvider(_params))
            .requireValue
            .postStream
            .posts
            .map((post) => post.postNumber),
        contains(120),
      );
      expect(find.textContaining('阅读 #120').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      container.dispose();
      PlatformUtils.debugDesktopOverride = null;
      await tester.pump(Duration.zero);
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('真实 VS Code 话题页打开后不滚动不改窗口，连续补载普通正文直到够屏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final network = _TopicNetwork();
    final messageBus = _MessageBusNetwork();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        aiSharedPreferencesProvider.overrideWithValue(preferences),
        discourseServiceProvider.overrideWithValue(network),
        appStartupProvider.overrideWithValue(_GuestStartup()),
        messageBusServiceProvider.overrideWithValue(messageBus),
      ],
    );
    PlatformUtils.debugDesktopOverride = true;
    try {
      // 只在挂载前设置一次窗口；随后只推进帧和交付网络响应。
      await tester.binding.setSurfaceSize(_windowSize);
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
              theme: ThemeData(
                colorScheme: VscodeTheme.colorScheme(Brightness.light),
                extensions: [VscodeTokens.of(Brightness.light)],
              ),
              home: const TopicDetailPage(
                topicId: 1,
                instanceId: 'real-page-auto-fill',
              ),
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(find.byType(VscodePostSource), findsOneWidget);
      expect(network.requests, hasLength(1));

      final scrollController = tester
          .widget<TopicPostList>(find.byType(TopicPostList))
          .scrollController;
      expect(scrollController.position.pixels, closeTo(0, 0.5));
      expect(scrollController.position.extentAfter, lessThanOrEqualTo(1));
      expect(
        tester.getSize(find.byType(VscodePostSource)).height,
        lessThan(scrollController.position.viewportDimension),
      );

      // 首次请求悬而未决时持续布局，不能并发请求下一页。
      await _pumpFrames(tester);
      expect(network.requests, hasLength(1));
      network.requests[0].response.complete(_page([2]));
      await _pumpFrames(tester);
      expect(network.requests, hasLength(2));
      expect(scrollController.position.extentAfter, lessThanOrEqualTo(1));
      expect(scrollController.position.pixels, closeTo(0, 0.5));

      // 第二页仍不足一屏，不依赖滚动、resize 或人工调用 onLayout/markPositioned。
      network.requests[1].response.complete(_page([3]));
      await _pumpFrames(tester);
      expect(network.requests, hasLength(3));
      expect(scrollController.position.extentAfter, lessThanOrEqualTo(1));
      expect(scrollController.position.pixels, closeTo(0, 0.5));

      network.requests[2].response.complete(_page(_range(4, 40)));
      await _pumpFrames(tester);
      expect(
        container
            .read(topicDetailProvider(_params))
            .requireValue
            .postStream
            .posts
            .map((post) => post.postNumber),
        _range(1, 40),
      );
      expect(
        container.read(topicDetailProvider(_params).notifier).hasMoreAfter,
        isTrue,
      );
      // 保留未加载的后续帖子；停止原因必须是正文充足，而非耗尽 stream。
      expect(scrollController.position.extentAfter, greaterThan(500));
      expect(scrollController.position.pixels, closeTo(0, 0.5));
      expect(network.requests, hasLength(3));
      await _pumpFrames(tester);
      expect(network.requests, hasLength(3));
      expect(tester.takeException(), isNull);
    } finally {
      // 在测试不变量检查前卸载，先处理页面 disposeDeferred，再销毁 provider。
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
      } finally {
        container.dispose();
        PlatformUtils.debugDesktopOverride = null;
        await tester.pump(Duration.zero);
        await tester.binding.setSurfaceSize(null);
      }
    }
  });
}
