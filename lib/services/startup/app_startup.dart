import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/user.dart';
import '../app_logger.dart';
import '../startup_progress.dart';
import 'production_startup_ports.dart';

/// 冷启动序列的阶段，按声明顺序进入。
///
/// 「进入」只表示这一步已经开始：priming 与预加载照旧并行（priming 不阻塞
/// 预加载），启动页只等预加载，会话判定在后台进行。
enum StartupPhase {
  /// jar / prefs 等存储已就绪（main 的并行初始化批次完成）。
  storesReady,

  /// SessionTokenAuthority 接上服务端探测、User API Key 自愈与认证回调。
  sessionHooks,

  /// WebView cookie priming（含 `_t` 对账），不阻塞后续阶段。
  prime,

  /// 首页预加载（直连或启动期 WebView）。
  preload,

  /// 判定是否登录（含启动恢复链），不依赖任何 widget 是否在监听。
  sessionVerdict,

  /// 登录后启动项：浏览器会话补同步、cf_clearance 续期、MessageBus 等。
  postLogin,
}

/// 启动预加载实际走的路径。
enum StartupPreloadPath { native, webView }

/// 「是否已登录」的依据。
enum SessionVerdictSource {
  /// 预加载的首页数据里带着当前用户。
  preload,

  /// 预加载是匿名的，但本地会话检查（含恢复链）判定仍在登录。
  storedSession,

  /// 未登录。
  none,
}

/// 会话判定：全 App 唯一的「是否已登录」来源。
@immutable
class SessionVerdict {
  const SessionVerdict.loggedIn({this.user, required this.source})
    : loggedIn = true;

  const SessionVerdict.loggedOut()
    : loggedIn = false,
      user = null,
      source = SessionVerdictSource.none;

  final bool loggedIn;

  /// 预加载里带的当前用户；依据是 [SessionVerdictSource.storedSession] 时为
  /// null，用户资料由 CurrentUserNotifier 另行拉取。
  final User? user;

  final SessionVerdictSource source;

  @override
  String toString() =>
      'SessionVerdict(loggedIn=$loggedIn, source=${source.name}, '
      'user=${user?.username})';
}

/// 登录后启动项（判定为已登录时启动，判定为未登录时停止）。
abstract interface class PostLoginStart {
  String get name;

  void start(SessionVerdict verdict);

  void stop();
}

/// 启动序列依赖的外部能力。生产实现见 [ProductionStartupPorts]，测试用假实现。
abstract interface class AppStartupPorts {
  // --- storesReady ---

  /// jar 是否已初始化（只用于诊断：Dio 工厂在 jar 未就绪时会等待）。
  bool get storesReady;

  // --- sessionHooks ---

  /// 把服务端探测 / 自愈 / 认证回调接给 SessionTokenAuthority。
  void attachSessionHooks();

  /// 登录成功 / 登出的广播（每次都重新判定会话）。
  Stream<void> get authStateChanges;

  // --- prime ---

  /// WebView cookie priming（含 `_t` 对账），不阻塞调用方。
  void prime({required String reason});

  // --- preload ---

  bool get isPreloaded;

  /// 预加载首页；失败时抛错。返回实际走的路径。
  Future<StartupPreloadPath?> preload({
    required String reason,
    required StartupPreloadProgress progress,
  });

  /// 预加载成功后的轻量预热（表情回应、emoji）。
  void afterPreload();

  // --- sessionVerdict ---

  /// 预加载数据里的当前用户 JSON；匿名或未加载时为 null。
  Map<String, dynamic>? get preloadedUserJson;

  /// 标准 Discourse 站点没有专属 bootstrap 兜底。预加载来自 WebView 时，
  /// 它的 current_user 不能证明原生 jar 也有登录 Cookie，须先走恢复链。
  bool get validatePreloadedSession;

  /// 本地会话检查：用户名 → jar `_t`（缺失时走 jar 丢值恢复）→
  /// `/session/current.json`（被拒时走恢复链）。网络不通时保守判定为已登录。
  Future<bool> checkStoredSession();

  /// 把判定出的当前用户交给认证层（加速 DoH 授权等跟随它）。
  void publishUser(User user);

  // --- postLogin ---

  /// 直连预加载拿到登录态后补一次浏览器会话同步。
  void settleAfterNativePreload({required String reason});

  /// 启动 cf_clearance 续期（浏览器会话同步进行中时顺延到同步结束）。
  void startClearanceRefresh({required String reason});

  // --- resume ---

  Future<void> disableBackgroundKeepAlive();

  void reloadStoresAfterBackground();

  Future<void> reconcileAfterBackground();

  void exitBackgroundPolling();

  void ensureNetworkAlive();

  void resumeBrowserTrust({required String reason});
}

/// 冷启动序列：存储就绪 → 会话接线 → priming → 预加载 → 会话判定 →
/// 登录后启动项；以及回前台时的子集。
///
/// 以前这条序列散在 main()、PreheatGate、BrowserTrustCoordinator、
/// CurrentUserNotifier 与 MainPage 的监听里：「是否已登录」有三处各自判定，
/// 启动恢复链只在某个 widget 恰好 watch 了 currentUserProvider 时才会跑。
/// 现在顺序在这里声明一次，其余地方只读：
/// - PreheatGate 等 [ensurePreloaded]；
/// - CurrentUserNotifier 读 [verdictNow] / [verdict]；
/// - MainPage 注册登录后启动项、回前台调 [resumeFromBackground]；
/// - BrowserTrustCoordinator 读 [isLoggedIn]。
class AppStartup {
  AppStartup({
    required AppStartupPorts ports,
    StartupProgressReporter? progress,
  }) : _ports = ports,
       _reporter = progress ?? StartupProgressReporter.instance;

  static final AppStartup instance = AppStartup(
    ports: ProductionStartupPorts(),
  );

  final AppStartupPorts _ports;
  final StartupProgressReporter _reporter;

  final ValueNotifier<StartupPhase?> _phase = ValueNotifier(null);

  /// 冷启动当前进入的阶段（只前进不后退）。
  ValueListenable<StartupPhase?> get phase => _phase;

  bool _hooksAttached = false;
  bool _launched = false;
  String _launchReason = 'startup';
  Future<void>? _activePreload;
  bool _warmedUp = false;
  StartupPreloadPath? _preloadPath;

  bool _startupVerdictStarted = false;
  final Completer<void> _startupVerdictReady = Completer<void>();

  /// 登录态纪元：每次登录成功 / 登出广播 +1，旧纪元的判定结果作废。
  int _epoch = 0;
  _Resolution? _resolution;
  StreamSubscription<void>? _authSub;

  final ValueNotifier<SessionVerdict?> _session = ValueNotifier(null);
  final List<PostLoginStart> _postLoginStarts = [];
  bool _postLoginActive = false;

  // ---------------------------------------------------------------------------
  // 冷启动
  // ---------------------------------------------------------------------------

  /// 阶段 1→2：main() 在并行初始化批次（含 jar）完成后调用，同步完成。
  void storesReady() {
    _enter(StartupPhase.storesReady);
    if (!_ports.storesReady) {
      _log('stores not ready at storesReady()', warning: true);
    }
    _attachSessionHooks();
  }

  /// 阶段 3→6：网络栈（DoH / 代理 / VPN）落定后由 main() 调用，不阻塞 runApp。
  ///
  /// priming 与预加载并行开始（与以前一致）；预加载成功后在后台做会话判定，
  /// 判定为已登录再启动登录后启动项。
  void launch({String reason = 'startup'}) {
    if (_launched) return;
    _launched = true;
    _launchReason = reason;
    if (!_hooksAttached) {
      // 漏调 storesReady 也不能让 priming 在没有探测的情况下对账
      _log('launch() before storesReady(): attach session hooks now');
      _attachSessionHooks();
    }
    // 登录成功 / 登出广播从这里开始跟踪（此时网络栈已就绪，DiscourseService
    // 早已构造）；启动判定开始前的广播只推进纪元，由启动判定读最新状态
    _authSub ??= _ports.authStateChanges.listen((_) => _onAuthStateChanged());
    _enter(StartupPhase.prime);
    _ports.prime(reason: reason);
    unawaited(ensurePreloaded(reason: reason).catchError((Object _) {}));
  }

  /// 预加载（复用进行中的那次）+ 预热；第一次成功后开始会话判定。
  ///
  /// 失败时抛错（启动页显示错误与重试）。会话判定不在这个 Future 里：
  /// 启动页只等预加载，与以前一致。
  Future<void> ensurePreloaded({String reason = 'unknown'}) {
    final active = _activePreload;
    if (active != null) return active;
    late final Future<void> future;
    future = _preloadOnce(reason).whenComplete(() {
      if (identical(_activePreload, future)) _activePreload = null;
    });
    _activePreload = future;
    return future;
  }

  Future<void> _preloadOnce(String reason) async {
    if (!_ports.isPreloaded) {
      _enter(StartupPhase.preload);
      _reporter.begin();
      try {
        final path = await _ports.preload(
          reason: reason,
          progress: ReporterPreloadProgress(_reporter),
        );
        _preloadPath = path ?? _preloadPath;
      } finally {
        // 无论成功失败都清掉启动页状态，避免手动重试时先显示旧阶段
        _reporter.clear();
      }
    }
    if (!_warmedUp) {
      _warmedUp = true;
      try {
        _ports.afterPreload();
      } catch (e) {
        _log('afterPreload failed: $e', warning: true);
      }
    }
    _startStartupVerdict();
  }

  void _startStartupVerdict() {
    if (_startupVerdictStarted) return;
    _startupVerdictStarted = true;
    _enter(StartupPhase.sessionVerdict);
    _authSub ??= _ports.authStateChanges.listen((_) => _onAuthStateChanged());
    final future = _resolve(reason: _launchReason, startup: true);
    _startupVerdictReady.complete();
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object e, StackTrace s) {
          _log('startup session verdict failed: $e', warning: true);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 会话判定
  // ---------------------------------------------------------------------------

  /// 当前登录态纪元已经得出的判定；还在判定或尚未开始时为 null。
  SessionVerdict? get verdictNow {
    final r = _resolution;
    if (r == null || r.epoch != _epoch) return null;
    return r.settled;
  }

  /// 是否已登录（未判定时按未登录处理）。
  bool get isLoggedIn => verdictNow?.loggedIn ?? false;

  /// 最近一次生效的判定（启动项据此启停）。
  ValueListenable<SessionVerdict?> get session => _session;

  /// 当前登录态纪元的判定。
  ///
  /// 冷启动时等启动序列自己的判定（预加载完成后才开始，不另起一次）；之后
  /// 复用本纪元已有的判定。登录成功 / 登出广播会开启新纪元并重新判定。
  Future<SessionVerdict> verdict() {
    final r = _resolution;
    if (r != null && r.epoch == _epoch) return r.future;
    if (_launched && !_startupVerdictStarted) {
      return _startupVerdictReady.future.then((_) => verdict());
    }
    return _resolve(reason: 'verdict');
  }

  void _onAuthStateChanged() {
    _epoch++;
    if (_launched && !_startupVerdictStarted) {
      // 预加载还没完成：启动判定稍后会读到最新状态，不在这里另起一次
      _log('auth state changed before startup verdict (epoch=$_epoch)');
      return;
    }
    _log('auth state changed: re-resolve session (epoch=$_epoch)');
    unawaited(
      _resolve(reason: 'auth_state').then<void>(
        (_) {},
        onError: (Object e, StackTrace s) {
          _log('session verdict after auth change failed: $e', warning: true);
        },
      ),
    );
  }

  /// 判定是否已登录：标准站点须同时确认原生会话，缺失时走现有恢复链；
  /// LINUX DO 的预加载快路径保持不变。
  Future<SessionVerdict> _resolve({
    required String reason,
    bool startup = false,
  }) {
    final epoch = _epoch;
    final json = _ports.preloadedUserJson;
    if (json != null && !_ports.validatePreloadedSession) {
      // 同步得出：启动页放行时 CurrentUserNotifier 能直接拿到用户，不闪未登录
      final verdict = SessionVerdict.loggedIn(
        user: User.fromJson(json),
        source: SessionVerdictSource.preload,
      );
      final resolution = _Resolution(epoch, Future.value(verdict))
        ..settled = verdict;
      _resolution = resolution;
      _apply(verdict, epoch: epoch, startup: startup, reason: reason);
      return resolution.future;
    }

    final completer = Completer<SessionVerdict>();
    final resolution = _Resolution(epoch, completer.future);
    _resolution = resolution;
    () async {
      try {
        final ok = await _ports.checkStoredSession();
        final verdict = ok
            ? SessionVerdict.loggedIn(
                user: json == null ? null : User.fromJson(json),
                source: json == null
                    ? SessionVerdictSource.storedSession
                    : SessionVerdictSource.preload,
              )
            : const SessionVerdict.loggedOut();
        resolution.settled = verdict;
        _apply(verdict, epoch: epoch, startup: startup, reason: reason);
        completer.complete(verdict);
      } catch (e, s) {
        // 检查本身出错（极少见）：不留下坏结果，下次读取时重新判定
        if (identical(_resolution, resolution)) _resolution = null;
        completer.completeError(e, s);
      }
    }();
    return completer.future;
  }

  void _apply(
    SessionVerdict verdict, {
    required int epoch,
    required bool startup,
    required String reason,
  }) {
    // 判定期间登录态又变了：以新纪元的判定为准
    if (epoch != _epoch) return;
    _log('session verdict: $verdict reason=$reason');
    final user = verdict.user;
    if (user != null) _ports.publishUser(user);
    final wasActive = _postLoginActive;
    _session.value = verdict;
    if (verdict.loggedIn && !wasActive) {
      _postLoginActive = true;
      if (startup) _enter(StartupPhase.postLogin);
      _runPostLoginStarts(verdict, startup: startup, reason: reason);
    } else if (!verdict.loggedIn && wasActive) {
      _postLoginActive = false;
      for (final item in List.of(_postLoginStarts)) {
        _guard(item.name, item.stop);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 登录后启动项
  // ---------------------------------------------------------------------------

  /// 注册登录后启动项；已登录时立即启动。返回注销函数（注销时会先停止）。
  VoidCallback registerPostLogin(PostLoginStart item) {
    _postLoginStarts.add(item);
    final current = _session.value;
    if (_postLoginActive && current != null) {
      _guard(item.name, () => item.start(current));
    }
    return () {
      if (_postLoginStarts.remove(item)) _guard(item.name, item.stop);
    };
  }

  void _runPostLoginStarts(
    SessionVerdict verdict, {
    required bool startup,
    required String reason,
  }) {
    // 1. 启动期直连预加载拿到登录态：补一次浏览器会话同步。先于续期启动，
    //    续期会顺延到这次同步结束（与以前在预加载路径里的顺序一致）。
    if (startup &&
        verdict.source == SessionVerdictSource.preload &&
        _preloadPath == StartupPreloadPath.native) {
      _guard(
        'browser_trust_settle',
        () => _ports.settleAfterNativePreload(
          reason: '$reason:native_preload_settle',
        ),
      );
    }
    // 2. cf_clearance 续期
    _guard(
      'clearance_refresh',
      () => _ports.startClearanceRefresh(reason: 'current_user_ready'),
    );
    // 3. 注册的启动项（MessageBus 频道等）
    for (final item in List.of(_postLoginStarts)) {
      _guard(item.name, () => item.start(verdict));
    }
  }

  // ---------------------------------------------------------------------------
  // 回前台
  // ---------------------------------------------------------------------------

  /// 回前台只跑启动序列的子集：停后台保活 → 重载存储（iOS）→ WebView 对账 →
  /// 恢复前台轮询 → [afterSessionReady]（UI 刷新）→ 网络栈保活 → 浏览器信任
  /// 恢复（总会执行）。不重新接线、不 priming、不预加载、不重新判定会话。
  Future<void> resumeFromBackground({
    String reason = 'resume',
    FutureOr<void> Function()? afterSessionReady,
  }) async {
    try {
      await _ports.disableBackgroundKeepAlive();
      _ports.reloadStoresAfterBackground();
      // 后台期间 WebView（站内页 / 适配器）可能自己轮换过 _t：先对账，
      // 再恢复 message-bus 等原生请求，避免用落后的值去碰服务端
      await _ports.reconcileAfterBackground();
      _ports.exitBackgroundPolling();
      await afterSessionReady?.call();
      _ports.ensureNetworkAlive();
    } catch (e) {
      _log('resume from background failed: $e', warning: true);
    } finally {
      _ports.resumeBrowserTrust(reason: reason);
    }
  }

  // ---------------------------------------------------------------------------

  void _attachSessionHooks() {
    if (_hooksAttached) return;
    _hooksAttached = true;
    _enter(StartupPhase.sessionHooks);
    _ports.attachSessionHooks();
  }

  void _enter(StartupPhase phase) {
    final current = _phase.value;
    if (current != null && current.index >= phase.index) return;
    _phase.value = phase;
  }

  void _guard(String name, VoidCallback action) {
    try {
      action();
    } catch (e) {
      _log('post-login step $name failed: $e', warning: true);
    }
  }

  void _log(String message, {bool warning = false}) {
    if (warning) {
      AppLogger.warning(message, tag: 'AppStartup');
    } else {
      debugPrint('[AppStartup] $message');
    }
  }
}

class _Resolution {
  _Resolution(this.epoch, this.future);

  final int epoch;
  final Future<SessionVerdict> future;
  SessionVerdict? settled;
}
