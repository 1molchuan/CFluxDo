// cfluxdo 补丁：让 Dart 侧逐主机放行「本地代理签发的那张叶子证书」。
//
// WebView 经本地 MITM 代理连 linux.do 时，代理用设备 CA 现签叶子证书。WPE 没有
// 「额外信任某个 CA」的接口；上游做法是证书出错时一律 PROCEED（等于不校验）。
// 这里改成：Dart 从代理取到某主机的叶子 PEM，预先放进默认网络会话的允许表，
// WebKit 只会对完全相同的证书放行，换一张（哪怕同 CA 签的）也照样报错。
#include "cfluxdo_tls_channel.h"

#include <wpe/webkit.h>

namespace {

constexpr char kChannelName[] = "cfluxdo/wpe_tls";

FlMethodResponse* AllowTlsCertificateForHost(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("bad_args", "需要 {host, pem}", nullptr));
  }
  FlValue* host = fl_value_lookup_string(args, "host");
  FlValue* pem = fl_value_lookup_string(args, "pem");
  if (host == nullptr || pem == nullptr || fl_value_get_type(host) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(pem) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("bad_args", "host / pem 必须是字符串", nullptr));
  }

  g_autoptr(GError) error = nullptr;
  g_autoptr(GTlsCertificate) cert =
      g_tls_certificate_new_from_pem(fl_value_get_string(pem), -1, &error);
  if (cert == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_pem", error != nullptr ? error->message : "无法解析证书", nullptr));
  }

  // 插件里非无痕 WebView 都用默认网络会话（代理也设在它上面）
  WebKitNetworkSession* session = webkit_network_session_get_default();
  webkit_network_session_allow_tls_certificate_for_host(session, cert,
                                                         fl_value_get_string(host));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(TRUE)));
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "allowTlsCertificateForHost") == 0) {
    response = AllowTlsCertificateForHost(fl_method_call_get_args(call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void cfluxdo_tls_channel_register(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // 通道随进程存活，不释放
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethodCall, nullptr, nullptr);
}
