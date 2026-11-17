import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../pages/ld_store/ld_store_common.dart';
import '../pages/ld_store/ld_store_coupons_page.dart';
import '../pages/ld_store/ld_store_home_page.dart';
import '../pages/ld_store/ld_store_orders_page.dart';
import '../providers/core_providers.dart';
import '../providers/ld_store_providers.dart';
import '../services/ld_store/ld_store_models.dart';
import '../services/ld_store/ld_store_service.dart';
import '../services/site_context.dart';
import '../theme/mojian_theme.dart';
import '../utils/dialog_utils.dart';
import 'common/mojian_ledger_card.dart';

/// 元宇宙页的 LD士多（ldcstore.com，第三方积分商城）卡片。
///
/// 未授权：一句介绍 + 公开统计，「进入商城」「授权登录」；
/// 已授权：待付款 / 待收货 / 未读消息 / 可用券，点哪项进对应页面。
/// 商城浏览、下单、订单、优惠券都是原生页（`lib/pages/ld_store/`）；未读消息
/// 与「在浏览器中打开」仍走内置浏览器里的商城网页（带上 App 的登录态）。
class LdStoreCard extends ConsumerStatefulWidget {
  const LdStoreCard({super.key});

  static const title = 'LD士多';

  @override
  ConsumerState<LdStoreCard> createState() => _LdStoreCardState();
}

class _LdStoreCardState extends ConsumerState<LdStoreCard> {
  bool _processing = false;

  Future<void> _openStore() async {
    await LdStoreHomePage.open(context);
    // 在商城里下了单 / 付了款：待办数字跟上
    if (mounted && ref.read(ldStoreSessionProvider).value != null) {
      await ref.read(ldStoreSessionProvider.notifier).refresh();
    }
  }

  Future<void> _openOrders(LdShopOrderTab tab) async {
    await LdStoreOrdersPage.open(context, tab: tab);
    // 回来时订单可能变了
    if (mounted) await ref.read(ldStoreSessionProvider.notifier).refresh();
  }

  Future<void> _openCoupons() async {
    await LdStoreCouponsPage.open(context);
    if (mounted) await ref.read(ldStoreSessionProvider.notifier).refresh();
  }

  /// 系统消息原生页没做，进商城网页的消息中心
  Future<void> _openMessages() =>
      openLdStoreInBrowser(context, '/user/messages');

  Future<void> _authorize() async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await authorizeLdStore(context);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _signOut() async {
    if (_processing) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.ldStore_signOut),
        content: Text(context.l10n.ldStore_signOutMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.ldStore_signOut),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _processing = true);
    try {
      await ref.read(ldStoreSessionProvider.notifier).signOut();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SiteContext.isLinuxDo) return const SizedBox.shrink();
    final session = ref.watch(ldStoreSessionProvider);
    final stats = ref.watch(ldStoreStatsProvider).value;
    final loggedIn = ref.watch(
      currentUserProvider.select((value) => value.value != null),
    );
    final expired = session.error is LdStoreAuthExpiredException;
    final view = _LdStoreView(
      // 过期时 AsyncError 里可能还挂着上一次的会话，不能再当已授权显示
      session: expired ? null : session.value,
      expired: expired,
      failed: session.hasError && !expired && session.value == null,
      busy: _processing || session.isLoading,
      stats: stats,
      canAuthorize: loggedIn && !_processing,
    );
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    return mj != null
        ? _buildMojian(theme, mj, view)
        : _buildClassic(theme, view);
  }

  // ---------------------------------------------------------------------------
  // 经典
  // ---------------------------------------------------------------------------

  Widget _buildClassic(ThemeData theme, _LdStoreView view) {
    final colorScheme = theme.colorScheme;
    final session = view.session;
    return Card(
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: view.expired
            ? BorderSide(color: colorScheme.error.withValues(alpha: 0.5))
            : BorderSide.none,
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openStore,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Symbols.local_mall_rounded,
                      size: 26,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          LdStoreCard.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          session != null
                              ? '@${session.token.username}'
                              : context.l10n.ldStore_desc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (view.busy)
                    const LoadingSpinner(size: 20)
                  else if (session != null)
                    IconButton(
                      onPressed: _signOut,
                      tooltip: context.l10n.ldStore_signOut,
                      icon: Icon(
                        Symbols.power_settings_new_rounded,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              ..._body(
                theme,
                view,
                figure: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                label: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                note: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                error: colorScheme.error,
              ),
              const SizedBox(height: 16),
              _actions(view),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 墨笺
  // ---------------------------------------------------------------------------

  Widget _buildMojian(ThemeData theme, MojianTokens mj, _LdStoreView view) {
    return MojianLedgerCard(
      icon: view.expired
          ? Symbols.lock_clock_rounded
          : Symbols.local_mall_rounded,
      title: LdStoreCard.title,
      danger: view.expired,
      onTap: _openStore,
      trailing: view.busy
          ? MojianLedgerCard.spinner(mj)
          : view.session != null
          ? MojianLedgerCard.powerButton(mj, _signOut)
          : null,
      children: [
        if (view.session != null) ...[
          Text(
            '@${view.session!.token.username}',
            style: theme.textTheme.bodyMedium?.copyWith(color: mj.ink2),
          ),
          const SizedBox(height: 10),
        ] else ...[
          Text(
            context.l10n.ldStore_desc,
            style: theme.textTheme.bodyMedium?.copyWith(color: mj.ink3),
          ),
          const SizedBox(height: 6),
        ],
        ..._body(
          theme,
          view,
          figure: MojianLedgerCard.figureStyle(mj).copyWith(fontSize: 24),
          label: theme.textTheme.bodySmall?.copyWith(color: mj.ink3),
          note: theme.textTheme.bodyMedium?.copyWith(color: mj.ink3),
          error: theme.colorScheme.error,
        ),
        const SizedBox(height: 14),
        _actions(view, mojian: true),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 共用
  // ---------------------------------------------------------------------------

  List<Widget> _body(
    ThemeData theme,
    _LdStoreView view, {
    required TextStyle? figure,
    required TextStyle? label,
    required TextStyle? note,
    required Color error,
  }) {
    final session = view.session;
    if (view.expired) {
      return [
        Text(
          context.l10n.ldStore_authExpired,
          style: note?.copyWith(color: error),
        ),
      ];
    }
    final account = session?.account;
    if (account != null) {
      final a = account.attention;
      return [
        Row(
          children: [
            _counter(
              a.pendingPayment,
              context.l10n.ldStore_pendingPayment,
              () => _openOrders(LdShopOrderTab.pending),
              figure,
              label,
            ),
            _counter(
              a.awaitingDelivery,
              context.l10n.ldStore_awaitingDelivery,
              () => _openOrders(LdShopOrderTab.paid),
              figure,
              label,
            ),
            _counter(
              account.unreadMessages,
              context.l10n.ldStore_unread,
              _openMessages,
              figure,
              label,
            ),
            _counter(
              a.unusedCoupons,
              context.l10n.ldStore_coupons,
              _openCoupons,
              figure,
              label,
            ),
          ],
        ),
      ];
    }
    if (session != null || view.failed) {
      // 已授权但这次没读到，或读凭据本身失败
      return [Text(context.l10n.common_loadFailed, style: note)];
    }
    final stats = view.stats;
    if (stats == null) return const [];
    return [
      Text(
        context.l10n.ldStore_stats(
          stats.onlineProducts,
          stats.ordersToday,
          stats.stores,
        ),
        style: label,
      ),
    ];
  }

  Widget _counter(
    int value,
    String text,
    VoidCallback onTap,
    TextStyle? figure,
    TextStyle? label,
  ) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text('$value', style: figure),
              const SizedBox(height: 2),
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions(_LdStoreView view, {bool mojian = false}) {
    final session = view.session;
    final needsAuthorize = session == null;
    final open = needsAuthorize
        ? OutlinedButton(
            onPressed: _openStore,
            child: Text(context.l10n.ldStore_open),
          )
        : (mojian
              ? OutlinedButton(
                  onPressed: _openStore,
                  child: Text(context.l10n.ldStore_open),
                )
              : FilledButton.tonal(
                  onPressed: _openStore,
                  child: Text(context.l10n.ldStore_open),
                ));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if ((session != null && session.account == null) || view.failed)
          TextButton(
            onPressed: view.busy
                ? null
                : () => ref.read(ldStoreSessionProvider.notifier).refresh(),
            child: Text(context.l10n.common_retry),
          ),
        open,
        if (needsAuthorize)
          FilledButton(
            onPressed: view.canAuthorize ? _authorize : null,
            child: Text(
              view.expired
                  ? context.l10n.common_reAuth
                  : context.l10n.ldStore_authorize,
            ),
          ),
        // 兜底：原生页没覆盖的（求购、评论、卖家后台）进商城网页
        PopupMenuButton<void>(
          tooltip: context.l10n.common_more,
          icon: const Icon(Symbols.more_horiz_rounded),
          itemBuilder: (context) => [
            PopupMenuItem<void>(
              onTap: () => openLdStoreInBrowser(this.context),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.open_in_browser_rounded),
                title: Text(context.l10n.ldShop_openInBrowser),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LdStoreView {
  const _LdStoreView({
    required this.session,
    required this.expired,
    required this.failed,
    required this.busy,
    required this.stats,
    required this.canAuthorize,
  });

  final LdStoreSession? session;
  final bool expired;
  final bool failed;
  final bool busy;
  final LdStoreStats? stats;
  final bool canAuthorize;
}
