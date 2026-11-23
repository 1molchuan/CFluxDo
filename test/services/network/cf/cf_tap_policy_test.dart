import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_tap_policy.dart';

void main() {
  group('shouldAttempt', () {
    bool attempt({
      bool supported = true,
      bool interactiveSignaled = true,
      bool isBackground = false,
      bool someoneWaiting = false,
      bool done = false,
    }) => CfTapPolicy.shouldAttempt(
      supported: supported,
      interactiveSignaled: interactiveSignaled,
      isBackground: isBackground,
      someoneWaiting: someoneWaiting,
      done: done,
    );

    test('前台、要人工操作、未结束：点', () {
      expect(attempt(), isTrue);
    });

    test('后台有人在等结果：点', () {
      expect(attempt(isBackground: true, someoneWaiting: true), isTrue);
    });

    test('纯后台轮次（没人在等）：不替正在阅读的用户点', () {
      expect(attempt(isBackground: true, someoneWaiting: false), isFalse);
    });

    test('非 Android / 还在转圈 / 已结束：不点', () {
      expect(attempt(supported: false), isFalse);
      expect(attempt(interactiveSignaled: false), isFalse);
      expect(attempt(done: true), isFalse);
    });
  });

  test('点击额度：每回合 2 次、每文档 3 次', () {
    expect(
      CfTapPolicy.hasBudget(roundAttempts: 0, documentAttempts: 0),
      isTrue,
    );
    expect(
      CfTapPolicy.hasBudget(roundAttempts: 1, documentAttempts: 2),
      isTrue,
    );
    expect(
      CfTapPolicy.hasBudget(roundAttempts: 2, documentAttempts: 2),
      isFalse,
    );
    expect(
      CfTapPolicy.hasBudget(roundAttempts: 0, documentAttempts: 3),
      isFalse,
    );
  });

  group('checkboxOffset', () {
    test('标准 300x65 widget：点左侧勾选框，而不是正中间', () {
      final offset = CfTapPolicy.checkboxOffset(300, 65)!;
      expect(offset.dx, 32);
      expect(offset.dy, 32.5);
    });

    test('窄一点的标准 widget 按比例缩', () {
      final offset = CfTapPolicy.checkboxOffset(200, 65)!;
      expect(offset.dx, closeTo(24, 1e-9));
    });

    test('compact / 整页这类布局不确定的尺寸不点', () {
      expect(CfTapPolicy.checkboxOffset(150, 140), isNull);
      expect(CfTapPolicy.checkboxOffset(400, 400), isNull);
      expect(CfTapPolicy.checkboxOffset(120, 65), isNull);
    });
  });
}
