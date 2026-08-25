; XAMP RPS Local Stack Assistant installer
; Build with Inno Setup (iscc installer.iss). Requires update-xampp-php.ps1 in same folder,
; and a php-8.5.x zip named to match PhpZipName below (or edit that value).

#define MyAppName "XAMP RPS Local Stack Assistant"
#define MyAppVersion "1.3"
#define PhpZipName "php-8.5.8-Win32-vs17-x64.zip"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\XampRPSLocalStackAssistant
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=no
DisableFinishedPage=no
OutputBaseFilename=XampRPSLocalStackAssistantSetup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
; Code-signing: without this, the built exe is unsigned and gets hard-blocked by
; Windows Smart App Control on other people's machines ("publisher could not be
; verified"). To enable:
;   1. Get a code-signing certificate (e.g. Microsoft Trusted Signing, or an OV/EV
;      cert from a CA like Certum/SSL.com/DigiCert).
;   2. In the Inno Setup IDE: Tools -> Configure Sign Tools, add a tool named
;      "MyCert" that runs signtool with your certificate.
;   3. Uncomment the line below (name must match what you configured).
;SignTool=MyCert

[Files]
Source: "update-xampp-php.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#PhpZipName}"; DestDir: "{tmp}"; Flags: dontcopy
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: dontcopy

[Code]
var
  XamppPage: TInputDirWizardPage;
  BackupPage: TInputOptionWizardPage;
  AppPage: TInputQueryWizardPage;
  SourcePage: TInputFileWizardPage;
  DetectedPath: String;
  UpdateFailed: Boolean;

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
    if DirExists(Candidates[I] + '\php') and DirExists(Candidates[I] + '\mysql') then
    begin
      Result := Candidates[I];
      Exit;
    end;
  end;
end;

procedure InitializeWizard;
begin
  DetectedPath := DetectXampp();
  UpdateFailed := False;

  XamppPage := CreateInputDirPage(wpWelcome,
    'Locate XAMPP Installation',
    'Where is XAMPP installed?',
    'Setup needs the folder containing your XAMPP install (must contain php\ and mysql\ subfolders).',
    False, '');
  XamppPage.Add('');
  if DetectedPath <> '' then
    XamppPage.Values[0] := DetectedPath
  else
    XamppPage.Values[0] := 'C:\xampp';

  BackupPage := CreateInputOptionPage(XamppPage.ID,
    'Backup Options',
    'Choose what to back up before updating PHP',
    'PHP will always be backed up. MySQL backup is optional and requires the MySQL service to be stopped first.',
    False, False);
  BackupPage.Add('Back up the MySQL folder before updating PHP');
  BackupPage.Values[0] := True;

  AppPage := CreateInputQueryPage(BackupPage.ID,
    'Application Details',
    'Configure the Apache VirtualHost for your app',
    'The app name becomes the folder name under htdocs and the VirtualHost hostname ' +
    '(e.g. "rps" -> http://rps.local). A matching entry is added to the hosts file automatically.');
  AppPage.Add('App name (folder / hostname):', False);
  AppPage.Values[0] := 'rps';
  AppPage.Add('Document root subfolder (usually "public"):', False);
  AppPage.Values[1] := 'public';

  SourcePage := CreateInputFilePage(AppPage.ID,
    'App Source (optional)',
    'Select a zip file with the app source, or leave blank',
    'If you already copied the app files into htdocs manually, leave this blank.');
  SourcePage.Add('App source .zip:', 'Zip Files|*.zip|All files|*.*', '.zip');
  SourcePage.Values[0] := '';
end;

function IsVCRedist2022X64Installed(): Boolean;
var
  Installed: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', 'Installed', Installed)
            and (Installed = 1);
end;

function InstallVCRedistIfNeeded(): Boolean;
var
  ResultCode: Integer;
  RedistPath: String;
begin
  if IsVCRedist2022X64Installed() then
  begin
    Result := True;
    Exit;
  end;

  ExtractTemporaryFile('vc_redist.x64.exe');
  RedistPath := ExpandConstant('{tmp}\vc_redist.x64.exe');

  Result := Exec(RedistPath, '/install /quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode)
            and ((ResultCode = 0) or (ResultCode = 3010) or (ResultCode = 1638));

  if not Result then
    MsgBox('The Visual C++ 2015-2022 x64 Redistributable failed to install (exit code ' +
           IntToStr(ResultCode) + ').' + #13#10 +
           'PHP 8.5 requires it to run. Install it manually from ' +
           'https://aka.ms/vs/17/release/vc_redist.x64.exe and re-run this installer.',
           mbError, MB_OK);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = XamppPage.ID) and (DetectedPath <> '') then
    Result := True;
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
    if not (DirExists(P + '\php') and DirExists(P + '\mysql')) then
    begin
      MsgBox('That folder does not look like a XAMPP install' + #13#10 +
             '(missing php\ or mysql\ subfolder). Please check the path.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = BackupPage.ID then
  begin
    if BackupPage.Values[0] then
      if MsgBox('MySQL backup is enabled.' + #13#10 +
                'Stop the MySQL service from the XAMPP control panel before continuing.' + #13#10 +
                'Click OK to continue or Cancel to go back.',
                mbConfirmation, MB_OKCANCEL) <> IDOK then
      begin
        Result := False;
        Exit;
      end;
  end;

  if CurPageID = AppPage.ID then
  begin
    TrimmedName := Trim(AppPage.Values[0]);
    if TrimmedName = '' then
    begin
      MsgBox('Please enter an app name.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if Trim(AppPage.Values[1]) = '' then
    begin
      MsgBox('Please enter a document root subfolder (e.g. "public").', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = SourcePage.ID then
  begin
    if (SourcePage.Values[0] <> '') and not FileExists(SourcePage.Values[0]) then
    begin
      MsgBox('That zip file does not exist.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function RunUpdateScript(): Boolean;
var
  ResultCode: Integer;
  ScriptPath, XamppPath, PhpZipPath, AppName, DocRoot, SourceZip: String;
  Params, LogPath, BackupMySqlArg, SourceArg, FailureMessage: String;
begin
  if not InstallVCRedistIfNeeded() then
  begin
    Result := False;
    UpdateFailed := True;
    Exit;
  end;

  ExtractTemporaryFile('update-xampp-php.ps1');
  ExtractTemporaryFile('{#PhpZipName}');
  ScriptPath := ExpandConstant('{tmp}\update-xampp-php.ps1');
  XamppPath := XamppPage.Values[0];
  PhpZipPath := ExpandConstant('{tmp}\{#PhpZipName}');
  AppName := Trim(AppPage.Values[0]);
  DocRoot := Trim(AppPage.Values[1]);
  SourceZip := SourcePage.Values[0];
  LogPath := XamppPath + '\backup\update-php.log';

  if BackupPage.Values[0] then
    BackupMySqlArg := '-BackupMySql'
  else
    BackupMySqlArg := '';

  if SourceZip <> '' then
    SourceArg := '-SourcePath "' + SourceZip + '"'
  else
    SourceArg := '';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '" ' +
            '-XamppPath "' + XamppPath + '" -PhpZipPath "' + PhpZipPath + '" ' +
            '-AppName "' + AppName + '" -DocRootSubfolder "' + DocRoot + '" ' +
            SourceArg + ' ' + BackupMySqlArg;

  Result := Exec('powershell.exe', Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode)
             and (ResultCode = 0);

  if not Result then
  begin
    FailureMessage := 'Update failed (exit code ' + IntToStr(ResultCode) + ').';
    if FileExists(LogPath) then
      FailureMessage := FailureMessage + #13#10 +
        'Check this log for the exact error:' + #13#10 + LogPath
    else
      FailureMessage := FailureMessage + #13#10 +
        'The updater did not create its log file, so the script likely failed before initialization.';

    MsgBox(FailureMessage, mbError, MB_OK);
    UpdateFailed := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not RunUpdateScript() then
      WizardForm.Close;
  end;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if UpdateFailed then
    Confirm := False;
end;
