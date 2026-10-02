RPS App Installer
==================

Deploys a release zip built by `php artisan release:build` into XAMPP's htdocs\<app name>
folder. Run the main installer (one folder up) first -- that one sets up PHP, the
VirtualHost, SSL and the hosts entry. This one only deals with the app itself.

Every run does the same thing: stop Apache, copy the package over the app folder, clear the
compiled views and bootstrap caches, start Apache.

The app's own in-app updater is deliberately NOT used. It takes a full database backup and
a snapshot of every file it is about to overwrite before it copies anything, which on a
XAMPP box turns a routine update into minutes rather than seconds.

The trade-off is worth stating plainly: there is no database backup and no automatic
rollback. A migration that fails part-way leaves the database where it stopped. Pass
-Backup to at least zip the app folder first, and take a database dump before updating
anything you cannot afford to lose.

What happens after the copy depends on one thing -- whether the app folder already had a
.env:

- NO .env -> FIRST INSTALL. The .env from the package is kept and pointed at the database,
  the database is created if it doesn't exist, and `php artisan app:install-local` does the
  rest (APP_KEY, installation identity, migrations, first admin). The storage symlink is
  created here too, because it needs the admin rights the installer already has and
  Apache/PHP usually lack.

- EXISTING .env -> UPDATE. The .env is left as it is, with one exception: the update-server
  settings (RPS_UPDATE_SERVER_URL, RPS_CLIENT_SHARED_KEY, RPS_UPDATE_CHANNEL) are compared
  against deploy-settings.json and rewritten only where they differ, so a rotated shared key
  or a moved update manager reaches installs that already exist. Keys that already match are
  left alone, every other line is untouched, and the file is not rewritten at all when
  nothing differs. Then migrations run, because releases ship schema changes.

Caches are cleared by deleting storage\framework\views\*.php and the bootstrap\cache
manifests directly, and then running `optimize:clear`. The direct deletion comes first on
purpose: a stale compiled view or route cache from the previous release is exactly what
stops artisan being able to boot, and deleting files needs no PHP at all -- so the clear
still happens on a machine where php.exe is missing or broken.

WHAT'S IN THIS FOLDER
- app-installer.iss             -> Inno Setup script that builds the GUI installer .exe
- deploy-app.ps1                -> the script that does the actual work (also runnable
                                    standalone)
- deploy-settings.example.json  -> template for the update-server settings
- deploy-settings.json          -> the real update-server URL + client shared key. Not in
                                    git. Copy the .example one and fill it in.
- app.zip                       -> the release zip to deploy. Not in git -- put your own
                                    here before compiling.
- version.txt                   -> the version inside app.zip, read by the .iss so the
                                    installer reports the right one. Not in git; written
                                    from app.zip at build time (see BUILD).

BUILD
1. In the RPS project, build a release:
     php artisan release:build 1.2.4 --changelog="..."
   and copy the resulting zip (storage\app\private\updates\releases\<version>.zip) into
   this folder as app.zip.
1a. Write that same version into version.txt next to app.zip:
     unzip -p app.zip VERSION > version.txt
   The .iss reads it, so the wizard caption, the Programs list and the output filename all
   report the release actually inside app.zip. Skip this and the installer announces itself
   as 0.0.0 (with a compile warning), which is how it previously ended up claiming to be
   "1.0" while carrying a much later release.
2. Copy deploy-settings.example.json to deploy-settings.json and fill in the update-server
   URL and client shared key, if you haven't already.
3. Open app-installer.iss in Inno Setup and Compile (or right-click -> Compile).
4. The output .exe is written to
   app-installer\Output\RpsAppInstallerSetup-<version>.exe -- versioned so two builds in
   the same folder can be told apart.

Re-run the compile step each time you have a new app.zip to ship an updated installer.

RUN
1. Copy the built .exe to the target Windows machine and run it.
2. Approve the UAC prompt (admin rights are needed to write to htdocs, control services,
   and create the storage symlink).
3. Confirm the XAMPP folder (pre-filled if it could be detected -- check it, a machine with
   more than one XAMPP install will only ever guess the first) and the app name (folder
   under htdocs, e.g. "rps"). The app name must match the one the main installer used for
   the VirtualHost.
4. It reads the version out of app.zip and logs it alongside what's installed. Nothing here
   blocks: a lower-numbered package only writes a note to the log, because RPS version
   numbers are not strictly increasing over time and a machine holding an older build with
   a higher number would otherwise be stopped from taking a package that is genuinely
   newer. If you see that note and it isn't a deliberate rollback, check which build is
   actually on the machine. A zip with no release-manifest.json still deploys; the version
   is just logged as "unknown".
5. From there it follows either the first-install or the update path described above.

On a first install the defaults are:
  database  rps  (created if it doesn't exist, as root with no password -- XAMPP stock)
  admin     rps@admin.local / rpsadmin
CHANGE THAT PASSWORD after the first sign-in. It is the same on every install.

Apache is stopped before any files are written, so nothing is locked mid-copy, and started
again afterwards -- unless XAMPP never registered it as a Windows service, in which case the
script only verifies it comes up and then stops it again, so your own (non-elevated) Control
Panel can start it cleanly without an elevation mismatch. The log says which of the two
happened, and tells you when you need to start Apache yourself.

Progress is reported while files are written: a live bar in the console, and a percentage in
the log every 10%. The package is extracted straight into the app folder rather than into a
temp folder and copied across, which halves the disk work on a ~12,000-file release. The
trade-off is that an extraction interrupted half-way leaves the app folder half-updated --
use -Backup if that matters on the machine you are updating.

A log file is appended to XAMPP's backup\deploy-app.log every time it runs. It is appended,
not overwritten, so earlier runs stay available when a later one goes wrong.

RUNNING WITHOUT THE INSTALLER
deploy-app.ps1 can be run directly and will prompt for anything not passed on the command
line:
  powershell -ExecutionPolicy Bypass -File deploy-app.ps1 -XamppPath "C:\xampp" `
    -AppZipPath ".\app.zip" -AppName "rps"

Options:
  -Backup           Zip the existing app folder into XAMPP's backup\ folder before
                    deploying. Off by default. vendor\ and node_modules\ are left out (they
                    come back from the zip, and they are what makes the archive slow and
                    liable to hit the 260-character path limit). A backup that fails is a
                    warning, not a stopped deploy.
  -ClearFirst       Delete the existing app folder contents before copying, so files
                    dropped from the release are actually gone. .env, storage\,
                    bootstrap\cache\ and public\storage are always preserved -- those hold
                    secrets, uploads, database backups and generated caches, and storage\
                    is not in the release zip, so clearing it would destroy data with no
                    way back. Anything that can't be deleted is reported, not swallowed.
  -DbName           Database to use/create. Default: rps
  -DbUser           MySQL user. Default: root
  -DbPassword       MySQL password. Default: empty (XAMPP stock)
  -AdminEmail       First admin's email. Default: rps@admin.local
  -AdminPassword    First admin's password. Default: rpsadmin
  -AdminName        First admin's display name. Default: Admin
  -UpdateServerUrl  }
  -ClientSharedKey  }  Override deploy-settings.json for a single run.
  -UpdateChannel    }

The update-server options are the exception to "an update leaves .env alone": they are
reconciled on every run, writing only the keys whose value differs from what's configured.

The database and admin options only apply to a first install -- an update never touches
them.

IF SOMETHING GOES WRONG
- Migrations failed on an update: the new files are already in place, so the app is running
  new code against an older schema. There is no automatic rollback -- read
  backup\deploy-app.log for the actual error, fix it, and run `php artisan migrate --force`
  in htdocs\<app name> yourself.
- PHP is missing: the copy and the cache clear still happen (both are plain file
  operations), but migrations do not run and a first install cannot be completed. Repair
  PHP with the main installer one folder up and re-run this one.
- The database couldn't be created, or app:install-local failed: the files are still in
  place. Finish setup in the browser at http://<app name>.local/install
- The app still shows old pages after an update: that is a cache that survived. Check the
  log for the "Clearing compiled views and bootstrap caches" lines, and if needed run
  `php artisan optimize:clear` in htdocs\<app name>.
