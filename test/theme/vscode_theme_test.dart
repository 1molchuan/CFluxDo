import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in Brightness.values) {
    test('${brightness.name} 界面继承全局字体，代码字体回退保留全局字体', () {
      final theme = VscodeTheme.build(
        scheme: VscodeTheme.colorScheme(brightness),
        fontFamily: 'UserFont',
        pageTransitionsTheme: const PageTransitionsTheme(),
        iconTheme: const IconThemeData(),
        primaryIconTheme: const IconThemeData(),
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, 'UserFont');
      expect(theme.textTheme.titleLarge?.fontFamily, 'UserFont');
      expect(theme.appBarTheme.titleTextStyle?.fontFamily, 'UserFont');
      expect(theme.dialogTheme.titleTextStyle?.fontFamily, 'UserFont');
      expect(theme.tooltipTheme.textStyle?.fontFamily, 'UserFont');
      expect(theme.extension<VscodeTokens>()?.background,
          VscodeTokens.of(brightness).background);
      expect(VscodeTheme.codeFontFallback('UserFont'), contains('UserFont'));
    });
  }

  test('恢复和写入 VS Code 风格遵守同一平台限制，且不更改字体偏好', () async {
    SharedPreferences.setMockInitialValues({
      'ui_style': 'vscode',
      'font_family': 'miSans',
    });
    final prefs = await SharedPreferences.getInstance();
    final notifier = ThemeNotifier(prefs);
    addTearDown(notifier.dispose);
    final expected = ThemeState.supportsVscode ? UiStyle.vscode : UiStyle.mojian;
    expect(notifier.state.uiStyle, expected);
    expect(notifier.state.fontFamily, AppFontFamily.miSans);
    await notifier.setUiStyle(UiStyle.vscode);
    expect(notifier.state.uiStyle, expected);
    expect(prefs.getString('ui_style'), expected.name);
    expect(notifier.state.fontFamily, AppFontFamily.miSans);
    expect(prefs.getString('font_family'), 'miSans');
  });
}
