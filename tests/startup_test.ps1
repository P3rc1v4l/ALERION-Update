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

Check 'protection rules: OEM hardware services (name based, fake items)' {
    $names = @('ArmouryCrate.Service', 'ArmourySocketServer', 'AcPowerNotification', 'NoiseCancelingEngine', 'AsusFCNotification',
        'Gigabyte Control Center GCC', 'MSI Center', 'Lenovo Vantage Service', 'Dell SupportAssist', 'HP Support Assistant', 'P508PowerAgent', 'Realtek HD Audio', 'NVIDIA Broadcast', 'AMD Software', 'Intel Driver Support')
    foreach ($n in $names) {
        $r = Get-StartupProtection -Name $n -Publisher '' -ImagePath "C:\Fake\$n.exe" -Command "C:\Fake\$n.exe"
        if (-not $r -or $r -notmatch '^startup\.protect\.(oem|driver)$') { throw "$n not protected ($r)" }
    }
    (Get-StartupProtection -Name 'x' -Publisher 'ASUSTeK COMPUTER INC.' -ImagePath 'C:\x\a.exe' -Command 'C:\x\a.exe') -eq 'startup.protect.oem'
}
Check 'protection rules: user apps stay toggleable' {
    foreach ($n in @('Discord', 'Steam', 'Spotify', 'OneDrive', 'Logitech G HUB', 'Stream Deck', 'GoXLR', 'NZXT CAM', 'Corsair iCUE', 'Teams')) {
        $r = Get-StartupProtection -Name $n -Publisher '' -ImagePath "C:\Apps\$n.exe" -Command "C:\Apps\$n.exe"
        if ($r) { throw "$n wrongly protected: $r" }
    }
    foreach ($p in @('Logitech', 'Elgato Systems GmbH', 'NZXT, Inc.', 'Corsair Memory, Inc.', 'Discord Inc.', 'Valve', 'Spotify AB', 'Microsoft Corporation')) {
        $r = Get-StartupProtection -Name 'SomeApp' -Publisher $p -ImagePath 'C:\Apps\SomeApp.exe' -Command 'C:\Apps\SomeApp.exe'
        if ($r) { throw "publisher $p wrongly protected: $r" }
    }
    $true
}
Check 'protection rule: Microsoft-signed AND under WINDIR' {
    $sub = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $inWin = Join-Path $env:WINDIR 'System32\fakehelper.exe'
    if ((Get-StartupProtection -Name 'Helper' -Publisher '' -ImagePath $inWin -Command $inWin -SignerSubject $sub) -ne 'startup.protect.windows') { throw 'under WINDIR not protected' }
    if (Get-StartupProtection -Name 'Helper' -Publisher '' -ImagePath 'C:\Apps\fakehelper.exe' -Command 'C:\Apps\fakehelper.exe' -SignerSubject $sub) { throw 'outside WINDIR protected' }
    if (Get-StartupProtection -Name 'Helper' -Publisher '' -ImagePath $inWin -Command $inWin -SignerSubject 'CN=Some Vendor, O=Some Vendor Ltd') { throw 'non-Microsoft signer protected' }
    if (Get-StartupProtection -Name 'Helper' -Publisher '' -ImagePath $inWin -Command $inWin -SignerSubject 'CN=Fake, O=Microsoft Corporation Fake Ltd') { throw 'lookalike signer protected' }
    $true
}
Check 'protection rule: system tasks (SYSTEM / service / highest)' {
    if ((Get-StartupProtection -Name 'AnyTask' -Publisher '' -ImagePath 'C:\x\a.exe' -Command 'C:\x\a.exe' -IsSystemTask $true) -ne 'startup.protect.systemTask') { throw 'flag ignored' }
    if (-not (Test-TaskPrivileged -UserId 'SYSTEM' -RunLevel 'Limited' -LogonType 'ServiceAccount')) { throw 'SYSTEM' }
    if (-not (Test-TaskPrivileged -UserId 'S-1-5-18' -RunLevel '' -LogonType '')) { throw 'SID 18' }
    if (-not (Test-TaskPrivileged -UserId 'NT AUTHORITY\LOCAL SERVICE' -RunLevel '' -LogonType '')) { throw 'local service' }
    if (-not (Test-TaskPrivileged -UserId 'PC\user' -RunLevel 'Highest' -LogonType 'Interactive')) { throw 'highest' }
    if (Test-TaskPrivileged -UserId 'PC\user' -RunLevel 'Limited' -LogonType 'Interactive') { throw 'plain user task privileged' }
    $true
}
Check 'Set-StartupItemEnabled refuses system tasks both ways, allows (dry-run) user tasks' {
    $sys = [pscustomobject]@{ Id = 't1'; Name = 'FakeSysTask'; Publisher = ''; Command = 'C:\x\a.exe'; ImagePath = 'C:\x\a.exe'; Scope = 'Machine'; Kind = 'task'
        Protected = $false; IsSystemTask = $false; TaskPath = '\UcTestNope\'; TaskName = 'FakeSysTask' }
    foreach ($en in @($false, $true)) {
        $r = Set-StartupItemEnabled -Item $sys -Enabled $en -DryRun
        if ($r.Ok -or $r.Message -ne 'startup.protected' -or $r.Reason -ne 'startup.protect.systemTask') { throw "sys enabled=$en -> $($r.Ok) $($r.Message) $($r.Reason)" }
    }
    $usr = [pscustomobject]@{ Id = 't2'; Name = 'FakeUserTask'; Publisher = 'Fake Co'; Command = 'C:\x\a.exe'; ImagePath = 'C:\x\a.exe'; Scope = 'User'; Kind = 'task'
        Protected = $false; IsSystemTask = $false; TaskPath = '\UcTestNope\'; TaskName = 'FakeUserTask' }
    $r2 = Set-StartupItemEnabled -Item $usr -Enabled $false -DryRun
    $r2.Ok -and $r2.DryRun
}
Check 'Set-StartupItemEnabled refuses protected advanced task by name' {
    $t = [pscustomobject]@{ Id = 't3'; Name = 'ArmouryCrate.UserSessionHelper'; Publisher = ''; Command = 'C:\x\a.exe'; ImagePath = 'C:\x\a.exe'; Scope = 'User'; Kind = 'task'
        Protected = $false; TaskPath = '\'; TaskName = 'ArmouryCrate.UserSessionHelper' }
    $r = Set-StartupItemEnabled -Item $t -Enabled $false -DryRun
    (-not $r.Ok) -and $r.Message -eq 'startup.protected' -and $r.Reason -eq 'startup.protect.oem'
}
Check 'windows rule: generic host judged by launched file (rundll32 + third-party DLL stays toggleable)' {
    $sub = 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond'
    $host32 = Join-Path $env:WINDIR 'System32\rundll32.exe'
    $r1 = Get-StartupProtection -Name 'Logitech Download Assistant' -Publisher '' -ImagePath $host32 -Command ('"' + $host32 + '" "C:\Program Files\Logitech\LogiDA\LogiDA.dll",Run') -SignerSubject $sub
    if ($r1) { throw "third-party dll protected: $r1" }
    $r1b = Get-StartupProtection -Name 'Thing' -Publisher '' -ImagePath $host32 -Command ($host32 + ' C:\Vendor Dir\x.dll,Run') -SignerSubject $sub
    if ($r1b) { throw "unquoted third-party dll protected: $r1b" }
    $r2 = Get-StartupProtection -Name 'Thing' -Publisher '' -ImagePath $host32 -Command ($host32 + ' ' + (Join-Path $env:WINDIR 'System32\shell32.dll') + ',Foo') -SignerSubject $sub
    if ($r2 -ne 'startup.protect.windows') { throw "MS dll under WINDIR not protected: $r2" }
    $r3 = Get-StartupProtection -Name 'Thing' -Publisher '' -ImagePath $host32 -Command ($host32 + ' shell32.dll,Control_RunDLL') -SignerSubject $sub
    if ($r3 -ne 'startup.protect.windows') { throw "no resolvable path should stay protected: $r3" }
    $whql = Get-StartupProtection -Name 'Thing' -Publisher '' -ImagePath $host32 -Command ($host32 + ' ' + (Join-Path $env:WINDIR 'System32\LogiLDA.dll') + ',Go') -SignerSubject 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond'
    if ($whql) { throw "WHQL-signed vendor dll protected: $whql" }
    $cmdExe = Join-Path $env:WINDIR 'System32\cmd.exe'
    if (Get-StartupProtection -Name 'Thing' -Publisher '' -ImagePath $cmdExe -Command ($cmdExe + ' /c "D:\Tools\start.bat"') -SignerSubject $sub) { throw 'cmd + third-party bat protected' }
    (Get-HostLaunchTarget -ImagePath 'C:\Apps\app.exe' -Command 'C:\Apps\app.exe C:\x\y.dll') -eq ''
}
Check 'Get-StartupRisk levels' {
    (Get-StartupRisk -Protected $true -Kind 'run' -Scope 'User' -Exists $true -Publisher 'x').Risk -eq 'High' -and
    (Get-StartupRisk -Protected $false -Kind 'run' -Scope 'User' -Exists $false -Publisher 'x').Risk -eq 'Low' -and
    (Get-StartupRisk -Protected $false -Kind 'task' -Scope 'User' -Exists $true -Publisher 'x').Risk -eq 'Medium' -and
    (Get-StartupRisk -Protected $false -Kind 'run' -Scope 'Machine' -Exists $true -Publisher 'x').Risk -eq 'Medium' -and
    (Get-StartupRisk -Protected $false -Kind 'run' -Scope 'User' -Exists $true -Publisher '').Risk -eq 'Medium' -and
    (Get-StartupRisk -Protected $false -Kind 'run' -Scope 'User' -Exists $true -Publisher 'Acme').Risk -eq 'Low'
}
Check 'i18n fragment: de/en identical keys, covers all message keys' {
    $fp = Join-Path $src 'i18n.json'
    $j = Get-Content -Raw -Encoding UTF8 $fp | ConvertFrom-Json
    $de = @($j.de.PSObject.Properties.Name | Sort-Object); $en = @($j.en.PSObject.Properties.Name | Sort-Object)
    if (($de -join ',') -ne ($en -join ',')) { throw 'de/en key mismatch' }
    foreach ($k in @('startup.protect.oem', 'startup.protect.windows', 'startup.protect.systemTask', 'startup.removeOnlyOwn', 'startup.add.ok', 'startup.add.notFound',
        'startup.add.badType', 'startup.add.exists', 'startup.add.failed', 'startup.remove.ok', 'startup.remove.failed',
        'startup.risk.reason.protected', 'startup.risk.reason.missing', 'startup.risk.reason.task', 'startup.risk.reason.machine', 'startup.risk.reason.unknown', 'startup.risk.reason.user')) {
        if ($k -notin $de) { throw "missing $k" }
    }
    foreach ($p in $j.de.PSObject.Properties) { if (-not $p.Value) { throw "empty de $($p.Name)" } }
    $true
}

# --- add / remove against a temporary startup folder -------------------------------
$sf = Join-Path ([IO.Path]::GetTempPath()) ("uc-su-folder-" + [guid]::NewGuid().ToString('N'))
$toolDir = Join-Path ([IO.Path]::GetTempPath()) ("uc-su-tool-" + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $sf -Force); [void](New-Item -ItemType Directory -Path $toolDir -Force)
    $fakeExe = Join-Path $toolDir 'uctool.exe'; $fakeBat = Join-Path $toolDir 'uctool.bat'; $fakePs1 = Join-Path $toolDir 'uctool.ps1'
    Set-Content -LiteralPath $fakeExe -Value 'x'; Set-Content -LiteralPath $fakeBat -Value '@echo off'; Set-Content -LiteralPath $fakePs1 -Value 'x'

    Check 'Add: missing target -> startup.add.notFound' {
        $r = Add-StartupItem -Path (Join-Path $toolDir 'nope.exe') -StartupFolder $sf
        (-not $r.Ok) -and $r.Message -eq 'startup.add.notFound'
    }
    Check 'Add: ps1 refused -> startup.add.badType' {
        $r = Add-StartupItem -Path $fakePs1 -StartupFolder $sf
        (-not $r.Ok) -and $r.Message -eq 'startup.add.badType' -and @(Get-ChildItem $sf).Count -eq 0
    }
    Check 'Add: DryRun creates nothing' {
        $r = Add-StartupItem -Path $fakeExe -Name 'UcDry' -StartupFolder $sf -DryRun
        $r.Ok -and $r.DryRun -and @(Get-ChildItem $sf).Count -eq 0
    }
    Check 'Add: creates shortcut with marker description, args, working dir' {
        $r = Add-StartupItem -Path $fakeExe -Arguments '--min /x' -Name 'UcOwn' -StartupFolder $sf
        if (-not $r.Ok -or $r.Message -ne 'startup.add.ok') { throw "not ok: $($r.Message)" }
        $lnkFile = Join-Path $sf 'UcOwn.lnk'
        if (-not (Test-Path $lnkFile)) { throw 'no lnk' }
        $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($lnkFile)
        $okLnk = ($l.Description -ceq 'Added by Update Center') -and $l.TargetPath -eq $fakeExe -and $l.Arguments -eq '--min /x' -and $l.WorkingDirectory -eq $toolDir
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
        $okLnk -and $r.Item.AddedByUs -and $r.Item.Name -eq 'UcOwn' -and $r.Item.Category -eq 'Standard' -and $r.Item.Kind -eq 'folder'
    }
    Check 'Add: existing name refused (no overwrite)' {
        $r = Add-StartupItem -Path $fakeExe -Name 'UcOwn' -StartupFolder $sf
        (-not $r.Ok) -and $r.Message -eq 'startup.add.exists'
    }
    Check 'Add: bat accepted, default name from file' {
        $r = Add-StartupItem -Path $fakeBat -StartupFolder $sf
        $r.Ok -and $r.Item.Name -eq 'uctool' -and (Test-Path (Join-Path $sf 'uctool.lnk'))
    }
    # foreign shortcut: different description
    $sh = New-Object -ComObject WScript.Shell
    $fl = $sh.CreateShortcut((Join-Path $sf 'UcForeign.lnk')); $fl.TargetPath = $fakeExe; $fl.Description = 'Somebody else'; $fl.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)

    Check 'Get-StartupItems -StartupFolder: category Standard, AddedByUs only for ours' {
        $l = @(Get-StartupItems -StartupFolder $sf)
        if ($l.Count -ne 3) { throw "count $($l.Count)" }
        foreach ($i in $l) { if ($i.Category -ne 'Standard' -or $i.Kind -ne 'folder') { throw "bad $($i.Name)" } }
        $own = @($l | Where-Object { $_.Name -eq 'UcOwn' })[0]; $for = @($l | Where-Object { $_.Name -eq 'UcForeign' })[0]
        $own.AddedByUs -and -not $for.AddedByUs
    }
    Check 'items carry Category/Kind/Risk/RiskReason/AddedByUs' {
        foreach ($i in @(Get-StartupItems -StartupFolder $sf)) {
            foreach ($p in @('Category', 'Kind', 'Risk', 'RiskReason', 'AddedByUs', 'IsSystemTask', 'FilePath')) { if (-not $i.PSObject.Properties[$p]) { throw "missing $p" } }
            if ($i.Risk -notin @('Low', 'Medium', 'High') -or $i.RiskReason -notlike 'startup.risk.reason.*') { throw "bad risk $($i.Risk) $($i.RiskReason)" }
        }
        $true
    }
    Check 'Remove: foreign shortcut refused (startup.removeOnlyOwn)' {
        $for = @(Get-StartupItems -StartupFolder $sf | Where-Object { $_.Name -eq 'UcForeign' })[0]
        $r = Remove-StartupItem -Item $for -StartupFolder $sf
        (-not $r.Ok) -and $r.Message -eq 'startup.removeOnlyOwn' -and (Test-Path (Join-Path $sf 'UcForeign.lnk'))
    }
    Check 'Remove: tampered AddedByUs flag does not help' {
        $for = @(Get-StartupItems -StartupFolder $sf | Where-Object { $_.Name -eq 'UcForeign' })[0]
        $for.AddedByUs = $true
        $r = Remove-StartupItem -Item $for -StartupFolder $sf
        (-not $r.Ok) -and $r.Message -eq 'startup.removeOnlyOwn' -and (Test-Path (Join-Path $sf 'UcForeign.lnk'))
    }
    Check 'Remove: our shortcut elsewhere / run item / task refused' {
        $own = @(Get-StartupItems -StartupFolder $sf | Where-Object { $_.Name -eq 'UcOwn' })[0]
        $other = Join-Path $toolDir 'other'; [void](New-Item -ItemType Directory -Path $other -Force)
        $r1 = Remove-StartupItem -Item $own -StartupFolder $other
        $run = [pscustomobject]@{ Id = 'r'; Name = 'RunThing'; Kind = 'run'; FilePath = ''; AddedByUs = $true }
        $r2 = Remove-StartupItem -Item $run -StartupFolder $sf
        $tk = [pscustomobject]@{ Id = 't'; Name = 'TaskThing'; Kind = 'task'; AddedByUs = $true }
        $r3 = Remove-StartupItem -Item $tk -StartupFolder $sf
        (-not $r1.Ok) -and $r1.Message -eq 'startup.removeOnlyOwn' -and (-not $r2.Ok) -and $r2.Message -eq 'startup.removeOnlyOwn' -and (-not $r3.Ok) -and $r3.Message -eq 'startup.removeOnlyOwn' -and (Test-Path (Join-Path $sf 'UcOwn.lnk'))
    }
    Check 'Remove: DryRun on our shortcut keeps it' {
        $own = @(Get-StartupItems -StartupFolder $sf | Where-Object { $_.Name -eq 'UcOwn' })[0]
        $r = Remove-StartupItem -Item $own -StartupFolder $sf -DryRun
        $r.Ok -and $r.DryRun -and (Test-Path (Join-Path $sf 'UcOwn.lnk'))
    }
    Check 'Remove: our shortcut leaves the folder (Recycle Bin), foreign one stays' {
        $own = @(Get-StartupItems -StartupFolder $sf | Where-Object { $_.Name -eq 'UcOwn' })[0]
        $r = Remove-StartupItem -Item $own -StartupFolder $sf -PermanentForTest
        if (-not $r.Ok -or $r.Message -ne 'startup.remove.ok') { throw "not ok: $($r.Message)" }
        (-not (Test-Path (Join-Path $sf 'UcOwn.lnk'))) -and (Test-Path (Join-Path $sf 'UcForeign.lnk'))
    }
} finally {
    Remove-Item -LiteralPath $sf -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toolDir -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'temporary startup folders removed' { -not (Test-Path $sf) -and -not (Test-Path $toolDir) }

# --- real items, read-only ---------------------------------------------------------
$real = @()
Check 'Get-StartupItems (real, read-only)' {
    $script:real = @(Get-StartupItems)
    foreach ($i in $script:real) {
        foreach ($p in @('Id', 'Name', 'Publisher', 'Command', 'Location', 'Scope', 'Enabled', 'Protected', 'ProtectReason', 'Impact', 'ImagePath', 'Exists', 'Category', 'Kind', 'Risk', 'RiskReason', 'AddedByUs')) {
            if (-not $i.PSObject.Properties[$p]) { throw "missing property $p" }
        }
        if (($i.Kind -eq 'task') -ne ($i.Category -eq 'Advanced')) { throw "category/kind mismatch for $($i.Name)" }
    }
    $true
}
Write-Host ("  items: {0} total, {1} enabled, {2} disabled, {3} protected" -f @($real).Count, @($real | Where-Object { $_.Enabled }).Count, @($real | Where-Object { -not $_.Enabled }).Count, @($real | Where-Object { $_.Protected }).Count)
Check 'live: host-launched third-party items (e.g. Logitech Download Assistant) are toggleable with Risk Medium' {
    foreach ($i in @($script:real | Where-Object { $_.ImagePath -match '(?i)\\(rundll32|cmd|regsvr32)\.exe$' -and $_.Command -notmatch '(?i)windows\\system32\\\w+\.dll' -and $_.Publisher -notmatch 'Microsoft' })) { if ($i.Protected -and $i.ProtectReason -eq 'startup.protect.windows') { throw "$($i.Name) wrongly windows-protected" }; if (-not $i.Protected -and $i.Risk -ne 'Medium' -and $i.Risk -ne 'High') { throw "$($i.Name) risk $($i.Risk)" } }
    $true
}
foreach ($g in @($real | Group-Object Location)) { Write-Host ("    {0}: {1}" -f $g.Name, $g.Count) }
foreach ($i in $real) {
    Write-Host ("    - [{0}] {1} | {2} | {3} | enabled={4} protected={5} {6} | risk={7} | exists={8}" -f $i.Location, $i.Name, $i.Publisher, $i.Category, $i.Enabled, $i.Protected, $i.ProtectReason, $i.Risk, $i.Exists) -ForegroundColor DarkGray
}

# --- toggle round-trip against a temporary key only --------------------------------
$tmp = "HKCU:\Software\UpdateCenterTest\" + [guid]::NewGuid().ToString('N')
$runRoot = "$tmp\Run"; $apprRoot = "$tmp\Approved"
try {
    [void](New-Item -Path $runRoot -Force)
    # a non-Windows, unsigned dummy image (notepad.exe would be protected by the Microsoft-under-WINDIR rule)
    $testExeDir = Join-Path ([IO.Path]::GetTempPath()) ("uc-su-run-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $testExeDir -Force)
    Set-Content -LiteralPath (Join-Path $testExeDir 'testapp.exe') -Value 'x'
    $testCmd = '"' + (Join-Path $testExeDir 'testapp.exe') + '" /x'
    [void](New-ItemProperty -Path $runRoot -Name 'TestApp' -Value $testCmd -PropertyType String)
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
        (Get-Item $runRoot).GetValue('TestApp') -eq $testCmd
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
    if ($testExeDir) { Remove-Item -LiteralPath $testExeDir -Recurse -Force -ErrorAction SilentlyContinue }
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
