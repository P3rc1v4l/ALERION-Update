# Update Center - security check and scans using Windows' own tools
# (Microsoft Defender, Malicious Software Removal Tool, sfc, DISM).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Providers.psm1') -DisableNameChecking

# ---------------------------------------------------------------- small helpers
function Get-SafeProp {
    # StrictMode-safe property read (CIM / cmdlet objects differ between Windows builds).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function New-Check {
    param([string]$Id, [string]$State, [string]$Detail, [string]$FixUri = '')
    [pscustomobject]@{ Id = $Id; State = $State; Detail = $Detail; FixUri = $FixUri }
}

function Invoke-Check {
    # Runs one check; any exception becomes State 'Unknown' (missing cmdlet on Home, no admin, ...).
    param([string]$Id, [scriptblock]$Body, [string]$FixUri = '')
    try {
        $r = & $Body
        if ($null -eq $r) { return (New-Check $Id 'Unknown' (T 'sec.detail.noData') $FixUri) }
        return $r
    } catch {
        $msg = ($_.Exception.Message -split "`r?`n")[0]
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
        return (New-Check $Id 'Unknown' (T 'sec.detail.notAvailable' @($msg)) $FixUri)
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $Default }
}

function Get-MrtPath {
    <# Path of the Malicious Software Removal Tool (delivered monthly via Windows Update), or $null. #>
    $p = Join-Path ([Environment]::GetFolderPath('System')) 'MRT.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-MrtLogPath { Join-Path $env:SystemRoot 'debug\mrt.log' }

function Get-ThirdPartyAntivirus {
    <# Active non-Microsoft antivirus products from the Security Center (root\SecurityCenter2).
       productState bit 0x1000 = product enabled (on). Returns an array of product names. #>
    $names = @()
    try {
        foreach ($av in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $name = [string](Get-SafeProp $av 'displayName' '')
            $state = [int64](Get-SafeProp $av 'productState' 0)
            if ($name -and $name -notmatch '(?i)windows defender|microsoft defender' -and (($state -band 0x1000) -ne 0)) { $names += $name }
        }
    } catch { }
    return @($names)
}

function Get-DefenderStatus {
    try { return (Get-MpComputerStatus -ErrorAction Stop) } catch { return $null }
}

function Test-DefenderPassive {
    <# True when another antivirus is active, so Defender runs passive (no own scans useful). #>
    $third = @(Get-ThirdPartyAntivirus)
    if ($third.Count -gt 0) { return $true }
    $mp = Get-DefenderStatus
    $mode = [string](Get-SafeProp $mp 'AMRunningMode' '')
    return ($mode -match '(?i)passive')
}

function Format-Age {
    param($Days)
    if ($null -eq $Days) { return (T 'sec.detail.ageUnknown') }
    $d = [int64]$Days
    if ($d -ge 4294967295 -or $d -lt 0) { return (T 'sec.detail.ageNever') }
    if ($d -eq 0) { return (T 'sec.detail.ageToday') }
    if ($d -eq 1) { return (T 'sec.detail.ageOne') }
    return (T 'sec.detail.ageDays' @($d))
}

# ---------------------------------------------------------------- status checks
function Get-SecurityStatus {
    <# Read-only snapshot of the security posture. Finishes in a few seconds; never throws. #>
    $mp = Get-DefenderStatus
    $pref = $null
    try { $pref = Get-MpPreference -ErrorAction Stop } catch { }
    $third = @(Get-ThirdPartyAntivirus)
    $passive = (@($third).Count -gt 0) -or ([string](Get-SafeProp $mp 'AMRunningMode' '') -match '(?i)passive')
    $results = New-Object System.Collections.Generic.List[object]

    $results.Add((Invoke-Check 'antivirus' {
        $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
        $active = @()
        foreach ($av in $products) {
            $state = [int64](Get-SafeProp $av 'productState' 0)
            if (($state -band 0x1000) -ne 0) { $active += [string](Get-SafeProp $av 'displayName' '?') }
        }
        if ($active.Count -gt 0) { return (New-Check 'antivirus' 'Ok' (T 'sec.detail.avActive' @(($active -join ', '))) '') }
        if ($products.Count -gt 0) { return (New-Check 'antivirus' 'Critical' (T 'sec.detail.avOff') 'windowsdefender://threat') }
        return (New-Check 'antivirus' 'Critical' (T 'sec.detail.avNone') 'windowsdefender://threat')
    } 'windowsdefender://threat'))

    $results.Add((Invoke-Check 'realtime' {
        if ($passive -and $third.Count -gt 0) { return (New-Check 'realtime' 'Ok' (T 'sec.detail.rtThird' @(($third -join ', '))) '') }
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        if ([bool](Get-SafeProp $mp 'RealTimeProtectionEnabled' $false)) { return (New-Check 'realtime' 'Ok' (T 'sec.detail.rtOn') '') }
        return (New-Check 'realtime' 'Critical' (T 'sec.detail.rtOff') 'windowsdefender://threatsettings')
    } 'windowsdefender://threatsettings'))

    $results.Add((Invoke-Check 'signatures' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        $age = [int64](Get-SafeProp $mp 'AntivirusSignatureAge' 4294967295)
        $ver = [string](Get-SafeProp $mp 'AntivirusSignatureVersion' '')
        if ($age -ge 4294967295) { return (New-Check 'signatures' 'Warning' (T 'sec.detail.sigUnknown') 'ms-settings:windowsupdate') }
        $detail = (T 'sec.detail.sigAge' @($age)) + $(if ($ver) { " (v$ver)" } else { '' })
        $state = if ($age -le 3) { 'Ok' } elseif ($age -le 7) { 'Warning' } else { 'Critical' }
        if ($passive -and $state -eq 'Critical') { $state = 'Warning'; $detail += (T 'sec.detail.sigPassive') }
        return (New-Check 'signatures' $state $detail $(if ($state -eq 'Ok') { '' } else { 'ms-settings:windowsupdate' }))
    } 'ms-settings:windowsupdate'))

    $results.Add((Invoke-Check 'tamper' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        if ($null -eq $mp.PSObject.Properties['IsTamperProtected']) { return (New-Check 'tamper' 'Unknown' (T 'sec.detail.tamperNA') '') }
        if ([bool]$mp.IsTamperProtected) { return (New-Check 'tamper' 'Ok' (T 'sec.detail.tamperOn') '') }
        return (New-Check 'tamper' 'Warning' (T 'sec.detail.tamperOff') 'windowsdefender://threatsettings')
    } 'windowsdefender://threatsettings'))

    $results.Add((Invoke-Check 'firewall' {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $on = @($profiles | Where-Object { [string]$_.Enabled -eq 'True' })
        $off = @($profiles | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })
        if ($profiles.Count -gt 0 -and $off.Count -eq 0) { return (New-Check 'firewall' 'Ok' (T 'sec.detail.fwOn') '') }
        if ($on.Count -eq 0) { return (New-Check 'firewall' 'Critical' (T 'sec.detail.fwOff') 'windowsdefender://network') }
        return (New-Check 'firewall' 'Warning' (T 'sec.detail.fwPartial' @(($off -join ', '))) 'windowsdefender://network')
    } 'windowsdefender://network'))

    $results.Add((Invoke-Check 'uac' {
        $v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
        if ($null -eq $v) { return (New-Check 'uac' 'Unknown' (T 'sec.detail.notReadable') '') }
        if ([int]$v -eq 1) { return (New-Check 'uac' 'Ok' (T 'sec.detail.uacOn') '') }
        return (New-Check 'uac' 'Critical' (T 'sec.detail.uacOff') '')
    }))

    $results.Add((Invoke-Check 'secureboot' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        if ($null -ne $v) {
            if ([int]$v -eq 1) { return (New-Check 'secureboot' 'Ok' (T 'sec.detail.sbOn') '') }
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbOff') '')
        }
        try {
            if (Confirm-SecureBootUEFI -ErrorAction Stop) { return (New-Check 'secureboot' 'Ok' (T 'sec.detail.sbOn') '') }
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbOff') '')
        } catch {
            return (New-Check 'secureboot' 'Warning' (T 'sec.detail.sbLegacy') '')
        }
    }))

    $results.Add((Invoke-Check 'tpm' {
        $t = Get-Tpm -ErrorAction Stop
        if (-not [bool](Get-SafeProp $t 'TpmPresent' $false)) {
            if (-not (Test-IsAdmin)) { return (New-Check 'tpm' 'Unknown' (T 'sec.detail.tpmAdmin') '') }
            return (New-Check 'tpm' 'Warning' (T 'sec.detail.tpmNone') '')
        }
        if ([bool](Get-SafeProp $t 'TpmReady' $false)) { return (New-Check 'tpm' 'Ok' (T 'sec.detail.tpmReady') '') }
        return (New-Check 'tpm' 'Warning' (T 'sec.detail.tpmNotReady') 'windowsdefender://devicesecurity')
    } 'windowsdefender://devicesecurity'))

    $results.Add((Invoke-Check 'bitlocker' {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return (New-Check 'bitlocker' 'Unknown' (T 'sec.detail.blNA') '') }
        $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $prot = [string](Get-SafeProp $vol 'ProtectionStatus' '')
        $pct = Get-SafeProp $vol 'EncryptionPercentage' 0
        if ($prot -eq 'On' -or $prot -eq '1') { return (New-Check 'bitlocker' 'Ok' (T 'sec.detail.blOn' @($pct)) '') }
        return (New-Check 'bitlocker' 'Warning' (T 'sec.detail.blOff') 'ms-settings:deviceencryption')
    } 'ms-settings:deviceencryption'))

    $results.Add((Invoke-Check 'smartscreen' {
        $pol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
        $v = [string](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' '')
        if ($null -ne $pol -and [int]$pol -eq 0) { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssPolicy') 'windowsdefender://smartscreenpua') }
        if ($v -eq 'Off') { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssOff') 'windowsdefender://smartscreenpua') }
        $app = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation'
        if ($null -ne $app -and [int]$app -eq 0) { return (New-Check 'smartscreen' 'Warning' (T 'sec.detail.ssAppOff') 'windowsdefender://smartscreenpua') }
        if ($v -eq '') { return (New-Check 'smartscreen' 'Ok' (T 'sec.detail.ssDefault') '') }
        return (New-Check 'smartscreen' 'Ok' (T 'sec.detail.ssOn' @($v)) '')
    } 'windowsdefender://smartscreenpua'))

    $results.Add((Invoke-Check 'hvci' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
        if ($null -ne $v -and [int]$v -eq 1) { return (New-Check 'hvci' 'Ok' (T 'sec.detail.hvciOn') '') }
        return (New-Check 'hvci' 'Warning' (T 'sec.detail.hvciOff') 'windowsdefender://coreisolation')
    } 'windowsdefender://coreisolation'))

    $results.Add((Invoke-Check 'smb1' {
        $enabled = $null
        if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
            try { $enabled = [bool](Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch { }
        }
        if ($null -eq $enabled) {
            $reg = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'
            if ($null -ne $reg) { $enabled = ([int]$reg -ne 0) }
        }
        if ($null -eq $enabled) { return (New-Check 'smb1' 'Unknown' (T 'sec.detail.smbNR') '') }
        if ($enabled) { return (New-Check 'smb1' 'Critical' (T 'sec.detail.smbOn') '') }
        return (New-Check 'smb1' 'Ok' (T 'sec.detail.smbOff') '')
    }))

    $results.Add((Invoke-Check 'rdp' {
        $deny = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
        if ($null -eq $deny) { return (New-Check 'rdp' 'Unknown' (T 'sec.detail.notReadable') '') }
        if ([int]$deny -ne 0) { return (New-Check 'rdp' 'Ok' (T 'sec.detail.rdpOff') '') }
        $nla = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
        if ($null -ne $nla -and [int]$nla -eq 1) { return (New-Check 'rdp' 'Warning' (T 'sec.detail.rdpNla') 'ms-settings:remotedesktop') }
        return (New-Check 'rdp' 'Critical' (T 'sec.detail.rdpOpen') 'ms-settings:remotedesktop')
    } 'ms-settings:remotedesktop'))

    $results.Add((Invoke-Check 'pua' {
        if ($null -eq $pref) { throw 'Defender preferences unavailable' }
        $v = [int](Get-SafeProp $pref 'PUAProtection' 0)
        if ($v -eq 1) { return (New-Check 'pua' 'Ok' (T 'sec.detail.puaOn') '') }
        if ($v -eq 2) { return (New-Check 'pua' 'Warning' (T 'sec.detail.puaAudit') 'windowsdefender://smartscreenpua') }
        return (New-Check 'pua' 'Warning' (T 'sec.detail.puaOff') 'windowsdefender://smartscreenpua')
    } 'windowsdefender://smartscreenpua'))

    $results.Add((Invoke-Check 'lastscan' {
        if ($null -eq $mp) { throw 'Defender status unavailable' }
        $q = [int64](Get-SafeProp $mp 'QuickScanAge' 4294967295)
        $f = [int64](Get-SafeProp $mp 'FullScanAge' 4294967295)
        $best = [Math]::Min($q, $f)
        $detail = (T 'sec.detail.lastScan' @((Format-Age $q), (Format-Age $f)))
        if ($best -le 7) { return (New-Check 'lastscan' 'Ok' $detail '') }
        if ($best -le 30) { return (New-Check 'lastscan' 'Warning' $detail 'windowsdefender://threat') }
        return (New-Check 'lastscan' 'Warning' $detail 'windowsdefender://threat')
    } 'windowsdefender://threat'))

    $results.Add((Invoke-Check 'updates' {
        $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        $last = $null
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = [int]$searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($e in @($searcher.QueryHistory(0, [Math]::Min($count, 40)))) {
                # Operation 1 = installation, ResultCode 2 = succeeded
                if ([int]$e.Operation -eq 1 -and [int]$e.ResultCode -eq 2) {
                    if ($null -eq $last -or $e.Date -gt $last) { $last = [datetime]$e.Date }
                }
            }
        }
        $detail = if ($last) { (T 'sec.detail.updLast' @($last.ToString('yyyy-MM-dd'))) } else { (T 'sec.detail.updNone') }
        if ($reboot) { return (New-Check 'updates' 'Warning' ($detail + (T 'sec.detail.updReboot')) 'ms-settings:windowsupdate') }
        if (-not $last) { return (New-Check 'updates' 'Warning' $detail 'ms-settings:windowsupdate') }
        $age = ((Get-Date) - $last).TotalDays
        if ($age -gt 90) { return (New-Check 'updates' 'Critical' $detail 'ms-settings:windowsupdate') }
        if ($age -gt 45) { return (New-Check 'updates' 'Warning' $detail 'ms-settings:windowsupdate') }
        return (New-Check 'updates' 'Ok' $detail '')
    } 'ms-settings:windowsupdate'))

    return $results.ToArray()
}

# ---------------------------------------------------------------- threat history
function Get-ThreatHistory {
    <# Defender detections of the last 30 days. #>
    $out = New-Object System.Collections.Generic.List[object]
    try {
        $names = @{}
        try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $names[[string]$t.ThreatID] = $t } } catch { }
        $limit = (Get-Date).AddDays(-30)
        $sev = @{ 0 = 'Unknown'; 1 = 'Low'; 2 = 'Moderate'; 4 = 'High'; 5 = 'Severe' }
        $act = @{ 1 = 'Cleaned'; 2 = 'Quarantined'; 3 = 'Removed'; 6 = 'Allowed'; 8 = 'User defined'; 9 = 'No action'; 10 = 'Blocked' }
        foreach ($d in @(Get-MpThreatDetection -ErrorAction Stop)) {
            $time = Get-SafeProp $d 'InitialDetectionTime' $null
            if ($null -eq $time -or [datetime]$time -lt $limit) { continue }
            $id = [string](Get-SafeProp $d 'ThreatID' '')
            $info = if ($names.ContainsKey($id)) { $names[$id] } else { $null }
            $name = [string](Get-SafeProp $info 'ThreatName' ('Threat ' + $id))
            $sid = [int](Get-SafeProp $info 'SeverityID' 0)
            $aid = [int](Get-SafeProp $d 'CleaningActionID' 0)
            $res = @(Get-SafeProp $d 'Resources' @())
            $path = if ($res.Count -gt 0) { ([string]$res[0]) -replace '^[A-Za-z]+:_', '' } else { '' }
            $out.Add([pscustomobject]@{
                Name     = $name
                Severity = $(if ($sev.ContainsKey($sid)) { $sev[$sid] } else { "$sid" })
                Time     = [datetime]$time
                Action   = $(if ($act.ContainsKey($aid)) { $act[$aid] } else { "$aid" })
                Path     = $path
            })
        }
    } catch {
        Write-Log -Level WARN -Message "Get-ThreatHistory failed: $($_.Exception.Message)"
    }
    return @($out.ToArray() | Sort-Object Time -Descending)
}

# ---------------------------------------------------------------- parsers
function ConvertFrom-MrtLog {
    <# Parses (the new part of) C:\Windows\debug\mrt.log. The format is not formally documented, so
       this is heuristic: "No infection found" = clean, otherwise malware family names such as
       Win32/Name or Trojan:Win32/Name are collected. "Return code: N" ends every run. #>
    param([AllowEmptyString()][string]$Text)
    $threats = New-Object System.Collections.Generic.List[string]
    $clean = $Text -match '(?i)no infection found'
    $code = $null
    $m = [regex]::Matches($Text, '(?i)return code:\s*(-?\d+)')
    if ($m.Count -gt 0) { $code = [int]$m[$m.Count - 1].Groups[1].Value }
    if (-not $clean) {
        $rx = '\b(?:Trojan|Backdoor|Worm|Virus|Ransom|PWS|HackTool|Exploit|Program|TrojanDownloader|TrojanDropper|TrojanSpy|Win32|Win64|Win95|Win16|DOS|VBS|JS)[:/][A-Za-z0-9_.!/:-]+'
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '(?i)(detected|found|infect|threat|malware)') {
                foreach ($mm in [regex]::Matches($line, $rx)) {
                    $v = $mm.Value.TrimEnd('.', ',', ':')
                    if (-not $threats.Contains($v)) { $threats.Add($v) }
                }
            }
        }
    }
    $removed = ($threats.Count -gt 0) -and ($Text -match '(?i)(successfully removed|removed|cleaned|disinfected)')
    $finished = $Text -match '(?i)finished on'
    $hasInfection = (-not $clean) -and ($threats.Count -gt 0 -or $Text -match '(?i)(infection|threat|malware)\s+(detected|found)|found\s+(infection|malware)')
    if ($hasInfection -and $threats.Count -eq 0) { $threats.Add('Unknown (see mrt.log)') }
    [pscustomobject]@{
        Clean      = [bool]($clean -and -not $hasInfection)
        Infected   = [bool]$hasInfection
        Removed    = [bool]$removed
        Threats    = $threats.ToArray()
        ReturnCode = $code
        Finished   = [bool]$finished
    }
}

function ConvertFrom-SfcOutput {
    <# Classifies `sfc /scannow` output (English and German wording; text is already NUL-stripped). #>
    param([AllowEmptyString()][string]$Text)
    $t = $Text -replace "`0", ''
    $state = 'Unknown'
    if ($t -match '(?i)unable to fix|could not perform the requested operation|nicht repariert werden|nicht alle|konnte.{0,40}nicht') { $state = 'Unfixed' }
    elseif ($t -match '(?i)successfully repaired|erfolgreich repariert') { $state = 'Repaired' }
    elseif ($t -match '(?i)did not find any integrity violations|keine Integrit.tsverletzung') { $state = 'Clean' }
    elseif ($t -match '(?i)pending system repair|restart.{0,30}pending|Neustart') { $state = 'PendingReboot' }
    return $state
}

function Read-ProcessText {
    <# Decodes raw console output that may be UTF-16 (sfc) or ANSI/UTF-8 (DISM, MRT). #>
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $hasNul = $false
    for ($i = 0; $i -lt [Math]::Min($Bytes.Length, 400); $i++) { if ($Bytes[$i] -eq 0) { $hasNul = $true; break } }
    if ($hasNul) { return ([Text.Encoding]::Unicode.GetString($Bytes) -replace "`0", '') }
    return [Text.Encoding]::Default.GetString($Bytes)
}

function Invoke-RawProcess {
    # Like Invoke-Process, but decodes UTF-16 output (needed for sfc.exe).
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMinutes = 90)
    $tmp = Join-Path (Get-AppPaths).CacheDir ("sec-{0}.out" -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmp
    $null = $p.Handle
    $finished = $p.WaitForExit($TimeoutMinutes * 60 * 1000)
    $code = -999
    if (-not $finished) { try { $p.Kill() } catch { } } else { $p.WaitForExit(); $code = $p.ExitCode }
    $text = ''
    if (Test-Path $tmp) {
        try { $text = Read-ProcessText ([IO.File]::ReadAllBytes($tmp)) } catch { }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $code; Output = [string]$text; TimedOut = (-not $finished) }
}

# ---------------------------------------------------------------- scans
function New-ScanResult {
    param([string]$Type, [string]$Status, [string[]]$Threats = @(), [string]$Message = '', [double]$DurationSec = 0)
    [pscustomobject]@{
        Type        = $Type
        Status      = $Status
        Threats     = @($Threats)
        Message     = $Message
        DurationSec = [Math]::Round($DurationSec, 1)
    }
}

function Invoke-DefenderScan {
    param([string]$Type)
    $started = Get-Date
    $scanType = if ($Type -eq 'Full') { 'FullScan' } else { 'QuickScan' }
    Write-Log -Message "Defender $scanType starting"
    try {
        Start-MpScan -ScanType $scanType -ErrorAction Stop
    } catch {
        return (New-ScanResult $Type 'Failed' @() ("Start-MpScan failed: " + $_.Exception.Message) ((Get-Date) - $started).TotalSeconds)
    }
    $dur = ((Get-Date) - $started).TotalSeconds
    $threats = @()
    $active = $false
    try {
        $from = $started.AddSeconds(-5)
        $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $d = Get-SafeProp $_ 'InitialDetectionTime' $null; $null -ne $d -and [datetime]$d -ge $from })
        $info = @{}
        try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $info[[string]$t.ThreatID] = $t } } catch { }
        foreach ($d in $det) {
            $id = [string](Get-SafeProp $d 'ThreatID' '')
            $ti = if ($info.ContainsKey($id)) { $info[$id] } else { $null }
            $n = [string](Get-SafeProp $ti 'ThreatName' ('Threat ' + $id))
            if ($threats -notcontains $n) { $threats += $n }
            if ($null -ne $ti -and [bool](Get-SafeProp $ti 'IsActive' $false)) { $active = $true }
        }
    } catch { Write-Log -Level WARN -Message "Reading detections failed: $($_.Exception.Message)" }
    if ($threats.Count -eq 0) { return (New-ScanResult $Type 'Clean' @() 'No threats found' $dur) }
    if ($active) { return (New-ScanResult $Type 'ThreatsFound' $threats 'Threats found, some still active - open Windows Security' $dur) }
    return (New-ScanResult $Type 'ThreatsRemoved' $threats 'Threats found and handled by Defender' $dur)
}

function Invoke-MrtScan {
    param([string]$Type)
    $started = Get-Date
    $mrt = Get-MrtPath
    if (-not $mrt) { return (New-ScanResult $Type 'Skipped' @() 'mrt-missing' 0) }
    $log = Get-MrtLogPath
    $offset = 0L
    try { if (Test-Path -LiteralPath $log) { $offset = (Get-Item -LiteralPath $log -ErrorAction Stop).Length } } catch { }
    $args2 = if ($Type -eq 'MrtFull') { @('/Q', '/F') } else { @('/Q') }
    $timeout = if ($Type -eq 'MrtFull') { 240 } else { 60 }
    Write-Log -Message ("MRT starting: " + ($args2 -join ' '))
    $r = Invoke-Process -FilePath $mrt -ArgumentList $args2 -TimeoutMinutes $timeout
    $dur = ((Get-Date) - $started).TotalSeconds
    if ($r.TimedOut) { return (New-ScanResult $Type 'Failed' @() 'timeout' $dur) }
    $text = ''
    try {
        if (Test-Path -LiteralPath $log) {
            $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -lt $offset) { $offset = 0 }   # log was rotated
                [void]$fs.Seek($offset, 'Begin')
                $buf = New-Object byte[] ($fs.Length - $offset)
                $n = $fs.Read($buf, 0, $buf.Length)
                if ($n -lt $buf.Length) { $short = New-Object byte[] ([Math]::Max(0, $n)); if ($n -gt 0) { [Array]::Copy($buf, $short, $n) }; $buf = $short }
                $text = Read-ProcessText $buf
            } finally { $fs.Dispose() }
        }
    } catch { Write-Log -Level WARN -Message "mrt.log unreadable: $($_.Exception.Message)" }
    if (-not $text.Trim()) {
        if ($r.ExitCode -eq 0) { return (New-ScanResult $Type 'Clean' @() 'Finished without findings (no log entry)' $dur) }
        return (New-ScanResult $Type 'Failed' @() ("MRT exit code " + $r.ExitCode + ", no log entry") $dur)
    }
    $p = ConvertFrom-MrtLog $text
    if ($p.Clean) { return (New-ScanResult $Type 'Clean' @() 'No infection found' $dur) }
    if ($p.Infected -and $p.Removed) { return (New-ScanResult $Type 'ThreatsRemoved' $p.Threats 'Threats found and removed' $dur) }
    if ($p.Infected) { return (New-ScanResult $Type 'ThreatsFound' $p.Threats ("Threats found - see " + $log) $dur) }
    if ($r.ExitCode -eq 0 -or $p.ReturnCode -eq 0) { return (New-ScanResult $Type 'Clean' @() 'Finished without findings' $dur) }
    return (New-ScanResult $Type 'Failed' @() ("MRT exit code " + $r.ExitCode) $dur)
}

function Invoke-IntegrityScan {
    $started = Get-Date
    $sfc = Join-Path ([Environment]::GetFolderPath('System')) 'sfc.exe'
    $dism = Join-Path ([Environment]::GetFolderPath('System')) 'Dism.exe'
    Write-Log -Message 'sfc /scannow starting'
    $r = Invoke-RawProcess -FilePath $sfc -ArgumentList @('/scannow') -TimeoutMinutes 240
    if ($r.TimedOut) { return (New-ScanResult 'Integrity' 'Failed' @() 'sfc timeout' ((Get-Date) - $started).TotalSeconds) }
    $state = ConvertFrom-SfcOutput $r.Output
    Write-Log -Message "sfc result: $state (exit $($r.ExitCode))"
    switch ($state) {
        'Clean'    { return (New-ScanResult 'Integrity' 'Clean' @() 'No integrity violations' ((Get-Date) - $started).TotalSeconds) }
        'Repaired' { return (New-ScanResult 'Integrity' 'ThreatsRemoved' @() 'Corrupt system files were repaired' ((Get-Date) - $started).TotalSeconds) }
        'PendingReboot' { return (New-ScanResult 'Integrity' 'Failed' @() 'Restart Windows first (pending repair), then run again' ((Get-Date) - $started).TotalSeconds) }
        'Unknown'  { return (New-ScanResult 'Integrity' 'Failed' @() ("sfc result not recognised (exit " + $r.ExitCode + ")") ((Get-Date) - $started).TotalSeconds) }
    }
    # Unfixed corruption -> repair the component store with DISM, then verify again with sfc.
    Write-Log -Message 'DISM RestoreHealth starting'
    $d = Invoke-Process -FilePath $dism -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth') -TimeoutMinutes 240
    if ($d.TimedOut) { return (New-ScanResult 'Integrity' 'Failed' @() 'DISM timeout' ((Get-Date) - $started).TotalSeconds) }
    if ($d.ExitCode -ne 0) {
        return (New-ScanResult 'Integrity' 'ThreatsFound' @() ("sfc found unfixable files; DISM failed (exit " + $d.ExitCode + ")") ((Get-Date) - $started).TotalSeconds)
    }
    $r2 = Invoke-RawProcess -FilePath $sfc -ArgumentList @('/scannow') -TimeoutMinutes 240
    $state2 = ConvertFrom-SfcOutput $r2.Output
    $dur = ((Get-Date) - $started).TotalSeconds
    if ($state2 -eq 'Clean' -or $state2 -eq 'Repaired') { return (New-ScanResult 'Integrity' 'ThreatsRemoved' @() 'Repaired with DISM and sfc' $dur) }
    return (New-ScanResult 'Integrity' 'ThreatsFound' @() 'Some system files could not be repaired - see CBS.log' $dur)
}

function Start-SecurityScan {
    param(
        [Parameter(Mandatory)][ValidateSet('Quick', 'Full', 'Mrt', 'MrtFull', 'Integrity')][string]$Type,
        [switch]$DryRun
    )
    $started = Get-Date
    try {
        if ($DryRun) { return (New-ScanResult $Type 'WouldRun' @() 'dry-run' 0) }
        if (-not (Test-IsAdmin)) { return (New-ScanResult $Type 'Skipped' @() 'needs-admin' 0) }
        Initialize-DataDir
        switch ($Type) {
            { $_ -in 'Quick', 'Full' } {
                if (Test-DefenderPassive) { return (New-ScanResult $Type 'Skipped' @() 'defender-passive' 0) }
                return (Invoke-DefenderScan $Type)
            }
            { $_ -in 'Mrt', 'MrtFull' } { return (Invoke-MrtScan $Type) }
            'Integrity' { return (Invoke-IntegrityScan) }
        }
    } catch {
        Write-Log -Level ERROR -Message "Start-SecurityScan $Type failed: $($_.Exception.Message)"
        return (New-ScanResult $Type 'Failed' @() $_.Exception.Message ((Get-Date) - $started).TotalSeconds)
    }
}

Export-ModuleMember -Function Get-SecurityStatus, Start-SecurityScan, Get-ThreatHistory, Get-MrtPath, Get-MrtLogPath, ConvertFrom-MrtLog, ConvertFrom-SfcOutput, Test-DefenderPassive, Get-ThirdPartyAntivirus
