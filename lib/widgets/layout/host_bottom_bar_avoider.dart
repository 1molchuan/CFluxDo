import 'package:flutter/widgets.dart';

/// 让嵌在底栏宿主里的页面自己的悬浮按钮避开底栏。
///
/// 手机布局下聊天、私信等页面会作为底栏 tab 嵌进 [AdaptiveScaffold] 的 body，
/// 外层 Scaffold 开着 extendBody，只把底栏高度注进 body 的
/// `MediaQuery.padding.bottom`；Flutter 的 FAB 定位却只认 `viewPadding`（系统
/// 安全区）。于是内层 Scaffold 的 FAB 只抬了手势条那一点，压在悬浮胶囊底栏
/// 上（2026-11 佬友反馈聊天页「神秘的开新对话按钮」）。
///
/// 这里补上两者之差。**[lift] 必须用 [liftOf] 在页面自己的 context（内层
/// Scaffold 外面）算**：Scaffold 给 FAB 槽位去掉了全部 padding，在槽位里算
/// 永远是 0。页面作为独立路由打开、或者键盘弹起时差值不为正，原样返回。
class HostBottomBarAvoider extends StatelessWidget {
  const HostBottomBarAvoider({
    super.key,
    required this.lift,
    required this.child,
  });

  /// 要额外抬高的量，见 [liftOf]
  final double lift;
  final Widget child;

  /// 宿主底栏比系统安全区多占的高度
  static double liftOf(BuildContext pageContext) {
    final lift =
        MediaQuery.paddingOf(pageContext).bottom -
        MediaQuery.viewPaddingOf(pageContext).bottom;
    return lift > 0 ? lift : 0;
  }

  @override
  Widget build(BuildContext context) {
    if (lift <= 0) return child;
    return Padding(
      padding: EdgeInsets.only(bottom: lift),
      child: child,
    );
  }
}
