import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/discourse_url_parser.dart';

void main() {
  group('平行视界左栏链接解析', () {
    test('解析分类 ID', () {
      expect(DiscourseUrlParser.parseCategory('/c/develop/42')?.categoryId, 42);
      expect(DiscourseUrlParser.parseCategory('/c/42')?.categoryId, 42);
    });

    test('解析并解码标签', () {
      expect(DiscourseUrlParser.parseTag('/tag/flutter'), 'flutter');
      expect(DiscourseUrlParser.parseTag('/tag/%E4%B8%AD%E6%96%87'), '中文');
    });

    test('标签 href 是未编码的中文原文(客户端 cook 预览)也不抛', () {
      // 发帖器预览的 cook bundle 直接拼 `/tag/<原文>`,
      // Uri.decodeComponent 对非 ASCII 会抛 ArgumentError
      expect(DiscourseUrlParser.parseTag('/tag/开源推广'), '开源推广');
      expect(
        DiscourseUrlParser.parseTag('https://linux.do/tag/开源推广?u=x#top'),
        '开源推广',
      );
      // 编码与原文混排同样还原
      expect(DiscourseUrlParser.parseTag('/tag/%E5%BC%80%E6%BA%90推广'), '开源推广');
    });

    test('宽容解码:畸形百分号原样返回,正常编码照常解', () {
      expect(DiscourseUrlParser.decodeComponentLenient('a%20b'), 'a b');
      expect(DiscourseUrlParser.decodeComponentLenient('%zz'), '%zz');
      expect(DiscourseUrlParser.decodeComponentLenient('开源%zz'), '开源%zz');
      expect(DiscourseUrlParser.decodeComponentLenient(''), '');
    });

    test('只把真正的站点根路径识别为首页', () {
      expect(DiscourseUrlParser.isHomepage('/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('https://linux.do/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('/latest'), isFalse);
    });
  });
}
