import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/toast_service.dart';
import 'balance_card_action_button.dart';

/// 验证与随后的余额刷新共用忙碌状态；取消验证不会清除业务登录态。
///
/// 验证通过、刷新仍被拦（或本次会话已确认原生链路不被信任）时，按钮改为
/// 在内置浏览器里打开业务页：浏览器能看到余额，回来后再刷新一次。
class BalanceCardCfAction extends StatefulWidget {
  const BalanceCardCfAction({
    super.key,
    required this.onRetry,
    required this.isLoading,
    this.filled = false,
    this.outlined = false,
    this.verify,
    this.openInBrowser,
    this.stillBlocked,
    this.preferBrowser = false,
  });

  /// 验证通过或从浏览器回来后的刷新（不再自动起验证）。
  final Future<void> Function() onRetry;
  final bool isLoading;
  final bool filled;
  final bool outlined;
  final Future<bool?> Function(BuildContext)? verify;

  /// 在内置浏览器里打开业务页，关闭后返回。
  final Future<void> Function(BuildContext)? openInBrowser;

  /// 刷新后是否仍被安全验证拦截。
  final bool Function()? stillBlocked;

  /// 错误本身已说明再验证也没用（原生链路不被信任）：直接给浏览器入口。
  final bool preferBrowser;

  @override
  State<BalanceCardCfAction> createState() => _BalanceCardCfActionState();
}

class _BalanceCardCfActionState extends State<BalanceCardCfAction> {
  bool _verifying = false;

  /// 本卡片上手动验证已通过、刷新仍被拦。
  bool _stillBlocked = false;

  bool get _showBrowser =>
      widget.openInBrowser != null && (widget.preferBrowser || _stillBlocked);

  Future<void> _verify() async {
    if (_verifying || widget.isLoading) return;
    setState(() => _verifying = true);
    try {
      final result =
          await (widget.verify?.call(context) ??
              CfChallengeService().showManualVerifyNow(context, true));
      if (!mounted) return;
      if (result == true) {
        await widget.onRetry();
        if (mounted && (widget.stillBlocked?.call() ?? false)) {
          setState(() => _stillBlocked = true);
          if (widget.openInBrowser != null) {
            ToastService.showInfo(S.current.cf_serviceStillBlocked);
          }
        }
      } else if (result == false) {
        ToastService.showError(S.current.cf_verifyIncomplete);
      } else {
        ToastService.showError(S.current.cf_cannotOpenVerifyPage);
      }
    } catch (error) {
      if (mounted) ToastService.showError(S.current.cf_failedRetry);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _openBrowser() async {
    final open = widget.openInBrowser;
    if (open == null || _verifying || widget.isLoading) return;
    setState(() => _verifying = true);
    try {
      await open(context);
      if (!mounted) return;
      await widget.onRetry();
    } catch (error) {
      if (mounted) ToastService.showError(S.current.cf_failedRetry);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) => BalanceCardActionButton(
    label: _showBrowser
        ? context.l10n.cf_openInBrowserAction
        : context.l10n.cf_manualVerifyAction,
    onPressed: _showBrowser ? _openBrowser : _verify,
    isLoading: widget.isLoading || _verifying,
    filled: widget.filled,
    outlined: widget.outlined,
  );
}
