; Installeur de Nabla pour Windows (Inno Setup) : construit par la CI, iscc /DVersion=X.Y.Z installer.iss
; Installation pour l'utilisateur seul : pas besoin d'être administrateur.
#ifndef Version
  #define Version "0.0.0"
#endif

[Setup]
AppId={{5B8E2B31-6F0A-4C8E-9C1D-4E2A7F3B9D10}
AppName=Nabla
AppVersion={#Version}
AppPublisher=Evolvlabs
AppPublisherURL=https://github.com/Evolvlabs-research/Latex-converter
DefaultDirName={localappdata}\Programs\Nabla
DefaultGroupName=Nabla
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=Nabla-{#Version}-installeur
SetupIconFile=assets\nabla.ico
UninstallDisplayIcon={app}\Nabla.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer une icône sur le Bureau"; Flags: unchecked

[Files]
Source: "dist\Nabla\Nabla.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\Nabla\pdfium.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dist\Nabla\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Nabla"; Filename: "{app}\Nabla.exe"
Name: "{userdesktop}\Nabla"; Filename: "{app}\Nabla.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Nabla.exe"; Description: "Lancer Nabla"; Flags: nowait postinstall skipifsilent
