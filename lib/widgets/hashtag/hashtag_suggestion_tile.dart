import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../models/hashtag_suggestion.dart';
import '../../utils/font_awesome_helper.dart';

/// `#` 补全下拉里的一行：分类显示自己的图标（或色块），标签显示标签图标，
/// 右侧标出类型（分类和标签可能同名）。
class HashtagSuggestionTile extends StatelessWidget {
  const HashtagSuggestionTile({
    super.key,
    required this.suggestion,
    required this.selected,
    required this.onTap,
  });

  final HashtagSuggestion suggestion;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Center(child: _leading(scheme)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                suggestion.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (suggestion.isCategory || suggestion.isTag) ...[
              const SizedBox(width: 8),
              Text(
                suggestion.isCategory
                    ? S.current.hashtag_typeCategory
                    : S.current.hashtag_typeTag,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _leading(ColorScheme scheme) {
    final color = _parseColor(
      suggestion.colors.isEmpty ? null : suggestion.colors.first,
    );
    if (suggestion.isTag) {
      final tagIcon = FontAwesomeHelper.getIcon(suggestion.icon ?? 'tag');
      return tagIcon != null
          ? Icon(tagIcon.data, size: 14, color: scheme.onSurfaceVariant)
          : Icon(Symbols.sell_rounded, size: 16, color: scheme.onSurfaceVariant);
    }
    final icon = suggestion.styleType == 'square'
        ? null
        : FontAwesomeHelper.getIcon(suggestion.icon);
    if (icon != null) {
      return Icon(icon.data, size: 15, color: color ?? scheme.primary);
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color ?? scheme.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    var value = hex.replaceAll('#', '');
    if (value.length == 3) {
      value = value.split('').map((c) => '$c$c').join();
    }
    if (value.length != 6) return null;
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? null : Color(0xFF000000 | parsed);
  }
}
