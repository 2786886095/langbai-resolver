#include <winsock2.h>
#include <ws2tcpip.h>

#include <bcrypt.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <iphlpapi.h>
#include <windows.h>

#include <array>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kApplicationMutex[] = L"langbaiResolverAppMutex";
constexpr wchar_t kWindowTitle[] = L"langbai\u89E3\u6790";
constexpr USHORT kBackendPort = 8787;

std::wstring ExecutableDirectory() {
  wchar_t path[MAX_PATH] = {};
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring executable(path, length);
  const size_t separator = executable.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"." : executable.substr(0, separator);
}

std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD length = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0) return L"";
  std::wstring value(length, L'\0');
  ::GetEnvironmentVariableW(name, value.data(), length);
  value.resize(length - 1);
  return value;
}

void EnsureDirectory(const std::wstring& path) {
  if (!path.empty()) ::CreateDirectoryW(path.c_str(), nullptr);
}

std::wstring RuntimeRoot() {
  std::wstring root = EnvironmentValue(L"LOCALAPPDATA");
  if (root.empty()) root = ExecutableDirectory();
  root += L"\\langbai-resolver";
  EnsureDirectory(root);
  return root;
}

std::wstring LogDirectory() {
  const std::wstring directory = RuntimeRoot() + L"\\logs";
  EnsureDirectory(directory);
  return directory;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (length <= 0) return "";
  std::string result(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), result.data(), length,
                        nullptr, nullptr);
  return result;
}

std::string JsonEscape(const std::string& value) {
  std::string escaped;
  escaped.reserve(value.size());
  for (const char character : value) {
    switch (character) {
      case '\\':
        escaped += "\\\\";
        break;
      case '"':
        escaped += "\\\"";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        escaped.push_back(character);
        break;
    }
  }
  return escaped;
}

void RotateLogIfNeeded(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA attributes = {};
  if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) {
    return;
  }
  ULARGE_INTEGER size = {};
  size.HighPart = attributes.nFileSizeHigh;
  size.LowPart = attributes.nFileSizeLow;
  if (size.QuadPart < 5ULL * 1024ULL * 1024ULL) return;
  const std::wstring previous = path + L".1";
  ::DeleteFileW(previous.c_str());
  ::MoveFileExW(path.c_str(), previous.c_str(), MOVEFILE_REPLACE_EXISTING);
}

void WriteRunnerLog(const char* event, const std::wstring& detail) {
  const std::wstring path = LogDirectory() + L"\\runner.log";
  RotateLogIfNeeded(path);
  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME time = {};
  ::GetSystemTime(&time);
  char timestamp[40] = {};
  ::sprintf_s(timestamp, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
              static_cast<unsigned int>(time.wYear),
              static_cast<unsigned int>(time.wMonth),
              static_cast<unsigned int>(time.wDay),
              static_cast<unsigned int>(time.wHour),
              static_cast<unsigned int>(time.wMinute),
              static_cast<unsigned int>(time.wSecond),
              static_cast<unsigned int>(time.wMilliseconds));
  std::string message = "{\"timestamp\":\"";
  message += timestamp;
  message += "\",\"event\":\"";
  message += event;
  message += "\",\"detail\":\"";
  message += JsonEscape(Utf8(detail));
  message += "\"}\r\n";
  DWORD written = 0;
  ::WriteFile(file, message.data(), static_cast<DWORD>(message.size()),
              &written, nullptr);
  ::CloseHandle(file);
}

DWORD ListeningOwnerPid() {
  ULONG size = 0;
  const DWORD first = ::GetExtendedTcpTable(
      nullptr, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
  if (first != ERROR_INSUFFICIENT_BUFFER || size == 0) return MAXDWORD;
  std::vector<unsigned char> buffer(size);
  auto* table = reinterpret_cast<PMIB_TCPTABLE_OWNER_PID>(buffer.data());
  if (::GetExtendedTcpTable(table, &size, FALSE, AF_INET,
                            TCP_TABLE_OWNER_PID_LISTENER, 0) != NO_ERROR) {
    return MAXDWORD;
  }
  for (DWORD index = 0; index < table->dwNumEntries; ++index) {
    const MIB_TCPROW_OWNER_PID& row = table->table[index];
    if (::ntohs(static_cast<u_short>(row.dwLocalPort)) == kBackendPort &&
        (row.dwLocalAddr == ::htonl(INADDR_LOOPBACK) ||
         row.dwLocalAddr == INADDR_ANY)) {
      return row.dwOwningPid;
    }
  }
  return 0;
}

std::wstring GenerateInstanceToken() {
  std::array<unsigned char, 32> bytes = {};
  if (::BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    return L"";
  }
  constexpr wchar_t hex[] = L"0123456789abcdef";
  std::wstring token;
  token.reserve(bytes.size() * 2);
  for (const unsigned char byte : bytes) {
    token.push_back(hex[(byte >> 4) & 0x0F]);
    token.push_back(hex[byte & 0x0F]);
  }
  return token;
}

void ActivateExistingWindow() {
  HWND existing = ::FindWindowW(nullptr, kWindowTitle);
  if (!existing) return;
  if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
  ::SetForegroundWindow(existing);
}

class BackendController {
 public:
  BackendController() = default;
  ~BackendController() { Shutdown(); }

  bool Initialize() {
    if (::WSAStartup(MAKEWORD(2, 2), &socket_data_) != 0) {
      WriteRunnerLog("winsock_start_failed", L"WSAStartup failed");
      return false;
    }
    winsock_started_ = true;
    instance_token_ = GenerateInstanceToken();
    if (instance_token_.empty()) {
      WriteRunnerLog("token_generation_failed", L"BCryptGenRandom failed");
      return false;
    }
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_INSTANCE_TOKEN",
                              instance_token_.c_str());
    const DWORD existing_owner = ListeningOwnerPid();
    if (existing_owner == MAXDWORD) {
      WriteRunnerLog("port_owner_query_failed", std::to_wstring(::GetLastError()));
      return false;
    }
    if (existing_owner != 0) {
      WriteRunnerLog("foreign_port_owner", L"127.0.0.1:8787 is already in use");
      return false;
    }
    return Start();
  }

  void MonitorAndRestart() {
    if (process_) {
      if (::WaitForSingleObject(process_, 0) != WAIT_OBJECT_0) return;
      DWORD exit_code = 0;
      ::GetExitCodeProcess(process_, &exit_code);
      WriteRunnerLog("backend_exited", std::to_wstring(exit_code));
      CloseProcessAndJob();
    }

    const ULONGLONG now = ::GetTickCount64();
    if (restart_window_started_ == 0 ||
        now - restart_window_started_ > 60ULL * 1000ULL) {
      restart_window_started_ = now;
      restart_count_ = 0;
      restart_suppression_logged_ = false;
    }
    if (restart_count_ >= 5) {
      if (!restart_suppression_logged_) {
        WriteRunnerLog(
            "backend_restart_suppressed",
            L"five failures in one minute; retrying after cooldown");
        restart_suppression_logged_ = true;
      }
      return;
    }
    ++restart_count_;
    if (!Start()) {
      WriteRunnerLog("backend_restart_failed", L"start or ownership verification failed");
    } else {
      restart_suppression_logged_ = false;
    }
  }

  void Shutdown() {
    CloseProcessAndJob();
    if (winsock_started_) {
      ::WSACleanup();
      winsock_started_ = false;
    }
  }

 private:
  bool Start() {
    const std::wstring backend_directory = ExecutableDirectory() + L"\\backend";
    const std::wstring backend_executable =
        backend_directory + L"\\langbai_backend.exe";
    if (::GetFileAttributesW(backend_executable.c_str()) ==
        INVALID_FILE_ATTRIBUTES) {
      WriteRunnerLog("backend_missing", backend_executable);
      return false;
    }
    const DWORD existing_owner = ListeningOwnerPid();
    if (existing_owner == MAXDWORD) {
      WriteRunnerLog("port_owner_query_failed", std::to_wstring(::GetLastError()));
      return false;
    }
    if (existing_owner != 0) {
      WriteRunnerLog("foreign_port_owner", L"127.0.0.1:8787 is already in use");
      return false;
    }

    std::wstring downloads = RuntimeRoot() + L"\\downloads";
    EnsureDirectory(downloads);
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_HOST", L"127.0.0.1");
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_PORT", L"8787");
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_ALLOW_FAKE_IP_DNS", L"true");
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_DOWNLOAD_DIR", downloads.c_str());
    ::SetEnvironmentVariableW(L"MEDIA_HARBOR_FFMPEG_LOCATION",
                              backend_directory.c_str());
    const std::wstring updated_path =
        backend_directory + L";" + EnvironmentValue(L"PATH");
    ::SetEnvironmentVariableW(L"PATH", updated_path.c_str());

    job_ = ::CreateJobObjectW(nullptr, nullptr);
    if (!job_) {
      WriteRunnerLog("job_create_failed", std::to_wstring(::GetLastError()));
      return false;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!::SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
                                   &limits, sizeof(limits))) {
      WriteRunnerLog("job_configure_failed", std::to_wstring(::GetLastError()));
      CloseProcessAndJob();
      return false;
    }

    SECURITY_ATTRIBUTES security = {};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;
    const std::wstring backend_log = LogDirectory() + L"\\backend.log";
    RotateLogIfNeeded(backend_log);
    HANDLE log = ::CreateFileW(
        backend_log.c_str(), FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log == INVALID_HANDLE_VALUE) log = nullptr;

    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    if (log) {
      startup.dwFlags = STARTF_USESTDHANDLES;
      startup.hStdOutput = log;
      startup.hStdError = log;
      startup.hStdInput = nullptr;
    }
    PROCESS_INFORMATION process = {};
    std::wstring command = L"\"" + backend_executable + L"\"";
    const BOOL created = ::CreateProcessW(
        backend_executable.c_str(), command.data(), nullptr, nullptr,
        log != nullptr,
        CREATE_NO_WINDOW, nullptr, backend_directory.c_str(), &startup, &process);
    if (log) ::CloseHandle(log);
    if (!created) {
      WriteRunnerLog("backend_start_failed", std::to_wstring(::GetLastError()));
      CloseProcessAndJob();
      return false;
    }
    if (!::AssignProcessToJobObject(job_, process.hProcess)) {
      WriteRunnerLog("backend_job_assignment_failed",
                     std::to_wstring(::GetLastError()));
      ::TerminateProcess(process.hProcess, 1);
      ::CloseHandle(process.hThread);
      ::CloseHandle(process.hProcess);
      CloseProcessAndJob();
      return false;
    }
    ::CloseHandle(process.hThread);
    process_ = process.hProcess;
    process_id_ = process.dwProcessId;

    for (int attempt = 0; attempt < 80; ++attempt) {
      const DWORD owner = ListeningOwnerPid();
      if (owner == MAXDWORD) {
        WriteRunnerLog("port_owner_query_failed", std::to_wstring(::GetLastError()));
        CloseProcessAndJob();
        return false;
      }
      if (owner == process_id_) {
        WriteRunnerLog("backend_ready", std::to_wstring(process_id_));
        return true;
      }
      if (owner != 0 && owner != process_id_) {
        WriteRunnerLog("backend_port_hijacked", std::to_wstring(owner));
        CloseProcessAndJob();
        return false;
      }
      if (::WaitForSingleObject(process_, 0) == WAIT_OBJECT_0) {
        WriteRunnerLog("backend_early_exit", std::to_wstring(process_id_));
        CloseProcessAndJob();
        return false;
      }
      ::Sleep(100);
    }
    WriteRunnerLog("backend_ready_timeout", std::to_wstring(process_id_));
    CloseProcessAndJob();
    return false;
  }

  void CloseProcessAndJob() {
    if (process_) {
      ::CloseHandle(process_);
      process_ = nullptr;
    }
    if (job_) {
      ::CloseHandle(job_);
      job_ = nullptr;
    }
    process_id_ = 0;
  }

  WSADATA socket_data_ = {};
  bool winsock_started_ = false;
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
  DWORD process_id_ = 0;
  std::wstring instance_token_;
  ULONGLONG restart_window_started_ = 0;
  int restart_count_ = 0;
  bool restart_suppression_logged_ = false;
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE application_mutex = ::CreateMutexW(nullptr, FALSE, kApplicationMutex);
  if (!application_mutex) return EXIT_FAILURE;
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow();
    ::CloseHandle(application_mutex);
    return EXIT_SUCCESS;
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  BackendController backend;
  if (!backend.Initialize()) {
    ::MessageBoxW(
        nullptr,
        L"\u672c\u5730\u89e3\u6790\u670d\u52a1\u65e0\u6cd5\u5b89\u5168\u542f\u52a8\u3002\n\n"
        L"\u8bf7\u5173\u95ed\u5360\u7528 127.0.0.1:8787 \u7684\u7a0b\u5e8f\uff0c\u7136\u540e\u91cd\u8bd5\u3002\n"
        L"\u8be6\u7ec6\u4fe1\u606f\u5df2\u5199\u5165 %LOCALAPPDATA%\\langbai-resolver\\logs\\runner.log\u3002",
        kWindowTitle, MB_OK | MB_ICONERROR);
    backend.Shutdown();
    ::CoUninitialize();
    ::CloseHandle(application_mutex);
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    backend.Shutdown();
    ::CoUninitialize();
    ::CloseHandle(application_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  const UINT_PTR backend_monitor_timer = ::SetTimer(nullptr, 0, 2000, nullptr);
  if (backend_monitor_timer == 0) {
    WriteRunnerLog("backend_monitor_timer_failed",
                   std::to_wstring(::GetLastError()));
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    if (backend_monitor_timer != 0 && msg.message == WM_TIMER &&
        msg.wParam == backend_monitor_timer) {
      backend.MonitorAndRestart();
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (backend_monitor_timer != 0) {
    ::KillTimer(nullptr, backend_monitor_timer);
  }
  backend.Shutdown();
  ::CoUninitialize();
  ::CloseHandle(application_mutex);
  return EXIT_SUCCESS;
}
