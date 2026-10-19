import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 用户选的 WebView 渲染方式（Linux）
enum LinuxWebViewRenderMode {
  auto,
  hardware,
  software;

  static LinuxWebViewRenderMode parse(String? value) => switch (value) {
    'hardware' => hardware,
    'software' => software,
    _ => auto,
  };
}

/// 本次启动的 WebView 渲染状态（原生侧启动时判定一次）
@immutable
class LinuxWebViewRenderState {
  /// 本次启动按哪个设置判定的
  final LinuxWebViewRenderMode mode;

  /// 已保存、下次启动生效的设置
  final LinuxWebViewRenderMode savedMode;

  /// 本次网页进程是否用软件渲染
  final bool software;

  /// 判定依据：env / user / crash / nvidia / no_gpu / vm / preset / default
  final String reason;

  /// 各渲染节点的内核驱动，如 `i915,nvidia`
  final String gpuDrivers;

  const LinuxWebViewRenderState({
    required this.mode,
    required this.savedMode,
    required this.software,
    required this.reason,
    required this.gpuDrivers,
  });

  factory LinuxWebViewRenderState.fromMap(Map<Object?, Object?> map) {
    return LinuxWebViewRenderState(
      mode: LinuxWebViewRenderMode.parse(map['mode'] as String?),
      savedMode: LinuxWebViewRenderMode.parse(map['savedMode'] as String?),
      software: map['software'] == true,
      reason: map['reason'] as String? ?? '',
      gpuDrivers: map['gpuDrivers'] as String? ?? '',
    );
  }

  /// 改了设置还没重启
  bool get pendingRestart => savedMode != mode;
}

/// Linux：WebView 网页进程（WPEWebProcess）渲染方式的原生桥接。
///
/// NVIDIA 专有驱动下网页进程走硬件渲染会在 libnvidia-eglcore 里崩溃（登录页、
/// 人机验证页全黑）。原生侧（flutter_inappwebview_linux 的 cfluxdo_render_mode）
/// 启动时自动判定，崩过一次也会自动改软件；这里只负责设置页读写与崩溃提示。
class LinuxWebViewRenderService {
  const LinuxWebViewRenderService._();

  static const MethodChannel _channel = MethodChannel('cfluxdo/wpe_render');

  static bool get supported => !kIsWeb && Platform.isLinux;

  /// 网页进程在「自动 + 硬件」下崩溃（原生侧已记下，下次启动改软件），每次进程最多一回
  static void listen({required VoidCallback onWebProcessCrashed}) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'webProcessCrashed') onWebProcessCrashed();
      return null;
    });
  }

  static Future<LinuxWebViewRenderState?> getState() async {
    if (!supported) return null;
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('getState');
      return map == null ? null : LinuxWebViewRenderState.fromMap(map);
    } catch (e) {
      debugPrint('读取 WebView 渲染状态失败: $e');
      return null;
    }
  }

  /// 保存设置（下次启动生效），同时清掉崩溃记录
  static Future<LinuxWebViewRenderState?> setMode(
    LinuxWebViewRenderMode mode,
  ) async {
    if (!supported) return null;
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'setMode',
      mode.name,
    );
    return map == null ? null : LinuxWebViewRenderState.fromMap(map);
  }
}
