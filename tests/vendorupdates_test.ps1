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
    Check 'fake: Lenovo and ASUS fallback candidates are IsCheck / Available (ASUS API unreachable)' {
        # API unreachable -> the old DriverHub hint (no network in this check).
        & (Get-Module VendorUpdates) { $script:AsusHooks.GetText = { param($u) throw 'offline (test)' } }
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
    Check 'fake: ASUS fallback also when no model name is known' {
        & (Get-Module VendorUpdates) { $script:AsusHooks.Models = { @() }; $script:AsusHooks.GetText = { param($u) throw 'must not be called' } }
        $a = @(Get-AsusCandidates); $a.Count -eq 1 -and $a[0].Key -eq 'oem|asus|driverhub'
    }
    Check 'fake: trusted-path check with redirected ProgramFiles' {
        (Test-VuTrustedPath "$fake\pf\Dell\CommandUpdate\dcu-cli.exe") -and -not (Test-VuTrustedPath "$fake\lad\Discord\Update.exe")
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

# --- ASUS web API: parsing, versions, matching (saved, trimmed sample answers; no network) ---
Import-Module (Join-Path $root 'src\VendorUpdates.psm1') -Force -DisableNameChecking
$mod = Get-Module VendorUpdates
function Set-Hook { param([string]$Table, [string]$Name, [scriptblock]$Block) & $mod { param($t, $n, $b) (Get-Variable -Name $t -Scope Script -ValueOnly)[$n] = $b } $Table $Name $Block }

# Trimmed from GetPDDrivers?website=global&model=ROG%20STRIX%20X870E-E%20GAMING%20WIFI&osid=52 (2026-10-26).
$asusSample = @'
{"Result":{"Count":9,"Obj":[
 {"Name":"LAN","Count":2,"Files":[
  {"Id":"1@66@6@1@52@5@DRV_LAN_Realtek_8126_8127_TP_W11_64_V1128501224_20260206B.zip","Version":"11.28.50.1224","Title":"Realtek LAN Driver V11.28.50.1224 for Windows 11 64-bit.(WHQL)","Lang":null,"Description":"","FileSize":"14.57 MB","ReleaseDate":"2026/02/23","IsRelease":"1","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/04LAN/DRV_LAN_Realtek_8126_8127_TP_W11_64_V1128501224_20260206B.zip?model=ROG STRIX X870E-E GAMING WIFI","China":""},"HardwareInfoList":[],"Reboot":"0","sha256":"B4248E339E6195BE8BD0A33C1F9B69F2259DE48778B55231F8E4DFF59905E80A"},
  {"Id":"1@LAN-old","Version":"1126.21.901.2024","Title":"Realtek LAN Driver V1126.21.901.2024 for Windows 11.(WHQL)","FileSize":"14.3 MB","ReleaseDate":"2025/01/09","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/old.zip","China":""},"sha256":""}]},
 {"Name":"Wireless","Count":1,"Files":[{"Id":"1@W","Version":"5.7.0.6054","Title":"MTK WiFi Driver V5.7.0.6054 for Windows 11 64-bit.","ReleaseDate":"2026/07/16","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/08WIRELESS/w.zip","China":""},"sha256":"AA"}]},
 {"Name":"Chipset","Count":1,"Files":[{"Id":"1@C","Version":"8.09.10.2141","Title":"AMD Chipset Driver V8.09.10.2141 for Windows 10 64-bit, Windows 11 64-bit.(WHQL)","ReleaseDate":"2026/10/19","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/03CHIPSET/c.zip","China":""},"sha256":"BB"}]},
 {"Name":"VGA Drivers","Count":2,"Files":[
  {"Id":"1@V1","Version":"2026.04.15","Title":"AMD Graphics Driver V2026.04.15 (Package version)  for Windows 10 64-bit, Windows 11 64-bit.(WHQL)","ReleaseDate":"2026/06/08","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/07VGA/v1.zip","China":""},"sha256":"CC"},
  {"Id":"1@V2","Version":"32.0.21036.18","Title":"AMD Graphics Driver V32.0.21036.18 for Windows 10 64-bit, Windows 11 64-bit.(WHQL)","ReleaseDate":"2025/12/10","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/07VGA/v2.zip","China":""},"sha256":"DD"}]},
 {"Name":"USB","Count":1,"Files":[{"Id":"1@U","Version":"10.0.28000.118","Title":"REALTEK UCM Driver V10.0.28000.118 for Windows 10/11 64-bit.","ReleaseDate":"2026/07/16","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/06USB/u.zip","China":""},"sha256":"EE"}]},
 {"Name":"Bluetooth","Count":1,"Files":[{"Id":"1@B","Version":"3.1.0.1571","Title":"QCA Bluetooth Driver V3.1.0.1571 for Windows 11 64-bit.","ReleaseDate":"2026/05/25","DownloadUrl":{"Global":"https://dlcdnets.asus.com/b.zip","China":""},"sha256":""}]},
 {"Name":"Software and Utility","Count":1,"Files":[{"Id":"1@S","Version":"1.2.9","Title":"USB Wattage Watcher V1.2.9 for Windows 11,Windows 10 64-bit.","ReleaseDate":"2024/09/09","DownloadUrl":{"Global":"https://dlcdnets.asus.com/s.zip","China":""},"sha256":""}]}
]},"Status":"SUCCESS","Message":"SUCCESS"}
'@
# Trimmed from rog.asus.com/support/webapi/product/GetPDBIOS?website=global&model=rog-strix-x870e-e-gaming-wifi&cpu=&pdid=
$biosSample = '{"Result":{"Count":2,"Obj":[{"Name":"BIOS","Count":1,"Files":[{"Id":"1@BIOS","Version":"2503","Title":"","ReleaseDate":"2026/09/22","DownloadUrl":{"Global":"https://dlcdnets.asus.com/pub/ASUS/mb/BIOS/ROG-STRIX-X870E-E-GAMING-WIFI-ASUS-2503.ZIP?model=x","China":""},"sha256":"8714"}]},{"Name":"Firmware","Count":1,"Files":[{"Id":"1@FW","Version":"4242: 250708, IT8857: 0206","Title":"ASUS 4242 and PD-GX Firmware Windows Update Tool","ReleaseDate":"2025/12/29","DownloadUrl":{"Global":"https://dlcdnets.asus.com/f.zip","China":""},"sha256":""}]}]},"Status":"SUCCESS","Message":"SUCCESS"}'

$parsed = ConvertFrom-AsusDriverResponse -Json $asusSample
$items = @($parsed.Items)
Check 'ASUS parse: categories, versions, dates, URLs, SHA-256' {
    $f = $items[0]
    $parsed.Ok -and $items.Count -eq 9 -and $f.Category -eq 'LAN' -and $f.Version -eq '11.28.50.1224' -and $f.ReleaseDate -eq [datetime]'2026-02-23' -and
    $f.Url -like 'https://dlcdnets.asus.com/pub/ASUS/mb/04LAN/*' -and $f.Sha256 -eq 'B4248E339E6195BE8BD0A33C1F9B69F2259DE48778B55231F8E4DFF59905E80A' -and
    (@($items | Where-Object { $_.Category -eq 'Wireless' }).Count -eq 1)
}
Check 'ASUS parse: FAIL answer, garbage and empty are Ok=false' {
    -not (ConvertFrom-AsusDriverResponse -Json '{"Result":null,"Status":"FAIL","Message":"FAIL"}').Ok -and -not (ConvertFrom-AsusDriverResponse -Json '<html>').Ok -and -not (ConvertFrom-AsusDriverResponse -Json '').Ok
}
Check 'ASUS URLs: drivers by board name, BIOS by slug' {
    (Get-AsusDriversUrl -Model 'ROG STRIX X870E-E GAMING WIFI' -OsId '52') -eq 'https://www.asus.com/support/api/product.asmx/GetPDDrivers?website=global&model=ROG%20STRIX%20X870E-E%20GAMING%20WIFI&osid=52&pdhashedid=' -and
    (@(Get-AsusBiosUrls -Model 'ROG STRIX X870E-E GAMING WIFI')[0]) -like '*rog.asus.com/support/webapi/product/GetPDBIOS?*model=rog-strix-x870e-e-gaming-wifi*'
}
Check 'version compare: same scheme compares, different schemes are not comparable' {
    (Compare-AsusVersion '11.28.50.1224' '11.21.0901.2024') -eq 1 -and (Compare-AsusVersion '10.0.26100.117' '10.0.28000.118') -eq -1 -and
    (Compare-AsusVersion '5.7.0.6054' '5.7.0.6054') -eq 0 -and (Compare-AsusVersion '2503' '1715') -eq 1 -and (Compare-AsusVersion 'v1.01.10' '1.1.9') -eq 1 -and
    ($null -eq (Compare-AsusVersion '11.28.50.1224' '1126.21.901.2024')) -and ($null -eq (Compare-AsusVersion '2026.04.15' '32.0.21042.62')) -and
    ($null -eq (Compare-AsusVersion '4242: 250708' '1.0.0.0')) -and ($null -eq (Compare-AsusVersion '' '1.0')) -and ($null -eq (Compare-AsusVersion 'abc' 'def'))
}

$fakeDrivers = @(
    [pscustomobject]@{ DeviceClass = 'NET'; DriverProviderName = 'Realtek'; DeviceName = 'Realtek PCIe 5GbE Family Controller'; DriverVersion = '1126.21.901.2024'; DriverDate = [datetime]'2024-03-09' }
    [pscustomobject]@{ DeviceClass = 'NET'; DriverProviderName = 'MediaTek, Inc.'; DeviceName = 'MediaTek Wi-Fi 7 MT7927 Wireless LAN Card'; DriverVersion = '5.7.0.6054'; DriverDate = [datetime]'2026-06-11' }
    [pscustomobject]@{ DeviceClass = 'DISPLAY'; DriverProviderName = 'Advanced Micro Devices, Inc.'; DeviceName = 'AMD Radeon(TM) Graphics'; DriverVersion = '32.0.21042.62'; DriverDate = [datetime]'2026-04-17' }
    [pscustomobject]@{ DeviceClass = 'USB'; DriverProviderName = 'Realtek Semiconductor Corp.'; DeviceName = 'Realtek UcmCx Client Device'; DriverVersion = '10.0.26100.117'; DriverDate = [datetime]'2024-09-18' }
    [pscustomobject]@{ DeviceClass = 'DISPLAY'; DriverProviderName = 'NVIDIA'; DeviceName = 'NVIDIA GeForce RTX 5070 Ti'; DriverVersion = '32.0.16.2101'; DriverDate = [datetime]'2026-10-19' }
)
$fakePrograms = @(
    [pscustomobject]@{ Name = 'Realtek Ethernet Controller Driver'; Version = '11.21.0901.2024' }
    [pscustomobject]@{ Name = 'AMD Chipset Software'; Version = '8.03.25.247' }
    [pscustomobject]@{ Name = 'AMD Software'; Version = '2026.04.15' }
    [pscustomobject]@{ Name = 'USB Wattage Watcher'; Version = '1.2.14' }
)
$asusData = [pscustomobject]@{ Model = 'ROG STRIX X870E-E GAMING WIFI'; Drivers = $items; Bios = @((ConvertFrom-AsusDriverResponse -Json $biosSample).Items) }
$rows = @(Get-AsusAnalysis -Data $asusData -Drivers $fakeDrivers -Programs $fakePrograms -BiosVersion '1715')
$cands = @($rows | Where-Object { $_.Candidate } | ForEach-Object { $_.Candidate })
function Get-Cand { param([string]$Key) @($cands | Where-Object { $_.Key -eq $Key })[0] }
Check 'ASUS match: exactly LAN, chipset, UCM and BIOS are candidates' {
    $keys = @($cands | ForEach-Object { $_.Key } | Sort-Object)
    ($keys -join ',') -eq 'oem|asus|bios,oem|asus|chipset-amd,oem|asus|lan-realtek,oem|asus|ucm-realtek'
}
Check 'ASUS match: LAN compared with the package version (same scheme), INF install' {
    $c = Get-Cand 'oem|asus|lan-realtek'
    $c.Status -eq 'Available' -and $c.From -eq '11.21.0901.2024' -and $c.To -eq '11.28.50.1224' -and $c.InstallMode -eq 'inf' -and $c.Message -eq 'vu.asus.auto' -and
    $c.Priority -eq 'Important' -and $c.Vendor -eq 'asus' -and -not $c.ManualOnly -and $c.Sha256 -and $c.DownloadUrl -like 'https://dlcdnets.asus.com/*'
}
Check 'ASUS match: chipset via uninstall entry -> interactive installer' { $c = Get-Cand 'oem|asus|chipset-amd'; $c.InstallMode -eq 'installer' -and $c.Message -eq 'vu.asus.interactive' -and $c.From -eq '8.03.25.247' }
Check 'ASUS match: BIOS is ManualOnly + Major, firmware tools are not listed' {
    $c = Get-Cand 'oem|asus|bios'; $c.ManualOnly -and $c.Major -and $c.Message -eq 'vu.bios' -and $c.From -eq '1715' -and $c.To -eq '2503' -and -not ($rows | Where-Object { $_.Group -match 'firmware' })
}
Check 'ASUS match: up to date (WiFi equal, VGA package equal), absent device (QCA BT) and newer utility are not candidates' {
    (@($rows | Where-Object { $_.Group -eq 'bt-qca' })[0].Decision -eq 'no matching device installed') -and -not (Get-Cand 'oem|asus|wifi-mtk') -and -not (Get-Cand 'oem|asus|vga-amd') -and
    -not ($cands | Where-Object { $_.Key -like 'oem|asus|util-*' })
}
Check 'ASUS match: different version scheme only -> Info, never Available' {
    $r2 = @(Get-AsusAnalysis -Data $asusData -Drivers $fakeDrivers -Programs @() -BiosVersion '')
    $lan = @($r2 | Where-Object { $_.Group -eq 'lan-realtek' })[0].Candidate; $vga = @($r2 | Where-Object { $_.Group -eq 'vga-amd' })[0].Candidate
    $lan.Status -eq 'Info' -and $lan.Message -eq 'vu.asus.unsure' -and $vga.Status -eq 'Info' -and -not (@($r2 | Where-Object { $_.Group -eq 'bios' }).Count -and @($r2 | Where-Object { $_.Group -eq 'bios' })[0].Candidate)
}
Check 'ASUS match: own install record bridges pnputil installs (no endless re-offer)' {
    $drv = @($fakeDrivers | ForEach-Object { $_ }) ; $drv[0] = [pscustomobject]@{ DeviceClass = 'NET'; DriverProviderName = 'Realtek'; DeviceName = 'Realtek PCIe 5GbE Family Controller'; DriverVersion = '1128.50.1224.2026'; DriverDate = [datetime]'2026-01-20' }
    $rec = @{ 'lan-realtek' = [pscustomobject]@{ Version = '11.28.50.1224'; Pnp = @('1128.50.1224.2026') } }
    $with = @(Get-AsusAnalysis -Data $asusData -Drivers $drv -Programs $fakePrograms -Records $rec | Where-Object { $_.Group -eq 'lan-realtek' })[0]
    $stale = @{ 'lan-realtek' = [pscustomobject]@{ Version = '11.28.50.1224'; Pnp = @('9.9.9.9') } }
    $without = @(Get-AsusAnalysis -Data $asusData -Drivers $drv -Programs $fakePrograms -Records $stale | Where-Object { $_.Group -eq 'lan-realtek' })[0]
    $null -eq $with.Candidate -and $without.Candidate.Status -eq 'Available'
}

# --- host allow-list ---
Check 'ASUS URL allow-list accepts only https *.asus.com' {
    (Test-AsusUrl 'https://dlcdnets.asus.com/pub/ASUS/mb/04LAN/x.zip?model=ROG STRIX X870E-E GAMING WIFI') -and (Test-AsusUrl 'https://www.asus.com/support/api/product.asmx/GetPDDrivers') -and
    -not (Test-AsusUrl 'http://dlcdnets.asus.com/x.zip') -and -not (Test-AsusUrl 'https://dlcdnets.asus.com.evil.example/x.zip') -and -not (Test-AsusUrl 'https://evilasus.com/x.zip') -and
    -not (Test-AsusUrl 'https://dlcdnets.asus.com:8443/x.zip') -and -not (Test-AsusUrl 'https://user@dlcdnets.asus.com/x.zip') -and -not (Test-AsusUrl 'ftp://dlcdnets.asus.com/x.zip') -and
    -not (Test-AsusUrl 'https://127.0.0.1:53000/asus') -and -not (Test-AsusUrl '') -and -not (Test-AsusUrl 'not a url')
}
Check 'ASUS: download from a foreign host is rejected before anything runs (even without -DryRun)' {
    $global:ucDl = 0
    Set-Hook 'AsusHooks' 'Download' { param($u, $p) $global:ucDl++ }
    $c = (Get-Cand 'oem|asus|lan-realtek').PSObject.Copy(); $c.DownloadUrl = 'https://downloads.example.com/DRV_LAN.zip'
    $r = Invoke-VendorUpdate -Candidate $c
    $r.Status -eq 'Failed' -and $r.Message -eq 'msg.vu.asus.hostRejected' -and $global:ucDl -eq 0
}

# --- signature check (mocked Get-AuthenticodeSignature) ---
function New-SigMock { param([string]$Status, [string]$Subject) $o = [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }; return { $o }.GetNewClosure() }
Check 'signature: Valid + WHQL / ASUS signer accepted' {
    (Test-AsusFileSignature -Path 'x.cat' -Provider (New-SigMock 'Valid' 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, C=US')).Ok -and
    (Test-AsusFileSignature -Path 'x.exe' -Provider (New-SigMock 'Valid' 'CN=ASUSTeK Computer Inc., O=ASUSTeK Computer Inc., L=Taipei, C=TW')).Ok
}
Check 'signature: invalid status, unknown signer, missing and throwing provider rejected' {
    -not (Test-AsusFileSignature -Path 'x' -Provider (New-SigMock 'HashMismatch' 'CN=ASUSTeK Computer Inc.')).Ok -and
    -not (Test-AsusFileSignature -Path 'x' -Provider (New-SigMock 'NotSigned' '')).Ok -and
    -not (Test-AsusFileSignature -Path 'x' -Provider (New-SigMock 'Valid' 'CN=Evil Corp, O=Evil Corp')).Ok -and
    -not (Test-AsusFileSignature -Path 'x' -Provider { $null }).Ok -and -not (Test-AsusFileSignature -Path 'x' -Provider { throw 'boom' }).Ok
}
Check 'pnputil outcome: 0 ok, 3010 reboot, 259 no device, other failed' {
    $a = Get-PnputilOutcome @([pscustomobject]@{ ExitCode = 0; Output = '' }); $b = Get-PnputilOutcome @([pscustomobject]@{ ExitCode = 3010; Output = '' }, [pscustomobject]@{ ExitCode = 259; Output = '' })
    $c = Get-PnputilOutcome @([pscustomobject]@{ ExitCode = 259; Output = '' }); $d = Get-PnputilOutcome @([pscustomobject]@{ ExitCode = 5; Output = '' })
    $a.Kind -eq 'Updated' -and -not $a.Reboot -and $b.Kind -eq 'Updated' -and $b.Reboot -and $c.Kind -eq 'NoDevice' -and $d.Kind -eq 'Failed' -and $d.Text -eq 'pnputil exit 5'
}

# --- install flow with mocks (no network, no admin, nothing installed) ---
$global:ucCalls = New-Object System.Collections.Generic.List[string]
Set-Hook 'AsusHooks' 'Download' { param($u, $p) $global:ucCalls.Add("download $u"); Copy-Item -LiteralPath $global:ucZip -Destination $p -Force }
Set-Hook 'AsusHooks' 'Pnputil' { param($inf) $global:ucCalls.Add("pnputil $inf"); [pscustomobject]@{ ExitCode = 3010; Output = 'System reboot is needed'; TimedOut = $false } }
Set-Hook 'AsusHooks' 'Signature' { param($p) $global:ucCalls.Add("sig $p"); [pscustomobject]@{ Status = $global:ucSigStatus; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation' } } }
Set-Hook 'AsusHooks' 'Drivers' { @() }
Set-Hook 'VuHooks' 'IsElevated' { $true }
Set-Hook 'VuHooks' 'InteractiveUser' { 'PC\tester' }
Set-Hook 'VuHooks' 'StartDirect' { param($f, $a, $w) $global:ucCalls.Add("direct $f") }
Set-Hook 'VuHooks' 'InvokeDirect' { param($f, $a, $t) $global:ucCalls.Add("invoke $f"); [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
Set-Hook 'VuHooks' 'RunTask' { param($s, $w, $t) $global:ucCalls.Add("task $($s.Execute) $($s.RunLevel) $($s.LogonType) $($s.UserId) $($s.TaskPath)$($s.TaskName) wait=$w"); [pscustomobject]@{ Started = $true; ExitCode = 0; TimedOut = $false } }

$pkg = Join-Path ([IO.Path]::GetTempPath()) ("uc-asus-pkg-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path "$pkg\src\WIN11\64", "$pkg\src\WIN11\32", "$pkg\src\WIN10\64" -Force | Out-Null
    $inf = "[Version]`r`nSignature=`"`$WINDOWS NT`$`"`r`nCatalogFile=drv.cat`r`n[Manufacturer]`r`n%M%=Models,NTamd64`r`n"
    foreach ($d in 'WIN11\64', 'WIN11\32', 'WIN10\64') { Set-Content "$pkg\src\$d\drv.inf" $inf -Encoding ASCII; Set-Content "$pkg\src\$d\drv.cat" 'cat' -Encoding ASCII }
    Set-Content "$pkg\src\WIN11\64\nocat.inf" "[Version]`r`n[Manufacturer]`r`n%M%=Models,NTamd64`r`n" -Encoding ASCII
    Set-Content "$pkg\src\AsusSetup.exe" 'MZ' -Encoding ASCII
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory("$pkg\src", "$pkg\pkg.zip")
    $global:ucZip = "$pkg\pkg.zip"
    $zipSha = (Get-FileHash -LiteralPath $global:ucZip -Algorithm SHA256).Hash
    $base = Get-Cand 'oem|asus|lan-realtek'

    Check 'DryRun never downloads, verifies or installs' {
        $global:ucCalls.Clear()
        $r1 = Invoke-VendorUpdate -Candidate $base -DryRun; $r2 = Invoke-VendorUpdate -Candidate (Get-Cand 'oem|asus|chipset-amd') -DryRun
        $r1.Status -eq 'Info' -and $r1.Message -eq 'msg.vu.dryRun' -and $r2.Status -eq 'Info' -and $global:ucCalls.Count -eq 0
    }
    Check 'INF package: SHA-256 ok, catalog signature ok -> pnputil only for the Win11 x64 INF with catalog, reboot detected' {
        $global:ucCalls.Clear(); $global:ucSigStatus = 'Valid'
        $c = $base.PSObject.Copy(); $c.Sha256 = $zipSha
        $r = Invoke-VendorUpdate -Candidate $c
        $pn = @($global:ucCalls | Where-Object { $_ -like 'pnputil *' })
        $r.Status -eq 'Updated' -and $r.RebootRequired -and $pn.Count -eq 1 -and $pn[0] -like '*\WIN11\64\drv.inf' -and
        @($global:ucCalls | Where-Object { $_ -like 'sig *' -and $_ -like '*drv.cat' }).Count -eq 1 -and @($global:ucCalls | Where-Object { $_ -like 'task *' -or $_ -like 'direct *' }).Count -eq 0
    }
    Check 'INF package: SHA-256 mismatch -> Failed, nothing verified or installed' {
        $global:ucCalls.Clear(); $c = $base.PSObject.Copy(); $c.Sha256 = ('0' * 64)
        $r = Invoke-VendorUpdate -Candidate $c
        $r.Status -eq 'Failed' -and $r.Message -eq 'msg.vu.asus.hashMismatch' -and @($global:ucCalls | Where-Object { $_ -notlike 'download *' }).Count -eq 0
    }
    Check 'INF package: invalid catalog signature -> no pnputil; invalid installer signature -> Failed, nothing started' {
        $global:ucCalls.Clear(); $global:ucSigStatus = 'HashMismatch'
        $c = $base.PSObject.Copy(); $c.Sha256 = $zipSha
        $r = Invoke-VendorUpdate -Candidate $c
        $r.Status -eq 'Failed' -and $r.Message -eq 'msg.vu.asus.badSignature' -and @($global:ucCalls | Where-Object { $_ -like 'pnputil *' -or $_ -like 'task *' -or $_ -like 'direct *' }).Count -eq 0
    }
    Check 'installer package: verified AsusSetup.exe opened NON-elevated via the one-shot task -> Triggered' {
        $global:ucCalls.Clear(); $global:ucSigStatus = 'Valid'
        $c = (Get-Cand 'oem|asus|chipset-amd').PSObject.Copy(); $c.Sha256 = $zipSha
        $r = Invoke-VendorUpdate -Candidate $c
        $t = @($global:ucCalls | Where-Object { $_ -like 'task *' })
        $r.Status -eq 'Triggered' -and $r.Message -eq 'msg.vu.asus.interactive' -and $t.Count -eq 1 -and $t[0] -match 'AsusSetup\.exe Limited Interactive PC\\tester \\UpdateCenter\\Update Center Launch wait=False' -and
        @($global:ucCalls | Where-Object { $_ -like 'pnputil *' -or $_ -like 'direct *' }).Count -eq 0
    }
    Check 'Info (unsure) and ManualOnly ASUS entries never download' {
        $global:ucCalls.Clear()
        $info = (Get-Cand 'oem|asus|lan-realtek').PSObject.Copy(); $info.Status = 'Info'; $info.Message = 'vu.asus.unsure'
        $a = Invoke-VendorUpdate -Candidate $info; $b = Invoke-VendorUpdate -Candidate (Get-Cand 'oem|asus|bios')
        $u = (Get-Cand 'oem|asus|chipset-amd').PSObject.Copy(); $u.ManualOnly = $true; $u.Category = 'Software and Utility'
        $c = Invoke-VendorUpdate -Candidate $u
        $a.Status -eq 'Skipped' -and $b.Status -eq 'Skipped' -and $b.Message -eq 'msg.vu.biosManual' -and $c.Message -eq 'msg.vu.asus.manual' -and $global:ucCalls.Count -eq 0
    }
    Check 'zip-slip entry is refused' {
        $evil = "$pkg\evil.zip"
        $fs = [IO.File]::Open($evil, 'Create'); $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        $e = $za.CreateEntry('../escape.txt'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write('x'); $w.Dispose(); $za.Dispose(); $fs.Dispose()
        $threw = $false; try { Expand-AsusZip -ZipPath $evil -Destination "$pkg\out" } catch { $threw = $true }
        $threw -and -not (Test-Path "$pkg\escape.txt")
    }
} finally { Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue }

# --- elevation safety: trusted paths and the non-elevated launch task (mocked) ---
Check 'trusted path: ProgramFiles / WINDIR only, no traversal or prefix tricks' {
    (Test-VuTrustedPath (Join-Path $env:ProgramFiles 'Dell\x.exe')) -and (Test-VuTrustedPath (Join-Path $env:WINDIR 'System32\pnputil.exe')) -and
    -not (Test-VuTrustedPath (Join-Path $env:LOCALAPPDATA 'Discord\Update.exe')) -and -not (Test-VuTrustedPath (Join-Path $env:APPDATA 'x.exe')) -and
    -not (Test-VuTrustedPath ($env:ProgramFiles + '\..\Users\Public\x.exe')) -and -not (Test-VuTrustedPath ($env:ProgramFiles + ' Evil\x.exe')) -and
    -not (Test-VuTrustedPath '') -and -not (Test-VuTrustedPath 'C:\SWSetup\HPImageAssistant\HPImageAssistant.exe')
}
Check 'task spec: \UpdateCenter\Update Center Launch, interactive user, Limited, quoted args' {
    $s = New-VuLaunchTaskSpec -FilePath 'C:\Users\u\AppData\Local\Discord\Update.exe' -ArgumentList @('--processStart', 'Discord.exe', 'a b') -UserId 'PC\u'
    $s.TaskPath -eq '\UpdateCenter\' -and $s.TaskName -eq 'Update Center Launch' -and $s.UserId -eq 'PC\u' -and $s.LogonType -eq 'Interactive' -and $s.RunLevel -eq 'Limited' -and
    $s.Argument -eq '--processStart Discord.exe "a b"' -and $s.WorkingDirectory -eq 'C:\Users\u\AppData\Local\Discord'
}
Check 'Start-VuProcess: elevated + untrusted -> task; elevated + trusted -> direct; -Unelevated -> task; not elevated -> direct' {
    Set-Hook 'VuHooks' 'IsTrusted' { param($p) $p -like 'C:\Program Files\*' }
    $global:ucCalls.Clear()
    $a = Start-VuProcess -FilePath 'C:\Users\u\AppData\Local\Discord\Update.exe'
    $b = Start-VuProcess -FilePath 'C:\Program Files\Google\Update\GoogleUpdate.exe'
    $c = Start-VuProcess -FilePath 'C:\Program Files\Epic Games\Launcher.exe' -Unelevated
    Set-Hook 'VuHooks' 'IsElevated' { $false }
    $d = Start-VuProcess -FilePath 'C:\Users\u\AppData\Local\Discord\Update.exe' -Unelevated
    Set-Hook 'VuHooks' 'IsElevated' { $true }
    $a -eq 'task' -and $b -eq 'direct' -and $c -eq 'task' -and $d -eq 'direct' -and @($global:ucCalls | Where-Object { $_ -like 'task *Limited Interactive*' }).Count -eq 2
}
Check 'Invoke-VuProcess: elevated + untrusted waits on the task (exit code from task), trusted runs directly' {
    $global:ucCalls.Clear()
    $r1 = Invoke-VuProcess -FilePath 'C:\SWSetup\HPImageAssistant\HPImageAssistant.exe' -ArgumentList @('/Silent') -TimeoutMinutes 5
    $r2 = Invoke-VuProcess -FilePath 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe' -ArgumentList @('/scan')
    $r1.ExitCode -eq 0 -and ($global:ucCalls[0] -like 'task C:\SWSetup\*wait=True') -and ($global:ucCalls[1] -like 'invoke C:\Program Files\Dell\*')
}
Check 'no interactive user: Start-VuProcess throws, Invoke-VuProcess returns a failure code (never runs elevated)' {
    Set-Hook 'VuHooks' 'InteractiveUser' { '' }
    $global:ucCalls.Clear()
    $threw = $false; try { Start-VuProcess -FilePath 'C:\Users\u\x.exe' } catch { $threw = $true }
    $r = Invoke-VuProcess -FilePath 'C:\Users\u\x.exe'
    $threw -and $r.ExitCode -eq -998 -and $global:ucCalls.Count -eq 0
}
Check 'source: every process start goes through the safe wrappers; launchers forced non-elevated; Epic path from HKLM only' {
    $code = Get-Content (Join-Path $root 'src\VendorUpdates.psm1') -Raw
    @([regex]::Matches($code, '\bStart-Process\b')).Count -eq 1 -and @([regex]::Matches($code, '\bInvoke-Process\b')).Count -eq 1 -and
    $code -match 'Start-VuProcess -FilePath \$info\.Exe [^\r\n]*-Unelevated' -and $code -match "NameRegex '\^Epic Games Launcher' -MachineOnly"
}
Import-Module (Join-Path $root 'src\VendorUpdates.psm1') -Force -DisableNameChecking   # real hooks again for the live part

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
