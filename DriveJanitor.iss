[Setup]
AppName=Drive Janitor
AppVersion=1.0.0
AppPublisher=sagar-dalwala999
AppPublisherURL=https://github.com/sagar-dalwala999/drive-janitor
AppSupportURL=https://github.com/sagar-dalwala999/drive-janitor/issues
AppUpdatesURL=https://github.com/sagar-dalwala999/drive-janitor/releases
DefaultDirName={autopf}\Drive Janitor
DefaultGroupName=Drive Janitor
OutputDir=dist
OutputBaseFilename=DriveJanitorSetup-v1.0.0
SetupIconFile=app.ico
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
DisableProgramGroupPage=yes

[Files]
Source: "DriveJanitor.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "DriveJanitor.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "DriveJanitor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Install-Shortcut.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Run-AllChecks.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "app.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "modules\*"; DestDir: "{app}\modules"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "ui\*"; DestDir: "{app}\ui"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Drive Janitor"; Filename: "{app}\DriveJanitor.exe"; IconFilename: "{app}\app.ico"
Name: "{autodesktop}\Drive Janitor"; Filename: "{app}\DriveJanitor.exe"; IconFilename: "{app}\app.ico"

[Run]
Filename: "{app}\DriveJanitor.exe"; Description: "{cm:LaunchProgram,Drive Janitor}"; Flags: nowait postinstall skipifsilent
