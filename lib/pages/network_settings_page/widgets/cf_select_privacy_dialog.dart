import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/cfhub_probe_auth_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';

/// 本地优选隐私说明对话框
///
/// 1.1 起 App 自己在 Cloudflare 共享池里测速选节点，会对公共 DoH 发少量域名查询、
/// 与若干节点做 ECH 握手；这里把这些行为和「帮助优选」的承诺一次说清。
///
/// - [firstLaunch] 为 true：版本首启弹出，按钮是「保持关闭」(默认焦点，返回 false)
///   与「开启并帮助优选」(返回 true)。
/// - [firstLaunch] 为 false：设置页「查看隐私说明」，只有一个「知道了」。
class CfSelectPrivacyDialog extends StatelessWidget {
  const CfSelectPrivacyDialog({super.key, required this.firstLaunch});

  final bool firstLaunch;

  /// 对话框显示期间为 true，供其他自动弹窗（如专属加速的 Connect 授权）避让
  static bool isShowing = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.cfSelect_noticeTitle),
      content: SingleChildScrollView(
        child: Text(
          l10n.cfSelect_noticeBody,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
      ),
      actions: firstLaunch
          ? [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cfSelect_noticeKeepOff),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.cfSelect_noticeEnable),
              ),
            ]
          : [
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.common_gotIt),
              ),
            ],
    );
  }
}

/// 弹出隐私说明；[firstLaunch] 为 true 时返回用户是否选了「开启并帮助优选」，
/// 否则返回 null。弹窗不可点遮罩关闭，显示期间 [CfSelectPrivacyDialog.isShowing] 为 true。
Future<bool?> showCfSelectPrivacyDialog(
  BuildContext context, {
  required bool firstLaunch,
}) async {
  CfSelectPrivacyDialog.isShowing = true;
  try {
    return await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CfSelectPrivacyDialog(firstLaunch: firstLaunch),
    );
  } finally {
    CfSelectPrivacyDialog.isShowing = false;
  }
}

/// 把 cfhub 授权结果转成给用户看的提示；成功返回 null（无需提示）
///
/// 首启弹窗（main.dart）与设置卡片共用，保证两处文案一致。
/// 「分享失败」带上卡在哪一步（如 start HTTP 403），方便用户反馈
String _shareFailedMessage() {
  final l10n = S.current;
  final detail = CfhubProbeAuthService.instance.lastFailureDetail;
  if (detail == null || detail.isEmpty) return l10n.common_shareFailed;
  return l10n.cfSelect_shareFailedWith(detail);
}

String? cfhubEnableResultMessage(CfhubEnableResult result) {
  final l10n = S.current;
  return switch (result) {
    CfhubEnableResult.ok => null,
    CfhubEnableResult.needLogin ||
    CfhubEnableResult.needTrust => l10n.cfSelect_shareNeedTrust,
    CfhubEnableResult.hubUnavailable => l10n.cfSelect_shareHubUnavailable,
    CfhubEnableResult.rejected => l10n.cfSelect_shareRejected,
    CfhubEnableResult.failed => _shareFailedMessage(),
    // 用户自己取消了授权页，不再追加提示
    CfhubEnableResult.cancelled => null,
  };
}

/// 按 cfhub 授权结果弹 toast；成功时不弹
void showCfhubEnableResultToast(CfhubEnableResult result) {
  final message = cfhubEnableResultMessage(result);
  if (message == null) return;
  ToastService.showError(message);
}
