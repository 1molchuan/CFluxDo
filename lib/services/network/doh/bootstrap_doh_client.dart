import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../l10n/s.dart';
import '../../network_logger.dart';

/// DNS 记录类型
enum DnsRecordType {
  a(1), // IPv4
  aaaa(28); // IPv6

  const DnsRecordType(this.value);
  final int value;
}

/// DNS 解析结果，包含地址和 TTL
class DnsResult {
  DnsResult({required this.addresses, required this.minTtl});

  final List<InternetAddress> addresses;

  /// 所有应答记录中最小的 TTL（秒）
  final int minTtl;
}

/// 支持 Bootstrap IP 的 DOH 客户端
/// 类似 Chrome 的实现：预置 DOH 服务器的 IP，直接连接，绕过 DNS 解析
class BootstrapDohClient {
  BootstrapDohClient({
    required this.serverUrl,
    this.bootstrapIps = const [],
    this.timeout = const Duration(seconds: 5),
    this.preferIPv6 = false,
    this.authToken,
    this.onAuthRejected,
  }) {
    _parseServerUrl();
  }

  final String serverUrl;
  final List<String> bootstrapIps;
  final Duration timeout;

  /// DoH 访问令牌，非空时放在 `Authorization: Bearer` 里
  final String? authToken;

  /// 带令牌查询却被服务端以 401/403 拒绝时回调
  final void Function()? onAuthRejected;

  /// 是否优先使用 IPv6 连接 DOH 服务
  bool preferIPv6;

  late String _host;
  late int _port;
  late String _path;

  final _random = Random();

  /// 缓存的连接
  SecureSocket? _cachedSocket;
  DateTime? _socketCreatedAt;

  /// 连接最大存活时间
  static const _maxSocketAge = Duration(seconds: 30);

  void _parseServerUrl() {
    final uri = Uri.parse(serverUrl);
    _host = uri.host;
    _port = uri.port == 0 ? 443 : uri.port;
    _path = uri.path.isEmpty ? '/dns-query' : uri.path;
  }

  /// 查询单个地址
  Future<InternetAddress?> lookup(String host) async {
    final result = await lookupAllWithTtl(host);
    return result.addresses.isNotEmpty ? result.addresses.first : null;
  }

  /// 查询所有地址（同时查询 A 和 AAAA 记录）
  Future<List<InternetAddress>> lookupAll(String host) async {
    final result = await lookupAllWithTtl(host);
    return result.addresses;
  }

  /// 查询所有地址并返回 TTL
  Future<DnsResult> lookupAllWithTtl(String host) async {
    // 串行查询 A 和 AAAA 记录（共享单个 socket 连接，不能并行）
    final results = [
      await _lookupByType(host, DnsRecordType.a),
      await _lookupByType(host, DnsRecordType.aaaa),
    ];

    final addresses = <InternetAddress>[
      ...results[0].addresses,
      ...results[1].addresses,
    ];

    // 取两个查询结果中较小的 TTL
    final minTtl = [results[0].minTtl, results[1].minTtl]
        .where((t) => t > 0)
        .fold<int>(300, min); // 默认 300 秒

    return DnsResult(addresses: addresses, minTtl: minTtl);
  }

  /// 获取或创建连接
  Future<SecureSocket?> _getOrCreateSocket() async {
    // 检查缓存的连接是否可用
    if (_cachedSocket != null && _socketCreatedAt != null) {
      final age = DateTime.now().difference(_socketCreatedAt!);
      if (age < _maxSocketAge) {
        return _cachedSocket;
      }
      // 连接过期，关闭
      _closeSocket();
    }

    // 创建新连接
    SecureSocket? socket;
    Object? lastError;

    if (bootstrapIps.isNotEmpty) {
      final ipv4 = bootstrapIps.where((ip) => !ip.contains(':')).toList();
      final ipv6 = bootstrapIps.where((ip) => ip.contains(':')).toList();
      final sortedIps = preferIPv6 ? [...ipv6, ...ipv4] : [...ipv4, ...ipv6];

      NetworkLogger.log(
          '[DOH] 使用 Bootstrap IP 连接 $_host (IPv6优先: $preferIPv6): $sortedIps');

      for (final ip in sortedIps) {
        try {
          final address = InternetAddress(ip);
          final rawSocket = await Socket.connect(
            address,
            _port,
            timeout: timeout,
          );
          socket = await SecureSocket.secure(
            rawSocket,
            host: _host,
          );
          NetworkLogger.log('[DOH] Bootstrap IP 连接成功: $ip');
          break;
        } catch (e) {
          lastError = e;
          NetworkLogger.log('[DOH] Bootstrap IP 连接失败: $ip | $e');
          continue;
        }
      }
    } else {
      try {
        socket = await SecureSocket.connect(
          _host,
          _port,
          timeout: timeout,
        );
      } catch (e) {
        lastError = e;
      }
    }

    if (socket == null) {
      throw lastError ?? SocketException(S.current.doh_cannotConnect);
    }

    _cachedSocket = socket;
    _socketCreatedAt = DateTime.now();
    return socket;
  }

  void _closeSocket() {
    try {
      _cachedSocket?.destroy();
    } catch (_) {}
    _cachedSocket = null;
    _socketCreatedAt = null;
  }

  /// 按记录类型查询地址
  Future<DnsResult> _lookupByType(String host, DnsRecordType type) async {
    try {
      final query = _buildDnsQuery(host, type: type);
      final base64Query = base64Url.encode(query).replaceAll('=', '');
      final requestPath = '$_path?dns=$base64Query';

      // 尝试用缓存连接发送（keep-alive），失败则新建连接
      for (var attempt = 0; attempt < 2; attempt++) {
        SecureSocket? socket;
        final isReuse = attempt == 0 && _cachedSocket != null;

        try {
          if (isReuse) {
            socket = _cachedSocket;
          } else {
            _closeSocket();
            socket = await _getOrCreateSocket();
          }

          if (socket == null) {
            throw SocketException(S.current.doh_cannotConnect);
          }

          // 发送 HTTP/1.1 请求，使用 keep-alive
          final request = StringBuffer()
            ..writeln('GET $requestPath HTTP/1.1')
            ..writeln('Host: $_host')
            ..writeln('Accept: application/dns-message');
          final token = authToken;
          if (token != null && token.isNotEmpty) {
            request.writeln('Authorization: Bearer $token');
          }
          request
            ..writeln('Connection: keep-alive')
            ..writeln();

          socket.write(request.toString());
          await socket.flush();

          // 读取响应（字节级解析）
          final responseBytes = await _readHttpResponse(socket);
          if (responseBytes == null) {
            if (isReuse) {
              // 缓存连接可能已被服务端关闭，重试
              _closeSocket();
              continue;
            }
            throw HttpException(S.current.doh_invalidHttpResponse);
          }

          return _parseDnsResponse(responseBytes);
        } catch (e) {
          if (isReuse) {
            // 复用连接失败，清理后重试
            _closeSocket();
            continue;
          }
          _closeSocket();
          rethrow;
        }
      }

      throw SocketException(S.current.doh_queryFailed);
    } catch (e) {
      NetworkLogger.log('[DOH] 查询失败: $host | $e');
      rethrow;
    }
  }

  /// 在字节层面读取完整的 HTTP 响应 body
  /// 返回解码后的 DNS 响应字节，或 null 表示连接已关闭
  Future<Uint8List?> _readHttpResponse(SecureSocket socket) async {
    final allBytes = <int>[];
    final completer = Completer<Uint8List?>();
    StreamSubscription<Uint8List>? subscription;

    subscription = socket.listen(
      (data) {
        allBytes.addAll(data);

        // 在字节层面查找 \r\n\r\n (0x0D 0x0A 0x0D 0x0A)
        final headerEndIndex = _findHeaderEnd(allBytes);
        if (headerEndIndex == -1) return;

        final headerBytes = allBytes.sublist(0, headerEndIndex);
        final headerStr = ascii.decode(headerBytes, allowInvalid: true);
        final bodyStart = headerEndIndex + 4;

        // 检查状态码
        final statusLine = headerStr.split('\r\n').first;
        if (!statusLine.contains('200')) {
          subscription?.cancel();
          final token = authToken;
          if (token != null &&
              token.isNotEmpty &&
              (statusLine.contains(' 401') || statusLine.contains(' 403'))) {
            onAuthRejected?.call();
          }
          if (!completer.isCompleted) {
            completer.completeError(
                HttpException(S.current.doh_serverError(statusLine)));
          }
          return;
        }

        final headersLower = headerStr.toLowerCase();

        // 处理 chunked 编码
        if (headersLower.contains('transfer-encoding: chunked')) {
          // chunked 模式需要等待完整数据（以 0\r\n\r\n 结尾）
          if (_isChunkedComplete(allBytes, bodyStart)) {
            subscription?.cancel();
            final body = Uint8List.fromList(allBytes.sublist(bodyStart));
            if (!completer.isCompleted) {
              completer.complete(_decodeChunked(body));
            }
          }
          return;
        }

        // 处理 Content-Length
        final clMatch =
            RegExp(r'content-length:\s*(\d+)').firstMatch(headersLower);
        if (clMatch != null) {
          final contentLength = int.parse(clMatch.group(1)!);
          if (allBytes.length >= bodyStart + contentLength) {
            subscription?.cancel();
            if (!completer.isCompleted) {
              completer.complete(Uint8List.fromList(
                  allBytes.sublist(bodyStart, bodyStart + contentLength)));
            }
          }
          return;
        }

        // 没有 Content-Length 也没有 chunked，等连接关闭
      },
      onDone: () {
        if (!completer.isCompleted) {
          final headerEndIndex = _findHeaderEnd(allBytes);
          if (headerEndIndex == -1) {
            completer.complete(null);
            return;
          }
          final bodyStart = headerEndIndex + 4;
          if (bodyStart < allBytes.length) {
            completer
                .complete(Uint8List.fromList(allBytes.sublist(bodyStart)));
          } else {
            completer.complete(null);
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    return completer.future.timeout(timeout, onTimeout: () {
      subscription?.cancel();
      return null;
    });
  }

  /// 在字节流中查找 \r\n\r\n 的位置
  int _findHeaderEnd(List<int> bytes) {
    for (var i = 0; i <= bytes.length - 4; i++) {
      if (bytes[i] == 0x0D &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  /// 检查 chunked 编码数据是否完整（以 0\r\n\r\n 结尾）
  bool _isChunkedComplete(List<int> bytes, int bodyStart) {
    if (bytes.length < bodyStart + 5) return false;
    final len = bytes.length;
    // 检查末尾是否为 0\r\n\r\n
    return (bytes[len - 5] == 0x30 && // '0'
        bytes[len - 4] == 0x0D &&
        bytes[len - 3] == 0x0A &&
        bytes[len - 2] == 0x0D &&
        bytes[len - 1] == 0x0A);
  }

  /// 解码 chunked 传输编码
  Uint8List _decodeChunked(Uint8List data) {
    final result = BytesBuilder();
    var offset = 0;

    while (offset < data.length) {
      // 查找 chunk size 行的结尾
      var lineEnd = offset;
      while (lineEnd < data.length - 1) {
        if (data[lineEnd] == 0x0D && data[lineEnd + 1] == 0x0A) {
          break;
        }
        lineEnd++;
      }

      if (lineEnd >= data.length - 1) break;

      // 解析 chunk size
      final sizeStr = utf8.decode(data.sublist(offset, lineEnd));
      final chunkSize = int.tryParse(sizeStr.trim(), radix: 16) ?? 0;

      if (chunkSize == 0) break;

      // 跳过 \r\n
      offset = lineEnd + 2;

      // 读取 chunk 数据
      if (offset + chunkSize <= data.length) {
        result.add(data.sublist(offset, offset + chunkSize));
      }

      // 跳过 chunk 数据和结尾的 \r\n
      offset += chunkSize + 2;
    }

    return result.toBytes();
  }

  /// 构建 DNS 查询消息 (RFC 1035)
  Uint8List _buildDnsQuery(String host, {DnsRecordType type = DnsRecordType.a}) {
    final buffer = BytesBuilder();

    // Transaction ID (2 bytes) - 随机生成
    final txId = _random.nextInt(0xFFFF);
    buffer.addByte((txId >> 8) & 0xFF);
    buffer.addByte(txId & 0xFF);

    // Flags (2 bytes) - 标准查询，递归
    buffer.addByte(0x01); // RD = 1
    buffer.addByte(0x00);

    // Questions (2 bytes) - 1 个问题
    buffer.addByte(0x00);
    buffer.addByte(0x01);

    // Answer RRs (2 bytes) - 0
    buffer.addByte(0x00);
    buffer.addByte(0x00);

    // Authority RRs (2 bytes) - 0
    buffer.addByte(0x00);
    buffer.addByte(0x00);

    // Additional RRs (2 bytes) - 0
    buffer.addByte(0x00);
    buffer.addByte(0x00);

    // Question section - QNAME
    final labels = host.split('.');
    for (final label in labels) {
      buffer.addByte(label.length);
      buffer.add(utf8.encode(label));
    }
    buffer.addByte(0x00); // 结束标记

    // QTYPE (2 bytes)
    buffer.addByte((type.value >> 8) & 0xFF);
    buffer.addByte(type.value & 0xFF);

    // QCLASS (2 bytes) - IN = 1
    buffer.addByte(0x00);
    buffer.addByte(0x01);

    return buffer.toBytes();
  }

  /// 解析 DNS 响应，提取地址和 TTL
  DnsResult _parseDnsResponse(Uint8List data) {
    if (data.length < 12) return DnsResult(addresses: [], minTtl: 300);

    final addresses = <InternetAddress>[];
    var minTtl = 0x7FFFFFFF; // 初始化为最大值
    var hasRecord = false;

    // 跳过头部 (12 bytes)
    var offset = 12;

    // 跳过问题部分
    final qdcount = (data[4] << 8) | data[5];
    for (var i = 0; i < qdcount; i++) {
      offset = _skipName(data, offset);
      offset += 4; // QTYPE + QCLASS
    }

    // 解析回答部分
    final ancount = (data[6] << 8) | data[7];
    for (var i = 0; i < ancount; i++) {
      if (offset >= data.length) break;

      // 跳过 NAME
      offset = _skipName(data, offset);
      if (offset + 10 > data.length) break;

      // TYPE (2 bytes)
      final type = (data[offset] << 8) | data[offset + 1];
      offset += 2;

      // CLASS (2 bytes)
      offset += 2;

      // TTL (4 bytes) - 提取 TTL
      final ttl = (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
      offset += 4;

      // RDLENGTH (2 bytes)
      final rdlength = (data[offset] << 8) | data[offset + 1];
      offset += 2;

      if (offset + rdlength > data.length) break;

      // RDATA
      if (type == 1 && rdlength == 4) {
        // A 记录 (IPv4)
        final ip =
            '${data[offset]}.${data[offset + 1]}.${data[offset + 2]}.${data[offset + 3]}';
        addresses.add(InternetAddress(ip));
        hasRecord = true;
        if (ttl < minTtl) minTtl = ttl;
      } else if (type == 28 && rdlength == 16) {
        // AAAA 记录 (IPv6)
        final parts = <String>[];
        for (var j = 0; j < 16; j += 2) {
          parts.add(
              ((data[offset + j] << 8) | data[offset + j + 1]).toRadixString(16));
        }
        addresses.add(InternetAddress(parts.join(':')));
        hasRecord = true;
        if (ttl < minTtl) minTtl = ttl;
      }

      offset += rdlength;
    }

    // 限制 TTL 范围：最小 60 秒，最大 1800 秒（30 分钟）
    final clampedTtl = hasRecord ? minTtl.clamp(60, 1800) : 300;

    return DnsResult(addresses: addresses, minTtl: clampedTtl);
  }

  /// 跳过 DNS 名称字段
  int _skipName(Uint8List data, int offset) {
    while (offset < data.length) {
      final len = data[offset];
      if (len == 0) {
        return offset + 1;
      } else if ((len & 0xC0) == 0xC0) {
        // 压缩指针
        return offset + 2;
      } else {
        offset += len + 1;
      }
    }
    return offset;
  }

  void close() {
    _closeSocket();
  }
}
