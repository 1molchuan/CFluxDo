import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../site_context.dart';

/// 一份启动快照：上一次成功拿到的首页预加载片段。
@immutable
class StartupSnapshot {
  const StartupSnapshot({
    required this.fragment,
    required this.savedAt,
    required this.host,
    this.userId,
  });

  /// 首页 HTML 里启动要用的那几段（见 [StartupSnapshotStore.buildFragment]），
  /// 可以原样交给预加载解析。
  final String fragment;

  final DateTime savedAt;

  /// 快照属于哪个论坛（主机名）。
  final String host;

  /// 快照里的当前用户；游客快照为 null。
  final int? userId;

  bool get loggedIn => userId != null;
}

/// 启动快照的落盘读写。
///
/// 冷启动不必等首页请求回来才出内容：先把上一次的首页数据读回来放行，
/// 这次的首页请求照常发，回来后整份替换。文件在应用私有目录里，按站点分开
/// （LINUX DO 在根目录，其余站点在 `sites/<id>/`，和 Cookie 的归属一致）。
class StartupSnapshotStore {
  StartupSnapshotStore({Future<Directory> Function()? directory})
    : _directory = directory ?? SiteContext.supportDirectory;

  final Future<Directory> Function() _directory;

  static const fileName = 'startup_snapshot.json';
  static const _version = 1;

  Future<File> _file() async =>
      File(path.join((await _directory()).path, fileName));

  /// 读回快照；没有、读坏了或版本不对都返回 null。
  Future<StartupSnapshot?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['v'] != _version) return null;
      final fragment = json['fragment'];
      final host = json['host'];
      final savedAt = json['savedAt'];
      if (fragment is! String ||
          fragment.isEmpty ||
          host is! String ||
          savedAt is! int) {
        return null;
      }
      final userId = json['userId'];
      return StartupSnapshot(
        fragment: fragment,
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
        host: host,
        userId: userId is int ? userId : null,
      );
    } catch (e) {
      debugPrint('[StartupSnapshot] 读取失败: $e');
      return null;
    }
  }

  /// 写快照：先写临时文件再改名，进程中途被杀也不会留下半截文件。
  Future<void> save(StartupSnapshot snapshot) async {
    try {
      final file = await _file();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'v': _version,
          'savedAt': snapshot.savedAt.millisecondsSinceEpoch,
          'host': snapshot.host,
          'userId': snapshot.userId,
          'fragment': snapshot.fragment,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (e) {
      debugPrint('[StartupSnapshot] 保存失败: $e');
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[StartupSnapshot] 删除失败: $e');
    }
  }

  static final _scriptOpen = RegExp(
    '''<script[^>]*id=["']data-preloaded["'][^>]*>''',
    caseSensitive: false,
  );
  static final _attributeForm = RegExp(r'data-preloaded="([^"]*)"');
  static final _setupMarker = RegExp(
    '''id=["']data-discourse-setup["']''',
    caseSensitive: false,
  );
  static final _baseUriMeta = RegExp(
    '''<meta[^>]+name=["']discourse-base-uri["'][^>]*>''',
    caseSensitive: false,
  );

  /// 从首页 HTML（或验证页交来的片段）里抽出启动要用的几段：预加载数据、
  /// `data-discourse-setup`、子路径前缀。抽不全返回 null。
  ///
  /// 刻意不留 `csrf-token` 和 `shared_session_key`：它们跟着会话走、会过期，
  /// 下次启动要用这次请求回来的新值。
  static String? buildFragment(String html) {
    final parts = <String>[];
    final script = _scriptOpen.firstMatch(html);
    if (script != null) {
      final end = html.indexOf('</script>', script.end);
      if (end <= script.end) return null;
      parts.add(html.substring(script.start, end + '</script>'.length));
    } else {
      final attribute = _attributeForm.firstMatch(html);
      if (attribute == null) return null;
      parts.add('<div id="data-preloaded" ${attribute.group(0)}></div>');
    }

    final marker = _setupMarker.firstMatch(html);
    if (marker == null) return null;
    final start = html.lastIndexOf('<', marker.start);
    final end = html.indexOf('>', marker.end);
    if (start < 0 || end < 0) return null;
    parts.add(html.substring(start, end + 1));

    final baseUri = _baseUriMeta.firstMatch(html);
    if (baseUri != null) parts.add(baseUri.group(0)!);
    return parts.join('\n');
  }
}
