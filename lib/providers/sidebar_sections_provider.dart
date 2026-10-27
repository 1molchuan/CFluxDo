import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sidebar_section.dart';
import '../services/site_context.dart';
import 'core_providers.dart';
import 'theme_provider.dart';

/// 网页侧栏的自定义分区（全站公开的 + 自己建的），与网页双向同步。
///
/// 按账号缓存在本机，打开时先用缓存、再在后台拉一次；增删改直接写服务端，
/// 成功后用服务端返回的那份更新列表和缓存。写请求串行，避免两次保存交错。
final sidebarSectionsProvider =
    AsyncNotifierProvider<SidebarSectionsNotifier, List<SidebarSection>>(
      SidebarSectionsNotifier.new,
    );

class SidebarSectionsNotifier extends AsyncNotifier<List<SidebarSection>> {
  int _generation = 0;
  String? _cacheKey;
  DateTime? _fetchedAt;
  Future<void> _writes = Future.value();

  /// 打开抽屉时距上次拉取超过这么久就后台刷新一次
  static const _staleAfter = Duration(minutes: 2);

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  Future<List<SidebarSection>> build() async {
    final generation = ++_generation;
    final userId = ref.watch(
      currentUserProvider.select((user) => user.value?.id),
    );
    if (userId == null) {
      _cacheKey = null;
      return const [];
    }
    final key = _cacheKey = SiteContext.storageKey('sidebar_sections_$userId');
    final cached = _readCache(key);
    if (cached != null) {
      // 等缓存这份先落进 state 再刷新（不然刷新结果可能先到、又被盖回缓存）
      Timer.run(() => _refresh(generation, background: true));
      return cached;
    }
    final fresh = await ref.read(discourseServiceProvider).getSidebarSections();
    _fetchedAt = DateTime.now();
    _writeCache(fresh);
    return fresh;
  }

  /// 打开抽屉 / 回到前台时调用：数据旧了就后台刷新
  void refreshIfStale() {
    final fetchedAt = _fetchedAt;
    if (_cacheKey == null || state.isLoading) return;
    if (fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _staleAfter) {
      return;
    }
    unawaited(_refresh(_generation, background: true));
  }

  Future<void> _refresh(int generation, {required bool background}) async {
    try {
      final fresh = await ref
          .read(discourseServiceProvider)
          .getSidebarSections(background: background);
      if (!ref.mounted || generation != _generation) return;
      _fetchedAt = DateTime.now();
      _writeCache(fresh);
      state = AsyncValue.data(fresh);
    } catch (e) {
      debugPrint('[SidebarSections] 刷新失败（保留缓存）: $e');
    }
  }

  Future<SidebarSection> create({
    required String title,
    required List<SidebarSectionLink> links,
  }) => _write(() async {
    final created = await ref
        .read(discourseServiceProvider)
        .createSidebarSection(title: title, links: links);
    _apply((sections) => [...sections, created]);
    return created;
  });

  Future<SidebarSection> save(
    SidebarSection section, {
    required String title,
    required List<SidebarSectionLink> links,
    Iterable<SidebarSectionLink> removedLinks = const [],
  }) => _write(() async {
    final updated = await ref
        .read(discourseServiceProvider)
        .updateSidebarSection(
          section.id,
          title: title,
          links: links,
          removedLinks: removedLinks,
        );
    _apply(
      (sections) => [
        for (final s in sections) s.id == updated.id ? updated : s,
      ],
    );
    return updated;
  });

  Future<void> delete(SidebarSection section) => _write(() async {
    await ref.read(discourseServiceProvider).deleteSidebarSection(section.id);
    _apply(
      (sections) => [
        for (final s in sections)
          if (s.id != section.id) s,
      ],
    );
  });

  Future<T> _write<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _apply(List<SidebarSection> Function(List<SidebarSection>) change) {
    if (!ref.mounted) return;
    final next = change(state.value ?? const []);
    _writeCache(next);
    state = AsyncValue.data(next);
  }

  List<SidebarSection>? _readCache(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          SidebarSection.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }

  void _writeCache(List<SidebarSection> sections) {
    final key = _cacheKey;
    if (key == null) return;
    unawaited(
      _prefs.setString(
        key,
        jsonEncode([for (final section in sections) section.toJson()]),
      ),
    );
  }
}
