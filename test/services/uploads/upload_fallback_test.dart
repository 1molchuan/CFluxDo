import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/uploads/s3_multipart_upload.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingStorage implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    await requestStream?.drain<void>();
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'storage unreachable',
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('对象存储连不上时放弃分片、改走普通上传，合并请求不会发出', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
    final loaded = await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup">'
      '<script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'enable_direct_s3_uploads': true},
        'site': {'categories': []},
      })}</script>',
    );
    expect(loaded, isTrue);

    final storage = _FailingStorage();
    S3MultipartUpload.debugStorageFactory = () =>
        Dio()..httpClientAdapter = storage;
    addTearDown(() => S3MultipartUpload.debugStorageFactory = null);

    final paths = <String>[];
    final service = DiscourseService();
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        paths.add(options.path);
        final data = switch (options.path) {
          '/uploads/create-multipart.json' => {
            'external_upload_identifier': 'external',
            'unique_identifier': 'unique',
          },
          '/uploads/batch-presign-multipart-parts.json' => {
            'presigned_urls': {'1': 'https://storage.test/1?signature=x'},
          },
          '/uploads.json' => {
            'id': 7,
            'short_url': 'upload://standard.jpeg',
            'url': '/uploads/standard.jpeg',
          },
          _ => {'success': 'OK'},
        };
        handler.resolve(Response(requestOptions: options, data: data));
      },
    );
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));

    final dir = await Directory.systemTemp.createTemp('upload-fallback');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/photo.jpg')
      ..writeAsBytesSync(List.filled(2048, 7));

    final result = await service.uploadFile(file.path);

    expect(result.shortUrl, 'upload://standard.jpeg');
    expect(storage.calls, 3, reason: '分片 PUT 先按原逻辑重试三次');
    expect(paths, contains('/uploads/abort-multipart.json'));
    expect(paths, isNot(contains('/uploads/complete-multipart.json')));
    expect(paths.last, '/uploads.json');
  });
}
