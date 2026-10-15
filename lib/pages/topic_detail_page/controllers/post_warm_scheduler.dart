import 'dart:async' show Timer;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphWarmup;

import '../../../utils/frame_jank_monitor.dart';
import '../../../utils/idle_task.dart';
import '../../../widgets/post/post_item/post_render_prep.dart';

/// 话题帖子列表的预热调度:把「首次滚到某楼层」原本要在滚动帧里付的
/// 解析、flatten、排版提前做完,产物落全局缓存(RenderParseCache /
/// FlattenCache / ParagraphLayoutCache),滚到时全程查表。
///
/// 本类只管**何时、按什么顺序、用多少时间**做;每个原子单位做什么由
/// [PostWarmHost.warmUnit](→ [PostRenderPrep.warmOneUnit])决定。列表
/// widget 只转发滚动事件与数据落地事件,时钟与帧回调经 [WarmClock] 注入。
///
/// 两种调度:
/// - **空闲链**(scheduleIdleTask,8ms 定时器链):列表静止时跑,每步一个
///   原子单位(短帖解析一帖 / 长帖解析一块 / 一片 ≤4ms 的段落 flatten +
///   排版),不超一帧预算。
/// - **帧隙链**(post-frame 回调,每帧一看):惯性滚动期间跑。连续甩动
///   时手指一直在接惯性,ScrollEnd 根本不会来,空闲链没有机会;而真机
///   录屏里的掉帧恰恰发生在甩动中新楼层进视口那几帧。这一帧的 UI 工作
///   (从本帧滚动 tick 派发的 ScrollUpdate 起算)不到半帧才借剩余的一截
///   做一个单位,帧本身已经吃紧就跳过;场景已提交合成,借的只是下一帧
///   的起跑时间,按「半帧 − 已用 − 余量」封顶。
///
/// 触发时机:
/// - **数据落地**(首屏 / 翻页 / gap 填充)后的下一帧,见 [onDataLanded]:
///   静止 → 起空闲链;惯性中 → 帧隙链下一步按新楼层集合重建队列;
///   手指拖动中 → 不动,松手进惯性再建;
/// - **滚动停止**([onScrollEnd]):锚点楼层变了,按新位置起空闲链;
/// - **滚动开始**([onScrollStart]):只作废不重建。手指拖动期间没有
///   ticker,scheduleIdleTask 的「动画中让路」判定不生效,旧链会与
///   拖动帧抢主线程;
/// - **进入惯性**(第一条 ballistic 的 [onScrollUpdate]):起帧隙链;
///   手指再按下接住惯性 → Hold 触发 ScrollEnd → 空闲链 → 拖动 ScrollStart
///   → 作废,松手又进惯性,循环自洽。
///
/// 队列按距离排序:锚点楼层起沿滚动方向 [aheadPosts] 楼,再反向
/// [behindPosts] 楼(静止时默认向后)。惯性中锚点一直在走,离建队锚点
/// 超过 [reanchorPosts] 楼就按新锚点重建;已热过的楼层一圈查表(<0.1ms)
/// 即过,重建不重复付费。
///
/// 每次(重)起链代际 +1,旧链的回调见代际不符即退出。
class PostWarmScheduler {
  PostWarmScheduler({required PostWarmHost host, WarmClock? clock})
    : _host = host,
      _clock = clock ?? WarmClock.binding;

  final PostWarmHost _host;
  final WarmClock _clock;

  static const int aheadPosts = 16;
  static const int behindPosts = 4;
  static const int reanchorPosts = 4;

  /// 探针未收敛(首屏还没有直绘段落挂载)时整轮重试的间隔与上限
  static const Duration probeRetryDelay = Duration(milliseconds: 250);
  static const int probeRetryMax = 8;
  static const int stepBudgetMicros = 4000;

  /// 帧隙链:不足 1ms 的余量不借;半帧线再留 0.5ms 给回调本身与帧收尾
  static const int slackMinMicros = 1000;
  static const int slackMarginMicros = 500;

  int _generation = 0;
  bool _disposed = false;
  void Function()? _cancelRetry;

  /// 预热队列(postNumber,按距离排序;null = 下一步再建,好让 ScrollEnd
  /// 之后的 post-frame 可见性上报先把锚点更新掉)、建队时的锚点与游标
  List<int>? _queue;
  int? _queueAnchor;
  int _queuePos = 0;
  final PostWarmCursor _cursor = PostWarmCursor();
  bool _probeMissing = false;
  int _probeRetries = 0;

  /// 当前是帧隙链(惯性滚动中)还是空闲链
  bool _inFrameSlack = false;

  /// 本帧 UI 工作起点:每条本列表的 ScrollUpdate 到达时记下。滚动 tick
  /// 在 build 之前派发,post-frame 时读它就是本帧 build+layout+paint 的耗时
  int? _frameStartMicros;

  /// 诊断计数(WARMUP 事件,监控关闭时不拼串)
  int _parsedPosts = 0;
  int _parsedChunks = 0;
  int _steps = 0;
  int _paragraphsAtStart = 0;
  int? _startedAtMicros;

  /// 当前队列(测试/诊断用;null = 尚未建)
  List<int>? get debugQueue => _queue;

  /// 是否在跑帧隙链
  bool get inFrameSlack => _inFrameSlack;

  // ---------------------------------------------------------------------
  // 事件(列表 widget 转发,只认本列表自己的 depth-0 滚动)
  // ---------------------------------------------------------------------

  /// 本列表的 ScrollUpdate:记本帧 UI 工作起点;手指离开进入惯性的
  /// 第一条更新起帧隙链,惯性中再被手指拖动则作废。
  void onScrollUpdate({required bool ballistic}) {
    if (_disposed) return;
    _frameStartMicros = _clock.nowMicros();
    if (ballistic && !_inFrameSlack) {
      _restart(frameSlack: true);
    } else if (!ballistic && _inFrameSlack) {
      _cancel();
    }
  }

  /// 本列表的 ScrollStart:只作废,不重建
  void onScrollStart() {
    if (_disposed) return;
    _cancel();
  }

  /// 本列表的 ScrollEnd(含 Hold 接住惯性):按新锚点起空闲链
  void onScrollEnd() {
    if (_disposed) return;
    _restart();
  }

  /// 数据落地(首屏 / 翻页 / gap 填充 —— 楼层集合变了;纯数据更新不要
  /// 调)。在 build 中调用也安全:推迟到帧后再起链。
  void onDataLanded() {
    if (_disposed) return;
    _clock.postFrame(() {
      if (_disposed) return;
      if (_host.isScrollActive) {
        // 滚动中落地(翻页):惯性链在跑就让它下一步按新楼层集合重建队列;
        // 手指拖动中没有链,松手进入惯性时会从头建
        if (_inFrameSlack) _resetQueue();
        return;
      }
      _restart();
    });
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _cancelRetry?.call();
    _cancelRetry = null;
  }

  // ---------------------------------------------------------------------
  // 链
  // ---------------------------------------------------------------------

  bool _isLive(int generation) => !_disposed && generation == _generation;

  void _cancel() {
    // 帧隙链没有自然收尾(总是被 ScrollEnd / ScrollStart 作废),在这里记
    // 一条,一次惯性一条
    if (_inFrameSlack) _logRound('帧隙');
    _inFrameSlack = false;
    _generation++;
    _cancelRetry?.call();
    _cancelRetry = null;
  }

  void _resetQueue() {
    _queue = null;
    _queueAnchor = null;
    _queuePos = 0;
    _cursor.reset();
  }

  /// 作废旧链、从当前锚点重新起一条预热链(空闲链或帧隙链)
  void _restart({bool frameSlack = false}) {
    _cancel();
    _resetQueue();
    _probeMissing = false;
    _probeRetries = 0;
    _parsedPosts = 0;
    _parsedChunks = 0;
    _steps = 0;
    _paragraphsAtStart = ParagraphWarmup.warmedParagraphs;
    _startedAtMicros = _clock.nowMicros();
    _inFrameSlack = frameSlack;
    if (frameSlack) {
      _stepInFrame(_generation);
    } else {
      _stepIdle(_generation);
    }
  }

  List<int> _buildQueue() {
    final count = _host.postCount;
    if (count == 0) return const [];
    final anchorNumber = _host.anchorPostNumber;
    final anchor =
        (anchorNumber == null ? null : _host.indexOfPostNumber(anchorNumber)) ??
        _host.fallbackAnchorIndex.clamp(0, count - 1);
    _queueAnchor = _host.postNumberAt(anchor);
    // 往前面的楼层滚 = 反向;静止(idle)默认向后
    final step = _host.scrollingTowardEarlierPosts ? -1 : 1;
    final queue = <int>[];
    for (var i = 0; i <= aheadPosts; i++) {
      final index = anchor + i * step;
      if (index < 0 || index >= count) break;
      queue.add(_host.postNumberAt(index));
    }
    for (var i = 1; i <= behindPosts; i++) {
      final index = anchor - i * step;
      if (index < 0 || index >= count) break;
      queue.add(_host.postNumberAt(index));
    }
    return queue;
  }

  /// 惯性滚动中锚点一直在走:离建队锚点超过 [reanchorPosts] 楼就按新锚点、
  /// 新方向重建。
  void _maybeReanchor() {
    final anchor = _host.anchorPostNumber;
    final built = _queueAnchor;
    if (_queue == null || anchor == null || built == null) return;
    final a = _host.indexOfPostNumber(anchor);
    final b = _host.indexOfPostNumber(built);
    if (a == null || b == null || (a - b).abs() < reanchorPosts) return;
    _resetQueue();
  }

  /// 沿队列找到下一个还有活干的楼层,做一个原子单位;一串已热楼层的查表
  /// 也会累积,超预算就先交还主线程。返回 false = 队列已走完。
  bool _runUnit(int budgetMicros) {
    final queue = _queue ??= _buildQueue();
    _steps++;
    final budget = WarmBudget(budgetMicros, _clock.nowMicros);
    while (_queuePos < queue.length) {
      if (budget.elapsedMicros > budgetMicros) return true;
      final outcome = _host.warmUnit(queue[_queuePos], _cursor, budget);
      switch (outcome) {
        case PostWarmOutcome.parsedPost:
          _parsedPosts++;
        case PostWarmOutcome.parsedChunk:
          _parsedChunks++;
        case PostWarmOutcome.probeMissing:
          _probeMissing = true;
        case PostWarmOutcome.warmedParagraphs:
        case PostWarmOutcome.outOfBudget:
        case PostWarmOutcome.done:
          break;
      }
      if (outcome.staysOnPost) return true;
      _queuePos++;
      _cursor.reset();
    }
    return false;
  }

  /// 空闲链的一步。scheduleIdleTask 是我们自己包的安全版:Flutter 3.44 的
  /// SchedulerBinding.scheduleTask(idle) 撞上持续动画会让事件循环忙等
  /// 活锁,原生 scheduleTask 不能用。
  void _stepIdle(int generation) {
    _clock.idle(() {
      if (!_isLive(generation)) return;
      if (_runUnit(stepBudgetMicros)) {
        _stepIdle(generation);
      } else {
        _finish(generation);
      }
    }, isCanceled: () => !_isLive(generation));
  }

  /// 帧隙链的一步:每帧 post-frame 看一眼余量,够就做一个单位;队列走完
  /// 不收工,锚点走远了重建接着做,直到被 ScrollEnd / ScrollStart 作废。
  void _stepInFrame(int generation) {
    _clock.postFrame(() {
      if (!_isLive(generation)) return;
      final budget = _frameSlackBudgetMicros();
      if (budget >= slackMinMicros) {
        _maybeReanchor();
        if (!_runUnit(budget) &&
            _probeMissing &&
            _probeRetries < probeRetryMax) {
          // 探针缺失只跳过了段落:下一帧从头再走一遍(解析都已命中)
          _probeRetries++;
          _probeMissing = false;
          _resetQueue();
        }
      }
      _stepInFrame(generation);
    });
  }

  /// 本帧还能借给预热的时长(µs):本帧 UI 工作不到半帧才借,封顶
  /// [stepBudgetMicros];本帧没有 ScrollUpdate(起点停在上一帧)则已用
  /// 读数很大,自然不借。
  int _frameSlackBudgetMicros() {
    final start = _frameStartMicros;
    if (start == null) return 0;
    final refreshRate = _host.refreshRate;
    final intervalMicros = (1e6 / (refreshRate > 0 ? refreshRate : 60)).round();
    final slack =
        intervalMicros ~/ 2 - (_clock.nowMicros() - start) - slackMarginMicros;
    return slack.clamp(0, stepBudgetMicros);
  }

  /// 空闲链队列走完:探针缺失时延后整轮重做(已解析部分都是命中,只补
  /// 段落),否则记一条诊断事件收工。
  void _finish(int generation) {
    if (_probeMissing && _probeRetries < probeRetryMax) {
      _probeRetries++;
      _cancelRetry?.call();
      _cancelRetry = _clock.timer(probeRetryDelay, () {
        if (!_isLive(generation)) return;
        _queuePos = 0;
        _cursor.reset();
        _probeMissing = false;
        _stepIdle(generation);
      });
      return;
    }
    _logRound('空闲');
  }

  void _logRound(String mode) {
    if (!FrameJankMonitor.isRunning) return;
    final startedAt = _startedAtMicros;
    final elapsed = startedAt == null
        ? 0
        : (_clock.nowMicros() - startedAt) ~/ 1000;
    final paragraphs = ParagraphWarmup.warmedParagraphs - _paragraphsAtStart;
    final queue = _queue ?? const <int>[];
    FrameJankMonitor.logEvent(
      'WARMUP',
      '$mode 锚#${_host.anchorPostNumber ?? '-'} 队列${queue.length}楼 '
          '解析 短帖$_parsedPosts 块$_parsedChunks '
          '段落$paragraphs 步数$_steps 历时${elapsed}ms'
          '${_probeMissing ? ' 探针缺失' : ''}',
    );
  }
}

/// 调度器向宿主(帖子列表)要的东西:楼层序、锚点、滚动状态,以及
/// 「对某楼层做一个预热单位」。读的都是调用时刻的最新值。
abstract interface class PostWarmHost {
  /// 已加载楼层数
  int get postCount;

  /// 第 [index] 个已加载楼层的楼层号
  int postNumberAt(int index);

  /// 楼层号 → 已加载下标;不在列表里返回 null
  int? indexOfPostNumber(int postNumber);

  /// 视口锚点楼层号(最近一次可见性上报;尚未上报为 null)
  int? get anchorPostNumber;

  /// 锚点未知时的兜底下标(center 楼层)
  int get fallbackAnchorIndex;

  /// 用户正往前面的楼层滚(userScrollDirection == forward)
  bool get scrollingTowardEarlierPosts;

  /// 列表正在滚动(拖动或惯性)
  bool get isScrollActive;

  /// 屏幕刷新率(Hz),帧隙余量按半帧算
  double get refreshRate;

  /// 对 [postNumber] 楼做一个原子单位的预热(楼层已不在列表里返回
  /// [PostWarmOutcome.done])
  PostWarmOutcome warmUnit(
    int postNumber,
    PostWarmCursor cursor,
    WarmBudget budget,
  );
}

/// 调度器的时钟与回调来源(生产 = [WarmClock.binding],测试注入假时钟)
abstract interface class WarmClock {
  static const WarmClock binding = _BindingWarmClock();

  /// 单调时钟读数(µs):帧起点、帧余量、单步预算都从它算
  int nowMicros();

  /// 帧后回调(post-frame,一次性)
  void postFrame(void Function() callback);

  /// 空闲任务(动画进行中让路)
  void idle(void Function() task, {required bool Function() isCanceled});

  /// 一次性定时器,返回取消函数
  void Function() timer(Duration delay, void Function() callback);
}

class _BindingWarmClock implements WarmClock {
  const _BindingWarmClock();

  static final Stopwatch _monotonic = Stopwatch()..start();

  @override
  int nowMicros() => _monotonic.elapsedMicroseconds;

  @override
  void postFrame(void Function() callback) =>
      SchedulerBinding.instance.addPostFrameCallback((_) => callback());

  @override
  void idle(void Function() task, {required bool Function() isCanceled}) =>
      scheduleIdleTask(task, isCanceled: isCanceled);

  @override
  void Function() timer(Duration delay, void Function() callback) =>
      Timer(delay, callback).cancel;
}
