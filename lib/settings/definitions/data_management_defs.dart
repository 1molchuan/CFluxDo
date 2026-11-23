import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../providers/preferences_provider.dart';
import '../../pages/data_management_page.dart';
import '../../pages/notion_settings_page.dart';
import '../settings_model.dart';

/// 数据管理设置数据声明
List<SettingsGroup> buildDataManagementGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // Section 1 — 缓存管理
    SettingsGroup(
      title: l10n.dataManagement_cacheManagement,
      icon: Symbols.cleaning_services_rounded,
      // 区块内部自带分段卡片
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'cacheManagement',
          title: l10n.dataManagement_cacheManagement,
          builder: (context, ref) => const CacheManagementSection(),
        ),
      ],
    ),

    // Section 2 — 退出时自动清理（并在缓存这一组下面，不单独起标题）
    SettingsGroup(
      title: '',
      icon: Symbols.auto_delete_rounded,
      items: [
        SwitchModel(
          id: 'clearOnExit',
          title: l10n.dataManagement_clearOnExit,
          subtitle: l10n.dataManagement_clearOnExitDesc,
          icon: Symbols.auto_delete_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).clearCacheOnExit,
          onChanged: (ref, value) =>
              ref.read(preferencesProvider.notifier).setClearCacheOnExit(value),
        ),
      ],
    ),

    // Section 3 — 数据备份
    SettingsGroup(
      title: l10n.dataManagement_dataBackup,
      icon: Symbols.backup_rounded,
      // 区块内部自带分段卡片
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'dataBackup',
          title: l10n.dataManagement_dataBackup,
          builder: (context, ref) => const DataBackupSection(),
        ),
      ],
    ),

    // Section 4 — 同步到 Notion（原来是设置总页里单独的一个入口）
    SettingsGroup(
      title: '',
      icon: Symbols.cloud_sync_rounded,
      items: [
        ActionModel(
          id: 'notionSync',
          title: l10n.notion_title,
          subtitle: l10n.notion_subtitle,
          icon: Symbols.cloud_sync_rounded,
          onTap: (context, _) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NotionSettingsPage()),
          ),
        ),
      ],
    ),
  ];
}
