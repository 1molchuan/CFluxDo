#ifndef CFLUXDO_TLS_CHANNEL_H_
#define CFLUXDO_TLS_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// 注册 `cfluxdo/wpe_tls` 通道（见 cfluxdo_tls_channel.cc）
void cfluxdo_tls_channel_register(FlPluginRegistrar* registrar);

#endif  // CFLUXDO_TLS_CHANNEL_H_
