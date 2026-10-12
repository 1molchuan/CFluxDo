import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/user.dart';

/// cfluxdo 加速 DoH 的账号令牌
///
/// 登录且信任等级 ≥ 1 时，向加速服务端上报 id / 用户名 / 等级换一个令牌，
/// 之后查询都带 `Authorization: Bearer <令牌>`。游客、TL0 或还没换到令牌时
/// 没有令牌，DoH 自动改用公共 DNSPod。
///
/// 发给加速服务端的只有上面三项和它自己发的令牌，
/// 从不携带 linux.do 的 cookie、_t 或 API key。
/// 会话被动失效不动令牌；只有主动退出登录才作废（[revoke]）。
class AccelDohAuthService {
  AccelDohAuthService._();

  static final AccelDohAuthService instance = AccelDohAuthService._();

  static const String _prefsKey = 'doh_accel_auth';

  /// 能拿到令牌的最低信任等级
  static const int minTrustLevel = 1;

  static const Duration _connectTimeout = Duration(seconds: 5);
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// 服务端没给 expires_in 时按这个有效期算
  static const Duration _defaultLifetime = Duration(hours: 24);

  /// 同一个令牌被拒后，至少隔这么久才再处理一次
  static const Duration _rejectCooldown = Duration(seconds: 60);

  /// 这段时间内被拒超过 [_maxRejectsInWindow] 次就暂停加速
  static const Duration _rejectWindow = Duration(minutes: 10);
  static const int _maxRejectsInWindow = 3;

  /// 服务端拒绝发令牌后，同一账号状态多久内不再申请
  static const Duration _deniedRetryDelay = Duration(hours: 1);

  /// 申请失败（网络/服务端异常）后的重试间隔，逐次拉长
  static const List<Duration> _retryDelays = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  static final RegExp _tokenPattern = RegExp(r'^[\x21-\x7E]{1,4096}$');

  /// 当前可用的令牌；null 表示没有（游客/TL0/过期/未申请到）
  final ValueNotifier<String?> tokenNotifier = ValueNotifier(null);

  SharedPreferences? _prefs;
  Uri? _baseUri;
  List<String> _bootstrapIps = const [];
  _AccelDohToken? _stored;

  /// 最近一次拿到的登录用户；主动退出后清空
  User? _user;

  /// 主动退出时自增，用来丢弃退出前发出、退出后才返回的申请结果
  int _epoch = 0;

  Future<void>? _inflight;

  /// 同步进行中又有新的触发（换号/退出后重新登录），结束后再跑一次
  bool _resyncRequested = false;
  Timer? _refreshTimer;
  Timer? _expiryTimer;
  Timer? _retryTimer;
  int _failures = 0;
  DateTime? _nextAttemptAt;
  String? _lastAttemptKey;
  DateTime? _lastRejectAt;
  DateTime? _rejectWindowStart;
  int _rejectCount = 0;

  String? get token => tokenNotifier.value;

  /// [serverUrl] 是本机的加速 DoH 地址，申请/作废令牌走同一个域名
  void initialize(
    SharedPreferences prefs, {
    required String serverUrl,
    required List<String> bootstrapIps,
  }) {
    if (_prefs != null) return;
    _prefs = prefs;
    final uri = Uri.parse(serverUrl);
    _baseUri = Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    _bootstrapIps = bootstrapIps;
    _stored = _AccelDohToken.decode(prefs.getString(_prefsKey));
    _publish();
    if (_user != null) {
      unawaited(_sync());
    }
  }

  /// 登录用户信息有变化时调用（DiscourseService.currentUserNotifier）
  void onUserChanged(User? user) {
    // 会话失效时也会变成 null，这里不动令牌；主动退出走 revoke()
    if (user == null) return;
    _user = user;
    if (_prefs == null) return;
    unawaited(_sync());
  }

  /// 回到前台等时机主动检查一次：过期了就改用公共 DoH，快到期就续期
  void checkNow() {
    if (_prefs == null) return;
    _publish();
    unawaited(_sync());
  }

  /// 加速服务端拒绝了当前令牌（401/403）：先换一个，换不到就丢掉改走公共 DoH
  Future<void> handleRejected() async {
    if (_prefs == null || _stored == null) return;
    final now = DateTime.now();
    final last = _lastRejectAt;
    if (last != null && now.difference(last) < _rejectCooldown) return;
    _lastRejectAt = now;

    final windowStart = _rejectWindowStart;
    if (windowStart == null || now.difference(windowStart) > _rejectWindow) {
      _rejectWindowStart = now;
      _rejectCount = 0;
    }
    _rejectCount++;
    if (_rejectCount > _maxRejectsInWindow) {
      // 新令牌也接连被拒，多半是服务端出了问题：先改走公共 DoH，过一阵再申请
      debugPrint('[DOH] 加速令牌接连被拒，暂停使用加速');
      _nextAttemptAt = now.add(_retryDelays.last);
      final user = _user;
      _lastAttemptKey = user == null ? null : _attemptKeyOf(user);
      _retryTimer?.cancel();
      _retryTimer = Timer(_retryDelays.last, () => unawaited(_sync()));
      await _clear();
      return;
    }

    debugPrint('[DOH] 加速令牌被服务端拒绝，重新申请');
    await _sync(force: true, dropOnFailure: true);
  }

  /// 主动退出登录：作废令牌并改回公共 DoH
  Future<void> revoke() async {
    _epoch++;
    _user = null;
    _failures = 0;
    _nextAttemptAt = null;
    _lastAttemptKey = null;
    _rejectWindowStart = null;
    _rejectCount = 0;
    _retryTimer?.cancel();
    final stored = _stored;
    await _clear();
    if (stored != null) {
      unawaited(_revokeRemote(stored.token));
    }
  }

  Future<void> _sync({bool force = false, bool dropOnFailure = false}) {
    final running = _inflight;
    if (running != null) {
      _resyncRequested = true;
      return running;
    }
    final future = _doSync(force: force, dropOnFailure: dropOnFailure)
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

  Future<void> _doSync({
    required bool force,
    required bool dropOnFailure,
  }) async {
    final epoch = _epoch;
    final user = _user;
    final stored = _stored;
    if (user == null) {
      // 不知道是谁（启动早期或会话已失效）：没法续期，被拒时只能丢掉
      if (dropOnFailure && stored != null) await _clear();
      return;
    }

    if (user.trustLevel < minTrustLevel) {
      if (stored != null) {
        debugPrint('[DOH] 当前账号等级不足，停用加速令牌');
        await _clear();
      }
      return;
    }

    final sameAccount = stored?.userId == user.id;
    final upToDate =
        stored != null &&
        sameAccount &&
        stored.username == user.username &&
        stored.trustLevel == user.trustLevel &&
        !stored.shouldRefresh;
    if (!force && upToDate) {
      _scheduleRefresh();
      return;
    }

    // 账号状态没变且还在退避期内就先不申请
    final attemptKey = _attemptKeyOf(user);
    final nextAttemptAt = _nextAttemptAt;
    if (!force &&
        attemptKey == _lastAttemptKey &&
        nextAttemptAt != null &&
        DateTime.now().isBefore(nextAttemptAt)) {
      return;
    }
    _lastAttemptKey = attemptKey;

    final result = await _requestToken(user);
    if (epoch != _epoch) return;

    switch (result.outcome) {
      case _RequestOutcome.issued:
        _failures = 0;
        _nextAttemptAt = null;
        _retryTimer?.cancel();
        await _save(result.token!);
        if (stored != null && !sameAccount) {
          unawaited(_revokeRemote(stored.token));
        }
      case _RequestOutcome.denied:
        _failures = 0;
        _nextAttemptAt = DateTime.now().add(_deniedRetryDelay);
        if (stored != null) await _clear();
      case _RequestOutcome.failed:
        final delay = _retryDelays[_failures.clamp(0, _retryDelays.length - 1)];
        _failures++;
        _nextAttemptAt = DateTime.now().add(delay);
        _retryTimer?.cancel();
        _retryTimer = Timer(delay, () => unawaited(_sync()));
        // 别人的令牌或已被拒的令牌不能留着
        if (stored != null && (dropOnFailure || !sameAccount)) {
          await _clear();
        }
    }
  }

  static String _attemptKeyOf(User user) =>
      '${user.id}|${user.username}|${user.trustLevel}';

  Future<_RequestResult> _requestToken(User user) async {
    final baseUri = _baseUri;
    if (baseUri == null) return const _RequestResult(_RequestOutcome.failed);
    final client = _createClient();
    try {
      final request = await client
          .postUrl(baseUri.replace(path: '/v1/token'))
          .timeout(_requestTimeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'user_id': user.id,
          'username': user.username,
          'trust_level': user.trustLevel,
        }),
      );
      final response = await request.close().timeout(_requestTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      final status = response.statusCode;
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        debugPrint('[DOH] 加速服务端拒绝发放令牌: HTTP $status');
        return const _RequestResult(_RequestOutcome.denied);
      }
      if (status != HttpStatus.ok) {
        debugPrint('[DOH] 申请加速令牌失败: HTTP $status');
        return const _RequestResult(_RequestOutcome.failed);
      }

      final json = jsonDecode(body);
      final token = json is Map ? json['token'] : null;
      if (token is! String || !_tokenPattern.hasMatch(token)) {
        debugPrint('[DOH] 加速令牌格式不对，忽略');
        return const _RequestResult(_RequestOutcome.failed);
      }
      final expiresIn = json['expires_in'];
      final lifetime = expiresIn is num && expiresIn > 0
          ? Duration(seconds: expiresIn.toInt())
          : _defaultLifetime;
      final issuedAt = DateTime.now();
      debugPrint('[DOH] 已拿到加速令牌，有效期 ${lifetime.inMinutes} 分钟');
      return _RequestResult(
        _RequestOutcome.issued,
        _AccelDohToken(
          token: token,
          userId: user.id,
          username: user.username,
          trustLevel: user.trustLevel,
          issuedAt: issuedAt,
          expiresAt: issuedAt.add(lifetime),
        ),
      );
    } catch (e) {
      debugPrint('[DOH] 申请加速令牌失败: $e');
      return const _RequestResult(_RequestOutcome.failed);
    } finally {
      client.close(force: true);
    }
  }

  /// 通知服务端作废令牌，尽力而为，失败不影响本地
  Future<void> _revokeRemote(String token) async {
    final baseUri = _baseUri;
    if (baseUri == null) return;
    final client = _createClient();
    try {
      final request = await client
          .postUrl(baseUri.replace(path: '/v1/token/revoke'))
          .timeout(_requestTimeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>().timeout(_requestTimeout);
    } catch (e) {
      debugPrint('[DOH] 作废加速令牌失败(忽略): $e');
    } finally {
      client.close(force: true);
    }
  }

  /// 独立的 HttpClient：不走 App 的 Dio，不会带上 linux.do 的 cookie
  HttpClient _createClient() {
    final bootstrapIps = _bootstrapIps;
    return HttpClient()
      ..connectionTimeout = _connectTimeout
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) async =>
          ConnectionTask.fromSocket(
            _connectSecure(uri.host, uri.port, bootstrapIps),
            () {},
          );
  }

  /// 先按系统 DNS 连；解析不出或连不上时直连加速节点 IP（SNI 仍是加速域名）
  static Future<Socket> _connectSecure(
    String host,
    int port,
    List<String> bootstrapIps,
  ) async {
    final targets = <Object>[
      host,
      ...bootstrapIps
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>(),
    ];
    Object? lastError;
    for (final target in targets) {
      Socket? raw;
      try {
        raw = await Socket.connect(target, port, timeout: _connectTimeout);
        return await SecureSocket.secure(
          raw,
          host: host,
        ).timeout(_connectTimeout);
      } catch (e) {
        raw?.destroy();
        lastError = e;
      }
    }
    throw lastError ?? SocketException('无法连接 $host');
  }

  Future<void> _save(_AccelDohToken value) async {
    _stored = value;
    await _prefs?.setString(_prefsKey, value.encode());
    _publish();
  }

  Future<void> _clear() async {
    _stored = null;
    await _prefs?.remove(_prefsKey);
    _publish();
  }

  /// 按当前存的令牌刷新对外状态，并安排过期/续期定时器
  void _publish() {
    _expiryTimer?.cancel();
    final stored = _stored;
    final now = DateTime.now();
    final valid = stored != null && stored.expiresAt.isAfter(now);
    tokenNotifier.value = valid ? stored.token : null;
    if (valid) {
      _expiryTimer = Timer(stored.expiresAt.difference(now), _publish);
    }
    _scheduleRefresh();
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

enum _RequestOutcome { issued, denied, failed }

class _RequestResult {
  const _RequestResult(this.outcome, [this.token]);

  final _RequestOutcome outcome;
  final _AccelDohToken? token;
}

class _AccelDohToken {
  const _AccelDohToken({
    required this.token,
    required this.userId,
    required this.username,
    required this.trustLevel,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String token;
  final int userId;
  final String username;
  final int trustLevel;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// 有效期过半就续期
  DateTime get refreshAt => issuedAt.add(expiresAt.difference(issuedAt) ~/ 2);

  bool get shouldRefresh => !DateTime.now().isBefore(refreshAt);

  String encode() => jsonEncode({
    'token': token,
    'user_id': userId,
    'username': username,
    'trust_level': trustLevel,
    'issued_at': issuedAt.millisecondsSinceEpoch,
    'expires_at': expiresAt.millisecondsSinceEpoch,
  });

  static _AccelDohToken? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['token'];
      final userId = json['user_id'];
      final username = json['username'];
      final trustLevel = json['trust_level'];
      final issuedAt = json['issued_at'];
      final expiresAt = json['expires_at'];
      if (token is! String ||
          userId is! int ||
          username is! String ||
          trustLevel is! int ||
          issuedAt is! int ||
          expiresAt is! int) {
        return null;
      }
      return _AccelDohToken(
        token: token,
        userId: userId,
        username: username,
        trustLevel: trustLevel,
        issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAt),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      );
    } catch (_) {
      return null;
    }
  }
}
