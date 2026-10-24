import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/forum_site.dart';

/// 当前引擎只服务一个论坛。切换仅持久化选择，由新引擎重新初始化。
/// 旧引擎的异步回写始终留在旧站，不能因切换改变凭据或缓存的归属。
abstract final class SiteContext {
  static const selectionKey = 'active_forum_site';
  static ForumSite _current = ForumSite.linuxDo;
  static SharedPreferences? _preferences;

  static ForumSite get current => _current;
  static bool get isLinuxDo => _current.isLinuxDo;

  static Future<void> initialize(SharedPreferences preferences) async {
    if (_preferences != null) return;
    await preferences.reload();
    _current = ForumSite.fromId(preferences.getString(selectionKey)) ??
        ForumSite.linuxDo;
    _preferences = preferences;
  }

  static String storageKey(String legacyKey) => _current.storageKey(legacyKey);
  static String accountKey(String accountId) => _current.accountKey(accountId);

  static Directory directory(Directory root) => isLinuxDo
      ? root
      : Directory(path.join(root.path, 'sites', current.id));

  static Future<Directory> supportDirectory() async {
    final root = await getApplicationSupportDirectory();
    final scoped = directory(root);
    await scoped.create(recursive: true);
    return scoped;
  }

  static Future<void> persistSelection(ForumSite target) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    if (!await preferences.setString(selectionKey, target.id)) {
      throw const FileSystemException('无法保存论坛站点选择');
    }
  }
}
