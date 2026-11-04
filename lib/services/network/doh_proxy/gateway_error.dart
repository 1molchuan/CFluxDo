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

  /// 网关错误的原因（截断到 300 字）；不是网关错误返回 null。
  /// 优先用头里带的原因（流式响应在拦截器里读不到正文，正文只是个 ResponseBody），
  /// 老版本网关头值只是 "1"，再退回正文
  static String? textOf(Response<dynamic>? response) {
    if (!isGatewayResponse(response)) return null;
    final headerText = response!.headers.value(header)?.trim();
    if (headerText != null && headerText.isNotEmpty && headerText != '1') {
      return _clip(headerText);
    }
    final data = response.data;
    final text = switch (data) {
      String s => s,
      List<int> bytes => String.fromCharCodes(bytes),
      ResponseBody() => null,
      null => null,
      _ => data.toString(),
    };
    if (text == null || text.isEmpty) return 'gateway error';
    return _clip(text);
  }

  static String _clip(String text) =>
      text.length > 300 ? text.substring(0, 300) : text;
}
