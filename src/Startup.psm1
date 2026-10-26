# Update Center - autostart manager.
# Behaves like the Task Manager "Startup apps" tab: items are only ever DISABLED/ENABLED through the
# StartupApproved registry values (or by disabling/enabling a scheduled task). Run values, startup-folder
# shortcuts and tasks are never deleted. -DryRun never changes anything.
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:ApprovedBaseHKCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:ApprovedBaseHKLM = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

# =====================================================================================
# Protection rules - the ONE place to edit. Each rule matches against the item name,
# the publisher and the image file name. Reason = i18n key startup.protect.<Key>.
# =====================================================================================
$script:ProtectRules = @(
    @{ Key = 'security'
       Name = '(?i)SecurityHealth|Windows Security|Windows Defender|Microsoft Defender|\bDefender\b|MsMpEng|Antivirus|Anti-?Malware|Endpoint Protection'
       Publisher = '(?i)Kaspersky|Bitdefender|Avast|\bAVG\b|Norton|Gen Digital|McAfee|\bESET\b|Sophos|Malwarebytes|Trend Micro|F-Secure|WithSecure|CrowdStrike|SentinelOne|Carbon Black|Cylance|Webroot|G ?DATA|Avira|Panda Security|Comodo|Symantec|Cisco Systems.*Secure'
       Exe = '(?i)^(SecurityHealth\w*|MSASCui|MpCmdRun|MpDefenderCoreService|avast\w*|avgui|avp|bdagent|mcui\w*|egui|SophosUI|MBAMTray|ccSvcHst|CylanceUI|csfalcon\w*)\.exe$' },
    @{ Key = 'driver'
       Name = '(?i)Realtek|NVIDIA|\bGeForce\b|Radeon|\bAMD\b.*(Software|Settings|Chipset)|Intel\(R\)|Intel Graphics|Synaptics|\bElan\b|HD Audio|Waves ?MaxxAudio|Conexant|Dolby'
       Publisher = '(?i)^Realtek|NVIDIA|Advanced Micro Devices|^Intel\b|Synaptics|Elan Microelectronics|Conexant|Dolby'
       Exe = '(?i)^(RtkNGUI\w*|RAVCpl\w*|RtkAudUService\w*|nvcontainer|NvBackend|NvTray|nvtray|NVDisplay\.Container|RadeonSoftware|AMDRSServ|AMDRSSrcExt|igfxtray|igfxpers|igfxHK|SynTPEnh|SynTPHelper|ETDCtrl\w*|HControl|WavesSvc\w*)\.exe$' },
    @{ Key = 'input'
       Name = '(?i)\bctfmon\b|\bIME\b|Text Input|Input Method|TabTip|Touch Keyboard|Handwriting'
       Publisher = ''
       Exe = '(?i)^(ctfmon|imejp\w*|imekr\w*|ChsIME|ChtIME|MicrosoftIME\w*|TabTip|InputPersonalization|TextInputHost)\.exe$' },
    @{ Key = 'accessibility'
       Name = '(?i)Narrator|Magnifier|On-?Screen Keyboard|Screen Reader|\bNVDA\b|\bJAWS\b|ZoomText|Sticky Keys|Accessibility|Ease of Access'
       Publisher = '(?i)NV Access|Freedom Scientific|Vispero|Dolphin Computer Access'
       Exe = '(?i)^(narrator|magnify|osk|utilman|AtBroker|nvda|jfw|zt\w*)\.exe$' },
    @{ Key = 'self'
       Name = '(?i)Update ?Center|ALERION Update|ALERION.*Update'
       Publisher = ''
       Exe = '(?i)^(UpdateCenter\w*|AlerionUpdate\w*)\.exe$' }
)

function Get-StartupProtection {
    <# Reason key (e.g. 'startup.protect.security') or '' when the item may be disabled. #>
    param([string]$Name, [string]$Publisher, [string]$ImagePath, [string]$Command)
    $exe = ''
    if ($ImagePath) { try { $exe = [IO.Path]::GetFileName($ImagePath) } catch { $exe = '' } }
    $cmd = [string]$Command
    foreach ($r in $script:ProtectRules) {
        if ($r.Name -and $Name -and $Name -match $r.Name) { return 'startup.protect.' + $r.Key }
        if ($r.Publisher -and $Publisher -and $Publisher -match $r.Publisher) { return 'startup.protect.' + $r.Key }
        if ($r.Exe -and $exe -and $exe -match $r.Exe) { return 'startup.protect.' + $r.Key }
    }
    # Update Center installed anywhere: its own scripts/folder in the command line.
    if ($cmd -match '(?i)UpdateCenter|ALERION[ _-]?Update|Computer Update\\src') { return 'startup.protect.self' }
    return ''
}

# =====================================================================================
# Small helpers
# =====================================================================================

function Get-SuProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function ConvertFrom-StartupApproved {
    <# StartupApproved binary -> enabled? Absent/empty = enabled. First byte even (02/06) = enabled, odd (03/07) = disabled. #>
    param($Bytes)
    if ($null -eq $Bytes) { return $true }
    $b = @($Bytes)
    if ($b.Count -lt 1) { return $true }
    return (([int]$b[0] -band 1) -eq 0)
}

function ConvertTo-StartupApproved {
    <# 12-byte value exactly like Task Manager: enabled = 02 + zeros; disabled = 03 00 00 00 + FILETIME(now). #>
    param([bool]$Enabled, [datetime]$Now = [datetime]::UtcNow)
    $bytes = New-Object byte[] 12
    if ($Enabled) { $bytes[0] = 2; return , $bytes }
    $bytes[0] = 3
    $ft = [BitConverter]::GetBytes([int64]$Now.ToUniversalTime().ToFileTimeUtc())
    [Array]::Copy($ft, 0, $bytes, 4, 8)
    return , $bytes
}

function Get-CommandImagePath {
    <# Executable path out of a command line ('' when unknown). Handles quotes and unquoted paths with spaces. #>
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) { return $c.Substring(1, $end - 1) }
        return $c.Trim('"')
    }
    $m = [regex]::Match($c, '^(.+?\.(exe|bat|cmd|com|lnk|msc|cpl|vbs|js|ps1))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    $first = ($c -split '\s+')[0]
    return $first
}

$script:PublisherCache = @{}
function Get-ImagePublisher {
    param([string]$ImagePath)
    if (-not $ImagePath) { return '' }
    if ($script:PublisherCache.ContainsKey($ImagePath)) { return $script:PublisherCache[$ImagePath] }
    $pub = ''
    try {
        if (Test-Path -LiteralPath $ImagePath -PathType Leaf) {
            try { $pub = [string](Get-Item -LiteralPath $ImagePath -ErrorAction Stop).VersionInfo.CompanyName } catch { $pub = '' }
            if ([string]::IsNullOrWhiteSpace($pub) -and $ImagePath -match '(?i)\.(exe|dll|msi|sys)$') {
                try {
                    $sig = Get-AuthenticodeSignature -LiteralPath $ImagePath -ErrorAction Stop
                    if ($sig -and $sig.SignerCertificate) {
                        $m = [regex]::Match([string]$sig.SignerCertificate.Subject, 'CN=("([^"]+)"|[^,]+)')
                        if ($m.Success) { $pub = $m.Groups[1].Value.Trim('"').Trim() }
                    }
                } catch { $pub = '' }
            }
        }
    } catch { $pub = '' }
    if ($null -eq $pub) { $pub = '' }
    $pub = $pub.Trim()
    $script:PublisherCache[$ImagePath] = $pub
    return $pub
}

function Get-StartupImpactHint {
    <# Rough estimate from the file size only (a real impact needs ETW boot traces). unknown|low|medium|high #>
    param([string]$ImagePath)
    try {
        if ($ImagePath -and (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            $len = (Get-Item -LiteralPath $ImagePath).Length
            if ($len -lt 3MB) { return 'low' }
            if ($len -lt 40MB) { return 'medium' }
            return 'high'
        }
    } catch { }
    return 'unknown'
}

function New-StartupItem {
    param([string]$Id, [string]$Name, [string]$Command, [string]$Location, [string]$Scope, [bool]$Enabled,
          [string]$ImagePath, [string]$ApprovedPath, [string]$ApprovedValue, [string]$Kind,
          [string]$TaskPath = '', [string]$TaskName = '', [string]$Publisher = $null)
    if ($null -eq $Publisher -or $Publisher -eq '') { $Publisher = Get-ImagePublisher -ImagePath $ImagePath }
    $exists = $false
    if ($ImagePath) { try { $exists = [bool](Test-Path -LiteralPath $ImagePath) } catch { $exists = $false } }
    $reason = Get-StartupProtection -Name $Name -Publisher $Publisher -ImagePath $ImagePath -Command $Command
    [pscustomobject]@{
        Id = $Id; Name = $Name; Publisher = [string]$Publisher; Command = $Command
        Location = $Location; Scope = $Scope; Enabled = $Enabled
        Protected = [bool]$reason; ProtectReason = [string]$reason
        Impact = (Get-StartupImpactHint -ImagePath $ImagePath)
        ImagePath = $ImagePath; Exists = $exists
        Kind = $Kind; ApprovedPath = $ApprovedPath; ApprovedValue = $ApprovedValue
        TaskPath = $TaskPath; TaskName = $TaskName
    }
}

function Get-ApprovedState {
    param([string]$ApprovedPath, [string]$ValueName)
    try {
        if (-not $ApprovedPath -or -not (Test-Path -LiteralPath $ApprovedPath)) { return $true }
        $k = Get-Item -LiteralPath $ApprovedPath -ErrorAction Stop
        $v = $k.GetValue($ValueName, $null)
        if ($v -is [byte[]]) { return (ConvertFrom-StartupApproved -Bytes $v) }
        return $true
    } catch { return $true }
}

# =====================================================================================
# Get-StartupItems
# =====================================================================================

function Get-RunKeyItems {
    param([string]$RunPath, [string]$Location, [string]$Scope, [string]$ApprovedPath, [string]$IdPrefix)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $RunPath)) { return $out }
    try { $key = Get-Item -LiteralPath $RunPath -ErrorAction Stop } catch { return $out }
    foreach ($vn in @($key.GetValueNames())) {
        if ([string]::IsNullOrEmpty($vn)) { continue }
        $cmd = [string]$key.GetValue($vn, '')
        $img = Get-CommandImagePath -Command $cmd
        $en = Get-ApprovedState -ApprovedPath $ApprovedPath -ValueName $vn
        $out.Add((New-StartupItem -Id "$IdPrefix|$vn" -Name $vn -Command $cmd -Location $Location -Scope $Scope -Enabled $en `
            -ImagePath $img -ApprovedPath $ApprovedPath -ApprovedValue $vn -Kind 'run'))
    }
    return $out
}

function Get-FolderItems {
    param([string]$Folder, [string]$Location, [string]$Scope, [string]$ApprovedPath, [string]$IdPrefix)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return $out }
    $shell = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -ieq 'desktop.ini') { continue }
        $cmd = $f.FullName; $img = $f.FullName
        if ($f.Extension -ieq '.lnk') {
            try {
                if ($null -eq $shell) { $shell = New-Object -ComObject WScript.Shell }
                $lnk = $shell.CreateShortcut($f.FullName)
                if ($lnk.TargetPath) {
                    $img = [string]$lnk.TargetPath
                    $cmd = ('"' + $img + '" ' + [string]$lnk.Arguments).Trim()
                }
            } catch { }
        }
        $en = Get-ApprovedState -ApprovedPath $ApprovedPath -ValueName $f.Name
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $out.Add((New-StartupItem -Id "$IdPrefix|$($f.Name)" -Name $name -Command $cmd -Location $Location -Scope $Scope -Enabled $en `
            -ImagePath $img -ApprovedPath $ApprovedPath -ApprovedValue $f.Name -Kind 'folder'))
    }
    if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    return $out
}

function Get-TaskItems {
    $out = New-Object System.Collections.Generic.List[object]
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { return $out }
    foreach ($t in $tasks) {
        try {
            $tp = [string]$t.TaskPath
            if ($tp -match '^\\Microsoft\\') { continue }
            $logon = $false
            foreach ($tr in @($t.Triggers)) {
                if ($null -ne $tr -and $tr.CimClass -and $tr.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') { $logon = $true; break }
            }
            if (-not $logon) { continue }
            $cmd = ''
            $act = @($t.Actions) | Select-Object -First 1
            if ($act) { $cmd = ((Get-SuProp $act 'Execute' '') + ' ' + (Get-SuProp $act 'Arguments' '')).Trim() }
            $img = Get-CommandImagePath -Command ([string](Get-SuProp $act 'Execute' ''))
            $uid = [string](Get-SuProp $t.Principal 'UserId' '')
            $scope = 'User'
            if ($uid -match '(?i)SYSTEM|LOCAL SERVICE|NETWORK SERVICE|Administrators' -or [string](Get-SuProp $t.Principal 'RunLevel' '') -eq 'Highest') { $scope = 'Machine' }
            $en = ([string]$t.State -ne 'Disabled')
            $out.Add((New-StartupItem -Id ("Task|" + $tp + $t.TaskName) -Name ([string]$t.TaskName) -Command $cmd `
                -Location 'Task' -Scope $scope -Enabled $en -ImagePath $img -ApprovedPath '' -ApprovedValue '' -Kind 'task' `
                -TaskPath $tp -TaskName ([string]$t.TaskName)))
        } catch { }
    }
    return $out
}

function Get-StartupItems {
    <# All autostart entries. -RunRoot/-ApprovedRoot are test overrides: when RunRoot is given ONLY that key
       is scanned (as 'HKCU Run') and its state is read from <ApprovedRoot>\Run. #>
    param([string]$RunRoot, [string]$ApprovedRoot, [switch]$SkipTasks)
    $items = New-Object System.Collections.Generic.List[object]
    if ($RunRoot) {
        $ap = if ($ApprovedRoot) { Join-Path $ApprovedRoot 'Run' } else { Join-Path $script:ApprovedBaseHKCU 'Run' }
        foreach ($i in @(Get-RunKeyItems -RunPath $RunRoot -Location 'HKCU Run' -Scope 'User' -ApprovedPath $ap -IdPrefix 'HKCU-Run')) { $items.Add($i) }
        return $items.ToArray()
    }
    foreach ($i in @(Get-RunKeyItems -RunPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Location 'HKCU Run' -Scope 'User' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKCU 'Run') -IdPrefix 'HKCU-Run')) { $items.Add($i) }
    foreach ($i in @(Get-RunKeyItems -RunPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Location 'HKLM Run' -Scope 'Machine' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKLM 'Run') -IdPrefix 'HKLM-Run')) { $items.Add($i) }
    foreach ($i in @(Get-RunKeyItems -RunPath 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' -Location 'HKLM Run WOW6432' -Scope 'Machine' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKLM 'Run32') -IdPrefix 'HKLM-Run32')) { $items.Add($i) }
    $userStartup = [Environment]::GetFolderPath('Startup')
    $commonStartup = [Environment]::GetFolderPath('CommonStartup')
    foreach ($i in @(Get-FolderItems -Folder $userStartup -Location 'HKCU Startup folder' -Scope 'User' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKCU 'StartupFolder') -IdPrefix 'UserStartup')) { $items.Add($i) }
    foreach ($i in @(Get-FolderItems -Folder $commonStartup -Location 'Common Startup folder' -Scope 'Machine' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKLM 'StartupFolder') -IdPrefix 'CommonStartup')) { $items.Add($i) }
    if (-not $SkipTasks) { foreach ($i in @(Get-TaskItems)) { $items.Add($i) } }
    return $items.ToArray()
}

# =====================================================================================
# Set-StartupItemEnabled
# =====================================================================================

function New-StartupResult {
    param([bool]$Ok, [string]$Message, $Item, [bool]$Enabled, [bool]$DryRun = $false)
    [pscustomobject]@{
        Ok = $Ok; Message = $Message; DryRun = $DryRun; Enabled = $Enabled
        Id = [string](Get-SuProp $Item 'Id' ''); Name = [string](Get-SuProp $Item 'Name' '')
    }
}

function Set-StartupItemEnabled {
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][bool]$Enabled,
          [switch]$DryRun, [string]$ApprovedRoot)
    $kind = [string](Get-SuProp $Item 'Kind' '')
    $name = [string](Get-SuProp $Item 'Name' '')
    if (-not $kind -or -not $name) { return (New-StartupResult -Ok $false -Message 'startup.invalid' -Item $Item -Enabled $Enabled) }

    # Second line of defense: re-evaluate from the data, so a tampered Protected flag cannot bypass it.
    if (-not $Enabled) {
        $reason = Get-StartupProtection -Name $name -Publisher ([string](Get-SuProp $Item 'Publisher' '')) `
            -ImagePath ([string](Get-SuProp $Item 'ImagePath' '')) -Command ([string](Get-SuProp $Item 'Command' ''))
        if ($reason -or [bool](Get-SuProp $Item 'Protected' $false)) {
            return (New-StartupResult -Ok $false -Message 'startup.protected' -Item $Item -Enabled $Enabled -DryRun:$DryRun)
        }
    }

    $scope = [string](Get-SuProp $Item 'Scope' 'User')
    $needsAdmin = ($scope -eq 'Machine') -and (-not $ApprovedRoot)
    if ($needsAdmin -and -not (Test-IsAdmin)) {
        return (New-StartupResult -Ok $false -Message 'startup.needsAdmin' -Item $Item -Enabled $Enabled -DryRun:$DryRun)
    }

    if ($DryRun) { return (New-StartupResult -Ok $true -Message 'startup.dryRun' -Item $Item -Enabled $Enabled -DryRun $true) }

    try {
        if ($kind -eq 'task') {
            $tp = [string](Get-SuProp $Item 'TaskPath' '\'); $tn = [string](Get-SuProp $Item 'TaskName' '')
            if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop) }
            else { [void](Disable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop) }
            return (New-StartupResult -Ok $true -Message 'startup.ok' -Item $Item -Enabled $Enabled)
        }
        $ap = [string](Get-SuProp $Item 'ApprovedPath' '')
        $vn = [string](Get-SuProp $Item 'ApprovedValue' '')
        if ($ApprovedRoot) {
            $leaf = if ($ap) { Split-Path -Leaf $ap } else { 'Run' }
            $ap = Join-Path $ApprovedRoot $leaf
        }
        if (-not $ap -or -not $vn) { return (New-StartupResult -Ok $false -Message 'startup.invalid' -Item $Item -Enabled $Enabled) }
        if (-not (Test-Path -LiteralPath $ap)) { [void](New-Item -Path $ap -Force -ErrorAction Stop) }
        $bytes = ConvertTo-StartupApproved -Enabled $Enabled
        [void](New-ItemProperty -LiteralPath $ap -Name $vn -PropertyType Binary -Value $bytes -Force -ErrorAction Stop)
        return (New-StartupResult -Ok $true -Message 'startup.ok' -Item $Item -Enabled $Enabled)
    } catch [System.UnauthorizedAccessException] {
        return (New-StartupResult -Ok $false -Message 'startup.needsAdmin' -Item $Item -Enabled $Enabled)
    } catch [System.Security.SecurityException] {
        return (New-StartupResult -Ok $false -Message 'startup.needsAdmin' -Item $Item -Enabled $Enabled)
    } catch {
        Write-Log -Level WARN -Message "Startup toggle failed for '$name': $($_.Exception.Message)"
        return (New-StartupResult -Ok $false -Message 'startup.failed' -Item $Item -Enabled $Enabled)
    }
}

Export-ModuleMember -Function Get-StartupItems, Set-StartupItemEnabled, Get-StartupImpactHint, Get-StartupProtection, ConvertFrom-StartupApproved, ConvertTo-StartupApproved, Get-CommandImagePath
