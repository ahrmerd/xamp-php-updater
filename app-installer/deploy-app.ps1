<#
    RPS App Installer / Updater

    Deploys a release zip built by `php artisan release:build` into XAMPP's
    htdocs\<app name> folder.

    Every run does the same thing: stop Apache, copy the package over the app
    folder, clear the compiled views and bootstrap caches, start Apache. The
    app's own in-app updater is deliberately NOT used -- it takes a full
    database backup and a file snapshot before it copies anything, which on a
    XAMPP box makes an update take minutes rather than seconds.

    What happens after the copy depends on one thing: whether the app folder
    already had a .env.

      * NO .env -- first install. The .env from the package is kept and pointed
        at the database, the database is created if missing, and
        `php artisan app:install-local` does the rest (APP_KEY, installation
        identity, migrations, first admin). The storage symlink is created out
        here because it needs the admin rights the installer already has, which
        Apache/PHP usually lack.

      * EXISTING .env -- update. The .env is left as it is, with one exception:
        the update-server settings (URL, client shared key, channel) are
        compared against deploy-settings.json and rewritten only where they
        differ, so a rotated key or a moved manager reaches installs that
        already exist. Every other line is untouched, and the file is not
        rewritten at all when they already match. Then migrations run, because
        releases ship schema changes.

    The trade-off of not using the in-app updater: there is no database backup
    and no automatic rollback. A migration that fails part-way leaves the
    database as it was at that point. Pass -Backup to at least zip the app
    folder first, and take a database dump before updating anything you can't
    afford to lose.
#>
param(
    [string]$XamppPath,
    [string]$AppZipPath,
    [string]$AppName = "rps",
    [switch]$ClearFirst,
    [switch]$Backup,
    [string]$UpdateServerUrl,
    [string]$ClientSharedKey,
    [string]$UpdateChannel,
    [string]$DbName = "rps",
    [string]$DbUser = "root",
    [string]$DbPassword = "",
    [string]$AdminEmail = "rps@admin.local",
    [string]$AdminPassword = "rpsadmin",
    [string]$AdminName = "Admin"
)

$ErrorActionPreference = "Stop"
$script:LogFilePath = $null

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Output $line

    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line -ErrorAction SilentlyContinue
    }
}

function Get-DefaultXamppPath {
    $candidates = @(
        'C:\xampp',
        'D:\xampp',
        'C:\xampp8',
        (Join-Path $env:ProgramFiles 'xampp')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate 'htdocs')) {
            return $candidate
        }
    }
    return $null
}

function Read-PromptWithDefault {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = ''
    )
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $val = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Stop-ApacheIfRunning {
    Log "Stopping Apache (httpd.exe) if running, so app files aren't locked"
    $serviceName = "Apache2.4"
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Log "Stopping Apache Windows service ($serviceName)"
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }

    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

<#
    Starts Apache again after a first install. Mirrors update-xampp-php.ps1: if
    XAMPP registered Apache as a service we can start it for real, otherwise we
    only verify it comes up and stop it again, because an httpd.exe launched
    from this elevated process cannot be stopped by a normally-run XAMPP
    Control Panel and would look permanently stuck "on".
#>
function Start-Apache {
    param([Parameter(Mandatory=$true)][string]$XamppPath)

    $httpdExe = Join-Path $XamppPath "apache\bin\httpd.exe"
    if (-not (Test-Path $httpdExe)) {
        Log "httpd.exe not found at $httpdExe -- leaving Apache alone"
        return $false
    }

    $serviceName = "Apache2.4"
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($svc) {
        Log "Starting Apache Windows service ($serviceName)"
        try {
            Start-Service -Name $serviceName
            Start-Sleep -Seconds 2
            $svc.Refresh()
        }
        catch {
            Log "WARNING: could not start the Apache service: $($_.Exception.Message)"
            return $false
        }

        if ($svc.Status -ne 'Running') {
            Log "WARNING: Apache service did not reach the Running state -- check apache\logs\error.log"
            return $false
        }

        Log "Apache is running again"
        return $true
    }

    Log "No Apache service found; starting httpd.exe briefly to verify the app deploy didn't break its config"
    try {
        $proc = Start-Process -FilePath $httpdExe -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 2
        if ($proc.HasExited) {
            Log "WARNING: Apache exited immediately after start -- check apache\logs\error.log"
            return $false
        }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Log "Apache config verified; stopped again so XAMPP Control Panel (run as your normal user) can start it cleanly"
    }
    catch {
        Log "WARNING: could not verify Apache: $($_.Exception.Message)"
    }

    return $false
}

<#
    XAMPP installs MySQL as a service only when the user ticked that box, so
    this starts the service when there is one and otherwise leaves mysqld to
    the Control Panel -- New-MySqlDatabase below reports clearly if nothing is
    listening either way.
#>
function Start-MySqlIfPresent {
    param([Parameter(Mandatory=$true)][string]$XamppPath)

    foreach ($serviceName in @('mysql', 'MySQL', 'mariadb')) {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $svc) { continue }

        if ($svc.Status -eq 'Running') {
            Log "MySQL service ($serviceName) is already running"
            return $true
        }

        Log "Starting MySQL service ($serviceName)"
        try {
            Start-Service -Name $serviceName
            Start-Sleep -Seconds 3
            return $true
        }
        catch {
            Log "WARNING: could not start the MySQL service: $($_.Exception.Message)"
            return $false
        }
    }

    Log "No MySQL service registered -- assuming it is already running under the XAMPP Control Panel"
    return $false
}

function New-MySqlDatabase {
    param(
        [Parameter(Mandatory=$true)][string]$XamppPath,
        [Parameter(Mandatory=$true)][string]$DbName,
        [Parameter(Mandatory=$true)][string]$DbUser,
        [string]$DbPassword = ''
    )

    $mysqlExe = Join-Path $XamppPath 'mysql\bin\mysql.exe'
    if (-not (Test-Path $mysqlExe)) {
        Log "WARNING: mysql.exe not found at $mysqlExe"
        return $false
    }

    Log "Creating the '$DbName' database if it doesn't exist"

    $arguments = @("--user=$DbUser")
    if (-not [string]::IsNullOrEmpty($DbPassword)) { $arguments += "--password=$DbPassword" }
    $arguments += @('--execute', ('"CREATE DATABASE IF NOT EXISTS `' + $DbName + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"'))

    $outFile = Join-Path $env:TEMP "rps_mysql_out_$PID.txt"
    $errFile = Join-Path $env:TEMP "rps_mysql_err_$PID.txt"

    try {
        $proc = Start-Process -FilePath $mysqlExe -ArgumentList $arguments `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        if ($proc.ExitCode -ne 0) {
            $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            Log "WARNING: mysql.exe exited with code $($proc.ExitCode): $stderr"
            return $false
        }

        Log "Database '$DbName' is ready"
        return $true
    }
    catch {
        Log "WARNING: could not run mysql.exe: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Artisan {
    param(
        [Parameter(Mandatory=$true)][string]$PhpExe,
        [Parameter(Mandatory=$true)][string]$AppDir,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    Log "Running php artisan $($Arguments -join ' ')"

    $outFile = Join-Path $env:TEMP "rps_artisan_out_$PID.txt"
    $errFile = Join-Path $env:TEMP "rps_artisan_err_$PID.txt"

    $proc = Start-Process -FilePath $PhpExe -ArgumentList (@('artisan') + $Arguments) `
        -WorkingDirectory $AppDir -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

    foreach ($line in (("$stdout`n$stderr") -split "`r?`n")) {
        if ($line.Trim()) { Log "  $line" }
    }

    return $proc.ExitCode
}

<#
    Clears everything Laravel generated from the previous release: the compiled
    Blade views under storage\framework\views and the bootstrap caches (config,
    routes, events, and the package/service manifests).

    The files are deleted directly first, and only then does artisan get a go.
    That order matters: a stale compiled view or route cache from the previous
    release is exactly the thing that makes artisan itself fail to boot, and
    deleting the files needs no PHP at all -- so the clear still happens on a
    machine where php.exe is missing or broken.
#>
function Clear-AppCaches {
    param(
        [Parameter(Mandatory=$true)][string]$AppDir,
        [Parameter(Mandatory=$true)][string]$PhpExe
    )

    Log "Clearing compiled views and bootstrap caches"

    $viewCacheDir = Join-Path $AppDir 'storage\framework\views'
    if (Test-Path $viewCacheDir) {
        $views = @(Get-ChildItem -LiteralPath $viewCacheDir -Filter '*.php' -File -Force -ErrorAction SilentlyContinue)
        foreach ($view in $views) {
            Remove-Item -LiteralPath $view.FullName -Force -ErrorAction SilentlyContinue
        }
        Log "  Removed $($views.Count) compiled view(s)"
    }

    $bootstrapCacheDir = Join-Path $AppDir 'bootstrap\cache'
    foreach ($cacheFile in @('config.php', 'routes-v7.php', 'routes.php', 'events.php', 'packages.php', 'services.php')) {
        $path = Join-Path $bootstrapCacheDir $cacheFile
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Log "  Removed bootstrap\cache\$cacheFile"
        }
    }

    if (-not (Test-Path $PhpExe)) {
        Log "  PHP not found -- cache files were still deleted directly"
        return
    }

    # Catches anything the file sweep above doesn't know about (the application
    # cache store, for one). Failure here is not fatal: the files that actually
    # go stale between releases are already gone.
    if ((Invoke-Artisan -PhpExe $PhpExe -AppDir $AppDir -Arguments @('optimize:clear')) -ne 0) {
        Log "  WARNING: optimize:clear reported an error, but the stale cache files were already deleted"
    }
}

<#
    Extracts the release package straight into the app folder, reporting as it
    goes.

    This replaces Expand-Archive into a temp folder followed by a recursive
    Copy-Item. That did the work twice over -- roughly 12,000 files written to
    disk, then read and written again -- and neither step could say anything
    while it ran, so the console sat silent for minutes on end and the
    installer looked hung.

    Going entry by entry means every file can be counted, so there is a real
    progress bar and a percentage in the log. The trade-off, deliberate: files
    land in the app folder as they are read, so an extraction that dies
    half-way leaves the folder half-updated. Pass -Backup if that matters.

    $Preserve holds archive-relative paths that must not be written at all
    (the package's .env, when the installation already has one).
#>
function Expand-PackageInto {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [string[]]$Preserve = @()
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    try {
        $entries = @($archive.Entries)
        $total = $entries.Count

        if ($total -eq 0) {
            throw "The package at $ZipPath contains no files."
        }

        # Zipping a project folder directly leaves everything under a single
        # wrapper directory; deploy its contents, not the wrapper itself.
        $rootPrefix = ''
        $topLevel = @($entries |
            ForEach-Object { ($_.FullName -split '/')[0] } |
            Sort-Object -Unique)

        if ($topLevel.Count -eq 1 -and -not ($entries | Where-Object { $_.FullName -eq $topLevel[0] })) {
            $rootPrefix = $topLevel[0] + '/'
            Log "Package is wrapped in a single '$($topLevel[0])' folder -- deploying its contents"
        }

        Log "Extracting $total files into $Destination"

        $written = 0
        $skipped = 0
        $lastReportedPercent = -1
        $lastDrawnPercent = -1

        for ($i = 0; $i -lt $total; $i++) {
            $entry = $entries[$i]
            $relativePath = $entry.FullName

            if ($rootPrefix -ne '' -and $relativePath.StartsWith($rootPrefix)) {
                $relativePath = $relativePath.Substring($rootPrefix.Length)
            }

            if ($relativePath -eq '') { continue }

            $windowsPath = $relativePath -replace '/', '\'

            if ($Preserve -contains $windowsPath) {
                Log "  Keeping the existing $windowsPath -- not taking the one from the package"
                $skipped++
                continue
            }

            $targetPath = Join-Path $Destination $windowsPath

            # A directory entry, or a file whose folder doesn't exist yet.
            if ($entry.Name -eq '') {
                New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
                continue
            }

            $parent = Split-Path -Parent $targetPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }

            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            $written++

            $percent = [int](($i + 1) / $total * 100)

            # Only redrawn when the number actually changes. Calling
            # Write-Progress once per file across ~12,000 files costs more time
            # than the extraction it is reporting on.
            if ($percent -ne $lastDrawnPercent) {
                $lastDrawnPercent = $percent

                Write-Progress -Activity "Deploying the app" `
                    -Status "$($i + 1) of $total files" `
                    -CurrentOperation $windowsPath `
                    -PercentComplete $percent
            }

            # Logged every 10% so the log file stays readable while the
            # console still shows a live bar.
            if ($percent -ge $lastReportedPercent + 10) {
                $lastReportedPercent = $percent - ($percent % 10)
                Log "  $lastReportedPercent% ($($i + 1) of $total files)"
            }
        }

        Write-Progress -Activity "Deploying the app" -Completed

        Log "Extracted $written files ($skipped preserved)"
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ZipEntryText {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$EntryName
    )

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) { return $null }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    catch {
        return $null
    }
    finally {
        if ($archive) { $archive.Dispose() }
    }
}

function ConvertTo-ComparableVersion {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    $core = ($Version -split '[-+]')[0].Trim()
    $parsed = $null
    if ([version]::TryParse($core, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory=$true)][string]$EnvPath,
        [Parameter(Mandatory=$true)][string]$Key
    )

    if (-not (Test-Path $EnvPath)) { return $null }

    $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$"
    foreach ($line in (Get-Content -LiteralPath $EnvPath -ErrorAction SilentlyContinue)) {
        if ($line -match $pattern) { return $Matches[1].Trim().Trim('"') }
    }

    return $null
}

function Set-EnvValues {
    param(
        [Parameter(Mandatory=$true)][string]$EnvPath,
        [Parameter(Mandatory=$true)][System.Collections.Specialized.OrderedDictionary]$Values
    )

    if ($Values.Count -eq 0) {
        Log "No update-server settings supplied -- leaving .env untouched"
        return
    }

    if (-not (Test-Path $EnvPath)) {
        Log ".env not found at $EnvPath -- skipping RPS update-server settings"
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Get-Content -LiteralPath $EnvPath))

    $changed = $false

    foreach ($key in $Values.Keys) {
        $newLine = "$key=$($Values[$key])"
        $pattern = "^\s*$([regex]::Escape($key))\s*=\s*(.*)$"
        $index = -1
        $currentValue = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                $index = $i
                $currentValue = $Matches[1].Trim().Trim('"')
                break
            }
        }

        if ($index -ge 0) {
            # Only rewrite a key whose value actually differs. On an update this
            # is what lets a rotated shared key or a moved update-server URL
            # reach an existing install, while leaving every other line -- and
            # every key that already matches -- exactly as the site had it.
            if ($currentValue -ceq [string]$Values[$key]) {
                Log "  $key already matches -- left alone"
                continue
            }

            $lines[$index] = $newLine
            Log "  Updated $key in .env (differed from the configured value)"
            $changed = $true
        }
        else {
            $lines.Add($newLine)
            Log "  Added missing $key to .env"
            $changed = $true
        }
    }

    if (-not $changed) {
        Log "  .env already has the configured values -- not rewriting it"
        return
    }

    # Deliberately BOM-less: Set-Content -Encoding UTF8 on Windows PowerShell
    # writes a BOM, which anything reading .env with a plain parser (not just
    # Laravel) then has to know to strip.
    [System.IO.File]::WriteAllLines($EnvPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-PathReportingFailure {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return @()
    }
    catch {
        return @("$Path -- $($_.Exception.Message)")
    }
}

<#
    Clears the app folder so files dropped from the release actually disappear,
    while keeping everything that belongs to the installation rather than to
    the package: secrets (.env), user uploads and database backups (storage\),
    the storage symlink, and the generated bootstrap caches. These are the same
    paths UpdateService::EXCLUDED_PATHS protects during an in-app update.
#>
function Clear-AppDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)

    $preservedTopLevel = @('.env', 'storage')
    $preservedNested = @{ 'bootstrap' = @('cache'); 'public' = @('storage') }
    $failures = @()

    foreach ($item in (Get-ChildItem -LiteralPath $Path -Force)) {
        if ($preservedTopLevel -contains $item.Name) {
            Log "  Preserving $($item.Name)"
            continue
        }

        if ($item.PSIsContainer -and $preservedNested.ContainsKey($item.Name)) {
            $keep = $preservedNested[$item.Name]
            Log "  Clearing $($item.Name)\ but preserving $($item.Name)\$($keep -join ", $($item.Name)\")"
            foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -Force)) {
                if ($keep -contains $child.Name) { continue }
                $failures += Remove-PathReportingFailure -Path $child.FullName
            }
            continue
        }

        $failures += Remove-PathReportingFailure -Path $item.FullName
    }

    return $failures
}

function New-AppBackup {
    param(
        [Parameter(Mandatory=$true)][string]$AppDir,
        [Parameter(Mandatory=$true)][string]$BackupZip
    )

    # vendor\ and node_modules\ are reinstalled from the release zip and are by
    # far the slowest part of a Compress-Archive over a Laravel tree (and the
    # likeliest to blow the 260-character path limit), so they are left out.
    $items = @(Get-ChildItem -LiteralPath $AppDir -Force |
        Where-Object { $_.Name -notin @('vendor', 'node_modules') })

    if ($items.Count -eq 0) {
        Log "Nothing to back up in $AppDir"
        return $true
    }

    try {
        Compress-Archive -Path $items.FullName -DestinationPath $BackupZip -Force -ErrorAction Stop
        Log "Backed up existing app folder (excluding vendor\, node_modules\) -> $BackupZip"
        return $true
    }
    catch {
        # Non-fatal on purpose: a backup that cannot be written is a reason to
        # warn, not a reason to abandon the deploy the operator asked for.
        Log "WARNING: could not back up the existing app folder: $($_.Exception.Message)"
        Log "WARNING: continuing without a file backup."
        return $false
    }
}

function Get-DeploySettings {
    param([Parameter(Mandatory=$true)][string]$ScriptDir)

    $settingsPath = Join-Path $ScriptDir 'deploy-settings.json'
    if (-not (Test-Path $settingsPath)) { return $null }

    try {
        return Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    }
    catch {
        Log "WARNING: deploy-settings.json could not be parsed: $($_.Exception.Message)"
        return $null
    }
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$settings = Get-DeploySettings -ScriptDir $scriptDir

if (-not $PSBoundParameters.ContainsKey('UpdateServerUrl') -and $settings) { $UpdateServerUrl = [string]$settings.UpdateServerUrl }
if (-not $PSBoundParameters.ContainsKey('ClientSharedKey') -and $settings) { $ClientSharedKey = [string]$settings.ClientSharedKey }
if (-not $PSBoundParameters.ContainsKey('UpdateChannel') -and $settings) { $UpdateChannel = [string]$settings.UpdateChannel }
if ([string]::IsNullOrWhiteSpace($UpdateChannel)) { $UpdateChannel = 'stable' }

$script:Interactive = -not $PSBoundParameters.ContainsKey('XamppPath')

if ($script:Interactive) {
    Write-Host ""
    Write-Host "=== RPS App Installer ===" -ForegroundColor Cyan
    Write-Host "Deploys a release zip into XAMPP's htdocs folder. First installs copy the" -ForegroundColor Cyan
    Write-Host "files and hand over to the app's /install wizard; existing installs are" -ForegroundColor Cyan
    Write-Host "updated through the app's own updater. Press Ctrl+C at any point to abort." -ForegroundColor Cyan
    Write-Host ""

    $detected = Get-DefaultXamppPath
    $xamppDefault = if ($detected) { $detected } else { 'C:\xampp' }
    $XamppPath = Read-PromptWithDefault -Prompt "XAMPP folder" -Default $xamppDefault
    while (-not (Test-Path (Join-Path $XamppPath 'htdocs'))) {
        Write-Host "That folder doesn't look like a XAMPP install (missing htdocs\ subfolder)." -ForegroundColor Red
        $XamppPath = Read-PromptWithDefault -Prompt "XAMPP folder" -Default $XamppPath
    }

    if (-not $PSBoundParameters.ContainsKey('AppZipPath')) {
        $zipCandidates = @(Get-ChildItem -Path $scriptDir -Filter 'app*.zip' -File -ErrorAction SilentlyContinue)
        $zipDefault = if ($zipCandidates.Count -gt 0) { $zipCandidates[0].FullName } else { '' }
        $AppZipPath = Read-PromptWithDefault -Prompt "App zip to deploy" -Default $zipDefault
    }
    while (-not (Test-Path $AppZipPath)) {
        Write-Host "That zip file doesn't exist." -ForegroundColor Red
        $AppZipPath = Read-PromptWithDefault -Prompt "App zip to deploy" -Default $AppZipPath
    }

    if (-not $PSBoundParameters.ContainsKey('AppName')) {
        $AppName = Read-PromptWithDefault -Prompt "App folder name under htdocs" -Default 'rps'
    }
}

if (-not $XamppPath)   { throw "XamppPath is required." }
if (-not $AppZipPath)  { throw "AppZipPath is required." }
if (-not $AppName)     { throw "AppName is required." }

try {
    $XamppPath = $XamppPath.TrimEnd('\')
    $htdocsDir = Join-Path $XamppPath "htdocs"
    $appDir = Join-Path $htdocsDir $AppName
    $backupDir = Join-Path $XamppPath "backup"
    $phpExe = Join-Path $XamppPath "php\php.exe"

    if (-not (Test-Path $htdocsDir))  { throw "htdocs folder not found: $htdocsDir" }
    if (-not (Test-Path $AppZipPath)) { throw "App zip not found: $AppZipPath" }

    $AppZipPath = (Resolve-Path -LiteralPath $AppZipPath).Path

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    # Appended, not overwritten: when a customer's third update is the one that
    # goes wrong, the first two runs are the context you need.
    $script:LogFilePath = Join-Path $backupDir 'deploy-app.log'
    Add-Content -Path $script:LogFilePath -Value "" -ErrorAction SilentlyContinue
    Log "=== Starting app deploy for '$AppName' ==="

    # Read for the log only. A zip without a manifest still deploys -- nothing
    # here refuses to run over what it finds.
    $packageVersion = 'unknown'
    $rawManifest = Get-ZipEntryText -ZipPath $AppZipPath -EntryName 'release-manifest.json'
    if ($rawManifest) {
        $packageVersion = [string]($rawManifest | ConvertFrom-Json).version
    }

    Log "Release package version: $packageVersion"

    $installedVersionRaw = $null
    if (Test-Path (Join-Path $appDir 'VERSION')) {
        $installedVersionRaw = (Get-Content -LiteralPath (Join-Path $appDir 'VERSION') -Raw -ErrorAction SilentlyContinue)
        if ($installedVersionRaw) { $installedVersionRaw = $installedVersionRaw.Trim() }
    }

    if ($installedVersionRaw) {
        Log "Currently installed version: $installedVersionRaw"

        $installedVersion = ConvertTo-ComparableVersion $installedVersionRaw
        $newVersion = ConvertTo-ComparableVersion $packageVersion

        # Logged, never blocking. RPS version numbers are not strictly increasing
        # over time -- older builds carry higher numbers -- so refusing on this
        # would stop deploys that are perfectly legitimate.
        if ($installedVersion -and $newVersion -and $newVersion -lt $installedVersion) {
            Log "NOTE: $packageVersion is numbered lower than the installed $installedVersionRaw. Deploying it anyway."
        }
    }

    $rpsEnvValues = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($UpdateServerUrl)) { $rpsEnvValues['RPS_UPDATE_SERVER_URL'] = $UpdateServerUrl }
    if (-not [string]::IsNullOrWhiteSpace($ClientSharedKey)) { $rpsEnvValues['RPS_CLIENT_SHARED_KEY'] = $ClientSharedKey }
    if ($rpsEnvValues.Count -gt 0) { $rpsEnvValues['RPS_UPDATE_CHANNEL'] = $UpdateChannel }

    $envPath = Join-Path $appDir ".env"

    # The one thing that decides what happens after the copy. An existing .env
    # means this machine has been set up already, so the copy is an update and
    # the .env is left exactly as it is. No .env means a first install, and the
    # one from the package gets filled in.
    $isFirstInstall = -not (Test-Path $envPath)

    Log $(if ($isFirstInstall) { "No .env at $appDir -- first install" } else { "Existing .env found -- update; it will be left untouched" })

    $existingItems = if (Test-Path $appDir) { @(Get-ChildItem -LiteralPath $appDir -Force -ErrorAction SilentlyContinue) } else { @() }

    if ($existingItems.Count -gt 0) {
        Stop-ApacheIfRunning

        if ($Backup) {
            New-AppBackup -AppDir $appDir -BackupZip (Join-Path $backupDir "${AppName}_backup_$ts.zip") | Out-Null
        }
        else {
            Log "Not backing up the existing app folder (pass -Backup to zip it into $backupDir first)"
        }
    }

    New-Item -ItemType Directory -Force -Path $appDir | Out-Null

    if ($ClearFirst) {
        Log "Clearing existing app folder contents before copying (clear-and-copy mode)"
        $clearFailures = Clear-AppDirectory -Path $appDir
        if ($clearFailures.Count -gt 0) {
            Log "WARNING: $($clearFailures.Count) item(s) could not be removed, so stale files may remain:"
            foreach ($failure in $clearFailures) { Log "  $failure" }
        }
    }
    else {
        Log "Writing new files over the existing app folder (replace mode; files no longer in the package are left in place)"
    }

    # An existing installation's .env is never overwritten by the package's.
    $preserve = @()
    if (-not $isFirstInstall) {
        $preserve += '.env'
    }

    Expand-PackageInto -ZipPath $AppZipPath -Destination $appDir -Preserve $preserve

    Clear-AppCaches -AppDir $appDir -PhpExe $phpExe

    $setupComplete = -not $isFirstInstall

    if ($isFirstInstall) {
        # Written before app:install-local runs, because that command ends with
        # config:cache -- anything added to .env afterwards would be shadowed by
        # the cached config until someone cleared it.
        $dbEnvValues = [ordered]@{
            'DB_CONNECTION' = 'mysql'
            'DB_HOST'       = '127.0.0.1'
            'DB_PORT'       = '3306'
            'DB_DATABASE'   = $DbName
            'DB_USERNAME'   = $DbUser
            'DB_PASSWORD'   = $DbPassword
        }

        foreach ($key in $rpsEnvValues.Keys) { $dbEnvValues[$key] = $rpsEnvValues[$key] }
        Set-EnvValues -EnvPath $envPath -Values $dbEnvValues

        if (-not (Test-Path $phpExe)) {
            Log "WARNING: PHP not found at $phpExe -- skipping database setup entirely."
            Log "WARNING: the app will not boot until PHP is repaired and setup is run by hand."
        }
        else {
            Start-MySqlIfPresent -XamppPath $XamppPath | Out-Null

            if (-not (New-MySqlDatabase -XamppPath $XamppPath -DbName $DbName -DbUser $DbUser -DbPassword $DbPassword)) {
                Log "WARNING: could not create the '$DbName' database automatically."
                Log "WARNING: create it in phpMyAdmin, then finish setup at http://$AppName.local/install"
            }
            else {
                # app:install-local is the app's own headless installer: it fills
                # in a missing APP_KEY, writes the per-machine installation
                # identity, migrates, creates the first admin, and caches config.
                # It is the same work the /install wizard does, minus the questions.
                $exitCode = Invoke-Artisan -PhpExe $phpExe -AppDir $appDir -Arguments @(
                    'app:install-local',
                    ('--admin-email=' + $AdminEmail),
                    ('--admin-password=' + $AdminPassword),
                    ('--admin-name="' + $AdminName + '"')
                )

                if ($exitCode -ne 0) {
                    Log "WARNING: php artisan app:install-local failed (exit code $exitCode)."
                    Log "WARNING: the files are in place -- finish setup at http://$AppName.local/install once the cause above is resolved."
                    $setupComplete = $false
                }
                else {
                    $setupComplete = $true
                }
            }

            # Creating the symlink needs the elevation this installer already has;
            # the wizard's own button often fails because Apache/PHP runs without it.
            if (Test-Path (Join-Path $appDir 'public\storage')) {
                Log "public\storage already exists -- leaving it alone"
            }
            elseif ((Invoke-Artisan -PhpExe $phpExe -AppDir $appDir -Arguments @('storage:link')) -ne 0) {
                Log "WARNING: php artisan storage:link failed. Uploaded files will 404 until it is created -- the /install wizard has a button to retry it."
            }
        }
    }
    else {
        # The existing .env is otherwise left alone, but the update-server
        # settings are reconciled: if the shared key was rotated or the manager
        # moved, an install that never gets them would silently stop being able
        # to check for updates. Only keys whose value actually differs are
        # touched, and the file is not rewritten at all when they all match.
        if ($rpsEnvValues.Count -gt 0) {
            Log "Checking the update-server settings in the existing .env"
            Set-EnvValues -EnvPath $envPath -Values $rpsEnvValues
        }
        else {
            Log "No update-server settings configured (deploy-settings.json missing or empty) -- .env left as-is"
        }

        if (Test-Path $phpExe) {
            # Releases ship schema changes, so an update that skipped this would
            # leave the new code running against the old tables.
            if ((Invoke-Artisan -PhpExe $phpExe -AppDir $appDir -Arguments @('migrate', '--force')) -ne 0) {
                Log "WARNING: php artisan migrate failed. The new files are in place but the database schema is behind -- check the output above."
                $setupComplete = $false
            }
        }
        else {
            Log "WARNING: PHP not found at $phpExe -- migrations were not run. The new files are in place but the database schema may be behind."
            $setupComplete = $false
        }
    }

    $apacheRunning = Start-Apache -XamppPath $XamppPath

    Log "App '$AppName' (version $packageVersion) deployed to $appDir"
    Log "Backup folder: $backupDir"

    if (-not $apacheRunning) {
        Log "NEXT: start Apache from the XAMPP Control Panel (run it as your normal user, not elevated)."
    }

    if ($setupComplete) {
        Log "Installation complete. Sign in at http://$AppName.local as $AdminEmail"
        Log "IMPORTANT: change that password after the first sign-in -- it is the same on every install."
    }
    else {
        Log "NEXT: finish setup at http://$AppName.local/install"
    }

    exit 0
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
