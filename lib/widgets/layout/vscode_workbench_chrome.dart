import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/vscode_body_style.dart';
import '../../providers/preferences_provider.dart';
import '../../navigation/nav_action_bus.dart';
import '../../pages/settings_page.dart';
import '../../providers/selected_topic_provider.dart';
import '../../services/site_context.dart';
import '../../theme/vscode_theme.dart';
import '../topic/category_drawer.dart';
import 'adaptive_navigation.dart';
import 'site_switch_button.dart';
import 'vscode_reader_status_scope.dart';

/// 只保留工作区入口；分类与标签复用临时抽屉，不另建常驻导航列。
class VscodeActivityBar extends StatelessWidget {
  const VscodeActivityBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.bottomLeading,
  });

  static const width = 52.0;
  final List<AdaptiveDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Widget? bottomLeading;

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    final profileIndex = destinations.indexWhere(
      (item) => item.id == NavEntryIds.profile,
    );
    return ColoredBox(
      color: tokens.panel,
      child: SizedBox(
        width: width,
        child: SafeArea(
          child: Column(
            children: [
              const SiteSwitchButton(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var index = 0; index < destinations.length; index++)
                        if (index != profileIndex)
                          _ActivityButton(
                            label: destinations[index].label,
                            selected: index == selectedIndex,
                            icon: destinations[index].id == 'home'
                                ? const Icon(Icons.file_copy_outlined)
                                : index == selectedIndex
                                ? destinations[index].selectedIcon
                                : destinations[index].icon,
                            onPressed: () => onDestinationSelected(index),
                          ),
                      _ActivityButton(
                        label: context.l10n.topics_browseCategories,
                        icon: const Icon(Icons.account_tree_outlined),
                        onPressed: () => CategoryDrawerHost.isOpen
                            ? CategoryDrawerHost.close()
                            : CategoryDrawerHost.open(),
                      ),
                    ],
                  ),
                ),
              ),
              ?bottomLeading,
              if (profileIndex >= 0)
                _ActivityButton(
                  label: destinations[profileIndex].label,
                  selected: profileIndex == selectedIndex,
                  icon: profileIndex == selectedIndex
                      ? destinations[profileIndex].selectedIcon
                      : destinations[profileIndex].icon,
                  onPressed: () => onDestinationSelected(profileIndex),
                ),
              _ActivityButton(
                label: context.l10n.settings_title,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    return Semantics(
      selected: selected,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 2,
              color: selected ? tokens.accent : Colors.transparent,
            ),
          ),
        ),
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            foregroundColor: selected ? tokens.foreground : tokens.muted,
            shape: const RoundedRectangleBorder(),
            minimumSize: const Size(50, 46),
          ),
          icon: icon,
        ),
      ),
    );
  }
}

/// 显示真实工作区与话题标识，不伪造光标位置或网络状态。
class VscodeStatusBar extends ConsumerWidget {
  const VscodeStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = VscodeTokens.maybeOf(context)!;
    final topicId = ref.watch(selectedTopicProvider.select((s) => s.topicId));
    final bodyOptions = ref.watch(
      preferencesProvider.select(
        (prefs) => (prefs.vscodeBodyStyle, prefs.vscodeCodeLanguage),
      ),
    );
    final controller = VscodeReaderStatusScope.maybeOf(context);
    final language = bodyOptions.$1 == VscodeBodyStyle.compact
        ? 'Markdown'
        : bodyOptions.$2 == VscodeCodeLanguage.java
        ? 'Java'
        : 'Python';
    Widget content(Widget? controls) => Theme(
      data: VscodeTheme.toolbarTheme(Theme.of(context)),
      child: Material(
        key: const ValueKey('vscode-workbench-status'),
        color: tokens.panel,
        child: Container(
          height: 33,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.border)),
          ),
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: tokens.muted,
              fontSize: 11,
            ),
            child:
                (controls == null
                    ? null
                    : Padding(
                        padding: EdgeInsets.only(
                          left: controller!.leadingInset,
                        ),
                        child: controls,
                      )) ??
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_tree_outlined,
                        size: 16,
                        color: tokens.muted,
                      ),
                      const SizedBox(width: 6),
                      Text(SiteContext.current.name),
                      if (topicId != null) ...[
                        const SizedBox(width: 16),
                        Text('#$topicId'),
                      ],
                      const Spacer(),
                      if (topicId != null) Text(language),
                      const SizedBox(width: 12),
                      const Text('Windows'),
                    ],
                  ),
                ),
          ),
        ),
      ),
    );
    return controller == null
        ? content(null)
        : ValueListenableBuilder<Widget?>(
            valueListenable: controller,
            builder: (context, controls, _) => content(controls),
          );
  }
}
