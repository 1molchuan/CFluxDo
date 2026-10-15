import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/user.dart';
import '../../discourse/discourse_service.dart';
import 'accel_doh_connect_flow.dart';
import 'cfhub_api.dart';
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
class CfhubProbeAuthService extends ChangeNotifier {
  CfhubProbeAuthService._({
    CfhubApi? api,
    AccelDohConnectFlow? flow,
    ValueListenable<User?>? userNotifier,
  }) : _api = api,
       _flow = flow,
       _userNotifier = userNotifier;

  static CfhubProbeAuthService instance = CfhubProbeAuthService._();

  /// 测试用：换一个干净的实例，可注入假的 cfhub 接口 / Connect 流程 / 用户通知器
  @visibleForTesting
  static void resetForTest({
    CfhubApi? api,
    AccelDohConnectFlow? flow,
    ValueListenable<User?>? userNotifier,
  }) {
    instance._detachUserListener();
    instance = CfhubProbeAuthService._(
      api: api,
      flow: flow,
      userNotifier: userNotifier,
    );
  }

  static const String _tokenKey = 'cfhub_probe_token';
  static const String _userIdKey = 'cfhub_probe_user_id';

  /// 能开探针上报的最低信任等级
  static const int minTrustLevel = 1;

  /// 令牌被 cfhub 拒绝（401/403）时自增一次，UI 据此弹一次提示
  final ValueNotifier<int> rejectedNotifier = ValueNotifier<int>(0);

  CfhubApi? _api;
  AccelDohConnectFlow? _flow;
  ValueListenable<User?>? _userNotifier;
  bool _userListenerAttached = false;

  SharedPreferences? _prefs;
  String? _token;
  int? _userId;
  Future<CfhubEnableResult>? _inflight;

  /// 上一次关闭时发出的作废请求：cfhub 按账号作废，重新开启前要等它落地，
  /// 否则它可能晚于新令牌到达、把新令牌一起作废
  Future<void>? _pendingRevoke;

  CfhubApi get _effectiveApi => _api ??= CfhubApi();

  AccelDohConnectFlow get _effectiveFlow => _flow ??= AccelDohConnectFlow();

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
    if (_token != null && user != null && user.id != _userId) {
      unawaited(disable());
    }
  }

  /// 用户在设置里打开「帮助优选」：按账号条件走一遍 Connect 换令牌
  ///
  /// 已经有当前账号的令牌时只是把上报重新打开。并发调用共用同一次结果。
  Future<CfhubEnableResult> enable() {
    final running = _inflight;
    if (running != null) return running;
    final future = _enableWithRetry().whenComplete(() => _inflight = null);
    _inflight = future;
    return future;
  }

  /// 整条链路（取授权地址 → Connect → 换令牌）有 4 跳、每跳只请求一次，
  /// 移动网络上任一跳瞬时失败就整体失败。只对「网络类失败」整体重来：
  /// 每次都是新的 state，重来是安全的；被拒 / 未开放 / 用户取消不重来
  static const int _maxAttempts = 3;

  /// 重试间隔；测试里置空让用例不用真等
  @visibleForTesting
  static List<Duration> retryDelays = const [
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  Future<CfhubEnableResult> _enableWithRetry() async {
    CfhubEnableResult result = CfhubEnableResult.failed;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retryDelays[attempt - 1]);
        debugPrint('[CFHUB] 开启失败，第 ${attempt + 1} 次尝试');
      }
      result = await _enable();
      if (result != CfhubEnableResult.failed) break;
    }
    return result;
  }

  Future<CfhubEnableResult> _enable() async {
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
      // 别的账号留下的令牌，先作废
      await _clearStored();
      _pendingRevoke = _effectiveApi.revoke(existing);
    }
    await _awaitPendingRevoke();

    final start = await _effectiveApi.startConnect();
    if (start.unavailable) return _fail(CfhubEnableResult.hubUnavailable);
    final authorizeUrl = start.url;
    if (authorizeUrl == null) return _fail(CfhubEnableResult.failed);

    final connect = await _effectiveFlow.fetchCode(authorizeUrl, silent: false);
    if (_currentUser?.id != user.id) return _fail(CfhubEnableResult.cancelled);
    switch (connect.outcome) {
      case AccelDohConnectOutcome.failed:
        _effectiveApi.lastFailure = 'connect failed';
        return _fail(CfhubEnableResult.failed);
      case AccelDohConnectOutcome.unavailable:
        debugPrint('[CFHUB] Connect 授权没拿到 code，放弃开启探针上报');
        return _fail(CfhubEnableResult.cancelled);
      case AccelDohConnectOutcome.code:
        break;
    }

    final result = await _effectiveApi.exchangeCode(
      connect.code!,
      connect.state!,
    );
    if (_currentUser?.id != user.id) {
      // 等结果期间退出或换了号，这个令牌不能留
      final issued = result.token;
      if (issued != null) unawaited(_effectiveApi.revoke(issued));
      return _fail(CfhubEnableResult.cancelled);
    }
    switch (result.outcome) {
      case CfhubTokenOutcome.ok:
        final issued = result.token!;
        await _save(issued, user.id);
        await _setShare(true, bearer: issued);
        notifyListeners();
        return CfhubEnableResult.ok;
      case CfhubTokenOutcome.rejected:
        debugPrint('[CFHUB] cfhub 拒绝了此账号');
        return _fail(CfhubEnableResult.rejected);
      case CfhubTokenOutcome.unavailable:
        return _fail(CfhubEnableResult.hubUnavailable);
      case CfhubTokenOutcome.failed:
        return _fail(CfhubEnableResult.failed);
    }
  }

  /// 没开成：确保上报是关的，再把结果原样返回
  Future<CfhubEnableResult> _fail(CfhubEnableResult result) async {
    lastFailureDetail = result == CfhubEnableResult.failed
        ? _effectiveApi.lastFailure
        : null;
    await _setShare(false);
    notifyListeners();
    return result;
  }

  /// 关闭「帮助优选」：作废令牌（尽力而为）、清掉本地记录、关上报
  Future<void> disable({bool revoke = true}) async {
    final token = _token;
    if (revoke && token != null) {
      _pendingRevoke = _effectiveApi.revoke(token);
    }
    await _clearStored();
    await _setShare(false);
    notifyListeners();
  }

  /// 等上一次的作废请求结束（最多几秒，失败也不管），避免它压掉随后发的新令牌
  Future<void> _awaitPendingRevoke() async {
    final pending = _pendingRevoke;
    if (pending == null) return;
    try {
      await pending.timeout(const Duration(seconds: 5));
    } catch (_) {
      // revoke 本来就是尽力而为
    }
    if (identical(_pendingRevoke, pending)) _pendingRevoke = null;
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
    if (_token == null) return;
    final user = _effectiveUserNotifier.value;
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
