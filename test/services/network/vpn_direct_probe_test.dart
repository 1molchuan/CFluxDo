import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 安卓「自动」判定下，加速让不让路按实测（系统网络能否直连论坛），不只看 VPN 网卡。
/// 2026-11 佬友反馈：路由器分流的手机没有 VPN 网卡却能直连；Tailscale 有网卡却不翻墙
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wifi = [ConnectivityResult.wifi];
  const wifiVpn = [ConnectivityResult.wifi, ConnectivityResult.vpn];
  const mobile = [ConnectivityResult.mobile];
  const none = [ConnectivityResult.none];

  late SharedPreferences prefs;
  late VpnAutoToggleService toggle;
  final probed = <Uri>[];
  Future<bool> Function() answer = () async => false;

  /// 现有用例只分「通 / 不通」：不通按「确实连不上」（被重置、超时）算
  DirectProbeResult verdict(bool ok) =>
      ok ? DirectProbeResult.reachable : DirectProbeResult.blocked;

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    VpnAutoToggleService.probeSupportedOverride = true;
    VpnAutoToggleService.probeDelay = Duration.zero;
    probed.clear();
    VpnAutoToggleService.probeRetryDelays = const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
    ];
    VpnAutoToggleService.reprobeMinInterval = Duration.zero;
    VpnAutoToggleService.directProber = (url) async {
      probed.add(url);
      return verdict(await answer());
    };
    toggle = VpnAutoToggleService.instance
      ..resetForTest()
      ..initialize(prefs);
    toggle.accelUnreachableStreak = ForumUnreachableStreak(
      minSpan: Duration.zero,
    );
    await settle();
  });

  tearDown(() {
    VpnAutoToggleService.probeSupportedOverride = null;
    VpnAutoToggleService.directProber = VpnAutoToggleService.probeDirect;
    VpnAutoToggleService.probeDelay = const Duration(milliseconds: 1500);
    VpnAutoToggleService.probeRetryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ];
    VpnAutoToggleService.probeStaleAfter = const Duration(minutes: 5);
    VpnAutoToggleService.reprobeMinInterval = const Duration(seconds: 30);
  });

  test('Tailscale 一类：有 VPN 网卡但实测连不上 → 先按网卡让路，测完恢复加速', () async {
    answer = () async => false;
    await toggle.syncInitialState(wifiVpn);
    // 没有缓存：初值按 VPN 网卡（旧行为）
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    await settle();
    // 论坛主域 + linux.do 的 ldstatic 消息推送域与 CDN 域
    expect(probed.map((u) => u.host).toSet(), {
      'linux.do',
      'ping.ldstatic.com',
      'cdn.ldstatic.com',
    });
    expect(probed.firstWhere((u) => u.host == 'linux.do').path, '/srv/status');
    expect(toggle.directReachableNotifier.value, isFalse);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
    expect(toggle.vpnActive, isTrue);
    expect(toggle.locksAcceleration, isFalse);
  });

  test('路由器分流一类：没有 VPN 网卡但实测能直连 → 让路', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    await settle();
    expect(toggle.directReachableNotifier.value, isTrue);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.isDohSuppressed, isTrue);
    expect(toggle.vpnActive, isFalse);
    expect(toggle.locksAcceleration, isTrue);
  });

  test('同一网络再启动：先用上次实测结果，不等这次测完', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    // 重启：这次实测一直不回来
    final never = Completer<bool>();
    answer = () => never.future;
    toggle.resetForTest();
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.directReachableNotifier.value, isNull);
  });

  test('换网作废旧结果：Wi-Fi 能直连，换到流量测出不能 → 恢复加速', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    answer = () async => false;
    toggle.handleConnectivityChanged(mobile);
    await settle();
    expect(toggle.directReachableNotifier.value, isFalse);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('同一形态的重复网络事件不重测', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    final once = probed.length;
    toggle.handleConnectivityChanged(wifi);
    toggle.handleConnectivityChanged(wifi);
    await settle();
    expect(probed, hasLength(once));
  });

  test('主域通但消息推送域不通 → 不让路（规则模式漏了 ldstatic 子域）', () async {
    VpnAutoToggleService.directProber = (url) async {
      probed.add(url);
      return verdict(url.host != 'ping.ldstatic.com');
    };
    await toggle.syncInitialState(wifiVpn);
    await settle();
    expect(toggle.directReachableNotifier.value, isFalse);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
  });

  test('探测目标：站点设置里的推送域、CDN 域去重并入', () {
    final targets = VpnAutoToggleService.probeTargets(
      forumHost: 'idcflare.com',
      isLinuxDo: false,
      longPollingBaseUrl: 'https://ping.example.com/',
      cdnUrl: 'https://idcflare.com',
    );
    expect(targets.map((u) => u.toString()), [
      'https://idcflare.com/srv/status',
      'https://ping.example.com/',
    ]);
  });

  test('实测能直连但实际一直连不上 → 恢复加速，并把这个网络记成不能直连', () async {
    answer = () async => true;
    await toggle.syncInitialState(wifi);
    await settle();
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

    expect(await toggle.resumeAccelerationForVpn('test'), isTrue);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.directReachableNotifier.value, isFalse);

    // 下次启动同一网络：缓存是「不能」，直接保持加速
    final never = Completer<bool>();
    answer = () => never.future;
    toggle.resetForTest();
    await toggle.syncInitialState(wifi);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('强制档不实测：强制非 VPN 时即使能直连也保持加速', () async {
    answer = () async => true;
    await toggle.setDetectionMode(VpnDetectionMode.forceInactive);
    await toggle.syncInitialState(wifiVpn);
    await settle();
    expect(probed, isEmpty);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    await toggle.setDetectionMode(VpnDetectionMode.automatic);
    await settle();
  });

  // ---- 2026-11-20 日志：后台被系统断网、VPN 还没接管时测到的「连不上」不能算数 ----

  group('只认可信的实测', () {
    /// 按次序给出每一轮实测的结论（三个目标同一个结论），用完后一直给最后一个
    void script(List<DirectProbeResult> rounds) {
      var calls = 0;
      VpnAutoToggleService.directProber = (url) async {
        probed.add(url);
        final round = (calls++ ~/ 3).clamp(0, rounds.length - 1);
        return rounds[round];
      };
    }

    test('失败原因归类：被本机拒绝 / 没路由 / 解析不出是没就绪，其余是连不上', () {
      DirectProbeResult of(Object e) =>
          VpnAutoToggleService.classifyProbeError(e);
      expect(
        of(
          const SocketException(
            '',
            osError: OSError('Connection refused', 111),
          ),
        ),
        DirectProbeResult.notReady,
      );
      expect(
        of(
          const SocketException(
            '',
            osError: OSError('Network is unreachable', 101),
          ),
        ),
        DirectProbeResult.notReady,
      );
      expect(
        of(const SocketException("Failed host lookup: 'linux.do'")),
        DirectProbeResult.notReady,
      );
      // 墙的重置在握手里、丢包是超时、被污染到别家 IP 是证书不对
      expect(
        of(
          const SocketException(
            '',
            osError: OSError('Connection reset by peer', 104),
          ),
        ),
        DirectProbeResult.blocked,
      );
      expect(of(TimeoutException('probe')), DirectProbeResult.blocked);
      expect(
        of(const HandshakeException('bad cert')),
        DirectProbeResult.blocked,
      );
    });

    test('VPN 刚起来还没接管：先没就绪、重测通了 → 一直让路，中途不切回加速', () async {
      script([DirectProbeResult.notReady, DirectProbeResult.reachable]);
      await toggle.syncInitialState(wifiVpn);
      // 没有缓存：初值按 VPN 网卡让路
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      await settle();
      expect(probed, hasLength(6));
      expect(toggle.directReachableNotifier.value, isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      expect(toggle.isDohSuppressed, isTrue);
    });

    test('一直没就绪：先按不能直连保持加速，但不记进缓存', () async {
      script([DirectProbeResult.notReady]);
      await toggle.syncInitialState(wifiVpn);
      await settle();
      // 首测 + 两次重测
      expect(probed, hasLength(9));
      expect(toggle.directReachableNotifier.value, isFalse);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);

      // 同一网络再启动：没有缓存，初值仍按 VPN 网卡
      final never = Completer<DirectProbeResult>();
      VpnAutoToggleService.directProber = (_) => never.future;
      toggle.resetForTest();
      await toggle.syncInitialState(wifiVpn);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    });

    test('有的目标确实连不上、有的没就绪 → 直接按连不上，不重测', () async {
      VpnAutoToggleService.directProber = (url) async {
        probed.add(url);
        return url.host == 'linux.do'
            ? DirectProbeResult.blocked
            : DirectProbeResult.notReady;
      };
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(probed, hasLength(3));
      expect(toggle.directReachableNotifier.value, isFalse);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    });

    test('App 在后台时换网：不测、不改让路，回前台补测', () async {
      answer = () async => true;
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      final before = probed.length;

      // 退到后台，Wi-Fi 换成流量（VPN 还在）：系统这时会拒掉 App 的连接
      toggle.setAppForeground(false);
      answer = () async => false;
      toggle.handleConnectivityChanged(const [
        ConnectivityResult.mobile,
        ConnectivityResult.vpn,
      ]);
      await settle();
      expect(probed, hasLength(before));
      expect(toggle.directReachableNotifier.value, isNull);
      // 没测过的 VPN 网络：仍按 VPN 网卡让路，网关不重启
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

      answer = () async => true;
      toggle.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await settle();
      expect(probed.length, before + 3);
      expect(toggle.directReachableNotifier.value, isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    });

    test('实测途中退到后台：没测通的结果作废，回前台重测', () async {
      final gate = Completer<void>();
      var rounds = 0;
      VpnAutoToggleService.directProber = (url) async {
        probed.add(url);
        if (rounds == 0) {
          await gate.future;
          return DirectProbeResult.blocked;
        }
        return DirectProbeResult.reachable;
      };
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(probed, hasLength(3));
      toggle.setAppForeground(false);
      rounds = 1;
      gate.complete();
      await settle();
      // 作废：没有结论，也没切回加速
      expect(toggle.directReachableNotifier.value, isNull);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

      toggle.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await settle();
      expect(probed, hasLength(6));
      expect(toggle.directReachableNotifier.value, isTrue);
    });

    test('断网的一瞬不改让路：Wi-Fi+VPN → 无网络 → 流量+VPN，全程不切回加速', () async {
      answer = () async => true;
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(toggle.isDohSuppressed, isTrue);

      toggle.handleConnectivityChanged(none);
      await settle();
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
      expect(toggle.isDohSuppressed, isTrue);

      toggle.handleConnectivityChanged(const [
        ConnectivityResult.mobile,
        ConnectivityResult.vpn,
      ]);
      await settle();
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    });

    test('开着 VPN 保持加速时论坛连续连不上 → 重测，能直连了就让路', () async {
      answer = () async => false;
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
      final before = probed.length;

      answer = () async => true;
      for (var i = 0; i < 3; i++) {
        toggle.reportForumTransport(reachable: false, detail: 'refused');
      }
      await settle();
      expect(probed.length, before + 3);
      expect(toggle.directReachableNotifier.value, isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    });

    test('没有 VPN 网卡时加速连不上不重测（那是网络本身的事）', () async {
      answer = () async => false;
      await toggle.syncInitialState(wifi);
      await settle();
      final before = probed.length;
      for (var i = 0; i < 5; i++) {
        toggle.reportForumTransport(reachable: false, detail: 'refused');
      }
      await settle();
      expect(probed, hasLength(before));
    });

    test('回到前台：开着 VPN 且上次实测已久就重测一次', () async {
      answer = () async => true;
      await toggle.syncInitialState(wifiVpn);
      await settle();
      final before = probed.length;

      // 刚测过：不重测
      toggle.setAppForeground(false);
      toggle.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await settle();
      expect(probed, hasLength(before));

      VpnAutoToggleService.probeStaleAfter = Duration.zero;
      toggle.setAppForeground(false);
      toggle.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await settle();
      expect(probed.length, before + 3);
    });

    test('后台的连不上不算数：让路期间长轮询被系统拒掉，不恢复加速也不改缓存', () async {
      answer = () async => true;
      await toggle.syncInitialState(wifiVpn);
      await settle();
      expect(toggle.isDohSuppressed, isTrue);
      toggle.unreachableStreak = ForumUnreachableStreak(minSpan: Duration.zero);

      toggle.setAppForeground(false);
      for (var i = 0; i < 5; i++) {
        toggle.reportForumTransport(reachable: false, detail: 'refused');
      }
      await settle();
      expect(toggle.accelResumed, isFalse);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);

      // 对照：前台同样的连败照旧恢复加速
      toggle.setAppForeground(true);
      await settle();
      for (var i = 0; i < 3; i++) {
        toggle.reportForumTransport(reachable: false, detail: 'refused');
      }
      await settle();
      expect(toggle.accelResumed, isTrue);
      expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
      toggle.unreachableStreak = ForumUnreachableStreak();
    });

    test('旧版本的实测缓存整个作废', () async {
      SharedPreferences.setMockInitialValues({
        'vpn_direct_probe':
            '{"mobile|vpn@linux.do":{"ok":false,"at":${DateTime.now().millisecondsSinceEpoch}}}',
      });
      final fresh = await SharedPreferences.getInstance();
      final never = Completer<DirectProbeResult>();
      VpnAutoToggleService.directProber = (_) => never.future;
      final service = VpnAutoToggleService.instance
        ..resetForTest()
        ..initialize(fresh);
      await service.syncInitialState(const [
        ConnectivityResult.mobile,
        ConnectivityResult.vpn,
      ]);
      // 旧缓存说「不能直连」；作废后按 VPN 网卡让路
      expect(NetworkSettingsService.storedDohEnabled(fresh), isFalse);
      expect(fresh.containsKey('vpn_direct_probe'), isFalse);
    });
  });
}
