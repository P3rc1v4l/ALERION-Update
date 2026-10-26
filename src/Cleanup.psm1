# Update Center - risk-free system cleanup ("Aufraeumen").
# Only caches and temporary data that Windows or the owning app rebuilds on demand.
# Deliberately NOT included: Prefetch, registry cleaners, DISM /ResetBase, the Installer folder,
# manual WinSxS deletion, browser cookies/history/passwords, memory dumps, restore points.
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:CategoryMeta = [ordered]@{
    recyclebin   = @{ Risk = 'None'; Admin = $false; Default = $true }
    temp         = @{ Risk = 'None'; Admin = $false; Default = $true }
    wucache      = @{ Risk = 'None'; Admin = $true;  Default = $true }
    docache      = @{ Risk = 'None'; Admin = $true;  Default = $true }
    thumbs       = @{ Risk = 'None'; Admin = $false; Default = $true }
    wer          = @{ Risk = 'None'; Admin = $true;  Default = $true }
    shadercache  = @{ Risk = 'None'; Admin = $false; Default = $true }
    browsercache = @{ Risk = 'None'; Admin = $false; Default = $true }
    dumps        = @{ Risk = 'None'; Admin = $false; Default = $true }
    appcache     = @{ Risk = 'None'; Admin = $false; Default = $true }
    components   = @{ Risk = 'Low';  Admin = $true;  Default = $false }
}

# ---------------------------------------------------------------- path guard
function Test-CleanupPath {
    <# True only when Path is strictly inside Root (never Root itself, never a drive root as Root,
       '..' segments are resolved first). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch { return $false }
    if ($r.Length -lt 4 -or $r -match '^[A-Za-z]:$') { return $false }   # refuse drive roots
    if ($p.Length -le $r.Length) { return $false }
    return $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------- enumeration
function Get-CleanupFiles {
    <# Walks Root without following junctions/symlinks. Returns Files (FileInfo[]) and Dirs (string[],
       only directories that are old enough; used to remove empty folders afterwards). #>
    param([Parameter(Mandatory)][string]$Root, [double]$MinAgeDays = 0, [string]$NameRegex = '', [switch]$NoRecurse)
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $cutoff = [datetime]::UtcNow.AddDays(-$MinAgeDays)
    $rootInfo = $null
    try { $rootInfo = New-Object System.IO.DirectoryInfo($Root) } catch { }
    if ($rootInfo -and $rootInfo.Exists -and -not ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push($rootInfo)
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            $entries = $null
            try { $entries = $d.GetFileSystemInfos() } catch { continue }
            foreach ($e in $entries) {
                if ($e -is [System.IO.DirectoryInfo]) {
                    if ($NoRecurse) { continue }
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($e)
                    if ($e.LastWriteTimeUtc -lt $cutoff) { $dirs.Add($e.FullName) }
                } else {
                    if ($NameRegex -and $e.Name -notmatch $NameRegex) { continue }
                    if ($MinAgeDays -gt 0 -and ($e.LastWriteTimeUtc -ge $cutoff -or $e.CreationTimeUtc -ge $cutoff)) { continue }
                    $files.Add([System.IO.FileInfo]$e)
                }
            }
        }
    }
    [pscustomobject]@{ Files = $files.ToArray(); Dirs = $dirs.ToArray() }
}

function Clear-CleanupFolder {
    <# Deletes (or, with -DryRun, only measures) matching files below Root. Locked / denied files are
       skipped silently and counted. Every path is validated against Root before deletion. #>
    param([Parameter(Mandatory)][string]$Root, [double]$MinAgeDays = 0, [string]$NameRegex = '', [switch]$NoRecurse, [switch]$DryRun)
    $freed = [long]0; $done = 0; $locked = 0
    $found = Get-CleanupFiles -Root $Root -MinAgeDays $MinAgeDays -NameRegex $NameRegex -NoRecurse:$NoRecurse
    foreach ($f in $found.Files) {
        if (-not (Test-CleanupPath -Path $f.FullName -Root $Root)) { $locked++; continue }
        if ($DryRun) { $freed += $f.Length; $done++; continue }
        try {
            $len = $f.Length
            if ($f.IsReadOnly) { $f.IsReadOnly = $false }
            $f.Delete()
            $freed += $len; $done++
        } catch { $locked++ }
    }
    if (-not $DryRun) {
        foreach ($d in ($found.Dirs | Sort-Object { $_.Length } -Descending)) {
            if (-not (Test-CleanupPath -Path $d -Root $Root)) { continue }
            try { [IO.Directory]::Delete($d) } catch { }   # non-recursive: fails on non-empty dirs, which is intended
        }
    }
    [pscustomobject]@{ Freed = $freed; Files = $done; Locked = $locked }
}

# ---------------------------------------------------------------- targets per category
$script:Browsers = @(
    @{ Name = 'chrome'; Proc = 'chrome'; Base = 'Google\Chrome\User Data'; Kind = 'chromium' },
    @{ Name = 'edge';   Proc = 'msedge'; Base = 'Microsoft\Edge\User Data'; Kind = 'chromium' },
    @{ Name = 'brave';  Proc = 'brave';  Base = 'BraveSoftware\Brave-Browser\User Data'; Kind = 'chromium' },
    @{ Name = 'firefox'; Proc = 'firefox'; Base = 'Mozilla\Firefox\Profiles'; Kind = 'firefox' }
)

function New-Target {
    param([string]$Root, [double]$MinAgeDays = 0, [string]$NameRegex = '', [switch]$NoRecurse, [string]$Proc = '')
    [pscustomobject]@{ Root = $Root; MinAgeDays = $MinAgeDays; NameRegex = $NameRegex; NoRecurse = [bool]$NoRecurse; Proc = $Proc }
}

function Get-CleanupTargets {
    param([Parameter(Mandatory)][string]$Id)
    $t = New-Object System.Collections.Generic.List[object]
    $sys = $env:SystemRoot; $pd = $env:ProgramData; $lad = $env:LOCALAPPDATA
    switch ($Id) {
        'temp' {
            if ($env:TEMP) { $t.Add((New-Target -Root $env:TEMP -MinAgeDays 1)) }
            if ((Test-IsAdmin) -and $sys) { $t.Add((New-Target -Root (Join-Path $sys 'Temp') -MinAgeDays 1)) }
        }
        'wucache' { if ($sys) { $t.Add((New-Target -Root (Join-Path $sys 'SoftwareDistribution\Download'))) } }
        'docache' { if ($pd) { $t.Add((New-Target -Root (Join-Path $pd 'Microsoft\Windows\DeliveryOptimization\Cache'))) } }
        'thumbs' { if ($lad) { $t.Add((New-Target -Root (Join-Path $lad 'Microsoft\Windows\Explorer') -NameRegex '^thumbcache_.*\.db$' -NoRecurse)) } }
        'wer' {
            if ($pd) { foreach ($s in 'ReportQueue', 'ReportArchive', 'Temp') { $t.Add((New-Target -Root (Join-Path $pd "Microsoft\Windows\WER\$s"))) } }
            if ($lad) { foreach ($s in 'ReportQueue', 'ReportArchive') { $t.Add((New-Target -Root (Join-Path $lad "Microsoft\Windows\WER\$s"))) } }
        }
        'shadercache' { if ($lad) { $t.Add((New-Target -Root (Join-Path $lad 'D3DSCache'))) } }
        'dumps' {
            if ($lad) { $t.Add((New-Target -Root (Join-Path $lad 'CrashDumps') -MinAgeDays 30)) }
            if ((Test-IsAdmin) -and $sys) { $t.Add((New-Target -Root (Join-Path $sys 'Minidump') -MinAgeDays 30)) }
        }
        'appcache' {
            $p = Get-AppPaths
            $t.Add((New-Target -Root $p.LogDir -MinAgeDays 30 -NameRegex '\.log$'))
            $t.Add((New-Target -Root $p.CacheDir -MinAgeDays 14))
        }
        'browsercache' {
            foreach ($b in $script:Browsers) {
                if (-not $lad) { continue }
                $base = Join-Path $lad $b.Base
                if (-not (Test-Path -LiteralPath $base)) { continue }
                if ($b.Kind -eq 'chromium') {
                    $profiles = @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
                    foreach ($pr in $profiles) {
                        foreach ($c in 'Cache', 'Code Cache', 'GPUCache') {
                            $t.Add((New-Target -Root (Join-Path $pr.FullName $c) -Proc $b.Proc))
                        }
                    }
                } else {
                    foreach ($pr in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
                        $t.Add((New-Target -Root (Join-Path $pr.FullName 'cache2') -Proc $b.Proc))
                    }
                }
            }
        }
    }
    return $t.ToArray()
}

function Get-RunningBrowserProcs {
    $names = @($script:Browsers | ForEach-Object { $_.Proc })
    @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName.ToLowerInvariant() } | Select-Object -Unique)
}

function Get-RecycleBinInfo {
    $size = [long]0; $count = 0
    try {
        $ns = (New-Object -ComObject Shell.Application).Namespace(0xA)
        if ($ns) {
            foreach ($i in @($ns.Items())) { $count++; try { $size += [long]$i.Size } catch { } }
        }
    } catch { }
    [pscustomobject]@{ Size = $size; Count = $count }
}

function Test-UpdateBusy {
    @(Get-Process -Name 'TiWorker', 'wusa', 'TrustedInstaller' -ErrorAction SilentlyContinue).Count -gt 0
}

# ---------------------------------------------------------------- public: categories
function Get-CleanupCategories {
    $admin = Test-IsAdmin
    $running = @(Get-RunningBrowserProcs)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($id in $script:CategoryMeta.Keys) {
        $m = $script:CategoryMeta[$id]
        $size = [long]0; $count = 0; $avail = $true; $note = ''
        try {
            if ($id -eq 'recyclebin') {
                $info = Get-RecycleBinInfo; $size = $info.Size; $count = $info.Count
            } elseif ($id -eq 'components') {
                $size = [long]-1
            } else {
                $targets = @(Get-CleanupTargets -Id $id)
                foreach ($tg in $targets) {
                    $r = Clear-CleanupFolder -Root $tg.Root -MinAgeDays $tg.MinAgeDays -NameRegex $tg.NameRegex -NoRecurse:$tg.NoRecurse -DryRun
                    $size += $r.Freed; $count += $r.Files
                }
                if ($id -eq 'browsercache') {
                    $installed = @($targets | ForEach-Object { $_.Proc } | Select-Object -Unique)
                    if ($installed.Count -eq 0) { $avail = $false; $note = 'not-installed' }
                    elseif (@($installed | Where-Object { $running -notcontains $_ }).Count -eq 0) { $avail = $false; $note = 'browser-running' }
                }
            }
            if ($m.Admin -and -not $admin) { $avail = $false; $note = 'needs-admin' }
            elseif ($id -eq 'wucache' -and $avail) {
                if (Test-UpdateBusy) { $avail = $false; $note = 'update-busy' }
                elseif (Test-PendingReboot) { $avail = $false; $note = 'reboot-pending' }
            }
        } catch {
            Write-Log -Level WARN -Message "Cleanup scan '$id' failed: $($_.Exception.Message)"
        }
        $out.Add([pscustomobject]@{
            Id = $id; SizeBytes = [long]$size; ItemCount = [int]$count; Risk = $m.Risk
            RequiresAdmin = [bool]$m.Admin; Default = [bool]$m.Default; Available = [bool]$avail; Note = $note
        })
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- public: run
function New-CleanupResult {
    param([string]$Id, [string]$Status, [long]$Freed = 0, [string]$Message = '')
    [pscustomobject]@{ Id = $Id; Status = $Status; FreedBytes = [long]$Freed; Message = $Message }
}

function Invoke-ServiceGuarded {
    <# Stops the services, runs the action, restarts what was running - always (finally). #>
    param([string[]]$Services, [scriptblock]$Action)
    $stopped = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($n in $Services) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -ne 'Stopped') {
                Stop-Service -Name $n -Force -ErrorAction Stop
                $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
                $stopped.Add($n)
            }
        }
        return (& $Action)
    } finally {
        foreach ($n in $stopped) {
            try { Start-Service -Name $n -ErrorAction Stop } catch { Write-Log -Level WARN -Message "Could not restart service ${n}: $($_.Exception.Message)" }
        }
    }
}

function Invoke-OneCleanup {
    param([string]$Id, [switch]$DryRun)
    $admin = Test-IsAdmin
    $m = $script:CategoryMeta[$Id]
    if ($m.Admin -and -not $admin) { return (New-CleanupResult $Id 'Skipped' 0 'needs-admin') }

    if ($Id -eq 'recyclebin') {
        $info = Get-RecycleBinInfo
        if ($info.Count -eq 0) { return (New-CleanupResult $Id 'Cleaned' 0 'nothing-to-clean') }
        if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' $info.Size "items=$($info.Count)") }
        Clear-RecycleBin -Force -ErrorAction Stop
        return (New-CleanupResult $Id 'Cleaned' $info.Size "items=$($info.Count)")
    }

    if ($Id -eq 'components') {
        if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' 0 'dism-startcomponentcleanup') }
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        $before = $drive.AvailableFreeSpace
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart' -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { return (New-CleanupResult $Id 'Failed' 0 "dism-exit=$($p.ExitCode)") }
        $gain = [Math]::Max([long]0, [long]($drive.AvailableFreeSpace - $before))
        $msg = if ($p.ExitCode -eq 3010) { 'reboot-required' } else { 'ok' }
        return (New-CleanupResult $Id 'Cleaned' $gain $msg)
    }

    $targets = @(Get-CleanupTargets -Id $Id)
    $skipNote = ''
    if ($Id -eq 'browsercache') {
        $running = @(Get-RunningBrowserProcs)
        $blocked = @($targets | Where-Object { $running -contains $_.Proc } | ForEach-Object { $_.Proc } | Select-Object -Unique)
        if ($blocked.Count -gt 0) { $skipNote = 'skipped-running=' + ($blocked -join ',') }
        $targets = @($targets | Where-Object { $running -notcontains $_.Proc })
        if ($targets.Count -eq 0) { return (New-CleanupResult $Id 'Skipped' 0 $(if ($skipNote) { 'browser-running' } else { 'not-installed' })) }
    }
    if ($Id -eq 'wucache') {
        if (Test-UpdateBusy) { return (New-CleanupResult $Id 'Skipped' 0 'update-busy') }
        if (Test-PendingReboot) { return (New-CleanupResult $Id 'Skipped' 0 'reboot-pending') }
    }

    $run = {
        $freed = [long]0; $files = 0; $locked = 0
        foreach ($tg in $targets) {
            $r = Clear-CleanupFolder -Root $tg.Root -MinAgeDays $tg.MinAgeDays -NameRegex $tg.NameRegex -NoRecurse:$tg.NoRecurse -DryRun:$DryRun
            $freed += $r.Freed; $files += $r.Files; $locked += $r.Locked
        }
        [pscustomobject]@{ Freed = $freed; Files = $files; Locked = $locked }
    }

    if ($Id -eq 'docache' -and -not $DryRun -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { Write-Log -Level WARN -Message "Delete-DeliveryOptimizationCache: $($_.Exception.Message)" }
    }

    if ($Id -eq 'wucache' -and -not $DryRun) {
        $res = Invoke-ServiceGuarded -Services @('wuauserv', 'bits') -Action $run
    } else {
        $res = & $run
    }

    $msg = "files=$($res.Files) locked=$($res.Locked)"
    if ($skipNote) { $msg += ' ' + $skipNote }
    if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' $res.Freed $msg) }
    $status = if ($res.Locked -gt 0 -or $skipNote) { 'Partial' } else { 'Cleaned' }
    return (New-CleanupResult $Id $status $res.Freed $msg)
}

function Invoke-Cleanup {
    param([Parameter(Mandatory)][string[]]$Ids, [switch]$DryRun)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($Ids)) {
        if (-not $script:CategoryMeta.Contains($id)) { $out.Add((New-CleanupResult $id 'Skipped' 0 'unknown-id')); continue }
        try {
            $r = Invoke-OneCleanup -Id $id -DryRun:$DryRun
            Write-Log -Level INFO -Message "Cleanup $id : $($r.Status) freed=$($r.FreedBytes) $($r.Message)"
            $out.Add($r)
        } catch {
            Write-Log -Level ERROR -Message "Cleanup $id failed: $($_.Exception.Message)"
            $out.Add((New-CleanupResult $id 'Failed' 0 $_.Exception.Message))
        }
    }
    return $out.ToArray()
}

Export-ModuleMember -Function Get-CleanupCategories, Invoke-Cleanup, Test-CleanupPath, Clear-CleanupFolder
