import '../../site_context.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/user.dart';
import '../../discourse/discourse_service.dart';
import 'cfhub_api.dart';
import 'connect_bound_token.dart';
import 'connect_code_flow.dart';
import 'network_settings_service.dart';

/// 开启「帮助优选」（探针上报）的结果
enum CfhubEnableResult {
  /// 已拿到探针令牌，上报已开
  ok,

  /// 没登录
  needLogin,

  /// 信任等级不够
  needTrust,

  /// cfhub 还没开放探针接口
  hubUnavailable,

  /// cfhub 拒绝了这个账号
  rejected,

  /// 网络或服务端异常
  failed,

  /// 授权中途没拿到 code（账号用不了 Connect、或期间换了账号）
  cancelled,
}

/// cfhub 探针上报的账号令牌
///
/// 「帮助优选」默认关，用户手动开：登录且信任等级 ≥ 1 的账号在 App 里走一遍
/// LinuxDo Connect 授权，把回调里的 code/state 交给 cfhub，cfhub 核验身份后
/// 发一个 `cfp_` 开头的令牌；之后 Rust 侧把本地竞速的测量结果带着这个令牌上报。
/// 令牌只用来防伪造上报，和加速 DoH 的令牌互不相干。
///
/// 发给 cfhub 的只有 code/state 和它自己发的令牌，从不携带 linux.do 的 cookie、_t
/// 或 API key。登出或换账号时令牌作废。令牌值不写日志。
///
/// 取授权地址 → Connect → 换码 → 作废这条链路与加速 DoH 共用 [ConnectBoundToken]
/// （网络类失败整体重来、作废先于重发、换号守卫都在那里），这里只管开关与令牌存取。
class CfhubProbeAuthService extends ChangeNotifier {
  CfhubProbeAuthService._({
    ConnectTokenTransport? transport,
    ConnectCodeFlow? flow,
    ValueListenable<User?>? userNotifier,
    Future<void> Function(Duration delay)? sleep,
  }) : _transport = transport,
       _flow = flow,
       _userNotifier = userNotifier,
       _sleep = sleep;

  static CfhubProbeAuthService instance = CfhubProbeAuthService._();

  /// 测试用：换一个干净的实例，可注入假的传输（假 cfhub）/ Connect 流程 /
  /// 用户通知器 / 重试等待
  @visibleForTesting
  static void resetForTest({
    ConnectTokenTransport? transport,
    ConnectCodeFlow? flow,
    ValueListenable<User?>? userNotifier,
    Future<void> Function(Duration delay)? sleep,
  }) {
    instance._detachUserListener();
    instance = CfhubProbeAuthService._(
      transport: transport,
      flow: flow,
      userNotifier: userNotifier,
      sleep: sleep,
    );
  }

  static const String _tokenKey = 'cfhub_probe_token';
  static const String _userIdKey = 'cfhub_probe_user_id';

  /// 能开探针上报的最低信任等级
  static const int minTrustLevel = 1;

  /// 令牌被 cfhub 拒绝（401/403）时自增一次，UI 据此弹一次提示
  final ValueNotifier<int> rejectedNotifier = ValueNotifier<int>(0);

  final ConnectTokenTransport? _transport;
  ConnectCodeFlow? _flow;
  ValueListenable<User?>? _userNotifier;
  final Future<void> Function(Duration delay)? _sleep;
  bool _userListenerAttached = false;

  SharedPreferences? _prefs;
  String? _token;
  int? _userId;
  Future<CfhubEnableResult>? _inflight;

  /// 上次看到的登录账号 id：区分「换号 / 登出」与同一账号的资料刷新
  int? _seenUserId;

  /// cfhub 按账号作废令牌：重新开启前由它先等上一次作废落地，
  /// 否则作废可能晚于新令牌到达、把新令牌一起作废
  late final ConnectBoundToken _bound = ConnectBoundToken(
    policy: CfhubApi.policy,
    transport: _transport ?? CfhubApi.transport(),
    flow: () => _flow ??= ConnectCodeFlow(),
    currentUserId: () => _currentUser?.id,
    sleep: _sleep,
  );

  /// 用户通知器默认取 DiscourseService 的；测试里注入假的，免得构造整个服务
  ValueListenable<User?> get _effectiveUserNotifier =>
      _userNotifier ??= DiscourseService().currentUserNotifier;

  /// 当前的探针令牌；null 表示没有
  String? get token => _token;

  /// 最近一次开启失败卡在哪一步（`start HTTP 403` / `connect failed` 等），给提示用
  String? lastFailureDetail;

  /// 是否已拿到探针令牌
  bool get isAuthorized => _token != null;

  /// 读回上次存的令牌，并开始跟随登录账号
  void initialize(SharedPreferences prefs) {
    if (!SiteContext.isLinuxDo) return;
    if (_prefs != null) return;
    _prefs = prefs;
    final token = prefs.getString(_tokenKey);
    final userId = prefs.getInt(_userIdKey);
    if (token != null && token.isNotEmpty && userId != null) {
      _token = token;
      _userId = userId;
    } else if (token != null || userId != null) {
      // 两项不成对说明上次没写完整，当没有处理
      unawaited(_clearStored());
    }
    _attachUserListener();
    // 启动时已经知道是谁（不是本令牌的账号）就马上停用；还不知道时等通知
    final user = _effectiveUserNotifier.value;
    _seenUserId = user?.id;
    if (_token != null && user != null && user.id != _userId) {
      unawaited(disable());
    }
  }

  /// 用户在设置里打开「帮助优选」：按账号条件走一遍 Connect 换令牌
  ///
  /// 已经有当前账号的令牌时只是把上报重新打开。并发调用共用同一次结果。
  /// 网络类失败整条链路最多重来 2 次（2 s / 4 s，见 [CfhubApi.policy]）
  Future<CfhubEnableResult> enable() {
    final running = _inflight;
    if (running != null) return running;
    final future = _enable().whenComplete(() => _inflight = null);
    _inflight = future;
    return future;
  }

  Future<CfhubEnableResult> _enable() async {
    if (!SiteContext.isLinuxDo) return CfhubEnableResult.failed;
    if (_prefs == null) return CfhubEnableResult.failed;
    final user = _currentUser;
    if (user == null) return CfhubEnableResult.needLogin;
    if (user.trustLevel < minTrustLevel) return CfhubEnableResult.needTrust;

    final existing = _token;
    if (existing != null && _userId == user.id) {
      await _setShare(true, bearer: existing);
      notifyListeners();
      return CfhubEnableResult.ok;
    }
    if (existing != null) {
      // 别的账号留下的令牌，先作废（下面换码前会等它落地）
      await _clearStored();
      unawaited(_bound.revoke(existing));
    }

    final result = await _bound.authorize(userId: user.id, interactive: true);
    switch (result.outcome) {
      case ConnectTokenOutcome.issued:
        final issued = result.token!;
        await _save(issued, user.id);
        await _setShare(true, bearer: issued);
        notifyListeners();
        return CfhubEnableResult.ok;
      case ConnectTokenOutcome.rejected:
        debugPrint('[CFHUB] cfhub 拒绝了此账号');
        return _fail(CfhubEnableResult.rejected);
      case ConnectTokenOutcome.serverUnavailable:
        return _fail(CfhubEnableResult.hubUnavailable);
      case ConnectTokenOutcome.connectUnavailable:
        debugPrint('[CFHUB] Connect 授权没拿到 code，放弃开启探针上报');
        return _fail(CfhubEnableResult.cancelled);
      case ConnectTokenOutcome.cancelled:
        // 撞盾后关掉了验证页：CF 那边已经提示过，不再追加
        return _fail(CfhubEnableResult.cancelled);
      case ConnectTokenOutcome.stale:
        // 等结果期间退出或换了号：拿到的令牌已作废
        return _fail(CfhubEnableResult.cancelled);
      case ConnectTokenOutcome.failed:
        return _fail(CfhubEnableResult.failed);
    }
  }

  /// 没开成：确保上报是关的，再把结果原样返回
  Future<CfhubEnableResult> _fail(CfhubEnableResult result) async {
    lastFailureDetail = result == CfhubEnableResult.failed
        ? _bound.lastFailureDetail
        : null;
    await _setShare(false);
    notifyListeners();
    return result;
  }

  /// 关闭「帮助优选」：作废令牌（尽力而为）、清掉本地记录、关上报
  ///
  /// 进行中的开启结果一并丢弃；作废请求由 [ConnectBoundToken] 记着，
  /// 重新开启时先等它落地再换码
  Future<void> disable({bool revoke = true}) async {
    if (!SiteContext.isLinuxDo) return;
    _bound.invalidate();
    final token = _token;
    if (revoke && token != null) {
      unawaited(_bound.revoke(token));
    }
    await _clearStored();
    await _setShare(false);
    notifyListeners();
  }

  /// Rust 侧上报被 cfhub 拒绝（401/403）：令牌已失效，清掉并关上报，通知 UI 提示一次
  Future<void> onRejected() async {
    if (_token == null) {
      // 已经处理过了（轮询可能重复拿到同一个标记），只确保上报是关的
      await _setShare(false);
      return;
    }
    debugPrint('[CFHUB] 探针令牌被 cfhub 拒绝，已停用「帮助优选」');
    await _clearStored();
    await _setShare(false);
    rejectedNotifier.value++;
    notifyListeners();
  }

  User? get _currentUser => _effectiveUserNotifier.value;

  void _attachUserListener() {
    if (_userListenerAttached) return;
    _effectiveUserNotifier.addListener(_handleUserChanged);
    _userListenerAttached = true;
  }

  void _detachUserListener() {
    if (!_userListenerAttached) return;
    _userNotifier?.removeListener(_handleUserChanged);
    _userListenerAttached = false;
  }

  /// 登出（变成 null）或换了账号：令牌不能再用
  void _handleUserChanged() {
    final user = _effectiveUserNotifier.value;
    if (user?.id != _seenUserId) {
      _seenUserId = user?.id;
      // 换号 / 登出（哪怕很快又换回来）：进行中的开启结果不能落到现在的账号上，
      // Connect 那一跳用的可能已经是另一个账号的登录态
      _bound.invalidate();
    }
    if (_token == null) return;
    if (user == null || user.id != _userId) {
      debugPrint('[CFHUB] 登录账号变化，停用探针令牌');
      unawaited(disable());
    }
  }

  Future<void> _setShare(bool on, {String? bearer}) async {
    try {
      await NetworkSettingsService.instance.setShareMeasurements(
        on,
        bearer: bearer,
      );
    } catch (e) {
      debugPrint('[CFHUB] 更新「帮助优选」开关失败: $e');
    }
  }

  Future<void> _save(String token, int userId) async {
    _token = token;
    _userId = userId;
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_tokenKey, token);
    await prefs.setInt(_userIdKey, userId);
  }

  Future<void> _clearStored() async {
    _token = null;
    _userId = null;
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
  }
}
