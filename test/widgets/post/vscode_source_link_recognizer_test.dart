import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_source_link_recognizer.dart';

const _sourceKey = ValueKey('source-link');

Future<void> _showSource(
  WidgetTester tester,
  VoidCallback onOpen,
) async {
  final recognizer = VscodeSourceLinkRecognizer(onOpen: onOpen);
  addTearDown(recognizer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SelectionArea(
            child: Text.rich(
              TextSpan(text: '[链接](https://example.com)', recognizer: recognizer),
              key: _sourceKey,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('普通单击和拖选不会打开源码链接', (tester) async {
    var opened = 0;
    await _showSource(tester, () => opened++);
    final center = tester.getCenter(find.byKey(_sourceKey));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(center);
    await mouse.up();
    await tester.pump();
    expect(opened, 0);

    await mouse.down(center - const Offset(40, 0));
    await mouse.moveTo(center + const Offset(40, 0));
    await mouse.up();
    await tester.pump();
    expect(opened, 0);
  });

  for (final control in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
  ]) {
    testWidgets('按住 ${control.keyLabel} 单击打开一次，拖动不打开', (tester) async {
      var opened = 0;
      await _showSource(tester, () => opened++);
      final center = tester.getCenter(find.byKey(_sourceKey));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(control);
      await mouse.down(center);
      await mouse.up();
      await tester.pump();
      expect(opened, 1);

      await mouse.down(center - const Offset(40, 0));
      await mouse.moveTo(center + const Offset(40, 0));
      await mouse.up();
      await tester.pump();
      expect(opened, 1);
      await tester.sendKeyUpEvent(control);
    });
  }

  testWidgets('点击开始后才按 Ctrl 或松开前释放 Ctrl 均不打开', (tester) async {
    var opened = 0;
    await _showSource(tester, () => opened++);
    final center = tester.getCenter(find.byKey(_sourceKey));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(center);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await mouse.up();
    await tester.pump();
    expect(opened, 0);

    await mouse.down(center);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await mouse.up();
    await tester.pump();
    expect(opened, 0);
  });

  testWidgets('Ctrl 不把触摸或鼠标副键变成链接激活', (tester) async {
    var opened = 0;
    await _showSource(tester, () => opened++);
    final center = tester.getCenter(find.byKey(_sourceKey));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(center);
    await touch.up();
    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.down(center);
    await secondary.up();
    await tester.pump();
    expect(opened, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });
}
