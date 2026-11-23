import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// 检测操作系统层面的"系统代理"设置（区别于 VPN 虚拟网卡）。
///
/// Windows 下系统代理（设置里手动配的 HTTP 代理，或 Clash/V2rayN 等工具的
/// "设置为系统代理"模式，均不建虚拟网卡）写在
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`：
/// `ProxyEnable`（DWORD，1 表示已启用）+ `ProxyServer`（字符串），
/// 或 `AutoConfigURL`（PAC 自动代理脚本）。
/// 这是 WinINet/WinHTTP 系统代理的标准存放位置，IE/Edge/大多数拿系统代理
/// 的工具均读写这里。
///
/// 安卓走原生通道读 `ConnectivityManager.getDefaultProxy()`（异步，见
/// [SystemProxyService]），解析在 [SystemProxyDetector.parseAndroid]。
/// 系统代理注册表配置快照。
class SystemProxyConfig {
  const SystemProxyConfig({this.proxyUrl, this.pacUrl});

  /// 解析出的固定代理地址（`http://host:port` / `socks5://host:port`）。
  /// 注册表未启用固定代理时为 null。
  final String? proxyUrl;

  /// PAC 脚本地址。PAC 无法在 Dart 侧求值，只用于「系统代理已启用」判定。
  final String? pacUrl;

  bool get isEnabled => proxyUrl != null || (pacUrl?.isNotEmpty ?? false);

  @override
  bool operator ==(Object other) =>
      other is SystemProxyConfig &&
      other.proxyUrl == proxyUrl &&
      other.pacUrl == pacUrl;

  @override
  int get hashCode => Object.hash(proxyUrl, pacUrl);
}

class SystemProxyDetector {
  const SystemProxyDetector._();

  static const _keyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// 当前系统代理是否已启用。
  static bool isEnabled() => read().isEnabled;

  /// 读取系统代理完整配置。非 Windows 平台恒返回空配置。
  static SystemProxyConfig read() {
    if (!Platform.isWindows) return const SystemProxyConfig();
    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: _keyPath);
      try {
        final enabled = key.getIntValue('ProxyEnable') ?? 0;
        final server = key.getStringValue('ProxyServer')?.trim() ?? '';
        final pacUrl = key.getStringValue('AutoConfigURL')?.trim() ?? '';
        return SystemProxyConfig(
          proxyUrl: enabled != 0 && server.isNotEmpty
              ? parseProxyServer(server)
              : null,
          pacUrl: pacUrl.isEmpty ? null : pacUrl,
        );
      } finally {
        key.close();
      }
    } catch (e) {
      debugPrint('[SystemProxyDetector] 读取系统代理设置失败: $e');
      return const SystemProxyConfig();
    }
  }

  /// 把注册表 `ProxyServer` 值解析成代理 URL。
  ///
  /// 支持两种格式：
  /// - `host:port`（对所有协议生效）→ `http://host:port`
  /// - `http=h:p;https=h:p;socks=h:p`（按协议分列）→ 优先 https，其次
  ///   http，最后 socks（映射为 socks5，WinINet 的 socks= 即 SOCKS 代理）
  @visibleForTesting
  static String? parseProxyServer(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    if (!value.contains('=')) {
      return _normalize(value, 'http');
    }

    final entries = <String, String>{};
    for (final part in value.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final scheme = part.substring(0, idx).trim().toLowerCase();
      final host = part.substring(idx + 1).trim();
      if (host.isNotEmpty) entries[scheme] = host;
    }
    final https = entries['https'];
    if (https != null) return _normalize(https, 'http');
    final http = entries['http'];
    if (http != null) return _normalize(http, 'http');
    final socks = entries['socks'];
    if (socks != null) return _normalize(socks, 'socks5');
    return null;
  }

  /// 把安卓 `ConnectivityManager.getDefaultProxy()` 的读数（见原生
  /// SystemProxyChannel）转成配置。
  ///
  /// - 有 PAC：Dart 侧求不了值，只记「系统代理已启用」，不给固定代理地址
  ///   （与 Windows 的 PAC-only 一致）；
  /// - 固定代理的排除名单命中论坛主机：对论坛等于没有代理，当成未启用。
  static SystemProxyConfig parseAndroid(
    Map<Object?, Object?>? raw, {
    required String forumHost,
  }) {
    if (raw == null || raw.isEmpty) return const SystemProxyConfig();
    final pac = (raw['pac'] as String?)?.trim();
    if (pac != null && pac.isNotEmpty) return SystemProxyConfig(pacUrl: pac);
    final host = (raw['host'] as String?)?.trim() ?? '';
    final port = raw['port'] is int ? raw['port'] as int : -1;
    if (host.isEmpty || port < 1 || port > 65535) {
      return const SystemProxyConfig();
    }
    final exclusions = [
      for (final e in (raw['exclusions'] as List?) ?? const [])
        if (e is String) e,
    ];
    if (isExcluded(forumHost, exclusions)) return const SystemProxyConfig();
    final hostPart = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return SystemProxyConfig(proxyUrl: _normalize('$hostPart:$port', 'http'));
  }

  /// 安卓代理排除名单的匹配：条目是主机名，可带前导 `*`（`*.linux.do`、
  /// `*linux.do`），也可能带前导点（`.linux.do`），不区分大小写
  @visibleForTesting
  static bool isExcluded(String host, List<String> exclusions) {
    final h = host.toLowerCase();
    for (final raw in exclusions) {
      var e = raw.trim().toLowerCase();
      if (e.isEmpty) continue;
      if (e == '*') return true;
      if (e.startsWith('*')) {
        e = e.substring(1);
        if (h.endsWith(e) || '.$h' == e) return true;
        continue;
      }
      if (e.startsWith('.')) {
        if (h.endsWith(e) || '.$h' == e) return true;
        continue;
      }
      if (h == e) return true;
    }
    return false;
  }

  static String? _normalize(String hostPort, String defaultScheme) {
    var v = hostPort.trim();
    if (v.isEmpty) return null;
    // 少数工具会把带 scheme 的地址直接写进注册表，做一次归一化。
    final schemeMatch = RegExp(r'^(https?|socks5?)://').firstMatch(v);
    String scheme = defaultScheme;
    if (schemeMatch != null) {
      scheme = schemeMatch.group(1) == 'socks' ? 'socks5' : schemeMatch.group(1)!;
      if (scheme == 'https') scheme = 'http';
      v = v.substring(schemeMatch.group(0)!.length);
    }
    // Uri 会把 http:80 / https:443 等默认端口归一化掉,不能用 hasPort 判定,
    // 这里显式要求 host:port 形式。
    final m = RegExp(r'^(\[[0-9a-fA-F:]+\]|[^:/\s]+):(\d{1,5})$').firstMatch(v);
    if (m == null) return null;
    final port = int.parse(m.group(2)!);
    if (port < 1 || port > 65535) return null;
    return '$scheme://${m.group(1)}:$port';
  }
}
