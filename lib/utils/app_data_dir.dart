import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// App 自己的数据目录（Cookie、数据库、日志等）。
///
/// Android 上沿用 [getApplicationDocumentsDirectory]（应用私有目录，旧数据都在这里，
/// 不迁移）。Linux 上那是用户的「文档」文件夹，没配置 XDG 用户目录时还会直接抛异常，
/// 所以改用 XDG 数据目录 `~/.local/share/<app id>`；在 Flatpak 里会自动落到
/// `~/.var/app/<app id>/data/<app id>`
Future<Directory> getAppDataDirectory() {
  if (Platform.isLinux) {
    return getApplicationSupportDirectory();
  }
  return getApplicationDocumentsDirectory();
}
