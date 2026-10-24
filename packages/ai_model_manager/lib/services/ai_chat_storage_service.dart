import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_chat_message.dart';
import '../models/ai_provider.dart';

/// AI 聊天记录持久化存储服务
///
/// 存储结构：
/// - `ai_chat_topic_sessions_{topicId}` — 某话题的会话列表（按 updatedAt 降序）
/// - `ai_chat_session_messages_{sessionId}` — 某会话的消息列表
/// - `ai_chat_all_sessions_index` — 全局会话索引（用于上限清理）
/// - `ai_chat_max_sessions` — 最大会话总数
/// - `ai_chat_title_model` — 标题生成模型 key
class AiChatStorageService {
  final String _allSessionsIndexKey;
  static const _maxSessionsKey = 'ai_chat_max_sessions';
  static const _titleModelKey = 'ai_chat_title_model';
  static const _imagePromptOptimizerModelKey = 'ai_image_prompt_optimizer_model';
  static const _thinkingLevelKey = 'ai_thinking_level';
  final String _topicSessionsKeyPrefix;
  final String _sessionMessagesKeyPrefix;
  static const _defaultMaxSessions = 50;

  final SharedPreferences _prefs;

  /// 会话按宿主站点隔离，模型、思考配置与通用上限仍然共用。
  AiChatStorageService(this._prefs, {String sessionNamespace = ''})
      : _allSessionsIndexKey = '${sessionNamespace}ai_chat_all_sessions_index',
        _topicSessionsKeyPrefix = '${sessionNamespace}ai_chat_topic_sessions_',
        _sessionMessagesKeyPrefix = '${sessionNamespace}ai_chat_session_messages_';

  // ===== 最大会话数管理 =====

  /// 获取最大会话总数
  int getMaxSessions() {
    return _prefs.getInt(_maxSessionsKey) ?? _defaultMaxSessions;
  }

  /// 设置最大会话总数
  Future<void> setMaxSessions(int value) async {
    await _prefs.setInt(_maxSessionsKey, value);
    await enforceLimit();
  }

  // ===== 标题生成模型 =====

  /// 获取标题生成模型 key（providerId:modelId）
  String? getTitleModelKey() {
    return _prefs.getString(_titleModelKey);
  }

  /// 设置标题生成模型 key
  Future<void> setTitleModelKey(String? key) async {
    if (key == null) {
      await _prefs.remove(_titleModelKey);
    } else {
      await _prefs.setString(_titleModelKey, key);
    }
  }

  // ===== 图像 Prompt 优化模型 =====
  // 用于在调 image gen 模型前先用一个聊天模型把话题上下文+用户简短指令
  // 翻译成精炼的 image prompt（200 词内、视觉化、英文常见关键词）。

  String? getImagePromptOptimizerModelKey() {
    return _prefs.getString(_imagePromptOptimizerModelKey);
  }

  Future<void> setImagePromptOptimizerModelKey(String? key) async {
    if (key == null) {
      await _prefs.remove(_imagePromptOptimizerModelKey);
    } else {
      await _prefs.setString(_imagePromptOptimizerModelKey, key);
    }
  }

  // ===== 思考深度 =====

  static const _thinkingCustomBudgetKey = 'ai_thinking_custom_budget';

  ThinkingConfig getThinkingConfig() {
    final idx = _prefs.getInt(_thinkingLevelKey);
    final level = (idx != null && idx >= 0 && idx < ThinkingLevel.values.length)
        ? ThinkingLevel.values[idx]
        : ThinkingLevel.off;
    final budget = _prefs.getInt(_thinkingCustomBudgetKey) ?? 8192;
    return ThinkingConfig(level: level, customBudget: budget);
  }

  Future<void> setThinkingConfig(ThinkingConfig config) async {
    await _prefs.setInt(_thinkingLevelKey, config.level.index);
    await _prefs.setInt(_thinkingCustomBudgetKey, config.customBudget);
  }

  // ===== 话题会话列表操作 =====

  /// 获取某话题的所有会话（按 updatedAt 降序）
  List<AiChatSession> getTopicSessions(int topicId) {
    final raw = _prefs.getString('$_topicSessionsKeyPrefix$topicId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AiChatSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存某话题的会话列表
  Future<void> _saveTopicSessions(
      int topicId, List<AiChatSession> sessions) async {
    final json = sessions.map((s) => s.toJson()).toList();
    await _prefs.setString(
        '$_topicSessionsKeyPrefix$topicId', jsonEncode(json));
  }

  // ===== 会话消息操作 =====

  /// 加载某会话的消息
  List<AiChatMessage> loadSessionMessages(String sessionId) {
    final raw = _prefs.getString('$_sessionMessagesKeyPrefix$sessionId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AiChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存某会话的消息，并更新会话索引
  Future<void> saveSessionMessages(
    int topicId,
    String sessionId,
    List<AiChatMessage> messages, {
    String? topicTitle,
  }) async {
    // 只保存已完成的消息
    final toSave = messages.where((m) {
      if (m.status == MessageStatus.streaming ||
          m.status == MessageStatus.sending) {
        return false;
      }
      return true;
    }).toList();

    if (toSave.isEmpty) {
      await deleteSession(topicId, sessionId);
      return;
    }

    // 保存消息
    final json = toSave.map((m) => m.toJson()).toList();
    await _prefs.setString(
        '$_sessionMessagesKeyPrefix$sessionId', jsonEncode(json));

    // 更新话题会话列表
    final sessions = getTopicSessions(topicId);
    final now = DateTime.now();
    final existingIndex = sessions.indexWhere((s) => s.id == sessionId);
    if (existingIndex >= 0) {
      // 更新时间并移到最前面
      final updated = sessions[existingIndex].copyWith(updatedAt: now);
      sessions.removeAt(existingIndex);
      sessions.insert(0, updated);
    } else {
      // 新会话，插入最前面
      sessions.insert(
          0, AiChatSession(id: sessionId, createdAt: now, updatedAt: now));
    }
    await _saveTopicSessions(topicId, sessions);

    // 更新全局索引
    await _updateGlobalIndex(topicId, sessionId, topicTitle: topicTitle);

    // 检查上限
    await enforceLimit();
  }

  /// 更新会话标题
  Future<void> updateSessionTitle(
      int topicId, String sessionId, String title) async {
    final sessions = getTopicSessions(topicId);
    final index = sessions.indexWhere((s) => s.id == sessionId);
    if (index < 0) return;

    sessions[index] = sessions[index].copyWith(title: title);
    await _saveTopicSessions(topicId, sessions);
  }

  /// 删除某个会话
  Future<void> deleteSession(int topicId, String sessionId) async {
    // 删除消息
    await _prefs.remove('$_sessionMessagesKeyPrefix$sessionId');

    // 从话题会话列表中移除
    final sessions = getTopicSessions(topicId);
    sessions.removeWhere((s) => s.id == sessionId);
    if (sessions.isEmpty) {
      await _prefs.remove('$_topicSessionsKeyPrefix$topicId');
    } else {
      await _saveTopicSessions(topicId, sessions);
    }

    // 从全局索引中移除
    await _removeFromGlobalIndex(sessionId);
  }

  /// 删除某话题的所有会话
  Future<void> deleteAllTopicSessions(int topicId) async {
    final sessions = getTopicSessions(topicId);
    for (final session in sessions) {
      await _prefs.remove('$_sessionMessagesKeyPrefix${session.id}');
      await _removeFromGlobalIndex(session.id);
    }
    await _prefs.remove('$_topicSessionsKeyPrefix$topicId');
  }

  /// 删除所有话题的所有会话
  Future<void> deleteAllSessions() async {
    final index = _loadGlobalIndex();
    final topicIds = <int>{};

    for (final item in index) {
      final sessionId = item['sessionId'] as String;
      final topicId = item['topicId'] as int;
      await _prefs.remove('$_sessionMessagesKeyPrefix$sessionId');
      topicIds.add(topicId);
    }

    for (final topicId in topicIds) {
      await _prefs.remove('$_topicSessionsKeyPrefix$topicId');
    }

    await _prefs.remove(_allSessionsIndexKey);
  }

  // ===== 全局索引与上限管理 =====

  /// 获取所有话题的会话分组列表（按最新更新时间降序）
  List<TopicSessionGroup> getAllTopicsWithSessions() {
    final index = _loadGlobalIndex();
    // 按 topicId 分组，保持顺序
    final topicOrder = <int>[];
    final topicTitles = <int, String?>{};
    final topicSessionIds = <int, List<String>>{};

    for (final item in index) {
      final topicId = item['topicId'] as int;
      final topicTitle = item['topicTitle'] as String?;
      if (!topicOrder.contains(topicId)) {
        topicOrder.add(topicId);
        topicTitles[topicId] = topicTitle;
      }
      // 更新为最新的标题
      if (topicTitle != null) {
        topicTitles[topicId] = topicTitle;
      }
      topicSessionIds.putIfAbsent(topicId, () => []);
    }

    final result = <TopicSessionGroup>[];
    for (final topicId in topicOrder) {
      final sessions = getTopicSessions(topicId);
      if (sessions.isNotEmpty) {
        result.add(TopicSessionGroup(
          topicId: topicId,
          topicTitle: topicTitles[topicId],
          sessions: sessions,
        ));
      }
    }
    return result;
  }

  /// 获取全局会话总数
  int getTotalSessionCount() {
    return _loadGlobalIndex().length;
  }

  /// 全局会话索引结构: [{topicId, topicTitle?, sessionId, updatedAt}]
  List<Map<String, dynamic>> _loadGlobalIndex() {
    final raw = _prefs.getString(_allSessionsIndexKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveGlobalIndex(List<Map<String, dynamic>> index) async {
    await _prefs.setString(_allSessionsIndexKey, jsonEncode(index));
  }

  /// 更新全局索引（将指定会话移到最前面）
  Future<void> _updateGlobalIndex(
    int topicId,
    String sessionId, {
    String? topicTitle,
  }) async {
    final index = _loadGlobalIndex();
    // 获取旧记录中的 topicTitle（如果本次没传入的话保留旧值）
    if (topicTitle == null) {
      final old = index.where((e) => e['topicId'] == topicId).firstOrNull;
      topicTitle = old?['topicTitle'] as String?;
    }
    index.removeWhere((e) => e['sessionId'] == sessionId);
    index.insert(0, {
      'topicId': topicId,
      'sessionId': sessionId,
      if (topicTitle != null) 'topicTitle': topicTitle,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    await _saveGlobalIndex(index);
  }

  /// 从全局索引中移除
  Future<void> _removeFromGlobalIndex(String sessionId) async {
    final index = _loadGlobalIndex();
    index.removeWhere((e) => e['sessionId'] == sessionId);
    await _saveGlobalIndex(index);
  }

  /// 当全局会话总数超过上限时，删除最旧的会话
  Future<void> enforceLimit() async {
    final index = _loadGlobalIndex();
    final maxSessions = getMaxSessions();

    if (index.length <= maxSessions) return;

    // index 按 updatedAt 降序排列，删除尾部多余的
    final toRemove = index.sublist(maxSessions);
    for (final item in toRemove) {
      final topicId = item['topicId'] as int;
      final sessionId = item['sessionId'] as String;

      // 删除消息
      await _prefs.remove('$_sessionMessagesKeyPrefix$sessionId');

      // 从话题会话列表中移除
      final sessions = getTopicSessions(topicId);
      sessions.removeWhere((s) => s.id == sessionId);
      if (sessions.isEmpty) {
        await _prefs.remove('$_topicSessionsKeyPrefix$topicId');
      } else {
        await _saveTopicSessions(topicId, sessions);
      }
    }

    // 只保留上限内的索引
    final kept = index.sublist(0, maxSessions);
    await _saveGlobalIndex(kept);
  }
}
