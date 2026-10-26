# Update Center - security check and scans using Windows' own tools
# (Microsoft Defender, Malicious Software Removal Tool, sfc, DISM).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Providers.psm1') -DisableNameChecking

# ---------------------------------------------------------------- progress helpers
# Contract: caller passes a synchronized hashtable. We write Percent (0..100, -1 = indeterminate), Text, CanCancel,
# CanPause, Phase and Estimated ($true = Percent is a time-based estimate, not measured; the GUI labels it);
# we read Cancel and Pause. Optional key Log: a synchronized ArrayList that receives short localized log lines
# ("HH:mm:ss  text", capped at 500 lines) via Add-ProgLog. $null = no progress, behave as before.
function Set-Prog {
    param($Progress, $Percent = $null, $Text = $null, $CanCancel = $null, $CanPause = $null, $Phase = $null, $Estimated = $null)
    if ($null -eq $Progress) { return }
    try {
        if ($null -ne $Estimated) { $Progress['Estimated'] = [bool]$Estimated }
        if ($null -ne $Percent) { $Progress['Percent'] = [double]$Percent }
        if ($null -ne $Text) { $Progress['Text'] = [string]$Text }
        if ($null -ne $CanCancel) { $Progress['CanCancel'] = [bool]$CanCancel }
        if ($null -ne $CanPause) { $Progress['CanPause'] = [bool]$CanPause }
        if ($null -ne $Phase) { $Progress['Phase'] = [string]$Phase }
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

function Format-Elapsed {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Stop-ProcessTree {
    <# Kills a process and its children (taskkill /T), falls back to Process.Kill(). #>
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $tk = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
            if (Test-Path -LiteralPath $tk) {
                $null = Start-Process -FilePath $tk -ArgumentList @('/PID', [string]$Process.Id, '/T', '/F') -WindowStyle Hidden -Wait -PassThru
            }
        }
    } catch { }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Wait-ScanProcess {
    <# Polls a started process every 500 ms. OnTick gets the elapsed TimeSpan; OnCancel is run once when Cancel is
       seen (only if AllowCancel). Returns Cancelled / TimedOut / ExitCode. #>
    param([Parameter(Mandatory)]$Process, $Progress = $null, [bool]$AllowCancel = $true, [int]$TimeoutMinutes = 90,
          [scriptblock]$OnTick = $null, [scriptblock]$OnCancel = $null)
    $null = $Process.Handle
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cancelled = $false; $timedOut = $false
    while (-not $Process.WaitForExit(500)) {
        if ($AllowCancel -and (Test-ProgCancel $Progress)) {
            $cancelled = $true
            Set-Prog $Progress -Text (T 'prog.cancelling') -CanCancel $false
            if ($OnCancel) { try { & $OnCancel } catch { } }
            if (-not $Process.WaitForExit(30000)) { Stop-ProcessTree $Process }
            break
        }
        if ($clock.Elapsed.TotalMinutes -ge $TimeoutMinutes) { $timedOut = $true; Stop-ProcessTree $Process; break }
        if ($OnTick) { try { & $OnTick $clock.Elapsed } catch { } }
    }
    $code = -999
    try { $Process.WaitForExit(); if (-not $timedOut) { $code = $Process.ExitCode } } catch { }
    [pscustomobject]@{ Cancelled = $cancelled; TimedOut = $timedOut; ExitCode = $code }
}

function Read-SharedFileBytes {
    # Reads a file another process is still writing.
    param([string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $buf = New-Object byte[] $fs.Length; $n = $fs.Read($buf, 0, $buf.Length); if ($n -lt $buf.Length) { $b2 = New-Object byte[] $n; if ($n -gt 0) { [Array]::Copy($buf, $b2, $n) }; return $b2 }; return $buf }
        finally { $fs.Dispose() }
    } catch { return (New-Object byte[] 0) }
}

$script:ProgLogMax = 500

function Add-ProgLog {
    <# Appends "HH:mm:ss  <T key args>" to $Progress['Log'] (if the caller supplied one) and trims it to 500 lines.
       Never throws: a logging problem must not break a scan. #>
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

function Format-Remaining {
    <# Approximate remaining time for people: "3 min", "1 h 20 min" (rounded up, at least 1 min). #>
    param([double]$Seconds)
    $m = [int][Math]::Max(1, [Math]::Ceiling($Seconds / 60.0))
    if ($m -ge 60) { return ('{0} h {1:00} min' -f [int][Math]::Floor($m / 60), ($m % 60)) }
    return ('{0} min' -f $m)
}

# ---------------------------------------------------------------- time based estimate (Defender / MRT)
$script:DefaultScanSeconds = @{ Quick = 240; Full = 3600; Mrt = 300; MrtFull = 1800; Integrity = 900 }

function Get-ScanDurationsPath {
    return (Join-Path (Get-AppPaths).StateDir 'scan-durations.json')
}

function Read-ScanDurations {
    <# Type -> seconds of the last successful scan of that type (hashtable, empty if no/broken file). Never throws. #>
    $out = @{}
    try {
        $p = Get-ScanDurationsPath
        if (-not (Test-Path -LiteralPath $p)) { return $out }
        $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $o.PSObject.Properties) {
            $v = 0.0
            if ([double]::TryParse([string]$prop.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0 -and $v -lt 1e7) { $out[[string]$prop.Name] = $v }
        }
    } catch { }
    return $out
}

function Save-ScanDuration {
    <# Remembers the duration of a successful scan: <StateDir>\scan-durations.json {"Quick": 231.4, ...}.
       Returns $true when written. Never throws. #>
    param([Parameter(Mandatory)][string]$Type, [double]$Seconds)
    try {
        if ($Seconds -le 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return $false }
        $all = Read-ScanDurations
        $all[$Type] = [Math]::Round($Seconds, 1)
        $ord = [ordered]@{}
        foreach ($k in ($all.Keys | Sort-Object)) { $ord[$k] = $all[$k] }
        $p = Get-ScanDurationsPath
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($p, (($ord | ConvertTo-Json) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Get-ExpectedScanSeconds {
    <# Expected duration of a scan type. Order: our own history file, then (Quick/Full) Defender's last scan from
       Get-MpComputerStatus, then a fixed default (Quick 4 min, Full 60 min, ...). -MpSource is a hook for tests.
       Returns Seconds and Source (history | defender | default). Never throws. #>
    param([Parameter(Mandatory)][string]$Type, [scriptblock]$MpSource = $null)
    try {
        $h = Read-ScanDurations
        if ($h.ContainsKey($Type)) { return [pscustomobject]@{ Seconds = [double]$h[$Type]; Source = 'history' } }
        if ($Type -in 'Quick', 'Full') {
            $mp = $null
            try { $mp = if ($MpSource) { & $MpSource } else { Get-MpComputerStatus -ErrorAction Stop } } catch { }
            $pre = if ($Type -eq 'Full') { 'FullScan' } else { 'QuickScan' }
            $a = Get-SafeProp $mp ($pre + 'StartTime') $null
            $b = Get-SafeProp $mp ($pre + 'EndTime') $null
            if ($null -ne $a -and $null -ne $b) {
                $d = ([datetime]$b - [datetime]$a).TotalSeconds
                if ($d -ge 10 -and $d -le 86400) { return [pscustomobject]@{ Seconds = [double]$d; Source = 'defender' } }
            }
        }
    } catch { }
    $def = 600.0
    if ($script:DefaultScanSeconds.ContainsKey($Type)) { $def = [double]$script:DefaultScanSeconds[$Type] }
    return [pscustomobject]@{ Seconds = $def; Source = 'default' }
}

function Get-ScanEstimate {
    <# Percent = min(95, elapsed / expected * 100); remaining = expected - elapsed (floored at 0). Over = elapsed >= expected.
       Percent -1 when there is no usable expectation. #>
    param([double]$ElapsedSec, [double]$ExpectedSec)
    if ($ExpectedSec -le 0) { return [pscustomobject]@{ Percent = -1.0; RemainingSec = -1.0; Over = $false } }
    $pct = [Math]::Min(95.0, [Math]::Max(0.0, 100.0 * $ElapsedSec / $ExpectedSec))
    [pscustomobject]@{ Percent = $pct; RemainingSec = [Math]::Max(0.0, $ExpectedSec - $ElapsedSec); Over = ($ElapsedSec -ge $ExpectedSec) }
}

function Set-EstimatedProg {
    <# Writes Percent (estimate), Estimated = $true and "<TextKey elapsed> - remaining ca. x min". Never throws. #>
    param($Progress, [string]$TextKey, [double]$ElapsedSec, [double]$ExpectedSec)
    if ($null -eq $Progress) { return }
    try {
        $e = Get-ScanEstimate -ElapsedSec $ElapsedSec -ExpectedSec $ExpectedSec
        $text = T $TextKey @((Format-Elapsed ([TimeSpan]::FromSeconds($ElapsedSec))))
        if ($e.Percent -ge 0) {
            $tail = if ($e.Over) { T 'prog.estOver' } else { T 'prog.estRemain' @((Format-Remaining $e.RemainingSec)) }
            Set-Prog $Progress -Percent $e.Percent -Text ($text + ' ' + [char]0xB7 + ' ' + $tail) -Estimated $true
        } else {
            Set-Prog $Progress -Text $text
        }
    } catch { }
}

# ---------------------------------------------------------------- live log: Defender detections, periodic status
function Get-ActionKey {
    param($Id)
    switch ([int]$Id) {
        1 { return 'log.act.clean' }
        2 { return 'log.act.quarantine' }
        3 { return 'log.act.remove' }
        6 { return 'log.act.allow' }
        9 { return 'log.act.none' }
        10 { return 'log.act.block' }
        default { return 'log.act.other' }
    }
}

function Get-NewDefenderDetections {
    <# Detections that started at or after -Since and were not reported before (-Seen is updated in place).
       Hooks for tests: -DetectionSource / -ThreatSource scriptblocks replace Get-MpThreatDetection / Get-MpThreat.
       Returns objects with Name, Path, Action. Never throws (returns @() on any problem). #>
    param([datetime]$Since, [hashtable]$Seen, [scriptblock]$DetectionSource = $null, [scriptblock]$ThreatSource = $null)
    $out = @()
    try {
        $raw = if ($DetectionSource) { @(& $DetectionSource) } else { @(Get-MpThreatDetection -ErrorAction Stop) }
        $new = @()
        foreach ($d in $raw) {
            $t = Get-SafeProp $d 'InitialDetectionTime' $null
            if ($null -eq $t -or [datetime]$t -lt $Since) { continue }
            $res = @(Get-SafeProp $d 'Resources' @()) -join ';'
            $key = [string](Get-SafeProp $d 'DetectionID' ('{0}|{1:o}|{2}' -f (Get-SafeProp $d 'ThreatID' ''), [datetime]$t, $res))
            if ($Seen.ContainsKey($key)) { continue }
            $Seen[$key] = $true
            $new += $d
        }
        if ($new.Count -eq 0) { return @() }
        $names = @{}
        try {
            $thr = if ($ThreatSource) { @(& $ThreatSource) } else { @(Get-MpThreat -ErrorAction Stop) }
            foreach ($x in $thr) { $names[[string](Get-SafeProp $x 'ThreatID' '')] = [string](Get-SafeProp $x 'ThreatName' '') }
        } catch { }
        foreach ($d in $new) {
            $id = [string](Get-SafeProp $d 'ThreatID' '')
            $name = if ($names.ContainsKey($id) -and $names[$id]) { $names[$id] } else { 'Threat ' + $id }
            $paths = @(@(Get-SafeProp $d 'Resources' @()) | ForEach-Object { ([string]$_) -replace '^(file|folder|process|regkey|containerfile|webfile):_?', '' } | Select-Object -First 3)
            $path = ($paths -join '; ')
            if ($path.Length -gt 200) { $path = $path.Substring(0, 197) + '...' }
            if (-not $path) { $path = '?' }
            $out += [pscustomobject]@{ Name = $name; Path = $path; Action = (T (Get-ActionKey (Get-SafeProp $d 'CleaningActionID' 0))) }
        }
    } catch { return @() }
    return $out
}

function New-ScanWatch {
    param([datetime]$Since, [double]$ExpectedSec)
    return @{ Since = $Since; Seen = @{}; NextPoll = 5.0; NextTick = 30.0; Expected = $ExpectedSec; Found = 0 }
}

function Step-ScanWatch {
    <# Called on every tick of a running scan (-ElapsedSec is injectable for tests).
       Every 5 s (only with -Detections): poll Defender for new detections. Every 30 s: log elapsed + estimate. Never throws. #>
    param($Progress, [hashtable]$State, [double]$ElapsedSec, [switch]$Detections, [scriptblock]$DetectionSource = $null, [scriptblock]$ThreatSource = $null)
    try {
        if ($Detections -and $ElapsedSec -ge $State.NextPoll) {
            $State.NextPoll = $ElapsedSec + 5.0
            foreach ($f in @(Get-NewDefenderDetections -Since $State.Since -Seen $State.Seen -DetectionSource $DetectionSource -ThreatSource $ThreatSource)) {
                $State.Found++
                Add-ProgLog $Progress 'log.def.found' @($f.Name, $f.Path, $f.Action)
            }
        }
        if ($ElapsedSec -ge $State.NextTick) {
            $State.NextTick = $ElapsedSec + 30.0
            $el = Format-Elapsed ([TimeSpan]::FromSeconds($ElapsedSec))
            $e = Get-ScanEstimate -ElapsedSec $ElapsedSec -ExpectedSec $State.Expected
            if ($e.Percent -lt 0) { Add-ProgLog $Progress 'log.scan.tickNoEst' @($el) }
            elseif ($e.Over) { Add-ProgLog $Progress 'log.scan.tickOver' @($el, (Format-Remaining $State.Expected)) }
            else { Add-ProgLog $Progress 'log.scan.tick' @($el, (Format-Remaining $State.Expected), (Format-Remaining $e.RemainingSec)) }
        }
    } catch { }
}

function Add-PctStepLog {
    <# Logs 10 % steps ("sfc 30 %") once each; State.Last = highest step already logged. Never throws. #>
    param($Progress, [hashtable]$State, [double]$Pct, [string]$Label)
    try {
        $step = [int]([Math]::Floor($Pct / 10.0) * 10)
        if ($step -gt $State.Last) {
            $State.Last = $step
            Add-ProgLog $Progress 'log.int.step' @($Label, $step)
        }
    } catch { }
}

# ---------------------------------------------------------------- small helpers
function Get-SafeProp {
    # StrictMode-safe property read (CIM / cmdlet objects differ between Windows builds).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function New-Check {
    param([string]$Id, [string]$State, [string]$Detail, [string]$FixUri = '')
    [pscustomobject]@{ Id = $Id; State = $State; Detail = $Detail; FixUri = $FixUri }
}

function Invoke-Check {
    # Runs one check; any exception becomes State 'Unknown' (missing cmdlet on Home, no admin, ...).
    param([string]$Id, [scriptblock]$Body, [string]$FixUri = '')
    $sp = $script:SecProg
    if ($sp) {
        if (-not $script:SecCancelled -and (Wait-ProgPause $sp)) { $script:SecCancelled = $true }
        if ($script:SecCancelled) { return (New-Check $Id 'Unknown' (T 'prog.cancelled') $FixUri) }
        Set-Prog $sp -Percent ([Math]::Min(99.0, 100.0 * $script:SecDone / $script:SecTotal)) -Text (T 'prog.secCheck' @(($script:SecDone + 1), $script:SecTotal))
        $script:SecDone++
    }
    try {
        $r = & $Body
        if ($null -eq $r) { return (New-Check $Id 'Unknown' (T 'sec.detail.noData') $FixUri) }
        return $r
    } catch {
        $msg = ($_.Exception.Message -split "`r?`n")[0]
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
        return (New-Check $Id 'Unknown' (T 'sec.detail.notAvailable' @($msg)) $FixUri)
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $Default }
}

function Get-MrtPath {
    <# Path of the Malicious Software Removal Tool (delivered monthly via Windows Update), or $null. #>
    $p = Join-Path ([Environment]::GetFolderPath('System')) 'MRT.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-MrtLogPath { Join-Path $env:SystemRoot 'debug\mrt.log' }

function Get-ThirdPartyAntivirus {
    <# Active non-Microsoft antivirus products from the Security Center (root\SecurityCenter2).
       productState bit 0x1000 = product enabled (on). Returns an array of product names. #>
    $names = @()
    try {
        foreach ($av in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $name = [string](Get-SafeProp $av 'displayName' '')
            $state = [int64](Get-SafeProp $av 'productState' 0)
            if ($name -and $name -notmatch '(?i)windows defender|microsoft defender' -and (($state -band 0x1000) -ne 0)) { $names += $name }
        }
    } catch { }
    return @($names)
}

function Get-DefenderStatus {
    try { return (Get-MpComputerStatus -ErrorAction Stop) } catch { return $null }
}

function Test-DefenderPassive {
    <# True when another antivirus is active, so Defender runs passive (no own scans useful). #>
    $third = @(Get-ThirdPartyAntivirus)
    if ($third.Count -gt 0) { return $true }
    $mp = Get-DefenderStatus
    $mode = [string](Get-SafeProp $mp 'AMRunningMode' '')
    return ($mode -match '(?i)passive')
}

function Format-Age {
    param($Days)
    if ($null -eq $Days) { return (T 'sec.detail.ageUnknown') }
    $d = [int64]$Days
    if ($d -ge 4294967295 -or $d -lt 0) { return (T 'sec.detail.ageNever') }
    if ($d -eq 0) { return (T 'sec.detail.ageToday') }
    if ($d -eq 1) { return (T 'sec.detail.ageOne') }
    return (T 'sec.detail.ageDays' @($d))
}

# ---------------------------------------------------------------- status checks
$script:SecProg = $null; $script:SecCancelled = $false; $script:SecDone = 0; $script:SecTotal = 16

function Get-SecurityStatus {
    <# Read-only snapshot of the security posture. Finishes in a few seconds; never throws.
       Optional -Progress: percent by check count (16), cancel/pause between checks (remaining checks come back
       as Unknown with the cancelled text). #>
    param([hashtable]$Progress = $null)
    $script:SecProg = $Progress; $script:SecCancelled = $false; $script:SecDone = 0
    Set-Prog $Progress -Percent 0 -Text (T 'prog.secStart') -CanCancel $true -CanPause $true -Phase 'status'
    try { $res = @(Get-SecurityStatusCore) } finally { $script:SecProg = $null }
    if ($Progress) {
        Set-Prog $Progress -CanCancel $false -CanPause $false
        if ($script:SecCancelled) { Set-Prog $Progress -Text (T 'prog.cancelled') } else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
    }
    return $res
}

function Get-SecurityStatusCore {
    $mp = Get-DefenderStatus
    $pref = $null
    try { $pref = Get-MpPreference -ErrorAction Stop } catch { }
    $third = @(Get-ThirdPartyAntivirus)
    $passive = (@($third).Count -gt 0) -or ([string](Get-SafeProp $mp 'AMRunningMode' '') -match '(?i)passive')
    $results = New-Object System.Collections.Generic.List[object]

    $results.Add((Invoke-Check 'antivirus' {
        $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
        $active = @()
        foreach ($av in $products) {
            $state = [int64](Get-SafeProp $av 'productState' 0)
            if (($state -band 0x1000) -ne 0) { $active += [string](Get-SafeProp $av 'displayName' '?') }
        }
        if ($active.Count -gt 0) { return (New-Check 'antivirus' 'Ok' (T 'sec.detail.avActive' @(($active -join ', '))) '') }
        if ($products.Count -gt 0) { return (New-Check 'antivirus' 'Critical' (T 'sec.detail.avOff') 'windowsdefender://threat') }
        return (New-Check 'antivirus' 'Critical' (T 'sec.detail.avNone') 'windowsdefender://threat')
    } 'windowsdefender://threat'))

    $results.Add((Invoke-Check 'realtime' {
        if ($passive -and $third.Count -gt 0) { return (New-Check 'realtime' 'Ok' (T 'sec.detail.rtThird' @(($third -join ', '))) '') }
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        if ([bool](Get-SafeProp $mp 'RealTimeProtectionEnabled' $false)) { return (New-Check 'realtime' 'Ok' (T 'sec.detail.rtOn') '') }
        return (New-Check 'realtime' 'Critical' (T 'sec.detail.rtOff') 'windowsdefender://threatsettings')
    } 'windowsdefender://threatsettings'))

    $results.Add((Invoke-Check 'signatures' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        $age = [int64](Get-SafeProp $mp 'AntivirusSignatureAge' 4294967295)
        $ver = [string](Get-SafeProp $mp 'AntivirusSignatureVersion' '')
        if ($age -ge 4294967295) { return (New-Check 'signatures' 'Warning' (T 'sec.detail.sigUnknown') 'ms-settings:windowsupdate') }
        $detail = (T 'sec.detail.sigAge' @($age)) + $(if ($ver) { " (v$ver)" } else { '' })
        $state = if ($age -le 3) { 'Ok' } elseif ($age -le 7) { 'Warning' } else { 'Critical' }
        if ($passive -and $state -eq 'Critical') { $state = 'Warning'; $detail += (T 'sec.detail.sigPassive') }
        return (New-Check 'signatures' $state $detail $(if ($state -eq 'Ok') { '' } else { 'ms-settings:windowsupdate' }))
    } 'ms-settings:windowsupdate'))

    $results.Add((Invoke-Check 'tamper' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        if ($null -eq $mp.PSObject.Properties['IsTamperProtected']) { return (New-Check 'tamper' 'Unknown' (T 'sec.detail.tamperNA') '') }
        if ([bool]$mp.IsTamperProtected) { return (New-Check 'tamper' 'Ok' (T 'sec.detail.tamperOn') '') }
        return (New-Check 'tamper' 'Warning' (T 'sec.detail.tamperOff') 'windowsdefender://threatsettings')
    } 'windowsdefender://threatsettings'))

    $results.Add((Invoke-Check 'firewall' {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $on = @($profiles | Where-Object { [string]$_.Enabled -eq 'True' })
        $off = @($profiles | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })
        if ($profiles.Count -gt 0 -and $off.Count -eq 0) { return (New-Check 'firewall' 'Ok' (T 'sec.detail.fwOn') '') }
        if ($on.Count -eq 0) { return (New-Check 'firewall' 'Critical' (T 'sec.detail.fwOff') 'windowsdefender://network') }
        return (New-Check 'firewall' 'Warning' (T 'sec.detail.fwPartial' @(($off -join ', '))) 'windowsdefender://network')
    } 'windowsdefender://network'))

    $results.Add((Invoke-Check 'uac' {
        $v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
        if ($null -eq $v) { return (New-Check 'uac' 'Unknown' (T 'sec.detail.notReadable') '') }
        if ([int]$v -eq 1) { return (New-Check 'uac' 'Ok' (T 'sec.detail.uacOn') '') }
        return (New-Check 'uac' 'Critical' (T 'sec.detail.uacOff') '')
    }))

    $results.Add((Invoke-Check 'secureboot' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        if ($null -ne $v) {
            if ([int]$v -eq 1) { return (New-Check 'secureboot' 'Ok' (T 'sec.detail.sbOn') '') }
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbOff') '')
        }
        try {
            if (Confirm-SecureBootUEFI -ErrorAction Stop) { return (New-Check 'secureboot' 'Ok' (T 'sec.detail.sbOn') '') }
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbOff') '')
        } catch {
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbLegacy') '')
        }
    }))

    $results.Add((Invoke-Check 'tpm' {
        $t = Get-Tpm -ErrorAction Stop
        if (-not [bool](Get-SafeProp $t 'TpmPresent' $false)) {
            if (-not (Test-IsAdmin)) { return (New-Check 'tpm' 'Unknown' (T 'sec.detail.tpmAdmin') '') }
            return (New-Check 'tpm' 'Warning' (T 'sec.detail.tpmNone') '')
        }
        if ([bool](Get-SafeProp $t 'TpmReady' $false)) { return (New-Check 'tpm' 'Ok' (T 'sec.detail.tpmReady') '') }
        return (New-Check 'tpm' 'Warning' (T 'sec.detail.tpmNotReady') 'windowsdefender://devicesecurity')
    } 'windowsdefender://devicesecurity'))

    $results.Add((Invoke-Check 'bitlocker' {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return (New-Check 'bitlocker' 'Unknown' (T 'sec.detail.blNA') '') }
        $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $prot = [string](Get-SafeProp $vol 'ProtectionStatus' '')
        $pct = Get-SafeProp $vol 'EncryptionPercentage' 0
        if ($prot -eq 'On' -or $prot -eq '1') { return (New-Check 'bitlocker' 'Ok' (T 'sec.detail.blOn' @($pct)) '') }
        return (New-Check 'bitlocker' 'Warning' (T 'sec.detail.blOff') 'ms-settings:deviceencryption')
    } 'ms-settings:deviceencryption'))

    $results.Add((Invoke-Check 'smartscreen' {
        $pol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
        $v = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' '')
        if ($null -ne $pol -and [int]$pol -eq 0) { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssPolicy') 'windowsdefender://smartscreenpua') }
        if ($v -eq 'Off') { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssOff') 'windowsdefender://smartscreenpua') }
        $app = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation'
        if ($null -ne $app -and [int]$app -eq 0) { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssAppOff') 'windowsdefender://smartscreenpua') }
        if ($v -eq '') { return (New-Check 'smartscreen' 'Ok' (T 'sec.detail.ssDefault') '') }
        return (New-Check 'smartscreen' 'Ok' (T 'sec.detail.ssOn' @($v)) '')
    } 'windowsdefender://smartscreenpua'))

    $results.Add((Invoke-Check 'hvci' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
        if ($null -ne $v -and [int]$v -eq 1) { return (New-Check 'hvci' 'Ok' (T 'sec.detail.hvciOn') '') }
        return (New-Check 'hvci' 'Warning' (T 'sec.detail.hvciOff') 'windowsdefender://coreisolation')
    } 'windowsdefender://coreisolation'))

    $results.Add((Invoke-Check 'smb1' {
        $enabled = $null
        if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
            try { $enabled = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch { }
        }
        if ($null -eq $enabled) {
            $reg = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'
            if ($null -ne $reg) { $enabled = ([int]$reg -ne 0) }
        }
        if ($null -eq $enabled) { return (New-Check 'smb1' 'Unknown' (T 'sec.detail.smbNR') '') }
        if ($enabled) { return (New-Check 'smb1' 'Critical' (T 'sec.detail.smbOn') '') }
        return (New-Check 'smb1' 'Ok' (T 'sec.detail.smbOff') '')
    }))

    $results.Add((Invoke-Check 'rdp' {
        $deny = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
        if ($null -eq $deny) { return (New-Check 'rdp' 'Unknown' (T 'sec.detail.notReadable') '') }
        if ([int]$deny -ne 0) { return (New-Check 'rdp' 'Ok' (T 'sec.detail.rdpOff') '') }
        $nla = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
        if ($null -ne $nla -and [int]$nla -eq 1) { return (New-Check 'rdp' 'Warning' (T 'sec.detail.rdpNla') 'ms-settings:remotedesktop') }
        return (New-Check 'rdp' 'Critical' (T 'sec.detail.rdpOpen') 'ms-settings:remotedesktop')
    } 'ms-settings:remotedesktop'))

    $results.Add((Invoke-Check 'pua' {
        if ($null -eq $pref) { throw 'Defender preferences unavailable' }
        $v = [int](Get-SafeProp $pref 'PUAProtection' 0)
        if ($v -eq 1) { return (New-Check 'pua' 'Ok' (T 'sec.detail.puaOn') '') }
        if ($v -eq 2) { return (New-Check 'pua' 'Warning' (T 'sec.detail.puaAudit') 'windowsdefender://smartscreenpua') }
        return (New-Check 'pua' 'Warning' (T 'sec.detail.puaOff') 'windowsdefender://smartscreenpua')
    } 'windowsdefender://smartscreenpua'))

    $results.Add((Invoke-Check 'lastscan' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        $q = [int64](Get-SafeProp $mp 'QuickScanAge' 4294967295)
        $f = [int64](Get-SafeProp $mp 'FullScanAge' 4294967295)
        $best = [Math]::Min($q, $f)
        $detail = (T 'sec.detail.lastScan' @((Format-Age $q), (Format-Age $f)))
        if ($best -le 7) { return (New-Check 'lastscan' 'Ok' $detail '') }
        if ($best -le 30) { return (New-Check 'lastscan' 'Warning' $detail 'windowsdefender://threat') }
        return (New-Check 'lastscan' 'Warning' $detail 'windowsdefender://threat')
    } 'windowsdefender://threat'))

    $results.Add((Invoke-Check 'updates' {
        $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        $last = $null
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = [int]$searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($e in @($searcher.QueryHistory(0, [Math]::Min($count, 40)))) {
                # Operation 1 = installation, ResultCode 2 = succeeded
                if ([int]$e.Operation -eq 1 -and [int]$e.ResultCode -eq 2) {
                    if ($null -eq $last -or $e.Date -gt $last) { $last = [datetime]$e.Date }
                }
            }
        }
        $detail = if ($last) { (T 'sec.detail.updLast' @($last.ToString('yyyy-MM-dd'))) } else { (T 'sec.detail.updNone') }
        if ($reboot) { return (New-Check 'updates' 'Warning' ($detail + (T 'sec.detail.updReboot')) 'ms-settings:windowsupdate') }
        if (-not $last) { return (New-Check 'updates' 'Warning' $detail 'ms-settings:windowsupdate') }
        $age = ((Get-Date) - $last).TotalDays
        if ($age -gt 90) { return (New-Check 'updates' 'Critical' $detail 'ms-settings:windowsupdate') }
        if ($age -gt 45) { return (New-Check 'updates' 'Warning' $detail 'ms-settings:windowsupdate') }
        return (New-Check 'updates' 'Ok' $detail '')
    } 'ms-settings:windowsupdate'))

    return $results.ToArray()
}

# ---------------------------------------------------------------- threat history
function Get-ThreatHistory {
    <# Defender detections of the last 30 days. #>
    $out = New-Object System.Collections.Generic.List[object]
    try {
        $names = @{}
        try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $names[[string]$t.ThreatID] = $t } } catch { }
        $limit = (Get-Date).AddDays(-30)
        $sev = @{ 0 = 'Unknown'; 1 = 'Low'; 2 = 'Moderate'; 4 = 'High'; 5 = 'Severe' }
        $act = @{ 1 = 'Cleaned'; 2 = 'Quarantined'; 3 = 'Removed'; 6 = 'Allowed'; 8 = 'User defined'; 9 = 'No action'; 10 = 'Blocked' }
        foreach ($d in @(Get-MpThreatDetection -ErrorAction Stop)) {
            $time = Get-SafeProp $d 'InitialDetectionTime' $null
            if ($null -eq $time -or [datetime]$time -lt $limit) { continue }
            $id = [string](Get-SafeProp $d 'ThreatID' '')
            $info = if ($names.ContainsKey($id)) { $names[$id] } else { $null }
            $name = [string](Get-SafeProp $info 'ThreatName' ('Threat ' + $id))
            $sid = [int](Get-SafeProp $info 'SeverityID' 0)
            $aid = [int](Get-SafeProp $d 'CleaningActionID' 0)
            $res = @(Get-SafeProp $d 'Resources' @())
            $path = if ($res.Count -gt 0) { ([string]$res[0]) -replace '^[A-Za-z]+:_', '' } else { '' }
            $out.Add([pscustomobject]@{
                Name     = $name
                Severity = $(if ($sev.ContainsKey($sid)) { $sev[$sid] } else { "$sid" })
                Time     = [datetime]$time
                Action   = $(if ($act.ContainsKey($aid)) { $act[$aid] } else { "$aid" })
                Path     = $path
            })
        }
    } catch {
        Write-Log -Level WARN -Message "Get-ThreatHistory failed: $($_.Exception.Message)"
    }
    return @($out.ToArray() | Sort-Object Time -Descending)
}

# ---------------------------------------------------------------- parsers
function ConvertFrom-MrtLog {
    <# Parses (the new part of) C:\Windows\debug\mrt.log. The format is not formally documented, so
       this is heuristic: "No infection found" = clean, otherwise malware family names such as
       Win32/Name or Trojan:Win32/Name are collected. "Return code: N" ends every run. #>
    param([AllowEmptyString()][string]$Text)
    $threats = New-Object System.Collections.Generic.List[string]
    $clean = $Text -match '(?i)no infection found'
    $code = $null
    $m = [regex]::Matches($Text, '(?i)return code:\s*(-?\d+)')
    if ($m.Count -gt 0) { $code = [int]$m[$m.Count - 1].Groups[1].Value }
    if (-not $clean) {
        $rx = '\b(?:Trojan|Backdoor|Worm|Virus|Ransom|PWS|HackTool|Exploit|Program|TrojanDownloader|TrojanDropper|TrojanSpy|Win32|Win64|Win95|Win16|DOS|VBS|JS)[:/][A-Za-z0-9_.!/:-]+'
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '(?i)(detected|found|infect|threat|malware)') {
                foreach ($mm in [regex]::Matches($line, $rx)) {
                    $v = $mm.Value.TrimEnd('.', ',', ':')
                    if (-not $threats.Contains($v)) { $threats.Add($v) }
                }
            }
        }
    }
    $removed = ($threats.Count -gt 0) -and ($Text -match '(?i)(successfully removed|removed|cleaned|disinfected)')
    $finished = $Text -match '(?i)finished on'
    $hasInfection = (-not $clean) -and ($threats.Count -gt 0 -or $Text -match '(?i)(infection|threat|malware)\s+(detected|found)|found\s+(infection|malware)')
    if ($hasInfection -and $threats.Count -eq 0) { $threats.Add('Unknown (see mrt.log)') }
    [pscustomobject]@{
        Clean      = [bool]($clean -and -not $hasInfection)
        Infected   = [bool]$hasInfection
        Removed    = [bool]$removed
        Threats    = $threats.ToArray()
        ReturnCode = $code
        Finished   = [bool]$finished
    }
}

function ConvertFrom-SfcOutput {
    <# Classifies `sfc /scannow` output (English and German wording; text is already NUL-stripped). #>
    param([AllowEmptyString()][string]$Text)
    $t = $Text -replace "`0", ''
    $state = 'Unknown'
    if ($t -match '(?i)unable to fix|could not perform the requested operation|nicht repariert werden|nicht alle|konnte.{0,40}nicht') { $state = 'Unfixed' }
    elseif ($t -match '(?i)successfully repaired|erfolgreich repariert') { $state = 'Repaired' }
    elseif ($t -match '(?i)did not find any integrity violations|keine Integrit.tsverletzung') { $state = 'Clean' }
    elseif ($t -match '(?i)pending system repair|restart.{0,30}pending|Neustart') { $state = 'PendingReboot' }
    return $state
}

function Read-ProcessText {
    <# Decodes raw console output that may be UTF-16 (sfc) or ANSI/UTF-8 (DISM, MRT). #>
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $hasNul = $false
    for ($i = 0; $i -lt [Math]::Min($Bytes.Length, 400); $i++) { if ($Bytes[$i] -eq 0) { $hasNul = $true; break } }
    if ($hasNul) { return ([Text.Encoding]::Unicode.GetString($Bytes) -replace "`0", '') }
    return [Text.Encoding]::Default.GetString($Bytes)
}

function Invoke-RawProcess {
    # Like Invoke-Process, but decodes UTF-16 output (needed for sfc.exe).
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMinutes = 90)
    $tmp = Join-Path (Get-AppPaths).CacheDir ("sec-{0}.out" -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmp
    $null = $p.Handle
    $finished = $p.WaitForExit($TimeoutMinutes * 60 * 1000)
    $code = -999
    if (-not $finished) { try { $p.Kill() } catch { } } else { $p.WaitForExit(); $code = $p.ExitCode }
    $text = ''
    if (Test-Path $tmp) {
        try { $text = Read-ProcessText ([IO.File]::ReadAllBytes($tmp)) } catch { }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $code; Output = [string]$text; TimedOut = (-not $finished) }
}

# ---------------------------------------------------------------- scans
function New-ScanResult {
    param([string]$Type, [string]$Status, [string[]]$Threats = @(), [string]$Message = '', [double]$DurationSec = 0)
    [pscustomobject]@{
        Type        = $Type
        Status      = $Status
        Threats     = @($Threats)
        Message     = $Message
        DurationSec = [Math]::Round($DurationSec, 1)
    }
}

function Get-MpCmdRunPath {
    <# MpCmdRun.exe (Defender command line tool) in Program Files, or $null. #>
    $p = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function ConvertFrom-SfcProgress {
    <# Last percentage of `sfc /scannow` output: "Verification 45% complete." (English) or the German
       "Ueberpruefung ... 45 % abgeschlossen" wording. Text may still contain NULs (UTF-16). Returns $null if none. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    $t = $Text -replace "`0", ''
    $m = [regex]::Matches($t, '(\d{1,3})\s*%')
    for ($i = $m.Count - 1; $i -ge 0; $i--) {
        $v = [int]$m[$i].Groups[1].Value
        if ($v -le 100) { return [double]$v }
    }
    return $null
}

function ConvertFrom-DismProgress {
    <# Last percentage in DISM output such as "[=====     45.0%     ]", or $null. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Matches($Text, '\[[= ]*(\d{1,3}(?:[.,]\d+)?)\s*%[= ]*\]')
    if ($m.Count -eq 0) { return $null }
    $v = [double]::Parse(($m[$m.Count - 1].Groups[1].Value -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    return [Math]::Min(100.0, [Math]::Max(0.0, $v))
}

function Invoke-ScanTool {
    <# Runs sfc.exe / Dism.exe hidden with output redirected to a file that is re-read every 500 ms (sfc writes UTF-16
       and uses carriage-return progress lines, so line-wise reading is not possible). Kind 'sfc' | 'dism' selects the
       percent parser. Without -Progress nothing is reported but the result is the same. #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [ValidateSet('sfc', 'dism')][string]$Kind = 'sfc',
          $Progress = $null, [bool]$AllowCancel = $true, [int]$TimeoutMinutes = 240, [string]$TextKey = '', [string]$TextKeyNoPct = '')
    $tmp = Join-Path (Get-AppPaths).CacheDir ("sec-{0}.out" -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmp
    $stepState = @{ Last = 0 }
    $stepLabel = if ($Kind -eq 'dism') { 'DISM' } else { 'sfc' }
    $w = Wait-ScanProcess -Process $p -Progress $Progress -AllowCancel $AllowCancel -TimeoutMinutes $TimeoutMinutes -OnTick {
        param($el)
        if ($null -eq $Progress) { return }
        $txt = Read-ProcessText (Read-SharedFileBytes $tmp)
        $pct = if ($Kind -eq 'dism') { ConvertFrom-DismProgress $txt } else { ConvertFrom-SfcProgress $txt }
        if ($null -ne $pct) {
            Set-Prog $Progress -Percent $pct -Text (T $TextKey @([int][Math]::Round($pct))) -Estimated $false
            Add-PctStepLog $Progress $stepState $pct $stepLabel
        }
        elseif ($TextKeyNoPct) { Set-Prog $Progress -Text (T $TextKeyNoPct @((Format-Elapsed $el))) }
    } -OnCancel { Stop-ProcessTree $p }
    $text = ''
    if (Test-Path -LiteralPath $tmp) {
        try { $text = Read-ProcessText ([IO.File]::ReadAllBytes($tmp)) } catch { }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $w.ExitCode; Output = [string]$text; TimedOut = $w.TimedOut; Cancelled = $w.Cancelled }
}

function Invoke-DefenderScan {
    param([string]$Type, $Progress = $null)
    $started = Get-Date
    $scanType = if ($Type -eq 'Full') { 'FullScan' } else { 'QuickScan' }
    $textKey = if ($Type -eq 'Full') { 'prog.scanFull' } else { 'prog.scanQuick' }
    Write-Log -Message "Defender $scanType starting"
    $mpcmd = Get-MpCmdRunPath
    $mpNow = $null
    try { $mpNow = Get-MpComputerStatus -ErrorAction Stop } catch { }
    $exp = Get-ExpectedScanSeconds -Type $Type -MpSource { $mpNow }
    $watch = New-ScanWatch -Since $started -ExpectedSec $exp.Seconds
    Add-ProgLog $Progress 'log.def.start' @((T "log.type.$Type"), [string](Get-SafeProp $mpNow 'AntivirusSignatureVersion' '?'), [string](Get-SafeProp $mpNow 'AMEngineVersion' '?'))
    if ($mpcmd) {
        # MpCmdRun runs as a process, so it can be cancelled with `MpCmdRun.exe -Cancel`. Defender reports no percent:
        # Percent is estimated from the previous duration of this scan type (Estimated = $true).
        Set-Prog $Progress -Percent 0 -Text (T $textKey @('00:00')) -CanCancel $true -CanPause $false -Phase 'defender' -Estimated $true
        $st = if ($Type -eq 'Full') { '2' } else { '1' }
        try {
            $proc = Start-Process -FilePath $mpcmd -ArgumentList @('-Scan', '-ScanType', $st) -PassThru -WindowStyle Hidden
        } catch {
            return (New-ScanResult $Type 'Failed' @() ("MpCmdRun failed to start: " + $_.Exception.Message) ((Get-Date) - $started).TotalSeconds)
        }
        $w = Wait-ScanProcess -Process $proc -Progress $Progress -AllowCancel $true -TimeoutMinutes 720 -OnTick {
            param($el)
            Set-EstimatedProg $Progress $textKey $el.TotalSeconds $exp.Seconds
            Step-ScanWatch $Progress $watch $el.TotalSeconds -Detections
        } -OnCancel {
            $null = Start-Process -FilePath $mpcmd -ArgumentList @('-Cancel') -WindowStyle Hidden -Wait -PassThru
        }
        $dur = ((Get-Date) - $started).TotalSeconds
        if ($w.Cancelled) { return (New-ScanResult $Type 'Cancelled' @() 'prog.cancelled' $dur) }
        if ($w.TimedOut) { return (New-ScanResult $Type 'Failed' @() 'timeout' $dur) }
        $exit = $w.ExitCode
    } else {
        Set-Prog $Progress -Percent -1 -Text (T $textKey @('00:00')) -CanCancel $false -CanPause $false -Phase 'defender' -Estimated $false
        $exit = 0
        try {
            Start-MpScan -ScanType $scanType -ErrorAction Stop
        } catch {
            return (New-ScanResult $Type 'Failed' @() ("Start-MpScan failed: " + $_.Exception.Message) ((Get-Date) - $started).TotalSeconds)
        }
    }
    $dur = ((Get-Date) - $started).TotalSeconds
    $threats = @()
    $active = $false
    try {
        $from = $started.AddSeconds(-5)
        $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $d = Get-SafeProp $_ 'InitialDetectionTime' $null; $null -ne $d -and [datetime]$d -ge $from })
        $info = @{}
        try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $info[[string]$t.ThreatID] = $t } } catch { }
        foreach ($d in $det) {
            $id = [string](Get-SafeProp $d 'ThreatID' '')
            $ti = if ($info.ContainsKey($id)) { $info[$id] } else { $null }
            $n = [string](Get-SafeProp $ti 'ThreatName' ('Threat ' + $id))
            if ($threats -notcontains $n) { $threats += $n }
            if ($null -ne $ti -and [bool](Get-SafeProp $ti 'IsActive' $false)) { $active = $true }
        }
    } catch { Write-Log -Level WARN -Message "Reading detections failed: $($_.Exception.Message)" }
    if ($threats.Count -eq 0) {
        # MpCmdRun reports scan errors through its exit code; only trust it when no detection explains it.
        if ($exit -ne 0) { return (New-ScanResult $Type 'Failed' @() ("MpCmdRun exit code " + $exit) $dur) }
        return (New-ScanResult $Type 'Clean' @() 'No threats found' $dur)
    }
    if ($active) { return (New-ScanResult $Type 'ThreatsFound' $threats 'Threats found, some still active - open Windows Security' $dur) }
    return (New-ScanResult $Type 'ThreatsRemoved' $threats 'Threats found and handled by Defender' $dur)
}

function Write-MrtLogLines {
    <# Copies the meaningful result lines of the new mrt.log part into the live log (max 12, 160 chars each). #>
    param($Progress, [AllowEmptyString()][string]$Text)
    if ($null -eq $Progress -or -not $Text) { return }
    try {
        $n = 0
        foreach ($line in ($Text -split "`r?`n")) {
            $l = $line.Trim()
            if (-not $l) { continue }
            if ($l -notmatch '(?i)(no infection|infection|detected|removed|threat|malware|started on|finished on|return code|results summary)') { continue }
            if ($l.Length -gt 160) { $l = $l.Substring(0, 157) + '...' }
            Add-ProgLog $Progress 'log.mrt.line' @($l)
            $n++; if ($n -ge 12) { break }
        }
    } catch { }
}

function Invoke-MrtScan {
    param([string]$Type, $Progress = $null)
    $started = Get-Date
    $mrt = Get-MrtPath
    if (-not $mrt) { return (New-ScanResult $Type 'Skipped' @() 'mrt-missing' 0) }
    $log = Get-MrtLogPath
    $offset = 0L
    try { if (Test-Path -LiteralPath $log) { $offset = (Get-Item -LiteralPath $log -ErrorAction Stop).Length } } catch { }
    $args2 = if ($Type -eq 'MrtFull') { @('/Q', '/F') } else { @('/Q') }
    $timeout = if ($Type -eq 'MrtFull') { 240 } else { 60 }
    $textKey = if ($Type -eq 'MrtFull') { 'prog.scanMrtFull' } else { 'prog.scanMrt' }
    Write-Log -Message ("MRT starting: " + ($args2 -join ' '))
    $exp = Get-ExpectedScanSeconds -Type $Type
    $watch = New-ScanWatch -Since $started -ExpectedSec $exp.Seconds
    $mrtVer = '?'
    try { $mrtVer = [string](Get-Item -LiteralPath $mrt -ErrorAction Stop).VersionInfo.FileVersion } catch { }
    Add-ProgLog $Progress 'log.mrt.start' @((T "log.type.$Type"), $mrtVer)
    Set-Prog $Progress -Percent 0 -Text (T $textKey @('00:00')) -CanCancel $true -CanPause $false -Phase 'mrt' -Estimated $true
    $proc = Start-Process -FilePath $mrt -ArgumentList $args2 -PassThru -WindowStyle Hidden
    $w = Wait-ScanProcess -Process $proc -Progress $Progress -AllowCancel $true -TimeoutMinutes $timeout -OnTick {
        param($el)
        Set-EstimatedProg $Progress $textKey $el.TotalSeconds $exp.Seconds
        Step-ScanWatch $Progress $watch $el.TotalSeconds
    } -OnCancel { Stop-ProcessTree $proc }
    $r = [pscustomobject]@{ ExitCode = $w.ExitCode; TimedOut = $w.TimedOut }
    $dur = ((Get-Date) - $started).TotalSeconds
    if ($w.Cancelled) { return (New-ScanResult $Type 'Cancelled' @() 'prog.cancelled' $dur) }
    if ($r.TimedOut) { return (New-ScanResult $Type 'Failed' @() 'timeout' $dur) }
    $text = ''
    try {
        if (Test-Path -LiteralPath $log) {
            $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -lt $offset) { $offset = 0 }   # log was rotated
                [void]$fs.Seek($offset, 'Begin')
                $buf = New-Object byte[] ($fs.Length - $offset)
                $n = $fs.Read($buf, 0, $buf.Length)
                if ($n -lt $buf.Length) { $short = New-Object byte[] ([Math]::Max(0, $n)); if ($n -gt 0) { [Array]::Copy($buf, $short, $n) }; $buf = $short }
                $text = Read-ProcessText $buf
            } finally { $fs.Dispose() }
        }
    } catch { Write-Log -Level WARN -Message "mrt.log unreadable: $($_.Exception.Message)" }
    Write-MrtLogLines -Progress $Progress -Text $text
    if (-not $text.Trim()) {
        if ($r.ExitCode -eq 0) { return (New-ScanResult $Type 'Clean' @() 'Finished without findings (no log entry)' $dur) }
        return (New-ScanResult $Type 'Failed' @() ("MRT exit code " + $r.ExitCode + ", no log entry") $dur)
    }
    $p = ConvertFrom-MrtLog $text
    if ($p.Clean) { return (New-ScanResult $Type 'Clean' @() 'No infection found' $dur) }
    if ($p.Infected -and $p.Removed) { return (New-ScanResult $Type 'ThreatsRemoved' $p.Threats 'Threats found and removed' $dur) }
    if ($p.Infected) { return (New-ScanResult $Type 'ThreatsFound' $p.Threats ("Threats found - see " + $log) $dur) }
    if ($r.ExitCode -eq 0 -or $p.ReturnCode -eq 0) { return (New-ScanResult $Type 'Clean' @() 'Finished without findings' $dur) }
    return (New-ScanResult $Type 'Failed' @() ("MRT exit code " + $r.ExitCode) $dur)
}

function Get-CbsLogPath { return (Join-Path ([Environment]::GetFolderPath('Windows')) 'Logs\CBS\CBS.log') }

function Write-SfcResultLog {
    <# One localized result line for an sfc state (Clean / Repaired / Unfixed / PendingReboot / Unknown), CBS.log hint when
       files could not be repaired. Never throws. #>
    param($Progress, [string]$State, $ExitCode = 0)
    try {
        switch ($State) {
            'Clean'         { Add-ProgLog $Progress 'log.int.clean' }
            'Repaired'      { Add-ProgLog $Progress 'log.int.repaired' }
            'Unfixed'       { Add-ProgLog $Progress 'log.int.unfixed'; Add-ProgLog $Progress 'log.int.cbs' @((Get-CbsLogPath)) }
            'PendingReboot' { Add-ProgLog $Progress 'log.int.pending' }
            default         { Add-ProgLog $Progress 'log.int.unknown' @($ExitCode); Add-ProgLog $Progress 'log.int.cbs' @((Get-CbsLogPath)) }
        }
    } catch { }
}

function Invoke-IntegrityScan {
    param($Progress = $null)
    $started = Get-Date
    $sfc = Join-Path ([Environment]::GetFolderPath('System')) 'sfc.exe'
    $dism = Join-Path ([Environment]::GetFolderPath('System')) 'Dism.exe'
    Write-Log -Message 'sfc /scannow starting'
    # Each tool reports its own 0..100 (phase 'sfc' / 'dism'); sfc may run twice (before and after the DISM repair).
    Add-ProgLog $Progress 'log.int.phaseSfc'
    Set-Prog $Progress -Percent -1 -Text (T 'prog.sfcStart' @('00:00')) -CanCancel $true -CanPause $false -Phase 'sfc' -Estimated $false
    $r = Invoke-ScanTool -FilePath $sfc -ArgumentList @('/scannow') -Kind sfc -Progress $Progress -AllowCancel $true -TimeoutMinutes 240 -TextKey 'prog.sfc' -TextKeyNoPct 'prog.sfcStart'
    if ($r.Cancelled) { return (New-ScanResult 'Integrity' 'Cancelled' @() 'prog.cancelled' ((Get-Date) - $started).TotalSeconds) }
    if ($r.TimedOut) { return (New-ScanResult 'Integrity' 'Failed' @() 'sfc timeout' ((Get-Date) - $started).TotalSeconds) }
    $state = ConvertFrom-SfcOutput $r.Output
    Write-Log -Message "sfc result: $state (exit $($r.ExitCode))"
    Write-SfcResultLog -Progress $Progress -State $state -ExitCode $r.ExitCode
    switch ($state) {
        'Clean'    { return (New-ScanResult 'Integrity' 'Clean' @() 'No integrity violations' ((Get-Date) - $started).TotalSeconds) }
        'Repaired' { return (New-ScanResult 'Integrity' 'ThreatsRemoved' @() 'Corrupt system files were repaired' ((Get-Date) - $started).TotalSeconds) }
        'PendingReboot' { return (New-ScanResult 'Integrity' 'Failed' @() 'Restart Windows first (pending repair), then run again' ((Get-Date) - $started).TotalSeconds) }
        'Unknown'  { return (New-ScanResult 'Integrity' 'Failed' @() ("sfc result not recognised (exit " + $r.ExitCode + ")") ((Get-Date) - $started).TotalSeconds) }
    }
    # Unfixed corruption -> repair the component store with DISM, then verify again with sfc.
    if (Test-ProgCancel $Progress) { return (New-ScanResult 'Integrity' 'Cancelled' @() 'prog.cancelled' ((Get-Date) - $started).TotalSeconds) }
    Write-Log -Message 'DISM RestoreHealth starting'
    Add-ProgLog $Progress 'log.int.phaseDism'
    # Interrupting a component-store repair can leave the store inconsistent: not cancellable, not pausable.
    Set-Prog $Progress -Percent -1 -Text (T 'prog.noCancelRepair') -CanCancel $false -CanPause $false -Phase 'dism'
    $d = Invoke-ScanTool -FilePath $dism -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') -Kind dism -Progress $Progress -AllowCancel $false -TimeoutMinutes 240 -TextKey 'prog.dismRepair' -TextKeyNoPct 'prog.noCancelRepair'
    if ($d.TimedOut) { return (New-ScanResult 'Integrity' 'Failed' @() 'DISM timeout' ((Get-Date) - $started).TotalSeconds) }
    if ($d.ExitCode -ne 0) {
        Add-ProgLog $Progress 'log.int.dismFail' @($d.ExitCode)
        Add-ProgLog $Progress 'log.int.cbs' @((Get-CbsLogPath))
        return (New-ScanResult 'Integrity' 'ThreatsFound' @() ("sfc found unfixable files; DISM failed (exit " + $d.ExitCode + ")") ((Get-Date) - $started).TotalSeconds)
    }
    if (Test-ProgCancel $Progress) { return (New-ScanResult 'Integrity' 'Cancelled' @() 'prog.cancelled' ((Get-Date) - $started).TotalSeconds) }
    Add-ProgLog $Progress 'log.int.dismOk'
    Add-ProgLog $Progress 'log.int.phaseSfc2'
    Set-Prog $Progress -Percent -1 -Text (T 'prog.sfcStart' @('00:00')) -CanCancel $true -CanPause $false -Phase 'sfc' -Estimated $false
    $r2 = Invoke-ScanTool -FilePath $sfc -ArgumentList @('/scannow') -Kind sfc -Progress $Progress -AllowCancel $true -TimeoutMinutes 240 -TextKey 'prog.sfc' -TextKeyNoPct 'prog.sfcStart'
    if ($r2.Cancelled) { return (New-ScanResult 'Integrity' 'Cancelled' @() 'prog.cancelled' ((Get-Date) - $started).TotalSeconds) }
    $state2 = ConvertFrom-SfcOutput $r2.Output
    Write-SfcResultLog -Progress $Progress -State $state2 -ExitCode $r2.ExitCode
    $dur = ((Get-Date) - $started).TotalSeconds
    if ($state2 -eq 'Clean' -or $state2 -eq 'Repaired') { return (New-ScanResult 'Integrity' 'ThreatsRemoved' @() 'Repaired with DISM and sfc' $dur) }
    return (New-ScanResult 'Integrity' 'ThreatsFound' @() 'Some system files could not be repaired - see CBS.log' $dur)
}

function Write-ScanFinishLog {
    <# "<scan> finished after mm:ss: <result>" (or the cancelled variant). Never throws. #>
    param($Progress, [string]$Type, $Result)
    try {
        $dur = Format-Elapsed ([TimeSpan]::FromSeconds([double]$Result.DurationSec))
        $label = T "log.type.$Type"
        if ($Result.Status -eq 'Cancelled') { Add-ProgLog $Progress 'log.scan.cancelled' @($label, $dur); return }
        $threats = @($Result.Threats)
        $txt = T ("log.res." + $Result.Status)
        if ($threats.Count -gt 0) { $txt += ' (' + (($threats | Select-Object -First 3) -join ', ') + ')' }
        Add-ProgLog $Progress 'log.scan.finished' @($label, $dur, $txt)
    } catch { }
}

function Start-SecurityScan {
    param(
        [Parameter(Mandatory)][ValidateSet('Quick', 'Full', 'Mrt', 'MrtFull', 'Integrity')][string]$Type,
        [switch]$DryRun,
        [hashtable]$Progress = $null
    )
    $started = Get-Date
    try {
        if ($DryRun) { return (New-ScanResult $Type 'WouldRun' @() 'dry-run' 0) }
        if (-not (Test-IsAdmin)) { return (New-ScanResult $Type 'Skipped' @() 'needs-admin' 0) }
        Initialize-DataDir
        if (Test-ProgCancel $Progress) { return (New-ScanResult $Type 'Cancelled' @() 'prog.cancelled' 0) }
        $res = $null
        Set-Prog $Progress -Estimated $false
        switch ($Type) {
            { $_ -in 'Quick', 'Full' } {
                if (Test-DefenderPassive) { return (New-ScanResult $Type 'Skipped' @() 'defender-passive' 0) }
                $res = Invoke-DefenderScan $Type $Progress
            }
            { $_ -in 'Mrt', 'MrtFull' } { $res = Invoke-MrtScan $Type $Progress }
            'Integrity' { $res = Invoke-IntegrityScan $Progress }
        }
        if ($res -and $res.Status -in 'Clean', 'ThreatsFound', 'ThreatsRemoved') {
            if ($Type -ne 'Integrity' -or $res.Status -eq 'Clean') { [void](Save-ScanDuration -Type $Type -Seconds $res.DurationSec) }
        }
        if ($res) { Write-ScanFinishLog -Progress $Progress -Type $Type -Result $res }
        if ($Progress) {
            Set-Prog $Progress -CanCancel $false -CanPause $false -Estimated $false
            if ($res -and $res.Status -eq 'Cancelled') { Set-Prog $Progress -Text (T 'prog.cancelled') }
            else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
        }
        return $res
    } catch {
        Write-Log -Level ERROR -Message "Start-SecurityScan $Type failed: $($_.Exception.Message)"
        return (New-ScanResult $Type 'Failed' @() $_.Exception.Message ((Get-Date) - $started).TotalSeconds)
    }
}

Export-ModuleMember -Function Get-SecurityStatus, Start-SecurityScan, Get-ThreatHistory, Get-MrtPath, Get-MrtLogPath, ConvertFrom-MrtLog, ConvertFrom-SfcOutput, ConvertFrom-SfcProgress, ConvertFrom-DismProgress, Get-MpCmdRunPath, Test-DefenderPassive, Get-ThirdPartyAntivirus, Get-ExpectedScanSeconds, Get-ScanEstimate, Save-ScanDuration, Read-ScanDurations, Get-ScanDurationsPath, Get-NewDefenderDetections, New-ScanWatch, Step-ScanWatch, Add-PctStepLog, Format-Remaining
