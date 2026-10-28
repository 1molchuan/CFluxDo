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

  /// 没拿到结论：超时、撞 CF 盾、网络断了……
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
/// 先用 jar 的会话问 `/session/current.json`（一个小 JSON，比整页首页轻，
/// 也少撞盾）；没结论再看首页预加载 [preloadedUser]（调用方让它在后台
/// 并行加载，这里才去等），仍不行隔 [retryDelay] 再问一次。只有服务端明确
/// 答复（是别人 / 会话失效）才算确定不对；问不到时预加载里是别人也算不对，
/// 什么都没有就是 [AccountCheck.unknown]。
Future<AccountCheckResult> verifySwitchedAccount({
  required int userId,
  required Future<SessionTokenProbeResult> Function() probe,
  required Future<Map<String, dynamic>?> Function() preloadedUser,
  int attempts = 2,
  Duration probeTimeout = const Duration(seconds: 8),
  Duration retryDelay = const Duration(milliseconds: 1500),
}) async {
  int? preloadedId;
  var preloadChecked = false;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) await Future<void>.delayed(retryDelay);
    SessionTokenProbeResult? result;
    try {
      result = await probe().timeout(probeTimeout);
    } catch (_) {
      result = null;
    }
    if (result != null) {
      if (result.isRejected) {
        return const AccountCheckResult(AccountCheck.rejected);
      }
      final liveId = result.isValid ? _idOf(result.currentUser) : null;
      if (liveId != null) {
        return liveId == userId
            ? AccountCheckResult(AccountCheck.confirmed, result.currentUser)
            : const AccountCheckResult(AccountCheck.wrongAccount);
      }
    }
    if (!preloadChecked) {
      preloadChecked = true;
      Map<String, dynamic>? preloaded;
      try {
        preloaded = await preloadedUser();
      } catch (_) {
        preloaded = null;
      }
      preloadedId = _idOf(preloaded);
      if (preloadedId == userId) {
        return AccountCheckResult(AccountCheck.confirmed, preloaded);
      }
    }
  }
  return AccountCheckResult(
    preloadedId != null ? AccountCheck.wrongAccount : AccountCheck.unknown,
  );
}

int? _idOf(Map<String, dynamic>? user) => (user?['id'] as num?)?.toInt();
