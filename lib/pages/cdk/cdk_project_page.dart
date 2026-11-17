import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/cdk_project.dart';
import '../../models/cdk_user_info.dart';
import '../../providers/cdk_providers.dart';
import '../../services/app_logger.dart';
import '../../services/cdk_api_service.dart';
import '../../services/network/exceptions/oauth_exception.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/time_utils.dart';
import '../../widgets/cdk/hcaptcha_sheet.dart';
import '../../widgets/common/error_view.dart';
import '../webview_page.dart';
import 'cdk_widgets.dart';

/// CDK 分发项目（帖子里的 `cdk.linux.do/receive/<id>` 链接）的原生领取页。
///
/// 领取只多一步 hCaptcha 验证层（[HCaptchaSheet]），其余都是原生接口。付费项目的
/// 付款页在 credit.linux.do，用内置浏览器打开，回来后重新读项目确认是否到账。
class CdkProjectPage extends StatelessWidget {
  const CdkProjectPage({super.key, required this.projectId});

  final String projectId;

  static String receiveUrl(String projectId) =>
      'https://cdk.linux.do/receive/${Uri.encodeComponent(projectId)}';

  static Future<void> open(BuildContext context, String projectId) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CdkProjectPage(projectId: projectId)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.current.cdkPage_projectTitle),
        actions: [
          IconButton(
            tooltip: S.current.cdkPage_openInBrowser,
            icon: const Icon(Symbols.open_in_browser_rounded),
            onPressed: () => WebViewPage.open(
              context,
              receiveUrl(projectId),
              title: 'LINUX DO CDK',
            ),
          ),
        ],
      ),
      body: CdkSessionGate(
        builder: (context, user) =>
            _ProjectView(projectId: projectId, user: user),
      ),
    );
  }
}

class _ProjectView extends ConsumerStatefulWidget {
  const _ProjectView({required this.projectId, required this.user});

  final String projectId;
  final CdkUserInfo user;

  @override
  ConsumerState<_ProjectView> createState() => _ProjectViewState();
}

class _ProjectViewState extends ConsumerState<_ProjectView> {
  CdkProject? _project;
  CdkPendingPayment? _pending;
  Object? _error;
  StackTrace? _errorStack;
  bool _receiving = false;

  CdkApiService get _api => ref.read(cdkApiServiceProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final project = await _api.project(widget.projectId);
      CdkPendingPayment? pending;
      if (project.isPaid && !project.isReceived) {
        pending = await _api
            .pendingPayment(widget.projectId)
            .catchError(
              (Object _) => const CdkPendingPayment(
                hasPending: false,
                payUrl: '',
                amount: '',
              ),
            );
      }
      if (!mounted) return;
      setState(() {
        _project = project;
        _pending = pending;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _errorStack = st;
      });
    }
  }

  /// 不能领的原因（null 表示可以领）。和后端 IsReceivable 的判断顺序一致，
  /// 但最终以后端为准——它还会查 IP、风控分
  String? _blockedReason(CdkProject p) {
    final now = DateTime.now();
    if (p.distributionType == CdkDistributionType.lottery) {
      return S.current.cdkPage_lotteryHint;
    }
    if (p.distributionType == CdkDistributionType.invite) {
      return S.current.cdkPage_inviteHint;
    }
    final start = p.startTime;
    if (start != null && now.isBefore(start)) {
      return S.current.cdkPage_notStarted(TimeUtils.formatDetailTime(start));
    }
    final end = p.endTime;
    if (end != null && now.isAfter(end)) return S.current.cdkPage_ended;
    if (widget.user.trustLevel < p.minimumTrustLevel) {
      return S.current.cdkPage_trustTooLow(p.minimumTrustLevel);
    }
    if (p.availableItems <= 0 && _pending?.hasPending != true) {
      return S.current.cdkPage_soldOut;
    }
    return null;
  }

  Future<void> _receive() async {
    final project = _project;
    if (project == null || _receiving) return;
    setState(() => _receiving = true);
    try {
      // 已有未过期的待支付订单：直接继续付款，不重新占库存
      final pending = _pending;
      if (pending != null && pending.hasPending && pending.payUrl.isNotEmpty) {
        await _pay(pending.payUrl);
        return;
      }

      final siteKey = await _api.hcaptchaSiteKey(widget.projectId);
      if (!mounted) return;
      if (siteKey == null) {
        ToastService.showError(S.current.cdkPage_captchaUnavailable);
        return;
      }
      final token = await HCaptchaSheet.show(
        context,
        siteKey: siteKey,
        hostUrl: CdkProjectPage.receiveUrl(widget.projectId),
      );
      if (token == null || !mounted) return;

      final result = await _api.receive(widget.projectId, token);
      if (!mounted) return;
      if (result.requirePayment) {
        await _pay(result.payUrl);
        return;
      }
      if (result.itemContent.isNotEmpty) {
        HapticFeedback.mediumImpact();
        setState(() => _project = project.copyWithReceived(result.itemContent));
        ToastService.showSuccess(S.current.cdkPage_receiveSuccess);
      } else {
        await _load();
      }
    } on CdkApiException catch (e) {
      ToastService.showError(e.message);
      // 已领 / 没库存之类：刷新一下让按钮状态跟上
      if (mounted) await _load();
    } on OAuthExpiredException {
      ToastService.showError(S.current.cdk_reAuthHint);
      ref.read(cdkUserInfoProvider.notifier).refresh();
    } catch (e) {
      AppLogger.warning('CDK 领取失败：$e', tag: 'CDK');
      ToastService.showError(S.current.cdkPage_receiveFailed);
    } finally {
      if (mounted) setState(() => _receiving = false);
    }
  }

  /// 付款页只认 credit.linux.do（LDC），别的地址不打开
  Future<void> _pay(String payUrl) async {
    final uri = Uri.tryParse(payUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != 'credit.linux.do') {
      ToastService.showError(S.current.cdkPage_payUrlInvalid);
      return;
    }
    await WebViewPage.open<void>(context, payUrl, title: 'LINUX DO Credit');
    if (!mounted) return;
    // 付完回来：重新读项目，到账的话 is_received 会变真
    await _load();
    final project = _project;
    if (project != null && project.isReceived) {
      ToastService.showSuccess(S.current.cdkPage_receiveSuccess);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return ErrorView(error: error, stackTrace: _errorStack, onRetry: _load);
    }
    final project = _project;
    if (project == null) return const Center(child: LoadingSpinner());

    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        Expanded(
          child: M3eRefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                _ProjectHeader(project: project),
                if (project.isReceived) ...[
                  const SizedBox(height: 12),
                  _ReceivedCard(content: project.receivedContent),
                ],
                if (project.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  CdkSurfaceCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        project.description.trim(),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(height: 1.6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!project.isReceived)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + bottom),
            child: _buildAction(project),
          ),
      ],
    );
  }

  Widget _buildAction(CdkProject project) {
    final theme = Theme.of(context);
    final reason = _blockedReason(project);
    final pending = _pending;
    final String label;
    if (pending != null && pending.hasPending) {
      label = S.current.cdkPage_continuePay(
        pending.amount.isNotEmpty ? pending.amount : project.price,
      );
    } else if (project.isPaid) {
      label = S.current.cdkPage_payAndReceive(project.price);
    } else {
      label = S.current.cdkPage_receive;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              reason,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: reason != null || _receiving ? null : _receive,
          child: _receiving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(label),
        ),
      ],
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project});

  final CdkProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final subtle = mj?.ink3 ?? theme.colorScheme.onSurfaceVariant;
    final creator = project.creatorNickname.isNotEmpty
        ? project.creatorNickname
        : project.creatorUsername;
    final start = project.startTime;
    final end = project.endTime;

    Widget fact(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: subtle),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: subtle),
          ),
        ),
      ],
    );

    return CdkSurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              project.name,
              style: mj != null
                  ? TextStyle(
                      fontFamily: MojianTokens.titleFamilyFor(context),
                      fontSize: 20,
                      height: 1.35,
                      color: mj.ink,
                    )
                  : theme.textTheme.titleLarge,
            ),
            if (creator.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                S.current.cdkPage_byCreator(creator),
                style: theme.textTheme.bodySmall?.copyWith(color: subtle),
              ),
            ],
            if (project.tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in project.tags)
                    Chip(
                      label: Text(tag),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelStyle: theme.textTheme.labelSmall,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                fact(
                  Symbols.inventory_2_rounded,
                  S.current.cdkPage_stock(
                    project.availableItems,
                    project.totalItems,
                  ),
                ),
                fact(
                  Symbols.payments_rounded,
                  project.isPaid
                      ? S.current.cdkPage_price(project.price)
                      : S.current.cdkPage_free,
                ),
                fact(
                  Symbols.verified_user_rounded,
                  S.current.cdkPage_minTrust(project.minimumTrustLevel),
                ),
                if (start != null || end != null)
                  fact(
                    Symbols.schedule_rounded,
                    '${start == null ? '' : TimeUtils.formatDetailTime(start)}'
                    ' – '
                    '${end == null ? '' : TimeUtils.formatDetailTime(end)}',
                  ),
                if (!project.allowSameIp)
                  fact(Symbols.lan_rounded, S.current.cdkPage_oneIpOnce),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceivedCard extends StatelessWidget {
  const _ReceivedCard({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CdkSurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Symbols.check_circle_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  S.current.cdkPage_alreadyReceived,
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 10),
            CdkContentBox(content: content),
          ],
        ),
      ),
    );
  }
}
