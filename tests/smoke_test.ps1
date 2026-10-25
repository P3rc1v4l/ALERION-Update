<#
.SYNOPSIS
    Headless smoke test for ALERION Update. Exit code 0 = all checks passed.
    Runs without admin rights and without installing anything.
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

$env:ALERION_UPDATE_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("alerion-smoke-" + [guid]::NewGuid().ToString('N'))
Write-Host 'ALERION Update smoke test' -ForegroundColor Cyan

$scripts = Get-ChildItem $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($f in $scripts) {
    Check "syntax $($f.Name)" {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        if ($errs.Count) { throw ($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
    }
    Check "ascii-only $($f.Name)" {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($bad) { throw "$bad non-ASCII bytes (Windows PowerShell 5.1 would misread them)" }
    }
}

Import-Module (Join-Path $src 'Common.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Providers.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Report.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $src 'Scheduler.psm1') -DisableNameChecking -Force

Check 'version file is SemVer' { (Get-AppVersion) -match '^\d+\.\d+\.\d+$' }
Check 'default config is valid' { (Test-Config (Get-DefaultConfig)).Count -eq 0 }
Check 'config merge keeps defaults for missing keys' {
    $user = '{"Mode":"Silent","Sources":{"Nvidia":false},"Unknown":1}' | ConvertFrom-Json
    $m = Merge-Config -Defaults (Get-DefaultConfig) -User $user
    ($m.Mode -eq 'Silent') -and ($m.Sources.Nvidia -eq $false) -and ($m.Sources.Winget -eq $true) -and -not ($m.PSObject.Properties.Name -contains 'Unknown')
}
Check 'config validation rejects bad values' {
    $c = Get-DefaultConfig; $c.Schedule.Time = '25:99'; $c.SelfUpdate.Repo = 'bad repo'
    (Test-Config $c).Count -eq 2
}
Check 'config save/load roundtrip' {
    $c = Get-DefaultConfig; $c.ExcludedPackages = @('Unity.*'); Save-Config $c
    (Get-Config).ExcludedPackages[0] -eq 'Unity.*'
}

$i18n = Get-Content (Join-Path $src 'i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'i18n DE/EN key parity' {
    $de = $i18n.de.PSObject.Properties.Name; $en = $i18n.en.PSObject.Properties.Name
    $diff = Compare-Object $de $en
    if ($diff) { throw ($diff | ForEach-Object { $_.InputObject }) -join ', ' }
}
Check 'all msg.* keys used in code exist' {
    $code = ($scripts | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $used = [regex]::Matches($code, "'(msg\.[A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $missing = @($used | Where-Object { -not ($i18n.de.PSObject.Properties.Name -contains $_) })
    if ($missing) { throw ($missing -join ', ') }
}

$fixture = @"
   - \ |
Name                                             Id                                      Version         Available      Source
------------------------------------------------------------------------------------------------------------------------------
AIDA64 Extreme v7.50                             FinalWire.AIDA64.Extreme                7.50            8.40           winget
FiveM                                            Cfx.re.FiveM                            Unknown         2.0.0.25776    winget
Python Launcher                                  Python.Launcher                         < 3.14.7        3.14.7         winget
Windows-Subsystem f$([char]0xFC)r Linux                      Microsoft.WSL                           2.7.8.0         2.7.14         winget
NVIDIA App                                       XP8CLZL93F5Z4P                          1.0             2.0            msstore
35 upgrades available.
"@
Check 'winget table parser' {
    $rows = ConvertFrom-WingetUpgradeTable -Text $fixture
    if ($rows.Count -ne 5) { throw "expected 5 rows, got $($rows.Count)" }
    ($rows[0].Id -eq 'FinalWire.AIDA64.Extreme') -and ($rows[0].Version -eq '7.50') -and ($rows[0].Available -eq '8.40') -and
    ($rows[1].Version -eq 'Unknown') -and ($rows[2].Version -eq '< 3.14.7') -and ($rows[2].Id -eq 'Python.Launcher') -and
    ($rows[3].Name -like 'Windows-Subsystem*') -and ($rows[4].Source -eq 'msstore')
}
Check 'all T keys used in the GUI/engine exist (DE)' {
    $code = ($scripts | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $used = [regex]::Matches($code, "\bT '([a-zA-Z]+\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $missing = @($used | Where-Object { -not ($i18n.de.PSObject.Properties.Name -contains $_) })
    if ($missing) { throw ($missing -join ', ') }
}
Check 'priority rules' {
    $p = { param($src, $id, $from, $to) Get-UpdatePriority -Item ([pscustomobject]@{ Source = $src; Id = $id; From = $from; To = $to }) }
    $cases = @(
        @('winget', 'Google.Chrome', '1', '2', 'Critical'), @('winget', 'Microsoft.DotNet.Runtime.8', '8.0.1', '8.0.2', 'Critical'),
        @('winget', 'OBSProject.OBSStudio', '32', '33', 'Normal'), @('winget', 'Cfx.re.FiveM', 'Unknown', '2.0', 'Optional'),
        @('winget', 'TeamSpeakSystems.TeamSpeakClient', '5.0.0', '6.0.0-beta4.1', 'Optional'), @('gpu', 'NVIDIA driver', '1', '2', 'Important'),
        @('defender', 'signatures', '', '', 'Critical'), @('choco', 'chocolatey', '2.7.3', '2.7.4', 'Critical')
    )
    foreach ($c in $cases) { $got = & $p $c[0] $c[1] $c[2] $c[3]; if ($got -ne $c[4]) { throw "$($c[1]): expected $($c[4]), got $got" } }
    (Test-MajorJump '32.0.4' '33.0.0') -and -not (Test-MajorJump '8.0.23' '8.0.32') -and -not (Test-MajorJump 'Unknown' '1.0')
}
Check 'windows priority uses security categories' {
    $i = [pscustomobject]@{ Source = 'windows'; Id = 'KB1'; From = ''; To = 'KB1' }
    ((Get-UpdatePriority -Item $i -Categories @('Security Updates')) -eq 'Critical') -and ((Get-UpdatePriority -Item $i -Categories @('Updates')) -eq 'Important')
}
Check 'winget list parser (empty columns)' {
    $list = @"
Name                          Id                                            Version Available Source
-----------------------------------------------------------------------------------------------------
AEGIS                         ARP\User\X64\ef6ec825ce55e423fc18908cacbca081 1.0
AIDA64 Extreme v7.50          FinalWire.AIDA64.Extreme                      7.50    8.40      winget
Elgato Stream Deck            Elgato.StreamDeck                             7.6.0             winget
"@
    $r = @(ConvertFrom-WingetListTable -Text $list)
    ($r.Count -eq 3) -and ($r[0].Version -eq '1.0') -and ($r[0].Source -eq '') -and ($r[1].Available -eq '8.40') -and ($r[2].Id -eq 'Elgato.StreamDeck') -and ($r[2].Source -eq 'winget')
}
Check 'config migration schema 1 -> 2' {
    $old = '{"SchemaVersion":1,"Mode":"Silent","SelfUpdate":{"Enabled":true,"Repo":"P3rc1v4l/ALERION-Update"}}'
    [IO.File]::WriteAllText((Get-AppPaths).ConfigPath, $old)
    $c = Get-Config
    ($c.SchemaVersion -eq 2) -and ($c.Mode -eq 'Silent') -and ($c.ScheduleAction -eq 'Install') -and (@($c.AutoInstallPriorities).Count -eq 3) -and ($c.SelfUpdate.Repo -eq 'P3rc1v4l/ALERION-Update')
}
Check 'result keys' { ((New-UpdateResult -Source winget -Name 'X' -Id 'A.B').Key -eq 'winget|A.B') }
Check 'GUI view model compiles' {
    if (-not ('Alerion.UpdateRow' -as [type])) { Add-Type -TypeDefinition (Get-Content (Join-Path $src 'GuiModel.cs') -Raw) }
    $r = New-Object Alerion.UpdateRow; $r.IsUpdate = $true; $r.Excluded = $false; $r.Selectable
}
Check 'winget parser handles empty output' { @(ConvertFrom-WingetUpgradeTable -Text 'No installed package found').Count -eq 0 }
Check 'NVIDIA version conversion' { (ConvertTo-NvidiaVersion '32.0.16.2101') -eq '621.01' -and (ConvertTo-NvidiaVersion '32.0.15.6094') -eq '560.94' }

foreach ($type in 'Daily', 'Weekly', 'BiWeekly', 'Monthly') {
    Check "task XML ($type) is well-formed" {
        $c = Get-DefaultConfig; $c.Schedule.Type = $type
        $x = [xml](New-TaskXml -Description 'test' -Arguments (Get-EngineArguments) -TriggerXml (New-TriggerXml -Schedule $c.Schedule))
        $null -ne $x.Task.Triggers.CalendarTrigger
    }
}

Check 'report HTML renders' {
    $report = [pscustomobject]@{
        AppVersion = '1.0.0'; Computer = 'TEST'; StartedAt = (Get-Date).AddMinutes(-3).ToString('o'); EndedAt = (Get-Date).ToString('o')
        DryRun = $false; RebootRequired = $true; ExitCode = 0; LogFile = 'x.log'
        Counts = [pscustomobject]@{ Updated = 1; Failed = 1; Skipped = 0; Available = 0 }
        Items = @((New-UpdateResult -Source winget -Name 'App <b>' -Id 'A.B' -From '1.0' -To '2.0' -Status Updated),
                  (New-UpdateResult -Source gpu -Name 'GPU' -Status Failed -Message 'msg.timeout' -RebootRequired $true))
    }
    $html = ConvertTo-ReportHtml -Report $report
    ($html -match 'App &lt;b&gt;') -and ($html -notmatch 'msg\.timeout')
}

Check 'GUI XAML loads' {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $w = [Windows.Markup.XamlReader]::Parse((Get-Content (Join-Path $src 'Gui.xaml') -Raw -Encoding UTF8))
    $names = @([regex]::Matches((Get-Content (Join-Path $src 'Gui.xaml') -Raw), 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $gui = Get-Content (Join-Path $src 'Gui.ps1') -Raw
    # every $ui.Name used by the code must exist in the XAML
    $used = [regex]::Matches($gui, '\$ui\.([A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $missing = @($used | Where-Object { $names -notcontains $_ })
    if ($missing) { throw "XAML lacks: $($missing -join ', ')" }
    ($null -ne $w.FindName('DialogLayer')) -and ($null -ne $w.FindName('BtnClose'))
}
Check 'restart estimate is sane' {
    $e = Get-RestartEstimate -WithUpdates $false; $u = Get-RestartEstimate -WithUpdates $true
    ($e.MinMinutes -ge 1) -and ($e.MaxMinutes -ge $e.MinMinutes) -and ($u.MaxMinutes -gt $e.MaxMinutes) -and ((Format-RestartEstimate -Estimate $e) -match '\d')
}
Check 'next time of day is in the future' { (Get-NextTimeOfDay -Time '03:00') -gt (Get-Date) }Check 'icon assets exist' { (Test-Path (Join-Path $root 'assets\icon.ico')) -and (Test-Path (Join-Path $root 'assets\icon.png')) }

Remove-Item $env:ALERION_UPDATE_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failures.Count) { Write-Host "$($failures.Count) check(s) failed, $passed passed." -ForegroundColor Red; exit 1 }
Write-Host "All $passed checks passed." -ForegroundColor Green
exit 0
