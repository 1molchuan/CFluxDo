import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/read_later_item.dart';
import '../services/site_context.dart';
import '../services/site_data_lifecycle.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 稍后阅读列表最大数量
const int maxReadLaterItems = 10;

/// 稍后阅读状态管理
class ReadLaterNotifier extends StateNotifier<List<ReadLaterItem>> {
  static String get _storageKey => SiteContext.storageKey('read_later_items');

  final SharedPreferences _prefs;

  ReadLaterNotifier(this._prefs) : super(_load(_prefs));

  /// 从 SharedPreferences 加载列表
  static List<ReadLaterItem> _load(SharedPreferences prefs) {
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr == null) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.map((e) => ReadLaterItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 添加话题到稍后阅读
  /// 已存在则更新位置并移到头部，满 10 个返回 false
  bool add(ReadLaterItem item) {
    final list = [...state];

    // 去重：已存在则更新位置并移到头部
    final existingIndex = list.indexWhere((e) => e.topicId == item.topicId);
    if (existingIndex >= 0) {
      list.removeAt(existingIndex);
      list.insert(0, item);
      state = list;
      _save();
      return true;
    }

    // 满 10 个
    if (list.length >= maxReadLaterItems) return false;

    list.insert(0, item);
    state = list;
    _save();
    return true;
  }

  /// 移除话题
  void remove(int topicId) {
    state = state.where((e) => e.topicId != topicId).toList();
    _save();
  }

  /// 检查是否已在列表中
  bool contains(int topicId) {
    return state.any((e) => e.topicId == topicId);
  }

  /// 持久化到 SharedPreferences
  Future<void> _save() async {
    final jsonStr = jsonEncode(state.map((e) => e.toJson()).toList());
    await _prefs.setString(_storageKey, jsonStr);
  }
}

/// 应用是否已完成初始化（PreheatGate 之后）
final appReadyProvider = StateProvider<bool>((ref) => false);

final readLaterProvider =
    StateNotifierProvider<ReadLaterNotifier, List<ReadLaterItem>>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final notifier = ReadLaterNotifier(prefs);
  final unregister = SiteDataLifecycle.register(notifier._save);
  ref.onDispose(unregister);
  return notifier;
});
