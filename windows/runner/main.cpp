#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

// 深链启动(discourse:// / fluxdo://)时把 URL 转发给已运行实例并退出,
// 避免为一次授权回调开出第二个窗口(app_links 官方集成方式)。
// 仅对携带 scheme 链接的启动生效,普通启动的多开行为不变。
// 窗口标题固定为下方 Create 的 L"CFluxDo",Dart 侧无 setTitle 调用。
static bool SendAppLinkToInstance(const wchar_t* command_line) {
  if (command_line == nullptr ||
      (::wcsstr(command_line, L"discourse://") == nullptr &&
       ::wcsstr(command_line, L"fluxdo://") == nullptr)) {
    return false;
  }

  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"CFluxDo");
  if (hwnd == nullptr) {
    return false;
  }

  // 把本进程命令行里的链接派发给该窗口(app_links 插件接收)
  SendAppLink(hwnd);

  // 把已运行实例带回前台
  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &place);
  switch (place.showCmd) {
    case SW_SHOWMAXIMIZED:
      ::ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      break;
    case SW_SHOWMINIMIZED:
      ::ShowWindow(hwnd, SW_RESTORE);
      break;
    default:
      ::ShowWindow(hwnd, SW_NORMAL);
      break;
  }
  ::SetForegroundWindow(hwnd);
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool site_restart = false;
  constexpr const char* restart_prefix = "--fluxdo-site-restart-parent=";
  for (auto iterator = command_line_arguments.begin();
       iterator != command_line_arguments.end();) {
    if (iterator->rfind(restart_prefix, 0) != 0) {
      ++iterator;
      continue;
    }
    const char* value = iterator->c_str() + strlen(restart_prefix);
    char* end = nullptr;
    const auto handle_value = std::strtoull(value, &end, 10);
    HANDLE parent = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(handle_value));
    if (handle_value == 0 || end == value || *end != '\0' ||
        WaitForSingleObject(parent, INFINITE) != WAIT_OBJECT_0) {
      MessageBoxW(nullptr, L"站点切换失败：无法等待旧进程退出。", L"CFluxDo", MB_OK | MB_ICONERROR);
      return EXIT_FAILURE;
    }
    CloseHandle(parent);
    site_restart = true;
    iterator = command_line_arguments.erase(iterator);
  }
  if (!site_restart && SendAppLinkToInstance(command_line)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");


  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"CFluxDo", origin, size)) {
    MessageBoxW(nullptr, L"应用初始化失败，无法创建 Flutter 窗口。请重新启动应用。",
                L"CFluxDo", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
