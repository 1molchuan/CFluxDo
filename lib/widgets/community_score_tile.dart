import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../pages/webview_page.dart';
import '../providers/core_providers.dart';
import '../utils/number_utils.dart';

/// 「我的」页余额卡组里的社区点数行：当前用户的社区点数（Discourse
/// gamification 的 gamification_score，随 current_user 一起下发），点开站点排行榜。
/// 版式与同组的 LDC / CDK 行一致。游客或站点没开插件（字段缺失）时不占位。
class CommunityScoreTile extends ConsumerWidget {
  const CommunityScoreTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final score = ref.watch(
      currentUserProvider.select((u) => u.value?.gamificationScore),
    );
    if (score == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Material(
      key: const ValueKey('profile-community-score'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => WebViewPage.open(
          context,
          '${AppConstants.baseUrl}/leaderboard',
          title: l10n.topics_leaderboard,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Symbols.stars_rounded,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.profile_communityScore,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      NumberUtils.formatThousands(score),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                l10n.topics_leaderboard,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Symbols.chevron_right_rounded,
                color: scheme.outline.withValues(alpha: 0.4),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
