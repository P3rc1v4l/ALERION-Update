<#
.SYNOPSIS
    Non-destructive test for src\Startup.psm1. Exit code 0 = all checks passed.
    Real startup entries are only READ. Toggling is tested against a temporary HKCU:\Software\UpdateCenterTest key
    that is removed afterwards.
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

$env:UPDATECENTER_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("alerion-su-test-" + [guid]::NewGuid().ToString('N'))
Write-Host 'Startup test (real entries read-only)' -ForegroundColor Cyan

$path = Join-Path $src 'Startup.psm1'
Check 'syntax Startup.psm1' {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    if ($e.Count) { throw (($e | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
}
Check 'ascii-only Startup.psm1' { @([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count -eq 0 }
Check 'i18n startup keys present in de/en' {
    $j = Get-Content -Raw -Encoding UTF8 (Join-Path $src 'i18n.json') | ConvertFrom-Json
    $de = @($j.de.PSObject.Properties.Name | Where-Object { $_ -like 'startup.*' } | Sort-Object); $en = @($j.en.PSObject.Properties.Name | Where-Object { $_ -like 'startup.*' } | Sort-Object)
    if (($de -join ',') -ne ($en -join ',')) { throw 'key mismatch' }
    foreach ($k in @('startup.title', 'startup.needsAdmin', 'startup.protected', 'startup.toast.disabled')) { if ($k -notin $de) { throw "missing $k" } }
}

Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module $path -DisableNameChecking -Force

# --- pure encoding / parsing -------------------------------------------------------
Check 'parse: 02/06 enabled, 03/07 disabled, null/empty enabled' {
    (ConvertFrom-StartupApproved -Bytes ([byte[]](2, 0, 0, 0))) -and (ConvertFrom-StartupApproved -Bytes ([byte[]](6, 0, 0, 0))) -and
    -not (ConvertFrom-StartupApproved -Bytes ([byte[]](3, 0, 0, 0))) -and -not (ConvertFrom-StartupApproved -Bytes ([byte[]](7, 1, 2))) -and
    (ConvertFrom-StartupApproved -Bytes $null) -and (ConvertFrom-StartupApproved -Bytes ([byte[]]@()))
}
Check 'encode enabled = 02 + 11 zero bytes' {
    $b = ConvertTo-StartupApproved -Enabled $true
    $b.Length -eq 12 -and $b[0] -eq 2 -and @($b[1..11] | Where-Object { $_ -ne 0 }).Count -eq 0
}
Check 'encode disabled = 03 + zeros + FILETIME of given time' {
    $now = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
    $b = ConvertTo-StartupApproved -Enabled $false -Now $now
    $ft = [BitConverter]::ToInt64($b, 4)
    $b.Length -eq 12 -and $b[0] -eq 3 -and $b[1] -eq 0 -and $b[2] -eq 0 -and $b[3] -eq 0 -and $ft -eq $now.ToFileTimeUtc() -and -not (ConvertFrom-StartupApproved -Bytes $b)
}
Check 'command image path parsing' {
    (Get-CommandImagePath -Command '"C:\Program Files\A B\app.exe" /min') -eq 'C:\Program Files\A B\app.exe' -and
    (Get-CommandImagePath -Command 'C:\Program Files\A B\app.exe -x') -eq 'C:\Program Files\A B\app.exe' -and
    (Get-CommandImagePath -Command 'C:\x\y.exe') -eq 'C:\x\y.exe' -and (Get-CommandImagePath -Command '') -eq ''
}

# --- protection rules --------------------------------------------------------------
Check 'protection rules: positives' {
    $cases = @(
        @('SecurityHealth', '', 'C:\Windows\system32\SecurityHealthSystray.exe', 'startup.protect.security'),
        @('Whatever', 'Kaspersky Lab', 'C:\x\a.exe', 'startup.protect.security'),
        @('RtkAudUService', 'Realtek Semiconductor', 'C:\x\RtkAudUService64.exe', 'startup.protect.driver'),
        @('NVIDIA Broadcast', 'NVIDIA Corporation', 'C:\x\n.exe', 'startup.protect.driver'),
        @('Synaptics Pointing', '', 'C:\x\SynTPEnh.exe', 'startup.protect.driver'),
        @('CTF Loader', '', 'C:\Windows\System32\ctfmon.exe', 'startup.protect.input'),
        @('Narrator', '', 'C:\Windows\System32\Narrator.exe', 'startup.protect.accessibility'),
        @('ALERION Update Center', '', 'C:\x\a.exe', 'startup.protect.self')
    )
    foreach ($c in $cases) {
        $r = Get-StartupProtection -Name $c[0] -Publisher $c[1] -ImagePath $c[2] -Command $c[2]
        if ($r -ne $c[3]) { throw "$($c[0]) -> '$r' expected $($c[3])" }
    }
}
Check 'protection rules: negatives (Discord, Spotify, Steam, OneDrive, Logitech)' {
    foreach ($n in @('Discord', 'Spotify', 'Steam', 'OneDrive', 'Logitech Options', 'Teams')) {
        $r = Get-StartupProtection -Name $n -Publisher '' -ImagePath "C:\Apps\$n.exe" -Command "C:\Apps\$n.exe"
        if ($r) { throw "$n wrongly protected: $r" }
    }
}

# --- real items, read-only ---------------------------------------------------------
$real = @()
Check 'Get-StartupItems (real, read-only)' {
    $script:real = @(Get-StartupItems)
    foreach ($i in $script:real) {
        foreach ($p in @('Id', 'Name', 'Publisher', 'Command', 'Location', 'Scope', 'Enabled', 'Protected', 'ProtectReason', 'Impact', 'ImagePath', 'Exists')) {
            if (-not $i.PSObject.Properties[$p]) { throw "missing property $p" }
        }
    }
    $true
}
Write-Host ("  items: {0} total, {1} enabled, {2} disabled, {3} protected" -f @($real).Count, @($real | Where-Object { $_.Enabled }).Count, @($real | Where-Object { -not $_.Enabled }).Count, @($real | Where-Object { $_.Protected }).Count)
foreach ($g in @($real | Group-Object Location)) { Write-Host ("    {0}: {1}" -f $g.Name, $g.Count) }
foreach ($i in $real) {
    Write-Host ("    - [{0}] {1} | {2} | enabled={3} protected={4} {5} | exists={6} impact={7}" -f $i.Location, $i.Name, $i.Publisher, $i.Enabled, $i.Protected, $i.ProtectReason, $i.Exists, $i.Impact) -ForegroundColor DarkGray
}

# --- toggle round-trip against a temporary key only --------------------------------
$tmp = "HKCU:\Software\UpdateCenterTest\" + [guid]::NewGuid().ToString('N')
$runRoot = "$tmp\Run"; $apprRoot = "$tmp\Approved"
try {
    [void](New-Item -Path $runRoot -Force)
    [void](New-ItemProperty -Path $runRoot -Name 'TestApp' -Value '"C:\Windows\System32\notepad.exe" /x' -PropertyType String)
    [void](New-ItemProperty -Path $runRoot -Name 'SecurityHealth' -Value '%windir%\system32\SecurityHealthSystray.exe' -PropertyType ExpandString)

    Check 'override scan sees only temp key' {
        $l = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot)
        $l.Count -eq 2 -and (@($l | Where-Object { $_.Name -eq 'TestApp' })[0].Enabled) -and (@($l | Where-Object { $_.Name -eq 'TestApp' })[0].Exists)
    }
    Check 'disable writes 03 + FILETIME, item reads disabled' {
        $it = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'TestApp' })[0]
        $r = Set-StartupItemEnabled -Item $it -Enabled $false -ApprovedRoot $apprRoot
        if (-not $r.Ok) { throw "not ok: $($r.Message)" }
        $v = (Get-Item "$apprRoot\Run").GetValue('TestApp')
        if ($v.Length -ne 12 -or $v[0] -ne 3 -or [BitConverter]::ToInt64($v, 4) -le 0) { throw 'bad bytes' }
        $again = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'TestApp' })[0]
        -not $again.Enabled
    }
    Check 'Run value is never deleted by disable' {
        (Get-Item $runRoot).GetValue('TestApp') -eq '"C:\Windows\System32\notepad.exe" /x'
    }
    Check 'enable restores 02 + zeros, item reads enabled' {
        $it = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'TestApp' })[0]
        $r = Set-StartupItemEnabled -Item $it -Enabled $true -ApprovedRoot $apprRoot
        if (-not $r.Ok) { throw "not ok: $($r.Message)" }
        $v = (Get-Item "$apprRoot\Run").GetValue('TestApp')
        if ($v[0] -ne 2 -or @($v[1..11] | Where-Object { $_ -ne 0 }).Count) { throw 'bad bytes' }
        (@(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'TestApp' })[0]).Enabled
    }
    Check 'DryRun changes nothing' {
        $it = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'TestApp' })[0]
        $before = (Get-Item "$apprRoot\Run").GetValue('TestApp') -join ','
        $r = Set-StartupItemEnabled -Item $it -Enabled $false -DryRun -ApprovedRoot $apprRoot
        $after = (Get-Item "$apprRoot\Run").GetValue('TestApp') -join ','
        $r.Ok -and $r.DryRun -and $before -eq $after
    }
    Check 'protected item refuses to be disabled (even with tampered flag)' {
        $it = @(Get-StartupItems -RunRoot $runRoot -ApprovedRoot $apprRoot | Where-Object { $_.Name -eq 'SecurityHealth' })[0]
        if (-not $it.Protected) { throw 'not flagged protected' }
        $r = Set-StartupItemEnabled -Item $it -Enabled $false -ApprovedRoot $apprRoot
        if ($r.Ok -or $r.Message -ne 'startup.protected') { throw "got $($r.Ok) $($r.Message)" }
        $it.Protected = $false
        $r2 = Set-StartupItemEnabled -Item $it -Enabled $false -ApprovedRoot $apprRoot
        if ($r2.Ok -or $r2.Message -ne 'startup.protected') { throw 'tampered flag bypassed' }
        $null -eq (Get-Item "$apprRoot\Run" -ErrorAction SilentlyContinue).GetValue('SecurityHealth')
    }
    Check 'machine item without admin returns startup.needsAdmin (no throw)' {
        if (Test-IsAdmin) { return $true }
        $fake = [pscustomobject]@{ Id = 'x'; Name = 'FakeApp'; Publisher = ''; Command = 'C:\x\fake.exe'; ImagePath = 'C:\x\fake.exe'; Scope = 'Machine'; Kind = 'run'
            Protected = $false; ApprovedPath = 'HKLM:\Software\UpdateCenterTest\neverwritten\Run'; ApprovedValue = 'FakeApp' }
        $r = Set-StartupItemEnabled -Item $fake -Enabled $false
        (-not $r.Ok) -and $r.Message -eq 'startup.needsAdmin' -and -not (Test-Path 'HKLM:\Software\UpdateCenterTest')
    }
} finally {
    Remove-Item -LiteralPath "HKCU:\Software\UpdateCenterTest\$(Split-Path -Leaf $tmp)" -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem 'HKCU:\Software\UpdateCenterTest' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath 'HKCU:\Software\UpdateCenterTest' -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check 'temporary registry key removed' { -not (Test-Path 'HKCU:\Software\UpdateCenterTest') }

Remove-Item -LiteralPath $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
if ($failures.Count) {
    Write-Host ""; Write-Host "$($failures.Count) check(s) FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host ""; Write-Host "All $passed checks passed." -ForegroundColor Green
exit 0
