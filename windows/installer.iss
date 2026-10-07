; LastWave - Windows installer (Inno Setup 6).
;
; Built ONLY for releases (v* tags); see .github/workflows/desktop.yml.
; Version is injected by CI: ISCC /DMyAppVersion=1.0.0
; Local dev build: ISCC windows/installer.iss  (defaults to 1.0.0-dev)
;
; Per-user install (no admin UAC): {localappdata}\Programs\LastWave.
; User data (SQLite, prefs, downloads live elsewhere) is untouched
; by install/uninstall.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0-dev"
#endif
#define MyAppName "LastWave"
#define MyAppPublisher "Clash-Projects"
#define MyAppURL "https://github.com/Clash-Projects/LastWave-Desktop"
#define MyAppExeName "lastwave_desktop.exe"
#define MyAppId "{{E8B4F6A2-7C3D-4A1E-9F5B-2D6A8C4E1A3B5}"
; Must match kLastWaveAppUserModelId in windows/runner/app_identity.h.
; The shell resolves the SMTC volume-flyout label/icon via the Start Menu
; shortcut's AppUserModelID - without this the flyout shows "Unknown app"
; with no logo even though the exe sets the same ID at runtime.
#define MyAppUserModelId "com.lastwave.lastwave_desktop"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\LastWave
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\windows\installer
OutputBaseFilename=lastwave_{#MyAppVersion}_windows-x86_64-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
DisableProgramGroupPage=yes
; No LicenseFile/SetupIconFile yet: no license text or .ico asset in
; the repo. Add both when they land.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; AppUserModelID: "{#MyAppUserModelId}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; AppUserModelID: "{#MyAppUserModelId}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

