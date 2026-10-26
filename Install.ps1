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
    if ($Quiet) { $argList += ' -Quiet' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argList
    exit 0
}
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"
# Compile (Add-Type in Common.psm1) in an admin-only folder, not in the user's %TEMP%.
$env:UPDATECENTER_USERTEMP = $env:TEMP
$privTemp = Join-Path $env:ProgramFiles 'Update Center\tmp'
New-Item -ItemType Directory -Path $privTemp -Force | Out-Null
$env:TEMP = $privTemp; $env:TMP = $privTemp
function Say { param([string]$Text, [string]$Color = 'Gray') if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color } }
# Install log lives in the (admin-only) program folder: ProgramData may not be hardened yet.
$installLog = Join-Path $env:ProgramFiles 'Update Center\install.log'
function Write-InstallLog { param([string]$Text) try { Add-Content -Path $installLog -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch { } }
try { if ((Test-Path $installLog) -and (Get-Item $installLog).Length -gt 512KB) { Remove-Item $installLog -Force } } catch { }
Write-InstallLog "Install from $here (quiet=$Quiet)"
# Any unexpected error is logged (quiet installs have no window) and the app is reopened if it was open.
trap {
    Write-InstallLog ("ERROR: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    if ($runLock) { try { $runLock.Dispose() } catch { } }
    if ($guiWasOpen) { & "$env:WINDIR\System32\schtasks.exe" /run /tn '\UpdateCenter\Update Center GUI' | Out-Null }
    break
}

# ------------------------------------------------------------------ preflight: never start replacing files from an incomplete package
foreach ($r in @('VERSION', 'Install.ps1', 'src\Common.psm1', 'src\Providers.psm1', 'src\UpdateEngine.ps1', 'src\Gui.ps1', 'src\Gui.xaml', 'src\GuiModel.cs',
                 'src\Scheduler.psm1', 'src\Report.psm1', 'src\i18n.json', 'src\config.default.json', 'assets\icon.ico')) {
    $p = Join-Path $here $r
    if (-not (Test-Path $p -PathType Leaf) -or (Get-Item $p).Length -eq 0) {
        Write-InstallLog "ABORT: package incomplete ($r) - nothing was changed"
        if (-not $Quiet) { Write-Host "Package incomplete: $r - nothing was changed." -ForegroundColor Red }
        exit 2
    }
}

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
    if ((Get-Date) -gt $deadline) { Write-InstallLog 'ABORT: an update run is still active'; throw 'An update run is active - please wait until it has finished.' }
    Start-Sleep -Seconds 10
}
# Harden the data folder first (removes planted links, resets owner/ACL), then hold the engine's run lock
# while files are replaced, so no run can start in between.
Initialize-DataDir -Harden
$stateDir = (Get-AppPaths).StateDir
$runLock = $null
while (-not $runLock) {
    try { $runLock = [IO.File]::Open((Join-Path $stateDir 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { if ((Get-Date) -gt $deadline) { Write-InstallLog 'ABORT: run lock busy'; throw 'An update run is active - please wait until it has finished.' }; Start-Sleep -Seconds 5 }
}
$guiWasOpen = @(& $appProcs | Where-Object { $_.CommandLine -like '*Gui.ps1*' }).Count -gt 0
& $appProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($guiWasOpen) { Start-Sleep -Seconds 1 }

# ------------------------------------------------------------------ copy files (with backup + automatic rollback)
if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
$backup = "$target.bak"
if ((Resolve-Path $here).Path -ne (Resolve-Path $target).Path) {
    $items = @('src', 'assets', 'VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md', 'Install.ps1', 'Uninstall.ps1', 'UpdateCenter.cat')
    Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $target 'src')) {
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($item in $items) { $p = Join-Path $target $item; if (Test-Path $p) { Copy-Item $p -Destination (Join-Path $backup $item) -Recurse -Force } }
    }
    try {
        foreach ($item in $items) {
            $from = Join-Path $here $item
            $to = Join-Path $target $item
            if (-not (Test-Path $from)) {
                # The package has no signed catalog any more: drop the old one, it would not match.
                if ($item -eq 'UpdateCenter.cat') { Remove-Item $to -Force -ErrorAction SilentlyContinue }
                continue
            }
            if (Test-Path $from -PathType Container) {
                # Replace folders completely (copying a folder onto an existing one would nest it).
                if (Test-Path $to) { Remove-Item $to -Recurse -Force }
                Copy-Item $from -Destination $to -Recurse -Force
            } else {
                Copy-Item $from -Destination $to -Force
            }
        }
        if (-not (Test-Path (Join-Path $target 'src\UpdateEngine.ps1'))) { throw 'copy verification failed' }
    } catch {
        $why = $_.Exception.Message
        Write-InstallLog "ERROR while copying: $why - restoring the previous version"
        if (Test-Path $backup) {
            foreach ($item in $items) {
                $b = Join-Path $backup $item; $t = Join-Path $target $item
                Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue   # also drops items that are new in the package
                if (Test-Path $b) { Copy-Item $b -Destination $t -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        $runLock.Dispose()
        if ($guiWasOpen) { & "$env:WINDIR\System32\schtasks.exe" /run /tn '\UpdateCenter\Update Center GUI' | Out-Null }
        if (-not $Quiet) { Write-Host "Installation failed ($why). The previous version was restored. Log: $installLog" -ForegroundColor Red }
        exit 1
    }
    Write-InstallLog 'Files copied'
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
Set-BackgroundCheck -Interval ([string]$config.CheckInterval) -AppRoot $target
Set-CleanupSchedule -Schedule ([string]$config.CleanupSchedule) -AppRoot $target
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
# (only once its settings have arrived in the new data folder)
if ((Test-Path $product.LegacyDataDir) -and (Test-Path $paths.ConfigPath)) {
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

$runLock.Dispose()
Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
Write-InstallLog ("Installed version {0}" -f (Get-Content (Join-Path $target 'VERSION') -Raw).Trim())
# Started from a self-update staging folder: remove it once this script has exited.
$staging = Join-Path $env:ProgramFiles 'UpdateCenter-Update'
if ($here.StartsWith($staging, [StringComparison]::OrdinalIgnoreCase)) {
    $cmd = "Start-Sleep -Seconds 10; Remove-Item -LiteralPath '$staging' -Recurse -Force -ErrorAction SilentlyContinue"
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -ArgumentList "-NoProfile -Command $cmd"
}
Say 'Update Center installed.' Green
if ($Quiet) {
    # In-app/background update: tell the user it happened (the app reopens only if it was open).
    try { Import-I18n -Language $config.Language; Show-Toast -Title (T 'toast.appUpdated' @((Get-Content (Join-Path $target 'VERSION') -Raw).Trim())) -Body (T 'toast.appUpdatedBody') } catch { }
}
Say "Tip: right-click the Update Center icon in the taskbar -> 'Pin to taskbar'."
if (-not $NoLaunch -or $guiWasOpen) { & "$env:WINDIR\System32\schtasks.exe" /run /tn "$($names.Path)$($names.Gui)" | Out-Null }
