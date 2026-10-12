import 'dart:convert';
import 'dart:io';

/// 加速服务端下发的节点列表（已由 Rust 侧验签）
///
/// 持有「域名 → 引导 IP」映射，供 Dart 侧 DohResolver / AccelDohApi 建连时使用。
/// 只接受两种来源：
/// - Rust `take_accel_update` 返回的 `nodes`（验签后的 payload JSON）
/// - 启动时从持久化的信封 `{"kid","payload","sig"}` 里解出的 payload
///   （信封本身是上次 Rust 接受过的内容，启动时会原样回传给 Rust 重新验签）
class AccelNodeStore {
  /// key 为小写域名，value 为该域名的引导 IP 列表（v4 在前、v6 在后）
  final Map<String, List<String>> _hosts = {};

  /// 节点列表 serial，便于日志排查
  int serial = 0;

  /// 当前是否没有任何节点
  bool get isEmpty => _hosts.isEmpty;

  /// 当前已知的域名集合
  Iterable<String> get hosts => _hosts.keys;

  /// 从验签后的 payload JSON 载入；格式不对或已过期返回 false，保留原有内容
  bool loadPayloadJson(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return false;
    }
    if (decoded is! Map) return false;
    return _loadPayload(decoded);
  }

  /// 从持久化的签名信封 JSON 载入（只解 payload，不验签）
  bool loadEnvelopeJson(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return false;
    }
    if (decoded is! Map) return false;
    final payload = decoded['payload'];
    if (payload is! String || payload.isEmpty) return false;
    final dynamic payloadJson;
    try {
      payloadJson = jsonDecode(utf8.decode(base64.decode(base64.normalize(payload))));
    } catch (_) {
      return false;
    }
    if (payloadJson is! Map) return false;
    return _loadPayload(payloadJson);
  }

  /// 清空
  void clear() {
    _hosts.clear();
    serial = 0;
  }

  bool _loadPayload(Map payload) {
    final notAfter = payload['not_after'];
    if (notAfter is num) {
      final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (notAfter <= nowSecs) return false;
    }
    final hosts = payload['hosts'];
    if (hosts is! Map) return false;

    final parsed = <String, List<String>>{};
    hosts.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final host = key.trim().toLowerCase();
      if (host.isEmpty) return;
      final ips = <String>[];
      for (final family in const ['v4', 'v6']) {
        final list = value[family];
        if (list is! List) continue;
        for (final item in list) {
          if (item is! String) continue;
          final ip = item.trim();
          if (ip.isEmpty || InternetAddress.tryParse(ip) == null) continue;
          if (!ips.contains(ip)) ips.add(ip);
        }
      }
      if (ips.isNotEmpty) parsed[host] = ips;
    });
    if (parsed.isEmpty) return false;

    _hosts
      ..clear()
      ..addAll(parsed);
    final serialValue = payload['serial'];
    serial = serialValue is num ? serialValue.toInt() : 0;
    return true;
  }

  /// 查某个域名的引导 IP：精确匹配或以 `.<key>` 结尾（最长 key 优先）；没有则空列表
  List<String> ipsFor(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty || _hosts.isEmpty) return const [];
    String? bestKey;
    for (final key in _hosts.keys) {
      if (normalized == key || normalized.endsWith('.$key')) {
        if (bestKey == null || key.length > bestKey.length) bestKey = key;
      }
    }
    if (bestKey == null) return const [];
    return List.unmodifiable(_hosts[bestKey]!);
  }
}

/// 合并引导 IP：已下发节点在前、内置种子在后，去重并保持顺序
List<String> mergeAccelBootstrapIps(List<String> stored, List<String> seeds) {
  final merged = <String>[];
  for (final ip in [...stored, ...seeds]) {
    final value = ip.trim();
    if (value.isEmpty || merged.contains(value)) continue;
    merged.add(value);
  }
  return merged;
}
