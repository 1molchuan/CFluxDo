import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import '../../theme/vscode_theme.dart';
import '../../utils/color_utils.dart';
import '../../utils/time_utils.dart';
import 'topic_card.dart';

/// 资源管理器叶节点：统一树缩进，文件图标沿用真实分类颜色。
class VscodeTopicRow extends StatelessWidget {
  const VscodeTopicRow({
    super.key,
    required this.topic,
    required this.isSelected,
    required this.onTap,
    this.onMiddleClick,
    this.onLongPress,
    this.onPreviewIntent,
    this.highlightColor,
    this.category,
  });

  final Topic topic;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onMiddleClick;
  final VoidCallback? onLongPress;
  final VoidCallback? onPreviewIntent;
  final Color? highlightColor;
  final Category? category;

  @override
  Widget build(BuildContext context) {
    final tokens = VscodeTokens.maybeOf(context)!;
    final theme = Theme.of(context);
    final unread = topic.unseen || topic.unread > 0 || topic.newPosts > 0;
    final rawColor = int.tryParse(
      category?.color.replaceFirst('#', '') ?? '',
      radix: 16,
    );
    final fileColor = rawColor == null
        ? tokens.muted
        : ColorUtils.readableOn(Color(0xFF000000 | rawColor), theme.brightness);
    final author = topic.posters.isNotEmpty
        ? topic.posters.first.user?.displayName
        : topic.lastPosterUsername;
    // 论坛元信息保留给辅助技术，不再把文件树排成论坛统计表。
    final metadata = [
      if (category != null) category!.name,
      if (author != null && author.isNotEmpty) author,
      context.l10n.topic_replyCount(topic.replyCount),
      if (topic.lastPostedAt != null)
        TimeUtils.formatDetailTime(topic.lastPostedAt),
    ].join(' · ');

    return Semantics(
      selected: isSelected,
      label: metadata,
      child: ColoredBox(
        color:
            highlightColor ?? (isSelected ? tokens.selection : tokens.sidebar),
        child: TopicCardInteractiveSurface(
          borderRadius: BorderRadius.zero,
          onTap: onTap,
          onMiddleClick: onMiddleClick,
          onLongPress: onLongPress,
          onPreviewIntent: onPreviewIntent,
          child: Padding(
            padding: const EdgeInsets.only(left: 22),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: tokens.border)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 4, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 16,
                      color: fileColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        topic.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13,
                          height: 1.25,
                          color: tokens.foreground,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    if (topic.pinned) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.push_pin_outlined,
                        size: 12,
                        color: tokens.muted,
                      ),
                    ],
                    if (topic.closed) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.lock_outline,
                        size: 12,
                        color: tokens.muted,
                        semanticLabel: context.l10n.search_statusClosed,
                      ),
                    ],
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 6,
                      height: 6,
                      child: unread
                          ? Semantics(
                              label: context.l10n.topics_unreadTopics,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: tokens.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
