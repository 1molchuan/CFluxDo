import 'dart:typed_data';

/// 随机访问式字节读取回调：返回 `[offset, offset + length)` 区间的字节。
///
/// 允许越界：文件尾之后读不到数据时返回的字节数可以少于 `length`，解析侧
/// 一律按实际返回长度处理（真实字体库里存在 name 表长度超出文件尾的坏字体）。
typedef FontBytesReader = Uint8List Function(int offset, int length);

/// 字体文件里读出的 family 名。
class SfntFamilyNames {
  const SfntFamilyNames({required this.family, this.localizedFamily});

  /// 渲染用 family：交给引擎按 family 匹配系统字体时用的名字。
  ///
  /// 优先排版 family（nameID 16，把 Semibold 之类的子族归并回一家），退回
  /// family（nameID 1）；语言优先英文记录——Windows DirectWrite / Linux
  /// fontconfig 都认本地化名，但英文名是各平台交集。
  final String family;

  /// 中文本地化 family（简中/繁中/港/新），仅用于界面展示；没有则为 null。
  final String? localizedFamily;
}

/// name 表里 family 相关记录的 id：16 = 排版 family，1 = family。
const int _nameIdTypographicFamily = 16;
const int _nameIdFamily = 1;

/// Windows 平台英文（美国）语言 id
const int _langEnUs = 0x0409;

/// 中文本地化语言 id：zh-CN / zh-TW / zh-HK / zh-SG
const Set<int> _langZh = {0x0804, 0x0404, 0x0C04, 0x1004};

/// 平台 id：0 = Unicode，1 = Macintosh，3 = Windows
const int _platformUnicode = 0;
const int _platformWindows = 3;

/// 真实字体最多几十张表；超出的按坏文件处理，避免按垃圾长度分配内存。
const int _maxTables = 4096;

/// name 表正常在几 KB 量级（CJK 大字体也不过 20KB 上下）。
const int _maxNameTableLength = 1 << 20;

/// 一个 .ttc 里的子字体会不会多到离谱？真实集合字体顶多几十个。
const int _maxSubfonts = 128;

/// 解析字体文件的 `name` 表，返回每个子字体（.ttc/.otc 可能多个）的 family 名。
///
/// 只读 name 表所在区间，不整文件读入——系统字体目录动辄几百个大文件
/// （Windows 的 msyh.ttc 单个 19MB），全量读盘不可接受。
///
/// 无法识别（非 SFNT、表目录损坏、没有 name 表、没有 family 记录）时返回空表。
List<SfntFamilyNames> readSfntFamilies(FontBytesReader read) {
  final result = <SfntFamilyNames>[];
  for (final base in _subfontOffsets(read)) {
    final names = _readSubfont(read, base);
    if (names != null) result.add(names);
  }
  return result;
}

/// 子字体起点：普通 SFNT 是 0，.ttc/.otc 从 ttcf 头里逐个取。
List<int> _subfontOffsets(FontBytesReader read) {
  final header = read(0, 12);
  if (header.length < 12) return const [];
  // 'ttcf'：字体集合，头部之后是各子字体表目录的绝对偏移
  if (_u32(header, 0) != 0x74746366) return const [0];
  final count = _u32(header, 8);
  if (count == 0 || count > _maxSubfonts) return const [];
  final offsets = read(12, count * 4);
  final available = offsets.length ~/ 4;
  return [for (var i = 0; i < available; i++) _u32(offsets, i * 4)];
}

SfntFamilyNames? _readSubfont(FontBytesReader read, int base) {
  final head = read(base + 4, 2);
  if (head.length < 2) return null;
  final numTables = _u16(head, 0);
  if (numTables == 0 || numTables > _maxTables) return null;

  final records = read(base + 12, numTables * 16);
  final available = records.length ~/ 16;
  var nameOffset = -1;
  var nameLength = 0;
  for (var i = 0; i < available; i++) {
    final o = i * 16;
    if (records[o] == 0x6E && // n
        records[o + 1] == 0x61 && // a
        records[o + 2] == 0x6D && // m
        records[o + 3] == 0x65) {
      // e
      nameOffset = _u32(records, o + 8);
      nameLength = _u32(records, o + 12);
      break;
    }
  }
  if (nameOffset < 0 || nameLength < 6 || nameLength > _maxNameTableLength) {
    return null;
  }

  final table = read(nameOffset, nameLength);
  if (table.length < 6) return null;

  final count = _u16(table, 2);
  final storageOffset = _u16(table, 4);
  final names = <(int, int, int, String)>[];

  for (var i = 0; i < count; i++) {
    final o = 6 + i * 12;
    if (o + 12 > table.length) break;
    final nameId = _u16(table, o + 6);
    if (nameId != _nameIdFamily && nameId != _nameIdTypographicFamily) continue;
    final platform = _u16(table, o);
    final encoding = _u16(table, o + 2);
    final language = _u16(table, o + 4);
    final start = storageOffset + _u16(table, o + 10);
    final end = start + _u16(table, o + 8);
    if (start >= table.length || end > table.length) continue;
    final value = _decode(
      platform,
      encoding,
      Uint8List.sublistView(table, start, end),
    );
    if (value != null) names.add((nameId, platform, language, value));
  }
  if (names.isEmpty) return null;

  String? pick(bool Function(int nameId, int platform, int language) test) {
    for (final (nameId, platform, language, value) in names) {
      if (test(nameId, platform, language)) return value;
    }
    return null;
  }

  final family =
      pick(
        (id, p, l) => id == _nameIdTypographicFamily && p == _platformWindows && l == _langEnUs,
      ) ??
      pick(
        (id, p, l) => id == _nameIdFamily && p == _platformWindows && l == _langEnUs,
      ) ??
      pick((id, p, l) => id == _nameIdTypographicFamily && p == _platformUnicode) ??
      pick((id, p, l) => id == _nameIdFamily && p == _platformUnicode) ??
      // 没有英文记录（部分国产/日文字体只带本地化名）时退回任意语言的 family
      pick((id, p, l) => id == _nameIdTypographicFamily) ??
      pick((id, p, l) => id == _nameIdFamily);
  if (family == null) return null;

  final localized =
      pick((id, p, l) => id == _nameIdTypographicFamily && _langZh.contains(l)) ??
      pick((id, p, l) => id == _nameIdFamily && _langZh.contains(l));

  return SfntFamilyNames(
    family: family,
    localizedFamily: localized == null || localized == family ? null : localized,
  );
}

/// 按平台解码字符串，得到净化后的非空值；编码不支持或内容为空时返回 null。
String? _decode(int platform, int encoding, Uint8List bytes) {
  final String decoded;
  if (platform == _platformWindows || platform == _platformUnicode) {
    if (encoding == 10) {
      // UCS-4
      if (bytes.length < 4) return null;
      final codes = <int>[
        for (var i = 0; i + 3 < bytes.length; i += 4) _u32(bytes, i),
      ];
      decoded = String.fromCharCodes(codes);
    } else {
      // UTF-16BE（Windows 记录几乎都是这个；encoding 0/1 都按 UTF-16 读）
      if (bytes.length < 2) return null;
      final units = <int>[
        for (var i = 0; i + 1 < bytes.length; i += 2) _u16(bytes, i),
      ];
      decoded = String.fromCharCodes(units);
    }
  } else if (platform == 1) {
    // Macintosh Roman：family 名基本都是 ASCII，按 Latin-1 读足够
    decoded = String.fromCharCodes(bytes);
  } else {
    return null;
  }

  // 坏字体里常见结尾 NUL / 控制字符，去掉再 trim
  final buffer = StringBuffer();
  for (final unit in decoded.codeUnits) {
    if (unit >= 0x20 && unit != 0x7F) buffer.writeCharCode(unit);
  }
  final result = buffer.toString().trim();
  return result.isEmpty ? null : result;
}

int _u16(Uint8List bytes, int offset) => (bytes[offset] << 8) | bytes[offset + 1];

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
