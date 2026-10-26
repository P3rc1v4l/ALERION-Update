<#
.SYNOPSIS
    Non-destructive test for src\Uninstaller.psm1. Exit code 0 = all checks passed.
    Never uninstalls anything; only creates and removes its own temp folders.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0

function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok -eq $false) { throw 'returned false' }
        $script:passed++; Write-Host "  [OK]   $Name" -ForegroundColor Green
    } catch {
        $script:failures.Add("$Name : $($_.Exception.Message)"); Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$env:UPDATECENTER_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("alerion-un-test-" + [guid]::NewGuid().ToString('N'))
Write-Host 'Uninstaller test (non-destructive)' -ForegroundColor Cyan

foreach ($f in @('Uninstaller.psm1')) {
    $path = Join-Path $src $f
    Check "syntax $f" {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
        if ($e.Count) { throw (($e | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
    }
    Check "ascii-only $f" { @([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count -eq 0 }
}

Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Uninstaller.psm1') -DisableNameChecking -Force

# One real scan (with winget mapping), reused by the checks below.
$apps = @()
Check 'Get-InstalledApps returns items' {
    $script:apps = @(Get-InstalledApps)
    Write-Host ("         {0} apps, {1} protected" -f $script:apps.Count, @($script:apps | Where-Object Protected).Count)
    $script:apps.Count -gt 0
}
Check 'app objects have the contract fields' {
    $need = 'Key', 'Name', 'Publisher', 'Version', 'SizeMB', 'InstallDate', 'Source', 'WingetId', 'UninstallString', 'QuietUninstallString', 'ProductCode', 'AppxFullName', 'InstallLocation', 'Scope', 'Protected', 'ProtectedReason'
    $have = $script:apps[0].PSObject.Properties.Name
    foreach ($n in $need) { if ($have -notcontains $n) { throw "missing $n" } }
    foreach ($a in $script:apps) { if ($a.Source -notin 'winget', 'msi', 'exe', 'store') { throw "bad Source $($a.Source) for $($a.Name)" } }
}
Check 'winget ids are mapped (when winget is available)' {
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or -not (Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) { return $true }
    $n = @($script:apps | Where-Object { $_.WingetId }).Count
    Write-Host "         $n apps with a winget id"
    foreach ($a in @($script:apps | Where-Object { $_.WingetId })) { if ($a.WingetId -match '[\\\s]') { throw "bad id $($a.WingetId)" } }
    $n -gt 0
}
Check 'no real app is both Protected=false and a runtime/driver by name' {
    $bad = @($script:apps | Where-Object { -not $_.Protected -and $_.Name -match 'Visual C\+\+.*Redistributable|WebView2|^NVIDIA Graphics Driver|\.NET (Runtime|SDK)' })
    if ($bad.Count) { throw ($bad.Name -join '; ') }
}

# Synthetic entries: protection must work on names alone.
function New-FakeApp {
    param($Name, $Publisher = 'Test Publisher', [bool]$Protected = $false, $Reason = '', $WingetId = '', $Code = '', $Un = 'C:\nonexistent\unins000.exe', $Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\UCTEST-NOT-REAL', $Loc = '')
    [pscustomobject]@{ Key = $Key; Name = $Name; Publisher = $Publisher; Version = '1.0'; SizeMB = 0; InstallDate = ''; Source = 'exe'; WingetId = $WingetId
        UninstallString = $Un; QuietUninstallString = ''; ProductCode = $Code; AppxFullName = ''; InstallLocation = $Loc; Scope = 'machine'; Protected = $Protected; ProtectedReason = $Reason }
}

Check 'protected names are refused even when Protected=$false' {
    foreach ($n in 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.38.33135', 'Microsoft Visual C++ 2012 x86 Minimum Runtime - 11.0.61030',
                   'Microsoft .NET Runtime - 8.0.4 (x64)', 'Microsoft Windows Desktop Runtime - 8.0.4 (x64)', 'Microsoft Edge WebView2 Runtime',
                   'NVIDIA Graphics Driver 551.23', 'NVIDIA HD Audio Driver 1.3.40.14', 'Windows Software Development Kit - Windows 10.0.22621',
                   'Security Update for Microsoft Windows (KB5034123)', 'Intel(R) Management Engine Components') {
        $r = Invoke-AppUninstall -App (New-FakeApp -Name $n -WingetId 'Some.Id')
        if ($r.Status -ne 'Skipped') { throw "$n -> $($r.Status)" }
    }
}
Check 'vendor driver/component entries are refused, user-facing vendor apps are not' {
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'AMD Application Compatibility Database File' -Publisher 'Advanced Micro Devices, Inc.' -WingetId 'X.Y')
    if ($r.Status -ne 'Skipped') { throw "AMD db -> $($r.Status)" }
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'AMD Software: Adrenalin Edition' -Publisher 'Advanced Micro Devices, Inc.' -WingetId 'X.Y')
    if ($r.Status -ne 'Skipped') { throw "Adrenalin -> $($r.Status)" }
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'NVIDIA App' -Publisher 'NVIDIA Corporation' -WingetId 'Nvidia.NvidiaApp') -DryRun
    $r.Status -eq 'WouldRemove'
}
Check 'no unprotected Store app has a technical name or hash publisher; no path-like publishers' {
    $hash = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-'
    foreach ($a in @($script:apps | Where-Object { $_.Source -eq 'store' -and -not $_.Protected })) {
        if ($a.Name -match $hash -or $a.Publisher -match $hash -or $a.Name -match '^[0-9A-Fa-f]{7,8}\.') { throw "technical: $($a.Name) / $($a.Publisher)" }
    }
    foreach ($a in $script:apps) { if ($a.Publisher -match '[\\/]') { throw "path publisher: $($a.Name) / $($a.Publisher)" } }
    $true
}
Check 'entries flagged Protected are refused' {
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'Whatever' -Protected $true -Reason 'system-component')
    $r.Status -eq 'Skipped' -and $r.Message -match 'system-component'
}
Check 'DryRun returns WouldRemove and changes nothing' {
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'UC Test Tool' -WingetId 'Fake.UCTestTool') -DryRun
    if ($r.Status -ne 'WouldRemove') { throw $r.Status }
    $r2 = Invoke-AppUninstall -App (New-FakeApp -Name 'UC Test MSI' -Code '{11111111-2222-3333-4444-555555555555}') -DryRun
    $r2.Status -eq 'WouldRemove' -and $r2.Message -match 'msiexec'
}
Check 'app without any uninstaller is not removable' {
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'UC No Uninstaller' -Un '') -DryRun
    $r.Status -eq 'Skipped'
}
Check 'non-installed app is skipped (nothing executed)' {
    $r = Invoke-AppUninstall -App (New-FakeApp -Name 'UC Ghost App')
    $r.Status -eq 'Skipped' -and $r.Message -eq 'not-installed'
}
Check 'at least one real runtime/driver/framework entry is Protected (if present)' {
    $hit = @($script:apps | Where-Object { $_.Name -match 'Redistributable|\.NET|WebView2|NVIDIA.*Driver' })
    foreach ($h in $hit) { if (-not $h.Protected) { throw "$($h.Name) not protected" } }
    $true
}

# Leftovers: dangerous locations must be unsafe, a private temp folder owned by a fake app must be safe.
$empty = @()
Check 'C:\Windows, drive root and Program Files root are unsafe' {
    foreach ($p in @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), ($env:SystemDrive + '\'), $env:ProgramFiles, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA)) {
        $app = New-FakeApp -Name 'UC Fake App' -Loc $p
        $items = @(Find-AppLeftovers -App $app -InstalledApps $empty)
        $hit = @($items | Where-Object { $_.Type -eq 'Folder' })
        if ($hit.Count -eq 0) { throw "no item for $p" }
        foreach ($i in $hit) { if ($i.Safe) { throw "$($i.Path) marked safe" } }
    }
}
Check 'generic names are unsafe' {
    $d = Join-Path $env:LOCALAPPDATA 'Programs'
    $app = New-FakeApp -Name 'Google' -Publisher 'Google LLC' -Loc (Join-Path $env:ProgramFiles 'Google')
    foreach ($i in @(Find-AppLeftovers -App $app -InstalledApps $empty)) { if ($i.Safe) { throw "$($i.Path) marked safe" } }
}
Check 'folder shared with another installed app is unsafe' {
    $tmp = Join-Path $env:LOCALAPPDATA ('UCTestShared-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $tmp 'other') -Force | Out-Null
    try {
        $app = New-FakeApp -Name (Split-Path -Leaf $tmp) -Loc $tmp -Key 'HKLM:\x\one'
        $other = New-FakeApp -Name 'Other App' -Loc (Join-Path $tmp 'other') -Key 'HKLM:\x\two'
        $items = @(Find-AppLeftovers -App $app -InstalledApps @($other))
        $f = @($items | Where-Object { $_.Path -ieq $tmp })
        $f.Count -eq 1 -and -not $f[0].Safe -and $f[0].Reason -eq 'shared-with-installed-app'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Check 'own app folder is Safe; DryRun removal reports WouldRemove and keeps it' {
    $tmp = Join-Path $env:LOCALAPPDATA ('UCTestOwn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'x'
    try {
        $app = New-FakeApp -Name (Split-Path -Leaf $tmp) -Loc $tmp
        $items = @(Find-AppLeftovers -App $app -InstalledApps $empty)
        $f = @($items | Where-Object { $_.Path -ieq $tmp })
        if ($f.Count -ne 1 -or -not $f[0].Safe) { throw "not safe: $($f | Out-String)" }
        $r = @(Remove-AppLeftovers -Items $items -DryRun)
        if (@($r | Where-Object { $_.Status -eq 'WouldRemove' }).Count -lt 1) { throw 'no WouldRemove' }
        Test-Path -LiteralPath $tmp
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Check 'Remove-AppLeftovers refuses Safe=false and tampered Safe=true on protected paths' {
    $items = @(
        [pscustomobject]@{ Type = 'Folder'; Path = $env:SystemRoot; SizeMB = 0; Safe = $false; Reason = 'x' },
        [pscustomobject]@{ Type = 'Folder'; Path = $env:SystemRoot; SizeMB = 0; Safe = $true; Reason = 'tampered' },
        [pscustomobject]@{ Type = 'Folder'; Path = $env:ProgramFiles; SizeMB = 0; Safe = $true; Reason = 'tampered' },
        [pscustomobject]@{ Type = 'RegistryKey'; Path = 'HKLM:\SOFTWARE\Microsoft'; SizeMB = 0; Safe = $true; Reason = 'tampered' },
        [pscustomobject]@{ Type = 'RegistryKey'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows'; SizeMB = 0; Safe = $true; Reason = 'tampered' },
        [pscustomobject]@{ Type = 'Shortcut'; Path = (Join-Path $env:SystemRoot 'notepad.exe'); SizeMB = 0; Safe = $true; Reason = 'tampered' }
    )
    foreach ($r in @(Remove-AppLeftovers -Items $items)) { if ($r.Status -ne 'Skipped') { throw "$($r.Path) -> $($r.Status)" } }
    $true
}

# ---------------------------------------------------------------- progress / cancel / pause
Write-Host 'Progress, cancel, pause' -ForegroundColor Cyan
$pausedText = T 'prog.paused'

# Live log: the new i18n keys live in a fragment that the app merges into i18n.json; merge them here so line texts can be checked.
$fragPath = Join-Path $src 'i18n.json'
$unMod = Get-Module Uninstaller
$tMod = & $unMod { (Get-Command T).ScriptBlock.Module }
$frag = Get-Content -LiteralPath $fragPath -Raw -Encoding UTF8 | ConvertFrom-Json
& $tMod { param($f)
    $null = T 'prog.done'
    foreach ($l in 'de', 'en') { foreach ($p in $f.$l.PSObject.Properties) { Add-Member -InputObject $script:I18n.$l -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
} $frag
# Same merge for the module copy that runs inside a job runspace (prefix for the job code).
$mergeCode = '$mm = & (Get-Module Uninstaller) { (Get-Command T).ScriptBlock.Module }; $fr = Get-Content -LiteralPath ''' + $fragPath + ''' -Raw -Encoding UTF8 | ConvertFrom-Json; & $mm { param($f) $null = T "prog.done"; foreach ($l in "de","en") { foreach ($p in $f.$l.PSObject.Properties) { Add-Member -InputObject $script:I18n.$l -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } } } $fr; '
function New-LogProgress { [hashtable]::Synchronized(@{ Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) }) }

Check 'Add-ProgLog: timestamped line; null / no Log key never throw; capped at 500' {
    $p = New-LogProgress
    & $unMod { param($pp) Add-ProgLog $pp 'log.un.removedApp' @('Foo') } $p
    & $unMod { Add-ProgLog $null 'log.un.removedApp' @('a'); Add-ProgLog ([hashtable]::Synchronized(@{})) 'log.un.removedApp' @('a'); Add-ProgLog @{ Log = 5 } 'log.un.removedApp' @('a') }
    if ($p['Log'].Count -ne 1 -or $p['Log'][0] -notmatch '^\d\d:\d\d:\d\d  .*Foo') { throw "line: $($p['Log'] -join '|')" }
    $q = New-LogProgress
    & $unMod { param($pp) 1..520 | ForEach-Object { Add-ProgLog $pp 'log.un.removedApp' @("app$_") } } $q
    $q['Log'].Count -eq 500 -and $q['Log'][0] -match 'app21\b' -and $q['Log'][499] -match 'app520\b'
}

function Start-ModJob {
    param([string]$Code, [hashtable]$Progress, [hashtable]$Vars = @{})
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('Progress', $Progress)
    $rs.SessionStateProxy.SetVariable('ModPath', (Join-Path $src 'Uninstaller.psm1'))
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript("Import-Module `$ModPath -Force -DisableNameChecking; " + $Code)
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}
function Receive-ModJob {
    param($Job, [int]$TimeoutSec = 120)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Job.Handle.IsCompleted) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $Job.PS.Stop(); throw "job timeout after $TimeoutSec s" }
        Start-Sleep -Milliseconds 20
    }
    $out = @($Job.PS.EndInvoke($Job.Handle))
    if ($Job.PS.Streams.Error.Count -gt 0) { $e = $Job.PS.Streams.Error[0].ToString(); $Job.PS.Dispose(); $Job.RS.Dispose(); throw $e }
    $Job.PS.Dispose(); $Job.RS.Dispose()
    return $out
}
function Wait-Until {
    param([scriptblock]$Cond, [int]$TimeoutSec = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Cond)) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { return $false }; Start-Sleep -Milliseconds 10 }
    return $true
}

# Get-InstalledApps with a progress table (read-only scan in a separate runspace, sampled from here).
$prog = [hashtable]::Synchronized(@{})
$job = Start-ModJob -Progress $prog -Code '@(Get-InstalledApps -Progress $Progress)'
$samples = New-Object System.Collections.Generic.List[double]; $sawCancel = $false; $sawPhase = ''; $sawText = ''
while (-not $job.Handle.IsCompleted) {
    $pc = $prog['Percent']; if ($null -ne $pc) { $samples.Add([double]$pc) }
    if ($prog['CanCancel'] -eq $true) { $sawCancel = $true }
    if ($prog['Phase']) { $sawPhase = [string]$prog['Phase'] }
    if ($prog['Text']) { $sawText = [string]$prog['Text'] }
    Start-Sleep -Milliseconds 15
}
$listed = @(Receive-ModJob $job)
Check "Get-InstalledApps progress: same result kind, Percent rises to 100 ($(@($samples | Select-Object -Unique).Count) distinct values)" {
    if ($listed.Count -lt 1) { throw 'no apps' }
    if ($prog['Percent'] -ne 100) { throw "final $($prog['Percent'])" }
    for ($i = 1; $i -lt $samples.Count; $i++) { if ($samples[$i] -lt $samples[$i - 1]) { throw "backwards ($($samples[$i - 1]) -> $($samples[$i]))" } }
    @($samples | Select-Object -Unique).Count -ge 3
}
Check 'Get-InstalledApps progress: CanCancel true while reading, Phase scan, Text set, CanCancel false at the end' {
    $sawCancel -and $sawPhase -eq 'scan' -and $sawText -and $prog['CanCancel'] -eq $false
}
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '@(Get-InstalledApps -Progress $Progress)'
Check 'Get-InstalledApps pause: blocks until Pause=false' {
    if (-not (Wait-Until { $prog['Text'] -eq $pausedText })) { throw "never paused (Text='$($prog['Text'])')" }
    Start-Sleep -Milliseconds 1000
    if ($job.Handle.IsCompleted) { throw 'finished while paused' }
    $prog['CanPause'] -eq $true
}
$prog['Pause'] = $false
$l2 = @(Receive-ModJob $job)
Check 'Get-InstalledApps pause: completes with the full list after resume' { $l2.Count -ge [Math]::Floor($listed.Count * 0.9) -and $prog['Percent'] -eq 100 }
$prog = [hashtable]::Synchronized(@{ Pause = $true })
$job = Start-ModJob -Progress $prog -Code '@(Get-InstalledApps -Progress $Progress)'
[void](Wait-Until { $prog['Text'] -eq $pausedText })
$prog['Cancel'] = $true
$sw = [Diagnostics.Stopwatch]::StartNew()
$l3 = @(Receive-ModJob $job -TimeoutSec 30)
Check 'Get-InstalledApps cancel (while paused): returns quickly with a partial list, Text = cancelled' {
    $sw.Elapsed.TotalSeconds -lt 20 -and $l3.Count -lt $listed.Count -and $prog['Text'] -eq (T 'prog.cancelled')
}

# Invoke-AppUninstall: DryRun with a progress table, cancel before the uninstaller starts.
function New-ProgFakeApp {
    param($Name, $Key, $Un = '', $WingetId = '')
    [pscustomobject]@{ Key = $Key; Name = $Name; Publisher = 'Test Publisher'; Version = '1.0'; SizeMB = 0; InstallDate = ''; Source = 'exe'; WingetId = $WingetId
        UninstallString = $Un; QuietUninstallString = ''; ProductCode = ''; AppxFullName = ''; InstallLocation = ''; Scope = 'user'; Protected = $false; ProtectedReason = '' }
}
Check 'Invoke-AppUninstall -DryRun -Progress returns WouldRemove' {
    $p = [hashtable]::Synchronized(@{})
    (Invoke-AppUninstall -App (New-ProgFakeApp -Name 'UC Prog Tool' -Key 'HKCU:\Software\UCNope' -WingetId 'Fake.UCProg') -DryRun -Progress $p).Status -eq 'WouldRemove'
}
Check 'Invoke-AppUninstall: Cancel=true -> Status Cancelled, prog.cancelled, nothing executed; phase restorepoint, CanCancel true' {
    $p = [hashtable]::Synchronized(@{ Cancel = $true })
    $app = New-ProgFakeApp -Name 'UC Prog Tool' -Key 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -WingetId 'Fake.UCProg'
    $r = Invoke-AppUninstall -App $app -Progress $p
    $r.Status -eq 'Cancelled' -and $r.Message -eq 'prog.cancelled' -and $p['Phase'] -eq 'restorepoint' -and $p['CanCancel'] -eq $true
}

# Uninstall phase with a harmless stand-in: a throw-away HKCU key plus ping.exe as the "vendor uninstaller".
$fakeKey = 'HKCU:\Software\UCTestFakeApp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
New-Item -Path $fakeKey -Force | Out-Null
$ping = Join-Path ([Environment]::GetFolderPath('System')) 'PING.EXE'
try {
    $fake = New-ProgFakeApp -Name 'UC Prog Fake Program' -Key $fakeKey -Un ('"' + $ping + '" -n 5 127.0.0.1')
    $prog = New-LogProgress
    $job = Start-ModJob -Progress $prog -Vars @{ App = $fake } -Code ($mergeCode + 'Invoke-AppUninstall -App $App -Progress $Progress')
    $okPhase = Wait-Until { $prog['Phase'] -eq 'uninstall' -and $prog['Percent'] -eq -1 }
    $uninstallFlags = ($prog['CanCancel'] -eq $false) -and ($prog['CanPause'] -eq $false)
    Start-Sleep -Milliseconds 1300
    $elapsedText = [string]$prog['Text']
    $prog['Cancel'] = $true            # must be ignored while the vendor uninstaller runs
    Start-Sleep -Milliseconds 300
    $stillRunning = -not $job.Handle.IsCompleted
    Remove-Item -LiteralPath $fakeKey -Recurse -Force   # "uninstall" done -> verification finds the app gone
    $ur = @(Receive-ModJob $job -TimeoutSec 60)
    Check 'uninstall phase: indeterminate, CanCancel=false, CanPause=false' { $okPhase -and $uninstallFlags }
    Check 'uninstall phase: elapsed text shown, Cancel ignored while the uninstaller runs' { $elapsedText -match '\d\d:\d\d|prog\.uninstalling' -and $stillRunning }
    Check 'uninstall: result Removed, Percent 100, final CanCancel false' { $ur[0].Status -eq 'Removed' -and $prog['Percent'] -eq 100 -and $prog['CanCancel'] -eq $false }
    Check 'uninstall log: start, method, exit code, verify, removed - in that order, each with the app/method details' {
        $l = @($prog['Log'])
        if ($l.Count -ne 5) { throw "expected 5 lines, got $($l.Count): $($l -join ' | ')" }
        $l[0] -match 'UC Prog Fake Program' -and $l[1] -match '1' -and $l[2] -match '\b0\b' -and $l[3] -match 'UC Prog Fake Program' -and $l[4] -match 'UC Prog Fake Program'
    }
} finally { Remove-Item -LiteralPath $fakeKey -Recurse -Force -ErrorAction SilentlyContinue }

# Find-AppLeftovers / Remove-AppLeftovers with progress (private folders under LOCALAPPDATA, DryRun removal).
$fo = Join-Path $env:LOCALAPPDATA ('UCTestProg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fo -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fo 'a.txt') -Value 'x'
try {
    $app = New-ProgFakeApp -Name (Split-Path -Leaf $fo) -Key 'HKCU:\Software\UCNope2'
    $app.InstallLocation = $fo
    $prog = New-LogProgress
    $job = Start-ModJob -Progress $prog -Vars @{ App = $app } -Code ($mergeCode + '@(Find-AppLeftovers -App $App -InstalledApps @() -Progress $Progress)')
    $samples = New-Object System.Collections.Generic.List[double]; $sawCancel = $false; $sawPhase = ''
    while (-not $job.Handle.IsCompleted) {
        $pc = $prog['Percent']; if ($null -ne $pc) { $samples.Add([double]$pc) }
        if ($prog['CanCancel'] -eq $true) { $sawCancel = $true }
        if ($prog['Phase']) { $sawPhase = [string]$prog['Phase'] }
        Start-Sleep -Milliseconds 3
    }
    $items = @(Receive-ModJob $job)
    Check 'Find-AppLeftovers progress: finds the folder, Percent rises to 100, CanCancel/Phase written' {
        if (@($items | Where-Object { $_.Path -ieq $fo -and $_.Safe }).Count -ne 1) { throw 'folder not found/safe' }
        if ($prog['Percent'] -ne 100) { throw "final $($prog['Percent'])" }
        for ($i = 1; $i -lt $samples.Count; $i++) { if ($samples[$i] -lt $samples[$i - 1]) { throw 'backwards' } }
        $sawCancel -and $sawPhase -eq 'leftovers'
    }
    Check 'Find-AppLeftovers log: search start, found item(s), search summary with the count' {
        $l = @($prog['Log'])
        $l.Count -ge 3 -and $l[0] -match [regex]::Escape($app.Name) -and (@($l | Where-Object { $_ -match [regex]::Escape($fo) }).Count -ge 1) -and $l[$l.Count - 1] -match "\b$($items.Count)\b"
    }
    $prog = [hashtable]::Synchronized(@{ Pause = $true })
    $job = Start-ModJob -Progress $prog -Vars @{ App = $app } -Code '@(Find-AppLeftovers -App $App -InstalledApps @() -Progress $Progress)'
    Check 'Find-AppLeftovers pause blocks, resume completes' {
        if (-not (Wait-Until { $prog['Text'] -eq $pausedText })) { throw 'never paused' }
        Start-Sleep -Milliseconds 800
        if ($job.Handle.IsCompleted) { throw 'finished while paused' }
        $true
    }
    $prog['Pause'] = $false
    $items2 = @(Receive-ModJob $job)
    Check 'Find-AppLeftovers resume: same items as the unpaused run' { $items2.Count -eq $items.Count }
    $prog = [hashtable]::Synchronized(@{ Pause = $true })
    $job = Start-ModJob -Progress $prog -Vars @{ App = $app } -Code '@(Find-AppLeftovers -App $App -InstalledApps @() -Progress $Progress)'
    [void](Wait-Until { $prog['Text'] -eq $pausedText })
    $prog['Cancel'] = $true
    [void](Receive-ModJob $job -TimeoutSec 30)
    Check 'Find-AppLeftovers cancel (while paused): returns early, Text = cancelled' { $prog['Text'] -eq (T 'prog.cancelled') }

    # Remove-AppLeftovers
    $fo2 = Join-Path $env:LOCALAPPDATA ('UCTestProg2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fo2 -Force | Out-Null
    try {
        $its = @(
            [pscustomobject]@{ Type = 'Folder'; Path = $fo; SizeMB = 0; Safe = $true; Reason = 'app-folder' },
            [pscustomobject]@{ Type = 'Folder'; Path = $fo2; SizeMB = 0; Safe = $true; Reason = 'app-folder' }
        )
        $prog = New-LogProgress
        $rr = @(Remove-AppLeftovers -Items $its -DryRun -Progress $prog)
        Check 'Remove-AppLeftovers -DryRun -Progress: WouldRemove for each, Percent 100, nothing deleted' {
            $rr.Count -eq 2 -and @($rr | Where-Object { $_.Status -ne 'WouldRemove' }).Count -eq 0 -and $prog['Percent'] -eq 100 -and (Test-Path -LiteralPath $fo) -and (Test-Path -LiteralPath $fo2) -and $prog['Phase'] -eq 'leftovers'
        }
        Check 'Remove-AppLeftovers log: start, one line per item, summary with the counts' {
            $l = @($prog['Log'])
            $l.Count -eq 4 -and $l[0] -match '\b2\b' -and $l[1] -match [regex]::Escape($fo) -and $l[2] -match [regex]::Escape($fo2) -and $l[3] -match '\b2\b'
        }
        $prog = [hashtable]::Synchronized(@{ Pause = $true })
        $job = Start-ModJob -Progress $prog -Vars @{ Its = $its } -Code '@(Remove-AppLeftovers -Items $Its -DryRun -Progress $Progress)'
        Check 'Remove-AppLeftovers pause: blocks between items' {
            if (-not (Wait-Until { $prog['Text'] -eq $pausedText })) { throw 'never paused' }
            Start-Sleep -Milliseconds 800
            -not $job.Handle.IsCompleted -and $prog['CanPause'] -eq $true -and $prog['CanCancel'] -eq $true
        }
        $prog['Cancel'] = $true
        $rc = @(Receive-ModJob $job -TimeoutSec 30)
        Check 'Remove-AppLeftovers cancel: every pending item reported Cancelled, nothing removed' {
            $rc.Count -eq 2 -and @($rc | Where-Object { $_.Status -ne 'Cancelled' -or $_.Message -ne 'prog.cancelled' }).Count -eq 0 -and (Test-Path -LiteralPath $fo) -and (Test-Path -LiteralPath $fo2)
        }
    } finally { Remove-Item -LiteralPath $fo2 -Recurse -Force -ErrorAction SilentlyContinue }
} finally { Remove-Item -LiteralPath $fo -Recurse -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} FAILED" -f $passed, $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host ("All {0} checks passed." -f $passed) -ForegroundColor Green
exit 0
