import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../providers/topic_detail/topic_view_mode.dart';
import '../../../theme/mojian_theme.dart';
import '../../../theme/vscode_theme.dart';

import 'package:common_ui/common_ui.dart';

/// 话题阅读工具栏：VS Code 放在标题栏，其余主题保留底栏。
class TopicBottomBar extends StatelessWidget {
  final VoidCallback? onScrollToTop;
  final VoidCallback? onShare;
  final VoidCallback? onShareAsImage;
  final VoidCallback? onExport;
  final VoidCallback? onOpenInBrowser;
  final bool hasSummary;
  final bool isPostVoting;
  final TopicViewMode viewMode;
  final bool isNestedMode;
  final bool isLoading;
  final VoidCallback? onShowTopReplies;
  final VoidCallback? onShowByActivity;
  final VoidCallback? onShowAuthorOnly;
  final VoidCallback? onShowTopLevelReplies;
  final VoidCallback? onCancelFilter;
  final VoidCallback? onShowNestedView;
  final bool isPrivateMessage;

  /// 墨笺窄栏:叠在常驻阅读条上方,只占一行、不带底部安全区
  final bool docked;

  /// [docked] 时的高度
  static const double dockedHeight = 44;

  const TopicBottomBar({
    super.key,
    this.onScrollToTop,
    this.onShare,
    this.onShareAsImage,
    this.onExport,
    this.onOpenInBrowser,
    this.hasSummary = false,
    this.isPostVoting = false,
    this.viewMode = TopicViewMode.all,
    this.isNestedMode = false,
    this.isLoading = false,
    this.isPrivateMessage = false,
    this.onShowTopReplies,
    this.onShowByActivity,
    this.onShowAuthorOnly,
    this.onShowTopLevelReplies,
    this.onCancelFilter,
    this.onShowNestedView,
    this.docked = false,
  });

  bool get _hasActiveFilter => viewMode.isFiltered || isNestedMode;

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final vscode = VscodeTokens.maybeOf(context);
    final theme = vscode == null
        ? inheritedTheme
        : VscodeTheme.toolbarTheme(inheritedTheme);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final mj = theme.extension<MojianTokens>();

    return Theme(
      data: theme,
      child: Container(
        height: vscode != null ? 32 : (docked ? dockedHeight : 80),
        padding: EdgeInsets.only(
          bottom: vscode != null || docked ? 0 : bottomPadding,
        ),
        decoration: BoxDecoration(
          color: vscode == null ? theme.colorScheme.surface : null,
          border: mj == null ? null : Border(top: BorderSide(color: mj.rule)),
        ),
        child: Row(
          mainAxisSize: vscode != null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            if (vscode == null) const SizedBox(width: 8),
            // 回到顶部
            IconButton(
              onPressed: onScrollToTop,
              icon: const Icon(Symbols.vertical_align_top_rounded),
              tooltip: context.l10n.topicDetail_scrollToTop,
            ),
            // 筛选
            if (_hasActiveFilter)
              _buildActiveFilterChip(context, theme)
            else
              _buildFilterMenuButton(context, theme),
            // 分享菜单
            _buildShareMenu(context, theme),
            // 在浏览器打开
            IconButton(
              onPressed: onOpenInBrowser,
              icon: const Icon(Symbols.language_rounded),
              tooltip: context.l10n.topicDetail_openInBrowser,
            ),
          ],
        ),
      ),
    );
  }

  /// 激活态：紧凑图标按钮 + 小关闭按钮
  Widget _buildActiveFilterChip(BuildContext context, ThemeData theme) {
    final (icon, _) = _activeFilterInfo(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: isLoading ? null : onCancelFilter,
          icon: Icon(icon, color: theme.colorScheme.primary),
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.primaryContainer,
          ),
          iconSize: theme.extension<VscodeTokens>() == null ? 20 : 16,
          visualDensity: theme.extension<VscodeTokens>() == null
              ? VisualDensity.compact
              : VisualDensity.standard,
        ),
      ],
    );
  }

  (IconData, String) _activeFilterInfo(BuildContext context) {
    if (viewMode.isSummary)
      return (
        Symbols.local_fire_department_rounded,
        context.l10n.topicDetail_hotOnly,
      );
    if (viewMode.isActivity)
      return (Symbols.history_rounded, context.l10n.topicDetail_sortByActivity);
    if (viewMode.isUserFilter)
      return (Symbols.person_rounded, context.l10n.topicDetail_authorOnly);
    if (viewMode.isTopLevel)
      return (
        Symbols.account_tree_rounded,
        context.l10n.topicDetail_topLevelOnly,
      );
    if (isNestedMode) return (Symbols.forum_rounded, context.l10n.nested_title);
    return (Symbols.filter_list_rounded, '');
  }

  /// 未激活：筛选菜单按钮
  Widget _buildFilterMenuButton(BuildContext context, ThemeData theme) {
    return SwipeDismissiblePopupMenuButton<String>(
      enabled: !isLoading,
      icon: const Icon(Symbols.filter_list_rounded),
      iconColor: theme.colorScheme.onSurfaceVariant,
      tooltip: context.l10n.topicDetail_filter,
      onSelected: (value) {
        switch (value) {
          case 'hot':
            onShowTopReplies?.call();
          case 'activity':
            onShowByActivity?.call();
          case 'author':
            onShowAuthorOnly?.call();
          case 'top_level':
            onShowTopLevelReplies?.call();
          case 'nested':
            onShowNestedView?.call();
        }
      },
      itemBuilder: (context) => [
        if (isPostVoting)
          PopupMenuItem(
            value: 'activity',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.history_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_sortByActivity),
              ],
            ),
          ),
        if (hasSummary)
          PopupMenuItem(
            value: 'hot',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.local_fire_department_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_hotOnly),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'author',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.person_rounded,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_authorOnly),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'top_level',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.account_tree_rounded,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_topLevelOnly),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'nested',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.forum_rounded,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.nested_title),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShareMenu(BuildContext context, ThemeData theme) {
    return SwipeDismissiblePopupMenuButton<String>(
      icon: const Icon(Symbols.share_rounded),
      iconColor: theme.colorScheme.onSurfaceVariant,
      tooltip: context.l10n.common_share,
      onSelected: (value) {
        switch (value) {
          case 'link':
            onShare?.call();
            break;
          case 'image':
            onShareAsImage?.call();
            break;
          case 'export':
            onExport?.call();
            break;
        }
      },
      itemBuilder: (context) => [
        // 私信话题不显示链接分享和生成分享图
        if (!isPrivateMessage)
          PopupMenuItem(
            value: 'link',
            child: Row(
              children: [
                Icon(
                  Symbols.link_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_shareLink),
              ],
            ),
          ),
        if (!isPrivateMessage)
          PopupMenuItem(
            value: 'image',
            child: Row(
              children: [
                Icon(
                  Symbols.image_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 12),
                Text(context.l10n.topicDetail_generateShareImage),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'export',
          child: Row(
            children: [
              Icon(
                Symbols.download_rounded,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              Text(context.l10n.topicDetail_exportArticle),
            ],
          ),
        ),
      ],
    );
  }
}
