import 'dart:io';

/// 一段自定义节点输入拆开后的结果
class CustomNodeParseResult {
  const CustomNodeParseResult({required this.nodes, required this.invalid});

  /// 写法没问题的条目（已规范化、去重，保持输入顺序）
  final List<String> nodes;

  /// 写法不对的原文
  final List<String> invalid;
}

/// 自定义节点（用户自己填的 Cloudflare IP / 优选域名）的输入整理。
///
/// 这里只管写法对不对、统一成规范形式；在不在 Cloudflare 网段、能不能连上
/// linux.do 由 Rust 引擎判断（core/doh_proxy 的 select.rs `CustomNodes`），
/// 结论从优选状态里读回来（[DohSelectStatus.customNodes]）
class CustomNodeInput {
  CustomNodeInput._();

  /// 清单最多几条（和 Rust 侧 `CUSTOM_MAX_ENTRIES` 一致）
  static const maxEntries = 8;

  static final _schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
  static final _separatorPattern = RegExp(r'[\s,;，；、]+');
  static final _ipv4Pattern = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  );
  static final _labelPattern = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');
  static final _digitsPattern = RegExp(r'^\d+$');

  /// 把一条输入规范化：IPv4 / IPv6（去方括号、压缩写法）/ 小写域名；
  /// 带 `:443` 或网址形式的只取主机。写法不对（含别的端口：网关只连 443）返回 null
  static String? normalize(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    // 粘进来的是网址：只取主机
    if (_schemePattern.hasMatch(text)) {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) return null;
      if (uri.hasPort && uri.port != 443) return null;
      text = uri.host;
    }
    final direct = _ipv4(text) ?? _ipv6(text);
    if (direct != null) return direct;
    if (text.startsWith('[')) {
      final end = text.indexOf(']');
      if (end < 0) return null;
      final rest = text.substring(end + 1);
      if (rest.isNotEmpty && rest != ':443') return null;
      return _ipv6(text.substring(1, end));
    }
    if (text.endsWith(':443')) text = text.substring(0, text.length - 4);
    final v4 = _ipv4(text);
    if (v4 != null) return v4;
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    text = text.toLowerCase();
    return _isDomain(text) ? text : null;
  }

  /// 把一段输入（换行、逗号、分号、空白分隔）拆开并规范化
  static CustomNodeParseResult parse(String input) {
    final nodes = <String>[];
    final invalid = <String>[];
    for (final part in input.split(_separatorPattern)) {
      if (part.isEmpty) continue;
      final node = normalize(part);
      if (node == null) {
        if (!invalid.contains(part)) invalid.add(part);
      } else if (!nodes.contains(node)) {
        nodes.add(node);
      }
    }
    return CustomNodeParseResult(nodes: nodes, invalid: invalid);
  }

  /// 落盘 / 交给引擎前的整理：逐条规范化、去掉写错的和重复的、截到上限
  static List<String> sanitize(Iterable<String> nodes) {
    final out = <String>[];
    for (final raw in nodes) {
      final node = normalize(raw);
      if (node == null || out.contains(node)) continue;
      out.add(node);
      if (out.length >= maxEntries) break;
    }
    return out;
  }

  static String? _ipv4(String text) {
    final match = _ipv4Pattern.firstMatch(text);
    if (match == null) return null;
    final parts = <int>[];
    for (var i = 1; i <= 4; i++) {
      final value = int.parse(match.group(i)!);
      if (value > 255) return null;
      parts.add(value);
    }
    return parts.join('.');
  }

  /// IPv6 统一成压缩写法（RFC 5952），同一个地址的不同写法才能去重
  static String? _ipv6(String text) {
    if (!text.contains(':') || text.contains('%')) return null;
    final address = InternetAddress.tryParse(text);
    if (address == null || address.type != InternetAddressType.IPv6) {
      return null;
    }
    final raw = address.rawAddress;
    final groups = [for (var i = 0; i < 16; i += 2) (raw[i] << 8) | raw[i + 1]];
    // 最长的一段连续 0（至少两组）压成 ::
    var bestStart = -1;
    var bestLength = 0;
    var start = -1;
    for (var i = 0; i <= groups.length; i++) {
      if (i < groups.length && groups[i] == 0) {
        if (start < 0) start = i;
        continue;
      }
      if (start >= 0 && i - start > bestLength) {
        bestStart = start;
        bestLength = i - start;
      }
      start = -1;
    }
    String hex(Iterable<int> part) =>
        part.map((group) => group.toRadixString(16)).join(':');
    if (bestLength < 2) return hex(groups);
    return '${hex(groups.take(bestStart))}::'
        '${hex(groups.skip(bestStart + bestLength))}';
  }

  static bool _isDomain(String host) {
    if (host.length > 253) return false;
    final labels = host.split('.');
    if (labels.length < 2) return false;
    for (final label in labels) {
      if (label.length > 63 || !_labelPattern.hasMatch(label)) return false;
    }
    // 末段全是数字的是写坏了的 IP（如 1.2.3、300.1.1.1），不当域名
    return !_digitsPattern.hasMatch(labels.last);
  }
}
