import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// 文字链接只接受 Ctrl 主键；图片接受普通主键及触摸，拖动均取消点击。
class VscodeSourceLinkRecognizer extends TapGestureRecognizer {
  VscodeSourceLinkRecognizer({
    required VoidCallback onOpen,
    this.requireControl = true,
  }) {
    onTap = () {
      if (!requireControl || HardwareKeyboard.instance.isControlPressed) {
        onOpen();
      }
    };
  }

  final bool requireControl;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      event.buttons == kPrimaryMouseButton &&
      (!requireControl ||
          (event.kind == PointerDeviceKind.mouse &&
              HardwareKeyboard.instance.isControlPressed)) &&
      super.isPointerAllowed(event);
}
