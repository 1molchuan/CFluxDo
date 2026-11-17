import 'package:markdown/markdown.dart' as md;

/// 把商品描述（Markdown）转成交给 App 的 HTML 渲染组件的 HTML。
///
/// 与商城前端 `renderProductDescription` 口径一致：
/// - 单个换行就是换行（marked 的 `breaks: true`）；
/// - 图片**不内嵌**，变成指向图片地址的链接（描述里的图片可能来自任意域名）；
/// - 原始 HTML 一律当文本显示（不认 `<img>`、`<iframe>` 之类的标签）；
/// - `++下划线++` 扩展转成 `<u>`。
String ldShopDescriptionHtml(String markdown) {
  final raw = markdown.trim();
  if (raw.isEmpty) return '';
  final document = md.Document(
    // 不带任何扩展集：默认的 commonMark 集里有 InlineHtmlSyntax（原样透传 HTML）
    extensionSet: md.ExtensionSet.none,
    // 不用默认块语法：默认里有 HtmlBlockSyntax（原样透传 HTML 块）
    withDefaultBlockSyntaxes: false,
    blockSyntaxes: const [
      md.EmptyBlockSyntax(),
      md.FencedCodeBlockSyntax(),
      md.SetextHeaderSyntax(),
      md.HeaderSyntax(),
      md.CodeBlockSyntax(),
      md.BlockquoteSyntax(),
      md.HorizontalRuleSyntax(),
      md.TableSyntax(),
      md.UnorderedListSyntax(),
      md.OrderedListSyntax(),
      md.LinkReferenceDefinitionSyntax(),
      md.ParagraphSyntax(),
    ],
    // 不加 InlineHtmlSyntax：行内 HTML 按文本转义
    inlineSyntaxes: [
      _UnderlineSyntax(),
      _NewlineAsBreakSyntax(),
      md.StrikethroughSyntax(),
      md.AutolinkExtensionSyntax(),
    ],
    encodeHtml: true,
  );
  return md.renderToHtml(_imagesToLinks(document.parse(raw)));
}

/// 递归把 `<img>` 换成 `<a href=图片地址>说明文字或地址</a>`。
List<md.Node> _imagesToLinks(List<md.Node> nodes) {
  return [
    for (final node in nodes)
      if (node is md.Element && node.tag == 'img')
        _imageLink(node)
      else if (node is md.Element && node.children != null)
        _copyWithChildren(node, _imagesToLinks(node.children!))
      else
        node,
  ];
}

md.Node _imageLink(md.Element image) {
  // src 已由 markdown 规整过（百分号编码），alt 来自已转义的文本节点
  final src = image.attributes['src'] ?? '';
  final alt = (image.attributes['alt'] ?? '').trim();
  final label = alt.isEmpty ? _escape(src) : alt;
  if (!_isHttpUrl(src)) return md.Text(label);
  final link = md.Element('a', [md.Text(label)]);
  link.attributes['href'] = src;
  return link;
}

md.Element _copyWithChildren(md.Element element, List<md.Node> children) {
  final copy = md.Element(element.tag, children);
  copy.attributes.addAll(element.attributes);
  return copy;
}

bool _isHttpUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 段落里的单个换行渲染成 `<br>`（商城前端 marked 开了 `breaks: true`）。
class _NewlineAsBreakSyntax extends md.InlineSyntax {
  _NewlineAsBreakSyntax() : super(r'[ \t]*\n', startCharacter: null);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// `++下划线++`（GitLab 风格扩展，商城前端支持）。开标记要在行首或空白、
/// 括号、引号之后，免得把「C++」当成下划线。
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax()
    : super(r'\+\+([^\n+][^\n]*?)\+\+(?!\+)', startCharacter: 0x2B);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final pos = startMatchPos ?? parser.pos;
    if (pos > 0) {
      final before = parser.source[pos - 1];
      if (!RegExp('[\\s(（"\'“]').hasMatch(before)) return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('u', [md.Text(_escape(match.group(1)!))]));
    return true;
  }
}
