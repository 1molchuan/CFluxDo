import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 证书 SubjectPublicKeyInfo 的 SHA-256（Base64），即 Chromium
/// `--ignore-certificate-errors-spki-list` 要的格式。
///
/// Windows 的 WebView2 用它只信任本机代理的设备 CA：链上任一证书的公钥摘要
/// 命中就放行，作用范围只限 App 自己的 WebView2，不进系统根信任库。
/// 解析失败返回 null（调用方按「不加这个参数」处理）。
String? spkiSha256Base64(String certPem) {
  final der = _pemToDer(certPem);
  if (der == null) return null;
  try {
    final spki = _subjectPublicKeyInfo(der);
    if (spki == null) return null;
    return base64.encode(sha256.convert(spki).bytes);
  } on RangeError {
    return null;
  }
}

Uint8List? _pemToDer(String pem) {
  final body = pem
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  if (body.isEmpty) return null;
  try {
    return base64.decode(body);
  } on FormatException {
    return null;
  }
}

/// Certificate ::= SEQUENCE { tbsCertificate, ... }
/// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
///   issuer, validity, subject, subjectPublicKeyInfo, ... }
/// 返回 subjectPublicKeyInfo 的完整 DER（含标签与长度）
Uint8List? _subjectPublicKeyInfo(Uint8List der) {
  final cert = _readTlv(der, 0);
  if (cert == null || cert.tag != 0x30) return null;
  final tbs = _readTlv(der, cert.contentStart);
  if (tbs == null || tbs.tag != 0x30) return null;
  var offset = tbs.contentStart;
  final first = _readTlv(der, offset);
  if (first == null) return null;
  // 跳过可选的 [0] version
  if (first.tag == 0xA0) offset = first.end;
  // serialNumber、signature、issuer、validity、subject
  for (var i = 0; i < 5; i++) {
    final field = _readTlv(der, offset);
    if (field == null) return null;
    offset = field.end;
  }
  final spki = _readTlv(der, offset);
  if (spki == null || spki.tag != 0x30) return null;
  return Uint8List.sublistView(der, offset, spki.end);
}

class _Tlv {
  const _Tlv(this.tag, this.contentStart, this.end);
  final int tag;
  final int contentStart;
  final int end;
}

_Tlv? _readTlv(Uint8List der, int offset) {
  if (offset + 2 > der.length) return null;
  final tag = der[offset];
  var lenByte = der[offset + 1];
  var pos = offset + 2;
  int length;
  if (lenByte < 0x80) {
    length = lenByte;
  } else {
    final n = lenByte & 0x7F;
    if (n == 0 || n > 4 || pos + n > der.length) return null;
    length = 0;
    for (var i = 0; i < n; i++) {
      length = (length << 8) | der[pos + i];
    }
    pos += n;
  }
  final end = pos + length;
  if (end > der.length) return null;
  return _Tlv(tag, pos, end);
}
