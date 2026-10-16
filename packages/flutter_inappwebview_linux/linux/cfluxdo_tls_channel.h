#ifndef CFLUXDO_TLS_CHANNEL_H_
#define CFLUXDO_TLS_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// 注册 `cfluxdo/wpe_tls` 通道（见 cfluxdo_tls_channel.cc）
void cfluxdo_tls_channel_register(FlPluginRegistrar* registrar);

// 让默认网络会话把 Cookie 持久化到磁盘（见 cfluxdo_tls_channel.cc）
void cfluxdo_enable_persistent_cookies();

#endif  // CFLUXDO_TLS_CHANNEL_H_
