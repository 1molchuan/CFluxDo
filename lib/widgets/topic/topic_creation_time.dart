import 'package:flutter/material.dart';

import '../../theme/mojian_theme.dart';
import '../../utils/relative_time_clock.dart';
import '../../utils/time_utils.dart';
import '../common/relative_time_text.dart';

/// 自绘列表没有逐项 Provider 订阅，通过同一快照通知在屏卡片即时重排。
abstract final class TopicCreationTimeScope {
  static final enabled = ValueNotifier<bool>(true);

  @visibleForTesting
  static DateTime Function()? debugNow;

  static DateTime now() => debugNow?.call() ?? DateTime.now();
}

/// 输入已经由 TimeUtils 转为本地时间；用日历字段计算，避免夏令时的 23/25 小时日。
int topicCreationDayAge(DateTime createdAt, DateTime now) =>
    DateTime.utc(now.year, now.month, now.day)
        .difference(
          DateTime.utc(createdAt.year, createdAt.month, createdAt.day),
        )
        .inDays;

Color topicCreationTimeColor(
  ThemeData theme,
  DateTime createdAt,
  DateTime now,
) {
  final days = topicCreationDayAge(createdAt, now);
  final mj = theme.extension<MojianTokens>();
  final scheme = theme.colorScheme;
  // 使用主题为文字定义的前景角色，不把品牌色的 HSL 亮度当作对比度保证。
  if (days <= 0) return mj?.accent ?? scheme.onPrimaryContainer;
  if (days <= 7) return mj?.jade ?? scheme.tertiary;
  if (days <= 30) return mj?.ink2 ?? scheme.onSurface;
  return mj?.ink3 ?? scheme.onSurfaceVariant;
}

String topicCreationTimeText(DateTime createdAt, DateTime now) =>
    topicCreationDayAge(createdAt, now) <= 0
    ? TimeUtils.formatClockTime(createdAt)
    : TimeUtils.formatShortDate(createdAt);

/// 仅供话题列表使用：发帖绝对日期在左，最后回复相对时间在右。
class TopicListTimes extends StatefulWidget {
  const TopicListTimes({
    super.key,
    required this.createdAt,
    required this.lastPostedAt,
    required this.replyStyle,
  });

  final DateTime? createdAt;
  final DateTime? lastPostedAt;
  final TextStyle? replyStyle;

  @override
  State<TopicListTimes> createState() => _TopicListTimesState();
}

class _TopicListTimesState extends State<TopicListTimes> {
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    TopicCreationTimeScope.enabled.addListener(_onTick);
  }

  void _onTick() => setState(() {});

  void _setSubscribed(bool value) {
    if (_subscribed == value) return;
    _subscribed = value;
    if (value) {
      RelativeTimeClock.instance.addListener(_onTick);
    } else {
      RelativeTimeClock.instance.removeListener(_onTick);
    }
  }

  @override
  void dispose() {
    TopicCreationTimeScope.enabled.removeListener(_onTick);
    _setSubscribed(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final created = widget.createdAt;
    final enabled = TopicCreationTimeScope.enabled.value;
    _setSubscribed(
      enabled && created != null && TickerMode.valuesOf(context).enabled,
    );
    if (!enabled || created == null) {
      return RelativeTimeText(
        dateTime: widget.lastPostedAt,
        style: widget.replyStyle,
      );
    }
    final now = TopicCreationTimeScope.now();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            topicCreationTimeText(created, now),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (widget.replyStyle ?? const TextStyle()).copyWith(
              color: topicCreationTimeColor(Theme.of(context), created, now),
            ),
          ),
        ),
        Text(' · ', style: widget.replyStyle),
        Flexible(
          child: Tooltip(
            message: TimeUtils.formatTooltipTime(widget.lastPostedAt),
            child: Text(
              TimeUtils.formatRelativeTime(widget.lastPostedAt),
              style: widget.replyStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}
