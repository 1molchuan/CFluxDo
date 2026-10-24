#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <vector>
#include <shellapi.h>
#include <cstdint>

namespace {
constexpr UINT kSiteRestartMessage = WM_APP + 41;

std::wstring QuoteArgument(const std::wstring& argument) {
  std::wstring result = L"\"";
  result.reserve(argument.size() * 2 + 2);
  size_t slashes = 0;
  for (wchar_t character : argument) {
    if (character == L'\\') {
      ++slashes;
      continue;
    }
    result.append(character == L'\"' ? slashes * 2 + 1 : slashes, L'\\');
    result += character;
    slashes = 0;
  }
  result.append(slashes * 2, L'\\');
  result += L'\"';
  return result;
}
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  site_switch_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "fluxdo/site_switch",
          &flutter::StandardMethodCodec::GetInstance());
  site_switch_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "isSupported") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() != "restart") {
          result->NotImplemented();
          return;
        }
        if (restart_pending_) {
          result->Error("restart_pending", "站点切换正在进行");
          return;
        }
        if (!PrepareProcessRestart()) {
          result->Error("restart_failed", "无法启动新的应用进程");
          return;
        }
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 首帧画出来再显示窗口（上游由 Dart 侧 window_manager 恢复窗口状态后再显示，
  // cfluxdo 已去掉该依赖，不在这里显示的话窗口永远不出来）
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!IsWindowVisible(GetHandle())) {
      this->Show();
    }
  });

  // 首帧可能在注册回调之前就画完了；这里确保还有一帧待画，保证窗口会显示。
  // 首帧还没画完时是空操作
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::PrepareProcessRestart() {
  // 复用已有的窗口位置持久化，不重放旧的授权回调参数。
  SendMessage(GetHandle(), WM_EXITSIZEMOVE, 0, 0);
  wchar_t executable[32768];
  const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
  if (length == 0 || length >= 32768) {
    return false;
  }

  HANDLE parent = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(),
                       GetCurrentProcess(), &parent, SYNCHRONIZE, TRUE, 0)) {
    return false;
  }
  SIZE_T attributes_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attributes_size);
  std::vector<BYTE> attributes(attributes_size);
  STARTUPINFOEXW startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                         &attributes_size)) {
    CloseHandle(parent);
    return false;
  }
  const bool attributes_ready = UpdateProcThreadAttribute(
      startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &parent,
      sizeof(parent), nullptr, nullptr) != FALSE;
  std::wstring command = L"\"" + std::wstring(executable) +
      L"\" --fluxdo-site-restart-parent=" +
      std::to_wstring(reinterpret_cast<uintptr_t>(parent));
  int argument_count = 0;
  wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (arguments != nullptr) {
    for (int index = 1; index < argument_count; ++index) {
      const std::wstring argument(arguments[index]);
      // 所有 URI 启动参数都属于旧会话，跨站待打开链接由 Dart 单独持久化。
      // 仅检查分隔符也覆盖大写或混合大小写 scheme，无需复制参数做小写转换。
      if (argument.find(L"://") == std::wstring::npos &&
          argument.find(L"--fluxdo-site-restart-parent=") != 0) {
        command += L" " + QuoteArgument(argument);
      }
    }
    LocalFree(arguments);
  }
  PROCESS_INFORMATION process = {};
  const bool created = attributes_ready && CreateProcessW(
      executable, command.data(), nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED, nullptr, nullptr,
      &startup.StartupInfo, &process);
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  CloseHandle(parent);
  if (!created) {
    return false;
  }
  // 子进程先等待继承的父进程句柄；旧进程所有线程退出后才初始化 Flutter。
  restart_pending_ = true;
  if (ResumeThread(process.hThread) == static_cast<DWORD>(-1) ||
      !PostMessage(GetHandle(), kSiteRestartMessage, 0, 0)) {
    restart_pending_ = false;
    TerminateProcess(process.hProcess, EXIT_FAILURE);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return false;
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}

void FlutterWindow::OnDestroy() {
  if (site_switch_channel_) {
    site_switch_channel_->SetMethodCallHandler(nullptr);
    site_switch_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kSiteRestartMessage && restart_pending_) {
    site_switch_channel_->SetMethodCallHandler(nullptr);
    site_switch_channel_.reset();
    // 不运行 WebView2 插件的不安全析构；系统在进程退出时释放全部引擎、
    // Controller、代理线程及句柄，子进程的等待屏障随后才会解除。
    TerminateProcess(GetCurrentProcess(), EXIT_SUCCESS);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
