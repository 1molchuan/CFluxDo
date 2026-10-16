import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/custom_font_service.dart';

void main() {
  group('CustomFontService.familyNameFor', () {
    test('由文件名推出 family，去掉扩展名', () {
      expect(
        CustomFontService.familyNameFor(
          r'C:\data\app\custom_fonts\custom_font_17.ttf',
        ),
        'FluxdoCustomFont_custom_font_17',
      );
      expect(
        CustomFontService.familyNameFor(
          '/data/app/custom_fonts/custom_font_42.otf',
        ),
        'FluxdoCustomFont_custom_font_42',
      );
    });

    test('只去掉最后一段扩展名，无扩展名时原样保留', () {
      expect(
        CustomFontService.familyNameFor('/tmp/My.Font.2.ttf'),
        'FluxdoCustomFont_My.Font.2',
      );
      expect(
        CustomFontService.familyNameFor('/tmp/NoExt'),
        'FluxdoCustomFont_NoExt',
      );
    });

    test('同一路径恒定（family 不额外持久化的前提）', () {
      const path = r'D:\fonts\custom_font_99.ttf';
      expect(
        CustomFontService.familyNameFor(path),
        CustomFontService.familyNameFor(path),
      );
    });
  });

  group('注册字体文件', () {
    test('注册后同一段文本按新字体排版（非内置字体的运行时加载路径）', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const fontPath = 'assets/fonts/MiSansVF.ttf';
      expect(File(fontPath).existsSync(), isTrue, reason: '测试依赖内置字体文件');

      expect(await CustomFontService.load(fontPath), isTrue);

      // 同一段文本：注册过的 family 与不存在的 family 应该量出不同宽度，
      // 否则说明 loadFontFromList 那条链路根本没生效。
      const text = 'Handgloves 混排 123';
      expect(
        _measureWidth(text, CustomFontService.familyNameFor(fontPath)),
        isNot(equals(_measureWidth(text, 'FluxdoNotRegistered'))),
      );
    });

    test('文件不存在时注册失败而不是抛异常', () async {
      expect(await CustomFontService.load('/no/such/font.ttf'), isFalse);
    });
  });
}

/// 用指定 family 排版一次并返回宽度。
double _measureWidth(String text, String family) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: 16),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
