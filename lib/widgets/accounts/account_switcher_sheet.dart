import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../pages/login_page.dart';
import '../../providers/app_state_refresher.dart';
import '../../providers/core_providers.dart';
import '../../services/accounts/account_store.dart';
import '../../services/accounts/account_switcher.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/url_helper.dart';
import '../common/loading_dialog.dart';
import '../common/smart_avatar.dart';

/// 本机保存的账号列表（含当前账号），点一下即切换。
final savedAccountsProvider = FutureProvider.autoDispose<List<SavedAccount>>(
  (ref) => AccountSwitcher.instance.store.list(),
);

/// 打开账号切换面板。打开时顺手把当前账号（及其最新凭据）存进列表。
Future<void> showAccountSwitcherSheet(BuildContext context) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const AccountSwitcherSheet(),
  );
}

class AccountSwitcherSheet extends ConsumerStatefulWidget {
  const AccountSwitcherSheet({super.key});

  @override
  ConsumerState<AccountSwitcherSheet> createState() =>
      _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends ConsumerState<AccountSwitcherSheet> {
  @override
  void initState() {
    super.initState();
    _saveCurrent();
  }

  Future<void> _saveCurrent() async {
    try {
      await AccountSwitcher.instance.saveCurrent();
    } on AccountLimitException catch (e) {
      ToastService.showInfo(S.current.accounts_limit(e.max));
    } catch (_) {
      ToastService.showError(S.current.accounts_unavailable);
    }
    if (mounted) ref.invalidate(savedAccountsProvider);
  }

  /// 关掉面板、回到首页再切：切换会清掉上一个账号的页面状态。
  /// 标了「要重新登录」的账号也先用存下的凭据试一次（以前切换时网络一抖
  /// 就会误标），服务端确实不认再打开登录页。
  Future<void> _switchTo(SavedAccount account) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.popUntil((route) => route.isFirst);
    final loading = LoadingDialog.show(
      navigator.context,
      message: S.current.accounts_switching(account.username),
    );
    AccountSwitchOutcome outcome;
    try {
      outcome = await AccountSwitcher.instance.switchTo(account, container);
    } catch (e) {
      debugPrint('[AccountSwitcher] 切换异常: $e');
      outcome = AccountSwitchOutcome.loggedOut;
    } finally {
      loading.hide();
    }
    AppStateRefresher.refreshAll(container);
    if (account.needsLogin &&
        (outcome == AccountSwitchOutcome.targetInvalidRestored ||
            outcome == AccountSwitchOutcome.targetNeedsLogin ||
            outcome == AccountSwitchOutcome.loggedOut)) {
      if (navigator.mounted) await _addAccount(container, navigator);
      return;
    }
    switch (outcome) {
      case AccountSwitchOutcome.switched:
        ToastService.showSuccess(S.current.accounts_switched(account.username));
      case AccountSwitchOutcome.switchedUnverified:
        ToastService.showInfo(
          S.current.accounts_switchedUnverified(account.username),
        );
      case AccountSwitchOutcome.targetInvalidRestored:
        ToastService.showError(
          S.current.accounts_targetInvalid(account.username),
        );
      case AccountSwitchOutcome.loggedOut:
        ToastService.showError(S.current.accounts_loggedOut);
      case AccountSwitchOutcome.targetNeedsLogin:
        ToastService.showError(S.current.accounts_needsLogin);
      case AccountSwitchOutcome.busy:
        ToastService.showInfo(S.current.accounts_busy);
    }
  }

  void _onAddAccount() {
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context, rootNavigator: true);
    _addAccount(container, navigator);
  }

  /// 面板可能已经关了：容器和导航器由调用方先取好
  static Future<void> _addAccount(
    ProviderContainer container,
    NavigatorState navigator,
  ) async {
    navigator.popUntil((route) => route.isFirst);
    SavedAccount? previous;
    try {
      previous = await AccountSwitcher.instance.beginAddAccount(container);
    } on AccountLimitException catch (e) {
      ToastService.showInfo(S.current.accounts_limit(e.max));
      return;
    }
    final loggedIn = await navigator.push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (!navigator.mounted) return;
    final loading = previous != null && loggedIn != true
        ? LoadingDialog.show(
            navigator.context,
            message: S.current.accounts_switching(previous.username),
          )
        : null;
    try {
      final ok = await AccountSwitcher.instance.finishAddAccount(
        previous,
        container,
        loggedIn: loggedIn == true,
      );
      if (!ok && previous != null) {
        ToastService.showError(S.current.accounts_loggedOut);
      }
    } finally {
      loading?.hide();
    }
    AppStateRefresher.refreshAll(container);
  }

  Future<void> _remove(SavedAccount account) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(S.current.accounts_removeConfirm(account.username)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.current.common_remove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AccountSwitcher.instance.remove(account);
    if (mounted) ref.invalidate(savedAccountsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentId = ref.watch(
      currentUserProvider.select((user) => user.value?.id),
    );
    final accounts = ref.watch(savedAccountsProvider).value ?? const [];
    final sorted = [
      ...accounts.where((a) => a.userId == currentId),
      ...accounts.where((a) => a.userId != currentId),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                S.current.accounts_switchAccount,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: Text(
                S.current.accounts_hint,
                style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
              ),
            ),
            for (final account in sorted)
              _AccountTile(
                account: account,
                isCurrent: account.userId == currentId,
                onTap: account.userId == currentId
                    ? null
                    : () => _switchTo(account),
                onRemove: account.userId == currentId
                    ? null
                    : () => _remove(account),
              ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colorScheme.surfaceContainerHighest,
                child: Icon(
                  Symbols.person_add_rounded,
                  color: colorScheme.primary,
                ),
              ),
              title: Text(S.current.accounts_addAccount),
              onTap: _onAddAccount,
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isCurrent,
    this.onTap,
    this.onRemove,
  });

  final SavedAccount account;
  final bool isCurrent;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final template = account.avatarTemplate;
    final name = account.name;
    return ListTile(
      onTap: onTap,
      leading: SmartAvatar(
        imageUrl: template == null
            ? null
            : UrlHelper.resolveUrlWithCdn(template.replaceAll('{size}', '96')),
        radius: 20,
        fallbackText: account.username,
      ),
      title: Text(account.username),
      subtitle: account.needsLogin
          ? Text(
              S.current.accounts_needsLogin,
              style: TextStyle(color: colorScheme.error),
            )
          : (name == null || name.isEmpty ? null : Text(name)),
      trailing: isCurrent
          ? Chip(
              label: Text(S.current.accounts_current),
              visualDensity: VisualDensity.compact,
            )
          : PopupMenuButton<VoidCallback>(
              icon: const Icon(Symbols.more_vert_rounded),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                if (account.needsLogin && onTap != null)
                  PopupMenuItem(
                    value: onTap!,
                    child: Text(S.current.accounts_relogin),
                  ),
                if (onRemove != null)
                  PopupMenuItem(
                    value: onRemove!,
                    child: Text(S.current.accounts_remove),
                  ),
              ],
            ),
    );
  }
}
