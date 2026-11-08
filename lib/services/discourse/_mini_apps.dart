part of 'discourse_service.dart';

/// 微应用（discourse-mini-app 插件，linux.do 的 `/apps` 应用广场）
mixin _MiniAppsMixin on _DiscourseServiceBase {
  /// 应用广场的一页。[sort] 为空时用站点默认排序；[favorite] 只看自己收藏的
  Future<MiniAppDirectory> getMiniAppDirectory({
    MiniAppSort? sort,
    String query = '',
    int page = 0,
    bool favorite = false,
  }) async {
    try {
      final response = await _dio.get(
        '/mini-app-api/apps.json',
        queryParameters: {
          'sort': ?sort?.value,
          if (query.isNotEmpty) 'q': query,
          'page': page,
          if (favorite) 'favorite': true,
        },
      );
      return MiniAppDirectory.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 应用详情（名称、图标、讨论主题等）。未登录走公开通道，与网页端一致
  Future<MiniApp> getMiniApp(String appId) async {
    final channel = isAuthenticated ? 'production' : 'public';
    try {
      final response = await _dio.get(
        '/mini-app-api/$channel/${Uri.encodeComponent(appId)}/info',
      );
      final app = (response.data as Map<String, dynamic>)['app'];
      if (app is! Map<String, dynamic>) {
        throw Exception(S.current.miniApp_unavailable);
      }
      return MiniApp.fromJson(app);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}
