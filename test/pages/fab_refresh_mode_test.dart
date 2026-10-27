import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topics_page.dart' show fabRefreshModeFromScroll;

/// 首页 FAB 创作/刷新模式只认用户拖拽方向：往回（向上）滑进入刷新，
/// 向下滑或到顶退出；横向、惯性与回弹通知不改变模式。
void main() {
  FixedScrollMetrics metrics({
    double pixels = 500,
    Axis axis = Axis.vertical,
  }) => FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 2000,
    pixels: pixels,
    viewportDimension: 800,
    axisDirection: axis == Axis.vertical
        ? AxisDirection.down
        : AxisDirection.right,
    devicePixelRatio: 1,
  );

  testWidgets('拖拽方向决定模式，顶部与横向不触发', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));

    UserScrollNotification user(
      ScrollDirection direction, {
      double pixels = 500,
      Axis axis = Axis.vertical,
    }) => UserScrollNotification(
      metrics: metrics(pixels: pixels, axis: axis),
      context: context,
      direction: direction,
    );

    // 深处往回滑 → 刷新；往下滑 → 创作
    expect(fabRefreshModeFromScroll(user(ScrollDirection.forward)), isTrue);
    expect(fabRefreshModeFromScroll(user(ScrollDirection.reverse)), isFalse);
    // IndexedStack 里的非活跃页面不得改写首页的全局 FAB 模式。
    for (final direction in ScrollDirection.values) {
      expect(
        fabRefreshModeFromScroll(user(direction), isActive: false),
        isNull,
      );
    }
    expect(
      fabRefreshModeFromScroll(
        ScrollUpdateNotification(metrics: metrics(pixels: 0), context: context),
        isActive: false,
      ),
      isNull,
    );
    // 松手 idle 不改变
    expect(fabRefreshModeFromScroll(user(ScrollDirection.idle)), isNull);
    // 已在顶部往回拉（下拉刷新区）不进入刷新模式
    expect(
      fabRefreshModeFromScroll(user(ScrollDirection.forward, pixels: 0)),
      isFalse,
    );
    // 首页列表贴顶时停在折叠锚位（头部可折叠段高度）而不是 0：
    // 锚位以内都算顶部，松手（idle）落在带内也退出刷新模式
    expect(
      fabRefreshModeFromScroll(
        user(ScrollDirection.forward, pixels: 48),
        topExtent: 124,
      ),
      isFalse,
    );
    expect(
      fabRefreshModeFromScroll(
        user(ScrollDirection.idle, pixels: 100),
        topExtent: 124,
      ),
      isFalse,
    );
    expect(
      fabRefreshModeFromScroll(
        user(ScrollDirection.forward, pixels: 125),
        topExtent: 124,
      ),
      isTrue,
    );
    expect(
      fabRefreshModeFromScroll(
        ScrollUpdateNotification(metrics: metrics(pixels: 60), context: context),
        topExtent: 124,
      ),
      isFalse,
    );
    // 横向（TabBarView）不参与
    expect(
      fabRefreshModeFromScroll(
        user(ScrollDirection.forward, axis: Axis.horizontal),
      ),
      isNull,
    );

    // 惯性滚动中的位置更新：深处不改变，回到顶部退出刷新模式
    expect(
      fabRefreshModeFromScroll(
        ScrollUpdateNotification(metrics: metrics(), context: context),
      ),
      isNull,
    );
    expect(
      fabRefreshModeFromScroll(
        ScrollUpdateNotification(metrics: metrics(pixels: 0), context: context),
      ),
      isFalse,
    );
    expect(
      fabRefreshModeFromScroll(
        ScrollUpdateNotification(metrics: metrics(pixels: -40), context: context),
      ),
      isFalse,
    );
    // 开始/结束通知不改变
    expect(
      fabRefreshModeFromScroll(
        ScrollStartNotification(metrics: metrics(), context: context),
      ),
      isNull,
    );
    expect(
      fabRefreshModeFromScroll(
        ScrollEndNotification(metrics: metrics(), context: context),
      ),
      isNull,
    );
  });
}
