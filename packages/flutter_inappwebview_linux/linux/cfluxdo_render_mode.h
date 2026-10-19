#ifndef CFLUXDO_RENDER_MODE_H_
#define CFLUXDO_RENDER_MODE_H_

#include <flutter_linux/flutter_linux.h>

#include <string>

// cfluxdo 补丁：WebView（WPEWebProcess）用硬件还是软件渲染，见 cfluxdo_render_mode.cc

namespace cfluxdo_render {

// 用户在设置里选的方式
enum class Mode { kAuto, kHardware, kSoftware };

// 判定依据（启动时算一次，用于设置页展示）
struct Decision {
  Mode mode = Mode::kAuto;
  bool software = false;
  // env / user / crash / nvidia / no_gpu / vm / preset / default
  std::string reason;
  // 各渲染节点的内核驱动，逗号分隔，如 "i915,nvidia"
  std::string gpu_drivers;
  // 强制给 WebProcess 用的 Mesa EGL 厂商文件；空 = 没找到 / 没设置
  std::string mesa_vendor_file;
  // 上次在硬件模式下网页进程崩溃的时间（ISO 8601）；空 = 没有
  std::string crashed_at;
};

// 纯判定（不读不写环境与文件），供单元测试
struct Inputs {
  Mode mode = Mode::kAuto;
  // CFLUXDO_WEBVIEW_RENDERING 环境变量：hardware / software，空 = 没设
  std::string env_override;
  bool libgl_software_preset = false;
  bool crash_marker = false;
  bool has_render_node = true;
  bool nvidia_proprietary = false;
  // 上游的虚拟机 / 问题驱动判定结果
  bool vm_needs_software = false;
};
Decision Decide(const Inputs& inputs);

Mode ParseMode(const std::string& value);
const char* ModeName(Mode mode);

}  // namespace cfluxdo_render

// 插件注册时、任何 WPEDisplay / WebView 创建之前调用：读设置与崩溃记录、探测显卡，
// 需要软件渲染就设好只影响网页进程的环境变量（取代上游的 ApplySoftwareRenderingIfNeeded）
void cfluxdo_render_mode_apply();

// 注册 `cfluxdo/wpe_render` 通道：getState / setMode，并向 Dart 推送 webProcessCrashed
void cfluxdo_render_mode_register(FlPluginRegistrar* registrar);

// WebView 的网页进程崩溃时调用（InAppWebView::OnWebProcessTerminated）
void cfluxdo_render_mode_on_web_process_crashed();

#endif  // CFLUXDO_RENDER_MODE_H_
