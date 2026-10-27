import 'dart:async';

import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/startup/app_startup.dart';
import 'package:fluxdo/services/startup_progress.dart';

/// 记录调用顺序的假启动端口。所有步骤写进同一份 [log]，测试按顺序断言。
class FakeStartupPorts implements AppStartupPorts {
  FakeStartupPorts({
    this.preloadedUser,
    this.storedSession = true,
    this.path = StartupPreloadPath.native,
  });

  final List<String> log = [];

  /// 预加载完成后能读到的当前用户 JSON；null 表示匿名首页。
  Map<String, dynamic>? preloadedUser;

  /// [checkStoredSession] 的结果；[storedSessionGate] 不为 null 时等它。
  bool storedSession;
  @override
  bool validatePreloadedSession = false;
  Completer<bool>? storedSessionGate;
  int storedSessionChecks = 0;
  Future<bool> Function()? storedSessionBody;

  StartupPreloadPath path;

  /// 预加载过程中要报给启动页的进度（按顺序回放）。
  void Function(StartupPreloadProgress progress)? onPreload;

  /// 预加载等它完成；不为 null 时可模拟慢预加载 / 失败。
  Completer<void>? preloadGate;

  /// 预加载的实际过程（例如用真实 Dio 走一遍直连 → 回退直连）；抛错即预加载失败。
  Future<void> Function()? preloadBody;
  Object? preloadError;
  bool _preloaded = false;

  /// 接线 / priming 时额外执行的检查（例如「priming 时探测必须已接上」）。
  void Function()? onAttach;
  void Function()? onPrime;

  final StreamController<void> auth = StreamController<void>.broadcast();

  Object? reconcileError;

  @override
  bool storesReady = true;

  @override
  void attachSessionHooks() {
    log.add('attachSessionHooks');
    onAttach?.call();
  }

  @override
  Stream<void> get authStateChanges => auth.stream;

  @override
  void prime({required String reason}) {
    log.add('prime');
    onPrime?.call();
  }

  @override
  bool get isPreloaded => _preloaded;

  @override
  Future<StartupPreloadPath?> preload({
    required String reason,
    required StartupPreloadProgress progress,
  }) async {
    log.add('preload');
    onPreload?.call(progress);
    final gate = preloadGate;
    if (gate != null) await gate.future;
    final body = preloadBody;
    if (body != null) {
      try {
        await body();
      } catch (_) {
        log.add('preload:failed');
        rethrow;
      }
    }
    final error = preloadError;
    if (error != null) {
      preloadError = null;
      log.add('preload:failed');
      throw error;
    }
    _preloaded = true;
    log.add('preload:done');
    return path;
  }

  @override
  void afterPreload() => log.add('afterPreload');

  @override
  Map<String, dynamic>? get preloadedUserJson =>
      _preloaded ? preloadedUser : null;

  @override
  Future<bool> checkStoredSession() async {
    storedSessionChecks++;
    log.add('checkStoredSession');
    final body = storedSessionBody;
    if (body != null) return body();
    final gate = storedSessionGate;
    if (gate != null) return gate.future;
    return storedSession;
  }

  @override
  void publishUser(User user) => log.add('publishUser:${user.username}');

  @override
  void settleAfterNativePreload({required String reason}) =>
      log.add('settleAfterNativePreload:$reason');

  @override
  void startClearanceRefresh({required String reason}) =>
      log.add('startClearanceRefresh:$reason');

  @override
  Future<void> disableBackgroundKeepAlive() async =>
      log.add('disableBackgroundKeepAlive');

  @override
  void reloadStoresAfterBackground() => log.add('reloadStoresAfterBackground');

  @override
  Future<void> reconcileAfterBackground() async {
    log.add('reconcileAfterBackground');
    final error = reconcileError;
    if (error != null) throw error;
  }

  @override
  void exitBackgroundPolling() => log.add('exitBackgroundPolling');

  @override
  void ensureNetworkAlive() => log.add('ensureNetworkAlive');

  @override
  void resumeBrowserTrust({required String reason}) =>
      log.add('resumeBrowserTrust:$reason');
}

/// 记录启停的登录后启动项（代替 MainPage 的 MessageBus 频道）。
class FakePostLoginStart implements PostLoginStart {
  FakePostLoginStart(this.log, {this.name = 'message_bus'});

  final List<String> log;

  @override
  final String name;

  @override
  void start(SessionVerdict verdict) => log.add('$name:start');

  @override
  void stop() => log.add('$name:stop');
}

const aliceJson = <String, dynamic>{'id': 7, 'username': 'alice'};
