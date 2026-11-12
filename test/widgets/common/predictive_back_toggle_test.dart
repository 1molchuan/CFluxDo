import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_overlay_handler.dart';

/// 设置里的「预测性返回手势」开关（#6）：关掉后手势不再驱动预览，
/// 松手照常返回——和三键导航的返回键同一条路径。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> send(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Map<String, Object?> gestureArgs(double progress) => {
    'touchOffset': <double>[10, 300],
    'progress': progress,
    'swipeEdge': 0,
  };

  Widget buildApp() {
    return MaterialApp(
      theme: ThemeData(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android:
                PredictiveBackCupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('page B')),
              ),
            ),
            child: const Text('page A'),
          ),
        ),
      ),
    );
  }

  double bOffsetX(WidgetTester tester) =>
      tester.getTopLeft(find.text('page B', skipOffstage: false)).dx;

  tearDown(() => PredictiveBackSettings.enabled = true);

  testWidgets('关掉后：拖动时页面不跟手，松手照常返回上一页', (tester) async {
    PredictiveBackSettings.enabled = false;
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.6));
    await tester.pump();
    // 没有预览：页面还在原位
    expect(bOffsetX(tester), 0.0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // 松手：没人认领的手势由框架按普通返回处理
    await send('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(bOffsetX(tester), greaterThan(0.0), reason: '走普通的返回动画');
    await tester.pumpAndSettle();
    expect(find.text('page B'), findsNothing);
    expect(find.text('page A'), findsOneWidget);
  });

  testWidgets('关掉后取消手势：页面不动、不返回', (tester) async {
    PredictiveBackSettings.enabled = false;
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    await send('startBackGesture', gestureArgs(0.0));
    await send('updateBackGestureProgress', gestureArgs(0.4));
    await send('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page B'), findsOneWidget);
    expect(bOffsetX(tester), 0.0);

    // 关了再开：下一次手势恢复跟手，说明关着的那次没有留下半截状态
    PredictiveBackSettings.enabled = true;
    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.5));
    await tester.pump();
    expect(bOffsetX(tester), greaterThan(0.0));
    await send('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(bOffsetX(tester), 0.0);
  });

  testWidgets('默认开着：拖动时页面跟手', (tester) async {
    expect(PredictiveBackSettings.enabled, isTrue);
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.5));
    await tester.pump();
    expect(bOffsetX(tester), greaterThan(0.0));
    await send('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page A'), findsOneWidget);
  });

  test('浮层的手势处理器：关掉后不认领', () {
    var started = 0;
    final handler = PredictiveBackOverlayHandler(
      isEnabled: () => true,
      onStart: () => started++,
      onUpdate: (_) {},
      onCancel: () {},
      onCommit: () {},
    );
    final event = PredictiveBackEvent.fromMap(const <String?, Object?>{
      'touchOffset': <double>[10, 300],
      'progress': 0.0,
      'swipeEdge': 0,
    });

    PredictiveBackSettings.enabled = false;
    expect(handler.handleStartBackGesture(event), isFalse);
    expect(started, 0);

    PredictiveBackSettings.enabled = true;
    expect(handler.handleStartBackGesture(event), isTrue);
    expect(started, 1);
    handler.handleCancelBackGesture();
  });
}
