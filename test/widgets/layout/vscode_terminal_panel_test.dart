import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/layout/vscode_terminal_panel.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  Widget host({
    required Widget composer,
    GlobalKey<VscodeTerminalPanelState>? panelKey,
    double textScale = 1,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: VscodeTerminalPanel(
              key: panelKey,
              reader: const SizedBox.expand(
                key: ValueKey('reader'),
                child: Text('正文内容'),
              ),
              composer: composer,
              targetLabel: '一个很长的回复目标，用于验证窄窗口中的省略显示',
              onClose: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('真实输入在收起、展开和 reveal 后仍保留', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final panelKey = GlobalKey<VscodeTerminalPanelState>();
    await tester.pumpWidget(
      host(
        panelKey: panelKey,
        composer: const Material(child: TextField(maxLines: null)),
      ),
    );
    await tester.enterText(find.byType(TextField), '保留这段真实输入');
    await tester.tap(find.byTooltip('收起回复面板'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextField, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byTooltip('展开回复面板'));
    await tester.pump();
    expect(find.text('保留这段真实输入'), findsOneWidget);
    await tester.tap(find.byTooltip('收起回复面板'));
    await tester.pump();
    panelKey.currentState!.reveal();
    await tester.pump();
    expect(find.text('保留这段真实输入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖拽高度有界，最大化和还原保持几何，窄矮窗口不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    const composer = SizedBox.expand(
      key: ValueKey('composer'),
      child: ColoredBox(color: Colors.blue),
    );
    await tester.pumpWidget(host(composer: composer));
    final reader = find.byKey(const ValueKey('reader'));
    final editor = find.byKey(const ValueKey('composer'));
    final divider = find.byKey(const ValueKey('vscode-terminal-divider'));
    final panelRect = tester.getRect(find.byType(VscodeTerminalPanel));
    expect(tester.getSize(reader).height, greaterThan(panelRect.height * 0.1));
    expect(
      tester.getRect(editor).top,
      greaterThan(tester.getRect(reader).bottom),
    );
    expect(tester.getRect(editor).bottom, panelRect.bottom);

    await tester.drag(divider, const Offset(0, -2000));
    await tester.pump();
    expect(tester.getSize(reader).height, greaterThan(panelRect.height * 0.1));
    expect(
      tester.getRect(editor).top,
      greaterThan(tester.getRect(reader).bottom),
    );
    expect(tester.getRect(editor).bottom, panelRect.bottom);
    final restoredRect = tester.getRect(editor);
    await tester.tap(find.byTooltip('最大化回复面板'));
    await tester.pump();
    expect(find.text('正文内容'), findsNothing);
    expect(find.text('正文内容', skipOffstage: false), findsOneWidget);
    expect(tester.getRect(editor).top, greaterThan(panelRect.top));
    expect(tester.getRect(editor).top, lessThan(restoredRect.top));
    expect(tester.getRect(editor).height, greaterThan(restoredRect.height));
    expect(tester.getRect(editor).bottom, panelRect.bottom);
    await tester.tap(find.byTooltip('还原回复面板'));
    await tester.pump();
    expect(tester.getRect(editor), restoredRect);

    await tester.drag(divider, const Offset(0, 2000));
    await tester.pump();
    expect(tester.getSize(editor).height, greaterThan(panelRect.height * 0.1));
    expect(tester.getRect(editor).bottom, panelRect.bottom);
    expect(tester.getRect(reader).bottom, tester.getRect(divider).top);

    tester.view.physicalSize = const Size(90, 80);
    await tester.pumpWidget(host(composer: composer, textScale: 3));
    final narrowPanelRect = tester.getRect(find.byType(VscodeTerminalPanel));
    expect(tester.getRect(editor).bottom, narrowPanelRect.bottom);
    expect(tester.takeException(), isNull);
  });
}
