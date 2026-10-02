; RPS App Installer
; Build with Inno Setup (iscc app-installer.iss). Drop an "app.zip" (your built app,
; e.g. the Laravel project with vendor/ and any built frontend assets) in this same
; folder before compiling -- or edit AppZipName below to match a different filename.
; This installer only deploys app files into XAMPP's htdocs\<app name> folder; it does
; not touch PHP, MySQL, or Apache's config. Use the main installer.iss (one folder up)
; for the initial full setup (PHP version + VirtualHost + SSL) first.

#define MyAppName "RPS App Installer"
#define AppZipName "app.zip"

; The installer's own version is read from version.txt, which sits next to
; app.zip and holds the version of the release inside it. Hard-coding it meant
; every build announced itself as "1.0" no matter which release it carried,
; so the wizard and the Programs list disagreed with the payload. Write
; version.txt whenever you replace app.zip -- see README.txt.
#define VersionFile "version.txt"
#if FileExists(VersionFile)
  #define VersionHandle FileOpen(VersionFile)
  #define MyAppVersion Trim(FileRead(VersionHandle))
  #expr FileClose(VersionHandle)
#else
  #pragma warning "version.txt not found -- the installer will report 0.0.0. Create it next to app.zip with the release version in it."
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
; Puts the version in the wizard caption, so whoever runs it can see which
; release they are about to deploy without opening app.zip.
AppVerName={#MyAppName} {#MyAppVersion}
DefaultDirName={autopf}\RpsAppInstaller
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=no
DisableFinishedPage=no
; Versioned so two builds sitting in a folder can be told apart. Previously
; every build produced the same filename regardless of the release inside.
OutputBaseFilename=RpsAppInstallerSetup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
; Everything this installer ships is `dontcopy` (extracted to {tmp} and used by
; the deploy script), so nothing is left in DefaultDirName. Without these it
; would still register an Add/Remove Programs entry whose uninstall removes
; nothing, which just confuses whoever finds it later.
Uninstallable=no
CreateUninstallRegKey=no
; Code-signing: without this, the built exe is unsigned and gets hard-blocked by
; Windows Smart App Control on other people's machines ("publisher could not be
; verified"). See installer.iss (one folder up) for how to set this up.
;SignTool=MyCert

[Files]
Source: "deploy-app.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#AppZipName}"; DestDir: "{tmp}"; Flags: dontcopy
; Holds the update-server URL and client shared key. Kept out of the script (and
; out of git) so the key lives in one place; copy deploy-settings.example.json to
; deploy-settings.json and fill it in before compiling.
Source: "deploy-settings.json"; DestDir: "{tmp}"; Flags: dontcopy skipifsourcedoesntexist

[Code]
var
  XamppPage: TInputDirWizardPage;
  AppNamePage: TInputQueryWizardPage;
  DetectedPath: String;
  DeployFailed: Boolean;

function DetectXampp(): String;
var
  Candidates: array[0..3] of String;
  I: Integer;
begin
  Result := '';
  Candidates[0] := 'C:\xampp';
  Candidates[1] := 'D:\xampp';
  Candidates[2] := 'C:\xampp8';
  Candidates[3] := ExpandConstant('{autopf}\xampp');
  for I := 0 to GetArrayLength(Candidates) - 1 do
  begin
    if DirExists(Candidates[I] + '\htdocs') then
    begin
      Result := Candidates[I];
      Exit;
    end;
  end;
end;

procedure InitializeWizard;
begin
  DetectedPath := DetectXampp();
  DeployFailed := False;

  XamppPage := CreateInputDirPage(wpWelcome,
    'Locate XAMPP Installation',
    'Where is XAMPP installed?',
    'Setup needs the folder containing your XAMPP install (must contain an htdocs\ subfolder).',
    False, '');
  XamppPage.Add('');
  if DetectedPath <> '' then
    XamppPage.Values[0] := DetectedPath
  else
    XamppPage.Values[0] := 'C:\xampp';

  AppNamePage := CreateInputQueryPage(XamppPage.ID,
    'Application Details',
    'Where should the app be deployed?',
    'This installer carries RPS {#MyAppVersion}.' + #13#10#13#10 +
    'The app name is the folder name under htdocs (e.g. "rps" -> htdocs\rps). This should ' +
    'match the app name used when the main installer set up the VirtualHost.');
  AppNamePage.Add('App name (folder under htdocs):', False);
  AppNamePage.Values[0] := 'rps';
end;

{ The detected path is only ever a guess -- a machine with both C:\xampp and
  D:\xampp silently got the first one. The page is still shown, pre-filled, so
  it can be corrected. }
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  P, TrimmedName: String;
begin
  Result := True;

  if CurPageID = XamppPage.ID then
  begin
    P := XamppPage.Values[0];
    if not DirExists(P) then
    begin
      MsgBox('That folder does not exist.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not DirExists(P + '\htdocs') then
    begin
      MsgBox('That folder does not look like a XAMPP install' + #13#10 +
             '(missing htdocs\ subfolder). Please check the path.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = AppNamePage.ID then
  begin
    TrimmedName := Trim(AppNamePage.Values[0]);
    if TrimmedName = '' then
    begin
      MsgBox('Please enter an app name.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function RunDeployScript(): Boolean;
var
  ResultCode: Integer;
  ScriptPath, XamppPath, AppZipPath, AppName: String;
  Params, LogPath, FailureMessage: String;
begin
  ExtractTemporaryFile('deploy-app.ps1');
  ExtractTemporaryFile('{#AppZipName}');

  { Optional: only present when the builder filled in deploy-settings.json.
    Without it the script still deploys, but leaves the update-server settings
    in .env alone and says so in the log. }
  try
    ExtractTemporaryFile('deploy-settings.json');
  except
  end;

  ScriptPath := ExpandConstant('{tmp}\deploy-app.ps1');
  XamppPath := XamppPage.Values[0];
  AppZipPath := ExpandConstant('{tmp}\{#AppZipName}');
  AppName := Trim(AppNamePage.Values[0]);
  LogPath := XamppPath + '\backup\deploy-app.log';

  { Replace rather than clear-and-copy, so nothing outside the package is
    removed, and no -Backup: on a first install there is nothing worth zipping,
    and on an existing install the script hands the package to the app's own
    updater, which takes its own database backup and file snapshot anyway. }
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '" ' +
            '-XamppPath "' + XamppPath + '" -AppZipPath "' + AppZipPath + '" ' +
            '-AppName "' + AppName + '"';

  Result := Exec('powershell.exe', Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode)
             and (ResultCode = 0);

  if not Result then
  begin
    FailureMessage := 'Deploy failed (exit code ' + IntToStr(ResultCode) + ').';
    if FileExists(LogPath) then
      FailureMessage := FailureMessage + #13#10 +
        'Check this log for the exact error:' + #13#10 + LogPath
    else
      FailureMessage := FailureMessage + #13#10 +
        'The installer did not create its log file, so the script likely failed before initialization.';

    MsgBox(FailureMessage, mbError, MB_OK);
    DeployFailed := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not RunDeployScript() then
      WizardForm.Close;
  end;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if DeployFailed then
    Confirm := False;
end;
