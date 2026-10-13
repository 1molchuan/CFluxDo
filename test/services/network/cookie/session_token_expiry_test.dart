import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

void main() {
  group('CookieJarService.resolveSessionTokenExpiry', () {
    final now = DateTime.utc(2026, 10, 13, 8);
    final future = now.add(const Duration(days: 30));
    final laterFuture = now.add(const Duration(days: 45));
    final past = now.subtract(const Duration(hours: 1));

    test('候选值自带的未来过期时间优先', () {
      expect(
        CookieJarService.resolveSessionTokenExpiry(
          candidate: future,
          existing: laterFuture,
          now: now,
        ),
        future,
      );
    });

    test('候选值没有过期时间时继承 jar 原值的', () {
      expect(
        CookieJarService.resolveSessionTokenExpiry(
          candidate: null,
          existing: laterFuture,
          now: now,
        ),
        laterFuture,
      );
    });

    test('两边都没有时兜底为 now + 60 天，保证 _t 能落盘', () {
      expect(
        CookieJarService.sessionTokenFallbackLifetime,
        const Duration(days: 60),
      );
      expect(
        CookieJarService.resolveSessionTokenExpiry(now: now),
        now.add(const Duration(days: 60)),
      );
    });

    test('已过期的时间一律视为缺失', () {
      expect(
        CookieJarService.resolveSessionTokenExpiry(
          candidate: past,
          existing: past,
          now: now,
        ),
        now.add(const Duration(days: 60)),
      );
      expect(
        CookieJarService.resolveSessionTokenExpiry(
          candidate: past,
          existing: future,
          now: now,
        ),
        future,
      );
    });
  });
}
