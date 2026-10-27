import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ld_store/ld_store_models.dart';
import '../services/ld_store/ld_store_service.dart';
import '../services/site_context.dart';
import 'core_providers.dart';

final ldStoreServiceProvider = Provider((ref) => LdStoreService());

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

  Future<void> signOut() async {
    final username = ref.read(currentUserProvider).value?.username;
    await ref.read(ldStoreServiceProvider).signOut(username: username);
    await refresh();
  }
}
