part of 'discourse_service.dart';

/// 认证相关
mixin _AuthMixin on _DiscourseServiceBase {
  // --- 保守登出复检机制 ---
  // 收到 discourse-logged-out 等信号后，不立即登出，而是累积 strike 并通过
  // probe（GET /session/current.json）做二次验证，避免瞬时 cookie 传输问题
  // 或 token rotation 窗口导致的误判。
  static const Duration _strikeWindow = Duration(seconds: 45);
  static const Duration _inconclusiveCooldown = Duration(seconds: 30);
  static const Duration _candidateProbeFailureCooldown = Duration(minutes: 5);
  static const Duration _previousTTokenFallbackTtl = Duration(minutes: 15);
  int _authStrikeCount = 0;
  DateTime? _lastStrikeAt;
  DateTime? _lastInconclusiveAt;
  String? _lastRejectedSessionCandidateHash;
  DateTime? _lastRejectedSessionCandidateAt;
  String? _previousTTokenFallback;
  DateTime? _previousTTokenFallbackAt;
  Future<bool?>? _activeProbe;

  void _resetStrikes() {
    _authStrikeCount = 0;
    _lastStrikeAt = null;
    _lastInconclusiveAt = null;
  }

  String? _safeTokenHash(String? token) {
    if (token == null || token.isEmpty) return null;

    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;

    for (final byte in utf8.encode(token)) {
      hash = (hash ^ BigInt.from(byte)) * prime & mask;
    }

    return hash.toRadixString(16).padLeft(16, '0').substring(0, 12);
  }

  int? _tokenLength(String? token) =>
      token != null && token.isNotEmpty ? token.length : null;

  bool _hasTokenValue(String? token) => token != null && token.isNotEmpty;

  bool _isRejectedSessionCandidateInCooldown(String? token) {
    final hash = _safeTokenHash(token);
    final rejectedAt = _lastRejectedSessionCandidateAt;
    if (hash == null ||
        rejectedAt == null ||
        hash != _lastRejectedSessionCandidateHash) {
      return false;
    }
    return DateTime.now().difference(rejectedAt) <=
        _candidateProbeFailureCooldown;
  }

  void _markRejectedSessionCandidate(String? token) {
    final hash = _safeTokenHash(token);
    if (hash == null) return;
    _lastRejectedSessionCandidateHash = hash;
    _lastRejectedSessionCandidateAt = DateTime.now();
  }

  void _clearRejectedSessionCandidate() {
    _lastRejectedSessionCandidateHash = null;
    _lastRejectedSessionCandidateAt = null;
  }

  void _rememberPreviousTTokenFallback(
    String? token, {
    required String reason,
    String? replacementToken,
    RequestOptions? requestOptions,
  }) {
    if (!_hasTokenValue(token) || token == replacementToken) return;

    _previousTTokenFallback = token;
    _previousTTokenFallbackAt = DateTime.now();

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'previous_t_token_fallback_stored',
      'message': '已临时保存上一枚 _t，供登录失效 probe 回退使用',
      'reason': reason,
      'previousTLen': _tokenLength(token),
      'previousTHash': _safeTokenHash(token),
      'replacementTLen': _tokenLength(replacementToken),
      'replacementTHash': _safeTokenHash(replacementToken),
      if (requestOptions != null) 'method': requestOptions.method,
      if (requestOptions != null) 'url': requestOptions.uri.toString(),
    });
  }

  String? _readPreviousTTokenFallback({String? sentTToken, String? jarTToken}) {
    final token = _previousTTokenFallback;
    final storedAt = _previousTTokenFallbackAt;
    if (!_hasTokenValue(token) || storedAt == null) return null;

    if (DateTime.now().difference(storedAt) > _previousTTokenFallbackTtl) {
      _clearPreviousTTokenFallback();
      return null;
    }
    if (token == sentTToken || token == jarTToken) return null;
    return token;
  }

  void _clearPreviousTTokenFallback() {
    _previousTTokenFallback = null;
    _previousTTokenFallbackAt = null;
  }

  bool? _sameNonEmptyToken(String? left, String? right) {
    if (left == null || left.isEmpty || right == null || right.isEmpty) {
      return null;
    }
    return left == right;
  }

  String? _sentTTokenFromRequest(RequestOptions requestOptions) {
    final sentCookieHeader =
        requestOptions.headers[HttpHeaders.cookieHeader]?.toString() ??
        requestOptions.headers['Cookie']?.toString() ??
        '';
    return RegExp(
      r'(?:^|;\s*)_t=([^;]*)',
    ).firstMatch(sentCookieHeader)?.group(1);
  }

  Map<String, dynamic> _sentTDiagnostics(RequestOptions requestOptions) {
    final sentTToken = _sentTTokenFromRequest(requestOptions);
    return {
      'sentHasT': sentTToken != null && sentTToken.isNotEmpty,
      'sentTLen': _tokenLength(sentTToken),
      'sentTHash': _safeTokenHash(sentTToken),
    };
  }

  bool _isAlreadyLoggedOutSignal({String? jarTToken, String? sentTToken}) {
    return !_hasTokenValue(_tToken) &&
        !_hasTokenValue(jarTToken) &&
        !_hasTokenValue(sentTToken);
  }

  void _logAuthSignalSuppressedAlreadyLoggedOut({
    required String source,
    required String triggerInfo,
    int? statusCode,
    String? jarTToken,
    String? sentTToken,
  }) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_signal_suppressed_already_logged_out',
      'message': '本地已无登录态，忽略后续未登录响应',
      'source': source,
      'trigger': triggerInfo,
      'statusCode': statusCode,
      'memHasToken': _hasTokenValue(_tToken),
      'jarHasToken': _hasTokenValue(jarTToken),
      'sentHasT': _hasTokenValue(sentTToken),
    });
  }

  bool _isInCooldown() {
    final last = _lastInconclusiveAt;
    if (last == null) return false;
    return DateTime.now().difference(last) <= _inconclusiveCooldown;
  }

  /// 统一的 auth invalid 信号入口。
  /// [isStrong] 强信号：not_logged_in / 4xx + logged-out（1 次即触发 probe）
  ///           弱信号：2xx + logged-out（需 2 次累积）
  Future<void> _reportAuthSignal({
    required bool isStrong,
    required String source,
    required String triggerInfo,
    required RequestOptions requestOptions,
    int? statusCode,
  }) async {
    if (_isLoggingOut) return;

    final requestGeneration =
        requestOptions.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_signal_suppressed_stale_generation',
        'message': '忽略过期会话请求产生的 auth 信号',
        'source': source,
        'trigger': triggerInfo,
        'statusCode': statusCode,
        'requestGeneration': requestGeneration,
        'currentGeneration': AuthSession().generation,
      });
      return;
    }

    final jarTToken = await _cookieJar.getTToken();
    final sentTToken = _sentTTokenFromRequest(requestOptions);
    if (_isAlreadyLoggedOutSignal(
      jarTToken: jarTToken,
      sentTToken: sentTToken,
    )) {
      _logAuthSignalSuppressedAlreadyLoggedOut(
        source: source,
        triggerInfo: triggerInfo,
        statusCode: statusCode,
        jarTToken: jarTToken,
        sentTToken: sentTToken,
      );
      _resetStrikes();
      return;
    }

    // 冷却期内抑制
    if (_isInCooldown() && !isStrong) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_signal_suppressed_cooldown',
        'message': '处于 inconclusive 冷却期，暂时抑制弱 auth 信号',
        'source': source,
        'trigger': triggerInfo,
      });
      return;
    }

    // probe 进行中，不增加 strike（并发折叠）
    if (_activeProbe != null) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_signal_folded',
        'message': 'probe 进行中，折叠此 auth 信号',
        'source': source,
        'trigger': triggerInfo,
      });
      return;
    }

    // 累加 strike
    final now = DateTime.now();
    if (_lastStrikeAt == null ||
        now.difference(_lastStrikeAt!) > _strikeWindow) {
      _authStrikeCount = 1;
    } else {
      _authStrikeCount += 1;
    }
    _lastStrikeAt = now;

    final threshold = isStrong ? 1 : 2;

    // 记录诊断日志
    LogWriter.instance.write({
      'timestamp': now.toIso8601String(),
      'level': _authStrikeCount >= threshold ? 'warning' : 'info',
      'type': 'auth',
      'event': 'auth_signal_reported',
      'message': _authStrikeCount >= threshold
          ? 'auth 信号达到阈值，准备执行 session probe'
          : 'auth 信号已记录，等待后续信号确认',
      'source': source,
      'trigger': triggerInfo,
      'isStrong': isStrong,
      'strike': _authStrikeCount,
      'threshold': threshold,
      'statusCode': statusCode,
      'memHasToken': _tToken != null && _tToken!.isNotEmpty,
      'memTLen': _tokenLength(_tToken),
      'memTHash': _safeTokenHash(_tToken),
      'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
      'jarTLen': _tokenLength(jarTToken),
      'jarTHash': _safeTokenHash(jarTToken),
      'sentHasT': sentTToken != null && sentTToken.isNotEmpty,
      'sentTLen': _tokenLength(sentTToken),
      'sentTHash': _safeTokenHash(sentTToken),
      'sentMatchesJarT': _sameNonEmptyToken(sentTToken, jarTToken),
      'sentMatchesMemT': _sameNonEmptyToken(sentTToken, _tToken),
    });

    if (_authStrikeCount >= threshold) {
      if (requestGeneration != null &&
          !AuthSession().isValid(requestGeneration)) {
        return;
      }
      await _probeSession(
        source: source,
        triggerInfo: triggerInfo,
        signalRequestOptions: requestOptions,
      );
    }
  }

  /// 通过 GET /session/current.json 验证会话是否仍然有效。
  /// 返回值：true=有效, false=确认失效, null=无法判断
  Future<bool?> _probeSession({
    required String source,
    String? triggerInfo,
    RequestOptions? signalRequestOptions,
  }) {
    final inFlight = _activeProbe;
    if (inFlight != null) return inFlight;

    final future = _probeSessionImpl(
      source: source,
      triggerInfo: triggerInfo,
      signalRequestOptions: signalRequestOptions,
    );
    _activeProbe = future;
    future.whenComplete(() {
      if (identical(_activeProbe, future)) {
        _activeProbe = null;
      }
    });
    return future;
  }

  Future<bool?> _probeSessionImpl({
    required String source,
    String? triggerInfo,
    RequestOptions? signalRequestOptions,
  }) async {
    final strikeSnapshot = _authStrikeCount;
    final requestGeneration =
        signalRequestOptions?.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }

    final recoveredUser = await _recoverWebViewSessionBeforeProbe(
      source: source,
      triggerInfo: triggerInfo,
      signalRequestOptions: signalRequestOptions,
    );
    if (recoveredUser != null) {
      currentUserNotifier.value = recoveredUser;
      if (recoveredUser.username.isNotEmpty) {
        _username = recoveredUser.username;
        await _storage.write(
          key: DiscourseService._usernameKey,
          value: recoveredUser.username,
        );
      }
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_probe_success',
        'message': 'WebView 候选 session 已确认有效，跳过重复 probe',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'username': recoveredUser.username,
        if (signalRequestOptions != null)
          ..._sentTDiagnostics(signalRequestOptions),
      });
      _resetStrikes();
      return true;
    }

    // probe 前同步 cf_clearance，避免 CF 验证态落后导致 probe 不确定。
    try {
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: {'cf_clearance'},
        requestGeneration: requestGeneration,
      );
    } catch (e) {
      debugPrint('[Auth] probe 前 cf_clearance 同步失败: $e');
    }

    final probeJarTToken = await _cookieJar.getTToken();
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_probe_started',
      'message': '开始 session probe',
      'source': source,
      if (triggerInfo != null) 'trigger': triggerInfo,
      'memHasToken': _tToken != null && _tToken!.isNotEmpty,
      'memTLen': _tokenLength(_tToken),
      'memTHash': _safeTokenHash(_tToken),
      'jarHasToken': probeJarTToken != null && probeJarTToken.isNotEmpty,
      'jarTLen': _tokenLength(probeJarTToken),
      'jarTHash': _safeTokenHash(probeJarTToken),
      'memMatchesJarT': _sameNonEmptyToken(_tToken, probeJarTToken),
    });

    try {
      final response = await _dio.get(
        '/session/current.json',
        queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_probe_inconclusive',
          'message': 'probe 返回非预期数据结构，暂不登出',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'statusCode': response.statusCode,
          ..._sentTDiagnostics(response.requestOptions),
        });
        _lastInconclusiveAt = DateTime.now();
        return null;
      }

      final currentUser = data['current_user'];
      if (currentUser is Map<String, dynamic>) {
        // 会话有效，恢复
        final user = User.fromJson(currentUser);
        currentUserNotifier.value = user;
        if (user.username.isNotEmpty) {
          _username = user.username;
          await _storage.write(
            key: DiscourseService._usernameKey,
            value: user.username,
          );
        }
        final liveToken = await _cookieJar.getTToken();
        if (liveToken != null && liveToken.isNotEmpty) {
          _tToken = liveToken;
        }
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_probe_success',
          'message': 'session probe 确认会话有效，保持登录',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'username': user.username,
          ..._sentTDiagnostics(response.requestOptions),
        });
        _clearPreviousTTokenFallback();
        _resetStrikes();
        return true;
      }

      final recoveredByPrevious = await _recoverPreviousSessionBeforeLogout(
        source: source,
        triggerInfo: triggerInfo,
        signalRequestOptions: signalRequestOptions,
        failedJarTToken: probeJarTToken,
      );
      if (recoveredByPrevious != null) {
        currentUserNotifier.value = recoveredByPrevious;
        if (recoveredByPrevious.username.isNotEmpty) {
          _username = recoveredByPrevious.username;
          await _storage.write(
            key: DiscourseService._usernameKey,
            value: recoveredByPrevious.username,
          );
        }
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_probe_success',
          'message': '上一枚 session 候选已确认有效，取消本次登出',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'username': recoveredByPrevious.username,
          ..._sentTDiagnostics(response.requestOptions),
        });
        _resetStrikes();
        return true;
      }

      // 200 但无 current_user → 先尝试 User API Key 自愈,再确认失效
      final healedUser = await _recoverViaUserApiKeySelfHeal(
        source: source,
        triggerInfo: triggerInfo,
      );
      if (healedUser != null) {
        currentUserNotifier.value = healedUser;
        if (healedUser.username.isNotEmpty) {
          _username = healedUser.username;
          await _storage.write(
            key: DiscourseService._usernameKey,
            value: healedUser.username,
          );
        }
        _resetStrikes();
        return true;
      }

      // 200 但无 current_user → 确认失效
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_probe_failed',
        'message': 'session probe 确认 current_user 不存在，执行登出',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        ..._sentTDiagnostics(response.requestOptions),
      });
      await _handleAuthInvalid(
        S.current.auth_loginExpiredRelogin,
        source: 'probe_confirmed',
        triggerInfo: triggerInfo,
      );
      return false;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 404 = 无用户（session_controller.rb:676）
      if (status == 404) {
        final recoveredByPrevious = await _recoverPreviousSessionBeforeLogout(
          source: source,
          triggerInfo: triggerInfo,
          signalRequestOptions: signalRequestOptions,
          failedJarTToken: probeJarTToken,
        );
        if (recoveredByPrevious != null) {
          currentUserNotifier.value = recoveredByPrevious;
          if (recoveredByPrevious.username.isNotEmpty) {
            _username = recoveredByPrevious.username;
            await _storage.write(
              key: DiscourseService._usernameKey,
              value: recoveredByPrevious.username,
            );
          }
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': 'info',
            'type': 'auth',
            'event': 'auth_probe_success',
            'message': '上一枚 session 候选已确认有效，取消本次登出',
            'source': source,
            if (triggerInfo != null) 'trigger': triggerInfo,
            'username': recoveredByPrevious.username,
            ..._sentTDiagnostics(
              e.response?.requestOptions ?? e.requestOptions,
            ),
          });
          _resetStrikes();
          return true;
        }

        final healedUser404 = await _recoverViaUserApiKeySelfHeal(
          source: source,
          triggerInfo: triggerInfo,
        );
        if (healedUser404 != null) {
          currentUserNotifier.value = healedUser404;
          if (healedUser404.username.isNotEmpty) {
            _username = healedUser404.username;
            await _storage.write(
              key: DiscourseService._usernameKey,
              value: healedUser404.username,
            );
          }
          _resetStrikes();
          return true;
        }

        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_probe_failed',
          'message': 'session probe 返回 404，确认会话失效',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          ..._sentTDiagnostics(e.response?.requestOptions ?? e.requestOptions),
        });
        await _handleAuthInvalid(
          S.current.auth_loginExpiredRelogin,
          source: 'probe_confirmed',
          triggerInfo: triggerInfo,
        );
        return false;
      }
      // 网络异常 → inconclusive
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_probe_inconclusive',
        'message': 'session probe 请求失败，暂不登出',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'statusCode': status,
        'errorType': e.type.toString(),
        ..._sentTDiagnostics(e.response?.requestOptions ?? e.requestOptions),
      });
      // 如果累积 strike 较多，升级为登出
      if (strikeSnapshot >= 2) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_inconclusive_escalated',
          'message': 'probe 不确定但 strike 已累积 $strikeSnapshot 次，升级为登出',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
        });
        await _handleAuthInvalid(
          S.current.auth_loginExpiredRelogin,
          source: 'probe_escalated',
          triggerInfo: triggerInfo,
        );
        return false;
      }
      _lastInconclusiveAt = DateTime.now();
      return null;
    } catch (e) {
      debugPrint('[Auth] probe 异常: $e');
      _lastInconclusiveAt = DateTime.now();
      return null;
    }
  }

  /// auth 信号可能来自 native CookieJar 落后于 WebView，也可能来自 WebView
  /// 残留了更旧的 session。这里不信任 WebView，只把它的值当候选：
  /// 先用候选值单独 probe，服务端确认有效后才写回 CookieJar。
  ///
  /// WebView 当前值不可用（为空 / 与 jar 相同 / 刚被拒绝）时，退而尝试
  /// 血缘服务最近在 WebView 里见过的 `_t`：哨兵清理多变体、priming 覆盖
  /// 都可能把 WebView 里更新的那枚值抹掉，但它可能仍在服务端有效。
  Future<User?> _recoverWebViewSessionBeforeProbe({
    required String source,
    String? triggerInfo,
    RequestOptions? signalRequestOptions,
  }) async {
    final sentTToken = signalRequestOptions == null
        ? null
        : _sentTTokenFromRequest(signalRequestOptions);
    if (!_hasTokenValue(sentTToken)) return null;

    final requestGeneration =
        signalRequestOptions?.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }

    final beforeJarTToken = await _cookieJar.getTToken();
    String? liveTToken;
    try {
      liveTToken = await BoundarySyncService.instance
          .readCookieValueFromWebView(
            currentUrl: AppConstants.baseUrl,
            name: '_t',
            allowLowConfidenceSessionCookies: true,
          );
    } catch (e) {
      debugPrint('[Auth] probe 前读取 WebView session 失败: $e');
      liveTToken = null;
    }

    final liveUsable =
        _hasTokenValue(liveTToken) &&
        liveTToken != beforeJarTToken &&
        liveTToken != sentTToken &&
        !_isRejectedSessionCandidateInCooldown(liveTToken);

    // 候选顺序：WebView 当前值优先，其后是血缘环里最近见过的值（最多两枚）。
    final candidates = <String>[if (liveUsable) liveTToken!];
    final ringCandidates = SessionTokenLineage.instance.recentWebViewCandidates(
      exclude: [beforeJarTToken, sentTToken, liveTToken],
    );
    for (final ring in ringCandidates) {
      if (candidates.length >= 3) break;
      if (_isRejectedSessionCandidateInCooldown(ring)) continue;
      candidates.add(ring);
    }
    if (candidates.isEmpty) return null;

    String? candidateForumSession;
    if (liveUsable) {
      try {
        candidateForumSession = await BoundarySyncService.instance
            .readCookieValueFromWebView(
              currentUrl: AppConstants.baseUrl,
              name: '_forum_session',
              allowLowConfidenceSessionCookies: true,
            );
      } catch (e) {
        debugPrint('[Auth] probe 前读取 WebView _forum_session 失败: $e');
      }
    }

    String? candidateTToken;
    User? candidateUser;
    var candidateIsLive = false;
    var rejectedCandidates = 0;
    var inconclusiveCandidates = 0;
    for (final candidate in candidates) {
      final isLive = liveUsable && candidate == liveTToken;
      final cookies = <String, String>{
        '_t': candidate,
        if (isLive && _hasTokenValue(candidateForumSession))
          '_forum_session': candidateForumSession!,
      };
      final probeResult = await _probeCandidateSessionDetailed(
        cookies,
        requestGeneration: requestGeneration,
      );
      final user = probeResult.user;
      if (user != null) {
        candidateTToken = candidate;
        candidateUser = user;
        candidateIsLive = isLive;
        break;
      }
      if (probeResult.conclusive) {
        rejectedCandidates++;
        _markRejectedSessionCandidate(candidate);
      } else {
        // 网关错误 / 网络异常 / 撞盾：不是服务端拒绝，不打入冷却，
        // 下一次信号再试。
        inconclusiveCandidates++;
      }
    }
    if (candidateTToken == null || candidateUser == null) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_probe_session_candidates_exhausted',
        'message': 'probe 前的 WebView/血缘候选都没能确认有效',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'candidatesTried': candidates.length,
        'rejected': rejectedCandidates,
        'inconclusive': inconclusiveCandidates,
        'liveUsable': liveUsable,
      });
      return null;
    }
    _clearRejectedSessionCandidate();

    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }

    // 候选已经服务端确认有效，必须以可信写入进 jar：jar 里旧值的版本号已被
    // 之前的可信轮换抬高，非可信写入会被 isFresherThan 丢弃，恢复就会静默失败。
    if (candidateIsLive) {
      final candidateSessionCookies = <String, String>{
        '_t': candidateTToken,
        if (_hasTokenValue(candidateForumSession))
          '_forum_session': candidateForumSession!,
      };
      try {
        await BoundarySyncService.instance.syncFromWebView(
          currentUrl: AppConstants.baseUrl,
          cookieNames: candidateSessionCookies.keys.toSet(),
          acceptValues: candidateSessionCookies,
          requestGeneration: requestGeneration,
          trusted: true,
        );
      } catch (e) {
        debugPrint('[Auth] 已验证的 WebView session 同步失败: $e');
        return null;
      }
    } else {
      // 血缘环里的候选只有值没有过期时间，让 jar 补上（否则不落盘）。
      await _cookieJar.setSessionTokenTrusted(candidateTToken);
    }

    final afterJarTToken = await _cookieJar.getTToken();
    if (!_hasTokenValue(afterJarTToken) || afterJarTToken != candidateTToken) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_probe_session_cookie_recover_write_failed',
        'message': '已验证的候选 _t 写入 CookieJar 后读回不符，放弃恢复',
        'source': source,
        'candidateIsLive': candidateIsLive,
        'candidateTLen': _tokenLength(candidateTToken),
        'candidateTHash': _safeTokenHash(candidateTToken),
        'afterJarTLen': _tokenLength(afterJarTToken),
        'afterJarTHash': _safeTokenHash(afterJarTToken),
      });
      return null;
    }

    _rememberPreviousTTokenFallback(
      beforeJarTToken,
      reason: 'webview_session_recovered',
      replacementToken: afterJarTToken,
      requestOptions: signalRequestOptions,
    );
    _tToken = afterJarTToken;
    if (candidateIsLive) {
      // WebView 本来就持有这枚值，现在 jar 也有了：两端一致。
      SessionTokenLineage.instance.markAgreed(afterJarTToken);
    } else {
      // 来自血缘环：WebView 当前值已不是它，推回去让两端收敛。
      unawaited(
        SessionTokenLineage.instance.pushJarCookieToWebView(
          name: '_t',
          reason: 'auth_recover_ring_candidate',
          nukeVariantsFirst: true,
        ),
      );
    }
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_probe_session_cookie_recovered',
      'message': candidateIsLive
          ? 'probe 前从 WebView 恢复了不同的 session cookie'
          : 'probe 前用最近在 WebView 见过的 _t 恢复了 session cookie',
      'source': source,
      if (triggerInfo != null) 'trigger': triggerInfo,
      'candidateIsLive': candidateIsLive,
      'candidatesTried': candidates.length,
      'sentTLen': _tokenLength(sentTToken),
      'sentTHash': _safeTokenHash(sentTToken),
      'beforeJarTLen': _tokenLength(beforeJarTToken),
      'beforeJarTHash': _safeTokenHash(beforeJarTToken),
      'afterJarTLen': _tokenLength(afterJarTToken),
      'afterJarTHash': _safeTokenHash(afterJarTToken),
      'afterMatchesSentT': _sameNonEmptyToken(afterJarTToken, sentTToken),
      if (requestGeneration != null) 'requestGeneration': requestGeneration,
    });
    return candidateUser;
  }

  /// 血缘对账的探测钩子：用 WebView 里的候选 `_t` 单独探测服务端。
  ///
  /// true/false 是服务端的明确答复；null 表示探测没结论（网关 502、超时、
  /// 撞盾、会话代已变）。对账方拿到 null 必须按「无结论」处理、两端都不动：
  /// 冷启动时探测撞上一次 502 就把 WebView 里的活 token 当死值推翻，
  /// 正是无征兆掉登录的触发点之一。
  Future<bool?> _probeWebViewTokenForLineage(
    String candidate, {
    int? requestGeneration,
  }) async {
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }
    if (_isRejectedSessionCandidateInCooldown(candidate)) return false;
    final result = await _probeCandidateSessionDetailed({
      '_t': candidate,
    }, requestGeneration: requestGeneration);
    if (result.accepted) {
      _clearRejectedSessionCandidate();
      return true;
    }
    if (!result.conclusive) return null;
    _markRejectedSessionCandidate(candidate);
    return false;
  }

  /// 2xx 响应里服务端明确删除了 `_t`（Set-Cookie `_t=` 空值 / del）。
  ///
  /// Discourse 的 `refresh_session` 只在「请求带了 `_t` 却找不到用户」时这么
  /// 做，等价于「你手里这枚 token 已死」。CookieManager 已把这条删除指令拦下
  /// 不动 jar，这里把它当强信号交给 probe：jar 的值若真死，probe 会依次试
  /// WebView 的候选、上一枚值、User API Key，都不行才登出并留下日志；若只是
  /// jar 落后于 WebView，probe 顺手就把活值捞回来。之前这条路径不产生任何
  /// 信号，jar 的 `_t` 被静默删掉，App 就无征兆地变成匿名。
  void _onSessionTokenDeletionDeferred(
    RequestOptions requestOptions,
    int? statusCode,
  ) {
    if (_isLoggingOut) return;
    if (requestOptions.spec.skipAuthCheck) return;
    if (!_hasTokenValue(_sentTTokenFromRequest(requestOptions))) return;
    unawaited(
      _reportAuthSignal(
        isStrong: true,
        source: 'response_t_deleted',
        triggerInfo:
            '${requestOptions.method} ${requestOptions.uri} → $statusCode',
        requestOptions: requestOptions,
        statusCode: statusCode,
      ),
    );
  }

  /// 血缘对账采纳了 WebView 的 `_t` 之后：把被替换掉的 jar 旧值留作上一枚
  /// 候选（轮换窗口内服务端仍接受），并同步内存里的 token。
  void _onLineageAdoptedWebViewToken(String adopted, String? previousJar) {
    _rememberPreviousTTokenFallback(
      previousJar,
      reason: 'lineage_adopt_webview',
      replacementToken: adopted,
    );
    _tToken = adopted;
  }

  void _registerSessionTokenLineageHooks() {
    SessionTokenLineage.instance.registerHooks(
      probe: _probeWebViewTokenForLineage,
      onAdopted: _onLineageAdoptedWebViewToken,
    );
    AppCookieManager.sessionTokenDeletionObserver =
        _onSessionTokenDeletionDeferred;
  }

  Future<User?> _recoverPreviousSessionBeforeLogout({
    required String source,
    String? triggerInfo,
    RequestOptions? signalRequestOptions,
    String? failedJarTToken,
  }) async {
    final sentTToken = signalRequestOptions == null
        ? null
        : _sentTTokenFromRequest(signalRequestOptions);
    final candidateTToken = _readPreviousTTokenFallback(
      sentTToken: sentTToken,
      jarTToken: failedJarTToken,
    );
    if (!_hasTokenValue(candidateTToken)) return null;
    final candidateTTokenValue = candidateTToken!;

    final requestGeneration =
        signalRequestOptions?.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }
    if (_isRejectedSessionCandidateInCooldown(candidateTTokenValue)) {
      return null;
    }

    final probeResult = await _probeCandidateSessionDetailed({
      '_t': candidateTTokenValue,
    }, requestGeneration: requestGeneration);
    final candidateUser = probeResult.user;
    if (candidateUser == null) {
      // 只有服务端明确拒绝才打入冷却；网关/网络无结论时留给下次再试。
      if (probeResult.conclusive) {
        _markRejectedSessionCandidate(candidateTTokenValue);
      }
      return null;
    }
    _clearRejectedSessionCandidate();

    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return null;
    }

    // 上一枚值只有值没有过期时间，让 jar 补上（否则不落盘，冷启动又丢）。
    await _cookieJar.setSessionTokenTrusted(candidateTTokenValue);
    final afterJarTToken = await _cookieJar.getTToken();
    if (!_hasTokenValue(afterJarTToken) ||
        afterJarTToken != candidateTTokenValue) {
      return null;
    }

    _tToken = afterJarTToken;
    _clearPreviousTTokenFallback();
    // WebView 里多半还是那枚已死的值，推回去让两端收敛（读回校验、失败记日志）。
    unawaited(
      SessionTokenLineage.instance.pushJarCookieToWebView(
        name: '_t',
        reason: 'auth_recover_previous_t',
        nukeVariantsFirst: true,
      ),
    );
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_probe_previous_session_cookie_recovered',
      'message': '登录失效前用上一枚 _t 候选恢复了 session cookie',
      'source': source,
      if (triggerInfo != null) 'trigger': triggerInfo,
      'sentTLen': _tokenLength(sentTToken),
      'sentTHash': _safeTokenHash(sentTToken),
      'failedJarTLen': _tokenLength(failedJarTToken),
      'failedJarTHash': _safeTokenHash(failedJarTToken),
      'afterJarTLen': _tokenLength(afterJarTToken),
      'afterJarTHash': _safeTokenHash(afterJarTToken),
      'afterMatchesSentT': _sameNonEmptyToken(afterJarTToken, sentTToken),
      if (requestGeneration != null) 'requestGeneration': requestGeneration,
    });
    return candidateUser;
  }

  /// 第三级恢复:WebView 候选与上一枚 _t 候选都失败后,若存在已授权的
  /// User API Key,静默补发 OTP 兑换全新 _t(DiscourseHub 模式自愈)。
  /// 成功 = 服务端签发了与密码登录同源的新 UserAuthToken,取消本次登出。
  Future<User?> _recoverViaUserApiKeySelfHeal({
    required String source,
    String? triggerInfo,
  }) async {
    try {
      final currentUserJson = await UserApiKeyService().selfHeal(_dio);
      if (currentUserJson == null) return null;

      final newToken = await _cookieJar.getTToken();
      if (!_hasTokenValue(newToken)) return null;

      _tToken = newToken;
      _clearPreviousTTokenFallback();
      _clearRejectedSessionCandidate();

      final user = User.fromJson(currentUserJson);
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_probe_user_api_key_recovered',
        'message': 'User API Key 自愈成功,已兑换新 _t,取消本次登出',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'username': user.username,
        'newTLen': _tokenLength(newToken),
        'newTHash': _safeTokenHash(newToken),
      });
      return user;
    } catch (e) {
      debugPrint('[Auth] User API Key 自愈异常: $e');
      return null;
    }
  }

  /// 用候选会话 cookie 探测 `/session/current.json`。
  ///
  /// 只有服务端**明确**答复会话失效（404、带登出信号的 401/403，口径同
  /// [classifySessionCheckFailure]）才算有结论的拒绝；网关 502、超时、撞 CF
  /// 盾、非预期响应体一律是「无结论」。调用方不得把无结论当拒绝：既不能把
  /// 候选打入冷却，更不能据此覆盖另一端的值。
  Future<_CandidateProbeResult> _probeCandidateSessionDetailed(
    Map<String, String> candidateCookies, {
    int? requestGeneration,
  }) async {
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return const _CandidateProbeResult.inconclusive();
    }

    final cookieHeader = await _cookieHeaderReplacingSessionCookies(
      candidateCookies,
    );
    try {
      final response = await _dio.get(
        '/session/current.json',
        queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          headers: {
            HttpHeaders.cookieHeader: cookieHeader,
            'Discourse-Logged-In': 'true',
          },
          extra: const {
            'skipAuthCheck': true,
            'skipCsrf': true,
            'skipSessionStateSync': true,
            'skipWebViewAdapter': true,
            AppCookieManager.skipCookieManagerExtraKey: true,
            // 候选会话探测带手工 Cookie 头,绝不能被恢复层重放:
            // 重放会清掉这个手工头,让探测失去意义。
            FluxRequestKeys.noRecovery: true,
          },
        ),
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return const _CandidateProbeResult.inconclusive();
      }
      final currentUser = data['current_user'];
      if (currentUser is! Map<String, dynamic>) {
        // Discourse 对匿名是 404，2xx 却没有 current_user 不是正常形态，
        // 按无结论处理。
        return const _CandidateProbeResult.inconclusive();
      }
      return _CandidateProbeResult.accepted(User.fromJson(currentUser));
    } on DioException catch (e) {
      final verdict = classifySessionCheckFailure(e.response);
      if (verdict == SessionCheckVerdict.sessionInvalid) {
        return const _CandidateProbeResult.rejected();
      }
      debugPrint(
        '[Auth] candidate session probe 无结论: '
        'status=${e.response?.statusCode} type=${e.type} verdict=$verdict',
      );
      return const _CandidateProbeResult.inconclusive();
    } catch (e) {
      debugPrint('[Auth] candidate session probe 异常: $e');
      return const _CandidateProbeResult.inconclusive();
    }
  }

  Future<String> _cookieHeaderReplacingSessionCookies(
    Map<String, String> replacements,
  ) async {
    final currentHeader = await _cookieJar.getCookieHeader() ?? '';
    final replacementNames = replacements.keys.toSet();
    final preserved = currentHeader
        .split(';')
        .map((part) => part.trim())
        .where((part) {
          final separator = part.indexOf('=');
          if (separator <= 0) return false;
          final name = part.substring(0, separator);
          return !replacementNames.contains(name);
        })
        .toList(growable: true);

    for (final entry in replacements.entries) {
      if (entry.value.isEmpty) continue;
      preserved.add('${entry.key}=${entry.value}');
    }
    return preserved.join('; ');
  }

  /// 初始化拦截器
  void _initInterceptors() {
    // 添加业务特定拦截器
    _dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (!_credentialsLoaded) {
            await _loadStoredCredentials();
            _credentialsLoaded = true;
          }

          final sessionState = await _readSessionCookieState();
          final liveToken = sessionState.tToken;
          if (liveToken != _tToken) {
            _rememberPreviousTTokenFallback(
              _tToken,
              reason: 'request_cookie_jar_changed',
              replacementToken: liveToken,
              requestOptions: options,
            );
            if ((liveToken == null || liveToken.isEmpty) &&
                _tToken != null &&
                _tToken!.isNotEmpty) {
              LogWriter.instance.write({
                'timestamp': DateTime.now().toIso8601String(),
                'level': 'warning',
                'type': 'auth',
                'event': 'token_desync_before_request',
                'message': '请求前检测到内存 token 与 CookieJar 不一致，已按 CookieJar 修正',
                'method': options.method,
                'url': options.uri.toString(),
                'memTokenLen': _tToken?.length,
                'jarTokenLen': liveToken?.length,
              });
            }
            _tToken = (liveToken != null && liveToken.isNotEmpty)
                ? liveToken
                : null;
          }

          options.extra['_sessionCookieFingerprint'] = sessionState.fingerprint;

          if (_tToken != null && _tToken!.isNotEmpty) {
            if (!_isLoggingOut) {
              // bootstrap 是站点风控的指纹上报，产物 _rt 是软依赖：
              // 服务端用 _t 已经能完成认证，首个请求漏掉 _rt 不会被拒。
              // 后台触发，不阻塞业务请求，避免冷启动后第一次点话题被
              // bootstrap (Mac 上 6~20s) 整段拖住。
              WebViewSessionCookieRefreshService.instance.ensureInBackground(
                reason: 'dio_request:${options.method}',
              );
            }
            options.headers['Discourse-Logged-In'] = 'true';
            if (UserPresenceService().isPresent) {
              options.headers['Discourse-Present'] = 'true';
            } else {
              options.headers.remove('Discourse-Present');
            }
          } else {
            options.headers.remove('Discourse-Logged-In');
            options.headers.remove('Discourse-Present');
          }

          debugPrint('[DIO] ${options.method} ${options.uri}');
          handler.next(options);
        },
        onResponse: (response, handler) async {
          final skipAuthCheck =
              response.requestOptions.spec.skipAuthCheck;

          final loggedOut = response.headers.value('discourse-logged-out');
          if (!skipAuthCheck &&
              loggedOut != null &&
              loggedOut.isNotEmpty &&
              !_isLoggingOut) {
            // 2xx + discourse-logged-out 是弱信号（矛盾信号），异步处理不阻塞
            unawaited(
              _reportAuthSignal(
                isStrong: false,
                source: 'response_header',
                triggerInfo:
                    '${response.requestOptions.method} ${response.requestOptions.uri} → ${response.statusCode}',
                requestOptions: response.requestOptions,
                statusCode: response.statusCode,
              ),
            );
            return handler.next(response);
          }

          final skipSessionStateSync =
              response.requestOptions.spec.skipSessionStateSync;
          if (!skipSessionStateSync) {
            final sessionState = await _syncSessionStateFromResponse(
              response.requestOptions,
              response: response,
              phase: 'response',
            );
            _syncMemoryTokenFromSessionState(
              sessionState,
              logWhenCleared: true,
              requestOptions: response.requestOptions,
            );
          }

          final username = response.headers.value('x-discourse-username');
          if (username != null &&
              username.isNotEmpty &&
              username != _username) {
            _username = username;
            _storage.write(key: DiscourseService._usernameKey, value: username);
          }

          debugPrint(
            '[DIO] ${response.statusCode} ${response.requestOptions.uri}',
          );
          handler.next(response);
        },
        onError: (error, handler) async {
          final skipAuthCheck =
              error.requestOptions.spec.skipAuthCheck;
          final data = error.response?.data;
          debugPrint('[DIO] Error: ${error.response?.statusCode}');

          // BAD CSRF 处理：对齐 Discourse 官方前端，只清空 token。
          // 下一次非 GET 请求会在 RequestHeaderInterceptor 中先刷新 CSRF。
          if (error.response?.statusCode == 403 && _isBadCsrfResponse(data)) {
            debugPrint('[DIO] BAD CSRF detected, clearing csrfToken');
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'warning',
              'type': 'auth',
              'event': 'csrf_bad_response_detected',
              'message': '收到 BAD CSRF，已清空 token，下次 POST 前刷新',
              'method': error.requestOptions.method,
              'url': error.requestOptions.uri.toString(),
              'statusCode': error.response?.statusCode,
            });
            _cookieSync.clearCsrfToken();
            return handler.next(error);
          }

          final loggedOut = error.response?.headers.value(
            'discourse-logged-out',
          );
          if (!skipAuthCheck &&
              loggedOut != null &&
              loggedOut.isNotEmpty &&
              !_isLoggingOut) {
            // 4xx + logged-out 是强信号，2xx/3xx 是弱信号
            final errorStatusCode = error.response?.statusCode;
            unawaited(
              _reportAuthSignal(
                isStrong: errorStatusCode == 401 || errorStatusCode == 403,
                source: 'error_response_header',
                triggerInfo:
                    '${error.requestOptions.method} ${error.requestOptions.uri} → $errorStatusCode',
                requestOptions: error.requestOptions,
                statusCode: errorStatusCode,
              ),
            );
            return handler.next(error);
          }

          final skipSessionStateSync =
              error.requestOptions.spec.skipSessionStateSync;
          final sessionState = skipSessionStateSync
              ? await _readSessionCookieState()
              : await _syncSessionStateFromResponse(
                  error.requestOptions,
                  response: error.response,
                  phase: 'error',
                );
          if (!skipSessionStateSync) {
            _syncMemoryTokenFromSessionState(
              sessionState,
              requestOptions: error.requestOptions,
            );
          }

          if (!skipAuthCheck &&
              data is Map &&
              data['error_type'] == 'not_logged_in') {
            final jarTToken = sessionState.tToken;
            final sentTToken = _sentTTokenFromRequest(error.requestOptions);
            if (_isAlreadyLoggedOutSignal(
              jarTToken: jarTToken,
              sentTToken: sentTToken,
            )) {
              _logAuthSignalSuppressedAlreadyLoggedOut(
                source: 'error_response_body',
                triggerInfo:
                    '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}, error_type=${data['error_type']}',
                statusCode: error.response?.statusCode,
                jarTToken: jarTToken,
                sentTToken: sentTToken,
              );
              return handler.next(error);
            }
            AppLogger.warning(
              '认证失效: source=error_response, reason=${data['error_type'] ?? 'not_logged_in'}',
              tag: 'Auth',
              fields: {
                'type': 'auth',
                'event': 'auth_invalid',
                'source': 'error_response',
                'reason': data['error_type']?.toString() ?? 'not_logged_in',
                'method': error.requestOptions.method,
                'url': error.requestOptions.uri.toString(),
                'statusCode': error.response?.statusCode,
                'errors': data['errors']?.toString(),
                'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
                'jarTokenLength': jarTToken?.length,
                'memHasToken': _tToken != null && _tToken!.isNotEmpty,
              },
            );
            // 服务端明确返回 not_logged_in 是强信号
            unawaited(
              _reportAuthSignal(
                isStrong: true,
                source: 'error_response_body',
                triggerInfo:
                    '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}, error_type=${data['error_type']}',
                requestOptions: error.requestOptions,
                statusCode: error.response?.statusCode,
              ),
            );
          }

          handler.next(error);
        },
      ),
    );
  }

  Future<SessionSnapshot> _readSessionCookieState() async {
    final tToken = await _cookieJar.getTToken();
    final forumSession = await _cookieJar.getCookieValue('_forum_session');

    return SessionSnapshot.fromValues(
      tToken: tToken,
      forumSession: forumSession,
    );
  }

  Future<SessionSnapshot> _syncSessionStateFromResponse(
    RequestOptions requestOptions, {
    Response? response,
    required String phase,
  }) async {
    final sessionState = await _readSessionStateAfterResponse(response);
    final beforeFingerprint =
        requestOptions.extra['_sessionCookieFingerprint'] as String?;
    final afterFingerprint = sessionState.fingerprint;

    if (beforeFingerprint == afterFingerprint) {
      return sessionState;
    }

    final requestGeneration =
        requestOptions.extra['_sessionGeneration'] as int?;
    if (requestGeneration != null &&
        !AuthSession().isValid(requestGeneration)) {
      return sessionState;
    }

    _rememberPreviousTTokenFallback(
      beforeFingerprint,
      reason: 'response_session_cookie_changed',
      replacementToken: afterFingerprint,
      requestOptions: requestOptions,
    );
    requestOptions.extra['_sessionCookieFingerprint'] = afterFingerprint;

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'session_cookie_rotated',
      'message': '检测到会话 Cookie 变化，后续请求将使用新的 _t',
      'phase': phase,
      'method': requestOptions.method,
      'url': requestOptions.uri.toString(),
      'hadSessionBefore':
          beforeFingerprint != null && beforeFingerprint.isNotEmpty,
      'hasSessionAfter':
          afterFingerprint != null && afterFingerprint.isNotEmpty,
      'beforeTLen': beforeFingerprint?.length,
      'beforeTHash': _safeTokenHash(beforeFingerprint),
      'afterTLen': afterFingerprint?.length,
      'afterTHash': _safeTokenHash(afterFingerprint),
      'hasForumSessionAfter': sessionState.hasForumSession,
    });

    return sessionState;
  }

  Future<SessionSnapshot> _readSessionStateAfterResponse(
    Response? response,
  ) async {
    final tTokenFromResponse = _extractTTokenFromSetCookie(response);
    if (tTokenFromResponse != null || _hasExplicitTDeletion(response)) {
      final forumSession = await _cookieJar.getCookieValue('_forum_session');
      return SessionSnapshot.fromValues(
        tToken: tTokenFromResponse,
        forumSession: forumSession,
      );
    }

    return _readSessionCookieState();
  }

  String? _extractTTokenFromSetCookie(Response? response) {
    final headers = _flattenSetCookieHeaders(response);
    String? token;

    for (final header in headers) {
      if (!header.toLowerCase().startsWith('_t=')) continue;
      final value = header.substring(3).split(';').first;
      if (value.isEmpty || value == 'del') {
        token = null;
      } else {
        token = value;
      }
    }

    return token;
  }

  bool _hasExplicitTDeletion(Response? response) {
    final headers = _flattenSetCookieHeaders(response);
    for (final header in headers) {
      if (!header.toLowerCase().startsWith('_t=')) continue;
      final value = header.substring(3).split(';').first;
      if (value.isEmpty || value == 'del') {
        return true;
      }
    }
    return false;
  }

  List<String> _flattenSetCookieHeaders(Response? response) {
    final rawHeaders = response?.headers[HttpHeaders.setCookieHeader];
    if (rawHeaders == null || rawHeaders.isEmpty) return const [];

    return rawHeaders
        .map((str) => str.split(RegExp('(?<=)(,)(?=[^;]+?=)')))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .toList(growable: false);
  }

  void _syncMemoryTokenFromSessionState(
    SessionSnapshot sessionState, {
    bool logWhenCleared = false,
    RequestOptions? requestOptions,
  }) {
    final tToken = sessionState.tToken;

    if (tToken != null && tToken.isNotEmpty) {
      _tToken = tToken;
      return;
    }

    if (_tToken != null && _tToken!.isNotEmpty) {
      if (logWhenCleared && requestOptions != null) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'token_missing_after_response',
          'message': '响应后会话 Cookie 已缺失，仅记录告警，不立即清空内存 token',
          'method': requestOptions.method,
          'url': requestOptions.uri.toString(),
          'memTokenLen': _tToken?.length,
        });
      }
      // 不再立即清空 _tToken，由 probe 确认失效后在 logout() 中统一清除
      // _tToken = null;
    }
  }

  /// 收到 discourse-logged-out header 时的处理
  ///
  /// 服务端在以下情况设置此 header（BAD_TOKEN）：
  /// 1. 有 _t cookie 但 UserAuthToken.lookup 找不到对应用户（token 已失效）
  /// 2. 没有 _t cookie 但请求带了 Discourse-Logged-In header
  ///
  /// Discourse 官方前端：弹对话框 → 无论点什么都刷新页面。
  /// 我们采用保守策略：通过 _reportAuthSignal → probe 机制二次验证，
  /// 避免因 cookie 传输瞬时问题或 token rotation 窗口导致误判。
  ///
  /// 此方法已不再被拦截器直接调用，保留仅供参考和未来扩展。
  // ignore: unused_element
  Future<void> _onDiscourseLoggedOut({
    required String source,
    required String triggerInfo,
    required RequestOptions requestOptions,
    int? statusCode,
  }) async {
    if (_isLoggingOut) return;

    debugPrint('[Auth] discourse-logged-out: $triggerInfo');

    final jarTToken = await _cookieJar.getTToken();
    final sentCookieHeader =
        requestOptions.headers[HttpHeaders.cookieHeader]?.toString() ??
        requestOptions.headers['Cookie']?.toString() ??
        '';
    final sentTToken = _sentTTokenFromRequest(requestOptions);

    AppLogger.warning(
      '认证失效: source=$source, reason=discourse-logged-out',
      tag: 'Auth',
      fields: {
        'type': 'auth',
        'event': 'auth_invalid',
        'source': source,
        'reason': 'discourse-logged-out',
        'method': requestOptions.method,
        'url': requestOptions.uri.toString(),
        'statusCode': statusCode,
        'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
        'jarTokenLen': jarTToken?.length,
        'jarTHash': _safeTokenHash(jarTToken),
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        'memTLen': _tokenLength(_tToken),
        'memTHash': _safeTokenHash(_tToken),
        'sentHasT': sentTToken != null && sentTToken.isNotEmpty,
        'sentTLen': _tokenLength(sentTToken),
        'sentTHash': _safeTokenHash(sentTToken),
        'sentMatchesJarT': _sameNonEmptyToken(sentTToken, jarTToken),
        'sentMatchesMemT': _sameNonEmptyToken(sentTToken, _tToken),
        'sentCookieLen': sentCookieHeader.length,
      },
    );
  }

  /// 判断响应是否为 BAD CSRF
  /// Discourse 返回 403 + '["BAD CSRF"]' 表示 CSRF token 校验失败
  bool _isBadCsrfResponse(dynamic data) {
    if (data is String) return data == '["BAD CSRF"]';
    if (data is List) return data.length == 1 && data.first == 'BAD CSRF';
    return false;
  }

  /// 设置导航 context
  void setNavigatorContext(BuildContext context) {
    _cfChallenge.setContext(context);
  }

  /// 服务端主动踢下线（MessageBus `/logout/:user_id` 频道）
  ///
  /// 与 [_handleAuthInvalid] 的关键区别：不走 User API Key 自愈。
  /// 那条路径处理的是“疑似失效”（cookie 轮换窗口、传输抖动），所以要先尝试
  /// 静默恢复；而 /logout 是服务端明确撤销了这个会话（管理员登出设备、账号被
  /// 删除等），再拿 API Key 换一个新会话回来直接违背了服务端意图。
  ///
  /// 复用 [_isLoggingOut] 同一把锁：与接口 403 触发的登出互斥，避免两路并发
  /// 时重复清理、重复弹框。
  Future<void> handleServerForcedLogout({String source = 'message_bus'}) async {
    if (_isLoggingOut) {
      debugPrint('[Auth] 已在登出流程中，忽略 /logout 推送');
      return;
    }
    _isLoggingOut = true;

    AppLogger.warning(
      '服务端推送强制登出',
      tag: 'Auth',
      fields: {
        'type': 'auth',
        'event': 'logout_server_forced',
        'source': source,
      },
    );

    // 先切断在途请求，避免失效会话继续产生 403 噪声
    AuthSession().advance();

    try {
      // callApi: false —— 会话已被服务端撤销，再调 DELETE /session 只会 403
      await logout(callApi: false, refreshPreload: true);
    } finally {
      // 无论清理是否抛错都要释锁并广播，否则会卡在“凭证已清、UI 以为还
      // 登录着”的中间态（同 logout() 里第四~六步的 try/finally 理由）
      _isLoggingOut = false;
    }

    _authErrorController.add(S.current.auth_loggedOutByServer);
  }

  Future<void> _handleAuthInvalid(
    String message, {
    String? source,
    String? triggerInfo,
    bool? sentHasT,
    int? sentTLen,
  }) async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;

    // ===== 第零步：尝试 User API Key 静默恢复 =====
    // 已授权 key（one_time_password scope）时先换新 OTP 重建会话，
    // 成功则本次失效对用户完全透明，不登出不打扰。
    // selfHeal 内部有单飞合流与失败冷却窗口，不会形成恢复风暴。
    try {
      final restoredUser = await UserApiKeyService().selfHeal(_dio);
      final restoredUsername = restoredUser?['username']?.toString();
      if (restoredUsername != null && restoredUsername.isNotEmpty) {
        await finalizeNativeLoginSuccess(restoredUsername);
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_restored_by_user_api_key',
          'message': '登录失效已通过 User API Key 自动恢复，取消登出',
          'source': source,
          'trigger': triggerInfo,
        });
        _resetStrikes();
        _isLoggingOut = false;
        return;
      }
    } catch (e) {
      debugPrint('[Auth] User API Key 自动恢复异常: $e');
    }

    // ===== 第一步：立即切断所有在途请求 =====
    // 先于 logout 执行，防止用户在失效状态下继续操作产生更多 403
    AuthSession().advance();

    // 收集 _t cookie 诊断信息（不含实际值，仅状态）
    final jarTToken = await _cookieJar.getTToken();
    final csrfToken = _cookieSync.csrfToken;
    final jarSessionCookies = await _cookieJar
        .getSessionCookieDiagnosticsForRequest(
          uri: Uri.parse(AppConstants.baseUrl),
        );

    // 记录被动退出日志（含触发来源，方便排查）
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'lifecycle',
      'event': 'logout_passive',
      'message': '登录失效被动退出',
      'reason': message,
      'source': source,
      'trigger': triggerInfo,
      // _t cookie 诊断（仅记录有无和长度，不记录实际值）
      'memHasToken': _tToken != null && _tToken!.isNotEmpty,
      'memTLen': _tokenLength(_tToken),
      'memTHash': _safeTokenHash(_tToken),
      'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
      'jarTokenLen': jarTToken?.length,
      'jarTHash': _safeTokenHash(jarTToken),
      'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
      'jarSessionCookies': jarSessionCookies,
      // 实际请求中 Cookie header 的 _t 状态（仅 discourse-logged-out 触发时有值）
      'sentHasT': sentHasT,
      'sentTLen': sentTLen,
    });

    await AuthIssueNoticeService.instance.recordPassiveLogout();
    await logout(callApi: false, refreshPreload: true);
    _isLoggingOut = false;
    _authErrorController.add(message);
  }

  /// 检查是否已登录
  ///
  /// 除了检查本地 _t cookie，还会请求 /session/current.json 做服务端验证，
  /// 避免本地有 cookie 但服务端已撤销 session 的"假在线"状态。
  /// 网络异常时保守返回 true（保留本地状态）。
  Future<bool> isLoggedIn() async {
    final username = await _storage.read(key: DiscourseService._usernameKey);
    if (username == null || username.isEmpty) return false;

    final storedTToken = await _cookieJar.getTToken();
    final String tToken;
    if (_hasTokenValue(storedTToken)) {
      tToken = storedTToken!;
    } else {
      // 登出会连用户名一起删，所以「用户名还在、jar 没 _t」是 jar 异常丢值
      // （会话 cookie 没落盘、文件损坏等），不是用户登出。WebView 会把会话
      // cookie 跨重启保留，先看它手里有没有活会话，再决定是否判未登录。
      final recovered = await _recoverStartupTokenFromWebView(
        storedUsername: username,
      );
      if (!_hasTokenValue(recovered)) return false;
      tToken = recovered!;
    }

    // 服务端验证
    try {
      final response = await _dio.get(
        '/session/current.json',
        queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );
      final data = response.data;
      if (data is Map<String, dynamic> && data['current_user'] is Map) {
        _tToken = tToken;
        final liveUsername = (data['current_user'] as Map)['username']
            ?.toString();
        _username = (liveUsername != null && liveUsername.isNotEmpty)
            ? liveUsername
            : username;
        _resetStrikes();
        return true;
      }
      // 200 但无 current_user
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_session_check_failed',
        'message': '登录态检查返回 200 但无 current_user，先走恢复链再决定是否登出',
        'statusCode': response.statusCode,
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        'memTLen': _tokenLength(_tToken),
        'memTHash': _safeTokenHash(_tToken),
        'jarHasToken': tToken.isNotEmpty,
        'jarTLen': _tokenLength(tToken),
        'jarTHash': _safeTokenHash(tToken),
        ..._sentTDiagnostics(response.requestOptions),
      });
      return _recoverOrLogoutAfterStartupCheck(
        triggerInfo: 'GET /session/current.json → ${response.statusCode} 无 current_user',
        signalRequestOptions: response.requestOptions,
        storedUsername: username,
        jarTToken: tToken,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 404 = 无用户 / 401/403 + 登出信号 = 明确拒绝；
      // CF 挑战与无登出信号的 403（站点风控）不是会话问题，不能据此登出
      final verdict = classifySessionCheckFailure(e.response);
      if (verdict == SessionCheckVerdict.sessionInvalid) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_session_check_failed',
          'message': '登录态检查被服务端拒绝，先走恢复链再决定是否登出',
          'statusCode': status,
          'errorType': e.type.toString(),
          'memHasToken': _tToken != null && _tToken!.isNotEmpty,
          'memTLen': _tokenLength(_tToken),
          'memTHash': _safeTokenHash(_tToken),
          'jarHasToken': tToken.isNotEmpty,
          'jarTLen': _tokenLength(tToken),
          'jarTHash': _safeTokenHash(tToken),
          ..._sentTDiagnostics(e.response?.requestOptions ?? e.requestOptions),
        });
        return _recoverOrLogoutAfterStartupCheck(
          triggerInfo: 'GET /session/current.json → $status',
          signalRequestOptions: e.response?.requestOptions ?? e.requestOptions,
          storedUsername: username,
          jarTToken: tToken,
        );
      }
      if (status != null) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_session_check_inconclusive',
          'message': '登录态检查失败但未确认会话失效，保留本地登录态',
          'statusCode': status,
          'verdict': verdict.name,
          'errorType': e.type.toString(),
        });
      }
      // 网络异常/CF 验证等 → 保守保留本地状态
      _tToken = tToken;
      _username = username;
      return true;
    } catch (_) {
      _tToken = tToken;
      _username = username;
      return true;
    }
  }

  /// 启动登录态检查被服务端明确拒绝后，走与 auth 信号相同的恢复链再决定
  /// 是否登出：WebView 候选 `_t` → 上一枚值 → User API Key，都不行才被动
  /// 登出并留下 logout_passive 日志。
  ///
  /// 以前这里直接 logout：jar 里的 `_t` 在 WebView 轮换后已经过期，而
  /// WebView 里那枚活值还没来得及对账回 jar，冷启动就把本来能救回来的会话
  /// 丢掉了，表现就是「无征兆掉登录、重登立刻恢复」。
  Future<bool> _recoverOrLogoutAfterStartupCheck({
    required String triggerInfo,
    required RequestOptions signalRequestOptions,
    required String storedUsername,
    required String jarTToken,
  }) async {
    final verdict = await _probeSession(
      source: 'startup_session_check',
      triggerInfo: triggerInfo,
      signalRequestOptions: signalRequestOptions,
    );
    if (verdict == true) {
      // 恢复链可能已经换掉了 jar 里的 _t，以 jar 为准同步内存。
      final liveToken = await _cookieJar.getTToken();
      _tToken = _hasTokenValue(liveToken) ? liveToken : jarTToken;
      if (_username == null || _username!.isEmpty) {
        _username = storedUsername;
      }
      return true;
    }
    if (verdict == false) {
      // probe 已确认失效并执行了被动登出（含提示）。
      return false;
    }
    // 再探测无结论（网关 / 网络 / 撞盾）：保守保留本地状态，
    // 后续请求的 auth 信号会继续走 strike 机制。
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'auth',
      'event': 'auth_session_check_inconclusive',
      'message': '登录态检查被拒绝后再探测无结论，保留本地登录态',
      'trigger': triggerInfo,
    });
    _tToken = jarTToken;
    _username = storedUsername;
    return true;
  }

  /// 冷启动时 jar 没有 `_t` 但用户名还在：从 WebView 找回会话。
  ///
  /// 顺序：WebView 当前 `_t`（探测通过才标记两端一致；探测无结论时也先
  /// 采纳，交给随后的登录态检查和 strike 机制裁决，与「网络异常保守保留
  /// 本地状态」一致）→ User API Key 自愈 → 都不行返回 null。
  ///
  /// WebView 的值被服务端明确拒绝、自愈也失败时，按被动登出收尾（提示 +
  /// logout_passive 日志），让用户知道会话已失效，而不是悄悄变成匿名态。
  /// WebView 根本没有 `_t` 时沿用旧行为：静默判未登录。
  Future<String?> _recoverStartupTokenFromWebView({
    required String storedUsername,
  }) async {
    const source = 'startup_jar_token_missing';
    final boundary = BoundarySyncService.instance;

    String? webViewTToken;
    String? webViewForumSession;
    try {
      webViewTToken = await boundary.readCookieValueFromWebView(
        currentUrl: AppConstants.baseUrl,
        name: '_t',
        allowLowConfidenceSessionCookies: true,
      );
      if (_hasTokenValue(webViewTToken)) {
        webViewForumSession = await boundary.readCookieValueFromWebView(
          currentUrl: AppConstants.baseUrl,
          name: '_forum_session',
          allowLowConfidenceSessionCookies: true,
        );
      }
    } catch (e) {
      debugPrint('[Auth] 启动恢复读取 WebView session 失败: $e');
      webViewTToken = null;
    }

    var webViewRejected = false;
    if (_hasTokenValue(webViewTToken)) {
      final candidate = webViewTToken!;
      final cookies = <String, String>{
        '_t': candidate,
        if (_hasTokenValue(webViewForumSession))
          '_forum_session': webViewForumSession!,
      };
      final probeResult = await _probeCandidateSessionDetailed(cookies);
      final verified = probeResult.user != null;
      if (verified || !probeResult.conclusive) {
        String? afterJarTToken;
        try {
          // 可信写回：WebView 里这枚 _t 若没有过期时间，syncFromWebView 会
          // 补上，保证落盘。
          await boundary.syncFromWebView(
            currentUrl: AppConstants.baseUrl,
            cookieNames: cookies.keys.toSet(),
            acceptValues: cookies,
            allowLowConfidenceSessionCookies: true,
            trusted: true,
          );
          afterJarTToken = await _cookieJar.getTToken();
        } catch (e) {
          debugPrint('[Auth] 启动恢复写回 WebView session 失败: $e');
        }
        if (afterJarTToken == candidate) {
          if (verified) {
            _clearRejectedSessionCandidate();
            SessionTokenLineage.instance.markAgreed(candidate);
          }
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': verified ? 'info' : 'warning',
            'type': 'auth',
            'event': verified
                ? 'auth_startup_session_recovered_from_webview'
                : 'auth_startup_session_adopted_unverified',
            'message': verified
                ? 'jar 没有 _t 但 WebView 持有有效会话，已可信写回 jar'
                : 'jar 没有 _t，WebView 的 _t 探测无结论，先采纳交给后续检查裁决',
            'source': source,
            'webViewTLen': _tokenLength(candidate),
            'webViewTHash': _safeTokenHash(candidate),
            'hasForumSession': cookies.containsKey('_forum_session'),
          });
          return afterJarTToken;
        }
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_startup_session_recover_write_failed',
          'message': 'WebView 的 _t 写入 CookieJar 后读回不符，继续尝试自愈',
          'source': source,
          'verified': verified,
          'webViewTLen': _tokenLength(candidate),
          'webViewTHash': _safeTokenHash(candidate),
          'afterJarTLen': _tokenLength(afterJarTToken),
          'afterJarTHash': _safeTokenHash(afterJarTToken),
        });
      } else {
        webViewRejected = true;
        _markRejectedSessionCandidate(candidate);
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_startup_webview_token_rejected',
          'message': 'jar 没有 _t，WebView 的 _t 被服务端明确拒绝',
          'source': source,
          'webViewTLen': _tokenLength(candidate),
          'webViewTHash': _safeTokenHash(candidate),
        });
      }
    }

    final healedUser = await _recoverViaUserApiKeySelfHeal(
      source: source,
      triggerInfo: 'startup jar _t missing',
    );
    if (healedUser != null) {
      currentUserNotifier.value = healedUser;
      final healedTToken = await _cookieJar.getTToken();
      if (_hasTokenValue(healedTToken)) return healedTToken;
    }

    if (webViewRejected) {
      // 两端都是死值：会话确实已失效，按被动登出收尾，不要悄悄变匿名。
      await _handleAuthInvalid(
        S.current.auth_loginExpiredRelogin,
        source: 'startup_webview_token_rejected',
        triggerInfo: 'startup jar _t missing, WebView _t rejected',
      );
      return null;
    }

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'auth',
      'event': 'auth_startup_jar_token_missing',
      'message': 'jar 没有 _t 且 WebView 也没有可用会话，按未登录处理',
      'source': source,
      'webViewHasT': _hasTokenValue(webViewTToken),
      'storedUsernameLen': storedUsername.length,
    });
    return null;
  }

  /// 仅设置 token，不触发状态广播（登录流程中先设置 token，等数据就绪后再广播）
  void setToken(String tToken) {
    _clearPreviousTTokenFallback();
    // 新登录的 _t 与旧血缘无关，清掉旧的一致记录与候选环。
    SessionTokenLineage.instance.clear();
    _tToken = tToken;
    _credentialsLoaded = false;
  }

  /// 登录成功后通知监听者（应在预加载数据就绪后调用）
  /// 会话写入由显式边界同步统一处理。
  void onLoginSuccess(String tToken, {bool forceBrowserSessionSync = true}) {
    _clearPreviousTTokenFallback();
    SessionTokenLineage.instance.clear();
    _tToken = tToken;
    _credentialsLoaded = false;
    AuthIssueNoticeService.instance.clearSessionCookieRepairHint();
    WebViewSessionCookieRefreshService.instance.ensureInBackground(
      reason: 'login_success',
      force: forceBrowserSessionSync,
    );
    _authStateController.add(null);
  }

  /// 保存用户名
  Future<void> saveUsername(String username) async {
    _username = username;
    await _storage.write(key: DiscourseService._usernameKey, value: username);
  }

  /// 登出 API 调用的总超时。
  ///
  /// 撤销 User API Key + DELETE /session 两个请求合计。超时即放弃服务端
  /// 撤销、继续清本地——绝不让网络把登出 UI 卡住。
  static const Duration _logoutApiTimeout = Duration(seconds: 8);

  /// 登出后预加载刷新的超时。它只是为下一个匿名会话预热,不必久等。
  static const Duration _preloadRefreshTimeout = Duration(seconds: 10);

  /// 登出的服务端调用:撤销自愈凭证 + 删除会话。
  Future<void> _performLogoutApiCalls() async {
    // 显式登出:自愈凭证一并撤销,防止之后被自愈机制"复活"会话
    await UserApiKeyService().revokeAndClear(_dio);

    final usernameForLogout =
        _username ?? await _storage.read(key: DiscourseService._usernameKey);
    if (usernameForLogout == null || usernameForLogout.isEmpty) return;

    try {
      await _dio.delete(
        '/session/$usernameForLogout',
        options: Options(
          // 登出不该产生"会话失效"信号(它本来就是要失效)。
          // 自愈的豁免在策略侧按端点判定,见 SessionSelfHealPolicy。
          extra: const {FluxRequestKeys.skipAuthCheck: true},
        ),
      );
    } catch (e) {
      debugPrint('[DiscourseService] Logout API failed: $e');
    }
  }

  /// 登出
  Future<void> logout({bool callApi = true, bool refreshPreload = true}) async {
    // ===== 第一步：切断所有旧请求 =====
    AuthSession().advance();

    // ===== 第二步：主动停止后台 Service =====
    MessageBusService().stopAll();
    unawaited(CfClearanceRefreshService().stop());
    WebViewAdapterSettingsService.instance.resetSessionFallback();
    CfChallengeService().resetSessionCompatibilityDecision();
    // 在位 cf_clearance 的「被撞」标记随登录会话失效，一并清空
    CfClearanceAuthority.instance.reset();

    // ===== 第三步：调用登出 API（可选，用新的 generation） =====
    //
    // 整段带超时兜底:登出是用户的明确意图,本地状态清理(第四步起)绝不能
    // 被网络卡住。服务端会话没撤销掉是可接受的降级——本地凭证清干净后,
    // 那个会话也无法再被这台设备使用。
    if (callApi) {
      try {
        await _performLogoutApiCalls().timeout(_logoutApiTimeout);
      } on TimeoutException {
        debugPrint(
          '[DiscourseService] 登出 API 超时 '
          '(${_logoutApiTimeout.inSeconds}s),继续清理本地状态',
        );
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'logout_api_timeout',
          'message': '登出 API 超时，已跳过并继续清理本地状态',
          'timeoutSeconds': _logoutApiTimeout.inSeconds,
        });
      }
    }

    // ===== 第四步：清除内存状态 =====
    //
    // 第四~六步用 try/finally 包住:凭证已经清掉、状态广播却没发出去是最坏
    // 的中间态(UI 仍以为在登录中)。secure storage 写入与 cookie 清理都是
    // 平台通道调用,理论上可能抛,那时也必须把广播补上。
    try {
      _clearPreviousTTokenFallback();
      SessionTokenLineage.instance.clear();
      _tToken = null;
      _username = null;
      _cachedUserSummary = null;
      _cachedUserSummaryUsername = null;
      _userSummaryCacheTime = null;
      await _storage.delete(key: DiscourseService._usernameKey);
      _credentialsLoaded = false;
      // bootstrap 成功态是「进程 × 登录会话」级(浏览器语义:每页面加载一次),
      // 换账号 = 新浏览器会话,这里复位让下一个会话重新跑一次。
      WebViewSessionCookieRefreshService.instance.resetSessionState();

      // ===== 第五步：清除 Cookie（保留 cf_clearance）=====
      await _cookieSync.reset();
      final cfClearanceCookie = await _cookieJar.getCfClearanceCookie();
      await _cookieJar.clearAll();
      if (cfClearanceCookie != null) {
        await _cookieJar.restoreCfClearance(cfClearanceCookie);
      }

      // ===== 第六步：刷新预加载数据（确保新状态就绪后再广播）=====
      //
      // 尽力而为:这一步是为下一个匿名会话预热站点数据,不是登出的必要条件。
      // 它发 GET / 拉首页 HTML,可能撞 CF 盾、被限流、或解析失败抛
      // FormatException —— 任何一种都不该让登出流程中断。
      PreloadedDataService().reset();
      if (refreshPreload) {
        try {
          await PreloadedDataService().refresh().timeout(
            _preloadRefreshTimeout,
          );
        } catch (e) {
          debugPrint('[DiscourseService] 登出后预加载刷新失败(忽略): $e');
          LogWriter.instance.write({
            'timestamp': DateTime.now().toIso8601String(),
            'level': 'warning',
            'type': 'auth',
            'event': 'logout_preload_refresh_failed',
            'message': '登出后预加载刷新失败，已忽略并继续',
            'error': e.toString(),
          });
        }
      }
    } finally {
      // ===== 第七步：广播状态变更（无论前面是否出错都必须执行）=====
      currentUserNotifier.value = null;
      _authStateController.add(null);

      // ===== 第八步：重置 auth strike 状态 =====
      _resetStrikes();
    }
  }
}

/// 候选会话探测的结果：服务端接受 / 服务端明确拒绝 / 没结论。
class _CandidateProbeResult {
  const _CandidateProbeResult._({this.user, required this.conclusive});

  /// 服务端返回了 current_user。
  const _CandidateProbeResult.accepted(User user)
    : this._(user: user, conclusive: true);

  /// 服务端明确答复会话失效（404 / 带登出信号的 401、403）。
  const _CandidateProbeResult.rejected() : this._(conclusive: true);

  /// 网关错误、超时、撞盾、会话代已变等，探测本身没结论。
  const _CandidateProbeResult.inconclusive() : this._(conclusive: false);

  final User? user;

  /// 服务端给出了明确答复（接受或拒绝）。
  final bool conclusive;

  bool get accepted => user != null;
}
