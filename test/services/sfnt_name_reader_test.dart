import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/fonts/sfnt_name_reader.dart';

/// 构造 name 表记录的参数（platform/encoding/language/nameId/值）。
class _Name {
  const _Name(
    this.platform,
    this.encoding,
    this.language,
    this.nameId,
    this.value, {
    this.ucs4 = false,
  });

  final int platform;
  final int encoding;
  final int language;
  final int nameId;
  final String value;

  /// 值按 UCS-4（encoding 10）编码，而不是默认的 UTF-16BE
  final bool ucs4;
}

const int _platformUnicode = 0;
const int _platformMac = 1;
const int _platformWindows = 3;
const int _langEnUs = 0x0409;
const int _langZhCn = 0x0804;
const int _langZhTw = 0x0404;

const int _nameIdFamily = 1;
const int _nameIdSubfamily = 2;
const int _nameIdTypographicFamily = 16;

void main() {
  group('SFNT family 名字选择', () {
    test('排版 family（nameID 16）优先于 family（nameID 1），子族记录被忽略', () {
      final font = _sfnt([
        const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, 'Example Narrow'),
        const _Name(_platformWindows, 1, _langEnUs, _nameIdSubfamily, 'Bold'),
        const _Name(
          _platformWindows,
          1,
          _langEnUs,
          _nameIdTypographicFamily,
          'Example',
        ),
      ]);

      final names = readSfntFamilies(_reader(font));
      expect(names, hasLength(1));
      expect(names.single.family, 'Example');
      expect(names.single.localizedFamily, isNull);
    });

    test('中文记录作为展示名，渲染名仍取英文', () {
      final font = _sfnt([
        const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, 'YaHei Demo'),
        const _Name(_platformWindows, 1, _langZhCn, _nameIdFamily, '雅黑示例'),
        const _Name(_platformWindows, 1, _langZhTw, _nameIdFamily, '雅黑示例繁體'),
      ]);

      final names = readSfntFamilies(_reader(font));
      expect(names.single.family, 'YaHei Demo');
      // 同级记录按表内顺序取第一个命中的中文名
      expect(names.single.localizedFamily, '雅黑示例');
    });

    test('没有英文记录时退回本地化名，且不重复产出展示名', () {
      final font = _sfnt([
        const _Name(_platformWindows, 1, _langZhCn, _nameIdFamily, '示例字体'),
      ]);

      final names = readSfntFamilies(_reader(font));
      expect(names.single.family, '示例字体');
      expect(names.single.localizedFamily, isNull);
    });

    test('Unicode 平台记录可用，UCS-4（encoding 10）可解码', () {
      final font = _sfnt([
        const _Name(_platformUnicode, 3, 0, _nameIdFamily, 'Unicode Family'),
        const _Name(
          _platformWindows,
          10,
          _langEnUs,
          _nameIdTypographicFamily,
          'Wide Family',
          ucs4: true,
        ),
      ]);

      final names = readSfntFamilies(_reader(font));
      expect(names.single.family, 'Wide Family');
    });

    test('Macintosh 记录只作最后兜底', () {
      final font = _sfnt([
        const _Name(_platformMac, 0, 0, _nameIdFamily, 'Mac Family'),
      ]);

      expect(readSfntFamilies(_reader(font)).single.family, 'Mac Family');
    });

    test('控制字符与 NUL 被清掉，空名不产出条目', () {
      final font = _sfnt([
        const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, '\u0000Trim Me\u0000'),
        const _Name(_platformWindows, 1, _langEnUs, _nameIdTypographicFamily, '\u0000'),
      ]);

      final names = readSfntFamilies(_reader(font));
      expect(names.single.family, 'Trim Me');
    });
  });

  group('字体集合（.ttc）', () {
    test('逐个读出子字体的 family', () {
      final ttc = _ttc([
        [
          const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, 'Ttc One'),
        ],
        [
          const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, 'Ttc Two'),
          const _Name(_platformWindows, 1, _langZhCn, _nameIdFamily, '集合二'),
        ],
      ]);

      final names = readSfntFamilies(_reader(ttc));
      expect(names.map((n) => n.family).toList(), ['Ttc One', 'Ttc Two']);
      expect(names.last.localizedFamily, '集合二');
    });
  });

  group('坏数据容错', () {
    test('头部不足 12 字节返回空表', () {
      expect(readSfntFamilies(_reader(Uint8List.fromList(List.filled(8, 0)))), isEmpty);
    });

    test('表数量异常（0xFFFF）时不按垃圾长度分配并返回空表', () {
      final bytes = BytesBuilder()
        ..add(_be32(0x00010000))
        ..add(_be16(0xFFFF))
        ..add(_be16(0))
        ..add(_be16(0))
        ..add(_be16(0));
      expect(readSfntFamilies(_reader(bytes.toBytes())), isEmpty);
    });

    test('字体集合子字体数量异常时返回空表', () {
      final header = BytesBuilder()
        ..add('ttcf'.codeUnits)
        ..add(_be32(0x00010000))
        ..add(_be32(0xFFFFFFFF));
      expect(readSfntFamilies(_reader(header.toBytes())), isEmpty);
    });

    test('文件被截断（name 表超出 EOF）时不抛异常', () {
      final font = _sfnt([
        const _Name(_platformWindows, 1, _langEnUs, _nameIdFamily, 'Truncated'),
      ]);
      // 读到 name 表一半就 EOF：解析侧按可用字节处理，不应抛异常
      expect(
        () => readSfntFamilies(_reader(font, eof: font.length - 20)),
        returnsNormally,
      );
      // 整表都读不到时退化为空表
      expect(readSfntFamilies(_reader(font, eof: 40)), isEmpty);
    });
  });
}

/// 按 [bytes] 做随机访问读取，可按 [eof] 模拟文件被截断。
FontBytesReader _reader(Uint8List bytes, {int? eof}) {
  final limit = eof ?? bytes.length;
  return (offset, length) {
    if (offset < 0 || length <= 0 || offset >= limit) return Uint8List(0);
    return Uint8List.sublistView(
      bytes,
      offset,
      math.min(offset + length, limit),
    );
  };
}

/// 单个字体（不含 .ttc 容器）
Uint8List _sfnt(List<_Name> names) => _buildSfnt(_buildNameTable(names));

/// 字体集合：子字体的表偏移是相对文件起点的绝对偏移（SFNT/TTC 规范）
Uint8List _ttc(List<List<_Name>> subfonts) {
  final tables = [for (final names in subfonts) _buildNameTable(names)];
  var offset = 12 + tables.length * 4;
  final bases = <int>[];
  for (final table in tables) {
    bases.add(offset);
    // 子字体长度与 base 无关（base 只影响表记录里的偏移值）
    offset += _buildSfnt(table, base: 0).length;
  }

  final header = BytesBuilder()
    ..add('ttcf'.codeUnits)
    ..add(_be32(0x00010000))
    ..add(_be32(tables.length));
  for (final base in bases) {
    header.add(_be32(base));
  }

  final builder = BytesBuilder()..add(header.toBytes());
  for (var i = 0; i < tables.length; i++) {
    builder.add(_buildSfnt(tables[i], base: bases[i]));
  }
  return Uint8List.fromList(builder.toBytes());
}

/// 组装一个只含 head / name 两张表的最小 SFNT；[base] 为它在容器里的起点。
Uint8List _buildSfnt(Uint8List nameTable, {int base = 0}) {
  final tables = <(String, Uint8List)>[
    ('head', Uint8List(54)),
    ('name', nameTable),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  final recordSize = tables.length * 16;
  var dataOffset = base + 12 + recordSize;
  final directory = BytesBuilder();
  final body = BytesBuilder();
  for (final (tag, data) in tables) {
    directory.add(tag.codeUnits);
    directory.add(_be32(0)); // checksum
    directory.add(_be32(dataOffset));
    directory.add(_be32(data.length));
    body.add(data);
    dataOffset += data.length;
  }

  final header = BytesBuilder()
    ..add(_be32(0x00010000))
    ..add(_be16(tables.length))
    ..add(_be16(0))
    ..add(_be16(0))
    ..add(_be16(0));

  return Uint8List.fromList([
    ...header.toBytes(),
    ...directory.toBytes(),
    ...body.toBytes(),
  ]);
}

Uint8List _buildNameTable(List<_Name> names) {
  final storage = BytesBuilder();
  final records = BytesBuilder();
  for (final name in names) {
    final value = name.ucs4 ? _ucs4be(name.value) : _utf16be(name.value);
    records.add(_be16(name.platform));
    records.add(_be16(name.encoding));
    records.add(_be16(name.language));
    records.add(_be16(name.nameId));
    records.add(_be16(value.length));
    records.add(_be16(storage.length));
    storage.add(value);
  }

  final header = BytesBuilder()
    ..add(_be16(0)) // format
    ..add(_be16(names.length)) // count
    ..add(_be16(6 + names.length * 12)); // stringOffset

  return Uint8List.fromList([
    ...header.toBytes(),
    ...records.toBytes(),
    ...storage.toBytes(),
  ]);
}

List<int> _be16(int value) => [value >> 8 & 0xff, value & 0xff];

List<int> _be32(int value) => [
  value >> 24 & 0xff,
  value >> 16 & 0xff,
  value >> 8 & 0xff,
  value & 0xff,
];

List<int> _utf16be(String value) => [
  for (final unit in value.codeUnits) ..._be16(unit),
];

List<int> _ucs4be(String value) => [
  for (final code in value.runes) ..._be32(code),
];
