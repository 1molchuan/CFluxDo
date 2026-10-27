import 'dart:async';
import 'dart:io';

import '../../models/user.dart';
import '../background/background_notification_service.dart';
import '../browser_trust_coordinator.dart';
import '../connectivity_service.dart';
import '../discourse/discourse_service.dart';
import '../emoji_handler.dart';
import '../message_bus_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../network/doh/network_settings_service.dart';
import '../preloaded_data_service.dart';
import '../session/webview_use.dart';
import '../site_context.dart';
import '../startup_progress.dart';
import 'app_startup.dart';

/// [AppStartup] 的生产实现：只做转接，不持有状态。
class ProductionStartupPorts implements AppStartupPorts {
  BrowserTrustCoordinator get _browserTrust => BrowserTrustCoordinator.instance;

  @override
  bool get storesReady => CookieJarService().isInitialized;

  @override
  void attachSessionHooks() => DiscourseService.attachSessionTokenAuthority();

  @override
  Stream<void> get authStateChanges => DiscourseService().authStateStream;

  @override
  void prime({required String reason}) =>
      _browserTrust.prepareStartup(reason: reason);

  @override
  bool get isPreloaded => PreloadedDataService().isLoaded;

  @override
  Future<StartupPreloadPath?> preload({
    required String reason,
    required StartupPreloadProgress progress,
  }) async {
    await _browserTrust.ensurePreloaded(reason: reason, progress: progress);
    return switch (_browserTrust.lastPreloadPath) {
      BrowserTrustPreloadPath.native => StartupPreloadPath.native,
      BrowserTrustPreloadPath.webView => StartupPreloadPath.webView,
      null => null,
    };
  }

  @override
  void afterPreload() {
    DiscourseService().getEnabledReactions();
    EmojiHandler().init();
  }

  @override
  Map<String, dynamic>? get preloadedUserJson =>
      PreloadedDataService().currentUserSync;

  @override
  bool get validatePreloadedSession =>
      !SiteContext.current.supportsFingerprintBootstrap;

  @override
  Future<bool> checkStoredSession() => DiscourseService().isLoggedIn();

  @override
  void publishUser(User user) {
    DiscourseService().currentUserNotifier.value = user;
  }

  @override
  void settleAfterNativePreload({required String reason}) =>
      _browserTrust.settleAfterNativePreload(reason: reason);

  @override
  void startClearanceRefresh({required String reason}) =>
      _browserTrust.startClearanceRefresh(reason: reason);

  @override
  Future<void> disableBackgroundKeepAlive() =>
      BackgroundNotificationService().disable();

  @override
  void reloadStoresAfterBackground() {
    if (Platform.isIOS) {
      // iOS 后台轮询任务在独立 isolate 写 cookie 文件，回前台时重载
      // 磁盘值，避免主 isolate 用旧缓存覆盖后台轮换的 token
      CookieJarService().reloadPersistedCookies();
    }
  }

  @override
  Future<void> reconcileAfterBackground() =>
      WebViewUses.instance.reconcileAfterBackground();

  @override
  void exitBackgroundPolling() => MessageBusService().exitBackgroundMode();

  @override
  void ensureNetworkAlive() {
    // DOH 代理在后台期间失效则自动重启
    NetworkSettingsService.instance.ensureProxyAlive();
    // 主动检查连通性（等同 Discourse 的 visibilitychange）
    unawaited(ConnectivityService().check());
  }

  @override
  void resumeBrowserTrust({required String reason}) =>
      _browserTrust.resumeFromBackground(reason: reason);
}
