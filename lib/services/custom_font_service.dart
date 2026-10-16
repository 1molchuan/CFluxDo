import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户自选字体（本地字体文件）的导入、注册与文件管理。
///
/// 内置字体走 asset，编译期就登记在 `FontManifest.json` 里；用户自选的字体只能
/// 在运行时把字节交给引擎注册（[FontLoader] → `loadFontFromList`）。文件必须先
/// **复制**进应用私有目录：系统 picker 给的临时路径/授权 URI 重启后就失效了
/// （同 AppBackgroundService）。
///
/// 每次导入用一个**新的 family 名**（`FluxdoCustomFont_<文件名>`）：引擎按 family
/// 缓存 typeface，同名再注册只是把新字体叠加到旧字体后面，换字体不会立即生效。
/// 导入文件名带时间戳，family 名随之唯一。
class CustomFontService {
  CustomFontService._();

  /// 字体文件路径（SharedPreferences）
  static const String pathPrefKey = 'custom_font_path';

  /// 字体文件原始文件名，仅用于界面展示
  static const String namePrefKey = 'custom_font_name';

  /// 支持的扩展名。.ttc/.otc 是字体集合，FontLoader 只认单个字体，不收。
  static const List<String> supportedExtensions = ['ttf', 'otf'];

  static const String _dirName = 'custom_fonts';
  static const String _filePrefix = 'custom_font_';
  static const String _familyPrefix = 'FluxdoCustomFont';

  /// 已注册进引擎的 family：同一文件重复注册是白跑一遍读盘。
  static final Set<String> _registered = <String>{};

  /// 由文件路径推出的 family 名。同一路径恒定，因此无需额外持久化。
  static String familyNameFor(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return '${_familyPrefix}_$stem';
  }

  /// 拉起系统文件选择器并把字体复制进私有目录，返回新路径与原始文件名。
  /// 用户取消返回 null。
  static Future<({String path, String name})?> pickAndImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
    );
    final file = picked?.files.single;
    final sourcePath = file?.path;
    if (file == null || sourcePath == null) return null;

    final dir = await _fontDir();
    final dot = file.name.lastIndexOf('.');
    final ext = dot > 0 ? file.name.substring(dot).toLowerCase() : '.ttf';
    final target = File(
      '${dir.path}/$_filePrefix${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await File(sourcePath).copy(target.path);
    return (path: target.path, name: file.name);
  }

  /// 把字体文件注册进引擎。文件缺失、格式不被引擎接受时返回 false。
  static Future<bool> load(String path) async {
    final family = familyNameFor(path);
    if (_registered.contains(family)) return true;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      final bytes = await file.readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _registered.add(family);
      return true;
    } catch (e) {
      debugPrint('[CustomFont] 注册字体失败: $e');
      return false;
    }
  }

  /// 启动时按 prefs 记录注册用户字体。未配置或文件丢失时静默跳过，
  /// 界面回落到系统字体（设置页会提示文件已丢失）。
  static Future<bool> loadSaved(SharedPreferences prefs) async {
    final path = prefs.getString(pathPrefKey);
    if (path == null) return false;
    return load(path);
  }

  /// 删除已导入的字体文件（换字体/移除后调用；文件已不存在时静默跳过）。
  static Future<void> delete(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException {
      // 删除失败不影响主流程，残留文件随清缓存自然淘汰
    }
  }

  static Future<Directory> _fontDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_dirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }
}
