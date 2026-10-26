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

# ---------------------------------------------------------------- progress helpers
# Contract: the caller passes a synchronized hashtable. We write Percent (0..100, -1 = indeterminate), Text,
# CanCancel, CanPause, Phase; we read Cancel and Pause. Optional key Log: a synchronized ArrayList that receives short localized
# log lines ("HH:mm:ss  text", capped at 500 lines) via Add-ProgLog. $null = no progress, behave as before.
function Set-Prog {
    param($Progress, $Percent = $null, $Text = $null, $CanCancel = $null, $CanPause = $null, $Phase = $null)
    if ($null -eq $Progress) { return }
    try {
        if ($null -ne $Percent) { $Progress['Percent'] = [double]$Percent }
        if ($null -ne $Text) { $Progress['Text'] = [string]$Text }
        if ($null -ne $CanCancel) { $Progress['CanCancel'] = [bool]$CanCancel }
        if ($null -ne $CanPause) { $Progress['CanPause'] = [bool]$CanPause }
        if ($null -ne $Phase) { $Progress['Phase'] = [string]$Phase }
    } catch { }
}

$script:ProgLogMax = 500

function Add-ProgLog {
    <# Appends "HH:mm:ss  <T key args>" to $Progress['Log'] (if the caller supplied one) and trims it to 500 lines.
       Never throws: a logging problem must not break a cleanup. #>
    param($Progress, [string]$Key, [object[]]$Args2 = @())
    if ($null -eq $Progress) { return }
    try {
        $log = $Progress['Log']
        if ($null -eq $log) { return }
        $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), (T $Key $Args2)
        [void]$log.Add($line)
        while ($log.Count -gt $script:ProgLogMax) { $log.RemoveAt(0) }
    } catch { }
}

function Write-CleanupResultLog {
    <# One line per finished category: freed X / freed X with N locked files skipped / skipped (reason) / failed. Never throws. #>
    param($Progress, $Result)
    if ($null -eq $Progress) { return }
    try {
        $cat = T ('cl.' + $Result.Id)
        $freed = Format-ProgBytes ([double]$Result.FreedBytes)
        $msg = [string]$Result.Message
        $locked = 0
        if ($msg -match 'locked=(\d+)') { $locked = [int]$Matches[1] }
        switch ($Result.Status) {
            'Cleaned'    { Add-ProgLog $Progress 'log.cl.freed' @($cat, $freed) }
            'Partial'    {
                if ($locked -gt 0) { Add-ProgLog $Progress 'log.cl.freedLocked' @($cat, $freed, $locked) }
                else { Add-ProgLog $Progress 'log.cl.freed' @($cat, $freed) }
                if ($msg -match 'skipped-running=(\S+)') { Add-ProgLog $Progress 'log.cl.browserOpen' @($Matches[1]) }
            }
            'WouldClean' { Add-ProgLog $Progress 'log.cl.would' @($cat, $freed) }
            'Skipped'    {
                $why = switch -Regex ($msg) {
                    '^needs-admin'     { T 'log.cl.why.admin'; break }
                    '^browser-running' { T 'log.cl.why.browser'; break }
                    '^not-installed'   { T 'log.cl.why.notInstalled'; break }
                    '^update-busy'     { T 'log.cl.why.updateBusy'; break }
                    '^reboot-pending'  { T 'log.cl.why.reboot'; break }
                    default            { $msg }
                }
                Add-ProgLog $Progress 'log.cl.skipped' @($cat, $why)
            }
            'Cancelled'  { Add-ProgLog $Progress 'log.cl.cancelled' @($cat, $freed) }
            default      { Add-ProgLog $Progress 'log.cl.failed' @($cat, $msg) }
        }
    } catch { }
}

function Test-ProgCancel {
    param($Progress)
    if ($null -eq $Progress) { return $false }
    return ($Progress['Cancel'] -eq $true)
}

function Wait-ProgPause {
    <# Safe point: blocks while Pause is set (and pausing is currently allowed), keeps watching Cancel.
       Returns $true when cancellation was requested. #>
    param($Progress)
    if ($null -eq $Progress) { return $false }
    if ($Progress['Cancel'] -eq $true) { return $true }
    if ($Progress['Pause'] -eq $true -and $Progress['CanPause'] -eq $true) {
        $prev = $Progress['Text']
        Set-Prog $Progress -Text (T 'prog.paused')
        while ($Progress['Pause'] -eq $true -and $Progress['Cancel'] -ne $true) { Start-Sleep -Milliseconds 300 }
        if ($Progress['Cancel'] -eq $true) { return $true }
        if ($null -ne $prev) { Set-Prog $Progress -Text $prev }
    }
    return $false
}

function Format-ProgBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function ConvertFrom-DismProgress {
    <# Last percentage in DISM output such as "[=====     45.0%     ]" (also "[==== 100.0% ====]"), or $null. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Matches($Text, '\[[= ]*(\d{1,3}(?:[.,]\d+)?)\s*%[= ]*\]')
    if ($m.Count -eq 0) { return $null }
    $v = [double]::Parse(($m[$m.Count - 1].Groups[1].Value -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    return [Math]::Min(100.0, [Math]::Max(0.0, $v))
}

function Write-CleanupProgress {
    <# Overall percent = Floor + (100 - Floor) * (finished category weights + bytes done in this category) / total weight.
       Floor (10) is the share of the analysis pass, so the percent never runs backwards. #>
    param($Progress, $Ctx)
    if ($null -eq $Progress -or $null -eq $Ctx) { return }
    $done = [Math]::Min([double]$Ctx.CatDone, [double]$Ctx.CurW)
    $frac = if ($Ctx.Total -gt 0) { ([double]$Ctx.Base + $done) / [double]$Ctx.Total } else { 0.0 }
    $pct = [double]$Ctx.Floor + (100.0 - [double]$Ctx.Floor) * $frac
    $pct = [Math]::Min(99.9, [Math]::Max(0.0, $pct))
    Set-Prog $Progress -Percent $pct -Text (T 'prog.cleaning' @((T ('cl.' + $Ctx.Cat)), (Format-ProgBytes $Ctx.Freed)))
    $Ctx.Last = $Ctx.Sw.ElapsedMilliseconds
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
    param([Parameter(Mandatory)][string]$Root, [double]$MinAgeDays = 0, [string]$NameRegex = '', [switch]$NoRecurse, [hashtable]$Progress = $null)
    $cancelled = $false
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $cutoff = [datetime]::UtcNow.AddDays(-$MinAgeDays)
    $rootInfo = $null
    try { $rootInfo = New-Object System.IO.DirectoryInfo($Root) } catch { }
    if ($rootInfo -and $rootInfo.Exists -and -not ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push($rootInfo)
        while ($stack.Count -gt 0) {
            if ($Progress -and (Wait-ProgPause $Progress)) { $cancelled = $true; break }
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
    [pscustomobject]@{ Files = $files.ToArray(); Dirs = $dirs.ToArray(); Cancelled = $cancelled }
}

function Clear-CleanupFolder {
    <# Deletes (or, with -DryRun, only measures) matching files below Root. Locked / denied files are
       skipped silently and counted. Every path is validated against Root before deletion.
       Optional: -Found (pre-enumerated result of Get-CleanupFiles), -Progress (cancel/pause between files),
       -Ctx (internal progress context of Invoke-Cleanup). Result.Cancelled = $true when stopped early. #>
    param([Parameter(Mandatory)][string]$Root, [double]$MinAgeDays = 0, [string]$NameRegex = '', [switch]$NoRecurse, [switch]$DryRun,
          $Found = $null, [hashtable]$Progress = $null, $Ctx = $null)
    $freed = [long]0; $done = 0; $locked = 0; $cancelled = $false; $n = 0
    if ($null -eq $Found) { $Found = Get-CleanupFiles -Root $Root -MinAgeDays $MinAgeDays -NameRegex $NameRegex -NoRecurse:$NoRecurse -Progress $Progress }
    if ($Found.Cancelled) { $cancelled = $true }
    foreach ($f in $(if ($cancelled) { @() } else { $Found.Files })) {
        $n++
        if ($Progress -and (Wait-ProgPause $Progress)) { $cancelled = $true; break }
        if (-not (Test-CleanupPath -Path $f.FullName -Root $Root)) { $locked++; continue }
        $len = [long]$f.Length
        $ok = $true
        if ($DryRun) { $freed += $len; $done++ }
        else {
            try {
                if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                $f.Delete()
                $freed += $len; $done++
            } catch { $locked++; $ok = $false }
        }
        if ($Ctx) {
            $Ctx.CatDone += $len
            if ($ok) { $Ctx.Freed += $len }
            if (($n % 200) -eq 0 -or ($Ctx.Sw.ElapsedMilliseconds - $Ctx.Last) -ge 300) { Write-CleanupProgress $Progress $Ctx }
        }
    }
    if (-not $DryRun -and -not $cancelled) {
        foreach ($d in ($Found.Dirs | Sort-Object { $_.Length } -Descending)) {
            if (-not (Test-CleanupPath -Path $d -Root $Root)) { continue }
            try { [IO.Directory]::Delete($d) } catch { }   # non-recursive: fails on non-empty dirs, which is intended
        }
    }
    [pscustomobject]@{ Freed = $freed; Files = $done; Locked = $locked; Cancelled = $cancelled }
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
            # Test hook: UPDATECENTER_CLEANUP_TESTROOT redirects this category to a folder strictly inside the
            # user temp folder (used by tests/cleanup_test.ps1). Ignored for anything else.
            $hook = $env:UPDATECENTER_CLEANUP_TESTROOT
            if ($hook -and (Test-CleanupPath -Path $hook -Root ([IO.Path]::GetTempPath()))) {
                $t.Add((New-Target -Root $hook -MinAgeDays 0)); break
            }
            # The elevated app points %TEMP% to its private folder; the user's temp folder is remembered separately.
            $userTemp = if ($env:UPDATECENTER_USERTEMP) { $env:UPDATECENTER_USERTEMP } else { $env:TEMP }
            if ($userTemp) { $t.Add((New-Target -Root $userTemp -MinAgeDays 1)) }
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
    param([hashtable]$Progress = $null)
    $admin = Test-IsAdmin
    $running = @(Get-RunningBrowserProcs)
    $out = New-Object System.Collections.Generic.List[object]
    $total = $script:CategoryMeta.Count; $idx = 0; $stop = $false
    Set-Prog $Progress -Percent 0 -Text (T 'prog.analyzingStart') -CanCancel $true -CanPause $true -Phase 'scan'
    foreach ($id in $script:CategoryMeta.Keys) {
        $m = $script:CategoryMeta[$id]
        $size = [long]0; $count = 0; $avail = $true; $note = ''
        if (-not $stop -and $Progress -and (Wait-ProgPause $Progress)) { $stop = $true }
        if ($stop) {
            $out.Add([pscustomobject]@{
                Id = $id; SizeBytes = [long]0; ItemCount = 0; Risk = $m.Risk
                RequiresAdmin = [bool]$m.Admin; Default = [bool]$m.Default; Available = $false; Note = 'cancelled'
            })
            continue
        }
        Set-Prog $Progress -Percent (100.0 * $idx / $total) -Text (T 'prog.analyzing' @((T ('cl.' + $id))))
        $idx++
        try {
            if ($id -eq 'recyclebin') {
                $info = Get-RecycleBinInfo; $size = $info.Size; $count = $info.Count
            } elseif ($id -eq 'components') {
                $size = [long]-1
            } else {
                $targets = @(Get-CleanupTargets -Id $id)
                foreach ($tg in $targets) {
                    $r = Clear-CleanupFolder -Root $tg.Root -MinAgeDays $tg.MinAgeDays -NameRegex $tg.NameRegex -NoRecurse:$tg.NoRecurse -DryRun -Progress $Progress
                    $size += $r.Freed; $count += $r.Files
                    if ($r.Cancelled) { $stop = $true; break }
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
            RequiresAdmin = [bool]$m.Admin; Default = [bool]$m.Default; Available = [bool]$avail; Note = $(if ($stop) { 'cancelled' } else { $note })
        })
    }
    if ($stop) { Set-Prog $Progress -Text (T 'prog.cancelled') } else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
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

function Invoke-DismComponentCleanup {
    <# DISM /StartComponentCleanup. With a progress table the output is redirected to a file and polled so the
       "[==== 45.0% ====]" percentages can be shown. Cancel/pause are NOT offered here (interrupting servicing is unsafe). #>
    param([hashtable]$Progress = $null, $Ctx = $null)
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $dargs = '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart'
    if ($null -eq $Progress) {
        $p = Start-Process -FilePath $dism -ArgumentList $dargs -Wait -PassThru -WindowStyle Hidden
        return $p.ExitCode
    }
    Set-Prog $Progress -Percent -1 -Text (T 'prog.dismCleanup') -CanCancel $false -CanPause $false -Phase 'clean'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('uc-dism-{0}.out' -f [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath $dism -ArgumentList $dargs -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmp
        $null = $p.Handle
        while (-not $p.WaitForExit(500)) {
            $txt = ''
            try {
                $fs = [IO.File]::Open($tmp, 'Open', 'Read', 'ReadWrite')
                try { $buf = New-Object byte[] $fs.Length; $n = $fs.Read($buf, 0, $buf.Length); $txt = [Text.Encoding]::Default.GetString($buf, 0, $n) } finally { $fs.Dispose() }
            } catch { }
            $pct = ConvertFrom-DismProgress $txt
            if ($null -ne $pct -and $Ctx -and $Ctx.Total -gt 0) {
                $all = [double]$Ctx.Floor + (100.0 - [double]$Ctx.Floor) * ([double]$Ctx.Base + [double]$Ctx.CurW * $pct / 100.0) / [double]$Ctx.Total
                Set-Prog $Progress -Percent ([Math]::Min(99.9, $all)) -Text (T 'prog.dismCleanupPct' @([Math]::Round($pct)))
            } elseif ($null -ne $pct) {
                Set-Prog $Progress -Percent $pct -Text (T 'prog.dismCleanupPct' @([Math]::Round($pct)))
            }
        }
        $p.WaitForExit()
        return $p.ExitCode
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Invoke-OneCleanup {
    param([string]$Id, [switch]$DryRun, [hashtable]$Progress = $null, $Ctx = $null)
    $admin = Test-IsAdmin
    $m = $script:CategoryMeta[$Id]
    if ($m.Admin -and -not $admin) { return (New-CleanupResult $Id 'Skipped' 0 'needs-admin') }

    if ($Id -eq 'recyclebin') {
        $info = Get-RecycleBinInfo
        if ($info.Count -eq 0) { return (New-CleanupResult $Id 'Cleaned' 0 'nothing-to-clean') }
        if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' $info.Size "items=$($info.Count)") }
        # Emptying the bin is one atomic shell call: no percent, no cancel, no pause.
        Set-Prog $Progress -Percent -1 -Text (T 'prog.recycle') -CanCancel $false -CanPause $false
        Clear-RecycleBin -Force -ErrorAction Stop
        return (New-CleanupResult $Id 'Cleaned' $info.Size "items=$($info.Count)")
    }

    if ($Id -eq 'components') {
        if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' 0 'dism-startcomponentcleanup') }
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        $before = $drive.AvailableFreeSpace
        $exit = Invoke-DismComponentCleanup -Progress $Progress -Ctx $Ctx
        if ($exit -ne 0 -and $exit -ne 3010) { return (New-CleanupResult $Id 'Failed' 0 "dism-exit=$exit") }
        $gain = [Math]::Max([long]0, [long]($drive.AvailableFreeSpace - $before))
        $msg = if ($exit -eq 3010) { 'reboot-required' } else { 'ok' }
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
        $freed = [long]0; $files = 0; $locked = 0; $cancelled = $false
        foreach ($tg in $targets) {
            $found = $null
            if ($Ctx -and $Ctx.Plan.ContainsKey($Id) -and $Ctx.Plan[$Id].Found.ContainsKey($tg.Root)) { $found = $Ctx.Plan[$Id].Found[$tg.Root] }
            $r = Clear-CleanupFolder -Root $tg.Root -MinAgeDays $tg.MinAgeDays -NameRegex $tg.NameRegex -NoRecurse:$tg.NoRecurse -DryRun:$DryRun -Found $found -Progress $Progress -Ctx $Ctx
            $freed += $r.Freed; $files += $r.Files; $locked += $r.Locked
            if ($r.Cancelled) { $cancelled = $true; break }
        }
        [pscustomobject]@{ Freed = $freed; Files = $files; Locked = $locked; Cancelled = $cancelled }
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
    if ($res.Cancelled) { return (New-CleanupResult $Id 'Cancelled' $res.Freed 'prog.cancelled') }
    if ($DryRun) { return (New-CleanupResult $Id 'WouldClean' $res.Freed $msg) }
    $status = if ($res.Locked -gt 0 -or $skipNote) { 'Partial' } else { 'Cleaned' }
    return (New-CleanupResult $Id $status $res.Freed $msg)
}

function New-CleanupContext {
    <# Analysis pass for a run with progress: enumerates the targets once (reused for deletion) and derives the
       per-category weights (bytes). Returns the context, or $null when cancelled during the pass. #>
    param([string[]]$Ids, [hashtable]$Progress)
    $admin = Test-IsAdmin
    $running = @(Get-RunningBrowserProcs)
    $plan = @{}
    $valid = @($Ids | Where-Object { $script:CategoryMeta.Contains($_) })
    $i = 0
    Set-Prog $Progress -Percent 0 -Text (T 'prog.analyzingStart') -CanCancel $true -CanPause $true -Phase 'scan'
    foreach ($id in $valid) {
        if (Wait-ProgPause $Progress) { return $null }
        Set-Prog $Progress -Percent (10.0 * $i / [Math]::Max(1, $valid.Count)) -Text (T 'prog.analyzing' @((T ('cl.' + $id))))
        $i++
        $w = [double]1; $found = @{}
        try {
            if ($id -eq 'recyclebin') {
                $w = [double][Math]::Max(1, (Get-RecycleBinInfo).Size)
            } elseif ($id -eq 'components') {
                $w = -1   # resolved below
            } elseif (-not ($script:CategoryMeta[$id].Admin -and -not $admin)) {
                $bytes = [double]0
                foreach ($tg in @(Get-CleanupTargets -Id $id)) {
                    if ($id -eq 'browsercache' -and $running -contains $tg.Proc) { continue }
                    $f = Get-CleanupFiles -Root $tg.Root -MinAgeDays $tg.MinAgeDays -NameRegex $tg.NameRegex -NoRecurse:$tg.NoRecurse -Progress $Progress
                    if ($f.Cancelled) { return $null }
                    $found[$tg.Root] = $f
                    foreach ($fi in $f.Files) { $bytes += $fi.Length }
                }
                $w = [Math]::Max(1, $bytes)
            }
        } catch { Write-Log -Level WARN -Message "Cleanup plan '$id' failed: $($_.Exception.Message)" }
        $plan[$id] = @{ Weight = $w; Found = $found }
    }
    $sum = [double]0
    foreach ($k in @($plan.Keys)) { if ($plan[$k].Weight -gt 0) { $sum += $plan[$k].Weight } }
    if ($plan.ContainsKey('components')) { $plan['components'].Weight = [Math]::Max(1MB, $sum * 0.1) }
    $total = [double]0
    foreach ($k in @($plan.Keys)) { $total += $plan[$k].Weight }
    return @{ Plan = $plan; Total = $total; Base = [double]0; CurW = [double]1; CatDone = [double]0; Freed = [long]0; Cat = ''; Floor = [double]10
              Sw = [Diagnostics.Stopwatch]::StartNew(); Last = [long]0 }
}

function Invoke-Cleanup {
    param([Parameter(Mandatory)][string[]]$Ids, [switch]$DryRun, [hashtable]$Progress = $null)
    $out = New-Object System.Collections.Generic.List[object]
    $ctx = $null; $cancelled = $false
    if ($Progress) {
        $ctx = New-CleanupContext -Ids @($Ids) -Progress $Progress
        if ($null -eq $ctx) { $cancelled = $true }
    }
    foreach ($id in @($Ids)) {
        if (-not $script:CategoryMeta.Contains($id)) { $out.Add((New-CleanupResult $id 'Skipped' 0 'unknown-id')); continue }
        if ($Progress -and -not $cancelled -and (Wait-ProgPause $Progress)) { $cancelled = $true }
        if ($cancelled) { $out.Add((New-CleanupResult $id 'Cancelled' 0 'prog.cancelled')); continue }
        if ($ctx) {
            $ctx.Cat = $id; $ctx.CurW = [double]$ctx.Plan[$id].Weight; $ctx.CatDone = [double]0
            Set-Prog $Progress -CanCancel $true -CanPause $true -Phase 'clean'
            Write-CleanupProgress $Progress $ctx
        }
        Add-ProgLog $Progress 'log.cl.start' @((T ('cl.' + $id)))
        try {
            $r = Invoke-OneCleanup -Id $id -DryRun:$DryRun -Progress $Progress -Ctx $ctx
            Write-Log -Level INFO -Message "Cleanup $id : $($r.Status) freed=$($r.FreedBytes) $($r.Message)"
            Write-CleanupResultLog $Progress $r
            $out.Add($r)
            if ($r.Status -eq 'Cancelled') { $cancelled = $true }
        } catch {
            Write-Log -Level ERROR -Message "Cleanup $id failed: $($_.Exception.Message)"
            $fr = New-CleanupResult $id 'Failed' 0 $_.Exception.Message
            Write-CleanupResultLog $Progress $fr
            $out.Add($fr)
        }
        if ($ctx) { $ctx.Base += $ctx.CurW }
    }
    if ($Progress) {
        $sum = [double]0
        foreach ($o in $out) { if ($o.Status -in 'Cleaned', 'Partial', 'WouldClean') { $sum += [double]$o.FreedBytes } }
        Add-ProgLog $Progress $(if ($cancelled) { 'log.cl.doneCancelled' } else { 'log.cl.done' }) @((Format-ProgBytes $sum))
        Set-Prog $Progress -CanCancel $false -CanPause $false
        if ($cancelled) { Set-Prog $Progress -Text (T 'prog.cancelled') }
        else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
    }
    return $out.ToArray()
}

Export-ModuleMember -Function Get-CleanupCategories, Invoke-Cleanup, Test-CleanupPath, Clear-CleanupFolder, ConvertFrom-DismProgress
