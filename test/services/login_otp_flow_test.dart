import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/user_api_key_service.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浏览器授权登录的「换会话」这一步：口令落盘、失败原因、授权密钥的清理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = FlutterSecureStorage();
  final service = UserApiKeyService();

  late _ForumAdapter adapter;
  late Dio dio;
  String? sessionToken;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    adapter = _ForumAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
      ..httpClientAdapter = adapter;
    sessionToken = null;
    service.debugSessionTokenReader = () async => sessionToken;
  });
  tearDown(() => service.debugSessionTokenReader = null);

  group('待兑换的口令', () {
    test('存下来能读回，过了有效期读不到并被清掉', () async {
      final issuedAt = DateTime(2026, 11, 22, 10);
      await service.savePendingOtp('abc123', now: issuedAt);

      final pending = await service.readPendingOtp(
        now: issuedAt.add(const Duration(minutes: 8, seconds: 59)),
      );
      expect(pending?.otp, 'abc123');
      expect(pending?.issuedAt, issuedAt);

      expect(
        await service.readPendingOtp(
          now: issuedAt.add(const Duration(minutes: 9)),
        ),
        isNull,
      );
      expect(await secure.read(key: 'user_api_key_pending_otp'), isNull);
    });

    test('清掉后读不到；存坏了按没有处理', () async {
      await service.savePendingOtp('abc123');
      await service.clearPendingOtp();
      expect(await service.readPendingOtp(), isNull);

      await secure.write(key: 'user_api_key_pending_otp', value: '不是 JSON');
      expect(await service.readPendingOtp(), isNull);
      expect(await secure.read(key: 'user_api_key_pending_otp'), isNull);
    });
  });

  group('拿口令换会话', () {
    test('成功：服务端签出新的 _t', () async {
      adapter.onRedeem = () => sessionToken = 'new-session';
      final progress = <List<String>>[];

      final result = await service.redeemOtpDetailed(
        dio,
        'abc123',
        onProgress: () => progress.add(List.of(adapter.calls)),
      );
      // 取到 CSRF、发兑换请求之前报一次进展
      expect(progress, [
        ['GET /session/csrf'],
      ]);

      expect(result.ok, isTrue);
      expect(result.token, 'new-session');
      expect(adapter.calls, ['GET /session/csrf', 'POST /session/otp/abc123']);
      expect(adapter.redeemCsrf, 'csrf-token');
    });

    test('口令写法不对：不发请求', () async {
      final result = await service.redeemOtpDetailed(dio, '../oops');

      expect(result.failure, OtpRedeemFailure.badFormat);
      expect(result.retryable, isFalse);
      expect(adapter.calls, isEmpty);
    });

    test('服务端收下请求却没签出会话（过期 / 用过）：不可重试', () async {
      final result = await service.redeemOtpDetailed(dio, 'abc123');

      expect(result.ok, isFalse);
      expect(result.failure, OtpRedeemFailure.rejected);
      expect(result.retryable, isFalse);
    });

    test('口令被拒、jar 里的 _t 却恰好变了（内置网页那边换成的）：不算这边换成', () async {
      // 假论坛回 200 的提示页；与此同时别的路把会话写进了 jar
      adapter.onRejectedRedeem = () => sessionToken = 'session-from-web';

      final result = await service.redeemOtpDetailed(dio, 'abc123');

      expect(sessionToken, 'session-from-web');
      expect(result.ok, isFalse);
      expect(result.failure, OtpRedeemFailure.rejected);
    });

    test('别的路先换成了：取消后不再发后面的请求', () async {
      final cancel = CancelToken();
      adapter.onCsrf = () => cancel.cancel('web leg won');

      final result = await service.redeemOtpDetailed(
        dio,
        'abc123',
        cancelToken: cancel,
      );

      expect(result.ok, isFalse);
      expect(adapter.calls, ['GET /session/csrf']);
    });

    test('被人机验证拦下：口令还在，可以换一条路', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              error: CfChallengeException(userCancelled: true),
              type: DioExceptionType.unknown,
            ),
          ),
        ),
      );

      final result = await service.redeemOtpDetailed(dio, 'abc123');

      expect(result.failure, OtpRedeemFailure.challenge);
      expect(result.retryable, isTrue);
      expect(adapter.calls, isEmpty);
    });

    test('连接失败：口令还在，可以再试', () async {
      adapter.failConnection = true;

      final result = await service.redeemOtpDetailed(dio, 'abc123');

      expect(result.failure, OtpRedeemFailure.network);
      expect(result.retryable, isTrue);
    });

    test('redeemOtp 仍只给 _t（自愈与扫码登录在用）', () async {
      adapter.onRedeem = () => sessionToken = 'new-session';
      expect(await service.redeemOtp(dio, 'abc123'), 'new-session');
      sessionToken = null;
      adapter.onRedeem = null;
      expect(await service.redeemOtp(dio, 'abc123'), isNull);
    });
  });

  group('用已登录的会话签发口令', () {
    late AsymmetricKeyPair<PublicKey, PrivateKey> keys;

    setUp(() async {
      keys = _keyPair();
      await secure.write(
        key: 'user_api_key_rsa_private',
        value: _privateJson(keys.privateKey as RSAPrivateKey),
      );
      adapter.issueKey = keys.publicKey as RSAPublicKey;
    });

    test('成功：带上公钥与回跳地址，解出口令', () async {
      adapter.issuedOtp = '0123456789abcdef0123456789abcdef';

      final otp = await service.issueOtpWithSession(dio);

      expect(otp, '0123456789abcdef0123456789abcdef');
      expect(adapter.calls, ['POST /user-api-key/otp']);
      expect(adapter.issueForm?['auth_redirect'], 'discourse://auth_redirect');
      expect(adapter.issueForm?['application_name'], 'CFluxDo');
      expect(adapter.issueForm?['public_key'], contains('BEGIN PUBLIC KEY'));
      // 靠会话签发，不带授权密钥
      expect(adapter.issueHeaders.keys, isNot(contains('User-Api-Key')));
    });

    test('服务端不放行：返回 null', () async {
      adapter.issueStatus = 403;
      expect(await service.issueOtpWithSession(dio), isNull);
    });

    test('回应里没有口令、或解出来不是十六进制串：返回 null', () async {
      expect(await service.issueOtpWithSession(dio), isNull);
      adapter.issuedOtp = '不是口令';
      expect(await service.issueOtpWithSession(dio), isNull);
    });

    test('连不上：返回 null', () async {
      adapter.failConnection = true;
      expect(await service.issueOtpWithSession(dio), isNull);
    });
  });

  group('授权前预检', () {
    test('取得到 CSRF 就算能连上', () async {
      expect(await service.canReachForum(dio), isTrue);
      expect(adapter.calls, ['GET /session/csrf']);
    });

    test('连不上或被拦下都算不通', () async {
      adapter.failConnection = true;
      expect(await service.canReachForum(dio), isFalse);
    });
  });

  group('授权密钥用完即焚', () {
    test('撤销成功才清本地', () async {
      await secure.write(key: 'user_api_key_key', value: 'the-key');

      await service.burnAfterLoginIfUseless(dio);

      expect(adapter.calls, ['POST /user-api-key/revoke']);
      expect(adapter.revokedKey, 'the-key');
      expect(await service.hasKey(), isFalse);
    });

    test('撤销没发成：本地先留着，下次再撤', () async {
      await secure.write(key: 'user_api_key_key', value: 'the-key');
      adapter.failConnection = true;

      await service.burnAfterLoginIfUseless(dio);
      expect(await service.readApiKey(), 'the-key');

      adapter.failConnection = false;
      await service.burnAfterLoginIfUseless(dio);
      expect(await service.hasKey(), isFalse);
    });

    test('服务端已经不认这枚密钥：本地也清掉，不再反复撤', () async {
      await secure.write(key: 'user_api_key_key', value: 'the-key');
      adapter.revokeStatus = 403;

      await service.burnAfterLoginIfUseless(dio);

      expect(await service.hasKey(), isFalse);
    });

    test('撤销被人机验证拦下：不算密钥失效，本地留着', () async {
      await secure.write(key: 'user_api_key_key', value: 'the-key');
      adapter.revokeStatus = 403;
      adapter.revokeChallenged = true;

      await service.burnAfterLoginIfUseless(dio);

      expect(await service.readApiKey(), 'the-key');
    });

    test('本地没有密钥时不发请求', () async {
      await service.burnAfterLoginIfUseless(dio);
      expect(adapter.calls, isEmpty);
    });
  });
}

/// 只认登录流程用到的三个接口的假论坛
class _ForumAdapter implements HttpClientAdapter {
  final List<String> calls = [];
  bool failConnection = false;
  void Function()? onRedeem;
  void Function()? onRejectedRedeem;
  void Function()? onCsrf;
  String? redeemCsrf;
  String? revokedKey;
  int revokeStatus = 200;
  bool revokeChallenged = false;

  /// 签发口令接口的回应：状态码与（加密后挂在回跳地址上的）口令
  int issueStatus = 200;
  String? issuedOtp;
  RSAPublicKey? issueKey;
  Map<String, String>? issueForm;
  Map<String, dynamic> issueHeaders = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (failConnection) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    calls.add('${options.method} ${options.uri.path}');
    if (options.uri.path == '/session/csrf') {
      onCsrf?.call();
      return ResponseBody.fromString(
        jsonEncode({'csrf': 'csrf-token'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path.startsWith('/session/otp/')) {
      redeemCsrf = options.headers['X-CSRF-Token']?.toString();
      final redeem = onRedeem;
      if (redeem == null) {
        onRejectedRedeem?.call();
        return ResponseBody.fromString('<html>', 200);
      }
      redeem();
      return ResponseBody.fromString('', 302, headers: {
        'location': ['/'],
      });
    }
    if (options.uri.path == '/user-api-key/otp') {
      issueHeaders = Map<String, dynamic>.of(options.headers);
      issueForm = Uri.splitQueryString(
        utf8.decode(await requestStream!.expand((chunk) => chunk).toList()),
      );
      if (issueStatus != 200) {
        return ResponseBody.fromString(
          jsonEncode({'error_type': 'invalid_access'}),
          issueStatus,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      final otp = issuedOtp;
      var redirect = 'discourse://auth_redirect';
      if (otp != null) {
        final cipher = PKCS1Encoding(RSAEngine())
          ..init(true, PublicKeyParameter<RSAPublicKey>(issueKey!));
        final encrypted = cipher.process(Uint8List.fromList(utf8.encode(otp)));
        // 服务端用 Base64.encode64：每 60 个字符一个换行
        final wrapped = base64Encode(
          encrypted,
        ).replaceAllMapped(RegExp('.{60}'), (m) => '${m[0]}\n');
        redirect = Uri.parse(redirect)
            .replace(queryParameters: {'oneTimePassword': wrapped})
            .toString();
      }
      return ResponseBody.fromString(
        jsonEncode({'redirect_url': redirect}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.uri.path == '/user-api-key/revoke') {
      revokedKey = options.headers['User-Api-Key']?.toString();
      return ResponseBody.fromString(
        '{"success":"OK"}',
        revokeStatus,
        headers: {
          if (revokeChallenged) 'cf-mitigated': ['challenge'],
        },
      );
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

AsymmetricKeyPair<PublicKey, PrivateKey> _keyPair() {
  final random = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i + 7))));
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
        random,
      ),
    );
  return generator.generateKeyPair();
}

String _privateJson(RSAPrivateKey key) => jsonEncode({
  'n': key.modulus!.toRadixString(16),
  'd': key.privateExponent!.toRadixString(16),
  'p': key.p!.toRadixString(16),
  'q': key.q!.toRadixString(16),
});
