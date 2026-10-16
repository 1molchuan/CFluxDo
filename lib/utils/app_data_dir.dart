import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App 自己的数据目录（Cookie、数据库、日志等）。
///
/// Android 上沿用 [getApplicationDocumentsDirectory]（应用私有目录，旧数据都在这里，
/// 不迁移）。桌面上那是用户的「文档」文件夹，所以改用应用数据目录：
/// - Linux：XDG 数据目录 `~/.local/share/<app id>`（没配置 XDG 用户目录时「文档」还会直接抛异常）；
///   在 Flatpak 里会自动落到 `~/.var/app/<app id>/data/<app id>`
/// - Windows：`%APPDATA%\<公司名>\<产品名>`（取自 Runner.rc）
Future<Directory> getAppDataDirectory() {
  if (Platform.isLinux || Platform.isWindows) {
    return getApplicationSupportDirectory();
  }
  return getApplicationDocumentsDirectory();
}
