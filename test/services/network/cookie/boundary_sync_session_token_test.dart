import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/boundary_sync_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

/// WebView → jar 的边界同步只在登录收口写 `_t`。
///
/// 回归背景（1.1.1-beta.2 真机复现）：只把 WebView 的 `_t` 改成坏值、jar 仍是
/// 活值 T1，冷启动撞上 CF 盾。BrowserTrust 启动预载 / WebView 会话刷新的
/// 「全量可信同步」把 WebView 的坏值不经探测写进了 jar（version +1、过期时间
/// 沿用 WebView 那枚的），过盾后两端都是坏值，被动登出。现在这类同步不带
/// `_t`，WebView 的 `_t` 交 SessionTokenAuthority 对账。
void main() {
  group('BoundarySyncService.shouldSyncCookie', () {
    final cases =
        <
          ({
            String name,
            String cookie,
            Set<String>? names,
            Set<String>? excludes,
            bool login,
            bool expect,
          })
        >[
          (
            name: '全量同步（BrowserTrust / 会话刷新）不写 _t',
            cookie: '_t',
            names: null,
            excludes: null,
            login: false,
            expect: false,
          ),
          (
            name: '点名 _t 但不是登录收口（适配器回写）也不写',
            cookie: '_t',
            names: CookieJarService.criticalCookieNames,
            excludes: null,
            login: false,
            expect: false,
          ),
          (
            name: '登录收口写 _t',
            cookie: '_t',
            names: null,
            excludes: null,
            login: true,
            expect: true,
          ),
          (
            name: '登录收口但调用方排除了登录 cookie → 仍不写',
            cookie: '_t',
            names: null,
            excludes: CookieJarService.authCookieNames,
            login: true,
            expect: false,
          ),
          (
            name: '_forum_session 等其他 cookie 照常同步',
            cookie: '_forum_session',
            names: null,
            excludes: null,
            login: false,
            expect: true,
          ),
          (
            name: 'cf_clearance 点名同步照常',
            cookie: 'cf_clearance',
            names: {'cf_clearance'},
            excludes: null,
            login: false,
            expect: true,
          ),
          (
            name: '不在点名列表里的不同步',
            cookie: '_rt',
            names: {'cf_clearance'},
            excludes: null,
            login: false,
            expect: false,
          ),
        ];

    for (final c in cases) {
      test(c.name, () {
        expect(
          BoundarySyncService.shouldSyncCookie(
            c.cookie,
            cookieNames: c.names,
            excludeCookieNames: c.excludes,
            includeSessionToken: c.login,
          ),
          c.expect,
        );
      });
    }
  });
}
