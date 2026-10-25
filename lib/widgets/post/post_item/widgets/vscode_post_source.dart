// 正文代码结构参考 Twelveeee/linuxdo-vscode-ui 的 topic-editor.js（MIT）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/vscode_body_style.dart';
import '../../../../providers/preferences_provider.dart';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../../../theme/vscode_theme.dart';
import '../../../../l10n/s.dart';
import '../../../../utils/html_to_markdown.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../utils/platform_utils.dart';
import '../../../../utils/url_helper.dart';
import '../../../../models/topic.dart';
import '../../../../pages/image_viewer_page.dart';
import '../../../../services/html_parse_service.dart';
import '../../../content/discourse_html_content/image_utils.dart';
import '../quote_selection_helper.dart';
import 'vscode_source_link_recognizer.dart';
import '../../../content/discourse_image.dart';

/// 与富文本共用现有 cooked 数据，不请求逐楼 raw，也不创建编辑控制器。
class VscodePostSource extends ConsumerStatefulWidget {
  const VscodePostSource({
    super.key,
    required this.document,
    required this.post,
    required this.topicId,
    this.onQuoteSelection,
    required this.richTextBuilder,
    this.firstLine = 1,
    this.fontScale = 1,
    this.firstUnit = true,
    this.lastUnit = true,
    this.topicTitle,
  });

  final VscodeSourceDocument document;
  final Post post;
  final int topicId;
  final QuoteSelectionCallback? onQuoteSelection;
  final WidgetBuilder richTextBuilder;
  final int firstLine;
  final double fontScale;
  final bool firstUnit;
  final bool lastUnit;
  final String? topicTitle;

  static bool enabled(BuildContext context) =>
      Theme.of(context).extension<VscodeTokens>() != null;

  @override
  ConsumerState<VscodePostSource> createState() => _VscodePostSourceState();
}

class _VscodePostSourceState extends ConsumerState<VscodePostSource> {
  late bool _showRichText;
  final _links = <(String, bool), VscodeSourceLinkRecognizer>{};
  String? _selectedText;
  bool _hovered = false;
  bool _focused = false;
  final _toolsVisible = ValueNotifier(false);
  VscodeSourceDocument? _activeDocument;

  @override
  void initState() {
    super.initState();
    _showRichText = widget.document.preferRichText;
  }

  @override
  void didUpdateWidget(VscodePostSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _disposeLinks();
      _selectedText = null;
      _showRichText = widget.document.preferRichText;
    }
  }

  void _disposeLinks() {
    for (final recognizer in _links.values) {
      recognizer.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _disposeLinks();
    _toolsVisible.dispose();
    super.dispose();
  }

  VscodeSourceLinkRecognizer _link(_SourceRun run) => _links.putIfAbsent(
    (run.url!, run.image),
    () => VscodeSourceLinkRecognizer(
      requireControl: !run.image,
      onOpen: () {
        if (run.image) {
          _openImage(run);
        } else {
          launchContentLink(context, run.url!);
        }
      },
    ),
  );

  Future<void> _openImage(_SourceRun run) async {
    final parsed = await HtmlParseService.instance.parse(widget.post.cooked);
    if (!mounted) return;
    final gallery = parsed.galleryInfo;
    final index = gallery.findIndex(run.url!) ??
        gallery.findIndex(run.previewUrl ?? run.url!);
    final visible = gallery.getVisibleIndices({});
    final selectedIndex = index == null ? -1 : visible.indexOf(index);
    final urls = selectedIndex < 0
        ? [run.url!]
        : visible.map((i) => gallery.images[i]).toList();
    final resolved = await Future.wait(
      urls.map(DiscourseImageUtils.resolveUploadUrl),
    );
    final initialIndex = selectedIndex < 0 ? 0 : selectedIndex;
    if (!mounted || resolved[initialIndex] == null) return;
    final images = [
      for (var i = 0; i < urls.length; i++)
        DiscourseImageUtils.getOriginalUrl(
          UrlHelper.resolveUrlWithCdn(resolved[i] ?? urls[i]),
        ),
    ];
    // 源码标签不是图片瓦片，不伪造 Hero；仍沿用查看器的原图、画廊及缩略图占位。
    ImageViewerPage.open(
      context,
      images[initialIndex],
      galleryImages: images,
      initialIndex: initialIndex,
      thumbnailUrl: UrlHelper.resolveUrlWithCdn(run.previewUrl ?? run.url!),
      filenames: selectedIndex < 0
          ? null
          : visible.map(gallery.getFilename).toList(),
    );
  }

  Color _color(_SourceKind kind, VscodeTokens tokens) => switch (kind) {
    _SourceKind.normal => tokens.foreground,
    _SourceKind.keyword => tokens.syntaxKeyword,
    _SourceKind.string => tokens.syntaxString,
    _SourceKind.comment => tokens.syntaxComment,
    _SourceKind.link => tokens.accent,
    _SourceKind.type => tokens.syntaxType,
    _SourceKind.function => tokens.syntaxFunction,
  };

  TextSpan _sourceLine(
    List<_SourceRun> runs,
    VscodeSourceDocument document,
    VscodeTokens tokens,
  ) {
    final comment =
        document.programming && runs.first.text == document.bodyPrefix;
    return TextSpan(
      children: [
        for (final run in runs)
          TextSpan(
            text: comment && identical(run, runs.first)
                ? document.bodyPrefix.trimLeft()
                : run.text,
            style: TextStyle(
              // 代码式正文已经位于注释中，行内格式和链接不应重新开启语法着色。
              color: comment ? tokens.syntaxComment : _color(run.kind, tokens),
              fontStyle: run.italic ? FontStyle.italic : null,
              fontWeight: run.bold ? FontWeight.w600 : null,
              decoration: run.strike
                  ? TextDecoration.lineThrough
                  : run.url == null || run.image
                  ? null
                  : TextDecoration.underline,
            ),
            semanticsLabel: run.url == null
                ? null
                : run.image
                ? '${run.text}，单击查看大图'
                : '${run.text}，按住 Ctrl 并单击打开 ${run.url}',
            recognizer: run.url == null ? null : _link(run),
          ),
      ],
    );
  }

  Widget _richBody(BuildContext context, VscodeTokens tokens) {
    final inset = VscodeTheme.sourceTextInset(widget.fontScale);
    return CustomPaint(
      painter: _SourceGutterPainter(inset - 12, tokens.border),
      child: Padding(
        padding: EdgeInsets.only(left: inset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.firstUnit)
              Transform.translate(
                offset: Offset(-inset, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: inset - 12,
                      child: Text(
                        '${widget.firstLine}',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: tokens.muted),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _activeDocument!.generatedLines.first,
                        style: TextStyle(
                          color: tokens.syntaxComment,
                          fontFamily: 'Consolas',
                          fontSize: 13 * widget.fontScale,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            widget.richTextBuilder(context),
          ],
        ),
      ),
    );
  }

  InlineSpan _lineHint(List<_SourceRun> line) {
    final image = line.where((run) => run.image).firstOrNull;
    if (image != null) {
      return WidgetSpan(
        child: DiscourseImage(
          url: UrlHelper.resolveUrlWithCdn(image.previewUrl ?? image.url!),
          width: 280,
          height: 180,
          fit: BoxFit.contain,
          enableLightbox: false,
        ),
      );
    }
    return TextSpan(
      text: line.any((run) => run.url != null) ? '按住 Ctrl 并单击打开链接；拖动可选择文本' : '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<VscodeTokens>()!;
    final bodyStyle = ref.watch(
      preferencesProvider.select((p) => p.vscodeBodyStyle),
    );
    final language = ref.watch(
      preferencesProvider.select((p) => p.vscodeCodeLanguage),
    );
    final document = VscodeSourceDocument.forPost(
      widget.post,
      html: widget.document.originalHtml,
      topicTitle: widget.topicTitle,
      style: bodyStyle,
      language: language,
      firstUnit: widget.firstUnit,
      lastUnit: widget.lastUnit,
    );
    if (!identical(_activeDocument, document)) {
      _disposeLinks();
      _selectedText = null;
      _showRichText = document.preferRichText;
      _activeDocument = document;
    }
    // 剧透、隐藏和互动内容始终交给原文，不提供可绕过门禁的源码入口。
    if (document.preferRichText) {
      return Padding(
        padding: const EdgeInsets.only(right: 28),
        child: _richBody(context, tokens),
      );
    }
    final style = theme.textTheme.bodyMedium!.copyWith(
      fontFamily: 'Consolas',
      fontFamilyFallback: VscodeTheme.codeFontFallback(
        theme.textTheme.bodyMedium?.fontFamily,
      ),
      fontSize: 13 * widget.fontScale,
      height: 1.5,
      color: tokens.foreground,
    );
    final gutterWidth = VscodeTheme.sourceTextInset(widget.fontScale) - 12;
    final visiblePrefix = document.bodyPrefix.trimLeft();
    final bodyIndent =
        (document.bodyPrefix.length - visiblePrefix.length) *
        style.fontSize! *
        0.6;

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _toolsVisible.value = _hovered || _focused;
      },
      onExit: (_) {
        _hovered = false;
        _toolsVisible.value = _focused;
      },
      child: Focus(
        onFocusChange: (focused) {
          _focused = focused;
          _toolsVisible.value = _hovered || _focused;
        },
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 28),
              child: _showRichText
                  ? _richBody(context, tokens)
                  : SelectionArea(
                      key: ValueKey(document),
                      onSelectionChanged: (selection) =>
                          _selectedText = selection?.plainText,
                      contextMenuBuilder: (context, state) =>
                          AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: state.contextMenuAnchors,
                            buttonItems: QuoteSelectionHelper.buildMenuItems(
                              baseItems: [
                                ...state.contextMenuButtonItems,
                                if (widget.onQuoteSelection == null &&
                                    _selectedText?.trim().isNotEmpty == true)
                                  ContextMenuButtonItem(
                                    label: S.current.common_copyQuote,
                                    onPressed: () {
                                      final text = document.quoteText(
                                        _selectedText,
                                      );
                                      if (text != null) {
                                        QuoteSelectionHelper.copyQuoteToClipboard(
                                          selectedText: text,
                                          post: widget.post,
                                          topicId: widget.topicId,
                                        );
                                      }
                                      state.hideToolbar();
                                    },
                                  ),
                                ContextMenuButtonItem(
                                  label: '查看原文',
                                  onPressed: () {
                                    state.hideToolbar();
                                    setState(() => _showRichText = true);
                                  },
                                ),
                              ],
                              plainText: document.quoteText(_selectedText),
                              post: widget.post,
                              topicId: widget.topicId,
                              onQuoteSelection: widget.onQuoteSelection,
                              hideToolbar: state.hideToolbar,
                            ),
                          ),
                      child: CustomPaint(
                        painter: _SourceGutterPainter(
                          gutterWidth,
                          tokens.border,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var index = 0;
                              index < document.lineCount;
                              index++
                            )
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectionContainer.disabled(
                                    child: ExcludeSemantics(
                                      child: Container(
                                        width: gutterWidth,
                                        padding: const EdgeInsets.only(
                                          right: 12,
                                        ),
                                        alignment: Alignment.topRight,
                                        // 分隔线由整段绘制，软换行不会留下断口。
                                        child: Text(
                                          '${widget.firstLine + index}',
                                          style: style.copyWith(
                                            color: tokens.lineNumber,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left:
                                            document.programming &&
                                                document
                                                        ._lines[index]
                                                        .first
                                                        .text ==
                                                    document.bodyPrefix
                                            ? bodyIndent
                                            : 0,
                                      ),
                                      child: Tooltip(
                                        richMessage: _lineHint(
                                          document._lines[index],
                                        ),
                                        child: Text.rich(
                                          _sourceLine(
                                            document._lines[index],
                                            document,
                                            tokens,
                                          ),
                                          style: style,
                                          softWrap: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _toolsVisible,
                builder: (_, visible, child) => Opacity(
                  opacity: visible || !PlatformUtils.isDesktop ? 1 : 0,
                  alwaysIncludeSemantics: true,
                  child: child,
                ),
                child: IconButton(
                  tooltip: _showRichText ? '查看源码' : '查看原文',
                  onPressed: () => setState(() {
                    _showRichText = !_showRichText;
                    _selectedText = null;
                  }),
                  icon: Icon(
                    _showRichText ? Icons.code : Icons.article_outlined,
                  ),
                  iconSize: 15,
                  style: IconButton.styleFrom(
                    foregroundColor: tokens.muted,
                    backgroundColor: tokens.background,
                    minimumSize: const Size(24, 24),
                    maximumSize: const Size(24, 24),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const RoundedRectangleBorder(),
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

/// 只缓存无上下文的转换与词法结果。长帖仍由外层 sliver 按原有 chunk 挂载，
/// 不把整楼排成一个 Text；回滚已回收的段落也无需重新转换。
class VscodeSourceDocument {
  VscodeSourceDocument._(
    this._lines,
    this.preferRichText,
    this.originalHtml, {
    this.programming = false,
    this.bodyPrefix = '',
    this.generatedLines = const {},
  });

  final List<List<_SourceRun>> _lines;
  final bool preferRichText;
  final String originalHtml;
  final bool programming;
  final String bodyPrefix;
  final Set<String> generatedLines;

  /// 移除本地生成的声明和注释前缀，正文格式由引用链路从 cooked 还原。
  String? quoteText(String? selection) {
    if (selection == null) return null;
    if (!programming && generatedLines.isEmpty) return selection;
    final lines = selection
        .split('\n')
        .where((line) => !generatedLines.contains(line.trim()))
        .map((line) {
          if (bodyPrefix.isNotEmpty && line.startsWith(bodyPrefix)) {
            return line.substring(bodyPrefix.length);
          }
          final trimmed = line.trimLeft();
          final prefix = bodyPrefix.trimLeft();
          return prefix.isNotEmpty && trimmed.startsWith(prefix)
              ? trimmed.substring(prefix.length)
              : line;
        });
    final text = lines.join('\n').trim();
    return text.isEmpty ? null : text;
  }

  static VscodeSourceDocument forPost(
    Post post, {
    String? html,
    String? topicTitle,
    VscodeBodyStyle style = VscodeBodyStyle.compact,
    VscodeCodeLanguage language = VscodeCodeLanguage.java,
    bool firstUnit = true,
    bool lastUnit = true,
  }) {
    final source = html ?? post.cooked;
    final key = (
      source,
      style,
      language,
      firstUnit,
      lastUnit,
      post.postNumber,
      post.username,
      topicTitle,
    );
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    if (style == VscodeBodyStyle.compact) {
      final result = _withAuthor(forHtml(source), post, language, firstUnit);
      _store(key, result);
      return result;
    }
    final fragment = html_parser.parseFragment(source);
    if (fragment.querySelector(_richSelector) != null) {
      final result = _withAuthor(forHtml(source), post, language, firstUnit);
      _store(key, result);
      return result;
    }
    final bodyLines = _cookedLines(fragment);
    if (bodyLines.isEmpty) {
      final result = _withAuthor(forHtml(source), post, language, firstUnit);
      _store(key, result);
      return result;
    }
    final python = language == VscodeCodeLanguage.python;
    final first = post.postNumber == 1;
    var topicName = (topicTitle ?? 'Topic').replaceAll(_invalidIdentifier, '_');
    if (topicName.replaceAll('_', '').isEmpty) topicName = 'Topic';
    if (RegExp(r'^\p{N}', unicode: true).hasMatch(topicName)) {
      topicName = 'Topic_$topicName';
    }
    final identifier = post.username
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final user = identifier.replaceAll('_', '').isEmpty ? 'user' : identifier;
    final method = 'reply_${user}_${post.postNumber.abs()}';
    final prefix = python ? '    # ' : '  // ';
    final lines = <List<_SourceRun>>[];
    final generated = <String>{};
    void declaration(String text) {
      generated.add(text.trim());
      lines.add(_declarationRuns(text, topicName));
    }

    if (firstUnit) {
      final author = _authorLine(post, language);
      generated.add(author);
      lines.add([_SourceRun(author, _SourceKind.comment)]);
      declaration(
        first
            ? python
                  ? 'class $topicName:'
                  : 'public class $topicName {'
            : python
            ? 'def $method(self):'
            : 'public void $method() {',
      );
    }
    // 从 cooked 提取可见区块，保留链接标签和行内样式，不展示 Markdown 编码。
    for (final body in bodyLines) {
      lines.add([_SourceRun(prefix, _SourceKind.comment), ...body]);
    }
    if (lastUnit) {
      declaration(
        python
            ? first
                  ? '    # end of topic'
                  : '    return None'
            : '}',
      );
    }
    final result = VscodeSourceDocument._(
      lines,
      false,
      source,
      programming: true,
      bodyPrefix: prefix,
      generatedLines: generated,
    );
    _store(key, result);
    return result;
  }

  static String _authorLine(Post post, VscodeCodeLanguage language) {
    final marker = language == VscodeCodeLanguage.python ? '#' : '//';
    final username = post.username.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return '$marker @$username · #${post.postNumber}';
  }

  static VscodeSourceDocument _withAuthor(
    VscodeSourceDocument body,
    Post post,
    VscodeCodeLanguage language,
    bool firstUnit,
  ) {
    if (!firstUnit) return body;
    final author = _authorLine(post, language);
    return VscodeSourceDocument._(
      [
        [_SourceRun(author, _SourceKind.comment)],
        ...body._lines,
      ],
      body.preferRichText,
      body.originalHtml,
      generatedLines: {author},
    );
  }

  int get lineCount => _lines.length;
  static final _cache = <Object, VscodeSourceDocument>{};
  static int _cachedCharacters = 0;
  static const _characterLimit = 2 * 1024 * 1024;

  static VscodeSourceDocument forHtml(String html) {
    final key = html;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final fragment = html_parser.parseFragment(html);
    // 不把剧透、访问控制、折叠区直接摊平成可见文字；默认交给真实原文组件。
    final rich = fragment.querySelector(_richSelector) != null;
    final markdown = rich ? '' : HtmlToMarkdown.convert(html);
    final result = VscodeSourceDocument._(
      markdown.isEmpty
          ? const []
          : _tokenize(markdown, images: _imageElements(fragment)),
      rich || markdown.isEmpty,
      html,
    );
    _store(key, result);
    return result;
  }

  static void _store(Object key, VscodeSourceDocument result) {
    _cache[key] = result;
    _cachedCharacters += result.originalHtml.length;
    while (_cache.length > 128 || _cachedCharacters > _characterLimit) {
      final oldest = _cache.keys.first;
      _cachedCharacters -= _cache.remove(oldest)!.originalHtml.length;
    }
  }

  static final _invalidIdentifier = RegExp(r'[^\p{L}\p{N}_]', unicode: true);
  static const _keywords = {
    'package',
    'import',
    'from',
    'class',
    'public',
    'void',
    'def',
    'self',
    'return',
    'None',
  };
  static final _declaration = RegExp(r'[\p{L}_][\p{L}\p{N}_]*', unicode: true);

  static List<_SourceRun> _declarationRuns(String text, String typeName) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('#') || trimmed.startsWith('//')) {
      return [_SourceRun(text, _SourceKind.comment)];
    }
    final runs = <_SourceRun>[];
    var cursor = 0;
    for (final match in _declaration.allMatches(text)) {
      if (match.start > cursor) {
        runs.add(
          _SourceRun(text.substring(cursor, match.start), _SourceKind.normal),
        );
      }
      final token = match.group(0)!;
      runs.add(
        _SourceRun(
          token,
          token == typeName
              ? _SourceKind.type
              : token.startsWith('reply_')
              ? _SourceKind.function
              : _keywords.contains(token)
              ? _SourceKind.keyword
              : _SourceKind.normal,
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      runs.add(_SourceRun(text.substring(cursor), _SourceKind.normal));
    }
    return runs;
  }

  static const _richSelector =
      '.spoiler, .spoiled, details, .policy, .poll, iframe, video, audio, '
      'svg:not(.d-icon), table, .onebox, [hidden], .hidden, [data-wrap="hide"]';

  static final _whitespace = RegExp(r'\s+');
  static final _nonWhitespace = RegExp(r'\S');
  static final _trailingNewline = RegExp(r'\n$');

  static List<List<_SourceRun>> _cookedLines(dom.DocumentFragment fragment) {
    final lines = <List<_SourceRun>>[];
    var current = <_SourceRun>[];
    void flush() {
      if (current.any((run) => run.text.trim().isNotEmpty)) lines.add(current);
      current = [];
    }

    void append(_SourceRun run, String prefix) {
      if (current.isEmpty && prefix.isNotEmpty) {
        current.add(_SourceRun(prefix, _SourceKind.comment));
      }
      current.add(run);
    }

    void visit(
      dom.Node node, {
      String prefix = '',
      _SourceKind kind = _SourceKind.normal,
      String? url,
      bool bold = false,
      bool italic = false,
      bool strike = false,
    }) {
      if (node is dom.Text) {
        final text = node.text.replaceAll(_whitespace, ' ');
        if (text.trim().isNotEmpty || current.isNotEmpty) {
          append(
            _SourceRun(
              text,
              kind,
              url: url,
              bold: bold,
              italic: italic,
              strike: strike,
            ),
            prefix,
          );
        }
        return;
      }
      if (node is! dom.Element) return;
      final tag = node.localName;
      if (tag == 'script' ||
          tag == 'style' ||
          tag == 'svg' ||
          node.classes.contains('meta')) {
        return;
      }
      if (tag == 'br') {
        flush();
        return;
      }
      if (tag == 'img') {
        if (node.classes.contains('avatar')) return;
        final alt = node.attributes['alt'] ?? '';
        if (node.classes.contains('emoji') ||
            node.classes.contains('emoji-custom')) {
          append(_SourceRun(alt, kind), prefix);
          return;
        }
        final src = _originalImageUrl(node);
        if (src != null && src.isNotEmpty) {
          flush();
          append(
            _SourceRun(
              alt.isEmpty ? '[图片]' : '[图片] $alt',
              _SourceKind.link,
              url: src,
              image: true,
              previewUrl: node.attributes['data-src'] ?? node.attributes['src'],
            ),
            prefix,
          );
          flush();
        }
        return;
      }
      if (tag == 'pre') {
        flush();
        final code = node.text
            .replaceAll('\r', '')
            .replaceFirst(_trailingNewline, '');
        for (final line in _tokenize(code, codeOnly: true)) {
          lines.add([
            if (prefix.isNotEmpty) _SourceRun(prefix, _SourceKind.comment),
            ...line,
          ]);
        }
        return;
      }
      final block = const {
        'p',
        'div',
        'section',
        'ul',
        'ol',
        'li',
        'blockquote',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'hr',
      }.contains(tag);
      if (block) flush();
      var nextPrefix = prefix;
      if (tag == 'li') {
        final parent = node.parent;
        final index = parent?.children.indexOf(node) ?? 0;
        nextPrefix += parent?.localName == 'ol' ? '${index + 1}. ' : '- ';
      } else if (tag == 'ul' || tag == 'ol') {
        nextPrefix = prefix.replaceAll(_nonWhitespace, ' ');
      } else if (tag == 'blockquote') {
        nextPrefix += '> ';
      } else if (tag == 'hr') {
        append(const _SourceRun('───', _SourceKind.comment), prefix);
      }
      final nextUrl = tag == 'a' ? node.attributes['href'] : url;
      final heading = const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag);
      final nextKind = nextUrl != null
          ? _SourceKind.link
          : tag == 'code' || tag == 'kbd'
          ? _SourceKind.string
          : tag == 'strong' || tag == 'b' || heading
          ? _SourceKind.function
          : kind;
      for (final child in node.nodes) {
        visit(
          child,
          prefix: nextPrefix,
          kind: nextKind,
          url: nextUrl,
          bold: bold || tag == 'strong' || tag == 'b' || heading,
          italic: italic || tag == 'em' || tag == 'i',
          strike: strike || tag == 'del' || tag == 's',
        );
      }
      if (block) flush();
    }

    for (final node in fragment.nodes) {
      visit(node);
    }
    flush();
    return lines;
  }

  static String? _originalImageUrl(dom.Element image) =>
      DiscourseImageUtils.findOriginalImageUrl(image) ??
      image.attributes['data-orig-src'] ??
      image.attributes['data-src'] ??
      image.attributes['src'];

  static Map<String, dom.Element> _imageElements(dom.DocumentFragment fragment) {
    final images = <String, dom.Element>{};
    for (final image in fragment.querySelectorAll('img')) {
      if (image.classes.contains('emoji') ||
          image.classes.contains('emoji-custom') ||
          image.classes.contains('avatar')) {
        continue;
      }
      final original = _originalImageUrl(image);
      for (final url in [
        original,
        image.attributes['src'],
        image.attributes['data-src'],
        image.attributes['data-orig-src'],
      ]) {
        if (url != null && url.isNotEmpty) images[url] = image;
      }
      final sha = image.attributes['data-base62-sha1'];
      if (sha != null && sha.isNotEmpty) {
        final extension = HtmlToMarkdown.extensionFromUrl(
          image.attributes['src'] ?? original,
        );
        images['upload://$sha${extension == null ? '' : '.$extension'}'] = image;
      }
    }
    return images;
  }

  static final _inline = RegExp(
    r'!?\[[^\[\]]*\]\(([^\s)]+)(?:[^)]*)\)|https?://[^\s<>]+|`[^`]+`|\*\*[^*]+\*\*',
  );
  static final _code = RegExp(
    r'''//.*$|#.*$|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:package|self|None|class|const|final|var|let|if|else|return|void|int|double|String|bool|true|false|null|import|from|def|function|async|await|for|while|new|public|private|static)\b''',
  );
  static final _marker = RegExp(r'^(\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+))');
  static final _fence = RegExp(r'^\s*(`{3,}|~{3,})');

  static List<List<_SourceRun>> _tokenize(
    String markdown, {
    bool codeOnly = false,
    Map<String, dom.Element> images = const {},
  }) {
    var inCode = codeOnly;
    final lines = <List<_SourceRun>>[];
    for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
      if (!codeOnly && _fence.hasMatch(line)) {
        inCode = !inCode;
        lines.add([_SourceRun(line, _SourceKind.keyword)]);
        continue;
      }
      if (line.isEmpty) {
        lines.add([const _SourceRun(' ', _SourceKind.normal)]);
        continue;
      }
      final runs = <_SourceRun>[];
      var cursor = 0;
      if (!inCode) {
        final marker = _marker.firstMatch(line);
        if (marker != null) {
          runs.add(_SourceRun(marker.group(0)!, _SourceKind.keyword));
          cursor = marker.end;
        }
      }
      for (final match in (inCode ? _code : _inline).allMatches(line, cursor)) {
        if (match.start > cursor) {
          runs.add(
            _SourceRun(line.substring(cursor, match.start), _SourceKind.normal),
          );
        }
        final text = match.group(0)!;
        final url = inCode
            ? null
            : match.group(1) ?? (text.startsWith('http') ? text : null);
        final kind = inCode
            ? text.startsWith('//') || text.startsWith('#')
                  ? _SourceKind.comment
                  : text.startsWith('"') || text.startsWith("'")
                  ? _SourceKind.string
                  : _SourceKind.keyword
            : url != null
            ? _SourceKind.link
            : _SourceKind.string;
        final image = !inCode && text.startsWith('![') && url != null;
        final element = image ? images[url] : null;
        runs.add(
          _SourceRun(
            text,
            kind,
            url: element == null ? url : _originalImageUrl(element) ?? url,
            image: image,
            previewUrl: element?.attributes['data-src'] ??
                element?.attributes['src'],
          ),
        );
        cursor = match.end;
      }
      if (cursor < line.length) {
        runs.add(_SourceRun(line.substring(cursor), _SourceKind.normal));
      }
      lines.add(runs);
    }
    return lines;
  }
}

enum _SourceKind { normal, keyword, string, comment, link, type, function }

class _SourceRun {
  const _SourceRun(
    this.text,
    this.kind, {
    this.url,
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.image = false,
    this.previewUrl,
  });
  final String text;
  final _SourceKind kind;
  final String? url;
  final bool bold;
  final bool italic;
  final bool strike;
  final bool image;
  final String? previewUrl;
}

class _SourceGutterPainter extends CustomPainter {
  const _SourceGutterPainter(this.width, this.color);

  final double width;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(width, 0),
      Offset(width, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SourceGutterPainter oldDelegate) =>
      oldDelegate.width != width || oldDelegate.color != color;
}
