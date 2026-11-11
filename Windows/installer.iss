; Installateur C-SAFE pour Windows (Inno Setup) — installation pour l'utilisateur, sans droits administrateur.

#ifndef AppVersion
  #define AppVersion "1.0"
#endif

[Setup]
AppId={{6F3C1B2E-8C2A-4F55-9C11-C5AFE0C0F0C5}
AppName=C-SAFE
AppVersion={#AppVersion}
AppVerName=C-SAFE {#AppVersion}
AppPublisher=C-FOCUS
VersionInfoVersion={#AppVersion}.0.0
VersionInfoProductVersion={#AppVersion}
VersionInfoDescription=Installateur de C-SAFE (C-FOCUS)
DefaultDirName={localappdata}\Programs\C-SAFE
DefaultGroupName=C-SAFE
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\sortie
OutputBaseFilename=C-SAFE-Setup
SetupIconFile=CSafe.App\Assets\app.ico
UninstallDisplayIcon={app}\C-SAFE.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer une icône sur le Bureau"; GroupDescription: "Raccourcis :"

[Files]
Source: "..\publication\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\C-SAFE"; Filename: "{app}\C-SAFE.exe"
Name: "{autodesktop}\C-SAFE"; Filename: "{app}\C-SAFE.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\C-SAFE.exe"; Description: "Lancer C-SAFE"; Flags: nowait postinstall skipifsilent
Filename: "{app}\C-SAFE.exe"; Flags: nowait; Check: Relaunch

[Code]
function Relaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;
