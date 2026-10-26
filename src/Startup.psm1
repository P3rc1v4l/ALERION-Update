# Update Center - autostart manager.
# Behaves like the Task Manager "Startup apps" tab: items are only ever DISABLED/ENABLED through the
# StartupApproved registry values (or by disabling/enabling a scheduled task). Run values, startup-folder
# shortcuts and tasks are never deleted. -DryRun never changes anything.
# The only things this module ever creates/removes are shortcuts in the CURRENT USER startup folder that carry
# the description 'Added by Update Center' (Add-StartupItem / Remove-StartupItem; removal goes to the Recycle Bin).
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

$script:ApprovedBaseHKCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:ApprovedBaseHKLM = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:MarkerDescription = 'Added by Update Center'
$script:SignerCache = @{}

# =====================================================================================
# Protection rules - the ONE place to edit. Each rule matches against the item name,
# the publisher and the image file name. Reason = i18n key startup.protect.<Key>.
# Two more protections are not name based (see Get-StartupProtection): scheduled tasks that run as
# SYSTEM / a service account / with highest privileges (systemTask), and anything signed by
# O=Microsoft Corporation whose image lies under %WINDIR% (windows).
# User apps (Discord, Steam, Spotify, OneDrive, Logitech G HUB, Stream Deck, GoXLR, NZXT CAM,
# Corsair iCUE, ...) are deliberately NOT listed and stay toggleable.
# =====================================================================================
$script:ProtectRules = @(
    # security: Windows Security / Defender and third-party antivirus tray and agent programs
    @{ Key = 'security'
       Name = '(?i)SecurityHealth|Windows Security|Windows Defender|Microsoft Defender|\bDefender\b|MsMpEng|Antivirus|Anti-?Malware|Endpoint Protection'
       Publisher = '(?i)Kaspersky|Bitdefender|Avast|\bAVG\b|Norton|Gen Digital|McAfee|\bESET\b|Sophos|Malwarebytes|Trend Micro|F-Secure|WithSecure|CrowdStrike|SentinelOne|Carbon Black|Cylance|Webroot|G ?DATA|Avira|Panda Security|Comodo|Symantec|Cisco Systems.*Secure'
       Exe = '(?i)^(SecurityHealth\w*|MSASCui|MpCmdRun|MpDefenderCoreService|avast\w*|avgui|avp|bdagent|mcui\w*|egui|SophosUI|MBAMTray|ccSvcHst|CylanceUI|csfalcon\w*)\.exe$' },
    # driver: audio, graphics, chipset and touchpad helpers (Realtek, Intel, AMD, NVIDIA, Synaptics, Elan, Dolby)
    @{ Key = 'driver'
       Name = '(?i)Realtek|NVIDIA|\bGeForce\b|Radeon|\bAMD\b.*(Software|Settings|Chipset)|Intel\(R\)|Intel Graphics|Intel.*(Driver|Graphics|Wireless|Bluetooth|Management Engine|Audio|Rapid Storage)|Synaptics|\bElan\b|HD Audio|Waves ?MaxxAudio|Conexant|Dolby'
       Publisher = '(?i)^Realtek|NVIDIA|Advanced Micro Devices|^Intel\b|Synaptics|Elan Microelectronics|Conexant|Dolby'
       Exe = '(?i)^(RtkNGUI\w*|RAVCpl\w*|RtkAudUService\w*|nvcontainer|NvBackend|NvTray|nvtray|NVDisplay\.Container|RadeonSoftware|AMDRSServ|AMDRSSrcExt|igfxtray|igfxpers|igfxHK|SynTPEnh|SynTPHelper|ETDCtrl\w*|HControl|WavesSvc\w*)\.exe$' },
    # oem: hardware services of PC/board makers (ASUS Armoury Crate and helpers, Gigabyte GCC, MSI Center, Lenovo Vantage, Dell SupportAssist, HP support, power agents)
    @{ Key = 'oem'
       Name = '(?i)Armou?ry ?(Crate|Socket)|ArmourySocketServer|ArmouryCrate|AcPowerNotification|NoiseCancelingEngine|AsusFCNotification|\bASUS\b|Gigabyte|\bGCC\b|MSI Center|Lenovo Vantage|Lenovo.*(Service|Hotkey|Utility)|SupportAssist|Dell (Update|Command|Optimizer|Power|Digital)|HP (Support|System Event|Hotkey|Wolf|Smart Sense|Audio)|HPSupport|HPSystemEvent|P508PowerAgent|PowerAgent'
       Publisher = '(?i)ASUSTeK|\bASUS\b|GIGA-?BYTE|Micro-Star|\bMSI\b|Lenovo|Dell Inc|Dell Technologies|Hewlett-Packard|^HP Inc|Acer Incorporated'
       Exe = '(?i)^(ArmouryCrate\w*|ArmourySocketServer|ArmouryHM\w*|AsusFCNotification|AsusSystemAnalysis\w*|AcPowerNotification|NoiseCancelingEngine|GCC\w*|GigabyteUpdateService|MSI ?Center\w*|Dragon ?Center\w*|LenovoVantage\w*|LenovoUtility\w*|SupportAssist\w*|HPSupportAssistant\w*|HPSystemEventUtility\w*|HpTouchpointAnalytics\w*|P508PowerAgent)\.exe$' },
    # input: keyboard/IME/touch text-input helpers; without them typing can stop working
    @{ Key = 'input'
       Name = '(?i)\bctfmon\b|\bIME\b|Text Input|Input Method|TabTip|Touch Keyboard|Handwriting'
       Publisher = ''
       Exe = '(?i)^(ctfmon|imejp\w*|imekr\w*|ChsIME|ChtIME|MicrosoftIME\w*|TabTip|InputPersonalization|TextInputHost)\.exe$' },
    # accessibility: screen readers, magnifiers and on-screen keyboards that some people depend on
    @{ Key = 'accessibility'
       Name = '(?i)Narrator|Magnifier|On-?Screen Keyboard|Screen Reader|\bNVDA\b|\bJAWS\b|ZoomText|Sticky Keys|Accessibility|Ease of Access'
       Publisher = '(?i)NV Access|Freedom Scientific|Vispero|Dolphin Computer Access'
       Exe = '(?i)^(narrator|magnify|osk|utilman|AtBroker|nvda|jfw|zt\w*)\.exe$' },
    # self: Update Center itself must not switch its own autostart off here
    @{ Key = 'self'
       Name = '(?i)Update ?Center|ALERION Update|ALERION.*Update'
       Publisher = ''
       Exe = '(?i)^(UpdateCenter\w*|AlerionUpdate\w*)\.exe$' }
)

function Test-TaskPrivileged {
    <# True when a scheduled task runs as SYSTEM / a service account / an admin group, or with highest privileges. #>
    param([string]$UserId, [string]$RunLevel, [string]$LogonType)
    if ($RunLevel -eq 'Highest') { return $true }
    if ($LogonType -match '(?i)ServiceAccount') { return $true }
    if ($UserId -match '(?i)^(NT AUTHORITY\\|NT SERVICE\\)|\bSYSTEM\b|LOCAL ?SERVICE|NETWORK ?SERVICE|LocalSystem|Administrators|^S-1-5-(18|19|20|32-544)$') { return $true }
    return $false
}

function Test-WindowsMicrosoftImage {
    <# True when the image lies under %WINDIR% AND is signed by O=Microsoft Corporation.
       -SignerSubject lets tests supply the certificate subject instead of reading the file. #>
    param([string]$ImagePath, $SignerSubject = $null)
    if (-not $ImagePath) { return $false }
    $win = [Environment]::GetEnvironmentVariable('WINDIR')
    if (-not $win) { return $false }
    $full = ''
    try { $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ImagePath)) } catch { return $false }
    $winFull = $win.TrimEnd('\') + '\'
    if (-not $full.StartsWith($winFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($null -eq $SignerSubject) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        if ($script:SignerCache.ContainsKey($full)) { $SignerSubject = $script:SignerCache[$full] }
        else {
            $SignerSubject = ''
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop
                if ($sig -and $sig.SignerCertificate -and [string]$sig.Status -eq 'Valid') { $SignerSubject = [string]$sig.SignerCertificate.Subject }
            } catch { $SignerSubject = '' }
            $script:SignerCache[$full] = $SignerSubject
        }
    }
    # WHQL driver/vendor files are co-signed by Microsoft hardware publishers - those are third-party, not Windows itself
    if ([string]$SignerSubject -match '(?i)CN=[^,]*(Hardware Compatibility|Hardware Abstraction|Third Party)') { return $false }
    return ([string]$SignerSubject -match '(?i)(^|,\s*)O=Microsoft Corporation(,|$)')
}

function Get-HostLaunchTarget {
    <# For generic Windows host binaries (rundll32, regsvr32, cmd, powershell, wscript, cscript, explorer, conhost) that
       launch something via their arguments: the DLL/script/exe path found in the arguments ('' when not a host or no path found). #>
    param([string]$ImagePath, [string]$Command)
    if (-not $ImagePath -or -not $Command) { return '' }
    $exe = ''
    try { $exe = [IO.Path]::GetFileName($ImagePath) } catch { return '' }
    if ($exe -notmatch '(?i)^(rundll32|regsvr32|cmd|powershell|pwsh|wscript|cscript|explorer|conhost)\.exe$') { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $m0 = [regex]::Match($c, '^\s*("[^"]*"|\S+)\s*(.*)$')
    if (-not $m0.Success) { return '' }
    $rest = $m0.Groups[2].Value
    $ext = 'dll|ps1|vbs|vbe|js|jse|wsf|bat|cmd|exe|msc|cpl'
    $m = [regex]::Match($rest, '(?i)"([A-Za-z]:[\\/][^"]+?\.(?:' + $ext + '))"|([A-Za-z]:[\\/][^",|&]*?\.(?:' + $ext + '))')
    if (-not $m.Success) { return '' }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

function Get-StartupProtection {
    <# Reason key (e.g. 'startup.protect.security') or '' when the item may be disabled.
       -IsSystemTask: scheduled task running as SYSTEM/service/highest. -SignerSubject: test override for the signature. #>
    param([string]$Name, [string]$Publisher, [string]$ImagePath, [string]$Command,
          [bool]$IsSystemTask = $false, $SignerSubject = $null)
    # systemTask: tasks with elevated principals are only listed, never toggled
    if ($IsSystemTask) { return 'startup.protect.systemTask' }
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
    # windows: signed by Microsoft Corporation and located under %WINDIR% = part of Windows itself
    # generic Windows host (rundll32, cmd, ...) launching a component: judge the launched file, not the host
    $hostTarget = Get-HostLaunchTarget -ImagePath $ImagePath -Command $Command
    if ($hostTarget) {
        if (Test-WindowsMicrosoftImage -ImagePath $hostTarget -SignerSubject $SignerSubject) { return 'startup.protect.windows' }
        return ''
    }
    if (Test-WindowsMicrosoftImage -ImagePath $ImagePath -SignerSubject $SignerSubject) { return 'startup.protect.windows' }
    return ''
}

function Get-StartupRisk {
    <# Beginner-friendly risk of DISABLING an item: Low | Medium | High, plus i18n reason key startup.risk.reason.* #>
    param([bool]$Protected, [string]$Kind, [string]$Scope, [bool]$Exists, [string]$Publisher)
    if ($Protected) { return @{ Risk = 'High'; Reason = 'startup.risk.reason.protected' } }
    if (-not $Exists) { return @{ Risk = 'Low'; Reason = 'startup.risk.reason.missing' } }
    if ($Kind -eq 'task') { return @{ Risk = 'Medium'; Reason = 'startup.risk.reason.task' } }
    if ($Scope -eq 'Machine') { return @{ Risk = 'Medium'; Reason = 'startup.risk.reason.machine' } }
    if ([string]::IsNullOrWhiteSpace($Publisher)) { return @{ Risk = 'Medium'; Reason = 'startup.risk.reason.unknown' } }
    return @{ Risk = 'Low'; Reason = 'startup.risk.reason.user' }
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
    # Category: Standard = shown by Task Manager (Run keys, startup folders); Advanced = scheduled tasks and anything else.
    param([string]$Id, [string]$Name, [string]$Command, [string]$Location, [string]$Scope, [bool]$Enabled,
          [string]$ImagePath, [string]$ApprovedPath, [string]$ApprovedValue, [string]$Kind,
          [string]$TaskPath = '', [string]$TaskName = '', [string]$Publisher = $null,
          [bool]$IsSystemTask = $false, [string]$FilePath = '', [bool]$AddedByUs = $false)
    $hostTarget = Get-HostLaunchTarget -ImagePath $ImagePath -Command $Command
    if ($null -eq $Publisher -or $Publisher -eq '') {
        $Publisher = if ($hostTarget) { Get-ImagePublisher -ImagePath $hostTarget } else { Get-ImagePublisher -ImagePath $ImagePath }
    }
    $exists = $false
    if ($ImagePath) { try { $exists = [bool](Test-Path -LiteralPath $ImagePath) } catch { $exists = $false } }
    $reason = Get-StartupProtection -Name $Name -Publisher $Publisher -ImagePath $ImagePath -Command $Command -IsSystemTask $IsSystemTask
    $category = if ($Kind -eq 'run' -or $Kind -eq 'folder') { 'Standard' } else { 'Advanced' }
    $risk = Get-StartupRisk -Protected ([bool]$reason) -Kind $Kind -Scope $Scope -Exists $exists -Publisher ([string]$Publisher)
    if (-not $reason -and $hostTarget -and $risk.Risk -eq 'Low') { $risk = @{ Risk = 'Medium'; Reason = 'startup.risk.reason.host' } }
    [pscustomobject]@{
        Id = $Id; Name = $Name; Publisher = [string]$Publisher; Command = $Command
        Location = $Location; Scope = $Scope; Enabled = $Enabled
        Category = $category
        Protected = [bool]$reason; ProtectReason = [string]$reason
        Risk = [string]$risk.Risk; RiskReason = [string]$risk.Reason
        Impact = (Get-StartupImpactHint -ImagePath $ImagePath)
        ImagePath = $ImagePath; Exists = $exists
        Kind = $Kind; ApprovedPath = $ApprovedPath; ApprovedValue = $ApprovedValue
        TaskPath = $TaskPath; TaskName = $TaskName
        IsSystemTask = $IsSystemTask; FilePath = $FilePath; AddedByUs = $AddedByUs
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

function Get-ShortcutDescription {
    <# Description of a .lnk file ('' when unreadable). #>
    param([string]$LnkPath)
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        return [string]$shell.CreateShortcut($LnkPath).Description
    } catch { return '' } finally {
        if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
}

function Get-UserStartupFolder {
    param([string]$StartupFolder)
    if ($StartupFolder) { return $StartupFolder }
    return [Environment]::GetFolderPath('Startup')
}

function Test-SameFolder {
    param([string]$A, [string]$B)
    try {
        $fa = [IO.Path]::GetFullPath($A).TrimEnd('\'); $fb = [IO.Path]::GetFullPath($B).TrimEnd('\')
        return ($fa -ieq $fb)
    } catch { return $false }
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
    param([string]$Folder, [string]$Location, [string]$Scope, [string]$ApprovedPath, [string]$IdPrefix, [switch]$IsUserFolder)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return $out }
    $shell = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -ieq 'desktop.ini') { continue }
        $cmd = $f.FullName; $img = $f.FullName; $ours = $false
        if ($f.Extension -ieq '.lnk') {
            try {
                if ($null -eq $shell) { $shell = New-Object -ComObject WScript.Shell }
                $lnk = $shell.CreateShortcut($f.FullName)
                if ($lnk.TargetPath) {
                    $img = [string]$lnk.TargetPath
                    $cmd = ('"' + $img + '" ' + [string]$lnk.Arguments).Trim()
                }
                if ($IsUserFolder -and ([string]$lnk.Description -ceq $script:MarkerDescription)) { $ours = $true }
            } catch { }
        }
        $en = Get-ApprovedState -ApprovedPath $ApprovedPath -ValueName $f.Name
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $out.Add((New-StartupItem -Id "$IdPrefix|$($f.Name)" -Name $name -Command $cmd -Location $Location -Scope $Scope -Enabled $en `
            -ImagePath $img -ApprovedPath $ApprovedPath -ApprovedValue $f.Name -Kind 'folder' -FilePath $f.FullName -AddedByUs $ours))
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
            $priv = Test-TaskPrivileged -UserId ([string](Get-SuProp $t.Principal 'UserId' '')) `
                -RunLevel ([string](Get-SuProp $t.Principal 'RunLevel' '')) -LogonType ([string](Get-SuProp $t.Principal 'LogonType' ''))
            $scope = if ($priv) { 'Machine' } else { 'User' }
            $en = ([string]$t.State -ne 'Disabled')
            $out.Add((New-StartupItem -Id ("Task|" + $tp + $t.TaskName) -Name ([string]$t.TaskName) -Command $cmd `
                -Location 'Task' -Scope $scope -Enabled $en -ImagePath $img -ApprovedPath '' -ApprovedValue '' -Kind 'task' `
                -TaskPath $tp -TaskName ([string]$t.TaskName) -IsSystemTask $priv))
        } catch { }
    }
    return $out
}

function Get-StartupItems {
    <# All autostart entries. Overrides for tests: when -RunRoot and/or -StartupFolder is given ONLY those sources are
       scanned (RunRoot as 'HKCU Run', StartupFolder as the user startup folder); states are read from
       <ApprovedRoot>\Run / <ApprovedRoot>\StartupFolder (real HKCU StartupApproved, read-only, when no ApprovedRoot). #>
    param([string]$RunRoot, [string]$ApprovedRoot, [string]$StartupFolder, [switch]$SkipTasks)
    $items = New-Object System.Collections.Generic.List[object]
    if ($RunRoot -or $StartupFolder) {
        if ($RunRoot) {
            $ap = if ($ApprovedRoot) { Join-Path $ApprovedRoot 'Run' } else { Join-Path $script:ApprovedBaseHKCU 'Run' }
            foreach ($i in @(Get-RunKeyItems -RunPath $RunRoot -Location 'HKCU Run' -Scope 'User' -ApprovedPath $ap -IdPrefix 'HKCU-Run')) { $items.Add($i) }
        }
        if ($StartupFolder) {
            $ap = if ($ApprovedRoot) { Join-Path $ApprovedRoot 'StartupFolder' } else { Join-Path $script:ApprovedBaseHKCU 'StartupFolder' }
            foreach ($i in @(Get-FolderItems -Folder $StartupFolder -Location 'HKCU Startup folder' -Scope 'User' `
                -ApprovedPath $ap -IdPrefix 'UserStartup' -IsUserFolder)) { $items.Add($i) }
        }
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
        -ApprovedPath (Join-Path $script:ApprovedBaseHKCU 'StartupFolder') -IdPrefix 'UserStartup' -IsUserFolder)) { $items.Add($i) }
    foreach ($i in @(Get-FolderItems -Folder $commonStartup -Location 'Common Startup folder' -Scope 'Machine' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKLM 'StartupFolder') -IdPrefix 'CommonStartup')) { $items.Add($i) }
    if (-not $SkipTasks) { foreach ($i in @(Get-TaskItems)) { $items.Add($i) } }
    return $items.ToArray()
}

# =====================================================================================
# Set-StartupItemEnabled
# =====================================================================================

function New-StartupResult {
    param([bool]$Ok, [string]$Message, $Item, [bool]$Enabled, [bool]$DryRun = $false, [string]$Reason = '')
    [pscustomobject]@{
        Ok = $Ok; Message = $Message; DryRun = $DryRun; Enabled = $Enabled; Reason = $Reason
        Id = [string](Get-SuProp $Item 'Id' ''); Name = [string](Get-SuProp $Item 'Name' '')
    }
}

function Test-LiveTaskPrivileged {
    <# Re-reads the real task so a tampered item cannot make a SYSTEM/highest task look harmless. #>
    param([string]$TaskPath, [string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        return (Test-TaskPrivileged -UserId ([string](Get-SuProp $t.Principal 'UserId' '')) `
            -RunLevel ([string](Get-SuProp $t.Principal 'RunLevel' '')) -LogonType ([string](Get-SuProp $t.Principal 'LogonType' '')))
    } catch { return $false }
}

function Set-StartupItemEnabled {
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][bool]$Enabled,
          [switch]$DryRun, [string]$ApprovedRoot)
    $kind = [string](Get-SuProp $Item 'Kind' '')
    $name = [string](Get-SuProp $Item 'Name' '')
    if (-not $kind -or -not $name) { return (New-StartupResult -Ok $false -Message 'startup.invalid' -Item $Item -Enabled $Enabled) }

    # Second line of defense: re-evaluate from the data, so a tampered Protected flag cannot bypass it.
    $sysTask = $false
    if ($kind -eq 'task') {
        $sysTask = ([bool](Get-SuProp $Item 'IsSystemTask' $false)) -or ([string](Get-SuProp $Item 'Scope' 'User') -eq 'Machine')
        if (-not $sysTask) {
            $sysTask = Test-LiveTaskPrivileged -TaskPath ([string](Get-SuProp $Item 'TaskPath' '\')) -TaskName ([string](Get-SuProp $Item 'TaskName' ''))
        }
    }
    $reason = Get-StartupProtection -Name $name -Publisher ([string](Get-SuProp $Item 'Publisher' '')) `
        -ImagePath ([string](Get-SuProp $Item 'ImagePath' '')) -Command ([string](Get-SuProp $Item 'Command' '')) -IsSystemTask $sysTask
    if ($sysTask) {
        # system tasks are listed only, in both directions
        return (New-StartupResult -Ok $false -Message 'startup.protected' -Item $Item -Enabled $Enabled -DryRun:$DryRun -Reason 'startup.protect.systemTask')
    }
    if (-not $Enabled) {
        if ($reason -or [bool](Get-SuProp $Item 'Protected' $false)) {
            return (New-StartupResult -Ok $false -Message 'startup.protected' -Item $Item -Enabled $Enabled -DryRun:$DryRun -Reason $reason)
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

# =====================================================================================
# Add-StartupItem / Remove-StartupItem (current user startup folder only; reversible, no admin)
# =====================================================================================

function New-StartupAddResult {
    param([bool]$Ok, [string]$Message, $Item = $null, [bool]$DryRun = $false)
    [pscustomobject]@{ Ok = $Ok; Message = $Message; DryRun = $DryRun; Item = $Item }
}

function Add-StartupItem {
    <# Creates a shortcut (Description = 'Added by Update Center') in the CURRENT USER startup folder.
       Allowed targets: exe, lnk, bat, cmd. Never overwrites an existing shortcut.
       Returns { Ok, Message (i18n key), DryRun, Item }. #>
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Arguments = '', [string]$Name = '',
          [switch]$DryRun, [string]$StartupFolder)
    $target = ''
    try { $target = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))) } catch { $target = '' }
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { return (New-StartupAddResult -Ok $false -Message 'startup.add.notFound') }
    if ([IO.Path]::GetExtension($target) -notmatch '(?i)^\.(exe|lnk|bat|cmd)$') { return (New-StartupAddResult -Ok $false -Message 'startup.add.badType') }

    $label = $Name
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [IO.Path]::GetFileNameWithoutExtension($target) }
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $label = $label.Replace([string]$c, '') }
    $label = $label.Trim().TrimEnd('.')
    if (-not $label) { return (New-StartupAddResult -Ok $false -Message 'startup.add.badType') }

    $folder = Get-UserStartupFolder -StartupFolder $StartupFolder
    $lnkPath = Join-Path $folder ($label + '.lnk')
    if (Test-Path -LiteralPath $lnkPath) { return (New-StartupAddResult -Ok $false -Message 'startup.add.exists') }

    if ($DryRun) {
        $preview = [pscustomobject]@{ Name = $label; FilePath = $lnkPath; Command = (('"' + $target + '" ' + $Arguments).Trim()); AddedByUs = $true; Kind = 'folder'; Category = 'Standard' }
        return (New-StartupAddResult -Ok $true -Message 'startup.dryRun' -Item $preview -DryRun $true)
    }

    $shell = $null
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop) }
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $target
        $lnk.Arguments = [string]$Arguments
        $lnk.WorkingDirectory = [IO.Path]::GetDirectoryName($target)
        $lnk.Description = $script:MarkerDescription
        $lnk.Save()
    } catch {
        Write-Log -Level WARN -Message "Add startup shortcut failed for '$label': $($_.Exception.Message)"
        return (New-StartupAddResult -Ok $false -Message 'startup.add.failed')
    } finally {
        if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
    $item = $null
    foreach ($i in @(Get-FolderItems -Folder $folder -Location 'HKCU Startup folder' -Scope 'User' `
        -ApprovedPath (Join-Path $script:ApprovedBaseHKCU 'StartupFolder') -IdPrefix 'UserStartup' -IsUserFolder)) {
        if ($i.FilePath -ieq $lnkPath) { $item = $i; break }
    }
    if ($null -eq $item) { return (New-StartupAddResult -Ok $false -Message 'startup.add.failed') }
    return (New-StartupAddResult -Ok $true -Message 'startup.add.ok' -Item $item)
}

function Remove-StartupItem {
    <# Removes ONLY shortcuts in the user startup folder whose Description is 'Added by Update Center'
       (moved to the Recycle Bin). The item's own AddedByUs flag is not trusted; the file is re-checked.
       Everything else -> Message 'startup.removeOnlyOwn'. #>
    param([Parameter(Mandatory = $true)]$Item, [switch]$DryRun, [string]$StartupFolder, [switch]$PermanentForTest)
    $deny = { New-StartupResult -Ok $false -Message 'startup.removeOnlyOwn' -Item $Item -Enabled $false -DryRun:$DryRun }
    $fp = [string](Get-SuProp $Item 'FilePath' '')
    if ([string](Get-SuProp $Item 'Kind' '') -ne 'folder' -or -not $fp) { return (& $deny) }
    $folder = Get-UserStartupFolder -StartupFolder $StartupFolder
    $parent = ''
    try { $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fp)) } catch { return (& $deny) }
    if (-not (Test-SameFolder -A $parent -B $folder)) { return (& $deny) }
    if ([IO.Path]::GetExtension($fp) -ine '.lnk') { return (& $deny) }
    if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { return (& $deny) }
    if ((Get-ShortcutDescription -LnkPath $fp) -cne $script:MarkerDescription) { return (& $deny) }

    if ($DryRun) { return (New-StartupResult -Ok $true -Message 'startup.dryRun' -Item $Item -Enabled $false -DryRun $true) }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        # production: Recycle Bin. -PermanentForTest (tests only) deletes for good so nothing lands in the real bin.
        $opt = if ($PermanentForTest) { [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently } else { [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin }
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($fp, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, $opt)
        return (New-StartupResult -Ok $true -Message 'startup.remove.ok' -Item $Item -Enabled $false)
    } catch {
        Write-Log -Level WARN -Message "Remove startup shortcut failed: $($_.Exception.Message)"
        return (New-StartupResult -Ok $false -Message 'startup.remove.failed' -Item $Item -Enabled $false)
    }
}

Export-ModuleMember -Function Get-HostLaunchTarget, Get-StartupItems, Set-StartupItemEnabled, Add-StartupItem, Remove-StartupItem, Get-StartupImpactHint, Get-StartupProtection, Get-StartupRisk, Test-TaskPrivileged, Test-WindowsMicrosoftImage, ConvertFrom-StartupApproved, ConvertTo-StartupApproved, Get-CommandImagePath
