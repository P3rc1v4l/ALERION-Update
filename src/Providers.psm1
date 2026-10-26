# Update Center - update providers.
# Every provider returns result objects created by New-UpdateResult so the report stays uniform.
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function New-UpdateResult {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Name,
        [string]$Id = '',
        [string]$From = '',
        [string]$To = '',
        [ValidateSet('Updated', 'Failed', 'Skipped', 'Available', 'Info', 'Triggered')][string]$Status = 'Info',
        [string]$Message = '',
        [bool]$RebootRequired = $false,
        [string]$Key = '',
        [ValidateSet('', 'Critical', 'Important', 'Normal', 'Optional')][string]$Priority = '',
        [bool]$IsCheck = $false
    )
    if (-not $Key) { $Key = '{0}|{1}' -f $Source, $(if ($Id) { $Id } else { $Name }) }
    [pscustomobject]@{
        Key = $Key; Source = $Source; Name = $Name; Id = $Id; From = $From; To = $To
        Status = $Status; Message = $Message; RebootRequired = $RebootRequired
        Priority = $Priority; Major = $false; IsCheck = $IsCheck; Excluded = $false
    }
}

# =====================================================================================
# Priorities
#   Critical  - security relevant: Windows security updates, Defender, browsers, runtimes,
#               archivers, PDF readers, remote access/VPN, the update tools themselves
#   Important - drivers, other Windows/Microsoft updates, Store, Office
#   Normal    - all other programs
#   Optional  - beta/preview builds and packages whose installed version winget cannot read
# =====================================================================================

$script:SecurityPackages = @(
    'Microsoft.AppInstaller', 'chocolatey', 'Google.Chrome*', 'Mozilla.Firefox*', 'Brave.Brave*', 'Microsoft.Edge*',
    'Opera.Opera*', 'Vivaldi.Vivaldi', 'LibreWolf.LibreWolf', 'Microsoft.DotNet.*', 'Microsoft.VCRedist.*',
    'Oracle.JavaRuntimeEnvironment', 'Oracle.JDK.*', 'EclipseAdoptium.*', 'Microsoft.OpenJDK.*', '7zip.7zip', 'RARLab.WinRAR',
    'VideoLAN.VLC', 'Git.Git', 'OpenJS.NodeJS*', 'Python.Python.*', 'Microsoft.PowerShell', 'Zoom.Zoom',
    'Mozilla.Thunderbird*', 'Notepad++.Notepad++', 'WinSCP.WinSCP', 'PuTTY.PuTTY', 'Tailscale.Tailscale',
    'OpenVPNTechnologies.*', 'WireGuard.WireGuard', 'Microsoft.OneDrive', 'Adobe.Acrobat.Reader*', 'Foxit.FoxitReader*',
    'TeamViewer.TeamViewer*', 'AnyDesk.AnyDesk', 'Docker.DockerDesktop', 'GitHub.cli', 'KeePassXCTeam.KeePassXC',
    'Bitwarden.Bitwarden', 'AgileBits.1Password', 'Microsoft.WSL', 'Microsoft.Teams*', 'Microsoft.Office',
    'python*', 'nodejs*', 'git', '7zip*', 'googlechrome', 'firefox', 'vlc', 'dotnet*', 'vcredist*'
)

function Test-MajorJump {
    param([string]$From, [string]$To)
    $a = [regex]::Match([string]$From, '^\s*(\d+)'); $b = [regex]::Match([string]$To, '^\s*(\d+)')
    if (-not $a.Success -or -not $b.Success) { return $false }
    return ([long]$b.Groups[1].Value -gt [long]$a.Groups[1].Value)
}

# Per-package priorities chosen by the user (config PriorityOverrides: id -> priority).
$script:PriorityOverrides = @{}

function Set-PriorityOverrides {
    param($Map)
    $script:PriorityOverrides = @{}
    if ($Map) { foreach ($p in $Map.PSObject.Properties) { if ([string]$p.Value -in 'Critical', 'Important', 'Normal', 'Optional') { $script:PriorityOverrides[$p.Name] = [string]$p.Value } } }
}

function Get-UpdatePriority {
    param([Parameter(Mandatory)]$Item, [string[]]$Categories = @(), [string]$Severity = '')
    if ($Item.Id -and $script:PriorityOverrides.ContainsKey([string]$Item.Id)) { return $script:PriorityOverrides[[string]$Item.Id] }
    switch ($Item.Source) {
        'defender' { return 'Critical' }
        'self'     { return 'Critical' }
        'gpu'      { return 'Important' }
        'store'    { return 'Important' }
        'office'   { return 'Important' }
        'windows'  {
            if ($Severity -or (($Categories -join ' ') -match '(?i)security|critical|sicherheit|kritisch')) { return 'Critical' }
            return 'Important'
        }
    }
    $text = "$($Item.Id) $($Item.To)"
    if ($Item.From -match '(?i)unknown|unbekannt|<|>' -or $text -match '(?i)beta|alpha|preview|insider|canary|nightly|[-.]rc\d*\b') { return 'Optional' }
    foreach ($p in $script:SecurityPackages) { if ($Item.Id -like $p) { return 'Critical' } }
    return 'Normal'
}

function Set-UpdateMeta {
    <# Adds Priority/Major to a candidate (and copies Key/Priority onto an install result). #>
    param([Parameter(Mandatory)]$Item, $Template, [string[]]$Categories = @(), [string]$Severity = '')
    if ($Template) {
        $Item.Key = $Template.Key; $Item.Priority = $Template.Priority; $Item.Major = $Template.Major; $Item.IsCheck = $Template.IsCheck
        if (-not $Item.From) { $Item.From = $Template.From }
        return $Item
    }
    if (-not $Item.Priority) { $Item.Priority = Get-UpdatePriority -Item $Item -Categories $Categories -Severity $Severity }
    $Item.Major = Test-MajorJump -From $Item.From -To $Item.To
    return $Item
}

function Invoke-Process {
    <# Runs an executable hidden, captures output to files, enforces a timeout. #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMinutes = 90)
    $tmp = Join-Path (Get-AppPaths).CacheDir ("proc-{0}" -f [guid]::NewGuid().ToString('N'))
    $outFile = "$tmp.out"; $errFile = "$tmp.err"
    $quoted = $ArgumentList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $p = Start-Process -FilePath $FilePath -ArgumentList $quoted -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle  # caches the handle so ExitCode is available after exit (PS 5.1 quirk)
    $finished = $p.WaitForExit($TimeoutMinutes * 60 * 1000)
    if (-not $finished) {
        try { $p.Kill() } catch { }
        $code = -999
    } else {
        $p.WaitForExit()
        $code = $p.ExitCode
    }
    $out = ''
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path $f) { $out += (Get-Content $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ ExitCode = $code; Output = [string]$out; TimedOut = (-not $finished) }
}

# =====================================================================================
# winget
# =====================================================================================

$script:WingetCodes = @{
    0             = 'OK'
    3010          = 'REBOOT'
    1641          = 'REBOOT'
    -1978334967   = 'REBOOT'          # 0x8A150109 install finished, reboot required
    -1978334966   = 'REBOOT_TO_INSTALL' # 0x8A15010A reboot required before install
    -1978335189   = 'NOT_APPLICABLE'  # 0x8A15002B no applicable upgrade
    -1978335090   = 'TECH_MISMATCH'   # 0x8A15008E upgrade uses a different installer technology
    -1978334959   = 'IN_USE'          # 0x8A150111 package in use by another application
    -1978335212   = 'NOT_FOUND'       # 0x8A150014 no package found
    -1978334975   = 'IN_USE'          # 0x8A150101 application in use
    -1978334973   = 'IN_PROGRESS'     # 0x8A150103 another installation in progress
    -1978334972   = 'DISK_FULL'       # 0x8A150104
    -1978334964   = 'CANCELLED'       # 0x8A15010C
}

function Get-WingetPath {
    # Prefer the admin-protected WindowsApps location over PATH lookup, so a winget.exe planted
    # in a user-writable PATH folder can never be executed elevated.
    $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.InstallLocation 'winget.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function ConvertFrom-WingetUpgradeTable {
    <# Parses `winget upgrade` text output. Columns are read from the right because names may
       contain spaces or wide characters: Source, Available, Version (may be "< 1.2"), Id, Name. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    $lines = @($Text -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() })
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}$') { $start = $i + 1; break } }
    if ($start -lt 0) { return $rows.ToArray() }
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $tok = @($line -split '\s+' | Where-Object { $_ })
        if ($tok.Count -lt 4) { break }
        $source = $tok[-1]
        if ($source -notin @('winget', 'msstore')) { break }   # footer line like "35 upgrades available."
        $available = $tok[-2]
        $idx = $tok.Count - 3
        $version = $tok[$idx]
        if ($idx -ge 1 -and $tok[$idx - 1] -in @('<', '>')) { $idx--; $version = $tok[$idx] + ' ' + $version }
        $idIdx = $idx - 1
        if ($idIdx -lt 0) { continue }
        $id = $tok[$idIdx]
        $name = if ($idIdx -gt 0) { ($tok[0..($idIdx - 1)] -join ' ') } else { $id }
        $rows.Add([pscustomobject]@{
            Name = $name; Id = $id; Version = $version; Available = $available; Source = $source
            Truncated = ($id.EndsWith([string][char]0x2026) -or $id.EndsWith('...'))
        })
    }
    return $rows.ToArray()
}

function ConvertFrom-WingetListTable {
    <# Parses `winget list`. Columns can be empty here (no "Available", no "Source"), so cells are
       cut at the header positions instead of splitting on whitespace. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    $lines = @($Text -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() })
    $sep = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 1) { return $rows.ToArray() }
    $starts = @([regex]::Matches($lines[$sep - 1], '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 3) { return $rows.ToArray() }
    for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $cells = for ($c = 0; $c -lt $starts.Count; $c++) {
            $s = $starts[$c]
            if ($s -ge $line.Length) { ''; continue }
            $e = if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $line.Length) } else { $line.Length }
            $line.Substring($s, $e - $s).Trim()
        }
        $cells = @($cells)
        if (-not $cells[1]) { continue }
        $rows.Add([pscustomobject]@{
            Name = $cells[0]; Id = $cells[1]; Version = $cells[2]
            Available = $(if ($starts.Count -ge 5) { $cells[3] } else { '' })
            Source = $cells[-1]
        })
    }
    return $rows.ToArray()
}

function Get-InstalledPrograms {
    <# Everything winget can see (also programs it cannot update) - used by the GUI search. #>
    $winget = Get-WingetPath
    if (-not $winget) { return @() }
    $r = Invoke-Process -FilePath $winget -ArgumentList @('list', '--accept-source-agreements', '--disable-interactivity') -TimeoutMinutes 10
    return @(ConvertFrom-WingetListTable -Text $r.Output)
}

function Get-WingetUpgrades {
    param([bool]$IncludeUnknown = $true)
    $winget = Get-WingetPath
    if (-not $winget) { throw 'winget.exe not found' }
    $wgArgs = @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    if ($IncludeUnknown) { $wgArgs += '--include-unknown' }
    $r = Invoke-Process -FilePath $winget -ArgumentList $wgArgs -TimeoutMinutes 10
    return @(ConvertFrom-WingetUpgradeTable -Text $r.Output)
}

function Get-PackageProcess {
    <# Running processes that belong to an installed program. winget manifests carry no process
       names, so the install folder is taken from the uninstall registry entry with the same
       display name and matched against the paths of running processes. #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $folders = foreach ($entry in @(Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -eq $DisplayName })) {
        if ($entry.PSObject.Properties.Name -contains 'InstallLocation' -and $entry.InstallLocation) { $entry.InstallLocation.Trim('"').TrimEnd('\') }
        elseif ($entry.PSObject.Properties.Name -contains 'DisplayIcon' -and $entry.DisplayIcon) { Split-Path ($entry.DisplayIcon.Split(',')[0].Trim('"')) -Parent }
    }
    # Never treat broad folders as "the program" (would match unrelated processes).
    $folders = @($folders | Where-Object { $_ -and $_.Length -gt 12 -and $_ -notmatch '^[A-Za-z]:\\(Windows|Program Files( \(x86\))?|ProgramData)?\\?$' } | Select-Object -Unique)
    if (-not $folders.Count) { return @() }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $p = $null; try { $p = $_.Path } catch { }
        $p -and @($folders | Where-Object { $p.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count
    })
}

function Invoke-WingetPackageUpgrade {
    param([Parameter(Mandatory)]$Package, [int]$TimeoutMinutes = 90, [switch]$CloseRunning)
    $winget = Get-WingetPath
    $base = @{ Source = 'winget'; Name = $Package.Name; Id = $Package.Id; From = $Package.Version; To = $Package.Available }
    # A running program usually blocks its own update (e.g. OBS): close it when allowed, else skip.
    if ($CloseRunning) { [void](Stop-PackageProcess -DisplayName $Package.Name) }
    $running = @(Get-PackageProcess -DisplayName $Package.Name)
    if ($running.Count) {
        Write-Log -Level WARN -Message ("winget {0}: skipped, running ({1})" -f $Package.Id, (($running | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', '))
        return New-UpdateResult @base -Status Skipped -Message 'msg.appRunning'
    }
    $wgArgs = @('upgrade', '--id', $Package.Id, '--exact', '--source', $Package.Source, '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Package.Version -match 'Unknown|Unbekannt|<|>') { $wgArgs += '--include-unknown' }
    Write-Log -Message "winget upgrade $($Package.Id) ($($Package.Version) -> $($Package.Available))"
    $r = Invoke-Process -FilePath $winget -ArgumentList $wgArgs -TimeoutMinutes $TimeoutMinutes
    $code = $r.ExitCode
    $kind = if ($script:WingetCodes.ContainsKey($code)) { $script:WingetCodes[$code] } else { 'ERROR' }
    if ($r.TimedOut) { $kind = 'TIMEOUT' }
    # "No applicable upgrade" is often a scope mismatch (user vs machine install): retry once per scope.
    if ($kind -eq 'NOT_APPLICABLE') {
        foreach ($scope in 'user', 'machine') {
            $retry = Invoke-Process -FilePath $winget -ArgumentList ($wgArgs + @('--scope', $scope)) -TimeoutMinutes $TimeoutMinutes
            $retryKind = if ($script:WingetCodes.ContainsKey($retry.ExitCode)) { $script:WingetCodes[$retry.ExitCode] } else { 'ERROR' }
            Write-Log -Message ("winget {0}: retry --scope {1} -> exit {2} ({3})" -f $Package.Id, $scope, $retry.ExitCode, $retryKind)
            if ($retryKind -in 'OK', 'REBOOT') { $code = $retry.ExitCode; $kind = $retryKind; break }
        }
    }
    Write-Log -Level $(if ($kind -in 'OK', 'REBOOT') { 'OK' } else { 'WARN' }) -Message ("winget {0}: exit {1} ({2})" -f $Package.Id, $code, $kind)
    switch ($kind) {
        'OK'                { return New-UpdateResult @base -Status Updated }
        'REBOOT'            { return New-UpdateResult @base -Status Updated -RebootRequired $true }
        'NOT_APPLICABLE'    { return New-UpdateResult @base -Status Skipped -Message 'msg.noApplicableUpdate' }
        'TECH_MISMATCH'     { return New-UpdateResult @base -Status Skipped -Message 'msg.techMismatch' }
        'REBOOT_TO_INSTALL' { return New-UpdateResult @base -Status Skipped -Message 'msg.rebootFirst' -RebootRequired $true }
        'IN_USE'            { return New-UpdateResult @base -Status Skipped -Message 'msg.appInUse' }
        'TIMEOUT'           { return New-UpdateResult @base -Status Failed -Message 'msg.timeout' }
        default             { return New-UpdateResult @base -Status Failed -Message ("exit 0x{0:X8}" -f $code) }
    }
}

function Stop-PackageProcess {
    <# Closes a program before its update: asks politely (WM_CLOSE) and only kills after the grace period.
       Returns the names of processes that were running. #>
    param([Parameter(Mandatory)][string]$DisplayName, [int]$GraceSeconds = 15)
    $procs = @(Get-PackageProcess -DisplayName $DisplayName)
    if (-not $procs.Count) { return @() }
    $names = @($procs | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    foreach ($p in $procs) { try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { } }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline -and @($procs | Where-Object { -not $_.HasExited }).Count) { Start-Sleep -Milliseconds 500 }
    foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Write-Log -Message ("Closed for update: {0} ({1})" -f $DisplayName, ($names -join ', '))
    return $names
}

function Invoke-WingetReinstall {
    <# For packages installed with another installer technology (winget 0x8A15008E): uninstall the
       current copy and install the winget version. User data normally stays (only the program is replaced). #>
    param([Parameter(Mandatory)][string]$Id, [string]$Name = '', [string]$From = '', [switch]$DryRun)
    $winget = Get-WingetPath
    $base = @{ Source = 'winget'; Name = $(if ($Name) { $Name } else { $Id }); Id = $Id; From = $From }
    if (-not $winget) { return New-UpdateResult @base -Status Failed -Message 'msg.wingetMissing' }
    if ($DryRun) { return New-UpdateResult @base -Status Info -Message 'msg.reinstallDry' }
    if ($Name) { [void](Stop-PackageProcess -DisplayName $Name) }
    $common = @('--id', $Id, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
    Write-Log -Message "winget reinstall $Id"
    $u = Invoke-Process -FilePath $winget -ArgumentList (@('uninstall') + $common + @('--force')) -TimeoutMinutes 30
    Write-Log -Message ("winget uninstall {0}: exit {1}" -f $Id, $u.ExitCode)
    $i = Invoke-Process -FilePath $winget -ArgumentList (@('install') + $common + @('--accept-package-agreements', '--force')) -TimeoutMinutes 60
    $kind = if ($script:WingetCodes.ContainsKey($i.ExitCode)) { $script:WingetCodes[$i.ExitCode] } else { 'ERROR' }
    Write-Log -Level $(if ($kind -in 'OK', 'REBOOT') { 'OK' } else { 'WARN' }) -Message ("winget install {0}: exit {1} ({2})" -f $Id, $i.ExitCode, $kind)
    $to = ''
    if ($kind -in 'OK', 'REBOOT') {
        $list = Invoke-Process -FilePath $winget -ArgumentList @('list', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutMinutes 5
        $row = @(ConvertFrom-WingetListTable -Text $list.Output | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
        if ($row) { $to = [string]$row.Version }
        return New-UpdateResult @base -To $to -Status Updated -RebootRequired ($kind -eq 'REBOOT') -Message 'msg.reinstalled'
    }
    return New-UpdateResult @base -Status Failed -Message ("exit 0x{0:X8}" -f $i.ExitCode)
}

function Get-WingetReleaseNotesUrl {
    <# Release notes link of a package (falls back to the homepage). Empty when winget knows none. #>
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-WingetPath
    if (-not $winget) { return '' }
    $r = Invoke-Process -FilePath $winget -ArgumentList @('show', '--id', $Id, '--exact', '--accept-source-agreements', '--disable-interactivity') -TimeoutMinutes 2
    $fallback = ''
    foreach ($line in ($r.Output -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(Release Notes Url|Versionshinweise-URL|Homepage|Startseite|Publisher Url|Herausgeber-URL)\s*:\s*(https://\S+)\s*$')
        if (-not $m.Success) { continue }
        if ($m.Groups[1].Value -match 'Release|Versionshinweise') { return $m.Groups[2].Value }
        if (-not $fallback) { $fallback = $m.Groups[2].Value }
    }
    return $fallback
}

# =====================================================================================
# Remembered winget outcomes: packages that cannot be updated in place stop being offered as
# recommended until a newer version appears (avoids the same failure on every run).
# =====================================================================================

function Get-WingetMemoryPath { Join-Path (Get-AppPaths).StateDir 'winget-memory.json' }

function Get-WingetMemory {
    $map = @{}
    $file = Get-WingetMemoryPath
    if (Test-Path $file) {
        try {
            $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $data.PSObject.Properties) { $map[$p.Name] = $p.Value }
        } catch { }
    }
    return $map
}

function Update-WingetMemory {
    <# Kinds: 'notapplicable', 'tech' (other installer technology), 'mismatch' (version never changes). #>
    param([Parameter(Mandatory)][object[]]$Results)
    $map = Get-WingetMemory
    foreach ($r in $Results) {
        if ($r.Source -ne 'winget' -or -not $r.Id) { continue }
        $kind = switch ($r.Message) { 'msg.noApplicableUpdate' { 'notapplicable' } 'msg.techMismatch' { 'tech' } 'msg.stillOutdated' { 'mismatch' } default { '' } }
        if ($r.Status -eq 'Updated' -and -not $kind) { $map.Remove($r.Id); continue }
        if ($kind) { $map[$r.Id] = [pscustomobject]@{ Available = [string]$r.To; Kind = $kind; At = (Get-Date).ToString('o') } }
    }
    $obj = New-Object PSObject
    foreach ($k in $map.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $map[$k] }
    Write-AtomicFile -Path (Get-WingetMemoryPath) -Content ($obj | ConvertTo-Json -Depth 4)
}
# =====================================================================================
# Chocolatey
# =====================================================================================

function Get-ChocoPath {
    # Machine-level variable only: user-level environment must not choose what runs elevated.
    $root = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    if (-not $root) { $root = Join-Path $env:ProgramData 'chocolatey' }
    $p = Join-Path $root 'bin\choco.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Get-ChocoOutdated {
    $choco = Get-ChocoPath
    if (-not $choco) { return @() }
    $r = Invoke-Process -FilePath $choco -ArgumentList @('outdated', '-r', '--ignore-unfound', '--ignore-pinned', '--no-color') -TimeoutMinutes 15
    $list = foreach ($line in ($r.Output -split "`r?`n")) {
        $parts = $line.Trim() -split '\|'
        if ($parts.Count -ge 4 -and $parts[3] -eq 'false') {
            [pscustomobject]@{ Name = $parts[0]; Version = $parts[1]; Available = $parts[2] }
        }
    }
    return @($list)
}

function Invoke-ChocoUpgrade {
    param([Parameter(Mandatory)]$Package)
    $choco = Get-ChocoPath
    Write-Log -Message "choco upgrade $($Package.Name) ($($Package.Version) -> $($Package.Available))"
    $r = Invoke-Process -FilePath $choco -ArgumentList @('upgrade', $Package.Name, '-y', '-r', '--no-progress', '--no-color') -TimeoutMinutes 60
    $base = @{ Source = 'choco'; Name = $Package.Name; Id = $Package.Name; From = $Package.Version; To = $Package.Available }
    switch ($r.ExitCode) {
        0       { return New-UpdateResult @base -Status Updated }
        { $_ -in 1641, 3010 } { return New-UpdateResult @base -Status Updated -RebootRequired $true }
        -999    { return New-UpdateResult @base -Status Failed -Message 'msg.timeout' }
        default { return New-UpdateResult @base -Status Failed -Message "exit $($r.ExitCode)" }
    }
}

# =====================================================================================
# Windows Update / Microsoft Update (COM API, no extra module)
# =====================================================================================

$script:MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

function Enable-MicrosoftUpdate {
    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $registered = @($sm.Services | Where-Object { $_.ServiceID -eq $script:MicrosoftUpdateServiceId }).Count -gt 0
        if (-not $registered) {
            # 7 = allow pending + online registration + register with Automatic Updates
            [void]$sm.AddService2($script:MicrosoftUpdateServiceId, 7, '')
            Write-Log -Message 'Microsoft Update service registered'
        }
        return $true
    } catch {
        Write-Log -Level WARN -Message "Microsoft Update registration failed: $($_.Exception.Message)"
        return $false
    }
}

function Find-WindowsUpdates {
    <# Returns an IUpdateCollection-compatible list of applicable updates (already filtered). #>
    param([bool]$IncludeDrivers = $true, [bool]$UseMicrosoftUpdate = $true, [bool]$SkipNvidiaDisplay = $true, [bool]$SkipDefinitions = $false)
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Update Center'
    $searcher = $session.CreateUpdateSearcher()
    if ($UseMicrosoftUpdate -and (Enable-MicrosoftUpdate)) {
        $searcher.ServerSelection = 3   # ssOthers
        $searcher.ServiceID = $script:MicrosoftUpdateServiceId
    }
    $criteria = @("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($IncludeDrivers) { $criteria += "IsInstalled=0 and IsHidden=0 and Type='Driver'" }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($c in $criteria) {
        $res = $searcher.Search($c)
        foreach ($u in $res.Updates) {
            $title = [string]$u.Title
            if ($u.Type -eq 1) {
                # Software: skip optional previews and feature upgrades (big OS jumps stay a manual decision).
                if ($u.BrowseOnly) { continue }
                if ($title -match '(?i)feature update|funktionsupdate|upgrade to windows|preview') { continue }
                # Defender definitions are handled by the Defender source (avoids duplicates).
                if ($SkipDefinitions -and ((Get-WUCategories $u) -join ' ') -match '(?i)definition') { continue }
            } else {
                # Drivers: never let Windows Update replace the NVIDIA driver we manage directly.
                if ($SkipNvidiaDisplay -and $u.DriverClass -eq 'Display' -and $title -match '(?i)nvidia') { continue }
            }
            if ($u.InstallationBehavior.CanRequestUserInput) { continue }
            $found.Add($u)
        }
    }
    return $found.ToArray()
}

function Get-WUKb { param($Update) $kb = @($Update.KBArticleIDs); if ($kb.Count -gt 0 -and $kb[0]) { "KB$($kb[0])" } else { '' } }
function Get-WUCategories { param($Update) @($Update.Categories | ForEach-Object { [string]$_.Name }) }

function ConvertTo-WUCandidate {
    param([Parameter(Mandatory)]$Update)
    $kb = Get-WUKb $Update
    $isDriver = ($Update.Type -eq 2)
    $to = if ($isDriver -and $Update.DriverVerDate) { ([datetime]$Update.DriverVerDate).ToString('yyyy-MM-dd') } else { $kb }
    $item = New-UpdateResult -Source 'windows' -Name ([string]$Update.Title) -Id $(if ($kb) { $kb } else { [string]$Update.Identity.UpdateID }) `
        -To $to -Status Available -Key ('windows|' + $Update.Identity.UpdateID) -RebootRequired ([bool]($Update.InstallationBehavior.RebootBehavior -ne 0))
    if ($isDriver) { $item.Message = 'msg.driver' }
    $item = Set-UpdateMeta -Item $item -Categories (Get-WUCategories $Update) -Severity ([string]$Update.MsrcSeverity)
    # "Optional driver updates" in Windows Settings: offered, but Windows itself would not install them.
    if ($isDriver -and $Update.BrowseOnly -and -not $script:PriorityOverrides.ContainsKey([string]$item.Id)) { $item.Priority = 'Optional'; $item.Message = 'msg.driverOptional' }
    return $item
}

function Get-WindowsUpdateCandidates {
    param([bool]$IncludeDrivers, [bool]$UseMicrosoftUpdate, [bool]$SkipNvidiaDisplay, [bool]$SkipDefinitions)
    return @(Find-WindowsUpdates -IncludeDrivers $IncludeDrivers -UseMicrosoftUpdate $UseMicrosoftUpdate -SkipNvidiaDisplay $SkipNvidiaDisplay -SkipDefinitions $SkipDefinitions |
        ForEach-Object { ConvertTo-WUCandidate $_ })
}

function Select-WUUpdates {
    param([object[]]$Updates, [string[]]$OnlyIds)
    if (-not $OnlyIds) { return @($Updates) }
    return @($Updates | Where-Object { $OnlyIds -contains [string]$_.Identity.UpdateID })
}

function Save-WindowsUpdates {
    <# Downloads the selected updates (runs in a background job). Returns update IDs. #>
    param([bool]$IncludeDrivers, [bool]$UseMicrosoftUpdate, [bool]$SkipNvidiaDisplay, [bool]$SkipDefinitions, [string[]]$OnlyIds)
    # @() matters: a single COM update would otherwise come back as a scalar without .Count
    $updates = @(Select-WUUpdates -Updates @(Find-WindowsUpdates -IncludeDrivers $IncludeDrivers -UseMicrosoftUpdate $UseMicrosoftUpdate -SkipNvidiaDisplay $SkipNvidiaDisplay -SkipDefinitions $SkipDefinitions) -OnlyIds $OnlyIds)
    if ($updates.Count -eq 0) { return @() }
    $session = New-Object -ComObject Microsoft.Update.Session
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        if (-not $u.IsDownloaded) { [void]$coll.Add($u) }
    }
    if ($coll.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $coll
        [void]$dl.Download()
    }
    return @($updates | ForEach-Object { $_.Identity.UpdateID })
}

function Install-WindowsUpdates {
    param([bool]$IncludeDrivers, [bool]$UseMicrosoftUpdate, [bool]$SkipNvidiaDisplay, [bool]$SkipDefinitions, [string[]]$OnlyIds)
    $results = New-Object System.Collections.Generic.List[object]
    # @() matters: a single COM update would otherwise come back as a scalar without .Count
    $updates = @(Select-WUUpdates -Updates @(Find-WindowsUpdates -IncludeDrivers $IncludeDrivers -UseMicrosoftUpdate $UseMicrosoftUpdate -SkipNvidiaDisplay $SkipNvidiaDisplay -SkipDefinitions $SkipDefinitions) -OnlyIds $OnlyIds)
    if ($updates.Count -eq 0) { return $results.ToArray() }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Update Center'
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }

    $pending = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $coll) { if (-not $u.IsDownloaded) { [void]$pending.Add($u) } }
    if ($pending.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $pending; [void]$dl.Download()
    }
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $coll
    $res = $installer.Install()
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $u = $coll.Item($i)
        $r = $res.GetUpdateResult($i)
        $status = if ($r.ResultCode -in 2, 3) { 'Updated' } else { 'Failed' }   # 2 ok, 3 ok with errors, 4 failed, 5 aborted
        $item = ConvertTo-WUCandidate $u
        $item.Status = $status
        $item.RebootRequired = [bool]$r.RebootRequired
        if ($status -eq 'Failed') { $item.Message = ("HRESULT 0x{0:X8}" -f $r.HResult) }
        $results.Add($item)
    }
    if ($res.RebootRequired -and $results.Count -gt 0) { $results[0].RebootRequired = $true }
    return $results.ToArray()
}
# =====================================================================================
# Microsoft Store
# =====================================================================================

function Get-StoreSnapshot {
    $map = @{}
    Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and $_.SignatureKind -eq 'Store' } |
        ForEach-Object { $map[$_.Name] = [string]$_.Version }
    return $map
}

function Start-StoreUpdateScan {
    try {
        $cls = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop
        $r = $cls | Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop
        Write-Log -Message "Store update scan triggered (result $($r.ReturnValue))"
        return $true
    } catch {
        Write-Log -Level WARN -Message "Store update scan failed: $($_.Exception.Message)"
        return $false
    }
}

function Compare-StoreSnapshot {
    param([hashtable]$Before)
    $after = Get-StoreSnapshot
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in $after.Keys) {
        if ($Before.ContainsKey($name) -and $Before[$name] -ne $after[$name]) {
            $results.Add((New-UpdateResult -Source 'store' -Name $name -Id $name -From $Before[$name] -To $after[$name] -Status Updated))
        }
    }
    return $results.ToArray()
}

# =====================================================================================
# Microsoft Defender signatures
# =====================================================================================

function Update-DefenderSignatures {
    try {
        $before = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
    } catch {
        return New-UpdateResult -Source 'defender' -Name 'Microsoft Defender' -Status Skipped -Message 'msg.defenderInactive'
    }
    try {
        Update-MpSignature -ErrorAction Stop
        $after = (Get-MpComputerStatus).AntivirusSignatureVersion
        $status = if ($after -ne $before) { 'Updated' } else { 'Info' }
        $msg = if ($status -eq 'Info') { 'msg.upToDate' } else { '' }
        return New-UpdateResult -Source 'defender' -Name 'Microsoft Defender' -Id 'signatures' -From $before -To $after -Status $status -Message $msg
    } catch {
        return New-UpdateResult -Source 'defender' -Name 'Microsoft Defender' -From $before -Status Failed -Message $_.Exception.Message
    }
}

# =====================================================================================
# Microsoft 365 / Office Click-to-Run
# =====================================================================================

function Start-OfficeUpdate {
    param([int]$WaitMinutes = 25)
    $c2r = Join-Path $env:CommonProgramFiles 'microsoft shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path $c2r)) { return $null }
    $cfg = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $ver = ''
    try { $ver = (Get-ItemProperty $cfg -ErrorAction Stop).VersionToReport } catch { }
    try {
        # Office has its own updater (Click-to-Run). Open Office apps are not force-closed; the update
        # is then staged and applied when they close.
        Start-Process -FilePath $c2r -ArgumentList '/update user displaylevel=false forceappshutdown=false' -WindowStyle Hidden
        # Follow the updater instead of fire-and-forget: wait until its client processes are gone and
        # compare the version, so the report can say what really happened.
        $deadline = (Get-Date).AddMinutes($WaitMinutes)
        Start-Sleep -Seconds 20
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'OfficeC2RClient' -ErrorAction SilentlyContinue).Count) { Start-Sleep -Seconds 10 }
        $now = ''
        try { $now = (Get-ItemProperty $cfg -ErrorAction Stop).VersionToReport } catch { }
        if ($now -and $ver -and $now -ne $ver) {
            return New-UpdateResult -Source 'office' -Name 'Microsoft 365 / Office' -Id 'C2R' -From $ver -To $now -Status Updated
        }
        $officeOpen = @(Get-Process -Name 'WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'lync', 'Teams' -ErrorAction SilentlyContinue).Count -gt 0
        $msg = if ($officeOpen) { 'msg.officeStaged' } else { 'msg.officeBackground' }
        return New-UpdateResult -Source 'office' -Name 'Microsoft 365 / Office' -Id 'C2R' -From $ver -To $now -Status Triggered -Message $msg
    } catch {
        return New-UpdateResult -Source 'office' -Name 'Microsoft 365 / Office' -From $ver -Status Failed -Message $_.Exception.Message
    }
}

# =====================================================================================
# NVIDIA graphics driver (official NVIDIA lookup API, signature-verified)
# =====================================================================================

function ConvertTo-NvidiaVersion {
    <# Windows driver version 32.0.16.2101 -> NVIDIA version 621.01 (last five digits). #>
    param([Parameter(Mandatory)][string]$DriverVersion)
    $digits = ($DriverVersion -replace '\.', '')
    if ($digits.Length -lt 5) { return $null }
    $last = $digits.Substring($digits.Length - 5)
    return '{0}.{1}' -f [int]$last.Substring(0, 3), $last.Substring(3, 2)
}

function Get-NvidiaGpu {
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA' } | Select-Object -First 1
}

function Get-NvidiaLookup {
    <# Cached (7 days) NVIDIA product/OS lookup tables. #>
    param([int]$TypeId)
    $file = Join-Path (Get-AppPaths).CacheDir "nvidia-lookup-$TypeId.xml"
    if (-not (Test-Path $file) -or (Get-Item $file).LastWriteTime -lt (Get-Date).AddDays(-7)) {
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=$TypeId" -OutFile $file -TimeoutSec 60
    }
    return [xml](Get-Content $file -Raw)
}

function Get-NvidiaLatestDriver {
    param([Parameter(Mandatory)][string]$GpuName, [switch]$Studio)
    $products = (Get-NvidiaLookup -TypeId 3).LookupValueSearch.LookupValues.LookupValue
    $name = $GpuName.Trim()
    $p = $products | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $p) { $p = $products | Where-Object { $_.Name -eq ($name -replace '^NVIDIA\s+', '') } | Select-Object -First 1 }
    if (-not $p) { throw "GPU '$name' not found in NVIDIA product list" }
    $osName = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'Windows 11' } else { 'Windows 10 64-bit' }
    $os = (Get-NvidiaLookup -TypeId 4).LookupValueSearch.LookupValues.LookupValue | Where-Object { $_.Name -eq $osName } | Select-Object -First 1
    if (-not $os) { throw "OS '$osName' not found in NVIDIA OS list" }
    $uri = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
        "?func=DriverManualLookup&psid=$($p.ParentID)&pfid=$($p.Value)&osID=$($os.Value)&languageCode=1033&isWHQL=1&dch=1&upCRD=$(if ($Studio) { 1 } else { 0 })&sort1=0&numberOfResults=1"
    $r = Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 60
    if (-not $r.IDS -or -not $r.IDS[0].downloadInfo) { throw 'NVIDIA lookup returned no driver' }
    $info = $r.IDS[0].downloadInfo
    $url = [uri]$info.DownloadURL
    if ($url.Scheme -ne 'https' -or $url.Host -notmatch '(^|\.)download\.nvidia\.com$') { throw "Untrusted NVIDIA download host: $($url.Host)" }
    [pscustomobject]@{ Version = [string]$info.Version; Url = $url.AbsoluteUri; Size = [string]$info.DownloadURLFileSize; Release = [string]$info.ReleaseDateTime }
}

function Get-NvidiaUpdateInfo {
    <# Returns $null when no NVIDIA GPU, otherwise current/latest/needsUpdate. -Studio = Studio driver branch. #>
    param([switch]$Studio)
    $gpu = Get-NvidiaGpu
    if (-not $gpu) { return $null }
    $current = ConvertTo-NvidiaVersion $gpu.DriverVersion
    $latest = Get-NvidiaLatestDriver -GpuName $gpu.Name -Studio:$Studio
    [pscustomobject]@{
        GpuName = $gpu.Name; Current = $current; Latest = $latest.Version; Url = $latest.Url; Size = $latest.Size
        NeedsUpdate = ([version]$latest.Version -gt [version]$current)
    }
}

function Save-NvidiaDriver {
    <# Downloads the driver package into the protected cache and verifies the NVIDIA signature. #>
    param([Parameter(Mandatory)]$Info)
    $dir = Join-Path (Get-AppPaths).CacheDir 'nvidia'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ("nvidia-{0}.exe" -f $Info.Latest)
    if (-not (Test-Path $file)) {
        $part = "$file.part"
        try {
            Start-BitsTransfer -Source $Info.Url -Destination $part -Priority Foreground -ErrorAction Stop
        } catch {
            Write-Log -Level WARN -Message "BITS failed, falling back to HTTPS download: $($_.Exception.Message)"
            Invoke-WebRequest -UseBasicParsing -Uri $Info.Url -OutFile $part -TimeoutSec 3600
        }
        Move-Item $part $file -Force
    }
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation') {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        throw "NVIDIA package signature invalid ($($sig.Status))"
    }
    return $file
}

function Install-NvidiaDriver {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)][string]$File)
    $base = @{ Source = 'gpu'; Name = $Info.GpuName; Id = 'NVIDIA driver'; From = $Info.Current; To = $Info.Latest }
    Write-Log -Message "Installing NVIDIA driver $($Info.Latest)"
    # The NVIDIA package is a 7-Zip SFX that forwards these switches to setup.exe.
    $r = Invoke-Process -FilePath $File -ArgumentList @('-s', '-noreboot', '-noeula', '-nofinish', '-nosplash') -TimeoutMinutes 45
    $gpu = Get-NvidiaGpu
    $now = if ($gpu) { ConvertTo-NvidiaVersion $gpu.DriverVersion } else { '' }
    if ($now -eq $Info.Latest) {
        Get-ChildItem (Split-Path $File) -Filter 'nvidia-*.exe' | Remove-Item -Force -ErrorAction SilentlyContinue
        return New-UpdateResult @base -Status Updated -RebootRequired ($r.ExitCode -ne 0)
    }
    if ($r.ExitCode -eq 0) { return New-UpdateResult @base -Status Updated -RebootRequired $true -Message 'msg.activeAfterReboot' }
    return New-UpdateResult @base -Status Failed -Message ("setup exit {0}" -f $r.ExitCode)
}

function Backup-DisplayDriver {
    <# Exports the installed graphics driver package (pnputil) before a driver update, so it can be
       reinstalled via Device Manager -> Update driver -> Browse. Keeps the two newest backups. #>
    $root = Join-Path (Get-AppPaths).DataDir 'backups\drivers'
    try {
        $drv = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" -ErrorAction Stop | Where-Object { $_.InfName -match '^oem\d+\.inf$' })
        if (-not $drv.Count) { return New-UpdateResult -Source 'system' -Name 'msg.driverBackup' -Status Skipped -Message 'msg.driverBackupNone' }
        $d = $drv[0]
        $dir = Join-Path $root ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmm'), ($d.DriverVersion -replace '[^\d.]', ''))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $pnputil = Join-Path $env:WINDIR 'System32\pnputil.exe'
        $r = Invoke-Process -FilePath $pnputil -ArgumentList @('/export-driver', $d.InfName, $dir) -TimeoutMinutes 10
        if ($r.ExitCode -ne 0) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; throw "pnputil exit $($r.ExitCode)" }
        @(Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -Skip 2) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log -Level OK -Message "Display driver $($d.DriverVersion) backed up to $dir"
        return New-UpdateResult -Source 'system' -Name 'msg.driverBackup' -From ([string]$d.DriverVersion) -Status Updated -Message $dir
    } catch {
        return New-UpdateResult -Source 'system' -Name 'msg.driverBackup' -Status Skipped -Message $_.Exception.Message
    }
}

# =====================================================================================
# System restore point
# =====================================================================================

function New-RestorePoint {
    try {
        $warn = $null
        Checkpoint-Computer -Description 'Update Center' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable warn -WarningAction SilentlyContinue
        if ($warn) { return New-UpdateResult -Source 'system' -Name 'msg.restorePoint' -Status Skipped -Message 'msg.restorePointRecent' }
        return New-UpdateResult -Source 'system' -Name 'msg.restorePoint' -Status Updated -Message 'msg.restorePointCreated'
    } catch {
        return New-UpdateResult -Source 'system' -Name 'msg.restorePoint' -Status Skipped -Message 'msg.restorePointDisabled'
    }
}

# =====================================================================================
# Self-update from GitHub Releases (SHA-256 verified, applied after the run)
# =====================================================================================

function Invoke-SelfUpdate {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [switch]$DryRun,
        # Test hook: apply into this folder instead of the installed program folder.
        [string]$TargetRoot
    )
    $current = Get-AppVersion
    $paths = Get-AppPaths
    $appRoot = if ($TargetRoot) { $TargetRoot } else { $paths.AppRoot }
    $headers = @{ 'User-Agent' = 'UpdateCenter'; 'Accept' = 'application/vnd.github+json' }
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 30
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -Status Info -Message 'msg.noRelease' }
        return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -Status Skipped -Message $_.Exception.Message
    }
    $tag = ([string]$rel.tag_name).TrimStart('v')
    if ($tag -notmatch '^\d+\.\d+\.\d+$') { return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -Status Skipped -Message "invalid tag $($rel.tag_name)" }
    if ([version]$tag -le [version]$current) { return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -To $current -Status Info -Message 'msg.upToDate' }
    if ($DryRun) { return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -To $tag -Status Available }
    if (-not $TargetRoot -and $appRoot -notlike "$env:ProgramFiles*") {
        return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -To $tag -Status Skipped -Message 'msg.selfUpdateDevMode'
    }
    # Current asset name first, v1.x name as fallback.
    $zipAsset = $null; $shaAsset = $null; $zipName = $null
    foreach ($candidate in @("UpdateCenter-v$tag.zip", "ALERION-Update-v$tag.zip")) {
        $z = @($rel.assets | Where-Object { $_.name -eq $candidate }) | Select-Object -First 1
        $h = @($rel.assets | Where-Object { $_.name -eq "$candidate.sha256" }) | Select-Object -First 1
        if ($z -and $h) { $zipAsset = $z; $shaAsset = $h; $zipName = $candidate; break }
    }
    if (-not $zipAsset -or -not $shaAsset) { return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -To $tag -Status Skipped -Message 'msg.releaseIncomplete' }
    foreach ($a in @($zipAsset, $shaAsset)) {
        $u = [uri]$a.browser_download_url
        if ($u.Scheme -ne 'https' -or $u.Host -ne 'github.com') { throw "Untrusted self-update URL: $u" }
    }
    $work = Join-Path $paths.CacheDir "selfupdate-$tag"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work $zipName
    Invoke-WebRequest -UseBasicParsing -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $headers -TimeoutSec 300
    # GitHub serves release assets as application/octet-stream, so Content is a byte[] here.
    $shaContent = (Invoke-WebRequest -UseBasicParsing -Uri $shaAsset.browser_download_url -Headers $headers -TimeoutSec 60).Content
    $expected = if ($shaContent -is [byte[]]) { [Text.Encoding]::ASCII.GetString($shaContent) } else { [string]$shaContent }
    $expected = ($expected.Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw 'Self-update checksum mismatch, update rejected' }
    $extract = Join-Path $work 'x'
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $versionFile = Get-ChildItem $extract -Recurse -Filter 'VERSION' | Select-Object -First 1
    if (-not $versionFile) { throw 'Self-update package has no VERSION file' }
    $root = $versionFile.DirectoryName
    if ((Get-Content $versionFile.FullName -Raw).Trim() -ne $tag) { throw 'Self-update package version does not match release tag' }
    if (-not (Test-Path (Join-Path $root 'src\UpdateEngine.ps1'))) { throw 'Self-update package is incomplete' }
    # Code signing (trust on first use): once the installed copy is signed, every update must be signed
    # by the same certificate and match its catalog. The verifier is the INSTALLED module, never the new one.
    $signingModule = Join-Path $appRoot 'src\Signing.psm1'
    if (Test-Path $signingModule) {
        Import-Module $signingModule -Force -DisableNameChecking
        $trust = Test-UpdatePackageTrust -NewRoot $root -InstalledRoot $appRoot
        Write-Log -Message ("Self-update signature: {0} {1}" -f $trust.Reason, $trust.Detail)
        if (-not $trust.Allowed) {
            Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
            return New-UpdateResult -Source 'self' -Name 'Update Center' -From $current -To $tag -Status Failed -Message $trust.Reason
        }
    }
    if ($TargetRoot) {
        # Test hook: copy straight into the given folder.
        foreach ($item in @('src', 'assets', 'VERSION', 'Install.ps1', 'Uninstall.ps1', 'LICENSE', 'README.md', 'CHANGELOG.md')) {
            $srcItem = Join-Path $root $item
            $dstItem = Join-Path $appRoot $item
            if (-not (Test-Path $srcItem)) { continue }
            if (Test-Path $srcItem -PathType Container) {
                if (-not (Test-Path $dstItem)) { New-Item -ItemType Directory -Path $dstItem -Force | Out-Null }
                Copy-Item (Join-Path $srcItem '*') -Destination $dstItem -Recurse -Force
            } else { Copy-Item $srcItem -Destination $dstItem -Force }
        }
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        return New-UpdateResult -Source 'self' -Name 'Update Center' -Id $Repo -From $current -To $tag -Status Updated
    }
    # Never copy into the program folder while the app is running (open windows lock files such as
    # assets\icon.ico). The verified package is handed to ITS installer instead: it waits until this run
    # has finished, closes the app, replaces all files, re-registers tasks and reopens the app.
    $installer = Join-Path $root 'Install.ps1'
    if (-not (Test-Path $installer)) { throw 'Self-update package has no installer' }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installer`" -NoLaunch -Quiet"
    Write-Log -Level OK -Message "Self-update $current -> $tag verified, installer started from $root"
    return New-UpdateResult -Source 'self' -Name 'Update Center' -Id $Repo -From $current -To $tag -Status Updated -Message 'msg.selfUpdateStaged'
}

# =====================================================================================
# Candidates for the "one action" sources (shown and selectable like packages)
# =====================================================================================

function Get-DefenderCandidate {
    try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { return $null }
    $item = New-UpdateResult -Source 'defender' -Name 'Microsoft Defender' -Id 'signatures' -From ([string]$s.AntivirusSignatureVersion) -Key 'defender|signatures'
    $age = (Get-Date) - [datetime]$s.AntivirusSignatureLastUpdated
    if ($age.TotalHours -ge 12) { $item.Status = 'Available'; $item.Message = 'msg.signaturesOld' }
    else { $item.Status = 'Info'; $item.Message = 'msg.upToDate' }
    return Set-UpdateMeta -Item $item
}

function Get-StoreCandidate {
    $item = New-UpdateResult -Source 'store' -Name 'msg.storeApps' -Id 'apps' -Status Available -Key 'store|apps' -IsCheck $true -Message 'msg.checkInstall'
    return Set-UpdateMeta -Item $item
}

function Get-OfficeCandidate {
    $c2r = Join-Path $env:CommonProgramFiles 'microsoft shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path $c2r)) { return $null }
    $ver = ''
    try { $ver = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction Stop).VersionToReport } catch { }
    $item = New-UpdateResult -Source 'office' -Name 'Microsoft 365 / Office' -Id 'C2R' -From $ver -Status Available -Key 'office|c2r' -IsCheck $true -Message 'msg.checkInstall'
    return Set-UpdateMeta -Item $item
}

function ConvertTo-GpuCandidate {
    param($Info)
    if (-not $Info) { return $null }
    $item = New-UpdateResult -Source 'gpu' -Name $Info.GpuName -Id 'NVIDIA driver' -From $Info.Current -To $Info.Latest -Key 'gpu|nvidia'
    if ($Info.NeedsUpdate) { $item.Status = 'Available'; $item.Message = $Info.Size } else { $item.Status = 'Info'; $item.Message = 'msg.upToDate' }
    return Set-UpdateMeta -Item $item
}

Export-ModuleMember -Function *
