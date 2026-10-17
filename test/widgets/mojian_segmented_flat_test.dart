import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:m3e_ui/m3e_ui.dart';

ThemeData _mojian() => MojianTheme.build(
  scheme: MojianTheme.colorScheme(Brightness.light, MojianAccent.cinnabar),
  accent: MojianAccent.cinnabar,
  fontFamily: null,
  pageTransitionsTheme: const PageTransitionsTheme(),
  iconTheme: const IconThemeData(),
  primaryIconTheme: const IconThemeData(),
);

Future<void> _pumpGroup(WidgetTester tester, ThemeData theme) {
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const Scaffold(
        body: SegmentedCardGroup(
          children: [
            SizedBox(height: 40, child: Text('a')),
            SizedBox(height: 40, child: Text('b')),
            SizedBox(height: 40, child: Text('c')),
          ],
        ),
      ),
    ),
  );
}

ShapeBorder? _shapeOf(WidgetTester tester, String label) {
  final material = tester.widget<Material>(
    find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
  );
  return material.shape;
}

void main() {
  testWidgets('墨笺:分段卡片组平铺,首项上下细线、其余只有下细线、无块间缝', (tester) async {
    await _pumpGroup(tester, _mojian());
    final rule = _mojian().extension<MojianTokens>()!.rule;
    final first = _shapeOf(tester, 'a')! as Border;
    final second = _shapeOf(tester, 'b')! as Border;
    expect(first.top.color, rule);
    expect(first.bottom.color, rule);
    expect(second.top, BorderSide.none);
    expect(second.bottom.color, rule);
    // 三项紧贴:总高 = 3 × 40 + 细线
    final aBottom = tester.getBottomLeft(find.text('a')).dy;
    final bTop = tester.getTopLeft(find.text('b')).dy;
    expect(bTop - aBottom, lessThan(3));
  });

  testWidgets('经典:不注入样式时仍是 M3E 圆角分段卡片', (tester) async {
    await _pumpGroup(
      tester,
      ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
    );
    expect(_shapeOf(tester, 'a'), isA<RoundedRectangleBorder>());
  });
}
