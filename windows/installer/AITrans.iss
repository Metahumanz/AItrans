; AITrans Windows 安装脚本（Inno Setup 6）
;
; 用法：
;   ISCC.exe /DMyAppVersion=0.2.0 /DSourceDir=..\dist\app AITrans.iss
;
; SourceDir 指向 dotnet publish 的输出目录；相对路径按本脚本所在目录解析。
;
; 设计取舍：
; - 未签名分发，所以默认按当前用户安装到 %LocalAppData%\Programs，
;   不需要管理员权限；想装到 Program Files 可以在向导里勾选「为所有用户安装」。
; - 不打包 .NET 与 Windows App SDK 运行时，缺运行时时由 AITrans.exe 自己弹提示，
;   安装向导的「准备安装」页会先列出依赖和下载地址。

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\app"
#endif

#define MyAppName "AITrans"
#define MyAppExeName "AITrans.exe"
#define MyAppPublisher "Metahumanz"
#define MyAppUrl "https://github.com/Metahumanz/AItrans"

; VersionInfoVersion 只接受纯数字点分，0.3.0-rc1 / 0.0.0-ci 这类要砍掉后缀。
#define MyAppVersionNumeric Copy(MyAppVersion, 1, Pos("-", MyAppVersion) > 0 ? Pos("-", MyAppVersion) - 1 : Len(MyAppVersion))

[Setup]
; AppId 一旦发布就不能改，否则新版本会装成第二个程序。
AppId={{7F3C1A2E-9B4D-4E6A-8C1F-2D5B7A9E0C31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppUrl}
AppSupportURL={#MyAppUrl}/issues
AppUpdatesURL={#MyAppUrl}/releases
VersionInfoVersion={#MyAppVersionNumeric}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename={#MyAppName}-{#MyAppVersion}-win-x64-setup
SetupIconFile=..\..\assets\icon\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
InfoBeforeFile=prerequisites.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
CloseApplications=yes
RestartApplications=no
; 按系统语言自动选，不弹语言选择框：中文系统直接进简体中文向导，
; 英文系统用 Default.isl。需要强制指定时仍可传 /LANG=en。
ShowLanguageDialog=no

[Languages]
Name: "zh"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只清理安装目录里的残留，%AppData%\AITrans 下的配置与密钥由用户自己决定是否删除。
Type: filesandordirs; Name: "{app}\logs"
