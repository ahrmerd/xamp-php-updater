param(
    [string]$XamppPath,
    [string]$PhpZipPath,
    [string]$AppName,
    [string]$SourcePath,
    [string]$DocRootSubfolder = "public",
    [switch]$BackupMySql
)

$ErrorActionPreference = "Stop"
$script:LogFilePath = $null
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Output $line

    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-TextFileNoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-TempRootPath {
    $preferredRoot = 'C:\xamp-php-updater-temp'
    $fallbackRoot = Join-Path $env:SystemDrive 'xamp-php-updater-temp'

    foreach ($candidate in @($preferredRoot, $fallbackRoot, $env:TEMP)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        try {
            New-Item -ItemType Directory -Force -Path $candidate | Out-Null
            return $candidate
        }
        catch {
            continue
        }
    }

    throw "Unable to create a temporary working directory on C: or in the system temp path."
}

function Get-DefaultXamppPath {
    $candidates = @(
        'C:\xampp',
        'D:\xampp',
        'C:\xampp8',
        (Join-Path $env:ProgramFiles 'xampp')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path (Join-Path $candidate 'php')) -and (Test-Path (Join-Path $candidate 'mysql'))) {
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

function Install-VCRedistIfNeeded {
    $installed = $false
    try {
        $val = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' -Name 'Installed' -ErrorAction Stop
        $installed = ($val -eq 1)
    }
    catch {
        $installed = $false
    }

    if ($installed) {
        Log "VC++ 2015-2022 x64 redistributable already installed"
        return
    }

    Log "VC++ 2015-2022 x64 redistributable not found; PHP 8.5 needs it to run"
    $localRedist = Join-Path $script:ScriptDir 'vc_redist.x64.exe'
    $redistPath = $null

    if (Test-Path $localRedist) {
        $redistPath = $localRedist
    }
    else {
        Log "vc_redist.x64.exe not found alongside script; downloading from Microsoft"
        $redistPath = Join-Path (Get-TempRootPath) 'vc_redist.x64.exe'
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redistPath -UseBasicParsing
    }

    Log "Installing VC++ redistributable (silent)"
    $proc = Start-Process -FilePath $redistPath -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 3010, 1638)) {
        throw "VC++ redistributable install failed (exit code $($proc.ExitCode)). Install it manually from https://aka.ms/vs/17/release/vc_redist.x64.exe and re-run this script."
    }
    Log "VC++ redistributable installed"
}

function Stop-ApacheIfRunning {
    Log "Stopping Apache (httpd.exe) if running, so PHP files aren't locked"
    $serviceName = "Apache2.4"
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Log "Stopping Apache Windows service ($serviceName)"
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }

    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Test-ApacheConfig($httpdExe, $confPath) {
    Log "Testing Apache configuration syntax (httpd.exe -t)"
    $errFile = Join-Path $env:TEMP "httpd_test_err_$PID.txt"
    $proc = Start-Process -FilePath $httpdExe -ArgumentList @("-t", "-f", $confPath) `
        -NoNewWindow -PassThru -Wait -RedirectStandardError $errFile
    $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        Log "Apache config test FAILED: $errText"
        return $false
    }

    Log "Apache config test OK"
    return $true
}

function Start-Apache($xamppPath) {
    $httpdExe = Join-Path $xamppPath "apache\bin\httpd.exe"
    $apacheErrorLog = Join-Path $xamppPath "apache\logs\error.log"
    $serviceName = "Apache2.4"
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($svc) {
        Log "Starting Apache Windows service ($serviceName)"
        Start-Service -Name $serviceName
        Start-Sleep -Seconds 2
        $svc.Refresh()
        if ($svc.Status -ne 'Running') {
            $recentLog = ''
            if (Test-Path $apacheErrorLog) {
                $recentLog = (Get-Content $apacheErrorLog -Tail 20 -ErrorAction SilentlyContinue) -join "`r`n"
            }
            throw "Apache service did not reach the Running state. $recentLog"
        }
        return $true
    }

    # This script normally runs elevated (admin), so a directly-launched httpd.exe here
    # inherits an admin token. XAMPP Control Panel is usually run as a normal user, which
    # can enumerate but not open/stop a handle to that elevated process ("Access is
    # denied"), so it can neither reflect nor control it: Stop silently fails and Start
    # launches a second, non-elevated httpd.exe that immediately dies on the port conflict,
    # making Apache look permanently "off" until a reboot clears the orphan. To avoid that,
    # only use this path to verify the config actually works, then stop it again and let
    # the user's own (non-elevated) Control Panel be the one to start Apache for real.
    Log "No Apache service found; starting httpd.exe directly to verify the new config works"
    $proc = Start-Process -FilePath $httpdExe -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if ($proc.HasExited) {
        $recentLog = ''
        if (Test-Path $apacheErrorLog) {
            $recentLog = (Get-Content $apacheErrorLog -Tail 20 -ErrorAction SilentlyContinue) -join "`r`n"
        }
        throw "Apache process exited immediately after start. $recentLog"
    }

    Log "Apache started successfully under this elevated process; stopping it now so XAMPP Control Panel (run as your normal user) can start it cleanly without an elevation mismatch"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    return $false
}

function Invoke-PhpCli {
    param(
        [Parameter(Mandatory=$true)][string]$PhpExe,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    $outFile = Join-Path $env:TEMP "php_cli_out_$PID.txt"
    $errFile = Join-Path $env:TEMP "php_cli_err_$PID.txt"

    $proc = Start-Process -FilePath $PhpExe -ArgumentList $Arguments `
        -NoNewWindow -PassThru -Wait -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-PhpVersionSummary {
    param([Parameter(Mandatory=$true)][string]$PhpExe)

    if (-not (Test-Path $PhpExe)) {
        return $null
    }

    $result = Invoke-PhpCli -PhpExe $PhpExe -Arguments @("-v")
    $line = (($result.StdOut + $result.StdErr) -split "`r?`n") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    if ($line) {
        return $line.Trim()
    }

    return "php -v returned exit code $($result.ExitCode)"
}

function Get-PhpLoadedModules {
    param([Parameter(Mandatory=$true)][string]$PhpExe)

    if (-not (Test-Path $PhpExe)) {
        return @()
    }

    $result = Invoke-PhpCli -PhpExe $PhpExe -Arguments @("-m")
    if ($result.ExitCode -ne 0) {
        return @()
    }

    $modules = @()
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^\[') { continue }
        $modules += $trimmed
    }

    $modules | Sort-Object -Unique
}

function Get-PhpIniDirectives {
    param(
        [Parameter(Mandatory=$true)][string]$IniPath
    )

    if (-not (Test-Path $IniPath)) {
        return @()
    }

    $entries = @()
    foreach ($line in (Get-Content -Path $IniPath -ErrorAction SilentlyContinue)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(';')) { continue }
        if ($trimmed -match '^(zend_extension|extension)\s*=\s*(.+?)\s*$') {
            $entries += [pscustomobject]@{
                Type  = $Matches[1].ToLowerInvariant()
                Value = $Matches[2].Trim()
            }
        }
    }

    $entries
}

function Set-IniDirective {
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $pattern = "(?im)^\s*(?!;)\s*" + [regex]::Escape($Key) + "\s*=.*$"
    $replacement = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "$Key = $Value" }
    $rx = [regex]::new($pattern)

    if ($rx.IsMatch($Content)) {
        # NOTE: [regex]::Replace(input, pattern, MatchEvaluator, 1) resolves to the
        # (string, string, MatchEvaluator, RegexOptions) overload, silently turning "1"
        # into RegexOptions.IgnoreCase and doing a global replace instead of one match.
        # Using an explicit Regex instance's .Replace(input, evaluator, count) avoids that.
        return $rx.Replace($Content, $replacement, 1)
    }

    return $Content.TrimEnd("`r", "`n") + "`r`n$Key = $Value`r`n"
}

function Enable-RequiredExtensions {
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)][string[]]$Extensions
    )

    # extension_dir must be uncommented and pointed at the new php\ext folder,
    # otherwise every extension= line below silently fails to load.
    $Content = Set-IniDirective -Content $Content -Key 'extension_dir' -Value '"ext"'

    $enabled = @()
    foreach ($ext in $Extensions) {
        $activePattern = "(?im)^\s*extension\s*=\s*(php_)?" + [regex]::Escape($ext) + "(\.dll)?\s*$"
        if ($Content -match $activePattern) {
            continue
        }

        # No whitespace allowed between ";" and "extension": php.ini-production's header
        # comment also contains indented example lines like ";   extension=mysqli" that
        # must NOT be matched here, only the real (unindented) commented directive.
        $commentedPattern = "(?im)^;extension\s*=\s*(php_)?" + [regex]::Escape($ext) + "(\.dll)?\s*$"
        $rx = [regex]::new($commentedPattern)
        if ($rx.IsMatch($Content)) {
            $Content = $rx.Replace($Content, "extension=$ext", 1)
        }
        else {
            $Content = $Content.TrimEnd("`r", "`n") + "`r`nextension=$ext`r`n"
        }

        $enabled += $ext
    }

    [pscustomobject]@{
        Content = $Content
        Enabled = $enabled
    }
}

function Add-DirectoryToMachinePath {
    param([Parameter(Mandatory=$true)][string]$Directory)

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ([string]::IsNullOrWhiteSpace($machinePath)) {
        $machinePath = ''
    }

    $entries = @($machinePath -split ';' | Where-Object { $_ -and $_.Trim() })
    $alreadyPresent = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $Directory.TrimEnd('\')) {
            $alreadyPresent = $true
            break
        }
    }

    if ($alreadyPresent) {
        Log "System PATH already includes $Directory"
        return $false
    }

    $updatedPath = if ([string]::IsNullOrWhiteSpace($machinePath)) {
        $Directory
    }
    else {
        $machinePath.TrimEnd(';') + ';' + $Directory
    }

    [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'Machine')
    Log "Added $Directory to the machine PATH"
    return $true
}

function Update-ApachePhpIntegration {
    param(
        [Parameter(Mandatory=$true)][string]$ConfPath,
        [Parameter(Mandatory=$true)][string]$PhpDir
    )

    $currentConf = Get-Content -Path $ConfPath -Raw
    $normalizedPhpDir = ($PhpDir -replace '\\', '/').TrimEnd('/')

    $newConf = $currentConf
    $newConf = [regex]::Replace(
        $newConf,
        '(?m)^\s*LoadFile\s+".*?/php(?:\d+)?ts\.dll"\s*$',
        "LoadFile `"$normalizedPhpDir/php8ts.dll`""
    )
    # Matches LoadModule regardless of which module name (php_module / php7_module) or
    # which php*apache2_4.dll filename is currently present, so it still fixes the line
    # correctly even if something upstream (e.g. Repair-ApachePhpReferences) already
    # rewrote just the filename half, leaving a mismatched module-name/filename pair.
    $newConf = [regex]::Replace(
        $newConf,
        '(?m)^\s*LoadModule\s+php7?_module\s+".*?/php(?:\d+)?apache2_4\.dll"\s*$',
        "LoadModule php_module `"$normalizedPhpDir/php8apache2_4.dll`""
    )
    $newConf = [regex]::Replace(
        $newConf,
        '(?m)^\s*PHPIniDir\s+".*?"\s*$',
        "PHPIniDir `"$normalizedPhpDir`""
    )

    if ($newConf -notmatch '(?m)^\s*LoadFile\s+".*?/php8ts\.dll"\s*$') {
        $newConf = $newConf.TrimEnd("`r", "`n") + "`r`nLoadFile `"$normalizedPhpDir/php8ts.dll`"`r`n"
    }
    if ($newConf -notmatch '(?m)^\s*LoadModule\s+php_module\s+".*?/php8apache2_4\.dll"\s*$') {
        $newConf = $newConf.TrimEnd("`r", "`n") + "`r`nLoadModule php_module `"$normalizedPhpDir/php8apache2_4.dll`"`r`n"
    }
    $newConf = [regex]::Replace(
        $newConf,
        '(?m)^\s*<IfModule\s+php7_module>\s*$',
        '<IfModule php_module>'
    )
    if ($newConf -notmatch '(?m)^\s*PHPIniDir\s+".*?"\s*$') {
        $newConf = $newConf.TrimEnd("`r", "`n") + "`r`nPHPIniDir `"$normalizedPhpDir`"`r`n"
    }

    if ($newConf -ne $currentConf) {
        Write-TextFileNoBom -Path $ConfPath -Content $newConf
        return $true
    }

    return $false
}

function Enable-VhostsInclude {
    param([Parameter(Mandatory=$true)][string]$MainConfPath)

    $content = Get-Content -Path $MainConfPath -Raw

    $activePattern = '(?im)^\s*Include\s+"?conf/extra/httpd-vhosts\.conf"?\s*$'
    if ($content -match $activePattern) {
        return $false
    }

    $commentedPattern = '(?im)^\s*#\s*Include\s+"?conf/extra/httpd-vhosts\.conf"?\s*$'
    $rx = [regex]::new($commentedPattern)
    if ($rx.IsMatch($content)) {
        $newContent = $rx.Replace($content, 'Include conf/extra/httpd-vhosts.conf', 1)
    }
    else {
        $newContent = $content.TrimEnd("`r", "`n") + "`r`nInclude conf/extra/httpd-vhosts.conf`r`n"
    }

    Write-TextFileNoBom -Path $MainConfPath -Content $newContent
    return $true
}

function Set-DefaultLocalhostVirtualHost {
    param(
        [Parameter(Mandatory=$true)][string]$VhostsConfPath,
        [Parameter(Mandatory=$true)][string]$XamppPath
    )

    # Apache 2.4 treats the first <VirtualHost> block on an IP:Port as the fallback for
    # any request whose Host header doesn't match a later ServerName. Once we add an
    # app-specific VirtualHost, http://localhost (the XAMPP dashboard) would otherwise
    # stop resolving unless a matching default VirtualHost exists too, so add one once.
    $beginMarker = "# BEGIN default-localhost (managed by update-xampp-php.ps1)"
    $endMarker   = "# END default-localhost"

    $currentConf = ''
    if (Test-Path $VhostsConfPath) {
        $currentConf = Get-Content -Path $VhostsConfPath -Raw
    }

    if ($currentConf -match [regex]::Escape($beginMarker)) {
        return $false
    }

    $forwardHtdocs = ($XamppPath.TrimEnd('\') + '\htdocs') -replace '\\', '/'
    $block = @"
$beginMarker
<VirtualHost *:80>
    DocumentRoot "$forwardHtdocs"
    ServerName localhost
</VirtualHost>
$endMarker
"@

    $newConf = $currentConf.TrimEnd("`r", "`n") + "`r`n`r`n" + $block.TrimEnd() + "`r`n"
    Write-TextFileNoBom -Path $VhostsConfPath -Content $newConf
    return $true
}

function Set-AppVirtualHost {
    param(
        [Parameter(Mandatory=$true)][string]$VhostsConfPath,
        [Parameter(Mandatory=$true)][string]$AppName,
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$DocRoot,
        [string]$SslCrtPath,
        [string]$SslKeyPath
    )

    $forwardDocRoot = $DocRoot -replace '\\', '/'
    $beginMarker = "# BEGIN $AppName (managed by update-xampp-php.ps1)"
    $endMarker   = "# END $AppName"

    $httpsSection = ""
    if ($SslCrtPath -and $SslKeyPath) {
        $forwardCrt = $SslCrtPath -replace '\\', '/'
        $forwardKey = $SslKeyPath -replace '\\', '/'
        $httpsSection = @"


<VirtualHost *:443>
    ServerName $HostName
    DocumentRoot "$forwardDocRoot"

    SSLEngine on
    SSLCertificateFile "$forwardCrt"
    SSLCertificateKeyFile "$forwardKey"

    <Directory "$forwardDocRoot">
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
"@
    }

    $block = @"
$beginMarker
<VirtualHost *:80>
    ServerName $HostName
    DocumentRoot "$forwardDocRoot"

    <Directory "$forwardDocRoot">
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>$httpsSection
$endMarker
"@

    $currentConf = ''
    if (Test-Path $VhostsConfPath) {
        $currentConf = Get-Content -Path $VhostsConfPath -Raw
    }

    if ($currentConf -match [regex]::Escape($beginMarker)) {
        $pattern = "(?s)" + [regex]::Escape($beginMarker) + ".*?" + [regex]::Escape($endMarker)
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block.TrimEnd() }
        $newConf = [regex]::Replace($currentConf, $pattern, $evaluator)
    }
    else {
        $newConf = $currentConf.TrimEnd("`r", "`n") + "`r`n`r`n" + $block.TrimEnd() + "`r`n"
    }

    Write-TextFileNoBom -Path $VhostsConfPath -Content $newConf
}

function Add-HostsFileEntry {
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$BackupDir,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $content = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }

    $pattern = "(?im)^[ \t]*127\.0\.0\.1[ \t]+" + [regex]::Escape($HostName) + "[ \t]*$"
    if ($content -match $pattern) {
        return $false
    }

    $backupPath = Join-Path $BackupDir "hosts_backup_$Timestamp.txt"
    Copy-Item -Path $hostsPath -Destination $backupPath -Force -ErrorAction SilentlyContinue

    $newContent = $content.TrimEnd("`r", "`n") + "`r`n127.0.0.1`t$HostName`r`n"
    Write-TextFileNoBom -Path $hostsPath -Content $newContent
    return $true
}

function Repair-ApachePhpReferences {
    param(
        [Parameter(Mandatory=$true)][string]$ApacheConfRoot,
        [Parameter(Mandatory=$true)][string]$PhpDir
    )

    $normalizedPhpDir = ($PhpDir -replace '\\', '/').TrimEnd('/')
    $confFiles = Get-ChildItem -Path $ApacheConfRoot -Filter '*.conf' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\backup\\' }
    $changedFiles = @()

    foreach ($file in $confFiles) {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { continue }

        $newContent = $content
        $newContent = [regex]::Replace($newContent, '(?i)php7ts\.dll', 'php8ts.dll')
        $newContent = [regex]::Replace($newContent, '(?i)php7apache2_4\.dll', 'php8apache2_4.dll')
        $newContent = [regex]::Replace($newContent, '(?im)^\s*PHPIniDir\s+".*?"\s*$', "PHPIniDir `"$normalizedPhpDir`"")

        if ($newContent -ne $content) {
            Write-TextFileNoBom -Path $file.FullName -Content $newContent
            $changedFiles += $file.FullName
        }
    }

    return $changedFiles
}

function Repair-SharedApacheCurlDlls {
    param(
        [Parameter(Mandatory=$true)][string]$PhpDir,
        [Parameter(Mandatory=$true)][string]$ApacheBinDir,
        [Parameter(Mandatory=$true)][string]$BackupDir,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )

    # php_curl.dll (loaded in-process by httpd.exe) depends on libssh2/nghttp2/libsasl,
    # plus libssl-3-x64/libcrypto-3-x64 (OpenSSL 3.x). XAMPP's apache\bin also ships its
    # own older copies of these same DLL names, and Windows' default search order checks
    # the exe's own directory (apache\bin) before PATH, so the stale Apache copy silently
    # wins and crashes PHP's curl extension the moment curl (or anything using OpenSSL) is
    # used - e.g. "The procedure entry point SSL_get0_group_name could not be located",
    # since that function was only added in OpenSSL 3.2 and the older Apache-bundled
    # libssl-3-x64.dll doesn't export it. Overwrite them with the versions bundled with
    # the new PHP so both processes load the same, current build.
    $sharedDlls = @('libssh2.dll', 'nghttp2.dll', 'libsasl.dll', 'libssl-3-x64.dll', 'libcrypto-3-x64.dll')
    $replaced = @()

    foreach ($dllName in $sharedDlls) {
        $phpDllPath = Join-Path $PhpDir $dllName
        $apacheDllPath = Join-Path $ApacheBinDir $dllName

        if (-not (Test-Path $phpDllPath) -or -not (Test-Path $apacheDllPath)) {
            continue
        }

        $phpHash = (Get-FileHash -Path $phpDllPath -Algorithm SHA256).Hash
        $apacheHash = (Get-FileHash -Path $apacheDllPath -Algorithm SHA256).Hash
        if ($phpHash -eq $apacheHash) {
            continue
        }

        $backupPath = Join-Path $BackupDir "${dllName}_apache_backup_$Timestamp.dll"
        Copy-Item -Path $apacheDllPath -Destination $backupPath -Force
        Copy-Item -Path $phpDllPath -Destination $apacheDllPath -Force
        $replaced += $dllName
    }

    return $replaced
}

function Repair-WeakSslCertificate {
    param(
        [Parameter(Mandatory=$true)][string]$ApacheDir,
        [Parameter(Mandatory=$true)][string]$BackupDir,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )

    # Replacing apache\bin's libssl-3-x64.dll/libcrypto-3-x64.dll with the newer OpenSSL
    # build PHP ships (see Repair-SharedApacheCurlDlls) raises mod_ssl's effective default
    # security level, since it loads the same DLL files. XAMPP's stock self-signed dummy
    # certificate (server.crt) uses a weak (typically 1024-bit) RSA key that the newer
    # OpenSSL's default @SECLEVEL rejects outright ("ee key too small" / error:0A00018F) -
    # and unlike the curl warning, this is fatal: Apache refuses to start at all
    # (AH00016: Configuration Failed). Regenerate it with a 2048-bit key so Apache still
    # starts once the shared OpenSSL DLLs move to the newer build.
    $opensslExe = Join-Path $ApacheDir "bin\openssl.exe"
    $crtPath = Join-Path $ApacheDir "conf\ssl.crt\server.crt"
    $keyPath = Join-Path $ApacheDir "conf\ssl.key\server.key"
    $cnfPath = Join-Path $ApacheDir "conf\openssl.cnf"

    if (-not (Test-Path $opensslExe)) {
        Log "WARNING: apache\bin\openssl.exe not found; cannot check the SSL certificate's key strength"
        return $false
    }
    if (-not (Test-Path $crtPath) -or -not (Test-Path $keyPath)) {
        return $false
    }

    $textResult = Invoke-PhpCli -PhpExe $opensslExe -Arguments @("x509", "-in", $crtPath, "-noout", "-text")
    if ($textResult.StdOut -notmatch 'Public-Key:\s*\((\d+)\s*bit\)') {
        Log "WARNING: Could not determine the SSL certificate's key size; skipping regeneration check"
        return $false
    }

    $keyBits = [int]$Matches[1]
    if ($keyBits -ge 2048) {
        return $false
    }

    Log "Existing SSL certificate uses a $keyBits-bit key, which the newer OpenSSL build will reject; regenerating"

    $crtBackup = Join-Path $BackupDir "server.crt_backup_$Timestamp.crt"
    $keyBackup = Join-Path $BackupDir "server.key_backup_$Timestamp.key"
    Copy-Item -Path $crtPath -Destination $crtBackup -Force
    Copy-Item -Path $keyPath -Destination $keyBackup -Force

    $reqArgs = @(
        "req", "-x509", "-nodes", "-newkey", "rsa:2048",
        "-keyout", $keyPath, "-out", $crtPath,
        "-days", "3650", "-subj", "/CN=localhost"
    )
    if (Test-Path $cnfPath) {
        $reqArgs += @("-config", $cnfPath)
    }

    $reqResult = Invoke-PhpCli -PhpExe $opensslExe -Arguments $reqArgs
    if ($reqResult.ExitCode -ne 0) {
        Copy-Item -Path $crtBackup -Destination $crtPath -Force
        Copy-Item -Path $keyBackup -Destination $keyPath -Force
        throw "Failed to regenerate the weak self-signed SSL certificate: $($reqResult.StdErr)"
    }

    return $true
}

function New-AppSslCertificate {
    param(
        [Parameter(Mandatory=$true)][string]$ApacheDir,
        [Parameter(Mandatory=$true)][string]$AppName,
        [Parameter(Mandatory=$true)][string]$HostName
    )

    # A dedicated cert per app, not XAMPP's shared ssl.crt/server.crt (which stays
    # CN=localhost for the XAMPP dashboard's own https://localhost vhost), so its
    # Subject Alternative Name actually matches $HostName - modern browsers reject
    # CN-only certs outright. Note that HTTPS alone (even with a cert the browser
    # doesn't trust) already satisfies window.isSecureContext, which is what actually
    # unblocks camera/microphone access; a properly matching, trusted cert (see
    # Install-TrustedCertificate) only removes the "Not Secure" interstitial on top of
    # that.
    $opensslExe = Join-Path $ApacheDir "bin\openssl.exe"
    $crtPath = Join-Path $ApacheDir "conf\ssl.crt\$AppName.crt"
    $keyPath = Join-Path $ApacheDir "conf\ssl.key\$AppName.key"
    $cnfPath = Join-Path $ApacheDir "conf\openssl.cnf"

    if (-not (Test-Path $opensslExe)) {
        Log "WARNING: apache\bin\openssl.exe not found; cannot generate an SSL certificate for $HostName"
        return $null
    }

    if ((Test-Path $crtPath) -and (Test-Path $keyPath)) {
        $textResult = Invoke-PhpCli -PhpExe $opensslExe -Arguments @("x509", "-in", $crtPath, "-noout", "-text")
        if ($textResult.StdOut -match [regex]::Escape("DNS:$HostName")) {
            return [pscustomobject]@{ CrtPath = $crtPath; KeyPath = $keyPath; Generated = $false }
        }
        Log "Existing certificate for '$AppName' doesn't cover $HostName; regenerating"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $crtPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $keyPath) | Out-Null

    $reqArgs = @(
        "req", "-x509", "-nodes", "-newkey", "rsa:2048",
        "-keyout", $keyPath, "-out", $crtPath,
        "-days", "3650", "-subj", "/CN=$HostName",
        "-addext", "subjectAltName=DNS:$HostName"
    )
    if (Test-Path $cnfPath) {
        $reqArgs += @("-config", $cnfPath)
    }

    $reqResult = Invoke-PhpCli -PhpExe $opensslExe -Arguments $reqArgs
    if ($reqResult.ExitCode -ne 0) {
        Log "WARNING: Could not generate an SSL certificate for $HostName - $($reqResult.StdErr)"
        return $null
    }

    return [pscustomobject]@{ CrtPath = $crtPath; KeyPath = $keyPath; Generated = $true }
}

function Enable-SslModule {
    param([Parameter(Mandatory=$true)][string]$MainConfPath)

    $content = Get-Content -Path $MainConfPath -Raw
    $changed = $false

    $activeModulePattern = '(?im)^\s*LoadModule\s+ssl_module\s+modules/mod_ssl\.so\s*$'
    if ($content -notmatch $activeModulePattern) {
        $commentedModulePattern = '(?im)^\s*#\s*LoadModule\s+ssl_module\s+modules/mod_ssl\.so\s*$'
        $rx = [regex]::new($commentedModulePattern)
        if ($rx.IsMatch($content)) {
            $content = $rx.Replace($content, 'LoadModule ssl_module modules/mod_ssl.so', 1)
        }
        else {
            $content = $content.TrimEnd("`r", "`n") + "`r`nLoadModule ssl_module modules/mod_ssl.so`r`n"
        }
        $changed = $true
    }

    $activeIncludePattern = '(?im)^\s*Include\s+"?conf/extra/httpd-ssl\.conf"?\s*$'
    if ($content -notmatch $activeIncludePattern) {
        $commentedIncludePattern = '(?im)^\s*#\s*Include\s+"?conf/extra/httpd-ssl\.conf"?\s*$'
        $rx = [regex]::new($commentedIncludePattern)
        if ($rx.IsMatch($content)) {
            $content = $rx.Replace($content, 'Include conf/extra/httpd-ssl.conf', 1)
        }
        else {
            $content = $content.TrimEnd("`r", "`n") + "`r`nInclude conf/extra/httpd-ssl.conf`r`n"
        }
        $changed = $true
    }

    if ($changed) {
        Write-TextFileNoBom -Path $MainConfPath -Content $content
    }

    return $changed
}

function Install-TrustedCertificate {
    param([Parameter(Mandatory=$true)][string]$CrtPath)

    # certutil.exe ships with Windows itself, so this needs no XAMPP/openssl dependency.
    # Purely cosmetic (see the note in New-AppSslCertificate) - only removes the "Not
    # Secure" browser warning, doesn't affect whether HTTPS/camera access works.
    $result = Invoke-PhpCli -PhpExe "certutil.exe" -Arguments @("-addstore", "-f", "ROOT", $CrtPath)
    if ($result.ExitCode -ne 0) {
        Log "WARNING: Could not add the certificate to Windows' trusted root store: $($result.StdErr)"
        return $false
    }

    return $true
}

function Clear-DirectoryContents {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Directory not found: $Path"
    }

    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Broadcast-EnvironmentChange {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int Msg, UIntPtr wParam, string lParam, int fuFlags, int uTimeout, out UIntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue

    $result = [UIntPtr]::Zero
    [void][NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
}

function ConvertFrom-PhpIniSize {
    param([Parameter(Mandatory=$true)][string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed -eq '' -or $trimmed -eq '-1') { return -1 } # -1 = unlimited

    if ($trimmed -match '^(\d+)\s*([KMG])$') {
        $num = [int64]$Matches[1]
        switch ($Matches[2].ToUpperInvariant()) {
            'K' { return $num * 1KB }
            'M' { return $num * 1MB }
            'G' { return $num * 1GB }
        }
    }

    if ($trimmed -match '^\d+$') { return [int64]$trimmed }

    return 0
}

function Set-MinimumIniDirective {
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$MinimumValue,
        [Parameter(Mandatory=$true)][ValidateSet('size', 'count')][string]$Kind,
        [Parameter(Mandatory=$true)]$Result
    )

    $pattern = "(?im)^\s*(?!;)\s*" + [regex]::Escape($Key) + "\s*=\s*(.+?)\s*$"
    $currentRaw = if ($Content -match $pattern) { $Matches[1].Trim() } else { $null }

    if ($Kind -eq 'size') {
        # -1 already means unlimited; never downgrade that.
        $currentBytes = if ($currentRaw) { ConvertFrom-PhpIniSize -Value $currentRaw } else { 0 }
        if ($currentBytes -eq -1 -or $currentBytes -ge (ConvertFrom-PhpIniSize -Value $MinimumValue)) {
            return $Content
        }
    }
    else {
        # For time/count settings 0 means unlimited in PHP - never downgrade
        # that, and treat our own "0" targets (e.g. max_execution_time) as
        # always worth forcing, since nothing current can already exceed it.
        if ($currentRaw -eq '0' -and $MinimumValue -ne '0') {
            return $Content
        }
        if ($MinimumValue -ne '0') {
            $currentNum = if ($currentRaw -match '^\d+$') { [int64]$currentRaw } else { 0 }
            if ($currentNum -ge [int64]$MinimumValue) {
                return $Content
            }
        }
        elseif ($currentRaw -eq '0') {
            return $Content
        }
    }

    $Result.BaselineDefaultsRaised += "$Key = $MinimumValue (was: $(if ($currentRaw) { $currentRaw } else { 'default' }))"

    return Set-IniDirective -Content $Content -Key $Key -Value $MinimumValue
}

function Set-RpsRecommendedPhpDefaults {
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)]$Result
    )

    # Mirrors RPS's own System Health thresholds (app/Services/SystemHealthService.php)
    # plus headroom for large legacy-data imports and slow-hardware backup
    # restores - a stock php.ini-production's defaults (30s execution time,
    # 2M uploads, 128M memory) are well below what RPS needs in practice.
    $Content = Set-MinimumIniDirective -Content $Content -Key 'memory_limit' -MinimumValue '256M' -Kind 'size' -Result $Result
    $Content = Set-MinimumIniDirective -Content $Content -Key 'upload_max_filesize' -MinimumValue '20M' -Kind 'size' -Result $Result
    $Content = Set-MinimumIniDirective -Content $Content -Key 'post_max_size' -MinimumValue '20M' -Kind 'size' -Result $Result
    $Content = Set-MinimumIniDirective -Content $Content -Key 'max_execution_time' -MinimumValue '0' -Kind 'count' -Result $Result
    $Content = Set-MinimumIniDirective -Content $Content -Key 'max_input_time' -MinimumValue '300' -Kind 'count' -Result $Result
    $Content = Set-MinimumIniDirective -Content $Content -Key 'max_input_vars' -MinimumValue '3000' -Kind 'count' -Result $Result

    return $Content
}

function Update-PhpIniForMigration {
    param(
        [Parameter(Mandatory=$true)][string]$OldIniPath,
        [Parameter(Mandatory=$true)][string]$NewIniPath,
        [Parameter(Mandatory=$true)][string]$BackupDir,
        [Parameter(Mandatory=$true)][string]$Timestamp,
        [string]$LegacyIniBackupPath
    )

    $result = [ordered]@{
        OldIniBackedUp = $false
        ScalarSettings = @()
        ExtensionWarnings = @()
        RequiredExtensionsEnabled = @()
        BaselineDefaultsRaised = @()
    }

    $laravelExtensions = @(
        'curl', 'fileinfo', 'gd', 'intl', 'mbstring',
        'mysqli', 'openssl', 'pdo_mysql', 'sodium', 'zip'
    )

    if (-not (Test-Path $NewIniPath)) {
        return [pscustomobject]$result
    }

    $newIniContent = Get-Content -Path $NewIniPath -Raw -ErrorAction SilentlyContinue

    if ($LegacyIniBackupPath) {
        $result.OldIniBackedUp = Test-Path $LegacyIniBackupPath
        $OldIniPath = $LegacyIniBackupPath
    }
    elseif (Test-Path $OldIniPath) {
        $iniBackupPath = Join-Path $BackupDir "php.ini_backup_$Timestamp.ini"
        Copy-Item -Path $OldIniPath -Destination $iniBackupPath -Force
        $result.OldIniBackedUp = $true
        $OldIniPath = $iniBackupPath
    }

    if (Test-Path $OldIniPath) {
        $newIniContent = Merge-LegacyScalarSettings -OldIniPath $OldIniPath -NewIniContent $newIniContent -Result $result
    }

    $extResult = Enable-RequiredExtensions -Content $newIniContent -Extensions $laravelExtensions
    $newIniContent = $extResult.Content
    $result.RequiredExtensionsEnabled = $extResult.Enabled

    $newIniContent = Set-RpsRecommendedPhpDefaults -Content $newIniContent -Result $result

    Write-TextFileNoBom -Path $NewIniPath -Content $newIniContent

    return [pscustomobject]$result
}

function Merge-LegacyScalarSettings {
    param(
        [Parameter(Mandatory=$true)][string]$OldIniPath,
        [Parameter(Mandatory=$true)][string]$NewIniContent,
        [Parameter(Mandatory=$true)]$Result
    )

    $oldIniContent = Get-Content -Path $OldIniPath -Raw -ErrorAction SilentlyContinue
    $newIniContent = $NewIniContent

    $safeScalarKeys = @(
        'date.timezone',
        'memory_limit',
        'upload_max_filesize',
        'post_max_size',
        'max_execution_time',
        'max_input_time',
        'max_input_vars',
        'display_errors',
        'error_reporting',
        'log_errors',
        'error_log',
        'default_charset',
        'cgi.force_redirect',
        'file_uploads',
        'upload_tmp_dir',
        'sendmail_path',
        'smtp_port',
        'extension_dir',
        'openssl.cafile',
        'curl.cainfo'
    )

    foreach ($key in $safeScalarKeys) {
        $pattern = "(?im)^\s*(?!;)\s*" + [regex]::Escape($key) + "\s*=\s*(.+?)\s*$"
        if ($oldIniContent -match $pattern) {
            $value = $Matches[1].Trim()
            $newIniContent = Set-IniDirective -Content $newIniContent -Key $key -Value $value
            $result.ScalarSettings += "$key=$value"
        }
    }

    $enabledExtensions = Get-PhpIniDirectives -IniPath $OldIniPath
    foreach ($entry in $enabledExtensions) {
        if ($entry.Value) {
            $result.ExtensionWarnings += "$($entry.Type) = $($entry.Value) (not carried forward; verify against the new PHP 8.5 ext folder)"
        }
    }

    return $newIniContent
}

$script:Interactive = -not $PSBoundParameters.ContainsKey('XamppPath')

if ($script:Interactive) {
    Write-Host ""
    Write-Host "=== XAMP PHP Updater ===" -ForegroundColor Cyan
    Write-Host "This backs up and replaces the PHP version in your XAMPP install, then" -ForegroundColor Cyan
    Write-Host "configures Apache for your app. Press Ctrl+C at any point to abort." -ForegroundColor Cyan
    Write-Host ""

    $detected = Get-DefaultXamppPath
    $xamppDefault = if ($detected) { $detected } else { 'C:\xampp' }
    $XamppPath = Read-PromptWithDefault -Prompt "XAMPP folder" -Default $xamppDefault
    while (-not ((Test-Path (Join-Path $XamppPath 'php')) -and (Test-Path (Join-Path $XamppPath 'mysql')))) {
        Write-Host "That folder doesn't look like a XAMPP install (missing php\ or mysql\ subfolder)." -ForegroundColor Red
        $XamppPath = Read-PromptWithDefault -Prompt "XAMPP folder" -Default $XamppPath
    }

    if (-not $PSBoundParameters.ContainsKey('PhpZipPath')) {
        $zipCandidates = @(Get-ChildItem -Path $script:ScriptDir -Filter 'php-*.zip' -File -ErrorAction SilentlyContinue)
        $zipDefault = if ($zipCandidates.Count -gt 0) { $zipCandidates[0].FullName } else { '' }
        $PhpZipPath = Read-PromptWithDefault -Prompt "PHP zip to install" -Default $zipDefault
    }
    while (-not (Test-Path $PhpZipPath)) {
        Write-Host "That zip file doesn't exist." -ForegroundColor Red
        $PhpZipPath = Read-PromptWithDefault -Prompt "PHP zip to install" -Default $PhpZipPath
    }

    if (-not $PSBoundParameters.ContainsKey('BackupMySql')) {
        $ans = Read-PromptWithDefault -Prompt "Back up the MySQL folder before updating? (y/n)" -Default 'y'
        if ($ans -match '^(y|yes)$') {
            Write-Host "Stop the MySQL service from the XAMPP control panel before continuing." -ForegroundColor Yellow
            Read-Host "Press Enter once MySQL is stopped (or Ctrl+C to abort)" | Out-Null
            $BackupMySql = $true
        }
    }

    if (-not $PSBoundParameters.ContainsKey('AppName')) {
        $AppName = Read-PromptWithDefault -Prompt "App name (folder / hostname, e.g. 'rps')" -Default 'rps'
    }
    if (-not $PSBoundParameters.ContainsKey('DocRootSubfolder')) {
        $DocRootSubfolder = Read-PromptWithDefault -Prompt "Document root subfolder" -Default 'public'
    }
    if (-not $PSBoundParameters.ContainsKey('SourcePath')) {
        $SourcePath = Read-PromptWithDefault -Prompt "App source .zip to deploy (optional, leave blank to skip)" -Default ''
    }
    while ($SourcePath -and -not (Test-Path $SourcePath)) {
        Write-Host "That zip file doesn't exist." -ForegroundColor Red
        $SourcePath = Read-PromptWithDefault -Prompt "App source .zip to deploy (optional, leave blank to skip)" -Default ''
    }

    Write-Host ""
    Write-Host "Ready to update PHP in '$XamppPath' and configure app '$AppName'." -ForegroundColor Cyan
    Read-Host "Press Enter to continue (or Ctrl+C to abort)" | Out-Null
}

if (-not $XamppPath)  { throw "XamppPath is required." }
if (-not $PhpZipPath) { throw "PhpZipPath is required." }
if (-not $AppName)    { throw "AppName is required." }

try {
    $XamppPath = $XamppPath.TrimEnd('\')
    $phpDir   = Join-Path $XamppPath "php"
    $mysqlDir = Join-Path $XamppPath "mysql"
    $htdocsDir     = Join-Path $XamppPath "htdocs"
    $apacheConfDir = Join-Path $XamppPath "apache\conf"
    $xamppConfPath = Join-Path $apacheConfDir "extra\httpd-xampp.conf"
    $mainConfPath  = Join-Path $apacheConfDir "httpd.conf"
    $httpdExe      = Join-Path $XamppPath "apache\bin\httpd.exe"

    if (-not (Test-Path $phpDir))        { throw "PHP folder not found: $phpDir" }
    if (-not (Test-Path $mysqlDir))      { throw "MySQL folder not found: $mysqlDir" }
    if (-not (Test-Path $PhpZipPath))    { throw "PHP zip not found: $PhpZipPath" }
    if (-not (Test-Path $htdocsDir))     { throw "htdocs folder not found: $htdocsDir" }
    if (-not (Test-Path $xamppConfPath)) { throw "httpd-xampp.conf not found: $xamppConfPath" }
    if (-not (Test-Path $httpdExe))      { throw "httpd.exe not found: $httpdExe" }

    Install-VCRedistIfNeeded

    $appDir  = Join-Path $htdocsDir $AppName
    $docRoot = Join-Path $appDir $DocRootSubfolder
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $XamppPath "backup"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $phpUpgradeReportPath = Join-Path $backupDir "php_migration_report_$ts.txt"
    $legacyPhpIniBackupPath = $null
    $prePhpExe = Join-Path $phpDir "php.exe"
    $prePhpIniPath = Join-Path $phpDir "php.ini"
    $postPhpExe = $prePhpExe
    $postPhpIniPath = $prePhpIniPath
    $apachePhpIntegrationUpdated = $false
    $systemPathUpdated = $false
    $prePhpVersion = $null
    $preLoadedModules = @()
    try {
        $prePhpVersion = Get-PhpVersionSummary -PhpExe $prePhpExe
        $preLoadedModules = Get-PhpLoadedModules -PhpExe $prePhpExe
    }
    catch {
        Log "WARNING: Could not capture pre-upgrade PHP snapshot: $($_.Exception.Message)"
    }

    $script:LogFilePath = Join-Path $backupDir 'update-php.log'
    Set-Content -Path $script:LogFilePath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting PHP update + app setup for '$AppName'" -Encoding UTF8

    if (Test-Path $prePhpIniPath) {
        $legacyPhpIniBackupPath = Join-Path $backupDir "php.ini_backup_$ts.ini"
        Copy-Item -Path $prePhpIniPath -Destination $legacyPhpIniBackupPath -Force
        Log "Backed up php.ini -> $legacyPhpIniBackupPath"
    }

    # Taken before Repair-ApachePhpReferences / Update-ApachePhpIntegration touch this file,
    # so it's a true pre-migration snapshot (the later backup at the Alias-block step only
    # guards that specific edit, not the PHP-integration changes made earlier in the run).
    $preMigrationConfBackupPath = Join-Path $backupDir "httpd-xampp_pre-migration_$ts.conf"
    Copy-Item -Path $xamppConfPath -Destination $preMigrationConfBackupPath -Force
    Log "Backed up pre-migration httpd-xampp.conf -> $preMigrationConfBackupPath"

    if ($prePhpVersion) {
        Log "Current PHP version before upgrade: $prePhpVersion"
    }
    if ($preLoadedModules.Count -gt 0) {
        Log "Detected $($preLoadedModules.Count) currently loaded PHP modules before upgrade"
    }

    Stop-ApacheIfRunning

    # ================== PHP UPDATE ==================

    Log "Backing up php -> backup\php_backup_$ts.zip"
    Compress-Archive -Path $phpDir -DestinationPath (Join-Path $backupDir "php_backup_$ts.zip") -Force

    Log "Clearing existing PHP folder contents before applying the new PHP ZIP"
    Clear-DirectoryContents -Path $phpDir

    if ($BackupMySql) {
        if (Get-Process mysqld -ErrorAction SilentlyContinue) {
            throw "MySQL backup is enabled, but mysqld.exe is still running. Stop the MySQL service and try again."
        }

        Log "Backing up mysql -> backup\mysql_backup_$ts.zip"
        Compress-Archive -Path $mysqlDir -DestinationPath (Join-Path $backupDir "mysql_backup_$ts.zip") -Force
    }
    else {
        Log "Skipping MySQL backup by user choice"
    }

    $tempRoot = Get-TempRootPath
    $tempExtract = Join-Path $tempRoot "php_new_$ts"
    Log "Extracting new PHP zip to temp: $tempExtract"
    Expand-Archive -Path $PhpZipPath -DestinationPath $tempExtract -Force

    # If zip contains a single top-level folder (e.g. php-8.5.8-Win32-vs17-x64), use its contents as source root.
    $items = Get-ChildItem -Path $tempExtract
    $sourceRoot = $tempExtract
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        $sourceRoot = $items[0].FullName
    }

    Log "Copying new PHP files into $phpDir after clearing stale files"
    Copy-Item -Path (Join-Path $sourceRoot "*") -Destination $phpDir -Recurse -Force

    Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Log "PHP update complete"

    if (-not (Test-Path $postPhpIniPath)) {
        $iniTemplate = Join-Path $phpDir "php.ini-production"
        if (-not (Test-Path $iniTemplate)) {
            throw "Neither php.ini nor php.ini-production found in the new PHP folder; cannot configure PHP."
        }
        Log "No php.ini shipped in the new PHP zip; creating one from php.ini-production"
        Copy-Item -Path $iniTemplate -Destination $postPhpIniPath -Force
    }

    $migration = Update-PhpIniForMigration `
        -OldIniPath $prePhpIniPath `
        -NewIniPath $postPhpIniPath `
        -BackupDir $backupDir `
        -Timestamp $ts `
        -LegacyIniBackupPath $legacyPhpIniBackupPath

    if ($migration.OldIniBackedUp) {
        Log "php.ini backup preserved for migration review"
    }
    foreach ($entry in $migration.ScalarSettings) {
        Log "Merged php.ini setting: $entry"
    }
    foreach ($warning in $migration.ExtensionWarnings) {
        Log "WARNING: $warning"
    }
    foreach ($ext in $migration.RequiredExtensionsEnabled) {
        Log "Enabled required extension for Laravel: $ext"
    }
    foreach ($entry in $migration.BaselineDefaultsRaised) {
        Log "Raised php.ini default for RPS: $entry"
    }

    $postPhpVersion = $null
    $postLoadedModules = @()
    try {
        $postPhpVersion = Get-PhpVersionSummary -PhpExe $postPhpExe
        $postLoadedModules = Get-PhpLoadedModules -PhpExe $postPhpExe
    }
    catch {
        Log "WARNING: Could not capture post-upgrade PHP snapshot: $($_.Exception.Message)"
    }

    if ($postPhpVersion) {
        Log "PHP version after upgrade: $postPhpVersion"
    }
    if ($postLoadedModules.Count -gt 0) {
        Log "Detected $($postLoadedModules.Count) loaded PHP modules after upgrade"
    }

    $apacheRepairFiles = Repair-ApachePhpReferences -ApacheConfRoot $apacheConfDir -PhpDir $phpDir
    if ($apacheRepairFiles.Count -gt 0) {
        Log "Repaired PHP references in Apache conf files:"
        foreach ($file in $apacheRepairFiles) {
            Log "  $file"
        }
    }
    else {
        Log "No stale PHP 7 references found in Apache conf files"
    }

    $apacheBinDir = Join-Path $XamppPath "apache\bin"
    $replacedSharedDlls = Repair-SharedApacheCurlDlls -PhpDir $phpDir -ApacheBinDir $apacheBinDir -BackupDir $backupDir -Timestamp $ts
    if ($replacedSharedDlls.Count -gt 0) {
        Log "Replaced outdated Apache-bundled DLLs that conflict with php_curl.dll: $($replacedSharedDlls -join ', ')"
    }
    else {
        Log "No conflicting Apache-bundled curl dependency DLLs found"
    }

    # Always check the cert's key size, not just when this run happened to replace the
    # OpenSSL DLLs (Repair-WeakSslCertificate has its own idempotent >=2048-bit check and
    # is a no-op if the cert is already fine). Gating this on $replacedSharedDlls -contains
    # meant the check only ever ran on the one run where the DLL swap actually happened
    # (hashes match on every later run, so nothing gets "replaced") - if that first
    # regeneration failed, or the cert reverted for any reason (reinstall, restore from
    # backup, etc.), every subsequent run would silently skip re-checking it, leaving
    # Apache permanently stuck refusing to start with "ee key too small".
    $apacheDir = Join-Path $XamppPath "apache"
    $sslCertRegenerated = Repair-WeakSslCertificate -ApacheDir $apacheDir -BackupDir $backupDir -Timestamp $ts
    if ($sslCertRegenerated) {
        Log "Regenerated XAMPP's self-signed SSL certificate with a 2048-bit key (the old one was rejected by the newer OpenSSL build now shared with php_curl.dll)"
    }

    # ================== APP DEPLOYMENT (optional) ==================

    if ($SourcePath) {
        if (-not (Test-Path $SourcePath)) { throw "SourcePath not found: $SourcePath" }

        if ((Get-Item $SourcePath).PSIsContainer) {
            Log "Copying app source folder into $appDir"
            New-Item -ItemType Directory -Force -Path $appDir | Out-Null
            Copy-Item -Path (Join-Path $SourcePath "*") -Destination $appDir -Recurse -Force
        }
        elseif ($SourcePath -match '\.zip$') {
            $appExtractRoot = Get-TempRootPath
            $appTempExtract = Join-Path $appExtractRoot "app_new_$ts"
            Log "Extracting app zip to temp: $appTempExtract"
            Expand-Archive -Path $SourcePath -DestinationPath $appTempExtract -Force

            $appItems = Get-ChildItem -Path $appTempExtract
            $appSourceRoot = $appTempExtract
            if ($appItems.Count -eq 1 -and $appItems[0].PSIsContainer) {
                $appSourceRoot = $appItems[0].FullName
            }

            Log "Copying extracted app files into $appDir"
            New-Item -ItemType Directory -Force -Path $appDir | Out-Null
            Copy-Item -Path (Join-Path $appSourceRoot "*") -Destination $appDir -Recurse -Force
            Remove-Item -Path $appTempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            throw "SourcePath must be a folder or a .zip file: $SourcePath"
        }
    }
    else {
        Log "No SourcePath given; assuming app files already exist at $appDir"
    }

    if (-not (Test-Path $docRoot)) {
        Log "WARNING: expected document root does not exist yet: $docRoot"
        Log "The Alias/Directory block will still be written, but Apache will 404 until the folder exists."
    }

    # ================== APACHE PHP INTEGRATION ==================

    $apachePhpIntegrationUpdated = Update-ApachePhpIntegration -ConfPath $xamppConfPath -PhpDir $phpDir
    if ($apachePhpIntegrationUpdated) {
        Log "Updated Apache PHP handler lines in httpd-xampp.conf"
    }
    else {
        Log "Apache PHP handler lines already matched the new PHP folder"
    }

    $systemPathUpdated = $false
    try {
        $systemPathUpdated = Add-DirectoryToMachinePath -Directory $phpDir
        if ($systemPathUpdated) {
            Broadcast-EnvironmentChange
        }
    }
    catch {
        Log "WARNING: Could not update machine PATH (needs admin rights): $($_.Exception.Message)"
        Log "WARNING: PHP CLI may not be on PATH; Apache is unaffected by this and will still work."
    }

    # mysqldump/mysql aren't on PATH by default on a stock XAMPP install either - apps
    # that shell out to them (e.g. RPS's backup feature) fail with "'mysqldump' is not
    # recognized" until this is added, the same class of problem PHP had before the
    # block above.
    $mysqlBinDir = Join-Path $mysqlDir "bin"
    $mysqlPathUpdated = $false
    try {
        if (Test-Path $mysqlBinDir) {
            $mysqlPathUpdated = Add-DirectoryToMachinePath -Directory $mysqlBinDir
            if ($mysqlPathUpdated) {
                Broadcast-EnvironmentChange
            }
        }
    }
    catch {
        Log "WARNING: Could not update machine PATH (needs admin rights): $($_.Exception.Message)"
        Log "WARNING: mysqldump/mysql may not be on PATH; apps that shell out to them (e.g. RPS backups) may fail."
    }

    # ================== APACHE VIRTUAL HOST CONFIG ==================
    # A subfolder Alias (http://localhost/$AppName) breaks Laravel in practice: generated
    # asset/route URLs, redirects and the storage symlink all assume the app is served
    # from the domain root. A dedicated VirtualHost with its own hostname avoids that.

    $vhostsConfPath = Join-Path $apacheConfDir "extra\httpd-vhosts.conf"
    $hostName = "$AppName.local"

    $mainConfBackupPath = Join-Path $backupDir "httpd_backup_$ts.conf"
    Copy-Item -Path $mainConfPath -Destination $mainConfBackupPath -Force
    Log "Backed up httpd.conf -> backup\httpd_backup_$ts.conf"

    $vhostsConfBackupPath = Join-Path $backupDir "httpd-vhosts_backup_$ts.conf"
    if (Test-Path $vhostsConfPath) {
        Copy-Item -Path $vhostsConfPath -Destination $vhostsConfBackupPath -Force
        Log "Backed up httpd-vhosts.conf -> backup\httpd-vhosts_backup_$ts.conf"
    }

    $vhostsIncludeEnabled = Enable-VhostsInclude -MainConfPath $mainConfPath
    if ($vhostsIncludeEnabled) {
        Log "Enabled 'Include conf/extra/httpd-vhosts.conf' in httpd.conf"
    }
    else {
        Log "httpd-vhosts.conf was already included in httpd.conf"
    }

    $defaultVhostAdded = Set-DefaultLocalhostVirtualHost -VhostsConfPath $vhostsConfPath -XamppPath $XamppPath
    if ($defaultVhostAdded) {
        Log "Added a default VirtualHost for 'localhost' so the XAMPP dashboard keeps working"
    }

    # HTTPS for the app's own hostname, not just XAMPP's shared https://localhost - a
    # plain http://$hostName origin is treated as insecure by browsers, which blocks
    # camera/microphone access (getUserMedia) and other secure-context-only APIs.
    $sslModuleEnabled = Enable-SslModule -MainConfPath $mainConfPath
    if ($sslModuleEnabled) {
        Log "Enabled mod_ssl (LoadModule ssl_module + Include conf/extra/httpd-ssl.conf) in httpd.conf"
    }
    else {
        Log "mod_ssl was already enabled in httpd.conf"
    }

    $appCert = New-AppSslCertificate -ApacheDir $apacheDir -AppName $AppName -HostName $hostName
    if ($appCert) {
        if ($appCert.Generated) {
            Log "Generated a self-signed SSL certificate for $hostName"
            if (Install-TrustedCertificate -CrtPath $appCert.CrtPath) {
                Log "Trusted the certificate in Windows' Root store (avoids browser 'Not Secure' warnings for $hostName)"
            }
        }
        else {
            Log "Existing SSL certificate for $hostName is still valid; reusing it"
        }
    }

    $urlSummary = if ($appCert) { "http://$hostName and https://$hostName" } else { "http://$hostName (https:// unavailable - see warnings above)" }
    Log "Adding/updating VirtualHost for '$AppName' -> $urlSummary"
    Set-AppVirtualHost -VhostsConfPath $vhostsConfPath -AppName $AppName -HostName $hostName -DocRoot $docRoot -SslCrtPath $appCert.CrtPath -SslKeyPath $appCert.KeyPath

    $hostsEntryAdded = Add-HostsFileEntry -HostName $hostName -BackupDir $backupDir -Timestamp $ts
    if ($hostsEntryAdded) {
        Log "Added '127.0.0.1 $hostName' to the hosts file"
    }
    else {
        Log "Hosts file already had an entry for $hostName"
    }

    if (-not (Test-ApacheConfig -httpdExe $httpdExe -confPath $mainConfPath)) {
        Log "Rolling back httpd.conf and httpd-vhosts.conf to their pre-edit state due to failed syntax test"
        Copy-Item -Path $mainConfBackupPath -Destination $mainConfPath -Force
        if (Test-Path $vhostsConfBackupPath) {
            Copy-Item -Path $vhostsConfBackupPath -Destination $vhostsConfPath -Force
        }
        else {
            Remove-Item -Path $vhostsConfPath -Force -ErrorAction SilentlyContinue
        }
        throw "Apache config syntax test failed after edit. Changes were reverted; Apache was left stopped. See log for details."
    }

    # ================== RESTART APACHE ==================
    # Apache was stopped earlier to safely overwrite the PHP files, so it must be started back up now.

    $apacheLeftRunning = Start-Apache -xamppPath $XamppPath
    if ($apacheLeftRunning) {
        Log "Apache started"
    }
    else {
        Log "Apache config verified working. Start Apache from XAMPP Control Panel to bring it up for normal use."
    }

    $reportLines = @(
        "PHP migration report for $AppName",
        "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "",
        "Pre-upgrade PHP: $prePhpVersion",
        "Post-upgrade PHP: $postPhpVersion",
        "",
        "php.ini backup: " + $(if ($legacyPhpIniBackupPath) { $legacyPhpIniBackupPath } else { "not needed" }),
        "",
        "Apache PHP handler + PHPIniDir updated: " + $(if ($apachePhpIntegrationUpdated) { "yes" } else { "already correct" }),
        "Machine PATH updated with: " + $(if ($systemPathUpdated) { $phpDir } else { "already included" }),
        "Machine PATH updated with (mysql\bin): " + $(if ($mysqlPathUpdated) { $mysqlBinDir } else { "already included" }),
        "",
        "VirtualHost: $urlSummary -> $docRoot",
        "Hosts file entry ($hostName): " + $(if ($hostsEntryAdded) { "added" } else { "already present" }),
        "App SSL certificate ($hostName): " + $(if (-not $appCert) { "failed - see warnings above" } elseif ($appCert.Generated) { "generated" } else { "already valid" }),
        "",
        "Merged php.ini settings:"
    )
    if ($migration.ScalarSettings.Count -gt 0) {
        $reportLines += $migration.ScalarSettings
    }
    else {
        $reportLines += "none"
    }

    $reportLines += ""
    $reportLines += "php.ini defaults raised for RPS (memory/upload/execution-time/input limits):"
    if ($migration.BaselineDefaultsRaised.Count -gt 0) {
        $reportLines += $migration.BaselineDefaultsRaised
    }
    else {
        $reportLines += "none (already at or above the recommended baseline)"
    }

    $reportLines += ""
    $reportLines += "Extensions enabled for Laravel:"
    if ($migration.RequiredExtensionsEnabled.Count -gt 0) {
        $reportLines += $migration.RequiredExtensionsEnabled
    }
    else {
        $reportLines += "none (already enabled)"
    }

    $reportLines += ""
    $reportLines += "Enabled extensions that could not be verified in the new ext folder:"
    if ($migration.ExtensionWarnings.Count -gt 0) {
        $reportLines += $migration.ExtensionWarnings
    }
    else {
        $reportLines += "none"
    }

    $reportLines += ""
    $reportLines += "Apache conf files repaired:"
    if ($apacheRepairFiles.Count -gt 0) {
        $reportLines += $apacheRepairFiles
    }
    else {
        $reportLines += "none"
    }

    $reportLines += ""
    $reportLines += "Apache-bundled DLLs replaced (were shadowing php_curl.dll's dependencies):"
    if ($replacedSharedDlls.Count -gt 0) {
        $reportLines += $replacedSharedDlls
    }
    else {
        $reportLines += "none needed"
    }

    $reportLines += ""
    $reportLines += "Weak self-signed SSL certificate regenerated (2048-bit): " + $(if ($sslCertRegenerated) { "yes" } else { "not needed" })

    $reportLines += ""
    $reportLines += "Post-upgrade php -m snapshot:"
    if ($postLoadedModules.Count -gt 0) {
        $reportLines += $postLoadedModules
    }
    else {
        $reportLines += "No modules captured."
    }

    $reportLines += ""
    $reportLines += "Apache left running after this script: " + $(if ($apacheLeftRunning) { "yes" } else { "no - start it from XAMPP Control Panel" })

    Write-TextFileNoBom -Path $phpUpgradeReportPath -Content ($reportLines -join "`r`n")
    Log "Wrote migration report: $phpUpgradeReportPath"

    Log "Done. Backup folder: $backupDir."
    Log "PHP updated in place. App '$AppName' is available at $urlSummary -> $docRoot"
    if (-not $apacheLeftRunning) {
        Log "IMPORTANT: Start Apache from XAMPP Control Panel now (run Control Panel as your normal user, not elevated)."
    }
    exit 0
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
