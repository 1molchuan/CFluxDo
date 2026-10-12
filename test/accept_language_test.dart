import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';

void main() {
  group('Accept-Language 按系统语言生成（对齐 Chromium）', () {
    test('单个带地区的语言：补基础语言', () {
      expect(
        AppConstants.buildAcceptLanguage(const [Locale('zh', 'CN')]),
        'zh-CN,zh;q=0.9',
      );
    });

    test('多语言：同语系只在最后补一次基础语言，q 逐项递减', () {
      expect(
        AppConstants.buildAcceptLanguage(const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('en', 'US'),
        ]),
        'zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6',
      );
    });

    test('忽略 script 子标签，不带地区的语言不重复', () {
      expect(
        AppConstants.buildAcceptLanguage(const [
          Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
          Locale('en'),
        ]),
        'zh,en;q=0.9',
      );
    });

    test('q 值最低到 0.1', () {
      final locales = [
        for (final code in ['aa', 'bb', 'cc', 'dd', 'ee', 'ff', 'gg', 'hh', 'ii', 'jj', 'kk'])
          Locale(code),
      ];
      final header = AppConstants.buildAcceptLanguage(locales);
      expect(header, endsWith('jj;q=0.1,kk;q=0.1'));
      expect(header, startsWith('aa,bb;q=0.9,cc;q=0.8'));
    });

    test('拿不到系统语言时退回默认值', () {
      expect(
        AppConstants.buildAcceptLanguage(const []),
        'zh-CN,zh;q=0.9,en;q=0.8',
      );
    });
  });
}
