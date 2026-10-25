# Update Center - shared helpers (paths, config, logging, i18n, status, notifications, ACLs).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

Set-StrictMode -Version 2.0

$script:SrcDir     = $PSScriptRoot
$script:AppRoot    = Split-Path -Parent $PSScriptRoot
# Product identity in one place (names, install/data folders, task folder, legacy v1.x 'ALERION Update' paths).
$script:Product = [pscustomobject]@{
    Name             = 'Update Center'
    InstallDir       = Join-Path $env:ProgramFiles 'Update Center'
    DataDir          = Join-Path $env:ProgramData 'UpdateCenter'
    TaskPath         = '\UpdateCenter\'
    ShortcutName     = 'Update Center.lnk'
    UninstallKey     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UpdateCenter'
    AppUserModelId   = 'UpdateCenter.App'
    LegacyInstallDir = Join-Path $env:ProgramFiles 'ALERION Update'
    LegacyDataDir    = Join-Path $env:ProgramData 'ALERION\Update'
    LegacyTaskPath   = '\ALERION\'
    LegacyShortcut   = 'ALERION Update.lnk'
    LegacyUninstall  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ALERION Update'
}
$script:DataDir    = $script:Product.DataDir
# Test override (smoke test / CI). Ignored when elevated so user-level code cannot redirect
# the elevated engine to a writable config folder.
if ($env:UPDATECENTER_DATADIR -and -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $script:DataDir = $env:UPDATECENTER_DATADIR
}
$script:LogDir     = Join-Path $script:DataDir 'logs'
$script:ReportDir  = Join-Path $script:DataDir 'reports'
$script:StateDir   = Join-Path $script:DataDir 'state'
$script:CacheDir   = Join-Path $script:DataDir 'cache'
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:StatusPath = Join-Path $script:StateDir 'status.json'
$script:LogFile    = $null
$script:I18n       = $null
$script:Lang       = 'de'

# Well-known SIDs so ACLs work on every Windows display language.
$script:SidSystem = 'S-1-5-18'
$script:SidAdmins = 'S-1-5-32-544'
$script:SidUsers  = 'S-1-5-32-545'

function Get-Product { $script:Product }

function Test-LegacyInstall { $script:AppRoot -eq $script:Product.LegacyInstallDir }

function Get-AppVersion {
    $file = Join-Path $script:AppRoot 'VERSION'
    if (Test-Path $file) { return (Get-Content $file -Raw).Trim() }
    return '0.0.0'
}

function Get-AppPaths {
    [pscustomobject]@{
        AppRoot    = $script:AppRoot
        SrcDir     = $script:SrcDir
        DataDir    = $script:DataDir
        LogDir     = $script:LogDir
        ReportDir  = $script:ReportDir
        StateDir   = $script:StateDir
        CacheDir   = $script:CacheDir
        ConfigPath = $script:ConfigPath
        StatusPath = $script:StatusPath
        IconPath   = Join-Path $script:AppRoot 'assets\icon.ico'
        LogoPath   = Join-Path $script:AppRoot 'assets\icon.png'
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- ACL hardening
function Protect-Directory {
    <# Replaces the ACL so only SYSTEM/Administrators can write and Users can only read.
       Prevents a non-elevated process from planting config or code that later runs elevated. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $prop    = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(@($script:SidSystem, 'FullControl'), @($script:SidAdmins, 'FullControl'), @($script:SidUsers, 'ReadAndExecute'))) {
        $sid  = New-Object System.Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $entry[1], $inherit, $prop, 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:SidAdmins)))
    Set-Acl -Path $Path -AclObject $acl
}

function Initialize-DataDir {
    param([switch]$Harden)
    # One-time migration of settings, reports and logs from the v1.x location.
    if ((Test-IsAdmin) -and $script:DataDir -eq $script:Product.DataDir -and -not (Test-Path $script:DataDir) -and (Test-Path $script:Product.LegacyDataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        Copy-Item (Join-Path $script:Product.LegacyDataDir '*') -Destination $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:DataDir 'state\status.json') -Force -ErrorAction SilentlyContinue
    }
    foreach ($d in @($script:DataDir, $script:LogDir, $script:ReportDir, $script:StateDir, $script:CacheDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if ($Harden -and (Test-IsAdmin)) { Protect-Directory -Path $script:DataDir }
}

# ---------------------------------------------------------------- i18n
function Import-I18n {
    param([string]$Language)
    if (-not $script:I18n) {
        $raw = Get-Content (Join-Path $script:SrcDir 'i18n.json') -Raw -Encoding UTF8
        $script:I18n = $raw | ConvertFrom-Json
    }
    if ($Language -and ($script:I18n.PSObject.Properties.Name -contains $Language)) { $script:Lang = $Language }
}

function T {
    <# Translate a key; supports {0} format arguments. Falls back to English, then to the key. #>
    param([Parameter(Mandatory)][string]$Key, [object[]]$Args2 = @())
    if (-not $script:I18n) { Import-I18n }
    $text = $null
    foreach ($l in @($script:Lang, 'en')) {
        $table = $script:I18n.$l
        if ($table -and ($table.PSObject.Properties.Name -contains $Key)) { $text = $table.$Key; break }
    }
    if ($null -eq $text) { $text = $Key }
    if ($Args2.Count -gt 0) { return [string]::Format($text, $Args2) }
    return $text
}

function Get-CurrentLanguage { $script:Lang }

# ---------------------------------------------------------------- config
function Get-DefaultConfig {
    $cfg = Get-Content (Join-Path $script:SrcDir 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.Language -eq 'auto') {
        $cfg.Language = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' }
    }
    return $cfg
}

function Merge-Config {
    <# Copies every key that exists in the defaults from the user config (one level of nesting).
       Unknown keys are dropped, missing keys get defaults, so old configs migrate automatically. #>
    param($Defaults, $User)
    if ($null -eq $User) { return $Defaults }
    foreach ($p in $Defaults.PSObject.Properties) {
        if (-not ($User.PSObject.Properties.Name -contains $p.Name)) { continue }
        $uv = $User.($p.Name)
        if ($p.Value -is [System.Management.Automation.PSCustomObject] -and $uv -is [System.Management.Automation.PSCustomObject]) {
            foreach ($q in $p.Value.PSObject.Properties) {
                if ($uv.PSObject.Properties.Name -contains $q.Name) { $p.Value.($q.Name) = $uv.($q.Name) }
            }
        } else {
            $Defaults.($p.Name) = $uv
        }
    }
    return $Defaults
}

function Test-Config {
    <# Fail-fast validation. Returns a list of problems (empty = valid). #>
    param($Config)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($Config.Language -notin @('de', 'en')) { $errors.Add("Language must be 'de' or 'en'") }
    if ($Config.Mode -notin @('Visible', 'Silent')) { $errors.Add("Mode must be 'Visible' or 'Silent'") }
    if ($Config.Reboot -notin @('Never', 'Prompt', 'Auto', 'Scheduled')) { $errors.Add("Reboot must be Never, Prompt, Auto or Scheduled") }
    if ($Config.RebootTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors.Add("RebootTime must be HH:mm") }
    if ($Config.Schedule.Type -notin @('Manual', 'Daily', 'Weekly', 'BiWeekly', 'Monthly')) { $errors.Add("Schedule.Type invalid") }
    if ($Config.Schedule.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors.Add("Schedule.Time must be HH:mm") }
    if ($Config.Schedule.DayOfWeek -notin [Enum]::GetNames([DayOfWeek])) { $errors.Add("Schedule.DayOfWeek invalid") }
    if ([int]$Config.Schedule.DayOfMonth -lt 1 -or [int]$Config.Schedule.DayOfMonth -gt 28) { $errors.Add("Schedule.DayOfMonth must be 1-28") }
    if ([int]$Config.WaitWhileBusyMinutes -lt 0 -or [int]$Config.WaitWhileBusyMinutes -gt 1440) { $errors.Add("WaitWhileBusyMinutes must be 0-1440") }
    if ($Config.SelfUpdate.Repo -and $Config.SelfUpdate.Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { $errors.Add("SelfUpdate.Repo must be 'owner/name'") }
    if ($Config.ScheduleAction -notin @('Install', 'Notify')) { $errors.Add("ScheduleAction must be Install or Notify") }
    foreach ($p in @($Config.AutoInstallPriorities)) {
        if ($p -notin (Get-PriorityNames)) { $errors.Add("AutoInstallPriorities contains unknown priority: $p") }
    }
    foreach ($id in @($Config.ExcludedPackages)) {
        if ($id -and $id -notmatch '^[A-Za-z0-9_.+*\-]+$') { $errors.Add("Excluded package id contains invalid characters: $id") }
    }
    return , $errors
}

function Get-Config {
    $defaults = Get-DefaultConfig
    $user = $null
    if (Test-Path $script:ConfigPath) {
        try { $user = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Log -Level WARN -Message "config.json unreadable, using defaults: $($_.Exception.Message)" }
    }
    $cfg = Merge-Config -Defaults $defaults -User $user
    # Schema 1 -> 2: new keys (ScheduleAction, AutoInstallPriorities) are filled from the defaults above.
    if ($user -and [int]$user.SchemaVersion -lt 2) {
        $cfg.SchemaVersion = 2
        if (Test-IsAdmin) { try { Save-Config -Config $cfg } catch { Write-Log -Level WARN -Message "Config migration not saved: $($_.Exception.Message)" } }
    }
    $problems = Test-Config $cfg
    if ($problems.Count -gt 0) {
        Write-Log -Level WARN -Message ("Invalid config, falling back to defaults: " + ($problems -join '; '))
        $cfg = Get-DefaultConfig
    }
    $cfg.ExcludedPackages = @($cfg.ExcludedPackages | Where-Object { $_ })
    $cfg.AutoInstallPriorities = @($cfg.AutoInstallPriorities | Where-Object { $_ })
    return $cfg
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $problems = Test-Config $Config
    if ($problems.Count -gt 0) { throw ("Config invalid: " + ($problems -join '; ')) }
    Initialize-DataDir
    $json = $Config | ConvertTo-Json -Depth 6
    Write-AtomicFile -Path $script:ConfigPath -Content $json
}

function Write-AtomicFile {
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------- logging
function Start-LogFile {
    Initialize-DataDir
    $script:LogFile = Join-Path $script:LogDir ("update-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    return $script:LogFile
}

function Get-LogFile { $script:LogFile }

function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory)][string]$Message)
    # Never log anything that looks like a credential.
    $clean = $Message -replace '(?i)(token|password|secret|apikey)=\S+', '$1=***'
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $clean
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    Write-Verbose $line
}

function Remove-OldFiles {
    param([int]$Days = 60)
    $limit = (Get-Date).AddDays(-$Days)
    foreach ($d in @($script:LogDir, $script:ReportDir)) {
        Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $script:CacheDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- status (read by the GUI)
$script:Status = $null

function Get-PriorityNames { @('Critical', 'Important', 'Normal', 'Optional') }

function Reset-Status {
    param([ValidateSet('install', 'scan')][string]$Mode = 'install')
    $script:Status = [ordered]@{
        Running   = $true
        Mode      = $Mode
        Items     = [ordered]@{}
        Phase     = 'start'
        Percent   = 0
        Current   = ''
        StartedAt = (Get-Date).ToString('o')
        EndedAt   = $null
        Log       = @()
        ReportPath = $null
        Pid       = $PID
    }
    Save-Status
}

function Update-Status {
    param([string]$Phase, [int]$Percent = -1, [string]$Current, [string]$LogLine)
    if (-not $script:Status) { return }
    if ($Phase) { $script:Status.Phase = $Phase }
    if ($Percent -ge 0) { $script:Status.Percent = [Math]::Min(100, $Percent) }
    if ($PSBoundParameters.ContainsKey('Current')) { $script:Status.Current = $Current }
    if ($LogLine) {
        $script:Status.Log = @($script:Status.Log + ("{0:HH:mm:ss}  {1}" -f (Get-Date), $LogLine)) | Select-Object -Last 200
    }
    Save-Status
}

function Complete-Status {
    param([string]$ReportPath)
    if (-not $script:Status) { return }
    $script:Status.Running = $false
    $script:Status.Phase = 'done'
    $script:Status.Percent = 100
    $script:Status.Current = ''
    $script:Status.EndedAt = (Get-Date).ToString('o')
    $script:Status.ReportPath = $ReportPath
    Save-Status
}

function Set-ItemState {
    <# Per-package state for the GUI list: Pending, Running, Done, Failed, Skipped. #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$State)
    if (-not $script:Status) { return }
    $script:Status.Items[$Key] = $State
    Save-Status
}

# ---------------------------------------------------------------- cancel (GUI -> engine)
function Get-CancelPath { Join-Path $script:StateDir 'cancel.flag' }
function Request-Cancel { Set-Content -Path (Get-CancelPath) -Value (Get-Date).ToString('o') }
function Clear-Cancel { Remove-Item (Get-CancelPath) -Force -ErrorAction SilentlyContinue }
function Test-CancelRequested { Test-Path (Get-CancelPath) }

function Save-Status {
    try { Write-AtomicFile -Path $script:StatusPath -Content ($script:Status | ConvertTo-Json -Depth 4) } catch { }
}

function Get-Status {
    if (-not (Test-Path $script:StatusPath)) { return $null }
    try { return Get-Content $script:StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# ---------------------------------------------------------------- notifications
function Show-Toast {
    <# Native Windows toast via WinRT (works in Windows PowerShell 5.1, no extra module). #>
    param([string]$Title, [string]$Body, [string]$LaunchUri)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
        $launch = ''
        if ($LaunchUri) { $launch = " activationType=`"protocol`" launch=`"$(& $esc $LaunchUri)`"" }
        $logo = Join-Path $script:AppRoot 'assets\icon.png'
        $img = ''
        if (Test-Path $logo) { $img = "<image placement=`"appLogoOverride`" src=`"$(& $esc $logo)`"/>" }
        $xml = "<toast$launch><visual><binding template=`"ToastGeneric`">$img<text>$(& $esc $Title)</text><text>$(& $esc $Body)</text></binding></visual></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        # Our own AppUserModelID only works once the Start menu shortcut carries it (Install.ps1).
        $startLnk = Join-Path $env:ProgramData ('Microsoft\Windows\Start Menu\Programs\' + $script:Product.ShortcutName)
        $appId = if (Test-Path $startLnk) { $script:AppUserModelId } else { '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe' }
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($doc))
    } catch {
        Write-Log -Level WARN -Message "Toast failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- system state helpers
function Get-RestartEstimate {
    <# Estimates how long a restart takes on THIS PC from past restarts (System log: 6006 "event log
       stopped" -> 6005 "started"; gaps over 15 min are shutdowns, not restarts) plus time for closing
       apps / sign-in. When Windows has to finish installing updates during the restart, 2-7 minutes
       are added. Returns minutes as a range. #>
    param([bool]$WithUpdates = $false)
    $samples = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6005, 6006 } -MaxEvents 40 -ErrorAction Stop | Sort-Object TimeCreated)
        for ($i = 1; $i -lt $ev.Count; $i++) {
            if ($ev[$i].Id -eq 6005 -and $ev[$i - 1].Id -eq 6006) {
                $gap = ($ev[$i].TimeCreated - $ev[$i - 1].TimeCreated).TotalSeconds
                if ($gap -gt 5 -and $gap -lt 900) { $samples += $gap }
            }
        }
    } catch { }
    $measured = $samples.Count -gt 0
    $base = if ($measured) { ($samples | Sort-Object)[[int][Math]::Floor($samples.Count / 2)] } else { 75 }
    $base += 35   # closing apps before 6006 + sign-in after 6005
    $min = $base * 0.85; $max = $base * 1.4
    if ($WithUpdates) { $min += 120; $max += 420 }
    [pscustomobject]@{
        MinMinutes = [int][Math]::Max(1, [Math]::Round($min / 60))
        MaxMinutes = [int][Math]::Max(1, [Math]::Ceiling($max / 60))
        Measured   = $measured
        Samples    = $samples.Count
        WithUpdates = $WithUpdates
    }
}

function Format-RestartEstimate {
    param([Parameter(Mandatory)]$Estimate)
    if ($Estimate.MinMinutes -ge $Estimate.MaxMinutes) { return (T 'restart.estimateOne' @($Estimate.MaxMinutes)) }
    return (T 'restart.estimate' @($Estimate.MinMinutes, $Estimate.MaxMinutes))
}

function Get-NextTimeOfDay {
    param([Parameter(Mandatory)][string]$Time)
    $t = [datetime]::ParseExact($Time, 'HH:mm', $null)
    $at = (Get-Date).Date.AddHours($t.Hour).AddMinutes($t.Minute)
    if ($at -le (Get-Date).AddMinutes(2)) { $at = $at.AddDays(1) }
    return $at
}

function Test-PendingReboot {
    <# Only reliable signals: Windows servicing / Windows Update flags, plus our own last run when it
       reported a restart and the PC has not restarted since. PendingFileRenameOperations is ignored
       on purpose - components like Xbox Gaming Services leave entries there permanently. #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $file = Join-Path $script:StateDir 'last-report.json'
    if (Test-Path $file) {
        try {
            $r = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($r.Items | Where-Object { $_.RebootRequired -and $_.Status -eq 'Updated' })
            if (-not $r.DryRun -and $items.Count -gt 0) {
                $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                if ([datetime]::Parse($r.EndedAt) -gt $boot) { return $true }
            }
        } catch { }
    }
    return $false
}

if (-not ('Alerion.NativeState' -as [type])) {
    Add-Type -Namespace Alerion -Name NativeState -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SHQueryUserNotificationState(out int state);
'@
}

$script:AppUserModelId = $script:Product.AppUserModelId

if (-not ('Alerion.ShellUtil' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Alerion {
    // Gives the GUI process and its shortcuts one AppUserModelID, so the taskbar shows the
    // app icon (instead of grouping under powershell.exe) and pinned shortcut + window merge.
    public static class ShellUtil {
        [DllImport("shell32.dll")] static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bc, int flags, ref Guid iid, out IPropertyStore store);
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pv);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct PropertyKey { public Guid fmtid; public uint pid; }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr ptr; }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropVariant value);
            void SetValue(ref PropertyKey key, ref PropVariant value);
            void Commit();
        }

        public static void SetProcessAppId(string id) { SetCurrentProcessExplicitAppUserModelID(id); }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        // Windows 11: rounded corners + dark frame for our borderless window (no-op on Windows 10).
        // Returns true when the blurred "acrylic" backdrop is active (Windows 11 22H2+).
        public static bool StyleWindow(IntPtr hwnd) {
            int round = 2;  /* DWMWCP_ROUND */
            DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, 4);
            int dark = 1;
            DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref dark, 4);
            int border = 0x00453A33; /* COLORREF 0x00BBGGRR = #333A45, subtle frame */
            DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, ref border, 4);
            int backdrop = 3; /* DWMSBT_TRANSIENTWINDOW = acrylic */
            return DwmSetWindowAttribute(hwnd, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, ref backdrop, 4) == 0
                && System.Environment.OSVersion.Version.Build >= 22621;
        }

        public static void SetShortcutAppId(string lnkPath, string id) {
            Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore store;
            int hr = SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2 /* GPS_READWRITE */, ref iid, out store);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            PropertyKey key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
            PropVariant pv = new PropVariant { vt = 31 /* VT_LPWSTR */, ptr = Marshal.StringToCoTaskMemUni(id) };
            try { store.SetValue(ref key, ref pv); store.Commit(); }
            finally { PropVariantClear(ref pv); Marshal.ReleaseComObject(store); }
        }
    }
}
'@
}

function Get-AppUserModelId { $script:AppUserModelId }

function Test-UserBusy {
    <# True while a fullscreen D3D game, presentation or "busy" fullscreen app is running.
       QUNS: 2 = busy (fullscreen), 3 = D3D fullscreen, 4 = presentation mode. #>
    $state = 0
    try { [void][Alerion.NativeState]::SHQueryUserNotificationState([ref]$state) } catch { return $false }
    return ($state -in 2, 3, 4)
}

function Get-BatteryState {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $b) { return $null }
    # BatteryStatus 2 = on AC power
    [pscustomobject]@{ Percent = [int]$b.EstimatedChargeRemaining; OnAC = ($b.BatteryStatus -eq 2) }
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 10
        return ($r.Content -match 'Microsoft Connect Test')
    } catch { return $false }
}

Export-ModuleMember -Function * -Variable @()
