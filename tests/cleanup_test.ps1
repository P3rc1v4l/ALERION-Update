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

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count -gt 0) { Write-Host "FAILED ($($failures.Count)):" -ForegroundColor Red; $failures | ForEach-Object { Write-Host "  $_" }; exit 1 }
Write-Host "All $script:passed checks passed." -ForegroundColor Green
exit 0
