<#
.SYNOPSIS
    Installs ALERION Update: copies the app to Program Files (admin-protected), hardens the data
    folder, registers the scheduled tasks and creates desktop + Start menu shortcuts.
.PARAMETER NoLaunch
    Do not open the app after installation.
#>
[CmdletBinding()]
param([switch]$NoLaunch)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoLaunch) { $argList += ' -NoLaunch' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argList
    exit 0
}
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"

$target = Join-Path $env:ProgramFiles 'ALERION Update'
Write-Host "Installing ALERION Update to $target" -ForegroundColor Cyan

# ------------------------------------------------------------------ copy files
# Close an open ALERION Update window (upgrade) so its files can be replaced. A running
# update engine is left alone - installing during a run is refused instead.
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*$target\src\*" }
if ($running | Where-Object { $_.CommandLine -like '*UpdateEngine.ps1*' }) { throw 'An ALERION Update run is active - please wait until it has finished.' }
$running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($running) { Start-Sleep -Seconds 1 }
if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
foreach ($item in @('src', 'assets', 'VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md', 'Uninstall.ps1')) {
    $from = Join-Path $here $item
    $to = Join-Path $target $item
    if (-not (Test-Path $from)) { continue }
    if (Test-Path $from -PathType Container) {
        # Replace folders completely (copying a folder onto an existing one would nest it).
        if (Test-Path $to) { Remove-Item $to -Recurse -Force }
        Copy-Item $from -Destination $to -Recurse -Force
    } else {
        Copy-Item $from -Destination $to -Force
    }
}
# Program Files inherits "Administrators/SYSTEM write, Users read" - enforce it in case the
# folder existed before with weaker permissions.
Import-Module (Join-Path $target 'src\Common.psm1') -DisableNameChecking -Force
Protect-Directory -Path $target
Get-ChildItem $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ data folder + config
Initialize-DataDir -Harden
$paths = Get-AppPaths
if (-not (Test-Path $paths.ConfigPath)) { Save-Config -Config (Get-DefaultConfig) }
$config = Get-Config

# ------------------------------------------------------------------ scheduled tasks
Import-Module (Join-Path $target 'src\Scheduler.psm1') -DisableNameChecking -Force
Register-GuiTask -AppRoot $target
Register-ScheduleTask -Config $config -AppRoot $target
$names = Get-TaskNames

# ------------------------------------------------------------------ shortcuts
$icon = Join-Path $target 'assets\icon.ico'
$shell = New-Object -ComObject WScript.Shell
function New-AppShortcut {
    param([string]$Path)
    $lnk = $shell.CreateShortcut($Path)
    # conhost --headless starts the elevated GUI task without flashing a console window.
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
    $lnk.Arguments = "--headless `"$env:WINDIR\System32\schtasks.exe`" /run /tn `"$($names.Path)$($names.Gui)`""
    $lnk.IconLocation = "$icon,0"
    $lnk.Description = 'ALERION Update - keep apps, drivers and Windows up to date'
    $lnk.WorkingDirectory = $target
    $lnk.Save()
    try { [Alerion.ShellUtil]::SetShortcutAppId($Path, (Get-AppUserModelId)) }
    catch { Write-Warning "Could not set AppUserModelID on $Path : $($_.Exception.Message)" }
}
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
New-AppShortcut -Path (Join-Path $desktop 'ALERION Update.lnk')
New-AppShortcut -Path (Join-Path $startMenu 'ALERION Update.lnk')

# ------------------------------------------------------------------ Apps & Features entry
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ALERION Update'
New-Item -Path $uninstallKey -Force | Out-Null
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$props = @{
    DisplayName     = 'ALERION Update'
    DisplayVersion  = (Get-Content (Join-Path $target 'VERSION') -Raw).Trim()
    Publisher       = 'ALERION Studios'
    DisplayIcon     = $icon
    InstallLocation = $target
    UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$target\Uninstall.ps1`""
    URLInfoAbout    = 'https://discord.gg/tnfgta33uj'
}
foreach ($k in $props.Keys) { New-ItemProperty -Path $uninstallKey -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
New-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host 'ALERION Update installed.' -ForegroundColor Green
Write-Host "Tip: right-click the Start menu entry 'ALERION Update' -> 'Pin to taskbar'."
if (-not $NoLaunch) { & "$env:WINDIR\System32\schtasks.exe" /run /tn "$($names.Path)$($names.Gui)" | Out-Null }
