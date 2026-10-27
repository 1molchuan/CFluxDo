import 'dart:async';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../models/user.dart';
import '../../providers/app_state_refresher.dart';
import '../auth_session.dart';
import '../discourse/discourse_service.dart';
import '../cf_challenge_service.dart';
import '../../providers/ld_store_providers.dart';
import '../log/log_writer.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../network/cookie/session_cookie_sentinel.dart';
import '../network/cookie/webview_cookie_priming.dart';
import '../network/cookie/webview_cookie_push.dart';
import '../preloaded_data_service.dart';
import '../session/session_token_authority.dart';
import '../site_context.dart';
import '../site_data_lifecycle.dart';
import '../user_api_key_service.dart';
import 'account_store.dart';

enum AccountSwitchOutcome {
  /// 已切到目标账号
  switched,

  /// 目标账号登录已失效（已标记要重新登录），回到了原来的账号
  targetInvalidRestored,

  /// 目标账号失效，原账号也没能恢复：现在是未登录
  loggedOut,

  /// 目标账号没有可用的凭据（已标记要重新登录），没有动
  targetNeedsLogin,

  /// 正在切换 / 正在人机验证，没有动
  busy,
}

/// 多账号切换。
///
/// 切换 = 本地退出当前账号（不调服务端登出，它的会话照样有效）+ 用目标账号
/// 存下的 cookie「登录」：
/// 1. 先给当前账号拍快照（对账后的最新 `_t` 等账号 cookie，见
///    [CookieJarService.accountCookieNames]）存进 [AccountStore]；
/// 2. 走本地登出（会话代推进、在途请求作废、MessageBus 停、jar / WebView 的
///    登录 cookie 清掉，cf_clearance 保留并推回 WebView），清掉上一个账号的
///    界面状态；
/// 3. 把目标账号的 cookie 写进 jar 与 WebView，按登录收口的同一条路采纳
///    `_t`，重新拉首页预加载数据，**确认服务端认的确实是目标账号**才广播
///    登录成功；不认（登录过期 / 在别处退出）就标记要重新登录、按同样步骤
///    切回原账号。
///
/// 全程不碰 cf_clearance（设备 / 出口级），也不调任何登出 API。
class AccountSwitcher {
  AccountSwitcher._();

  static final AccountSwitcher instance = AccountSwitcher._();

  final AccountStore store = AccountStore();
  bool _busy = false;

  bool get isBusy => _busy;

  static const _preloadTimeout = Duration(seconds: 15);

  DiscourseService get _service => DiscourseService();
  CookieJarService get _jar => CookieJarService();

  /// 把当前登录的账号（及其最新凭据）存进本机账号列表；没登录返回 null。
  /// 列表已满且当前账号不在其中时抛 [AccountLimitException]。
  Future<SavedAccount?> saveCurrent() async {
    final user = _service.currentUserNotifier.value;
    if (user == null) return null;
    try {
      await SessionTokenAuthority.instance.reconcile(
        reason: 'account_snapshot',
      );
    } catch (e) {
      debugPrint('[AccountSwitcher] 快照前对账失败（继续用 jar 里的值）: $e');
    }
    final cookies = await _jar.exportAccountCookies();
    if (!cookies.any((cookie) => cookie.name == '_t')) return null;
    final account = SavedAccount(
      userId: user.id,
      username: user.username,
      name: user.name,
      avatarTemplate: user.avatarTemplate,
      savedAt: DateTime.now(),
    );
    await store.save(account, cookies);
    return account;
  }

  /// 切到 [target]。[container] 用来清上一个账号的界面状态。
  Future<AccountSwitchOutcome> switchTo(
    SavedAccount target,
    ProviderContainer container,
  ) async {
    // 验证页开着时别动 cookie：验证轮次正在等新的 cf_clearance 落进来
    if (_busy || CfChallengeService().isVerifying) {
      return AccountSwitchOutcome.busy;
    }
    _busy = true;
    try {
      final targetCookies = await store.cookiesOf(target);
      if (targetCookies == null ||
          !targetCookies.any((cookie) => cookie.name == '_t')) {
        await store.markNeedsLogin(target.userId, needsLogin: true);
        return AccountSwitchOutcome.targetNeedsLogin;
      }
      await SiteDataLifecycle.flushBeforeSwitch();
      final previous = await saveCurrent();
      final previousCookies = previous == null
          ? null
          : await store.cookiesOf(previous);
      _log('account_switch_begin', target: target, previous: previous);

      await _detach(container, previous: previous);
      if (await _attach(target, targetCookies)) {
        await store.markNeedsLogin(target.userId, needsLogin: false);
        _log('account_switch_done', target: target, previous: previous);
        return AccountSwitchOutcome.switched;
      }

      await store.markNeedsLogin(target.userId, needsLogin: true);
      _log('account_switch_target_invalid', target: target, previous: previous);
      await _detach(container);
      if (previous != null &&
          previousCookies != null &&
          await _attach(previous, previousCookies)) {
        return AccountSwitchOutcome.targetInvalidRestored;
      }
      _log('account_switch_restore_failed', target: target, previous: previous);
      return AccountSwitchOutcome.loggedOut;
    } finally {
      _busy = false;
    }
  }

  /// 添加账号第一步：把当前账号存好、本地退出，好打开登录页登另一个号。
  /// 返回原账号（未登录时为 null），登录页关掉后交给 [finishAddAccount]。
  Future<SavedAccount?> beginAddAccount(ProviderContainer container) async {
    if (_busy) throw StateError('account switch in progress');
    _busy = true;
    try {
      final current = _service.currentUserNotifier.value;
      if (current != null) {
        final accounts = await store.list();
        if (accounts.length >= AccountStore.maxAccounts &&
            !accounts.any((a) => a.userId == current.id)) {
          throw const AccountLimitException(AccountStore.maxAccounts);
        }
      }
      await SiteDataLifecycle.flushBeforeSwitch();
      final previous = await saveCurrent();
      if (previous != null) await _detach(container, previous: previous);
      return previous;
    } finally {
      _busy = false;
    }
  }

  /// 添加账号收尾：登录成功就把新账号存进列表；没登录（取消 / 失败）就切回
  /// 原账号 [previous]。返回最后是否处于登录态。
  Future<bool> finishAddAccount(
    SavedAccount? previous,
    ProviderContainer container, {
    required bool loggedIn,
  }) async {
    if (loggedIn && await _waitForCurrentUser() != null) {
      try {
        await saveCurrent();
      } on AccountLimitException {
        // 原账号已在列表里时上限在 begin 已查过；这里只可能是新账号挤不下
      }
      return true;
    }
    if (previous == null) return false;
    final cookies = await store.cookiesOf(previous);
    if (cookies == null) return false;
    _busy = true;
    try {
      // 登录页里可能留下了半截会话：先按切换的方式清一遍
      await _detach(container);
      return await _attach(previous, cookies);
    } finally {
      _busy = false;
    }
  }

  /// 登录页关掉时当前用户可能还在启动流程里没发布出来：最多等几秒
  Future<User?> _waitForCurrentUser() async {
    final notifier = _service.currentUserNotifier;
    if (notifier.value != null) return notifier.value;
    final completer = Completer<User?>();
    void listener() {
      if (notifier.value != null && !completer.isCompleted) {
        completer.complete(notifier.value);
      }
    }

    notifier.addListener(listener);
    try {
      return await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => notifier.value,
      );
    } finally {
      notifier.removeListener(listener);
    }
  }

  /// 从本机移除一个已保存的账号（不在服务端退出它）
  Future<void> remove(SavedAccount account) => store.remove(account.userId);

  /// 本地退出当前账号，清掉它在界面、缓存与 cookie 里的痕迹，cf_clearance 留着。
  Future<void> _detach(
    ProviderContainer container, {
    SavedAccount? previous,
  }) async {
    if (previous != null && SiteContext.isLinuxDo) {
      try {
        await container
            .read(ldStoreServiceProvider)
            .revokeWebSessionFor(previous.username);
      } catch (_) {}
    }
    await SessionCookieSentinel.instance.cancelAllSweeps();
    await _service.logout(callApi: false, refreshPreload: false);
    // 自愈凭据只认存它的那个账号，别让下一个账号失效时被它「救」回上一个人
    await UserApiKeyService().clearKey();
    // 登出只清主站域，子域上的账号 cookie（connect / LDC / CDK 会话）在这里清
    await _jar.replaceAccountCookies(const []);
    await _clearWebViewAccountCookies();
    WebViewCookiePriming.instance.invalidate();
    // 登出会把 WebView 里的 cf_clearance 一起删掉，jar 里的推回去（不然
    // 下一个账号一打开网页就撞盾）
    await WebViewCookiePush.instance.push(
      name: 'cf_clearance',
      reason: 'account_switch',
    );
    AppStateRefresher.resetForAccountSwitch(container);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  /// 用 [cookies] 登录 [account]，服务端确认是这个账号才广播登录成功。
  Future<bool> _attach(
    SavedAccount account,
    List<CanonicalCookie> cookies,
  ) async {
    await _jar.replaceAccountCookies(cookies);
    for (final cookie in cookies) {
      await WebViewCookiePush.instance.push(
        name: cookie.name,
        reason: 'account_switch',
        url: _urlFor(cookie),
        rawSetCookie: cookie.toSetCookieHeader(),
        expectedValue: cookie.value,
        clearVariantsFirst: true,
      );
    }
    final generation = AuthSession().advance();
    final adopted = await SessionTokenAuthority.instance.adoptLoginToken(
      reason: 'account_switch',
      generation: generation,
    );
    final token = await _jar.getTToken() ?? '';
    if (token.isEmpty) return false;
    if (!adopted) {
      // WebView 没写进去时 jar 里的值仍可用，对账会再推一次
      SessionTokenAuthority.instance
        ..resetLineage()
        ..markAgreed(token);
    }

    await _service.saveUsername(account.username);
    _service.setToken(token);
    PreloadedDataService().reset();
    try {
      // 本地登出的广播会让启动流程按游客身份拉一次首页：等它落地再按新身份拉
      await PreloadedDataService().reloadAfterPending().timeout(
        _preloadTimeout,
      );
    } catch (e) {
      debugPrint('[AccountSwitcher] 预加载失败: $e');
    }
    final user = PreloadedDataService().currentUserSync;
    final userId = (user?['id'] as num?)?.toInt();
    if (userId != account.userId) {
      _log(
        'account_switch_verify_failed',
        target: account,
        extra: {'preloadedUser': user == null ? 'none' : 'other'},
      );
      return false;
    }
    _service.currentUserNotifier.value = User.fromJson(user!);
    _service.onLoginSuccess(token, forceBrowserSessionSync: true);
    return true;
  }

  Future<void> _clearWebViewAccountCookies() async {
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final hosts = {
      baseHost,
      for (final sub in const ['connect', 'credit', 'cdk']) '$sub.$baseHost',
    };
    for (final name in CookieJarService.accountCookieNames) {
      await _jar.deleteWebViewCookieOnHosts(name, hosts);
    }
  }

  static String _urlFor(CanonicalCookie cookie) {
    final domain = cookie.domain ?? Uri.tryParse(cookie.originUrl ?? '')?.host;
    final host = (domain ?? Uri.parse(AppConstants.baseUrl).host).replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    return 'https://$host';
  }

  void _log(
    String event, {
    required SavedAccount target,
    SavedAccount? previous,
    Map<String, Object?> extra = const {},
  }) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': event.endsWith('failed') || event.endsWith('invalid')
          ? 'warning'
          : 'info',
      'type': 'auth',
      'event': event,
      'message': '多账号切换: $event',
      'targetUserId': target.userId,
      'previousUserId': previous?.userId,
      ...extra,
    });
  }
}
