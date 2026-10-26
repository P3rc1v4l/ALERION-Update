<#
.SYNOPSIS
    Non-destructive test for src/VendorUpdates.psm1 (no admin, nothing installed or started: parse functions,
    fake folders and -DryRun only). Exit code 0 = all checks passed.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$script:passed = 0

function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok -eq $false) { throw 'returned false' }
        $script:passed++; Write-Host "  [OK]   $Name" -ForegroundColor Green
    } catch {
        $failures.Add("$Name : $($_.Exception.Message)"); Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$env:UPDATECENTER_DATADIR = Join-Path ([IO.Path]::GetTempPath()) ("uc-vendor-test-" + [guid]::NewGuid().ToString('N'))
Write-Host 'Vendor updates module test' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\VendorUpdates.psm1') -Force -DisableNameChecking

# --- static ---
Check 'source is ASCII-only' { $b = [IO.File]::ReadAllBytes((Join-Path $root 'src\VendorUpdates.psm1')); @($b | Where-Object { $_ -gt 127 }).Count -eq 0 }
Check 'i18n: vu keys present in de and en' {
    $j = Get-Content (Join-Path $root 'src\i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $de = @($j.de.PSObject.Properties.Name | Where-Object { $_ -match '^(msg\.)?vu\.' } | Sort-Object); $en = @($j.en.PSObject.Properties.Name | Where-Object { $_ -match '^(msg\.)?vu\.' } | Sort-Object)
    if (($de -join ',') -ne ($en -join ',') -or -not $de.Count) { throw 'key mismatch' }
    $true
}
Check 'message keys used in code exist in i18n.json' {
    $j = Get-Content (Join-Path $root 'src\i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $have = @($j.en.PSObject.Properties.Name)
    $code = Get-Content (Join-Path $root 'src\VendorUpdates.psm1') -Raw
    $used = @([regex]::Matches($code, "'((?:msg\.)?vu\.[A-Za-z.]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($used | Where-Object { $_ -notin $have })
    if ($missing.Count) { throw "missing: $($missing -join ',')" }
    $true
}

# --- vendor detection ---
Check 'Resolve-VendorName' {
    (Resolve-VendorName 'Dell Inc.') -eq 'dell' -and (Resolve-VendorName 'LENOVO') -eq 'lenovo' -and (Resolve-VendorName 'HP') -eq 'hp' -and
    (Resolve-VendorName 'Hewlett-Packard') -eq 'hp' -and (Resolve-VendorName 'ASUSTeK COMPUTER INC.') -eq 'asus' -and (Resolve-VendorName 'Acme') -eq 'other' -and (Resolve-VendorName '') -eq 'other'
}
Check 'Get-SystemVendor returns a vendor' { (Get-SystemVendor).Vendor -in 'dell', 'lenovo', 'hp', 'asus', 'other' }

# --- Dell report ---
$dellXml = @'
<?xml version="1.0" encoding="utf-8"?>
<updates>
  <update><release>ABC12</release><name>Dell Wireless Driver</name><version>22.1.0</version><type>Driver</type><category>Network</category><urgency>Recommended</urgency></update>
  <update><release>XYZ99</release><name>Dell Precision BIOS 1.9.0</name><version>1.9.0</version><type>BIOS</type><category>BIOS</category><urgency>Urgent</urgency></update>
  <update><name>Dell Command Update</name><version>5.4</version><category>Application</category></update>
</updates>
'@
$dell = @(ConvertFrom-DellScanReport -Xml $dellXml)
Check 'Dell report: 3 entries parsed' { $dell.Count -eq 3 -and $dell[0].Id -eq 'ABC12' -and $dell[0].Version -eq '22.1.0' -and $dell[0].Category -eq 'Network' }
Check 'Dell report: missing id gets slug' { $dell[2].Id -eq 'Dell-Command-Update' }
Check 'Dell report: garbage and empty are safe' { @(ConvertFrom-DellScanReport -Xml 'not xml').Count -eq 0 -and @(ConvertFrom-DellScanReport -Xml '').Count -eq 0 }
$dc = @($dell | ForEach-Object { ConvertTo-DellCandidate $_ })
Check 'Dell candidate shape and key' {
    $dc[0].Source -eq 'oem' -and $dc[0].Key -eq 'oem|dell|ABC12' -and $dc[0].Status -eq 'Available' -and $dc[0].Priority -eq 'Important' -and -not $dc[0].ManualOnly -and -not $dc[0].Major
}
Check 'Dell BIOS candidate is ManualOnly + Major + warning' { $dc[1].ManualOnly -and $dc[1].Major -and $dc[1].Message -eq 'vu.bios' -and $dc[1].Priority -eq 'Important' }
Check 'Dell exit codes' {
    (Get-DellExitInfo 0).Kind -eq 'Ok' -and (Get-DellExitInfo 1).Kind -eq 'Reboot' -and (Get-DellExitInfo 500).Kind -eq 'NoUpdates' -and (Get-DellExitInfo 4).Kind -eq 'NoAdmin' -and (Get-DellExitInfo 1002).Kind -eq 'Failed' -and (Get-DellExitInfo -999).Kind -eq 'Timeout'
}

# --- HP report ---
$hpJson = '{"HPIA":{"Recommendations":[{"SoftPaqId":"sp111111","Name":"HP Audio Driver","Version":"6.0.1","Category":"Driver","ReleaseType":"Recommended"},{"SoftPaqId":"sp222222","Name":"HP System BIOS","Version":"01.05.00","Category":"BIOS"}]}}'
$hp = @(ConvertFrom-HpReport -Text $hpJson)
Check 'HP JSON report parsed' { $hp.Count -eq 2 -and $hp[0].Id -eq 'sp111111' -and $hp[0].Version -eq '6.0.1' }
Check 'HP single recommendation (PS 5.1 scalar) parsed' { @(ConvertFrom-HpReport -Text '{"HPIA":{"Recommendations":{"SoftPaqId":"sp1","Name":"X","Version":"1"}}}').Count -eq 1 }
Check 'HP no recommendations / garbage safe' { @(ConvertFrom-HpReport -Text '{"HPIA":{}}').Count -eq 0 -and @(ConvertFrom-HpReport -Text '{bad').Count -eq 0 }
$hpXml = '<HPIA><Recommendations><Recommendation><SoftPaqId>sp3</SoftPaqId><Name>HP Chipset</Name><Version>2.0</Version><Category>Driver</Category></Recommendation></Recommendations></HPIA>'
Check 'HP XML report parsed' { $x = @(ConvertFrom-HpReport -Text $hpXml); $x.Count -eq 1 -and $x[0].Id -eq 'sp3' }
$hc = @($hp | ForEach-Object { ConvertTo-HpCandidate $_ })
Check 'HP candidates: key, BIOS manual only' { $hc[0].Key -eq 'oem|hp|sp111111' -and -not $hc[0].ManualOnly -and $hc[1].ManualOnly -and $hc[1].Major }
Check 'HP exit codes' { (Get-HpExitInfo 0).Kind -eq 'Ok' -and (Get-HpExitInfo 256).Kind -eq 'NoUpdates' -and (Get-HpExitInfo 3010).Kind -eq 'Reboot' }

# --- fake folders: detection without running anything ---
$fake = Join-Path ([IO.Path]::GetTempPath()) ("uc-vendor-fake-" + [guid]::NewGuid().ToString('N'))
$savedPf = $env:ProgramFiles; $savedPf86 = ${env:ProgramFiles(x86)}; $savedLad = $env:LOCALAPPDATA
try {
    New-Item -ItemType Directory -Path "$fake\pf\Dell\CommandUpdate", "$fake\pf\Lenovo\System Update", "$fake\pf\ASUS\AsusDriverHub", "$fake\pf\Google\Update", "$fake\pf\Google\Chrome\Application\120.0.1.0", "$fake\pf\Google\Chrome\Application\121.0.2.0", "$fake\pf86", "$fake\lad\Discord\app-1.0.5", "$fake\lad\Discord\app-1.0.10" -Force | Out-Null
    foreach ($f in 'Dell\CommandUpdate\dcu-cli.exe', 'Lenovo\System Update\tvsu.exe', 'ASUS\AsusDriverHub\ASUS DriverHub.exe', 'Google\Update\GoogleUpdate.exe', 'Google\Chrome\Application\chrome.exe') { Set-Content "$fake\pf\$f" 'x' }
    Set-Content "$fake\lad\Discord\Update.exe" 'x'
    $env:ProgramFiles = "$fake\pf"; ${env:ProgramFiles(x86)} = "$fake\pf86"; $env:LOCALAPPDATA = "$fake\lad"

    Check 'fake: dcu-cli, tvsu, ASUS hub found' { (Get-DellCliPath) -like '*dcu-cli.exe' -and (Get-LenovoCliPath) -like '*tvsu.exe' -and (Get-AsusTools).DriverHubExe -like '*ASUS DriverHub.exe' }
    Check 'fake: Chrome version = highest version dir' { (& (Get-ChromeInfo).GetVersion) -eq '121.0.2.0' }
    Check 'fake: Discord version numeric (1.0.10 > 1.0.5)' { (& (Get-DiscordInfo).GetVersion) -eq '1.0.10' }
    Check 'fake: Lenovo and ASUS candidates are IsCheck / Available' {
        $l = @(Get-LenovoCandidates)[0]; $a = @(Get-AsusCandidates)[0]
        $l.IsCheck -and $l.Status -eq 'Available' -and $l.Key -eq 'oem|lenovo|check' -and $a.Key -eq 'oem|asus|driverhub' -and $a.Message -eq 'vu.asus.open' -and $a.To -eq '' -and $a.IsCheck
    }
    Check 'fake: self-updater candidates (chrome, discord)' {
        $c = @(Get-SelfUpdaterCandidates); $ids = @($c | ForEach-Object { $_.Id })
        ('chrome' -in $ids) -and ('discord' -in $ids) -and (@($c | Where-Object { $_.Id -eq 'discord' })[0].Priority -eq 'Optional') -and (@($c | Where-Object { $_.Id -eq 'chrome' })[0].Key -eq 'selfupdater|chrome') -and (@($c | Where-Object { $_.Source -ne 'selfupdater' }).Count -eq 0)
    }
    Check 'fake: DryRun for Dell/Lenovo/ASUS/Chrome executes nothing' {
        $r = @('oem|dell|ABC12', 'oem|lenovo|check', 'oem|asus|driverhub', 'selfupdater|chrome') | ForEach-Object {
            Invoke-VendorUpdate -Candidate ([pscustomobject]@{ Key = $_; Name = $_; Source = ($_ -split '\|')[0]; Id = 'x' }) -DryRun
        }
        @($r | Where-Object { $_.Status -ne 'Info' -or $_.Message -ne 'msg.vu.dryRun' }).Count -eq 0
    }
    Check 'fake: BIOS candidate is refused even without DryRun' {
        $r = Invoke-VendorUpdate -Candidate $dc[1]
        $r.Status -eq 'Skipped' -and $r.Message -eq 'msg.vu.biosManual'
    }
    Check 'fake: Get-VendorUpdateCandidates -SkipOem returns self-updaters only' {
        $c = @(Get-VendorUpdateCandidates -SkipOem); (@($c | Where-Object { $_.Source -ne 'selfupdater' }).Count -eq 0) -and $c.Count -ge 2
    }
} finally {
    $env:ProgramFiles = $savedPf; ${env:ProgramFiles(x86)} = $savedPf86; $env:LOCALAPPDATA = $savedLad
    Remove-Item $fake -Recurse -Force -ErrorAction SilentlyContinue
}

# --- self-updating app map / hints ---
$map = Get-SelfUpdatingAppMap
Check 'map has the required winget ids with Vendor+Hint' {
    foreach ($id in 'EpicGames.EpicGamesLauncher', 'Valve.Steam', 'Blizzard.BattleNet', 'ElectronicArts.EADesktop', 'Ubisoft.Connect', 'Discord.Discord', 'Google.Chrome', 'Microsoft.Edge') {
        if (-not $map.ContainsKey($id) -or -not $map[$id].Vendor -or $map[$id].Hint -notlike 'vu.hint.*') { throw "bad $id" }
    }
    $true
}
Check 'hint results only for mapped winget rows' {
    $rows = @([pscustomobject]@{ Id = 'Valve.Steam'; Name = 'Steam'; Version = '1'; Available = '2' }, [pscustomobject]@{ Id = 'Other.App'; Name = 'O'; Version = '1'; Available = '2' })
    $h = @(Get-SelfUpdateHintResults -WingetUpgrades $rows)
    $h.Count -eq 1 -and $h[0].Status -eq 'Info' -and $h[0].Key -eq 'selfupdater|Valve.Steam' -and $h[0].Message -eq 'vu.hint.steam'
}
Check 'Info hint candidate is not installable (Skipped, no process)' {
    $h = @(Get-SelfUpdateHintResults -WingetUpgrades @([pscustomobject]@{ Id = 'Valve.Steam'; Name = 'Steam'; Version = '1'; Available = '2' }))[0]
    (Invoke-VendorUpdate -Candidate $h).Status -eq 'Skipped'
}

# --- robustness ---
Check 'Invoke-VendorUpdate never throws on junk' {
    $a = Invoke-VendorUpdate -Candidate ([pscustomobject]@{ Key = 'garbage' }) -DryRun
    $b = Invoke-VendorUpdate -Candidate ([pscustomobject]@{ Key = 'oem|nobody|1'; Name = 'n' }) -DryRun
    $c = Invoke-VendorUpdate -Candidate ([pscustomobject]@{ }) -DryRun
    $a.Status -eq 'Skipped' -and $b.Status -eq 'Skipped' -and $c.Status -eq 'Skipped'
}
Check 'Wait-VuVersionChange returns once the version changes' {
    $script:n = 0
    (Wait-VuVersionChange -GetVersion { $script:n++; if ($script:n -ge 2) { '2' } else { '1' } } -From '1' -Minutes 1 -PollSeconds 1) -eq '2'
}

# --- live read-only (this machine) ---
$live = @(Get-VendorUpdateCandidates)
Check 'live: Get-VendorUpdateCandidates runs, returns result objects' {
    foreach ($c in $live) { foreach ($p in 'Key', 'Source', 'Name', 'Status', 'Priority', 'IsCheck', 'Major', 'ManualOnly', 'Vendor') { if (-not ($c.PSObject.Properties.Name -contains $p)) { throw "$($c.Key) lacks $p" } } }
    $true
}
Write-Host "  live detection: vendor=$((Get-SystemVendor).Vendor); candidates:" -ForegroundColor DarkGray
foreach ($c in $live) { Write-Host ("    {0,-28} {1,-10} {2,-9} from='{3}' {4}" -f $c.Key, $c.Status, $c.Priority, $c.From, $c.Message) -ForegroundColor DarkGray }

Remove-Item $env:UPDATECENTER_DATADIR -Recurse -Force -ErrorAction SilentlyContinue
if ($failures.Count) {
    Write-Host ("`n{0} check(s) failed:" -f $failures.Count) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll $($script:passed) checks passed." -ForegroundColor Green
exit 0
