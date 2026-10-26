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

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) failed, $passed passed" -ForegroundColor Red; exit 1 }
Write-Host "All $passed checks passed" -ForegroundColor Green
exit 0
