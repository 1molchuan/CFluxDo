import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ld_store/ld_store_models.dart';
import '../services/ld_store/ld_store_service.dart';
import '../services/ld_store/ld_store_shop_models.dart';
import '../services/ld_store/ld_store_shop_service.dart';
import '../services/site_context.dart';
import 'core_providers.dart';

final ldStoreServiceProvider = Provider((ref) => LdStoreService());

/// 商城浏览 / 下单 / 订单接口。
final ldShopServiceProvider = Provider((ref) => LdShopService());

/// 商品分类（公开，不需要授权）。
final ldShopCategoriesProvider =
    FutureProvider.autoDispose<List<LdShopCategory>>((ref) {
      return ref.read(ldShopServiceProvider).fetchCategories();
    });

/// 商城公开统计（在售、今日成交、小店数），不需要授权。
final ldStoreStatsProvider = FutureProvider.autoDispose<LdStoreStats?>((
  ref,
) async {
  if (!SiteContext.isLinuxDo) return null;
  return ref.read(ldStoreServiceProvider).fetchStats();
});

/// 已授权的商城会话。[account] 为 null 表示这次没读到（[loadError]），
/// 凭据仍在，入口照常带登录态打开。
class LdStoreSession {
  const LdStoreSession({required this.token, this.account, this.loadError});

  final LdStoreToken token;
  final LdStoreAccount? account;
  final Object? loadError;
}

/// null = 未授权；error 为 [LdStoreAuthExpiredException] = 授权已失效。
final ldStoreSessionProvider =
    AsyncNotifierProvider<LdStoreSessionNotifier, LdStoreSession?>(
      LdStoreSessionNotifier.new,
    );

class LdStoreSessionNotifier extends AsyncNotifier<LdStoreSession?> {
  /// 上一次成功读到的数字（只对同一枚凭据有效），网络失败时接着显示。
  ({String token, LdStoreAccount account})? _lastAccount;

  @override
  Future<LdStoreSession?> build() async {
    if (!SiteContext.isLinuxDo) return null;
    final currentUsername = ref.watch(
      currentUserProvider.select((value) => value.value?.username),
    );
    final username =
        currentUsername ??
        (await ref.watch(currentUserProvider.future))?.username;
    if (username == null) return null;

    final service = ref.read(ldStoreServiceProvider);
    final token = await service.loadToken(username);
    if (token == null) return null;
    try {
      final account = await service.fetchAccount(token);
      _lastAccount = (token: token.value, account: account);
      return LdStoreSession(token: token, account: account);
    } on LdStoreAuthExpiredException {
      _lastAccount = null;
      await service.discardToken(username);
      rethrow;
    } catch (e) {
      final last = _lastAccount;
      return LdStoreSession(
        token: token,
        account: last?.token == token.value ? last?.account : null,
        loadError: e,
      );
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {}
  }

  /// 授权成功（凭据已存好）后重新读取。
  Future<void> adopt() => refresh();

  /// 当前可用的凭据（未授权、已失效或还没读出来时为 null）。
  ///
  /// 正在读取时会等它读完，不会因为页面刚打开就当成未授权。
  Future<LdStoreToken?> currentToken() async {
    try {
      final token = (await future)?.token;
      return token == null || token.isExpired() ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// 商城接口说凭据无效（401 / 认证错误码）：丢掉凭据，入口卡显示「授权已过期」。
  Future<void> markExpired() async {
    _lastAccount = null;
    final username = ref.read(currentUserProvider).value?.username;
    if (username != null) {
      await ref.read(ldStoreServiceProvider).discardToken(username);
    }
    state = AsyncError(const LdStoreAuthExpiredException(), StackTrace.current);
  }

  Future<void> signOut() async {
    final username = ref.read(currentUserProvider).value?.username;
    await ref.read(ldStoreServiceProvider).signOut(username: username);
    await refresh();
  }
}
