import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log/log_writer.dart';
import 'site_context.dart';

class PassiveLogoutAdvice {
  const PassiveLogoutAdvice({
    this.mentionCookieRepair = false,
    this.suggestClearData = false,
    this.recentPassiveLogoutCount = 0,
    this.repairedCookieNames = const [],
  });

  final bool mentionCookieRepair;
  final bool suggestClearData;
  final int recentPassiveLogoutCount;
  final List<String> repairedCookieNames;

  bool get hasAdvice => mentionCookieRepair || suggestClearData;
}

class AuthIssueNoticeService {
  AuthIssueNoticeService._internal();

  static final AuthIssueNoticeService instance =
      AuthIssueNoticeService._internal();

  static String get _passiveLogoutHistoryKey =>
      SiteContext.storageKey('auth_passive_logout_history_v1');
  static String get _clearDataSuggestionAtKey =>
      SiteContext.storageKey('auth_clear_data_suggestion_at_v1');
  static const Duration _frequentLogoutWindow = Duration(hours: 24);
  static const int _frequentLogoutThreshold = 3;
  static const Duration _clearDataSuggestionCooldown = Duration(hours: 12);

  SharedPreferences? _prefs;
  bool _pendingCookieRepairHint = false;
  List<String> _pendingCookieRepairNames = const [];
  PassiveLogoutAdvice? _latestPassiveLogoutAdvice;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
  }

  Future<void> recordSessionCookieRepair({
    required Iterable<String> cookieNames,
    required String source,
  }) async {
    final normalizedNames = cookieNames
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();

    _pendingCookieRepairHint = true;
    _pendingCookieRepairNames = normalizedNames;

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'auth',
      'event': 'session_cookie_repair_recorded',
      'message': '已记录 session cookie 修复提示，若随后掉登录将提醒用户',
      'source': source,
      'cookieNames': normalizedNames,
    });
  }

  void clearSessionCookieRepairHint() {
    _pendingCookieRepairHint = false;
    _pendingCookieRepairNames = const [];
  }

  Future<void> recordPassiveLogout() async {
    final prefs = await _ensurePrefs();
    final now = DateTime.now();
    final history = _loadPassiveLogoutHistory(prefs)
        .where((time) => now.difference(time) <= _frequentLogoutWindow)
        .toList(growable: true)
      ..add(now);

    await prefs.setStringList(
      _passiveLogoutHistoryKey,
      history.map((time) => time.toIso8601String()).toList(growable: false),
    );

    final lastSuggestionAt = _readDateTime(
      prefs.getString(_clearDataSuggestionAtKey),
    );
    final shouldSuggestClearData =
        history.length >= _frequentLogoutThreshold &&
        (lastSuggestionAt == null ||
            now.difference(lastSuggestionAt) >=
                _clearDataSuggestionCooldown);

    if (shouldSuggestClearData) {
      await prefs.setString(
        _clearDataSuggestionAtKey,
        now.toIso8601String(),
      );
    }

    _latestPassiveLogoutAdvice = PassiveLogoutAdvice(
      mentionCookieRepair: _pendingCookieRepairHint,
      suggestClearData: shouldSuggestClearData,
      recentPassiveLogoutCount: history.length,
      repairedCookieNames: List.unmodifiable(_pendingCookieRepairNames),
    );

    LogWriter.instance.write({
      'timestamp': now.toIso8601String(),
      'level': _latestPassiveLogoutAdvice!.hasAdvice ? 'warning' : 'info',
      'type': 'auth',
      'event': 'passive_logout_advice',
      'message': '已生成被动退出提示信息',
      'mentionCookieRepair': _latestPassiveLogoutAdvice!.mentionCookieRepair,
      'suggestClearData': _latestPassiveLogoutAdvice!.suggestClearData,
      'recentPassiveLogoutCount':
          _latestPassiveLogoutAdvice!.recentPassiveLogoutCount,
      'repairedCookieNames': _latestPassiveLogoutAdvice!.repairedCookieNames,
    });

    clearSessionCookieRepairHint();
  }

  PassiveLogoutAdvice consumeLatestPassiveLogoutAdvice() {
    final advice = _latestPassiveLogoutAdvice ?? const PassiveLogoutAdvice();
    _latestPassiveLogoutAdvice = null;
    return advice;
  }

  Future<SharedPreferences> _ensurePrefs() async {
    final prefs = _prefs;
    if (prefs != null) {
      return prefs;
    }
    final loaded = await SharedPreferences.getInstance();
    _prefs = loaded;
    return loaded;
  }

  List<DateTime> _loadPassiveLogoutHistory(SharedPreferences prefs) {
    final values = prefs.getStringList(_passiveLogoutHistoryKey) ?? const [];
    return values
        .map(_readDateTime)
        .whereType<DateTime>()
        .toList(growable: false);
  }

  DateTime? _readDateTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return DateTime.parse(raw);
    } catch (e) {
      debugPrint('[AuthIssueNotice] Failed to parse time: $e');
      return null;
    }
  }
}
