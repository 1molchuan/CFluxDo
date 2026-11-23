import 'package:flutter/material.dart';

import '../l10n/s.dart';
import '../settings/definitions/reading_defs.dart';
import '../widgets/settings/settings_group_page.dart';

/// 进度条手势：总开关、三个滑动方向的动作、长按菜单
class ProgressGestureSettingsPage extends StatelessWidget {
  final String? highlightId;

  const ProgressGestureSettingsPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.progressGesture_title,
      groupsBuilder: buildProgressGestureGroups,
      highlightId: highlightId,
    );
  }
}
