import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/user.dart';
import '../../../pages/network_settings_page/widgets/cf_select_privacy_dialog.dart';
import 'accel_doh_api.dart';
import 'accel_doh_connect_flow.dart';
import 'network_settings_service.dart';

/// 加速 DoH 当前处在哪一档
enum AccelDohAuthStatus {
  /// 有专属令牌，走 cfluxdo 加速
  ready,

  /// 游客或信任等级不足，拿不到令牌，走公共加速
  notEligible,

  /// 还没授权 Connect（没问过或选了暂不），走公共加速
  notAuthorized,

  /// 这个账号用不了 Connect（如青春版），走公共加速
  unavailable,

  /// 加速服务端拒绝给这个账号发令牌，走公共加速
  denied,

  /// 刚授权不久令牌就被收回（多半是同一账号设备超过上限被挤掉），
  /// 走公共加速，等离上次授权满 6 小时再自动重新授权
  displaced,

  /// 正在授权或等网络恢复后重试，走公共加速
  pending,
}

/// cfluxdo 加速 DoH 的账号令牌
///
/// 登录且信任等级 ≥ 1 的账号经用户同意后，在 App 里走一遍 LinuxDo Connect
/// 授权，把回调里的 code/state 交给加速服务端；服务端去 Connect 核验身份后
/// 发一个令牌，之后查询都带 `Authorization: Bearer <令牌>`。
///
/// 没有令牌时一律走公共加速：登录且等级 ≥ 1 但没授权的、青春版等用不了 Connect 的账号，
/// 以及游客/TL0（国内公共 DoH 对 linux.do 的应答已被污染，游客不能落到 DNSPod）。
///
/// 发给加速服务端的只有 code/state 和它自己发的令牌，
/// 从不携带 linux.do 的 cookie、_t 或 API key。
/// 会话被动失效不动令牌；只有主动退出登录才作废（[revoke]）。
class AccelDohAuthService extends ChangeNotifier {
  AccelDohAuthService._();

  static final AccelDohAuthService instance = AccelDohAuthService._();

  static const String _tokenKey = 'doh_accel_token';
  static const String _memberKey = 'doh_accel_member';
  static const String _consentKey = 'doh_accel_consent';
  static const String _backoffKey = 'doh_accel_backoff';
  static const String _lastConnectKey = 'doh_accel_last_connect';

  /// 0.2.28.3 测试版自报身份时用的键，已废弃
  static const String _legacyTokenKey = 'doh_accel_auth';

  /// 能用加速的最低信任等级
  static const int minTrustLevel = 1;

  /// 同一个令牌被拒后，至少隔这么久才再处理一次
  @visibleForTesting
  Duration rejectCooldown = const Duration(seconds: 60);

  /// 这段时间内被拒超过 [_maxRejectsInWindow] 次就暂停加速
  static const Duration _rejectWindow = Duration(minutes: 10);
  static const int _maxRejectsInWindow = 3;

  /// 服务端拒绝发令牌后，同一账号同一等级多久内不再申请
  static const Duration _deniedRetryDelay = Duration(hours: 6);

  /// 账号用不了 Connect 时多久后再试
  static const Duration _unavailableRetryDelay = Duration(hours: 24);

  /// 两次自动 Connect 授权之间至少隔这么久。服务端每个账号只留 3 台设备，
  /// 第 4 台授权会挤掉最早那台；被挤掉的马上重新授权又会挤掉别的，几台设备会来回互踢
  static const Duration _reconnectInterval = Duration(hours: 6);

  /// 网络/服务端异常后的重试间隔，逐次拉长
  static const List<Duration> _retryDelays = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  /// 拿到登录用户后隔多久再弹授权说明，避开启动时的一堆弹窗
  @visibleForTesting
  Duration consentPromptDelay = const Duration(seconds: 5);

  @visibleForTesting
  AccelDohApi? debugApi;

  @visibleForTesting
  AccelDohConnectFlow? debugConnectFlow;

  SharedPreferences? _prefs;
  AccelDohApi? _defaultApi;
  AccelDohConnectFlow? _defaultFlow;
  _AccelDohToken? _stored;
  String? _token;
  bool _member = false;
  _AccelDohConsent? _consent;
  _AccelDohBackoff? _backoff;

  /// 最近一次 Connect 授权成功是哪个账号、什么时候
  _AccelDohLastConnect? _lastConnect;

  /// 最近一次拿到的登录用户；主动退出后清空
  User? _user;

  /// 主动退出时自增，用来丢弃退出前发出、退出后才返回的结果
  int _epoch = 0;

  Future<void>? _inflight;

  /// 同步进行中又有新的触发（换号/退出后重新登录），结束后再跑一次
  bool _resyncRequested = false;
  bool _connecting = false;
  Timer? _refreshTimer;
  Timer? _expiryTimer;
  Timer? _retryTimer;
  Timer? _consentPromptTimer;
  bool _consentPromptShowing = false;
  int _failures = 0;
  DateTime? _nextAttemptAt;
  DateTime? _lastRejectAt;
  DateTime? _rejectWindowStart;
  int _rejectCount = 0;

  AccelDohApi get _api => debugApi ?? _defaultApi!;

  AccelDohConnectFlow get _flow =>
      debugConnectFlow ?? (_defaultFlow ??= AccelDohConnectFlow());

  /// 当前可用的令牌；null 表示没有
  String? get token => _token;

  /// 登录且等级 ≥ 1（冷启动还没拿到用户时按上次记下的算）
  bool get isMember => _member || _stored != null;

  AccelDohAuthStatus get status {
    if (_token != null) return AccelDohAuthStatus.ready;
    if (!isMember) return AccelDohAuthStatus.notEligible;
    if (_connecting) return AccelDohAuthStatus.pending;
    final user = _user;
    final backoff = _activeBackoff(user);
    if (backoff != null) {
      return switch (backoff.reason) {
        _BackoffReason.denied => AccelDohAuthStatus.denied,
        _BackoffReason.unavailable => AccelDohAuthStatus.unavailable,
        _BackoffReason.displaced => AccelDohAuthStatus.displaced,
      };
    }
    final consent = user == null ? _consent?.granted : _consentFor(user);
    if (consent != true) return AccelDohAuthStatus.notAuthorized;
    return AccelDohAuthStatus.pending;
  }

  /// [serverUrl] 是本机的加速 DoH 地址，令牌接口走同一个域名
  void initialize(
    SharedPreferences prefs, {
    required String serverUrl,
    required List<String> bootstrapIps,
  }) {
    if (_prefs != null) return;
    _prefs = prefs;
    _defaultApi = AccelDohApi(serverUrl: serverUrl, bootstrapIps: bootstrapIps);
    unawaited(prefs.remove(_legacyTokenKey));
    _stored = _AccelDohToken.decode(prefs.getString(_tokenKey));
    _member = prefs.getBool(_memberKey) ?? false;
    _consent = _AccelDohConsent.decode(prefs.getString(_consentKey));
    _backoff = _AccelDohBackoff.decode(prefs.getString(_backoffKey));
    _lastConnect = _AccelDohLastConnect.decode(
      prefs.getString(_lastConnectKey),
    );
    _publish();
    if (_user != null) {
      unawaited(_sync());
    }
  }

  /// 登录用户信息有变化时调用（DiscourseService.currentUserNotifier）
  void onUserChanged(User? user) {
    // 会话失效时也会变成 null，这里不动令牌；主动退出走 revoke()
    if (user == null) return;
    final previous = _user;
    _user = user;
    if (previous != null && previous.id != user.id) {
      _resetRetry();
    }
    if (_prefs == null) return;
    unawaited(_sync());
  }

  /// 回到前台等时机主动检查一次：过期了就降档，快到期就续期
  void checkNow() {
    if (_prefs == null) return;
    _publish();
    unawaited(_sync());
  }

  /// 用户在设置里点了「用 L 站 Connect 授权」：没同意过就先弹说明，然后立即授权
  Future<AccelDohAuthStatus> authorizeNow() async {
    final user = _user;
    if (_prefs == null || user == null || user.trustLevel < minTrustLevel) {
      return status;
    }
    if (_consentFor(user) != true) {
      final answer = await _flow.askConsent();
      if (answer == null || _user?.id != user.id) return status;
      await _setConsent(user, answer);
      if (!answer) return status;
    }
    while (_inflight != null) {
      await _inflight;
    }
    await _sync(force: true, interactive: true);
    return status;
  }

  /// 加速服务端拒绝了当前令牌（401/403）：先降到公共加速，再重新走 Connect
  Future<void> handleRejected() async {
    if (_prefs == null || _stored == null) return;
    final now = DateTime.now();
    final last = _lastRejectAt;
    if (last != null && now.difference(last) < rejectCooldown) return;
    _lastRejectAt = now;

    final windowStart = _rejectWindowStart;
    if (windowStart == null || now.difference(windowStart) > _rejectWindow) {
      _rejectWindowStart = now;
      _rejectCount = 0;
    }
    _rejectCount++;
    await _clearToken();
    if (_rejectCount > _maxRejectsInWindow) {
      // 新令牌也接连被拒，多半是服务端出了问题：先用公共加速，过一阵再申请
      debugPrint('[DOH] 加速令牌接连被拒，暂停申请');
      _failures = _retryDelays.length - 1;
      _scheduleRetry();
      return;
    }

    debugPrint('[DOH] 加速令牌被服务端拒绝，重新走 Connect');
    await _sync(force: true);
  }

  /// 主动退出登录：作废令牌，清掉授权记录，改回 DNSPod
  Future<void> revoke() async {
    _epoch++;
    _user = null;
    _resetRetry();
    _rejectWindowStart = null;
    _rejectCount = 0;
    _consentPromptTimer?.cancel();
    _consentPromptTimer = null;
    final stored = _stored;
    final prefs = _prefs;
    _member = false;
    _consent = null;
    _backoff = null;
    await prefs?.remove(_memberKey);
    await prefs?.remove(_consentKey);
    await prefs?.remove(_backoffKey);
    await _clearLastConnect();
    await _clearToken();
    if (stored != null && prefs != null) {
      unawaited(_api.revoke(stored.token));
    }
  }

  Future<void> _sync({bool force = false, bool interactive = false}) {
    final running = _inflight;
    if (running != null) {
      _resyncRequested = true;
      return running;
    }
    final future = _doSync(force: force, interactive: interactive)
        .catchError((Object e) {
          debugPrint('[DOH] 加速令牌同步异常: $e');
        })
        .whenComplete(() {
          _inflight = null;
          if (_resyncRequested) {
            _resyncRequested = false;
            unawaited(_sync());
          }
        });
    _inflight = future;
    return future;
  }

  Future<void> _doSync({required bool force, required bool interactive}) async {
    final epoch = _epoch;
    final user = _user;
    // 不知道是谁（启动早期或会话已失效）：保持现状
    if (user == null) return;

    if (user.trustLevel < minTrustLevel) {
      await _setMember(false);
      await _clearLastConnect();
      final stored = _stored;
      if (stored != null) {
        debugPrint('[DOH] 当前账号等级不足，停用加速令牌');
        await _clearToken();
        unawaited(_api.revoke(stored.token));
      }
      return;
    }
    await _setMember(true);

    var stored = _stored;
    if (stored != null && stored.userId != user.id) {
      // 换了账号：旧账号的令牌马上作废
      await _clearToken();
      unawaited(_api.revoke(stored.token));
      stored = null;
    }

    if (stored != null && stored.isValid) {
      if (!force && !stored.shouldRefresh) {
        _scheduleRefresh();
        return;
      }
      if (!force && _inRetryBackoff) return;
      final result = await _api.refresh(stored.token);
      if (epoch != _epoch) return;
      switch (result.outcome) {
        case AccelDohIssueOutcome.issued:
          _resetRetry();
          await _saveToken(user.id, result);
          return;
        case AccelDohIssueOutcome.failed:
          // 令牌还没过期，先接着用
          _scheduleRetry();
          return;
        case AccelDohIssueOutcome.rejected:
          // 续不了，下面重新走 Connect
          await _clearToken();
      }
    } else if (stored != null) {
      await _clearToken();
    }

    final consent = _consentFor(user);
    if (consent == false && !interactive) return;
    if (!interactive) {
      final backoff = _activeBackoff(user);
      if (backoff != null) {
        // 重启 App 后冷却记录还在，到点要接着试
        _scheduleSyncAt(backoff.until);
        return;
      }
    }
    if (!force && !interactive && _inRetryBackoff) return;
    if (consent == null) {
      _scheduleConsentPrompt();
      return;
    }
    if (!interactive) {
      // 刚授权不久又要重新授权，多半是被同账号的其他设备挤掉了，先别抢回来
      final last = _lastConnectFor(user);
      final until = last?.add(_reconnectInterval);
      if (until != null && DateTime.now().isBefore(until)) {
        debugPrint('[DOH] 距上次 Connect 授权不到 6 小时，先用公共加速');
        await _setBackoff(user, _BackoffReason.displaced, until: until);
        return;
      }
    }
    await _connect(user, epoch, interactive: interactive);
  }

  /// 走一遍 Connect 授权换令牌
  Future<void> _connect(
    User user,
    int epoch, {
    required bool interactive,
  }) async {
    _connecting = true;
    notifyListeners();
    try {
      final authorizeUrl = await _api.startConnect();
      if (epoch != _epoch) return;
      if (authorizeUrl == null) {
        _scheduleRetry();
        return;
      }

      final connect = await _flow.fetchCode(authorizeUrl, silent: !interactive);
      if (epoch != _epoch || _user?.id != user.id) return;
      switch (connect.outcome) {
        case AccelDohConnectOutcome.failed:
          _scheduleRetry();
          return;
        case AccelDohConnectOutcome.unavailable:
          debugPrint('[DOH] 此账号用不了 Connect，使用公共加速');
          await _setBackoff(user, _BackoffReason.unavailable);
          return;
        case AccelDohConnectOutcome.code:
          break;
      }

      final result = await _api.exchangeCode(
        code: connect.code!,
        state: connect.state!,
      );
      if (epoch != _epoch || _user?.id != user.id) {
        // 等结果期间退出或换了号，这个令牌不能留
        final token = result.token;
        if (token != null) unawaited(_api.revoke(token));
        return;
      }
      switch (result.outcome) {
        case AccelDohIssueOutcome.issued:
          _resetRetry();
          await _clearBackoff();
          await _setLastConnect(user);
          await _saveToken(user.id, result);
        case AccelDohIssueOutcome.rejected:
          debugPrint('[DOH] 加速服务端拒绝了此账号，使用公共加速');
          await _setBackoff(user, _BackoffReason.denied);
        case AccelDohIssueOutcome.failed:
          _scheduleRetry();
      }
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// 没同意过的账号，过一会儿弹一次授权说明；现在弹不了就等下次检查
  void _scheduleConsentPrompt() {
    if (_consentPromptTimer != null || _consentPromptShowing) return;
    _consentPromptTimer = Timer(consentPromptDelay, () async {
      _consentPromptTimer = null;
      // 本地优选的隐私说明正在显示：不叠弹，推后再查
      if (CfSelectPrivacyDialog.isShowing) {
        _scheduleConsentPrompt();
        return;
      }
      // 1.1 起本地优选是一等连接方式：已经选出赢家就不自动弹专属加速的
      // Connect 授权（菜单里手动授权不受影响）
      if (NetworkSettingsService.instance.selectorHasWinner) return;
      final user = _user;
      if (user == null ||
          user.trustLevel < minTrustLevel ||
          _token != null ||
          _consentFor(user) != null) {
        return;
      }
      _consentPromptShowing = true;
      bool? answer;
      try {
        answer = await _flow.askConsent();
      } catch (e) {
        debugPrint('[DOH] 弹出加速授权说明失败: $e');
      } finally {
        _consentPromptShowing = false;
      }
      if (answer == null || _user?.id != user.id) return;
      await _setConsent(user, answer);
      if (answer) unawaited(_sync());
    });
  }

  bool? _consentFor(User user) {
    final consent = _consent;
    if (consent == null || consent.userId != user.id) return null;
    return consent.granted;
  }

  Future<void> _setConsent(User user, bool granted) async {
    final consent = _AccelDohConsent(userId: user.id, granted: granted);
    _consent = consent;
    await _prefs?.setString(_consentKey, consent.encode());
    notifyListeners();
  }

  Future<void> _setMember(bool value) async {
    if (_member == value) return;
    _member = value;
    if (value) {
      await _prefs?.setBool(_memberKey, true);
    } else {
      await _prefs?.remove(_memberKey);
    }
    notifyListeners();
  }

  /// 当前账号还在拒绝/不可用的冷却期内就返回那条记录
  _AccelDohBackoff? _activeBackoff(User? user) {
    final backoff = _backoff;
    if (backoff == null || !DateTime.now().isBefore(backoff.until)) {
      return null;
    }
    if (user != null && backoff.key != _backoffKeyOf(user)) return null;
    return backoff;
  }

  /// 没给 [until] 时按原因取默认冷却时长
  Future<void> _setBackoff(
    User user,
    _BackoffReason reason, {
    DateTime? until,
  }) async {
    final backoff = _AccelDohBackoff(
      key: _backoffKeyOf(user),
      reason: reason,
      until:
          until ??
          DateTime.now().add(
            reason == _BackoffReason.denied
                ? _deniedRetryDelay
                : _unavailableRetryDelay,
          ),
    );
    _backoff = backoff;
    await _prefs?.setString(_backoffKey, backoff.encode());
    _scheduleSyncAt(backoff.until);
    notifyListeners();
  }

  /// 多等 1 秒，免得定时器提前一点点触发时还在冷却期内
  void _scheduleSyncAt(DateTime at) {
    _retryTimer?.cancel();
    _retryTimer = Timer(
      at.difference(DateTime.now()) + const Duration(seconds: 1),
      () => unawaited(_sync()),
    );
  }

  DateTime? _lastConnectFor(User user) {
    final last = _lastConnect;
    if (last == null || last.userId != user.id) return null;
    return last.at;
  }

  Future<void> _setLastConnect(User user) async {
    final last = _AccelDohLastConnect(userId: user.id, at: DateTime.now());
    _lastConnect = last;
    await _prefs?.setString(_lastConnectKey, last.encode());
  }

  Future<void> _clearLastConnect() async {
    if (_lastConnect == null) return;
    _lastConnect = null;
    await _prefs?.remove(_lastConnectKey);
  }

  Future<void> _clearBackoff() async {
    if (_backoff == null) return;
    _backoff = null;
    await _prefs?.remove(_backoffKey);
  }

  /// 等级变了就重新判断，不沿用之前的拒绝记录
  static String _backoffKeyOf(User user) => '${user.id}|${user.trustLevel}';

  bool get _inRetryBackoff {
    final next = _nextAttemptAt;
    return next != null && DateTime.now().isBefore(next);
  }

  void _scheduleRetry() {
    final delay = _retryDelays[_failures.clamp(0, _retryDelays.length - 1)];
    _failures++;
    _nextAttemptAt = DateTime.now().add(delay);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(_sync()));
  }

  void _resetRetry() {
    _failures = 0;
    _nextAttemptAt = null;
    _retryTimer?.cancel();
  }

  Future<void> _saveToken(int userId, AccelDohIssueResult result) async {
    final issuedAt = DateTime.now();
    final value = _AccelDohToken(
      token: result.token!,
      userId: userId,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(result.lifetime!),
    );
    _stored = value;
    await _prefs?.setString(_tokenKey, value.encode());
    _publish();
  }

  Future<void> _clearToken() async {
    if (_stored == null && _token == null) return;
    _stored = null;
    await _prefs?.remove(_tokenKey);
    _publish();
  }

  /// 按当前存的令牌刷新对外状态，并安排过期/续期定时器
  void _publish() {
    _expiryTimer?.cancel();
    final stored = _stored;
    final valid = stored != null && stored.isValid;
    _token = valid ? stored.token : null;
    if (valid) {
      _expiryTimer = Timer(
        stored.expiresAt.difference(DateTime.now()),
        _publish,
      );
    }
    _scheduleRefresh();
    notifyListeners();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final stored = _stored;
    if (stored == null) return;
    final delay = stored.refreshAt.difference(DateTime.now());
    if (delay.isNegative) return;
    _refreshTimer = Timer(delay, () => unawaited(_sync()));
  }
}

class _AccelDohToken {
  const _AccelDohToken({
    required this.token,
    required this.userId,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String token;
  final int userId;
  final DateTime issuedAt;
  final DateTime expiresAt;

  bool get isValid => expiresAt.isAfter(DateTime.now());

  /// 有效期过半就续期
  DateTime get refreshAt => issuedAt.add(expiresAt.difference(issuedAt) ~/ 2);

  bool get shouldRefresh => !DateTime.now().isBefore(refreshAt);

  String encode() => jsonEncode({
    'token': token,
    'user_id': userId,
    'issued_at': issuedAt.millisecondsSinceEpoch,
    'expires_at': expiresAt.millisecondsSinceEpoch,
  });

  static _AccelDohToken? decode(String? raw) {
    final json = _decodeMap(raw);
    if (json == null) return null;
    final token = json['token'];
    final userId = json['user_id'];
    final issuedAt = json['issued_at'];
    final expiresAt = json['expires_at'];
    if (token is! String ||
        userId is! int ||
        issuedAt is! int ||
        expiresAt is! int) {
      return null;
    }
    return _AccelDohToken(
      token: token,
      userId: userId,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAt),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }
}

/// 用户对 Connect 授权的选择，按账号记
class _AccelDohConsent {
  const _AccelDohConsent({required this.userId, required this.granted});

  final int userId;
  final bool granted;

  String encode() => jsonEncode({'user_id': userId, 'granted': granted});

  static _AccelDohConsent? decode(String? raw) {
    final json = _decodeMap(raw);
    if (json == null) return null;
    final userId = json['user_id'];
    final granted = json['granted'];
    if (userId is! int || granted is! bool) return null;
    return _AccelDohConsent(userId: userId, granted: granted);
  }
}

/// 最近一次 Connect 授权成功的记录，用来限制自动重新授权的频率
class _AccelDohLastConnect {
  const _AccelDohLastConnect({required this.userId, required this.at});

  final int userId;
  final DateTime at;

  String encode() =>
      jsonEncode({'user_id': userId, 'at': at.millisecondsSinceEpoch});

  static _AccelDohLastConnect? decode(String? raw) {
    final json = _decodeMap(raw);
    if (json == null) return null;
    final userId = json['user_id'];
    final at = json['at'];
    if (userId is! int || at is! int) return null;
    return _AccelDohLastConnect(
      userId: userId,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

enum _BackoffReason { denied, unavailable, displaced }

/// 被拒/用不了 Connect/被挤掉的冷却记录，重启 App 后仍然有效
class _AccelDohBackoff {
  const _AccelDohBackoff({
    required this.key,
    required this.reason,
    required this.until,
  });

  final String key;
  final _BackoffReason reason;
  final DateTime until;

  String encode() => jsonEncode({
    'key': key,
    'reason': reason.name,
    'until': until.millisecondsSinceEpoch,
  });

  static _AccelDohBackoff? decode(String? raw) {
    final json = _decodeMap(raw);
    if (json == null) return null;
    final key = json['key'];
    final reason = _BackoffReason.values.asNameMap()[json['reason']];
    final until = json['until'];
    if (key is! String || reason == null || until is! int) return null;
    return _AccelDohBackoff(
      key: key,
      reason: reason,
      until: DateTime.fromMillisecondsSinceEpoch(until),
    );
  }
}

Map<String, Object?>? _decodeMap(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final json = jsonDecode(raw);
    return json is Map<String, Object?> ? json : null;
  } catch (_) {
    return null;
  }
}
