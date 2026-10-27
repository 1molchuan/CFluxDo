/// 编辑器 `#` 补全的候选（Discourse `/hashtags/search.json` 的一项）。
///
/// 选中后写进正文的是 `#ref`：分类与标签同名时 [ref] 会带类型后缀
/// （如 `ai::tag`），这样 cook 时能分清是哪一个。
class HashtagSuggestion {
  const HashtagSuggestion({
    required this.type,
    required this.text,
    required this.ref,
    required this.relativeUrl,
    this.slug,
    this.description,
    this.icon,
    this.styleType,
    this.emoji,
    this.colors = const [],
    this.id,
  });

  /// `category` / `tag`（站点插件还可能注册别的类型）
  final String type;

  /// 列表里显示的名字（分类显示名、标签名）
  final String text;

  /// 写进正文的引用串（不带 `#`）
  final String ref;

  /// 站内地址，如 `/c/develop/4`、`/tag/ai`
  final String relativeUrl;

  final String? slug;
  final String? description;

  /// FontAwesome 图标名（分类可自定义，标签一般是 `tag`）
  final String? icon;

  /// 分类的显示样式：`square`（色块）/ `icon` / `emoji`
  final String? styleType;
  final String? emoji;

  /// 十六进制颜色（不带 `#`），分类色块与图标着色用
  final List<String> colors;
  final int? id;

  bool get isCategory => type == 'category';
  bool get isTag => type == 'tag';

  /// 写进正文的文本
  String get insertText => '#$ref';

  static HashtagSuggestion? fromJson(Map<String, dynamic> json) {
    final ref = json['ref'] as String?;
    final text = json['text'] as String?;
    if (ref == null || ref.isEmpty || text == null) return null;
    return HashtagSuggestion(
      type: json['type'] as String? ?? '',
      text: text,
      ref: ref,
      relativeUrl: json['relative_url'] as String? ?? '',
      slug: json['slug'] as String?,
      description: json['description'] as String?,
      icon: json['icon'] as String?,
      styleType: json['style_type'] as String?,
      emoji: json['emoji'] as String?,
      colors: [
        for (final color in (json['colors'] as List? ?? const []))
          if (color is String && color.isNotEmpty) color,
      ],
      id: (json['id'] as num?)?.toInt(),
    );
  }
}

/// 按搜索词取 `#` 补全候选
typedef HashtagDataSource = Future<List<HashtagSuggestion>> Function(String term);

/// 光标前的 `#查询`：`#` 前面是行首或空白（不把 `a#b`、`&#123;` 当成补全），
/// 查询里可以有字母数字（含中文）、`-`、`_` 和类型后缀用的 `:`。
final RegExp hashtagQueryPattern = RegExp(
  r'(?:^|(?<=\s))#([\p{L}\p{N}_\-:]*)$',
  unicode: true,
);
