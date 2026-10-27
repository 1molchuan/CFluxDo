import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ld_store/ld_store_models.dart';

import 'ld_store_test_support.dart';

void main() {
  final now = DateTime(2026, 10, 26, 12);
  final later = now.add(const Duration(days: 7));

  group('LdStoreToken', () {
    test('读出身份与到期', () {
      final token = LdStoreToken.parse(ldStoreJwt(expiresAt: later), now: now)!;
      expect(token.userId, '12345');
      expect(token.site, 'linux.do');
      expect(token.username, 'alice');
      expect(
        token.expiresAt.millisecondsSinceEpoch ~/ 1000,
        later.millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('到期（含 30 秒提前量）、未生效、算法或站点不对都不认', () {
      expect(
        LdStoreToken.parse(
          ldStoreJwt(expiresAt: now.add(const Duration(seconds: 20))),
          now: now,
        ),
        isNull,
      );
      expect(
        LdStoreToken.parse(
          ldStoreJwt(
            expiresAt: later,
            notBefore: now.add(const Duration(minutes: 5)),
          ),
          now: now,
        ),
        isNull,
      );
      expect(
        LdStoreToken.parse(
          ldStoreJwt(expiresAt: later, alg: 'none'),
          now: now,
        ),
        isNull,
      );
      expect(
        LdStoreToken.parse(
          ldStoreJwt(expiresAt: later, site: 'example.com'),
          now: now,
        ),
        isNull,
      );
      expect(
        LdStoreToken.parse(
          ldStoreJwt(expiresAt: later, sub: '0'),
          now: now,
        ),
        isNull,
      );
      expect(LdStoreToken.parse('not-a-jwt', now: now), isNull);
    });

    test('decode 不管到期，供读存储时区分「到期」与「没有」', () {
      final expired = ldStoreJwt(
        expiresAt: now.subtract(const Duration(days: 1)),
      );
      expect(LdStoreToken.parse(expired, now: now), isNull);
      final decoded = LdStoreToken.decode(expired, now: now)!;
      expect(decoded.isExpired(now), isTrue);
    });
  });

  group('LdStoreLoginPayload', () {
    final jwt = ldStoreJwt(expiresAt: later);
    final param = ldStoreLoginParam(jwt);

    test('从 hash 取凭据', () {
      final token = LdStoreLoginPayload.fromRedirect(
        Uri.parse(
          'https://ldcstore.com/auth/callback?redirect=%2F#ldsp_oauth=$param',
        ),
        now: now,
      );
      expect(token?.value, jwt);
    });

    test('兼容落在 query、URL-safe、+ 被转成空格、缺 padding', () {
      final urlSafe = param
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');
      expect(
        LdStoreLoginPayload.fromRedirect(
          Uri.parse(
            'https://ldcstore.com/auth/callback?ldsp_oauth=$urlSafe&redirect=/',
          ),
          now: now,
        )?.value,
        jwt,
      );
      final encoded = base64.encode(
        utf8.encode(
          Uri.encodeComponent(
            jsonEncode({
              't': jwt,
              'u': {'id': '12345', 'site': 'linux.do'},
            }),
          ),
        ),
      );
      expect(
        LdStoreLoginPayload.fromRedirect(
          Uri.parse('https://ldcstore.com/auth/callback#ldsp_oauth=$encoded'),
          now: now,
        )?.value,
        jwt,
      );
    });

    test('载荷里的用户与凭据不是同一个人就不认', () {
      final forged = ldStoreLoginParam(jwt, userId: 999);
      expect(
        LdStoreLoginPayload.fromRedirect(
          Uri.parse('https://ldcstore.com/auth/callback#ldsp_oauth=$forged'),
          now: now,
        ),
        isNull,
      );
      expect(
        LdStoreLoginPayload.fromRedirect(
          Uri.parse('https://ldcstore.com/auth/callback#other=1'),
          now: now,
        ),
        isNull,
      );
    });
  });

  test('接口字段 snake_case / camelCase 混用都能读，显式 camelCase 优先', () {
    final stats = LdStoreStats.fromJson({
      'products': {'total': 300, 'online': 120},
      'orders': {'total': 9000, 'today': 45, 'week': 300},
      'stores': '18',
    });
    expect(stats.onlineProducts, 120);
    expect(stats.ordersToday, 45);
    expect(stats.stores, 18);

    final attention = LdStoreAttention.fromJson({
      'pending_payment_count': 2,
      'awaiting_delivery_count': 1,
      'awaitingDeliveryCount': 3,
      'unused_coupon_count': 4,
    });
    expect(attention.pendingPayment, 2);
    expect(attention.awaitingDelivery, 3);
    expect(attention.unusedCoupons, 4);
    expect(attention.refundAttention, 0);

    expect(LdStoreAccount.unreadFromJson({'total_unread': 7}), 7);
  });
}
