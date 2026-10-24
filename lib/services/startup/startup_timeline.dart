import '../app_logger.dart';

/// 冷启动时间线：从 main() 入口起算各节点的毫秒数，首个内容出来（或预加载失败）时
/// 写一条 `startup_timeline` 日志，每个进程只写一次。用来对比连接层改动前后的冷启动耗时。
class StartupTimeline {
  StartupTimeline._();

  static final Stopwatch _watch = Stopwatch();
  static final Map<String, int> _marks = {};
  static bool _reported = false;

  /// main() 第一行调用
  static void start() {
    if (!_watch.isRunning) _watch.start();
  }

  /// 记一个节点；同名只记第一次，写过日志后不再记
  static void mark(String name) {
    if (!_watch.isRunning || _reported) return;
    _marks.putIfAbsent(name, () => _watch.elapsedMilliseconds);
  }

  /// 记最后一个节点并写日志
  static void finish(String name) {
    if (!_watch.isRunning || _reported) return;
    mark(name);
    _reported = true;
    AppLogger.info(
      '冷启动 ${_marks[name]} ms（$name）',
      tag: 'Startup',
      fields: {
        'type': 'startup',
        'event': 'startup_timeline',
        'marks': Map<String, int>.of(_marks),
      },
    );
  }
}
