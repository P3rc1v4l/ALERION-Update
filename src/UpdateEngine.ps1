<#
.SYNOPSIS
    Update Center engine. Collects update candidates from all sources (with priority), then
    installs either everything, a selection, or the priorities configured for scheduled runs.
.PARAMETER Scan
    Only collect candidates (+ installed programs for the GUI search) into state\last-scan.json.
.PARAMETER DryRun
    Like -Scan but also writes a report. Needs no admin rights.
.PARAMETER Selection
    Path to a JSON array of item keys ("source|id") inside the protected state folder.
    Only these items are installed.
.PARAMETER Scheduled
    Started by the scheduled task: game/battery guards, ScheduleAction and AutoInstallPriorities apply.
.PARAMETER Silent
    Forces silent mode for this run.
.PARAMETER FromGui
    Started from the GUI (no toast, the GUI shows the result).
#>
[CmdletBinding()]
param(
    [switch]$Scheduled,
    [switch]$DryRun,
    [switch]$Scan,
    [string]$Selection,
    [switch]$Silent,
    [switch]$FromGui,
    # Only update Update Center itself (Settings > Check for updates).
    [switch]$SelfUpdateOnly,
    # Periodic background check: scan only, notify about NEW updates (no window, no install).
    [switch]$BackgroundCheck,
    # Scheduled cleanup run (config CleanupIds), no updates.
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
# Only load modules from admin-protected locations (the user profile module folder could
# otherwise inject code into this elevated process through module auto-loading).
$env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$src = $PSScriptRoot
# Elevated + installed: compile (Add-Type) and unpack in an admin-only temp folder, never in the user's
# %TEMP% (a normal process of the same user could swap files there between compile and load).
$appRootDir = Split-Path $PSScriptRoot -Parent
if ($appRootDir -like "$env:ProgramFiles\*" -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $privTemp = Join-Path $appRootDir 'tmp'
    if (-not (Test-Path $privTemp)) { New-Item -ItemType Directory -Path $privTemp -Force | Out-Null }
    $env:TEMP = $privTemp; $env:TMP = $privTemp
}Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Providers.psm1') -DisableNameChecking -Force

if ($BackgroundCheck) { $Scan = [switch]$true; $Silent = [switch]$true }
$scanOnly = [bool]($Scan -or $DryRun -or $Cleanup)
if (-not (Test-IsAdmin) -and -not $scanOnly) {
    [Console]::Error.WriteLine('Update Center must run elevated (use the desktop shortcut or the scheduled task).')
    exit 5
}

# ------------------------------------------------------------------ single instance
# A lock FILE in the admin-only state folder instead of a global mutex: standard users cannot hold it,
# and Windows releases it automatically when a run is killed (no "abandoned" state).
$stateDir = (Get-AppPaths).StateDir
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$lockPath = Join-Path $stateDir 'run.lock'
$lockWait = (Get-Date).AddMinutes($(if ($Scheduled -or $Cleanup) { 30 } else { 0 }))
$runLock = $null
while (-not $runLock) {
    try { $runLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch {
        if ((Get-Date) -ge $lockWait) {
            try { Write-Log -Level WARN -Message 'Another Update Center run is active - this run was skipped' } catch { }
            exit 3
        }
        Start-Sleep -Seconds 15
    }
}

$results = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToString('o')
$config = $null
$mode = 'Visible'
$jobs = @{}
$exitCode = 0
$cancelled = $false
$installed = @()
$done = 0
$total = 0
$nothingToDo = $false

function Add-Result { param($Item) foreach ($i in @($Item)) { if ($i) { $script:results.Add($i) } } }

function Step {
    <# $Text goes to the log file (English); the GUI shows the localized $Key text (falls back to $Text). #>
    param([string]$Phase, [int]$Percent, [string]$Text, [string]$Key = '', [object[]]$KeyArgs = @())
    Write-Log -Message $Text
    $shown = if ($Key) { T $Key $KeyArgs } else { $Text }
    Update-Status -Phase $Phase -Percent $Percent -Current $shown -LogLine $shown
}

function Next-Percent {
    $script:done++
    return [int](20 + 70 * $script:done / [Math]::Max(1, $script:total))
}

function Test-Excluded {
    param([string]$Id, $Config)
    foreach ($pattern in @($Config.ExcludedPackages)) { if ($Id -and $Id -like $pattern) { return $true } }
    return $false
}

function Start-ProviderJob {
    <# Runs a provider call in a separate (elevated) PowerShell process. #>
    param([string]$Name, [scriptblock]$Script, [object[]]$Arguments = @())
    $wrapper = {
        param($srcDir, $inner, $innerArgs)
        $ProgressPreference = 'SilentlyContinue'
        $env:PSModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules;$PSHOME\Modules"
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        Import-Module (Join-Path $srcDir 'Providers.psm1') -DisableNameChecking
        & ([scriptblock]::Create($inner)) @innerArgs
    }
    $script:jobs[$Name] = Start-Job -Name "uc-$Name" -ScriptBlock $wrapper -ArgumentList $src, $Script.ToString(), $Arguments
    Write-Log -Message "Background job started: $Name"
}

function Receive-ProviderJob {
    param([string]$Name, [int]$TimeoutMinutes = 120)
    if (-not $script:jobs.ContainsKey($Name)) { return $null }
    $job = $script:jobs[$Name]
    [void](Wait-Job $job -Timeout ($TimeoutMinutes * 60))
    $script:jobs.Remove($Name)
    if ($job.State -eq 'Running') { Stop-Job $job; Remove-Job $job -Force; throw "Job '$Name' timed out" }
    try { return Receive-Job $job -ErrorAction Stop } finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

function Add-Candidate {
    param($Item)
    foreach ($i in @($Item)) {
        if (-not $i) { continue }
        if ($i.Status -eq 'Available' -and (Test-Excluded -Id $i.Id -Config $script:config)) {
            $i.Status = 'Skipped'; $i.Message = 'msg.excluded'; $i.Excluded = $true
        }
        $script:candidates.Add($i)
    }
}

function Complete-Item {
    <# Copies key/priority from the candidate onto the install result and updates the GUI row. #>
    param($Result, $Candidate)
    foreach ($r in @($Result)) {
        if (-not $r) { continue }
        if ($Candidate) { [void](Set-UpdateMeta -Item $r -Template $Candidate) }
        Add-Result $r
        $state = switch ($r.Status) { 'Updated' { 'Done' } 'Triggered' { 'Done' } 'Info' { 'Done' } 'Failed' { 'Failed' } default { 'Skipped' } }
        Set-ItemState -Key $r.Key -State $state
    }
}

function Test-Stop {
    if (Test-CancelRequested) { $script:cancelled = $true }
    return $script:cancelled
}

function Test-ManualOnly {
    <# Never unattended: BIOS/firmware (ManualOnly), the DriverHub hint, and vendor setups that open a
       window (InstallMode 'installer'). Signed INF drivers (pnputil) may run automatically. #>
    param($Item)
    if ([string]$Item.Key -eq 'oem|asus|driverhub') { return $true }
    $names = $Item.PSObject.Properties.Name
    if ($names -contains 'InstallMode' -and [string]$Item.InstallMode -eq 'installer') { return $true }
    return ($names -contains 'ManualOnly') -and [bool]$Item.ManualOnly
}

function Select-BySource { param([string]$Source) return @($script:selected | Where-Object { $_.Source -eq $Source }) }

try {
    Initialize-DataDir -Harden
    $logFile = Start-LogFile
    $config = Get-Config
    Import-I18n -Language $config.Language
    Set-PriorityOverrides -Map $config.PriorityOverrides
    $studio = ($config.NvidiaDriverType -eq 'Studio')
    $mode = if ($Silent) { 'Silent' } else { $config.Mode }
    if ($Scheduled -and $config.ScheduleAction -eq 'Notify') { $scanOnly = $true }
    # -------------------------------------------------------------- scheduled cleanup (no updates)
    if ($Cleanup) {
        Import-Module (Join-Path $src 'Cleanup.psm1') -DisableNameChecking -Force
        Write-Log -Message ("Scheduled cleanup: {0}" -f (@($config.CleanupIds) -join ', '))
        $freed = 0L
        foreach ($r in @(Invoke-Cleanup -Ids @($config.CleanupIds))) {
            $freed += [long]$r.Freed
            Write-Log -Message ("cleanup {0}: {1} ({2} bytes) {3}" -f $r.Id, $r.Status, $r.Freed, $r.Message)
        }
        Write-Log -Level OK -Message ("Scheduled cleanup finished, {0:N0} MB freed" -f ($freed / 1MB))
        if ($freed -ge 50MB) { Show-Toast -Title (T 'toast.cleanupDone' @(('{0:N1} GB' -f ($freed / 1GB)))) -Body (T 'toast.cleanupBody') }
        throw [System.OperationCanceledException]::new('cleanup only')
    }

    Clear-Cancel
    Reset-Status -Mode $(if ($scanOnly) { 'scan' } else { 'install' })
    $version = Get-AppVersion
    Step 'start' 1 "Update Center v$version started (scheduled=$Scheduled, scan=$scanOnly, selection=$([bool]$Selection), mode=$mode, parallel=$($config.Parallel))" -Key 'eng.start'

    # -------------------------------------------------------------- scheduled-run guards
    if ($Scheduled) {
        $waited = 0
        while ((Test-UserBusy) -and $waited -lt [int]$config.WaitWhileBusyMinutes) {
            if ($waited -eq 0) { Step 'wait' 1 'Fullscreen app or game detected - waiting until it is closed' -Key 'eng.waitGame' }
            Start-Sleep -Seconds 300; $waited += 5
        }
        if (Test-UserBusy) { Step 'wait' 1 'Still busy after the wait limit - postponing to the next run' -Key 'eng.postponeGame'; $exitCode = 4; throw [System.OperationCanceledException]::new('busy') }
        $bat = Get-BatteryState
        if ($bat -and -not $bat.OnAC -and $bat.Percent -lt [int]$config.MinBatteryPercent) {
            Step 'wait' 1 "Battery at $($bat.Percent)% and not charging - postponing" -Key 'eng.battery' -KeyArgs @($bat.Percent); $exitCode = 4
            throw [System.OperationCanceledException]::new('battery')
        }
        if ($mode -eq 'Visible' -and -not $scanOnly) {
            $gui = Join-Path $src 'Gui.ps1'
            Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" -ArgumentList "--headless `"$PSHOME\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -File `"$gui`" -Monitor"
        }
    }

    # -------------------------------------------------------------- pre-checks
    Step 'precheck' 2 'Checking internet connection' -Key 'eng.internet'
    if (-not (Test-Internet)) { Add-Result (New-UpdateResult -Source 'system' -Name 'msg.internet' -Status Failed -Message 'msg.noInternet'); $exitCode = 2; throw [System.OperationCanceledException]::new('offline') }
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if (-not $scanOnly -and $sysDrive -and ($sysDrive.Free / 1GB) -lt [int]$config.MinFreeSpaceGB) {
        Add-Result (New-UpdateResult -Source 'system' -Name 'msg.diskSpace' -Status Info -Message ('{0:N1} GB' -f ($sysDrive.Free / 1GB)))
    }

    if ($SelfUpdateOnly) {
        Step 'self' 50 'Updating Update Center' -Key 'eng.self'
        try { Add-Result (Set-UpdateMeta -Item (Invoke-SelfUpdate -Repo $config.SelfUpdate.Repo)) }
        catch { Add-Result (New-UpdateResult -Source 'self' -Name 'Update Center' -Status Failed -Message $_.Exception.Message) }
        throw [System.OperationCanceledException]::new('self-update only')
    }

    # ============================================================== phase 1: collect candidates
    $s = $config.Sources
    $wuArgs = @([bool]$s.WindowsUpdateDrivers, [bool]$s.MicrosoftUpdate, [bool]$s.Nvidia, [bool]$s.Defender)
    if ($s.WindowsUpdate -and $config.Parallel) {
        Start-ProviderJob -Name 'wu-scan' -Script { param($d, $m, $n, $x) Get-WindowsUpdateCandidates -IncludeDrivers $d -UseMicrosoftUpdate $m -SkipNvidiaDisplay $n -SkipDefinitions $x } -Arguments $wuArgs
    }
    if ($s.Winget) {
        Step 'scan' 4 'Searching winget for updates' -Key 'eng.winget'
        if (-not (Get-WingetPath)) {
            Add-Result (New-UpdateResult -Source 'winget' -Name 'winget' -Status Failed -Message 'msg.wingetMissing')
        } else {
            $memory = Get-WingetMemory
            foreach ($p in @(Get-WingetUpgrades -IncludeUnknown ([bool]$s.WingetIncludeUnknown))) {
                $c = New-UpdateResult -Source 'winget' -Name $p.Name -Id $p.Id -From $p.Version -To $p.Available -Status Available
                $c | Add-Member -NotePropertyName WingetSource -NotePropertyValue $p.Source
                if ($p.Truncated) { $c.Status = 'Skipped'; $c.Message = 'msg.truncatedId' }
                $c = Set-UpdateMeta -Item $c
                # Failed the same way for this exact version before: keep it visible but not recommended.
                if ($memory.ContainsKey($p.Id) -and [string]$memory[$p.Id].Available -eq [string]$p.Available) {
                    $c.Priority = 'Optional'; $c.Message = 'msg.mem.' + $memory[$p.Id].Kind
                }
                Add-Candidate $c
            }
            if ($Scan) { Step 'scan' 6 'Reading installed programs' -Key 'eng.installed'; $installed = @(Get-InstalledPrograms) }
        }
    }
    if ($s.Chocolatey -and (Get-ChocoPath)) {
        Step 'scan' 8 'Searching Chocolatey for updates' -Key 'eng.choco'
        foreach ($p in @(Get-ChocoOutdated)) {
            Add-Candidate (Set-UpdateMeta -Item (New-UpdateResult -Source 'choco' -Name $p.Name -Id $p.Name -From $p.Version -To $p.Available -Status Available))
        }
    }
    if ($s.Nvidia) {
        Step 'scan' 10 'Checking NVIDIA graphics driver' -Key 'eng.nvidia'
        try { Add-Candidate (ConvertTo-GpuCandidate (Get-NvidiaUpdateInfo -Studio:$studio)) }
        catch { Add-Result (New-UpdateResult -Source 'gpu' -Name 'NVIDIA' -Status Failed -Message $_.Exception.Message) }
    }
    if ($s.Defender) { Add-Candidate (Get-DefenderCandidate) }
    if ($s.Store) { Add-Candidate (Get-StoreCandidate) }
    if ($s.Office) { Add-Candidate (Get-OfficeCandidate) }
    # OEM driver tools (Dell/Lenovo/HP CLIs, ASUS DriverHub) and apps with their own updater (Epic, Discord, Adobe ...)
    if ($s.Oem -or $s.SelfUpdaters) {
        Step 'scan' 12 'Checking manufacturer tools and self-updating apps' -Key 'eng.vendor'
        try {
            Import-Module (Join-Path $src 'VendorUpdates.psm1') -DisableNameChecking -Force
            $wingetIds = @($candidates | Where-Object { $_.Source -eq 'winget' } | ForEach-Object { $_.Id })
            $selfMap = Get-SelfUpdatingAppMap
            foreach ($v in @(Get-VendorUpdateCandidates -SkipOem:(-not $s.Oem) -SkipSelfUpdaters:(-not $s.SelfUpdaters))) {
                if (-not $v) { continue }
                # Chrome/Edge: winget already covers them when it has an update - no duplicate row.
                if ($v.Key -eq 'selfupdater|chrome' -and $wingetIds -contains 'Google.Chrome') { continue }
                if ($v.Key -eq 'selfupdater|edge' -and $wingetIds -contains 'Microsoft.Edge') { continue }
                Add-Candidate $v
            }
            # Launchers that update themselves (Epic, Steam, Battle.net, EA, Ubisoft, Discord): winget usually
            # fails on them, so they are not recommended; the note explains that they update on start.
            foreach ($c in @($candidates | Where-Object { $_.Source -eq 'winget' -and $selfMap.ContainsKey([string]$_.Id) })) {
                if ($c.Id -in 'Google.Chrome', 'Microsoft.Edge') { continue }
                $c.Priority = 'Optional'; $c.Message = [string]$selfMap[[string]$c.Id].Hint
            }
        } catch { Write-Log -Level WARN -Message "Vendor/self-updater check failed: $($_.Exception.Message)" }
    }
    if ($config.SelfUpdate.Enabled -and $config.SelfUpdate.Repo) {
        try { Add-Candidate (Set-UpdateMeta -Item (Invoke-SelfUpdate -Repo $config.SelfUpdate.Repo -DryRun)) }
        catch { Write-Log -Level WARN -Message "Self-update check failed: $($_.Exception.Message)" }
    }
    if ($s.WindowsUpdate) {
        Step 'scan' 14 'Searching Windows Update (this can take a minute)' -Key 'eng.wu'
        try {
            $wu = if ($config.Parallel) { Receive-ProviderJob -Name 'wu-scan' -TimeoutMinutes 30 }
                  else { Get-WindowsUpdateCandidates -IncludeDrivers $wuArgs[0] -UseMicrosoftUpdate $wuArgs[1] -SkipNvidiaDisplay $wuArgs[2] -SkipDefinitions $wuArgs[3] }
            Add-Candidate @($wu)
        } catch { Add-Result (New-UpdateResult -Source 'windows' -Name 'Windows Update' -Status Failed -Message $_.Exception.Message) }
    }

    $available = @($candidates | Where-Object { $_.Status -eq 'Available' })
    $nAvail = @($available | Where-Object { -not $_.IsCheck }).Count
    Step 'scan' 18 ("{0} update(s) available" -f $nAvail) -Key 'eng.found' -KeyArgs @($nAvail)
    $scanItems = @($candidates.ToArray()) + @($results | Where-Object { $_.Status -eq 'Failed' })
    Write-AtomicFile -Path (Join-Path (Get-AppPaths).StateDir 'last-scan.json') -Content (([pscustomobject]@{
        ScannedAt = (Get-Date).ToString('o'); Items = $scanItems; Installed = $installed
    }) | ConvertTo-Json -Depth 5)

    # ============================================================== phase 2: what to install
    $selected = @()
    if ($scanOnly) {
        $selected = @()
    } elseif ($Selection) {
        $selPath = [IO.Path]::GetFullPath($Selection)
        # Only accept selection files from the admin-protected state folder.
        if (-not $selPath.StartsWith((Get-AppPaths).StateDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $selPath)) { throw 'Selection file rejected' }
        # PS 5.1 emits a JSON array from ConvertFrom-Json as ONE object - enumerate it explicitly.
        $parsed = Get-Content $selPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $keys = @($parsed | ForEach-Object { [string]$_ })
        Write-Log -Message "Selection: $($keys.Count) item(s)"
        Remove-Item $selPath -Force -ErrorAction SilentlyContinue
        $selected = @($available | Where-Object { $keys -contains $_.Key })
    } elseif ($Scheduled) {
        $prio = @($config.AutoInstallPriorities)
        $selected = @($available | Where-Object { $prio -contains $_.Priority -and -not (Test-ManualOnly $_) })
    } else {
        # "Install recommended": everything except optional (beta / unknown version) packages.
        $selected = @($available | Where-Object { $_.Priority -ne 'Optional' -and -not (Test-ManualOnly $_) })
    }
    foreach ($c in $selected) { Set-ItemState -Key $c.Key -State 'Pending' }

    if ($scanOnly) {
        if ($DryRun) { Add-Result $candidates.ToArray() }
        if ($BackgroundCheck) {
            # Only tell the user about updates they have not been told about yet.
            $notifiedFile = Join-Path (Get-AppPaths).StateDir 'notified.json'
            $known = @(); if (Test-Path $notifiedFile) { try { $known = @((Get-Content $notifiedFile -Raw | ConvertFrom-Json) | ForEach-Object { [string]$_ }) } catch { } }
            $current = @($available | Where-Object { -not $_.IsCheck -and $_.Priority -ne 'Optional' } | ForEach-Object { $_.Key + '=' + $_.To })
            $new = @($current | Where-Object { $known -notcontains $_ })
            if ($new.Count) { Show-Toast -Title (T 'toast.available' @($current.Count)) -Body (T 'toast.availableBody') }
            Write-AtomicFile -Path $notifiedFile -Content (ConvertTo-Json @($current) -Compress)
            Write-Log -Message ("Background check: {0} update(s), {1} new" -f $current.Count, $new.Count)
        }
        if ($Scheduled -and $config.ScheduleAction -eq 'Notify') {
            $n = @($available | Where-Object { -not $_.IsCheck }).Count
            if ($n -gt 0) { Show-Toast -Title (T 'toast.available' @($n)) -Body (T 'toast.availableBody') }
        }
    } elseif ($selected.Count -eq 0) {
        $nothingToDo = $true
        Step 'install' 95 'Nothing selected to install' -Key 'eng.nothing'
    } else {
        # ========================================================== phase 3: install
        $total = $selected.Count
        if ($config.RestorePoint) { Step 'restore' 20 'Creating system restore point' -Key 'eng.restore'; Add-Result (New-RestorePoint) }

        # @() matters: PS 5.1 gives a single [pscustomobject] no .Count, so one selected item would be skipped.
        $wuSel = @(Select-BySource 'windows')
        $gpuSel = @(Select-BySource 'gpu')
        $wuIds = @($wuSel | ForEach-Object { $_.Key.Substring('windows|'.Length) })
        if ($config.Parallel -and $wuSel.Count) {
            Start-ProviderJob -Name 'wu-dl' -Script { param($d, $m, $n, $x, $ids) Save-WindowsUpdates -IncludeDrivers $d -UseMicrosoftUpdate $m -SkipNvidiaDisplay $n -SkipDefinitions $x -OnlyIds $ids } -Arguments ($wuArgs + , $wuIds)
        }
        $gpuInfo = $null
        if ($gpuSel.Count) {
            try { $gpuInfo = Get-NvidiaUpdateInfo -Studio:$studio } catch { Write-Log -Level WARN -Message "NVIDIA lookup failed: $($_.Exception.Message)" }
            if ($config.Parallel -and $gpuInfo -and $gpuInfo.NeedsUpdate) {
                Start-ProviderJob -Name 'gpu-dl' -Script { param($i) Save-NvidiaDriver -Info $i } -Arguments @(, $gpuInfo)
            }
        }

        # winget + choco, the update tools themselves first
        $pkgs = @(Select-BySource 'winget' | Sort-Object { if ($_.Id -eq 'Microsoft.AppInstaller') { 0 } else { 1 } }, Name) +
                @(Select-BySource 'choco' | Sort-Object { if ($_.Id -eq 'chocolatey') { 0 } else { 1 } }, Name)
        foreach ($c in $pkgs) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'
            Step $c.Source (Next-Percent) ("{0}  {1} -> {2}" -f $c.Name, $c.From, $c.To) -Key 'eng.package' -KeyArgs @($c.Name, $c.From, $c.To)
            if ($c.Source -eq 'winget') {
                $pkg = [pscustomobject]@{ Name = $c.Name; Id = $c.Id; Version = $c.From; Available = $c.To; Source = $c.WingetSource }
                Complete-Item (Invoke-WingetPackageUpgrade -Package $pkg -CloseRunning:($config.RunningApps -eq 'Close')) $c
            } else {
                Complete-Item (Invoke-ChocoUpgrade -Package ([pscustomobject]@{ Name = $c.Id; Version = $c.From; Available = $c.To })) $c
            }
        }

        $storeBefore = $null
        foreach ($c in (Select-BySource 'defender')) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'; Step 'defender' (Next-Percent) 'Updating Microsoft Defender signatures' -Key 'eng.defender'
            Complete-Item (Update-DefenderSignatures) $c
        }
        foreach ($c in (Select-BySource 'store')) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'; Step 'store' (Next-Percent) 'Triggering Microsoft Store updates' -Key 'eng.store'
            $storeBefore = Get-StoreSnapshot
            $ok = Start-StoreUpdateScan
            Complete-Item (New-UpdateResult -Source 'store' -Name 'msg.storeApps' -Status $(if ($ok) { 'Triggered' } else { 'Failed' }) -Message $(if ($ok) { 'msg.storeBackground' } else { 'msg.storeScanFailed' })) $c
        }
        foreach ($c in (Select-BySource 'office')) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'; Step 'office' (Next-Percent) 'Starting Office update' -Key 'eng.office'
            Complete-Item (Start-OfficeUpdate) $c
        }

        foreach ($c in @(Select-BySource 'oem') + @(Select-BySource 'selfupdater')) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'; Step $c.Source (Next-Percent) ("Updating {0}" -f $c.Name) -Key 'eng.vendorItem' -KeyArgs @($c.Name)
            if (-not (Get-Module VendorUpdates)) { Import-Module (Join-Path $src 'VendorUpdates.psm1') -DisableNameChecking -Force }
            Complete-Item (Invoke-VendorUpdate -Candidate $c) $c
        }

        if ($wuSel.Count -and -not (Test-Stop)) {
            foreach ($c in $wuSel) { Set-ItemState -Key $c.Key -State 'Running' }
            Step 'windows' (Next-Percent) "Installing $($wuSel.Count) Windows update(s) (this can take a while)" -Key 'eng.wuInstall' -KeyArgs @($wuSel.Count)
            try {
                if ($config.Parallel) { [void](Receive-ProviderJob -Name 'wu-dl' -TimeoutMinutes 180) }
                Complete-Item @(Install-WindowsUpdates -IncludeDrivers $wuArgs[0] -UseMicrosoftUpdate $wuArgs[1] -SkipNvidiaDisplay $wuArgs[2] -SkipDefinitions $wuArgs[3] -OnlyIds $wuIds) $null
                $done += [Math]::Max(0, $wuSel.Count - 1)
            } catch {
                $err = $_.Exception.Message
                foreach ($c in $wuSel) { Complete-Item (New-UpdateResult -Source 'windows' -Name $c.Name -Id $c.Id -Key $c.Key -Priority $c.Priority -Status Failed -Message $err) $null }
            }
        }

        foreach ($c in $gpuSel) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'
            try {
                if (-not $gpuInfo -or -not $gpuInfo.NeedsUpdate) { Complete-Item (New-UpdateResult -Source 'gpu' -Name $c.Name -Status Info -Message 'msg.upToDate') $c; continue }
                if (Test-UserBusy) { Complete-Item (New-UpdateResult -Source 'gpu' -Name $c.Name -To $c.To -Status Skipped -Message 'msg.busyPostponed') $c; continue }
                Step 'gpu' (Next-Percent) "Installing NVIDIA driver $($gpuInfo.Latest) ($($gpuInfo.Size))" -Key 'eng.gpu' -KeyArgs @($gpuInfo.Latest, $gpuInfo.Size)
                $file = if ($config.Parallel) { Receive-ProviderJob -Name 'gpu-dl' -TimeoutMinutes 120 } else { $null }
                if (-not $file) { $file = Save-NvidiaDriver -Info $gpuInfo }
                if ($config.BackupDrivers) { Step 'gpu' 85 'Backing up the current graphics driver' -Key 'eng.gpuBackup'; Add-Result (Backup-DisplayDriver) }
                Complete-Item (Install-NvidiaDriver -Info $gpuInfo -File ([string]@($file)[-1])) $c
            } catch {
                Complete-Item (New-UpdateResult -Source 'gpu' -Name $c.Name -Status Failed -Message $_.Exception.Message) $c
            }
        }

        foreach ($c in (Select-BySource 'self')) {
            if (Test-Stop) { break }
            Set-ItemState -Key $c.Key -State 'Running'; Step 'self' (Next-Percent) 'Updating Update Center' -Key 'eng.self'
            try { Complete-Item (Invoke-SelfUpdate -Repo $config.SelfUpdate.Repo) $c }
            catch { Complete-Item (New-UpdateResult -Source 'self' -Name 'Update Center' -Status Failed -Message $_.Exception.Message) $c }
        }

        if ($cancelled) {
            Step 'cancel' 95 'Cancelled by user - remaining items skipped' -Key 'eng.cancelled'
            $doneKeys = @($results | ForEach-Object { $_.Key })
            foreach ($c in $selected) {
                if ($doneKeys -notcontains $c.Key) {
                    $c.Status = 'Skipped'; $c.Message = 'msg.cancelled'; Add-Result $c; Set-ItemState -Key $c.Key -State 'Skipped'
                }
            }
        }

        # verification: still listed by winget with the same version -> failed
        $wingetDone = @($results | Where-Object { $_.Source -eq 'winget' -and $_.Status -eq 'Updated' })
        if ($wingetDone.Count) {
            Step 'verify' 93 'Verifying winget updates' -Key 'eng.verify'
            try {
                $still = @(Get-WingetUpgrades -IncludeUnknown ([bool]$s.WingetIncludeUnknown))
                foreach ($r in $wingetDone) {
                    $hit = $still | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
                    if (-not $hit) { continue }
                    if ($r.From -match 'Unknown|Unbekannt|<|>') { $r.Message = 'msg.unknownVersion'; continue }
                    if ($hit.Version -eq $r.From) { $r.Status = 'Failed'; $r.Message = 'msg.stillOutdated'; Set-ItemState -Key $r.Key -State 'Failed' }
                    else { $r.To = $hit.Version }
                }
            } catch { Write-Log -Level WARN -Message "Verification scan failed: $($_.Exception.Message)" }
        }
        try { Update-WingetMemory -Results $results.ToArray() } catch { Write-Log -Level WARN -Message "winget memory: $($_.Exception.Message)" }
        if ($storeBefore) {
            Start-Sleep -Seconds 20
            foreach ($r in @(Compare-StoreSnapshot -Before $storeBefore)) { $r.Priority = 'Important'; Add-Result $r }
        }
    }
}
catch [System.OperationCanceledException] {
    Write-Log -Level WARN -Message "Run cancelled: $($_.Exception.Message)"
}
catch {
    $exitCode = 1
    Write-Log -Level ERROR -Message ("Unexpected error: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    Add-Result (New-UpdateResult -Source 'system' -Name 'Update Center' -Status Failed -Message $_.Exception.Message)
}
finally {
    foreach ($j in @($jobs.Values)) { try { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue } catch { } }

    # -------------------------------------------------------------- report (plain GUI scans write none)
    $reportPath = $null
    $writeReport = (((-not $Scan) -and -not $nothingToDo) -or ($exitCode -ne 0)) -and -not $Cleanup
    if ($writeReport) {
        try {
            $items = $results.ToArray()   # @(List) inside a hashtable literal throws in PS 5.1
            $rebootNeeded = (@($items | Where-Object { $_.RebootRequired -and $_.Status -eq 'Updated' }).Count -gt 0) -or ((-not $scanOnly) -and (Test-PendingReboot))

            # ---------------------------------------------------------- restart plan
            $restartPlan = $null
            if (-not $scanOnly -and $rebootNeeded -and $config) {
                Import-Module (Join-Path $src 'Scheduler.psm1') -DisableNameChecking -Force
                $servicing = (@($items | Where-Object { $_.Source -eq 'windows' -and $_.Status -eq 'Updated' }).Count -gt 0) -or
                             (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
                $est = Get-RestartEstimate -WithUpdates $servicing
                $at = $null
                switch ($config.Reboot) {
                    'Auto' {
                        $at = (Get-Date).AddMinutes(2)
                        Invoke-RestartNow -Seconds 120 -Message (T 'toast.autoReboot')
                        Write-Log -Message 'Automatic restart in 2 minutes (cancel with: shutdown /a)'
                    }
                    'Scheduled' {
                        $at = Get-NextTimeOfDay -Time $config.RebootTime
                        Register-RestartTask -At $at -Message (T 'toast.plannedRebootNow')
                        Write-Log -Message "Restart planned for $($at.ToString('g'))"
                    }
                }
                $restartPlan = [pscustomobject]@{
                    Mode = $config.Reboot; At = $(if ($at) { $at.ToString('o') } else { $null })
                    MinMinutes = $est.MinMinutes; MaxMinutes = $est.MaxMinutes; WithUpdates = $est.WithUpdates
                }
            }

            $report = [pscustomobject]@{
                RestartPlan    = $restartPlan
                AppVersion     = Get-AppVersion
                Computer       = $env:COMPUTERNAME
                StartedAt      = $startedAt
                EndedAt        = (Get-Date).ToString('o')
                DryRun         = [bool]$scanOnly
                Cancelled      = [bool]$cancelled
                RebootRequired = [bool]$rebootNeeded
                ExitCode       = $exitCode
                LogFile        = (Get-LogFile)
                Counts         = [pscustomobject]@{
                    Updated   = @($items | Where-Object Status -eq 'Updated').Count
                    Failed    = @($items | Where-Object Status -eq 'Failed').Count
                    Skipped   = @($items | Where-Object Status -eq 'Skipped').Count
                    Available = @($items | Where-Object Status -eq 'Available').Count
                }
                Items          = $items
            }
            Import-Module (Join-Path $src 'Report.psm1') -DisableNameChecking -Force
            $reportPath = Save-Report -Report $report
            Write-Log -Level OK -Message ("Finished: {0} updated, {1} failed, {2} skipped, reboot={3}" -f $report.Counts.Updated, $report.Counts.Failed, $report.Counts.Skipped, $rebootNeeded)

            # The GUI shows its own summary; silent runs get a toast that opens the HTML report.
            if ($mode -eq 'Silent' -and -not $FromGui -and -not $scanOnly) {
                $title = if ($rebootNeeded) { T 'toast.titleReboot' } else { T 'toast.title' }
                $body = T 'toast.body' @($report.Counts.Updated, $report.Counts.Failed)
                if ($restartPlan -and $restartPlan.At) {
                    $body += ' ' + (T 'toast.restartAt' @(([datetime]$restartPlan.At).ToString('HH:mm'), (Format-RestartEstimate -Estimate $restartPlan)))
                }
                Show-Toast -Title $title -Body $body -LaunchUri ([uri]$reportPath.Html).AbsoluteUri
            }
        } catch {
            Write-Log -Level ERROR -Message ("Report failed: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        }
    } elseif (-not $Cleanup) {
        Write-Log -Level OK -Message 'Scan finished'
    }
    if (-not $Cleanup) { Clear-Cancel }
    # Still inside the old 'ALERION Update' folder (in-place update from v1.x): finish the move.
    if ((Test-IsAdmin) -and (Test-LegacyInstall) -and -not $scanOnly) {
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = "Start-Sleep -Seconds 15; & '$(Join-Path (Get-AppPaths).AppRoot 'Install.ps1')' -NoLaunch -Quiet"
        Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    }
    if (-not $Cleanup) { Complete-Status -ReportPath $(if ($reportPath) { $reportPath.Json } else { $null }) }
    Remove-OldFiles -Days $(if ($config) { [int]$config.LogRetentionDays } else { 60 })
    $runLock.Dispose()
}
exit $exitCode
