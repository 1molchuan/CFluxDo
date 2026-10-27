import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo/services/storage/secret_store.dart';

/// 造一枚商城格式的 JWT（签名随便写，客户端不验签）。
String ldStoreJwt({
  Object sub = '12345',
  String site = 'linux.do',
  String username = 'alice',
  String alg = 'HS256',
  required DateTime expiresAt,
  DateTime? notBefore,
}) {
  String segment(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return [
    segment({'alg': alg, 'typ': 'JWT'}),
    segment({
      'sub': sub,
      'id': sub,
      'site': site,
      'username': username,
      'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
      if (notBefore != null) 'nbf': notBefore.millisecondsSinceEpoch ~/ 1000,
    }),
    'c2lnbmF0dXJl',
  ].join('.');
}

/// 商城后端回跳时带的 `ldsp_oauth`。
String ldStoreLoginParam(String token, {Object userId = 12345}) =>
    base64.encode(
      utf8.encode(
        jsonEncode({
          't': token,
          'u': {'id': userId, 'site': 'linux.do', 'username': 'alice'},
          'j': 1,
          'ts': 1,
        }),
      ),
    );

class FakeRoute {
  FakeRoute(this.status, {this.body, this.location});

  final int status;
  final Object? body;
  final String? location;
}

/// 按 URL（不含 query）路由的假适配器，记下每个请求。
class RoutingAdapter implements HttpClientAdapter {
  RoutingAdapter(this.routes);

  final Map<String, FakeRoute Function(RequestOptions request)> routes;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    final uri = request.uri;
    final key = '${uri.scheme}://${uri.host}${uri.path}';
    final handler = routes[key];
    if (handler == null) {
      return ResponseBody.fromString('not found: $key', 404);
    }
    final route = handler(request);
    final body = route.body;
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body ?? {}),
      route.status,
      headers: {
        Headers.contentTypeHeader: [
          body is String ? 'text/html' : Headers.jsonContentType,
        ],
        if (route.location != null) 'location': [route.location!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(SecretKey key) async => values[key.storageKey];

  @override
  Future<void> write(SecretKey key, String value) async {
    values[key.storageKey] = value;
  }

  @override
  Future<void> delete(SecretKey key) async {
    values.remove(key.storageKey);
  }

  @override
  Future<void> deleteScope(SecretScope scope) async {
    values.removeWhere((k, _) => k.startsWith(scope.storagePrefix));
  }

  @override
  Future<SecretStoreAvailability> checkAvailability() async =>
      SecretStoreAvailability.available;
}
