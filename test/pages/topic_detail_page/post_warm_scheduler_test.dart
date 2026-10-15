// 预热调度器(PostWarmScheduler)的队列 / 预算 / 代际语义。
//
// 时钟、帧回调、空闲任务、定时器全部注入假实现:一帧 = 跑一轮 post-frame
// 回调;惯性滚动的每帧由一条 ballistic ScrollUpdate 起头(记本帧 UI 工作
// 起点),帧余量 = 半帧 − 本帧已用 − 0.5ms,封顶 4ms。
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/post_warm_scheduler.dart';
import 'package:fluxdo/widgets/post/post_item/post_render_prep.dart';

class _FakeClock implements WarmClock {
  int now = 0;
  List<void Function()> _frame = [];
  final List<({void Function() task, bool Function() isCanceled})> _idle = [];
  final List<({int at, void Function() callback, List<bool> canceled})>
  _timers = [];

  @override
  int nowMicros() => now;

  @override
  void postFrame(void Function() callback) => _frame.add(callback);

  @override
  void idle(void Function() task, {required bool Function() isCanceled}) =>
      _idle.add((task: task, isCanceled: isCanceled));

  @override
  void Function() timer(Duration delay, void Function() callback) {
    final canceled = [false];
    _timers.add((
      at: now + delay.inMicroseconds,
      callback: callback,
      canceled: canceled,
    ));
    return () => canceled[0] = true;
  }

  /// 跑一帧的 post-frame 回调(回调里新登记的排到下一帧,同 Flutter)
  void frame() {
    final callbacks = _frame;
    _frame = [];
    for (final callback in callbacks) {
      callback();
    }
  }

  int get pendingFrameCallbacks => _frame.length;

  /// 依次跑空闲任务直到没有(已作废的不执行,同 scheduleIdleTask)
  void runIdle() {
    for (var guard = 0; _idle.isNotEmpty; guard++) {
      if (guard > 10000) fail('空闲链没有收尾');
      final next = _idle.removeAt(0);
      if (!next.isCanceled()) next.task();
    }
  }

  /// 时间前进 [d],到点的定时器触发
  void elapse(Duration d) {
    now += d.inMicroseconds;
    final due = _timers.where((t) => t.at <= now).toList();
    _timers.removeWhere((t) => t.at <= now);
    for (final t in due) {
      if (!t.canceled[0]) t.callback();
    }
  }
}

typedef _Warm =
    PostWarmOutcome Function(
      int postNumber,
      PostWarmCursor cursor,
      WarmBudget budget,
    );

class _FakeHost implements PostWarmHost {
  _FakeHost(int count) : numbers = [for (var i = 1; i <= count; i++) i];

  List<int> numbers;
  int? anchor;
  int fallback = 0;
  bool towardEarlier = false;
  bool scrolling = false;

  /// 每次 warmUnit:(楼层号, 游标单位, 游标节点)
  final visits = <(int, int, int)>[];

  /// 默认:每楼都已热完
  _Warm onWarm = (_, _, _) => PostWarmOutcome.done;

  List<int> get visitedPosts => [for (final v in visits) v.$1];

  @override
  int get postCount => numbers.length;

  @override
  int postNumberAt(int index) => numbers[index];

  @override
  int? indexOfPostNumber(int postNumber) {
    final index = numbers.indexOf(postNumber);
    return index < 0 ? null : index;
  }

  @override
  int? get anchorPostNumber => anchor;

  @override
  int get fallbackAnchorIndex => fallback;

  @override
  bool get scrollingTowardEarlierPosts => towardEarlier;

  @override
  bool get isScrollActive => scrolling;

  @override
  double get refreshRate => 60;

  @override
  PostWarmOutcome warmUnit(
    int postNumber,
    PostWarmCursor cursor,
    WarmBudget budget,
  ) {
    visits.add((postNumber, cursor.unit, cursor.node));
    return onWarm(postNumber, cursor, budget);
  }
}

void main() {
  late _FakeClock clock;
  late _FakeHost host;
  late PostWarmScheduler scheduler;

  setUp(() {
    clock = _FakeClock();
    host = _FakeHost(100);
    scheduler = PostWarmScheduler(host: host, clock: clock);
  });

  tearDown(() => scheduler.dispose());

  /// 惯性中的一帧:滚动 tick(ballistic ScrollUpdate)→ 本帧 UI 工作
  /// 用掉 [used] → post-frame
  void ballisticFrame({int used = 1000}) {
    scheduler.onScrollUpdate(ballistic: true);
    clock.now += used;
    clock.frame();
  }

  group('队列', () {
    test('锚点 40、往上滚:40…24,再 41…44', () {
      host
        ..anchor = 40
        ..towardEarlier = true;
      scheduler.onScrollEnd();
      clock.runIdle();
      expect(host.visitedPosts, [
        for (var n = 40; n >= 24; n--) n,
        41,
        42,
        43,
        44,
      ]);
    });

    test('锚点 40、往下滚(或静止):40…56,再 39…36', () {
      host.anchor = 40;
      scheduler.onScrollEnd();
      clock.runIdle();
      expect(host.visitedPosts, [
        for (var n = 40; n <= 56; n++) n,
        39,
        38,
        37,
        36,
      ]);
    });

    test('锚点未上报:按 center 楼层兜底;越界截断', () {
      host.fallback = 1; // 第 2 楼
      host.towardEarlier = true;
      scheduler.onScrollEnd();
      clock.runIdle();
      expect(host.visitedPosts, [2, 1, 3, 4, 5, 6]);
    });

    test('锚点移动 4 楼 → 按新锚点、新方向重建队列(3 楼不重建)', () {
      host.anchor = 40;
      // 每楼永远有活:游标一直停在锚点楼
      host.onWarm = (_, _, _) => PostWarmOutcome.parsedPost;
      ballisticFrame();
      final built = scheduler.debugQueue;
      expect(built!.first, 40);

      host.anchor = 43;
      ballisticFrame();
      expect(identical(scheduler.debugQueue, built), isTrue);
      expect(host.visitedPosts.last, 40);

      host
        ..anchor = 44
        ..towardEarlier = true;
      ballisticFrame();
      expect(identical(scheduler.debugQueue, built), isFalse);
      expect(scheduler.debugQueue!.take(3), [44, 43, 42]);
      expect(host.visitedPosts.last, 44);
    });
  });

  group('帧隙预算', () {
    test('预算用尽 → 下一帧在同一游标处续', () {
      host.anchor = 40;
      host.onWarm = (_, cursor, budget) {
        clock.now += budget.remainingMicros; // 吃光预算
        cursor.node += 2;
        return PostWarmOutcome.warmedParagraphs;
      };
      ballisticFrame();
      ballisticFrame();
      ballisticFrame();
      expect(host.visits, [(40, 0, 0), (40, 0, 2), (40, 0, 4)]);
    });

    test('一串已热楼层的查表累积超预算 → 交还主线程,下一帧从下一楼续', () {
      host.anchor = 40;
      host.onWarm = (_, _, _) {
        clock.now += 1500;
        return PostWarmOutcome.done;
      };
      // 60Hz 半帧 8333µs − 已用 1000 − 余量 500 → 封顶 4000
      ballisticFrame();
      expect(host.visitedPosts, [40, 41, 42]);
      ballisticFrame();
      expect(host.visitedPosts, [40, 41, 42, 43, 44, 45]);
    });

    test('本帧已吃紧(余量不足 1ms)不借', () {
      host.anchor = 40;
      ballisticFrame(used: 7000); // 8333 − 7000 − 500 < 1000
      expect(host.visits, isEmpty);
      ballisticFrame(used: 1000);
      expect(host.visits, isNotEmpty);
    });

    test('本帧没有 ScrollUpdate(起点停在上一帧)不借', () {
      host.anchor = 40;
      ballisticFrame();
      final count = host.visits.length;
      clock.now += 20000;
      clock.frame();
      expect(host.visits.length, count);
    });
  });

  group('链的起停', () {
    test('Hold(接住惯性 → ScrollEnd)立即停帧隙链;随后拖动 ScrollStart 作废空闲链', () {
      host.anchor = 40;
      host.onWarm = (_, _, _) => PostWarmOutcome.parsedPost;
      ballisticFrame();
      expect(scheduler.inFrameSlack, isTrue);
      final count = host.visits.length;

      scheduler.onScrollEnd(); // Hold
      expect(scheduler.inFrameSlack, isFalse);
      clock.now += 100;
      clock.frame(); // 旧帧隙链的 post-frame 回调见代际不符,不做也不续
      expect(host.visits.length, count);
      expect(clock.pendingFrameCallbacks, 0);

      scheduler.onScrollStart(); // 拖动
      clock.runIdle();
      expect(host.visits.length, count);
    });

    test('惯性中被手指拖动(非 ballistic 更新)→ 作废帧隙链', () {
      host.anchor = 40;
      ballisticFrame();
      scheduler.onScrollUpdate(ballistic: false);
      expect(scheduler.inFrameSlack, isFalse);
      final count = host.visits.length;
      ballisticFrame(); // 松手再进惯性:重新起链
      expect(scheduler.inFrameSlack, isTrue);
      expect(host.visits.length, greaterThan(count));
    });

    test('代际:重起链后旧链的空闲步不执行', () {
      host.anchor = 40;
      scheduler.onScrollEnd();
      scheduler.onScrollEnd();
      clock.runIdle();
      // 只走了一遍队列(17 + 4 楼)
      expect(host.visits, hasLength(21));
    });

    test('代际:ScrollStart 作废后,探针重试定时器到点也不再干活', () {
      host.anchor = 40;
      host.onWarm = (_, _, _) => PostWarmOutcome.probeMissing;
      scheduler.onScrollEnd();
      clock.runIdle();
      expect(host.visits, hasLength(21));

      scheduler.onScrollStart();
      clock.elapse(PostWarmScheduler.probeRetryDelay);
      clock.runIdle();
      expect(host.visits, hasLength(21));
    });

    test('探针缺失:空闲链延后整轮重做,有上限', () {
      host.anchor = 40;
      host.onWarm = (_, _, _) => PostWarmOutcome.probeMissing;
      scheduler.onScrollEnd();
      clock.runIdle();
      for (var i = 0; i < PostWarmScheduler.probeRetryMax + 3; i++) {
        clock.elapse(PostWarmScheduler.probeRetryDelay);
        clock.runIdle();
      }
      expect(
        host.visits,
        hasLength(21 * (PostWarmScheduler.probeRetryMax + 1)),
      );
    });

    test('dispose 后一切回调都不再干活', () {
      host.anchor = 40;
      scheduler.onDataLanded(); // 帧后起链
      scheduler.onScrollUpdate(ballistic: true); // 帧隙链
      scheduler.dispose();
      clock.now += 1000;
      clock.frame();
      clock.runIdle();
      expect(host.visits, isEmpty);
      expect(clock.pendingFrameCallbacks, 0);
    });
  });

  group('数据落地', () {
    test('静止:下一帧起空闲链', () {
      host.anchor = 40;
      scheduler.onDataLanded();
      clock.runIdle();
      expect(host.visits, isEmpty, reason: '推迟到帧后');
      clock.frame();
      clock.runIdle();
      expect(host.visits, hasLength(21));
    });

    test('惯性中:不起新链,让帧隙链下一步按新楼层集合重建队列', () {
      host.anchor = 40;
      host.onWarm = (_, _, _) => PostWarmOutcome.parsedPost;
      ballisticFrame();
      final built = scheduler.debugQueue;

      host
        ..scrolling = true
        ..numbers = [for (var i = 1; i <= 200; i++) i];
      scheduler.onDataLanded();
      clock.frame();
      expect(scheduler.debugQueue, isNull);
      expect(scheduler.inFrameSlack, isTrue);

      ballisticFrame();
      expect(scheduler.debugQueue, isNot(same(built)));
      expect(scheduler.debugQueue!.first, 40);
    });

    test('手指拖动中:不动(松手进惯性再建)', () {
      host.anchor = 40;
      host.scrolling = true;
      scheduler.onDataLanded();
      clock.frame();
      clock.runIdle();
      expect(host.visits, isEmpty);
      expect(scheduler.inFrameSlack, isFalse);
    });
  });
}
