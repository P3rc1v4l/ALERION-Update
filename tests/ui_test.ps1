<#
.SYNOPSIS
    Automated UI test: drives the real window off-screen (settings, save bar, time picker, discard,
    toast) and fails if any check fails. Needs no admin rights and installs nothing.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scan = Join-Path $env:TEMP 'alerion-dry'
$env:UPDATECENTER_DATADIR = if (Test-Path (Join-Path $scan 'state\last-scan.json')) { $scan } else { Join-Path ([IO.Path]::GetTempPath()) ('uc-ui-' + [guid]::NewGuid().ToString('N')) }
$out = Join-Path ([IO.Path]::GetTempPath()) ('uc-ui-result-' + [guid]::NewGuid().ToString('N') + '.txt')
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'src\Gui.ps1') -UiTest $out
if (-not (Test-Path $out)) { Write-Host 'UI test produced no result' -ForegroundColor Red; exit 1 }
$lines = Get-Content $out; Remove-Item $out -Force
$lines | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like 'PASS*') { 'Green' } else { 'Red' }) }
if ($lines | Where-Object { $_ -like 'FAIL*' }) { exit 1 }
Write-Host "All $($lines.Count) UI checks passed." -ForegroundColor Green
