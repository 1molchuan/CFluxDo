import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_background.dart';
import 'package:fluxdo/theme/claude_theme.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:shared_preferences/shared_preferences.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Claude 界面风格状态', () {
    test('切换到 Claude 风格会落盘 ui_style=claude', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'ui_style': 'mojian',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.mojian);
      expect(n.state.isClaude, isFalse);

      await n.setUiStyle(UiStyle.claude);
      expect(n.state.uiStyle, UiStyle.claude);
      expect(n.state.isClaude, isTrue);
      expect(n.state.isMojian, isFalse);
      expect(n.state.isClassic, isFalse);
      expect(prefs.getString('ui_style'), 'claude');
      expect(n.state.effectiveSeedColor, const Color(0xFFDA7756));
    });

    test('Claude 风格下透明背景不生效，经典下照旧', () {
      const bg = AppBackground(imagePath: '/tmp/bg.png');
      const base = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        transparentEnabled: true,
        background: bg,
        uiStyle: UiStyle.claude,
      );
      expect(base.isTransparentActive, isFalse);
      expect(
        base.copyWith(uiStyle: UiStyle.classic).isTransparentActive,
        isTrue,
      );
    });
  });

  group('Claude 配色与对比度', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}：文本与核心元素对比度达标', () {
        final s = ClaudeTheme.colorScheme(brightness);
        final t = ClaudeTokens.of(brightness);
        expect(s.brightness, brightness);

        for (final bg in [
          s.surface,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
        ]) {
          // 主要文本对比度 >= 7.0 (AAA)
          expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(7.0));
          // 次要文本对比度 >= 4.5 (AA)
          expect(_contrast(s.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5));
        }

        if (brightness == Brightness.dark) {
          // 暗色下陶土红在深色底上的对比度 >= 4.5
          expect(_contrast(s.primary, s.surface), greaterThanOrEqualTo(4.5));
          expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
        }

        expect(s.surfaceTint, Colors.transparent);
        expect(t.accent, s.primary);
      });
    }

    test('令牌插值两端取值正确', () {
      final a = ClaudeTokens.of(Brightness.light);
      final b = ClaudeTokens.of(Brightness.dark);
      expect(a.lerp(b, 0).background, a.background);
      expect(a.lerp(b, 1).background, b.background);
      expect(a.lerp(b, 0).accent, a.accent);
      expect(a.lerp(b, 1).accent, b.accent);
      expect(a.lerp(null, 0.5), same(a));
    });
  });

  group('Claude 字体沿用全局设置', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}：默认不指定字体时，所有文本样式不强制任何字体族', () {
        final scheme = ClaudeTheme.colorScheme(brightness);
        final theme = ClaudeTheme.build(
          scheme: scheme,
          fontFamily: null,
          pageTransitionsTheme: const PageTransitionsTheme(),
          iconTheme: const IconThemeData(),
          primaryIconTheme: const IconThemeData(),
        );

        expect(theme.colorScheme, scheme);
        expect(theme.scaffoldBackgroundColor, scheme.surface);
        // 标题与正文均不被强制指定特定字体族（例如宋体 MojianSerif）
        expect(
          theme.textTheme.titleLarge?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(
          theme.textTheme.headlineSmall?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(
          theme.textTheme.bodyMedium?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(theme.appBarTheme.titleTextStyle?.fontFamily, isNull);

        // 正文渲染配置中也不硬编码标题字体族
        final rs = theme.extension<FluxdoRenderStyle>();
        expect(rs, isNotNull);
        expect(rs?.headingFontFamily, isNull);
        expect(rs?.quoteBarColor, ClaudeTokens.of(brightness).accent);

        // 正文字体样式采用舒适的 1.6 行高与深暖色
        final postStyle = MojianTheme.postBodyStyle(theme, 1.0);
        expect(postStyle?.height, 1.6);
        expect(postStyle?.color, ClaudeTokens.of(brightness).textPrimary);
      });

      test('${brightness.name}：全局指定自定义字体时，标题与组件统一继承该字体', () {
        const customFont = 'MiSans';
        final scheme = ClaudeTheme.colorScheme(brightness);
        final theme = ClaudeTheme.build(
          scheme: scheme,
          fontFamily: customFont,
          pageTransitionsTheme: const PageTransitionsTheme(),
          iconTheme: const IconThemeData(),
          primaryIconTheme: const IconThemeData(),
        );

        expect(theme.textTheme.titleLarge?.fontFamily, customFont);
        expect(theme.textTheme.headlineSmall?.fontFamily, customFont);
        expect(theme.textTheme.bodyMedium?.fontFamily, customFont);
        expect(theme.appBarTheme.titleTextStyle?.fontFamily, customFont);
        expect(theme.dialogTheme.titleTextStyle?.fontFamily, customFont);
      });
    }
  });
}
