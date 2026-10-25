# ALERION Update - Task Scheduler integration.
# Two tasks under \ALERION\:
#   "ALERION Update"      - the schedule (absent when Schedule.Type = Manual)
#   "ALERION Update GUI"  - on-demand only; the desktop shortcut starts it so the app opens
#                           elevated without a UAC prompt.
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:TaskPath     = '\ALERION\'
$script:TaskSchedule = 'ALERION Update'
$script:TaskGui      = 'ALERION Update GUI'

function Get-TaskNames { [pscustomobject]@{ Path = $script:TaskPath; Schedule = $script:TaskSchedule; Gui = $script:TaskGui } }

function Get-PowerShellExe { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
function Get-ConhostExe { Join-Path $env:WINDIR 'System32\conhost.exe' }

function ConvertTo-XmlText { param([string]$Value) [Security.SecurityElement]::Escape($Value) }

function New-TriggerXml {
    param([Parameter(Mandatory)]$Schedule)
    $time = [datetime]::ParseExact($Schedule.Time, 'HH:mm', $null)
    $start = (Get-Date).Date.AddHours($time.Hour).AddMinutes($time.Minute).ToString('yyyy-MM-ddTHH:mm:ss')
    switch ($Schedule.Type) {
        'Daily'    { $body = '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>' }
        'Weekly'   { $body = "<ScheduleByWeek><DaysOfWeek><$($Schedule.DayOfWeek) /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>" }
        'BiWeekly' { $body = "<ScheduleByWeek><DaysOfWeek><$($Schedule.DayOfWeek) /></DaysOfWeek><WeeksInterval>2</WeeksInterval></ScheduleByWeek>" }
        'Monthly'  {
            $months = ([Globalization.CultureInfo]::InvariantCulture.DateTimeFormat.MonthNames | Where-Object { $_ }) | ForEach-Object { "<$_ />" }
            $body = "<ScheduleByMonth><DaysOfMonth><Day>$([int]$Schedule.DayOfMonth)</Day></DaysOfMonth><Months>$($months -join '')</Months></ScheduleByMonth>"
        }
        default    { return '' }
    }
    return "<CalendarTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled>$body</CalendarTrigger>"
}

function New-TaskXml {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$TriggerXml = '',
        [bool]$WakeToRun = $false,
        [string]$UserSid = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value),
        [ValidateSet('IgnoreNew', 'Parallel')][string]$InstancePolicy = 'IgnoreNew',
        [string]$TimeLimit = 'PT8H'
    )
    $triggers = if ($TriggerXml) { "<Triggers>$TriggerXml</Triggers>" } else { '<Triggers />' }
    $networkOnly = if ($TriggerXml) { 'true' } else { 'false' }
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>ALERION Studios</Author>
    <Description>$(ConvertTo-XmlText $Description)</Description>
  </RegistrationInfo>
  $triggers
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $UserSid)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>$InstancePolicy</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>$networkOnly</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>$(if ($WakeToRun) { 'true' } else { 'false' })</WakeToRun>
    <ExecutionTimeLimit>$TimeLimit</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText (Get-ConhostExe))</Command>
      <Arguments>$(ConvertTo-XmlText $Arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Get-EngineArguments {
    param([string]$AppRoot = (Get-AppPaths).AppRoot)
    "--headless `"$(Get-PowerShellExe)`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $AppRoot 'src\UpdateEngine.ps1')`" -Scheduled"
}

function Get-GuiArguments {
    param([string]$AppRoot = (Get-AppPaths).AppRoot)
    "--headless `"$(Get-PowerShellExe)`" -NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $AppRoot 'src\Gui.ps1')`""
}

function Register-GuiTask {
    param([string]$AppRoot = (Get-AppPaths).AppRoot)
    $xml = New-TaskXml -Description 'Opens ALERION Update elevated (started by the desktop shortcut).' -Arguments (Get-GuiArguments -AppRoot $AppRoot) -InstancePolicy Parallel -TimeLimit 'PT0S'
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskGui -Xml $xml -Force | Out-Null
}

function Register-ScheduleTask {
    <# Creates, updates or removes the scheduled run according to the config. #>
    param([Parameter(Mandatory)]$Config, [string]$AppRoot = (Get-AppPaths).AppRoot)
    if ($Config.Schedule.Type -eq 'Manual') {
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskSchedule -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    $xml = New-TaskXml -Description 'Keeps apps, drivers and Windows up to date (ALERION Update).' `
        -Arguments (Get-EngineArguments -AppRoot $AppRoot) -TriggerXml (New-TriggerXml -Schedule $Config.Schedule) -WakeToRun ([bool]$Config.Schedule.WakeToRun)
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskSchedule -Xml $xml -Force | Out-Null
}

function Get-NextRun {
    try {
        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $script:TaskSchedule -ErrorAction Stop
        if ($info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { return $info.NextRunTime }
    } catch { }
    return $null
}

function Test-GuiTask {
    $null -ne (Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskGui -ErrorAction SilentlyContinue)
}

function Unregister-AllTasks {
    foreach ($n in @($script:TaskSchedule, $script:TaskGui)) {
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *
