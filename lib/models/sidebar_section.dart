/// Discourse 侧边栏「自定义分区」（网页侧栏里用户自己建的那一组链接）。
///
/// 接口：`GET/POST /sidebar_sections.json`、`PUT/DELETE
/// /sidebar_sections/{id}.json`。更新时提交**完整**链接数组，数组顺序就是
/// 最终顺序；没有 id 的是新链接，带 `_destroy` 的是删除。
class SidebarSection {
  const SidebarSection({
    required this.id,
    required this.title,
    required this.links,
    this.public = false,
    this.sectionType,
  });

  final int id;
  final String title;
  final List<SidebarSectionLink> links;

  /// 全站公开分区（只有管理员能建能改）
  final bool public;

  /// null = 自定义分区；`community` = 内置的「社区」分区
  final String? sectionType;

  bool get isCommunity => sectionType == 'community';

  /// 当前用户能不能改：自己的私有自定义分区可以；公开分区只有管理员
  bool canEdit({required bool isAdmin}) => !isCommunity && (!public || isAdmin);

  factory SidebarSection.fromJson(Map<String, dynamic> json) {
    final links = json['links'];
    return SidebarSection(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '',
      public: json['public'] == true,
      sectionType: json['section_type'] as String?,
      links: links is List
          ? [
              for (final link in links)
                if (link is Map<String, dynamic>)
                  SidebarSectionLink.fromJson(link),
            ]
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'public': public,
    'section_type': sectionType,
    'links': [for (final link in links) link.toJson()],
  };

  SidebarSection copyWith({String? title, List<SidebarSectionLink>? links}) =>
      SidebarSection(
        id: id,
        title: title ?? this.title,
        links: links ?? this.links,
        public: public,
        sectionType: sectionType,
      );
}

class SidebarSectionLink {
  const SidebarSectionLink({
    this.id,
    required this.name,
    required this.value,
    this.icon = defaultIcon,
    this.segment = 'primary',
  });

  static const defaultIcon = 'link';

  /// 新建的链接还没有 id
  final int? id;
  final String name;

  /// 站内路径（`/c/develop/4`、`/tag/ai`、`/t/123`）或外链（`https://...`）
  final String value;

  /// FontAwesome 图标名（网页同款：实心不带前缀，线框 `far-`，品牌 `fab-`）
  final String icon;
  final String segment;

  bool get isExternal =>
      value.startsWith('http://') || value.startsWith('https://');

  factory SidebarSectionLink.fromJson(Map<String, dynamic> json) =>
      SidebarSectionLink(
        id: (json['id'] as num?)?.toInt(),
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
        icon: json['icon'] as String? ?? defaultIcon,
        segment: json['segment'] as String? ?? 'primary',
      );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'value': value,
    'icon': icon,
    'segment': segment,
  };

  SidebarSectionLink copyWith({String? name, String? value, String? icon}) =>
      SidebarSectionLink(
        id: id,
        name: name ?? this.name,
        value: value ?? this.value,
        icon: icon ?? this.icon,
        segment: segment,
      );

  @override
  bool operator ==(Object other) =>
      other is SidebarSectionLink &&
      other.id == id &&
      other.name == name &&
      other.value == value &&
      other.icon == icon &&
      other.segment == segment;

  @override
  int get hashCode => Object.hash(id, name, value, icon, segment);
}

/// 服务端校验规则（Discourse SidebarSection / SidebarUrl 模型），字数按码点算。
abstract final class SidebarSectionLimits {
  static const titleMax = 30;
  static const nameMax = 80;
  static const valueMax = 1000;

  /// 站点设置 max_sidebar_section_links 的默认值（客户端读不到，按默认算）
  static const linksMax = 50;

  static int length(String text) => text.runes.length;
}
