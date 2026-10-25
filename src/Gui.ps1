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
    [switch]$Preview,
    [ValidateSet('Overview', 'Updates', 'History', 'Settings')][string]$Page = 'Overview',
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
Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Report.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Scheduler.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Providers.psm1') -DisableNameChecking -Force
$devMode = [bool]($Snapshot -or $Preview)

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
    Add-Type -TypeDefinition (Get-Content (Join-Path $src 'GuiModel.cs') -Raw)
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
if (Test-Path $paths.IconPath) { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri]$paths.IconPath) }
if (Test-Path $paths.LogoPath) { $ui.Logo.Source = [Windows.Media.Imaging.BitmapImage]::new([uri]$paths.LogoPath) }
if (Test-Path $largeLogo) { $ui.HeroLogo.Source = [Windows.Media.Imaging.BitmapImage]::new([uri]$largeLogo) }

$brushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush { param([string]$Hex) $brushConverter.ConvertFromString($Hex) }

# The window is opaque with its own rounded frame + shadow (Gui.xaml); no DWM glass any more.

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
$sourceKeys = @('Winget', 'WingetIncludeUnknown', 'Chocolatey', 'Store', 'WindowsUpdate', 'WindowsUpdateDrivers', 'MicrosoftUpdate', 'Nvidia', 'Defender', 'Office')
$sourceBoxes = @{}
$sourceRows = @{}

function New-ComboItem { param($Tag, $Text) $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Tag = $Tag; $i.Content = $Text; $i }
function Select-ComboTag { param($Combo, $Tag) foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq [string]$Tag) { $Combo.SelectedItem = $i; return } }; if ($Combo.Items.Count) { $Combo.SelectedIndex = 0 } }
function Format-When { param($Date)
    if (-not $Date) { return (T 'ov.never') }
    $d = [datetime]$Date; $span = (Get-Date) - $d
    if ($span.TotalMinutes -lt 1) { return (T 'time.justNow') }
    if ($span.TotalMinutes -lt 60) { return (T 'time.minutesAgo' @([int]$span.TotalMinutes)) }
    if ($d.Date -eq (Get-Date).Date) { return (T 'time.todayAt' @($d.ToString('HH:mm'))) }
    return $d.ToString('ddd, dd.MM.  HH:mm')
}
function Format-At { param([datetime]$At)
    if ($At.Date -eq (Get-Date).Date) { return (T 'time.todayAt' @($At.ToString('HH:mm'))) }
    if ($At.Date -eq (Get-Date).Date.AddDays(1)) { return (T 'time.tomorrowAt' @($At.ToString('HH:mm'))) }
    return $At.ToString('ddd, dd.MM.  HH:mm')
}

# ------------------------------------------------------------------ in-app dialog
function Close-Dialog { $ui.DialogLayer.Visibility = 'Collapsed'; $ui.DlgExtra.Children.Clear(); $ui.DlgButtons.Children.Clear() }

function Show-Dialog {
    <# Modal card inside the window. Buttons: @{ Text; Kind = Primary|Secondary|Danger|Ghost; Action = {...} } #>
    param([string]$Title, [string]$Text, [string]$Glyph = [string][char]0xE946, [string[]]$Colors = @('#22D3EE', '#2F6BFF'),
          [object[]]$Buttons = @(), [System.Windows.UIElement[]]$Extra = @())
    Close-Dialog
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
        $btn.Tag = $b.Action
        $btn.Add_Click({ param($s) $action = $s.Tag; Close-Dialog; if ($action) { & $action } })
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
    Show-Dialog -Title (T 'dlg.restartingTitle') -Text (T 'dlg.restartingText') -Glyph ([string][char]0xE777) -Colors @('#FFB020', '#FF6A3D') -Buttons @(
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
    $ui.TxtNavSettings.Text = T 'nav.settings'; $ui.TxtSidebarSub.Text = T 'app.subtitle'; $ui.TxtVersion.Text = "Version $version"
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
    $ui.TxtHistoryTitle.Text = T 'nav.history'; $ui.BtnHtml.Content = T 'rep.openHtml'; $ui.BtnLogs.Content = T 'rep.openLogs'
    $ui.ColSource.Header = T 'rep.colSource'; $ui.ColName.Header = T 'rep.colName'; $ui.ColFrom.Header = T 'rep.colFrom'
    $ui.ColTo.Header = T 'rep.colTo'; $ui.ColStatus.Header = T 'rep.colStatus'; $ui.ColNote.Header = T 'rep.colNote'
    $ui.TxtSettingsTitle.Text = T 'nav.settings'
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
    $ui.CmbReboot.Items.Clear(); foreach ($s in 'Prompt', 'Auto', 'Scheduled', 'Never') { [void]$ui.CmbReboot.Items.Add((New-ComboItem $s (T "set.reboot.$s"))) }
    $culture = if ((Get-CurrentLanguage) -eq 'de') { [Globalization.CultureInfo]'de-DE' } else { [Globalization.CultureInfo]'en-US' }
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
        if ($devMode) { $script:config = $c; Set-Dirty $false; Show-AppToast (T 'set.saved'); return $true }
        Save-Config -Config $c
        if ([bool]$c.StartWithWindows -ne [bool]$script:config.StartWithWindows) { Set-Autostart -Enabled ([bool]$c.StartWithWindows) }
        $scheduleChanged = ($c.Schedule | ConvertTo-Json -Compress) -ne ($script:config.Schedule | ConvertTo-Json -Compress)
        if ($scheduleChanged) { Register-ScheduleTask -Config $c }
        $langChanged = $c.Language -ne $script:config.Language
        $script:config = $c
        if ($langChanged) { Import-I18n -Language $c.Language; Set-Texts; Show-Config; Update-RowTexts }
        Show-Summary
        Set-Dirty $false
        Show-AppToast (T 'set.saved')
        return $true
    } catch {
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
    $Row.ExcludeTip = if ($Row.Excluded) { T 'up.include' } else { T 'up.exclude' }
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
    $r.Major = ($Item.PSObject.Properties.Name -contains 'Major') -and [bool]$Item.Major
    $r.MajorLabel = T 'up.major'
    $r.IsUpdate = $IsUpdate
    $r.CanExclude = ($r.Source -in 'winget', 'choco', 'windows', 'gpu') -and $r.Id -and ($r.Id -notmatch '^(ARP|MSIX)\\')
    $r.Note = Resolve-Text ([string]$Item.Message)
    if ($r.IsCheck) { $r.To = ''; $r.Note = T 'msg.checkInstall' }
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
    $script:scanAt = [datetime]::Parse($scan.ScannedAt)
    $ids = @{}
    foreach ($i in @($scan.Items)) {
        if (-not $i) { continue }
        $isUpdate = $i.Status -eq 'Available' -or ($i.Status -eq 'Skipped' -and $i.Message -eq 'msg.excluded')
        $row = New-Row $i $isUpdate
        if ($row.IsUpdate -and -not $row.Excluded) {
            $row.Selected = if ($hadRows -and $previous.ContainsKey($row.Key)) { $previous[$row.Key] } else { $row.Priority -ne 'Optional' }
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
    $rec = @($rows | Where-Object { $_.Selectable -and $_.Priority -ne 'Optional' })
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
        $crit = @($rows | Where-Object { $_.IsUpdate -and -not $_.Excluded -and $_.Priority -eq 'Critical' }).Count
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
    $ui.TxtLastRun.Text = if ($last -and -not $last.DryRun) { Format-When ([datetime]::Parse($last.EndedAt)) } else { T 'ov.never' }
    Update-RebootBanner
    Update-Counts
}

# ------------------------------------------------------------------ history
function Get-ReportFiles {
    @(Get-ChildItem $paths.ReportDir -Filter 'report-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 60)
}

function Show-History {
    $items = foreach ($f in Get-ReportFiles) {
        try { $r = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $title = ([datetime]::Parse($r.EndedAt)).ToString('dd.MM.yyyy  HH:mm')
        $sub = if ($r.DryRun) { T 'hist.check' } else { T 'ov.resultLine' @($r.Counts.Updated, $r.Counts.Failed) }
        [pscustomobject]@{ Title = $title; Subtitle = $sub; Report = $r }
    }
    $ui.ReportList.ItemsSource = @($items)
    if (@($items).Count) { $ui.ReportList.SelectedIndex = 0 } else { Show-ReportGrid $null }
}

function Show-ReportGrid { param($Report)
    $ui.TxtHistoryEmpty.Text = T 'rep.none'
    $ui.TxtHistoryEmpty.Visibility = if ($Report) { 'Collapsed' } else { 'Visible' }
    $ui.HistoryCard.Visibility = if ($Report) { 'Visible' } else { 'Collapsed' }
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
        }
    }
    $ui.Grid.ItemsSource = @($list)
}

# ------------------------------------------------------------------ engine control
function Show-Page { param([string]$Name)
    foreach ($p in 'Overview', 'Updates', 'History', 'Settings') { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    if (-not $ui["Nav$Name"].IsChecked) { $ui["Nav$Name"].IsChecked = $true }
}

function Test-EngineRunning {
    $st = Get-Status
    return [bool]($st -and $st.Running -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue))
}

function Start-Engine {
    param([ValidateSet('scan', 'install')][string]$Mode, [string[]]$Keys, [switch]$SelfOnly)
    if ($devMode) { return }
    if (Test-EngineRunning) {
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

function Start-Install { param([object[]]$Selected)
    $keys = @($Selected | ForEach-Object { $_.Key })
    if (-not $keys.Count) { return }
    foreach ($r in $rows) { if ($r.IsUpdate) { Set-RowState $r '' } }
    foreach ($r in $Selected) { Set-RowState $r 'Pending' }
    Start-Engine -Mode install -Keys $keys
    Show-Page 'Overview'
}

function Complete-InstallRun {
    <# After an install: history, restart handling (in-app), fresh scan. #>
    Show-Summary; Show-History; Show-Page 'History'; [void]$window.Activate()
    $rep = Get-LastReport
    if ($rep -and @($rep.Items | Where-Object { $_.Source -eq 'self' -and $_.Status -eq 'Updated' }).Count) {
        Show-Dialog -Title (T 'dlg.appUpdatedTitle') -Text (T 'dlg.appUpdatedText') -Glyph ([string][char]0xE73E) -Colors @('#30D158', '#22A06B') -Buttons @(@{ Text = 'OK'; Kind = 'Primary' })
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
$timer.Add_Tick({
    if ($showEvent.WaitOne(0)) { if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }; [void]$window.Activate() }
    $st = Get-Status
    if ($script:launchAt) {
        $fresh = $st -and $st.StartedAt -and ([datetime]::Parse($st.StartedAt) -ge $script:launchAt.AddSeconds(-2))
        if (-not $fresh) {
            if (((Get-Date) - $script:launchAt).TotalSeconds -gt 90) {
                $script:launchAt = $null; $script:running = $false; $script:wasRunning = $false; Update-Counts
                Show-Dialog -Title (T 'ov.alreadyRunning') -Glyph ([string][char]0xE783) -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' })
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
})

# ------------------------------------------------------------------ events
$ui.BtnClose.Add_Click({ $window.Close() })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$window.Add_StateChanged({
    # Maximized: no shadow margin, square corners (the window touches the screen edges).
    $max = $window.WindowState -eq 'Maximized'
    $ui.Root.Margin = [System.Windows.Thickness]::new($(if ($max) { 7 } else { 12 }))
    $r = [System.Windows.CornerRadius]::new($(if ($max) { 0 } else { 18 }))
    $ui.WindowShadow.CornerRadius = $r; $ui.WindowFrame.CornerRadius = $r; $ui.DialogDim.CornerRadius = $r
})
function Leave-Settings { if ($ui.PageSettings.Visibility -eq 'Visible' -and $script:dirty) { [void](Save-Settings) } }
$ui.NavOverview.Add_Checked({ Leave-Settings; Show-Page 'Overview' })
$ui.NavUpdates.Add_Checked({ Leave-Settings; Show-Page 'Updates' })
$ui.NavHistory.Add_Checked({ Leave-Settings; Show-Page 'History'; Show-History })
$ui.NavSettings.Add_Checked({ Show-Page 'Settings' })

$ui.BtnScan.Add_Click({ Start-Engine -Mode scan })
$ui.BtnCancel.Add_Click({ Request-Cancel; $ui.BtnCancel.IsEnabled = $false; $ui.TxtCurrent.Text = T 'ov.cancelling' })
$ui.BtnRecommended.Add_Click({ Start-Install @($rows | Where-Object { $_.Selectable -and $_.Priority -ne 'Optional' }) })
$ui.BtnInstallSelected.Add_Click({ Start-Install @($rows | Where-Object { $_.Selected -and $_.Selectable }) })
$ui.BtnSelectNone.Add_Click({ foreach ($r in $rows) { $r.Selected = $false }; Update-Counts })
$ui.BtnRestart.Add_Click({ Show-RestartDialog $null })
$ui.DialogLayer.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -eq $ui.DialogDim) { Close-Dialog } })
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
    if ($b.Name -eq 'GroupSelect') {
        $group = [string]$b.Tag
        $members = @($view | Where-Object { $_.GroupLabel -eq $group -and $_.Selectable })
        $all = @($members | Where-Object { -not $_.Selected }).Count -eq 0
        foreach ($r in $members) { $r.Selected = -not $all }
        Update-Counts
    }
})
$ui.ExclChips.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e) if ($e.OriginalSource.Name -eq 'ChipRemove') { Set-Exclusion -Id ([string]$e.OriginalSource.Tag) -Exclude $false }
})
$ui.BtnExclAdd.Add_Click({ $id = $ui.TxtExclAdd.Text.Trim(); if ($id) { Set-Exclusion -Id $id -Exclude $true; $ui.TxtExclAdd.Text = '' } })
$ui.TxtExclAdd.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $ui.BtnExclAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$ui.ReportList.Add_SelectionChanged({ if ($ui.ReportList.SelectedItem) { $script:shownReport = $ui.ReportList.SelectedItem.Report; Show-ReportGrid $script:shownReport } })
$ui.BtnLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($paths.LogDir)`"" })
$ui.BtnHtml.Add_Click({ $r = $script:shownReport; if ($r -and (Test-Path $r.HtmlPath)) { Start-Process $r.HtmlPath } })

# settings: changes are collected and saved with the Save button / when leaving the page / on close
foreach ($c in 'CmbSchedule', 'CmbDay', 'CmbDom', 'CmbReboot', 'CmbLang') { $ui[$c].Add_SelectionChanged({ Register-Change }) }
foreach ($c in 'ChkWake', 'ChkParallel', 'ChkRestore', 'ChkSelf', 'ChkAutostart', 'ChkPrioCritical', 'ChkPrioImportant', 'ChkPrioNormal', 'ChkPrioOptional') { $ui[$c].Add_Click({ Register-Change }) }
foreach ($c in 'RbActInstall', 'RbActNotify', 'RbVisible', 'RbSilent') { $ui[$c].Add_Checked({ Register-Change }) }
foreach ($c in 'TxtTime', 'TxtRepo', 'TxtRebootTime') { $ui[$c].Add_TextChanged({ Register-Change }) }
$ui.BtnSave.Add_Click({ [void](Save-Settings) })
$ui.BtnDiscard.Add_Click({ $script:config = Get-Config; Show-Config; Show-AppToast (T 'set.discarded') 'info' })
$ui.BtnTestToast.Add_Click({ Show-Toast -Title (T 'toast.testTitle') -Body (T 'toast.testBody'); Show-AppToast (T 'set.testSent') 'info' })
$ui.BtnCheckAppUpdate.Add_Click({ Find-AppUpdate })
Add-TimePicker $ui.TxtTime
Add-TimePicker $ui.TxtRebootTime

# keyboard: Ctrl+F search, F5 rescan, Esc closes dialog / clears search
$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape' -and $ui.DialogLayer.Visibility -eq 'Visible') { Close-Dialog; $e.Handled = $true }
    elseif ($e.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Show-Page 'Updates'; [void]$ui.TxtSearch.Focus(); $e.Handled = $true }
    elseif ($e.Key -eq 'F5' -and -not $script:running) { Start-Engine -Mode scan; $e.Handled = $true }
    elseif ($e.Key -eq 'Escape' -and $ui.TxtSearch.IsKeyboardFocused) { $ui.TxtSearch.Text = '' }
})
$window.Add_Closing({ if ($script:dirty) { [void](Save-Settings) } })
$window.Add_Closed({ $timer.Stop(); try { $guiMutex.ReleaseMutex() } catch { } })

# ------------------------------------------------------------------ dev aids
function Invoke-DevDialog {
    if ($Dialog -eq 'Restart') { Show-RestartDialog $null }
    elseif ($Dialog -eq 'Info') { Show-Dialog -Title (T 'ov.alreadyRunning') -Glyph ([string][char]0xE895) -Buttons @(@{ Text = 'OK'; Kind = 'Secondary' }) }
}

function Invoke-Snapshot {
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = 0; $window.ShowInTaskbar = $false
    if ($Page -eq 'Settings') { $window.Height = 1900 }
    $window.Add_ContentRendered({
        Show-Page $Page; if ($Page -eq 'History') { Show-History }
        if ($Query) { $ui.TxtSearch.Text = $Query }
        Invoke-DevDialog
        $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(900)
        $t.Add_Tick({
            $t.Stop()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($window)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
            $window.Close()
        }.GetNewClosure())
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
if ($Snapshot) { Invoke-Snapshot; return }
if ($Preview) {
    if ($X -ge 0) { $window.WindowStartupLocation = 'Manual'; $window.Left = $X; $window.Top = $Y }
    $window.Add_ContentRendered({ Show-Page $Page; if ($Page -eq 'History') { Show-History }; if ($Query) { $ui.TxtSearch.Text = $Query }; Invoke-DevDialog })
    [void]$window.ShowDialog(); return
}
if ($Minimized) { $window.WindowState = 'Minimized' }
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
$timer.Start()
[void]$window.ShowDialog()
