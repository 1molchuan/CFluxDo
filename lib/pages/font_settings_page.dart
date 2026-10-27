import 'dart:async';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../providers/theme_provider.dart';
import '../services/custom_font_service.dart';
import '../services/fonts/system_font_service.dart';
import '../services/recommended_font_service.dart';
import '../services/toast_service.dart';
import '../theme/mojian_theme.dart';
import '../utils/responsive.dart';
import '../widgets/common/app_bottom_sheet.dart';
import '../widgets/common/mojian_section_label.dart';

/// 字体设置页。
///
/// 所有字体排成同一种行：左边是用该字体写的「字」，名字也用它自己渲染，
/// 右边只有一个状态（勾 = 正在用、下载图标 = 还没下载、删除 = 下载过 /
/// 导入过的）。点一下就用；推荐字体没下载时点一下先下载再用。顶部预览
/// 就是当前主题本身，标题和正文分开示意（墨笺可以单独决定标题用不用宋体）。
class FontSettingsPage extends ConsumerStatefulWidget {
  const FontSettingsPage({super.key, this.recommendedFontService});

  /// 测试注入；默认用全局的 [RecommendedFontService.instance]
  @visibleForTesting
  final RecommendedFontService? recommendedFontService;

  @override
  ConsumerState<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends ConsumerState<FontSettingsPage> {
  RecommendedFontService get _recommended =>
      widget.recommendedFontService ?? RecommendedFontService.instance;

  /// 按名字选系统字体只在桌面端列出：手机系统里按名字能选到的几乎都是
  /// 西文字体（sans-serif、serif、monospace……），选了中文不变。
  static bool get _installedSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    unawaited(_registerPreviews());
  }

  /// 下载过 / 导入过的字体先注册进引擎，列表里才能用它自己的字形预览
  Future<void> _registerPreviews() async {
    try {
      await _recommended.ensureLoaded();
    } catch (e) {
      debugPrint('[FontSettings] 推荐字体清单不可用: $e');
    }
    if (!mounted) return;
    final paths = <String>[
      for (final font in _recommended.fonts) ?_recommended.installedPath(font),
      ?ref.read(themeProvider).importedFontPath,
    ];
    var loaded = false;
    for (final path in paths) {
      if (await CustomFontService.load(path)) loaded = true;
    }
    if (loaded && mounted) setState(() {});
  }

  Future<void> _useRecommended(RecommendedFont font) async {
    final l10n = context.l10n;
    var path = _recommended.installedPath(font);
    if (path == null) {
      try {
        path = await _recommended.download(font);
      } catch (_) {
        // 用户取消时 error 为 null，不提示
        if (mounted && _recommended.progressOf(font.id)?.error != null) {
          ToastService.showError(l10n.appearance_recommendedFontFailed);
        }
        return;
      }
    }
    if (!mounted) return;
    if (!await CustomFontService.load(path)) {
      if (mounted) {
        ToastService.showError(l10n.appearance_recommendedFontLoadFailed);
      }
      return;
    }
    if (!mounted) return;
    await ref
        .read(themeProvider.notifier)
        .setCustomFont(path: path, name: font.name);
  }

  Future<void> _deleteRecommended(RecommendedFont font) async {
    final path = _recommended.installedPath(font);
    if (path != null) {
      await ref.read(themeProvider.notifier).stopUsingFontFile(path);
    }
    await _recommended.remove(font);
  }

  /// 导入 → 注册进引擎 → 落状态。任一步失败都不改变当前选择。
  Future<void> _importFont() async {
    final l10n = context.l10n;
    final imported = await CustomFontService.pickAndImport();
    if (imported == null) return; // 用户取消
    if (!await CustomFontService.load(imported.path)) {
      await CustomFontService.delete(imported.path);
      if (mounted) ToastService.showError(l10n.appearance_fontCustomLoadFailed);
      return;
    }
    if (!mounted) return;
    await ref
        .read(themeProvider.notifier)
        .importFont(path: imported.path, name: imported.name);
  }

  Future<void> _useImported(String path, String name) async {
    if (!await CustomFontService.load(path)) {
      if (mounted) {
        ToastService.showError(context.l10n.appearance_fontCustomMissing);
      }
      return;
    }
    if (!mounted) return;
    await ref
        .read(themeProvider.notifier)
        .setCustomFont(path: path, name: name);
  }

  /// 打开系统字体选择面板（列表来自系统已安装字体）。用户取消则不改选择。
  Future<void> _pickInstalled() async {
    final l10n = context.l10n;
    // 中文界面优先展示本地化名（微软雅黑），其它语言用引擎匹配名
    final localized = Localizations.localeOf(context).languageCode == 'zh';
    final notifier = ref.read(themeProvider.notifier);
    final picked = await AppBottomSheet.showDraggable<SystemFont>(
      context: context,
      title: l10n.appearance_fontInstalledPick,
      bodyBuilder: (context, scrollController) => _SystemFontPickerSheet(
        scrollController: scrollController,
        selected: ref.read(themeProvider).installedFontFamily,
      ),
    );
    if (picked == null) return;
    await notifier.setInstalledFont(
      family: picked.family,
      name: picked.label(localized: localized),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    final state = ref.watch(themeProvider);
    final notifier = ref.read(themeProvider.notifier);

    final activeCustomPath = state.fontFamily == AppFontFamily.custom
        ? state.customFontPath
        : null;
    final importedPath = state.importedFontPath;
    final importedExists =
        importedPath != null && File(importedPath).existsSync();
    final installedFamily = state.installedFontFamily;
    final showInstalled =
        installedFamily != null &&
        (_installedSupported || state.fontFamily == AppFontFamily.installed);

    final rows = <Widget>[
      _FontRow(
        family: MojianTheme.platformBodyFamily,
        title: l10n.appearance_fontSystem,
        subtitle: l10n.appearance_fontSystemDesc,
        selected: state.fontFamily == AppFontFamily.system,
        onTap: () => notifier.setFontFamily(AppFontFamily.system),
      ),
      _FontRow(
        family: 'MiSans',
        title: 'MiSans',
        subtitle: l10n.appearance_fontMiSansDesc,
        selected: state.fontFamily == AppFontFamily.miSans,
        onTap: () => notifier.setFontFamily(AppFontFamily.miSans),
      ),
      if (importedPath != null)
        _FontRow(
          family: importedExists
              ? CustomFontService.familyNameFor(importedPath)
              : null,
          previewable: importedExists,
          title: state.importedFontName ?? l10n.appearance_fontImported,
          subtitle: importedExists
              ? l10n.appearance_fontImported
              : l10n.appearance_fontCustomMissing,
          subtitleError: !importedExists,
          // 文件丢了就不算选中，好让删除按钮露出来
          selected: importedExists && activeCustomPath == importedPath,
          onTap: importedExists
              ? () => _useImported(
                  importedPath,
                  state.importedFontName ?? l10n.appearance_fontImported,
                )
              : null,
          onDelete: () => notifier.removeImportedFont(),
        ),
      if (showInstalled)
        _FontRow(
          family: installedFamily,
          title: state.installedFontName ?? installedFamily,
          subtitle: _installedSupported
              ? l10n.appearance_fontInstalled
              : l10n.appearance_fontInstalledLatinOnly,
          selected: state.fontFamily == AppFontFamily.installed,
          onTap: () => notifier.setFontFamily(AppFontFamily.installed),
          action: _installedSupported
              ? TextButton(
                  onPressed: _pickInstalled,
                  child: Text(l10n.appearance_fontInstalledChange),
                )
              : null,
        ),
    ];

    final list = ListView(
      padding: EdgeInsets.only(
        top: 8,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _FontPreviewCard(currentName: _currentName(context, state)),
        ),
        if (state.isMojian)
          SwitchListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            title: Text(l10n.appearance_fontSerifTitles),
            subtitle: Text(l10n.appearance_fontSerifTitlesDesc),
            value: state.serifTitles,
            onChanged: notifier.setMojianSerifTitles,
          ),
        _SectionHeader(l10n.appearance_fontChoose),
        ...rows,
        ListenableBuilder(
          listenable: _recommended,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 下载过的排前面：常用的那几个不用往下翻
              for (final font in [
                ..._recommended.fonts.where(
                  (f) => _recommended.installedPath(f) != null,
                ),
                ..._recommended.fonts.where(
                  (f) => _recommended.installedPath(f) == null,
                ),
              ])
                _recommendedRow(context, font, activeCustomPath),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          leading: _ActionGlyph(icon: Symbols.upload_file_rounded),
          title: Text(l10n.appearance_fontCustomTitle),
          subtitle: Text(l10n.appearance_fontCustomHint),
          onTap: _importFont,
        ),
        if (_installedSupported)
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            leading: _ActionGlyph(icon: Symbols.font_download_rounded),
            title: Text(l10n.appearance_fontInstalled),
            subtitle: Text(l10n.appearance_fontInstalledHint),
            onTap: _pickInstalled,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${l10n.appearance_recommendedFontsHint}\n'
            '${l10n.appearance_fontMissingGlyphHint}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearance_font)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Breakpoints.maxContentWidth,
          ),
          child: list,
        ),
      ),
    );
  }

  Widget _recommendedRow(
    BuildContext context,
    RecommendedFont font,
    String? activeCustomPath,
  ) {
    final l10n = context.l10n;
    final path = _recommended.installedPath(font);
    final downloading = _recommended.isDownloading(font.id);
    final meta = [
      if (path != null) l10n.appearance_fontDownloaded,
      if (font.nameEn.isNotEmpty) font.nameEn,
      if (font.sizeLabel.isNotEmpty) font.sizeLabel,
      if (path == null && font.domesticMirror)
        l10n.appearance_recommendedFontDomestic,
    ].join(' · ');
    final selected = path != null && path == activeCustomPath;
    return _FontRow(
      family: path == null ? null : RecommendedFontService.familyNameFor(path),
      previewable: path != null,
      title: font.name,
      subtitle: meta,
      selected: selected,
      needsDownload: path == null,
      downloading: downloading,
      progress: _recommended.progressOf(font.id)?.fraction,
      onCancel: () => _recommended.cancel(font.id),
      onTap: selected ? null : () => _useRecommended(font),
      onDelete: path == null || selected
          ? null
          : () => _deleteRecommended(font),
    );
  }

  static String _currentName(BuildContext context, ThemeState state) {
    final l10n = context.l10n;
    return switch (state.fontFamily) {
      AppFontFamily.system => l10n.appearance_fontSystem,
      AppFontFamily.miSans => 'MiSans',
      AppFontFamily.installed =>
        state.installedFontName ??
            state.installedFontFamily ??
            l10n.appearance_fontInstalled,
      AppFontFamily.custom =>
        state.customFontPath != null && File(state.customFontPath!).existsSync()
            ? (state.customFontName ?? l10n.appearance_fontImported)
            : l10n.appearance_fontCustomMissing,
    };
  }
}

/// 预览：页面本身就按当前字体渲染，标题与正文各写一行。
class _FontPreviewCard extends StatelessWidget {
  const _FontPreviewCard({required this.currentName});

  final String currentName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.appearance_fontPreviewTitle,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.appearance_fontPreviewText,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.appearance_fontCurrent(currentName),
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: theme.extension<MojianTokens>() != null
          ? MojianSectionLabel(text)
          : Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
    );
  }
}

/// 字体行：左边用该字体写的「字」，名字也用它渲染；右边一个状态。
class _FontRow extends StatelessWidget {
  const _FontRow({
    required this.title,
    required this.selected,
    this.family,
    this.previewable = true,
    this.subtitle,
    this.subtitleError = false,
    this.onTap,
    this.needsDownload = false,
    this.downloading = false,
    this.progress,
    this.onCancel,
    this.onDelete,
    this.action,
  });

  final String title;
  final bool selected;

  /// 预览用的字体族（[previewable] 为 false 时不用：还没下载 / 文件丢了）
  final String? family;
  final bool previewable;
  final String? subtitle;
  final bool subtitleError;
  final VoidCallback? onTap;
  final bool needsDownload;
  final bool downloading;
  final double? progress;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;

  /// 行尾附加按钮（系统字体的「更换」）
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    final previewFamily = previewable ? family : null;

    Widget? status;
    if (downloading) {
      status = IconButton(
        tooltip: l10n.appearance_recommendedFontCancel,
        onPressed: onCancel,
        icon: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(value: progress, strokeWidth: 2.5),
        ),
      );
    } else if (selected) {
      status = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Icon(Symbols.check_circle_rounded, fill: 1, color: cs.primary),
      );
    } else if (needsDownload) {
      status = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Icon(
          Symbols.download_rounded,
          color: cs.primary,
          semanticLabel: l10n.appearance_recommendedFontDownload,
        ),
      );
    } else if (onDelete != null) {
      status = IconButton(
        tooltip: l10n.appearance_recommendedFontDelete,
        onPressed: onDelete,
        icon: Icon(Symbols.delete_rounded, size: 20, color: cs.outline),
      );
    }

    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.28)
          : Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        selected: selected,
        selectedColor: cs.onSurface,
        leading: _GlyphTile(family: previewFamily, enabled: previewable),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontFamily: previewFamily,
            fontWeight: selected ? FontWeight.w600 : null,
          ),
        ),
        subtitle: downloading
            ? Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: LinearProgressIndicator(value: progress, minHeight: 3),
              )
            : subtitle == null || subtitle!.isEmpty
            ? null
            : Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: subtitleError ? cs.error : cs.onSurfaceVariant,
                ),
              ),
        trailing: action == null
            ? status
            : Row(mainAxisSize: MainAxisSize.min, children: [action!, ?status]),
        onTap: downloading ? null : onTap,
      ),
    );
  }
}

/// 字体行左边的「字」：用该字体写；不能预览时淡一些
class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.family, required this.enabled});

  final String? family;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '字',
        style: TextStyle(
          fontSize: 20,
          height: 1.1,
          fontFamily: family,
          color: enabled ? cs.onSurface : cs.outline,
        ),
      ),
    );
  }
}

/// 「导入字体文件」「系统字体」两个动作行的图标，和字体行左边对齐
class _ActionGlyph extends StatelessWidget {
  const _ActionGlyph({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      height: 40,
      child: Icon(icon, color: cs.primary),
    );
  }
}

/// 系统已安装字体的选择面板：搜索框 + 列表，每行用该字体自身的 family 渲染
/// 标签做预览（滚动时才 build 到的那几行才会触发系统字体加载）。
///
/// 外壳走 [AppBottomSheet.showDraggable]：面板带搜索框，高度必须交给
/// DraggableScrollableSheet 托管（与 sticker_market_sheet 同款理由），键盘
/// 内边距由列表自己加。
class _SystemFontPickerSheet extends StatefulWidget {
  const _SystemFontPickerSheet({
    required this.scrollController,
    required this.selected,
  });

  /// 由 DraggableScrollableSheet 提供，必须交给列表才能联动拖拽缩放。
  final ScrollController scrollController;

  /// 当前生效的 family，用于打勾。
  final String? selected;

  @override
  State<_SystemFontPickerSheet> createState() => _SystemFontPickerSheetState();
}

class _SystemFontPickerSheetState extends State<_SystemFontPickerSheet> {
  /// 首次进入面板时枚举（后台 isolate，第二次起走内存缓存）
  late final Future<List<SystemFont>> _fonts = SystemFontService.list();

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SystemFont> _filtered(List<SystemFont> fonts) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return fonts;
    // 中英文名都参与匹配：搜「微软」和搜「yahei」都能命中
    return [
      for (final font in fonts)
        if (font.family.toLowerCase().contains(query) ||
            (font.localizedFamily?.toLowerCase().contains(query) ?? false))
          font,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final localized = Localizations.localeOf(context).languageCode == 'zh';

    return FutureBuilder<List<SystemFont>>(
      future: _fonts,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: LoadingSpinner());
        }
        final fonts = snapshot.data ?? const <SystemFont>[];
        if (fonts.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.appearance_fontInstalledEmpty,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        final filtered = _filtered(fonts);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.appearance_fontInstalledSearch,
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(Symbols.search_rounded, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Symbols.close_rounded, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: theme.colorScheme.primary),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        l10n.appearance_fontInstalledSearchEmpty,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: widget.scrollController,
                      // 外壳不叠加键盘内边距，键盘弹出时底部由列表自己让位
                      padding: EdgeInsets.only(
                        top: 4,
                        bottom: 8 + MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final font = filtered[index];
                        final isSelected = font.family == widget.selected;
                        return ListTile(
                          title: Text(
                            font.label(localized: localized),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: font.family),
                          ),
                          trailing: isSelected
                              ? Icon(
                                  Symbols.check_rounded,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(font),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
