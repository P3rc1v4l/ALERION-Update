<#
.SYNOPSIS
    Removes Update Center (tasks, shortcuts, Apps & Features entry, program folder) including
    leftovers of older "ALERION Update" versions.
.PARAMETER KeepData
    Keep settings, logs and reports in C:\ProgramData\UpdateCenter.
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

$targets = @((Join-Path $env:ProgramFiles 'Update Center'), (Join-Path $env:ProgramFiles 'ALERION Update'))
foreach ($tp in @('\UpdateCenter\', '\ALERION\')) {
    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'Update Center*' -or $_.TaskName -like 'ALERION*' } |
        ForEach-Object { Unregister-ScheduledTask -TaskPath $tp -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
}
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))) {
    foreach ($name in @('Update Center.lnk', 'ALERION Update.lnk')) { Remove-Item (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue }
}
foreach ($key in @('UpdateCenter', 'ALERION Update')) {
    Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key" -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $KeepData) {
    foreach ($d in @((Join-Path $env:ProgramData 'UpdateCenter'), (Join-Path $env:ProgramData 'ALERION\Update'))) {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The script may live inside the folder it deletes: remove it from a detached process.
$list = ($targets | ForEach-Object { "'$_'" }) -join ','
$cmd = "Start-Sleep -Seconds 2; foreach (`$t in @($list)) { Remove-Item -LiteralPath `$t -Recurse -Force -ErrorAction SilentlyContinue }"
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList "-NoProfile -Command $cmd"
Write-Host 'Update Center removed.' -ForegroundColor Green
