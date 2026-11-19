#define AppVersion "1.1.2"
[Setup]
AppId={{C46118B1-B164-42ED-8CA7-687DC2ED8B75}
AppName=GOB
AppVersion={#AppVersion}
AppPublisher=GOB
AppPublisherURL=https://github.com/motionsamm-lgtm/dropbox-downloader
DefaultDirName={localappdata}\Programs\GOB
DefaultGroupName=GOB
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=GOB-Setup
SetupIconFile=..\assets\windows\GOB.ico
UninstallDisplayIcon={app}\GOB.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\DropboxDownloaderHistoryWindow,Local\DropboxDownloaderBackgroundTransfer
CloseApplications=no
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
[Files]
Source: "dist\portable\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{autoprograms}\GOB"; Filename: "{app}\GOB.exe"; IconFilename: "{app}\GOB.exe"; AppUserModelID: "GOB.GrabOurBytes"
[Run]
Filename: "{app}\GOB.exe"; Description: "Open GOB"; Flags: nowait postinstall
[Code]
function OpenProcess(Access: LongWord; Inherit: Boolean; PID: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function InitializeSetup(): Boolean;
var
  PID: Integer;
  ProcessHandle: THandle;
begin
  Result := True;
  PID := StrToIntDef(ExpandConstant('{param:GOBWAITPID|0}'), 0);
  if PID > 0 then begin
    ProcessHandle := OpenProcess($00100000, False, PID);
    if ProcessHandle <> 0 then begin
      Result := WaitForSingleObject(ProcessHandle, 30000) = 0;
      CloseHandle(ProcessHandle);
    end;
  end;
end;
