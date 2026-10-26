<#
.SYNOPSIS
    Fast, non-destructive test for src\SecurityScan.psm1. Starts no scans. Exit code 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:UPDATECENTER_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("alerion-sec-" + [guid]::NewGuid().ToString('N'))
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0

function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok -eq $false) { throw 'returned false' }
        $script:passed++; Write-Host "  [OK]   $Name" -ForegroundColor Green
    } catch {
        $script:failures.Add("$Name : $($_.Exception.Message)"); Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host 'SecurityScan test' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\SecurityScan.psm1') -Force -DisableNameChecking

$ids = @('antivirus','realtime','signatures','tamper','firewall','uac','secureboot','tpm','bitlocker','smartscreen','hvci','smb1','pua','lastscan','updates')
$status = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
Check 'Get-SecurityStatus runs' { $script:status = @(Get-SecurityStatus); $script:status.Count -gt 0 }
$sw.Stop()
Check 'Get-SecurityStatus under 25 s' { $sw.Elapsed.TotalSeconds -lt 25 }
Check 'all check ids present' {
    $have = @($status | ForEach-Object { $_.Id })
    foreach ($i in $ids) { if ($have -notcontains $i) { throw "missing $i" } }
    $true
}
Check 'states and shape valid' {
    foreach ($s in $status) {
        if ($s.State -notin @('Ok','Warning','Critical','Unknown')) { throw "$($s.Id): bad state $($s.State)" }
        if ($null -eq $s.Detail -or $null -eq $s.FixUri) { throw "$($s.Id): missing Detail/FixUri" }
        if ($s.FixUri -and $s.FixUri -notmatch '^(windowsdefender://|ms-settings:)') { throw "$($s.Id): bad FixUri" }
    }
    $true
}
foreach ($t in @('Quick','Full','Mrt','MrtFull','Integrity')) {
    Check "DryRun $t -> WouldRun" {
        $r = Start-SecurityScan -Type $t -DryRun
        $r.Type -eq $t -and $r.Status -eq 'WouldRun' -and $null -ne $r.Threats -and @($r.Threats).Count -eq 0
    }
}
Check 'MRT path detection' {
    $p = Get-MrtPath
    if ($p) { (Split-Path -Leaf $p) -eq 'MRT.exe' -and (Test-Path $p) } else { $true }
}
Check 'ConvertFrom-MrtLog clean sample' {
    $s = "Microsoft Windows Malicious Software Removal Tool v5.120, (build 5.120.19831.1)`r`nStarted On Mon Oct 05 2026`r`nResults Summary:`r`n----------------`r`nNo infection found.`r`nMicrosoft Windows Malicious Software Removal Tool Finished On Mon Oct 05 2026, Return code: 0 (0x0)"
    $p = ConvertFrom-MrtLog $s
    $p.Clean -and -not $p.Infected -and $p.ReturnCode -eq 0 -and $p.Finished -and @($p.Threats).Count -eq 0
}
Check 'ConvertFrom-MrtLog infected sample' {
    $s = "Results Summary:`r`n----------------`r`nWin32/Blaster.A detected and successfully removed.`r`nFinished On Mon, Return code: 1 (0x1)"
    $p = ConvertFrom-MrtLog $s
    $p.Infected -and $p.Removed -and (@($p.Threats) -contains 'Win32/Blaster.A') -and $p.ReturnCode -eq 1
}
Check 'ConvertFrom-SfcOutput' {
    (ConvertFrom-SfcOutput 'Windows Resource Protection did not find any integrity violations.') -eq 'Clean' -and
    (ConvertFrom-SfcOutput 'Windows Resource Protection found corrupt files and successfully repaired them.') -eq 'Repaired' -and
    (ConvertFrom-SfcOutput 'Windows Resource Protection found corrupt files but was unable to fix some of them.') -eq 'Unfixed' -and
    (ConvertFrom-SfcOutput ('Der Windows-Ressourcenschutz hat keine Integrit' + [char]0xE4 + 'tsverletzungen gefunden.')) -eq 'Clean'
}
Check 'Get-ThreatHistory returns array' { $h = Get-ThreatHistory; ($null -eq $h) -or (@($h).Count -ge 0) }

# ---------------------------------------------------------------- progress / cancel / pause
Write-Host 'Progress, cancel, pause' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\Common.psm1') -Force -DisableNameChecking
$pausedText = T 'prog.paused'

function Start-ModJob {
    param([string]$Code, [hashtable]$Progress)
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('Progress', $Progress)
    $rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $root 'src\SecurityScan.psm1'))
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript("Import-Module `$ModPath -Force -DisableNameChecking; " + $Code)
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}
function Receive-ModJob {
    param($Job, [int]$TimeoutSec = 90)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Job.Handle.IsCompleted) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $Job.PS.Stop(); throw "job timeout after $TimeoutSec s" }
        Start-Sleep -Milliseconds 20
    }
    $out = @($Job.PS.EndInvoke($Job.Handle))
    if ($Job.PS.Streams.Error.Count -gt 0) { $e = $Job.PS.Streams.Error[0].ToString(); $Job.PS.Dispose(); $Job.RS.Dispose(); throw $e }
    $Job.PS.Dispose(); $Job.RS.Dispose()
    return $out
}
function Wait-Until {
    param([scriptblock]$Cond, [int]$TimeoutSec = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Cond)) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { return $false }; Start-Sleep -Milliseconds 10 }
    return $true
}

# sfc / DISM percent parsers (English, German, CR separated updates, UTF-16 NULs)
Check 'sfc progress parser: English, CR updates, last value wins' {
    (ConvertFrom-SfcProgress 'Verification 45% complete.') -eq 45 -and
    (ConvertFrom-SfcProgress "Beginning verification phase of system scan.`r`nVerification 12% complete.`rVerification 37% complete.") -eq 37 -and
    (ConvertFrom-SfcProgress 'Verification 100% complete.') -eq 100
}
Check 'sfc progress parser: German wording' {
    $ue = [string][char]0xDC
    (ConvertFrom-SfcProgress ($ue + 'berpr' + [char]0xFC + 'fung 12 % abgeschlossen.')) -eq 12 -and
    (ConvertFrom-SfcProgress ("Die Systempr" + [char]0xFC + "fung wird gestartet.`r`n" + $ue + 'berpr' + [char]0xFC + 'fung wird zu 63 % abgeschlossen.')) -eq 63
}
Check 'sfc progress parser: UTF-16 NULs, none, out-of-range' {
    $nul = 'V' + [char]0 + 'e' + [char]0 + 'r' + [char]0 + ' ' + [char]0 + '8' + [char]0 + '8' + [char]0 + '%' + [char]0
    (ConvertFrom-SfcProgress $nul) -eq 88 -and $null -eq (ConvertFrom-SfcProgress 'Windows Resource Protection did not find any integrity violations.') -and
    $null -eq (ConvertFrom-SfcProgress '') -and $null -eq (ConvertFrom-SfcProgress 'Verification 250% complete.')
}
Check 'dism progress parser: English, German, comma, none' {
    (ConvertFrom-DismProgress '[==========================100.0%==========================]') -eq 100 -and
    (ConvertFrom-DismProgress "Deployment Image Servicing and Management tool`r`n[=====                      10.0%                           ]") -eq 10 -and
    (ConvertFrom-DismProgress "[==========                 20,5%                          ]`r[==============             45.0%                         ]") -eq 45 -and
    (ConvertFrom-DismProgress '[==                          3,5%                           ]') -eq 3.5 -and
    $null -eq (ConvertFrom-DismProgress ('Der Vorgang wurde erfolgreich beendet.')) -and $null -eq (ConvertFrom-DismProgress '')
}

# Start-SecurityScan: DryRun with a progress table, and cancel before anything starts (no scan is ever launched here).
Check 'Start-SecurityScan -DryRun -Progress still returns WouldRun' {
    $p = [hashtable]::Synchronized(@{})
    foreach ($t in 'Quick', 'Full', 'Mrt', 'MrtFull', 'Integrity') { if ((Start-SecurityScan -Type $t -DryRun -Progress $p).Status -ne 'WouldRun') { throw $t } }
    $true
}
Check 'Start-SecurityScan with Cancel=true never starts a scan (Skipped without admin, Cancelled with admin)' {
    $p = [hashtable]::Synchronized(@{ Cancel = $true })
    $r = Start-SecurityScan -Type Integrity -Progress $p
    $r.Status -in 'Skipped', 'Cancelled'
}

# Get-SecurityStatus: percent by check count, pause, cancel.
$prog = [hashtable]::Synchronized(@{})
$job = Start-ModJob -Progress $prog -Code '@(Get-SecurityStatus -Progress $Progress)'
$samples = New-Object System.Collections.Generic.List[double]; $sawCancel = $false; $sawText = ''
while (-not $job.Handle.IsCompleted) {
    $pc = $prog['Percent']; if ($null -ne $pc) { $samples.Add([double]$pc) }
    if ($prog['CanCancel'] -eq $true) { $sawCancel = $true }
    if ($prog['Text']) { $sawText = [string]$prog['Text'] }
    Start-Sleep -Milliseconds 20
}
$st = @(Receive-ModJob $job)
Check 'status progress: 16 results, Percent ends at 100, never backwards, CanCancel/Phase written' {
    if ($st.Count -ne 16) { throw "count $($st.Count)" }
    if ($prog['Percent'] -ne 100) { throw "final $($prog['Percent'])" }
    for ($i = 1; $i -lt $samples.Count; $i++) { if ($samples[$i] -lt $samples[$i - 1]) { throw 'backwards' } }
    $sawCancel -and $prog['Phase'] -eq 'status' -and $sawText
}
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '@(Get-SecurityStatus -Progress $Progress)'
Check 'status pause: blocks at a check boundary until Pause=false' {
    if (-not (Wait-Until { $prog['Text'] -eq $pausedText })) { throw "never paused (Text='$($prog['Text'])')" }
    Start-Sleep -Milliseconds 1000
    if ($job.Handle.IsCompleted) { throw 'finished while paused' }
    $prog['CanPause'] -eq $true
}
$prog['Pause'] = $false
$st = @(Receive-ModJob $job)
Check 'status pause: completes after resume' { $st.Count -eq 16 -and $prog['Percent'] -eq 100 }
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '@(Get-SecurityStatus -Progress $Progress)'
[void](Wait-Until { $prog['Text'] -eq $pausedText })
$prog['Cancel'] = $true
$st = @(Receive-ModJob $job -TimeoutSec 60)
Check 'status cancel (while paused): full-shape list, every check Unknown with the cancelled text' {
    $st.Count -eq 16 -and @($st | Where-Object { $_.State -ne 'Unknown' }).Count -eq 0 -and @($st | Where-Object { $_.Detail -eq (T 'prog.cancelled') }).Count -eq 16
}

# Process runner with harmless stand-ins (cmd.exe /ping), no sfc/DISM/Defender/MRT is started.
& (Get-Module SecurityScan) { Initialize-DataDir }
$cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
Check 'Invoke-ScanTool (sfc kind): reads UTF-16 output incrementally and reports percent' {
    $p = [hashtable]::Synchronized(@{})
    $args2 = @('/u', '/c', 'echo Verification 45% complete.&ping -n 3 127.0.0.1 >nul&echo Verification 90% complete.')
    $seen = New-Object System.Collections.Generic.List[double]
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('P', $p); $rs.SessionStateProxy.SetVariable('Cmd', $cmd); $rs.SessionStateProxy.SetVariable('A', $args2)
    $rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $root 'src\SecurityScan.psm1'))
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('Import-Module $ModPath -Force -DisableNameChecking; & (Get-Module SecurityScan) { Initialize-DataDir }; & (Get-Module SecurityScan) { param($c, $a, $pp) Invoke-ScanTool -FilePath $c -ArgumentList $a -Kind sfc -Progress $pp -AllowCancel $true -TextKey "prog.sfc" } $Cmd $A $P')
    $h = $ps.BeginInvoke()
    while (-not $h.IsCompleted) { $v = $p['Percent']; if ($null -ne $v) { $seen.Add([double]$v) }; Start-Sleep -Milliseconds 100 }
    $r = @($ps.EndInvoke($h)); $ps.Dispose(); $rs.Dispose()
    if ($r[0].Cancelled -or $r[0].TimedOut -or $r[0].ExitCode -ne 0) { throw "bad result $($r[0] | Out-String)" }
    if ($r[0].Output -notmatch '90% complete') { throw "output not decoded: [$($r[0].Output)]" }
    if (-not ($seen -contains 45) -and -not ($seen -contains 90)) { throw "no percent seen: $($seen -join ',')" }
    $seen -contains 45
}
Check 'Invoke-ScanTool: Cancel stops a running process quickly (AllowCancel)' {
    $p = [hashtable]::Synchronized(@{})
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('P', $p); $rs.SessionStateProxy.SetVariable('Cmd', $cmd)
    $rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $root 'src\SecurityScan.psm1'))
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('Import-Module $ModPath -Force -DisableNameChecking; & (Get-Module SecurityScan) { Initialize-DataDir }; & (Get-Module SecurityScan) { param($c, $pp) Invoke-ScanTool -FilePath $c -ArgumentList @("/c", "ping -n 40 127.0.0.1 >nul") -Kind sfc -Progress $pp -AllowCancel $true -TextKey "prog.sfc" } $Cmd $P')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $h = $ps.BeginInvoke()
    Start-Sleep -Milliseconds 1500
    $p['Cancel'] = $true
    [void](Wait-Until { $h.IsCompleted } 20)
    $r = @($ps.EndInvoke($h)); $ps.Dispose(); $rs.Dispose()
    $clock.Stop()
    $r[0].Cancelled -eq $true -and $clock.Elapsed.TotalSeconds -lt 15 -and $p['CanCancel'] -eq $false
}
Check 'Invoke-ScanTool: Cancel is ignored when AllowCancel=false (DISM repair)' {
    $p = [hashtable]::Synchronized(@{ Cancel = $true })
    $r = & (Get-Module SecurityScan) { param($c, $pp) Invoke-ScanTool -FilePath $c -ArgumentList @('/c', 'ping -n 3 127.0.0.1 >nul') -Kind dism -Progress $pp -AllowCancel $false -TextKey 'prog.dismRepair' } $cmd $p
    -not $r.Cancelled -and $r.ExitCode -eq 0
}

# ---------------------------------------------------------------- live log, estimate, detection polling
Write-Host 'Live log, estimate, detection polling' -ForegroundColor Cyan
$sec = Get-Module SecurityScan
$fragPath = Join-Path $root 'src\i18n.json'
function Merge-I18nFragment {
    # Adds the new keys to the Common instance the module under test really uses (i18n.json itself is merged by the app).
    param([string]$ModuleName)
    $mod = & (Get-Module $ModuleName) { (Get-Command T).ScriptBlock.Module }
    $frag = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8 | ConvertFrom-Json
    & $mod { param($f)
        $null = T "prog.done"
        foreach ($l in 'de', 'en') { foreach ($p in $f.$l.PSObject.Properties) { Add-Member -InputObject $script:I18n.$l -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
    } $frag
}
function New-LogProgress { [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) }) }
Merge-I18nFragment 'SecurityScan'

Check 'i18n: valid JSON, de/en have identical keys' {
    $f = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $a = @($f.de.PSObject.Properties.Name | Sort-Object); $b = @($f.en.PSObject.Properties.Name | Sort-Object)
    ($a -join ',') -eq ($b -join ',') -and $a.Count -gt 50
}
Check 'fragment: every log./prog.est key used by the three modules exists' {
    $f = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $have = @($f.de.PSObject.Properties.Name)
    $miss = New-Object System.Collections.Generic.List[string]
    foreach ($m in 'SecurityScan', 'Cleanup', 'Uninstaller') {
        $t = Get-Content -LiteralPath (Join-Path $root "src\$m.psm1") -Raw
        foreach ($mm in [regex]::Matches($t, "'((?:log\.[A-Za-z0-9.]+)|(?:prog\.est[A-Za-z]+))'")) { if ($have -notcontains $mm.Groups[1].Value) { $miss.Add($mm.Groups[1].Value) } }
    }
    if ($miss.Count) { throw ('missing: ' + (($miss | Select-Object -Unique) -join ', ')) }
    $true
}
Check 'Add-ProgLog: timestamped line, no Log key / null progress never throw' {
    $p = New-LogProgress
    & $sec { param($pp) Add-ProgLog $pp 'log.mrt.line' @('hello') } $p
    & $sec { Add-ProgLog $null 'log.mrt.line' @('x'); Add-ProgLog ([hashtable]::Synchronized(@{})) 'log.mrt.line' @('x'); Add-ProgLog @{ Log = 5 } 'log.mrt.line' @('x') }
    $p['Log'].Count -eq 1 -and $p['Log'][0] -match '^\d\d:\d\d:\d\d  .*hello'
}
Check 'Add-ProgLog: capped at 500 lines, oldest dropped' {
    $p = New-LogProgress
    & $sec { param($pp) 1..520 | ForEach-Object { Add-ProgLog $pp 'log.mrt.line' @("line $_") } } $p
    $p['Log'].Count -eq 500 -and $p['Log'][0] -match 'line 21$' -and $p['Log'][499] -match 'line 520$'
}
Check 'Get-ScanEstimate: percent, remaining, 95 cap, no expectation' {
    $a = Get-ScanEstimate -ElapsedSec 60 -ExpectedSec 240
    $b = Get-ScanEstimate -ElapsedSec 1000 -ExpectedSec 240
    $c = Get-ScanEstimate -ElapsedSec 10 -ExpectedSec 0
    $d = Get-ScanEstimate -ElapsedSec -5 -ExpectedSec 100
    $a.Percent -eq 25 -and $a.RemainingSec -eq 180 -and -not $a.Over -and $b.Percent -eq 95 -and $b.RemainingSec -eq 0 -and $b.Over -and $c.Percent -eq -1 -and $d.Percent -eq 0
}
Check 'Format-Remaining: rounds up, minutes and hours' {
    (Format-Remaining 5) -eq '1 min' -and (Format-Remaining 180) -eq '3 min' -and (Format-Remaining 181) -eq '4 min' -and (Format-Remaining 4800) -eq '1 h 20 min'
}
Remove-Item -LiteralPath (Get-ScanDurationsPath) -Force -ErrorAction SilentlyContinue
Check 'Get-ExpectedScanSeconds without history: defaults (Quick 4 min, Full 60 min)' {
    $q = Get-ExpectedScanSeconds -Type Quick -MpSource { $null }
    $f = Get-ExpectedScanSeconds -Type Full -MpSource { $null }
    $m = Get-ExpectedScanSeconds -Type Mrt
    $q.Seconds -eq 240 -and $q.Source -eq 'default' -and $f.Seconds -eq 3600 -and $m.Source -eq 'default' -and $m.Seconds -gt 0
}
Check 'Get-ExpectedScanSeconds: Defender last scan duration from Get-MpComputerStatus (mock), sanity-checked' {
    $t0 = Get-Date '2026-01-01 10:00:00'
    $mp = [pscustomobject]@{ QuickScanStartTime = $t0; QuickScanEndTime = $t0.AddMinutes(7); FullScanStartTime = $t0; FullScanEndTime = $t0.AddMinutes(95) }
    $bad = [pscustomobject]@{ QuickScanStartTime = $t0; QuickScanEndTime = $t0.AddMinutes(-3); FullScanStartTime = $null; FullScanEndTime = $null }
    $q = Get-ExpectedScanSeconds -Type Quick -MpSource ({ $mp }.GetNewClosure())
    $f = Get-ExpectedScanSeconds -Type Full -MpSource ({ $mp }.GetNewClosure())
    $b = Get-ExpectedScanSeconds -Type Quick -MpSource ({ $bad }.GetNewClosure())
    $e = Get-ExpectedScanSeconds -Type Quick -MpSource { throw 'no defender' }
    $q.Seconds -eq 420 -and $q.Source -eq 'defender' -and $f.Seconds -eq 5700 -and $b.Source -eq 'default' -and $b.Seconds -eq 240 -and $e.Seconds -eq 240
}
Check 'DryRun / non-success never writes the durations file' {
    [void](Start-SecurityScan -Type Quick -DryRun)
    [void](Start-SecurityScan -Type Mrt -DryRun)
    -not (Test-Path -LiteralPath (Get-ScanDurationsPath))
}
Check 'Save-ScanDuration: writes <StateDir>\scan-durations.json, merges types, ignores bad values' {
    $p = Get-ScanDurationsPath
    if ($p -ne (Join-Path (Get-AppPaths).StateDir 'scan-durations.json')) { throw "path $p" }
    if (-not (Save-ScanDuration -Type Quick -Seconds 123.456)) { throw 'save Quick' }
    if (-not (Save-ScanDuration -Type MrtFull -Seconds 999)) { throw 'save MrtFull' }
    if (Save-ScanDuration -Type Full -Seconds 0) { throw 'zero accepted' }
    if (Save-ScanDuration -Type Full -Seconds -4) { throw 'negative accepted' }
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    $r = Read-ScanDurations
    $j.Quick -eq 123.5 -and $j.MrtFull -eq 999 -and -not ($j.PSObject.Properties.Name -contains 'Full') -and $r['Quick'] -eq 123.5 -and $r.Count -eq 2
}
Check 'Get-ExpectedScanSeconds prefers the history file, other types keep their default' {
    $q = Get-ExpectedScanSeconds -Type Quick -MpSource { throw 'must not be asked' }
    $mf = Get-ExpectedScanSeconds -Type MrtFull
    $m = Get-ExpectedScanSeconds -Type Mrt
    $q.Seconds -eq 123.5 -and $q.Source -eq 'history' -and $mf.Seconds -eq 999 -and $mf.Source -eq 'history' -and $m.Source -eq 'default'
}
Check 'Read-ScanDurations / Save-ScanDuration survive a corrupt file' {
    [IO.File]::WriteAllText((Get-ScanDurationsPath), '{ not json ]')
    $r = Read-ScanDurations
    $ok = Save-ScanDuration -Type Integrity -Seconds 321
    $r.Count -eq 0 -and $ok -and (Read-ScanDurations)['Integrity'] -eq 321
}
Check 'Set-EstimatedProg: Percent from elapsed/expected, Estimated=true, text has elapsed and remaining' {
    $p = [hashtable]::Synchronized(@{})
    & $sec { param($pp) Set-EstimatedProg $pp 'prog.scanQuick' 60 240 } $p
    $over = [hashtable]::Synchronized(@{})
    & $sec { param($pp) Set-EstimatedProg $pp 'prog.scanQuick' 600 240 } $over
    $p['Percent'] -eq 25 -and $p['Estimated'] -eq $true -and $p['Text'] -match '01:00' -and $p['Text'] -match '3 min' -and $over['Percent'] -eq 95 -and $over['Text'] -match '10:00'
}
Check 'Get-NewDefenderDetections (mock): filters by start time, dedupes, resolves name/path/action' {
    $t0 = Get-Date
    $script:mockDet = @(
        [pscustomobject]@{ DetectionID = 'A'; ThreatID = 7; InitialDetectionTime = $t0.AddMinutes(-30); Resources = @('file:_C:\old\a.exe'); CleaningActionID = 2 },
        [pscustomobject]@{ DetectionID = 'B'; ThreatID = 7; InitialDetectionTime = $t0.AddSeconds(2); Resources = @('file:_C:\Temp\evil.exe', 'file:_C:\Temp\evil.dll'); CleaningActionID = 2 },
        [pscustomobject]@{ DetectionID = 'C'; ThreatID = 9; InitialDetectionTime = $t0.AddSeconds(3); Resources = @('regkey:_HKLM\Software\Bad'); CleaningActionID = 99 }
    )
    $script:mockThr = @([pscustomobject]@{ ThreatID = 7; ThreatName = 'Trojan:Win32/Test.A' })
    $seen = @{}
    $n1 = @(Get-NewDefenderDetections -Since $t0 -Seen $seen -DetectionSource { $script:mockDet } -ThreatSource { $script:mockThr })
    $n2 = @(Get-NewDefenderDetections -Since $t0 -Seen $seen -DetectionSource { $script:mockDet } -ThreatSource { $script:mockThr })
    if ($n1.Count -ne 2) { throw "first poll $($n1.Count)" }
    if ($n2.Count -ne 0) { throw "second poll $($n2.Count) (not deduped)" }
    $n1[0].Name -eq 'Trojan:Win32/Test.A' -and $n1[0].Path -eq 'C:\Temp\evil.exe; C:\Temp\evil.dll' -and $n1[0].Action -and $n1[1].Name -eq 'Threat 9' -and $n1[1].Path -eq 'HKLM\Software\Bad'
}
Check 'Get-NewDefenderDetections: a failing source returns nothing and never throws' {
    $r = @(Get-NewDefenderDetections -Since (Get-Date) -Seen @{} -DetectionSource { throw 'boom' })
    $r.Count -eq 0
}
Check 'Step-ScanWatch: polls at 5 s, logs each NEW detection once, status line every 30 s' {
    $t0 = Get-Date
    $script:mockDet = @([pscustomobject]@{ DetectionID = 'X1'; ThreatID = 7; InitialDetectionTime = $t0.AddSeconds(1); Resources = @('file:_C:\Temp\evil.exe'); CleaningActionID = 3 })
    $script:mockThr = @([pscustomobject]@{ ThreatID = 7; ThreatName = 'Trojan:Win32/Test.A' })
    $script:polls = 0
    $src = { $script:polls++; $script:mockDet }
    $thr = { $script:mockThr }
    $p = New-LogProgress
    $w = New-ScanWatch -Since $t0 -ExpectedSec 240
    foreach ($e in 1, 2, 3, 4) { Step-ScanWatch $p $w $e -Detections -DetectionSource $src -ThreatSource $thr }
    if ($script:polls -ne 0 -or $p['Log'].Count -ne 0) { throw "before 5 s: polls=$($script:polls) log=$($p['Log'].Count)" }
    Step-ScanWatch $p $w 5 -Detections -DetectionSource $src -ThreatSource $thr
    Step-ScanWatch $p $w 7 -Detections -DetectionSource $src -ThreatSource $thr     # not yet due
    if ($script:polls -ne 1) { throw "polls $($script:polls)" }
    if ($p['Log'].Count -ne 1 -or $p['Log'][0] -notmatch 'Trojan:Win32/Test\.A' -or $p['Log'][0] -notmatch 'evil\.exe') { throw "detection line: $($p['Log'] -join ' | ')" }
    Step-ScanWatch $p $w 10 -Detections -DetectionSource $src -ThreatSource $thr
    if ($script:polls -ne 2 -or $p['Log'].Count -ne 1) { throw "repeat: polls=$($script:polls) log=$($p['Log'].Count)" }
    Step-ScanWatch $p $w 31 -Detections -DetectionSource $src -ThreatSource $thr
    if ($p['Log'].Count -ne 2 -or $p['Log'][1] -notmatch '00:31') { throw "tick line: $($p['Log'] -join ' | ')" }
    Step-ScanWatch $p $w 40 -Detections -DetectionSource $src -ThreatSource $thr
    $p['Log'].Count -eq 2
}
Check 'Step-ScanWatch: over-estimate wording, no polling without -Detections (MRT)' {
    $script:polls = 0
    $p = New-LogProgress
    $w = New-ScanWatch -Since (Get-Date) -ExpectedSec 20
    Step-ScanWatch $p $w 45 -DetectionSource { $script:polls++; @() }
    $script:polls -eq 0 -and $p['Log'].Count -eq 1 -and $p['Log'][0] -match '00:45' -and $p['Log'][0] -match '20|1 min'
}
Check 'Add-PctStepLog: one line per 10 % step, never twice' {
    $p = New-LogProgress
    $st2 = @{ Last = 0 }
    foreach ($v in 5, 12, 18, 12, 35, 99, 100) { & $sec { param($pp, $s2, $v2) Add-PctStepLog $pp $s2 $v2 'sfc' } $p $st2 $v }
    $p['Log'].Count -eq 4 -and $p['Log'][0] -match 'sfc.* 10' -and $p['Log'][1] -match '30' -and $p['Log'][2] -match '90' -and $p['Log'][3] -match '100'
}
Check 'Write-SfcResultLog: result lines per state, CBS.log hint when files could not be repaired' {
    $p = New-LogProgress
    & $sec { param($pp) Write-SfcResultLog $pp 'Clean' 0; Write-SfcResultLog $pp 'Repaired' 0 } $p
    $a = $p['Log'].Count
    & $sec { param($pp) Write-SfcResultLog $pp 'Unfixed' 0 } $p
    $a -eq 2 -and $p['Log'].Count -eq 4 -and $p['Log'][3] -match 'CBS\.log'
}
Check 'Write-MrtLogLines: keeps the result lines of mrt.log, drops noise' {
    $p = New-LogProgress
    $txt = "Microsoft Windows Malicious Software Removal Tool v5.120`r`nrandom noise line`r`nStarted On Mon Oct 05 2026`r`n`r`nResults Summary:`r`n----------------`r`nNo infection found.`r`nFinished On Mon Oct 05 2026, Return code: 0 (0x0)"
    & $sec { param($pp, $t) Write-MrtLogLines $pp $t } $p $txt
    $all = $p['Log'] -join "`n"
    $p['Log'].Count -ge 4 -and $all -match 'No infection found' -and $all -notmatch 'random noise'
}
Check 'Write-ScanFinishLog: finished (with duration and threats) and cancelled' {
    $p = New-LogProgress
    $r1 = [pscustomobject]@{ Type = 'Quick'; Status = 'ThreatsRemoved'; Threats = @('Trojan:X'); Message = ''; DurationSec = 125 }
    $r2 = [pscustomobject]@{ Type = 'Quick'; Status = 'Cancelled'; Threats = @(); Message = ''; DurationSec = 61 }
    & $sec { param($pp, $a, $b) Write-ScanFinishLog $pp 'Quick' $a; Write-ScanFinishLog $pp 'Quick' $b } $p $r1 $r2
    $p['Log'].Count -eq 2 -and $p['Log'][0] -match '02:05' -and $p['Log'][0] -match 'Trojan:X' -and $p['Log'][1] -match '01:01'
}
Check 'Invoke-ScanTool logs 10 % steps and keeps Estimated=false (real percent)' {
    $p = New-LogProgress
    $p['Estimated'] = $true
    $args3 = @('/u', '/c', 'echo Verification 25% complete.&ping -n 4 127.0.0.1 >nul&echo Verification 100% complete.')
    $r = & $sec { param($c, $a, $pp) Invoke-ScanTool -FilePath $c -ArgumentList $a -Kind sfc -Progress $pp -AllowCancel $true -TextKey 'prog.sfc' } $cmd $args3 $p
    if ($r.ExitCode -ne 0) { throw "exit $($r.ExitCode)" }
    $p['Estimated'] -eq $false -and $p['Log'].Count -ge 1 -and $p['Log'][0] -match 'sfc' -and $p['Log'][0] -match '20'
}

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) failed, $passed passed" -ForegroundColor Red; exit 1 }
Write-Host "All $passed checks passed" -ForegroundColor Green
exit 0
