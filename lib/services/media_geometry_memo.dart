import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'site_context.dart';

/// url → 自然尺寸(w,h)的持久记忆。
///
/// 服务对象是**无声明尺寸**的媒体(签名图、动态徽章、无 width/height
/// 的 SVG):这类图首次加载前无从得知高度,布局只能先占位后落位,产生
/// 一次高度跳变。首次实测后记入本备忘,此后任何挂载(含冷启动)在
/// 加载完成前即可同步取到尺寸、预留精确高度——跳变只发生在"人生第一次"。
///
/// cooked HTML 里带 width/height 属性的帖内图不需要它(布局早已恒定)。
class MediaGeometryMemo {
  MediaGeometryMemo._();

  static final Map<String, (double, double)> _mem = {};
  static Future<void>? _loadFuture;
  static Timer? _saveTimer;
  static const int _cap = 256;

  /// 同步查询;顺带触发首次磁盘加载(异步,极快,冷启动首屏前通常已就绪)。
  static (double, double)? peek(String url) {
    unawaited(ensureLoaded());
    final v = _mem.remove(url);
    if (v != null) _mem[url] = v; // LRU 触摸
    return v;
  }

  static void remember(String url, double w, double h) {
    if (w <= 0 || h <= 0 || url.isEmpty) return;
    final cur = _mem[url];
    if (cur != null && (cur.$1 - w).abs() < 0.5 && (cur.$2 - h).abs() < 0.5) {
      return;
    }
    _mem.remove(url);
    _mem[url] = (w, h);
    while (_mem.length > _cap) {
      _mem.remove(_mem.keys.first);
    }
    // 防抖落盘:密集滚动中多次 remember 合并为一次写
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(_save()));
  }

  static Future<void> ensureLoaded() => _loadFuture ??= _load();

  static Future<File> _file() async {
    final dir = await SiteContext.supportDirectory();
    return File('${dir.path}/media_geometry_memo.json');
  }

  static Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      for (final e in raw.entries) {
        final v = e.value;
        if (v is List && v.length == 2) {
          final w = (v[0] as num).toDouble();
          final h = (v[1] as num).toDouble();
          // 磁盘旧值不覆盖本会话已实测的新值
          if (w > 0 && h > 0) _mem.putIfAbsent(e.key, () => (w, h));
        }
      }
    } catch (e) {
      debugPrint('[MediaGeometryMemo] load 失败: $e');
    }
  }

  static Future<void> _save() async {
    try {
      final file = await _file();
      final out = <String, List<double>>{
        for (final e in _mem.entries) e.key: [e.value.$1, e.value.$2],
      };
      await file.writeAsString(jsonEncode(out), flush: false);
    } catch (e) {
      debugPrint('[MediaGeometryMemo] save 失败: $e');
    }
  }
}
