import 'package:dio/dio.dart';

/// 本机网关自己回的错误响应（连不上上游节点等）。
///
/// 网关在这类响应上带 `x-cfluxdo-gateway-error` 头（见 Rust 侧
/// `GATEWAY_ERROR_HEADER`），正文是失败原因；源站真的回了 5xx 时没有这个头。
abstract final class GatewayError {
  static const header = 'x-cfluxdo-gateway-error';

  /// [response] 是不是网关自己回的错误
  static bool isGatewayResponse(Response<dynamic>? response) =>
      response?.headers.value(header) != null;

  /// [error] 是不是「网关连不上上游」：这时走内置浏览器也没用，它也经同一个网关
  static bool isUpstreamFailure(Object? error) =>
      error is DioException && isGatewayResponse(error.response);

  /// 网关错误的正文（截断到 300 字）；不是网关错误返回 null
  static String? textOf(Response<dynamic>? response) {
    if (!isGatewayResponse(response)) return null;
    final data = response!.data;
    final text = data is String ? data : data?.toString();
    if (text == null || text.isEmpty) return 'gateway error';
    return text.length > 300 ? text.substring(0, 300) : text;
  }
}
