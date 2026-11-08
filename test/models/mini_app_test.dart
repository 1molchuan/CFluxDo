import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/mini_app.dart';

void main() {
  group('应用广场接口解析', () {
    // 2026-11-08 /mini-app-api/apps.json?sort=hot 的真实返回（截取两项）
    final json = <String, dynamic>{
      'apps': [
        {
          'app_id': '01a19ba5-b9d2-766f-9fb9-b7eddc10e0c7',
          'name': '🐟🧧',
          'description': '使用红包站的“社区小程序”分享文案，在社区里发红包。\n',
          'icon_url': 'https://cdn3.ldstatic.com/original/4X/5/4/6/5462c4b45b295c4e6f438df50bc7ff032ec1d3bf.svg',
          'version': '0.2.4',
          'published_at': '2026-11-08T08:08:23.514Z',
          'rating_average': 5.0,
          'rating_count': 8,
          'usage_count': 5577,
          'recent_usage_count': 5577,
          'tip_status': 'available',
          'is_favorited': false,
          'author': {
            'id': 332940,
            'username': 'lafish',
            'name': '',
            'avatar_template':
                '/user_avatar/linux.do/lafish/{size}/1677972_2.png',
            'animated_avatar': null,
          },
        },
        {
          'app_id': '01a1a081-677f-760e-9af7-ad8822216771',
          'name': '东北雨姐galgame',
          'description': '',
          'icon_url': null,
          'version': '1.0.0',
          'published_at': '2026-11-01T00:00:00.000Z',
          'rating_average': 0.0,
          'rating_count': 0,
          'usage_count': 12,
          'recent_usage_count': 3,
          'tip_status': 'given',
          'is_favorited': true,
          'author': null,
        },
      ],
      'page': 0,
      'total': 74,
      'per_page': 40,
      'sort': 'hot',
      'query': '',
      'favorite': false,
    };

    test('解析一页应用与分页信息', () {
      final directory = MiniAppDirectory.fromJson(json);
      expect(directory.apps, hasLength(2));
      expect(directory.total, 74);
      expect(directory.perPage, 40);
      expect(directory.sort, MiniAppSort.hot);
      expect(directory.hasMore, isTrue);

      final first = directory.apps.first;
      expect(first.appId, '01a19ba5-b9d2-766f-9fb9-b7eddc10e0c7');
      expect(first.description, '使用红包站的“社区小程序”分享文案，在社区里发红包。');
      expect(first.iconUrl, endsWith('.svg'));
      expect(first.ratingAverage, 5.0);
      expect(first.ratingCount, 8);
      expect(first.usageCount, 5577);
      expect(first.publishedAt, isNotNull);
      expect(first.author?.username, 'lafish');
      expect(first.author?.getAvatarUrl(size: 48), contains('/lafish/48/'));
    });

    test('没人评分时不给平均分，缺图标和作者也能解析', () {
      final app = MiniAppDirectory.fromJson(json).apps.last;
      expect(app.ratingAverage, isNull);
      expect(app.iconUrl, isNull);
      expect(app.author, isNull);
      expect(app.isFavorited, isTrue);
    });

    test('最后一页没有更多', () {
      final directory = MiniAppDirectory.fromJson({
        ...json,
        'page': 1,
        'apps': const [],
      });
      expect(directory.hasMore, isFalse);
    });

    test('未知排序值当作站点默认', () {
      expect(MiniAppSort.fromValue('hot'), MiniAppSort.hot);
      expect(MiniAppSort.fromValue('trending'), isNull);
      expect(MiniAppSort.fromValue(null), isNull);
    });
  });
}
