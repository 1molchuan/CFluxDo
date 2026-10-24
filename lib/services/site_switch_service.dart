import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/forum_site.dart';
import 'cf_clearance_refresh_service.dart';
import 'log/log_writer.dart';
import 'network/doh/network_settings_service.dart';
import 'network/doh_proxy/doh_proxy_service.dart';
import 'site_context.dart';
import 'site_data_lifecycle.dart';
import 'user_api_key_service.dart';

/// 切站是保存选择并重启运行环境，不是登出；旧站凭据与 Cookie 全部保留。
class SiteSwitchService {
  SiteSwitchService._();

  static final instance = SiteSwitchService._();
  static const _channel = MethodChannel('fluxdo/site_switch');
  static const pendingUrlKey = 'pending_site_open_url';

  final ValueNotifier<bool> _isSwitching = ValueNotifier(false);
  ValueListenable<bool> get isSwitching => _isSwitching;

  Future<void> switchTo(ForumSite target, {Uri? openUrl}) async {
    if (target == SiteContext.current) return;
    final preferences = await SharedPreferences.getInstance();
    if (_isSwitching.value) throw StateError('正在切换站点');
    _isSwitching.value = true;
    final previousUrl = preferences.getString(pendingUrlKey);
    var selectionSaved = false;
    var mobileProxyStopped = false;
    try {
      if (openUrl != null && !await _isValidTargetUrl(target, openUrl)) {
        throw ArgumentError.value(target.id, 'target', '链接与目标站点不匹配');
      }
      if (await _channel.invokeMethod<bool>('isSupported') != true) {
        throw PlatformException(code: 'SITE_SWITCH_UNSUPPORTED');
      }
      // 先保存编辑器当前值与延迟落盘数据，失败时不离开当前站点。
      await SiteDataLifecycle.flushBeforeSwitch();
      if (openUrl == null) {
        await preferences.remove(pendingUrlKey);
      } else if (!await preferences.setString(pendingUrlKey, openUrl.toString())) {
        throw const FileSystemException('无法保存待打开的站点链接');
      }
      await SiteContext.persistSelection(target);
      selectionSaved = true;
      await LogWriter.instance.flushNow();

      // 桌面使用进程重启，避免在活跃 WebView2 下析构环境导致消息泵卡死。
      // Android 重建引擎前必须停掉进程内 Rust 代理，不能让旧引擎继续占端口。
      if (Platform.isAndroid) {
        await CfClearanceRefreshService().stop();
        await DohProxyService.instance.stop();
        mobileProxyStopped = true;
      }
      await _channel.invokeMethod<void>('restart');
      // 成功后不解锁按钮；旧运行环境即将退出，不能接受第二次切换。
    } catch (_) {
      try {
        if (selectionSaved) {
          await SiteContext.persistSelection(SiteContext.current);
        }
        if (previousUrl == null) {
          await preferences.remove(pendingUrlKey);
        } else {
          await preferences.setString(pendingUrlKey, previousUrl);
        }
        if (mobileProxyStopped) {
          await NetworkSettingsService.instance.restartProxy();
          CfClearanceRefreshService().start();
        }
      } finally {
        _isSwitching.value = false;
      }
      rethrow;
    }
  }

  static Future<bool> _isValidTargetUrl(ForumSite target, Uri uri) async {
    if (ForumSite.fromUri(uri) == target) return true;
    if (uri.scheme != 'discourse' ||
        uri.host != 'auth_redirect' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return false;
    }
    return await UserApiKeyService().resolveAuthRedirectSite(uri) == target;
  }
}
