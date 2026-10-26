<#
.SYNOPSIS
    Update Center - WPF user interface (overview, update list with search/selection, history, settings).
    Layout and styles live in Gui.xaml; this file wires up data and behaviour.
.PARAMETER Monitor
    Opened by a scheduled run: shows the progress of the already running engine.
.PARAMETER Snapshot
    Development aid: renders a page to a PNG off-screen and exits (design checks / docs).
.PARAMETER Preview
    Development aid: shows the window without admin rights and without starting the engine.
#>
[CmdletBinding()]
param(
    [switch]$Monitor,
    [string]$Snapshot,
    [string]$UiTest,
    [switch]$Preview,
    [ValidateSet('Overview', 'Updates', 'Programs', 'Startup', 'Cleanup', 'Security', 'History', 'Settings')][string]$Page = 'Overview',
    [string]$Query,
    [switch]$Minimized,
    [ValidateSet('', 'Restart', 'Info')][string]$Dialog = '',
    [int]$X = -1,
    [int]$Y = -1
)

$ErrorActionPreference = 'Stop'
# Never fail silently: log unexpected GUI errors and tell the user where the log is.
trap {
    $msg = "{0:yyyy-MM-dd HH:mm:ss} {1}`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace
    $logDir = Join-Path $env:ProgramData 'UpdateCenter\logs'
    try { Add-Content -Path (Join-Path $logDir 'gui-error.log') -Value $msg -Encoding UTF8 } catch { }
    if (-not $Snapshot) {
        try { [void][System.Windows.MessageBox]::Show("Update Center: $($_.Exception.Message)`n`n$logDir\gui-error.log", 'Update Center', 'OK', 'Error') } catch { }
    }
    break
}
# Only load modules from admin-protected locations (see UpdateEngine.ps1).
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$src = $PSScriptRoot
# Elevated + installed: compile (Add-Type) and unpack in an admin-only temp folder, never in the user's
# %TEMP% (a normal process of the same user could swap files there between compile and load).
$appRootDir = Split-Path $PSScriptRoot -Parent
if ($appRootDir -like "$env:ProgramFiles\*" -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $privTemp = Join-Path $appRootDir 'tmp'
    if (-not (Test-Path $privTemp)) { New-Item -ItemType Directory -Path $privTemp -Force | Out-Null }
    $env:TEMP = $privTemp; $env:TMP = $privTemp
}Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Report.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Scheduler.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Providers.psm1') -DisableNameChecking -Force
$devMode = [bool]($Snapshot -or $Preview -or $UiTest)

# ------------------------------------------------------------------ elevation
if (-not (Test-IsAdmin) -and -not $devMode) {
    # Normally never reached: the shortcut starts the elevated GUI task. Fallback for manual starts.
    $names = Get-TaskNames
    if (Test-GuiTask) {
        & "$env:WINDIR\System32\schtasks.exe" /run /tn "$($names.Path)$($names.Gui)" | Out-Null
    } else {
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    exit 0
}

# ------------------------------------------------------------------ single window
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\UpdateCenter-GUI-Show')
$guiMutex = New-Object System.Threading.Mutex($false, 'Local\UpdateCenter-GUI')
if (-not $devMode -and -not $guiMutex.WaitOne(0)) { [void]$showEvent.Set(); exit 0 }

if (-not ('Alerion.UpdateRow' -as [type])) {
    Add-Type -TypeDefinition (Get-Content (Join-Path $src 'GuiModel.cs') -Raw) -ReferencedAssemblies PresentationCore, WindowsBase, System.Xaml
}

Initialize-DataDir -Harden
[Alerion.ShellUtil]::SetProcessAppId((Get-AppUserModelId))
$config = Get-Config
Import-I18n -Language $config.Language
$paths = Get-AppPaths
$version = Get-AppVersion

# ------------------------------------------------------------------ window
$window = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $src 'Gui.xaml') -Raw -Encoding UTF8))
$ui = @{}
foreach ($m in [regex]::Matches((Get-Content (Join-Path $src 'Gui.xaml') -Raw), 'x:Name="([^"]+)"')) {
    $el = $window.FindName($m.Groups[1].Value); if ($el) { $ui[$m.Groups[1].Value] = $el }
}
$largeLogo = Join-Path $paths.AppRoot 'assets\logo.png'
function Get-ImageNoLock { param([string]$Path)
    <# Loads an image fully into memory. Loading by URI keeps the file open, which blocks updates of
       the program folder while the window is open. #>
    $ms = New-Object System.IO.MemoryStream(, [IO.File]::ReadAllBytes($Path))
    $img = [Windows.Media.Imaging.BitmapFrame]::Create($ms, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $img.Freeze(); return $img
}
if (Test-Path $paths.IconPath) { $window.Icon = Get-ImageNoLock $paths.IconPath }
if (Test-Path $paths.LogoPath) { $ui.Logo.Source = Get-ImageNoLock $paths.LogoPath }
if (Test-Path $largeLogo) { $ui.HeroLogo.Source = Get-ImageNoLock $largeLogo }

$brushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush { param([string]$Hex) $brushConverter.ConvertFromString($Hex) }

# ------------------------------------------------------------------ appearance (accent colour, size)
$accentPalettes = [ordered]@{
    Blue   = @('#22D3EE', '#2F86FF', '#3D5CFF'); Violet = @('#C084FC', '#8B5CF6', '#6D28D9'); Green = @('#34D399', '#10B981', '#059669')
    Orange = @('#FBBF24', '#F59E0B', '#EA580C'); Pink   = @('#F472B6', '#EC4899', '#DB2777'); Teal  = @('#2DD4BF', '#14B8A6', '#0D9488')
}
function New-AccentBrush { param([string[]]$Stops, [double]$Lighten = 0)
    $b = New-Object System.Windows.Media.LinearGradientBrush; $b.StartPoint = '0,0'; $b.EndPoint = '1,0'
    $offsets = @(0, 0.55, 1)
    for ($i = 0; $i -lt 3; $i++) {
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Stops[$i])
        if ($Lighten) { $c = [System.Windows.Media.Color]::FromRgb([byte]($c.R + (255 - $c.R) * $Lighten), [byte]($c.G + (255 - $c.G) * $Lighten), [byte]($c.B + (255 - $c.B) * $Lighten)) }
        $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c, $offsets[$i])))
    }
    $b.Freeze(); return $b
}
function Set-Appearance { param([string]$Accent, [int]$Scale)
    $stops = if ($accentPalettes.Contains($Accent)) { $accentPalettes[$Accent] } else { $accentPalettes['Blue'] }
    # [Brush] cast: PowerShell would otherwise store a PSObject wrapper that WPF rejects as a brush.
    $window.Resources['Accent'] = [System.Windows.Media.Brush](New-AccentBrush $stops)
    $window.Resources['AccentHover'] = [System.Windows.Media.Brush](New-AccentBrush $stops 0.15)
    $s = [Math]::Max(0.8, [Math]::Min(1.4, $Scale / 100.0))
    $ui.Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($s, $s)
    $window.MinWidth = 1000 * $s; $window.MinHeight = 640 * $s
    if ($window.Width -lt $window.MinWidth) { $window.Width = $window.MinWidth }
    if ($window.Height -lt $window.MinHeight) { $window.Height = $window.MinHeight }
    $window.Resources['AccentSolid'] = [System.Windows.Media.Brush](New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($stops[1])))
}

# The window is opaque with its own rounded frame + shadow (Gui.xaml); no DWM glass any more.
$window.Add_SourceInitialized({ [Alerion.WindowFix]::Attach((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) })

# ------------------------------------------------------------------ state
$prioColors  = @{ Critical = '#FF453A'; Important = '#FF9F0A'; Normal = '#3D7BFF'; Optional = '#8A93A1' }
$prioRank    = @{ Critical = 0; Important = 1; Normal = 2; Optional = 3 }
$stateColors = @{ Pending = '#8A93A1'; Running = '#6FA8FF'; Done = '#30D158'; Failed = '#FF6B61'; Skipped = '#8A93A1'; Current = '#30D158' }
$statusColors = @{ Updated = '#30D158'; Failed = '#FF6B61'; Skipped = '#8A93A1'; Info = '#8A93A1'; Available = '#6FA8FF'; Triggered = '#6FA8FF' }
$rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.UpdateRow]'
$view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($rows)
$ui.UpdateList.ItemsSource = $rows
$script:segment = 'All'
$script:search = ''
$script:running = $false
$script:runMode = ''
$script:loading = $false
$script:scanAt = $null
$script:wasRunning = $false
$script:estimate = $null
$sourceKeys = @('Winget', 'WingetIncludeUnknown', 'Chocolatey', 'Store', 'WindowsUpdate', 'WindowsUpdateDrivers', 'MicrosoftUpdate', 'Nvidia', 'Defender', 'Office', 'Oem', 'SelfUpdaters')
$sourceBoxes = @{}
$sourceRows = @{}

function New-ComboItem { param($Tag, $Text) $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Tag = $Tag; $i.Content = $Text; $i }
function Select-ComboTag { param($Combo, $Tag) foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq [string]$Tag) { $Combo.SelectedItem = $i; return } }; if ($Combo.Items.Count) { $Combo.SelectedIndex = 0 } }
function Format-When { param($Date)
    if (-not $Date) { return (T 'ov.never') }
    $d = ConvertTo-DateSafe $Date; if (-not $d) { return (T 'ov.never') }; $span = (Get-Date) - $d
    if ($span.TotalMinutes -lt 1) { return (T 'time.justNow') }
    if ($span.TotalMinutes -lt 60) { return (T 'time.minutesAgo' @([int]$span.TotalMinutes)) }
    if ($d.Date -eq (Get-Date).Date) { return (T 'time.todayAt' @($d.ToString('HH:mm'))) }
    return $d.ToString('ddd, dd.MM.  HH:mm')
}
function ConvertTo-DateSafe { param($Value)
    <# Dates from files (reports, status, scan) may be missing or damaged: never throw, return $null. #>
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$d)) { return $d } else { return $null }
}
function Format-At { param([datetime]$At)
    if ($At.Date -eq (Get-Date).Date) { return (T 'time.todayAt' @($At.ToString('HH:mm'))) }
    if ($At.Date -eq (Get-Date).Date.AddDays(1)) { return (T 'time.tomorrowAt' @($At.ToString('HH:mm'))) }
    return $At.ToString('ddd, dd.MM.  HH:mm')
}

# ------------------------------------------------------------------ in-app dialog
$script:dialogQueue = New-Object System.Collections.Generic.Queue[hashtable]
$script:dialogModal = $false
function Close-Dialog {
    $ui.DialogLayer.Visibility = 'Collapsed'; $ui.DlgExtra.Children.Clear(); $ui.DlgButtons.Children.Clear(); $ui.DialogCard.Width = 470; $script:logView = $null; $script:dialogModal = $false
    # dialogs that arrived while another one was open are shown by the timer (Show-QueuedDialog)
}
function Show-QueuedDialog { if ($script:dialogQueue.Count -and $ui.DialogLayer.Visibility -ne 'Visible') { $next = $script:dialogQueue.Dequeue(); Show-Dialog @next } }

function Show-Dialog {
    <# Modal card inside the window. Buttons: @{ Text; Kind = Primary|Secondary|Danger|Ghost; Action = {...} } #>
    param([string]$Title, [string]$Text, [string]$Glyph = [string][char]0xE946, [string[]]$Colors = @('#22D3EE', '#2F6BFF'),
          [object[]]$Buttons = @(), [System.Windows.UIElement[]]$Extra = @(), [switch]$Modal)
    # Never replace an open dialog (e.g. a confirmation) with one that arrives from a background result.
    if ($ui.DialogLayer.Visibility -eq 'Visible') {
        $script:dialogQueue.Enqueue(@{ Title = $Title; Text = $Text; Glyph = $Glyph; Colors = $Colors; Buttons = $Buttons; Extra = $Extra; Modal = $Modal })
        return
    }
    Close-Dialog
    $script:dialogModal = [bool]$Modal   # modal: no closing by Esc or by clicking the dim background
    $ui.DlgTitle.Text = $Title; $ui.DlgText.Text = $Text; $ui.DlgIcon.Text = $Glyph
    $ui.DlgText.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = '0,0'; $g.EndPoint = '1,1'
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[0])), 0))
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($Colors[-1])), 1))
    $ui.DlgIconBg.Background = $g
    foreach ($e in $Extra) { [void]$ui.DlgExtra.Children.Add($e) }
    $ui.DlgExtra.Visibility = if ($Extra.Count) { 'Visible' } else { 'Collapsed' }
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $b.Text
        $btn.Style = $window.FindResource($(if ($b.Kind) { $b.Kind } else { 'Secondary' }))
        $btn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $btn.HorizontalAlignment = 'Stretch'
        $btn.Tag = @{ Action = $b.Action; Context = $b.Context }
        $btn.Add_Click({ param($s) $tag = $s.Tag; Close-Dialog; if ($tag.Action) { & $tag.Action $tag.Context } })
        [void]$ui.DlgButtons.Children.Add($btn)
    }
    $ui.DialogLayer.Visibility = 'Visible'
    # small "pop" animation
    $ui.DialogCard.Opacity = 0
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(160))
    $pop = New-Object System.Windows.Media.Animation.DoubleAnimation(0.94, 1, [TimeSpan]::FromMilliseconds(220))
    $pop.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $ui.DialogCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $ui.DialogScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $pop)
    $ui.DialogScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $pop)
}

function New-InfoLine { param([string]$Glyph, [string]$Text, [string]$Color = '#A3ABB8')
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $g = New-Object System.Windows.Controls.TextBlock; $g.Text = $Glyph; $g.FontFamily = $window.FindResource('Icons'); $g.Foreground = Get-Brush $Color; $g.Margin = [System.Windows.Thickness]::new(0, 2, 10, 0)
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.Foreground = Get-Brush $Color; $t.TextWrapping = 'Wrap'; $t.TextTrimming = 'None'; $t.MaxWidth = 380
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($t); return $sp
}

# ------------------------------------------------------------------ restart
function Get-Estimate {
    if (-not $script:estimate) {
        $servicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $script:estimate = Get-RestartEstimate -WithUpdates $servicing
    }
    return $script:estimate
}

function Get-EstimateText {
    $e = Get-Estimate
    $t = T 'restart.duration' @(Format-RestartEstimate -Estimate $e)
    if ($e.WithUpdates) { $t += ' ' + (T 'restart.withUpdates') }
    return $t
}

function Start-RestartNow {
    if ($devMode) { return }
    Invoke-RestartNow -Seconds 15 -Message (T 'toast.restartNow')
    Show-Dialog -Modal -Title (T 'dlg.restartingTitle') -Text (T 'dlg.restartingText') -Glyph ([string][char]0xE777) -Colors @('#FFB020', '#FF6A3D') -Buttons @(
        @{ Text = T 'dlg.cancelRestart'; Kind = 'Secondary'; Action = { & "$env:WINDIR\System32\shutdown.exe" /a; Update-RebootBanner } })
}

function Set-PlannedRestart { param([string]$Time)
    if ($Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Show-Dialog -Title (T 'set.invalid' @($Time)) -Glyph ([string][char]0xE783) -Colors @('#FF6B6B', '#E0306E') -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' }); return }
    $at = Get-NextTimeOfDay -Time $Time
    if (-not $devMode) { Register-RestartTask -At $at -Message (T 'toast.plannedRebootNow') }
    Update-RebootBanner
    Show-Dialog -Title (T 'dlg.plannedTitle' @(Format-At $at)) -Text (T 'dlg.plannedText') -Glyph ([string][char]0xE823) -Buttons @(@{ Text = 'OK'; Kind = 'Primary' })
}

function Show-RestartDialog { param($Plan)
    $extra = @(New-InfoLine ([string][char]0xE916) (Get-EstimateText))
    $planned = if ($devMode) { $null } else { Get-PlannedRestart }
    if ($planned) { $extra += New-InfoLine ([string][char]0xE823) (T 'restart.plannedAt' @(Format-At $planned)) '#6FA8FF' }
    if ($Plan -and $Plan.Mode -eq 'Auto') { $extra += New-InfoLine ([string][char]0xE7BA) (T 'restart.autoRunning') '#FFB340' }

    # "restart at" row: time box + button
    $row = New-Object System.Windows.Controls.Grid; $row.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $box = New-Object System.Windows.Controls.TextBox; $box.Width = 90; $box.HorizontalAlignment = 'Left'; $box.Text = $config.RebootTime
    Add-TimePicker $box
    $plan = New-Object System.Windows.Controls.Button; $plan.Style = $window.FindResource('Secondary'); $plan.Margin = [System.Windows.Thickness]::new(100, 0, 0, 0)
    $plan.Content = T 'dlg.restartAt'; $plan.Tag = $box
    $plan.Add_Click({ param($s) $t = $s.Tag.Text.Trim(); Close-Dialog; Set-PlannedRestart -Time $t })
    [void]$row.Children.Add($box); [void]$row.Children.Add($plan)
    $extra += $row

    $buttons = @(@{ Text = T 'dlg.restartNow'; Kind = 'Primary'; Action = { Start-RestartNow } })
    if ($Plan -and $Plan.Mode -eq 'Auto') { $buttons += @{ Text = T 'dlg.cancelRestart'; Kind = 'Danger'; Action = { & "$env:WINDIR\System32\shutdown.exe" /a } } }
    if ($planned) { $buttons += @{ Text = T 'dlg.cancelPlanned'; Kind = 'Danger'; Action = { Unregister-RestartTask; Update-RebootBanner } } }
    $buttons += @{ Text = T 'dlg.later'; Kind = 'Ghost' }
    Show-Dialog -Title (T 'dlg.restartTitle') -Text (T 'dlg.restartText') -Glyph ([string][char]0xE777) -Colors @('#FFB020', '#FF6A3D') -Buttons $buttons -Extra $extra
}

function Update-RebootBanner {
    $planned = if ($devMode) { $null } else { Get-PlannedRestart }
    $pending = Test-PendingReboot
    $ui.RebootBanner.Visibility = if ($pending -or $planned) { 'Visible' } else { 'Collapsed' }
    $ui.TxtRebootBanner.Text = if ($planned) { T 'restart.plannedAt' @(Format-At $planned) } else { T 'ov.rebootPending' }
    $ui.TxtRebootBannerSub.Text = Get-EstimateText
    $ui.BtnRestart.Content = T 'ov.restartOptions'
}

# ------------------------------------------------------------------ texts
function Set-Texts {
    $ui.TxtNavOverview.Text = T 'nav.overview'; $ui.TxtNavUpdates.Text = T 'nav.updates'; $ui.TxtNavHistory.Text = T 'nav.history'
    $ui.TxtNavPrograms.Text = T 'nav.programs'; $ui.TxtNavCleanup.Text = T 'nav.cleanup'; $ui.TxtNavSecurity.Text = T 'nav.security'; $ui.TxtNavStartup.Text = T 'startup.title'
    $ui.TxtStartupTitle.Text = T 'startup.title'; $ui.TxtStartupSub.Text = T 'startup.subtitle'; $ui.TxtStartSearchHint.Text = T 'pg.search'; $ui.BtnStartRefresh.Content = T 'startup.refresh'
    $ui.SegStartAll.Content = T 'startup.seg.standard'; $ui.SegStartOn.Content = T 'startup.seg.advanced'; $ui.SegStartOff.Content = T 'startup.seg.off'; $ui.BtnStartAdd.Content = T 'startup.add.button'
    $ui.LblActivities.Text = (T 'act.title').ToUpper(); $window.Resources['OpenText'] = T 'act.open'; $window.Resources['LogText'] = T 'sec.showLogShort'; $window.Resources['CancelText'] = T 'prog.cancel'
    $ui.BtnCleanupCancel.Content = T 'prog.cancel'
    foreach ($m in 'Programs', 'Startup', 'Cleanup', 'Security') { $ui["LblMod$m"].Text = $(if ($m -eq 'Startup') { T 'startup.title' } else { T ('nav.' + $m.ToLower()) }) }
    $ui.TxtQaScan.Text = T 'ov.qa.scan'; $ui.TxtQaQuick.Text = T 'ov.qa.quick'; $ui.TxtQaClean.Text = T 'ov.qa.clean'; $ui.TxtQaHistory.Text = T 'ov.qa.history'
    $ui.LblRecent.Text = (T 'ov.recent').ToUpper(); $ui.BtnRecentAll.Content = T 'ov.recentAll'
    $ui.LblLook.Text = (T 'set.look').ToUpper(); $ui.LblAccent.Text = T 'set.accent'; $ui.LblScale.Text = T 'set.scale'; $ui.TxtScaleHint.Text = T 'set.scaleHint'; $ui.LblStartPage.Text = T 'set.startPage'
    $ui.ChkTray.Content = T 'set.tray'; $ui.LblRunning.Text = T 'set.running'; $ui.TxtRunningHint.Text = T 'set.runningHint'
    $ui.LblDrivers.Text = (T 'set.driversSection').ToUpper(); $ui.LblNvidia.Text = T 'set.nvidia'; $ui.TxtNvidiaHint.Text = T 'set.nvidiaHint'
    $ui.ChkBackupDrivers.Content = T 'set.backupDrivers'; $ui.LblCleanSched.Text = T 'set.cleanSched'; $ui.TxtCleanSchedHint.Text = T 'set.cleanSchedHint'
    $ui.TxtProgramsTitle.Text = T 'nav.programs'; $ui.TxtProgSearchHint.Text = T 'pg.search'; $ui.SegProgAll.Content = T 'pg.segAll'; $ui.SegProgProtected.Content = T 'pg.segProtected'
    $ui.BtnProgRefresh.Content = T 'pg.refresh'; $ui.TxtProgramsSub.Text = T 'pg.subIntro'
    $ui.CmbProgSort.Items.Clear(); foreach ($s in 'name', 'size', 'date') { [void]$ui.CmbProgSort.Items.Add((New-ComboItem $s (T "pg.sort.$s"))) }; $ui.CmbProgSort.SelectedIndex = 0
    $ui.TxtCleanupTitle.Text = T 'nav.cleanup'; $ui.TxtCleanupSub.Text = T 'cl.sub'; $ui.BtnCleanupScan.Content = T 'cl.scan'
    $ui.TxtSecurityTitle.Text = T 'nav.security'; $ui.BtnSecRefresh.Content = T 'sec.refresh'; $ui.LblSecScans.Text = (T 'pg.secScans').ToUpper(); $ui.LblSecStatus.Text = (T 'pg.secStatus').ToUpper(); $ui.LblSecThreats.Text = (T 'sec.history').ToUpper()
    Set-ScanTexts
    $ui.TxtNavSettings.Text = T 'nav.settings'; $ui.TxtSidebarSub.Text = T 'app.subtitle'; $ui.TxtVersion.Text = T 'app.version' @($version)
    $ui.BtnClose.ToolTip = T 'win.close'; $ui.BtnMin.ToolTip = T 'win.minimize'; $ui.BtnMax.ToolTip = T 'win.maximize'
    $ui.TxtOverviewTitle.Text = T 'nav.overview'
    $ui.BtnScan.Content = T 'ov.scan'; $ui.BtnCancel.Content = T 'ov.cancel'
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["LblTile$p"].Text = T "prio.$p" }
    $ui.LblLastScan.Text = T 'ov.lastScan'; $ui.LblLastRun.Text = T 'ov.lastRun'; $ui.LblNext.Text = T 'ov.nextRun'
    $ui.LblLog.Text = T 'ov.log'; $ui.BtnToggleLog.Content = if ($ui.LogList.Visibility -eq 'Visible') { T 'ov.hideLog' } else { T 'ov.showLog' }
    $ui.TxtUpdatesTitle.Text = T 'nav.updates'; $ui.TxtSearchHint.Text = T 'up.search'
    $ui.SegAll.Content = T 'seg.all'; $ui.SegCritical.Content = T 'prio.Critical'; $ui.SegImportant.Content = T 'prio.Important'
    $ui.SegNormal.Content = T 'prio.Normal'; $ui.SegOptional.Content = T 'prio.Optional'; $ui.SegExcluded.Content = T 'seg.excluded'; $ui.SegInstalled.Content = T 'seg.installed'
    $ui.BtnSelectNone.Content = T 'up.selectNone'; $window.Resources['SelectAllText'] = T 'up.selectAll'
    $ui.TxtHistoryTitle.Text = T 'nav.history'; $ui.BtnHtml.Content = T 'rep.openHtml'; $ui.BtnLogs.Content = T 'rep.openLogs'; $ui.BtnCopyReport.Content = T 'rep.copy'
    $ui.ColSource.Header = T 'rep.colSource'; $ui.ColName.Header = T 'rep.colName'; $ui.ColFrom.Header = T 'rep.colFrom'
    $ui.ColTo.Header = T 'rep.colTo'; $ui.ColStatus.Header = T 'rep.colStatus'; $ui.ColNote.Header = T 'rep.colNote'
    $ui.TxtSettingsTitle.Text = T 'nav.settings'
    $ui.LblCheck.Text = T 'set.check'; $ui.TxtCheckHint.Text = T 'set.checkHint'
    $ui.LblAuto.Text = (T 'set.auto').ToUpper(); $ui.LblSchType.Text = T 'set.scheduleType'; $ui.LblDay.Text = T 'set.day'; $ui.LblDom.Text = T 'set.dayOfMonth'
    $ui.LblTime.Text = T 'set.time'; $ui.LblAction.Text = T 'set.action'; $ui.RbActInstall.Content = T 'set.act.Install'; $ui.RbActNotify.Content = T 'set.act.Notify'
    $ui.LblAutoPrio.Text = T 'set.autoPrio'
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["ChkPrio$p"].Content = T "prio.$p" }
    $ui.ChkWake.Content = T 'set.wake'
    $ui.LblRestartSection.Text = (T 'set.restartSection').ToUpper(); $ui.LblReboot.Text = T 'set.reboot'; $ui.LblRebootTime.Text = T 'set.rebootTime'
    $ui.LblBehavior.Text = (T 'set.behavior').ToUpper(); $ui.LblMode2.Text = T 'set.mode'; $ui.RbVisible.Content = T 'set.mode.Visible'; $ui.RbSilent.Content = T 'set.mode.Silent'
    $ui.ChkParallel.Content = T 'set.parallel'; $ui.ChkRestore.Content = T 'set.restore'; $ui.LblLang.Text = T 'set.language'
    $ui.LblSources.Text = (T 'set.sources').ToUpper(); $ui.LblExcl.Text = (T 'set.exclusions').ToUpper(); $ui.TxtExclHint.Text = T 'set.exclHint'; $ui.BtnExclAdd.Content = T 'set.exclAdd'
    $ui.LblSelf.Text = (T 'set.selfTitle').ToUpper(); $ui.ChkSelf.Content = T 'set.selfUpdate'; $ui.LblRepo.Text = T 'set.selfRepo'
    $ui.ChkAutostart.Content = T 'set.autostart'; $ui.LblNotify.Text = T 'set.notify'; $ui.TxtNotifyHint.Text = T 'set.notifyHint'; $ui.BtnTestToast.Content = T 'set.testToast'
    $ui.LblAppVersion.Text = T 'set.appVersion' @($version); $ui.TxtAppUpdateStatus.Text = T 'set.appCheckHint'; $ui.BtnCheckAppUpdate.Content = T 'set.checkUpdate'
    $ui.BtnSave.Content = T 'set.save'; $ui.BtnDiscard.Content = T 'set.discard'
    foreach ($k in $sourceKeys) { $sourceBoxes[$k].Content = T "set.src.$k" }
    $e = Get-Estimate
    $ui.TxtRestartEstimate.Text = if ($e.Measured) { T 'set.estimateMeasured' @((Format-RestartEstimate -Estimate (Get-RestartEstimate -WithUpdates $false)), $e.Samples) } else { T 'set.estimateDefault' }

    $script:loading = $true
    $ui.CmbSchedule.Items.Clear(); foreach ($s in 'Manual', 'Daily', 'Weekly', 'BiWeekly', 'Monthly') { [void]$ui.CmbSchedule.Items.Add((New-ComboItem $s (T "set.sch.$s"))) }
    $ui.CmbCheck.Items.Clear(); foreach ($s in 'Off', '1h', '3h', '6h', '12h', '24h') { [void]$ui.CmbCheck.Items.Add((New-ComboItem $s (T "set.check.$s"))) }
    $ui.CmbReboot.Items.Clear(); foreach ($s in 'Prompt', 'Auto', 'Scheduled', 'Never') { [void]$ui.CmbReboot.Items.Add((New-ComboItem $s (T "set.reboot.$s"))) }
    $ui.CmbScale.Items.Clear(); foreach ($s in 90, 100, 110, 125) { [void]$ui.CmbScale.Items.Add((New-ComboItem $s (T "set.scale.$s"))) }
    $ui.CmbStartPage.Items.Clear(); foreach ($s in 'Overview', 'Updates', 'Programs', 'Startup', 'Cleanup', 'Security', 'History') { [void]$ui.CmbStartPage.Items.Add((New-ComboItem $s $(if ($s -eq 'Startup') { T 'startup.title' } else { T ('nav.' + $s.ToLower()) }))) }
    $ui.AccentPanel.Children.Clear()
    foreach ($k in $accentPalettes.Keys) {
        $b = New-Object System.Windows.Controls.RadioButton; $b.GroupName = 'accent'; $b.Tag = $k; $b.ToolTip = T "set.accent.$k"
        $b.Style = $window.FindResource('Swatch'); $b.Background = [System.Windows.Media.Brush](New-AccentBrush $accentPalettes[$k])
        $b.Add_Checked({ param($s) if (-not $script:loading) { Set-Appearance ([string]$s.Tag) ([int]$ui.CmbScale.SelectedItem.Tag); Register-Change } })
        [void]$ui.AccentPanel.Children.Add($b)
    }
    $ui.CmbRunning.Items.Clear(); foreach ($s in 'Ask', 'Close', 'Skip') { [void]$ui.CmbRunning.Items.Add((New-ComboItem $s (T "set.running.$s"))) }
    $ui.CmbNvidia.Items.Clear(); foreach ($s in 'GameReady', 'Studio') { [void]$ui.CmbNvidia.Items.Add((New-ComboItem $s (T "set.nvidia.$s"))) }
    $ui.CmbCleanSched.Items.Clear(); foreach ($s in 'Off', 'Weekly', 'Monthly') { [void]$ui.CmbCleanSched.Items.Add((New-ComboItem $s (T "set.cleanSched.$s"))) }
    $culture = if ((Get-CurrentLanguage) -eq 'de') { [Globalization.CultureInfo]'de-DE' } else { [Globalization.CultureInfo]'en-US' }
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture   # dates follow the UI language, not the Windows format
    $ui.CmbDay.Items.Clear(); foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') {
        [void]$ui.CmbDay.Items.Add((New-ComboItem $d $culture.DateTimeFormat.GetDayName([DayOfWeek]$d))) }
    $script:loading = $false
}

function Initialize-Controls {
    $last = $sourceKeys[-1]
    foreach ($k in $sourceKeys) {
        $row = New-Object System.Windows.Controls.Border
        $row.Style = $window.FindResource($(if ($k -eq $last) { 'RowLast' } else { 'Row' }))
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Toggle')
        if ($k -in 'WingetIncludeUnknown', 'WindowsUpdateDrivers', 'MicrosoftUpdate') { $row.Padding = [System.Windows.Thickness]::new(42, 11, 18, 11); $cb.Foreground = Get-Brush '#B8C0CC' }
        $row.Child = $cb
        $sourceBoxes[$k] = $cb; $sourceRows[$k] = $row; [void]$ui.SourcePanel.Children.Add($row)
        $cb.Add_Click({ Register-Change })
    }
    $ui.TxtRepo.IsReadOnly = $true   # the update source is fixed (code from it runs elevated)
    $ui.CmbDom.Items.Clear(); 1..28 | ForEach-Object { [void]$ui.CmbDom.Items.Add((New-ComboItem $_ "$_.")) }
    $ui.CmbLang.Items.Clear(); [void]$ui.CmbLang.Items.Add((New-ComboItem 'de' 'Deutsch')); [void]$ui.CmbLang.Items.Add((New-ComboItem 'en' 'English'))
}

# ------------------------------------------------------------------ settings (saved automatically)
function Show-Config {
    $script:loading = $true
    Select-ComboTag $ui.CmbSchedule $config.Schedule.Type
    Select-ComboTag $ui.CmbDay $config.Schedule.DayOfWeek
    Select-ComboTag $ui.CmbDom $config.Schedule.DayOfMonth
    Select-ComboTag $ui.CmbReboot $config.Reboot
    Select-ComboTag $ui.CmbCheck $config.CheckInterval
    Select-ComboTag $ui.CmbLang $config.Language
    $ui.TxtTime.Text = $config.Schedule.Time
    $ui.TxtRebootTime.Text = $config.RebootTime
    $ui.ChkWake.IsChecked = [bool]$config.Schedule.WakeToRun
    $ui.RbActInstall.IsChecked = ($config.ScheduleAction -eq 'Install'); $ui.RbActNotify.IsChecked = ($config.ScheduleAction -eq 'Notify')
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["ChkPrio$p"].IsChecked = (@($config.AutoInstallPriorities) -contains $p) }
    $ui.RbVisible.IsChecked = ($config.Mode -eq 'Visible'); $ui.RbSilent.IsChecked = ($config.Mode -eq 'Silent')
    $ui.ChkParallel.IsChecked = [bool]$config.Parallel; $ui.ChkRestore.IsChecked = [bool]$config.RestorePoint
    foreach ($k in $sourceKeys) { $sourceBoxes[$k].IsChecked = [bool]$config.Sources.$k }
    $ui.ChkSelf.IsChecked = [bool]$config.SelfUpdate.Enabled; $ui.TxtRepo.Text = $config.SelfUpdate.Repo
    $ui.ChkAutostart.IsChecked = [bool]$config.StartWithWindows
    foreach ($b in $ui.AccentPanel.Children) { $b.IsChecked = ([string]$b.Tag -eq [string]$config.Appearance.Accent) }
    Select-ComboTag $ui.CmbScale ([int]$config.Appearance.Scale); Select-ComboTag $ui.CmbStartPage $config.Appearance.StartPage
    Set-Appearance ([string]$config.Appearance.Accent) ([int]$config.Appearance.Scale)
    $ui.ChkTray.IsChecked = [bool]$config.MinimizeToTray; $ui.ChkBackupDrivers.IsChecked = [bool]$config.BackupDrivers
    Select-ComboTag $ui.CmbRunning $config.RunningApps; Select-ComboTag $ui.CmbNvidia $config.NvidiaDriverType; Select-ComboTag $ui.CmbCleanSched $config.CleanupSchedule
    $ui.ExclChips.ItemsSource = @($config.ExcludedPackages)
    Update-SettingsUi
    Set-Dirty $false
    $script:loading = $false
}

# ------------------------------------------------------------------ time picker (select-all + hour/minute lists)
function Sync-TimePicker { param($State)
    if ($State.Box.Text -match '^([01]\d|2[0-3]):([0-5]\d)$') {
        $State.Sync = $true
        $State.Hours.SelectedIndex = [int]$Matches[1]; $State.Mins.SelectedIndex = [int]$Matches[2]
        $State.Hours.ScrollIntoView($State.Hours.SelectedItem); $State.Mins.ScrollIntoView($State.Mins.SelectedItem)
        $State.Sync = $false
    }
}

function Add-TimePicker {
    param([System.Windows.Controls.TextBox]$Box)
    $pop = New-Object System.Windows.Controls.Primitives.Popup
    $pop.PlacementTarget = $Box; $pop.Placement = 'Bottom'; $pop.StaysOpen = $false; $pop.AllowsTransparency = $true; $pop.PopupAnimation = 'Fade'
    $frame = New-Object System.Windows.Controls.Border
    $frame.Background = Get-Brush '#22252D'; $frame.BorderBrush = Get-Brush '#24FFFFFF'; $frame.BorderThickness = [System.Windows.Thickness]::new(1)
    $frame.CornerRadius = [System.Windows.CornerRadius]::new(14); $frame.Padding = [System.Windows.Thickness]::new(6); $frame.Margin = [System.Windows.Thickness]::new(0, 6, 8, 12)
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect; $shadow.BlurRadius = 20; $shadow.ShadowDepth = 4; $shadow.Opacity = 0.45; $frame.Effect = $shadow
    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Orientation = 'Horizontal'
    $state = @{ Box = $Box; Pop = $pop; Sync = $false; Hours = $null; Mins = $null }
    foreach ($part in 'Hours', 'Mins') {
        $lb = New-Object System.Windows.Controls.ListBox
        $lb.Width = 62; $lb.Height = 216; $lb.Background = Get-Brush '#00000000'; $lb.BorderThickness = [System.Windows.Thickness]::new(0)
        $lb.Foreground = Get-Brush '#D5DAE3'; $lb.ItemContainerStyle = $window.FindResource('TimeItem')
        [System.Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($lb, 'Hidden')
        $count = if ($part -eq 'Hours') { 24 } else { 60 }
        for ($i = 0; $i -lt $count; $i++) { [void]$lb.Items.Add(('{0:00}' -f $i)) }
        $lb.Tag = $state
        $lb.Add_SelectionChanged({ param($s)
            $st = $s.Tag
            if ($st.Sync -or -not $st.Hours.SelectedItem -or -not $st.Mins.SelectedItem) { return }
            $st.Box.Text = '{0}:{1}' -f $st.Hours.SelectedItem, $st.Mins.SelectedItem
            $st.Box.SelectAll()
        })
        $state[$part] = $lb
        [void]$panel.Children.Add($lb)
        if ($part -eq 'Hours') {
            $sep = New-Object System.Windows.Controls.TextBlock; $sep.Text = ':'; $sep.FontSize = 16; $sep.Foreground = Get-Brush '#6B7380'
            $sep.VerticalAlignment = 'Center'; $sep.Margin = [System.Windows.Thickness]::new(2, 0, 2, 0); [void]$panel.Children.Add($sep)
        }
    }
    $frame.Child = $panel; $pop.Child = $frame
    $Box.Tag = $state
    # first click selects everything (so typing replaces it) and opens the picker
    $Box.Add_PreviewMouseLeftButtonDown({ param($s, $e) if (-not $s.IsKeyboardFocusWithin) { [void]$s.Focus(); $e.Handled = $true } })
    $Box.Add_GotKeyboardFocus({ param($s) $s.SelectAll(); $s.Tag.Pop.IsOpen = $true; Sync-TimePicker $s.Tag })
    $Box.Add_TextChanged({ param($s) if ($s.Tag.Pop.IsOpen -and -not $s.Tag.Sync) { Sync-TimePicker $s.Tag } })
    $Box.Add_KeyDown({ param($s, $e) if ($e.Key -in 'Return', 'Escape', 'Tab') { $s.Tag.Pop.IsOpen = $false } })
}

# ------------------------------------------------------------------ app self-update
function Find-AppUpdate {
    $repo = $config.SelfUpdate.Repo
    if (-not $repo) { Show-AppToast (T 'set.appNoRepo') 'error'; return }
    $ui.TxtAppUpdateStatus.Text = T 'set.checking'; $ui.BtnCheckAppUpdate.IsEnabled = $false
    # let the UI render "checking" before the (short) network call
    [void]$window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
        try { $r = Invoke-SelfUpdate -Repo $config.SelfUpdate.Repo -DryRun } catch { $r = $null; $err = $_.Exception.Message }
        $ui.BtnCheckAppUpdate.IsEnabled = $true
        if ($r -and $r.Status -eq 'Available') {
            $ui.TxtAppUpdateStatus.Text = T 'set.appAvailable' @($r.To)
            Show-Dialog -Title (T 'dlg.appUpdateTitle' @($r.To)) -Text (T 'dlg.appUpdateText' @($version, $r.To)) -Glyph ([string][char]0xE896) -Buttons @(
                @{ Text = T 'dlg.appUpdateNow'; Kind = 'Primary'; Action = { Start-Engine -Mode install -SelfOnly } },
                @{ Text = T 'dlg.later'; Kind = 'Ghost' })
        } elseif ($r -and $r.Status -eq 'Info') {
            $ui.TxtAppUpdateStatus.Text = T 'set.appCurrent' @($version)
            Show-AppToast (T 'set.appCurrent' @($version))
        } else {
            $msg = if ($r) { Resolve-Text $r.Message } else { $err }
            $ui.TxtAppUpdateStatus.Text = T 'set.appUpdateFailed' @($msg)
            Show-AppToast (T 'set.appUpdateFailed' @($msg)) 'error'
        }
    })
}

function Set-Dirty { param([bool]$Dirty)
    $script:dirty = $Dirty
    $ui.DirtyDot.Visibility = if ($Dirty) { 'Visible' } else { 'Collapsed' }
    $ui.TxtSaveState.Text = if ($Dirty) { T 'set.unsaved' } else { T 'set.allSaved' }
    $ui.BtnSave.IsEnabled = $Dirty; $ui.BtnDiscard.IsEnabled = $Dirty
}

function Register-Change { if (-not $script:loading) { Update-SettingsUi; Set-Dirty $true } }

function Update-SettingsUi {
    $type = if ($ui.CmbSchedule.SelectedItem) { [string]$ui.CmbSchedule.SelectedItem.Tag } else { 'Manual' }
    $ui.PnlDay.Visibility = if ($type -in 'Weekly', 'BiWeekly') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDom.Visibility = if ($type -eq 'Monthly') { 'Visible' } else { 'Collapsed' }
    $ui.PnlTime.Visibility = if ($type -eq 'Manual') { 'Collapsed' } else { 'Visible' }
    $ui.PnlAutoDetails.Visibility = $ui.PnlTime.Visibility
    $ui.PnlAutoPrio.Visibility = if ($ui.RbActInstall.IsChecked) { 'Visible' } else { 'Collapsed' }
    $reboot = if ($ui.CmbReboot.SelectedItem) { [string]$ui.CmbReboot.SelectedItem.Tag } else { 'Prompt' }
    $ui.PnlRebootTime.Visibility = if ($reboot -eq 'Scheduled') { 'Visible' } else { 'Collapsed' }
    $sourceBoxes['WingetIncludeUnknown'].IsEnabled = [bool]$sourceBoxes['Winget'].IsChecked
    foreach ($k in 'WindowsUpdateDrivers', 'MicrosoftUpdate') { $sourceBoxes[$k].IsEnabled = [bool]$sourceBoxes['WindowsUpdate'].IsChecked }
    $repo = $ui.TxtRepo.Text.Trim()
    $ui.ChkSelf.IsEnabled = [bool]$repo
    $ui.TxtSelfStatus.Text = if ($repo) { T 'set.selfReady' @($repo) } else { T 'set.selfMissing' }
}

function Show-AppToast {
    <# Small in-app notification at the top of the window (fades in and out). #>
    param([string]$Text, [ValidateSet('ok', 'error', 'info')][string]$Kind = 'ok')
    $ui.ToastText.Text = $Text
    $map = @{ ok = @('#30D158', [string][char]0xE73E); error = @('#FF453A', [string][char]0xE711); info = @('#3D7BFF', [string][char]0xE946) }
    $ui.ToastIconBg.Background = Get-Brush $map[$Kind][0]; $ui.ToastIcon.Text = $map[$Kind][1]
    $ui.ToastPill.BorderBrush = Get-Brush ('#40' + $map[$Kind][0].Substring(1))
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    foreach ($kf in @(@(0, 0), @(180, 1), @(2600, 1), @(3100, 0))) {
        [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame($kf[1], [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($kf[0])))))
    }
    $ui.ToastPill.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
}
function Save-Settings {
    <# Explicit save: Save button, leaving the settings page or closing the window. Returns $true on success. #>
    if ($script:loading -or -not $script:dirty) { return $true }
    Update-SettingsUi
    # validate before anything is written
    foreach ($box in @($ui.TxtTime, $ui.TxtRebootTime)) {
        if ($box.Text.Trim() -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Show-AppToast (T 'set.badTime' @($box.Text.Trim())) 'error'; [void]$box.Focus(); return $false }
    }
    try {
        $c = Get-Config
        $c.Schedule.Type = [string]$ui.CmbSchedule.SelectedItem.Tag
        $c.Schedule.DayOfWeek = [string]$ui.CmbDay.SelectedItem.Tag
        $c.Schedule.DayOfMonth = [int]$ui.CmbDom.SelectedItem.Tag
        $c.Schedule.Time = $ui.TxtTime.Text.Trim()
        $c.Schedule.WakeToRun = [bool]$ui.ChkWake.IsChecked
        $c.ScheduleAction = if ($ui.RbActNotify.IsChecked) { 'Notify' } else { 'Install' }
        $c.AutoInstallPriorities = @('Critical', 'Important', 'Normal', 'Optional' | Where-Object { $ui["ChkPrio$_"].IsChecked })
        $c.Mode = if ($ui.RbSilent.IsChecked) { 'Silent' } else { 'Visible' }
        $c.Parallel = [bool]$ui.ChkParallel.IsChecked
        $c.RestorePoint = [bool]$ui.ChkRestore.IsChecked
        $c.Reboot = [string]$ui.CmbReboot.SelectedItem.Tag
        $c.RebootTime = $ui.TxtRebootTime.Text.Trim()
        foreach ($k in $sourceKeys) { $c.Sources.$k = [bool]$sourceBoxes[$k].IsChecked }
        $c.Language = [string]$ui.CmbLang.SelectedItem.Tag
        $c.SelfUpdate.Repo = $ui.TxtRepo.Text.Trim()
        $c.SelfUpdate.Enabled = [bool]$ui.ChkSelf.IsChecked -and [bool]$c.SelfUpdate.Repo
        $c.StartWithWindows = [bool]$ui.ChkAutostart.IsChecked
        $c.CheckInterval = [string]$ui.CmbCheck.SelectedItem.Tag
        $c.MinimizeToTray = [bool]$ui.ChkTray.IsChecked; $c.BackupDrivers = [bool]$ui.ChkBackupDrivers.IsChecked
        $c.RunningApps = [string]$ui.CmbRunning.SelectedItem.Tag; $c.NvidiaDriverType = [string]$ui.CmbNvidia.SelectedItem.Tag
        $c.CleanupSchedule = [string]$ui.CmbCleanSched.SelectedItem.Tag
        $acc = @($ui.AccentPanel.Children | Where-Object { $_.IsChecked }) | Select-Object -First 1
        $c.Appearance.Accent = if ($acc) { [string]$acc.Tag } else { 'Blue' }
        $c.Appearance.Scale = [int]$ui.CmbScale.SelectedItem.Tag; $c.Appearance.StartPage = [string]$ui.CmbStartPage.SelectedItem.Tag
        if ($devMode) { $script:config = $c; Set-Dirty $false; Show-AppToast (T 'set.saved'); Update-Tray; return $true }
        Save-Config -Config $c
        # scheduled tasks: a failure here must not leave the app with a stale config in memory
        $taskError = $null
        try {
            if ([bool]$c.StartWithWindows -ne [bool]$script:config.StartWithWindows) { Set-Autostart -Enabled ([bool]$c.StartWithWindows) }
            if ([string]$c.CheckInterval -ne [string]$script:config.CheckInterval) { Set-BackgroundCheck -Interval ([string]$c.CheckInterval) }
            if ([string]$c.CleanupSchedule -ne [string]$script:config.CleanupSchedule) { Set-CleanupSchedule -Schedule ([string]$c.CleanupSchedule) }
            $scheduleChanged = ($c.Schedule | ConvertTo-Json -Compress) -ne ($script:config.Schedule | ConvertTo-Json -Compress)
            if ($scheduleChanged) { Register-ScheduleTask -Config $c }
        } catch { $taskError = $_; Write-GuiError $_ 'settings-tasks' }
        $langChanged = $c.Language -ne $script:config.Language
        $script:config = $c
        if ($langChanged) {
            Import-I18n -Language $c.Language; Set-Texts; Show-Config; Update-RowTexts
            # module pages were built with the old language: rebuild them from their last data
            Restore-PageCaches; Show-History; Update-Recent
        }
        Update-Tray
        Show-Summary
        Set-Dirty $false
        if ($taskError) { Show-AppToast (T 'set.savedTaskWarn') 'error' } else { Show-AppToast (T 'set.saved') }
        return $true
    } catch {
        Write-GuiError $_ 'settings'
        Show-AppToast (T 'set.invalid' @($_.Exception.Message)) 'error'
        return $false
    }
}

function Set-Exclusion {
    <# Adds/removes an id pattern from the exclusion list and updates rows + chips immediately. #>
    param([string]$Id, [bool]$Exclude)
    if (-not $Id) { return }
    $c = Get-Config
    $list = [System.Collections.Generic.List[string]]@($c.ExcludedPackages)
    if ($Exclude) { if (-not $list.Contains($Id)) { $list.Add($Id) } } else { [void]$list.Remove($Id) }
    $c.ExcludedPackages = $list.ToArray()
    if (-not $devMode) { try { Save-Config -Config $c } catch { Show-AppToast (T 'set.invalid' @($_.Exception.Message)) 'error'; return } }
    $script:config = $c
    $ui.ExclChips.ItemsSource = @($c.ExcludedPackages)
    foreach ($r in $rows) { Update-RowExclusion $r }
    $view.Refresh()
    Update-Counts
}

# ------------------------------------------------------------------ update list
function Test-IdExcluded { param([string]$Id) foreach ($p in @($config.ExcludedPackages)) { if ($Id -and $Id -like $p) { return $true } }; return $false }

function Update-RowExclusion { param($Row)
    if (-not $Row.CanExclude) { return }
    $Row.Excluded = Test-IdExcluded $Row.Id
    if ($Row.Excluded) { $Row.Selected = $false }
    $Row.ExcludeGlyph = if ($Row.Excluded) { [string][char]0xE7B3 } else { [string][char]0xED1A }
    $Row.ExcludeTip = if ($Row.Excluded) { T 'up.includeTip' } else { T 'up.excludeTip' }
    Set-RowGroup $Row
}

function Set-RowGroup { param($Row)
    if ($Row.Excluded) { $Row.GroupLabel = T 'seg.excluded'; $Row.GroupRank = 4 }
    elseif ($Row.IsUpdate) { $Row.GroupLabel = T "prio.$($Row.Priority)"; $Row.GroupRank = $prioRank[$Row.Priority] }
    else { $Row.GroupLabel = T 'up.groupCurrent'; $Row.GroupRank = 5 }
}

function Set-RowState { param($Row, [string]$State)
    $Row.State = $State
    $Row.StateText = if ($State) { T "state.$State" } else { '' }
    $Row.StateBrush = if ($State -and $stateColors.ContainsKey($State)) { $stateColors[$State] } else { '#8A93A1' }
}

function New-Row { param($Item, [bool]$IsUpdate)
    $r = New-Object Alerion.UpdateRow
    $r.Key = [string]$Item.Key; $r.Source = [string]$Item.Source; $r.Name = Resolve-Text ([string]$Item.Name)
    $r.Id = [string]$Item.Id; $r.From = [string]$Item.From; $r.To = [string]$Item.To; $r.Status = [string]$Item.Status
    $r.SourceLabel = T ('source.' + $r.Source)
    $r.Priority = if ($Item.PSObject.Properties.Name -contains 'Priority' -and $Item.Priority) { [string]$Item.Priority } else { 'Normal' }
    $r.PriorityLabel = T "prio.$($r.Priority)"; $r.PriorityBrush = $prioColors[$r.Priority]
    $r.IsCheck = ($Item.PSObject.Properties.Name -contains 'IsCheck') -and [bool]$Item.IsCheck
    $props = $Item.PSObject.Properties.Name
    $r.ManualOnly = ([string]$Item.Key -eq 'oem|asus|driverhub') -or (($props -contains 'ManualOnly') -and [bool]$Item.ManualOnly) -or
                    (($props -contains 'InstallMode') -and [string]$Item.InstallMode -eq 'installer')
    $r.Major = ($Item.PSObject.Properties.Name -contains 'Major') -and [bool]$Item.Major
    $r.MajorLabel = T 'up.major'
    $r.IsUpdate = $IsUpdate
    $r.CanExclude = ($r.Source -in 'winget', 'choco', 'windows', 'gpu', 'oem', 'selfupdater') -and $r.Id -and ($r.Id -notmatch '^(ARP|MSIX)\\')
    $r.Note = Resolve-Text ([string]$Item.Message)
    # Installed with another installer technology: offer a clean reinstall through winget.
    if ($IsUpdate -and $r.Source -eq 'winget' -and [string]$Item.Message -in 'msg.mem.tech', 'msg.techMismatch') { $r.ActionText = T 'up.reinstall' }
    if ($r.IsCheck) { $r.To = ''; if (-not $r.Note) { $r.Note = T 'msg.checkInstall' } }   # keep specific hints (e.g. ASUS)
    if ($r.To -and $r.To -eq $r.Id) { $r.To = '' }   # Windows updates: the KB number is already shown as ID
    Update-RowExclusion $r
    if (-not $r.CanExclude) { $r.Excluded = $false; Set-RowGroup $r }
    if (-not $IsUpdate) { Set-RowState $r $(if ($r.Status -eq 'Failed') { 'Failed' } else { 'Current' }) }
    return $r
}

function Import-Scan {
    <# Loads state\last-scan.json into the list; keeps the user's selection when possible. #>
    $file = Join-Path $paths.StateDir 'last-scan.json'
    $previous = @{}; foreach ($r in $rows) { $previous[$r.Key] = $r.Selected }
    $hadRows = $rows.Count -gt 0
    $rows.Clear()
    $script:scanAt = $null
    if (-not (Test-Path $file)) { Update-Counts; return }
    try { $scan = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Update-Counts; return }
    $script:scanAt = (ConvertTo-DateSafe $scan.ScannedAt)
    $ids = @{}
    foreach ($i in @($scan.Items)) {
        if (-not $i) { continue }
        $isUpdate = $i.Status -eq 'Available' -or ($i.Status -eq 'Skipped' -and $i.Message -eq 'msg.excluded')
        $row = New-Row $i $isUpdate
        if ($row.IsUpdate -and -not $row.Excluded) {
            $row.Selected = if ($hadRows -and $previous.ContainsKey($row.Key)) { $previous[$row.Key] } else { $row.Priority -ne 'Optional' -and -not $row.ManualOnly }
        }
        $rows.Add($row); if ($row.Id) { $ids[$row.Id] = $true }
    }
    foreach ($p in @($scan.Installed)) {
        if (-not $p -or -not $p.Id -or $ids.ContainsKey($p.Id)) { continue }
        $ids[$p.Id] = $true
        $item = [pscustomobject]@{ Key = "installed|$($p.Id)"; Source = $(if ($p.Source) { 'winget' } else { 'system' }); Name = $p.Name; Id = $p.Id; From = $p.Version; To = ''; Status = 'Info'; Message = '' }
        $rows.Add((New-Row $item $false))
    }
    Update-Counts
}

function Update-RowTexts { foreach ($r in $rows) { $r.SourceLabel = T ('source.' + $r.Source); $r.PriorityLabel = T "prio.$($r.Priority)"; $r.MajorLabel = T 'up.major'; Update-RowExclusion $r; if (-not $r.CanExclude) { Set-RowGroup $r }; if ($r.State) { Set-RowState $r $r.State } }; $view.Refresh() }

$view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('GroupRank', 'Ascending')))
$view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Name', 'Ascending')))
$view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('GroupLabel')))
$view.Filter = [Predicate[object]]{
    param($r)
    $q = $script:search
    if ($q) {
        if ($r.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$r.Id).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        if ($script:segment -eq 'All') { return $true }   # search covers updates AND installed programs
    }
    switch ($script:segment) {
        'All'       { return $r.IsUpdate -and -not $r.Excluded }
        'Excluded'  { return $r.Excluded }
        'Installed' { return $true }
        default     { return $r.IsUpdate -and -not $r.Excluded -and $r.Priority -eq $script:segment }
    }
}

function Get-RecommendedRows {
    <# One definition for the button label and the click: everything selectable except Optional and
       entries that only open a vendor window (ASUS). #>
    @($rows | Where-Object { $_.Selectable -and $_.Priority -ne 'Optional' -and -not $_.ManualOnly })
}

function Update-Counts {
    $upd = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck })
    foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { $ui["TxtTile$p"].Text = [string]@($upd | Where-Object { $_.Priority -eq $p }).Count }
    $ui.Badge.Visibility = if ($upd.Count) { 'Visible' } else { 'Collapsed' }
    $ui.TxtBadge.Text = [string]$upd.Count
    $ui.Badge.Background = Get-Brush $(if (@($upd | Where-Object { $_.Priority -eq 'Critical' }).Count) { '#FF453A' } else { '#3D7BFF' })
    $sel = @($rows | Where-Object { $_.Selected -and $_.Selectable })
    $ui.TxtSelected.Text = T 'up.selected' @($sel.Count)
    $ui.BtnInstallSelected.Content = T 'up.installSelected' @($sel.Count)
    $ui.BtnInstallSelected.IsEnabled = ($sel.Count -gt 0) -and -not $script:running
    $rec = @(Get-RecommendedRows)
    $ui.BtnRecommended.Content = T 'ov.installRecommended' @(@($rec | Where-Object { -not $_.IsCheck }).Count)
    $ui.BtnRecommended.IsEnabled = ($rec.Count -gt 0) -and -not $script:running
    $ui.TxtUpdatesSub.Text = if ($script:scanAt) { T 'up.sub' @($upd.Count, (Format-When $script:scanAt)) } else { T 'up.notScanned' }
    $ui.TxtLastScan.Text = Format-When $script:scanAt
    Update-Hero
    Update-Empty
}

function Update-Empty {
    $visible = 0; foreach ($r in $view) { $visible++; break }
    $ui.EmptyPanel.Visibility = if ($visible) { 'Collapsed' } else { 'Visible' }
    if ($script:running -and $script:runMode -eq 'scan') { $ui.TxtEmpty.Text = T 'up.scanning'; $ui.EmptyGlyph.Text = [string][char]0xE895; $ui.EmptyGlyph.Foreground = Get-Brush '#6FA8FF' }
    elseif ($script:search) { $ui.TxtEmpty.Text = T 'up.noMatch' @($script:search); $ui.EmptyGlyph.Text = [string][char]0xE721; $ui.EmptyGlyph.Foreground = Get-Brush '#8A93A1' }
    elseif (-not $script:scanAt) { $ui.TxtEmpty.Text = T 'up.notScanned'; $ui.EmptyGlyph.Text = [string][char]0xE895; $ui.EmptyGlyph.Foreground = Get-Brush '#8A93A1' }
    else { $ui.TxtEmpty.Text = T 'up.allCurrent'; $ui.EmptyGlyph.Text = [string][char]0xE73E; $ui.EmptyGlyph.Foreground = Get-Brush '#30D158' }
}

# ------------------------------------------------------------------ overview
function Update-Hero {
    $spin = $window.FindResource('Spin')
    if ($script:running) {
        $ui.TxtState.Text = if ($script:runMode -eq 'scan') { T 'ov.scanning' } else { T 'ov.running' }
        $ui.TxtSub.Text = if ($script:runMode -eq 'scan') { T 'ov.scanningSub' } else { T 'ov.runningSub' }
        $ui.StateCircle.Fill = Get-Brush '#3D7BFF'; $ui.StateGlyph.Text = [string][char]0xE895
        $ui.Spinner.Visibility = 'Visible'; $spin.Begin($window, $true)
    } else {
        $spin.Stop($window); $ui.Spinner.Visibility = 'Collapsed'
        $n = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck }).Count
        $crit = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck -and $_.Priority -eq 'Critical' }).Count
        if (-not $script:scanAt) { $ui.TxtState.Text = T 'ov.ready'; $col = '#8A93A1'; $ui.StateGlyph.Text = [string][char]0xE895 }
        elseif ($n -eq 0) { $ui.TxtState.Text = T 'ov.allCurrent'; $col = '#30D158'; $ui.StateGlyph.Text = [string][char]0xE73E }
        else { $ui.TxtState.Text = T 'ov.available' @($n); $col = if ($crit) { '#FF453A' } else { '#3D7BFF' }; $ui.StateGlyph.Text = [string][char]0xE896 }
        $ui.StateCircle.Fill = Get-Brush $col
        $ui.TxtSub.Text = if ($crit) { T 'ov.criticalHint' @($crit) } else { T 'ov.lastScanLine' @(Format-When $script:scanAt) }
    }
    $ui.BtnScan.Visibility = if ($script:running) { 'Collapsed' } else { 'Visible' }
    $ui.BtnCancel.Visibility = if ($script:running -and $script:runMode -eq 'install') { 'Visible' } else { 'Collapsed' }
    $ui.ProgressPanel.Visibility = if ($script:running -and $script:runMode -eq 'install') { 'Visible' } else { 'Collapsed' }
}

function Show-Summary {
    $next = Get-NextRun
    $ui.TxtNext.Text = if ($config.Schedule.Type -eq 'Manual') { T 'ov.manualOnly' } elseif ($next) { $next.ToString('ddd, dd.MM.  HH:mm') } else { '-' }
    $last = Get-LastReport
    $ui.TxtLastRun.Text = if ($last -and -not $last.DryRun) { Format-When ((ConvertTo-DateSafe $last.EndedAt)) } else { T 'ov.never' }
    Update-RebootBanner
    Update-Counts
    Update-Recent
}

function Update-Recent {
    <# Last runs on the overview (newest first). #>
    $items = foreach ($f in @(Get-ReportFiles | Select-Object -First 4)) {
        try { $r = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $col = if ($r.Counts.Failed -gt 0) { '#FF9F0A' } elseif ($r.DryRun) { '#8A93A1' } else { '#30D158' }
        $title = if ($r.DryRun) { T 'hist.check' } else { T 'ov.resultLine' @($r.Counts.Updated, $r.Counts.Failed) }
        [pscustomobject]@{ Title = $title; When = Format-When ((ConvertTo-DateSafe $r.EndedAt)); Color = $col }
    }
    $ui.RecentList.ItemsSource = @($items)
    $ui.RecentCard.Visibility = if (@($items).Count) { 'Visible' } else { 'Collapsed' }
}

# ------------------------------------------------------------------ history
function Get-ReportFiles {
    @(Get-ChildItem $paths.ReportDir -Filter 'report-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 60)
}

function Show-History {
    $items = foreach ($f in Get-ReportFiles) {
        try { $r = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $ended = ConvertTo-DateSafe $r.EndedAt; $title = if ($ended) { $ended.ToString('dd.MM.yyyy  HH:mm') } else { [string]$f.BaseName }
        $sub = if ($r.DryRun) { T 'hist.check' } else { T 'ov.resultLine' @($r.Counts.Updated, $r.Counts.Failed) }
        [pscustomobject]@{ Title = $title; Subtitle = $sub; Report = $r }
    }
    $ui.ReportList.ItemsSource = @($items)
    if (@($items).Count) { $ui.ReportList.SelectedIndex = 0 } else { Show-ReportGrid $null }
}

function Show-ReportGrid { param($Report)
    $ui.TxtHistoryEmpty.Text = T 'rep.noneHint'
    $ui.TxtHistoryEmpty.Visibility = if ($Report) { 'Collapsed' } else { 'Visible' }
    $ui.HistoryCard.Visibility = if ($Report) { 'Visible' } else { 'Collapsed' }
    $ui.BtnCopyReport.IsEnabled = [bool]$Report
    if (-not $Report) { $ui.TxtRepMeta.Text = ''; $ui.Grid.ItemsSource = $null; $ui.BtnHtml.IsEnabled = $false; return }
    $ui.BtnHtml.IsEnabled = [bool]($Report.PSObject.Properties.Name -contains 'HtmlPath' -and (Test-Path $Report.HtmlPath))
    $meta = T 'ov.resultLine' @($Report.Counts.Updated, $Report.Counts.Failed)
    if ($Report.RebootRequired) { $meta += '  -  ' + (T 'report.rebootTag') }
    $ui.TxtRepMeta.Text = $meta
    $order = @{ Failed = 0; Updated = 1; Available = 2; Triggered = 3; Skipped = 4; Info = 5 }
    $list = foreach ($i in (@($Report.Items) | Sort-Object { $order[[string]$_.Status] }, Source, Name)) {
        $note = Resolve-Text $i.Message
        if ($i.RebootRequired) { $note = (T 'report.rebootTag') + $(if ($note) { ' - ' + $note } else { '' }) }
        [pscustomobject]@{
            Source = T ('source.' + $i.Source); Name = Resolve-Text $i.Name; From = $i.From; To = $i.To
            StatusText = T ('status.' + $i.Status); StatusColor = $statusColors[[string]$i.Status]; Note = $note
            StatusRank = $order[[string]$i.Status]
        }
    }
    $ui.Grid.ItemsSource = @($list)
}

function Copy-ReportRows {
    <# Copies report rows as tab-separated text (pastes cleanly into chats, mails, Excel). #>
    param([object[]]$Items, [switch]$WithHeader)
    $items = @($Items | Where-Object { $_ })
    if (-not $items.Count) { Show-AppToast (T 'rep.copyNone') 'info'; return }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($WithHeader -and $script:shownReport) {
        $r = $script:shownReport
        $lines.Add(('Update Center {0} - {1} - {2}' -f $r.AppVersion, ('{0:dd.MM.yyyy HH:mm}' -f (ConvertTo-DateSafe $r.EndedAt)), (T 'ov.resultLine' @($r.Counts.Updated, $r.Counts.Failed))))
    }
    $lines.Add((@((T 'rep.colSource'), (T 'rep.colName'), (T 'rep.colFrom'), (T 'rep.colTo'), (T 'rep.colStatus'), (T 'rep.colNote')) -join "`t"))
    foreach ($i in $items) { $lines.Add((@($i.Source, $i.Name, $i.From, $i.To, $i.StatusText, $i.Note) | ForEach-Object { ([string]$_) -replace '[\t\r\n]+', ' ' }) -join "`t") }
    [System.Windows.Clipboard]::SetText(($lines -join "`r`n"))
    Show-AppToast (T 'rep.copied' @($items.Count))
}

function Show-ReportMenu {
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($e in @(@('rep.copySelected', 'sel'), @('rep.copyAll', 'all'), @('rep.copyFailed', 'failed'))) {
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = T $e[0]; $mi.Tag = $e[1]
        $mi.Add_Click({ param($s)
            switch ([string]$s.Tag) {
                'sel'    { Copy-ReportRows @($ui.Grid.SelectedItems) }
                'all'    { Copy-ReportRows @($ui.Grid.ItemsSource) -WithHeader }
                'failed' { Copy-ReportRows @($ui.Grid.ItemsSource | Where-Object { $_.StatusRank -eq 0 }) -WithHeader }
            } })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $ui.Grid; $menu.IsOpen = $true
}

# ------------------------------------------------------------------ engine control
function Show-Page { param([string]$Name)
    foreach ($p in 'Overview', 'Updates', 'Programs', 'Startup', 'Cleanup', 'Security', 'History', 'Settings') { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    if (-not $ui["Nav$Name"].IsChecked) { $ui["Nav$Name"].IsChecked = $true }
}

function Test-EngineRunning {
    $st = Get-Status
    return [bool]($st -and $st.Running -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue))
}

function Start-Engine {
    param([ValidateSet('scan', 'install')][string]$Mode, [string[]]$Keys, [switch]$SelfOnly)
    if ($devMode) { return }
    # a run that was just launched has not written its status yet: never start a second one
    if ($script:launchAt -or $script:running -or (Test-EngineRunning)) {
        Show-Dialog -Title (T 'ov.alreadyRunning') -Glyph ([string][char]0xE895) -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' }); return
    }
    $engine = Join-Path $src 'UpdateEngine.ps1'
    $a = "--headless `"$PSHOME\powershell.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$engine`" -FromGui"
    if ($Mode -eq 'scan') { $a += ' -Scan' }
    if ($SelfOnly) { $a += ' -SelfUpdateOnly' }
    if ($Keys) {
        $sel = Join-Path $paths.StateDir 'selection.json'
        Write-AtomicFile -Path $sel -Content (ConvertTo-Json @($Keys) -Compress)
        $a += " -Selection `"$sel`""
    }
    [void](Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" -ArgumentList $a -PassThru)
    # Until the engine has written a fresh status, status.json still describes the previous run.
    $script:launchAt = Get-Date
    $ui.LogList.Items.Clear()
    $script:running = $true; $script:runMode = $Mode; $script:wasRunning = $true
    Update-Counts
}

function Start-Install { param([object[]]$Selected, [switch]$Checked)
    $keys = @($Selected | ForEach-Object { $_.Key })
    if (-not $keys.Count) { return }
    if (-not $Checked) {
        if ($script:installPending -or $script:running -or $script:launchAt) { return }   # double click / already running
        $script:installPending = $true
        Confirm-RunningApps $Selected; return   # asks about open programs first
    }
    $script:installPending = $false
    foreach ($r in $rows) { if ($r.IsUpdate) { Set-RowState $r '' } }
    foreach ($r in $Selected) { Set-RowState $r 'Pending' }
    Start-Engine -Mode install -Keys $keys
    Show-Page 'Overview'
}

function Complete-InstallRun {
    <# After an install: history, restart handling (in-app), fresh scan. #>
    Show-Summary; Show-History; Show-Page 'History'; [void]$window.Activate()
    $rep = Get-LastReport
    $self = if ($rep) { @($rep.Items | Where-Object { $_.Source -eq 'self' -and $_.Status -eq 'Updated' }) | Select-Object -First 1 } else { $null }
    if ($self) {
        # The verified package's installer now waits for this run, closes the app, replaces it and reopens it.
        $bar = New-Object System.Windows.Controls.ProgressBar; $bar.IsIndeterminate = $true; $bar.Margin = [System.Windows.Thickness]::new(0, 4, 0, 6)
        Show-Dialog -Title (T 'dlg.appUpdatingTitle' @([string]$self.To)) -Text (T 'dlg.appUpdatingText') -Glyph ([string][char]0xE896) -Extra @($bar)
        $ui.TxtAppUpdateStatus.Text = T 'dlg.appUpdatingTitle' @([string]$self.To)
        return
    }
    if ($rep -and $rep.RebootRequired -and -not $rep.DryRun) {
        $plan = if ($rep.PSObject.Properties.Name -contains 'RestartPlan') { $rep.RestartPlan } else { $null }
        $script:estimate = $null
        if ($plan -and $plan.Mode -eq 'Scheduled' -and $plan.At) {
            Show-Dialog -Title (T 'dlg.plannedTitle' @(Format-At ([datetime]$plan.At))) -Text (T 'dlg.plannedAfterRun') -Glyph ([string][char]0xE823) -Buttons @(
                @{ Text = 'OK'; Kind = 'Primary' }, @{ Text = T 'ov.restartOptions'; Kind = 'Secondary'; Action = { Show-RestartDialog $null } })
        } elseif ($plan -and $plan.Mode -eq 'Never') {
            Update-RebootBanner
        } else {
            Show-RestartDialog $plan
        }
    }
    Start-Engine -Mode scan   # refresh the list after installing
}

# ------------------------------------------------------------------ polling
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
function Write-GuiError { param($Err, [string]$Where = 'ui')
    try { Add-Content -Path (Join-Path $paths.LogDir 'gui-error.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}: {2}`n{3}" -f (Get-Date), $Where, $Err.Exception.Message, $Err.ScriptStackTrace) -Encoding UTF8 } catch { }
}
function Invoke-Tick {
    Show-QueuedDialog
    Complete-BgTasks
    Update-Activities
    if ($script:preloadAt -and (Get-Date) -ge $script:preloadAt) { Invoke-Preload }
    if ($showEvent.WaitOne(0)) { Show-FromTray }
    $st = Get-Status
    if ($script:launchAt) {
        $fresh = $st -and $st.StartedAt -and ((ConvertTo-DateSafe $st.StartedAt) -ge $script:launchAt.AddSeconds(-2))
        if (-not $fresh) {
            if (((Get-Date) - $script:launchAt).TotalSeconds -gt 90) {
                $script:launchAt = $null; $script:running = $false; $script:wasRunning = $false; Update-Counts
                Show-Dialog -Title (T 'ov.startFailed') -Text (T 'ov.startFailedText') -Glyph ([string][char]0xE783) -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' })
            }
            return
        }
        $script:launchAt = $null
    }
    if (-not $st) { return }
    $alive = $st.Running -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue)
    if ($alive) {
        if (-not $script:running) { $script:running = $true; $script:wasRunning = $true; $script:runMode = [string]$st.Mode; Update-Counts }
        $ui.Progress.Value = [int]$st.Percent
        $ui.TxtPercent.Text = "$([int]$st.Percent) %"
        $ui.TxtCurrent.Text = [string]$st.Current
        $lines = @($st.Log)
        if ($lines.Count -ne $ui.LogList.Items.Count) {
            $ui.LogList.Items.Clear(); foreach ($l in $lines) { [void]$ui.LogList.Items.Add($l) }
            if ($ui.LogList.Items.Count) { $ui.LogList.ScrollIntoView($ui.LogList.Items[$ui.LogList.Items.Count - 1]) }
        }
        if ($st.PSObject.Properties.Name -contains 'Items' -and $st.Items) {
            $map = @{}; foreach ($p in $st.Items.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
            foreach ($r in $rows) { if ($map.ContainsKey($r.Key) -and $r.State -ne $map[$r.Key]) { Set-RowState $r $map[$r.Key] } }
        }
    } elseif ($script:wasRunning) {
        $finishedMode = $script:runMode
        $script:wasRunning = $false; $script:running = $false; $script:runMode = ''
        if ($finishedMode -eq 'scan') { Import-Scan; Show-Summary } else { Complete-InstallRun }
    }
}
# One failing tick must never stop the polling or close the window.
$timer.Add_Tick({ try { Invoke-Tick } catch { Write-GuiError $_ 'timer' } })
# Last line of defence for exceptions inside WPF event handlers: log, tell the user, keep running.
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    try { Add-Content -Path (Join-Path $paths.LogDir 'gui-error.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} dispatcher: {1}`n{2}" -f (Get-Date), $e.Exception.Message, $e.Exception.StackTrace) -Encoding UTF8 } catch { }
    try { Show-AppToast (T 'err.unexpected') 'error' } catch { }
})

# ------------------------------------------------------------------ background tasks (keep the window responsive)
$script:bgTasks = New-Object System.Collections.Generic.List[object]

function Start-BgTask {
    <# Runs $Script in a separate runspace of this (elevated) process. $Script receives one hashtable $p.
       $OnDone gets ($Output, $ErrorText, $Context) on the UI thread. #>
    param([Parameter(Mandatory)][scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnDone, $Context, $Activity, [int]$TimeoutSec = 0)
    $prelude = @"
param(`$src, `$p)
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$env:PSModulePath = "`$env:ProgramFiles\WindowsPowerShell\Modules;`$PSHOME\Modules"
foreach (`$m in 'Common', 'Providers', 'Uninstaller', 'Cleanup', 'SecurityScan', 'Startup') {
    `$file = Join-Path `$src (`$m + '.psm1'); if (Test-Path `$file) { Import-Module `$file -DisableNameChecking }
}
"@
    $ps = [powershell]::Create()
    $prelude += "`nImport-I18n -Language '$(Get-CurrentLanguage)'`n"   # module texts in the UI language
    [void]$ps.AddScript($prelude + "`n" + $Script.ToString()).AddArgument($src).AddArgument($Params)
    $script:bgTasks.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Context = $Context; Activity = $Activity; Started = (Get-Date); TimeoutSec = $TimeoutSec })
}

function Complete-BgTasks {
    foreach ($t in @($script:bgTasks.ToArray())) {
        if (-not $t.Handle.IsCompleted) {
            # watchdog: a hung page load must not leave the page "loading" forever
            if ($t.TimeoutSec -gt 0 -and ((Get-Date) - $t.Started).TotalSeconds -gt $t.TimeoutSec) {
                [void]$script:bgTasks.Remove($t)
                try { [void]$t.Ps.BeginStop($null, $null) } catch { }
                if ($t.Activity) { Stop-Activity $t.Activity }
                if ($t.OnDone) { try { & $t.OnDone $null (T 'err.timeout') $t.Context } catch { Write-GuiError $_ 'bg-timeout' } }
            }
            continue
        }
        [void]$script:bgTasks.Remove($t)
        $out = $null; $err = ''
        try { $out = $t.Ps.EndInvoke($t.Handle) } catch { $err = $_.Exception.InnerException.Message; if (-not $err) { $err = $_.Exception.Message } }
        if (-not $err -and $t.Ps.Streams.Error.Count) { $err = [string]$t.Ps.Streams.Error[0] }
        $t.Ps.Dispose()
        if ($t.Activity) { Stop-Activity $t.Activity }
        # No GetNewClosure anywhere: closures lose access to this script's functions. Data travels as Context.
        if ($t.OnDone) {
            try { & $t.OnDone $out $err $t.Context }
            catch {
                Show-AppToast $_.Exception.Message 'error'
                try { Add-Content -Path (Join-Path $paths.LogDir 'gui-error.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} background task: {1}`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace) -Encoding UTF8 } catch { }
            }
        }
    }
}

function Format-Size { param([double]$Bytes)
    if ($Bytes -lt 0) { return '-' }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function New-CheckList { param([object[]]$Items)
    <# Checkbox list for dialogs: @{ Text; Checked; Enabled; Tag } -> StackPanel #>
    $panel = New-Object System.Windows.Controls.StackPanel
    $scroll = New-Object System.Windows.Controls.ScrollViewer; $scroll.MaxHeight = 260; $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Content = $panel
    foreach ($i in $Items) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Tick'); $cb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $i.Text; $tb.TextWrapping = 'Wrap'; $tb.TextTrimming = 'None'; $tb.MaxWidth = 360; $tb.FontSize = 12
        $cb.Content = $tb; $cb.IsChecked = [bool]$i.Checked; $cb.IsEnabled = [bool]$i.Enabled; $cb.Tag = $i.Tag
        [void]$panel.Children.Add($cb)
    }
    return $scroll
}

# ------------------------------------------------------------------ activities (live progress of module work)
# Each long task gets a synchronized hashtable the module writes (Percent/Text/CanCancel/CanPause) and
# reads (Cancel/Pause). The timer mirrors it into the overview card and into the row on the module page.
$activities = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$ui.ActivityList.ItemsSource = $activities

function Start-Activity {
    param([string]$Title, [string]$Glyph, [string]$Color, [string]$Page, $Row, [string]$RowText = '',
          [Parameter(Mandatory)][scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnDone, $Context)
    $prog = [hashtable]::Synchronized(@{ Percent = -1.0; Text = ''; CanCancel = $false; CanPause = $false; Cancel = $false; Pause = $false; Phase = ''; Estimated = $false
                                         Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
    $Params.Progress = $prog
    $act = New-Object Alerion.ListRow
    $act.Title = $Title; $act.Glyph = $Glyph; $act.BadgeBrush = $Color; $act.Page = $Page; $act.Data = $prog
    $act.Link = $Row; $act.Uri = $RowText; $act.Key = [string](Get-Date).Ticks
    $act.ShowProgress = $true; $act.Indeterminate = $true; $act.Detail = T 'pg.loading'
    $activities.Add($act)
    if ($Row) { $Row.Busy = $true; $Row.ShowProgress = $true; $Row.Indeterminate = $true }
    Start-BgTask -Script $Script -Params $Params -OnDone $OnDone -Context $Context -Activity $act
    Update-Activities
    return $act
}

function Stop-Activity { param($Act)
    [void]$activities.Remove($Act)
    if ($Act.Link) { $Act.Link.Busy = $false; $Act.Link.ShowProgress = $false }
    Update-Activities
}

function Update-Activities {
    foreach ($a in $activities) {
        $p = $a.Data
        $pct = [double]$p.Percent
        $a.Indeterminate = $pct -lt 0
        if ($pct -ge 0) { $a.Percent = [Math]::Min(100, $pct) }
        $a.Detail = if ($p.Cancel) { T 'prog.cancelling' } elseif ($p.Pause) { T 'prog.paused' } elseif ($p.Text) { [string]$p.Text } else { $a.Detail }
        $a.CanCancel = [bool]$p.CanCancel -and -not $p.Cancel
        $a.CanPause = [bool]$p.CanPause -and -not $p.Cancel
        $a.ActionText = if ($p.Pause) { T 'prog.resume' } else { T 'prog.pause' }
        $a.Right = if ($pct -ge 0) { $(if ($p.Estimated) { '~' } else { '' }) + ('{0} %' -f [int]$pct) } else { ([TimeSpan]::FromTicks((Get-Date).Ticks - [long]$a.Key)).ToString('mm\:ss') }
        if ($a.Link) {
            $r = $a.Link; $r.Indeterminate = $a.Indeterminate; $r.Percent = $a.Percent
            if ($a.Uri) { $r.($a.Uri) = $a.Detail }
        }
    }
    $ui.ActivityCard.Visibility = if ($activities.Count) { 'Visible' } else { 'Collapsed' }
    # an open live log follows its task
    $lv = $script:logView
    if ($lv -and $ui.DialogLayer.Visibility -eq 'Visible' -and $lv.Log.Count -ne $lv.Shown) {
        $lv.Box.Text = (@($lv.Log.ToArray()) -join "`r`n"); $lv.Shown = $lv.Log.Count; $lv.Box.ScrollToEnd()
    }
    # sidebar: pulsing dot on every module that is working right now
    foreach ($n in 'Programs', 'Startup', 'Cleanup', 'Security') {
        $busy = @($activities | Where-Object { $_.Page -eq $n }).Count -gt 0
        $ui["Busy$n"].Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    }
    $ui.BusyUpdates.Visibility = if ($script:running -or @($activities | Where-Object { $_.Page -eq 'Updates' }).Count) { 'Visible' } else { 'Collapsed' }
    # cleanup page: the floating bar turns into the progress bar while cleaning
    $c = $script:cleanAct
    if ($c -and $activities.Contains($c)) {
        $ui.CleanupProgPanel.Visibility = 'Visible'
        $ui.TxtCleanupProg.Text = $c.Detail; $ui.TxtCleanupPct.Text = $c.Right
        $ui.CleanupProg.IsIndeterminate = $c.Indeterminate; $ui.CleanupProg.Value = $c.Percent
        $ui.BtnCleanupPause.Visibility = if ($c.CanPause) { 'Visible' } else { 'Collapsed' }; $ui.BtnCleanupPause.Content = $c.ActionText
        $ui.BtnCleanupCancel.IsEnabled = $c.CanCancel
    } else { $ui.CleanupProgPanel.Visibility = 'Collapsed' }
}

function Invoke-ActivityCommand { param($Act, [string]$Command)
    if (-not $Act -or -not $activities.Contains($Act)) { return }
    switch ($Command) {
        'cancel' { if ($Act.CanCancel) { $Act.Data.Cancel = $true; $Act.Data.Pause = $false } }
        'pause'  { if ($Act.CanPause) { $Act.Data.Pause = -not [bool]$Act.Data.Pause } }
        'open'   { Show-Page $Act.Page }
    }
    Update-Activities
}

# ------------------------------------------------------------------ page data: cache + background refresh
# Every module page shows its last known data instantly (state\cache-*.json) and refreshes in the
# background. After start the pages are preloaded from the bottom of the sidebar upwards; the page the
# user opens is loaded immediately (in parallel) if it is not there yet.
$script:pageState = @{ Programs = 'none'; Startup = 'none'; Cleanup = 'none'; Security = 'none' }
$script:preloadQueue = New-Object System.Collections.Generic.List[string]
foreach ($n in 'Security', 'Cleanup', 'Startup', 'Programs') { $script:preloadQueue.Add($n) }

function Save-PageCache { param([string]$Name, $Data)
    if ($devMode) { return }
    try { Write-AtomicFile -Path (Join-Path $paths.StateDir "cache-$Name.json") -Content (ConvertTo-Json -InputObject @($Data) -Depth 6 -Compress) } catch { }
}

function Read-PageCache { param([string]$Name)
    $f = Join-Path $paths.StateDir "cache-$Name.json"
    if (-not (Test-Path $f)) { return $null }
    # PS 5.1 returns a JSON array as one object - enumerate it explicitly.
    try { return @((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { return $null }
}

function Request-PageLoad { param([string]$Name)
    if (-not $script:pageState.ContainsKey($Name) -or $script:pageState[$Name] -in 'loading', 'done') { return }
    switch ($Name) { 'Programs' { Import-Programs } 'Startup' { Import-Startup } 'Cleanup' { Import-Cleanup } 'Security' { Import-Security } }
}

function Invoke-Preload {
    if (@($script:pageState.Values | Where-Object { $_ -eq 'loading' }).Count) { return }   # one at a time
    while ($script:preloadQueue.Count) {
        $n = $script:preloadQueue[0]; $script:preloadQueue.RemoveAt(0)
        if ($script:pageState[$n] -eq 'none') { Request-PageLoad $n; return }
    }
}

function Restore-PageCaches {
    $d = Read-PageCache 'programs'; if ($d) { Show-Programs $d }
    $d = Read-PageCache 'startup'; if ($d) { Show-Startup $d }
    $d = Read-PageCache 'cleanup'; if ($d) { Show-Cleanup $d }
    $d = Read-PageCache 'security'; if ($d) { Show-Security $d[0] }
    Update-ModuleTiles
}

# ------------------------------------------------------------------ overview: status of the other modules
function Update-ModuleTiles {
    $removable = @($progRows | Where-Object { -not $_.Locked }).Count
    $ui.TxtModPrograms.Text = if ($progRows.Count) { [string]$removable } else { [string][char]0x2014 }
    $ui.SubModPrograms.Text = if ($progRows.Count) { T 'ov.mod.programs' @(@($progRows | Where-Object { $_.Locked }).Count) } else { T 'pg.loading' }
    $on = @($startRows | Where-Object { $_.Selected }).Count
    $ui.TxtModStartup.Text = if ($startRows.Count) { T 'ov.mod.startupOn' @($on) } else { [string][char]0x2014 }
    $ui.SubModStartup.Text = if ($startRows.Count) { T 'ov.mod.startupOff' @($startRows.Count - $on) } else { T 'pg.loading' }
    $sum = 0.0; foreach ($r in $cleanRows) { if (-not $r.Locked -and $r.SortValue -gt 0) { $sum += $r.SortValue } }
    $ui.TxtModCleanup.Text = if ($cleanRows.Count) { Format-Size $sum } else { [string][char]0x2014 }
    $ui.SubModCleanup.Text = if ($cleanRows.Count) { T 'ov.mod.cleanup' } else { T 'pg.loading' }
    $bad = @($secRows | Where-Object { $_.State -in 'Warning', 'Critical' })
    $crit = @($bad | Where-Object { $_.State -eq 'Critical' }).Count
    if ($secRows.Count) {
        $ui.TxtModSecurity.Text = if ($bad.Count) { T 'ov.mod.secIssues' @($bad.Count) } else { T 'ov.mod.secOk' }
        $ui.DotModSecurity.Fill = Get-Brush $(if ($crit) { '#FF453A' } elseif ($bad.Count) { '#FF9F0A' } else { '#30D158' })
        $ui.SubModSecurity.Text = T 'ov.mod.secChecks' @($secRows.Count)
    } else { $ui.TxtModSecurity.Text = [string][char]0x2014; $ui.SubModSecurity.Text = T 'pg.loading' }
}

# ------------------------------------------------------------------ programs (clean uninstall)
$progRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$progView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($progRows)
$ui.ProgramList.ItemsSource = $progRows
$script:progSegment = 'All'; $script:progSearch = ''
$sourceColors = @{ winget = '#3D7BFF'; msi = '#A78BFA'; exe = '#8A93A1'; store = '#34D399' }
$progView.Filter = [Predicate[object]]{
    param($r)
    if ($script:progSearch -and $r.Title.IndexOf($script:progSearch, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        ([string]$r.Subtitle).IndexOf($script:progSearch, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    if ($script:progSegment -eq 'Protected') { return $r.Locked }
    return -not $r.Locked
}

function Set-ProgramSort {
    $progView.SortDescriptions.Clear()
    $tag = if ($ui.CmbProgSort.SelectedItem) { [string]$ui.CmbProgSort.SelectedItem.Tag } else { 'name' }
    switch ($tag) {
        'size' { $progView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('SortValue', 'Descending'))) }
        'date' { $progView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Key', 'Descending'))) }
        default { $progView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Title', 'Ascending'))) }
    }
}

function Update-ProgramEmpty {
    $n = 0; foreach ($r in $progView) { $n++; break }
    $ui.TxtProgEmpty.Visibility = if ($n) { 'Collapsed' } else { 'Visible' }
}

function Show-Programs { param([object[]]$Apps)
    $progRows.Clear()
    foreach ($a in @($Apps)) {
        if (-not $a) { continue }
        $r = New-Object Alerion.ListRow
        $r.Data = $a; $r.Title = [string]$a.Name
        $r.Subtitle = (@([string]$a.Publisher, [string]$a.Version) | Where-Object { $_ }) -join ('  ' + [char]0xB7 + '  ')
        $r.SortValue = [double]$(if ($a.SizeMB) { $a.SizeMB } else { 0 })
        $r.Right = if ($a.SizeMB) { Format-Size ([double]$a.SizeMB * 1MB) } else { '' }
        $r.Key = [string]$a.InstallDate   # yyyyMMdd sorts as text
        $r.Badge = T ('un.source.' + $a.Source); $r.BadgeBrush = $(if ($sourceColors.ContainsKey([string]$a.Source)) { $sourceColors[[string]$a.Source] } else { '#8A93A1' })
        $r.Locked = [bool]$a.Protected
        $r.Detail = if ($a.Protected) { T ('un.reason.' + $a.ProtectedReason) } else { '' }
        $r.ActionText = if ($a.Protected) { T 'pg.protected' } else { T 'pg.uninstall' }
        $progRows.Add($r)
    }
    $ui.TxtProgramsSub.Text = T 'pg.sub' @(@($progRows | Where-Object { -not $_.Locked }).Count, @($progRows | Where-Object { $_.Locked }).Count)
    Set-ProgramSort; $progView.Refresh(); Update-ProgramEmpty; Update-ModuleTiles
}

function Import-Programs {
    $script:pageState.Programs = 'loading'
    if (-not $progRows.Count) { $ui.TxtProgEmpty.Text = T 'pg.loading'; $ui.TxtProgEmpty.Visibility = 'Visible' }
    $ui.BtnProgRefresh.IsEnabled = $false
    Start-BgTask -TimeoutSec 240 -Script { @(Get-InstalledApps) } -OnDone {
        param($out, $err)
        $ui.BtnProgRefresh.IsEnabled = $true
        if ($err) { $script:pageState.Programs = 'none'; Write-GuiError ([pscustomobject]@{ Exception = [Exception]$err; ScriptStackTrace = '' }) 'programs'; if (-not $progRows.Count) { $ui.TxtProgEmpty.Text = T 'pg.loadFailed' }; return }
        $script:pageState.Programs = 'done'
        Show-Programs @($out); Save-PageCache 'programs' @($out)
    }
}

function Start-AppUninstall { param($Row)
    $app = $Row.Data
    if (@($activities | Where-Object { $_.Page -eq 'Programs' }).Count) { Show-AppToast (T 'pg.oneAtATime') 'info'; return }
    Start-Activity -Title (T 'act.uninstall' @($Row.Title)) -Glyph ([string][char]0xE74D) -Color '#059669' -Page 'Programs' -Row $Row -RowText 'Detail' `
        -Params @{ App = $app; Dev = $devMode } -Context $Row -Script {
        if (-not $p.Dev) { $p.Progress.Text = T 'prog.restorepoint'; [void](New-RestorePoint) }
        if ($p.Progress.Cancel) { return [pscustomobject]@{ Result = [pscustomobject]@{ Status = 'Cancelled'; Message = 'prog.cancelled' }; Leftovers = @() } }
        $r = Invoke-AppUninstall -App $p.App -DryRun:$p.Dev -Progress $p.Progress
        $left = @()
        if ($r.Status -eq 'Removed') { $left = @(Find-AppLeftovers -App $p.App -Progress $p.Progress) }
        [pscustomobject]@{ Result = $r; Leftovers = $left }
    } -OnDone {
        param($out, $err, $Row)
        if ($err -or -not $out) { $Row.Detail = ''; Show-AppToast (T 'pg.failed' @($Row.Title, $err)) 'error'; return }
        $res = @($out)[0]
        switch ($res.Result.Status) {
            'Removed' {
                $left = @($res.Leftovers)
                if ($left.Count) { Show-LeftoverDialog $Row.Title $left }
                else { Show-AppToast (T 'pg.removed' @($Row.Title)) }
                [void]$progRows.Remove($Row); Update-ModuleTiles
            }
            'WouldRemove' { $Row.Detail = ''; Show-AppToast (T 'pg.dryrun' @($Row.Title)) 'info' }
            'Cancelled' { $Row.Detail = ''; Show-AppToast (T 'prog.cancelled') 'info' }
            default {
                $Row.Detail = Resolve-UninstallMessage $res.Result.Message
                Show-Dialog -Title (T 'pg.failedTitle' @($Row.Title)) -Text $Row.Detail -Glyph ([string][char]0xE783) -Colors @('#FF6B6B', '#E0306E') -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' })
            }
        }
    } | Out-Null
}

function Resolve-UninstallMessage { param([string]$Message)
    if (-not $Message) { return '' }
    $key = 'un.msg.' + $Message
    $t = T $key
    if ($t -eq $key) { return $Message } else { return $t }
}

function Show-LeftoverDialog { param([string]$Name, [object[]]$Items)
    $list = New-CheckList @($Items | ForEach-Object {
        $size = if ($_.SizeMB) { ' (' + (Format-Size ([double]$_.SizeMB * 1MB)) + ')' } else { '' }
        $why = if (-not $_.Safe) { '  -  ' + (T ('un.leftover.' + $_.Reason)) } else { '' }
        @{ Text = ('{0}: {1}{2}{3}' -f (T ('un.type.' + $_.Type)), $_.Path, $size, $why); Checked = [bool]$_.Safe; Enabled = [bool]$_.Safe; Tag = $_ }
    })
    Show-Dialog -Title (T 'pg.leftTitle' @($Name)) -Text (T 'pg.leftText') -Glyph ([string][char]0xEA99) -Colors @('#A78BFA', '#6D28D9') -Extra @($list) -Buttons @(
        @{ Text = T 'pg.leftRemove'; Kind = 'Primary'; Context = $list; Action = {
            param($list)
            $chosen = @($list.Content.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
            if (-not $chosen.Count) { return }
            Start-Activity -Title (T 'act.leftovers') -Glyph ([string][char]0xEA99) -Color '#6D28D9' -Page 'Programs' -Params @{ Items = $chosen; Dev = $devMode } `
                -Script { @(Remove-AppLeftovers -Items $p.Items -DryRun:$p.Dev -Progress $p.Progress) } -OnDone {
                param($out, $err)
                if ($err) { Show-AppToast $err 'error' } else { Show-AppToast (T 'pg.leftDone' @(@($out | Where-Object { $_.Status -in 'Removed', 'WouldRemove' }).Count)) }
            } | Out-Null
        } },
        @{ Text = T 'pg.leftKeep'; Kind = 'Ghost' })
}

# ------------------------------------------------------------------ autostart (reversible, like Task Manager)
$startRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$startView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($startRows)
$ui.StartupList.ItemsSource = $startRows
$script:startSegment = 'All'; $script:startSearch = ''   # All = Task-Manager view (Standard), On = Advanced, Off = disabled
$startView.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Title', 'Ascending')))
$startView.Filter = [Predicate[object]]{
    param($r)
    if ($script:startSearch -and $r.Title.IndexOf($script:startSearch, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        ([string]$r.Subtitle).IndexOf($script:startSearch, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    $cat = if ($r.Data -and $r.Data.PSObject.Properties.Name -contains 'Category') { [string]$r.Data.Category } else { 'Standard' }
    switch ($script:startSegment) { 'On' { return $cat -eq 'Advanced' } 'Off' { return -not $r.Selected } default { return $cat -ne 'Advanced' } }
}
$impactColors = @{ low = '#30D158'; medium = '#FF9F0A'; high = '#FF453A'; unknown = '#8A93A1' }

function Get-StartupLocationText { param([string]$Location)
    $key = switch -Regex ($Location) {
        '(?i)common' { 'commonFolder'; break } '(?i)folder' { 'userFolder'; break } '(?i)WOW|32' { 'hklmRun32'; break }
        '^HKCU' { 'hkcuRun'; break } '^HKLM' { 'hklmRun'; break } default { 'task' } }
    return T ('startup.location.' + $key)
}

function Set-StartupRowState { param($Row)
    $Row.State = if ($Row.Selected) { T 'startup.enabled' } else { T 'startup.disabled' }
    $Row.StateBrush = if ($Row.Selected) { '#30D158' } else { '#8A93A1' }
}

function Show-Startup { param([object[]]$Items)
    $startRows.Clear()
    foreach ($it in @($Items)) {
        if (-not $it) { continue }
        $r = New-Object Alerion.ListRow
        $r.Data = $it; $r.Key = [string]$it.Id; $r.Title = [string]$it.Name
        $pub = [string]$it.Publisher; if ($pub -match '^\s*TODO') { $pub = '' }   # placeholder text some vendors ship in VersionInfo
        $r.Subtitle = (@($pub, (Get-StartupLocationText ([string]$it.Location))) | Where-Object { $_ }) -join ('  ' + [char]0xB7 + '  ')
        $risk = if ($it.PSObject.Properties.Name -contains 'Risk') { [string]$it.Risk } else { '' }
        $reason = if ($it.PSObject.Properties.Name -contains 'RiskReason' -and $it.RiskReason) { T ([string]$it.RiskReason) } else { '' }
        $r.Detail = if ($it.Protected) { T ([string]$it.ProtectReason) } elseif (-not $it.Exists) { T 'startup.missing' } elseif ($risk -eq 'Medium') { $reason } else { '' }
        if ($it.PSObject.Properties.Name -contains 'AddedByUs' -and $it.AddedByUs) { $r.Detail = (T 'startup.addedByUs') + $(if ($r.Detail) { '  ' + [char]0xB7 + '  ' + $r.Detail } else { '' }) }
        $imp = if ($it.Impact) { [string]$it.Impact } else { 'unknown' }
        $r.Badge = T ('startup.impact.' + $imp); $r.BadgeBrush = $(if ($impactColors.ContainsKey($imp)) { $impactColors[$imp] } else { '#8A93A1' })
        # protected items can only be (re-)enabled; system tasks are display-only
        $r.Locked = [bool]$it.Protected -and ([bool]$it.Enabled -or [string]$it.ProtectReason -eq 'startup.protect.systemTask')
        $r.Selected = [bool]$it.Enabled
        Set-StartupRowState $r
        $startRows.Add($r)
    }
    $ui.TxtStartupSub.Text = T 'startup.count' @($startRows.Count, @($startRows | Where-Object { $_.Selected }).Count)
    $startView.Refresh(); Update-StartupEmpty; Update-ModuleTiles
}

function Update-StartupEmpty {
    $n = 0; foreach ($r in $startView) { $n++; break }
    $ui.TxtStartEmpty.Text = if ($script:pageState.Startup -eq 'loading' -and -not $startRows.Count) { T 'pg.loading' } else { T 'startup.empty' }
    $ui.TxtStartEmpty.Visibility = if ($n) { 'Collapsed' } else { 'Visible' }
}

function Update-StartupHint {
    $ui.StartHintBar.Visibility = if ($script:startSegment -eq 'On') { 'Visible' } else { 'Collapsed' }
    $ui.TxtStartHint.Text = T 'startup.category.advanced.hint'
}

function Add-StartupFromDialog {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = T 'startup.add.button'; $dlg.Filter = (T 'startup.add.filter') + '|*.exe;*.lnk;*.bat;*.cmd'
    if (-not $dlg.ShowDialog($window)) { return }
    try { $res = Add-StartupItem -Path $dlg.FileName -DryRun:$devMode } catch { $res = [pscustomobject]@{ Ok = $false; Message = 'startup.add.failed' } }
    Show-AppToast (T ([string]$res.Message)) $(if ($res.Ok) { 'ok' } else { 'error' })
    if ($res.Ok) { Import-Startup }
}

function Remove-StartupRow { param($Row)
    try { $res = Remove-StartupItem -Item $Row.Data -DryRun:$devMode } catch { $res = [pscustomobject]@{ Ok = $false; Message = 'startup.remove.failed' } }
    Show-AppToast (T ([string]$res.Message)) $(if ($res.Ok) { 'ok' } else { 'error' })
    if ($res.Ok) { [void]$startRows.Remove($Row); Update-ModuleTiles }
}

function Import-Startup {
    $script:pageState.Startup = 'loading'; Update-StartupEmpty
    $ui.BtnStartRefresh.IsEnabled = $false
    Start-BgTask -TimeoutSec 120 -Script { @(Get-StartupItems) } -OnDone {
        param($out, $err)
        $ui.BtnStartRefresh.IsEnabled = $true
        if ($err) { $script:pageState.Startup = 'none'; Write-GuiError ([pscustomobject]@{ Exception = [Exception]$err; ScriptStackTrace = '' }) 'startup'; Show-AppToast (T 'pg.loadFailed') 'error'; Update-StartupEmpty; return }
        $script:pageState.Startup = 'done'
        Show-Startup @($out); Save-PageCache 'startup' @($out)
    }
}

function Set-StartupRow { param($Row, [bool]$Enabled)
    if ($Row.Busy -or $Row.Selected -eq $Enabled) { return }
    $Row.Busy = $true
    # in the background: switching a scheduled task can take a few seconds
    Start-BgTask -TimeoutSec 60 -Params @{ Item = $Row.Data; Enabled = $Enabled; Dev = $devMode } -Context @{ Row = $Row; Enabled = $Enabled } -Script {
        Set-StartupItemEnabled -Item $p.Item -Enabled $p.Enabled -DryRun:$p.Dev
    } -OnDone {
        param($out, $err, $ctx)
        $res = @($out)[0]
        if ($err -or -not $res) { $res = [pscustomobject]@{ Ok = $false; Message = 'startup.failed' } }
        Complete-StartupToggle $ctx.Row $ctx.Enabled $res
    }
}

function Complete-StartupToggle { param($Row, [bool]$Enabled, $res)
    $Row.Busy = $false
    if ($res.Ok) {
        $Row.Selected = $Enabled; $Row.Data.Enabled = $Enabled
        if ($Enabled -and $Row.Data.Protected) { $Row.Locked = $true }
        Set-StartupRowState $Row
        Show-AppToast (T $(if ($Enabled) { 'startup.toast.enabled' } else { 'startup.toast.disabled' }) @($Row.Title))
        $ui.TxtStartupSub.Text = T 'startup.count' @($startRows.Count, @($startRows | Where-Object { $_.Selected }).Count)
        Update-ModuleTiles
    } else {
        $msg = [string]$res.Message; $t = T $msg; if ($t -eq $msg -and $msg -notmatch '\s') { $t = T 'startup.failed' }
        Show-AppToast $(if ($msg -eq 'startup.protected') { T 'startup.protected.refuse' @($Row.Title) } else { $t }) 'error'
    }
    $ui.StartupList.Items.Refresh()
}

# ------------------------------------------------------------------ cleanup
$cleanRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$ui.CleanupList.ItemsSource = $cleanRows
$script:cleanAct = $null

function Update-CleanupTotal {
    $sum = 0; foreach ($r in $cleanRows) { if ($r.Selected -and -not $r.Locked -and $r.SortValue -gt 0) { $sum += $r.SortValue } }
    $n = @($cleanRows | Where-Object { $_.Selected -and -not $_.Locked }).Count
    $ui.TxtCleanupTotal.Text = T 'cl.total' @($n, (Format-Size $sum))
    $ui.BtnCleanupRun.Content = T 'cl.run' @(Format-Size $sum)
    $ui.BtnCleanupRun.IsEnabled = $n -gt 0 -and -not ($script:cleanAct -and $activities.Contains($script:cleanAct))
}

function Show-Cleanup { param([object[]]$Categories)
    $previous = @{}; foreach ($r in $cleanRows) { $previous[$r.Key] = $r.Selected }
    $cleanRows.Clear()
    foreach ($cat in @($Categories)) {
        if (-not $cat) { continue }
        $r = New-Object Alerion.ListRow
        $r.Data = $cat; $r.Key = [string]$cat.Id
        $r.Title = T ('cl.' + $cat.Id); $r.Subtitle = T ('cl.' + $cat.Id + '.desc')
        $r.SortValue = [double]$cat.SizeBytes; $r.Right = Format-Size ([double]$cat.SizeBytes)
        $r.Badge = T ('cl.risk.' + $cat.Risk); $r.BadgeBrush = $(if ($cat.Risk -eq 'None') { '#30D158' } else { '#FF9F0A' })
        $r.Locked = -not [bool]$cat.Available
        $r.State = if (-not $cat.Available -and $cat.Note) { T ('cl.note.' + $cat.Note) } else { '' }; $r.StateBrush = '#8A93A1'
        $r.Selected = if ($previous.ContainsKey($r.Key)) { $previous[$r.Key] } else { [bool]$cat.Default -and [bool]$cat.Available }
        if ($r.Locked) { $r.Selected = $false }
        $cleanRows.Add($r)
    }
    Update-CleanupTotal; Update-ModuleTiles
}

function Import-Cleanup {
    $script:pageState.Cleanup = 'loading'
    $ui.BtnCleanupScan.IsEnabled = $false; $ui.TxtCleanupTotal.Text = T 'cl.scanning'
    Start-BgTask -TimeoutSec 240 -Script { @(Get-CleanupCategories) } -OnDone {
        param($out, $err)
        $ui.BtnCleanupScan.IsEnabled = $true
        if ($err) { $script:pageState.Cleanup = 'none'; Write-GuiError ([pscustomobject]@{ Exception = [Exception]$err; ScriptStackTrace = '' }) 'cleanup'; $ui.TxtCleanupTotal.Text = T 'pg.loadFailed'; return }
        $script:pageState.Cleanup = 'done'
        Show-Cleanup @($out); Save-PageCache 'cleanup' @($out)
    }
}

function Start-Cleanup {
    $ids = @($cleanRows | Where-Object { $_.Selected -and -not $_.Locked } | ForEach-Object { $_.Key })
    if (-not $ids.Count -or ($script:cleanAct -and $activities.Contains($script:cleanAct))) { return }
    $go = {
        param($ids)
        foreach ($r in $cleanRows) { if ($ids -contains $r.Key) { $r.State = T 'cl.working'; $r.StateBrush = '#6FA8FF' } }
        $ui.BtnCleanupRun.IsEnabled = $false; $ui.BtnCleanupScan.IsEnabled = $false
        $script:cleanAct = Start-Activity -Title (T 'act.cleanup') -Glyph ([string][char]0xEA99) -Color '#6D28D9' -Page 'Cleanup' `
            -Params @{ Ids = $ids; Dev = $devMode } -Script { @(Invoke-Cleanup -Ids $p.Ids -DryRun:$p.Dev -Progress $p.Progress) } -OnDone {
            param($out, $err)
            $ui.BtnCleanupScan.IsEnabled = $true
            if ($err) { Show-AppToast $err 'error'; Import-Cleanup; return }
            $freed = 0; $cancelled = $false
            foreach ($res in @($out)) {
                $freed += [double]$res.FreedBytes
                if ($res.Status -eq 'Cancelled') { $cancelled = $true }
                $row = @($cleanRows | Where-Object { $_.Key -eq $res.Id }) | Select-Object -First 1
                if ($row) { $row.State = (T ('cl.status.' + $res.Status)) + $(if ($res.FreedBytes -gt 0) { ' ' + [char]0xB7 + ' ' + (Format-Size ([double]$res.FreedBytes)) } else { '' }); $row.StateBrush = $(if ($res.Status -eq 'Failed') { '#FF6B61' } elseif ($res.Status -eq 'Cancelled') { '#8A93A1' } else { '#30D158' }) }
            }
            Show-AppToast $(if ($cancelled) { T 'cl.cancelled' @(Format-Size $freed) } else { T 'cl.done' @(Format-Size $freed) }) $(if ($cancelled) { 'info' } else { 'ok' })
            Import-Cleanup
        }
        Update-Activities   # show the progress bar right away
    }
    $lowRisk = @($cleanRows | Where-Object { $ids -contains $_.Key -and $_.Data -and [string]$_.Data.Risk -ne 'None' } | ForEach-Object { $_.Title })
    if ($ids -contains 'recyclebin' -or $lowRisk.Count) {
        $txt = @(); if ($ids -contains 'recyclebin') { $txt += T 'cl.confirmBin' }
        if ($lowRisk.Count) { $txt += T 'cl.confirmLow' @(($lowRisk -join ', ')) }
        Show-Dialog -Title (T 'cl.confirmTitle2') -Text ($txt -join "`n`n") -Glyph ([string][char]0xE74D) -Colors @('#A78BFA', '#6D28D9') -Buttons @(
            @{ Text = T 'cl.confirmGo'; Kind = 'Primary'; Action = $go; Context = $ids }, @{ Text = T 'dlg.later'; Kind = 'Ghost' })
    } else { & $go $ids }
}

# ------------------------------------------------------------------ security
$secRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$scanRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[Alerion.ListRow]'
$ui.SecStatusList.ItemsSource = $secRows; $ui.ScanList.ItemsSource = $scanRows
$script:scanAct = $null
$secStateColors = @{ Ok = '#30D158'; Warning = '#FF9F0A'; Critical = '#FF453A'; Unknown = '#6B7380' }
foreach ($s in @(@('Quick', [string][char]0xE721), @('Full', [string][char]0xEA18), @('Mrt', [string][char]0xE7BA), @('MrtFull', [string][char]0xE9F9), @('Integrity', [string][char]0xE90F))) {
    $r = New-Object Alerion.ListRow; $r.Key = $s[0]; $r.Glyph = $s[1]; $r.GlyphBrush = '#6FA8FF'; $scanRows.Add($r)
}

function Set-ScanTexts {
    foreach ($r in $scanRows) {
        $r.Title = T ('sec.scan.' + $r.Key); $r.Subtitle = T ('sec.scan.' + $r.Key + '.desc')
        $r.ActionText = if ($script:scanAct -and $script:scanAct.Link -eq $r) { T 'prog.cancel' } else { T 'sec.scan.start' }
    }
}

function Show-Security { param($Data)
    if (-not $Data) { return }
    $secRows.Clear()
    $order = @{ Critical = 0; Warning = 1; Unknown = 2; Ok = 3 }
    foreach ($chk in (@($Data.Status) | Where-Object { $_ } | Sort-Object { $order[[string]$_.State] })) {
        $r = New-Object Alerion.ListRow
        $r.Key = [string]$chk.Id; $r.Title = T ('sec.' + $chk.Id); $r.Subtitle = T ('sec.' + $chk.Id + '.desc'); $r.Detail = [string]$chk.Detail
        $r.State = [string]$chk.State; $r.StateBrush = $secStateColors[[string]$chk.State]; $r.Uri = [string]$chk.FixUri; $r.ActionText = T 'sec.fix'
        $secRows.Add($r)
    }
    $bad = @($Data.Status | Where-Object { $_ -and $_.State -in 'Warning', 'Critical' }).Count
    $ui.TxtSecuritySub.Text = if ($bad) { T 'pg.secIssues' @($bad) } else { T 'pg.secOk' }
    $threats = @($Data.Threats | Where-Object { $_ })
    $ui.TxtSecThreats.Text = if ($threats.Count) { ($threats | ForEach-Object { '{0:g}  {1}  ({2})' -f (ConvertTo-DateSafe $_.Time), $_.Name, $_.Action }) -join "`n" } else { T 'sec.history.none' }
    Update-ModuleTiles
}

function Import-Security {
    $script:pageState.Security = 'loading'
    $ui.BtnSecRefresh.IsEnabled = $false
    if (-not $secRows.Count) { $ui.TxtSecuritySub.Text = T 'pg.loading' }
    Start-BgTask -TimeoutSec 120 -Script { [pscustomobject]@{ Status = @(Get-SecurityStatus); Threats = @(Get-ThreatHistory) } } -OnDone {
        param($out, $err)
        $ui.BtnSecRefresh.IsEnabled = $true
        if ($err -or -not $out) { $script:pageState.Security = 'none'; if ($err) { Write-GuiError ([pscustomobject]@{ Exception = [Exception]$err; ScriptStackTrace = '' }) 'security' }; $ui.TxtSecuritySub.Text = T 'pg.loadFailed'; return }
        $script:pageState.Security = 'done'
        $res = @($out)[0]
        Show-Security $res; Save-PageCache 'security' $res
    }
}

function Start-Scan { param($Row)
    if ($script:scanAct -and $activities.Contains($script:scanAct)) {
        # the running scan's button is its cancel button
        if ($script:scanAct.Link -eq $Row) { Invoke-ActivityCommand $script:scanAct 'cancel' }
        return
    }
    $run = {
        param($Row)
        foreach ($r in $scanRows) { if ($r -ne $Row) { $r.Locked = $true } }
        $Row.State = T 'sec.scan.running'; $Row.StateBrush = '#6FA8FF'
        $script:scanAct = Start-Activity -Title $Row.Title -Glyph $Row.Glyph -Color '#DC2626' -Page 'Security' -Row $Row -RowText 'State' `
            -Params @{ Type = $Row.Key; Dev = $devMode } -Context $Row -Script { Start-SecurityScan -Type $p.Type -DryRun:$p.Dev -Progress $p.Progress } -OnDone {
            param($out, $err, $Row)
            $script:scanAct = $null
            foreach ($r in $scanRows) { $r.Locked = $false }
            Set-ScanTexts
            if ($err -or -not $out) { $Row.State = $err; $Row.StateBrush = '#FF6B61'; return }
            $res = @($out)[0]
            $Row.State = (T ('sec.result.' + $res.Status)) + $(if ($res.DurationSec) { ' ' + [char]0xB7 + ' ' + (T 'sec.result.duration' @(('{0} min' -f [int][Math]::Ceiling($res.DurationSec / 60)))) } else { '' })
            $Row.StateBrush = switch ($res.Status) { 'Clean' { '#30D158' } 'ThreatsRemoved' { '#FF9F0A' } 'ThreatsFound' { '#FF453A' } 'Failed' { '#FF453A' } default { '#8A93A1' } }
            $msg = if ($res.Message) { $k = 'sec.msg.' + $res.Message; $t = T $k; if ($t -ne $k) { $t } else { Resolve-Text ([string]$res.Message) } } else { '' }
            if (@($res.Threats).Count -or $res.Status -in 'ThreatsFound', 'Failed') {
                Show-Dialog -Title (T ('sec.result.' + $res.Status)) -Text ((@($res.Threats) -join "`n") + $(if ($msg) { "`n" + $msg } else { '' })) -Glyph ([string][char]0xEA18) -Colors @('#F87171', '#DC2626') -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' })
            } else { Show-AppToast $Row.State $(if ($res.Status -eq 'Cancelled') { 'info' } else { 'ok' }) }
            Import-Security
        }
        $Row.Data = $script:scanAct.Data.Log
        Set-ScanTexts
    }
    if ($Row.Key -in 'Full', 'MrtFull', 'Integrity') {
        Show-Dialog -Title $Row.Title -Text $Row.Subtitle -Glyph $Row.Glyph -Colors @('#F87171', '#DC2626') -Buttons @(
            @{ Text = T 'sec.scan.start'; Kind = 'Primary'; Action = $run; Context = $Row }, @{ Text = T 'dlg.later'; Kind = 'Ghost' })
    } else { & $run $Row }
}

# ------------------------------------------------------------------ updates: reinstall, priority, release notes, open apps
function Start-Reinstall { param($Row)
    Show-Dialog -Title (T 'up.reinstallTitle' @($Row.Name)) -Text (T 'up.reinstallText') -Glyph ([string][char]0xE777) -Buttons @(
        @{ Text = T 'up.reinstall'; Kind = 'Primary'; Context = $Row; Action = {
            param($Row)
            $Row.ActionText = ''; Set-RowState $Row 'Running'
            Start-Activity -Title (T 'act.reinstall' @($Row.Name)) -Glyph ([string][char]0xE777) -Color '#2F6BFF' -Page 'Updates' -Context $Row `
                -Params @{ Id = $Row.Id; Name = $Row.Name; From = $Row.From; Dev = $devMode } -Script {
                $p.Progress.Text = T 'act.reinstallRunning'
                Invoke-WingetReinstall -Id $p.Id -Name $p.Name -From $p.From -DryRun:$p.Dev
            } -OnDone {
                param($out, $err, $Row)
                $res = @($out)[0]
                if ($err -or -not $res -or $res.Status -eq 'Failed') {
                    Set-RowState $Row 'Failed'; $Row.ActionText = T 'up.reinstall'
                    Show-AppToast (T 'up.reinstallFailed' @($Row.Name, $(if ($err) { $err } else { Resolve-Text ([string]$res.Message) }))) 'error'
                } else { Set-RowState $Row 'Done'; Show-AppToast (T 'up.reinstallDone' @($Row.Name)) }
            } | Out-Null
        } },
        @{ Text = T 'dlg.later'; Kind = 'Ghost' })
}

function Set-PriorityOverride { param($Row, [string]$Priority)
    $c = Get-Config
    $map = New-Object PSObject
    if ($c.PriorityOverrides) { foreach ($p in $c.PriorityOverrides.PSObject.Properties) { if ($p.Name -ne $Row.Id) { $map | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value } } }
    if ($Priority) { $map | Add-Member -NotePropertyName $Row.Id -NotePropertyValue $Priority }
    $c.PriorityOverrides = $map
    if (-not $devMode) { try { Save-Config -Config $c } catch { Show-AppToast (T 'set.invalid' @($_.Exception.Message)) 'error'; return } }
    $script:config = $c
    if ($Priority) {
        $Row.Priority = $Priority; $Row.PriorityLabel = T "prio.$Priority"; $Row.PriorityBrush = $prioColors[$Priority]
        Set-RowGroup $Row; $view.Refresh(); Update-Counts
        Show-AppToast (T 'up.prioSet' @($Row.Name, (T "prio.$Priority")))
    } else { Show-AppToast (T 'up.prioReset' @($Row.Name)) 'info' }   # automatic priority applies with the next scan
}

function Open-ReleaseNotes { param($Row)
    Show-AppToast (T 'up.notesLoading') 'info'
    Start-BgTask -Params @{ Id = $Row.Id } -Context $Row -Script { Get-WingetReleaseNotesUrl -Id $p.Id } -OnDone {
        param($out, $err, $Row)
        $url = [string]@($out)[0]
        if ($url -match '^https://') { Start-Process $url } else { Show-AppToast (T 'up.notesNone' @($Row.Name)) 'info' }
    }
}

function Show-RowMenu { param($Row, $Target)
    $menu = New-Object System.Windows.Controls.ContextMenu
    $add = { param($text, $tag, [bool]$check)
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $text; $mi.Tag = $tag; $mi.IsChecked = $check
        $mi.Add_Click({ param($s) Invoke-RowMenu $s.Tag })
        [void]$menu.Items.Add($mi) }
    $override = $null
    if ($config.PriorityOverrides -and $Row.Id) { $prop = $config.PriorityOverrides.PSObject.Properties[$Row.Id]; if ($prop) { $override = [string]$prop.Value } }
    if ($Row.IsUpdate -and $Row.Id) {
        $hdr = New-Object System.Windows.Controls.MenuItem; $hdr.Header = T 'up.menuPriority'; $hdr.IsEnabled = $false; [void]$menu.Items.Add($hdr)
        foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') { & $add ('   ' + (T "prio.$p")) @{ Cmd = 'prio'; Row = $Row; Value = $p } ($override -eq $p) }
        & $add ('   ' + (T 'up.menuAuto')) @{ Cmd = 'prio'; Row = $Row; Value = '' } (-not $override)
        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    }
    if ($Row.Source -eq 'winget' -and $Row.Id) { & $add (T 'up.menuNotes') @{ Cmd = 'notes'; Row = $Row } $false }
    if ($Row.ActionText) { & $add $Row.ActionText @{ Cmd = 'reinstall'; Row = $Row } $false }
    if ($Row.CanExclude) { & $add $(if ($Row.Excluded) { T 'up.includeShort' } else { T 'up.excludeShort' }) @{ Cmd = 'exclude'; Row = $Row } $false }
    if (-not $menu.Items.Count) { return }
    $menu.PlacementTarget = $Target; $menu.IsOpen = $true
}

function Invoke-RowMenu { param($Tag)
    switch ($Tag.Cmd) {
        'prio'      { Set-PriorityOverride $Tag.Row $Tag.Value }
        'notes'     { Open-ReleaseNotes $Tag.Row }
        'reinstall' { Start-Reinstall $Tag.Row }
        'exclude'   { Set-Exclusion -Id $Tag.Row.Id -Exclude (-not $Tag.Row.Excluded) }
    }
}

function Confirm-RunningApps {
    <# Before installing: list selected winget packages whose program is open and ask whether to close them. #>
    param([object[]]$Selected)
    $pkgs = @($Selected | Where-Object { $_.Source -eq 'winget' } | ForEach-Object { @{ Name = $_.Name; Key = $_.Key } })
    if ($config.RunningApps -ne 'Ask' -or -not $pkgs.Count -or $devMode) { Start-Install -Selected $Selected -Checked; return }
    Start-BgTask -Params @{ Pkgs = $pkgs } -Context $Selected -Script {
        foreach ($k in $p.Pkgs) { $procs = @(Get-PackageProcess -DisplayName $k.Name); if ($procs.Count) { [pscustomobject]@{ Name = $k.Name; Procs = (@($procs | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', ') } } }
    } -OnDone {
        param($out, $err, $Selected)
        $open = @($out | Where-Object { $_ })
        if (-not $open.Count) { Start-Install -Selected $Selected -Checked; return }
        $text = (T 'up.openAppsText') + "`n`n" + (($open | ForEach-Object { [string][char]0x2022 + '  ' + $_.Name + '  (' + $_.Procs + ')' }) -join "`n")
        Show-Dialog -Modal -Title (T 'up.openAppsTitle' @($open.Count)) -Text $text -Glyph ([string][char]0xE7BA) -Colors @('#FFB020', '#FF6A3D') -Buttons @(
            @{ Text = T 'up.openAppsClose'; Kind = 'Primary'; Context = @{ Selected = $Selected; Names = @($open | ForEach-Object { $_.Name }) }; Action = {
                param($ctx)
                Show-AppToast (T 'up.closingApps') 'info'
                Start-BgTask -Params @{ Names = $ctx.Names } -Context $ctx.Selected -Script { foreach ($n in $p.Names) { [void](Stop-PackageProcess -DisplayName $n) } } -OnDone {
                    param($out, $err, $Selected) Start-Install -Selected $Selected -Checked }
            } },
            @{ Text = T 'up.openAppsSkip'; Kind = 'Secondary'; Context = $Selected; Action = { param($sel) Start-Install -Selected $sel -Checked } },
            @{ Text = T 'dlg.later'; Kind = 'Ghost'; Action = { $script:installPending = $false } })
    }
}

function Show-ScanLog { param([string]$Title, $Log)
    <# Live log of a scan / cleanup / uninstall (selectable and copyable, follows the running task). #>
    if (-not $Log) { Show-AppToast (T 'sec.logEmpty') 'info'; return }
    $box = New-Object System.Windows.Controls.TextBox
    $box.IsReadOnly = $true; $box.TextWrapping = 'Wrap'; $box.MaxHeight = 360; $box.MinHeight = 160
    $box.VerticalScrollBarVisibility = 'Auto'; $box.FontFamily = 'Cascadia Mono, Consolas'; $box.FontSize = 11.5
    $box.Text = (@($Log.ToArray()) -join "`r`n")
    Show-Dialog -Title (T 'sec.logTitle' @($Title)) -Glyph ([string][char]0xE9D9) -Extra @($box) -Buttons @(
        @{ Text = T 'rep.copy'; Kind = 'Secondary'; Context = $Log; Action = { param($l) Copy-Text (@($l.ToArray()) -join "`r`n") } },
        @{ Text = 'OK'; Kind = 'Primary' })
    $ui.DialogCard.Width = 680
    $script:logView = @{ Box = $box; Log = $Log; Shown = $Log.Count }
    $box.ScrollToEnd()
}

# ------------------------------------------------------------------ right-click menus
function Show-Menu {
    <# Items: @{ Text; Action = { param($ctx) }; Context; Enabled } or '-' for a separator. #>
    param($Target, [object[]]$Items)
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($i in $Items) {
        if ($i -is [string]) { [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator)); continue }
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Text; $mi.IsEnabled = ($i.Enabled -ne $false); $mi.Tag = @{ Action = $i.Action; Context = $i.Context }
        $mi.Add_Click({ param($s) try { & $s.Tag.Action $s.Tag.Context } catch { Show-AppToast $_.Exception.Message 'error' } })
        [void]$menu.Items.Add($mi)
    }
    if (-not $menu.Items.Count) { return }
    $menu.PlacementTarget = $Target; $menu.IsOpen = $true
}

function Get-EventRow { param($Source, [type]$Type)
    $el = $Source
    while ($el -and -not ($el -is [System.Windows.FrameworkElement] -and $el.DataContext -is $Type)) {
        $el = if ($el -is [System.Windows.Media.Visual] -or $el -is [System.Windows.Media.Media3D.Visual3D]) { [System.Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    if ($el) { return $el.DataContext } else { return $null }
}

function Open-InExplorer { param([string]$Path)
    if (-not $Path) { return }
    $p = $Path.Trim('"')
    if (Test-Path -LiteralPath $p -PathType Leaf) { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" }
    elseif (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList "`"$p`"" }
    else { Show-AppToast (T 'menu.notFound') 'info' }
}

function Copy-Text { param([string]$Text) if ($Text) { [System.Windows.Clipboard]::SetText($Text); Show-AppToast (T 'menu.copied') } }

function Show-ProgramMenu { param($Row)
    $a = $Row.Data
    Show-Menu $ui.ProgramList @(
        @{ Text = T 'pg.uninstall'; Enabled = (-not $Row.Locked -and -not $Row.Busy); Context = $Row; Action = { param($r)
            Show-Dialog -Title (T 'pg.confirmTitle' @($r.Title)) -Text (T 'pg.confirmText') -Glyph ([string][char]0xE74D) -Colors @('#FF6B6B', '#E0306E') -Buttons @(
                @{ Text = T 'pg.uninstall'; Kind = 'Danger'; Context = $r; Action = { param($x) Start-AppUninstall $x } }, @{ Text = T 'dlg.later'; Kind = 'Ghost' }) } },
        @{ Text = T 'menu.openFolder'; Enabled = [bool]$a.InstallLocation; Context = [string]$a.InstallLocation; Action = { param($p) Open-InExplorer $p } },
        '-',
        @{ Text = T 'menu.copyName'; Context = $Row.Title; Action = { param($t) Copy-Text $t } },
        @{ Text = T 'menu.copyDetails'; Context = $a; Action = { param($x) Copy-Text ((@($x.Name, $x.Publisher, $x.Version, $x.Source, $x.WingetId, $x.InstallLocation, $x.UninstallString) | Where-Object { $_ }) -join "`r`n") } })
}

function Show-StartupMenu { param($Row)
    $it = $Row.Data
    $items = @(
        @{ Text = $(if ($Row.Selected) { T 'startup.disable' } else { T 'startup.enable' }); Enabled = (-not $Row.Locked -and -not $Row.Busy); Context = $Row; Action = { param($r) Set-StartupRow $r (-not $r.Selected) } },
        @{ Text = T 'menu.openLocation'; Enabled = [bool]$it.ImagePath; Context = [string]$it.ImagePath; Action = { param($p) Open-InExplorer $p } },
        '-',
        @{ Text = T 'menu.copyCommand'; Context = [string]$it.Command; Action = { param($t) Copy-Text $t } })
    if ($it.PSObject.Properties.Name -contains 'AddedByUs' -and $it.AddedByUs) {
        $items += '-'
        $items += @{ Text = T 'startup.remove'; Context = $Row; Action = { param($r) Remove-StartupRow $r } }
    }
    Show-Menu $ui.StartupList $items
}

function Show-SecurityMenu { param($Row)
    Show-Menu $ui.SecStatusList @(
        @{ Text = T 'sec.fix'; Enabled = [bool]$Row.Uri; Context = $Row.Uri; Action = { param($u) Start-Process $u } },
        @{ Text = T 'menu.copyDetails'; Context = $Row; Action = { param($r) Copy-Text ("{0}: {1}`r`n{2}" -f $r.Title, $r.State, $r.Detail) } })
}

function Show-ActivityMenu { param($Act)
    Show-Menu $ui.ActivityList @(
        @{ Text = T 'act.open'; Context = $Act; Action = { param($a) $ui["Nav$($a.Page)"].IsChecked = $true } },
        @{ Text = $Act.ActionText; Enabled = $Act.CanPause; Context = $Act; Action = { param($a) Invoke-ActivityCommand $a 'pause' } },
        @{ Text = T 'prog.cancel'; Enabled = $Act.CanCancel; Context = $Act; Action = { param($a) Invoke-ActivityCommand $a 'cancel' } },
        '-',
        @{ Text = T 'sec.showLog'; Context = $Act; Action = { param($a) Show-ScanLog $a.Title $a.Data.Log } })
}

# ------------------------------------------------------------------ tray icon (optional: minimize to the notification area)
$script:tray = $null
function Update-Tray {
    if (-not $config.MinimizeToTray -or $devMode) {
        if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose(); $script:tray = $null }
        return
    }
    if (-not $script:tray) {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $script:tray = New-Object System.Windows.Forms.NotifyIcon
        if (Test-Path $paths.IconPath) { $script:tray.Icon = New-Object System.Drawing.Icon((New-Object System.IO.MemoryStream(, [IO.File]::ReadAllBytes($paths.IconPath)))) }
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add((T 'tray.open'), $null, { Show-FromTray })
        [void]$menu.Items.Add((T 'ov.scan'), $null, { Show-FromTray; Start-Engine -Mode scan })
        [void]$menu.Items.Add((T 'tray.exit'), $null, { $script:exiting = $true; $window.Close() })
        $script:tray.ContextMenuStrip = $menu
        $script:tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-FromTray } })
    }
    $n = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and -not $_.IsCheck }).Count
    $tip = if ($n) { T 'tray.tipUpdates' @($n) } else { T 'tray.tip' }
    $script:tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    $script:tray.Visible = $true
}

function Show-FromTray {
    $window.Show(); if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    [void]$window.Activate()
}

# ------------------------------------------------------------------ events
$ui.BtnClose.Add_Click({ $window.Close() })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$window.Add_StateChanged({
    # Maximized: no shadow margin, square corners (the window touches the screen edges).
    $max = $window.WindowState -eq 'Maximized'
    $ui.Root.Margin = [System.Windows.Thickness]::new($(if ($max) { 0 } else { 12 }))
    $r = [System.Windows.CornerRadius]::new($(if ($max) { 0 } else { 18 }))
    $ui.WindowShadow.CornerRadius = $r; $ui.WindowFrame.CornerRadius = $r; $ui.DialogDim.CornerRadius = $r
    # optional: minimized window lives in the notification area
    if ($window.WindowState -eq 'Minimized' -and $script:tray) { $window.Hide() }
})
function Get-CurrentPage {
    foreach ($p in 'Overview', 'Updates', 'Programs', 'Startup', 'Cleanup', 'Security', 'History', 'Settings') { if ($ui["Page$p"].Visibility -eq 'Visible') { return $p } }
    return 'Overview'
}
function Leave-Settings {
    <# Saves on leaving the settings page. Returns $false (and stays on the page) when saving failed. #>
    if ($ui.PageSettings.Visibility -eq 'Visible' -and $script:dirty -and -not (Save-Settings)) {
        $script:loading = $true; $ui.NavSettings.IsChecked = $true; $script:loading = $false
        return $false
    }
    return $true
}
$ui.NavOverview.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Overview' })
$ui.NavUpdates.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Updates' })
$ui.NavHistory.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'History'; Show-History })
# the opened page has priority: load it right now if the preload has not reached it yet
$ui.NavPrograms.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Programs'; Request-PageLoad 'Programs' })
$ui.NavStartup.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Startup'; Request-PageLoad 'Startup' })
$ui.NavCleanup.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Cleanup'; Request-PageLoad 'Cleanup' })
$ui.NavSecurity.Add_Checked({ if (-not (Leave-Settings)) { return }; Show-Page 'Security'; Request-PageLoad 'Security' })
foreach ($m in 'Programs', 'Startup', 'Cleanup', 'Security') { $ui["Mod$m"].Tag = $m; $ui["Mod$m"].Add_Click({ param($s) $ui["Nav$($s.Tag)"].IsChecked = $true }) }
$ui.ActivityList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) $b = $e.OriginalSource
    switch ($b.Name) { 'ActLog' { Show-ScanLog $b.DataContext.Title $b.DataContext.Data.Log } 'ActOpen' { $ui["Nav$($b.DataContext.Page)"].IsChecked = $true } 'ActPause' { Invoke-ActivityCommand $b.DataContext 'pause' } 'ActCancel' { Invoke-ActivityCommand $b.DataContext 'cancel' } }
})
$ui.BtnCleanupPause.Add_Click({ Invoke-ActivityCommand $script:cleanAct 'pause' })
$ui.BtnCleanupCancel.Add_Click({ Invoke-ActivityCommand $script:cleanAct 'cancel' })
$ui.BtnStartRefresh.Add_Click({ Import-Startup })
foreach ($seg in 'All', 'On', 'Off') { $ui["SegStart$seg"].Tag = $seg; $ui["SegStart$seg"].Add_Checked({ param($s) $script:startSegment = [string]$s.Tag; $startView.Refresh(); Update-StartupEmpty; Update-StartupHint }) }
$ui.BtnStartAdd.Add_Click({ Add-StartupFromDialog })
$ui.TxtStartSearch.Add_TextChanged({ $script:startSearch = $ui.TxtStartSearch.Text.Trim(); $ui.TxtStartSearchHint.Visibility = if ($ui.TxtStartSearch.Text) { 'Collapsed' } else { 'Visible' }; $startView.Refresh(); Update-StartupEmpty })
$ui.StartupList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) $b = $e.OriginalSource
    if ($b.Name -ne 'StartToggle') { return }
    $row = $b.DataContext; $want = [bool]$b.IsChecked
    # the row decides (it flips only when Windows accepted the change); UpdateTarget keeps the binding alive
    $be = $b.GetBindingExpression([System.Windows.Controls.Primitives.ToggleButton]::IsCheckedProperty); if ($be) { $be.UpdateTarget() }
    if (-not $want) {
        Show-Dialog -Title (T 'startup.disable') -Text (T 'startup.confirm.disable' @($row.Title)) -Glyph ([string][char]0xE7E8) -Colors @('#38BDF8', '#0369A1') -Buttons @(
            @{ Text = T 'startup.disable'; Kind = 'Primary'; Context = $row; Action = { param($r) Set-StartupRow $r $false } }, @{ Text = T 'dlg.later'; Kind = 'Ghost' })
    } else { Set-StartupRow $row $true }
})
# right-click menus on every list
$ui.ProgramList.Add_PreviewMouseRightButtonUp({ param($s, $e) $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if ($r) { Show-ProgramMenu $r; $e.Handled = $true } })
$ui.StartupList.Add_PreviewMouseRightButtonUp({ param($s, $e) $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if ($r) { Show-StartupMenu $r; $e.Handled = $true } })
$ui.SecStatusList.Add_PreviewMouseRightButtonUp({ param($s, $e) $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if ($r) { Show-SecurityMenu $r; $e.Handled = $true } })
$ui.ActivityList.Add_PreviewMouseRightButtonUp({ param($s, $e) $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if ($r) { Show-ActivityMenu $r; $e.Handled = $true } })
$ui.CleanupList.Add_PreviewMouseRightButtonUp({ param($s, $e)
    $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if (-not $r) { return }
    $e.Handled = $true
    Show-Menu $ui.CleanupList @(
        @{ Text = T 'menu.cleanOnly'; Enabled = (-not $r.Locked); Context = $r; Action = { param($x) foreach ($c in $cleanRows) { $c.Selected = ($c -eq $x) }; Update-CleanupTotal; Start-Cleanup } },
        '-',
        @{ Text = T 'up.selectAll'; Action = { foreach ($c in $cleanRows) { if (-not $c.Locked) { $c.Selected = $true } }; Update-CleanupTotal } },
        @{ Text = T 'up.selectNone'; Action = { foreach ($c in $cleanRows) { $c.Selected = $false }; Update-CleanupTotal } })
})
$ui.ScanList.Add_PreviewMouseRightButtonUp({ param($s, $e)
    $r = Get-EventRow $e.OriginalSource ([Alerion.ListRow]); if (-not $r) { return }
    $e.Handled = $true
    $running = $script:scanAct -and $activities.Contains($script:scanAct)
    $items = @(@{ Text = $(if ($running -and $script:scanAct.Link -eq $r) { T 'prog.cancel' } else { T 'sec.scan.start' }); Enabled = (-not $running -or $script:scanAct.Link -eq $r); Context = $r; Action = { param($x) Start-Scan $x } })
    if ($r.PSObject.Properties.Name -contains 'Data' -and $r.Data -is [System.Collections.IList]) { $items += @{ Text = T 'sec.showLog'; Context = $r; Action = { param($x) Show-ScanLog $x } } }
    Show-Menu $ui.ScanList $items
})
$ui.ReportList.Add_PreviewMouseRightButtonUp({ param($s, $e)
    $e.Handled = $true
    Show-Menu $ui.ReportList @(
        @{ Text = T 'rep.copyAll'; Action = { Copy-ReportRows @($ui.Grid.ItemsSource) -WithHeader } },
        @{ Text = T 'rep.copyFailed'; Action = { Copy-ReportRows @($ui.Grid.ItemsSource | Where-Object { $_.StatusRank -eq 0 }) -WithHeader } },
        @{ Text = T 'rep.openHtml'; Enabled = $ui.BtnHtml.IsEnabled; Action = { $r = $script:shownReport; if ($r -and (Test-Path $r.HtmlPath)) { Start-Process $r.HtmlPath } } })
})
# inner lists of scrolling pages must not swallow the mouse wheel (Security page)
foreach ($lb in @($ui.ScanList, $ui.SecStatusList)) {
    $lb.Add_PreviewMouseWheel({ param($s, $e)
        $e.Handled = $true
        $a = New-Object System.Windows.Input.MouseWheelEventArgs($e.MouseDevice, $e.Timestamp, $e.Delta)
        $a.RoutedEvent = [System.Windows.UIElement]::MouseWheelEvent
        $ui.PageSecurity.RaiseEvent($a) })
}
$ui.BtnProgRefresh.Add_Click({ Import-Programs })
$ui.CmbProgSort.Add_SelectionChanged({ Set-ProgramSort })
foreach ($seg in 'All', 'Protected') { $ui["SegProg$seg"].Tag = $seg; $ui["SegProg$seg"].Add_Checked({ param($s) $script:progSegment = [string]$s.Tag; $progView.Refresh(); Update-ProgramEmpty }) }
$ui.TxtProgSearch.Add_TextChanged({ $script:progSearch = $ui.TxtProgSearch.Text.Trim(); $ui.TxtProgSearchHint.Visibility = if ($ui.TxtProgSearch.Text) { 'Collapsed' } else { 'Visible' }; $progView.Refresh(); Update-ProgramEmpty })
$ui.ProgramList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) $b = $e.OriginalSource
    if ($b.Name -ne 'ProgAction') { return }
    $row = $b.DataContext
    if ($row.Locked -or $row.Busy) { return }
    Show-Dialog -Title (T 'pg.confirmTitle' @($row.Title)) -Text (T 'pg.confirmText') -Glyph ([string][char]0xE74D) -Colors @('#FF6B6B', '#E0306E') -Buttons @(
        @{ Text = T 'pg.uninstall'; Kind = 'Danger'; Context = $row; Action = { param($r) Start-AppUninstall $r } }, @{ Text = T 'dlg.later'; Kind = 'Ghost' })
})
$ui.BtnCleanupScan.Add_Click({ Import-Cleanup })
$ui.BtnCleanupRun.Add_Click({ Start-Cleanup })
$ui.CleanupList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ Update-CleanupTotal })
$ui.BtnSecRefresh.Add_Click({ Import-Security })
$ui.ScanList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    if ($e.OriginalSource.Name -eq 'ScanAction') { Start-Scan $e.OriginalSource.DataContext }
    elseif ($e.OriginalSource.Name -eq 'ScanLog') { Show-ScanLog $e.OriginalSource.DataContext.Title $e.OriginalSource.DataContext.Data } })
$ui.SecStatusList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) if ($e.OriginalSource.Name -eq 'SecFix' -and $e.OriginalSource.DataContext.Uri) { Start-Process $e.OriginalSource.DataContext.Uri } })
$ui.NavSettings.Add_Checked({ Show-Page 'Settings' })

$ui.BtnScan.Add_Click({ Start-Engine -Mode scan })
$ui.QaScan.Add_Click({ if (-not $script:running) { Start-Engine -Mode scan } else { Show-AppToast (T 'ov.alreadyRunning') 'info' } })
$ui.QaQuick.Add_Click({ $ui.NavSecurity.IsChecked = $true; $q = @($scanRows | Where-Object { $_.Key -eq 'Quick' }) | Select-Object -First 1; if ($q) { Start-Scan $q } })
$ui.QaClean.Add_Click({ $ui.NavCleanup.IsChecked = $true })
$ui.QaHistory.Add_Click({ $ui.NavHistory.IsChecked = $true })
$ui.BtnRecentAll.Add_Click({ $ui.NavHistory.IsChecked = $true })
$ui.BtnCancel.Add_Click({ Request-Cancel; $ui.BtnCancel.IsEnabled = $false; $ui.TxtCurrent.Text = T 'ov.cancelling' })
$ui.BtnRecommended.Add_Click({ Start-Install @(Get-RecommendedRows) })
$ui.BtnInstallSelected.Add_Click({ Start-Install @($rows | Where-Object { $_.Selected -and $_.Selectable }) })
$ui.BtnSelectNone.Add_Click({ foreach ($r in $rows) { $r.Selected = $false }; Update-Counts })
$ui.BtnRestart.Add_Click({ Show-RestartDialog $null })
$ui.DialogLayer.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -eq $ui.DialogDim -and -not $script:dialogModal) { Close-Dialog } })
$ui.BtnToggleLog.Add_Click({
    $ui.LogList.Visibility = if ($ui.LogList.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    $ui.BtnToggleLog.Content = if ($ui.LogList.Visibility -eq 'Visible') { T 'ov.hideLog' } else { T 'ov.showLog' }
})
foreach ($p in 'Critical', 'Important', 'Normal', 'Optional') {
    $ui["Tile$p"].Tag = $p
    $ui["Tile$p"].Add_Click({ param($s) $ui["Seg$($s.Tag)"].IsChecked = $true; Show-Page 'Updates' })
}
foreach ($seg in 'All', 'Critical', 'Important', 'Normal', 'Optional', 'Excluded', 'Installed') {
    $ui["Seg$seg"].Tag = $seg
    $ui["Seg$seg"].Add_Checked({ param($s) $script:segment = [string]$s.Tag; $view.Refresh(); Update-Empty })
}
$ui.TxtSearch.Add_TextChanged({
    $script:search = $ui.TxtSearch.Text.Trim()
    $ui.TxtSearchHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
    $view.Refresh(); Update-Empty
})
# Clicks inside list rows / group headers / chips (template buttons are found by name)
$ui.UpdateList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.CheckBox]) { Update-Counts; return }
    if ($b.Name -eq 'ExcludeBtn') { $r = $b.DataContext; Set-Exclusion -Id $r.Id -Exclude (-not $r.Excluded); return }
    if ($b.Name -eq 'RowAction') { Start-Reinstall $b.DataContext; return }
    if ($b.Name -eq 'GroupSelect') {
        $group = [string]$b.Tag
        $members = @($view | Where-Object { $_.GroupLabel -eq $group -and $_.Selectable })
        $all = @($members | Where-Object { -not $_.Selected }).Count -eq 0
        foreach ($r in $members) { $r.Selected = -not $all }
        Update-Counts
    }
})
$ui.UpdateList.Add_PreviewMouseRightButtonUp({
    param($s, $e)
    $el = $e.OriginalSource
    while ($el -and -not ($el -is [System.Windows.FrameworkElement] -and $el.DataContext -is [Alerion.UpdateRow])) { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
    if ($el) { Show-RowMenu $el.DataContext $el; $e.Handled = $true }
})
$ui.ExclChips.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) if ($e.OriginalSource.Name -eq 'ChipRemove') { Set-Exclusion -Id ([string]$e.OriginalSource.Tag) -Exclude $false }
})
$ui.BtnExclAdd.Add_Click({ $id = $ui.TxtExclAdd.Text.Trim(); if ($id) { Set-Exclusion -Id $id -Exclude $true; $ui.TxtExclAdd.Text = '' } })
$ui.TxtExclAdd.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $ui.BtnExclAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$ui.ReportList.Add_SelectionChanged({ if ($ui.ReportList.SelectedItem) { $script:shownReport = $ui.ReportList.SelectedItem.Report; Show-ReportGrid $script:shownReport } })
$ui.BtnCopyReport.Add_Click({ Copy-ReportRows @($ui.Grid.ItemsSource) -WithHeader })
# right-click in the report: copy selection / everything / only failures (text cells are also selectable with the mouse)
$ui.Grid.Add_PreviewMouseRightButtonUp({ param($s, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox] -and $e.OriginalSource.SelectionLength -gt 0) { return }   # keep the text box's own Copy menu
    Show-ReportMenu; $e.Handled = $true })
$ui.BtnLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($paths.LogDir)`"" })
$ui.BtnHtml.Add_Click({ $r = $script:shownReport; if ($r -and (Test-Path $r.HtmlPath)) { Start-Process $r.HtmlPath } })

# settings: changes are collected and saved with the Save button / when leaving the page / on close
$ui.CmbScale.Add_SelectionChanged({ if (-not $script:loading -and $ui.CmbScale.SelectedItem) { $acc = @($ui.AccentPanel.Children | Where-Object { $_.IsChecked }) | Select-Object -First 1; Set-Appearance $(if ($acc) { [string]$acc.Tag } else { 'Blue' }) ([int]$ui.CmbScale.SelectedItem.Tag) } })
foreach ($c in 'CmbSchedule', 'CmbDay', 'CmbDom', 'CmbReboot', 'CmbLang', 'CmbCheck', 'CmbRunning', 'CmbNvidia', 'CmbCleanSched', 'CmbScale', 'CmbStartPage') { $ui[$c].Add_SelectionChanged({ Register-Change }) }
foreach ($c in 'ChkWake', 'ChkParallel', 'ChkRestore', 'ChkSelf', 'ChkAutostart', 'ChkTray', 'ChkBackupDrivers', 'ChkPrioCritical', 'ChkPrioImportant', 'ChkPrioNormal', 'ChkPrioOptional') { $ui[$c].Add_Click({ Register-Change }) }
foreach ($c in 'RbActInstall', 'RbActNotify', 'RbVisible', 'RbSilent') { $ui[$c].Add_Checked({ Register-Change }) }
foreach ($c in 'TxtTime', 'TxtRepo', 'TxtRebootTime') { $ui[$c].Add_TextChanged({ Register-Change }) }
$ui.BtnSave.Add_Click({ [void](Save-Settings) })
$ui.BtnDiscard.Add_Click({ Show-Config; Show-AppToast (T 'set.discarded') 'info' })   # back to the last saved state
$ui.BtnTestToast.Add_Click({ Show-Toast -Title (T 'toast.testTitle') -Body (T 'toast.testBody'); Show-AppToast (T 'set.testSent') 'info' })
$ui.BtnCheckAppUpdate.Add_Click({ Find-AppUpdate })
Add-TimePicker $ui.TxtTime
Add-TimePicker $ui.TxtRebootTime

# keyboard: Ctrl+F search, F5 rescan, Esc closes dialog / clears search
$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($ui.DialogLayer.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape' -and -not $script:dialogModal) { Close-Dialog; $e.Handled = $true }
        return   # no shortcuts behind an open dialog
    }
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -eq 'Control'
    $page = Get-CurrentPage
    $search = @{ Updates = $ui.TxtSearch; Programs = $ui.TxtProgSearch; Startup = $ui.TxtStartSearch }
    if ($ctrl -and $e.Key -eq 'F') {
        # search on the current page (pages without a search jump to the update search)
        if ($search.ContainsKey($page)) { [void]$search[$page].Focus() } else { $ui.NavUpdates.IsChecked = $true; [void]$ui.TxtSearch.Focus() }
        $e.Handled = $true
    } elseif ($e.Key -eq 'F5') {
        # reload what the current page shows
        switch ($page) { 'Programs' { Import-Programs } 'Startup' { Import-Startup } 'Cleanup' { Import-Cleanup } 'Security' { Import-Security } 'History' { Show-History }
                         default { if (-not $script:running) { Start-Engine -Mode scan } } }
        $e.Handled = $true
    } elseif ($ctrl -and $e.Key -eq 'S' -and $page -eq 'Settings') { [void](Save-Settings); $e.Handled = $true }
    elseif ($ctrl -and $e.Key -ge 'D1' -and $e.Key -le 'D8') {
        $nav = @('Overview', 'Updates', 'Programs', 'Startup', 'Cleanup', 'Security', 'History', 'Settings')[[int]$e.Key - [int][System.Windows.Input.Key]::D1]
        $ui["Nav$nav"].IsChecked = $true; $e.Handled = $true
    } elseif ($e.Key -eq 'Escape') {
        foreach ($b in $search.Values) { if ($b.IsKeyboardFocused) { $b.Text = '' } }
    }
})
$window.Add_Closing({
    param($s, $e)
    # running module work (uninstall, cleanup, scan) would be cut off - ask first
    if ($activities.Count -and -not $script:exiting -and -not $devMode) {
        $e.Cancel = $true
        Show-Dialog -Title (T 'dlg.closeBusyTitle' @($activities.Count)) -Text (T 'dlg.closeBusyText') -Glyph ([string][char]0xE7BA) -Colors @('#FFB020', '#FF6A3D') -Buttons @(
            @{ Text = T 'dlg.closeBusyWait'; Kind = 'Primary' },
            @{ Text = T 'dlg.closeBusyQuit'; Kind = 'Danger'; Action = { $script:exiting = $true; $window.Close() } })
        return
    }
    if ($script:dirty) { [void](Save-Settings) }
})
$window.Add_Closed({ $timer.Stop(); if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }; try { $guiMutex.ReleaseMutex() } catch { } })

# ------------------------------------------------------------------ dev aids
function Invoke-DevDialog {
    if ($Dialog -eq 'Restart') { Show-RestartDialog $null }
    elseif ($Dialog -eq 'Info') { Show-Dialog -Title (T 'ov.alreadyRunning') -Glyph ([string][char]0xE895) -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' }) }
}

function Invoke-UiTest {
    <# Drives the real window off-screen and writes PASS/FAIL lines to $UiTest (dev aid, no admin). #>
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = 0; $window.ShowInTaskbar = $false
    $window.Add_ContentRendered({
        $res = New-Object System.Collections.Generic.List[string]
        function Check([string]$Name, [bool]$Ok) { $res.Add($(if ($Ok) { "PASS  $Name" } else { "FAIL  $Name" })) }
        $pump = { $f = New-Object System.Windows.Threading.DispatcherFrame
                  [void]$window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ $f.Continue = $false })
                  [System.Windows.Threading.Dispatcher]::PushFrame($f) }
        $click = { param($el) $el.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        try {
            $ui.NavSettings.IsChecked = $true; & $pump
            Check 'settings page visible' ($ui.PageSettings.Visibility -eq 'Visible')
            Check 'starts clean (save disabled)' (-not $ui.BtnSave.IsEnabled)
            Select-ComboTag $ui.CmbReboot 'Scheduled'; & $pump
            Check 'change marks dirty' ($script:dirty -and $ui.BtnSave.IsEnabled)
            Check 'reboot time row appears' ($ui.PnlRebootTime.Visibility -eq 'Visible')
            [void]$ui.TxtTime.Focus(); & $pump
            $state = $ui.TxtTime.Tag
            Check 'time box selects all on focus' ($ui.TxtTime.SelectionLength -eq $ui.TxtTime.Text.Length -and $ui.TxtTime.Text.Length -gt 0)
            Check 'time picker opens' ([bool]$state.Pop.IsOpen)
            Check 'picker preselects current time' ([string]$state.Hours.SelectedItem -eq $ui.TxtTime.Text.Substring(0, 2))
            $state.Hours.SelectedIndex = 7; $state.Mins.SelectedIndex = 45; & $pump
            Check 'picking 07:45 updates text' ($ui.TxtTime.Text -eq '07:45')
            $ui.TxtTime.Text = '21:30'; & $pump
            Check 'typing syncs picker' ([string]$state.Hours.SelectedItem -eq '21' -and [string]$state.Mins.SelectedItem -eq '30')
            $state.Pop.IsOpen = $false
            & $click $ui.BtnSave; & $pump
            Check 'save clears dirty' (-not $script:dirty)
            Check 'saved values kept' ($script:config.Schedule.Time -eq '21:30' -and $script:config.Reboot -eq 'Scheduled')
            Check 'toast shown' ($ui.ToastText.Text -eq (T 'set.saved'))
            $ui.ChkAutostart.IsChecked = $true; & $click $ui.ChkAutostart; & $pump
            Check 'toggle marks dirty' ($script:dirty)
            $ui.NavOverview.IsChecked = $true; & $pump
            Check 'leaving settings saves' (-not $script:dirty -and [bool]$script:config.StartWithWindows)
            Check 'overview visible after leaving' ($ui.PageOverview.Visibility -eq 'Visible')
            $ui.NavSettings.IsChecked = $true; Select-ComboTag $ui.CmbReboot 'Never'; & $pump
            & $click $ui.BtnDiscard; & $pump
            Check 'discard restores value' ([string]$ui.CmbReboot.SelectedItem.Tag -eq 'Scheduled' -and -not $script:dirty)
            Check 'test notification button labelled' ([string]$ui.BtnTestToast.Content -eq (T 'set.testToast'))
            Check 'app version shown' ($ui.LblAppVersion.Text -like "*$version*")
            Check 'eye button style applied' ($null -ne $window.FindResource('EyeButton'))
            # v1.5: navigation, module loading, live progress
            Check 'history sits above settings at the bottom' ($ui.NavHistory.Parent -eq $ui.NavSettings.Parent)
            $wait = { param([scriptblock]$Until, [int]$Seconds = 90)
                $end = (Get-Date).AddSeconds($Seconds)
                while (-not (& $Until) -and (Get-Date) -lt $end) { Complete-BgTasks; Update-Activities; & $pump; Start-Sleep -Milliseconds 150 }
                [bool](& $Until) }
            $ui.NavStartup.IsChecked = $true; & $pump
            Check 'opening a page loads it immediately' ($script:pageState.Startup -in 'loading', 'done')
            Check 'autostart entries listed' ((& $wait { $script:pageState.Startup -eq 'done' } 60) -and $startRows.Count -gt 0)
            Check 'overview tile shows autostart status' ($ui.TxtModStartup.Text -ne [string][char]0x2014)
            $ui.NavCleanup.IsChecked = $true
            Check 'cleanup categories measured' (& $wait { $script:pageState.Cleanup -eq 'done' } 120)
            foreach ($r in $cleanRows) { $r.Selected = ($r.Key -in 'temp', 'thumbs') -and -not $r.Locked }
            Start-Cleanup; & $pump
            Check 'cleanup shows an activity with progress' ($activities.Count -ge 1 -and $ui.ActivityCard.Visibility -eq 'Visible' -and $ui.CleanupProgPanel.Visibility -eq 'Visible')
            Check 'cleanup (test mode) finishes and clears the activity' (& $wait { $activities.Count -eq 0 } 120)
            Check 'progress panel hidden again' ($ui.CleanupProgPanel.Visibility -eq 'Collapsed')
            $ui.NavSecurity.IsChecked = $true
            [void](& $wait { $script:pageState.Security -eq 'done' } 90); & $pump
            $ui.PageSecurity.ScrollToTop(); & $pump
            $wheel = New-Object System.Windows.Input.MouseWheelEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, -360)
            $wheel.RoutedEvent = [System.Windows.UIElement]::PreviewMouseWheelEvent
            $ui.SecStatusList.RaiseEvent($wheel); & $pump
            Check 'security page scrolls with the mouse wheel over its lists' ($ui.PageSecurity.VerticalOffset -gt 0)
            # v1.6: dialogs never replace each other, modal dialogs ignore Esc, shortcuts, validation
            Show-Dialog -Title 'A' -Buttons @(@{ Text = 'OK' }); Show-Dialog -Title 'B' -Buttons @(@{ Text = 'OK' }); & $pump
            Check 'second dialog waits in the queue' ($ui.DlgTitle.Text -eq 'A' -and $script:dialogQueue.Count -eq 1)
            Close-Dialog; Show-QueuedDialog; & $pump
            Check 'queued dialog appears after closing the first' ($ui.DlgTitle.Text -eq 'B'); Close-Dialog
            Show-Dialog -Modal -Title 'M' -Buttons @(@{ Text = 'OK' }); & $pump
            $esc = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Escape)
            $esc.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent; $window.RaiseEvent($esc); & $pump
            Check 'modal dialog ignores Esc' ($ui.DialogLayer.Visibility -eq 'Visible'); Close-Dialog; & $pump
            $ui.NavSettings.IsChecked = $true; & $pump
            $ui.TxtTime.Text = '25:99'; Register-Change; $ui.NavOverview.IsChecked = $true; & $pump
            Check 'invalid time keeps the settings page open' ($ui.PageSettings.Visibility -eq 'Visible' -and $script:dirty)
            $ui.TxtTime.Text = '18:00'; [void](Save-Settings); & $pump
            Check 'valid time saves again' (-not $script:dirty)
            Check 'exclude button shows no text' (@(Get-Content (Join-Path $src 'Gui.xaml') -Raw | Select-String -Pattern 'Text="\{Binding ExcludeTip\}"').Count -eq 0)
            Check 'German status texts for the engine exist' ((T 'eng.winget') -ne 'eng.winget' -and (T 'eng.wu') -ne 'eng.wu')
            Check 'sidebar busy dots exist' ($null -ne $ui.BusyCleanup -and $null -ne $ui.BusyUpdates)
        } catch { $res.Add("FAIL  exception: $($_.Exception.Message)") }
        [IO.File]::WriteAllLines($UiTest, $res)
        $window.Close()
    })
    [void]$window.ShowDialog()
}

function Invoke-Snapshot {
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = 0; $window.ShowInTaskbar = $false
    if ($Page -eq 'Settings') { $window.Height = 1900 }
    $window.Add_ContentRendered({
        Show-Page $Page; if ($Page -eq 'History') { Show-History }
        switch ($Page) { 'Programs' { Import-Programs } 'Startup' { Import-Startup } 'Cleanup' { Import-Cleanup } 'Security' { Import-Security } }
        if ($Query) { $ui.TxtSearch.Text = $Query; $ui.TxtProgSearch.Text = $Query }
        Invoke-DevDialog
        $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(900)
        $t.Add_Tick({
            param($timerSender)
            Complete-BgTasks
            if ($script:bgTasks.Count) { $script:snapWait = 2; return }   # wait for page data
            if ($script:snapWait -gt 0) { $script:snapWait--; return }   # then let WPF lay out the lists
            $timerSender.Stop()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($window)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
            $window.Close()
        })
        $t.Start()
    })
    [void]$window.ShowDialog()
}

# ------------------------------------------------------------------ start
Initialize-Controls
Set-Texts
Show-Config
Import-Scan
Show-Summary
Restore-PageCaches   # last known module data shows instantly, fresh data follows in the background
Update-Tray
Set-ScanTexts
if ($Snapshot) { Invoke-Snapshot; return }
if ($UiTest) { Invoke-UiTest; return }
if ($Preview) {
    if ($X -ge 0) { $window.WindowStartupLocation = 'Manual'; $window.Left = $X; $window.Top = $Y }
    $window.Add_ContentRendered({ Show-Page $Page; if ($Page -eq 'History') { Show-History }; if ($Query) { $ui.TxtSearch.Text = $Query }; Invoke-DevDialog })
    [void]$window.ShowDialog(); return
}
if ($Minimized) { $window.WindowState = 'Minimized' }
# start page chosen in Settings -> Appearance (the overview stays the default)
$sp = [string]$config.Appearance.StartPage
if ($sp -and $sp -ne 'Overview' -and -not $Monitor) { $ui["Nav$sp"].IsChecked = $true }
if (Test-LegacyInstall) {
    # Files were updated in place inside the old 'ALERION Update' folder: finish the move to
    # 'Update Center' (installer stops this window, migrates and reopens the app).
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $paths.AppRoot 'Install.ps1')`" -NoLaunch -Quiet"
    $window.Add_ContentRendered({ Show-Dialog -Title (T 'dlg.migratingTitle') -Text (T 'dlg.migratingText') -Glyph ([string][char]0xE895) })
} elseif (Test-EngineRunning) {
    $st = Get-Status; $script:running = $true; $script:wasRunning = $true; $script:runMode = [string]$st.Mode; Update-Counts
} elseif (-not $script:scanAt -or ((Get-Date) - $script:scanAt).TotalMinutes -gt 30) {
    Start-Engine -Mode scan   # fresh list on open
}
function Show-WhatsNew {
    <# After an update: short "what's new" from CHANGELOG.md, once per version. #>
    $mark = Join-Path $paths.StateDir 'last-version.txt'
    $last = if (Test-Path $mark) { (Get-Content $mark -Raw).Trim() } else { '' }
    try { Write-AtomicFile -Path $mark -Content $version } catch { }
    if (-not $last -or $last -eq $version) { return }
    $log = Join-Path $paths.AppRoot 'CHANGELOG.md'
    $lines = @()
    if (Test-Path $log) {
        $in = $false
        foreach ($l in (Get-Content $log -Encoding UTF8)) {
            if ($l -match '^## \[') { if ($in) { break }; $in = $l -like "## ``[$version``]*"; continue }
            if ($in -and $l -match '^- (.+)$') { $lines += ([string][char]0x2022 + '  ' + ($Matches[1] -replace '\*\*', '' -replace '`', '')) }
        }
    }
    $text = if ($lines.Count) { (@($lines | Select-Object -First 8) -join "`n") } else { T 'dlg.whatsNewNone' }
    Show-Dialog -Title (T 'dlg.whatsNewTitle' @($version)) -Text $text -Glyph ([string][char]0xE789) -Colors @('#30D158', '#22A06B') -Buttons @(@{ Text = T 'dlg.whatsNewOk'; Kind = 'Primary' })
}

# overview first, then the module pages from the bottom of the sidebar upwards
$window.Add_ContentRendered({
    Show-History; $script:preloadAt = (Get-Date).AddMilliseconds(400)
    try { Show-WhatsNew } catch { }
    # code signature of the installed copy (shown under Settings -> App)
    Start-BgTask -Script { Import-Module (Join-Path $src 'Signing.psm1') -DisableNameChecking; Get-PackageSignature -Root (Get-AppPaths).AppRoot } -OnDone {
        param($out, $err)
        $sig = @($out)[0]
        $ui.TxtSignStatus.Text = if ($sig -and $sig.Valid -and $sig.CatalogOk) { T 'set.signed' @(([string]$sig.Subject -replace '^CN=([^,]+).*$', '$1')) } else { T 'set.unsigned' }
    }
})
$timer.Start()
[void]$window.ShowDialog()
