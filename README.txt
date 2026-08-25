XAMP PHP Updater
=================

WHAT'S IN THIS FOLDER
- update-xampp-php.ps1        -> the script that does the actual work
- Update-XAMPP-PHP.bat        -> double-click this to run it (launches the script elevated)
- php-8.5.8-Win32-vs17-x64.zip -> the PHP version that gets installed
- vc_redist.x64.exe            -> VC++ 2015-2022 x64 redistributable, needed by PHP 8.5
- installer.iss                -> optional: builds a GUI Inno Setup installer instead (see
                                   "ALTERNATIVE" below) -- most people don't need this
- README.txt                   -> this file

QUICK START (recommended - no build step, no installer, nothing to sign)
1. Download/copy this whole folder (or the zip it came in) to the Windows machine.
2. Double-click Update-XAMPP-PHP.bat.
3. Approve the UAC prompt (admin rights are needed to edit Apache config, the hosts file,
   and the system PATH).
4. Answer the prompts in the console window: XAMPP folder (auto-detected if possible),
   whether to back up MySQL, app name / doc root subfolder, optional app source zip.
5. It runs automatically and shows live progress in the console, then finishes. The window
   stays open at the end so you can read the summary -- press Enter to close it.

Re-run the same .bat any time -- for a different app, or after swapping in a newer PHP zip.
Answering the prompts again is safe and repeatable; the VirtualHost block for a given app
name is replaced in place rather than duplicated.

NOTE ON WINDOWS SMART APP CONTROL
Because this ships as a plain script + batch launcher (not a compiled, unsigned .exe), it
does not get hard-blocked by Windows Smart App Control the way an unsigned installer would.
powershell.exe and cmd.exe are already trusted by Windows; only unrecognized executables get
blocked outright.

WHAT IT DOES, IN ORDER
1. Installs the VC++ 2015-2022 x64 redistributable if it isn't already present (uses the
   vc_redist.x64.exe in this folder, or downloads it from Microsoft if that's missing)
2. Stops Apache (so PHP files aren't locked)
3. Backs up the current php\ folder (and mysql\ folder, if checked) into XAMPP's backup\ folder
4. Backs up php.ini and carries over safe settings from the old install
5. Clears the existing php\ folder contents and copies in the new PHP zip
6. Does not carry over old extension DLLs; it only warns about extension entries from the old php.ini so you can review them
7. Deploys the app source zip into htdocs\<app name>, if you provided one
8. Updates Apache's PHP handler lines and PHPIniDir
9. Scans Apache conf files for stale php7 references and repairs them
10. Adds C:\xampp\php and C:\xampp\mysql\bin to the machine PATH if needed (the latter is
    what mysqldump/mysql need to be found by apps that shell out to them, e.g. RPS backups)
11. Adds or updates a VirtualHost for your app in apache\conf\extra\httpd-vhosts.conf,
    serving it at http://<app name>.local instead of a http://localhost/<app name> subfolder
    (a subfolder Alias breaks Laravel's asset/route URLs, redirects and storage symlink,
    since those assume the app is served from the domain root). A default VirtualHost for
    "localhost" is added too, so the XAMPP dashboard keeps working, and a matching
    "127.0.0.1 <app name>.local" line is added to the Windows hosts file.
12. Enables mod_ssl if it isn't already, generates a self-signed SSL certificate scoped to
    <app name>.local (reused as-is on later runs unless the hostname changes), trusts it in
    Windows' Root store, and adds a matching https://<app name>.local VirtualHost. Plain
    http://<app name>.local is treated as an insecure origin by browsers, which silently
    blocks camera/microphone access and other secure-context-only APIs - https:// is what
    actually needs testing if the app uses any of those.
13. Validates the Apache config with "httpd -t" - if that fails, it automatically reverts
    the config changes (httpd.conf and httpd-vhosts.conf) and stops, leaving Apache off so
    nothing is left half-broken
14. Starts Apache back up
15. Runs php -v and php -m after the upgrade and writes a migration report to
    backup\php_migration_report_*.txt

A log file is also written to XAMPP's backup\update-php.log every time it runs.

NOTE ON THE APP'S .env
Because the app is now served from its own hostname rather than a localhost subfolder,
update APP_URL in the app's .env to match. The script also sets up HTTPS for that
hostname (see step 12 above), so prefer APP_URL=https://rps.local over http:// - besides
being the more realistic match for production, some browser APIs (camera/microphone
access, for QR scanning) only work at all on a secure (https or localhost) origin.

RUNNING NON-INTERACTIVELY
Pass any of the parameters on the command line and the script skips prompting for just
that value (pass all of them and it skips every prompt):
  powershell -ExecutionPolicy Bypass -File update-xampp-php.ps1 -XamppPath "C:\xampp" `
    -PhpZipPath ".\php-8.5.8-Win32-vs17-x64.zip" -AppName "rps" -DocRootSubfolder "public" `
    -BackupMySql

ALTERNATIVE: BUILD A GUI INSTALLER WITH INNO SETUP
If you'd rather hand out a polished setup-wizard .exe instead of the script + .bat, you can
still build one with installer.iss (requires Inno Setup: https://jrsoftware.org/isdl.php,
then right-click installer.iss -> Compile). Be aware that an unsigned .exe built this way
will get hard-blocked by Windows Smart App Control on other people's machines with "publisher
could not be verified" -- see the SignTool notes inside installer.iss if you get a code
signing certificate and want to fix that.
