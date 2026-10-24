import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/message_bus/topic_list_events.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/widgets/topic/topic_list_updates_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuietMessageBus extends MessageBusInitNotifier {
  @override
  void build() {}
}

/// 用最小的列表页验证 mixin：列表停在顶部才自动载入，载入走 loadTopicUpdates
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.controller, required this.applied});

  final ScrollController controller;
  final List<List<int>> applied;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host>
    with TopicListUpdatesMixin<_Host> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      if (widget.controller.position.pixels <= 1) {
        scheduleAutoApplyTopicUpdates();
      }
    });
  }

  @override
  bool get canAutoApplyTopicUpdates =>
      TopicListUpdatesMixin.scrolledToTop(widget.controller);

  @override
  Future<void> applyTopicUpdates() async {
    final ids = await loadTopicUpdates((ids) async => ids);
    widget.applied.add(ids);
  }

  @override
  Widget build(BuildContext context) {
    watchTopicUpdates(TopicListUpdateQuery(filter: TopicListFilter.latest));
    return ListView.builder(
      controller: widget.controller,
      itemCount: 60,
      itemBuilder: (_, i) => SizedBox(
        height: 80,
        child: Text(i == 0 ? 'pending ${topicUpdateSnapshot.length}' : '$i'),
      ),
    );
  }
}

void main() {
  late ScrollController controller;
  late List<List<int>> applied;
  late ProviderContainer container;

  Future<void> pumpHost(WidgetTester tester, {required bool enabled}) async {
    SharedPreferences.setMockInitialValues({
      'pref_auto_load_topic_updates': enabled,
    });
    final prefs = await SharedPreferences.getInstance();
    controller = ScrollController();
    addTearDown(controller.dispose);
    applied = [];
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        messageBusInitProvider.overrideWith(_QuietMessageBus.new),
        categoryMapProvider.overrideWithValue(
          const AsyncValue<Map<int, Category>>.data({}),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: _Host(controller: controller, applied: applied),
          ),
        ),
      ),
    );
  }

  void publish(int topicId) {
    container
        .read(topicListEventsProvider.notifier)
        .publish(TopicListEvent(topicId: topicId, type: 'new_topic'));
  }

  testWidgets('开关关闭时只显示提示，不自动载入', (tester) async {
    await pumpHost(tester, enabled: false);
    publish(1);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(applied, isEmpty);
    expect(find.text('pending 1'), findsOneWidget);
  });

  testWidgets('停在顶部时攒批后自动载入一次', (tester) async {
    await pumpHost(tester, enabled: true);
    publish(1);
    await tester.pump();
    publish(2);
    await tester.pump();
    expect(applied, isEmpty, reason: '先攒一会儿再拉');
    await tester.pump(TopicListUpdatesMixin.autoApplyBatchDelay);
    await tester.pump();
    expect(applied, [
      [1, 2],
    ]);
    expect(find.text('pending 0'), findsOneWidget);
  });

  testWidgets('往下浏览时不载入，回到顶部后再载入', (tester) async {
    await pumpHost(tester, enabled: true);
    controller.jumpTo(800);
    await tester.pump();
    publish(1);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(applied, isEmpty);

    controller.jumpTo(0);
    await tester.pump();
    await tester.pump(TopicListUpdatesMixin.autoApplyBatchDelay);
    await tester.pump();
    expect(applied, [
      [1],
    ]);
  });

  testWidgets('两次自动载入至少间隔 autoApplyMinInterval', (tester) async {
    await pumpHost(tester, enabled: true);
    publish(1);
    await tester.pump();
    await tester.pump(TopicListUpdatesMixin.autoApplyBatchDelay);
    await tester.pump();
    expect(applied, hasLength(1));

    publish(2);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(applied, hasLength(1), reason: '离上次还不到最小间隔');
    await tester.pump(TopicListUpdatesMixin.autoApplyMinInterval);
    await tester.pump();
    expect(applied, [
      [1],
      [2],
    ]);
  });

  testWidgets('被其他页面盖住时不载入，返回后补上', (tester) async {
    await pumpHost(tester, enabled: true);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('detail'))),
    );
    await tester.pumpAndSettle();
    publish(1);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(applied, isEmpty);

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(TopicListUpdatesMixin.autoApplyBatchDelay);
    await tester.pump();
    expect(applied, [
      [1],
    ]);
  });
}
