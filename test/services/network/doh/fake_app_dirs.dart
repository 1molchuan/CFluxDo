import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 应用目录全指向一个临时目录
///
/// 测试跑在 Linux 宿主上，桌面平台强制设备 CA，启动代理会去应用数据目录读写 `certs/`；
/// 测试环境没有 path_provider 的原生实现，不替换就是 MissingPluginException
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// 换上临时目录，返回它（用完由调用方删除）
Directory useTempAppDirs() {
  final dir = Directory.systemTemp.createTempSync('cfluxdo_test_');
  PathProviderPlatform.instance = _TempPathProvider(dir.path);
  return dir;
}
