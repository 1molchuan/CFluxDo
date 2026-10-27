import 'dart:convert';

/// LD士多（ldcstore.com，社区成员开发的积分兑换商城，第三方）的数据模型。
///
/// 前端源码公开在 caigg188/LDStatusPro 的 ld-store 目录；接口返回的字段
/// snake_case 与 camelCase 混用（它的前端在服务边界统一转 camelCase），
/// 这里同样先转 camelCase 再读，显式的 camelCase 字段优先。

/// 把 `snake_case` 键递归转成 `camelCase`；同名的 camelCase 键已存在时保留它。
Object? camelizeLdStoreWire(Object? value) {
  if (value is List) return value.map(camelizeLdStoreWire).toList();
  if (value is! Map) return value;
  final source = value.cast<Object?, Object?>();
  final output = <String, Object?>{};
  for (final entry in source.entries) {
    final key = entry.key.toString();
    final camel = key.replaceAllMapped(
      RegExp(r'_([a-z0-9])'),
      (m) => m.group(1)!.toUpperCase(),
    );
    if (camel != key && source.containsKey(camel)) continue;
    output[camel] = camelizeLdStoreWire(entry.value);
  }
  return output;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

/// 公开统计（`/api/shop/stats`，不需要登录）。
class LdStoreStats {
  const LdStoreStats({
    required this.onlineProducts,
    required this.ordersToday,
    required this.stores,
  });

  factory LdStoreStats.fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    return LdStoreStats(
      onlineProducts: _int(_map(json['products'])['online']),
      ordersToday: _int(_map(json['orders'])['today']),
      stores: _int(json['stores']),
    );
  }

  final int onlineProducts;
  final int ordersToday;
  final int stores;
}

/// 个人待办（`/api/shop/user/attention`）。
class LdStoreAttention {
  const LdStoreAttention({
    this.pendingPayment = 0,
    this.awaitingDelivery = 0,
    this.refundAttention = 0,
    this.unusedCoupons = 0,
    this.expiringCoupons = 0,
  });

  factory LdStoreAttention.fromJson(Object? data) {
    final json = _map(camelizeLdStoreWire(data));
    return LdStoreAttention(
      pendingPayment: _int(json['pendingPaymentCount']),
      awaitingDelivery: _int(json['awaitingDeliveryCount']),
      refundAttention: _int(json['refundAttentionCount']),
      unusedCoupons: _int(json['unusedCouponCount']),
      expiringCoupons: _int(json['expiringCouponCount']),
    );
  }

  final int pendingPayment;
  final int awaitingDelivery;
  final int refundAttention;
  final int unusedCoupons;
  final int expiringCoupons;
}

/// 已授权账号在商城里的概况。
class LdStoreAccount {
  const LdStoreAccount({
    required this.username,
    required this.attention,
    required this.unreadMessages,
  });

  final String username;
  final LdStoreAttention attention;

  /// 未读消息（`/api/shop/messages/unread-summary` 的 totalUnread）。
  final int unreadMessages;

  static int unreadFromJson(Object? data) =>
      _int(_map(camelizeLdStoreWire(data))['totalUnread']);
}

/// 商城签发的登录凭据（HS256 JWT）。客户端只读载荷做身份与到期判断，
/// 签名由商城 `/api/shop/auth/verify` 校验。
class LdStoreToken {
  const LdStoreToken._({
    required this.value,
    required this.userId,
    required this.site,
    required this.username,
    required this.expiresAt,
  });

  static const _sites = {'linux.do', 'idcflare.com'};

  /// 与商城前端一致：提前 30 秒按到期处理。
  static const expirySkew = Duration(seconds: 30);

  final String value;
  final String userId;
  final String site;
  final String username;
  final DateTime expiresAt;

  bool isExpired([DateTime? now]) =>
      !expiresAt.isAfter((now ?? DateTime.now()).add(expirySkew));

  /// 解析并检查格式与身份；格式不对、算法不对、站点不认识、已到期或尚未
  /// 生效都返回 null。
  static LdStoreToken? parse(String? token, {DateTime? now}) {
    final parsed = decode(token, now: now);
    return parsed == null || parsed.isExpired(now) ? null : parsed;
  }

  /// 同 [parse]，但不管是否到期（读存储时要区分「到期」和「没有」）。
  static LdStoreToken? decode(String? token, {DateTime? now}) {
    if (token == null || !RegExp(r'^[\w-]+\.[\w-]+\.[\w-]+$').hasMatch(token)) {
      return null;
    }
    try {
      final parts = token.split('.');
      final header = _decodeSegment(parts[0]);
      final payload = _decodeSegment(parts[1]);
      if (header is! Map || header['alg'] != 'HS256') return null;
      if (payload is! Map) return null;
      final exp = payload['exp'];
      if (exp is! int) return null;
      final nbf = payload['nbf'];
      if (nbf != null &&
          (nbf is! int ||
              nbf * 1000 > (now ?? DateTime.now()).millisecondsSinceEpoch)) {
        return null;
      }
      final id = '${payload['sub'] ?? payload['id'] ?? ''}';
      final site = '${payload['site'] ?? 'linux.do'}';
      if (!RegExp(r'^[1-9]\d*$').hasMatch(id) || !_sites.contains(site)) {
        return null;
      }
      return LdStoreToken._(
        value: token,
        userId: id,
        site: site,
        username: '${payload['username'] ?? ''}',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(exp * 1000),
      );
    } catch (_) {
      return null;
    }
  }

  static Object? _decodeSegment(String segment) =>
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(segment))));
}

/// 商城 OAuth 回调交回的登录结果：回跳地址 hash 或 query 里的 `ldsp_oauth`，
/// 内容是 base64url 编码的 `{t: token, u: user, j: isJoined, ts}`。
class LdStoreLoginPayload {
  LdStoreLoginPayload._();

  /// 从回跳地址取出凭据；载荷里的用户必须与凭据本身是同一个人。
  static LdStoreToken? fromRedirect(Uri location, {DateTime? now}) {
    final raw = _param(location.fragment) ?? _param(location.query);
    if (raw == null || raw.isEmpty) return null;
    try {
      // 与商城前端一致：兼容 + 被转成空格、URL-safe base64、缺 padding
      final normalized = Uri.decodeComponent(raw)
          .replaceAll(RegExp(r'\s'), '+')
          .replaceAll('-', '+')
          .replaceAll('_', '/');
      final padded = normalized.padRight(
        normalized.length + (4 - normalized.length % 4) % 4,
        '=',
      );
      final text = utf8.decode(base64.decode(padded));
      Object? json;
      try {
        json = jsonDecode(text);
      } on FormatException {
        // 另一种写法：先 encodeURIComponent 再 base64
        json = jsonDecode(Uri.decodeComponent(text));
      }
      if (json is! Map) return null;
      final token = LdStoreToken.parse(json['t']?.toString(), now: now);
      final user = json['u'];
      if (token == null || user is! Map) return null;
      if ('${user['id']}' != token.userId ||
          '${user['site'] ?? 'linux.do'}' != token.site) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }

  static String? _param(String part) {
    if (part.isEmpty) return null;
    final match = RegExp(r'(?:^|&)ldsp_oauth=([^&]*)').firstMatch(part);
    return match?.group(1);
  }
}
