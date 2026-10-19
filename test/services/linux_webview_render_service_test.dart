import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/services/linux_webview_render_service.dart';
import 'package:fluxdo/settings/definitions/preferences_defs.dart';

void main() {
  test('原生状态解析：未知取值回落到自动，改了没重启算待生效', () {
    final state = LinuxWebViewRenderState.fromMap(const {
      'mode': 'auto',
      'savedMode': 'hardware',
      'software': true,
      'reason': 'nvidia',
      'gpuDrivers': 'i915,nvidia',
    });
    expect(state.mode, LinuxWebViewRenderMode.auto);
    expect(state.savedMode, LinuxWebViewRenderMode.hardware);
    expect(state.software, isTrue);
    expect(state.gpuDrivers, 'i915,nvidia');
    expect(state.pendingRestart, isTrue);

    final empty = LinuxWebViewRenderState.fromMap(const {'mode': 'bogus'});
    expect(empty.mode, LinuxWebViewRenderMode.auto);
    expect(empty.savedMode, LinuxWebViewRenderMode.auto);
    expect(empty.software, isFalse);
    expect(empty.pendingRestart, isFalse);
  });

  test('设置页状态行：本次方式 + 依据，待生效时补一句', () {
    final l10n = AppLocale.zh.buildSync();
    const nvidia = LinuxWebViewRenderState(
      mode: LinuxWebViewRenderMode.auto,
      savedMode: LinuxWebViewRenderMode.auto,
      software: true,
      reason: 'nvidia',
      gpuDrivers: 'nvidia',
    );
    expect(
      linuxWebViewRenderStatus(l10n, nvidia),
      '本次：软件渲染（检测到 NVIDIA 专有驱动）',
    );

    const pending = LinuxWebViewRenderState(
      mode: LinuxWebViewRenderMode.auto,
      savedMode: LinuxWebViewRenderMode.software,
      software: false,
      reason: 'default',
      gpuDrivers: 'i915',
    );
    expect(
      linuxWebViewRenderStatus(l10n, pending),
      '本次：硬件加速（显卡正常） · 已保存，重启后生效',
    );
  });
}
