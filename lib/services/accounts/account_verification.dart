import 'dart:async';

import '../session/session_token_ports.dart';

/// 切到一个账号后，服务端认的是不是它。
enum AccountCheck {
  /// 服务端认的就是目标账号
  confirmed,

  /// 服务端认的是另一个人
  wrongAccount,

  /// 服务端明确说这份会话已失效（登录过期 / 在别处退出）
  rejected,

  /// 没拿到结论：超时、撞 CF 盾、网络断了、游客首页先落地……
  /// 不能当成失效——以前就是把这种情况当失效，标了「要重新登录」又切回
  /// 原账号，切换中途网络一抖就掉登录。
  unknown,
}

class AccountCheckResult {
  const AccountCheckResult(this.check, [this.user]);

  final AccountCheck check;

  /// [AccountCheck.confirmed] 时是服务端给的 current_user
  final Map<String, dynamic>? user;
}

/// 核对 [userId] 是否就是当前会话的用户。
///
/// 预加载里已经是目标账号就直接确认；否则（没有用户 / 是别人）用 jar 的
/// 会话问 `/session/current.json`，无结论时隔 [retryDelay] 再问一次。只有
/// 服务端明确答复（是别人 / 会话失效）才算确定不对；问不到时预加载里是
/// 别人也算不对，什么都没有就是 [AccountCheck.unknown]。
Future<AccountCheckResult> verifySwitchedAccount({
  required int userId,
  required Map<String, dynamic>? preloadedUser,
  required Future<SessionTokenProbeResult> Function() probe,
  int attempts = 2,
  Duration probeTimeout = const Duration(seconds: 8),
  Duration retryDelay = const Duration(milliseconds: 1500),
}) async {
  final preloadedId = _idOf(preloadedUser);
  if (preloadedId == userId) {
    return AccountCheckResult(AccountCheck.confirmed, preloadedUser);
  }
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) await Future<void>.delayed(retryDelay);
    SessionTokenProbeResult result;
    try {
      result = await probe().timeout(probeTimeout);
    } catch (_) {
      continue;
    }
    if (result.isRejected) {
      return const AccountCheckResult(AccountCheck.rejected);
    }
    if (!result.isValid) continue;
    final liveId = _idOf(result.currentUser);
    if (liveId == null) continue;
    return liveId == userId
        ? AccountCheckResult(AccountCheck.confirmed, result.currentUser)
        : const AccountCheckResult(AccountCheck.wrongAccount);
  }
  return AccountCheckResult(
    preloadedId != null ? AccountCheck.wrongAccount : AccountCheck.unknown,
  );
}

int? _idOf(Map<String, dynamic>? user) => (user?['id'] as num?)?.toInt();
