// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/discourse/discourse_service.dart';
import '../services/preloaded_data_service.dart';
import '../services/startup/app_startup.dart';
import '../services/site_context.dart';

/// Discourse 服务 Provider
final discourseServiceProvider = Provider((ref) => DiscourseService());

/// 认证错误 Provider（监听登录失效事件）
final authErrorProvider = StreamProvider<String>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authErrorStream;
});

/// 认证状态变化 Provider（登录/退出）
final authStateProvider = StreamProvider<void>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authStateStream;
});

/// 启动序列：全 App 唯一的「是否已登录」来源（测试可覆盖）。
final appStartupProvider = Provider<AppStartup>((ref) => AppStartup.instance);

/// 当前用户 Provider
///
/// 是否已登录只读启动序列的会话判定（[AppStartup.verdictNow] /
/// [AppStartup.verdict]，含启动恢复链），这里只负责用户资料：判定里带着
/// 预加载的当前用户时同步返回（避免启动时短暂显示未登录），否则缓存先行、
/// 再拉接口。
class CurrentUserNotifier extends AsyncNotifier<User?> {
  static String get _cacheKey => SiteContext.storageKey('current_user_cache');
  static String get _cacheUserKey => SiteContext.storageKey('current_user_cache_username');
  static const Duration _refreshCooldown = Duration(minutes: 2);
  DateTime? _lastRefreshTime;

  @override
  FutureOr<User?> build() {
    final startup = ref.read(appStartupProvider);
    final verdictUser = startup.verdictNow?.user;
    if (verdictUser != null) {
      _refreshUser(verdictUser);
      return verdictUser;
    }
    return _loadUserWithCache(startup);
  }

  Future<User?> _loadUserWithCache(AppStartup startup) async {
    // 先把上次会话的缓存亮出来(毫秒级,登出时缓存会被清,存在即上次已
    // 登录):会话判定可能还在进行(预加载是匿名的,要走含服务端校验的本地
    // 会话检查),getCurrentUser 又是全量接口,若等它们串行完成才给首值,
    // 头像/发帖入口要白等数秒。
    // 渐进 emit:缓存 → preloaded → 接口终态。
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    User? cachedUser;
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        cachedUser = User.fromCacheJson(json);
        state = AsyncValue.data(cachedUser);
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    final verdict = await startup.verdict();
    if (!verdict.loggedIn) {
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheUserKey);
      return null;
    }
    final verdictUser = verdict.user;
    if (verdictUser != null) {
      _refreshUser(verdictUser);
      return verdictUser;
    }

    final service = ref.read(discourseServiceProvider);
    try {
      final preloadedUser = await service.getPreloadedCurrentUser();
      if (preloadedUser != null) {
        state = AsyncValue.data(preloadedUser);
      }
      final user = await service.getCurrentUser();
      final resolved = user == null
          ? preloadedUser
          : (preloadedUser == null ? user : _mergeUser(user, preloadedUser));
      if (resolved != null) {
        _saveCache(prefs, resolved);
        return resolved;
      }
      // 网络返回 null 但本地有缓存时，保守处理：保留缓存返回，
      // 避免短暂鉴权抖动把 UI 误判成已登出。
      // 只有会话判定为未登录时才清理缓存。
      if (cachedUser != null) return cachedUser;
      return null;
    } catch (e) {
      // 网络失败，返回缓存
      if (cachedUser != null) return cachedUser;
      rethrow;
    }
  }

  Future<User?> _loadUser(DiscourseService service) async {
    final preloadedUser = await service.getPreloadedCurrentUser();
    final user = await service.getCurrentUser();
    if (user == null) return preloadedUser;
    if (preloadedUser == null) return user;
    return _mergeUser(user, preloadedUser);
  }

  /// 静默刷新，带冷却时间（默认 2 分钟内不重复请求）
  /// 不提前 emit 中间状态，只在拿到结果后更新一次，避免多余 rebuild
  Future<void> refreshSilently({bool force = false}) async {
    if (!force &&
        _lastRefreshTime != null &&
        DateTime.now().difference(_lastRefreshTime!) < _refreshCooldown) {
      return;
    }
    final service = ref.read(discourseServiceProvider);
    final previous = state.value;
    try {
      final user = await _loadUser(service);
      _lastRefreshTime = DateTime.now();
      if (user != null) {
        final prefs = await SharedPreferences.getInstance();
        _saveCache(prefs, user);
      }
      state = AsyncValue.data(user ?? previous);
    } catch (e, st) {
      // 刷新失败，保留旧数据并标记错误状态（用于离线提示）
      if (previous != null) {
        state = AsyncValue<User?>.error(
          e,
          st,
        ).copyWithPrevious(AsyncValue.data(previous));
      }
    }
  }

  void _refreshUser(User preloadedUser) {
    Future(() async {
      try {
        final service = ref.read(discourseServiceProvider);
        final user = await service.getCurrentUser();
        if (user == null) return;
        final merged = _mergeUser(user, preloadedUser);
        final prefs = await SharedPreferences.getInstance();
        _saveCache(prefs, merged);
        state = AsyncValue.data(merged);
      } catch (_) {
        // 后台刷新失败时静默忽略，refreshSilently 会负责设置错误状态
      }
    });
  }

  User _mergeUser(User user, User preloadedUser) {
    return user.copyWith(
      unreadNotifications: preloadedUser.unreadNotifications,
      unreadHighPriorityNotifications:
          preloadedUser.unreadHighPriorityNotifications,
      allUnreadNotificationsCount: preloadedUser.allUnreadNotificationsCount,
      seenNotificationId: preloadedUser.seenNotificationId,
      notificationChannelPosition: preloadedUser.notificationChannelPosition,
      // can_assign 只在 CurrentUserSerializer(预加载/会话数据)里有,
      // /u/username.json 这条公开资料接口不带,live fetch 那份永远是
      // 默认值 false——用预加载兜底,否则第二次刷新就把权限位冲没了。
      canAssign: user.canAssign || preloadedUser.canAssign,
    );
  }

  void _saveCache(SharedPreferences prefs, User user) {
    prefs.setString(_cacheKey, jsonEncode(user.toCacheJson()));
    prefs.setString(_cacheUserKey, user.username);
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheUserKey);
  }
}

final currentUserProvider = AsyncNotifierProvider<CurrentUserNotifier, User?>(
  CurrentUserNotifier.new,
);

/// 系统用户头像模板 Provider
/// 用于通知列表中没有 acting_user 时的默认头像
final systemUserAvatarTemplateProvider = FutureProvider<String?>((ref) async {
  return PreloadedDataService().getSystemUserAvatarTemplate();
});

/// 用户统计数据 Provider
class UserSummaryNotifier extends AsyncNotifier<UserSummary?> {
  static String get _cacheKey => SiteContext.storageKey('user_summary_cache');
  static String get _cacheUserKey => SiteContext.storageKey('user_summary_cache_username');

  @override
  Future<UserSummary?> build() async {
    final service = ref.watch(discourseServiceProvider);
    final currentUsername = ref.watch(
      currentUserProvider.select((value) => value.value?.username),
    );
    final username =
        currentUsername ??
        (await ref.watch(currentUserProvider.future))?.username;
    if (username == null) return null;

    // 先尝试从 SP 读取缓存
    final prefs = await SharedPreferences.getInstance();
    final cachedUser = prefs.getString(_cacheUserKey);
    // 切换账号时清除旧缓存
    if (cachedUser != null && cachedUser != username) {
      await _clearCache(prefs);
    }

    final cached = prefs.getString(_cacheKey);
    UserSummary? cachedSummary;
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        cachedSummary = UserSummary.fromCacheJson(json);
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    try {
      final summary = await service.getUserSummary(username);
      _saveCache(prefs, summary, username);
      return summary;
    } catch (e) {
      if (cachedSummary != null) return cachedSummary;
      rethrow;
    }
  }

  Future<void> refresh() async {
    final previous = state.value;
    try {
      final service = ref.read(discourseServiceProvider);
      final user = ref.read(currentUserProvider).value;
      if (user == null) return;

      final summary = await service.getUserSummary(
        user.username,
        forceRefresh: true,
      );
      final prefs = await SharedPreferences.getInstance();
      _saveCache(prefs, summary, user.username);
      state = AsyncValue.data(summary);
    } catch (e, st) {
      // 刷新失败，保留旧数据并标记错误状态
      if (previous != null) {
        state = AsyncValue<UserSummary?>.error(
          e,
          st,
        ).copyWithPrevious(AsyncValue.data(previous));
      }
    }
  }

  void _saveCache(
    SharedPreferences prefs,
    UserSummary summary,
    String username,
  ) {
    prefs.setString(_cacheKey, jsonEncode(summary.toCacheJson()));
    prefs.setString(_cacheUserKey, username);
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await _clearCache(prefs);
  }

  Future<void> _clearCache(SharedPreferences prefs) async {
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheUserKey);
  }
}

final userSummaryProvider =
    AsyncNotifierProvider<UserSummaryNotifier, UserSummary?>(
      UserSummaryNotifier.new,
    );
