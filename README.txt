XAMP RPS Local Stack Assistant - Inno Setup installer
=============================================

WHAT'S IN THIS FOLDER
- installer.iss             -> the installer source (build this into an .exe, see below)
- update-xampp-php.ps1      -> the script the installer runs; must stay in this same folder
- README.txt                -> this file

ONE-TIME SETUP
1. Install Inno Setup (free): https://jrsoftware.org/isdl.php
2. The PHP zip (php-8.5.8-Win32-vs17-x64.zip) is already included in this repo. To bundle
   a different PHP version instead, replace that file with your zip (same name), or open
   installer.iss and change the PhpZipName line near the top to match your filename.
3. Download the VC++ 2015-2022 x64 redistributable and place it in this folder as
   vc_redist.x64.exe: https://aka.ms/vs/17/release/vc_redist.x64.exe
   (Not committed to the repo since it's a large third-party binary you should get
   straight from Microsoft.)
4. Right-click installer.iss -> "Compile", or open it in the Inno Setup Compiler and press
   Compile (or run "iscc installer.iss" from a command prompt if you prefer).
5. Inno Setup produces a single file: Output\XampRPSLocalStackAssistantSetup.exe

THAT .EXE IS THE THING YOU ACTUALLY WANT
Once it's built, XampRPSLocalStackAssistantSetup.exe is fully self-contained. It has the PHP zip and
the script baked into it. From then on you just double-click it:

1. Double-click XampRPSLocalStackAssistantSetup.exe
2. Approve the UAC prompt
3. Wizard walks through: XAMPP folder (auto-detected if possible) -> MySQL backup option ->
   app name / doc root subfolder -> optional app source zip
4. Click through to install - it runs everything automatically and shows a console with
   live progress, then finishes

You only need to rebuild the .exe again if you change the PHP zip, the app name defaults,
or the script itself. Otherwise the same .exe can be reused/re-run any time.

WHAT IT DOES, IN ORDER
1. Stops Apache (so PHP files aren't locked)
2. Backs up the current php\ folder (and mysql\ folder, if checked) into XAMPP's backup\ folder
3. Backs up php.ini and carries over safe settings from the old install
4. Clears the existing php\ folder contents and copies in the new PHP zip
5. Does not carry over old extension DLLs; it only warns about extension entries from the old php.ini so you can review them
6. Deploys the app source zip into htdocs\<app name>, if you provided one
7. Updates Apache's PHP handler lines and PHPIniDir
8. Scans Apache conf files for stale php7 references and repairs them
9. Adds C:\xampp\php to the machine PATH if needed
10. Adds or updates a VirtualHost for your app in apache\conf\extra\httpd-vhosts.conf,
    serving it at http://<app name>.local instead of a http://localhost/<app name> subfolder
    (a subfolder Alias breaks Laravel's asset/route URLs, redirects and storage symlink,
    since those assume the app is served from the domain root). A default VirtualHost for
    "localhost" is added too, so the XAMPP dashboard keeps working, and a matching
    "127.0.0.1 <app name>.local" line is added to the Windows hosts file.
11. Validates the Apache config with "httpd -t" - if that fails, it automatically reverts
    the config changes (httpd.conf and httpd-vhosts.conf) and stops, leaving Apache off so
    nothing is left half-broken
12. Starts Apache back up
13. Runs php -v and php -m after the upgrade and writes a migration report to
    backup\php_migration_report_*.txt

A log file is also written to XAMPP's backup\update-php.log every time it runs.

RE-RUNNING FOR A DIFFERENT APP OR A DIFFERENT PHP VERSION
Re-run the same .exe. The wizard asks for the app name and PHP zip again each time, and
the VirtualHost block for a given app name is replaced in place rather than duplicated,
so it's safe to run repeatedly.

NOTE ON THE APP'S .env
Because the app is now served from its own hostname rather than a localhost subfolder,
update APP_URL in the app's .env to match (e.g. APP_URL=http://rps.local) so Laravel
generates correct absolute URLs.
