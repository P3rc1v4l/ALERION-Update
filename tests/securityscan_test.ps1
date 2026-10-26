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

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) failed, $passed passed" -ForegroundColor Red; exit 1 }
Write-Host "All $passed checks passed" -ForegroundColor Green
exit 0
