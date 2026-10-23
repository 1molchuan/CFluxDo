import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../network_logger.dart';
import '../../../l10n/s.dart';
import 'doh_proxy_ffi.dart';

/// DOH (DNS over HTTPS) 代理服务
/// 使用 Rust 实现的本地代理，通过 DOH 解析 DNS 并支持 ECH
///
/// 在桌面平台（Windows/macOS/Linux）使用进程方式运行代理
/// 在移动平台（Android/iOS）使用 FFI 直接调用 Rust 库
class DohProxyService {
  DohProxyService._();
  static final DohProxyService instance = DohProxyService._();

  // 桌面平台进程管理
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  // 共享状态
  int? _port;
  bool _isRunning = false;
  bool? _currentEnableDoh;
  bool? _currentGatewayMode;
  String? _currentDohServer;
  String? _currentDohServerEch;
  String? _currentDohBootstrapSignature;
  String? _currentDohAuthSignature;
  bool? _currentPreferIPv6;
  int? _currentPreferredPort;
  String? _currentServerIp;
  bool? _currentMitmConnect;
  bool? _currentH2Mitm;
  String? _currentUpstreamSignature;
  String? _currentDohRoutesUrl;
  String? _currentSelectMode;
  String? _lastError;
  bool _processAuthRejected = false;
  // 进程模式下 stdout 打出的 DOH_ACCEL_UPDATE 行，等 App 取走
  DohAccelUpdate? _processAccelUpdate;
  // ignore: unused_field
  Isolate? _ffiIsolate; // 保持引用防止 GC
  SendPort? _ffiSendPort;
  Future<void> _ffiQueue = Future.value();

  /// 代理是否正在运行
  bool get isRunning => _isRunning;

  /// 代理端口
  int? get port => _port;

  /// 最近一次启动失败的原因
  String? get lastError => _lastError;

  /// 启动 DOH 代理
  ///
  /// [preferredPort] - 首选端口（0 为自动选择）
  /// [preferIPv6] - 是否优先使用 IPv6
  /// [dohServer] - DOH 服务器 URL（null 为默认 Cloudflare）
  Future<bool> start({
    int preferredPort = 0,
    bool enableDoh = true,
    bool preferIPv6 = false,
    bool gatewayMode = false,
    String? dohServer,
    String? dohServerEch,
    List<String> dohBootstrapIps = const [],
    List<String> dohEchBootstrapIps = const [],
    String? dohAuthToken,
    String? dohEchAuthToken,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
    String? caCertPem,
    String? caKeyPem,
    bool mitmConnect = true,
    bool h2Mitm = false,
    String? dohRoutesUrl,
    String? dohRouteTableJson,
    String? dohNodeListJson,
    String selectMode = 'off',
    String? selectStateJson,
    bool shareMeasurements = false,
    String? atlasRoutesUrl,
    List<Map<String, Object>> publicDoh = const [],
    String? reportUrl,
    String? reportBearer,
    List<String> extraCoveredHosts = const [],
    String? appVersion,
    String? networkSig,
    List<String> preconnectHosts = const [],
  }) async {
    final authSignature = _buildAuthSignature(dohAuthToken, dohEchAuthToken);
    final bootstrapSignature = _buildBootstrapSignature(
      dohBootstrapIps,
      dohEchBootstrapIps,
    );
    final upstreamSignature = _buildUpstreamSignature(
      protocol: upstreamProtocol,
      host: upstreamHost,
      port: upstreamPort,
      username: upstreamUsername,
      password: upstreamPassword,
      cipher: upstreamCipher,
    );
    if (_isRunning) {
      final sameConfig =
          _currentEnableDoh == enableDoh &&
          _currentGatewayMode == gatewayMode &&
          _currentDohServer == dohServer &&
          _currentDohServerEch == dohServerEch &&
          _currentDohBootstrapSignature == bootstrapSignature &&
          _currentDohAuthSignature == authSignature &&
          _currentPreferIPv6 == preferIPv6 &&
          _currentPreferredPort == preferredPort &&
          _currentServerIp == serverIp &&
          _currentMitmConnect == mitmConnect &&
          _currentH2Mitm == h2Mitm &&
          _currentUpstreamSignature == upstreamSignature &&
          // 路由表 / 节点列表只是启动时的种子，内容变了不重启；只看接口地址
          _currentDohRoutesUrl == dohRoutesUrl &&
          // 优选模式变了要重启；share / bearer / networkSig / selectState / appVersion
          // 都是运行态（有专门的 FFI 入口或只在启动时回灌），不触发重启
          _currentSelectMode == selectMode;
      if (sameConfig) {
        NetworkLogger.log('[DOH] 代理已在运行，端口: $_port');
        return true;
      }
      NetworkLogger.log('[DOH] 配置变更，重启代理');
      await stop();
    }

    _lastError = null;

    // 根据平台选择启动方式
    if (DohProxyFfi.isAvailable) {
      final result = await _startWithFfi(
        preferredPort,
        enableDoh,
        gatewayMode,
        preferIPv6,
        dohServer,
        dohServerEch,
        dohBootstrapIps,
        dohEchBootstrapIps,
        dohAuthToken,
        dohEchAuthToken,
        serverIp,
        upstreamProtocol,
        upstreamHost,
        upstreamPort,
        upstreamUsername,
        upstreamPassword,
        upstreamCipher,
        caCertPem,
        caKeyPem,
        mitmConnect,
        h2Mitm,
        dohRoutesUrl,
        dohRouteTableJson,
        dohNodeListJson,
        selectMode: selectMode,
        selectStateJson: selectStateJson,
        shareMeasurements: shareMeasurements,
        atlasRoutesUrl: atlasRoutesUrl,
        publicDoh: publicDoh,
        reportUrl: reportUrl,
        reportBearer: reportBearer,
        extraCoveredHosts: extraCoveredHosts,
        appVersion: appVersion,
        networkSig: networkSig,
        preconnectHosts: preconnectHosts,
      );
      // 桌面平台 FFI 加载失败时，回退到进程模式
      if (!result && DohProxyFfi.canFallbackToProcess) {
        NetworkLogger.log('[DOH] FFI 启动失败，尝试进程模式');
        _lastError = null;
        return _startWithProcess(
          preferredPort,
          enableDoh,
          gatewayMode,
          preferIPv6,
          dohServer,
          dohServerEch,
          dohBootstrapIps,
          dohEchBootstrapIps,
          dohAuthToken,
          dohEchAuthToken,
          serverIp,
          upstreamProtocol,
          upstreamHost,
          upstreamPort,
          upstreamUsername,
          upstreamPassword,
          upstreamCipher,
          mitmConnect,
          h2Mitm,
          dohRoutesUrl,
          selectMode: selectMode,
        );
      }
      return result;
    } else {
      return _startWithProcess(
        preferredPort,
        enableDoh,
        gatewayMode,
        preferIPv6,
        dohServer,
        dohServerEch,
        dohBootstrapIps,
        dohEchBootstrapIps,
        dohAuthToken,
        dohEchAuthToken,
        serverIp,
        upstreamProtocol,
        upstreamHost,
        upstreamPort,
        upstreamUsername,
        upstreamPassword,
        upstreamCipher,
        mitmConnect,
        h2Mitm,
        dohRoutesUrl,
        selectMode: selectMode,
      );
    }
  }

  /// 使用 FFI 启动代理（Android/iOS）
  Future<bool> _startWithFfi(
    int port,
    bool enableDoh,
    bool gatewayMode,
    bool preferIPv6,
    String? dohServer,
    String? dohServerEch,
    List<String> dohBootstrapIps,
    List<String> dohEchBootstrapIps,
    String? dohAuthToken,
    String? dohEchAuthToken,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
    String? caCertPem,
    String? caKeyPem,
    bool mitmConnect,
    bool h2Mitm,
    String? dohRoutesUrl,
    String? dohRouteTableJson,
    String? dohNodeListJson, {
    String selectMode = 'off',
    String? selectStateJson,
    bool shareMeasurements = false,
    String? atlasRoutesUrl,
    List<Map<String, Object>> publicDoh = const [],
    String? reportUrl,
    String? reportBearer,
    List<String> extraCoveredHosts = const [],
    String? appVersion,
    String? networkSig,
    List<String> preconnectHosts = const [],
  }) async {
    try {
      return await _enqueueFfiOp(() async {
        NetworkLogger.log(
          '[DOH] 使用 FFI 启动代理，模式: ${enableDoh ? "DoH 网关" : "纯上游代理"}',
        );

        _currentPreferredPort = port;
        await _ensureFfiStopped();
        final resultPort = await _callFfiStart(
          port: port,
          enableDoh: enableDoh,
          gatewayMode: gatewayMode,
          preferIpv6: preferIPv6,
          dohServer: dohServer,
          dohServerEch: dohServerEch,
          dohBootstrapIps: dohBootstrapIps,
          dohEchBootstrapIps: dohEchBootstrapIps,
          dohAuthToken: dohAuthToken,
          dohEchAuthToken: dohEchAuthToken,
          serverIp: serverIp,
          upstreamProtocol: upstreamProtocol,
          upstreamHost: upstreamHost,
          upstreamPort: upstreamPort,
          upstreamUsername: upstreamUsername,
          upstreamPassword: upstreamPassword,
          upstreamCipher: upstreamCipher,
          caCertPem: caCertPem,
          caKeyPem: caKeyPem,
          mitmConnect: mitmConnect,
          h2Mitm: h2Mitm,
          dohRoutesUrl: dohRoutesUrl,
          dohRouteTableJson: dohRouteTableJson,
          dohNodeListJson: dohNodeListJson,
          selectMode: selectMode,
          selectStateJson: selectStateJson,
          shareMeasurements: shareMeasurements,
          atlasRoutesUrl: atlasRoutesUrl,
          publicDoh: publicDoh,
          reportUrl: reportUrl,
          reportBearer: reportBearer,
          extraCoveredHosts: extraCoveredHosts,
          appVersion: appVersion,
          networkSig: networkSig,
          preconnectHosts: preconnectHosts,
        );
        if (resultPort <= 0) {
          // _callFfiStart 已设置更详细的 _lastError，仅在未设置时补充
          _lastError ??= 'FFI 启动失败，返回值: $resultPort';
          NetworkLogger.log('[DOH] $_lastError');
          return false;
        }

        _port = resultPort;
        _isRunning = true;
        _currentEnableDoh = enableDoh;
        _currentGatewayMode = gatewayMode;
        _currentDohServer = dohServer;
        _currentDohServerEch = dohServerEch;
        _currentDohBootstrapSignature = _buildBootstrapSignature(
          dohBootstrapIps,
          dohEchBootstrapIps,
        );
        _currentDohAuthSignature = _buildAuthSignature(
          dohAuthToken,
          dohEchAuthToken,
        );
        _currentPreferIPv6 = preferIPv6;
        _currentPreferredPort = port;
        _currentServerIp = serverIp;
        _currentMitmConnect = mitmConnect;
        _currentH2Mitm = h2Mitm;
        _currentUpstreamSignature = _buildUpstreamSignature(
          protocol: upstreamProtocol,
          host: upstreamHost,
          port: upstreamPort,
          username: upstreamUsername,
          password: upstreamPassword,
          cipher: upstreamCipher,
        );
        _currentDohRoutesUrl = dohRoutesUrl;
        _currentSelectMode = selectMode;
        NetworkLogger.log('[DOH] FFI 代理已启动，端口: $_port');
        return true;
      });
    } catch (e) {
      _lastError = 'FFI 启动异常: $e';
      NetworkLogger.log('[DOH] $_lastError');
      return false;
    }
  }

  /// 使用进程启动代理（桌面平台）
  Future<bool> _startWithProcess(
    int preferredPort,
    bool enableDoh,
    bool gatewayMode,
    bool preferIPv6,
    String? dohServer,
    String? dohServerEch,
    List<String> dohBootstrapIps,
    List<String> dohEchBootstrapIps,
    String? dohAuthToken,
    String? dohEchAuthToken,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
    bool mitmConnect,
    bool h2Mitm,
    String? dohRoutesUrl, {
    // 进程模式不做本地优选，只记下模式让 sameConfig 比较稳定
    String selectMode = 'off',
  }) async {
    try {
      final executablePath = await _getExecutablePath();
      if (executablePath == null) {
        _lastError = S.current.doh_executableNotFound;
        NetworkLogger.log('[DOH] $_lastError');
        return false;
      }

      NetworkLogger.log(
        '[DOH] 启动代理进程: $executablePath, 模式: ${enableDoh ? "DoH 网关" : "纯上游代理"}',
      );

      // 构建命令行参数
      final args = <String>[
        preferredPort.toString(),
        if (!enableDoh) '--no-doh',
        if (gatewayMode) '--gateway',
        if (!mitmConnect) '--tunnel-connect',
        if (h2Mitm) '--h2-mitm',
        if (preferIPv6) '--ipv6',
        if (dohServer != null && dohServer.isNotEmpty) ...['--doh', dohServer],
        if (dohServerEch != null && dohServerEch.isNotEmpty) ...[
          '--doh-server-ech',
          dohServerEch,
        ],
        if (dohBootstrapIps.isNotEmpty) ...[
          '--doh-bootstrap-ips',
          dohBootstrapIps.join(','),
        ],
        if (dohEchBootstrapIps.isNotEmpty) ...[
          '--doh-ech-bootstrap-ips',
          dohEchBootstrapIps.join(','),
        ],
        if (serverIp != null && serverIp.isNotEmpty) ...[
          '--server-ip',
          serverIp,
        ],
        if (dohRoutesUrl != null && dohRoutesUrl.isNotEmpty) ...[
          '--doh-routes-url',
          dohRoutesUrl,
        ],
        if (upstreamHost != null && upstreamHost.isNotEmpty) ...[
          '--upstream-protocol',
          upstreamProtocol ?? 'http',
          '--upstream-host',
          upstreamHost,
          if (upstreamPort != null) ...[
            '--upstream-port',
            upstreamPort.toString(),
          ],
          if (upstreamCipher != null && upstreamCipher.isNotEmpty) ...[
            '--upstream-cipher',
            upstreamCipher,
          ],
          if (upstreamUsername != null && upstreamUsername.isNotEmpty) ...[
            '--upstream-user',
            upstreamUsername,
          ],
          if (upstreamPassword != null && upstreamPassword.isNotEmpty) ...[
            '--upstream-pass',
            upstreamPassword,
          ],
        ],
      ];

      // 启动进程；令牌走环境变量，不放命令行，避免出现在进程列表里
      _process = await Process.start(
        executablePath,
        args,
        environment: {
          if (dohAuthToken != null && dohAuthToken.isNotEmpty)
            'DOH_PROXY_AUTH_TOKEN': dohAuthToken,
          if (dohEchAuthToken != null && dohEchAuthToken.isNotEmpty)
            'DOH_PROXY_ECH_AUTH_TOKEN': dohEchAuthToken,
        },
      );

      // 监听 stdout 获取端口信息
      final stdoutLines = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      final completer = Completer<bool>();
      var completed = false;

      _stdoutSubscription = stdoutLines.listen((line) {
        if (line.trim() == 'DOH_AUTH_REJECTED') {
          _processAuthRejected = true;
          return;
        }
        if (line.startsWith(_accelUpdatePrefix)) {
          _processAccelUpdate = _parseProcessAccelUpdate(
            line.substring(_accelUpdatePrefix.length),
          );
          return;
        }
        NetworkLogger.log('[DOH] $line');
        // 解析端口: "DOH proxy server listening on 127.0.0.1:12345"
        final match = RegExp(r'listening on [\d.]+:(\d+)').firstMatch(line);
        if (match != null && !completed) {
          _port = int.tryParse(match.group(1) ?? '');
          _isRunning = true;
          _currentEnableDoh = enableDoh;
          _currentGatewayMode = gatewayMode;
          _currentDohServer = dohServer;
          _currentDohServerEch = dohServerEch;
          _currentDohBootstrapSignature = _buildBootstrapSignature(
            dohBootstrapIps,
            dohEchBootstrapIps,
          );
          _currentDohAuthSignature = _buildAuthSignature(
            dohAuthToken,
            dohEchAuthToken,
          );
          _currentPreferIPv6 = preferIPv6;
          _currentPreferredPort = preferredPort;
          _currentServerIp = serverIp;
          _currentMitmConnect = mitmConnect;
          _currentH2Mitm = h2Mitm;
          _currentUpstreamSignature = _buildUpstreamSignature(
            protocol: upstreamProtocol,
            host: upstreamHost,
            port: upstreamPort,
            username: upstreamUsername,
            password: upstreamPassword,
            cipher: upstreamCipher,
          );
          _currentDohRoutesUrl = dohRoutesUrl;
          _currentSelectMode = selectMode;
          NetworkLogger.log('[DOH] 代理已启动，端口: $_port');
          completed = true;
          completer.complete(true);
        }
      });

      // 监听 stderr
      final stderrLines = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      _stderrSubscription = stderrLines.listen((line) {
        NetworkLogger.log('[DOH][ERROR] $line');
      });

      // 监听进程退出
      _process!.exitCode.then((code) {
        NetworkLogger.log('[DOH] 进程退出，代码: $code');
        if (!completed) {
          _lastError = '代理进程异常退出，退出码: $code';
          NetworkLogger.log('[DOH] $_lastError');
        }
        _cleanup();
        if (!completed) {
          completed = true;
          completer.complete(false);
        }
      });

      // 等待代理启动或超时
      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _lastError = S.current.doh_startTimeout;
          NetworkLogger.log('[DOH] $_lastError');
          return false;
        },
      );

      if (!result) {
        await stop();
        return false;
      }

      return true;
    } catch (e) {
      _lastError = '启动失败: $e';
      NetworkLogger.log('[DOH] $_lastError');
      await stop();
      return false;
    }
  }

  /// 停止 DOH 代理
  Future<void> stop() async {
    if (DohProxyFfi.isAvailable) {
      await _enqueueFfiOp(() async {
        await _stopWithFfi();
      });
    } else {
      await _stopWithProcess();
    }
    _cleanup();
  }

  Future<void> _stopWithFfi() async {
    try {
      await _callFfiStop();
      await _ensureFfiStopped();
      NetworkLogger.log('[DOH] FFI 代理已停止');
    } catch (e) {
      NetworkLogger.log('[DOH] FFI 停止异常: $e');
    }
  }

  Future<void> _stopWithProcess() async {
    if (_process != null) {
      NetworkLogger.log('[DOH] 停止代理进程...');
      _process!.kill();
      await _process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  void _cleanup() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process = null;
    _port = null;
    _isRunning = false;
    _currentEnableDoh = null;
    _currentGatewayMode = null;
    _currentDohServer = null;
    _currentDohServerEch = null;
    _currentDohBootstrapSignature = null;
    _currentDohAuthSignature = null;
    _currentPreferIPv6 = null;
    _currentPreferredPort = null;
    _currentServerIp = null;
    _currentMitmConnect = null;
    _currentH2Mitm = null;
    _currentUpstreamSignature = null;
    _currentDohRoutesUrl = null;
    _currentSelectMode = null;
    // 注意：不清除 _lastError，保留用于 UI 展示
  }

  static const _accelUpdatePrefix = 'DOH_ACCEL_UPDATE ';

  /// 解析进程模式 stdout 里的 `DOH_ACCEL_UPDATE {json}` 行，格式同 FFI 返回值
  DohAccelUpdate? _parseProcessAccelUpdate(String rawJson) {
    try {
      final map = jsonDecode(rawJson);
      if (map is! Map) return null;
      final routeTable = map['route_table'];
      final nodes = map['nodes'];
      final envelope = map['nodes_envelope'];
      final selectState = map['select_state'];
      final update = DohAccelUpdate(
        routeTable: routeTable is String && routeTable.isNotEmpty
            ? routeTable
            : null,
        nodes: nodes is String && nodes.isNotEmpty ? nodes : null,
        nodesEnvelopeJson: envelope is Map ? jsonEncode(envelope) : null,
        selectState: selectState is String && selectState.isNotEmpty
            ? selectState
            : null,
        reportAuthRejected: map['report_auth_rejected'] == true,
      );
      return update.isEmpty ? null : update;
    } catch (e) {
      NetworkLogger.log('[DOH] 解析 DOH_ACCEL_UPDATE 失败: $e');
      return null;
    }
  }

  /// 获取 DOH 代理可执行文件路径（仅桌面平台）
  Future<String?> _getExecutablePath() async {
    // 根据平台确定可执行文件名
    String executableName;
    if (Platform.isWindows) {
      executableName = 'doh_proxy_bin.exe';
    } else if (Platform.isMacOS || Platform.isLinux) {
      executableName = 'doh_proxy_bin';
    } else {
      // Android/iOS 使用 FFI，不需要可执行文件
      return null;
    }

    // 查找可执行文件的可能位置
    final execPath = Platform.resolvedExecutable;
    final execDir = p.dirname(execPath);
    final possiblePaths = <String>[
      // 打包后：与应用程序同目录
      p.join(execDir, executableName),
      // 打包后：桌面平台统一收口到 native 子目录
      p.join(execDir, 'native', executableName),
      if (Platform.isMacOS)
        p.join(execDir, '..', 'Resources', 'native', executableName),
      // 打包后：assets 目录
      p.join(execDir, 'data', 'flutter_assets', 'assets', executableName),
      // 开发时：通过 app bundle 路径反推项目根目录
      ...() {
        final buildIdx = execPath.indexOf('${p.separator}build${p.separator}');
        if (buildIdx > 0) {
          final projectRoot = execPath.substring(0, buildIdx);
          return [
            if (Platform.isWindows)
              p.join(
                projectRoot,
                'windows',
                'runner',
                'native',
                executableName,
              ),
            if (Platform.isMacOS)
              p.join(projectRoot, 'macos', 'Runner', 'native', executableName),
            if (Platform.isLinux)
              p.join(projectRoot, 'linux', 'runner', 'native', executableName),
            p.join(
              projectRoot,
              'core',
              'doh_proxy',
              'target',
              'release',
              executableName,
            ),
            p.join(
              projectRoot,
              'core',
              'doh_proxy',
              'target',
              'debug',
              executableName,
            ),
          ];
        }
        return <String>[];
      }(),
      // 开发时：CWD 可能是项目根目录
      if (Platform.isWindows)
        p.join(
          Directory.current.path,
          'windows',
          'runner',
          'native',
          executableName,
        ),
      if (Platform.isMacOS)
        p.join(
          Directory.current.path,
          'macos',
          'Runner',
          'native',
          executableName,
        ),
      if (Platform.isLinux)
        p.join(
          Directory.current.path,
          'linux',
          'runner',
          'native',
          executableName,
        ),
      p.join(
        Directory.current.path,
        'core',
        'doh_proxy',
        'target',
        'release',
        executableName,
      ),
      p.join(
        Directory.current.path,
        'core',
        'doh_proxy',
        'target',
        'debug',
        executableName,
      ),
    ];

    for (final path in possiblePaths) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    return null;
  }

  /// 检查代理是否真正存活（通过 FFI 查询 Rust 侧状态）
  ///
  /// iOS 进入后台时系统会挂起进程，Rust 代理的 TCP listener 可能失效，
  /// 但 Dart 侧的 [_isRunning] 标志位不会自动更新。
  /// 此方法通过 FFI 查询 Rust 侧的实际运行状态来检测这种不一致。
  ///
  /// 返回 true 表示代理正常运行，false 表示已停止或状态不一致。
  Future<bool> checkAlive() async {
    if (!_isRunning) return false;
    if (!DohProxyFfi.isAvailable) {
      // 进程模式：检查进程是否存活
      return _process != null;
    }
    try {
      final status = await _callFfiStatus();
      final running = status['running'] as bool? ?? false;
      if (!running) {
        // Rust 侧已停止，同步 Dart 侧状态
        NetworkLogger.log('[DOH] 健康检查: Rust 代理已停止，同步 Dart 状态');
        _cleanup();
      }
      return running;
    } catch (e) {
      NetworkLogger.log('[DOH] 健康检查异常: $e');
      return false;
    }
  }

  /// 获取代理 URL（用于配置 HTTP 客户端）
  String? get proxyUrl {
    if (_isRunning && _port != null) {
      return 'http://127.0.0.1:$_port';
    }
    return null;
  }

  /// 生成新的 CA 证书（仅 FFI 可用时）
  Future<({String certPem, String keyPem})?> generateCa() async {
    if (!DohProxyFfi.isAvailable) return null;
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({'cmd': 'generate_ca', 'replyTo': response.sendPort});
      final result = await response.first;
      response.close();
      if (result is Map && result['ok'] == true) {
        return (
          certPem: result['certPem'] as String,
          keyPem: result['keyPem'] as String,
        );
      }
      return null;
    });
  }

  Future<Uint8List?> lookupEchConfig(String host, String dohServer) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.lookupEchConfig(host, dohServer);
    }
    return _enqueueFfiOp(() => _callFfiLookupEchConfig(host, dohServer));
  }

  Future<List<String>> lookupIp(
    String host,
    String dohServer, {
    bool preferIpv6 = false,
  }) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.lookupIp(
            host,
            dohServer,
            preferIpv6: preferIpv6,
          ) ??
          const [];
    }
    return _enqueueFfiOp(
      () => _callFfiLookupIp(host, dohServer, preferIpv6: preferIpv6),
    );
  }

  Future<DohHostLookupResult?> lookupHost(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    bool forceRefresh = false,
  }) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.lookupHost(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        forceRefresh: forceRefresh,
      );
    }
    return _enqueueFfiOp(
      () => _callFfiLookupHost(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        forceRefresh: forceRefresh,
      ),
    );
  }

  /// 取出并清除「DoH 服务器拒绝了令牌」标记，true 表示需要重新申请令牌
  Future<bool> takeAuthRejected() async {
    if (!DohProxyFfi.isAvailable) {
      final rejected = _processAuthRejected;
      _processAuthRejected = false;
      return rejected;
    }
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'take_auth_rejected',
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      return result is Map && result['rejected'] == true;
    });
  }

  /// 取出 Rust 侧新拉到的加速路由表 / 节点列表（取出即清），没有则 null
  Future<DohAccelUpdate?> takeAccelUpdate() async {
    if (!DohProxyFfi.isAvailable) {
      final update = _processAccelUpdate;
      _processAccelUpdate = null;
      return update;
    }
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'take_accel_update',
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      if (result is! Map || result['ok'] != true) return null;
      final data = result['data'];
      if (data is! Map) return null;
      final update = DohAccelUpdate(
        routeTable: data['routeTable'] as String?,
        nodes: data['nodes'] as String?,
        nodesEnvelopeJson: data['nodesEnvelopeJson'] as String?,
        selectState: data['selectState'] as String?,
        reportAuthRejected: data['reportAuthRejected'] == true,
      );
      return update.isEmpty ? null : update;
    });
  }

  /// 通知 Rust 侧网络环境变了（[sig] 来自 ConnectivityService.signatureOf）
  ///
  /// 只在 FFI 可用的平台有效；进程模式 / 代理未运行时直接返回，不抛异常
  Future<void> networkChanged(String sig) async {
    if (!DohProxyFfi.isAvailable || _ffiSendPort == null) return;
    await _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'network_changed',
        'sig': sig,
        'replyTo': response.sendPort,
      });
      await response.first;
      response.close();
    });
  }

  /// 查询本地动态优选状态；进程模式 / 未运行 / 库不支持 / 没有优选实例返回 null
  Future<DohSelectStatus?> selectStatus() async {
    if (!DohProxyFfi.isAvailable || _ffiSendPort == null) return null;
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'select_status',
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      if (result is! Map || result['ok'] != true) return null;
      final data = result['data'];
      if (data is! Map) return null;
      return DohSelectStatus.fromJson(data.cast<String, dynamic>());
    });
  }

  /// 手动触发重新优选；true 表示已发车，false 表示冷却中 / 没有实例 / 不可用
  Future<bool> reraceSelection() async {
    if (!DohProxyFfi.isAvailable || _ffiSendPort == null) return false;
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'select_rerace',
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      return result is Map && result['ok'] == true && result['started'] == true;
    });
  }

  /// 开关「帮助优选」；[bearer] 为 cfhub 令牌，关闭时可为 null，只传给 Rust 不进日志。
  /// true 表示已应用，false 表示没有优选实例 / 不可用
  Future<bool> setShareMeasurements(bool enabled, String? bearer) async {
    if (!DohProxyFfi.isAvailable || _ffiSendPort == null) return false;
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'set_share_measurements',
        'enabled': enabled,
        'bearer': bearer,
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      return result is Map && result['ok'] == true && result['applied'] == true;
    });
  }

  /// 经 Rust 的 DoH 客户端向加速服务端发 HTTP 请求，返回 (status, body)
  ///
  /// 只在 FFI 可用的平台有效；进程模式 / 库太旧返回 null，由调用方自行回退。
  /// 连不上或超时也返回 null，非 2xx 状态照常返回。
  Future<({int status, String body})?> accelRequest(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (!DohProxyFfi.isAvailable) return null;
    return _enqueueFfiOp(() async {
      final sendPort = await _ensureFfiIsolate();
      final response = ReceivePort();
      sendPort.send({
        'cmd': 'accel_request',
        'method': method,
        'url': url,
        'headers': Map<String, String>.of(headers),
        'body': body,
        'replyTo': response.sendPort,
      });
      final result = await response.first;
      response.close();
      if (result is! Map || result['ok'] != true) return null;
      final status = result['status'];
      if (status is! int) return null;
      return (status: status, body: result['body']?.toString() ?? '');
    });
  }

  Future<bool> clearDnsCache() async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.clearDnsCache();
    }
    return _enqueueFfiOp(_callFfiClearDnsCache);
  }

  /// 网络引擎计数（进程级累计）；进程模式 / 库不支持返回 null。只读原子量，同步调用即可
  Map<String, dynamic>? netStats() {
    if (!DohProxyFfi.isAvailable || _process != null) return null;
    return DohProxyFfi.instance.netStats();
  }

  Future<DohDnsCacheStats?> dnsCacheStats() async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.dnsCacheStats();
    }
    return _enqueueFfiOp(_callFfiDnsCacheStats);
  }

  Future<List<DohDnsCacheRecord>?> dnsCacheRecords() async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.dnsCacheRecords();
    }
    return _enqueueFfiOp(_callFfiDnsCacheRecords);
  }

  Future<bool> recordHostSuccess(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    required String ip,
  }) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.recordHostSuccess(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        ip: ip,
      );
    }
    return _enqueueFfiOp(
      () => _callFfiRecordHostSuccess(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        ip: ip,
      ),
    );
  }

  /// 报告连 [host] -> [ip] 失败（作废粘性 IP；[ip] 是钉住的优选赢家时计入它的连败）
  Future<bool> reportHostFailure(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    required String ip,
  }) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.reportHostFailure(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        ip: ip,
      );
    }
    return _enqueueFfiOp(
      () => _callFfiReportHostFailure(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
        ip: ip,
      ),
    );
  }

  Future<bool> clearPreferredHostIp(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
  }) async {
    if (!DohProxyFfi.isAvailable) {
      return DohProxyFfi.instance.clearPreferredHostIp(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
      );
    }
    return _enqueueFfiOp(
      () => _callFfiClearPreferredHostIp(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
      ),
    );
  }

  Future<T> _enqueueFfiOp<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _ffiQueue = _ffiQueue.then((_) async {
      try {
        final result = await op();
        completer.complete(result);
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }

  Future<int> _callFfiStart({
    required int port,
    required bool enableDoh,
    required bool gatewayMode,
    required bool preferIpv6,
    required String? dohServer,
    required String? dohServerEch,
    List<String> dohBootstrapIps = const [],
    List<String> dohEchBootstrapIps = const [],
    String? dohAuthToken,
    String? dohEchAuthToken,
    required String? serverIp,
    required String? upstreamProtocol,
    required String? upstreamHost,
    required int? upstreamPort,
    required String? upstreamUsername,
    required String? upstreamPassword,
    required String? upstreamCipher,
    String? caCertPem,
    String? caKeyPem,
    bool mitmConnect = true,
    bool h2Mitm = false,
    String? dohRoutesUrl,
    String? dohRouteTableJson,
    String? dohNodeListJson,
    String selectMode = 'off',
    String? selectStateJson,
    bool shareMeasurements = false,
    String? atlasRoutesUrl,
    List<Map<String, Object>> publicDoh = const [],
    String? reportUrl,
    String? reportBearer,
    List<String> extraCoveredHosts = const [],
    String? appVersion,
    String? networkSig,
    List<String> preconnectHosts = const [],
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'start',
      'port': port,
      'enableDoh': enableDoh,
      'gatewayMode': gatewayMode,
      'h2Mitm': h2Mitm,
      'preferIpv6': preferIpv6,
      'dohServer': dohServer,
      'dohServerEch': dohServerEch,
      'dohBootstrapIps': dohBootstrapIps,
      'dohEchBootstrapIps': dohEchBootstrapIps,
      'dohAuthToken': dohAuthToken,
      'dohEchAuthToken': dohEchAuthToken,
      'serverIp': serverIp,
      'upstreamProtocol': upstreamProtocol,
      'upstreamHost': upstreamHost,
      'upstreamPort': upstreamPort,
      'upstreamUsername': upstreamUsername,
      'upstreamPassword': upstreamPassword,
      'upstreamCipher': upstreamCipher,
      'caCertPem': caCertPem,
      'caKeyPem': caKeyPem,
      'mitmConnect': mitmConnect,
      'dohRoutesUrl': dohRoutesUrl,
      'dohRouteTableJson': dohRouteTableJson,
      'dohNodeListJson': dohNodeListJson,
      'selectMode': selectMode,
      'selectStateJson': selectStateJson,
      'shareMeasurements': shareMeasurements,
      'atlasRoutesUrl': atlasRoutesUrl,
      'publicDoh': publicDoh,
      'reportUrl': reportUrl,
      'reportBearer': reportBearer,
      'extraCoveredHosts': extraCoveredHosts,
      'appVersion': appVersion,
      'networkSig': networkSig,
      'preconnectHosts': preconnectHosts,
      'preferredPort': port,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true) {
      return (result['port'] as int?) ?? -1;
    }
    final error = result is Map ? result['error']?.toString() : null;
    _lastError = 'FFI 启动失败: ${error ?? 'unknown error'}';
    NetworkLogger.log('[DOH] $_lastError');
    return -1;
  }

  Future<void> _callFfiStop() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({'cmd': 'stop', 'replyTo': response.sendPort});
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] != true) {
      if (result['error'] != null) {
        NetworkLogger.log('[DOH] FFI 停止失败: ${result['error']}');
      } else {
        NetworkLogger.log('[DOH] FFI 停止失败: unknown error');
      }
    }
  }

  Future<Map<String, dynamic>> _callFfiStatus() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({'cmd': 'status', 'replyTo': response.sendPort});
    final result = await response.first;
    response.close();
    if (result is Map<String, dynamic>) return result;
    return {'ok': false};
  }

  Future<Uint8List?> _callFfiLookupEchConfig(
    String host,
    String dohServer,
  ) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'lookup_ech',
      'host': host,
      'dohServer': dohServer,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true && result['data'] is Uint8List) {
      return result['data'] as Uint8List;
    }
    return null;
  }

  Future<List<String>> _callFfiLookupIp(
    String host,
    String dohServer, {
    required bool preferIpv6,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'lookup_ip',
      'host': host,
      'dohServer': dohServer,
      'preferIpv6': preferIpv6,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true && result['data'] is List) {
      return (result['data'] as List)
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList();
    }
    return const [];
  }

  Future<DohHostLookupResult?> _callFfiLookupHost(
    String host,
    String dohServer, {
    required String? dohServerEch,
    required bool preferIpv6,
    required bool forceRefresh,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'lookup_host',
      'host': host,
      'dohServer': dohServer,
      'dohServerEch': dohServerEch,
      'preferIpv6': preferIpv6,
      'forceRefresh': forceRefresh,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true && result['data'] is Map) {
      final data = (result['data'] as Map).cast<String, dynamic>();
      final ips = ((data['ips'] as List?) ?? const [])
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList();
      final ttlMs = (data['ttl_ms'] as num?)?.toInt() ?? 300000;
      return DohHostLookupResult(
        ips: ips,
        preferredIp: data['preferredIp']?.toString(),
        echConfig: data['echConfig'] as Uint8List?,
        ttl: Duration(milliseconds: ttlMs),
        pinned: data['pinned'] == true,
      );
    }
    return null;
  }

  Future<bool> _callFfiClearDnsCache() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({'cmd': 'clear_dns_cache', 'replyTo': response.sendPort});
    final result = await response.first;
    response.close();
    return result is Map && result['ok'] == true;
  }

  Future<DohDnsCacheStats?> _callFfiDnsCacheStats() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({'cmd': 'dns_cache_stats', 'replyTo': response.sendPort});
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true && result['data'] is Map) {
      return DohDnsCacheStats.fromJson(
        (result['data'] as Map).cast<String, dynamic>(),
      );
    }
    return null;
  }

  Future<List<DohDnsCacheRecord>?> _callFfiDnsCacheRecords() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({'cmd': 'dns_cache_records', 'replyTo': response.sendPort});
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true && result['records'] is List) {
      return (result['records'] as List)
          .whereType<Map>()
          .map(
            (record) =>
                DohDnsCacheRecord.fromJson(record.cast<String, dynamic>()),
          )
          .where((record) => record.host.isNotEmpty && record.kind.isNotEmpty)
          .toList();
    }
    return null;
  }

  Future<bool> _callFfiRecordHostSuccess(
    String host,
    String dohServer, {
    required String? dohServerEch,
    required bool preferIpv6,
    required String ip,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'record_host_success',
      'host': host,
      'dohServer': dohServer,
      'dohServerEch': dohServerEch,
      'preferIpv6': preferIpv6,
      'ip': ip,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    return result is Map && result['ok'] == true;
  }

  Future<bool> _callFfiReportHostFailure(
    String host,
    String dohServer, {
    required String? dohServerEch,
    required bool preferIpv6,
    required String ip,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'report_host_failure',
      'host': host,
      'dohServer': dohServer,
      'dohServerEch': dohServerEch,
      'preferIpv6': preferIpv6,
      'ip': ip,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    return result is Map && result['ok'] == true;
  }

  Future<bool> _callFfiClearPreferredHostIp(
    String host,
    String dohServer, {
    required String? dohServerEch,
    required bool preferIpv6,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'clear_preferred_host_ip',
      'host': host,
      'dohServer': dohServer,
      'dohServerEch': dohServerEch,
      'preferIpv6': preferIpv6,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    return result is Map && result['ok'] == true;
  }

  Future<void> _ensureFfiStopped() async {
    const timeout = Duration(seconds: 1);
    const interval = Duration(milliseconds: 50);
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      final status = await _callFfiStatus();
      final running = status['running'] as bool? ?? false;
      if (!running) return;
      await Future<void>.delayed(interval);
    }
    NetworkLogger.log('[DOH] FFI 停止超时，可能仍占用端口');
  }

  String? _buildUpstreamSignature({
    required String? protocol,
    required String? host,
    required int? port,
    required String? username,
    required String? password,
    required String? cipher,
  }) {
    if (host == null || host.isEmpty || port == null || port <= 0) {
      return null;
    }
    return jsonEncode({
      'protocol': protocol ?? 'http',
      'host': host,
      'port': port,
      'username': username ?? '',
      'password': password ?? '',
      'cipher': cipher ?? '',
    });
  }

  String _buildBootstrapSignature(
    List<String> dohBootstrapIps,
    List<String> dohEchBootstrapIps,
  ) => '${dohBootstrapIps.join(',')}|${dohEchBootstrapIps.join(',')}';

  String _buildAuthSignature(String? dohAuthToken, String? dohEchAuthToken) =>
      '${dohAuthToken ?? ''}|${dohEchAuthToken ?? ''}';

  Future<SendPort> _ensureFfiIsolate() async {
    if (_ffiSendPort != null) return _ffiSendPort!;
    final readyPort = ReceivePort();
    _ffiIsolate = await Isolate.spawn(_ffiIsolateEntry, readyPort.sendPort);
    _ffiSendPort = await readyPort.first as SendPort;
    readyPort.close();
    return _ffiSendPort!;
  }
}

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

/// 跨 isolate 传来的公共 DoH 池：每项 `{'url': String, 'bootstrap_ips': List<String>}`
List<Map<String, Object>> _publicDohList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) {
        final url = item['url']?.toString() ?? '';
        return <String, Object>{
          'url': url,
          'bootstrap_ips': _stringList(item['bootstrap_ips']),
        };
      })
      .where((item) => (item['url'] as String).isNotEmpty)
      .toList();
}

void _ffiIsolateEntry(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);

  port.listen((message) {
    if (message is! Map) return;
    final cmd = message['cmd']?.toString();
    final replyTo = message['replyTo'];
    if (replyTo is! SendPort) return;

    try {
      if (!DohProxyFfi.instance.initialize()) {
        final detail = DohProxyFfi.instance.lastInitError ?? '未知原因';
        replyTo.send({'ok': false, 'error': '无法加载原生库: $detail'});
        return;
      }

      switch (cmd) {
        case 'start':
          final portValue = message['port'] as int? ?? 0;
          final preferredPort = message['preferredPort'] as int? ?? 0;
          final enableDoh = message['enableDoh'] as bool? ?? true;
          final gatewayMode = message['gatewayMode'] as bool? ?? false;
          final h2Mitm = message['h2Mitm'] as bool? ?? false;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final dohServer = message['dohServer'] as String?;
          final dohServerEch = message['dohServerEch'] as String?;
          final dohBootstrapIps = _stringList(message['dohBootstrapIps']);
          final dohEchBootstrapIps = _stringList(message['dohEchBootstrapIps']);
          final dohAuthToken = message['dohAuthToken'] as String?;
          final dohEchAuthToken = message['dohEchAuthToken'] as String?;
          final serverIp = message['serverIp'] as String?;
          final upstreamProtocol = message['upstreamProtocol'] as String?;
          final upstreamHost = message['upstreamHost'] as String?;
          final upstreamPort = message['upstreamPort'] as int?;
          final upstreamUsername = message['upstreamUsername'] as String?;
          final upstreamPassword = message['upstreamPassword'] as String?;
          final upstreamCipher = message['upstreamCipher'] as String?;
          final caCertPem = message['caCertPem'] as String?;
          final caKeyPem = message['caKeyPem'] as String?;
          final mitmConnect = message['mitmConnect'] as bool? ?? true;
          final dohRoutesUrl = message['dohRoutesUrl'] as String?;
          final dohRouteTableJson = message['dohRouteTableJson'] as String?;
          final dohNodeListJson = message['dohNodeListJson'] as String?;
          final selectMode = message['selectMode'] as String? ?? 'off';
          final selectStateJson = message['selectStateJson'] as String?;
          final shareMeasurements =
              message['shareMeasurements'] as bool? ?? false;
          final atlasRoutesUrl = message['atlasRoutesUrl'] as String?;
          final publicDoh = _publicDohList(message['publicDoh']);
          final reportUrl = message['reportUrl'] as String?;
          final reportBearer = message['reportBearer'] as String?;
          final extraCoveredHosts = _stringList(message['extraCoveredHosts']);
          final appVersion = message['appVersion'] as String?;
          final networkSig = message['networkSig'] as String?;
          final preconnectHosts = _stringList(message['preconnectHosts']);
          var resultPort = DohProxyFfi.instance.start(
            port: portValue,
            enableDoh: enableDoh,
            gatewayMode: gatewayMode,
            preferIpv6: preferIpv6,
            dohServer: dohServer,
            dohServerEch: dohServerEch,
            dohBootstrapIps: dohBootstrapIps,
            dohEchBootstrapIps: dohEchBootstrapIps,
            dohAuthToken: dohAuthToken,
            dohEchAuthToken: dohEchAuthToken,
            serverIp: serverIp,
            upstreamProtocol: upstreamProtocol,
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort,
            upstreamUsername: upstreamUsername,
            upstreamPassword: upstreamPassword,
            upstreamCipher: upstreamCipher,
            caCertPem: caCertPem,
            caKeyPem: caKeyPem,
            mitmConnect: mitmConnect,
            h2Mitm: h2Mitm,
            dohRoutesUrl: dohRoutesUrl,
            dohRouteTableJson: dohRouteTableJson,
            dohNodeListJson: dohNodeListJson,
            selectMode: selectMode,
            selectStateJson: selectStateJson,
            shareMeasurements: shareMeasurements,
            atlasRoutesUrl: atlasRoutesUrl,
            publicDoh: publicDoh,
            reportUrl: reportUrl,
            reportBearer: reportBearer,
            extraCoveredHosts: extraCoveredHosts,
            appVersion: appVersion,
            networkSig: networkSig,
            preconnectHosts: preconnectHosts,
          );
          if (resultPort <= 0 && preferredPort != 0) {
            resultPort = DohProxyFfi.instance.start(
              port: 0,
              enableDoh: enableDoh,
              gatewayMode: gatewayMode,
              preferIpv6: preferIpv6,
              dohServer: dohServer,
              dohServerEch: dohServerEch,
              dohBootstrapIps: dohBootstrapIps,
              dohEchBootstrapIps: dohEchBootstrapIps,
              dohAuthToken: dohAuthToken,
              dohEchAuthToken: dohEchAuthToken,
              serverIp: serverIp,
              upstreamProtocol: upstreamProtocol,
              upstreamHost: upstreamHost,
              upstreamPort: upstreamPort,
              upstreamUsername: upstreamUsername,
              upstreamPassword: upstreamPassword,
              upstreamCipher: upstreamCipher,
              caCertPem: caCertPem,
              caKeyPem: caKeyPem,
              mitmConnect: mitmConnect,
              h2Mitm: h2Mitm,
              dohRoutesUrl: dohRoutesUrl,
              dohRouteTableJson: dohRouteTableJson,
              dohNodeListJson: dohNodeListJson,
              selectMode: selectMode,
              selectStateJson: selectStateJson,
              shareMeasurements: shareMeasurements,
              atlasRoutesUrl: atlasRoutesUrl,
              publicDoh: publicDoh,
              reportUrl: reportUrl,
              reportBearer: reportBearer,
              extraCoveredHosts: extraCoveredHosts,
              appVersion: appVersion,
              networkSig: networkSig,
              preconnectHosts: preconnectHosts,
            );
          }
          if (resultPort <= 0) {
            // Rust 内部只等 200ms 就检查端口，老设备可能不够
            // 在 Dart 侧延迟重试，最多再等 1 秒
            for (var i = 0; i < 5; i++) {
              sleep(const Duration(milliseconds: 200));
              if (DohProxyFfi.instance.isRunning()) {
                final runningPort = DohProxyFfi.instance.getPort();
                if (runningPort > 0) {
                  replyTo.send({'ok': true, 'port': runningPort});
                  return;
                }
              }
            }
            // 重试后仍失败，构建诊断信息
            final details = StringBuffer('Rust 代理启动返回 $resultPort');
            details.write('，端口=$portValue');
            if (dohServer != null) details.write('，DoH=$dohServer');
            details.write('，延迟重试后仍未就绪');
            replyTo.send({'ok': false, 'error': details.toString()});
          } else {
            replyTo.send({'ok': true, 'port': resultPort});
          }
          return;
        case 'stop':
          DohProxyFfi.instance.stop();
          replyTo.send({'ok': true});
          return;
        case 'status':
          final running = DohProxyFfi.instance.isRunning();
          final portValue = running ? DohProxyFfi.instance.getPort() : 0;
          replyTo.send({'ok': true, 'running': running, 'port': portValue});
          return;
        case 'lookup_ech':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final bytes = DohProxyFfi.instance.lookupEchConfig(host, dohServer);
          replyTo.send({'ok': true, 'data': bytes});
          return;
        case 'lookup_ip':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final addrs =
              DohProxyFfi.instance.lookupIp(
                host,
                dohServer,
                preferIpv6: preferIpv6,
              ) ??
              const <String>[];
          replyTo.send({'ok': true, 'data': addrs});
          return;
        case 'lookup_host':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final dohServerEch = message['dohServerEch'] as String?;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final forceRefresh = message['forceRefresh'] as bool? ?? false;
          final result = DohProxyFfi.instance.lookupHost(
            host,
            dohServer,
            dohServerEch: dohServerEch,
            preferIpv6: preferIpv6,
            forceRefresh: forceRefresh,
          );
          replyTo.send({
            'ok': true,
            'data': result == null
                ? null
                : {
                    'ips': result.ips,
                    'preferredIp': result.preferredIp,
                    'echConfig': result.echConfig,
                    'ttl_ms': result.ttl.inMilliseconds,
                    'pinned': result.pinned,
                  },
          });
          return;
        case 'generate_ca':
          final result = DohProxyFfi.instance.generateCa();
          if (result != null) {
            replyTo.send({
              'ok': true,
              'certPem': result.certPem,
              'keyPem': result.keyPem,
            });
          } else {
            replyTo.send({'ok': false, 'error': 'generate_ca failed'});
          }
          return;
        case 'clear_dns_cache':
          final ok = DohProxyFfi.instance.clearDnsCache();
          replyTo.send({'ok': ok});
          return;
        case 'take_auth_rejected':
          final rejected = DohProxyFfi.instance.takeAuthRejected();
          replyTo.send({'ok': true, 'rejected': rejected});
          return;
        case 'take_accel_update':
          final update = DohProxyFfi.instance.takeAccelUpdate();
          replyTo.send({
            'ok': true,
            'data': update == null
                ? null
                : {
                    'routeTable': update.routeTable,
                    'nodes': update.nodes,
                    'nodesEnvelopeJson': update.nodesEnvelopeJson,
                    'selectState': update.selectState,
                    'reportAuthRejected': update.reportAuthRejected,
                  },
          });
          return;
        case 'network_changed':
          final sig = message['sig'] as String? ?? '';
          final code = DohProxyFfi.instance.networkChanged(sig);
          replyTo.send({'ok': true, 'code': code});
          return;
        case 'select_status':
          final status = DohProxyFfi.instance.selectStatus();
          replyTo.send({'ok': true, 'data': status?.toJson()});
          return;
        case 'select_rerace':
          final started = DohProxyFfi.instance.reraceSelection();
          replyTo.send({'ok': true, 'started': started});
          return;
        case 'set_share_measurements':
          final enabled = message['enabled'] as bool? ?? false;
          final bearer = message['bearer'] as String?;
          final applied = DohProxyFfi.instance.setShareMeasurements(
            enabled,
            bearer,
          );
          replyTo.send({'ok': true, 'applied': applied});
          return;
        case 'accel_request':
          final method = message['method'] as String? ?? 'GET';
          final url = message['url'] as String? ?? '';
          final rawHeaders = message['headers'];
          final headers = <String, String>{
            if (rawHeaders is Map)
              for (final entry in rawHeaders.entries)
                entry.key.toString(): entry.value.toString(),
          };
          final body = message['body'] as String?;
          final result = DohProxyFfi.instance.accelRequest(
            method,
            url,
            headers,
            body,
          );
          if (result == null) {
            replyTo.send({'ok': false, 'error': 'accel_request failed'});
          } else {
            replyTo.send({
              'ok': true,
              'status': result.status,
              'body': result.body,
            });
          }
          return;
        case 'dns_cache_stats':
          final stats = DohProxyFfi.instance.dnsCacheStats();
          replyTo.send({
            'ok': true,
            'data': stats == null
                ? null
                : {
                    'resolver_count': stats.resolverCount,
                    'host_count': stats.hostCount,
                    'ip_count': stats.ipCount,
                    'ech_count': stats.echCount,
                    'ech_negative_count': stats.echNegativeCount,
                    'ip_rtt_count': stats.ipRttCount,
                    'preferred_ip_count': stats.preferredIpCount,
                    'total_entries': stats.totalEntries,
                  },
          });
          return;
        case 'dns_cache_records':
          final records = DohProxyFfi.instance.dnsCacheRecords();
          replyTo.send({
            'ok': true,
            'records': records?.map((record) => record.toJson()).toList(),
          });
          return;
        case 'record_host_success':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final dohServerEch = message['dohServerEch'] as String?;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final ip = message['ip'] as String? ?? '';
          final ok = DohProxyFfi.instance.recordHostSuccess(
            host,
            dohServer,
            dohServerEch: dohServerEch,
            preferIpv6: preferIpv6,
            ip: ip,
          );
          replyTo.send({'ok': ok});
          return;
        case 'report_host_failure':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final dohServerEch = message['dohServerEch'] as String?;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final ip = message['ip'] as String? ?? '';
          final ok = DohProxyFfi.instance.reportHostFailure(
            host,
            dohServer,
            dohServerEch: dohServerEch,
            preferIpv6: preferIpv6,
            ip: ip,
          );
          replyTo.send({'ok': ok});
          return;
        case 'clear_preferred_host_ip':
          final host = message['host'] as String? ?? '';
          final dohServer = message['dohServer'] as String? ?? '';
          final dohServerEch = message['dohServerEch'] as String?;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final ok = DohProxyFfi.instance.clearPreferredHostIp(
            host,
            dohServer,
            dohServerEch: dohServerEch,
            preferIpv6: preferIpv6,
          );
          replyTo.send({'ok': ok});
          return;
      }
      replyTo.send({'ok': false, 'error': 'unknown command'});
    } catch (e) {
      replyTo.send({'ok': false, 'error': e.toString()});
    }
  });
}

/// Backwards compatibility alias
@Deprecated('Use DohProxyService instead')
typedef EchProxyService = DohProxyService;
