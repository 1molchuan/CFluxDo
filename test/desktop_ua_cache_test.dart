import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';

/// 桌面 WebView UA 按运行时版本缓存：版本一致才用，其余情况都重新探
void main() {
  test('版本一致返回缓存的 UA', () {
    final cached = jsonEncode({'version': '141.0.3537.57', 'ua': 'Mozilla/5.0 x'});
    expect(
      AppConstants.desktopUaFromCache(cached, '141.0.3537.57'),
      'Mozilla/5.0 x',
    );
  });

  test('版本变了、缓存为空、JSON 坏掉或 UA 为空都不用缓存', () {
    final old = jsonEncode({'version': '140.0.0.0', 'ua': 'Mozilla/5.0 x'});
    expect(AppConstants.desktopUaFromCache(old, '141.0.3537.57'), isNull);
    expect(AppConstants.desktopUaFromCache(null, '141.0.3537.57'), isNull);
    expect(AppConstants.desktopUaFromCache('', '141.0.3537.57'), isNull);
    expect(AppConstants.desktopUaFromCache('{not json', '141.0.3537.57'), isNull);
    expect(
      AppConstants.desktopUaFromCache(
        jsonEncode({'version': '141.0.3537.57', 'ua': ''}),
        '141.0.3537.57',
      ),
      isNull,
    );
  });
}
