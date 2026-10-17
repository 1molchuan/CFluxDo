import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/dialog_utils.dart';
import 'category_drawer.dart'
    show CategoryDrawerHost, openCategorySubscriptionSheet;
import 'category_tab_manager_sheet.dart' show PinnedCategoryEditPage;

/// 墨笺首页「分类」面板:搜索框 + 收藏 / 其他两组网格,☆ 收藏或取消,
/// 长按分类改订阅级别;顶部可进「编辑我的分类」(排序)与完整的分类侧栏
/// (标签、父子分类树)。手机是底部抽屉,宽屏是居中对话框。选中哪个分类由
/// [onSelect] 交宿主决定(已收藏切首页对应 tab,未收藏进分类页 —— 与分类
/// 侧栏一致)。
Future<void> showMojianCategorySheet(
  BuildContext context, {
  required int? currentCategoryId,
  required ValueChanged<Category> onSelect,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 760;
  Widget build(BuildContext ctx, {required bool dialog}) => MojianCategorySheet(
    currentCategoryId: currentCategoryId,
    dialog: dialog,
    onSelect: (category) {
      Navigator.of(ctx).pop();
      onSelect(category);
    },
  );
  if (wide) {
    return showAppDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700, maxHeight: 660),
          child: build(ctx, dialog: true),
        ),
      ),
    );
  }
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // 底部面板不会自己让位键盘:搜索时整体抬到键盘上方,高度固定不随结果收缩
    builder: (ctx) {
      final insets = MediaQuery.viewInsetsOf(ctx).bottom;
      final height = MediaQuery.sizeOf(ctx).height;
      return Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: SizedBox(
          // 下限 240 不能超过上限:矮窗口(分屏/小窗)里上限本身就不到 240
          height: (height * 0.86 - insets).clamp(
            math.min(240.0, height * 0.86),
            height * 0.86,
          ),
          child: build(ctx, dialog: false),
        ),
      );
    },
  );
}

class MojianCategorySheet extends ConsumerStatefulWidget {
  const MojianCategorySheet({
    super.key,
    required this.currentCategoryId,
    required this.onSelect,
    this.dialog = false,
  });

  final int? currentCategoryId;
  final ValueChanged<Category> onSelect;

  /// 宽屏居中对话框形态(无拖拽条,左右留白大一些)
  final bool dialog;

  @override
  ConsumerState<MojianCategorySheet> createState() =>
      _MojianCategorySheetState();
}

class _MojianCategorySheetState extends ConsumerState<MojianCategorySheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static final _tagPattern = RegExp(r'<[^>]*>');

  /// 分类描述是 HTML 片段,面板只要一行纯文本
  static String _plain(String? html) {
    if (html == null) return '';
    return html
        .replaceAll(_tagPattern, '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    final l10n = context.l10n;
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final hPad = widget.dialog ? 22.0 : 18.0;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(hPad, widget.dialog ? 20 : 4, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.category_categories,
                  style: TextStyle(
                    fontFamily: MojianTokens.serifFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 21,
                    letterSpacing: 1.2,
                    color: mj.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.category_sheetHint,
                  style: TextStyle(fontSize: 12, color: mj.ink3),
                ),
              ],
            ),
          ),
          if (pinnedIds.isNotEmpty)
            IconButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PinnedCategoryEditPage(),
                  ),
                );
              },
              icon: Icon(Symbols.swap_vert_rounded, color: mj.ink2),
              tooltip: l10n.category_editMyCategories,
            ),
          // 完整的分类侧栏:标签页签、父子分类树、长按菜单
          IconButton(
            onPressed: () {
              Navigator.of(context).pop();
              CategoryDrawerHost.open();
            },
            icon: Icon(Symbols.menu_open_rounded, color: mj.ink2),
            tooltip: l10n.topics_browseCategories,
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Symbols.close_rounded, color: mj.ink2),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          ),
        ],
      ),
    );

    final search = Padding(
      padding: EdgeInsets.fromLTRB(hPad, 14, hPad, 2),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: mj.paper2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Symbols.search_rounded, size: 18, color: mj.ink3),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 14.5, color: mj.ink),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: l10n.category_searchHint,
                  hintStyle: TextStyle(color: mj.ink4),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final body = categoriesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(40),
        child: Center(child: Text(l10n.common_loadFailed)),
      ),
      data: (categories) {
        final byId = {for (final c in categories) c.id: c};
        final q = _query.text.trim().toLowerCase();
        bool match(Category c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            _plain(c.description).toLowerCase().contains(q);
        final pinnedSet = pinnedIds.toSet();
        final pinned = [
          for (final id in pinnedIds)
            if (byId[id] case final c? when match(c)) c,
        ];
        final all = categories.where(match).toList();
        if (all.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                l10n.category_noCategoriesFound,
                style: TextStyle(
                  fontFamily: MojianTokens.serifFamily,
                  fontSize: 16,
                  color: mj.ink2,
                ),
              ),
            ),
          );
        }
        final rest = q.isNotEmpty
            ? all
            : all.where((c) => !pinnedSet.contains(c.id)).toList();

        Widget section(String title, int count) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 18, 0, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: MojianTokens.serifFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  letterSpacing: 3,
                  color: mj.ink3,
                ),
              ),
              const SizedBox(width: 8),
              Text('$count', style: TextStyle(fontSize: 11, color: mj.ink4)),
            ],
          ),
        );

        Widget grid(List<Category> items) => LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth >= 560 ? 3 : 2;
            const gap = 10.0;
            final w = (constraints.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final c in items)
                  SizedBox(
                    width: w,
                    child: _CategoryTile(
                      category: c,
                      parentName: c.parentCategoryId == null
                          ? null
                          : byId[c.parentCategoryId]?.name,
                      description: _plain(c.description),
                      pinned: pinnedSet.contains(c.id),
                      selected: c.id == widget.currentCategoryId,
                      onTap: () => widget.onSelect(c),
                      onLongPress: isLoggedIn
                          ? () => openCategorySubscriptionSheet(context, c)
                          : null,
                      onTogglePin: () {
                        final notifier = ref.read(
                          pinnedCategoriesProvider.notifier,
                        );
                        pinnedSet.contains(c.id)
                            ? notifier.remove(c.id)
                            : notifier.add(c.id);
                      },
                    ),
                  ),
              ],
            );
          },
        );

        return ListView(
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(
            hPad,
            0,
            hPad,
            18 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            if (q.isEmpty && pinned.isNotEmpty) ...[
              section(l10n.category_myCategories, pinned.length),
              grid(pinned),
            ],
            if (rest.isNotEmpty) ...[
              section(
                q.isEmpty && pinned.isNotEmpty
                    ? l10n.category_otherCategories
                    : l10n.category_allCategories,
                rest.length,
              ),
              grid(rest),
            ],
          ],
        );
      },
    );

    return Material(
      color: mj.paper3,
      child: Column(
        mainAxisSize: widget.dialog ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.dialog)
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 10),
                decoration: BoxDecoration(
                  color: mj.ruleStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          header,
          search,
          Flexible(child: body),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.parentName,
    required this.description,
    required this.pinned,
    required this.selected,
    required this.onTap,
    required this.onTogglePin,
    this.onLongPress,
  });

  final Category category;
  final String? parentName;
  final String description;
  final bool pinned;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;

  /// 长按:订阅级别(登录后)
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    final l10n = context.l10n;
    final color = MojianTheme.categoryColor(category.color, theme.brightness);
    final sub = parentName ?? description;
    return Material(
      color: mj.paper,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? mj.ink : mj.rule,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 2, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 受限分类(仅部分人可见)标一把锁,与侧栏一致
                          if (category.readRestricted) ...[
                            Icon(
                              Symbols.lock_rounded,
                              size: 13,
                              color: mj.ink3,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              category.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: MojianTokens.serifFamily,
                                fontWeight: FontWeight.w600,
                                fontSize: 15.5,
                                color: mj.ink,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 34,
                            height: 34,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              tooltip: pinned
                                  ? l10n.category_unpin
                                  : l10n.category_pinToTabs,
                              onPressed: onTogglePin,
                              icon: Icon(
                                Symbols.star_rounded,
                                fill: pinned ? 1 : 0,
                                color: pinned ? mj.gold : mj.ink4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        sub.isEmpty ? ' ' : sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: mj.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
