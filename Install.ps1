<#
.SYNOPSIS
    Installs (or upgrades) Update Center: copies the app to Program Files (admin-protected), hardens
    the data folder, registers the scheduled tasks and creates desktop + Start menu shortcuts.
    Older "ALERION Update" installations are migrated (settings + history kept) and removed.
.PARAMETER NoLaunch
    Do not open the app afterwards (it is reopened anyway if it was open before the upgrade).
.PARAMETER Quiet
    Used by the in-app self-update: waits for a running update to finish, no console output.
#>
[CmdletBinding()]
param([switch]$NoLaunch, [switch]$Quiet)

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
function Say { param([string]$Text, [string]$Color = 'Gray') if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color } }

Import-Module (Join-Path $here 'src\Common.psm1') -DisableNameChecking -Force
$product = Get-Product
$target = $product.InstallDir
$legacyRoot = $product.LegacyInstallDir
Say "Installing Update Center to $target" Cyan

# ------------------------------------------------------------------ stop the app (new + old location)
$roots = @($target, $legacyRoot)
$appProcs = { Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $cl = $_.CommandLine; $cl -and @($roots | Where-Object { $cl -like "*$_\src\*" }).Count } }
$deadline = (Get-Date).AddMinutes($(if ($Quiet) { 60 } else { 0 }))
while (@(& $appProcs | Where-Object { $_.CommandLine -like '*UpdateEngine.ps1*' }).Count) {
    if ((Get-Date) -gt $deadline) { throw 'An update run is active - please wait until it has finished.' }
    Start-Sleep -Seconds 10
}
$guiWasOpen = @(& $appProcs | Where-Object { $_.CommandLine -like '*Gui.ps1*' }).Count -gt 0
& $appProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($guiWasOpen) { Start-Sleep -Seconds 1 }

# ------------------------------------------------------------------ copy files
if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
if ((Resolve-Path $here).Path -ne (Resolve-Path $target).Path) {
    foreach ($item in @('src', 'assets', 'VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md', 'Install.ps1', 'Uninstall.ps1')) {
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
}
# Re-import from the installed copy so paths resolve to Program Files.
Import-Module (Join-Path $target 'src\Common.psm1') -DisableNameChecking -Force
Protect-Directory -Path $target
Get-ChildItem $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ data folder + config (migrates v1.x data)
Initialize-DataDir -Harden
$paths = Get-AppPaths
if (-not (Test-Path $paths.ConfigPath)) { Save-Config -Config (Get-DefaultConfig) }
$config = Get-Config

# ------------------------------------------------------------------ scheduled tasks
Import-Module (Join-Path $target 'src\Scheduler.psm1') -DisableNameChecking -Force
Remove-LegacyTasks
Register-GuiTask -AppRoot $target
Register-ScheduleTask -Config $config -AppRoot $target
Set-Autostart -Enabled ([bool]$config.StartWithWindows) -AppRoot $target
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
    $lnk.Description = 'Update Center - keep apps, drivers and Windows up to date'
    $lnk.WorkingDirectory = $target
    $lnk.Save()
    try { [Alerion.ShellUtil]::SetShortcutAppId($Path, (Get-AppUserModelId)) }
    catch { Write-Warning "Could not set AppUserModelID on $Path : $($_.Exception.Message)" }
}
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
foreach ($dir in @($desktop, $startMenu)) { Remove-Item (Join-Path $dir $product.LegacyShortcut) -Force -ErrorAction SilentlyContinue }
New-AppShortcut -Path (Join-Path $desktop $product.ShortcutName)
New-AppShortcut -Path (Join-Path $startMenu $product.ShortcutName)

# ------------------------------------------------------------------ Apps & Features entry
Remove-Item $product.LegacyUninstall -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $product.UninstallKey -Force | Out-Null
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$props = @{
    DisplayName     = 'Update Center'
    DisplayVersion  = (Get-Content (Join-Path $target 'VERSION') -Raw).Trim()
    Publisher       = 'Update Center'
    DisplayIcon     = $icon
    InstallLocation = $target
    UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$target\Uninstall.ps1`""
}
foreach ($k in $props.Keys) { New-ItemProperty -Path $product.UninstallKey -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
New-ItemProperty -Path $product.UninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $product.UninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

# ------------------------------------------------------------------ remove the v1.x installation
if (Test-Path $product.LegacyDataDir) {
    Remove-Item $product.LegacyDataDir -Recurse -Force -ErrorAction SilentlyContinue
    $parent = Split-Path $product.LegacyDataDir -Parent
    if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) { Remove-Item $parent -Force -ErrorAction SilentlyContinue }
}
if (Test-Path $legacyRoot) {
    # This script may be running from the old folder: delete it from a detached process.
    $cmd = "Start-Sleep -Seconds 5; Remove-Item -LiteralPath '$legacyRoot' -Recurse -Force -ErrorAction SilentlyContinue"
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList "-NoProfile -Command $cmd"
}
# Refresh Explorer's icon cache so the new desktop icon shows up immediately.
try { & "$env:WINDIR\System32\ie4uinit.exe" -show } catch { }

Say 'Update Center installed.' Green
Say "Tip: right-click the Update Center icon in the taskbar -> 'Pin to taskbar'."
if (-not $NoLaunch -or $guiWasOpen) { & "$env:WINDIR\System32\schtasks.exe" /run /tn "$($names.Path)$($names.Gui)" | Out-Null }
