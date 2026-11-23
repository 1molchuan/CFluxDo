import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_tap_policy.dart';

void main() {
  test('只有「要人工操作 + 本页没点过 + 未结束」才注入', () {
    expect(
      CfTapPolicy.shouldAttempt(
        supported: true,
        interactiveSignaled: true,
        alreadyAttempted: false,
        done: false,
      ),
      isTrue,
    );
    expect(
      CfTapPolicy.shouldAttempt(
        supported: false,
        interactiveSignaled: true,
        alreadyAttempted: false,
        done: false,
      ),
      isFalse,
      reason: '非 Android 没有原生实现，不点',
    );
    expect(
      CfTapPolicy.shouldAttempt(
        supported: true,
        interactiveSignaled: false,
        alreadyAttempted: false,
        done: false,
      ),
      isFalse,
      reason: 'Turnstile 还在转圈，没要求人工操作',
    );
    expect(
      CfTapPolicy.shouldAttempt(
        supported: true,
        interactiveSignaled: true,
        alreadyAttempted: true,
        done: false,
      ),
      isFalse,
      reason: '同一文档只注入一次',
    );
    expect(
      CfTapPolicy.shouldAttempt(
        supported: true,
        interactiveSignaled: true,
        alreadyAttempted: false,
        done: true,
      ),
      isFalse,
    );
  });

  test('标准 300x65 widget：点左侧勾选框，而不是正中间', () {
    final offset = CfTapPolicy.checkboxOffset(300, 65);
    expect(offset.dx, 32);
    expect(offset.dy, 32.5);
  });

  test('小尺寸和整页挑战退到中心', () {
    final compact = CfTapPolicy.checkboxOffset(120, 65);
    expect(compact.dx, 60);
    expect(compact.dy, 32.5);

    final fullPage = CfTapPolicy.checkboxOffset(400, 400);
    expect(fullPage.dx, 200);
    expect(fullPage.dy, 200);
  });

  test('widget 矩形换算成视口归一化坐标', () {
    final point = CfTapPolicy.normalize(
      left: 100,
      top: 200,
      width: 300,
      height: 65,
      viewportWidth: 400,
      viewportHeight: 800,
    );
    expect(point.nx, closeTo(132 / 400, 1e-9));
    expect(point.ny, closeTo(232.5 / 800, 1e-9));
  });

  test('矩形跑到视口外时夹在 1%..99%', () {
    final point = CfTapPolicy.normalize(
      left: -500,
      top: 5000,
      width: 300,
      height: 65,
      viewportWidth: 400,
      viewportHeight: 800,
    );
    expect(point.nx, 0.01);
    expect(point.ny, 0.99);
  });
}
