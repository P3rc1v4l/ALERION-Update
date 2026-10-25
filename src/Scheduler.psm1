# Update Center - Task Scheduler integration. Tasks under \UpdateCenter\:
#   "Update Center"           - the schedule (absent when Schedule.Type = Manual)
#   "Update Center GUI"       - on-demand only; the desktop shortcut starts it so the app opens
#                               elevated without a UAC prompt
#   "Update Center Autostart" - optional, opens the app minimized at sign-in
#   "Update Center Restart"   - optional one-time restart
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:TaskPath      = (Get-Product).TaskPath
$script:TaskSchedule  = 'Update Center'
$script:TaskGui       = 'Update Center GUI'
$script:TaskAutostart = 'Update Center Autostart'

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
    <Author>Update Center</Author>
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
    $xml = New-TaskXml -Description 'Opens Update Center elevated (started by the desktop shortcut).' -Arguments (Get-GuiArguments -AppRoot $AppRoot) -InstancePolicy Parallel -TimeLimit 'PT0S'
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskGui -Xml $xml -Force | Out-Null
}

function Register-ScheduleTask {
    <# Creates, updates or removes the scheduled run according to the config. #>
    param([Parameter(Mandatory)]$Config, [string]$AppRoot = (Get-AppPaths).AppRoot)
    if ($Config.Schedule.Type -eq 'Manual') {
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskSchedule -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    $xml = New-TaskXml -Description 'Keeps apps, drivers and Windows up to date (Update Center).' `
        -Arguments (Get-EngineArguments -AppRoot $AppRoot) -TriggerXml (New-TriggerXml -Schedule $Config.Schedule) -WakeToRun ([bool]$Config.Schedule.WakeToRun)
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskSchedule -Xml $xml -Force | Out-Null
}

$script:TaskRestart = 'Update Center Restart'

function Register-RestartTask {
    <# One-time restart at the given time. Runs as SYSTEM (works while locked), warns 2 minutes ahead
       (cancel: shutdown /a), is NOT caught up when the PC was off and deletes itself afterwards. #>
    param([Parameter(Mandatory)][datetime]$At, [string]$Message = 'Update Center: restart to finish updates')
    $fmt = 'yyyy-MM-ddTHH:mm:ss'
    $shutdown = Join-Path $env:WINDIR 'System32\shutdown.exe'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>Update Center</Author><Description>One-time restart planned by Update Center.</Description></RegistrationInfo>
  <Triggers><TimeTrigger><StartBoundary>$($At.ToString($fmt))</StartBoundary><EndBoundary>$($At.AddHours(1).ToString($fmt))</EndBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>false</StartWhenAvailable>
    <DeleteExpiredTaskAfter>PT1M</DeleteExpiredTaskAfter>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author"><Exec><Command>$(ConvertTo-XmlText $shutdown)</Command><Arguments>$(ConvertTo-XmlText ("/r /t 120 /c `"$Message`""))</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskRestart -Xml $xml -Force | Out-Null
}

function Get-PlannedRestart {
    <# Returns the planned restart time or $null. #>
    try {
        $t = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskRestart -ErrorAction Stop
        $at = [datetime]$t.Triggers[0].StartBoundary
        if ($at -gt (Get-Date)) { return $at }
    } catch { }
    return $null
}

function Unregister-RestartTask {
    Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskRestart -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-RestartNow {
    <# Short countdown so open documents can still be saved; cancel with shutdown /a. #>
    param([int]$Seconds = 15, [string]$Message = 'Update Center')
    Unregister-RestartTask
    & (Join-Path $env:WINDIR 'System32\shutdown.exe') /r /t $Seconds /c $Message
}

function Register-AutostartTask {
    <# Opens the app minimized at sign-in of the current user (elevated, no UAC prompt). #>
    param([string]$AppRoot = (Get-AppPaths).AppRoot)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trigger = "<LogonTrigger><Enabled>true</Enabled><UserId>$(ConvertTo-XmlText $sid)</UserId><Delay>PT20S</Delay></LogonTrigger>"
    $xml = New-TaskXml -Description 'Starts Update Center minimized at sign-in.' -Arguments ((Get-GuiArguments -AppRoot $AppRoot) + ' -Minimized') `
        -TriggerXml $trigger -InstancePolicy IgnoreNew -TimeLimit 'PT0S'
    # A logon trigger must not depend on the network being up.
    $xml = $xml.Replace('<RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>', '<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>')
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskAutostart -Xml $xml -Force | Out-Null
}

function Set-Autostart {
    param([Parameter(Mandatory)][bool]$Enabled, [string]$AppRoot = (Get-AppPaths).AppRoot)
    if ($Enabled) { Register-AutostartTask -AppRoot $AppRoot }
    else { Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskAutostart -Confirm:$false -ErrorAction SilentlyContinue }
}

function Remove-LegacyTasks {
    <# v1.x ("ALERION Update") task folder. #>
    $legacy = (Get-Product).LegacyTaskPath
    Get-ScheduledTask -TaskPath $legacy -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'ALERION*' } |
        ForEach-Object { Unregister-ScheduledTask -TaskPath $legacy -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
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
    foreach ($n in @($script:TaskSchedule, $script:TaskGui, $script:TaskRestart, $script:TaskAutostart)) {
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *
