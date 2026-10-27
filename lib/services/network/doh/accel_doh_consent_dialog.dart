import 'package:flutter/material.dart';

import '../../../utils/dialog_utils.dart';
import '../../local_notification_service.dart' show navigatorKey;

/// 弹窗征求开启 cfluxdo 加速的同意；返回 null 表示现在没法弹（不在前台或界面还没起来）
Future<bool?> askAccelDohConsent() async {
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
    return null;
  }
  final context = navigatorKey.currentContext;
  if (context == null || !context.mounted) return null;
  final result = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _ConsentDialog(),
  );
  return result ?? false;
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('开启 CFluxDo 加速'),
      content: const Text(
        'CFluxDo 加速需要用 L 站 Connect 确认一次你的账号。\n\n'
        '加速服务端只会拿到你的 L 站 id、用户名、信任等级这类基本资料，'
        '拿不到你的登录凭据。\n\n'
        '每个账号最多 3 台设备，第 4 台授权时最早授权的那台会被挤掉。\n\n'
        '不授权也能用，会改走公共加速。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('暂不'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('授权'),
        ),
      ],
    );
  }
}
