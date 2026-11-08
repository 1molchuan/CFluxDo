import '../utils/avatar_url.dart';
import '../utils/time_utils.dart';
import '../utils/url_helper.dart';

/// 应用广场的排序（与网页端 `/apps` 的四种一致）
enum MiniAppSort {
  /// 近 7 天去重使用量
  hot('hot'),

  /// 当前版本首次上线时间
  latest('latest'),

  /// 平均评分，同分时评分人数多的优先
  rating('rating'),

  /// 累计去重使用量
  used('used');

  const MiniAppSort(this.value);

  /// 接口里的取值
  final String value;

  static MiniAppSort? fromValue(String? value) {
    for (final sort in values) {
      if (sort.value == value) return sort;
    }
    return null;
  }
}

/// 微应用作者
class MiniAppAuthor {
  const MiniAppAuthor({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
  });

  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;

  factory MiniAppAuthor.fromJson(Map<String, dynamic> json) {
    return MiniAppAuthor(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
    );
  }

  String? getAvatarUrl({int size = 48}) {
    final template = avatarTemplate;
    if (template == null || template.isEmpty) return null;
    return UrlHelper.resolveUrlWithCdn(AvatarUrl.resolve(template, size: size));
  }
}

/// 应用广场里的一个微应用（`/mini-app-api/apps.json` 的一项，应用详情的 `app`
/// 也是这个形状，另多讨论主题等字段）
class MiniApp {
  const MiniApp({
    required this.appId,
    required this.name,
    this.description = '',
    this.iconUrl,
    this.version,
    this.publishedAt,
    this.ratingAverage,
    this.ratingCount = 0,
    this.usageCount = 0,
    this.recentUsageCount = 0,
    this.isFavorited = false,
    this.discussionTopicId,
    this.author,
  });

  final String appId;
  final String name;
  final String description;
  final String? iconUrl;
  final String? version;
  final DateTime? publishedAt;

  /// 没人评过分时为空
  final double? ratingAverage;
  final int ratingCount;

  /// 累计去重使用量
  final int usageCount;

  /// 近 7 天去重使用量
  final int recentUsageCount;
  final bool isFavorited;

  /// 讨论主题（只有应用详情里有）
  final int? discussionTopicId;
  final MiniAppAuthor? author;

  factory MiniApp.fromJson(Map<String, dynamic> json) {
    final author = json['author'];
    final icon = json['icon_url'] as String?;
    final ratingCount = (json['rating_count'] as num?)?.toInt() ?? 0;
    return MiniApp(
      appId: json['app_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: (json['description'] as String? ?? '').trim(),
      iconUrl: icon == null || icon.isEmpty
          ? null
          : UrlHelper.resolveUrlWithCdn(icon),
      version: json['version'] as String?,
      publishedAt: TimeUtils.parseUtcTime(json['published_at'] as String?),
      ratingAverage: ratingCount > 0
          ? (json['rating_average'] as num?)?.toDouble()
          : null,
      ratingCount: ratingCount,
      usageCount: (json['usage_count'] as num?)?.toInt() ?? 0,
      recentUsageCount: (json['recent_usage_count'] as num?)?.toInt() ?? 0,
      isFavorited: json['is_favorited'] == true,
      discussionTopicId: (json['discussion_topic_id'] as num?)?.toInt(),
      author: author is Map<String, dynamic>
          ? MiniAppAuthor.fromJson(author)
          : null,
    );
  }
}

/// 应用广场的一页
class MiniAppDirectory {
  const MiniAppDirectory({
    required this.apps,
    required this.page,
    required this.total,
    required this.perPage,
    this.sort,
    this.query = '',
    this.favorite = false,
  });

  final List<MiniApp> apps;

  /// 从 0 开始
  final int page;
  final int total;
  final int perPage;

  /// 服务端实际用的排序（没指定时是站点默认）
  final MiniAppSort? sort;
  final String query;
  final bool favorite;

  bool get hasMore => (page + 1) * perPage < total;

  factory MiniAppDirectory.fromJson(Map<String, dynamic> json) {
    final list = json['apps'];
    return MiniAppDirectory(
      apps: [
        if (list is List)
          for (final item in list)
            if (item is Map<String, dynamic>) MiniApp.fromJson(item),
      ],
      page: (json['page'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      perPage: (json['per_page'] as num?)?.toInt() ?? 40,
      sort: MiniAppSort.fromValue(json['sort'] as String?),
      query: json['query'] as String? ?? '',
      favorite: json['favorite'] == true,
    );
  }
}
