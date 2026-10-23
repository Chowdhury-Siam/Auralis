#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Auralis", origin, size)) {
    return EXIT_FAILURE;
  }
  MONITORINFO monitor_info{};
  monitor_info.cbSize = static_cast<DWORD>(sizeof(monitor_info));
  RECT frame{};
  if (GetWindowRect(window.GetHandle(), &frame) &&
      GetMonitorInfo(MonitorFromWindow(window.GetHandle(), MONITOR_DEFAULTTONEAREST),
                     &monitor_info)) {
    const RECT work = monitor_info.rcWork;
    const LONG width = std::min(frame.right - frame.left, work.right - work.left - 24);
    const LONG height = std::min(frame.bottom - frame.top, work.bottom - work.top - 24);
    SetWindowPos(window.GetHandle(), nullptr,
                 work.left + (work.right - work.left - width) / 2,
                 work.top + (work.bottom - work.top - height) / 2, width, height,
                 SWP_NOACTIVATE | SWP_NOZORDER);
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
