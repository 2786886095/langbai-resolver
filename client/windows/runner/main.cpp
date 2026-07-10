#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring ExecutableDirectory() {
  wchar_t path[MAX_PATH] = {};
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring executable(path, length);
  const size_t separator = executable.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"." : executable.substr(0, separator);
}

std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD length = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0) {
    return L"";
  }
  std::wstring value(length, L'\0');
  ::GetEnvironmentVariableW(name, value.data(), length);
  value.resize(length - 1);
  return value;
}

bool BackendIsListening() {
  SOCKET socket_handle = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (socket_handle == INVALID_SOCKET) {
    return false;
  }
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(8787);
  ::InetPtonW(AF_INET, L"127.0.0.1", &address.sin_addr);
  const bool connected =
      ::connect(socket_handle, reinterpret_cast<sockaddr*>(&address),
                sizeof(address)) == 0;
  ::closesocket(socket_handle);
  return connected;
}

HANDLE StartBundledBackend() {
  WSADATA socket_data = {};
  if (::WSAStartup(MAKEWORD(2, 2), &socket_data) != 0) {
    return nullptr;
  }
  if (BackendIsListening()) {
    ::WSACleanup();
    return nullptr;
  }

  const std::wstring backend_directory = ExecutableDirectory() + L"\\backend";
  const std::wstring backend_executable =
      backend_directory + L"\\langbai_backend.exe";
  if (::GetFileAttributesW(backend_executable.c_str()) == INVALID_FILE_ATTRIBUTES) {
    ::WSACleanup();
    return nullptr;
  }

  std::wstring data_directory =
      EnvironmentValue(L"LOCALAPPDATA") + L"\\langbai-resolver";
  ::CreateDirectoryW(data_directory.c_str(), nullptr);
  data_directory += L"\\downloads";
  ::CreateDirectoryW(data_directory.c_str(), nullptr);
  ::SetEnvironmentVariableW(L"MEDIA_HARBOR_HOST", L"127.0.0.1");
  ::SetEnvironmentVariableW(L"MEDIA_HARBOR_PORT", L"8787");
  // Clash and similar VPN clients can map public domains into 198.18.0.0/15.
  // The backend still rejects localhost and real private network ranges.
  ::SetEnvironmentVariableW(L"MEDIA_HARBOR_ALLOW_FAKE_IP_DNS", L"true");
  ::SetEnvironmentVariableW(L"MEDIA_HARBOR_DOWNLOAD_DIR",
                            data_directory.c_str());
  ::SetEnvironmentVariableW(L"MEDIA_HARBOR_FFMPEG_LOCATION",
                            backend_directory.c_str());
  const std::wstring updated_path =
      backend_directory + L";" + EnvironmentValue(L"PATH");
  ::SetEnvironmentVariableW(L"PATH", updated_path.c_str());

  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (!job) {
    ::WSACleanup();
    return nullptr;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!::SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits))) {
    ::CloseHandle(job);
    ::WSACleanup();
    return nullptr;
  }

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  std::wstring command = L"\"" + backend_executable + L"\"";
  if (!::CreateProcessW(backend_executable.c_str(), command.data(), nullptr,
                        nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
                        backend_directory.c_str(), &startup, &process)) {
    ::CloseHandle(job);
    ::WSACleanup();
    return nullptr;
  }
  if (!::AssignProcessToJobObject(job, process.hProcess)) {
    ::TerminateProcess(process.hProcess, 1);
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
    ::CloseHandle(job);
    ::WSACleanup();
    return nullptr;
  }
  ::CloseHandle(process.hThread);

  for (int attempt = 0; attempt < 150; ++attempt) {
    if (BackendIsListening()) {
      break;
    }
    if (::WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
      break;
    }
    ::Sleep(100);
  }
  ::CloseHandle(process.hProcess);
  ::WSACleanup();
  return job;
}

}  // namespace

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
  HANDLE backend_job = StartBundledBackend();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"langbai\u89E3\u6790", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (backend_job) {
    ::CloseHandle(backend_job);
  }
  return EXIT_SUCCESS;
}
