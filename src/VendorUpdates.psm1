# Update Center - vendor updates: OEM driver tools and apps with their own updater.
# Only official, documented command lines are used (ASUS: unofficial public web API, see the ASUS section). Result objects come from New-UpdateResult
# (Providers.psm1) and carry extra properties: Vendor, ManualOnly, Category, Hint.
# Keep this file ASCII-only (Windows PowerShell 5.1).
#
# VERIFIED vs ASSUMED is listed per area in the comments marked [VERIFIED] / [ASSUMED].

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Providers.psm1') -DisableNameChecking

# ---------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------

function Get-VuProp {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Add-VuProps {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Props)
    foreach ($k in $Props.Keys) { $Item | Add-Member -NotePropertyName $k -NotePropertyValue $Props[$k] -Force }
    return $Item
}

function New-VuCandidate {
    param(
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Key, [string]$From = '', [string]$To = '',
        [string]$Status = 'Available', [string]$Message = '', [string]$Priority = 'Important',
        [bool]$IsCheck = $false, [string]$Vendor = '', [bool]$ManualOnly = $false, [string]$Category = '', [bool]$Major = $false
    )
    $item = New-UpdateResult -Source $Source -Name $Name -Id $Id -From $From -To $To -Status $Status -Message $Message -Key $Key -Priority $Priority -IsCheck $IsCheck
    $item.Major = $Major
    return Add-VuProps -Item $item -Props @{ Vendor = $Vendor; ManualOnly = $ManualOnly; Category = $Category }
}

function Get-VuWorkDir {
    $dir = Join-Path (Get-AppPaths).CacheDir ("vendor-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Get-VuFileVersion {
    param([string]$Path)
    try { if ($Path -and (Test-Path -LiteralPath $Path)) { return [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion } } catch { }
    return ''
}

function Get-VuProgramDirs {
    $d = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    return @($d | Select-Object -Unique)
}

function Find-VuFile {
    <# First existing file of: {ProgramFiles, ProgramFiles(x86)} + each relative path. #>
    param([Parameter(Mandatory)][string[]]$Relative)
    foreach ($base in (Get-VuProgramDirs)) {
        foreach ($rel in $Relative) {
            $p = Join-Path $base $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }
    return $null
}

function Get-VuUninstallEntry {
    <# -MachineOnly: HKLM only. Required whenever a path from the entry is executed (HKCU is user-writable). #>
    param([Parameter(Mandatory)][string]$NameRegex, [switch]$MachineOnly)
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    if (-not $MachineOnly) { $roots += 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }
    foreach ($e in @(Get-ItemProperty $roots -ErrorAction SilentlyContinue)) {
        $n = [string](Get-VuProp $e 'DisplayName')
        if ($n -and $n -match $NameRegex) { return $e }
    }
    return $null
}

function Test-VuProcessRunning {
    param([Parameter(Mandatory)][string[]]$Name)
    return (@(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count -gt 0)
}

function Format-VuVersion {
    <# Combined getters return "registry|file"; show the first non-empty part. #>
    param([string]$Version)
    foreach ($p in ($Version -split '\|')) { if ($p) { return $p } }
    return ''
}

function Wait-VuVersionChange {
    <# Polls a version getter until it differs from $From or the timeout passes. Returns the last version seen. #>
    param([Parameter(Mandatory)][scriptblock]$GetVersion, [string]$From = '', [int]$Minutes = 5, [int]$PollSeconds = 5)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $cur = [string](& $GetVersion)
    while ($cur -eq $From -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $cur = [string](& $GetVersion)
    }
    return $cur
}

# ---------------------------------------------------------------------------------------
# Safe process start. The engine runs elevated, so a binary from a user-writable location
# (%LOCALAPPDATA%, %APPDATA%, the profile, paths from HKCU) must never run elevated.
#   - Elevated runs only for files under ProgramFiles, ProgramFiles(x86) or WINDIR.
#   - Everything else (and every GUI program / launcher) starts NON-elevated through a one-shot
#     scheduled task \UpdateCenter\Update Center Launch (interactive user, RunLevel Limited),
#     which is unregistered again once it has started.
# Hooks exist so tests can mock the elevation state, the path check and the task runner.
# ---------------------------------------------------------------------------------------

$script:VuLaunchTaskPath = '\UpdateCenter\'
$script:VuLaunchTaskName = 'Update Center Launch'

function Test-VuTrustedPath {
    <# True when the full path lies under ProgramFiles, ProgramFiles(x86) or WINDIR (admin-only writable). #>
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:WINDIR)) {
        if (-not $root) { continue }
        $r = $null
        try { $r = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\' } catch { continue }
        if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-VuInteractiveUser {
    <# The signed-in desktop user (DOMAIN\user). Falls back to the current identity unless that is SYSTEM. #>
    $u = ''
    try { $u = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
    if ($u) { return $u }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id.IsSystem) { return '' }
    return [string]$id.Name
}

function ConvertTo-VuArgumentString {
    param([string[]]$ArgumentList = @())
    $q = @($ArgumentList | Where-Object { $null -ne $_ } | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    return ($q -join ' ')
}

function New-VuLaunchTaskSpec {
    <# Pure description of the one-shot task (no side effects; the task runner turns it into a real task). #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [Parameter(Mandatory)][string]$UserId)
    $wd = ''
    try { $wd = Split-Path -Path $FilePath -Parent } catch { }
    [pscustomobject]@{
        TaskPath = $script:VuLaunchTaskPath; TaskName = $script:VuLaunchTaskName
        Execute = $FilePath; Argument = (ConvertTo-VuArgumentString $ArgumentList); WorkingDirectory = $wd
        UserId = $UserId; LogonType = 'Interactive'; RunLevel = 'Limited'
    }
}

function Invoke-VuLaunchTask {
    <# Registers the task from the spec, starts it, waits until it has started (or, with -Wait, finished),
       then unregisters it. Returns {Started, ExitCode, TimedOut}. #>
    param([Parameter(Mandatory)]$Spec, [switch]$Wait, [int]$TimeoutMinutes = 60)
    $tp = $Spec.TaskPath; $tn = $Spec.TaskName
    $aArgs = @{ Execute = $Spec.Execute }
    if ($Spec.Argument) { $aArgs.Argument = $Spec.Argument }
    if ($Spec.WorkingDirectory) { $aArgs.WorkingDirectory = $Spec.WorkingDirectory }
    $action = New-ScheduledTaskAction @aArgs
    $principal = New-ScheduledTaskPrincipal -UserId $Spec.UserId -LogonType $Spec.LogonType -RunLevel $Spec.RunLevel
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $tp -TaskName $tn -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $started = $false; $code = 0; $timedOut = $false
    try {
        $before = (Get-ScheduledTaskInfo -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue).LastRunTime
        Start-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $started -and (Get-Date) -lt $deadline) {
            $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
            $i = Get-ScheduledTaskInfo -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
            if (($t -and [string]$t.State -eq 'Running') -or ($i -and $i.LastRunTime -ne $before -and $i.LastTaskResult -ne 267011)) { $started = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if ($started -and $Wait) {
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            while ((Get-Date) -lt $deadline) {
                $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
                if (-not $t -or [string]$t.State -ne 'Running') { break }
                Start-Sleep -Seconds 2
            }
            $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
            if ($t -and [string]$t.State -eq 'Running') {
                $timedOut = $true; $code = -999
                Stop-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
            } else {
                $code = [int](Get-ScheduledTaskInfo -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue).LastTaskResult
            }
        }
    } finally {
        # [ASSUMED] Deleting the task does not end a process it already started (Task Scheduler only
        # terminates on Stop / ExecutionTimeLimit), so launchers keep running as the user.
        Unregister-ScheduledTask -TaskPath $tp -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Started = $started; ExitCode = $code; TimedOut = $timedOut }
}

$script:VuHooks = @{
    IsElevated      = { Test-IsAdmin }
    IsTrusted       = { param([string]$Path) Test-VuTrustedPath $Path }
    InteractiveUser = { Get-VuInteractiveUser }
    RunTask         = { param($Spec, [bool]$Wait, [int]$TimeoutMinutes) Invoke-VuLaunchTask -Spec $Spec -Wait:$Wait -TimeoutMinutes $TimeoutMinutes }
    StartDirect     = { param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle)
        $p = @{ FilePath = $FilePath }
        if (@($ArgumentList).Count) { $p.ArgumentList = $ArgumentList }
        if ($WindowStyle) { $p.WindowStyle = $WindowStyle }
        try { $p.WorkingDirectory = Split-Path -Path $FilePath -Parent } catch { }
        if (-not $p.WorkingDirectory) { $p.Remove('WorkingDirectory') }
        Start-Process @p | Out-Null }
    InvokeDirect    = { param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutMinutes) Invoke-Process -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutMinutes $TimeoutMinutes }
}

function Start-VuProcess {
    <# Fire-and-forget start. Elevated + (untrusted path or -Unelevated): one-shot task as the interactive user.
       Returns 'direct' or 'task'. Throws when no interactive user exists (callers turn that into a result). #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$WindowStyle = '', [switch]$Unelevated)
    $elevated = [bool](& $script:VuHooks.IsElevated)
    if (-not $elevated -or (-not $Unelevated -and [bool](& $script:VuHooks.IsTrusted $FilePath))) {
        & $script:VuHooks.StartDirect $FilePath $ArgumentList $WindowStyle
        return 'direct'
    }
    $user = [string](& $script:VuHooks.InteractiveUser)
    if (-not $user) { throw 'no interactive user' }
    $spec = New-VuLaunchTaskSpec -FilePath $FilePath -ArgumentList $ArgumentList -UserId $user
    Write-Log -Message ("Starting non-elevated as {0}: {1}" -f $user, $FilePath)
    $r = & $script:VuHooks.RunTask $spec $false 0
    if (-not $r -or -not $r.Started) { throw 'launch task did not start' }
    return 'task'
}

function Invoke-VuProcess {
    <# Run-and-wait. Elevated only for trusted paths; otherwise through the non-elevated task (exit code
       from LastTaskResult, no captured output). Returns {ExitCode, Output, TimedOut}. #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMinutes = 90)
    $elevated = [bool](& $script:VuHooks.IsElevated)
    if (-not $elevated -or [bool](& $script:VuHooks.IsTrusted $FilePath)) {
        return (& $script:VuHooks.InvokeDirect $FilePath $ArgumentList $TimeoutMinutes)
    }
    $user = [string](& $script:VuHooks.InteractiveUser)
    if (-not $user) { return [pscustomobject]@{ ExitCode = -998; Output = 'no interactive user'; TimedOut = $false } }
    Write-Log -Level WARN -Message ("Untrusted path, running non-elevated as {0}: {1}" -f $user, $FilePath)
    $spec = New-VuLaunchTaskSpec -FilePath $FilePath -ArgumentList $ArgumentList -UserId $user
    $r = & $script:VuHooks.RunTask $spec $true $TimeoutMinutes
    if (-not $r -or -not $r.Started) { return [pscustomobject]@{ ExitCode = -997; Output = 'launch task did not start'; TimedOut = $false } }
    return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = ''; TimedOut = [bool]$r.TimedOut }
}

# ---------------------------------------------------------------------------------------
# Manufacturer detection
# ---------------------------------------------------------------------------------------

function Resolve-VendorName {
    <# Maps a manufacturer string (Win32_ComputerSystem / BaseBoard) to dell, lenovo, hp, asus or other. #>
    param([AllowEmptyString()][string]$Text)
    switch -Regex ($Text) {
        '(?i)\bdell\b|alienware'                       { return 'dell' }
        '(?i)lenovo'                                   { return 'lenovo' }
        '(?i)^\s*hp\b|hewlett|\bhp inc'                { return 'hp' }
        '(?i)asus'                                     { return 'asus' }
        default                                        { return 'other' }
    }
}

function Get-SystemVendor {
    <# [VERIFIED] CIM classes. Computer manufacturer first, baseboard as fallback (custom PCs). #>
    $cs = ''; $bb = ''
    try { $cs = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer } catch { }
    try { $bb = [string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).Manufacturer } catch { }
    $v = Resolve-VendorName $cs
    if ($v -eq 'other') { $v = Resolve-VendorName $bb }
    [pscustomobject]@{ Vendor = $v; Manufacturer = $cs; BoardManufacturer = $bb }
}

function Test-VuBiosCategory {
    param([string]$Category, [string]$Name = '')
    return ("$Category $Name" -match '(?i)\bbios\b|\buefi\b|system firmware|\bfirmware\b|\bec firmware\b')
}

# ---------------------------------------------------------------------------------------
# Dell Command | Update (dcu-cli.exe)
#   [VERIFIED from Dell docs, from memory]: /scan, /applyUpdates, -silent, -reboot=disable,
#     -report=<dir>, -outputLog=<file>, exit codes 0, 1 (reboot required), 500 (no updates).
#   [ASSUMED] exact XML element names of DCUApplicableUpdates.xml (parser is name-tolerant),
#     -updateType filter values, exit codes 2-8 and 5xx details.
# ---------------------------------------------------------------------------------------

function Get-DellCliPath { Find-VuFile -Relative @('Dell\CommandUpdate\dcu-cli.exe', 'Dell\Dell Command Update\dcu-cli.exe') }

function Get-DellExitInfo {
    <# Returns Kind: Ok | Reboot | NoUpdates | NoAdmin | Busy | Failed | Timeout. #>
    param([int]$ExitCode)
    switch ($ExitCode) {
        0       { return [pscustomobject]@{ Kind = 'Ok'; Text = '' } }
        1       { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot required' } }
        500     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no updates found' } }
        4       { return [pscustomobject]@{ Kind = 'NoAdmin'; Text = 'administrator rights required' } }
        6       { return [pscustomobject]@{ Kind = 'Busy'; Text = 'another instance is running' } }
        5       { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot pending from a previous operation' } }
        -999    { return [pscustomobject]@{ Kind = 'Timeout'; Text = 'timeout' } }
        default { return [pscustomobject]@{ Kind = 'Failed'; Text = "exit $ExitCode" } }
    }
}

function Get-VuXmlChildText {
    param($Node, [string[]]$Names)
    foreach ($n in $Names) {
        foreach ($c in @($Node.ChildNodes)) {
            if ($c.NodeType -eq 'Element' -and $c.LocalName -ieq $n -and $c.InnerText) { return $c.InnerText.Trim() }
        }
        if ($Node.Attributes) {
            foreach ($a in @($Node.Attributes)) { if ($a.LocalName -ieq $n -and $a.Value) { return $a.Value.Trim() } }
        }
    }
    return ''
}

function ConvertFrom-DellScanReport {
    <# Parses DCUApplicableUpdates.xml text into plain objects {Id, Name, Version, Category, Type, Urgency}.
       Accepts any <update> element at any depth. Returns @() for unparseable input. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $out.ToArray() }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml.TrimStart([char]0xFEFF)) } catch { return $out.ToArray() }
    foreach ($u in @($doc.SelectNodes("//*[translate(local-name(),'UPDATE','update')='update']"))) {
        $name = Get-VuXmlChildText $u @('name', 'title')
        if (-not $name) { continue }
        $id = Get-VuXmlChildText $u @('release', 'releaseid', 'id', 'packageid')
        if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
        $out.Add([pscustomobject]@{
            Id = $id; Name = $name; Version = (Get-VuXmlChildText $u @('version', 'vendorversion'))
            Category = (Get-VuXmlChildText $u @('category', 'devicecategory')); Type = (Get-VuXmlChildText $u @('type', 'updatetype'))
            Urgency = (Get-VuXmlChildText $u @('urgency', 'priority'))
        })
    }
    return $out.ToArray()
}

function ConvertTo-DellCandidate {
    param([Parameter(Mandatory)]$Entry)
    $isBios = Test-VuBiosCategory -Category ("$($Entry.Category) $($Entry.Type)") -Name $Entry.Name
    $c = New-VuCandidate -Source 'oem' -Name $Entry.Name -Id $Entry.Id -Key ("oem|dell|{0}" -f $Entry.Id) -To $Entry.Version `
        -Priority 'Important' -Vendor 'dell' -Category ([string]$Entry.Category) -ManualOnly $isBios -Major $isBios `
        -Message $(if ($isBios) { 'vu.bios' } else { '' })
    return $c
}

function Get-DellCandidates {
    $cli = Get-DellCliPath
    if (-not $cli) { return @() }
    $dir = Get-VuWorkDir
    try {
        $log = Join-Path $dir 'scan.log'
        $r = Invoke-VuProcess -FilePath $cli -ArgumentList @('/scan', '-silent', "-report=$dir", "-outputLog=$log") -TimeoutMinutes 10
        $info = Get-DellExitInfo $r.ExitCode
        if ($info.Kind -eq 'NoUpdates') { return @() }
        if ($info.Kind -notin 'Ok', 'Reboot') {
            Write-Log -Level WARN -Message "dcu-cli scan: $($info.Text)"
            return @(New-VuCandidate -Source 'oem' -Name 'Dell Command | Update' -Id 'check' -Key 'oem|dell|check' -Status 'Info' `
                -Message 'msg.vu.scanFailed' -Priority 'Important' -Vendor 'dell' -IsCheck $true)
        }
        $xmlFile = Get-ChildItem -LiteralPath $dir -Filter '*.xml' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Applicable' } | Select-Object -First 1
        if (-not $xmlFile) { $xmlFile = Get-ChildItem -LiteralPath $dir -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $xmlFile) { return @() }
        return @(ConvertFrom-DellScanReport -Xml (Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8) | ForEach-Object { ConvertTo-DellCandidate $_ })
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-DellApply {
    param([switch]$DryRun, $Base)
    $cli = Get-DellCliPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    $dir = Get-VuWorkDir
    # dcu-cli applies a whole batch; BIOS is excluded by the update-type filter [ASSUMED values].
    $cliArgs = @('/applyUpdates', '-silent', '-reboot=disable', "-outputLog=$(Join-Path $dir 'apply.log')", '-updateType=driver,firmware,application,others')
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    try {
        Write-Log -Message "dcu-cli applyUpdates"
        $r = Invoke-VuProcess -FilePath $cli -ArgumentList $cliArgs -TimeoutMinutes 60
        $info = Get-DellExitInfo $r.ExitCode
        switch ($info.Kind) {
            'Ok'        { return New-UpdateResult @Base -Status Updated }
            'Reboot'    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
            'NoUpdates' { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.noUpdates' }
            'Timeout'   { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
            default     { return New-UpdateResult @Base -Status Failed -Message $info.Text }
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------
# Lenovo System Update (tvsu.exe)
#   [VERIFIED from Lenovo System Update admin guide, from memory]: /CM command mode,
#     -search A|R|C|O, -action LIST|DOWNLOAD|INSTALL, -noicon, -nolicense.
#   [ASSUMED] -packagetypes values (1 app, 2 driver, 3 BIOS, 4 firmware) and exit codes.
#   [NOT IMPLEMENTED] parsing of the LIST output (format not confident) -> one IsCheck candidate.
#   Lenovo Commercial Vantage: no documented CLI known -> not integrated.
# ---------------------------------------------------------------------------------------

function Get-LenovoCliPath { Find-VuFile -Relative @('Lenovo\System Update\tvsu.exe') }

function Get-LenovoCandidates {
    $cli = Get-LenovoCliPath
    if (-not $cli) { return @() }
    $ver = Get-VuFileVersion $cli
    return @(New-VuCandidate -Source 'oem' -Name 'Lenovo System Update' -Id 'check' -Key 'oem|lenovo|check' -From $ver `
        -Priority 'Important' -Vendor 'lenovo' -IsCheck $true -Message 'msg.checkInstall')
}

function Invoke-LenovoInstall {
    param([switch]$DryRun, $Base)
    $cli = Get-LenovoCliPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    # Package type 3 (BIOS) is deliberately left out.
    $r = Invoke-VuProcess -FilePath $cli -ArgumentList @('/CM', '-search', 'R', '-action', 'INSTALL', '-packagetypes', '1,2,4', '-noicon', '-nolicense') -TimeoutMinutes 60
    switch ($r.ExitCode) {
        0       { return New-UpdateResult @Base -Status Updated }
        3010    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
        -999    { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
        default { return New-UpdateResult @Base -Status Failed -Message "exit $($r.ExitCode)" }
    }
}

# ---------------------------------------------------------------------------------------
# HP Image Assistant (HPImageAssistant.exe)
#   [VERIFIED from HPIA user guide, from memory]: /Operation:Analyze /Action:List|Install /Silent
#     /ReportFolder:<dir> /SoftpaqDownloadFolder:<dir> /Category:<..> /Selection:<..>.
#   [ASSUMED] report JSON/XML field names (parser tolerant), exit codes 0/256/257/3010.
# ---------------------------------------------------------------------------------------

function Get-HpiaPath {
    $p = Find-VuFile -Relative @('HP\HP Image Assistant\HPImageAssistant.exe', 'HP\HPImageAssistant\HPImageAssistant.exe')
    if ($p) { return $p }
    foreach ($c in @("$env:SystemDrive\SWSetup\HPImageAssistant\HPImageAssistant.exe", "$env:SystemDrive\HPIA\HPImageAssistant.exe")) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    return $null
}

function Get-HpExitInfo {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0       { return [pscustomobject]@{ Kind = 'Ok'; Text = '' } }
        256     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no recommendations' } }
        257     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no recommendations selected' } }
        3010    { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot required' } }
        -999    { return [pscustomobject]@{ Kind = 'Timeout'; Text = 'timeout' } }
        default { return [pscustomobject]@{ Kind = 'Failed'; Text = "exit $ExitCode" } }
    }
}

function ConvertFrom-HpReport {
    <# Parses an HPIA report (JSON or XML text) into {Id, Name, Version, Category, Urgency}. Tolerant by design. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $out.ToArray() }
    $t = $Text.TrimStart([char]0xFEFF).TrimStart()
    if ($t.StartsWith('{') -or $t.StartsWith('[')) {
        $data = $null
        try { $data = $t | ConvertFrom-Json } catch { return $out.ToArray() }
        $recs = @()
        if ($data -is [array]) { $recs = @($data) }
        else {
            $root = if ($data.PSObject.Properties['HPIA']) { $data.HPIA } else { $data }
            $r = Get-VuProp $root 'Recommendations' $null
            if ($null -ne $r) { $recs = @($r) }
        }
        foreach ($rec in $recs) {
            $name = [string](Get-VuProp $rec 'Name'); if (-not $name) { $name = [string](Get-VuProp $rec 'Title') }
            if (-not $name) { continue }
            $id = [string](Get-VuProp $rec 'SoftPaqId'); if (-not $id) { $id = [string](Get-VuProp $rec 'Id') }
            if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
            $cat = [string](Get-VuProp $rec 'Category'); if (-not $cat) { $cat = [string](Get-VuProp $rec 'Type') }
            if (-not $cat) { $cat = [string](Get-VuProp $rec 'TargetComponent') }
            $out.Add([pscustomobject]@{
                Id = $id; Name = $name; Version = [string](Get-VuProp $rec 'Version'); Category = $cat
                Urgency = [string](Get-VuProp $rec 'ReleaseType')
            })
        }
        return $out.ToArray()
    }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($t) } catch { return $out.ToArray() }
    foreach ($n in @($doc.SelectNodes("//*[local-name()='Recommendation' or local-name()='Solution']"))) {
        $name = Get-VuXmlChildText $n @('Name', 'Title')
        if (-not $name) { continue }
        $id = Get-VuXmlChildText $n @('SoftPaqId', 'Id'); if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
        $cat = Get-VuXmlChildText $n @('Category', 'Type', 'TargetComponent')
        $out.Add([pscustomobject]@{ Id = $id; Name = $name; Version = (Get-VuXmlChildText $n @('Version')); Category = $cat; Urgency = (Get-VuXmlChildText $n @('ReleaseType')) })
    }
    return $out.ToArray()
}

function ConvertTo-HpCandidate {
    param([Parameter(Mandatory)]$Entry)
    $isBios = Test-VuBiosCategory -Category $Entry.Category -Name $Entry.Name
    return New-VuCandidate -Source 'oem' -Name $Entry.Name -Id $Entry.Id -Key ("oem|hp|{0}" -f $Entry.Id) -To $Entry.Version `
        -Priority 'Important' -Vendor 'hp' -Category $Entry.Category -ManualOnly $isBios -Major $isBios `
        -Message $(if ($isBios) { 'vu.bios' } else { '' })
}

function Get-HpCandidates {
    $cli = Get-HpiaPath
    if (-not $cli) { return @() }
    $dir = Get-VuWorkDir
    try {
        $r = Invoke-VuProcess -FilePath $cli -ArgumentList @('/Operation:Analyze', '/Action:List', '/Category:All', '/Silent', "/ReportFolder:$dir", "/SoftpaqDownloadFolder:$dir") -TimeoutMinutes 15
        $info = Get-HpExitInfo $r.ExitCode
        if ($info.Kind -eq 'NoUpdates') { return @() }
        if ($info.Kind -notin 'Ok', 'Reboot') {
            Write-Log -Level WARN -Message "HPIA analyze: $($info.Text)"
            return @(New-VuCandidate -Source 'oem' -Name 'HP Image Assistant' -Id 'check' -Key 'oem|hp|check' -Status 'Info' `
                -Message 'msg.vu.scanFailed' -Vendor 'hp' -IsCheck $true)
        }
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.json', '.xml' })
        $file = @($files | Where-Object { $_.Extension -eq '.json' }) | Select-Object -First 1
        if (-not $file) { $file = $files | Select-Object -First 1 }
        if (-not $file) { return @() }
        return @(ConvertFrom-HpReport -Text (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) | ForEach-Object { ConvertTo-HpCandidate $_ })
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-HpInstall {
    param([switch]$DryRun, $Base)
    $cli = Get-HpiaPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    $dir = Get-VuWorkDir
    try {
        # BIOS category is left out on purpose (manual only).
        $r = Invoke-VuProcess -FilePath $cli -ArgumentList @('/Operation:Analyze', '/Action:Install', '/Category:Drivers,Firmware', '/Selection:All', '/Silent', '/AutoCleanup', "/ReportFolder:$dir", "/SoftpaqDownloadFolder:$dir") -TimeoutMinutes 60
        $info = Get-HpExitInfo $r.ExitCode
        switch ($info.Kind) {
            'Ok'        { return New-UpdateResult @Base -Status Updated }
            'Reboot'    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
            'NoUpdates' { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.noUpdates' }
            'Timeout'   { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
            default     { return New-UpdateResult @Base -Status Failed -Message $info.Text }
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------
# ASUS: no official CLI. DriverHub's local web service (127.0.0.1) is NEVER contacted
# (CVE-2025-3462/3463). Instead the public support web API that the asus.com support pages call
# is read with plain GET requests. It is UNOFFICIAL and undocumented: it can change any day.
#   [VERIFIED 2026-10-26 on ROG STRIX X870E-E GAMING WIFI, global site]
#   Drivers: https://www.asus.com/support/api/product.asmx/GetPDDrivers?website=global&model=<board name>&osid=52&pdhashedid=
#            (osid 52 = Windows 11 64-bit, 45 = Windows 10 64-bit; an empty pdhashedid works)
#   BIOS:    https://rog.asus.com/support/webapi/product/GetPDBIOS?website=global&model=<slug>&cpu=&pdid=
#            (www.asus.com GetPDBIOS / GetPDLevel answer {"Status":"FAIL"} without a hashed id)
#   Answer:  {"Status":"SUCCESS","Result":{"Obj":[{"Name":<category>,"Files":[{Id,Version,Title,ReleaseDate
#            "yyyy/MM/dd",DownloadUrl{Global},sha256,FileSize,...}]}]}}
#   Zips contain INF+CAT driver packages and/or ASUS's AsusSetup.exe wrapper (checked by listing several).
# Flow: match ASUS entries to installed devices (Win32_PnPSignedDriver) and HKLM/HKCU uninstall entries
# by vendor + device class, compare versions only when both use the same version scheme.
# Install: HTTPS download from *.asus.com only, SHA-256 check (when listed), zip-slip safe extraction,
# Authenticode check (Valid + expected signer). INF packages -> pnputil /add-driver /install (automatic).
# Packages with their own installer -> the verified installer is opened for the user, non-elevated
# (no silent switches: ASUS documents none). BIOS, firmware and utilities -> manual only.
# ---------------------------------------------------------------------------------------

function Get-AsusTools {
    <# [VERIFIED on an ASUS machine] Files under Program Files\ASUS, Start menu entries. #>
    $hub = Find-VuFile -Relative @('ASUS\AsusDriverHub\ASUS DriverHub.exe')
    $adu = Find-VuFile -Relative @('ASUS\AsusDriverHub\ADU.exe')
    $crate = $false; $myasus = $false
    try {
        foreach ($a in @(Get-StartApps -ErrorAction SilentlyContinue)) {
            if ($a.Name -match '(?i)^Armoury Crate') { $crate = $true }
            if ($a.Name -match '(?i)^MyASUS') { $myasus = $true }
        }
    } catch { }
    $hubVersion = ''
    $e = Get-VuUninstallEntry -NameRegex '^ASUS DriverHub'
    if ($e) { $hubVersion = [string](Get-VuProp $e 'DisplayVersion') }
    [pscustomobject]@{ DriverHubExe = $hub; DriverHubAdu = $adu; DriverHubVersion = $hubVersion; ArmouryCrate = $crate; MyAsus = $myasus
        Any = [bool]($hub -or $adu -or $crate -or $myasus -or $hubVersion) }
}

function Get-AsusDriverHubCandidate {
    <# The old behaviour, kept as fallback when the web API is unreachable or the model is unknown. #>
    $t = Get-AsusTools
    if (-not $t.Any) { return @() }
    return @(New-VuCandidate -Source 'oem' -Name 'ASUS DriverHub / MyASUS' -Id 'driverhub' -Key 'oem|asus|driverhub' -From $t.DriverHubVersion `
        -Priority 'Important' -Vendor 'asus' -IsCheck $true -Message 'vu.asus.open')
}

function Invoke-AsusOpen {
    param([switch]$DryRun, $Base)
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    $t = Get-AsusTools
    try {
        # GUI: always as the signed-in user, never elevated (a browser must not run as admin).
        if ($t.DriverHubExe) { $null = Start-VuProcess -FilePath $t.DriverHubExe -Unelevated }
        else { $null = Start-VuProcess -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList @('https://driverhub.asus.com') -Unelevated }
        return New-UpdateResult @Base -Status Triggered -Message 'msg.vu.opened'
    } catch {
        return New-UpdateResult @Base -Status Failed -Message $_.Exception.Message
    }
}

# --- web access -------------------------------------------------------------------------

function Test-AsusUrl {
    <# Allow-list: https, default port, no user info, host asus.com or *.asus.com (e.g. dlcdnets.asus.com). #>
    param([AllowEmptyString()][string]$Url)
    if (-not $Url) { return $false }
    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https' -or $u.UserInfo -or -not $u.IsDefaultPort) { return $false }
    $h = $u.Host.ToLowerInvariant()
    return ($h -eq 'asus.com' -or $h.EndsWith('.asus.com'))
}

function Enable-VuTls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}

function Get-AsusHttpText {
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 25)
    if (-not (Test-AsusUrl $Url)) { throw "URL rejected: $Url" }
    Enable-VuTls12
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    return [string]$r.Content
}

function Save-AsusFile {
    <# Downloads to $Path. Redirects are followed manually (max 3) and every hop must pass Test-AsusUrl. #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Path, [long]$MaxBytes = 3GB)
    Enable-VuTls12
    $current = $Url
    for ($hop = 0; $hop -lt 4; $hop++) {
        if (-not (Test-AsusUrl $current)) { throw "URL rejected: $current" }
        $req = [Net.HttpWebRequest]::Create($current)
        $req.AllowAutoRedirect = $false; $req.Timeout = 60000; $req.ReadWriteTimeout = 300000; $req.UserAgent = 'UpdateCenter'
        $resp = $null
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
        try {
            $code = [int]$resp.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $loc = [string]$resp.Headers['Location']
                if (-not $loc) { throw 'redirect without Location' }
                $current = (New-Object Uri -ArgumentList ([uri]$current), $loc).AbsoluteUri
                continue
            }
            if ($code -ne 200) { throw "HTTP $code" }
            if ($resp.ContentLength -gt $MaxBytes) { throw 'file too large' }
            $in = $resp.GetResponseStream(); $out = [IO.File]::Create($Path)
            try {
                $buf = New-Object byte[] 262144; $total = 0L
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $total += $n
                    if ($total -gt $MaxBytes) { throw 'file too large' }
                    $out.Write($buf, 0, $n)
                }
            } finally { $out.Dispose(); $in.Dispose() }
            return $Path
        } finally { if ($resp) { $resp.Close() } }
    }
    throw 'too many redirects'
}

function Get-AsusModelNames {
    <# Board product first (desktops / custom PCs), then the computer model unless it is a placeholder. #>
    $names = New-Object System.Collections.Generic.List[string]
    try {
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        if ((Resolve-VendorName ([string]$bb.Manufacturer)) -eq 'asus' -and $bb.Product) { $names.Add(([string]$bb.Product).Trim()) }
    } catch { }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $m = ([string]$cs.Model).Trim()
        if ($m -and $m -notmatch '(?i)system product name|to be filled|default string' -and -not $names.Contains($m)) { $names.Add($m) }
    } catch { }
    return $names.ToArray()
}

function Get-AsusOsId {
    try { if ([Environment]::OSVersion.Version.Build -ge 22000) { return '52' } } catch { }
    return '45'
}

function ConvertTo-AsusSlug { param([string]$Model) return (($Model.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }

function Get-AsusDriversUrl {
    param([Parameter(Mandatory)][string]$Model, [string]$OsId = '52')
    return ('https://www.asus.com/support/api/product.asmx/GetPDDrivers?website=global&model={0}&osid={1}&pdhashedid=' -f [uri]::EscapeDataString($Model), $OsId)
}

function Get-AsusBiosUrls {
    param([Parameter(Mandatory)][string]$Model)
    return @(
        ('https://rog.asus.com/support/webapi/product/GetPDBIOS?website=global&model={0}&cpu=&pdid=' -f [uri]::EscapeDataString((ConvertTo-AsusSlug $Model)))
        ('https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=global&model={0}&pdhashedid=' -f [uri]::EscapeDataString($Model))
    )
}

# --- parsing and versions ------------------------------------------------------------------

function ConvertFrom-AsusDriverResponse {
    <# Parses a GetPDDrivers / GetPDBIOS answer. Returns {Ok; Items} where Items are flat entries
       {Category, Id, Title, Version, ReleaseDate ([datetime] or $null), Url, Sha256, FileSize, Description}.
       Ok = $false for FAIL answers or unparseable text. #>
    param([AllowEmptyString()][string]$Json)
    $items = New-Object System.Collections.Generic.List[object]
    $fail = [pscustomobject]@{ Ok = $false; Items = @() }
    if ([string]::IsNullOrWhiteSpace($Json)) { return $fail }
    $d = $null
    try { $d = $Json.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return $fail }
    if ([string](Get-VuProp $d 'Status') -ne 'SUCCESS') { return $fail }
    $res = Get-VuProp $d 'Result' $null
    if ($null -eq $res) { return $fail }
    foreach ($cat in @(Get-VuProp $res 'Obj' @())) {
        if ($null -eq $cat) { continue }
        $cname = [string](Get-VuProp $cat 'Name')
        foreach ($f in @(Get-VuProp $cat 'Files' @())) {
            if ($null -eq $f) { continue }
            $dl = Get-VuProp $f 'DownloadUrl' $null
            $url = if ($dl -is [string]) { $dl } else { [string](Get-VuProp $dl 'Global') }
            $date = $null
            $ds = [string](Get-VuProp $f 'ReleaseDate')
            $parsed = [datetime]::MinValue
            if ($ds -and [datetime]::TryParseExact($ds.Trim(), [string[]]@('yyyy/MM/dd', 'yyyy/M/d', 'yyyy-MM-dd'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { $date = $parsed }
            $items.Add([pscustomobject]@{
                Category = $cname; Id = [string](Get-VuProp $f 'Id'); Title = ([string](Get-VuProp $f 'Title')).Trim()
                Version = ([string](Get-VuProp $f 'Version')).Trim(); ReleaseDate = $date; Url = $url.Trim()
                Sha256 = ([string](Get-VuProp $f 'sha256')).Trim(); FileSize = [string](Get-VuProp $f 'FileSize')
                Description = [string](Get-VuProp $f 'Description')
            })
        }
    }
    return [pscustomobject]@{ Ok = $true; Items = $items.ToArray() }
}

function ConvertTo-AsusVersion {
    <# '11.28.50.1224', 'v1.01.10', '2026.04.15 (Package version)', '2503' -> {Version, Parts, MajorDigits}; else $null. #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '^\s*[vV]?(\d+(?:\.\d+){0,3})(?![\d.])')
    if (-not $m.Success) { return $null }
    $s = $m.Groups[1].Value
    $parts = $s.Split('.')
    foreach ($p in $parts) { if ($p.Length -gt 9) { return $null } }
    $major = $parts[0].TrimStart('0'); if (-not $major) { $major = '0' }
    $v = $null
    try { $v = if ($parts.Count -eq 1) { New-Object Version -ArgumentList ([int]$s), 0 } else { [version]$s } } catch { return $null }
    return [pscustomobject]@{ Version = $v; Parts = $parts.Count; MajorDigits = $major.Length }
}

function Compare-AsusVersion {
    <# 1 = A newer, 0 = equal, -1 = A older, $null = not comparable (different version schemes:
       part count or number of digits in the first part differ, e.g. 11.28.50.1224 vs 1126.21.901.2024). #>
    param([AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    $va = ConvertTo-AsusVersion $A; $vb = ConvertTo-AsusVersion $B
    if (-not $va -or -not $vb) { return $null }
    if ($va.Parts -ne $vb.Parts -or $va.MajorDigits -ne $vb.MajorDigits) { return $null }
    return $va.Version.CompareTo($vb.Version)
}

# --- matching ----------------------------------------------------------------------------------

$script:AsusWifiName = '(?i)wi-?fi|wireless|wlan|802\.11'
$script:AsusAmd = '(?i)advanced micro devices|^amd\b'

# Category regex, title regex -> how to find the installed counterpart. First match wins.
# Install: 'inf' = automatic via pnputil; 'installer' = verified installer opened for the user.
$script:AsusProfiles = @(
    @{ Id = 'chipset-amd';      Cat = '(?i)chipset';                 Title = '(?i)\bAMD\b.*chipset';        Install = 'installer'; Programs = '^AMD Chipset Software$' }
    @{ Id = 'chipset-intel';    Cat = '(?i)chipset';                 Title = '(?i)intel.*chipset';          Install = 'installer'; Programs = '^Intel\(R\) Chipset Device Software' }
    @{ Id = 'npu-amd';          Cat = '.';                           Title = '(?i)\bAMD\b.*\bNPU\b';        Install = 'installer'; Classes = @('COMPUTEACCELERATOR', 'SYSTEM'); Provider = $script:AsusAmd; Name = '(?i)\bNPU\b|\bIPU\b' }
    @{ Id = 'lan-realtek';      Cat = '(?i)^lan';                    Title = '(?i)realtek';                 Install = 'inf'; Classes = @('NET'); Provider = '(?i)realtek'; NotName = $script:AsusWifiName; Programs = '^Realtek Ethernet Controller Driver' }
    @{ Id = 'lan-intel';        Cat = '(?i)^lan';                    Title = '(?i)intel';                   Install = 'inf'; Classes = @('NET'); Provider = '(?i)^intel'; NotName = $script:AsusWifiName; Programs = '^Intel\(R\) Network Connections' }
    @{ Id = 'lan-marvell';      Cat = '(?i)^lan';                    Title = '(?i)marvell|aquantia';        Install = 'inf'; Classes = @('NET'); Provider = '(?i)marvell|aquantia'; NotName = $script:AsusWifiName }
    @{ Id = 'wifi-mtk';         Cat = '(?i)wireless|wi-?fi|wlan';    Title = '(?i)\bMTK\b|mediatek';        Install = 'inf'; Classes = @('NET'); Provider = '(?i)mediatek'; Name = $script:AsusWifiName }
    @{ Id = 'wifi-qca';         Cat = '(?i)wireless|wi-?fi|wlan';    Title = '(?i)\bQCA\b|qualcomm';        Install = 'inf'; Classes = @('NET'); Provider = '(?i)qualcomm'; Name = $script:AsusWifiName }
    @{ Id = 'wifi-intel';       Cat = '(?i)wireless|wi-?fi|wlan';    Title = '(?i)intel';                   Install = 'inf'; Classes = @('NET'); Provider = '(?i)^intel'; Name = $script:AsusWifiName }
    @{ Id = 'wifi-realtek';     Cat = '(?i)wireless|wi-?fi|wlan';    Title = '(?i)realtek';                 Install = 'inf'; Classes = @('NET'); Provider = '(?i)realtek'; Name = $script:AsusWifiName }
    @{ Id = 'bt-mtk';           Cat = '(?i)bluetooth';               Title = '(?i)\bMTK\b|mediatek';        Install = 'inf'; Classes = @('BLUETOOTH'); Provider = '(?i)mediatek' }
    @{ Id = 'bt-qca';           Cat = '(?i)bluetooth';               Title = '(?i)\bQCA\b|qualcomm';        Install = 'inf'; Classes = @('BLUETOOTH'); Provider = '(?i)qualcomm' }
    @{ Id = 'bt-intel';         Cat = '(?i)bluetooth';               Title = '(?i)intel';                   Install = 'inf'; Classes = @('BLUETOOTH'); Provider = '(?i)^intel' }
    @{ Id = 'bt-realtek';       Cat = '(?i)bluetooth';               Title = '(?i)realtek';                 Install = 'inf'; Classes = @('BLUETOOTH'); Provider = '(?i)realtek' }
    @{ Id = 'audio-realtek-usb'; Cat = '(?i)audio';                  Title = '(?i)realtek.*\busb\b';        Install = 'installer'; Classes = @('MEDIA'); Provider = '(?i)realtek'; Name = '(?i)usb audio'; Programs = '^Realtek USB Audio' }
    @{ Id = 'audio-realtek-hd'; Cat = '(?i)audio';                   Title = '(?i)realtek';                 Install = 'installer'; Classes = @('MEDIA'); Provider = '(?i)realtek'; Name = '(?i)realtek'; NotName = '(?i)\busb\b'; Programs = '^Realtek High Definition Audio' }
    @{ Id = 'vga-amd';          Cat = '(?i)vga|graphic';             Title = '(?i)\bAMD\b';                 Install = 'installer'; Classes = @('DISPLAY'); Provider = $script:AsusAmd; Programs = '^AMD Software$' }
    @{ Id = 'vga-intel';        Cat = '(?i)vga|graphic';             Title = '(?i)intel';                   Install = 'installer'; Classes = @('DISPLAY'); Provider = '(?i)^intel' }
    @{ Id = 'ucm-ite';          Cat = '(?i)usb';                     Title = '(?i)\bITE\b.*\bUCM\b';        Install = 'inf'; Classes = @('USB', 'UCM'); Provider = '(?i)^ITE\b'; Name = '(?i)ucm|usb connector' }
    @{ Id = 'ucm-realtek';      Cat = '(?i)usb';                     Title = '(?i)realtek.*\bUCM\b';        Install = 'inf'; Classes = @('USB', 'UCM'); Provider = '(?i)realtek'; Name = '(?i)ucm' }
    @{ Id = 'raid-amd';         Cat = '(?i)sata|raid|storage';       Title = '(?i)\bAMD\b.*RAID driver';    Install = 'installer'; Classes = @('SCSIADAPTER', 'HDC'); Provider = $script:AsusAmd; Name = '(?i)raid' }
)

function Get-AsusProfile {
    param([string]$Category, [string]$Title)
    foreach ($p in $script:AsusProfiles) { if ($Category -match $p.Cat -and $Title -match $p.Title) { return $p } }
    return $null
}

function Get-AsusProfileById { param([string]$Id) return (@($script:AsusProfiles | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1) }

function Test-AsusUtility {
    param([string]$Category, [string]$Title)
    return ($Category -match '(?i)utilit|software|armoury' -or $Title -match '(?i)RAIDXpert|\butility\b|uninstall tool')
}

function Get-AsusShortTitle {
    param([string]$Title, [string]$Fallback = 'ASUS driver')
    $t = ($Title -replace '(?i)\s+for\s+(windows|win)\b.*$', '' -replace '(?i)\s*\(WHQL\)\.?\s*$', '').Trim().TrimEnd('.')
    if ($t) { return $t }
    return $Fallback
}

function Get-AsusInstalledPrograms {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-ItemProperty $roots -ErrorAction SilentlyContinue)) {
        $n = [string](Get-VuProp $e 'DisplayName')
        if ($n) { $out.Add([pscustomobject]@{ Name = $n; Version = [string](Get-VuProp $e 'DisplayVersion') }) }
    }
    return $out.ToArray()
}

function Get-AsusRecordPath { Join-Path (Get-AppPaths).StateDir 'asus-installed.json' }

function Get-AsusInstallRecords {
    <# Profile id -> {Version (ASUS scheme), Pnp (driver versions right after our pnputil install)}. #>
    $map = @{}
    try {
        $p = Get-AsusRecordPath
        if (Test-Path -LiteralPath $p) {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $j.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
        }
    } catch { }
    return $map
}

function Get-AsusPnpMatches {
    param([Parameter(Mandatory)][hashtable]$Prof, [object[]]$Drivers = @())
    if (-not $Prof.ContainsKey('Classes')) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Drivers)) {
        if ($null -eq $d) { continue }
        $cls = [string](Get-VuProp $d 'DeviceClass')
        if (-not ($Prof.Classes -contains $cls.ToUpperInvariant())) { continue }
        if ([string](Get-VuProp $d 'DriverProviderName') -notmatch $Prof.Provider) { continue }
        $dn = [string](Get-VuProp $d 'DeviceName')
        if ($Prof.ContainsKey('Name') -and $dn -notmatch $Prof.Name) { continue }
        if ($Prof.ContainsKey('NotName') -and $dn -match $Prof.NotName) { continue }
        $ver = [string](Get-VuProp $d 'DriverVersion')
        if (-not $ver) { continue }
        $date = Get-VuProp $d 'DriverDate' $null
        if ($date -isnot [datetime]) {
            $dt = [datetime]::MinValue
            if ($date -and [datetime]::TryParse([string]$date, [ref]$dt)) { $date = $dt } else { $date = $null }
        }
        $out.Add([pscustomobject]@{ Version = $ver; Date = $date; Source = 'pnp'; Name = $dn })
    }
    return $out.ToArray()
}

function Get-AsusInstalled {
    <# Installed counterparts of a profile: PnP drivers, uninstall entries and our own install record. #>
    param([Parameter(Mandatory)][hashtable]$Prof, [object[]]$Drivers = @(), [object[]]$Programs = @(), [hashtable]$Records = @{})
    $list = New-Object System.Collections.Generic.List[object]
    $pnp = @(Get-AsusPnpMatches -Prof $Prof -Drivers $Drivers)
    foreach ($x in $pnp) { $list.Add($x) }
    if ($Prof.ContainsKey('Programs')) {
        foreach ($p in @($Programs)) {
            if ($p -and [string]$p.Name -match $Prof.Programs -and $p.Version) {
                $list.Add([pscustomobject]@{ Version = [string]$p.Version; Date = $null; Source = 'program'; Name = [string]$p.Name })
            }
        }
    }
    # A driver we installed with pnputil does not update the vendor's uninstall entry; the record
    # bridges that, but only while the device still runs exactly the driver we installed.
    if ($Records.ContainsKey($Prof.Id)) {
        $r = $Records[$Prof.Id]
        $rv = [string](Get-VuProp $r 'Version'); $rp = @(Get-VuProp $r 'Pnp' @() | ForEach-Object { [string]$_ })
        if ($rv -and $rp.Count -and @($pnp | Where-Object { $rp -contains $_.Version }).Count) {
            $list.Add([pscustomobject]@{ Version = $rv; Date = $null; Source = 'record'; Name = 'Update Center' })
        }
    }
    return $list.ToArray()
}

function Get-AsusGroupDecision {
    <# Newest ASUS file of a group vs installed. Returns $null (not applicable / up to date) or
       {Kind = 'Newer' | 'Unsure'; File; From}. Only 'Newer' is a confident, comparable result. #>
    param([object[]]$Files, [object[]]$Installed)
    $inst = @($Installed | Where-Object { $_ })
    if (-not $inst.Count) { return $null }
    $sorted = @($Files | Sort-Object -Property @{ Expression = { if ($_.ReleaseDate) { $_.ReleaseDate } else { [datetime]::MinValue } }; Descending = $true },
        @{ Expression = { $v = ConvertTo-AsusVersion $_.Version; if ($v) { $v.Version } else { [version]'0.0' } }; Descending = $true })
    $skipped = $null
    foreach ($f in $sorted) {
        $comparable = @($inst | Where-Object { $null -ne (Compare-AsusVersion $f.Version $_.Version) })
        if (-not $comparable.Count) { if (-not $skipped) { $skipped = $f }; continue }
        $best = $comparable[0]
        foreach ($c in $comparable) { if ((Compare-AsusVersion $c.Version $best.Version) -gt 0) { $best = $c } }
        if ((Compare-AsusVersion $f.Version $best.Version) -gt 0) { return [pscustomobject]@{ Kind = 'Newer'; File = $f; From = $best.Version } }
        if (-not $skipped) { return $null }
        break
    }
    if (-not $skipped) { return $null }
    # Not comparable: only worth a hint when the ASUS file is clearly newer than the installed driver date.
    $dates = @($inst | Where-Object { $_.Date } | ForEach-Object { $_.Date } | Sort-Object -Descending)
    if ($skipped.ReleaseDate -and $dates.Count -and $dates[0] -ge $skipped.ReleaseDate.AddDays(-30)) { return $null }
    $from = @($inst | ForEach-Object { $_.Version } | Select-Object -Unique) -join ' / '
    return [pscustomobject]@{ Kind = 'Unsure'; File = $skipped; From = $from }
}

function ConvertTo-AsusCandidate {
    param([Parameter(Mandatory)]$File, [Parameter(Mandatory)][string]$Id, [string]$From = '', [string]$Status = 'Available',
        [string]$Message = '', [bool]$ManualOnly = $false, [bool]$Major = $false, [string]$InstallMode = '')
    $c = New-VuCandidate -Source 'oem' -Name (Get-AsusShortTitle $File.Title "$($File.Category) $($File.Version)") -Id $Id -Key ("oem|asus|{0}" -f $Id) `
        -From $From -To $File.Version -Status $Status -Message $Message -Priority 'Important' -Vendor 'asus' -Category $File.Category `
        -ManualOnly $ManualOnly -Major $Major
    $rd = if ($File.ReleaseDate) { $File.ReleaseDate.ToString('yyyy-MM-dd') } else { '' }
    return Add-VuProps -Item $c -Props @{ DownloadUrl = $File.Url; Sha256 = $File.Sha256; FileSize = $File.FileSize; ReleaseDate = $rd
        InstallMode = $InstallMode; AsusFileId = $File.Id }
}

function Get-AsusAnalysis {
    <# One row per ASUS group: {Group, Category, Latest, Installed, Decision, Candidate}. Used for candidates and the live report. #>
    param([Parameter(Mandatory)]$Data, [object[]]$Drivers = @(), [object[]]$Programs = @(), [string]$BiosVersion = '', [hashtable]$Records = @{})
    $rows = New-Object System.Collections.Generic.List[object]
    $groups = [ordered]@{}
    foreach ($f in @($Data.Drivers)) {
        if (-not $f -or -not $f.Version) { continue }
        if (Test-AsusUtility $f.Category $f.Title) {
            $prod = ([regex]::Match($f.Title, '^(.*?)(\s+[vV]?\d+(\.\d+)+|\s+for\s+windows|$)')).Groups[1].Value.Trim()
            $gid = 'util-' + (ConvertTo-AsusSlug $prod)
            if (-not $groups.Contains($gid)) { $groups[$gid] = @{ Kind = 'util'; Product = $prod; Files = New-Object System.Collections.Generic.List[object] } }
            $groups[$gid].Files.Add($f); continue
        }
        $p = Get-AsusProfile $f.Category $f.Title
        $gid = if ($p) { $p.Id } else { 'other-' + (ConvertTo-AsusSlug $f.Category) }
        if (-not $groups.Contains($gid)) { $groups[$gid] = @{ Kind = $(if ($p) { 'driver' } else { 'other' }); Profile = $p; Files = New-Object System.Collections.Generic.List[object] } }
        $groups[$gid].Files.Add($f)
    }
    foreach ($gid in $groups.Keys) {
        $g = $groups[$gid]; $files = $g.Files.ToArray()
        $latest = @($files | Sort-Object -Property @{ Expression = { if ($_.ReleaseDate) { $_.ReleaseDate } else { [datetime]::MinValue } } } -Descending)[0]
        $row = [pscustomobject]@{ Group = $gid; Category = $latest.Category; Latest = $latest; Installed = @(); Decision = ''; Candidate = $null }
        switch ($g.Kind) {
            'other' { $row.Decision = 'no matching rule (info only, not shown)' }
            'util' {
                $rx = '^' + [regex]::Escape($g.Product)
                $inst = @($Programs | Where-Object { $_ -and $g.Product -and [string]$_.Name -match $rx -and $_.Version } |
                    ForEach-Object { [pscustomobject]@{ Version = [string]$_.Version; Date = $null; Source = 'program'; Name = [string]$_.Name } })
                $row.Installed = $inst
                $d = Get-AsusGroupDecision -Files $files -Installed $inst
                if (-not $inst.Count) { $row.Decision = 'utility not installed' }
                elseif ($d -and $d.Kind -eq 'Newer') {
                    $row.Decision = 'utility newer (manual only)'
                    $row.Candidate = ConvertTo-AsusCandidate -File $d.File -Id $gid -From $d.From -Message 'vu.asus.utility' -ManualOnly $true
                } else { $row.Decision = 'utility up to date or not comparable' }
            }
            'driver' {
                $inst = @(Get-AsusInstalled -Prof $g.Profile -Drivers $Drivers -Programs $Programs -Records $Records)
                $row.Installed = $inst
                if (-not $inst.Count) { $row.Decision = 'no matching device installed'; break }
                $d = Get-AsusGroupDecision -Files $files -Installed $inst
                if (-not $d) { $row.Decision = 'up to date' }
                elseif ($d.Kind -eq 'Newer') {
                    $msg = if ($g.Profile.Install -eq 'inf') { 'vu.asus.auto' } else { 'vu.asus.interactive' }
                    $row.Decision = 'newer (' + $g.Profile.Install + ')'
                    $row.Candidate = ConvertTo-AsusCandidate -File $d.File -Id $gid -From $d.From -Message $msg -InstallMode $g.Profile.Install
                } else {
                    $row.Decision = 'maybe newer, version scheme differs (info only)'
                    $row.Candidate = ConvertTo-AsusCandidate -File $d.File -Id $gid -From $d.From -Status 'Info' -Message 'vu.asus.unsure' -InstallMode $g.Profile.Install
                }
            }
        }
        $rows.Add($row)
    }
    # BIOS: manual only, always. Firmware tools: installed version is not readable -> not listed.
    $bios = @($Data.Bios | Where-Object { $_ -and $_.Category -match '(?i)^bios' -and $_.Version })
    if ($bios.Count) {
        $latest = @($bios | Sort-Object -Property @{ Expression = { if ($_.ReleaseDate) { $_.ReleaseDate } else { [datetime]::MinValue } } } -Descending)[0]
        $row = [pscustomobject]@{ Group = 'bios'; Category = 'BIOS'; Latest = $latest; Installed = @(); Decision = ''; Candidate = $null }
        if ($BiosVersion) {
            $row.Installed = @([pscustomobject]@{ Version = $BiosVersion; Date = $null; Source = 'bios'; Name = 'BIOS' })
            $cmp = Compare-AsusVersion $latest.Version $BiosVersion
            if ($null -eq $cmp) { $row.Decision = 'BIOS version not comparable' }
            elseif ($cmp -gt 0) {
                $row.Decision = 'BIOS newer (manual only)'
                $row.Candidate = ConvertTo-AsusCandidate -File $latest -Id 'bios' -From $BiosVersion -Message 'vu.bios' -ManualOnly $true -Major $true
            } else { $row.Decision = 'BIOS up to date' }
        } else { $row.Decision = 'installed BIOS version unknown' }
        $rows.Add($row)
    }
    return $rows.ToArray()
}

$script:AsusHooks = @{
    GetText     = { param([string]$Url) Get-AsusHttpText -Url $Url }
    Models      = { Get-AsusModelNames }
    Drivers     = { @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop) }
    Programs    = { Get-AsusInstalledPrograms }
    BiosVersion = { [string](Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion }
    Download    = { param([string]$Url, [string]$Path) Save-AsusFile -Url $Url -Path $Path }
    Signature   = { param([string]$Path) Get-AuthenticodeSignature -LiteralPath $Path }
    Pnputil     = { param([string]$Inf) Invoke-VuProcess -FilePath (Get-PnputilPath) -ArgumentList @('/add-driver', $Inf, '/install') -TimeoutMinutes 15 }
}

function Get-AsusSupportData {
    <# Reads the ASUS API for the first model name that ASUS knows. $null = unreachable / unknown model. #>
    $os = Get-AsusOsId
    foreach ($model in @(& $script:AsusHooks.Models)) {
        if (-not $model) { continue }
        $drv = $null
        try { $drv = ConvertFrom-AsusDriverResponse -Json ([string](& $script:AsusHooks.GetText (Get-AsusDriversUrl -Model $model -OsId $os))) }
        catch { Write-Log -Level WARN -Message "ASUS API (drivers, $model): $($_.Exception.Message)" }
        if (-not $drv -or -not $drv.Ok) { continue }
        $bios = @()
        foreach ($u in (Get-AsusBiosUrls -Model $model)) {
            try {
                $b = ConvertFrom-AsusDriverResponse -Json ([string](& $script:AsusHooks.GetText $u))
                if ($b.Ok) { $bios = @($b.Items); break }
            } catch { }
        }
        return [pscustomobject]@{ Model = $model; Drivers = @($drv.Items); Bios = $bios }
    }
    return $null
}

function Get-AsusApiCandidates {
    param([Parameter(Mandatory)]$Data)
    $drivers = @(); $programs = @(); $bv = ''
    try { $drivers = @(& $script:AsusHooks.Drivers) } catch { Write-Log -Level WARN -Message "PnP driver list: $($_.Exception.Message)" }
    try { $programs = @(& $script:AsusHooks.Programs) } catch { }
    try { $bv = [string](& $script:AsusHooks.BiosVersion) } catch { }
    $rows = @(Get-AsusAnalysis -Data $Data -Drivers $drivers -Programs $programs -BiosVersion $bv -Records (Get-AsusInstallRecords))
    return @($rows | Where-Object { $_.Candidate } | ForEach-Object { $_.Candidate })
}

function Get-AsusCandidates {
    <# Web API first; on failure (offline, unknown model, parse error) the old DriverHub hint. #>
    $data = $null
    try { $data = Get-AsusSupportData } catch { Write-Log -Level WARN -Message "ASUS API: $($_.Exception.Message)" }
    if ($data) {
        try { return @(Get-AsusApiCandidates -Data $data) }
        catch { Write-Log -Level WARN -Message "ASUS analysis failed: $($_.Exception.Message)" }
    }
    return @(Get-AsusDriverHubCandidate)
}

# --- install ------------------------------------------------------------------------------------

function Get-PnputilPath {
    $sysnative = Join-Path $env:WINDIR 'Sysnative\pnputil.exe'
    if (-not [Environment]::Is64BitProcess -and (Test-Path -LiteralPath $sysnative)) { return $sysnative }
    return (Join-Path $env:WINDIR 'System32\pnputil.exe')
}

# Anchored on both sides: 'CN=Intel Corporation Evil' or 'O=Marvellous Apps' must not pass.
$script:AsusSignerPattern = '(?i)(^|,\s*)(CN|O)="?(Microsoft Windows Hardware Compatibility Publisher|Microsoft Windows|Microsoft Corporation|ASUSTeK Computer Inc\.?|Realtek Semiconductor Corp\.?|MediaTek Inc\.?|Advanced Micro Devices,? Inc\.?|Intel Corporation|Qualcomm[^,"]*,? Inc\.?|ITE Tech\.? Inc\.?|Marvell[^,"]*,? Inc\.?|Broadcom Inc\.?)"?\s*(,|$)'

function Test-AsusFileSignature {
    <# Authenticode must be Valid and the signer one of the expected vendors / Microsoft WHQL.
       -Provider (scriptblock taking the path) replaces Get-AuthenticodeSignature in tests. #>
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$Provider = $null)
    $prov = if ($Provider) { $Provider } else { $script:AsusHooks.Signature }
    $s = $null
    try { $s = & $prov $Path } catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message; Signer = '' } }
    if (-not $s) { return [pscustomobject]@{ Ok = $false; Reason = 'no signature'; Signer = '' } }
    $status = [string](Get-VuProp $s 'Status')
    $cert = Get-VuProp $s 'SignerCertificate' $null
    $subject = if ($cert) { [string](Get-VuProp $cert 'Subject') } else { '' }
    if ($status -ne 'Valid') { return [pscustomobject]@{ Ok = $false; Reason = "signature $status"; Signer = $subject } }
    if ($subject -notmatch $script:AsusSignerPattern) { return [pscustomobject]@{ Ok = $false; Reason = 'unexpected signer'; Signer = $subject } }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Signer = $subject }
}

function Expand-AsusZip {
    <# Zip-slip safe extraction (every entry must stay inside $Destination). #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, ($e.FullName -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe zip entry: $($e.FullName)" }
            if (-not $e.Name) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Get-AsusInfPackages {
    <# amd64 INFs that name a catalog file present next to them. Win11 folders win when present. #>
    param([Parameter(Mandatory)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($inf in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)) {
        $rel = $inf.FullName.Substring([Math]::Min($rootFull.Length, $inf.FullName.Length))
        if ($rel -match '(?i)(^|\\)(x86|win32|32|arm|arm64)(\\|$)') { continue }
        $text = ''
        try { $text = Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop } catch { continue }
        if ($text -notmatch '(?i)ntamd64') { continue }
        $m = [regex]::Match($text, '(?im)^\s*CatalogFile(?:\.NTamd64)?\s*=\s*"?([^\s";]+)')
        if (-not $m.Success) { continue }
        $cat = Join-Path $inf.DirectoryName $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath $cat -PathType Leaf)) { continue }
        $list.Add([pscustomobject]@{ Inf = $inf.FullName; Cat = $cat; Rel = $rel })
    }
    $w11 = @($list | Where-Object { $_.Rel -match '(?i)win ?11|\bw11' })
    if ($w11.Count) { return $w11 }
    return $list.ToArray()
}

function Find-AsusInstaller {
    <# ASUS's AsusSetup.exe wrapper (top level first), then setup.exe / install.exe. #>
    param([Parameter(Mandatory)][string]$Root)
    $exes = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { ($_.FullName.Split('\')).Count } }, FullName)
    foreach ($name in 'AsusSetup.exe', 'Setup.exe', 'Install.exe') {
        $hit = @($exes | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-PnputilOutcome {
    <# [ASSUMED from pnputil docs] 0 ok, 3010 ok + reboot, 259 = added but no device updated. #>
    param([object[]]$Results)
    $res = @($Results | Where-Object { $_ })
    if (-not $res.Count) { return [pscustomobject]@{ Kind = 'Failed'; Reboot = $false; Text = 'nothing run' } }
    $reboot = @($res | Where-Object { $_.ExitCode -in 3010, 1641 -or [string]$_.Output -match '(?i)reboot is (needed|required)|system reboot' }).Count -gt 0
    if (@($res | Where-Object { $_.ExitCode -in 0, 3010, 1641 }).Count) { return [pscustomobject]@{ Kind = 'Updated'; Reboot = $reboot; Text = '' } }
    if (@($res | Where-Object { $_.ExitCode -ne 259 }).Count -eq 0) { return [pscustomobject]@{ Kind = 'NoDevice'; Reboot = $false; Text = '' } }
    $bad = @($res | Where-Object { $_.ExitCode -notin 0, 259, 3010, 1641 })[0]
    $text = if ([bool](Get-VuProp $bad 'TimedOut' $false)) { 'msg.timeout' } else { "pnputil exit $($bad.ExitCode)" }
    return [pscustomobject]@{ Kind = 'Failed'; Reboot = $false; Text = $text }
}

function Save-AsusInstallRecord {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version)
    try {
        $p = Get-AsusProfileById $Id
        if (-not $p) { return }
        $pnp = @(Get-AsusPnpMatches -Prof $p -Drivers @(& $script:AsusHooks.Drivers) | ForEach-Object { $_.Version } | Select-Object -Unique)
        $map = Get-AsusInstallRecords
        $map[$Id] = [pscustomobject]@{ Version = $Version; Pnp = $pnp; At = (Get-Date).ToString('o') }
        $obj = New-Object PSObject
        foreach ($k in $map.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $map[$k] }
        Write-AtomicFile -Path (Get-AsusRecordPath) -Content ($obj | ConvertTo-Json -Depth 4)
    } catch { Write-Log -Level WARN -Message "ASUS install record: $($_.Exception.Message)" }
}

function Clear-AsusCache {
    param([string]$Dir, [int]$Days = 14)
    try {
        Get-ChildItem -LiteralPath $Dir -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Invoke-AsusDriverUpdate {
    param([Parameter(Mandatory)]$Candidate, [switch]$DryRun, $Base)
    $key = [string](Get-VuProp $Candidate 'Key')
    $id = ($key -split '\|')[2]
    if ([string](Get-VuProp $Candidate 'Status') -eq 'Info') {
        return New-UpdateResult @Base -Status Skipped -Message ([string](Get-VuProp $Candidate 'Message' 'vu.asus.unsure'))
    }
    $url = [string](Get-VuProp $Candidate 'DownloadUrl')
    if (-not $url) {
        # Candidate came without the extra properties (e.g. rebuilt from a key): look it up again (GET only).
        $data = Get-AsusSupportData
        $again = if ($data) { @(Get-AsusApiCandidates -Data $data | Where-Object { $_.Key -eq $key }) | Select-Object -First 1 } else { $null }
        if (-not $again -or $again.Status -ne 'Available' -or $again.ManualOnly) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.asus.notFound' }
        $Candidate = $again; $url = [string]$again.DownloadUrl
    }
    if (-not (Test-AsusUrl $url)) { return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.hostRejected' }
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }

    $sha = [string](Get-VuProp $Candidate 'Sha256')
    $mode = [string](Get-VuProp $Candidate 'InstallMode' 'installer')
    $to = [string](Get-VuProp $Candidate 'To')
    $dir = Join-Path (Get-AppPaths).CacheDir 'asus'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Clear-AsusCache -Dir $dir
    $fileName = [IO.Path]::GetFileName(([uri]$url).AbsolutePath) -replace '[^A-Za-z0-9._-]', '_'
    if ($fileName -notmatch '(?i)\.zip$') { return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.noPackage' }
    $zip = Join-Path $dir $fileName

    $reuse = $false
    if ($sha -and (Test-Path -LiteralPath $zip)) { $reuse = ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ieq $sha) }
    if (-not $reuse) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Write-Log -Message "ASUS download: $url"
        try { $null = & $script:AsusHooks.Download $url $zip }
        catch {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Log -Level WARN -Message "ASUS download failed: $($_.Exception.Message)"
            return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.downloadFailed'
        }
    }
    if (-not (Test-Path -LiteralPath $zip)) { return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.downloadFailed' }
    if ($sha) {
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $sha) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.hashMismatch'
        }
    } else { Write-Log -Level WARN -Message "ASUS lists no SHA-256 for $fileName; relying on the Authenticode check only" }

    $x = Join-Path $dir ("{0}-{1}" -f [IO.Path]::GetFileNameWithoutExtension($fileName), [guid]::NewGuid().ToString('N').Substring(0, 8))
    try { Expand-AsusZip -ZipPath $zip -Destination $x }
    catch {
        Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
        return New-UpdateResult @Base -Status Failed -Message $_.Exception.Message
    }

    if ($mode -eq 'inf') {
        $good = New-Object System.Collections.Generic.List[object]
        foreach ($pk in @(Get-AsusInfPackages -Root $x)) {
            $sig = Test-AsusFileSignature -Path $pk.Cat
            if ($sig.Ok) { $good.Add($pk) } else { Write-Log -Level WARN -Message "ASUS: catalog rejected ($($sig.Reason)): $($pk.Cat)" }
        }
        if ($good.Count) {
            if (-not [bool](& $script:VuHooks.IsElevated)) { return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.needsAdmin' }
            $results = foreach ($pk in $good) {
                Write-Log -Message "pnputil /add-driver $($pk.Rel) /install"
                & $script:AsusHooks.Pnputil $pk.Inf
            }
            $o = Get-PnputilOutcome -Results @($results)
            Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
            switch ($o.Kind) {
                'Updated' {
                    Save-AsusInstallRecord -Id $id -Version $to
                    if ($o.Reboot) { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
                    return New-UpdateResult @Base -Status Updated
                }
                'NoDevice' { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.asus.noDevice' }
                default    { return New-UpdateResult @Base -Status Failed -Message $o.Text }
            }
        }
        Write-Log -Message 'ASUS: no signed amd64 INF package found, falling back to the interactive installer'
    }

    $exe = Find-AsusInstaller -Root $x
    if (-not $exe) {
        Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
        return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.noPackage'
    }
    $sig = Test-AsusFileSignature -Path $exe
    if (-not $sig.Ok) {
        Write-Log -Level WARN -Message "ASUS: installer rejected ($($sig.Reason), '$($sig.Signer)'): $exe"
        Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue
        return New-UpdateResult @Base -Status Failed -Message 'msg.vu.asus.badSignature'
    }
    # The cache is not under ProgramFiles/WINDIR, so Start-VuProcess runs it non-elevated as the
    # signed-in user; the installer asks for elevation itself (UAC), which the user confirms.
    try { $null = Start-VuProcess -FilePath $exe -Unelevated }
    catch { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.noUser' }
    return New-UpdateResult @Base -Status Triggered -Message 'msg.vu.asus.interactive'
}

# ---------------------------------------------------------------------------------------
# Apps with their own updater (table driven)
# ---------------------------------------------------------------------------------------

function Get-VuHighestVersionDir {
    param([string]$Root, [string]$Filter = '*')
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return '' }
    $best = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter $Filter -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($d.Name, '(\d+(\.\d+){1,3})')
        if (-not $m.Success) { continue }
        $v = $null; try { $v = [version]$m.Groups[1].Value } catch { continue }
        if ($null -eq $best -or $v -gt $best) { $best = $v }
    }
    if ($best) { return $best.ToString() }
    return ''
}

function Get-ChromeInfo {
    $upd = Find-VuFile -Relative @('Google\Update\GoogleUpdate.exe')
    $app = Find-VuFile -Relative @('Google\Chrome\Application\chrome.exe')
    if (-not $upd -or -not $app) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Split-Path (Find-VuFile -Relative @('Google\Chrome\Application\chrome.exe')) -Parent) } }
}

function Get-EdgeInfo {
    $upd = Find-VuFile -Relative @('Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
    $app = Find-VuFile -Relative @('Microsoft\Edge\Application\msedge.exe')
    if (-not $upd -or -not $app) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Split-Path (Find-VuFile -Relative @('Microsoft\Edge\Application\msedge.exe')) -Parent) } }
}

function Get-AdobeRumInfo {
    $rum = Find-VuFile -Relative @('Common Files\Adobe\OOBE\PDApp\UWA\RemoteUpdateManager.exe')
    if (-not $rum) { return $null }
    [pscustomobject]@{ Exe = $rum; GetVersion = { '' } }
}

function Get-EpicInfo {
    $e = Get-VuUninstallEntry -NameRegex '^Epic Games Launcher'
    # The exe path is executed: take InstallLocation from HKLM only (HKCU is user-writable).
    $m = Get-VuUninstallEntry -NameRegex '^Epic Games Launcher' -MachineOnly
    $loc = if ($m) { [string](Get-VuProp $m 'InstallLocation') } else { '' }
    $exe = $null
    foreach ($base in @($loc, (Join-Path $env:ProgramFiles 'Epic Games'), (Join-Path ${env:ProgramFiles(x86)} 'Epic Games')) | Where-Object { $_ }) {
        foreach ($rel in 'Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe', 'Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe') {
            $p = Join-Path $base $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) { $exe = $p; break }
        }
        if ($exe) { break }
    }
    if (-not $exe) { return $null }
    $regVer = if ($e) { [string](Get-VuProp $e 'DisplayVersion') } else { '' }
    $fileExe = $exe
    [pscustomobject]@{ Exe = $exe; GetVersion = {
        $ent = Get-VuUninstallEntry -NameRegex '^Epic Games Launcher'
        $rv = if ($ent) { [string](Get-VuProp $ent 'DisplayVersion') } else { '' }
        '{0}|{1}' -f $rv, (Get-VuFileVersion $fileExe) }.GetNewClosure() }
}

function Get-DiscordInfo {
    $root = Join-Path $env:LOCALAPPDATA 'Discord'
    $upd = Join-Path $root 'Update.exe'
    if (-not (Test-Path -LiteralPath $upd -PathType Leaf)) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Join-Path $env:LOCALAPPDATA 'Discord') -Filter 'app-*' } }
}

# Table: Id, display name, winget id, vendor, priority, detect function, trigger kind and arguments.
$script:SelfUpdaters = @(
    @{ Id = 'chrome';  Name = 'Google Chrome';          WingetId = 'Google.Chrome';              Priority = 'Critical'; Detect = 'Get-ChromeInfo'; Kind = 'oneshot'
       Args = @('/ua', '/installsource', 'scheduler'); WaitMin = 3; Hint = 'vu.hint.chrome' }
    @{ Id = 'edge';    Name = 'Microsoft Edge';         WingetId = 'Microsoft.Edge';             Priority = 'Critical'; Detect = 'Get-EdgeInfo';   Kind = 'oneshot'
       Args = @('/ua', '/installsource', 'scheduler'); WaitMin = 3; Hint = 'vu.hint.edge' }
    @{ Id = 'adobe';   Name = 'Adobe Remote Update Manager'; WingetId = '';                      Priority = 'Normal';   Detect = 'Get-AdobeRumInfo'; Kind = 'rum'
       Args = @(); WaitMin = 0; Hint = '' }
    @{ Id = 'epic';    Name = 'Epic Games Launcher';    WingetId = 'EpicGames.EpicGamesLauncher'; Priority = 'Optional'; Detect = 'Get-EpicInfo';   Kind = 'start'
       Args = @('-silent'); WaitMin = 10; Process = 'EpicGamesLauncher'; Hint = 'vu.hint.epic' }
    @{ Id = 'discord'; Name = 'Discord';                WingetId = 'Discord.Discord';            Priority = 'Optional'; Detect = 'Get-DiscordInfo'; Kind = 'start'
       Args = @('--processStart', 'Discord.exe'); WaitMin = 5; Process = 'Discord'; Hint = 'vu.hint.discord' }
)

# Apps that update themselves when they start: the engine can skip winget for them and show the hint.
$script:SelfUpdateInfoOnly = @(
    @{ WingetId = 'Valve.Steam';                Vendor = 'Valve';           Hint = 'vu.hint.steam' }
    @{ WingetId = 'Blizzard.BattleNet';         Vendor = 'Blizzard';        Hint = 'vu.hint.battlenet' }
    @{ WingetId = 'ElectronicArts.EADesktop';   Vendor = 'Electronic Arts'; Hint = 'vu.hint.ea' }
    @{ WingetId = 'Ubisoft.Connect';            Vendor = 'Ubisoft';         Hint = 'vu.hint.ubisoft' }
)

function Get-SelfUpdatingAppMap {
    <# winget Id -> @{ Vendor; Hint } for apps that update themselves (the engine may skip winget for these). #>
    $map = @{}
    foreach ($s in $script:SelfUpdateInfoOnly) { $map[$s.WingetId] = @{ Vendor = $s.Vendor; Hint = $s.Hint } }
    foreach ($s in $script:SelfUpdaters) {
        if ($s.WingetId) { $map[$s.WingetId] = @{ Vendor = $s.Name; Hint = $s.Hint } }
    }
    return $map
}

function Get-SelfUpdaterCandidates {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in $script:SelfUpdaters) {
        $info = $null
        try { $info = & $s.Detect } catch { }
        if (-not $info) { continue }
        $from = ''
        try { $from = [string](& $info.GetVersion) } catch { }
        $from = Format-VuVersion $from
        $c = New-VuCandidate -Source 'selfupdater' -Name $s.Name -Id $s.Id -Key ("selfupdater|{0}" -f $s.Id) -From $from `
            -Priority $s.Priority -Vendor $s.Name -IsCheck $true -Message 'msg.checkInstall'
        $list.Add($c)
    }
    return $list.ToArray()
}

function Get-SelfUpdateHintResults {
    <# Turns winget upgrade rows (Id/Name/Version/Available) of self-updating apps into Info results. #>
    param([object[]]$WingetUpgrades = @())
    $map = Get-SelfUpdatingAppMap
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($w in @($WingetUpgrades)) {
        $id = [string](Get-VuProp $w 'Id')
        if (-not $id -or -not $map.ContainsKey($id)) { continue }
        $out.Add((New-VuCandidate -Source 'selfupdater' -Name ([string](Get-VuProp $w 'Name' $id)) -Id $id -Key ("selfupdater|{0}" -f $id) `
            -From ([string](Get-VuProp $w 'Version')) -To ([string](Get-VuProp $w 'Available')) -Status 'Info' -Message $map[$id].Hint `
            -Priority 'Optional' -Vendor $map[$id].Vendor))
    }
    return $out.ToArray()
}

function Invoke-SelfUpdater {
    param([Parameter(Mandatory)][string]$Id, [switch]$DryRun, $Base)
    $s = @($script:SelfUpdaters | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $s) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.unknown' }
    $info = & $s.Detect
    if (-not $info) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    $from = [string](& $info.GetVersion)
    $b = @{} + $Base; $b.From = Format-VuVersion $from
    if ($s.Kind -eq 'start' -and (Test-VuProcessRunning -Name $s.Process)) {
        # A running launcher updates itself; starting a second instance would be pointless.
        return New-UpdateResult @b -Status Skipped -Message 'msg.vu.runningSkip'
    }
    if ($DryRun) { return New-UpdateResult @b -Status Info -Message 'msg.vu.dryRun' }
    Write-Log -Message ("{0}: trigger {1} {2}" -f $s.Name, $info.Exe, ($s.Args -join ' '))
    switch ($s.Kind) {
        'oneshot' {
            $r = Invoke-VuProcess -FilePath $info.Exe -ArgumentList $s.Args -TimeoutMinutes 10
            if ($r.TimedOut) { return New-UpdateResult @b -Status Failed -Message 'msg.timeout' }
            $to = Wait-VuVersionChange -GetVersion $info.GetVersion -From $from -Minutes $s.WaitMin
            if ($to -and $to -ne $from) { $b.To = Format-VuVersion $to; return New-UpdateResult @b -Status Updated }
            return New-UpdateResult @b -Status Triggered -Message 'msg.vu.triggered'
        }
        'rum' {
            $r = Invoke-VuProcess -FilePath $info.Exe -ArgumentList $s.Args -TimeoutMinutes 30
            if ($r.TimedOut) { return New-UpdateResult @b -Status Failed -Message 'msg.timeout' }
            if ($r.ExitCode -eq 0) { return New-UpdateResult @b -Status Triggered -Message 'msg.vu.rumDone' }   # [ASSUMED] 0 = success
            return New-UpdateResult @b -Status Failed -Message "exit $($r.ExitCode)"
        }
        'start' {
            # Fire and forget (not Invoke-VuProcess): the program must keep running after we return.
            # Launchers (Epic, Discord in %LOCALAPPDATA%) are always started as the user, never elevated.
            try { $null = Start-VuProcess -FilePath $info.Exe -ArgumentList $s.Args -WindowStyle Minimized -Unelevated }
            catch { return New-UpdateResult @b -Status Skipped -Message 'msg.vu.noUser' }
            $to = Wait-VuVersionChange -GetVersion $info.GetVersion -From $from -Minutes $s.WaitMin
            if ($to -and $to -ne $from) { $b.To = Format-VuVersion $to; return New-UpdateResult @b -Status Updated -Message 'msg.vu.leftRunning' }
            return New-UpdateResult @b -Status Triggered -Message 'msg.vu.leftRunning'
        }
    }
    return New-UpdateResult @b -Status Skipped -Message 'msg.vu.unknown'
}

# ---------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------

function Get-VendorUpdateCandidates {
    <# Never throws. -WingetUpgrades (optional) are the rows the engine already has; self-updating apps in it become Info hints. #>
    param([switch]$SkipOem, [switch]$SkipSelfUpdaters, [object[]]$WingetUpgrades = @())
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $SkipOem) {
        try {
            $sys = Get-SystemVendor
            $found = switch ($sys.Vendor) {
                'dell'   { Get-DellCandidates }
                'lenovo' { Get-LenovoCandidates }
                'hp'     { Get-HpCandidates }
                'asus'   { Get-AsusCandidates }
                default  { @() }
            }
            foreach ($c in @($found)) { if ($c) { $out.Add($c) } }
        } catch { Write-Log -Level WARN -Message "OEM scan failed: $($_.Exception.Message)" }
    }
    if (-not $SkipSelfUpdaters) {
        try { foreach ($c in @(Get-SelfUpdaterCandidates)) { $out.Add($c) } }
        catch { Write-Log -Level WARN -Message "Self-updater scan failed: $($_.Exception.Message)" }
        try { foreach ($c in @(Get-SelfUpdateHintResults -WingetUpgrades $WingetUpgrades)) { $out.Add($c) } } catch { }
    }
    return $out.ToArray()
}

function Invoke-VendorUpdate {
    <# Runs one candidate. Never throws: errors become a Failed result. #>
    param([Parameter(Mandatory)]$Candidate, [switch]$DryRun)
    $key = [string](Get-VuProp $Candidate 'Key')
    $name = [string](Get-VuProp $Candidate 'Name' $key)
    if (-not $name) { $name = 'Vendor update' }
    $base = @{ Source = [string](Get-VuProp $Candidate 'Source' 'oem'); Name = $name; Id = [string](Get-VuProp $Candidate 'Id')
               From = [string](Get-VuProp $Candidate 'From'); To = [string](Get-VuProp $Candidate 'To'); Key = $key }
    try {
        $parts = $key -split '\|'
        if ($parts.Count -lt 2) { return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown' }
        if ($parts[0] -eq 'selfupdater') {
            $info = @($script:SelfUpdateInfoOnly | Where-Object { $_.WingetId -eq $parts[1] }) | Select-Object -First 1
            if ($info -or (Get-VuProp $Candidate 'Status') -eq 'Info') { return New-UpdateResult @base -Status Skipped -Message ([string](Get-VuProp $Candidate 'Message' 'msg.vu.unknown')) }
            return Invoke-SelfUpdater -Id $parts[1] -DryRun:$DryRun -Base $base
        }
        if ($parts[0] -ne 'oem') { return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown' }
        if ([bool](Get-VuProp $Candidate 'ManualOnly' $false)) {
            $isBios = Test-VuBiosCategory -Category ([string](Get-VuProp $Candidate 'Category')) -Name $name
            return New-UpdateResult @base -Status Skipped -Message $(if ($isBios) { 'msg.vu.biosManual' } else { 'msg.vu.asus.manual' })
        }
        switch ($parts[1]) {
            'dell'   { return Invoke-DellApply -DryRun:$DryRun -Base $base }
            'lenovo' { return Invoke-LenovoInstall -DryRun:$DryRun -Base $base }
            'hp'     { return Invoke-HpInstall -DryRun:$DryRun -Base $base }
            'asus'   {
                if ($parts.Count -lt 3 -or $parts[2] -eq 'driverhub') { return Invoke-AsusOpen -DryRun:$DryRun -Base $base }
                return Invoke-AsusDriverUpdate -Candidate $Candidate -DryRun:$DryRun -Base $base
            }
        }
        return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown'
    } catch {
        Write-Log -Level WARN -Message "Vendor update $key failed: $($_.Exception.Message)"
        return New-UpdateResult @base -Status Failed -Message $_.Exception.Message
    }
}

Export-ModuleMember -Function *
