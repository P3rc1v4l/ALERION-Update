<#
.SYNOPSIS
    Removes ALERION Update (tasks, shortcuts, Apps & Features entry, program folder).
.PARAMETER KeepData
    Keep settings, logs and reports in C:\ProgramData\ALERION\Update.
#>
[CmdletBinding()]
param([switch]$KeepData)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($KeepData) { $argList += ' -KeepData' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argList
    exit 0
}

$target = Join-Path $env:ProgramFiles 'ALERION Update'
foreach ($n in @('ALERION Update', 'ALERION Update GUI', 'ALERION Restart')) {
    Unregister-ScheduledTask -TaskPath '\ALERION\' -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'ALERION Update.lnk'),
                   (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\ALERION Update.lnk'))) {
    Remove-Item $lnk -Force -ErrorAction SilentlyContinue
}
Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ALERION Update' -Recurse -Force -ErrorAction SilentlyContinue
if (-not $KeepData) { Remove-Item (Join-Path $env:ProgramData 'ALERION\Update') -Recurse -Force -ErrorAction SilentlyContinue }

# The script may live inside the folder it deletes: remove it from a detached process.
$cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$target' -Recurse -Force -ErrorAction SilentlyContinue"
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList "-NoProfile -Command $cmd"
Write-Host 'ALERION Update removed.' -ForegroundColor Green
