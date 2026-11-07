import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/connection_status_card.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/engine_card.dart';
import 'package:fluxdo/services/network/rhttp/rhttp_settings_service.dart';

/// 网络设置主页面：连接状态卡显示哪种情形、引擎预设怎么认
void main() {
  group('resolveNetStatusKind', () {
    NetStatusKind kind({
      bool dohEnabled = true,
      bool proxyActive = false,
      bool applying = false,
      bool running = true,
      bool startFailed = false,
      bool vpnPausedAccel = false,
      bool selectorEligible = true,
      String? phase = 'ready',
    }) => resolveNetStatusKind(
      dohEnabled: dohEnabled,
      proxyActive: proxyActive,
      applying: applying,
      running: running,
      startFailed: startFailed,
      vpnPausedAccel: vpnPausedAccel,
      selectorEligible: selectorEligible,
      phase: phase,
    );

    test('加速关着：VPN 接管时说暂停，否则说已关闭', () {
      expect(kind(dohEnabled: false, running: false), NetStatusKind.accelOff);
      expect(
        kind(dohEnabled: false, running: false, vpnPausedAccel: true),
        NetStatusKind.vpnPaused,
      );
    });

    test('网关在启动 / 没起来', () {
      expect(kind(applying: true), NetStatusKind.starting);
      expect(kind(running: false), NetStatusKind.starting);
      expect(
        kind(running: false, startFailed: true),
        NetStatusKind.startFailed,
      );
      // 改设置重启期间即使上次失败过也先显示「正在启动」
      expect(
        kind(applying: true, running: false, startFailed: true),
        NetStatusKind.starting,
      );
    });

    test('上游代理优先于优选状态；加速关着但代理开着也要起网关', () {
      expect(
        kind(proxyActive: true, selectorEligible: false),
        NetStatusKind.viaProxy,
      );
      expect(
        kind(dohEnabled: false, proxyActive: true, selectorEligible: false),
        NetStatusKind.viaProxy,
      );
      expect(
        kind(dohEnabled: false, proxyActive: true, running: false),
        NetStatusKind.starting,
      );
    });

    test('加速开着但不做优选（网关模式关 / 平台不支持）', () {
      expect(kind(selectorEligible: false), NetStatusKind.accelOnNoSelect);
    });

    test('优选各阶段；还没拉到快照时按「正在检查」', () {
      expect(kind(phase: null), NetStatusKind.checking);
      expect(kind(phase: 'verifying'), NetStatusKind.checking);
      expect(kind(phase: 'racing'), NetStatusKind.racing);
      expect(kind(phase: 'ready'), NetStatusKind.ready);
      expect(kind(phase: 'failed'), NetStatusKind.selectFailed);
      expect(kind(phase: 'idle'), NetStatusKind.idle);
    });
  });

  group('enginePresetOf', () {
    EnginePreset? preset(bool rhttp, RhttpMode mode, bool webView) =>
        enginePresetOf(
          rhttpEnabled: rhttp,
          rhttpMode: mode,
          webViewEnabled: webView,
        );

    test('三种预设', () {
      expect(preset(false, RhttpMode.always, false), EnginePreset.standard);
      // rhttp 关着时模式无所谓
      expect(preset(false, RhttpMode.proxyOnly, false), EnginePreset.standard);
      expect(preset(true, RhttpMode.always, false), EnginePreset.performance);
      expect(preset(false, RhttpMode.always, true), EnginePreset.compat);
    });

    test('对不上预设的组合算自定义', () {
      expect(preset(true, RhttpMode.proxyOnly, false), isNull);
      expect(preset(true, RhttpMode.always, true), isNull);
    });
  });
}
