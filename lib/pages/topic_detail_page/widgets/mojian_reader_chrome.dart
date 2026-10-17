import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../theme/mojian_theme.dart';
import '../../../utils/responsive.dart';
import '../../../utils/time_utils.dart';
import 'topic_progress_gestures.dart';

/// 墨笺的阅读控件:手机/窄栏是底部阅读条 [MojianReaderBar],
/// 宽栏是正文右侧的竖向时间轴 [MojianTimeline]。
/// 只在墨笺下由 [TopicDetailOverlay] 挂载;经典沿用楼层胶囊 + 回复按钮。
enum MojianReaderMode { bar, timeline }

/// 时间轴列宽、与正文的间距:正文列(maxContentWidth)居中后,
/// 右侧留白要放得下「间距 + 时间轴 + 呼吸」才用时间轴,否则用阅读条。
const double kMojianTimelineWidth = 112;
const double kMojianTimelineGap = 36;
const double kMojianTimelineMinWidth =
    Breakpoints.maxContentWidth +
    2 * (kMojianTimelineGap + kMojianTimelineWidth + 16);

/// 按阅读区实际宽度(不是屏宽:平行视界右栏、侧栏都要扣掉)选形态。
/// 详情浮层与目录层各自调用,两边必须同一口径。
MojianReaderMode mojianReaderModeFor(BuildContext context, double width) {
  if (Responsive.isMobile(context)) return MojianReaderMode.bar;
  return width >= kMojianTimelineMinWidth
      ? MojianReaderMode.timeline
      : MojianReaderMode.bar;
}

/// 底部阅读条:顶边一条阅读进度细线,下面是「写回复…」、楼层指示、赞(首帖)、书签。
/// 楼层指示保留原楼层胶囊的全部手势(单击开时间线、滑动、长按菜单)。
class MojianReaderBar extends StatelessWidget {
  const MojianReaderBar({
    super.key,
    required this.streamIndexListenable,
    required this.totalCount,
    required this.isLoggedIn,
    required this.showFloor,
    required this.liked,
    required this.bookmarked,
    required this.onReply,
    required this.onLike,
    required this.onBookmark,
    required this.onProgressTap,
    this.onProgressGesture,
  });

  /// 内容区高度(不含底部安全区)
  static const double height = 56;

  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final bool isLoggedIn;

  /// 嵌套视图自有滚动体系,不显示楼层与进度
  final bool showFloor;

  /// 首帖是否已赞;null = 不显示赞(首帖不在窗口里 / 自己的帖子)
  final bool? liked;
  final bool bookmarked;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback onBookmark;
  final VoidCallback onProgressTap;
  final ValueChanged<ProgressGestureAction>? onProgressGesture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final l10n = context.l10n;

    Widget floor = _FloorIndicator(
      streamIndexListenable: streamIndexListenable,
      totalCount: totalCount,
      onTap: onProgressTap,
    );
    floor = TopicProgressGestures(
      onAction: onProgressGesture ?? (_) {},
      child: floor,
    );

    return Material(
      color: mj.paper,
      child: Container(
        height: height + bottomPadding,
        padding: EdgeInsets.only(bottom: bottomPadding),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: mj.rule)),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (showFloor)
              Positioned(
                top: -1,
                left: 0,
                right: 0,
                height: 2,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<int>(
                    valueListenable: streamIndexListenable,
                    builder: (context, index, _) =>
                        AnimatedFractionallySizedBox(
                          duration: const Duration(milliseconds: 160),
                          alignment: Alignment.centerLeft,
                          widthFactor: _fraction(index, totalCount),
                          child: ColoredBox(color: mj.accent),
                        ),
                  ),
                ),
              ),
            // 宽栏(平板/平行视界右栏)里条子满宽,内容跟正文列同宽居中
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Breakpoints.maxContentWidth + 24,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      if (isLoggedIn)
                        Expanded(
                          child: _ReplyField(
                            label: l10n.topicDetail_writeReply,
                            onTap: onReply,
                          ),
                        )
                      else
                        const Spacer(),
                      if (showFloor) floor,
                      if (!isLoggedIn) const Spacer(),
                      if (isLoggedIn && liked != null)
                        IconButton(
                          onPressed: onLike,
                          tooltip: l10n.topicDetail_likeTopic,
                          icon: Icon(
                            Symbols.favorite_rounded,
                            fill: liked! ? 1 : 0,
                            color: liked! ? mj.accent : mj.ink2,
                          ),
                        ),
                      if (isLoggedIn)
                        IconButton(
                          onPressed: onBookmark,
                          tooltip: l10n.topicDetail_bookmarkTopic,
                          icon: Icon(
                            Symbols.bookmark_rounded,
                            fill: bookmarked ? 1 : 0,
                            color: bookmarked ? mj.accent : mj.ink2,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _fraction(int index, int total) =>
    total > 1 ? ((index - 1) / (total - 1)).clamp(0.0, 1.0) : 0.0;

class _ReplyField extends StatelessWidget {
  const _ReplyField({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mj = Theme.of(context).extension<MojianTokens>()!;
    return Material(
      color: mj.paper2,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(Symbols.edit_rounded, size: 16, color: mj.ink3),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: mj.ink3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「12 / 332」:宋体数字,楼层变化只重建自身
class _FloorIndicator extends StatelessWidget {
  const _FloorIndicator({
    required this.streamIndexListenable,
    required this.totalCount,
    required this.onTap,
  });

  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mj = Theme.of(context).extension<MojianTokens>()!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64, minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            widthFactor: 1,
            child: RepaintBoundary(
              child: ValueListenableBuilder<int>(
                valueListenable: streamIndexListenable,
                builder: (context, index, _) => Text(
                  '$index / $totalCount',
                  style: TextStyle(
                    fontFamily: MojianTokens.serifFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: mj.ink2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽栏的竖向时间轴:起始日期、可拖动的轨道(圆钮旁写「n / 总数」)、
/// 最新日期,下面是「跳转楼层」(= 原楼层胶囊:单击开时间线弹窗可手输楼层,
/// 滑动 / 长按手势照旧)、回复、赞首帖、书签。拖动/点击轨道松手后按
/// stream 序号跳转。
class MojianTimeline extends StatefulWidget {
  const MojianTimeline({
    super.key,
    required this.streamIndexListenable,
    required this.totalCount,
    required this.startDate,
    required this.endDate,
    required this.isLoggedIn,
    required this.bookmarked,
    required this.onSeekIndex,
    required this.onReply,
    required this.onBookmark,
    required this.onProgressTap,
    this.onProgressGesture,
    this.liked,
    this.onLike,
    this.trackHeight = 220,
  });

  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isLoggedIn;
  final bool bookmarked;

  /// 跳到第 n 个(1 起)stream 位置
  final ValueChanged<int> onSeekIndex;
  final VoidCallback onReply;
  final VoidCallback onBookmark;

  /// 单击「跳转楼层」:打开时间线弹窗(可手输楼层号)
  final VoidCallback onProgressTap;

  /// 「跳转楼层」上的滑动 / 长按菜单手势(与原楼层胶囊同一套设置)
  final ValueChanged<ProgressGestureAction>? onProgressGesture;

  /// 首帖是否已赞;null = 不显示赞(首帖不在窗口里 / 自己的帖子)
  final bool? liked;
  final VoidCallback? onLike;
  final double trackHeight;

  @override
  State<MojianTimeline> createState() => _MojianTimelineState();
}

class _MojianTimelineState extends State<MojianTimeline> {
  /// 拖动中的目标序号(松手前只动圆钮,不滚正文)
  int? _dragIndex;

  /// 松手后、正文真正跳到之前,圆钮先停在目标处(不弹回旧楼层再跳过去);
  /// 当前楼层变化或超时后清掉
  int? _pendingIndex;
  Timer? _pendingTimer;

  @override
  void initState() {
    super.initState();
    widget.streamIndexListenable.addListener(_onIndexChanged);
  }

  @override
  void didUpdateWidget(MojianTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamIndexListenable != widget.streamIndexListenable) {
      oldWidget.streamIndexListenable.removeListener(_onIndexChanged);
      widget.streamIndexListenable.addListener(_onIndexChanged);
    }
  }

  @override
  void dispose() {
    widget.streamIndexListenable.removeListener(_onIndexChanged);
    _pendingTimer?.cancel();
    super.dispose();
  }

  void _onIndexChanged() {
    if (_pendingIndex == null) return;
    _pendingTimer?.cancel();
    setState(() => _pendingIndex = null);
  }

  int _indexAt(double dy) {
    final total = widget.totalCount;
    if (total <= 1) return 1;
    final f = (dy / widget.trackHeight).clamp(0.0, 1.0);
    return (f * (total - 1) + 1).round().clamp(1, total);
  }

  void _drag(double dy) {
    final i = _indexAt(dy);
    if (i != _dragIndex) {
      if (_dragIndex != null) HapticFeedback.selectionClick();
      setState(() => _dragIndex = i);
    }
  }

  void _commit() {
    final i = _dragIndex;
    setState(() {
      _dragIndex = null;
      _pendingIndex = i;
    });
    if (i == null) return;
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pendingIndex = null);
    });
    widget.onSeekIndex(i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    final l10n = context.l10n;
    final dateStyle = TextStyle(
      fontFamily: MojianTokens.serifFamily,
      fontSize: 12,
      color: mj.ink3,
    );
    final h = widget.trackHeight;

    final track = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (d) => _drag(d.localPosition.dy),
      onVerticalDragUpdate: (d) => _drag(d.localPosition.dy),
      onVerticalDragEnd: (_) => _commit(),
      onVerticalDragCancel: () => setState(() => _dragIndex = null),
      onTapUp: (d) {
        _drag(d.localPosition.dy);
        _commit();
      },
      child: SizedBox(
        width: kMojianTimelineWidth,
        height: h,
        child: ValueListenableBuilder<int>(
          valueListenable: widget.streamIndexListenable,
          builder: (context, current, _) {
            final index = _dragIndex ?? _pendingIndex ?? current;
            final y = _fraction(index, widget.totalCount) * h;
            final dur = _dragIndex != null
                ? Duration.zero
                : const Duration(milliseconds: 200);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 5,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 1, color: mj.ruleStrong),
                ),
                AnimatedPositioned(
                  duration: dur,
                  curve: Curves.easeOutCubic,
                  left: 4,
                  top: 0,
                  height: y,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: mj.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: dur,
                  curve: Curves.easeOutCubic,
                  left: 0,
                  top: y - 6,
                  child: Row(
                    children: [
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: mj.paper,
                          shape: BoxShape.circle,
                          border: Border.all(color: mj.accent, width: 2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$index / ${widget.totalCount}',
                        style: TextStyle(
                          fontFamily: MojianTokens.serifFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          height: 1,
                          color: _dragIndex != null ? mj.accent : mj.ink,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );

    // 列宽固定在正文右侧留白里,系统大字号时封顶 1.2 倍,免得按钮与楼层号挤出列外
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: SizedBox(
        width: kMojianTimelineWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.startDate != null)
              Text(
                TimeUtils.formatSmartDate(widget.startDate),
                style: dateStyle,
              ),
            const SizedBox(height: 12),
            MouseRegion(cursor: SystemMouseCursors.click, child: track),
            const SizedBox(height: 12),
            if (widget.endDate != null)
              Text(
                TimeUtils.formatRelativeTime(widget.endDate),
                style: dateStyle,
              ),
            const SizedBox(height: 14),
            TopicProgressGestures(
              onAction: widget.onProgressGesture ?? (_) {},
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onProgressTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.unfold_more_rounded,
                          size: 16,
                          color: mj.ink2,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.topicDetail_jumpFloor,
                          style: TextStyle(fontSize: 13, color: mj.ink2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (widget.isLoggedIn) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 104, minHeight: 34),
                child: FilledButton.icon(
                  onPressed: widget.onReply,
                  icon: const Icon(Symbols.reply_rounded, size: 16),
                  label: Text(l10n.common_reply),
                  style: FilledButton.styleFrom(
                    // 固定 34 高(不按触屏补到 48),列高才算得准
                    minimumSize: const Size(104, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              if (widget.liked != null) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 104,
                    minHeight: 34,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: widget.onLike,
                    icon: Icon(
                      Symbols.favorite_rounded,
                      size: 16,
                      fill: widget.liked! ? 1 : 0,
                      color: widget.liked! ? mj.accent : null,
                    ),
                    label: Text(l10n.topicDetail_like),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(104, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(fontSize: 13),
                      foregroundColor: widget.liked! ? mj.accent : null,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 104, minHeight: 34),
                child: OutlinedButton.icon(
                  onPressed: widget.onBookmark,
                  icon: Icon(
                    Symbols.bookmark_rounded,
                    size: 16,
                    fill: widget.bookmarked ? 1 : 0,
                    color: widget.bookmarked ? mj.accent : null,
                  ),
                  label: Text(l10n.topicDetail_bookmarkTopic),
                  style: OutlinedButton.styleFrom(
                    // 固定 34 高(不按触屏补到 48),列高才算得准
                    minimumSize: const Size(104, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 13),
                    foregroundColor: widget.bookmarked ? mj.accent : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
