import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/common/app_glass_settings.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester, {required bool mojian}) async {
  SharedPreferences.setMockInitialValues({
    'pref_glass_enabled': true,
    'pref_glass_effect_level': 'basic',
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: ThemeData(
          extensions: [
            if (mojian) MojianTokens.of(Brightness.light, MojianAccent.cinnabar),
          ],
        ),
        builder: (_, child) => AppGlassSettings(child: child!),
        home: const Scaffold(
          body: Column(
            children: [
              GlassSurfaceFrame(
                radius: 20,
                recipe: GlassRecipe.menu,
                child: SizedBox(width: 200, height: 60),
              ),
              SizedBox(
                width: 300,
                child: ComposerIsland(child: SizedBox(height: 80)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('经典风格按偏好走玻璃', (tester) async {
    await _pump(tester, mojian: false);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('墨笺一律纸色实底 + 细线，不模糊背景、不投影', (tester) async {
    await _pump(tester, mojian: true);
    final mj = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).extension<MojianTokens>()!;
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(GlassSurface), findsNWidgets(2));

    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(GlassSurface),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<ShapeDecoration>()
        .toList();
    expect(
      decorations.where((d) => d.color == mj.paper),
      hasLength(2),
      reason: '两处表面都用纸色填充',
    );
    final borders = decorations
        .map((d) => d.shape)
        .whereType<RoundedRectangleBorder>()
        .where((s) => s.side.style != BorderStyle.none)
        .toList();
    expect(borders, isNotEmpty);
    for (final shape in borders) {
      expect(shape.side.color, mj.ruleStrong);
      expect(shape.side.width, 0.5);
    }
    expect(
      decorations.where((d) => d.shadows?.isNotEmpty ?? false),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
