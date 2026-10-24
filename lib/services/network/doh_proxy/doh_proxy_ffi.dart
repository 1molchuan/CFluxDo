import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'proxy_leaf_trust.dart';

class DohHostLookupResult {
  const DohHostLookupResult({
    required this.ips,
    required this.ttl,
    this.preferredIp,
    this.echConfig,
    this.pinned = false,
  });

  final List<String> ips;
  final String? preferredIp;
  final Uint8List? echConfig;
  final Duration ttl;

  /// Rust 把该域名钉在本地优选赢家上：[ips] 是赢家及同族兜底，按原样使用，
  /// 不要再按失败惩罚换 IP（cf_clearance 绑出口，换了就撞盾）
  final bool pinned;

  bool get hasData => ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
}

/// Rust 侧新拉到的加速路由表 / 节点列表，App 负责持久化
class DohAccelUpdate {
  const DohAccelUpdate({
    this.routeTable,
    this.nodes,
    this.nodesEnvelopeJson,
    this.selectState,
    this.reportAuthRejected = false,
  });

  /// 路由表接口的原始响应 JSON（下次启动原样回传给 Rust）
  final String? routeTable;

  /// 已验签的节点 payload JSON（`{"serial","not_after","hosts":{...}}`）
  final String? nodes;

  /// 带签名的节点信封 JSON（`{"kid","payload","sig"}`，下次启动回传给 Rust 重新验签）
  final String? nodesEnvelopeJson;

  /// 本地优选状态 JSON（赢家 + ECH 钥匙，下次启动经 `select_state_json` 回灌给 Rust）
  final String? selectState;

  /// 探针上报被 cfhub 拒绝令牌（401/403），App 需要重新取令牌或关掉「帮助优选」
  final bool reportAuthRejected;

  bool get isEmpty =>
      routeTable == null &&
      nodes == null &&
      nodesEnvelopeJson == null &&
      selectState == null &&
      !reportAuthRejected;
}

/// 单个公共 DoH 端点的答案计数（Rust 侧优选启动后累计）：诊断国内解析器投毒用，
/// 只有厂商名、端点地址和次数
class DohPublicDohStat {
  const DohPublicDohStat({
    required this.vendor,
    required this.host,
    this.accepted = 0,
    this.rejected = 0,
    this.negative = 0,
  });

  /// 厂商名（如 `DNSPod`）
  final String vendor;

  /// 端点地址（URL 里的主机，内置端点都是 IP 字面量）
  final String host;

  /// 通过 CF 网段检查、被采用的答案
  final int accepted;

  /// 投毒答案（地址不全在 CF 网段）
  final int rejected;

  /// 正常响应但没有要的记录
  final int negative;

  /// 诊断用的短标签：`厂商@地址`
  String get label => '$vendor@$host';

  bool get isEmpty => accepted == 0 && rejected == 0 && negative == 0;

  /// 旧版原生库没有这个字段、或字段形状不对时返回空列表
  static List<DohPublicDohStat> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <DohPublicDohStat>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final vendor = item['vendor']?.toString() ?? '';
      final host = item['host']?.toString() ?? '';
      if (vendor.isEmpty && host.isEmpty) continue;
      out.add(
        DohPublicDohStat(
          vendor: vendor,
          host: host,
          accepted: (item['accepted'] as num?)?.toInt() ?? 0,
          rejected: (item['rejected'] as num?)?.toInt() ?? 0,
          negative: (item['negative'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'vendor': vendor,
    'host': host,
    'accepted': accepted,
    'rejected': rejected,
    'negative': negative,
  };

  /// 一行摘要：`厂商@地址 通过/投毒/空`
  String get summary => '$label $accepted/$rejected/$negative';
}

/// 本地动态优选的运行状态（`doh_proxy_select_status` 的解析结果）
class DohSelectStatus {
  const DohSelectStatus({
    required this.mode,
    required this.phase,
    this.winnerIp,
    this.latencyMs,
    this.verifiedAt,
    this.source,
    this.echSource,
    this.lastRaceAt = 0,
    this.lastError,
    this.failStreak = 0,
    this.share = false,
    this.publicDoh = const [],
  });

  /// 优选模式（如 `off` / `local_atlas`）
  final String mode;

  /// 阶段：`idle` / `verifying` / `racing` / `ready` / `failed`
  final String phase;

  /// 当前赢家 IP，没有赢家时为 null
  final String? winnerIp;

  /// 赢家握手延迟（毫秒）
  final int? latencyMs;

  /// 赢家最近一次验证通过的 Unix 秒
  final int? verifiedAt;

  /// 赢家候选来源（如 `vendor` / `atlas` / `random`）
  final String? source;

  /// 赢家所用 ECH 钥匙来源
  final String? echSource;

  /// 最近一次竞速的 Unix 秒，没跑过为 0
  final int lastRaceAt;

  /// 最近一次失败原因
  final String? lastError;

  /// 连续失败次数
  final int failStreak;

  /// 是否开启「帮助优选」（分享测量结果给 cfhub）
  final bool share;

  /// 各公共 DoH 端点的答案计数（旧版原生库没有，为空）
  final List<DohPublicDohStat> publicDoh;

  /// 有过答案的端点（诊断导出只列这些）
  List<DohPublicDohStat> get activePublicDoh =>
      publicDoh.where((stat) => !stat.isEmpty).toList(growable: false);

  bool get hasWinner => winnerIp != null && phase == 'ready';

  factory DohSelectStatus.fromJson(Map<String, dynamic> map) {
    final winner = map['winner'];
    final winnerMap = winner is Map ? winner : null;
    final winnerIp = winnerMap?['ip']?.toString();
    final lastError = map['last_error'];
    return DohSelectStatus(
      mode: map['mode']?.toString() ?? 'off',
      phase: map['phase']?.toString() ?? 'idle',
      winnerIp: winnerIp != null && winnerIp.isNotEmpty ? winnerIp : null,
      latencyMs: (winnerMap?['latency_ms'] as num?)?.toInt(),
      verifiedAt: (winnerMap?['verified_at'] as num?)?.toInt(),
      source: winnerMap?['source']?.toString(),
      echSource: winnerMap?['ech_source']?.toString(),
      lastRaceAt: (map['last_race_at'] as num?)?.toInt() ?? 0,
      lastError: lastError is String && lastError.isNotEmpty ? lastError : null,
      failStreak: (map['fail_streak'] as num?)?.toInt() ?? 0,
      share: map['share'] == true,
      publicDoh: DohPublicDohStat.listFromJson(map['public_doh']),
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'phase': phase,
    'winner': winnerIp == null
        ? null
        : {
            'ip': winnerIp,
            'latency_ms': latencyMs,
            'verified_at': verifiedAt,
            'source': source,
            'ech_source': echSource,
          },
    'last_race_at': lastRaceAt,
    'last_error': lastError,
    'fail_streak': failStreak,
    'share': share,
    'public_doh': [for (final stat in publicDoh) stat.toJson()],
  };
}

class DohDnsCacheStats {
  const DohDnsCacheStats({
    required this.resolverCount,
    required this.hostCount,
    required this.ipCount,
    required this.echCount,
    required this.echNegativeCount,
    required this.ipRttCount,
    required this.preferredIpCount,
    required this.totalEntries,
    this.dartEntryCount = 0,
  });

  const DohDnsCacheStats.empty()
    : resolverCount = 0,
      hostCount = 0,
      ipCount = 0,
      echCount = 0,
      echNegativeCount = 0,
      ipRttCount = 0,
      preferredIpCount = 0,
      totalEntries = 0,
      dartEntryCount = 0;

  final int resolverCount;
  final int hostCount;
  final int ipCount;
  final int echCount;
  final int echNegativeCount;
  final int ipRttCount;
  final int preferredIpCount;
  final int totalEntries;
  final int dartEntryCount;

  int get rustVisibleHostEntries {
    final fallbackCount = ipCount + echCount + echNegativeCount;
    return hostCount > 0 ? hostCount : fallbackCount;
  }

  int get visibleHostEntries => rustVisibleHostEntries > dartEntryCount
      ? rustVisibleHostEntries
      : dartEntryCount;

  DohDnsCacheStats copyWith({
    int? resolverCount,
    int? hostCount,
    int? ipCount,
    int? echCount,
    int? echNegativeCount,
    int? ipRttCount,
    int? preferredIpCount,
    int? totalEntries,
    int? dartEntryCount,
  }) {
    return DohDnsCacheStats(
      resolverCount: resolverCount ?? this.resolverCount,
      hostCount: hostCount ?? this.hostCount,
      ipCount: ipCount ?? this.ipCount,
      echCount: echCount ?? this.echCount,
      echNegativeCount: echNegativeCount ?? this.echNegativeCount,
      ipRttCount: ipRttCount ?? this.ipRttCount,
      preferredIpCount: preferredIpCount ?? this.preferredIpCount,
      totalEntries: totalEntries ?? this.totalEntries,
      dartEntryCount: dartEntryCount ?? this.dartEntryCount,
    );
  }

  factory DohDnsCacheStats.fromJson(Map<String, dynamic> json) {
    return DohDnsCacheStats(
      resolverCount: (json['resolver_count'] as num?)?.toInt() ?? 0,
      hostCount: (json['host_count'] as num?)?.toInt() ?? 0,
      ipCount: (json['ip_count'] as num?)?.toInt() ?? 0,
      echCount: (json['ech_count'] as num?)?.toInt() ?? 0,
      echNegativeCount: (json['ech_negative_count'] as num?)?.toInt() ?? 0,
      ipRttCount: (json['ip_rtt_count'] as num?)?.toInt() ?? 0,
      preferredIpCount: (json['preferred_ip_count'] as num?)?.toInt() ?? 0,
      totalEntries: (json['total_entries'] as num?)?.toInt() ?? 0,
    );
  }
}

class DohDnsCacheRecord {
  const DohDnsCacheRecord({
    required this.host,
    required this.kind,
    required this.values,
    required this.ttl,
  });

  final String host;
  final String kind;
  final List<String> values;
  final Duration ttl;

  factory DohDnsCacheRecord.fromJson(Map<String, dynamic> json) {
    final values = json['values'];
    return DohDnsCacheRecord(
      host: json['host']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      values: values is List
          ? values
                .map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toList()
          : const [],
      ttl: Duration(milliseconds: (json['ttl_ms'] as num?)?.toInt() ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'kind': kind,
    'values': values,
    'ttl_ms': ttl.inMilliseconds,
  };
}

/// DOH Proxy FFI bindings
///
/// This provides direct FFI bindings to the Rust DOH proxy library
/// for Android and iOS platforms.
class DohProxyFfi {
  DohProxyFfi._();
  static final DohProxyFfi instance = DohProxyFfi._();

  DynamicLibrary? _lib;
  bool _initialized = false;

  // FFI function types（使用 late 而非 late final，允许重新初始化）
  late int Function(Pointer<Utf8> configJson) _dohProxyStartWithConfigJson;
  late void Function() _dohProxyStop;
  late int Function() _dohProxyIsRunning;
  late int Function() _dohProxyGetPort;
  late void Function() _dohProxyInitLogging;
  late Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)
  _dohProxyLookupEchConfig;
  late Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
  _dohProxyLookupIp;
  late Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    int,
  )
  _dohProxyLookupHost;
  late int Function() _dohProxyClearDnsCache;
  late int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
  )
  _dohProxyRecordHostSuccess;
  late int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
  _dohProxyClearPreferredHostIp;
  // 带 IP 的连接失败回报（计入赢家连败），旧版本库没有时回退到清粘性 IP
  int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>)?
  _dohProxyReportHostFailure;
  Pointer<Utf8> Function()? _dohProxyDnsCacheStats;
  // 网络引擎计数（只读原子量，不阻塞），旧版本库没有
  Pointer<Utf8> Function()? _dohProxyNetStats;
  Pointer<Utf8> Function()? _dohProxyDnsCacheRecords;
  Pointer<Utf8> Function()? _dohProxyGenerateCa;
  Pointer<Utf8> Function()? _dohProxyGetEmbeddedCaPem;
  int Function()? _dohProxyTakeAuthRejected;
  Pointer<Utf8> Function()? _dohProxyTakeAccelUpdate;
  Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)?
  _dohProxyAccelRequest;
  // 本地动态优选：网络变化通知 / 状态查询 / 手动重选 / 开关「帮助优选」，均为可选符号
  int Function(Pointer<Utf8>)? _dohProxyNetworkChanged;
  Pointer<Utf8> Function()? _dohProxySelectStatus;
  int Function()? _dohProxySelectRerace;
  int Function(int, Pointer<Utf8>)? _dohProxySetShareMeasurements;
  // Linux：取代理为某主机签发的 MITM 叶子证书，给 WPE 逐主机精确放行；可选符号
  Pointer<Utf8> Function(Pointer<Utf8>)? _dohProxyMitmLeafPem;
  late void Function(Pointer<Utf8>) _dohProxyFreeString;

  /// Initialize FFI bindings
  bool initialize() {
    if (_initialized) return true;

    try {
      _lib = _loadLibrary();
      if (_lib == null) return false;

      // Load function pointers
      _dohProxyStartWithConfigJson = _lib!
          .lookup<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
            'doh_proxy_start_with_config_json',
          )
          .asFunction();

      _dohProxyStop = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_stop')
          .asFunction();

      _dohProxyIsRunning = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_is_running')
          .asFunction();

      _dohProxyGetPort = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_get_port')
          .asFunction();

      _dohProxyInitLogging = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_init_logging')
          .asFunction();

      _dohProxyLookupEchConfig = _lib!
          .lookup<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('doh_proxy_lookup_ech_config')
          .asFunction();

      _dohProxyLookupIp = _lib!
          .lookup<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Int32)
            >
          >('doh_proxy_lookup_ip')
          .asFunction();

      _dohProxyLookupHost = _lib!
          .lookup<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Int32,
                Int32,
              )
            >
          >('doh_proxy_lookup_host')
          .asFunction();

      _dohProxyClearDnsCache = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_clear_dns_cache')
          .asFunction();

      _dohProxyRecordHostSuccess = _lib!
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Int32,
                Pointer<Utf8>,
              )
            >
          >('doh_proxy_record_host_success')
          .asFunction();

      _dohProxyClearPreferredHostIp = _lib!
          .lookup<
            NativeFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32)
            >
          >('doh_proxy_clear_preferred_host_ip')
          .asFunction();

      try {
        _dohProxyReportHostFailure = _lib!
            .lookup<
              NativeFunction<
                Int32 Function(
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Int32,
                  Pointer<Utf8>,
                )
              >
            >('doh_proxy_report_host_failure')
            .asFunction();
      } catch (_) {
        _dohProxyReportHostFailure = null;
      }

      try {
        _dohProxyDnsCacheStats = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_dns_cache_stats',
            )
            .asFunction();
      } catch (_) {
        _dohProxyDnsCacheStats = null;
      }

      try {
        _dohProxyNetStats = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_net_stats',
            )
            .asFunction();
      } catch (_) {
        _dohProxyNetStats = null;
      }

      try {
        _dohProxyDnsCacheRecords = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_dns_cache_records',
            )
            .asFunction();
      } catch (_) {
        _dohProxyDnsCacheRecords = null;
      }

      try {
        _dohProxyTakeAuthRejected = _lib!
            .lookup<NativeFunction<Int32 Function()>>(
              'doh_proxy_take_auth_rejected',
            )
            .asFunction();
      } catch (_) {
        _dohProxyTakeAuthRejected = null;
      }

      // 加速路由表 / 节点列表更新取回、经 Rust 客户端发加速 HTTP 请求：新增符号，可选绑定
      try {
        _dohProxyTakeAccelUpdate = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_take_accel_update',
            )
            .asFunction();
      } catch (_) {
        _dohProxyTakeAccelUpdate = null;
      }

      try {
        _dohProxyAccelRequest = _lib!
            .lookup<
              NativeFunction<
                Pointer<Utf8> Function(
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                )
              >
            >('doh_proxy_accel_request')
            .asFunction();
      } catch (_) {
        _dohProxyAccelRequest = null;
      }

      // 本地动态优选相关符号：旧版本库没有，缺失时置 null，调用方按无操作处理
      try {
        _dohProxyNetworkChanged = _lib!
            .lookup<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
              'doh_proxy_network_changed',
            )
            .asFunction();
      } catch (_) {
        _dohProxyNetworkChanged = null;
      }

      try {
        _dohProxyMitmLeafPem = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>)>>(
              'doh_proxy_mitm_leaf_pem',
            )
            .asFunction();
      } catch (_) {
        _dohProxyMitmLeafPem = null;
      }

      try {
        _dohProxySelectStatus = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_select_status',
            )
            .asFunction();
      } catch (_) {
        _dohProxySelectStatus = null;
      }

      try {
        _dohProxySelectRerace = _lib!
            .lookup<NativeFunction<Int32 Function()>>(
              'doh_proxy_select_rerace',
            )
            .asFunction();
      } catch (_) {
        _dohProxySelectRerace = null;
      }

      try {
        _dohProxySetShareMeasurements = _lib!
            .lookup<NativeFunction<Int32 Function(Int32, Pointer<Utf8>)>>(
              'doh_proxy_set_share_measurements',
            )
            .asFunction();
      } catch (_) {
        _dohProxySetShareMeasurements = null;
      }

      // doh_proxy_generate_ca 是新增符号，旧版本库可能没有，可选绑定
      try {
        _dohProxyGenerateCa = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_generate_ca',
            )
            .asFunction();
      } catch (_) {
        _dohProxyGenerateCa = null;
        debugPrint('[DOH FFI] doh_proxy_generate_ca 未找到，per-device CA 不可用');
      }

      // doh_proxy_get_embedded_ca_pem 是新增符号，可选绑定
      try {
        _dohProxyGetEmbeddedCaPem = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_get_embedded_ca_pem',
            )
            .asFunction();
      } catch (_) {
        _dohProxyGetEmbeddedCaPem = null;
      }

      _dohProxyFreeString = _lib!
          .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
            'doh_proxy_free_string',
          )
          .asFunction();

      _initialized = true;
      return true;
    } catch (e) {
      lastInitError = '初始化 FFI 绑定失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
      return false;
    }
  }

  DynamicLibrary? _loadLibrary() {
    try {
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libdoh_proxy.so');
      } else if (Platform.isIOS) {
        // iOS uses static linking, so we use the process itself
        return DynamicLibrary.process();
      } else if (Platform.isWindows) {
        return _loadWindowsLibrary();
      } else if (Platform.isMacOS) {
        return _loadMacOSLibrary();
      } else if (Platform.isLinux) {
        return _loadLinuxLibrary();
      }
    } catch (e) {
      lastInitError = '加载原生库失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
    }
    return null;
  }

  /// Linux bundle 把库装在 `<可执行文件目录>/lib/`；按绝对路径打开，
  /// 不依赖 dlopen 调用方（libflutter）的 RUNPATH
  DynamicLibrary _loadLinuxLibrary() {
    const libName = 'libdoh_proxy.so';
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$execDir/lib/$libName';
    if (File(bundled).existsSync()) {
      return DynamicLibrary.open(bundled);
    }
    return DynamicLibrary.open(libName);
  }

  DynamicLibrary? _loadWindowsLibrary() {
    const libName = 'doh_proxy.dll';
    final execPath = Platform.resolvedExecutable;
    final execDir = File(execPath).parent.path;
    final projectRoot = _projectRootFromBuildPath(execPath);
    final candidates = <String>[
      '$execDir/native/$libName',
      if (projectRoot != null) '$projectRoot/windows/runner/native/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/release/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/debug/$libName',
      '${Directory.current.path}/windows/runner/native/$libName',
      '${Directory.current.path}/core/doh_proxy/target/release/$libName',
      '${Directory.current.path}/core/doh_proxy/target/debug/$libName',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        debugPrint('[DOH FFI] 加载 Windows 库: $path');
        return DynamicLibrary.open(path);
      }
    }

    return DynamicLibrary.open(libName);
  }

  DynamicLibrary? _loadMacOSLibrary() {
    const libName = 'libdoh_proxy.dylib';
    final execPath = Platform.resolvedExecutable;
    final execDir = File(execPath).parent.path;
    final projectRoot = _projectRootFromBuildPath(execPath);
    final candidates = <String>[
      '$execDir/../Frameworks/$libName',
      '$execDir/../Resources/native/$libName',
      if (projectRoot != null) '$projectRoot/macos/Runner/native/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/release/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/debug/$libName',
      '${Directory.current.path}/macos/Runner/native/$libName',
      '${Directory.current.path}/core/doh_proxy/target/release/$libName',
      '${Directory.current.path}/core/doh_proxy/target/debug/$libName',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        debugPrint('[DOH FFI] 加载 macOS 库: $path');
        return DynamicLibrary.open(path);
      }
    }
    // 最后尝试系统搜索路径
    return DynamicLibrary.open(libName);
  }

  String? _projectRootFromBuildPath(String execPath) {
    final normalized = execPath.replaceAll('\\', '/');
    final buildIndex = normalized.indexOf('/build/');
    if (buildIndex <= 0) {
      return null;
    }
    return normalized.substring(0, buildIndex);
  }

  /// 最近一次初始化失败的原因
  String? lastInitError;

  /// Start the DOH proxy server
  /// Returns the port number on success, or -1 on failure
  ///
  /// [port] - Port to bind (0 for auto-select)
  /// [preferIpv6] - Whether to prefer IPv6 addresses
  /// [dohServer] - DOH server URL (null for default Cloudflare)
  int start({
    int port = 0,
    bool enableDoh = true,
    bool preferIpv6 = false,
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
    List<String> mitmHosts = const [],
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
  }) {
    if (!_initialized && !initialize()) {
      return -1;
    }

    final configJson = jsonEncode({
      'bind_addr': '127.0.0.1',
      'bind_port': port,
      'enable_doh': enableDoh,
      'gateway_mode': gatewayMode,
      'mitm_connect': mitmConnect,
      'h2_mitm': h2Mitm,
      // 空 = 除 CF 验证域名外全部 MITM；Linux 的 WPE 只能逐主机放行叶子证书，
      // 只 MITM 必须走 ECH 的主机（见 ProxyLeafTrust）
      if (mitmHosts.isNotEmpty)
        'mitm_hosts': mitmHosts
      else if (Platform.isLinux || Platform.isWindows)
        'mitm_hosts': ProxyLeafTrust.mitmHosts,
      'doh_server': dohServer ?? 'cloudflare',
      'prefer_ipv6': preferIpv6,
      'timeout_secs': 30,
      if (dohServerEch != null && dohServerEch.isNotEmpty)
        'doh_server_ech': dohServerEch,
      if (dohBootstrapIps.isNotEmpty) 'doh_bootstrap_ips': dohBootstrapIps,
      if (dohEchBootstrapIps.isNotEmpty)
        'doh_ech_bootstrap_ips': dohEchBootstrapIps,
      if (dohAuthToken != null && dohAuthToken.isNotEmpty)
        'doh_auth_token': dohAuthToken,
      if (dohEchAuthToken != null && dohEchAuthToken.isNotEmpty)
        'doh_ech_auth_token': dohEchAuthToken,
      if (serverIp != null && serverIp.isNotEmpty) 'server_ip': serverIp,
      if (upstreamHost != null &&
          upstreamHost.isNotEmpty &&
          upstreamPort != null &&
          upstreamPort > 0)
        'upstream_proxy': {
          'protocol': upstreamProtocol ?? 'http',
          'host': upstreamHost,
          'port': upstreamPort,
          if (upstreamCipher != null && upstreamCipher.isNotEmpty)
            'cipher': upstreamCipher,
          if (upstreamUsername != null && upstreamUsername.isNotEmpty)
            'username': upstreamUsername,
          if (upstreamPassword != null && upstreamPassword.isNotEmpty)
            'password': upstreamPassword,
        },
      if (caCertPem != null && caCertPem.isNotEmpty) 'ca_cert_pem': caCertPem,
      if (caKeyPem != null && caKeyPem.isNotEmpty) 'ca_key_pem': caKeyPem,
      // 加速查表模式：路由表接口地址，以及上次持久化的表 / 签名节点列表（启动即可用）
      if (dohRoutesUrl != null && dohRoutesUrl.isNotEmpty)
        'doh_routes_url': dohRoutesUrl,
      if (dohRouteTableJson != null && dohRouteTableJson.isNotEmpty)
        'doh_route_table_json': dohRouteTableJson,
      if (dohNodeListJson != null && dohNodeListJson.isNotEmpty)
        'doh_node_list_json': dohNodeListJson,
      // 本地动态优选：模式总是写；上次落盘的状态 / atlas 查表地址 / 公共 DoH 池 /
      // 探针上报地址与令牌 / 额外覆盖域名 / App 版本 / 网络签名，空值不写键
      'select_mode': selectMode,
      if (selectStateJson != null && selectStateJson.isNotEmpty)
        'select_state_json': selectStateJson,
      'share_measurements': shareMeasurements,
      if (atlasRoutesUrl != null && atlasRoutesUrl.isNotEmpty)
        'atlas_routes_url': atlasRoutesUrl,
      if (publicDoh.isNotEmpty) 'public_doh': publicDoh,
      if (reportUrl != null && reportUrl.isNotEmpty) 'report_url': reportUrl,
      if (reportBearer != null && reportBearer.isNotEmpty)
        'report_bearer': reportBearer,
      if (extraCoveredHosts.isNotEmpty) 'extra_covered_hosts': extraCoveredHosts,
      if (appVersion != null && appVersion.isNotEmpty) 'app_version': appVersion,
      if (networkSig != null && networkSig.isNotEmpty) 'network_sig': networkSig,
      if (preconnectHosts.isNotEmpty) 'preconnect_hosts': preconnectHosts,
    });
    final configPtr = configJson.toNativeUtf8();
    try {
      return _dohProxyStartWithConfigJson(configPtr);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// 生成新的 CA 证书，返回 (certPem, keyPem)，失败返回 null
  ({String certPem, String keyPem})? generateCa() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyGenerateCa;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true &&
        map['cert_pem'] is String &&
        map['key_pem'] is String) {
      return (
        certPem: map['cert_pem'] as String,
        keyPem: map['key_pem'] as String,
      );
    }
    debugPrint('[DOH FFI] generateCa: ${map['error'] ?? 'unknown error'}');
    return null;
  }

  /// 获取编译时嵌入的 CA 证书 PEM
  ///
  /// 返回 Rust 库中通过 include_str! 嵌入的 CA PEM，保证和代理实际使用的 CA 一致
  String? getEmbeddedCaPem() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyGetEmbeddedCaPem;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final pem = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);
    return pem;
  }

  /// Lookup ECH config for a host via DOH DNS HTTPS record.
  /// Returns raw ECH config bytes, or null if not available.
  Uint8List? lookupEchConfig(String host, String dohServer) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    try {
      final resultPtr = _dohProxyLookupEchConfig(hostPtr, dohPtr);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true && map['data'] is String) {
        return base64Decode(map['data'] as String);
      }
      debugPrint('[DOH FFI] ECH lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
    }
  }

  /// Lookup IP addresses for a host via DOH A/AAAA records.
  /// Returns ordered IP strings, or null on failure.
  List<String>? lookupIp(
    String host,
    String dohServer, {
    bool preferIpv6 = false,
  }) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    try {
      final resultPtr = _dohProxyLookupIp(hostPtr, dohPtr, preferIpv6 ? 1 : 0);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true && map['data'] is List) {
        return (map['data'] as List)
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList();
      }
      debugPrint('[DOH FFI] IP lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
    }
  }

  DohHostLookupResult? lookupHost(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    bool forceRefresh = false,
  }) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    try {
      final resultPtr = _dohProxyLookupHost(
        hostPtr,
        dohPtr,
        echPtr,
        preferIpv6 ? 1 : 0,
        forceRefresh ? 1 : 0,
      );
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true) {
        final ips = ((map['ips'] as List?) ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList();
        final ttlSecs = (map['ttl_secs'] as num?)?.toInt() ?? 300;
        final echBase64 = map['ech']?.toString();
        return DohHostLookupResult(
          ips: ips,
          preferredIp: map['preferred_ip']?.toString(),
          echConfig: echBase64 != null && echBase64.isNotEmpty
              ? base64Decode(echBase64)
              : null,
          ttl: Duration(seconds: ttlSecs),
          pinned: map['pinned'] == true,
        );
      }
      debugPrint('[DOH FFI] Host lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  bool clearDnsCache() {
    if (!_initialized && !initialize()) return false;
    return _dohProxyClearDnsCache() != 0;
  }

  /// 取出并清除「DoH 服务器拒绝了令牌」标记，true 表示需要重新申请令牌
  bool takeAuthRejected() {
    if (!_initialized && !initialize()) return false;
    final fn = _dohProxyTakeAuthRejected;
    if (fn == null) return false;
    return fn() != 0;
  }

  /// 取出 Rust 侧新拉到的加速路由表 / 节点列表（取出即清）
  ///
  /// [routeTable] 是服务端原始响应 JSON；[nodes] 是已验签的节点 payload JSON；
  /// [nodesEnvelopeJson] 是带签名的信封，持久化后下次启动原样回传给 Rust 重新验签。
  /// 库不支持或没有更新时返回 null。
  DohAccelUpdate? takeAccelUpdate() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyTakeAccelUpdate;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] != true) {
      debugPrint('[DOH FFI] takeAccelUpdate: ${map['error'] ?? 'unknown error'}');
      return null;
    }
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
  }

  /// 通知 Rust 侧网络环境变了（[sig] 为连接类型集合签名，如 `wifi` / `mobile|wifi`）
  ///
  /// 返回 Rust 的原始返回值：1 受理、0 没有优选实例、-1 参数错；库不支持返回 -1
  int networkChanged(String sig) {
    if (!_initialized && !initialize()) return -1;
    final fn = _dohProxyNetworkChanged;
    if (fn == null) return -1;

    final sigPtr = sig.toNativeUtf8();
    try {
      return fn(sigPtr);
    } finally {
      calloc.free(sigPtr);
    }
  }

  /// 当前代理为 [host] 签发的 MITM 叶子证书 PEM；代理没在跑、库不支持或出错返回 null。
  /// 代理每次重启叶子都会换，调用方要在重启后重新取
  String? mitmLeafPem(String host) {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyMitmLeafPem;
    if (fn == null) return null;

    final hostPtr = host.toNativeUtf8();
    try {
      final resultPtr = fn(hostPtr);
      if (resultPtr == nullptr) return null;
      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        debugPrint('[DOH FFI] mitmLeafPem($host): ${decoded is Map ? decoded['error'] : decoded}');
        return null;
      }
      return decoded['pem'] as String?;
    } finally {
      calloc.free(hostPtr);
    }
  }

  /// 查询本地动态优选状态；库不支持、没有优选实例或解析失败返回 null
  DohSelectStatus? selectStatus() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxySelectStatus;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['ok'] != true) {
      debugPrint('[DOH FFI] selectStatus: ${decoded['error'] ?? 'unknown error'}');
      return null;
    }
    return DohSelectStatus.fromJson(decoded);
  }

  /// 手动触发重新优选；true 表示已发车，false 表示冷却中 / 没有实例 / 库不支持
  bool reraceSelection() {
    if (!_initialized && !initialize()) return false;
    final fn = _dohProxySelectRerace;
    if (fn == null) return false;
    return fn() == 1;
  }

  /// 开关「帮助优选」（把握手测量结果分享给 cfhub）
  ///
  /// [bearer] 为 cfhub 令牌，关闭时可为 null；令牌只传给 Rust，绝不进日志。
  /// true 表示已应用，false 表示没有优选实例 / 库不支持
  bool setShareMeasurements(bool enabled, String? bearer) {
    if (!_initialized && !initialize()) return false;
    final fn = _dohProxySetShareMeasurements;
    if (fn == null) return false;

    final hasBearer = bearer != null && bearer.isNotEmpty;
    final bearerPtr = hasBearer ? bearer.toNativeUtf8() : nullptr.cast<Utf8>();
    try {
      return fn(enabled ? 1 : 0, bearerPtr) == 1;
    } finally {
      if (hasBearer) {
        calloc.free(bearerPtr);
      }
    }
  }

  /// 经 Rust 的 DoH 客户端（同一套 TLS 栈）向加速服务端发 HTTP 请求
  ///
  /// 返回 (status, body)；库不支持或请求失败（连不上、超时）返回 null。
  /// 非 2xx 状态不算失败，由调用方按 status 处理。
  ({int status, String body})? accelRequest(
    String method,
    String url,
    Map<String, String> headers,
    String? body,
  ) {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyAccelRequest;
    if (fn == null) return null;

    final methodPtr = method.toNativeUtf8();
    final urlPtr = url.toNativeUtf8();
    final headersPtr = jsonEncode(headers).toNativeUtf8();
    final hasBody = body != null;
    final bodyPtr = hasBody ? body.toNativeUtf8() : nullptr.cast<Utf8>();
    try {
      final resultPtr = fn(methodPtr, urlPtr, headersPtr, bodyPtr);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true && map['status'] is num) {
        return (
          status: (map['status'] as num).toInt(),
          body: map['body']?.toString() ?? '',
        );
      }
      debugPrint('[DOH FFI] accelRequest: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(methodPtr);
      calloc.free(urlPtr);
      calloc.free(headersPtr);
      if (hasBody) {
        calloc.free(bodyPtr);
      }
    }
  }

  /// 网络引擎计数（建连、握手、网关转发、解析等待，进程级累计）；库不支持返回 null。
  /// 只读原子量、不阻塞，可以在主 isolate 直接调
  Map<String, dynamic>? netStats() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyNetStats;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return null;
    final stats = decoded['stats'];
    return stats is Map<String, dynamic> ? stats : null;
  }

  DohDnsCacheStats? dnsCacheStats() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyDnsCacheStats;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true) {
      return DohDnsCacheStats.fromJson(map);
    }
    debugPrint('[DOH FFI] DNS cache stats: ${map['error'] ?? 'unknown error'}');
    return null;
  }

  List<DohDnsCacheRecord>? dnsCacheRecords() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyDnsCacheRecords;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true && map['records'] is List) {
      return (map['records'] as List)
          .whereType<Map>()
          .map(
            (record) =>
                DohDnsCacheRecord.fromJson(record.cast<String, dynamic>()),
          )
          .where((record) => record.host.isNotEmpty && record.kind.isNotEmpty)
          .toList();
    }
    debugPrint(
      '[DOH FFI] DNS cache records: ${map['error'] ?? 'unknown error'}',
    );
    return null;
  }

  bool recordHostSuccess(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    required String ip,
  }) {
    if (!_initialized && !initialize()) return false;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    final ipPtr = ip.toNativeUtf8();
    try {
      return _dohProxyRecordHostSuccess(
            hostPtr,
            dohPtr,
            echPtr,
            preferIpv6 ? 1 : 0,
            ipPtr,
          ) !=
          0;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      calloc.free(ipPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  /// 报告连 [host] -> [ip] 失败：Rust 作废该域名的粘性 IP，[ip] 是钉住的赢家时计入它的连败。
  /// 旧版本库没有该符号时退化为 [clearPreferredHostIp]
  bool reportHostFailure(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    required String ip,
  }) {
    if (!_initialized && !initialize()) return false;
    final report = _dohProxyReportHostFailure;
    if (report == null) {
      return clearPreferredHostIp(
        host,
        dohServer,
        dohServerEch: dohServerEch,
        preferIpv6: preferIpv6,
      );
    }

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    final ipPtr = ip.toNativeUtf8();
    try {
      return report(hostPtr, dohPtr, echPtr, preferIpv6 ? 1 : 0, ipPtr) != 0;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      calloc.free(ipPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  bool clearPreferredHostIp(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
  }) {
    if (!_initialized && !initialize()) return false;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    try {
      return _dohProxyClearPreferredHostIp(
            hostPtr,
            dohPtr,
            echPtr,
            preferIpv6 ? 1 : 0,
          ) !=
          0;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  /// Stop the DOH proxy server
  void stop() {
    if (!_initialized) return;
    _dohProxyStop();
  }

  /// Check if the DOH proxy is running
  bool isRunning() {
    if (!_initialized) return false;
    return _dohProxyIsRunning() != 0;
  }

  /// Get the DOH proxy port
  int getPort() {
    if (!_initialized) return 0;
    return _dohProxyGetPort();
  }

  /// Initialize logging
  void initLogging() {
    if (!_initialized && !initialize()) return;
    _dohProxyInitLogging();
  }

  /// Check if FFI is available on this platform
  static bool get isAvailable {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  /// 桌面平台 FFI 失败时可以回退到进程模式
  static bool get canFallbackToProcess {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }
}

/// Backwards compatibility alias
@Deprecated('Use DohProxyFfi instead')
typedef EchProxyFfi = DohProxyFfi;
