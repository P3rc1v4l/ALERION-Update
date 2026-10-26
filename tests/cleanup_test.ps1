<#
.SYNOPSIS
    Non-destructive test for src/Cleanup.psm1 (only touches a test folder it creates itself).
    Exit code 0 = all checks passed.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$script:passed = 0

function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok -eq $false) { throw 'returned false' }
        $script:passed++; Write-Host "  [OK]   $Name" -ForegroundColor Green
    } catch {
        $failures.Add("$Name : $($_.Exception.Message)"); Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$env:UPDATECENTER_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("uc-cleanup-test-" + [guid]::NewGuid().ToString('N'))
Write-Host 'Cleanup module test' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\Cleanup.psm1') -Force -DisableNameChecking

$expected = 'recyclebin', 'temp', 'wucache', 'docache', 'thumbs', 'wer', 'shadercache', 'browsercache', 'dumps', 'appcache', 'components'
$sw = [Diagnostics.Stopwatch]::StartNew()
$cats = @(Get-CleanupCategories)
$sw.Stop()

Check 'categories: all expected ids' { (@($cats | ForEach-Object { $_.Id }) -join ',') -eq ($expected -join ',') }
Check 'categories: fast (<15s)' { $sw.Elapsed.TotalSeconds -lt 15 }
Check 'categories: shape and sane values' {
    foreach ($c in $cats) {
        foreach ($p in 'Id', 'SizeBytes', 'ItemCount', 'Risk', 'RequiresAdmin', 'Default', 'Available', 'Note') {
            if (-not ($c.PSObject.Properties.Name -contains $p)) { throw "$($c.Id) lacks $p" }
        }
        if ($c.SizeBytes -lt -1) { throw "$($c.Id) size $($c.SizeBytes)" }
        if ($c.ItemCount -lt 0) { throw "$($c.Id) count" }
        if ($c.Risk -notin 'None', 'Low') { throw "$($c.Id) risk" }
        if (-not $c.Available -and -not $c.Note) { throw "$($c.Id) unavailable without note" }
    }
}
Check 'components: Low risk, default off, size -1' {
    $c = $cats | Where-Object Id -eq 'components'
    $c.Risk -eq 'Low' -and $c.Default -eq $false -and $c.SizeBytes -eq -1
}

$dry = @(Invoke-Cleanup -Ids $expected -DryRun)
Check 'dry run: one result per id' { $dry.Count -eq $expected.Count }
Check 'dry run: only WouldClean/Skipped/Cleaned(empty), never destructive' {
    foreach ($r in $dry) { if ($r.Status -notin 'WouldClean', 'Skipped', 'Cleaned') { throw "$($r.Id) -> $($r.Status): $($r.Message)" } }
}
Check 'dry run: nothing deleted (sizes unchanged for temp)' {
    $a = ($cats | Where-Object Id -eq 'temp').ItemCount
    $b = ((@(Get-CleanupCategories) | Where-Object Id -eq 'temp').ItemCount)
    [Math]::Abs($a - $b) -le [Math]::Max(5, $a * 0.2)
}
Check 'unknown id is skipped' { (@(Invoke-Cleanup -Ids 'nope'))[0].Status -eq 'Skipped' }

# path guard
$r = Join-Path $env:UPDATECENTER_DATADIR 'guard'
Check 'guard: inside root accepted' { Test-CleanupPath -Path "$r\a\b.txt" -Root $r }
Check 'guard: root itself refused' { -not (Test-CleanupPath -Path $r -Root $r) }
Check 'guard: sibling with same prefix refused' { -not (Test-CleanupPath -Path "${r}2\x.txt" -Root $r) }
Check 'guard: dot-dot escape refused' { -not (Test-CleanupPath -Path "$r\..\other\x.txt" -Root $r) }
Check 'guard: outside root refused' { -not (Test-CleanupPath -Path 'C:\Windows\System32\kernel32.dll' -Root $r) }
Check 'guard: drive root as root refused' { -not (Test-CleanupPath -Path 'C:\Windows\x.txt' -Root 'C:\') }
Check 'guard: empty refused' { -not (Test-CleanupPath -Path '' -Root $r) }

# real deletion engine on a private folder
$t = Join-Path $env:UPDATECENTER_DATADIR 'engine'
New-Item -ItemType Directory -Path "$t\sub" -Force | Out-Null
$old = (Get-Date).AddDays(-3)
$files = @{ old1 = "$t\old1.tmp"; old2 = "$t\sub\old2.tmp"; fresh = "$t\fresh.tmp"; locked = "$t\locked.tmp" }
foreach ($k in $files.Keys) { Set-Content -Path $files[$k] -Value ('x' * 1000) }
foreach ($k in 'old1', 'old2', 'locked') { $f = Get-Item $files[$k]; $f.LastWriteTime = $old; $f.CreationTime = $old }
(Get-Item "$t\sub").LastWriteTime = $old
$dryR = Clear-CleanupFolder -Root $t -MinAgeDays 1 -DryRun
Check 'engine: dry run counts 3 old files, deletes none' { $dryR.Files -eq 3 -and (Test-Path $files.old1) -and (Test-Path $files.old2) }
$fs = [IO.File]::Open($files.locked, 'Open', 'ReadWrite', 'None')
try { $res = Clear-CleanupFolder -Root $t -MinAgeDays 1 } finally { $fs.Dispose() }
Check 'engine: old files deleted' { -not (Test-Path $files.old1) -and -not (Test-Path $files.old2) }
Check 'engine: fresh file kept' { Test-Path $files.fresh }
Check 'engine: locked file kept and counted' { (Test-Path $files.locked) -and $res.Locked -eq 1 -and $res.Files -eq 2 }
Check 'engine: freed bytes sane' { $res.Freed -ge 2000 }
Check 'engine: empty old subfolder removed, root kept' { -not (Test-Path "$t\sub") -and (Test-Path $t) }

# ---------------------------------------------------------------- progress / cancel / pause
Write-Host 'Progress, cancel, pause' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\Common.psm1') -Force -DisableNameChecking
$pausedText = T 'prog.paused'

function Start-ModJob {
    param([string]$Code, [hashtable]$Progress)
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('Progress', $Progress)
    $rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $root 'src\Cleanup.psm1'))
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript("Import-Module `$ModPath -Force -DisableNameChecking; " + $Code)
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}
function Receive-ModJob {
    param($Job, [int]$TimeoutSec = 60)
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
    param([scriptblock]$Cond, [int]$TimeoutSec = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Cond)) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { return $false }; Start-Sleep -Milliseconds 10 }
    return $true
}

# Test hook: the 'temp' category is pointed at a private folder with many small files.
$tr = Join-Path $env:UPDATECENTER_DATADIR 'progroot'
$fileCount = 9000
foreach ($d in 0..4) { New-Item -ItemType Directory -Path (Join-Path $tr "d$d") -Force | Out-Null }
for ($i = 0; $i -lt $fileCount; $i++) { [IO.File]::WriteAllText((Join-Path $tr ("d{0}\f{1}.tmp" -f ($i % 5), $i)), ('x' * 100)) }
$env:UPDATECENTER_CLEANUP_TESTROOT = $tr
$expectBytes = [long]($fileCount * 100)

Check 'hook: ignored when pointing outside the temp folder' {
    $env:UPDATECENTER_CLEANUP_TESTROOT = 'C:\Windows'
    try { $t = @(& (Get-Module Cleanup) { Get-CleanupTargets -Id 'temp' }) } finally { $env:UPDATECENTER_CLEANUP_TESTROOT = $tr }
    @($t | Where-Object { $_.Root -ieq 'C:\Windows' }).Count -eq 0
}
Check 'dism progress parser (English/German/comma/none)' {
    (ConvertFrom-DismProgress '[==========================100.0%==========================]') -eq 100 -and
    (ConvertFrom-DismProgress "Deployment Image Servicing`r`n[=====                      10.0%                           ]") -eq 10 -and
    (ConvertFrom-DismProgress "[===========                20,5%                          ]`r[==============             45.0%                         ]") -eq 45 -and
    (ConvertFrom-DismProgress '[==                          3,5%                           ]') -eq 3.5 -and
    $null -eq (ConvertFrom-DismProgress 'Der Vorgang wurde erfolgreich beendet.') -and
    $null -eq (ConvertFrom-DismProgress '')
}

# Invoke-Cleanup: percent rises monotonically to 100, CanCancel is set, result is WouldClean (DryRun).
$prog = [hashtable]::Synchronized(@{})
$job = Start-ModJob -Progress $prog -Code '$r = Invoke-Cleanup -Ids "temp" -DryRun -Progress $Progress; $r'
$samples = New-Object System.Collections.Generic.List[double]
$sawCancel = $false; $sawPhaseClean = $false; $sawText = ''
while (-not $job.Handle.IsCompleted) {
    $pc = $prog['Percent']; if ($null -ne $pc) { $samples.Add([double]$pc) }
    if ($prog['CanCancel'] -eq $true) { $sawCancel = $true }
    if ($prog['Phase'] -eq 'clean') { $sawPhaseClean = $true; if ($prog['Text']) { $sawText = [string]$prog['Text'] } }
    Start-Sleep -Milliseconds 3
}
$res = @(Receive-ModJob $job)
Check 'cleanup progress: result WouldClean with the right size' { $res.Count -eq 1 -and $res[0].Status -eq 'WouldClean' -and $res[0].FreedBytes -eq $expectBytes }
Check 'cleanup progress: percent ends at 100, never runs backwards' {
    if ($prog['Percent'] -ne 100) { throw "final $($prog['Percent'])" }
    for ($i = 1; $i -lt $samples.Count; $i++) { if ($samples[$i] -lt $samples[$i - 1]) { throw "backwards at $i ($($samples[$i - 1]) -> $($samples[$i]))" } }
    $true
}
Check "cleanup progress: percent actually rises ($(@($samples | Select-Object -Unique).Count) distinct values)" { @($samples | Select-Object -Unique).Count -ge 3 }
Check 'cleanup progress: CanCancel/CanPause/Phase/Text written' {
    $sawCancel -and $sawPhaseClean -and $sawText -and ($prog['CanPause'] -is [bool]) -and ($prog['CanCancel'] -eq $false)
}

# Pause blocks until Pause=false (deterministic: Pause is set before the run).
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '$r = Invoke-Cleanup -Ids "temp" -DryRun -Progress $Progress; $r'
Check 'pause: run blocks at a safe point and reports the paused text' {
    if (-not (Wait-Until { $prog['Text'] -eq $pausedText })) { throw "never paused (Text='$($prog['Text'])')" }
    Start-Sleep -Milliseconds 1200
    if ($job.Handle.IsCompleted) { throw 'finished while paused' }
    $prog['CanPause'] -eq $true -and $prog['CanCancel'] -eq $true
}
$prog['Pause'] = $false
$res = @(Receive-ModJob $job)
Check 'pause: resumes after Pause=false and completes normally' { $res[0].Status -eq 'WouldClean' -and $res[0].FreedBytes -eq $expectBytes -and $prog['Percent'] -eq 100 }

# Cancel while paused in the analysis pass -> every id is Cancelled.
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '$r = Invoke-Cleanup -Ids "temp","thumbs" -DryRun -Progress $Progress; $r'
[void](Wait-Until { $prog['Text'] -eq $pausedText })
$prog['Cancel'] = $true
$res = @(Receive-ModJob $job -TimeoutSec 20)
Check 'cancel (during analysis, while paused): all results Cancelled, message prog.cancelled' {
    $res.Count -eq 2 -and @($res | Where-Object { $_.Status -ne 'Cancelled' -or $_.Message -ne 'prog.cancelled' }).Count -eq 0
}
Check 'cancel: no file was touched' { @(Get-ChildItem $tr -Recurse -File).Count -eq $fileCount }

# Cancel between files: paused at the first file of the delete loop, then cancelled -> nothing processed.
$found = & (Get-Module Cleanup) { param($r) Get-CleanupFiles -Root $r } $tr
$prog = [hashtable]::Synchronized(@{ Pause = $true; CanPause = $true; CanCancel = $true })
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('Progress', $prog); $rs.SessionStateProxy.SetVariable('Found', $found); $rs.SessionStateProxy.SetVariable('Tr', $tr)
$rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $root 'src\Cleanup.psm1'))
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript('Import-Module $ModPath -Force -DisableNameChecking; Clear-CleanupFolder -Root $Tr -DryRun -Found $Found -Progress $Progress')
$h = $ps.BeginInvoke()
[void](Wait-Until { $prog['Text'] -eq $pausedText })
$prog['Cancel'] = $true
[void](Wait-Until { $h.IsCompleted } 20)
$cr = @($ps.EndInvoke($h)); $ps.Dispose(); $rs.Dispose()
Check 'cancel between files: Clear-CleanupFolder returns Cancelled without processing' { $cr[0].Cancelled -eq $true -and $cr[0].Files -eq 0 }

# Mid-run cancel (race: cancel as soon as the clean phase reports progress); retried until it lands inside the run.
$midOk = $false; $midInfo = ''
for ($try = 0; $try -lt 8 -and -not $midOk; $try++) {
    $prog = [hashtable]::Synchronized(@{})
    $job = Start-ModJob -Progress $prog -Code '$r = Invoke-Cleanup -Ids "temp" -DryRun -Progress $Progress; $r'
    [void](Wait-Until { $prog['Phase'] -eq 'clean' -and $prog['Percent'] -gt 10 } 30)
    $prog['Cancel'] = $true
    $res = @(Receive-ModJob $job)
    $midInfo = "$($res[0].Status) freed=$($res[0].FreedBytes)"
    if ($res[0].Status -eq 'Cancelled' -and $res[0].FreedBytes -gt 0 -and $res[0].FreedBytes -lt $expectBytes -and $res[0].Message -eq 'prog.cancelled') { $midOk = $true }
}
Check "cancel mid-run: Cancelled with partial FreedBytes ($midInfo)" { $midOk }

# Get-CleanupCategories with progress: percent by category count, ends at 100, same shape.
$prog = [hashtable]::Synchronized(@{})
$cats2 = @(Get-CleanupCategories -Progress $prog)
Check 'categories progress: percent 100, CanCancel written, all ids present' {
    $prog['Percent'] -eq 100 -and $prog.ContainsKey('CanCancel') -and $prog['Phase'] -eq 'scan' -and $cats2.Count -eq $expected.Count -and
    (($cats2 | Where-Object Id -eq 'temp').ItemCount -eq $fileCount)
}
$prog = [hashtable]::Synchronized(@{ Cancel = $true })
$cats3 = @(Get-CleanupCategories -Progress $prog)
Check 'categories progress: Cancel=true returns full-shape list marked cancelled' {
    $cats3.Count -eq $expected.Count -and @($cats3 | Where-Object { $_.Note -ne 'cancelled' }).Count -eq 0
}
# ---------------------------------------------------------------- live log
Write-Host 'Live log' -ForegroundColor Cyan
$clMod = Get-Module Cleanup
$fragPath = Join-Path $root 'src\i18n.json'
$tMod = & $clMod { (Get-Command T).ScriptBlock.Module }
$frag = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8 | ConvertFrom-Json
& $tMod { param($f)
    $null = T 'prog.done'
    foreach ($l in 'de', 'en') { foreach ($p in $f.$l.PSObject.Properties) { Add-Member -InputObject $script:I18n.$l -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
} $frag
function New-LogProgress { [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) }) }

Check 'Add-ProgLog: timestamped line; null / no Log key never throw' {
    $p = New-LogProgress
    & $clMod { param($pp) Add-ProgLog $pp 'log.cl.freed' @('Temp', '1 MB') } $p
    & $clMod { Add-ProgLog $null 'log.cl.freed' @('a', 'b'); Add-ProgLog ([hashtable]::Synchronized(@{})) 'log.cl.freed' @('a', 'b'); Add-ProgLog @{ Log = 5 } 'log.cl.freed' @('a', 'b') }
    $p['Log'].Count -eq 1 -and $p['Log'][0] -match '^\d\d:\d\d:\d\d  .*Temp' -and $p['Log'][0] -match '1 MB'
}
Check 'Add-ProgLog: capped at 500 lines' {
    $p = New-LogProgress
    & $clMod { param($pp) 1..530 | ForEach-Object { Add-ProgLog $pp 'log.cl.start' @("cat$_") } } $p
    $p['Log'].Count -eq 500 -and $p['Log'][0] -match 'cat31\b' -and $p['Log'][499] -match 'cat530\b'
}
Check 'Write-CleanupResultLog: freed / locked files skipped / skipped reason / failed / cancelled' {
    $p = New-LogProgress
    $mk = { param($s, $b, $m) [pscustomobject]@{ Id = 'temp'; Status = $s; FreedBytes = [long]$b; Message = $m } }
    $rs = @((& $mk 'Cleaned' 5MB 'files=10 locked=0'), (& $mk 'Partial' 2MB 'files=9 locked=3'), (& $mk 'Skipped' 0 'needs-admin'),
            (& $mk 'Failed' 0 'access denied'), (& $mk 'Cancelled' 1MB 'prog.cancelled'), (& $mk 'WouldClean' 3MB 'files=4 locked=0'))
    foreach ($r in $rs) { & $clMod { param($pp, $rr) Write-CleanupResultLog $pp $rr } $p $r }
    $l = $p['Log']
    $l.Count -eq 6 -and $l[0] -match '5[.,]0 MB' -and $l[1] -match '2[.,]0 MB' -and $l[1] -match '\b3\b' -and $l[2] -notmatch 'needs-admin' -and
    $l[3] -match 'access denied' -and $l[4] -match '1[.,]0 MB' -and $l[5] -match '3[.,]0 MB'
}
$tr2 = Join-Path $env:UPDATECENTER_DATADIR 'logroot'
New-Item -ItemType Directory -Path $tr2 -Force | Out-Null
1..30 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $tr2 "g$_.tmp"), ('y' * 1000)) }
$env:UPDATECENTER_CLEANUP_TESTROOT = $tr2
try {
    $p = New-LogProgress
    $rd = @(Invoke-Cleanup -Ids 'temp' -DryRun -Progress $p)
    Check 'Invoke-Cleanup -DryRun -Progress: log has start, would-free and done lines; nothing deleted' {
        $l = $p['Log']
        $l.Count -eq 3 -and $l[0] -match [regex]::Escape((T 'cl.temp')) -and $l[1] -match '29[.,]\d KB|30 KB|29 KB' -and $l[2] -match 'KB' -and @(Get-ChildItem $tr2 -File).Count -eq 30
    }
    # Real run with one locked file: category line reports the skipped locked file.
    $fs = [IO.File]::Open((Join-Path $tr2 'g1.tmp'), 'Open', 'ReadWrite', 'None')
    try {
        $p = New-LogProgress
        $rr = @(Invoke-Cleanup -Ids 'temp' -Progress $p)
    } finally { $fs.Dispose() }
    Check 'Invoke-Cleanup real run: Partial, freed X and locked count in the log' {
        $l = $p['Log']
        $rr[0].Status -eq 'Partial' -and $l.Count -eq 3 -and $l[1] -match '\b1\b' -and $l[1] -match 'KB' -and $l[2] -match 'KB' -and @(Get-ChildItem $tr2 -File).Count -eq 1
    }
    $p = New-LogProgress; $p['Cancel'] = $true
    $rc = @(Invoke-Cleanup -Ids 'temp', 'thumbs' -DryRun -Progress $p)
    Check 'Invoke-Cleanup cancelled before start: no category line, a cancelled summary' {
        $rc.Count -eq 2 -and @($rc | Where-Object Status -ne 'Cancelled').Count -eq 0 -and $p['Log'].Count -eq 1
    }
    Check 'Invoke-Cleanup without Log key still works (no log, no error)' {
        $p = [hashtable]::Synchronized(@{})
        $x = @(Invoke-Cleanup -Ids 'temp' -DryRun -Progress $p)
        $x.Count -eq 1 -and -not $p.ContainsKey('Log')
    }
} finally { $env:UPDATECENTER_CLEANUP_TESTROOT = $tr }

Remove-Item Env:\UPDATECENTER_CLEANUP_TESTROOT -ErrorAction SilentlyContinue

# Real deletion engine with a progress table, on a private folder only.
$t2 = Join-Path $env:UPDATECENTER_DATADIR 'engine2'
New-Item -ItemType Directory -Path $t2 -Force | Out-Null
1..40 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $t2 "f$_.tmp"), 'abc') }
$prog = [hashtable]::Synchronized(@{ CanPause = $true })
$r2 = Clear-CleanupFolder -Root $t2 -Progress $prog
Check 'engine with progress table: deletes all files, not cancelled' { $r2.Files -eq 40 -and -not $r2.Cancelled -and @(Get-ChildItem $t2 -File).Count -eq 0 }

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count -gt 0) { Write-Host "FAILED ($($failures.Count)):" -ForegroundColor Red; $failures | ForEach-Object { Write-Host "  $_" }; exit 1 }
Write-Host "All $script:passed checks passed." -ForegroundColor Green
exit 0
