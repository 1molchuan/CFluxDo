import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/linux_webview_render_service.dart';
import '../services/render_backend_service.dart';

/// 是否曾检测到疑似 Mali/Vulkan 渲染崩溃。
///
/// 设置页据此在「Skia/OpenGL ES 渲染兼容模式」上常驻显示「建议开启」。
/// 与启动弹窗不同，这个标记不会被消费：用户点过「暂不开启」之后不再弹窗，
/// 但设置项上的建议保留，方便他之后想起来再开。
///
/// 非 Android 平台恒为 false。
final renderCrashDetectedProvider = FutureProvider<bool>((ref) async {
  return RenderBackendService.hasDetectedRenderCrash();
});

/// Linux：本次启动的内置网页（WPEWebProcess）渲染状态，设置页展示用；改设置后
/// invalidate 取「已保存」的新值。非 Linux 恒为 null。
final linuxWebViewRenderStateProvider =
    FutureProvider<LinuxWebViewRenderState?>((ref) async {
      return LinuxWebViewRenderService.getState();
    });
