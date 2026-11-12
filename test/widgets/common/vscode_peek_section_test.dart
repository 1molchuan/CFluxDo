import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/widgets/common/vscode_peek_section.dart';

void main() {
  testWidgets('辅助内容默认收起，键盘展开后保留折叠前的未提交输入', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
        home: Scaffold(
          body: VscodePeekSection(
            label: '附属内容',
            builder: (_) => const TextField(
              decoration: InputDecoration(labelText: '未提交内容'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('未提交内容'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '尚未发送的正文');
    await tester.tap(find.text('附属内容'));
    await tester.pump();
    expect(find.text('尚未发送的正文'), findsNothing);
    await tester.tap(find.text('附属内容'));
    await tester.pump();
    expect(find.text('尚未发送的正文'), findsOneWidget);
  });
}
