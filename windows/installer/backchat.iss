#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#ifndef MyBuildDir
  #error MyBuildDir must point at the built Windows release folder.
#endif

#ifndef MyOutputDir
  #error MyOutputDir must point at the directory where the installer should be written.
#endif

#define MyAppName "Backchat"
#define MyAppExeName "backchat.exe"
#define MyInstallerBaseName "backchat-windows-x64-" + MyAppVersion + "-setup"

[Setup]
AppId={{D8EC2D72-5385-4E03-AB9C-D640D2B07BAA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=Backchat
AppPublisherURL=https://github.com/mysticalg/Backchat
AppSupportURL=https://github.com/mysticalg/Backchat/issues
AppUpdatesURL=https://github.com/mysticalg/Backchat/releases
VersionInfoCompany=Backchat
VersionInfoDescription=Backchat Windows installer
VersionInfoProductName=Backchat
VersionInfoCopyright=Copyright (C) 2026 Backchat. All rights reserved.
DefaultDirName={localappdata}\Programs\Backchat
DefaultGroupName=Backchat
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyInstallerBaseName}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ChangesAssociations=no
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Backchat"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Backchat"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Backchat"; Flags: nowait postinstall skipifsilent
