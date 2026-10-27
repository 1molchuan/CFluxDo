part of 'discourse_service.dart';

/// 侧边栏自定义分区（与网页侧栏双向同步）
///
/// 写请求必须发 JSON：表单编码时 links 会被 Rails 解析成以数字为键的
/// 哈希，服务端直接 500。非管理员不带 `public` 字段（旧版本把字符串
/// "false" 当真，回 403）。
mixin _SidebarSectionsMixin on _DiscourseServiceBase {
  /// 全站公开分区 + 我自己的分区。[background]：已有本地缓存时的后台刷新
  Future<List<SidebarSection>> getSidebarSections({
    bool background = false,
  }) async {
    try {
      final response = await _dio.get(
        '/sidebar_sections.json',
        options: background ? Options(extra: const {'isSilent': true}) : null,
      );
      final list = (response.data as Map<String, dynamic>)['sidebar_sections'];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) SidebarSection.fromJson(item),
      ];
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  Future<SidebarSection> createSidebarSection({
    required String title,
    required List<SidebarSectionLink> links,
  }) async {
    try {
      final response = await _dio.post(
        '/sidebar_sections.json',
        data: {
          'title': title,
          'links': [for (final link in links) _linkPayload(link)],
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      return _sectionFrom(response.data);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 整体更新：[links] 是最终的完整列表（顺序即显示顺序）；[removedLinks]
  /// 是要删掉的旧链接（原样带上，标 `_destroy`）。
  Future<SidebarSection> updateSidebarSection(
    int id, {
    required String title,
    required List<SidebarSectionLink> links,
    Iterable<SidebarSectionLink> removedLinks = const [],
  }) async {
    try {
      final response = await _dio.put(
        '/sidebar_sections/$id.json',
        data: {
          'title': title,
          'links': [
            for (final link in links) _linkPayload(link),
            for (final removed in removedLinks)
              if (removed.id != null)
                {..._linkPayload(removed), '_destroy': '1'},
          ],
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      return _sectionFrom(response.data);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  Future<void> deleteSidebarSection(int id) async {
    try {
      await _dio.delete('/sidebar_sections/$id.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  static Map<String, dynamic> _linkPayload(SidebarSectionLink link) => {
    if (link.id != null) 'id': link.id,
    'name': link.name,
    'value': link.value,
    'icon': link.icon,
    'segment': link.segment,
  };

  static SidebarSection _sectionFrom(dynamic data) {
    final section = (data as Map<String, dynamic>)['sidebar_section'];
    return SidebarSection.fromJson(section as Map<String, dynamic>);
  }
}
