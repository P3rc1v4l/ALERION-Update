# Update Center - safe app uninstaller.
# Lists installed apps (Uninstall registry keys + current-user Store apps), refuses everything that
# could damage Windows or other apps, uninstalls via the vendor's own uninstaller and finds/removes
# leftovers conservatively. Nothing here deletes without an explicit call; -DryRun never changes anything.
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Providers.psm1') -DisableNameChecking

$script:UninstallTimeoutMinutes = 30
$script:MaxLeftoverBytes = [int64]2GB

# =====================================================================================
# Progress helpers
# Contract: the caller passes a synchronized hashtable. We write Percent (0..100, -1 = indeterminate), Text, CanCancel,
# CanPause, Phase; we read Cancel and Pause. $null = no progress, behave as before.
# =====================================================================================

function Set-Prog {
    param($Progress, $Percent = $null, $Text = $null, $CanCancel = $null, $CanPause = $null, $Phase = $null)
    if ($null -eq $Progress) { return }
    try {
        if ($null -ne $Percent) { $Progress['Percent'] = [double]$Percent }
        if ($null -ne $Text) { $Progress['Text'] = [string]$Text }
        if ($null -ne $CanCancel) { $Progress['CanCancel'] = [bool]$CanCancel }
        if ($null -ne $CanPause) { $Progress['CanPause'] = [bool]$CanPause }
        if ($null -ne $Phase) { $Progress['Phase'] = [string]$Phase }
    } catch { }
}

function Test-ProgCancel {
    param($Progress)
    if ($null -eq $Progress) { return $false }
    return ($Progress['Cancel'] -eq $true)
}

function Wait-ProgPause {
    <# Safe point: blocks while Pause is set (and pausing is currently allowed), keeps watching Cancel.
       Returns $true when cancellation was requested. #>
    param($Progress)
    if ($null -eq $Progress) { return $false }
    if ($Progress['Cancel'] -eq $true) { return $true }
    if ($Progress['Pause'] -eq $true -and $Progress['CanPause'] -eq $true) {
        $prev = $Progress['Text']
        Set-Prog $Progress -Text (T 'prog.paused')
        while ($Progress['Pause'] -eq $true -and $Progress['Cancel'] -ne $true) { Start-Sleep -Milliseconds 300 }
        if ($Progress['Cancel'] -eq $true) { return $true }
        if ($null -ne $prev) { Set-Prog $Progress -Text $prev }
    }
    return $false
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

# =====================================================================================
# Small helpers
# =====================================================================================

function Get-Prop {
    <# StrictMode-safe property read: returns $Default when the property does not exist. #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Use-WorkDirs {
    <# Invoke-Process writes its capture files below CacheDir; make sure the folder exists. #>
    try { Initialize-DataDir } catch { Write-Log -Level WARN -Message "Data dir not ready: $($_.Exception.Message)" }
}

function Get-PublisherFromSubject {
    param([string]$Subject)
    $m = [regex]::Match([string]$Subject, 'CN=("([^"]+)"|[^,]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim('"').Trim() }
    return [string]$Subject
}

function ConvertTo-NormalPath {
    <# Full path without trailing backslash (drive roots keep 'C:'). Returns '' for unusable input. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        if (-not [IO.Path]::IsPathRooted($p)) { return '' }
        $p = [IO.Path]::GetFullPath($p)
        return $p.TrimEnd('\')
    } catch { return '' }
}

function Test-PathUnder {
    <# True when $Path is $Root itself or lies inside it (case-insensitive, whole segments only). #>
    param([string]$Path, [string]$Root, [switch]$Strict)
    if (-not $Path -or -not $Root) { return $false }
    $r = $Root.TrimEnd('\')
    if (-not $Strict -and $Path -ieq $r) { return $true }
    return $Path.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

# =====================================================================================
# Protection rules (what must never be uninstalled)
# =====================================================================================

# Shared runtimes / frameworks that other programs depend on.
$script:RuntimePatterns = @(
    'Visual C\+\+.*(Redistributable|Runtime|Minimum|Additional)',
    '^Microsoft Visual C\+\+ (20\d\d|v\d)',
    '\.NET (Runtime|SDK|Core|Framework|Host|AppHost|Targeting|Desktop|Windows|Toolset)',
    '^Microsoft \.NET', 'ASP\.NET', '^\.NET\b', '^Microsoft Windows Desktop Runtime',
    'WebView2', 'DirectX', 'XNA Framework', '^OpenAL', 'Microsoft Visual Studio.*(Runtime|Shared)',
    'Microsoft Visual Studio Tools for Applications', 'Microsoft Silverlight'
)
# Drivers and OEM platform packages.
$script:DriverPatterns = @(
    '^NVIDIA .*(Driver|PhysX|HD Audio|USB|Virtual Audio|Control Panel|Install Application|Container|Update Core|Telemetry|Watchdog|FrameView|Display)',
    '^AMD (Software|Chipset|Radeon|Install Manager|PSP|PCI|SMBus|GPIO|I2C|Ryzen|Settings|Display)',
    '^AMD .*Driver',
    '^Intel\(R\).*(Driver|Chipset|Management Engine|Serial IO|Rapid Storage|Graphics|Wireless|Bluetooth|Ethernet|Thunderbolt|Dynamic Application Loader|Platform)',
    '^Intel .*(Driver|Chipset)',
    'Driver Package', 'Windows Driver', '(?i)\bchipset\b.*(driver|software|device)',
    '^Realtek', '^Synaptics', '^Qualcomm.*(Driver|Wi-?Fi|Bluetooth)', '^MediaTek.*Driver', 'Bluetooth.*Driver'
)
# Parts of Windows itself that show up as normal-looking entries.
$script:WindowsPatterns = @(
    '^Windows (Software Development Kit|SDK|Driver Kit|Assessment|Subsystem|App Runtime|Update|Setup)', '^Windows Kits',
    '^Microsoft Windows\b', '^Microsoft Update Health Tools', '^Microsoft Edge( Update)?$', '^Windows (PC )?Health Check',
    '^Update for Windows', '^Microsoft Visual Studio Installer'
)
$script:UpdatePatterns = @(
    '^(Security Update|Update|Hotfix|Service Pack|Cumulative Update|Update Rollup) for ', '\bKB\d{6,8}\b'
)
# Packages that are part of Windows or serve as frameworks for Store apps.
$script:AppxSystemPattern = '^(Microsoft\.(Windows|VCLibs|UI\.Xaml|NET\.|WindowsStore|DesktopAppInstaller|SecHealthUI|AAD\.|AccountsControl|LockApp|BioEnrollment|CredDialogHost|ECApp|Win32WebViewHost|XboxGameCallableUI|AsyncTextService|Services\.Store|StorePurchaseApp|WebpImageExtension|HEIFImageExtension|VP9VideoExtensions|WebMediaExtensions|RawImageExtension|ApplicationCompatibilityEnhancements|MicrosoftEdge|Edge|OOBE|GamingServices|XboxIdentityProvider|Appconnector)|MicrosoftWindows\.|Windows\.|NcsiUwpApp|InputApp|MicrosoftCorporationII\.WindowsSubsystemForLinux)'

function Get-NameProtection {
    <# Reason code from name/publisher alone ('' = nothing found). Also used as a second line of defense
       inside Invoke-AppUninstall, so a tampered Protected flag cannot bypass it. #>
    param([string]$Name, [string]$Publisher)
    foreach ($p in $script:RuntimePatterns) { if ($Name -match $p) { return 'runtime' } }
    foreach ($p in $script:DriverPatterns)  { if ($Name -match $p) { return 'driver' } }
    foreach ($p in $script:UpdatePatterns)  { if ($Name -match $p) { return 'update-entry' } }
    foreach ($p in $script:WindowsPatterns) { if ($Name -match $p) { return 'windows-component' } }
    if ($Name -match '^(Update Center|ALERION Update)$') { return 'system-component' }
    if ($Publisher -match '^(Realtek|Synaptics)\b') { return 'driver' }
    $kw = '(?i)driver|chipset|compatibility|database|audio|graphics|display|software component|install manager|PhysX|HD Audio|Management Engine|Rapid Storage|Bluetooth|Wi-?Fi|Wireless|Ethernet|\bLAN\b|Thunderbolt|ACPI'
    if (($Publisher -match '(?i)Advanced Micro Devices|\bAMD\b|Intel Corporation|NVIDIA Corporation|Realtek' -or $Name -match '^(AMD|NVIDIA|Intel|Realtek)\b') -and $Name -match $kw) { return 'driver' }
    return ''
}

function Get-EntryProtection {
    <# Reason code for a registry Uninstall entry. Order matters: the most specific signal first. #>
    param($Props, [string]$Name, [string]$Publisher, [bool]$HasUninstaller)
    if ([int](Get-Prop $Props 'SystemComponent' 0) -eq 1) { return 'system-component' }
    if ([int](Get-Prop $Props 'NoRemove' 0) -eq 1) { return 'system-component' }
    if ([string](Get-Prop $Props 'ParentKeyName' '') -or [string](Get-Prop $Props 'ParentDisplayName' '')) { return 'update-entry' }
    if ([string](Get-Prop $Props 'ReleaseType' '') -match '^(Update|Hotfix|Security Update|Update Rollup|Service Pack|Critical Update)$') { return 'update-entry' }
    $r = Get-NameProtection -Name $Name -Publisher $Publisher
    if ($r) { return $r }
    if (-not $HasUninstaller) { return 'no-uninstaller' }
    return ''
}

# =====================================================================================
# Get-InstalledApps
# =====================================================================================

function ConvertTo-AppRecord {
    param($Key, $Name, $Publisher, $Version, $SizeMB, $InstallDate, $Source, $WingetId, $UninstallString, $QuietUninstallString,
          $ProductCode, $AppxFullName, $InstallLocation, $Scope, [bool]$Protected, $ProtectedReason)
    [pscustomobject]@{
        Key = [string]$Key; Name = [string]$Name; Publisher = [string]$Publisher; Version = [string]$Version
        SizeMB = [double]$SizeMB; InstallDate = [string]$InstallDate; Source = [string]$Source; WingetId = [string]$WingetId
        UninstallString = [string]$UninstallString; QuietUninstallString = [string]$QuietUninstallString
        ProductCode = [string]$ProductCode; AppxFullName = [string]$AppxFullName; InstallLocation = [string]$InstallLocation
        Scope = [string]$Scope; Protected = $Protected; ProtectedReason = [string]$ProtectedReason
    }
}

function Get-RegistryApps {
    param($Progress = $null, [double]$PctFrom = 0, [double]$PctTo = 100)
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'machine' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'machine' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'user' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'user' }
    )
    $list = New-Object System.Collections.Generic.List[object]
    $ri = 0; $stop = $false
    foreach ($root in $roots) {
        if ($stop -or ($Progress -and (Wait-ProgPause $Progress))) { break }
        Set-Prog $Progress -Percent ($PctFrom + ($PctTo - $PctFrom) * $ri / $roots.Count) -Text (T 'prog.listRegistry')
        $ri++
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }
        $kc = 0
        foreach ($k in @(Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            $kc++
            if ($Progress -and ($kc % 25) -eq 0 -and (Wait-ProgPause $Progress)) { $stop = $true; break }
            try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
            $name = ([string](Get-Prop $props 'DisplayName' '')).Trim()
            if (-not $name) { continue }
            $publisher = ([string](Get-Prop $props 'Publisher' '')).Trim()
            if ($publisher -match '[\\/]') { $publisher = '' }   # some installers store a path here
            $uninst = ([string](Get-Prop $props 'UninstallString' '')).Trim()
            $quiet = ([string](Get-Prop $props 'QuietUninstallString' '')).Trim()
            $keyName = $k.PSChildName

            # MSI product code: key name is the GUID, or the uninstall command references it.
            $code = ''
            if ($keyName -match '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$' -and
                ([int](Get-Prop $props 'WindowsInstaller' 0) -eq 1 -or $uninst -match '(?i)msiexec')) { $code = $keyName }
            elseif ($uninst -match '(?i)msiexec(\.exe)?"?\s+/[IX]\s*(\{[0-9A-Fa-f-]{36}\})') { $code = $Matches[2] }

            $hasUninstaller = [bool]($uninst -or $quiet -or $code)
            $reason = Get-EntryProtection -Props $props -Name $name -Publisher $publisher -HasUninstaller $hasUninstaller

            $sizeKb = 0.0
            try { $sizeKb = [double](Get-Prop $props 'EstimatedSize' 0) } catch { }
            $date = [string](Get-Prop $props 'InstallDate' '')
            if ($date -match '^(\d{4})(\d{2})(\d{2})$') { $date = "$($Matches[1])-$($Matches[2])-$($Matches[3])" }

            $list.Add((ConvertTo-AppRecord -Key $k.PSPath.Replace('Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE', 'HKLM:').Replace('Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER', 'HKCU:') `
                -Name $name -Publisher $publisher -Version (Get-Prop $props 'DisplayVersion' '') -SizeMB ([Math]::Round($sizeKb / 1024, 1)) `
                -InstallDate $date -Source $(if ($code) { 'msi' } else { 'exe' }) -WingetId '' -UninstallString $uninst -QuietUninstallString $quiet `
                -ProductCode $code -AppxFullName '' -InstallLocation (Get-Prop $props 'InstallLocation' '') -Scope $root.Scope `
                -Protected ([bool]$reason) -ProtectedReason $reason))
        }
    }
    return $list.ToArray()
}

function Get-StoreStartMap {
    <# PackageFamilyName -> friendly Start menu name. Empty map when Get-StartApps is unavailable. #>
    $map = @{}
    try {
        foreach ($sa in @(Get-StartApps -ErrorAction Stop)) {
            $id = [string]$sa.AppID
            if ($id -match '^([^!\\]+)!') {
                $fam = $Matches[1]
                if (-not $map.ContainsKey($fam)) { $map[$fam] = [string]$sa.Name }
            }
        }
    } catch { Write-Log -Level WARN -Message "Get-StartApps failed: $($_.Exception.Message)" }
    return $map
}

function Get-AppxManifestText {
    <# DisplayName / PublisherDisplayName from the manifest; '' for ms-resource: references. #>
    param([string]$FullName)
    $r = @{ DisplayName = ''; Publisher = '' }
    try {
        $m = Get-AppxPackageManifest -Package $FullName -ErrorAction Stop
        $props = $m.Package.Properties
        foreach ($pair in @(@('DisplayName', 'DisplayName'), @('PublisherDisplayName', 'Publisher'))) {
            $v = [string](Get-Prop $props $pair[0] '')
            if ($v -and $v -notmatch '^ms-resource:') { $r[$pair[1]] = $v.Trim() }
        }
    } catch { }
    return $r
}

function Get-StoreApps {
    param($Progress = $null, [double]$PctFrom = 0, [double]$PctTo = 100)
    $list = New-Object System.Collections.Generic.List[object]
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) } catch { Write-Log -Level WARN -Message "Get-AppxPackage failed: $($_.Exception.Message)"; return @() }
    $startMap = Get-StoreStartMap
    $pi = 0
    foreach ($p in $pkgs) {
        $pi++
        if ($Progress) {
            if (Wait-ProgPause $Progress) { break }
            if (($pi % 5) -eq 0) { Set-Prog $Progress -Percent ($PctFrom + ($PctTo - $PctFrom) * $pi / [Math]::Max(1, $pkgs.Count)) -Text (T 'prog.listStore') }
        }
        if ([bool](Get-Prop $p 'IsResourcePackage' $false)) { continue }
        $raw = [string]$p.Name
        $reason = ''
        if ([bool](Get-Prop $p 'IsFramework' $false)) { $reason = 'framework' }
        elseif ([bool](Get-Prop $p 'NonRemovable' $false)) { $reason = 'windows-component' }
        elseif ([string](Get-Prop $p 'SignatureKind' '') -eq 'System') { $reason = 'windows-component' }
        elseif ($raw -match $script:AppxSystemPattern) { $reason = 'windows-component' }
        $fam = [string](Get-Prop $p 'PackageFamilyName' '')
        $hasStart = ($fam -and $startMap.ContainsKey($fam))
        # Packages without a Start menu entry are background parts of Windows or other apps.
        if (-not $reason -and $startMap.Count -gt 0 -and -not $hasStart) { $reason = 'windows-component' }
        $man = Get-AppxManifestText -FullName ([string]$p.PackageFullName)
        $name = if ($hasStart) { $startMap[$fam] } elseif ($man.DisplayName) { $man.DisplayName } else { $raw }
        $list.Add((ConvertTo-AppRecord -Key ('appx:' + $p.PackageFullName) -Name $name -Publisher $man.Publisher `
            -Version ([string]$p.Version) -SizeMB 0 -InstallDate '' -Source 'store' -WingetId '' -UninstallString '' -QuietUninstallString '' `
            -ProductCode '' -AppxFullName ([string]$p.PackageFullName) -InstallLocation ([string](Get-Prop $p 'InstallLocation' '')) `
            -Scope 'user' -Protected ([bool]$reason) -ProtectedReason $reason))
    }
    return $list.ToArray()
}

function Add-WingetIds {
    <# Fills WingetId for registry apps that `winget list` reports with a real repository id.
       ARP\/MSIX\ pseudo ids and msstore packages are ignored on purpose. #>
    param([object[]]$Apps)
    $winget = Get-WingetPath
    if (-not $winget) { return }
    Use-WorkDirs
    try { $r = Invoke-Process -FilePath $winget -ArgumentList @('list', '--accept-source-agreements', '--disable-interactivity') -TimeoutMinutes 5 }
    catch { Write-Log -Level WARN -Message "winget list failed: $($_.Exception.Message)"; return }
    if ($r.TimedOut) { return }
    $rows = @(ConvertFrom-WingetListTable -Text $r.Output | Where-Object { $_.Source -eq 'winget' -and $_.Id -notmatch '[\\]' -and $_.Id -notmatch '[\u2026]|\.\.\.$' })
    foreach ($row in $rows) {
        $rn = $row.Name.TrimEnd([char]0x2026, '.').Trim()
        $hits = @($Apps | Where-Object { $_.Source -ne 'store' -and -not $_.WingetId -and $_.Name.StartsWith($rn, [StringComparison]::OrdinalIgnoreCase) -and ($_.Name.Length -eq $row.Name.Length -or $row.Name.EndsWith([string][char]0x2026) -or $row.Name.EndsWith('...')) })
        # Several different registry entries with the same name: ambiguous, do not guess.
        if ($hits.Count -eq 1) {
            $app = $hits[0]
            $app.WingetId = $row.Id
            if ($app.Source -eq 'exe' -or $app.Source -eq 'msi') { $app.Source = 'winget' }
        }
    }
}

function Get-InstalledApps {
    <# All uninstallable-looking programs. Protected entries are returned too (Protected=$true) so the GUI can
       show them greyed out - they can never be uninstalled through Invoke-AppUninstall. #>
    param([switch]$SkipWinget, [hashtable]$Progress = $null, [double]$PctFrom = 0, [double]$PctTo = 100)
    $all = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    # Sources: registry (40 %), Store (45 %), winget ids (15 %; one external call, cannot be interrupted).
    $span = $PctTo - $PctFrom
    $wingetShare = if ($SkipWinget) { 0.0 } else { 0.15 }
    $regEnd = $PctFrom + $span * 0.40 * (1.0 - $wingetShare) / 0.85
    $storeEnd = $PctFrom + $span * (1.0 - $wingetShare)
    Set-Prog $Progress -Percent $PctFrom -Text (T 'prog.listRegistry') -CanCancel $true -CanPause $true -Phase 'scan'
    $regApps = @(Get-RegistryApps -Progress $Progress -PctFrom $PctFrom -PctTo $regEnd)
    $storeApps = @()
    if (-not (Test-ProgCancel $Progress)) { $storeApps = @(Get-StoreApps -Progress $Progress -PctFrom $regEnd -PctTo $storeEnd) }
    foreach ($a in ($regApps + $storeApps)) {
        # 32/64-bit duplicates and user/machine duplicates: first one wins (64-bit machine is listed first).
        $id = ('{0}|{1}|{2}' -f $a.Name, $a.Version, $a.Publisher).ToLowerInvariant()
        if ($a.Source -ne 'store' -and $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $all.Add($a)
    }
    $arr = $all.ToArray()
    if ($Progress -and (Test-ProgCancel $Progress)) {
        Set-Prog $Progress -Text (T 'prog.cancelled') -CanCancel $false -CanPause $false
        return @($arr | Sort-Object Name)   # partial list: caller knows it cancelled
    }
    if (-not $SkipWinget) {
        Set-Prog $Progress -Percent $storeEnd -Text (T 'prog.listWinget') -CanCancel $false -CanPause $false
        Add-WingetIds -Apps $arr
    }
    Set-Prog $Progress -Percent $PctTo
    if ($PctTo -ge 100) { Set-Prog $Progress -Text (T 'prog.done') -CanCancel $false -CanPause $false }
    return @($arr | Sort-Object Name)
}

# =====================================================================================
# Uninstall
# =====================================================================================

function New-UninstallResult {
    param($App, [string]$Status, $ExitCode = $null, [string]$Message = '', [bool]$RebootRequired = $false)
    [pscustomobject]@{
        Key = [string](Get-Prop $App 'Key' ''); Name = [string](Get-Prop $App 'Name' ''); Status = $Status
        ExitCode = $ExitCode; Message = $Message; RebootRequired = $RebootRequired
    }
}

function Split-CommandLine {
    <# Splits '"C:\x y\unins.exe" /S' or 'C:\x\unins.exe /S' into exe + argument string. #>
    param([string]$Command)
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) { return [pscustomobject]@{ Exe = $c.Substring(1, $end - 1); Args = $c.Substring($end + 1).Trim() } }
    }
    $m = [regex]::Match($c, '^(.+?\.(exe|bat|cmd|com))(\s+|$)(.*)$', 'IgnoreCase')
    if ($m.Success) { return [pscustomobject]@{ Exe = $m.Groups[1].Value; Args = $m.Groups[4].Value.Trim() } }
    $parts = $c -split '\s+', 2
    return [pscustomobject]@{ Exe = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Test-SafeUninstallExe {
    <# Uninstall commands come from the registry (HKCU can be written by any user process). Interpreters and
       script hosts are not accepted as uninstallers. #>
    param([string]$Exe)
    if (-not $Exe -or -not [IO.Path]::IsPathRooted($Exe)) { return $false }
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $false }
    $leaf = [IO.Path]::GetFileName($Exe).ToLowerInvariant()
    if ($leaf -in @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'regsvr32.exe', 'rundll32.exe', 'wmic.exe', 'bash.exe')) { return $false }
    return ($leaf -match '\.(exe|com)$')
}

function Start-UninstallProcess {
    <# Starts the uninstaller with a raw argument string (no re-quoting) and waits with a timeout.
       Output is not captured: vendor wizards must be free to show a window and cannot deadlock on a pipe. #>
    param([Parameter(Mandatory)][string]$Exe, [string]$Arguments = '', [switch]$Hidden, [int]$TimeoutMinutes = 30, $Progress = $null, [string]$Label = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = [bool]$Hidden
    $dir = Split-Path -Parent $Exe
    if ($dir -and (Test-Path -LiteralPath $dir)) { $psi.WorkingDirectory = $dir }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -ne 740) { throw }
        # Installer manifest demands elevation and we are not elevated: let Windows ask (UAC).
        $psi.UseShellExecute = $true; $psi.Verb = 'runas'; $psi.CreateNoWindow = $false
        $p = [System.Diagnostics.Process]::Start($psi)
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $limitMs = $TimeoutMinutes * 60 * 1000
    $done = $false
    if ($Progress) {
        # Report elapsed time once a second while the vendor uninstaller runs (it cannot be cancelled safely).
        while (-not ($done = $p.WaitForExit(1000)) -and $clock.ElapsedMilliseconds -lt $limitMs) {
            Set-Prog $Progress -Text (T 'prog.uninstallingElapsed' @($Label, (Format-Elapsed $clock.Elapsed)))
        }
    } else {
        $done = $p.WaitForExit($limitMs)
    }
    if ($done) {
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; TimedOut = $false }
    }
    try { $p.Kill() } catch { }
    return [pscustomobject]@{ ExitCode = -999; TimedOut = $true }
}

function Test-AppPresent {
    param($App)
    $full = [string](Get-Prop $App 'AppxFullName' '')
    if ($full) {
        $n = ($full -split '_')[0]
        return (@(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $full }).Count -gt 0)
    }
    $key = [string](Get-Prop $App 'Key' '')
    if ($key -match '^HK(LM|CU):') { return (Test-Path -LiteralPath $key) }
    return $false
}

function Wait-AppGone {
    <# Uninstallers often finish asynchronously; poll briefly before judging. #>
    param($App, [int]$Seconds = 20)
    $end = (Get-Date).AddSeconds($Seconds)
    do {
        if (-not (Test-AppPresent -App $App)) { return $true }
        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $end)
    return (-not (Test-AppPresent -App $App))
}

function ConvertTo-ExitInfo {
    <# Maps an exit code to Ok / Reboot flags. msiexec: 0 ok, 1605 not installed, 1641/3010 ok + restart.
       winget: 0x8A150109 = restart needed. #>
    param([int]$Code)
    $reboot = ($Code -in @(1641, 3010, -1978334967))
    [pscustomobject]@{ Ok = ($Code -eq 0 -or $reboot -or $Code -eq 1605); Reboot = $reboot }
}

function Get-UninstallPlan {
    <# Ordered list of ways to remove this app: winget -> MSI -> quiet string -> plain string -> AppX. #>
    param($App)
    $plan = New-Object System.Collections.Generic.List[object]
    $wid = [string](Get-Prop $App 'WingetId' '')
    $code = [string](Get-Prop $App 'ProductCode' '')
    $quiet = [string](Get-Prop $App 'QuietUninstallString' '')
    $un = [string](Get-Prop $App 'UninstallString' '')
    $full = [string](Get-Prop $App 'AppxFullName' '')

    if ($wid -match '^[A-Za-z0-9_.+\-]+$') { $plan.Add([pscustomobject]@{ Type = 'winget'; Value = $wid; Text = "winget uninstall $wid" }) }
    if ($code -match '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') { $plan.Add([pscustomobject]@{ Type = 'msi'; Value = $code; Text = "msiexec /x $code /qn /norestart" }) }
    # An 'MsiExec /I{...}' command is the Add/Remove entry of an MSI - already handled through its product code.
    if ($quiet -and $quiet -notmatch '(?i)msiexec') { $plan.Add([pscustomobject]@{ Type = 'quiet'; Value = $quiet; Text = 'QuietUninstallString' }) }
    if ($un -and $un -notmatch '(?i)msiexec') { $plan.Add([pscustomobject]@{ Type = 'string'; Value = $un; Text = 'UninstallString (vendor wizard)' }) }
    if ($full) { $plan.Add([pscustomobject]@{ Type = 'appx'; Value = $full; Text = 'Remove-AppxPackage' }) }
    return $plan.ToArray()
}

function Invoke-AppUninstall {
    <# Removes one app. Protected apps are always refused. The result is verified against the registry / package
       list afterwards. The vendor's own uninstaller may show its wizard (UninstallString fallback). #>
    param([Parameter(Mandatory)]$App, [switch]$DryRun, [hashtable]$Progress = $null, [switch]$RestorePoint)
    $name = [string](Get-Prop $App 'Name' '')
    if ([bool](Get-Prop $App 'Protected' $false)) {
        return New-UninstallResult -App $App -Status 'Skipped' -Message ('protected:' + (Get-Prop $App 'ProtectedReason' 'unknown'))
    }
    # Second line of defense: do not trust the Protected flag alone (object may come from the GUI / a file).
    $nameReason = Get-NameProtection -Name $name -Publisher ([string](Get-Prop $App 'Publisher' ''))
    if ($nameReason) { return New-UninstallResult -App $App -Status 'Skipped' -Message ('protected:' + $nameReason) }
    $full = [string](Get-Prop $App 'AppxFullName' '')
    if ($full -and (($full -split '_')[0] -match $script:AppxSystemPattern)) {
        return New-UninstallResult -App $App -Status 'Skipped' -Message 'protected:windows-component'
    }

    $plan = @(Get-UninstallPlan -App $App)
    if ($plan.Count -eq 0) { return New-UninstallResult -App $App -Status 'Skipped' -Message 'protected:no-uninstaller' }

    if ($DryRun) {
        return New-UninstallResult -App $App -Status 'WouldRemove' -Message ('method: ' + $plan[0].Text)
    }
    if (-not (Test-AppPresent -App $App)) {
        return New-UninstallResult -App $App -Status 'Skipped' -Message 'not-installed'
    }

    Use-WorkDirs
    $reboot = $false
    $last = ''
    $lastCode = $null
    $stepNo = 0
    # Phases: restorepoint (optional, cancel allowed) -> uninstall (vendor uninstaller: not cancellable) -> verify -> done.
    if ($Progress) {
        Set-Prog $Progress -Percent 0 -CanCancel $true -CanPause $false -Phase 'restorepoint' -Text (T 'prog.startUninstall' @($name))
        if (Test-ProgCancel $Progress) { return New-UninstallResult -App $App -Status 'Cancelled' -Message 'prog.cancelled' }
    }
    if ($RestorePoint) {
        Set-Prog $Progress -Percent -1 -Phase 'restorepoint' -Text (T 'prog.restorepoint')
        try { [void](New-RestorePoint) } catch { Write-Log -Level WARN -Message "Restore point failed: $($_.Exception.Message)" }
        # Checkpoint-Computer itself cannot be interrupted; a cancel that arrived meanwhile stops before the uninstall.
        if (Test-ProgCancel $Progress) { return New-UninstallResult -App $App -Status 'Cancelled' -Message 'prog.cancelled' }
    }
    foreach ($step in $plan) {
        if ($stepNo -gt 0 -and $Progress) {
            # Between fallback methods nothing is running: cancelling is safe again.
            Set-Prog $Progress -CanCancel $true -Phase 'uninstall' -Text (T 'prog.nextMethod' @($name))
            if (Test-ProgCancel $Progress) { return New-UninstallResult -App $App -Status 'Cancelled' -ExitCode $lastCode -Message 'prog.cancelled' -RebootRequired $reboot }
        }
        $stepNo++
        Set-Prog $Progress -Percent -1 -CanCancel $false -CanPause $false -Phase 'uninstall' -Text (T 'prog.uninstalling' @($name))
        Write-Log -Message "Uninstall '$name' via $($step.Text)"
        $code = $null
        $note = ''
        try {
            switch ($step.Type) {
                'winget' {
                    $winget = Get-WingetPath
                    if (-not $winget) { $last = 'winget-missing'; continue }
                    $r = Invoke-Process -FilePath $winget -ArgumentList @('uninstall', '--id', $step.Value, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity') -TimeoutMinutes $script:UninstallTimeoutMinutes
                    $code = $r.ExitCode; if ($r.TimedOut) { return New-UninstallResult -App $App -Status 'Failed' -ExitCode $code -Message 'timeout' }
                }
                'msi' {
                    $msi = Join-Path $env:SystemRoot 'System32\msiexec.exe'
                    $r = Start-UninstallProcess -Exe $msi -Arguments ('/x ' + $step.Value + ' /qn /norestart') -Hidden -TimeoutMinutes $script:UninstallTimeoutMinutes -Progress $Progress -Label $name
                    $code = $r.ExitCode; if ($r.TimedOut) { return New-UninstallResult -App $App -Status 'Failed' -ExitCode $code -Message 'timeout' }
                }
                { $_ -in 'quiet', 'string' } {
                    $cl = Split-CommandLine -Command $step.Value
                    if (-not (Test-SafeUninstallExe -Exe $cl.Exe)) { $last = 'unsafe-or-missing-uninstaller'; continue }
                    $hidden = ($step.Type -eq 'quiet')
                    $r = Start-UninstallProcess -Exe $cl.Exe -Arguments $cl.Args -Hidden:$hidden -TimeoutMinutes $script:UninstallTimeoutMinutes -Progress $Progress -Label $name
                    $code = $r.ExitCode; if ($r.TimedOut) { return New-UninstallResult -App $App -Status 'Failed' -ExitCode $code -Message 'timeout' }
                    if ($step.Type -eq 'string') { $note = ' (vendor uninstaller, may have shown its own window)' }
                }
                'appx' {
                    Remove-AppxPackage -Package $step.Value -ErrorAction Stop
                    $code = 0
                }
            }
        } catch {
            $last = "error: $($_.Exception.Message)"
            Write-Log -Level WARN -Message "Uninstall step $($step.Type) failed for '$name': $($_.Exception.Message)"
            continue
        }
        if ($null -eq $code) { continue }
        $lastCode = $code
        $info = ConvertTo-ExitInfo -Code ([int]$code)
        if ($info.Reboot) { $reboot = $true }
        Set-Prog $Progress -Percent -1 -CanCancel $false -CanPause $false -Phase 'verify' -Text (T 'prog.verifying' @($name))
        if (Wait-AppGone -App $App) {
            Write-Log -Level OK -Message "Uninstalled '$name' via $($step.Type) (exit $code)"
            Set-Prog $Progress -Percent 100 -Text (T 'prog.done')
            return New-UninstallResult -App $App -Status 'Removed' -ExitCode $code -Message ("via $($step.Text)$note") -RebootRequired $reboot
        }
        $last = if ($info.Ok) { 'still-installed' } else { "exit-code-$code ($($step.Type))" }
        # User cancelled the vendor wizard (MSI 1602/1223 style): do not start yet another uninstaller.
        if ([int]$code -in @(1602, 1223)) { $last = 'cancelled'; break }
    }
    Write-Log -Level ERROR -Message "Uninstall of '$name' failed: $last"
    Set-Prog $Progress -Percent 100 -CanCancel $false -CanPause $false -Text (T 'prog.done')
    return New-UninstallResult -App $App -Status 'Failed' -ExitCode $lastCode -Message $(if ($last) { $last } else { 'no-usable-method' }) -RebootRequired $reboot
}

# =====================================================================================
# Leftovers
# =====================================================================================

# First-level folder / key names that are shared roots or too generic to ever be offered for deletion.
$script:GenericNames = @(
    'common files', 'microsoft', 'microsoft shared', 'windows', 'windows nt', 'windowsapps', 'windows defender', 'intel', 'nvidia',
    'nvidia corporation', 'amd', 'ati', 'google', 'mozilla', 'apple', 'adobe', 'oracle', 'java', 'realtek', 'dell', 'hp', 'lenovo',
    'asus', 'msi', 'logitech', 'steam', 'epic games', 'valve', 'ubisoft', 'electronic arts', 'microsoft office', 'temp', 'tmp',
    'cache', 'programs', 'packages', 'data', 'config', 'settings', 'setup', 'install', 'installer', 'update', 'updates', 'drivers',
    'system32', 'syswow64', 'users', 'default', 'public', 'app', 'apps', 'bin', 'lib', 'software', 'classes', 'policies',
    'wow6432node', 'clients', 'registeredapplications', 'uninstall', 'run', 'microsoft games', 'modifiableqwindowsapps', 'internet explorer',
    'windows mail', 'windows media player', 'windows photo viewer', 'windows security', 'dotnet', 'reference assemblies', 'msbuild'
)
# Publishers whose registry/folder space is Windows itself.
$script:SystemVendors = @('microsoft', 'microsoft corporation', 'windows', 'microsoft windows')

function Get-KnownRoots {
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
    $roots = @($pf, $pf86, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA)
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Programs') }
    return @($roots | Where-Object { $_ } | ForEach-Object { ConvertTo-NormalPath $_ } | Where-Object { $_ } | Select-Object -Unique)
}

function Test-ProtectedFolderPath {
    <# Static hard block, independent of any app: returns a reason code for paths that must never be deleted. #>
    param([string]$Path)
    $p = ConvertTo-NormalPath $Path
    if (-not $p) { return 'invalid-path' }
    if ($p -match '^[A-Za-z]:$') { return 'drive-root' }
    if ($p -match '^\\\\') { return 'network-path' }
    $win = ConvertTo-NormalPath $env:SystemRoot
    if (Test-PathUnder $p $win) { return 'windows-folder' }
    $prof = ConvertTo-NormalPath $env:USERPROFILE
    $exact = @(
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
        $env:PUBLIC, ($env:SystemDrive + '\Users'), (Join-Path $env:LOCALAPPDATA 'Programs'), (Join-Path $env:ProgramFiles 'Common Files'),
        (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Pictures'), (Join-Path $env:USERPROFILE 'Music'), (Join-Path $env:USERPROFILE 'Videos'),
        (Join-Path $env:USERPROFILE 'AppData'), (Join-Path $env:USERPROFILE 'AppData\LocalLow')
    )
    foreach ($e in $exact) { if ($e -and ($p -ieq (ConvertTo-NormalPath $e))) { return 'system-root' } }
    # Direct children of the profile are the user's own folders (Desktop, Documents, ...), never app leftovers.
    if ($prof -and ($p -ieq $prof -or ((Split-Path -Parent $p) -ieq $prof))) { return 'user-profile' }
    $areas = @(
        (Join-Path $env:ProgramFiles 'WindowsApps'), (Join-Path $env:ProgramFiles 'Common Files'), (Join-Path $env:ProgramFiles 'Windows NT'),
        (Join-Path $env:ProgramFiles 'Windows Defender'), (Join-Path $env:ProgramFiles 'Microsoft'), (Join-Path $env:ProgramFiles 'Microsoft Office'),
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft'), (Join-Path ${env:ProgramFiles(x86)} 'Windows NT'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Defender'), (Join-Path $env:ProgramData 'Microsoft'), (Join-Path $env:ProgramData 'Packages'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft'), (Join-Path $env:LOCALAPPDATA 'Packages'), (Join-Path $env:APPDATA 'Microsoft'),
        ($env:SystemDrive + '\System Volume Information'), ($env:SystemDrive + '\$Recycle.Bin'), ($env:SystemDrive + '\Recovery'), ($env:SystemDrive + '\Boot')
    )
    foreach ($a in $areas) { if ($a -and (Test-PathUnder $p (ConvertTo-NormalPath $a))) { return 'system-area' } }
    # Never touch this tool itself.
    $ap = Get-AppPaths
    foreach ($self in @($ap.AppRoot, $ap.DataDir)) { if ($self -and (Test-PathUnder $p (ConvertTo-NormalPath $self))) { return 'update-center' } }
    return ''
}

function Test-ProtectedRegistryPath {
    <# Only HKCU:\Software\<Publisher>\<App> and HKLM:\SOFTWARE\[WOW6432Node\]<Publisher>\<App> (exactly two levels or more) are
       ever deletable, and never below Microsoft/Windows or generic vendor roots. #>
    param([string]$Path)
    $m = [regex]::Match([string]$Path, '^(HKCU|HKLM):\\software\\(.+)$', 'IgnoreCase')
    if (-not $m.Success) { return 'unsupported-hive' }
    $parts = @($m.Groups[2].Value.TrimEnd('\') -split '\\')
    if ($parts.Count -gt 0 -and $parts[0] -ieq 'WOW6432Node') { $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -lt 2) { return 'vendor-root' }
    if ($script:SystemVendors -contains $parts[0].ToLowerInvariant()) { return 'system-vendor' }
    if ($parts[0] -match '(?i)^(classes|policies|clients|registeredapplications|windows|microsoft|wow6432node)$') { return 'system-area' }
    if ($script:GenericNames -contains $parts[1].ToLowerInvariant()) { return 'generic-name' }
    return ''
}

function Get-FolderSizeBytes {
    <# Sums file sizes without following junctions; stops as soon as the cap is exceeded. #>
    param([string]$Path, [int64]$Cap)
    $total = [int64]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                try { $total += (New-Object IO.FileInfo($f)).Length } catch { }
                if ($total -gt $Cap) { return $total }
            }
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
                try { if (([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue } } catch { continue }
                $stack.Push($d)
            }
        } catch { }
    }
    return $total
}

function Get-FolderRisk {
    <# Returns the first reason why a folder must NOT be offered as safe ('' = safe) plus its size. #>
    param([string]$Path, [string]$AppName, [string[]]$OtherLocations, [string[]]$ServicePaths)
    $out = [pscustomobject]@{ Risk = ''; SizeMB = 0.0 }
    $hard = Test-ProtectedFolderPath -Path $Path
    if ($hard) { $out.Risk = $hard; return $out }
    try { if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $out.Risk = 'reparse-point'; return $out } } catch { }
    $leaf = (Split-Path -Leaf $Path).ToLowerInvariant()
    if ($script:GenericNames -contains $leaf -or $leaf.Length -lt 3) { $out.Risk = 'generic-name'; return $out }
    if ($script:GenericNames -contains $AppName.ToLowerInvariant() -or $AppName.Trim().Length -lt 3) { $out.Risk = 'generic-name'; return $out }
    # A folder directly on a drive root is only acceptable when it carries exactly the app's name.
    $parent = Split-Path -Parent $Path
    if ($parent -match '^[A-Za-z]:\\?$' -and (Split-Path -Leaf $Path) -ine $AppName) { $out.Risk = 'generic-location'; return $out }
    foreach ($loc in $OtherLocations) {
        if (-not $loc) { continue }
        if (Test-PathUnder $loc $Path) { $out.Risk = 'shared-with-installed-app'; return $out }
        if (Test-PathUnder $Path $loc -Strict) { $out.Risk = 'inside-installed-app'; return $out }
    }
    foreach ($sp in $ServicePaths) {
        if ($sp -and $sp.IndexOf($Path + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out.Risk = 'used-by-service'; return $out }
    }
    $bytes = Get-FolderSizeBytes -Path $Path -Cap $script:MaxLeftoverBytes
    $out.SizeMB = [Math]::Round($bytes / 1MB, 1)
    if ($bytes -gt $script:MaxLeftoverBytes) { $out.Risk = 'too-large' }
    return $out
}

function Get-ShortcutTarget {
    param([string]$Lnk)
    try {
        $sh = New-Object -ComObject WScript.Shell
        try { return [string]$sh.CreateShortcut($Lnk).TargetPath } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    } catch { return $null }
}

function Find-AppLeftovers {
    <# Conservative leftover search. Only call after the uninstall. Items with Safe=$false are shown for information
       only and are never removed by Remove-AppLeftovers. #>
    param([Parameter(Mandatory)]$App, [object[]]$InstalledApps, [hashtable]$Progress = $null)
    $name = ([string](Get-Prop $App 'Name' '')).Trim()
    $publisher = ([string](Get-Prop $App 'Publisher' '')).Trim()
    $key = [string](Get-Prop $App 'Key' '')
    $items = New-Object System.Collections.Generic.List[object]
    if (-not $name) { return @() }

    # With progress: listing the installed apps takes the first 30 %, the search itself the rest (percent by roots scanned).
    $cancelled = $false
    Set-Prog $Progress -Percent 0 -Text (T 'prog.leftoverSearch') -CanCancel $true -CanPause $true -Phase 'leftovers'
    if ($null -eq $InstalledApps) {
        $InstalledApps = @(Get-InstalledApps -SkipWinget -Progress $Progress -PctFrom 0 -PctTo 30)
        Set-Prog $Progress -CanCancel $true -CanPause $true -Phase 'leftovers'
    } else { Set-Prog $Progress -Percent 30 }
    if (Test-ProgCancel $Progress) { Set-Prog $Progress -Text (T 'prog.cancelled'); return @() }
    $others = @($InstalledApps | Where-Object { $_.Key -ne $key })
    $otherLocs = @($others | ForEach-Object { ConvertTo-NormalPath ([string](Get-Prop $_ 'InstallLocation' '')) } | Where-Object { $_ })
    $svcPaths = @()
    try { $svcPaths = @(Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object { [string]$_.PathName } | Where-Object { $_ }) } catch { }

    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $safeName = ($name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { [string]$_ } }) -join ''
    $safePub = ($publisher.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { [string]$_ } }) -join ''
    $sysVendor = ($script:SystemVendors -contains $publisher.ToLowerInvariant())

    $addFolder = {
        param([string]$Path, [string]$OkReason)
        $p = ConvertTo-NormalPath $Path
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { return }
        if (@($items | Where-Object { $_.Path -ieq $p }).Count -gt 0) { return }
        $risk = Get-FolderRisk -Path $p -AppName $name -OtherLocations $otherLocs -ServicePaths $svcPaths
        if (-not $risk.Risk -and $sysVendor) { $risk.Risk = 'system-vendor' }
        $items.Add([pscustomobject]@{ Type = 'Folder'; Path = $p; SizeMB = $risk.SizeMB; Safe = (-not $risk.Risk); Reason = $(if ($risk.Risk) { $risk.Risk } else { $OkReason }) })
    }

    $knownRoots = @(Get-KnownRoots)
    $regKeys = @()
    if ($publisher) { $regKeys = @("HKCU:\Software\$publisher\$name", "HKLM:\SOFTWARE\$publisher\$name", "HKLM:\SOFTWARE\WOW6432Node\$publisher\$name") }
    $menus = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
    $stepTotal = 1 + $knownRoots.Count + $regKeys.Count + $menus.Count
    $st = @{ Done = 0 }
    # Safe point + percent per scanned root; returns $true when cancelled.
    $step = {
        param([string]$What)
        if (Wait-ProgPause $Progress) { return $true }
        Set-Prog $Progress -Percent (30.0 + 70.0 * $st.Done / $stepTotal) -Text (T 'prog.leftoverScan' @($What))
        $st.Done++
        return $false
    }

    $loc = ConvertTo-NormalPath ([string](Get-Prop $App 'InstallLocation' ''))
    if ($Progress) { $cancelled = [bool](& $step 'install') }
    if (-not $cancelled -and $loc) { & $addFolder $loc 'install-location' }

    foreach ($root in $knownRoots) {
        if ($cancelled) { break }
        if ($Progress) { $cancelled = [bool](& $step $root); if ($cancelled) { break } }
        & $addFolder (Join-Path $root $safeName) 'app-folder'
        if ($safePub) { & $addFolder (Join-Path (Join-Path $root $safePub) $safeName) 'vendor-app-folder' }
    }

    # Registry: Software\Publisher\AppName only (needs a publisher; the vendor key itself is never offered).
    if ($publisher -and -not $cancelled) {
        foreach ($rk in $regKeys) {
            if ($Progress) { $cancelled = [bool](& $step 'registry'); if ($cancelled) { break } }
            if ($rk -match '[\*\?\[\]]') { continue }
            if (-not (Test-Path -LiteralPath $rk)) { continue }
            $why = Test-ProtectedRegistryPath -Path $rk
            if (-not $why -and $sysVendor) { $why = 'system-vendor' }
            $items.Add([pscustomobject]@{ Type = 'RegistryKey'; Path = $rk; SizeMB = 0.0; Safe = (-not $why); Reason = $(if ($why) { $why } else { 'app-registry-key' }) })
        }
    }

    # Start menu shortcuts of this app whose target no longer exists.
    foreach ($menu in $(if ($cancelled) { @() } else { $menus })) {
        if ($Progress) { $cancelled = [bool](& $step 'shortcuts'); if ($cancelled) { break } }
        if (-not (Test-Path -LiteralPath $menu)) { continue }
        $lnks = @(Get-ChildItem -LiteralPath $menu -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
        $dirs = @(Get-ChildItem -LiteralPath $menu -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $safeName })
        foreach ($d in $dirs) { $lnks += @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.lnk' -File -ErrorAction SilentlyContinue) }
        foreach ($l in $lnks) {
            if ($l.BaseName -ine $safeName -and -not $l.BaseName.StartsWith($safeName + ' ', [StringComparison]::OrdinalIgnoreCase) -and $l.Directory.Name -ine $safeName) { continue }
            $target = Get-ShortcutTarget -Lnk $l.FullName
            # Unknown target (MSIX/advertised shortcut) is NOT proof of a dead link - leave those alone.
            if (-not $target) { continue }
            if (Test-Path -LiteralPath $target) { continue }
            $items.Add([pscustomobject]@{ Type = 'Shortcut'; Path = $l.FullName; SizeMB = 0.0; Safe = $true; Reason = 'broken-shortcut' })
        }
    }
    if ($Progress) {
        Set-Prog $Progress -CanCancel $false -CanPause $false
        if ($cancelled) { Set-Prog $Progress -Text (T 'prog.cancelled') } else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
    }
    return @($items.ToArray())
}

# =====================================================================================
# Remove leftovers
# =====================================================================================

function New-LeftoverResult {
    param($Item, [string]$Status, [string]$Message = '')
    [pscustomobject]@{ Path = [string](Get-Prop $Item 'Path' ''); Status = $Status; Message = $Message }
}

function Export-RegistryBackup {
    <# Writes a .reg export under <CacheDir>\uninstall-backups. Returns the file path or $null on failure. #>
    param([string]$Path)
    Use-WorkDirs
    $dir = Join-Path (Get-AppPaths).CacheDir 'uninstall-backups'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $leaf = ($Path -replace '[^A-Za-z0-9_.-]', '_')
    if ($leaf.Length -gt 80) { $leaf = $leaf.Substring($leaf.Length - 80) }
    $file = Join-Path $dir ('{0:yyyyMMdd-HHmmss}-{1}.reg' -f (Get-Date), $leaf)
    $native = $Path -replace '^HKCU:', 'HKCU' -replace '^HKLM:', 'HKLM'
    $r = Invoke-Process -FilePath (Join-Path $env:SystemRoot 'System32\reg.exe') -ArgumentList @('export', $native, $file, '/y') -TimeoutMinutes 2
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $file)) { return $file }
    return $null
}

function Remove-AppLeftovers {
    <# Deletes only items flagged Safe=$true, and re-checks every path against the hard block list first.
       Folders and shortcuts go to the Recycle Bin (undo possible); registry keys are exported before deletion. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [switch]$DryRun, [hashtable]$Progress = $null)
    $results = New-Object System.Collections.Generic.List[object]
    $all = @($Items | Where-Object { $null -ne $_ })
    $idx = 0; $cancelled = $false
    Set-Prog $Progress -Percent 0 -Text (T 'prog.leftoverRemove' @(0, $all.Count)) -CanCancel $true -CanPause $true -Phase 'leftovers'
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ($Progress -and -not $cancelled -and (Wait-ProgPause $Progress)) { $cancelled = $true }
        if ($cancelled) { $results.Add((New-LeftoverResult $item 'Cancelled' 'prog.cancelled')); continue }
        $idx++
        Set-Prog $Progress -Percent (100.0 * ($idx - 1) / [Math]::Max(1, $all.Count)) -Text (T 'prog.leftoverRemove' @($idx, $all.Count))
        $type = [string](Get-Prop $item 'Type' '')
        $path = [string](Get-Prop $item 'Path' '')
        if ((Get-Prop $item 'Safe' $false) -ne $true) { $results.Add((New-LeftoverResult $item 'Skipped' 'not-safe')); continue }
        try {
            switch ($type) {
                'Folder' {
                    $block = Test-ProtectedFolderPath -Path $path
                    if ($block) { $results.Add((New-LeftoverResult $item 'Skipped' "protected:$block")); continue }
                    if (-not (Test-Path -LiteralPath $path -PathType Container)) { $results.Add((New-LeftoverResult $item 'Skipped' 'not-found')); continue }
                    if ($DryRun) { $results.Add((New-LeftoverResult $item 'WouldRemove' 'recycle-bin')); continue }
                    Add-Type -AssemblyName Microsoft.VisualBasic
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
                    Write-Log -Message "Leftover folder moved to Recycle Bin: $path"
                    $results.Add((New-LeftoverResult $item 'Removed' 'recycle-bin'))
                }
                'Shortcut' {
                    $okDir = $false
                    foreach ($menu in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
                        if (Test-PathUnder (ConvertTo-NormalPath $path) (ConvertTo-NormalPath $menu) -Strict) { $okDir = $true }
                    }
                    if (-not $okDir -or $path -notmatch '(?i)\.lnk$') { $results.Add((New-LeftoverResult $item 'Skipped' 'protected:not-a-start-menu-shortcut')); continue }
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $results.Add((New-LeftoverResult $item 'Skipped' 'not-found')); continue }
                    if ($DryRun) { $results.Add((New-LeftoverResult $item 'WouldRemove' 'recycle-bin')); continue }
                    Add-Type -AssemblyName Microsoft.VisualBasic
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
                    $results.Add((New-LeftoverResult $item 'Removed' 'recycle-bin'))
                }
                'RegistryKey' {
                    $block = Test-ProtectedRegistryPath -Path $path
                    if ($block) { $results.Add((New-LeftoverResult $item 'Skipped' "protected:$block")); continue }
                    if ($path -match '[\*\?\[\]]') { $results.Add((New-LeftoverResult $item 'Skipped' 'protected:wildcard')); continue }
                    if (-not (Test-Path -LiteralPath $path)) { $results.Add((New-LeftoverResult $item 'Skipped' 'not-found')); continue }
                    if ($DryRun) { $results.Add((New-LeftoverResult $item 'WouldRemove' 'registry-backup-then-delete')); continue }
                    $backup = Export-RegistryBackup -Path $path
                    if (-not $backup) { $results.Add((New-LeftoverResult $item 'Failed' 'backup-failed, key kept')); continue }
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    Write-Log -Message "Leftover registry key removed: $path (backup $backup)"
                    $results.Add((New-LeftoverResult $item 'Removed' ('backup: ' + $backup)))
                }
                default { $results.Add((New-LeftoverResult $item 'Skipped' 'unknown-type')) }
            }
        } catch {
            Write-Log -Level WARN -Message "Leftover removal failed for ${path}: $($_.Exception.Message)"
            $results.Add((New-LeftoverResult $item 'Failed' $_.Exception.Message))
        }
    }
    if ($Progress) {
        Set-Prog $Progress -CanCancel $false -CanPause $false
        if ($cancelled) { Set-Prog $Progress -Text (T 'prog.cancelled') } else { Set-Prog $Progress -Percent 100 -Text (T 'prog.done') }
    }
    return @($results.ToArray())
}

Export-ModuleMember -Function Get-InstalledApps, Invoke-AppUninstall, Find-AppLeftovers, Remove-AppLeftovers
