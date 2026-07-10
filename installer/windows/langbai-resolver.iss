#ifndef AppVersion
  #define AppVersion "1.0.6"
#endif

#define ProjectRoot SourcePath + "\..\.."
#define AppExecutable "langbai_resolver.exe"

[Setup]
AppId={{E8BF4352-8B55-43FA-949C-67905B3709F3}
AppName=langbai解析
AppVersion={#AppVersion}
AppPublisher=langbai
AppPublisherURL=https://github.com/2786886095/langbai-resolver
AppSupportURL=https://github.com/2786886095/langbai-resolver/issues
AppUpdatesURL=https://github.com/2786886095/langbai-resolver/releases/latest
DefaultDirName={localappdata}\Programs\langbai解析
DefaultGroupName=langbai解析
DisableProgramGroupPage=yes
OutputDir={#ProjectRoot}\dist
OutputBaseFilename=langbai-resolver-Setup
SetupIconFile={#ProjectRoot}\client\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExecutable}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
ChangesAssociations=yes
RestartApplications=no
AppMutex=langbaiResolverAppMutex
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=langbai
VersionInfoDescription=langbai解析 Windows 安装程序
VersionInfoProductName=langbai解析
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项："; Flags: unchecked

[Files]
Source: "{#ProjectRoot}\client\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\media_harbor.exe"

[Icons]
Name: "{group}\langbai解析"; Filename: "{app}\{#AppExecutable}"; IconFilename: "{app}\{#AppExecutable}"; IconIndex: 0
Name: "{group}\卸载 langbai解析"; Filename: "{uninstallexe}"
Name: "{autodesktop}\langbai解析"; Filename: "{app}\{#AppExecutable}"; IconFilename: "{app}\{#AppExecutable}"; IconIndex: 0; Tasks: desktopicon

[Run]
Filename: "{sys}\ie4uinit.exe"; Parameters: "-ClearIconCache"; Flags: runhidden; StatusMsg: "正在刷新应用图标..."
Filename: "{sys}\ie4uinit.exe"; Parameters: "-show"; Flags: runhidden
Filename: "{app}\{#AppExecutable}"; Description: "启动 langbai解析"; Flags: nowait postinstall skipifsilent
