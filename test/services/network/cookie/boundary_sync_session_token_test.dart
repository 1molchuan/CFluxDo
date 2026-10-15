import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/boundary_sync_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

/// WebView → jar 的边界同步从不写 `_t`（登录收口由
/// SessionTokenAuthority.adoptLoginToken 写，其余交它对账）。
///
/// 回归背景（1.1.1-beta.2 真机复现）：只把 WebView 的 `_t` 改成坏值、jar 仍是
/// 活值 T1，冷启动撞上 CF 盾。BrowserTrust 启动预载 / WebView 会话刷新的
/// 「全量可信同步」把 WebView 的坏值不经探测写进了 jar（version +1、过期时间
/// 沿用 WebView 那枚的），过盾后两端都是坏值，被动登出。现在边界同步不带
/// `_t`，WebView 的 `_t` 交 SessionTokenAuthority。
void main() {
  group('BoundarySyncService.shouldSyncCookie', () {
    final cases =
        <
          ({
            String name,
            String cookie,
            Set<String>? names,
            Set<String>? excludes,
            bool expect,
          })
        >[
          (
            name: '全量同步（BrowserTrust / 会话刷新 / 登录收口）不写 _t',
            cookie: '_t',
            names: null,
            excludes: null,
            expect: false,
          ),
          (
            name: '点名 _t（适配器回写关键 cookie）也不写',
            cookie: '_t',
            names: CookieJarService.criticalCookieNames,
            excludes: null,
            expect: false,
          ),
          (
            name: '_forum_session 等其他 cookie 照常同步',
            cookie: '_forum_session',
            names: null,
            excludes: null,
            expect: true,
          ),
          (
            name: '排除登录 cookie 时 _forum_session 不同步',
            cookie: '_forum_session',
            names: null,
            excludes: CookieJarService.authCookieNames,
            expect: false,
          ),
          (
            name: 'cf_clearance 点名同步照常',
            cookie: 'cf_clearance',
            names: {'cf_clearance'},
            excludes: null,
            expect: true,
          ),
          (
            name: '不在点名列表里的不同步',
            cookie: '_rt',
            names: {'cf_clearance'},
            excludes: null,
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
          ),
          c.expect,
        );
      });
    }
  });
}
