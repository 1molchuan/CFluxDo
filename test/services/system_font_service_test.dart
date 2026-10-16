import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/fonts/system_font_service.dart';

void main() {
  group('parseAndroidFontConfig', () {
    test('取出 family 名、去重，通用族排最后', () {
      const xml = '''
<familyset version="23">
  <family name="sans-serif">
    <font weight="400" style="normal">Roboto-Regular.ttf</font>
  </family>
  <family lang="zh-Hans" name="Noto Sans CJK SC">
    <font weight="400" style="normal">NotoSansCJK-Regular.ttc</font>
  </family>
  <family name="Roboto">
    <font weight="700" style="normal">Roboto-Bold.ttf</font>
  </family>
  <family name="Roboto">
    <font weight="400" style="normal">Roboto-Regular.ttf</font>
  </family>
  <alias name="sans" to="sans-serif" />
</familyset>''';

      final fonts = SystemFontService.parseAndroidFontConfig(xml);
      expect(fonts.map((f) => f.family).toList(), [
        'Noto Sans CJK SC',
        'Roboto',
        'sans-serif',
      ]);
      // alias 不收：选别名不如直接选被指向的 family
      expect(fonts.any((f) => f.family == 'sans'), isFalse);
      expect(fonts.every((f) => f.localizedFamily == null), isTrue);
    });

    test('没有 family 时返回空列表', () {
      expect(
        SystemFontService.parseAndroidFontConfig('<familyset version="23"/>'),
        isEmpty,
      );
    });
  });

  group('展示名', () {
    test('中文界面优先本地化名，其它语言用引擎匹配名', () {
      const localized = SystemFont('Microsoft YaHei', '微软雅黑');
      expect(localized.label(localized: true), '微软雅黑');
      expect(localized.label(localized: false), 'Microsoft YaHei');

      const plain = SystemFont('Cascadia Code');
      expect(plain.label(localized: true), 'Cascadia Code');
    });
  });

  group('枚举系统字体', () {
    test('跨 isolate 返回去重后的 family（桌面平台非空）', () async {
      final fonts = await SystemFontService.list();

      expect(fonts.every((f) => f.family.trim().isNotEmpty), isTrue);
      final families = [for (final f in fonts) f.family.toLowerCase()];
      expect(families.toSet(), hasLength(families.length));

      // 桌面平台的字体目录一定存在字体；容器/CI 无字体的场景不做断言
      if (Platform.isWindows || Platform.isLinux) {
        expect(fonts, isNotEmpty);
      }
      SystemFontService.clearCache();
    });
  });
}
