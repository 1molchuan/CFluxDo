import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'sfnt_name_reader.dart';

/// 一个可选的系统字体 family。
class SystemFont {
  const SystemFont(this.family, [this.localizedFamily]);

  /// 渲染用 family 名：写进 `TextStyle.fontFamily` 交给引擎匹配的值。
  final String family;

  /// 中文本地化名（如「微软雅黑」），仅用于展示；没有则为 null。
  final String? localizedFamily;

  /// 界面展示名。中文界面优先本地化名，其它语言用 [family]（引擎匹配名）。
  String label({required bool localized}) =>
      localized ? (localizedFamily ?? family) : family;
}

/// 系统已安装字体的枚举。
///
/// 与 [CustomFontService] 不同，这里**不往引擎注册字体字节**：直接用系统字体
/// 的 family 名走引擎自己的字体管理器（Windows DirectWrite / Linux
/// fontconfig / Android Skia 的 Android font manager）。代价是名字必须与引擎
/// 认的一致，好处是 .ttc 字体集合（微软雅黑、宋体等 CJK 字体几乎都是集合）
/// 与可变字体都能原生支持，也不用把 20MB 的字体拷进私有目录。
///
/// 名字来源按平台取「引擎同一份数据」：
/// - Windows：扫描系统字体目录里的 ttf/otf/ttc 的 name 表；
/// - Linux：扫描 fontconfig 默认字体目录里的字体文件 name 表（fontconfig 的
///   family 也正是它从 name 表读出来的值）；
/// - Android：解析 `/system/etc/fonts.xml` 的 `<family name=...>`（Skia 用同一份
///   配置做 family 匹配）。
///
/// 名字匹配失败时引擎会静默回落到默认字体（不报错），因此这里的名字只是
/// 「候选」：字号/字形不对说明该 family 在引擎侧不存在。
class SystemFontService {
  SystemFontService._();

  /// 选中的 family（渲染用，SharedPreferences）
  static const String familyPrefKey = 'system_font_family';

  /// 选中的展示名（SharedPreferences；与 family 相同则没有本地化名）
  static const String namePrefKey = 'system_font_name';

  /// 通用族名（Android 的 `<family name="sans-serif">` 一类）：不是具体字体，
  /// 排在列表最后。
  static const Set<String> genericFamilies = {
    'sans',
    'sans-serif',
    'sans-serif-black',
    'sans-serif-condensed',
    'sans-serif-light',
    'sans-serif-medium',
    'sans-serif-smallcaps',
    'sans-serif-thin',
    'serif',
    'serif-monospace',
    'monospace',
    'cursive',
    'casual',
    'fantasy',
    'system-ui',
  };

  static const List<String> _fontExtensions = [
    '.ttf',
    '.otf',
    '.ttc',
    '.otc',
  ];

  /// Android 各分区上的字体配置；引擎默认读 `/system/etc/fonts.xml`，
  /// 其余只在它不存在时兜底（部分定制 ROM 把配置挪到 vendor/product）。
  static const List<String> _androidFontConfigs = [
    '/system/etc/fonts.xml',
    '/system_ext/etc/fonts.xml',
    '/product/etc/fonts.xml',
    '/vendor/etc/fonts.xml',
  ];

  static Future<List<SystemFont>>? _cache;

  /// 枚举系统字体（首次调用后台 isolate 跑，之后走内存缓存）。
  static Future<List<SystemFont>> list() => _cache ??= _enumerateInIsolate();

  /// 丢弃缓存，下次 [list] 重新扫描（字体安装/卸载后刷新用）。
  @visibleForTesting
  static void clearCache() => _cache = null;

  static Future<List<SystemFont>> _enumerateInIsolate() =>
      Isolate.run(_enumerate);

  /// isolate 入口：同步、纯 dart:io，结果类型只有基本类型与 String。
  static List<SystemFont> _enumerate() {
    try {
      if (Platform.isAndroid) return _androidFonts();
      if (Platform.isWindows) return _scanDirectories(_windowsFontDirs());
      return _scanDirectories(_linuxFontDirs());
    } catch (e) {
      debugPrint('[SystemFont] 枚举系统字体失败: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 字体目录扫描（Windows / Linux）
  // ══════════════════════════════════════════════════════════════

  static List<String> _windowsFontDirs() {
    final dirs = <String>[];
    final windir = Platform.environment['WINDIR'];
    if (windir != null && windir.isNotEmpty) {
      dirs.add(p.join(windir, 'Fonts'));
    }
    // Win10+ 的「仅为当前用户安装」字体
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      dirs.add(p.join(localAppData, 'Microsoft', 'Windows', 'Fonts'));
    }
    return dirs;
  }

  static List<String> _linuxFontDirs() {
    final dirs = <String>['/usr/share/fonts', '/usr/local/share/fonts'];
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final xdgDataHome = Platform.environment['XDG_DATA_HOME'];
      dirs.add(
        xdgDataHome != null && xdgDataHome.isNotEmpty
            ? p.join(xdgDataHome, 'fonts')
            : p.join(home, '.local', 'share', 'fonts'),
      );
      dirs.add(p.join(home, '.fonts'));
    }
    return dirs;
  }

  static List<SystemFont> _scanDirectories(List<String> dirs) {
    // key 用小写 family：同一字体常被多个子族/文件/目录重复登记
    final found = <String, SystemFont>{};
    for (final dirPath in dirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(recursive: true, followLinks: false);
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        if (!_isFontFile(entry.path)) continue;
        try {
          _readFontFile(entry.path, found);
        } catch (_) {
          // 单个坏字体（截断/权限）不影响整轮枚举
        }
      }
    }
    return _sorted(found.values);
  }

  static bool _isFontFile(String path) {
    final lower = path.toLowerCase();
    return _fontExtensions.any(lower.endsWith);
  }

  static void _readFontFile(String path, Map<String, SystemFont> out) {
    final handle = File(path).openSync();
    try {
      Uint8List read(int offset, int length) {
        if (offset < 0 || length <= 0) return Uint8List(0);
        handle.setPositionSync(offset);
        return handle.readSync(length);
      }

      for (final names in readSfntFamilies(read)) {
        out.putIfAbsent(
          names.family.toLowerCase(),
          () => SystemFont(names.family, names.localizedFamily),
        );
      }
    } finally {
      handle.closeSync();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Android：解析 fonts.xml
  // ══════════════════════════════════════════════════════════════

  static List<SystemFont> _androidFonts() {
    for (final path in _androidFontConfigs) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final List<SystemFont> fonts;
      try {
        fonts = parseAndroidFontConfig(file.readAsStringSync());
      } catch (_) {
        continue;
      }
      if (fonts.isNotEmpty) return fonts;
    }
    return const [];
  }

  /// 从 fonts.xml 文本里取出所有 `<family name="...">`。
  ///
  /// 只认 family 属性，不收 `<alias>`：别名只是把通用名指向某个 family，
  /// 选它不如直接选那个 family。
  @visibleForTesting
  static List<SystemFont> parseAndroidFontConfig(String xml) {
    final pattern = RegExp(r'<family\s+[^>]*\bname\s*=\s*"([^"]+)"');
    final found = <String, SystemFont>{};
    for (final match in pattern.allMatches(xml)) {
      final name = match.group(1)?.trim();
      if (name == null || name.isEmpty) continue;
      found.putIfAbsent(name.toLowerCase(), () => SystemFont(name));
    }
    return _sorted(found.values);
  }

  // ══════════════════════════════════════════════════════════════
  // 排序
  // ══════════════════════════════════════════════════════════════

  /// 具体字体按 family 名排序，通用族（sans-serif 等）沉到最后。
  static List<SystemFont> _sorted(Iterable<SystemFont> fonts) {
    final sorted = fonts.toList();
    sorted.sort((a, b) {
      final aGeneric = genericFamilies.contains(a.family.toLowerCase());
      final bGeneric = genericFamilies.contains(b.family.toLowerCase());
      if (aGeneric != bGeneric) return aGeneric ? 1 : -1;
      return a.family.toLowerCase().compareTo(b.family.toLowerCase());
    });
    return sorted;
  }
}
