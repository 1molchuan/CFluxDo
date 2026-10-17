import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_background.dart';
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

  group('界面风格设置', () {
    test('新装：默认墨笺 + 朱砂，并把风格落盘，不提示', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.mojian);
      expect(n.state.mojianAccent, MojianAccent.cinnabar);
      expect(prefs.getString('ui_style'), 'mojian');
      expect(n.consumeMojianIntro(), isFalse);
    });

    test('老用户升级：默认墨笺，提示一次', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'theme_mode': 'dark',
        'palette_id': 'ocean',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.isMojian, isTrue);
      expect(n.state.mode, ThemeMode.dark);
      expect(n.consumeMojianIntro(), isTrue);
      expect(n.consumeMojianIntro(), isFalse);
      // 下一次启动不再提示
      expect(ThemeNotifier(prefs).consumeMojianIntro(), isFalse);
    });

    test('选过经典的保持经典、不提示；切换风格与强调色会落盘', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'ui_style': 'classic',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.classic);
      expect(n.consumeMojianIntro(), isFalse);
      await n.setUiStyle(UiStyle.mojian);
      await n.setMojianAccent(MojianAccent.pine);
      expect(prefs.getString('ui_style'), 'mojian');
      expect(prefs.getString('mojian_accent'), 'pine');
    });

    test('墨笺下透明背景不生效，经典下照旧', () {
      const bg = AppBackground(imagePath: '/tmp/bg.png');
      const base = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        transparentEnabled: true,
        background: bg,
      );
      expect(base.isTransparentActive, isFalse);
      expect(
        base.copyWith(uiStyle: UiStyle.classic).isTransparentActive,
        isTrue,
      );
    });
  });

  group('墨笺配色', () {
    for (final accent in MojianAccent.values) {
      for (final brightness in Brightness.values) {
        test('${accent.name} · ${brightness.name}：文字对比度达标', () {
          final s = MojianTheme.colorScheme(brightness, accent);
          expect(s.brightness, brightness);
          for (final bg in [
            s.surface,
            s.surfaceContainerLow,
            s.surfaceContainer,
            s.surfaceContainerHigh,
          ]) {
            expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(7));
            expect(
              _contrast(s.onSurfaceVariant, bg),
              greaterThanOrEqualTo(4.5),
            );
            // 链接、选中文字直接用 primary
            expect(_contrast(s.primary, bg), greaterThanOrEqualTo(4.5));
          }
          expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
          expect(
            _contrast(s.onPrimaryContainer, s.primaryContainer),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(s.onInverseSurface, s.inverseSurface),
            greaterThanOrEqualTo(7),
          );
          // 输入框、描边按钮的边框需要 3:1
          expect(_contrast(s.outline, s.surface), greaterThanOrEqualTo(3));
          expect(s.surfaceTint, Colors.transparent);
        });

        test('${accent.name} · ${brightness.name}：ThemeData 能装配，标题用宋体', () {
          final scheme = MojianTheme.colorScheme(brightness, accent);
          final theme = MojianTheme.build(
            scheme: scheme,
            accent: accent,
            fontFamily: null,
            pageTransitionsTheme: const PageTransitionsTheme(),
            iconTheme: const IconThemeData(),
            primaryIconTheme: const IconThemeData(),
          );
          expect(theme.colorScheme, scheme);
          expect(theme.scaffoldBackgroundColor, scheme.surface);
          expect(
            theme.textTheme.titleLarge?.fontFamily,
            MojianTokens.serifFamily,
          );
          expect(
            theme.textTheme.headlineSmall?.fontFamily,
            MojianTokens.serifFamily,
          );
          // 正文仍用正文字体
          expect(
            theme.textTheme.bodyMedium?.fontFamily,
            isNot(MojianTokens.serifFamily),
          );
          expect(
            theme.appBarTheme.titleTextStyle?.fontFamily,
            MojianTokens.serifFamily,
          );
          final tokens = theme.extension<MojianTokens>();
          expect(tokens, isNotNull);
          expect(tokens!.accent, accent.of(brightness));
          // 正文引用块/小标题的覆盖样式随墨笺一起注入
          final rs = theme.extension<FluxdoRenderStyle>();
          expect(rs?.quoteBarWidth, 2);
          expect(rs?.quoteBackground, Colors.transparent);
          expect(rs?.headingFontFamily, MojianTokens.serifFamily);
        });
      }
    }

    test('令牌插值两端取值正确', () {
      final a = MojianTokens.of(Brightness.light, MojianAccent.cinnabar);
      final b = MojianTokens.of(Brightness.dark, MojianAccent.indigo);
      expect(a.lerp(b, 0).paper, a.paper);
      expect(a.lerp(b, 1).accent, b.accent);
      expect(a.lerp(null, 0.5), same(a));
    });
  });
}
