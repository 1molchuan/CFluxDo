import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/radial_long_press_menu.dart';

const _screen = Size(411, 914);
const _padding = EdgeInsets.only(top: 24, bottom: 24);

/// 与 overlay 相同的布点：第 i 项在扇形窗口里等分，向上展开时 φ=0 在正上方
List<Offset> _itemCenters(RadialMenuPlacement p, int count) => [
  for (var i = 0; i < count; i++)
    () {
      final phi = count == 1
          ? (p.sweepStart + p.sweepEnd) / 2
          : p.sweepStart + i * (p.sweepEnd - p.sweepStart) / (count - 1);
      final dy = p.radius * math.cos(phi);
      return Offset(
        p.center.dx + p.radius * math.sin(phi),
        p.direction == RadialMenuDirection.up
            ? p.center.dy - dy
            : p.center.dy + dy,
      );
    }(),
];

void main() {
  test('锚点居中（经典进度悬浮条）仍是完整半圆、默认半径', () {
    final anchor = Rect.fromCenter(
      center: const Offset(205, 860),
      width: 120,
      height: 40,
    );
    final p = RadialMenuPlacement.fit(
      anchor: anchor,
      itemCount: 6,
      screenSize: _screen,
      safePadding: _padding,
    );
    expect(p.center, Offset(anchor.center.dx, anchor.top));
    expect(p.direction, RadialMenuDirection.up);
    expect(p.radius, RadialMenuSession.radiusForCount(6));
    expect(p.sweepStart, -math.pi / 2);
    expect(p.sweepEnd, math.pi / 2);
  });

  for (final count in [4, 6, 8]) {
    test('锚点贴右边缘（墨笺阅读条楼层数字）$count 项全部留在屏内', () {
      // 楼层数字约 66×40，右侧还有书签按钮
      final anchor = Rect.fromLTWH(_screen.width - 120, 850, 66, 40);
      final p = RadialMenuPlacement.fit(
        anchor: anchor,
        itemCount: count,
        screenSize: _screen,
        safePadding: _padding,
        maxTilt: math.pi / 2,
        allowShift: true,
      );
      if (count <= 6) {
        expect(p.center.dx, anchor.center.dx, reason: '排得下时圆心不挪，紧贴按压点');
      }
      expect(p.direction, RadialMenuDirection.up);
      final centers = _itemCenters(p, count);
      for (final c in centers) {
        expect(c.dx, inInclusiveRange(29, _screen.width - 29));
        expect(c.dy, lessThanOrEqualTo(anchor.top + 1e-6), reason: '不折到底栏里');
      }
      for (var i = 1; i < centers.length; i++) {
        expect(
          (centers[i] - centers[i - 1]).distance,
          greaterThanOrEqualTo(50),
          reason: '相邻两项不重叠',
        );
      }
    });
  }

  test('锚点贴近顶部时翻转向下展开', () {
    final anchor = Rect.fromLTWH(20, 40, 40, 40);
    final p = RadialMenuPlacement.fit(
      anchor: anchor,
      itemCount: 4,
      screenSize: _screen,
      safePadding: _padding,
    );
    expect(p.direction, RadialMenuDirection.down);
    expect(p.center.dy, anchor.bottom);
    for (final c in _itemCenters(p, 4)) {
      expect(c.dx, inInclusiveRange(29, _screen.width - 29));
    }
  });
}
