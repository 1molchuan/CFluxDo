import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台工具类 — 统一平台检测逻辑
class PlatformUtils {
  PlatformUtils._();

  @visibleForTesting
  static bool? debugDesktopOverride;

  /// 是否运行在桌面操作系统（macOS / Windows / Linux）
  static bool get isDesktop =>
      debugDesktopOverride ??
      (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux));

  /// 窗口是否有毛玻璃（acrylic）背景。上游在 macOS / Windows 上用 flutter_acrylic
  /// 让窗口底透出来，界面里相应地把背景设成透明；cfluxdo 已去掉该插件（775f1048），
  /// 透明背景会直接露出黑底，所以恒为 false
  static bool get hasWindowAcrylic => false;

  /// 是否运行在移动操作系统（Android / iOS）
  static bool get isMobile =>
      debugDesktopOverride == null
      ? (!kIsWeb && (Platform.isAndroid || Platform.isIOS))
      : !debugDesktopOverride!;
}
