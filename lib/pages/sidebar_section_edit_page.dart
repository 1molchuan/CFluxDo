import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../constants.dart';
import '../l10n/s.dart';
import '../models/category.dart';
import '../models/sidebar_section.dart';
import '../providers/category_provider.dart';
import '../providers/sidebar_sections_provider.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/font_awesome_helper.dart';

/// 新建 / 编辑一个侧栏自定义分区（与网页侧栏同步）。
///
/// 改动先留在本页，点「保存」时一次提交完整链接列表（顺序即显示顺序）；
/// 上移下移、拖拽都不单独发请求。
class SidebarSectionEditPage extends ConsumerStatefulWidget {
  const SidebarSectionEditPage({super.key, this.section});

  /// null = 新建
  final SidebarSection? section;

  @override
  ConsumerState<SidebarSectionEditPage> createState() =>
      _SidebarSectionEditPageState();
}

class _SidebarSectionEditPageState
    extends ConsumerState<SidebarSectionEditPage> {
  late final TextEditingController _title = TextEditingController(
    text: widget.section?.title ?? '',
  );
  late List<SidebarSectionLink> _links = [...?widget.section?.links];
  final List<SidebarSectionLink> _removed = [];
  bool _saving = false;
  bool _dirty = false;

  bool get _isNew => widget.section == null;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _change(VoidCallback update) => setState(() {
    update();
    _dirty = true;
  });

  void _move(int from, int to) {
    if (to < 0 || to >= _links.length || to == from) return;
    _change(() {
      final link = _links.removeAt(from);
      _links.insert(to, link);
    });
  }

  void _remove(int index) => _change(() {
    final link = _links.removeAt(index);
    if (link.id != null) _removed.add(link);
  });

  Future<void> _editLink([int? index]) async {
    final current = index == null ? null : _links[index];
    final edited = await showAppDialog<SidebarSectionLink>(
      context: context,
      builder: (_) => _LinkEditDialog(link: current),
    );
    if (edited == null || !mounted) return;
    _change(() {
      if (index == null) {
        _links = [..._links, edited];
      } else {
        _links[index] = edited;
      }
    });
  }

  Future<void> _addCategory() async {
    final category = await showAppBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CategoryPickerSheet(),
    );
    if (category == null || !mounted) return;
    final categoryMap = ref.read(categoryMapProvider).value ?? const {};
    final parent = categoryMap[category.parentCategoryId];
    final path = parent == null
        ? '/c/${category.slug}/${category.id}'
        : '/c/${parent.slug}/${category.slug}/${category.id}';
    _change(
      () => _links = [
        ..._links,
        SidebarSectionLink(name: category.name, value: path, icon: 'folder'),
      ],
    );
  }

  /// 本地先按服务端规则查一遍，免得白发请求；服务端的报错原样提示
  String? _validate(String title) {
    if (title.isEmpty) return S.current.sidebarSection_titleRequired;
    if (SidebarSectionLimits.length(title) > SidebarSectionLimits.titleMax) {
      return S.current.sidebarSection_titleTooLong(
        SidebarSectionLimits.titleMax,
      );
    }
    if (_links.isEmpty) return S.current.sidebarSection_needLink;
    if (_links.length + _removed.length > SidebarSectionLimits.linksMax) {
      return S.current.sidebarSection_tooManyLinks(
        SidebarSectionLimits.linksMax,
      );
    }
    for (final link in _links) {
      if (link.name.isEmpty || link.value.isEmpty) {
        return S.current.sidebarSection_linkIncomplete;
      }
      if (SidebarSectionLimits.length(link.name) >
          SidebarSectionLimits.nameMax) {
        return S.current.sidebarSection_nameTooLong(
          SidebarSectionLimits.nameMax,
        );
      }
    }
    return null;
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final error = _validate(title);
    if (error != null) {
      ToastService.showError(error);
      return;
    }
    setState(() => _saving = true);
    final notifier = ref.read(sidebarSectionsProvider.notifier);
    try {
      final section = widget.section;
      if (section == null) {
        await notifier.create(title: title, links: _links);
      } else {
        await notifier.save(
          section,
          title: title,
          links: _links,
          removedLinks: _removed,
        );
      }
      if (!mounted) return;
      ToastService.showSuccess(S.current.common_success);
      _closeClean();
    } catch (e) {
      ToastService.showError(_errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final section = widget.section;
    if (section == null) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(S.current.sidebarSection_deleteSection),
        content: Text(S.current.sidebarSection_deleteConfirm(section.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.current.common_delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(sidebarSectionsProvider.notifier).delete(section);
      if (!mounted) return;
      _closeClean();
    } catch (e) {
      ToastService.showError(_errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存 / 删除 / 放弃后关页：PopScope 的 canPop 要等重建后才放行
  void _closeClean() {
    setState(() {
      _dirty = false;
      _saving = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  static String _errorText(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(S.current.sidebarSection_discardChanges),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.current.common_discard),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _saving) return;
        if (await _confirmDiscard() && mounted) _closeClean();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isNew
                ? S.current.sidebarSection_newSection
                : S.current.sidebarSection_editSection,
          ),
          actions: [
            if (!_isNew)
              IconButton(
                tooltip: S.current.sidebarSection_deleteSection,
                onPressed: _saving ? null : _delete,
                icon: const Icon(Symbols.delete_rounded),
              ),
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(S.current.common_save),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              S.current.sidebarSection_syncHint,
              style: TextStyle(fontSize: 13, color: colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              enabled: !_saving,
              onChanged: (_) => setState(() => _dirty = true),
              decoration: InputDecoration(
                labelText: S.current.sidebarSection_titleLabel,
                border: const OutlineInputBorder(),
                counterText:
                    '${SidebarSectionLimits.length(_title.text)}'
                    '/${SidebarSectionLimits.titleMax}',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text(
                  S.current.sidebarSection_links,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _saving ? null : _addCategory,
                  icon: const Icon(Symbols.category_rounded, size: 18),
                  label: Text(S.current.sidebarSection_addCategory),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : () => _editLink(),
                  icon: const Icon(Symbols.add_link_rounded, size: 18),
                  label: Text(S.current.sidebarSection_addLink),
                ),
              ],
            ),
            if (_links.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    S.current.sidebarSection_noLinks,
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _links.length,
                onReorderItem: _move,
                itemBuilder: (context, index) {
                  final link = _links[index];
                  return _LinkTile(
                    key: ObjectKey(link),
                    link: link,
                    index: index,
                    isFirst: index == 0,
                    isLast: index == _links.length - 1,
                    enabled: !_saving,
                    onEdit: () => _editLink(index),
                    onMoveToTop: () => _move(index, 0),
                    onMoveUp: () => _move(index, index - 1),
                    onMoveDown: () => _move(index, index + 1),
                    onRemove: () => _remove(index),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 链接图标：网页同款 FontAwesome 名字，认不出来就用链接符号
class SidebarLinkIcon extends StatelessWidget {
  const SidebarLinkIcon(this.name, {super.key, this.size = 18, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = FontAwesomeHelper.getIcon(name);
    if (icon == null)
      return Icon(Symbols.link_rounded, size: size, color: color);
    return FaIcon(icon, size: size - 2, color: color);
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    super.key,
    required this.link,
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.enabled,
    required this.onEdit,
    required this.onMoveToTop,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  final SidebarSectionLink link;
  final int index;
  final bool isFirst;
  final bool isLast;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onMoveToTop;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        enabled: enabled,
        onTap: onEdit,
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        leading: SidebarLinkIcon(link.icon, color: colorScheme.primary),
        title: Text(link.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          link.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<VoidCallback>(
              enabled: enabled,
              tooltip: S.current.category_reorderMenu,
              icon: const Icon(Symbols.more_vert_rounded, size: 20),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: onEdit,
                  child: Text(S.current.sidebarSection_editLink),
                ),
                PopupMenuItem(
                  value: onMoveToTop,
                  enabled: !isFirst,
                  child: Text(S.current.category_moveToTop),
                ),
                PopupMenuItem(
                  value: onMoveUp,
                  enabled: !isFirst,
                  child: Text(S.current.category_moveUp),
                ),
                PopupMenuItem(
                  value: onMoveDown,
                  enabled: !isLast,
                  child: Text(S.current.category_moveDown),
                ),
                PopupMenuItem(
                  value: onRemove,
                  child: Text(
                    S.current.common_remove,
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
              ],
            ),
            ReorderableDragStartListener(
              index: index,
              enabled: enabled,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Symbols.drag_indicator_rounded,
                  size: 20,
                  color: colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑一条链接：名称、地址、图标
class _LinkEditDialog extends StatefulWidget {
  const _LinkEditDialog({this.link});

  final SidebarSectionLink? link;

  @override
  State<_LinkEditDialog> createState() => _LinkEditDialogState();
}

class _LinkEditDialogState extends State<_LinkEditDialog> {
  /// 选得到的图标：FontAwesome 5/6 里同名、Discourse 自带图标集里都有的
  static const _presetIcons = [
    'link',
    'star',
    'heart',
    'bookmark',
    'tag',
    'tags',
    'folder',
    'book',
    'code',
    'comment',
    'bell',
    'flag',
    'rocket',
    'trophy',
    'user',
    'users',
    'globe',
    'list',
    'image',
    'file',
    'inbox',
    'thumbtack',
  ];

  late final TextEditingController _name = TextEditingController(
    text: widget.link?.name ?? '',
  );
  late final TextEditingController _value = TextEditingController(
    text: widget.link?.value ?? '',
  );
  late String _icon = widget.link?.icon ?? SidebarSectionLink.defaultIcon;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  /// 本站的完整地址存成路径（网页那边也这么存）
  static String _normalizeValue(String raw) {
    final value = raw.trim();
    final base = AppConstants.baseUrl;
    if (value.startsWith(base)) {
      final path = value.substring(base.length);
      return path.isEmpty ? '/' : path;
    }
    return value;
  }

  void _submit() {
    final name = _name.text.trim();
    final value = _normalizeValue(_value.text);
    String? error;
    if (name.isEmpty || value.isEmpty) {
      error = S.current.sidebarSection_linkIncomplete;
    } else if (SidebarSectionLimits.length(name) >
        SidebarSectionLimits.nameMax) {
      error = S.current.sidebarSection_nameTooLong(
        SidebarSectionLimits.nameMax,
      );
    } else if (SidebarSectionLimits.length(value) >
        SidebarSectionLimits.valueMax) {
      error = S.current.sidebarSection_invalidUrl;
    } else if (value.startsWith('http://') || value.startsWith('https://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.host.isEmpty) {
        error = S.current.sidebarSection_invalidUrl;
      }
    } else if (!value.startsWith('/')) {
      error = S.current.sidebarSection_invalidUrl;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final link = widget.link;
    Navigator.of(context).pop(
      link == null
          ? SidebarSectionLink(name: name, value: value, icon: _icon)
          : link.copyWith(name: name, value: value, icon: _icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icons = [if (!_presetIcons.contains(_icon)) _icon, ..._presetIcons];
    return AlertDialog(
      title: Text(
        widget.link == null
            ? S.current.sidebarSection_addLink
            : S.current.sidebarSection_editLink,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.link == null,
                decoration: InputDecoration(
                  labelText: S.current.sidebarSection_linkName,
                  helperText: S.current.sidebarSection_linkNameHint,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _value,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: S.current.sidebarSection_linkValue,
                  helperText: S.current.sidebarSection_linkValueHint,
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.current.sidebarSection_icon,
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final name in icons)
                    ChoiceChip(
                      label: SidebarLinkIcon(
                        name,
                        size: 16,
                        color: name == _icon
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                      selected: name == _icon,
                      // 主题里选中态可能是深色实底（墨笺），图标会看不见
                      selectedColor: colorScheme.primaryContainer,
                      showCheckmark: false,
                      tooltip: name,
                      onSelected: (_) => setState(() => _icon = name),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.current.common_cancel),
        ),
        TextButton(onPressed: _submit, child: Text(S.current.common_ok)),
      ],
    );
  }
}

/// 选一个分类加进分区
class _CategoryPickerSheet extends ConsumerStatefulWidget {
  const _CategoryPickerSheet();

  @override
  ConsumerState<_CategoryPickerSheet> createState() =>
      _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends ConsumerState<_CategoryPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final categoryMap = ref.watch(categoryMapProvider).value ?? const {};
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? categories
        : categories
              .where((c) => c.name.toLowerCase().contains(query))
              .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: false,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search_rounded),
                  hintText: S.current.common_search,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final category = filtered[index];
                  final parent = categoryMap[category.parentCategoryId];
                  return ListTile(
                    title: Text(category.name),
                    subtitle: parent == null ? null : Text(parent.name),
                    onTap: () => Navigator.of(context).pop(category),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
