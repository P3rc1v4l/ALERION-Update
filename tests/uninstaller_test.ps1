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

Remove-Item -LiteralPath $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} FAILED" -f $passed, $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host ("All {0} checks passed." -f $passed) -ForegroundColor Green
exit 0
