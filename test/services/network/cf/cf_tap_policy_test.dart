import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_tap_policy.dart';

void main() {
  group('shouldAttempt', () {
    bool attempt({
      bool supported = true,
      bool interactiveSignaled = true,
      bool done = false,
    }) => CfTapPolicy.shouldAttempt(
      supported: supported,
      interactiveSignaled: interactiveSignaled,
      done: done,
    );

    test('要人工操作、未结束：点（前后台都点，后台 WebView 在屏幕外，用户无感）', () {
      expect(attempt(), isTrue);
    });

    test('非 Android / 还在转圈 / 已结束：不点', () {
      expect(attempt(supported: false), isFalse);
      expect(attempt(interactiveSignaled: false), isFalse);
      expect(attempt(done: true), isFalse);
    });
  });

  group('holdsPromotion', () {
    final now = DateTime(2026, 11, 23, 12);

    test('点击进行中：压住弹前台 / 超时', () {
      expect(
        CfTapPolicy.holdsPromotion(
          tapRunning: true,
          effectiveAt: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('点中后等 clearance 的窗口内压住，过了就放开', () {
      expect(
        CfTapPolicy.holdsPromotion(
          tapRunning: false,
          effectiveAt: now.subtract(const Duration(seconds: 3)),
          now: now,
        ),
        isTrue,
      );
      expect(
        CfTapPolicy.holdsPromotion(
          tapRunning: false,
          effectiveAt: now.subtract(CfTapPolicy.clearanceWait),
          now: now,
        ),
        isFalse,
      );
    });

    test('没在点也没点中：不压', () {
      expect(
        CfTapPolicy.holdsPromotion(
          tapRunning: false,
          effectiveAt: null,
          now: now,
        ),
        isFalse,
      );
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
