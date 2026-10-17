import 'package:common_ui/common_ui.dart' show MenuQuickActionStyle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/layout/master_detail_layout.dart';
import 'package:fluxdo/widgets/share/share_image_preview.dart';

ThemeData _mojian() => MojianTheme.build(
  scheme: MojianTheme.colorScheme(Brightness.light, MojianAccent.cinnabar),
  accent: MojianAccent.cinnabar,
  fontFamily: null,
  pageTransitionsTheme: const PageTransitionsTheme(),
  iconTheme: const IconThemeData(),
  primaryIconTheme: const IconThemeData(),
);

void main() {
  group('分享图版式', () {
    test('墨笺追加在末尾,原有版式的序号不变(偏好里存的是序号)', () {
      expect(ShareImageTheme.classic.index, 0);
      expect(ShareImageTheme.green.index, 5);
      expect(ShareImageTheme.mojian.index, ShareImageTheme.values.length - 1);
    });

    test('没选过时:墨笺界面默认墨笺版式,经典界面仍是经典;选过就用选过的', () {
      expect(
        ShareImageTheme.initial(-1, mojianUi: true),
        ShareImageTheme.mojian,
      );
      expect(
        ShareImageTheme.initial(-1, mojianUi: false),
        ShareImageTheme.classic,
      );
      expect(ShareImageTheme.initial(2, mojianUi: true), ShareImageTheme.dark);
      expect(
        ShareImageTheme.initial(0, mojianUi: true),
        ShareImageTheme.classic,
      );
    });
  });

  test('墨笺主题注入菜单快捷按钮的细线样式', () {
    final style = _mojian().extension<MenuQuickActionStyle>();
    expect(style, isNotNull);
    expect(style!.fill, Colors.transparent);
    expect(style.border, isNotNull);
  });

  testWidgets('页面空态:经典返回 null(保持原样),墨笺给淡墨空态', (tester) async {
    Widget? classic;
    Widget? mojian;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            classic = mojianEmptyState(context, Icons.inbox, 'x');
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: _mojian(),
        // 换主题默认有 200ms 过渡,首帧还是旧主题
        themeAnimationDuration: Duration.zero,
        home: Builder(
          builder: (context) {
            mojian = mojianEmptyState(context, Icons.inbox, 'x');
            return const SizedBox();
          },
        ),
      ),
    );
    expect(classic, isNull);
    expect(mojian, isA<MasterDetailEmptyState>());
  });
}
