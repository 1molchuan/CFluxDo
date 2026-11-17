import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_logger.dart';
import 'ld_store_models.dart';
import 'ld_store_service.dart';
import 'ld_store_shop_models.dart';
import 'ld_store_shop_service.dart';

/// 一次下单提交（落盘的那份）。同一个 [token] 对应商城那边至多一笔订单。
class LdShopPendingSubmission {
  const LdShopPendingSubmission({
    required this.token,
    required this.productId,
    required this.quantity,
    required this.expectedAmount,
    required this.createdAt,
    this.couponClaimId,
  });

  static LdShopPendingSubmission? decode(String? raw, String productId) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['token'];
      final quantity = json['quantity'];
      final amount = json['expectedAmount'];
      final createdAt = json['createdAt'];
      final coupon = json['couponClaimId'];
      if (token is! String ||
          !LdShopCheckout.tokenPattern.hasMatch(token) ||
          json['productId'] != productId ||
          quantity is! int ||
          quantity < 1 ||
          amount is! num ||
          !amount.isFinite ||
          createdAt is! int ||
          (coupon != null && coupon is! String)) {
        return null;
      }
      return LdShopPendingSubmission(
        token: token,
        productId: productId,
        quantity: quantity,
        expectedAmount: amount.toDouble(),
        couponClaimId: coupon as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      );
    } catch (_) {
      return null;
    }
  }

  final String token;
  final String productId;
  final int quantity;
  final double expectedAmount;
  final String? couponClaimId;
  final DateTime createdAt;

  String encode() => jsonEncode({
    'token': token,
    'productId': productId,
    'quantity': quantity,
    'expectedAmount': expectedAmount,
    'couponClaimId': couponClaimId,
    'createdAt': createdAt.millisecondsSinceEpoch,
  });
}

/// 提交记录的存放处（默认 SharedPreferences，测试可换）。
abstract class LdShopSubmissionStore {
  Future<String?> read(String key);

  /// 写失败要抛异常（调用方据此不发下单请求）。
  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class PrefsLdShopSubmissionStore implements LdShopSubmissionStore {
  const PrefsLdShopSubmissionStore();

  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value)) {
      throw StateError('提交记录没能保存');
    }
  }

  @override
  Future<void> delete(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }
}

/// 下单 / 恢复的结果。
sealed class LdShopSubmitResult {
  const LdShopSubmitResult();
}

/// 订单已创建（或查到了之前那次提交创建的订单）。
class LdShopSubmitCreated extends LdShopSubmitResult {
  const LdShopSubmitCreated(this.order);

  final LdShopOrderCreated order;
}

/// 商城明确拒绝（4xx 业务失败），这次提交没有生成订单；记录已清。
class LdShopSubmitRejected extends LdShopSubmitResult {
  const LdShopSubmitRejected(this.error);

  final Object error;
}

/// 结果不确定：订单可能已经创建。记录保留，只能用**同一个** token 核对，
/// 不能换新 token 重新下单。
class LdShopSubmitUncertain extends LdShopSubmitResult {
  const LdShopSubmitUncertain({this.inFlight = false});

  /// 同一件商品还有一次提交正在进行
  final bool inFlight;
}

/// 没有待核对的提交（本来就没有，或久远的那次已确认没生成订单，记录已清）。
class LdShopSubmitAbsent extends LdShopSubmitResult {
  const LdShopSubmitAbsent({this.staleCleared = false});

  final bool staleCleared;
}

/// 下单的幂等与恢复（移植自商城前端 `useCheckoutSubmission`）：
///
/// 1. 生成 `submissionToken = "ord_" + 32 位无连字符 uuid`，**先落盘**（按
///    商城账号 + 商品存）再发 `POST /api/shop/orders`；落盘失败就不发。
/// 2. 结果不确定（没拿到响应、超时、5xx、响应格式不对、错误码
///    `ORDER_SUBMISSION_CONFLICT` / `PUBLIC_ID_REQUIRED`）时，用同一个 token
///    查 `GET /api/shop/order-submissions/{token}`，最多 3 次、间隔 700ms；
///    还不确定就保留记录，提示去订单里核对。
/// 3. 只有明确的 4xx 业务失败才清记录；成功且有了定论（不是支付确认中）也清。
/// 4. 记录在的时候不允许再发起新的提交；[recover] 只用记录里的同一个 token
///    查询，`replay: true` 时按原样（同 token、同数量、同金额、同券）重发——
///    商城按 token 去重并核对金额，不会多出第二笔订单。
class LdShopCheckout {
  LdShopCheckout({
    required this.service,
    required this.token,
    required this.productId,
    this.store = const PrefsLdShopSubmissionStore(),
    Future<void> Function()? wait,
    String Function()? newToken,
    DateTime Function()? clock,
  }) : _wait = wait ?? (() => Future.delayed(lookupInterval)),
       _newToken = newToken ?? generateSubmissionToken,
       _clock = clock ?? DateTime.now;

  static const lookupAttempts = 3;
  static const lookupInterval = Duration(milliseconds: 700);

  /// 记录存了这么久、商城又明确说「没有这笔」，就当这次提交没送达，清掉
  static const staleAfter = Duration(minutes: 10);

  static final tokenPattern = RegExp(r'^ord_[a-zA-Z0-9_-]{16,80}$');

  /// 同一件商品正在发送的提交（跨确认弹层实例）
  static final _inFlight = <String>{};

  static const _uncertainCodes = {
    'ORDER_SUBMISSION_CONFLICT',
    'PUBLIC_ID_REQUIRED',
  };

  final LdShopService service;

  /// 下单用的商城凭据（也决定记录归属哪个商城账号）
  final LdStoreToken token;
  final String productId;
  final LdShopSubmissionStore store;
  final Future<void> Function() _wait;
  final String Function() _newToken;
  final DateTime Function() _clock;

  /// 记录按商城账号 + 商品分开（切账号不会串）
  String get storageKey =>
      'ld_shop_submission:${token.site}:${token.userId}:$productId';

  /// `"ord_" + 32 位十六进制`（随机 UUID v4 去掉连字符）。
  static String generateSubmissionToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'ord_$hex';
  }

  /// 还没核对清楚的那次提交（没有返回 null）。
  Future<LdShopPendingSubmission?> pending() async {
    final raw = await store.read(storageKey);
    final pending = LdShopPendingSubmission.decode(raw, productId);
    if (pending == null && raw != null) await store.delete(storageKey);
    return pending;
  }

  bool get isSubmitting => _inFlight.contains(storageKey);

  /// 新提交。调用方要先做完最终核价，[expectedAmount] 是核价给的应付。
  ///
  /// 还有没核对清楚的提交时不发请求，返回 [LdShopSubmitUncertain]（先 [recover]）。
  Future<LdShopSubmitResult> submit({
    required int quantity,
    required double expectedAmount,
    String? couponClaimId,
  }) async {
    final key = storageKey;
    if (!_inFlight.add(key)) return const LdShopSubmitUncertain(inFlight: true);
    try {
      if (await pending() != null) return const LdShopSubmitUncertain();
      final submission = LdShopPendingSubmission(
        token: _newToken(),
        productId: productId,
        quantity: quantity,
        expectedAmount: expectedAmount,
        couponClaimId: couponClaimId,
        createdAt: _clock(),
      );
      // 先落盘：发出去之后无论发生什么，都只能用这个 token 去核对
      await store.write(key, submission.encode());
      return await _send(submission);
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 核对上一次提交。[replay] 为 true 且查不到时，按原样（同一个 token）重发。
  Future<LdShopSubmitResult> recover({bool replay = false}) async {
    final key = storageKey;
    if (!_inFlight.add(key)) return const LdShopSubmitUncertain(inFlight: true);
    try {
      final submission = await pending();
      if (submission == null) return const LdShopSubmitAbsent();
      final lookup = await _lookup(submission);
      if (lookup.found != null) return lookup.found!;
      if (lookup.confirmedAbsent &&
          _clock().difference(submission.createdAt) > staleAfter) {
        await store.delete(key);
        return const LdShopSubmitAbsent(staleCleared: true);
      }
      if (replay) return await _send(submission, replaying: true);
      return const LdShopSubmitUncertain();
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<LdShopSubmitResult> _send(
    LdShopPendingSubmission submission, {
    bool replaying = false,
  }) async {
    final LdShopOrderCreated created;
    try {
      created = await service.createOrder(
        productId: submission.productId,
        quantity: submission.quantity,
        submissionToken: submission.token,
        expectedAmount: submission.expectedAmount,
        couponClaimId: submission.couponClaimId,
        token: token,
      );
    } on LdStoreAuthExpiredException {
      // 401：这次请求在鉴权这一步就被挡下，没有创建订单。重发时不清——
      // 第一次发出的那个请求可能已经建了单，重新授权后还要用同一个 token 核对
      if (!replaying) await store.delete(storageKey);
      rethrow;
    } on LdShopException catch (e) {
      if (_isUncertain(e)) return _afterUncertain(submission, e);
      await store.delete(storageKey);
      return LdShopSubmitRejected(e);
    } on DioException catch (e) {
      return _afterUncertain(submission, e);
    } on FormatException catch (e) {
      return _afterUncertain(submission, e);
    }
    return _adopt(created);
  }

  Future<LdShopSubmitResult> _afterUncertain(
    LdShopPendingSubmission submission,
    Object error,
  ) async {
    AppLogger.warning(
      'LD士多下单结果不确定，按同一提交核对: ${error.runtimeType}'
      '${error is LdShopException ? ' status=${error.status} code=${error.code}' : ''}',
      tag: 'LdShop',
    );
    final lookup = await _lookup(submission);
    return lookup.found ?? const LdShopSubmitUncertain();
  }

  Future<({LdShopSubmitResult? found, bool confirmedAbsent})> _lookup(
    LdShopPendingSubmission submission,
  ) async {
    var confirmedAbsent = false;
    for (var attempt = 0; attempt < lookupAttempts; attempt++) {
      try {
        final result = await service.lookupSubmission(submission.token, token);
        final order = result.order;
        if (result.exists && order != null) {
          return (found: await _adopt(order), confirmedAbsent: false);
        }
        if (!result.exists) confirmedAbsent = true;
      } on LdStoreAuthExpiredException {
        // 凭据失效：查不了，但记录不能丢（重新授权后还要用同一个 token 核对）
        rethrow;
      } catch (_) {
        // 查询失败不能说明订单有没有建
      }
      if (attempt < lookupAttempts - 1) await _wait();
    }
    return (found: null, confirmedAbsent: confirmedAbsent);
  }

  Future<LdShopSubmitResult> _adopt(LdShopOrderCreated order) async {
    // 支付结果还在确认时留着记录：再进来会先核对，避免重复兑换
    if (order.isResolved) await store.delete(storageKey);
    return LdShopSubmitCreated(order);
  }

  static bool _isUncertain(LdShopException e) =>
      e.status == 0 || e.status >= 500 || _uncertainCodes.contains(e.code);
}

// -----------------------------------------------------------------------------
// 选券与最终核价（移植自商城前端 `utils/checkoutCoupon.js`）
// -----------------------------------------------------------------------------

/// 选券方式：自动（默认选最优券）或用户手动选过（包括手动选「不用券」）。
enum LdShopCouponMode { auto, manual }

class LdShopCouponSelection {
  const LdShopCouponSelection({
    required this.claimId,
    required this.mode,
    this.replacedManualSelection = false,
  });

  final String? claimId;
  final LdShopCouponMode mode;

  /// 用户手动选的券不能用了，换成了别的（或不用券）
  final bool replacedManualSelection;

  /// 核价成功后决定用哪张券：手动选的还能用就保留，否则选第一张可用券
  /// （商城按优惠从大到小排好）。
  static LdShopCouponSelection resolve({
    required LdShopQuote quote,
    required LdShopCouponMode mode,
    required String? selectedClaimId,
  }) {
    if (mode == LdShopCouponMode.manual && selectedClaimId == null) {
      return const LdShopCouponSelection(
        claimId: null,
        mode: LdShopCouponMode.manual,
      );
    }
    if (mode == LdShopCouponMode.manual &&
        quote.eligibleCoupon(selectedClaimId) != null) {
      return LdShopCouponSelection(
        claimId: selectedClaimId,
        mode: LdShopCouponMode.manual,
      );
    }
    final eligible = quote.eligibleCoupons;
    return LdShopCouponSelection(
      claimId: eligible.isEmpty ? null : eligible.first.claimId,
      mode: LdShopCouponMode.auto,
      replacedManualSelection:
          mode == LdShopCouponMode.manual && selectedClaimId != null,
    );
  }
}

/// 提交前最终核价的结论。
enum LdShopFinalQuoteCheck {
  /// 与用户看到的一致，可以下单
  ok,

  /// 用户选的券失效了，要重新选
  couponInvalidated,

  /// 金额或用券变了，要用户确认后再点
  confirmationRequired,
}

LdShopFinalQuoteCheck evaluateLdShopFinalQuote({
  required String? requestedClaimId,
  required String? currentClaimId,
  required double amountBefore,
  required double amountNow,
}) {
  if (requestedClaimId != null && currentClaimId != requestedClaimId) {
    return LdShopFinalQuoteCheck.couponInvalidated;
  }
  if (currentClaimId != requestedClaimId ||
      (amountNow - amountBefore).abs() > 0.0001) {
    return LdShopFinalQuoteCheck.confirmationRequired;
  }
  return LdShopFinalQuoteCheck.ok;
}
