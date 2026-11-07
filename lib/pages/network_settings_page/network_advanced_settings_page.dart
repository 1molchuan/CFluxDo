import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../settings/definitions/network_defs.dart';
import '../../widgets/settings/settings_group_page.dart';

/// 高级网络设置：节点优选方式、连接加速总开关与 DNS、引擎组合、限流与上传、调试
class NetworkAdvancedSettingsPage extends StatelessWidget {
  final String? highlightId;

  const NetworkAdvancedSettingsPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.networkSettings_advancedTitle,
      groupsBuilder: buildNetworkAdvancedGroups,
      highlightId: highlightId,
    );
  }
}
