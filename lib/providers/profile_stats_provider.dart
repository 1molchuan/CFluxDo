import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/profile_stats_config.dart';
import '../services/site_context.dart';
import '../services/site_data_lifecycle.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

String get _configKey => SiteContext.storageKey('profile_stats_config');

/// 统计卡片配置 Provider
class ProfileStatsConfigNotifier extends Notifier<ProfileStatsConfig> {
  Timer? _saveTimer;
  @override
  ProfileStatsConfig build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final unregister = SiteDataLifecycle.register(_flush);
    ref.onDispose(() {
      unregister();
      _saveTimer?.cancel();
    });
    final jsonStr = prefs.getString(_configKey);
    if (jsonStr != null) {
      try {
        return _supportedConfig(ProfileStatsConfig.fromJsonString(jsonStr));
      } catch (_) {
        // 配置损坏，使用默认值
      }
    }
    return const ProfileStatsConfig();
  }

  void update(ProfileStatsConfig config) {
    state = _supportedConfig(config);
    _save(state);
  }

  void setLayoutMode(StatsLayoutMode mode) {
    update(state.copyWith(layoutMode: mode));
  }

  void setColumnsPerRow(int columns) {
    update(state.copyWith(columnsPerRow: columns));
  }

  void setDataSource(StatsDataSource source) {
    // 切换数据源时，自动移除不兼容的统计项
    final compatible = state.enabledStats
        .where((s) => isStatCompatible(s, source))
        .toList();
    update(state.copyWith(
      dataSource: source,
      enabledStats: compatible,
    ));
  }

  void setEnabledStats(List<ProfileStatType> stats) {
    update(state.copyWith(enabledStats: stats));
  }

  void addStat(ProfileStatType stat) {
    if (!state.enabledStats.contains(stat)) {
      update(state.copyWith(
        enabledStats: [...state.enabledStats, stat],
      ));
    }
  }

  void removeStat(ProfileStatType stat) {
    update(state.copyWith(
      enabledStats: state.enabledStats.where((s) => s != stat).toList(),
    ));
  }

  void reorderStats(int oldIndex, int newIndex) {
    final stats = List<ProfileStatType>.from(state.enabledStats);
    if (newIndex > oldIndex) newIndex -= 1;
    final item = stats.removeAt(oldIndex);
    stats.insert(newIndex, item);
    update(state.copyWith(enabledStats: stats));
  }

  ProfileStatsConfig _supportedConfig(ProfileStatsConfig config) {
    if (SiteContext.isLinuxDo || config.dataSource == StatsDataSource.summary) {
      return config;
    }
    return config.copyWith(
      dataSource: StatsDataSource.summary,
      enabledStats: config.enabledStats
          .where((stat) => isStatCompatible(stat, StatsDataSource.summary))
          .toList(),
    );
  }

  /// 防抖保存，切站时复用同一入口立即落盘。
  void _save(ProfileStatsConfig config) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _flush);
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await ref.read(sharedPreferencesProvider).setString(_configKey, state.toJsonString());
  }
}

final profileStatsConfigProvider =
    NotifierProvider<ProfileStatsConfigNotifier, ProfileStatsConfig>(
  ProfileStatsConfigNotifier.new,
);
