import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/hashtag_suggestion.dart';

void main() {
  String? query(String before) => hashtagQueryPattern.firstMatch(before)?.group(1);

  test('光标前的 #查询：行首或空白之后才算', () {
    expect(query('#'), '');
    expect(query('看这里 #dev'), 'dev');
    expect(query('第一行\n#开发'), '开发');
    expect(query('#ai::tag'), 'ai::tag');
    expect(query('a#b'), isNull);
    expect(query('&#123'), isNull);
    expect(query('#dev '), isNull);
    expect(query('颜色 #fff 和 #'), '');
  });

  test('解析搜索结果，缺 ref 或 text 的项丢掉', () {
    final category = HashtagSuggestion.fromJson({
      'relative_url': '/c/develop/4',
      'text': '开发调优',
      'description': 'desc',
      'icon': 'code',
      'colors': ['25AAE2'],
      'type': 'category',
      'ref': 'develop',
      'slug': 'develop',
      'id': 4,
      'style_type': 'icon',
    })!;
    expect(category.isCategory, isTrue);
    expect(category.insertText, '#develop');
    expect(category.colors, ['25AAE2']);
    expect(category.relativeUrl, '/c/develop/4');

    final tag = HashtagSuggestion.fromJson({
      'relative_url': '/tag/ai',
      'text': 'ai',
      'type': 'tag',
      'ref': 'ai::tag',
      'icon': 'tag',
    })!;
    expect(tag.isTag, isTrue);
    expect(tag.insertText, '#ai::tag');

    expect(HashtagSuggestion.fromJson({'text': 'x', 'type': 'tag'}), isNull);
    expect(HashtagSuggestion.fromJson({'ref': 'x', 'type': 'tag'}), isNull);
  });
}
