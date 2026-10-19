// cfluxdo 补丁：WebView 网页进程（WPEWebProcess）的渲染方式。
//
// 起因：NVIDIA 专有驱动（如 615.71）下，网页进程在 GBM / EGL 上走 NVIDIA 的 GL，
// 一打开登录页、人机验证页就在 libnvidia-eglcore 里 SIGSEGV，界面全黑。换到 Intel
// 核显就正常。主界面（Flutter）不受影响，崩的只是网页进程。
//
// 做法：判定需要软件渲染时，在任何 WebView 创建之前设三个环境变量（网页进程启动时继承）：
// - LIBGL_ALWAYS_SOFTWARE=1：WPEPlatform 因此不把 DRM 渲染节点交给网页进程，帧改走共享内存
//   （插件 SHM 路径直接拷像素，不经 GL）；网页进程里的 Mesa 也用 llvmpipe。
// - __EGL_VENDOR_LIBRARY_FILENAMES=<Mesa 厂商文件>：glvnd 只加载 Mesa，网页进程彻底不碰
//   NVIDIA 的 EGL（否则 surfaceless 显示仍可能被排在前面的 NVIDIA 接走）。
// - WEBKIT_SKIA_ENABLE_CPU_RENDERING=1：画布也走 CPU（llvmpipe 上的 GPU 画布反而更慢）。
//
// 这时主界面的 GL 早已初始化（runner 在注册插件前就 realize 了 FlView，glvnd 的厂商表
// 和 Mesa 的 DRI 屏幕都已建好），所以这些变量只影响之后才建的网页进程与 WPE 的 UI 侧
// 无头显示（SHM 路径用不到它的 GL）。
//
// 判定顺序（自动）：上次硬件模式下网页进程崩过 → NVIDIA 专有驱动 → 没有渲染节点 →
// 上游的虚拟机判定 → 硬件。设置页可强制硬件 / 软件；环境变量 CFLUXDO_WEBVIEW_RENDERING
// 优先于一切。设置写在 <XDG 配置目录>/<程序名>/webview_render_mode，改了下次启动生效
// （WebKit 只在第一个网页进程启动时取一次渲染节点）。
#include "cfluxdo_render_mode.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <set>
#include <string>

#include "utils/software_rendering.h"

namespace cfluxdo_render {

Mode ParseMode(const std::string& value) {
  if (value == "hardware") return Mode::kHardware;
  if (value == "software") return Mode::kSoftware;
  return Mode::kAuto;
}

const char* ModeName(Mode mode) {
  switch (mode) {
    case Mode::kHardware:
      return "hardware";
    case Mode::kSoftware:
      return "software";
    case Mode::kAuto:
    default:
      return "auto";
  }
}

Decision Decide(const Inputs& in) {
  Decision d;
  d.mode = in.mode;
  auto set = [&d](bool software, const char* reason) {
    d.software = software;
    d.reason = reason;
  };

  if (in.env_override == "software") {
    set(true, "env");
  } else if (in.env_override == "hardware") {
    set(false, "env");
  } else if (in.mode == Mode::kSoftware) {
    set(true, "user");
  } else if (in.mode == Mode::kHardware) {
    set(false, "user");
  } else if (in.crash_marker) {
    set(true, "crash");
  } else if (in.nvidia_proprietary) {
    set(true, "nvidia");
  } else if (!in.has_render_node) {
    set(true, "no_gpu");
  } else if (in.libgl_software_preset) {
    set(true, "preset");
  } else if (in.vm_needs_software) {
    set(true, "vm");
  } else {
    set(false, "default");
  }
  return d;
}

}  // namespace cfluxdo_render

namespace {

using cfluxdo_render::Decision;
using cfluxdo_render::Mode;

constexpr char kChannelName[] = "cfluxdo/wpe_render";
constexpr char kModeFile[] = "webview_render_mode";
constexpr char kCrashFile[] = "webview_render_crash";

Decision g_decision;
FlMethodChannel* g_channel = nullptr;
bool g_crash_reported = false;

std::string ConfigPath(const char* name) {
  g_autofree gchar* path =
      g_build_filename(g_get_user_config_dir(), g_get_prgname(), name, nullptr);
  return path;
}

std::string ReadTrimmed(const std::string& path) {
  g_autofree gchar* contents = nullptr;
  if (!g_file_get_contents(path.c_str(), &contents, nullptr, nullptr)) return "";
  return g_strstrip(contents);
}

bool WriteConfig(const char* name, const std::string& value) {
  g_autofree gchar* dir = g_build_filename(g_get_user_config_dir(), g_get_prgname(), nullptr);
  g_mkdir_with_parents(dir, 0700);
  return g_file_set_contents(ConfigPath(name).c_str(), value.c_str(), -1, nullptr);
}

bool IsTruthy(const char* value) {
  return value != nullptr && (strcmp(value, "1") == 0 || g_ascii_strcasecmp(value, "true") == 0 ||
                              g_ascii_strcasecmp(value, "yes") == 0);
}

// 各渲染节点的内核驱动名（/sys/class/drm/renderD*/device/driver 的链接目标末段）
std::set<std::string> RenderNodeDrivers(bool* has_render_node) {
  std::set<std::string> drivers;
  *has_render_node = false;
  GDir* dir = g_dir_open("/sys/class/drm", 0, nullptr);
  if (dir != nullptr) {
    while (const gchar* name = g_dir_read_name(dir)) {
      if (!g_str_has_prefix(name, "renderD")) continue;
      *has_render_node = true;
      g_autofree gchar* link =
          g_build_filename("/sys/class/drm", name, "device", "driver", nullptr);
      g_autofree gchar* target = g_file_read_link(link, nullptr);
      if (target != nullptr) {
        g_autofree gchar* base = g_path_get_basename(target);
        drivers.insert(base);
      }
    }
    g_dir_close(dir);
  }
  // 沙箱里 /sys 不全时，退回看 /dev/dri
  if (!*has_render_node) {
    GDir* dev = g_dir_open("/dev/dri", 0, nullptr);
    if (dev != nullptr) {
      while (const gchar* name = g_dir_read_name(dev)) {
        if (g_str_has_prefix(name, "renderD")) *has_render_node = true;
      }
      g_dir_close(dev);
    }
  }
  return drivers;
}

// Mesa 的 glvnd EGL 厂商文件（Flatpak 运行时与常见发行版的位置）
std::string FindMesaVendorFile() {
  static const char* const kDirs[] = {
      "/usr/lib/x86_64-linux-gnu/GL/glvnd/egl_vendor.d",
      "/usr/lib/x86_64-linux-gnu/GL/default/share/glvnd/egl_vendor.d",
      "/usr/lib/aarch64-linux-gnu/GL/glvnd/egl_vendor.d",
      "/etc/glvnd/egl_vendor.d",
      "/usr/share/glvnd/egl_vendor.d",
      "/usr/local/share/glvnd/egl_vendor.d",
      nullptr,
  };
  for (const char* const* d = kDirs; *d != nullptr; ++d) {
    GDir* dir = g_dir_open(*d, 0, nullptr);
    if (dir == nullptr) continue;
    std::string found;
    while (const gchar* name = g_dir_read_name(dir)) {
      if (strstr(name, "mesa") != nullptr && g_str_has_suffix(name, ".json")) {
        g_autofree gchar* path = g_build_filename(*d, name, nullptr);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) {
          found = path;
          break;
        }
      }
    }
    g_dir_close(dir);
    if (!found.empty()) return found;
  }
  return "";
}

FlValue* StateToValue(const Decision& current) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "mode",
                           fl_value_new_string(cfluxdo_render::ModeName(current.mode)));
  fl_value_set_string_take(map, "software", fl_value_new_bool(current.software));
  fl_value_set_string_take(map, "reason", fl_value_new_string(current.reason.c_str()));
  fl_value_set_string_take(map, "gpuDrivers", fl_value_new_string(current.gpu_drivers.c_str()));
  fl_value_set_string_take(map, "mesaVendorFile",
                           fl_value_new_string(current.mesa_vendor_file.c_str()));
  fl_value_set_string_take(map, "crashedAt", fl_value_new_string(current.crashed_at.c_str()));
  // 设置页的选中项要显示「已保存、下次启动生效」的那个
  std::string saved = ReadTrimmed(ConfigPath(kModeFile));
  fl_value_set_string_take(
      map, "savedMode",
      fl_value_new_string(cfluxdo_render::ModeName(cfluxdo_render::ParseMode(saved))));
  return map;
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "getState") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(StateToValue(g_decision)));
  } else if (g_strcmp0(method, "setMode") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("bad_args", "需要 auto / hardware / software", nullptr));
    } else {
      Mode mode = cfluxdo_render::ParseMode(fl_value_get_string(args));
      bool ok = WriteConfig(kModeFile, cfluxdo_render::ModeName(mode));
      // 重新选择即重新判定：崩溃记录作废（选「自动」= 下次再试硬件）
      g_remove(ConfigPath(kCrashFile).c_str());
      response = ok ? FL_METHOD_RESPONSE(
                          fl_method_success_response_new(StateToValue(g_decision)))
                    : FL_METHOD_RESPONSE(fl_method_error_response_new(
                          "write_failed", "无法写入设置文件", nullptr));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void cfluxdo_render_mode_apply() {
  cfluxdo_render::Inputs in;
  in.mode = cfluxdo_render::ParseMode(ReadTrimmed(ConfigPath(kModeFile)));
  if (const char* env = getenv("CFLUXDO_WEBVIEW_RENDERING")) in.env_override = env;
  in.libgl_software_preset = IsTruthy(getenv("LIBGL_ALWAYS_SOFTWARE"));
  std::string crashed_at = ReadTrimmed(ConfigPath(kCrashFile));
  in.crash_marker = !crashed_at.empty();

  bool has_render_node = false;
  std::set<std::string> drivers = RenderNodeDrivers(&has_render_node);
  in.has_render_node = has_render_node;
  // 专有驱动的内核模块叫 nvidia（开源的是 nouveau）；/sys 不可见时看 /proc
  in.nvidia_proprietary =
      drivers.count("nvidia") > 0 ||
      (drivers.empty() && g_file_test("/proc/driver/nvidia/version", G_FILE_TEST_EXISTS));
  in.vm_needs_software = flutter_inappwebview_plugin::ShouldUseSoftwareRendering();

  g_decision = cfluxdo_render::Decide(in);
  g_decision.crashed_at = crashed_at;
  for (const auto& driver : drivers) {
    if (!g_decision.gpu_drivers.empty()) g_decision.gpu_drivers += ",";
    g_decision.gpu_drivers += driver;
  }

  if (g_decision.software) {
    setenv("LIBGL_ALWAYS_SOFTWARE", "1", 0);
    setenv("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1", 0);
    if (const char* preset = getenv("__EGL_VENDOR_LIBRARY_FILENAMES")) {
      g_decision.mesa_vendor_file = preset;
    } else {
      std::string mesa = FindMesaVendorFile();
      if (!mesa.empty()) {
        setenv("__EGL_VENDOR_LIBRARY_FILENAMES", mesa.c_str(), 1);
        g_decision.mesa_vendor_file = mesa;
      }
    }
  }

  g_message("cfluxdo: WebView 渲染 = %s（设置 %s，依据 %s，显卡驱动 [%s]%s%s）",
            g_decision.software ? "软件" : "硬件", cfluxdo_render::ModeName(g_decision.mode),
            g_decision.reason.c_str(), g_decision.gpu_drivers.c_str(),
            g_decision.mesa_vendor_file.empty() ? "" : "，EGL 厂商 ",
            g_decision.mesa_vendor_file.c_str());
}

void cfluxdo_render_mode_register(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // 通道随进程存活，不释放
  g_channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), kChannelName,
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, HandleMethodCall, nullptr, nullptr);
}

void cfluxdo_render_mode_on_web_process_crashed() {
  // 只有「自动 + 当前硬件」才自愈：记下崩溃，下次启动改软件；用户或环境变量指定的方式不动
  if (g_decision.software || g_decision.mode != Mode::kAuto || g_decision.reason == "env") {
    return;
  }
  if (g_crash_reported) return;
  g_crash_reported = true;

  g_autoptr(GDateTime) now = g_date_time_new_now_local();
  g_autofree gchar* stamp = g_date_time_format_iso8601(now);
  WriteConfig(kCrashFile, stamp);
  g_warning("cfluxdo: 硬件渲染下网页进程崩溃，已记录；下次启动起 WebView 改用软件渲染");

  if (g_channel != nullptr) {
    fl_method_channel_invoke_method(g_channel, "webProcessCrashed", nullptr, nullptr, nullptr,
                                    nullptr);
  }
}
