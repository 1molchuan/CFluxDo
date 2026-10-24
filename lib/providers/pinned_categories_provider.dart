// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/site_context.dart';
import '../services/site_data_lifecycle.dart';
import 'theme_provider.dart';

/// 已固定的分类 ID 列表（用于首页分类 Tab）
class PinnedCategoriesNotifier extends StateNotifier<List<int>> {
  static String get _key => SiteContext.storageKey('pinned_category_ids');
  final SharedPreferences _prefs;

  PinnedCategoriesNotifier(this._prefs) : super(_load(_prefs));

  static List<int> _load(SharedPreferences prefs) {
    final list = prefs.getStringList(_key);
    if (list == null) return [];
    return list.map((s) => int.tryParse(s)).whereType<int>().toList();
  }

  void add(int categoryId) {
    if (state.contains(categoryId)) return;
    state = [...state, categoryId];
    _save();
  }

  void remove(int categoryId) {
    state = state.where((id) => id != categoryId).toList();
    _save();
  }

  void reorder(int oldIndex, int newIndex) {
    final list = [...state];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    state = list;
    _save();
  }

  Future<void> _save() async {
    await _prefs.setStringList(_key, state.map((id) => id.toString()).toList());
  }
}

final pinnedCategoriesProvider =
    StateNotifierProvider<PinnedCategoriesNotifier, List<int>>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final notifier = PinnedCategoriesNotifier(prefs);
  final unregister = SiteDataLifecycle.register(notifier._save);
  ref.onDispose(unregister);
  return notifier;
});
