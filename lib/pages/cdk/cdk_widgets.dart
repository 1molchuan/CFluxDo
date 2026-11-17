import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../../models/cdk_user_info.dart';
import '../../providers/cdk_providers.dart';
import '../../services/cdk_oauth_service.dart';
import '../../services/network/exceptions/oauth_exception.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/layout/master_detail_layout.dart';

/// CDK 原生页面的卡片外观：墨笺下是纸笺底 + 发丝线框，经典下是 M3 低层卡片
class CdkSurfaceCard extends StatelessWidget {
  const CdkSurfaceCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final body = onTap == null ? child : InkWell(onTap: onTap, child: child);
    if (mj != null) {
      return Material(
        color: mj.paper3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: mj.rule),
        ),
        clipBehavior: Clip.antiAlias,
        child: body,
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

/// 领到的内容：等宽、可选中，带复制按钮。多行内容（一行一个码）逐行可复制
class CdkContentBox extends StatelessWidget {
  const CdkContentBox({super.key, required this.content, this.maxLines});

  final String content;
  final int? maxLines;

  static Future<void> copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      ToastService.showSuccess(S.current.common_copiedToClipboard);
    } catch (_) {
      ToastService.showError(S.current.common_clipboardUnavailable);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    final bg = mj?.paper2 ?? theme.colorScheme.surfaceContainerHighest;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(mj != null ? 4 : 10),
        border: mj != null ? Border.all(color: mj.rule) : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SelectableText(
              content,
              // 只给 maxLines 时 SelectableText 按最大行数预留高度，一行的码也撑成
              // 一大块（2026-11-17 模拟器上实看），要配 minLines: 1 按内容撑开
              minLines: 1,
              maxLines: maxLines,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Roboto Mono', 'Menlo', 'Consolas'],
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            tooltip: S.current.common_copy,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.content_copy_rounded, size: 20),
            onPressed: () => copy(content),
          ),
        ],
      ),
    );
  }
}

/// 授权 CDK：与元宇宙页的开关同一流程（OAuth 同意 → 打开开关 → 刷新余额）
Future<bool> authorizeCdk(BuildContext context, WidgetRef ref) async {
  try {
    final ok = await CdkOAuthService().authorize(context);
    if (!ok) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cdk_enabled', true);
    await ref.read(cdkUserInfoProvider.notifier).refresh();
    ToastService.showSuccess(S.current.metaverse_cdkAuthSuccess);
    return true;
  } catch (e) {
    ToastService.showError(S.current.metaverse_authFailed(e.toString()));
    return false;
  }
}

/// 需要 CDK 会话的页面外壳：未开启 / 过期 / 撞盾 / 加载中各给对应的界面，
/// 有会话才交给 [builder]
class CdkSessionGate extends ConsumerStatefulWidget {
  const CdkSessionGate({super.key, required this.builder});

  final Widget Function(BuildContext context, CdkUserInfo user) builder;

  @override
  ConsumerState<CdkSessionGate> createState() => _CdkSessionGateState();
}

class _CdkSessionGateState extends ConsumerState<CdkSessionGate> {
  bool _authorizing = false;

  Future<void> _authorize() async {
    if (_authorizing) return;
    setState(() => _authorizing = true);
    await authorizeCdk(context, ref);
    if (mounted) setState(() => _authorizing = false);
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(cdkUserInfoProvider);
    final user = info.value;
    final error = info.error;

    if (error != null && (user == null || error is OAuthExpiredException)) {
      if (error is OAuthExpiredException) {
        return _prompt(
          icon: Symbols.lock_clock_rounded,
          message: S.current.cdk_reAuthHint,
          action: S.current.common_reAuth,
        );
      }
      return ErrorView(
        error: error,
        stackTrace: info.stackTrace,
        onRetry: () => OAuthErrorPolicy.isCfChallenge(error)
            ? ref
                  .read(cdkUserInfoProvider.notifier)
                  .refreshAfterCfVerification()
            : ref.read(cdkUserInfoProvider.notifier).refresh(),
      );
    }
    if (user != null) return widget.builder(context, user);
    if (info.isLoading) return const Center(child: LoadingSpinner());
    return _prompt(
      icon: Symbols.token_rounded,
      message: S.current.cdkPage_notAuthorized,
      action: S.current.cdkPage_authorize,
    );
  }

  Widget _prompt({
    required IconData icon,
    required String message,
    required String action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasterDetailEmptyState(icon: icon, message: message),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _authorizing ? null : _authorize,
              child: _authorizing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(action),
            ),
          ],
        ),
      ),
    );
  }
}
