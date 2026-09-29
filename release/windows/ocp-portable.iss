; Build with release\Build-OcpWindowsInstaller.ps1.  This definition installs
; an already-built, architecture-matched portable bundle and keeps application
; data outside {app} so uninstall does not silently delete user data.

#ifndef BundleDir
  #error BundleDir must point to an extracted OCP portable bundle.
#endif
#ifndef OutputDir
  #error OutputDir must point to the installer output directory.
#endif
#ifndef ProductVersion
  #error ProductVersion must be supplied without a leading v.
#endif
#ifndef OcpArch
  #error OcpArch must be arm64 or x86_64.
#endif
#ifndef InnoArch
  #error InnoArch must be arm64 or x64compatible.
#endif
#ifndef InstallerCompression
  #define InstallerCompression "zip"
#endif
#ifndef InstallerSolidCompression
  #define InstallerSolidCompression "no"
#endif

#define ProductName "Open Companion Platform"
#define AppId "{{2C0B0A1B-963D-4A61-B4B8-0A4342F31791}"

[Setup]
AppId={#AppId}
AppName={#ProductName}
AppVersion={#ProductVersion}
AppPublisher=Open Companion Platform
DefaultDirName={localappdata}\Programs\Open Companion Platform
DefaultGroupName={#ProductName}
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=ocp-windows-{#OcpArch}-{#ProductVersion}-setup
Compression={#InstallerCompression}
SolidCompression={#InstallerSolidCompression}
WizardStyle=modern
UninstallDisplayIcon={app}\desktop-shell\OCP.exe
ChangesAssociations=yes
ArchitecturesAllowed={#InnoArch}
ArchitecturesInstallIn64BitMode={#InnoArch}

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\ocp-launcher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\desktop-shell\OCP.exe"
Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\ocp-launcher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\desktop-shell\OCP.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "autostart"; Description: "Start OCP when I sign in"; GroupDescription: "Startup:"

[Registry]
; Production ocp:// registration is per-user and points at the full OCP launcher,
; not directly at Electron. This lets a Store deep link start Runtime first when
; OCP is not already running, then hand the exact URI to the Runtime-owned Shell.
Root: HKCU; Subkey: "Software\Classes\ocp"; ValueType: string; ValueData: "URL:OCP Desktop Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ocp"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\ocp\DefaultIcon"; ValueType: string; ValueData: "{app}\desktop-shell\OCP.exe,0"
Root: HKCU; Subkey: "Software\Classes\ocp\shell\open\command"; ValueType: string; ValueData: """{app}\ocp-launcher.exe"" --protocol-uri ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "OpenCompanionPlatform"; ValueData: """{app}\ocp-launcher.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\ocp-launcher.exe"; Parameters: "--open=home"; WorkingDir: "{app}"; Description: "Start Open Companion Platform"; Flags: nowait postinstall skipifsilent
