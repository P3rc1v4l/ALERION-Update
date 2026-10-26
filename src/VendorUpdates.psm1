# Update Center - vendor updates: OEM driver tools and apps with their own updater.
# Only official, documented command lines are used. Result objects come from New-UpdateResult
# (Providers.psm1) and carry extra properties: Vendor, ManualOnly, Category, Hint.
# Keep this file ASCII-only (Windows PowerShell 5.1).
#
# VERIFIED vs ASSUMED is listed per area in the comments marked [VERIFIED] / [ASSUMED].

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Providers.psm1') -DisableNameChecking

# ---------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------

function Get-VuProp {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Add-VuProps {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Props)
    foreach ($k in $Props.Keys) { $Item | Add-Member -NotePropertyName $k -NotePropertyValue $Props[$k] -Force }
    return $Item
}

function New-VuCandidate {
    param(
        [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Key, [string]$From = '', [string]$To = '',
        [string]$Status = 'Available', [string]$Message = '', [string]$Priority = 'Important',
        [bool]$IsCheck = $false, [string]$Vendor = '', [bool]$ManualOnly = $false, [string]$Category = '', [bool]$Major = $false
    )
    $item = New-UpdateResult -Source $Source -Name $Name -Id $Id -From $From -To $To -Status $Status -Message $Message -Key $Key -Priority $Priority -IsCheck $IsCheck
    $item.Major = $Major
    return Add-VuProps -Item $item -Props @{ Vendor = $Vendor; ManualOnly = $ManualOnly; Category = $Category }
}

function Get-VuWorkDir {
    $dir = Join-Path (Get-AppPaths).CacheDir ("vendor-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Get-VuFileVersion {
    param([string]$Path)
    try { if ($Path -and (Test-Path -LiteralPath $Path)) { return [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion } } catch { }
    return ''
}

function Get-VuProgramDirs {
    $d = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    return @($d | Select-Object -Unique)
}

function Find-VuFile {
    <# First existing file of: {ProgramFiles, ProgramFiles(x86)} + each relative path. #>
    param([Parameter(Mandatory)][string[]]$Relative)
    foreach ($base in (Get-VuProgramDirs)) {
        foreach ($rel in $Relative) {
            $p = Join-Path $base $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }
    return $null
}

function Get-VuUninstallEntry {
    param([Parameter(Mandatory)][string]$NameRegex)
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($e in @(Get-ItemProperty $roots -ErrorAction SilentlyContinue)) {
        $n = [string](Get-VuProp $e 'DisplayName')
        if ($n -and $n -match $NameRegex) { return $e }
    }
    return $null
}

function Test-VuProcessRunning {
    param([Parameter(Mandatory)][string[]]$Name)
    return (@(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count -gt 0)
}

function Format-VuVersion {
    <# Combined getters return "registry|file"; show the first non-empty part. #>
    param([string]$Version)
    foreach ($p in ($Version -split '\|')) { if ($p) { return $p } }
    return ''
}

function Wait-VuVersionChange {
    <# Polls a version getter until it differs from $From or the timeout passes. Returns the last version seen. #>
    param([Parameter(Mandatory)][scriptblock]$GetVersion, [string]$From = '', [int]$Minutes = 5, [int]$PollSeconds = 5)
    $deadline = (Get-Date).AddMinutes($Minutes)
    $cur = [string](& $GetVersion)
    while ($cur -eq $From -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $cur = [string](& $GetVersion)
    }
    return $cur
}

# ---------------------------------------------------------------------------------------
# Manufacturer detection
# ---------------------------------------------------------------------------------------

function Resolve-VendorName {
    <# Maps a manufacturer string (Win32_ComputerSystem / BaseBoard) to dell, lenovo, hp, asus or other. #>
    param([AllowEmptyString()][string]$Text)
    switch -Regex ($Text) {
        '(?i)\bdell\b|alienware'                       { return 'dell' }
        '(?i)lenovo'                                   { return 'lenovo' }
        '(?i)^\s*hp\b|hewlett|\bhp inc'                { return 'hp' }
        '(?i)asus'                                     { return 'asus' }
        default                                        { return 'other' }
    }
}

function Get-SystemVendor {
    <# [VERIFIED] CIM classes. Computer manufacturer first, baseboard as fallback (custom PCs). #>
    $cs = ''; $bb = ''
    try { $cs = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer } catch { }
    try { $bb = [string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).Manufacturer } catch { }
    $v = Resolve-VendorName $cs
    if ($v -eq 'other') { $v = Resolve-VendorName $bb }
    [pscustomobject]@{ Vendor = $v; Manufacturer = $cs; BoardManufacturer = $bb }
}

function Test-VuBiosCategory {
    param([string]$Category, [string]$Name = '')
    return ("$Category $Name" -match '(?i)\bbios\b|\buefi\b|system firmware|\bfirmware\b|\bec firmware\b')
}

# ---------------------------------------------------------------------------------------
# Dell Command | Update (dcu-cli.exe)
#   [VERIFIED from Dell docs, from memory]: /scan, /applyUpdates, -silent, -reboot=disable,
#     -report=<dir>, -outputLog=<file>, exit codes 0, 1 (reboot required), 500 (no updates).
#   [ASSUMED] exact XML element names of DCUApplicableUpdates.xml (parser is name-tolerant),
#     -updateType filter values, exit codes 2-8 and 5xx details.
# ---------------------------------------------------------------------------------------

function Get-DellCliPath { Find-VuFile -Relative @('Dell\CommandUpdate\dcu-cli.exe', 'Dell\Dell Command Update\dcu-cli.exe') }

function Get-DellExitInfo {
    <# Returns Kind: Ok | Reboot | NoUpdates | NoAdmin | Busy | Failed | Timeout. #>
    param([int]$ExitCode)
    switch ($ExitCode) {
        0       { return [pscustomobject]@{ Kind = 'Ok'; Text = '' } }
        1       { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot required' } }
        500     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no updates found' } }
        4       { return [pscustomobject]@{ Kind = 'NoAdmin'; Text = 'administrator rights required' } }
        6       { return [pscustomobject]@{ Kind = 'Busy'; Text = 'another instance is running' } }
        5       { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot pending from a previous operation' } }
        -999    { return [pscustomobject]@{ Kind = 'Timeout'; Text = 'timeout' } }
        default { return [pscustomobject]@{ Kind = 'Failed'; Text = "exit $ExitCode" } }
    }
}

function Get-VuXmlChildText {
    param($Node, [string[]]$Names)
    foreach ($n in $Names) {
        foreach ($c in @($Node.ChildNodes)) {
            if ($c.NodeType -eq 'Element' -and $c.LocalName -ieq $n -and $c.InnerText) { return $c.InnerText.Trim() }
        }
        if ($Node.Attributes) {
            foreach ($a in @($Node.Attributes)) { if ($a.LocalName -ieq $n -and $a.Value) { return $a.Value.Trim() } }
        }
    }
    return ''
}

function ConvertFrom-DellScanReport {
    <# Parses DCUApplicableUpdates.xml text into plain objects {Id, Name, Version, Category, Type, Urgency}.
       Accepts any <update> element at any depth. Returns @() for unparseable input. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $out.ToArray() }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml.TrimStart([char]0xFEFF)) } catch { return $out.ToArray() }
    foreach ($u in @($doc.SelectNodes("//*[translate(local-name(),'UPDATE','update')='update']"))) {
        $name = Get-VuXmlChildText $u @('name', 'title')
        if (-not $name) { continue }
        $id = Get-VuXmlChildText $u @('release', 'releaseid', 'id', 'packageid')
        if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
        $out.Add([pscustomobject]@{
            Id = $id; Name = $name; Version = (Get-VuXmlChildText $u @('version', 'vendorversion'))
            Category = (Get-VuXmlChildText $u @('category', 'devicecategory')); Type = (Get-VuXmlChildText $u @('type', 'updatetype'))
            Urgency = (Get-VuXmlChildText $u @('urgency', 'priority'))
        })
    }
    return $out.ToArray()
}

function ConvertTo-DellCandidate {
    param([Parameter(Mandatory)]$Entry)
    $isBios = Test-VuBiosCategory -Category ("$($Entry.Category) $($Entry.Type)") -Name $Entry.Name
    $c = New-VuCandidate -Source 'oem' -Name $Entry.Name -Id $Entry.Id -Key ("oem|dell|{0}" -f $Entry.Id) -To $Entry.Version `
        -Priority 'Important' -Vendor 'dell' -Category ([string]$Entry.Category) -ManualOnly $isBios -Major $isBios `
        -Message $(if ($isBios) { 'vu.bios' } else { '' })
    return $c
}

function Get-DellCandidates {
    $cli = Get-DellCliPath
    if (-not $cli) { return @() }
    $dir = Get-VuWorkDir
    try {
        $log = Join-Path $dir 'scan.log'
        $r = Invoke-Process -FilePath $cli -ArgumentList @('/scan', '-silent', "-report=$dir", "-outputLog=$log") -TimeoutMinutes 10
        $info = Get-DellExitInfo $r.ExitCode
        if ($info.Kind -eq 'NoUpdates') { return @() }
        if ($info.Kind -notin 'Ok', 'Reboot') {
            Write-Log -Level WARN -Message "dcu-cli scan: $($info.Text)"
            return @(New-VuCandidate -Source 'oem' -Name 'Dell Command | Update' -Id 'check' -Key 'oem|dell|check' -Status 'Info' `
                -Message 'msg.vu.scanFailed' -Priority 'Important' -Vendor 'dell' -IsCheck $true)
        }
        $xmlFile = Get-ChildItem -LiteralPath $dir -Filter '*.xml' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Applicable' } | Select-Object -First 1
        if (-not $xmlFile) { $xmlFile = Get-ChildItem -LiteralPath $dir -Filter '*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $xmlFile) { return @() }
        return @(ConvertFrom-DellScanReport -Xml (Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8) | ForEach-Object { ConvertTo-DellCandidate $_ })
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-DellApply {
    param([switch]$DryRun, $Base)
    $cli = Get-DellCliPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    $dir = Get-VuWorkDir
    # dcu-cli applies a whole batch; BIOS is excluded by the update-type filter [ASSUMED values].
    $cliArgs = @('/applyUpdates', '-silent', '-reboot=disable', "-outputLog=$(Join-Path $dir 'apply.log')", '-updateType=driver,firmware,application,others')
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    try {
        Write-Log -Message "dcu-cli applyUpdates"
        $r = Invoke-Process -FilePath $cli -ArgumentList $cliArgs -TimeoutMinutes 60
        $info = Get-DellExitInfo $r.ExitCode
        switch ($info.Kind) {
            'Ok'        { return New-UpdateResult @Base -Status Updated }
            'Reboot'    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
            'NoUpdates' { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.noUpdates' }
            'Timeout'   { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
            default     { return New-UpdateResult @Base -Status Failed -Message $info.Text }
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------
# Lenovo System Update (tvsu.exe)
#   [VERIFIED from Lenovo System Update admin guide, from memory]: /CM command mode,
#     -search A|R|C|O, -action LIST|DOWNLOAD|INSTALL, -noicon, -nolicense.
#   [ASSUMED] -packagetypes values (1 app, 2 driver, 3 BIOS, 4 firmware) and exit codes.
#   [NOT IMPLEMENTED] parsing of the LIST output (format not confident) -> one IsCheck candidate.
#   Lenovo Commercial Vantage: no documented CLI known -> not integrated.
# ---------------------------------------------------------------------------------------

function Get-LenovoCliPath { Find-VuFile -Relative @('Lenovo\System Update\tvsu.exe') }

function Get-LenovoCandidates {
    $cli = Get-LenovoCliPath
    if (-not $cli) { return @() }
    $ver = Get-VuFileVersion $cli
    return @(New-VuCandidate -Source 'oem' -Name 'Lenovo System Update' -Id 'check' -Key 'oem|lenovo|check' -From $ver `
        -Priority 'Important' -Vendor 'lenovo' -IsCheck $true -Message 'msg.checkInstall')
}

function Invoke-LenovoInstall {
    param([switch]$DryRun, $Base)
    $cli = Get-LenovoCliPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    # Package type 3 (BIOS) is deliberately left out.
    $r = Invoke-Process -FilePath $cli -ArgumentList @('/CM', '-search', 'R', '-action', 'INSTALL', '-packagetypes', '1,2,4', '-noicon', '-nolicense') -TimeoutMinutes 60
    switch ($r.ExitCode) {
        0       { return New-UpdateResult @Base -Status Updated }
        3010    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
        -999    { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
        default { return New-UpdateResult @Base -Status Failed -Message "exit $($r.ExitCode)" }
    }
}

# ---------------------------------------------------------------------------------------
# HP Image Assistant (HPImageAssistant.exe)
#   [VERIFIED from HPIA user guide, from memory]: /Operation:Analyze /Action:List|Install /Silent
#     /ReportFolder:<dir> /SoftpaqDownloadFolder:<dir> /Category:<..> /Selection:<..>.
#   [ASSUMED] report JSON/XML field names (parser tolerant), exit codes 0/256/257/3010.
# ---------------------------------------------------------------------------------------

function Get-HpiaPath {
    $p = Find-VuFile -Relative @('HP\HP Image Assistant\HPImageAssistant.exe', 'HP\HPImageAssistant\HPImageAssistant.exe')
    if ($p) { return $p }
    foreach ($c in @("$env:SystemDrive\SWSetup\HPImageAssistant\HPImageAssistant.exe", "$env:SystemDrive\HPIA\HPImageAssistant.exe")) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    return $null
}

function Get-HpExitInfo {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0       { return [pscustomobject]@{ Kind = 'Ok'; Text = '' } }
        256     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no recommendations' } }
        257     { return [pscustomobject]@{ Kind = 'NoUpdates'; Text = 'no recommendations selected' } }
        3010    { return [pscustomobject]@{ Kind = 'Reboot'; Text = 'reboot required' } }
        -999    { return [pscustomobject]@{ Kind = 'Timeout'; Text = 'timeout' } }
        default { return [pscustomobject]@{ Kind = 'Failed'; Text = "exit $ExitCode" } }
    }
}

function ConvertFrom-HpReport {
    <# Parses an HPIA report (JSON or XML text) into {Id, Name, Version, Category, Urgency}. Tolerant by design. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $out.ToArray() }
    $t = $Text.TrimStart([char]0xFEFF).TrimStart()
    if ($t.StartsWith('{') -or $t.StartsWith('[')) {
        $data = $null
        try { $data = $t | ConvertFrom-Json } catch { return $out.ToArray() }
        $recs = @()
        if ($data -is [array]) { $recs = @($data) }
        else {
            $root = if ($data.PSObject.Properties['HPIA']) { $data.HPIA } else { $data }
            $r = Get-VuProp $root 'Recommendations' $null
            if ($null -ne $r) { $recs = @($r) }
        }
        foreach ($rec in $recs) {
            $name = [string](Get-VuProp $rec 'Name'); if (-not $name) { $name = [string](Get-VuProp $rec 'Title') }
            if (-not $name) { continue }
            $id = [string](Get-VuProp $rec 'SoftPaqId'); if (-not $id) { $id = [string](Get-VuProp $rec 'Id') }
            if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
            $cat = [string](Get-VuProp $rec 'Category'); if (-not $cat) { $cat = [string](Get-VuProp $rec 'Type') }
            if (-not $cat) { $cat = [string](Get-VuProp $rec 'TargetComponent') }
            $out.Add([pscustomobject]@{
                Id = $id; Name = $name; Version = [string](Get-VuProp $rec 'Version'); Category = $cat
                Urgency = [string](Get-VuProp $rec 'ReleaseType')
            })
        }
        return $out.ToArray()
    }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($t) } catch { return $out.ToArray() }
    foreach ($n in @($doc.SelectNodes("//*[local-name()='Recommendation' or local-name()='Solution']"))) {
        $name = Get-VuXmlChildText $n @('Name', 'Title')
        if (-not $name) { continue }
        $id = Get-VuXmlChildText $n @('SoftPaqId', 'Id'); if (-not $id) { $id = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-') }
        $cat = Get-VuXmlChildText $n @('Category', 'Type', 'TargetComponent')
        $out.Add([pscustomobject]@{ Id = $id; Name = $name; Version = (Get-VuXmlChildText $n @('Version')); Category = $cat; Urgency = (Get-VuXmlChildText $n @('ReleaseType')) })
    }
    return $out.ToArray()
}

function ConvertTo-HpCandidate {
    param([Parameter(Mandatory)]$Entry)
    $isBios = Test-VuBiosCategory -Category $Entry.Category -Name $Entry.Name
    return New-VuCandidate -Source 'oem' -Name $Entry.Name -Id $Entry.Id -Key ("oem|hp|{0}" -f $Entry.Id) -To $Entry.Version `
        -Priority 'Important' -Vendor 'hp' -Category $Entry.Category -ManualOnly $isBios -Major $isBios `
        -Message $(if ($isBios) { 'vu.bios' } else { '' })
}

function Get-HpCandidates {
    $cli = Get-HpiaPath
    if (-not $cli) { return @() }
    $dir = Get-VuWorkDir
    try {
        $r = Invoke-Process -FilePath $cli -ArgumentList @('/Operation:Analyze', '/Action:List', '/Category:All', '/Silent', "/ReportFolder:$dir", "/SoftpaqDownloadFolder:$dir") -TimeoutMinutes 15
        $info = Get-HpExitInfo $r.ExitCode
        if ($info.Kind -eq 'NoUpdates') { return @() }
        if ($info.Kind -notin 'Ok', 'Reboot') {
            Write-Log -Level WARN -Message "HPIA analyze: $($info.Text)"
            return @(New-VuCandidate -Source 'oem' -Name 'HP Image Assistant' -Id 'check' -Key 'oem|hp|check' -Status 'Info' `
                -Message 'msg.vu.scanFailed' -Vendor 'hp' -IsCheck $true)
        }
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.json', '.xml' })
        $file = @($files | Where-Object { $_.Extension -eq '.json' }) | Select-Object -First 1
        if (-not $file) { $file = $files | Select-Object -First 1 }
        if (-not $file) { return @() }
        return @(ConvertFrom-HpReport -Text (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) | ForEach-Object { ConvertTo-HpCandidate $_ })
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-HpInstall {
    param([switch]$DryRun, $Base)
    $cli = Get-HpiaPath
    if (-not $cli) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    $dir = Get-VuWorkDir
    try {
        # BIOS category is left out on purpose (manual only).
        $r = Invoke-Process -FilePath $cli -ArgumentList @('/Operation:Analyze', '/Action:Install', '/Category:Drivers,Firmware', '/Selection:All', '/Silent', '/AutoCleanup', "/ReportFolder:$dir", "/SoftpaqDownloadFolder:$dir") -TimeoutMinutes 60
        $info = Get-HpExitInfo $r.ExitCode
        switch ($info.Kind) {
            'Ok'        { return New-UpdateResult @Base -Status Updated }
            'Reboot'    { return New-UpdateResult @Base -Status Updated -RebootRequired $true -Message 'msg.vu.rebootRequired' }
            'NoUpdates' { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.noUpdates' }
            'Timeout'   { return New-UpdateResult @Base -Status Failed -Message 'msg.timeout' }
            default     { return New-UpdateResult @Base -Status Failed -Message $info.Text }
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------
# ASUS: no official CLI. DriverHub's local web service is never contacted (CVE-2025-3462/3463).
# We only detect the tools and open the user interface so the user applies drivers there.
# ---------------------------------------------------------------------------------------

function Get-AsusTools {
    <# [VERIFIED on an ASUS machine] Files under Program Files\ASUS, Start menu entries. #>
    $hub = Find-VuFile -Relative @('ASUS\AsusDriverHub\ASUS DriverHub.exe')
    $adu = Find-VuFile -Relative @('ASUS\AsusDriverHub\ADU.exe')
    $crate = $false; $myasus = $false
    try {
        foreach ($a in @(Get-StartApps -ErrorAction SilentlyContinue)) {
            if ($a.Name -match '(?i)^Armoury Crate') { $crate = $true }
            if ($a.Name -match '(?i)^MyASUS') { $myasus = $true }
        }
    } catch { }
    $hubVersion = ''
    $e = Get-VuUninstallEntry -NameRegex '^ASUS DriverHub'
    if ($e) { $hubVersion = [string](Get-VuProp $e 'DisplayVersion') }
    [pscustomobject]@{ DriverHubExe = $hub; DriverHubAdu = $adu; DriverHubVersion = $hubVersion; ArmouryCrate = $crate; MyAsus = $myasus
        Any = [bool]($hub -or $adu -or $crate -or $myasus -or $hubVersion) }
}

function Get-AsusCandidates {
    $t = Get-AsusTools
    if (-not $t.Any) { return @() }
    return @(New-VuCandidate -Source 'oem' -Name 'ASUS DriverHub / MyASUS' -Id 'driverhub' -Key 'oem|asus|driverhub' -From $t.DriverHubVersion `
        -Priority 'Important' -Vendor 'asus' -IsCheck $true -Message 'vu.asus.open')
}

function Invoke-AsusOpen {
    param([switch]$DryRun, $Base)
    if ($DryRun) { return New-UpdateResult @Base -Status Info -Message 'msg.vu.dryRun' }
    $t = Get-AsusTools
    try {
        if ($t.DriverHubExe) { Start-Process -FilePath $t.DriverHubExe }
        else { Start-Process 'https://driverhub.asus.com' }
        return New-UpdateResult @Base -Status Triggered -Message 'msg.vu.opened'
    } catch {
        return New-UpdateResult @Base -Status Failed -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------------------
# Apps with their own updater (table driven)
# ---------------------------------------------------------------------------------------

function Get-VuHighestVersionDir {
    param([string]$Root, [string]$Filter = '*')
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return '' }
    $best = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter $Filter -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($d.Name, '(\d+(\.\d+){1,3})')
        if (-not $m.Success) { continue }
        $v = $null; try { $v = [version]$m.Groups[1].Value } catch { continue }
        if ($null -eq $best -or $v -gt $best) { $best = $v }
    }
    if ($best) { return $best.ToString() }
    return ''
}

function Get-ChromeInfo {
    $upd = Find-VuFile -Relative @('Google\Update\GoogleUpdate.exe')
    $app = Find-VuFile -Relative @('Google\Chrome\Application\chrome.exe')
    if (-not $upd -or -not $app) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Split-Path (Find-VuFile -Relative @('Google\Chrome\Application\chrome.exe')) -Parent) } }
}

function Get-EdgeInfo {
    $upd = Find-VuFile -Relative @('Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
    $app = Find-VuFile -Relative @('Microsoft\Edge\Application\msedge.exe')
    if (-not $upd -or -not $app) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Split-Path (Find-VuFile -Relative @('Microsoft\Edge\Application\msedge.exe')) -Parent) } }
}

function Get-AdobeRumInfo {
    $rum = Find-VuFile -Relative @('Common Files\Adobe\OOBE\PDApp\UWA\RemoteUpdateManager.exe')
    if (-not $rum) { return $null }
    [pscustomobject]@{ Exe = $rum; GetVersion = { '' } }
}

function Get-EpicInfo {
    $e = Get-VuUninstallEntry -NameRegex '^Epic Games Launcher'
    $loc = if ($e) { [string](Get-VuProp $e 'InstallLocation') } else { '' }
    $exe = $null
    foreach ($base in @($loc, (Join-Path $env:ProgramFiles 'Epic Games'), (Join-Path ${env:ProgramFiles(x86)} 'Epic Games')) | Where-Object { $_ }) {
        foreach ($rel in 'Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe', 'Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe') {
            $p = Join-Path $base $rel
            if (Test-Path -LiteralPath $p -PathType Leaf) { $exe = $p; break }
        }
        if ($exe) { break }
    }
    if (-not $exe) { return $null }
    $regVer = if ($e) { [string](Get-VuProp $e 'DisplayVersion') } else { '' }
    $fileExe = $exe
    [pscustomobject]@{ Exe = $exe; GetVersion = {
        $ent = Get-VuUninstallEntry -NameRegex '^Epic Games Launcher'
        $rv = if ($ent) { [string](Get-VuProp $ent 'DisplayVersion') } else { '' }
        '{0}|{1}' -f $rv, (Get-VuFileVersion $fileExe) }.GetNewClosure() }
}

function Get-DiscordInfo {
    $root = Join-Path $env:LOCALAPPDATA 'Discord'
    $upd = Join-Path $root 'Update.exe'
    if (-not (Test-Path -LiteralPath $upd -PathType Leaf)) { return $null }
    [pscustomobject]@{ Exe = $upd; GetVersion = { Get-VuHighestVersionDir -Root (Join-Path $env:LOCALAPPDATA 'Discord') -Filter 'app-*' } }
}

# Table: Id, display name, winget id, vendor, priority, detect function, trigger kind and arguments.
$script:SelfUpdaters = @(
    @{ Id = 'chrome';  Name = 'Google Chrome';          WingetId = 'Google.Chrome';              Priority = 'Critical'; Detect = 'Get-ChromeInfo'; Kind = 'oneshot'
       Args = @('/ua', '/installsource', 'scheduler'); WaitMin = 3; Hint = 'vu.hint.chrome' }
    @{ Id = 'edge';    Name = 'Microsoft Edge';         WingetId = 'Microsoft.Edge';             Priority = 'Critical'; Detect = 'Get-EdgeInfo';   Kind = 'oneshot'
       Args = @('/ua', '/installsource', 'scheduler'); WaitMin = 3; Hint = 'vu.hint.edge' }
    @{ Id = 'adobe';   Name = 'Adobe Remote Update Manager'; WingetId = '';                      Priority = 'Normal';   Detect = 'Get-AdobeRumInfo'; Kind = 'rum'
       Args = @(); WaitMin = 0; Hint = '' }
    @{ Id = 'epic';    Name = 'Epic Games Launcher';    WingetId = 'EpicGames.EpicGamesLauncher'; Priority = 'Optional'; Detect = 'Get-EpicInfo';   Kind = 'start'
       Args = @('-silent'); WaitMin = 10; Process = 'EpicGamesLauncher'; Hint = 'vu.hint.epic' }
    @{ Id = 'discord'; Name = 'Discord';                WingetId = 'Discord.Discord';            Priority = 'Optional'; Detect = 'Get-DiscordInfo'; Kind = 'start'
       Args = @('--processStart', 'Discord.exe'); WaitMin = 5; Process = 'Discord'; Hint = 'vu.hint.discord' }
)

# Apps that update themselves when they start: the engine can skip winget for them and show the hint.
$script:SelfUpdateInfoOnly = @(
    @{ WingetId = 'Valve.Steam';                Vendor = 'Valve';           Hint = 'vu.hint.steam' }
    @{ WingetId = 'Blizzard.BattleNet';         Vendor = 'Blizzard';        Hint = 'vu.hint.battlenet' }
    @{ WingetId = 'ElectronicArts.EADesktop';   Vendor = 'Electronic Arts'; Hint = 'vu.hint.ea' }
    @{ WingetId = 'Ubisoft.Connect';            Vendor = 'Ubisoft';         Hint = 'vu.hint.ubisoft' }
)

function Get-SelfUpdatingAppMap {
    <# winget Id -> @{ Vendor; Hint } for apps that update themselves (the engine may skip winget for these). #>
    $map = @{}
    foreach ($s in $script:SelfUpdateInfoOnly) { $map[$s.WingetId] = @{ Vendor = $s.Vendor; Hint = $s.Hint } }
    foreach ($s in $script:SelfUpdaters) {
        if ($s.WingetId) { $map[$s.WingetId] = @{ Vendor = $s.Name; Hint = $s.Hint } }
    }
    return $map
}

function Get-SelfUpdaterCandidates {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in $script:SelfUpdaters) {
        $info = $null
        try { $info = & $s.Detect } catch { }
        if (-not $info) { continue }
        $from = ''
        try { $from = [string](& $info.GetVersion) } catch { }
        $from = Format-VuVersion $from
        $c = New-VuCandidate -Source 'selfupdater' -Name $s.Name -Id $s.Id -Key ("selfupdater|{0}" -f $s.Id) -From $from `
            -Priority $s.Priority -Vendor $s.Name -IsCheck $true -Message 'msg.checkInstall'
        $list.Add($c)
    }
    return $list.ToArray()
}

function Get-SelfUpdateHintResults {
    <# Turns winget upgrade rows (Id/Name/Version/Available) of self-updating apps into Info results. #>
    param([object[]]$WingetUpgrades = @())
    $map = Get-SelfUpdatingAppMap
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($w in @($WingetUpgrades)) {
        $id = [string](Get-VuProp $w 'Id')
        if (-not $id -or -not $map.ContainsKey($id)) { continue }
        $out.Add((New-VuCandidate -Source 'selfupdater' -Name ([string](Get-VuProp $w 'Name' $id)) -Id $id -Key ("selfupdater|{0}" -f $id) `
            -From ([string](Get-VuProp $w 'Version')) -To ([string](Get-VuProp $w 'Available')) -Status 'Info' -Message $map[$id].Hint `
            -Priority 'Optional' -Vendor $map[$id].Vendor))
    }
    return $out.ToArray()
}

function Invoke-SelfUpdater {
    param([Parameter(Mandatory)][string]$Id, [switch]$DryRun, $Base)
    $s = @($script:SelfUpdaters | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $s) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.unknown' }
    $info = & $s.Detect
    if (-not $info) { return New-UpdateResult @Base -Status Skipped -Message 'msg.vu.notInstalled' }
    $from = [string](& $info.GetVersion)
    $b = @{} + $Base; $b.From = Format-VuVersion $from
    if ($s.Kind -eq 'start' -and (Test-VuProcessRunning -Name $s.Process)) {
        # A running launcher updates itself; starting a second instance would be pointless.
        return New-UpdateResult @b -Status Skipped -Message 'msg.vu.runningSkip'
    }
    if ($DryRun) { return New-UpdateResult @b -Status Info -Message 'msg.vu.dryRun' }
    Write-Log -Message ("{0}: trigger {1} {2}" -f $s.Name, $info.Exe, ($s.Args -join ' '))
    switch ($s.Kind) {
        'oneshot' {
            $r = Invoke-Process -FilePath $info.Exe -ArgumentList $s.Args -TimeoutMinutes 10
            if ($r.TimedOut) { return New-UpdateResult @b -Status Failed -Message 'msg.timeout' }
            $to = Wait-VuVersionChange -GetVersion $info.GetVersion -From $from -Minutes $s.WaitMin
            if ($to -and $to -ne $from) { $b.To = Format-VuVersion $to; return New-UpdateResult @b -Status Updated }
            return New-UpdateResult @b -Status Triggered -Message 'msg.vu.triggered'
        }
        'rum' {
            $r = Invoke-Process -FilePath $info.Exe -ArgumentList $s.Args -TimeoutMinutes 30
            if ($r.TimedOut) { return New-UpdateResult @b -Status Failed -Message 'msg.timeout' }
            if ($r.ExitCode -eq 0) { return New-UpdateResult @b -Status Triggered -Message 'msg.vu.rumDone' }   # [ASSUMED] 0 = success
            return New-UpdateResult @b -Status Failed -Message "exit $($r.ExitCode)"
        }
        'start' {
            # Not Invoke-Process: the program must keep running after we return.
            Start-Process -FilePath $info.Exe -ArgumentList $s.Args -WindowStyle Minimized | Out-Null
            $to = Wait-VuVersionChange -GetVersion $info.GetVersion -From $from -Minutes $s.WaitMin
            if ($to -and $to -ne $from) { $b.To = Format-VuVersion $to; return New-UpdateResult @b -Status Updated -Message 'msg.vu.leftRunning' }
            return New-UpdateResult @b -Status Triggered -Message 'msg.vu.leftRunning'
        }
    }
    return New-UpdateResult @b -Status Skipped -Message 'msg.vu.unknown'
}

# ---------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------

function Get-VendorUpdateCandidates {
    <# Never throws. -WingetUpgrades (optional) are the rows the engine already has; self-updating apps in it become Info hints. #>
    param([switch]$SkipOem, [switch]$SkipSelfUpdaters, [object[]]$WingetUpgrades = @())
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $SkipOem) {
        try {
            $sys = Get-SystemVendor
            $found = switch ($sys.Vendor) {
                'dell'   { Get-DellCandidates }
                'lenovo' { Get-LenovoCandidates }
                'hp'     { Get-HpCandidates }
                'asus'   { Get-AsusCandidates }
                default  { @() }
            }
            foreach ($c in @($found)) { if ($c) { $out.Add($c) } }
        } catch { Write-Log -Level WARN -Message "OEM scan failed: $($_.Exception.Message)" }
    }
    if (-not $SkipSelfUpdaters) {
        try { foreach ($c in @(Get-SelfUpdaterCandidates)) { $out.Add($c) } }
        catch { Write-Log -Level WARN -Message "Self-updater scan failed: $($_.Exception.Message)" }
        try { foreach ($c in @(Get-SelfUpdateHintResults -WingetUpgrades $WingetUpgrades)) { $out.Add($c) } } catch { }
    }
    return $out.ToArray()
}

function Invoke-VendorUpdate {
    <# Runs one candidate. Never throws: errors become a Failed result. #>
    param([Parameter(Mandatory)]$Candidate, [switch]$DryRun)
    $key = [string](Get-VuProp $Candidate 'Key')
    $name = [string](Get-VuProp $Candidate 'Name' $key)
    if (-not $name) { $name = 'Vendor update' }
    $base = @{ Source = [string](Get-VuProp $Candidate 'Source' 'oem'); Name = $name; Id = [string](Get-VuProp $Candidate 'Id')
               From = [string](Get-VuProp $Candidate 'From'); To = [string](Get-VuProp $Candidate 'To'); Key = $key }
    try {
        $parts = $key -split '\|'
        if ($parts.Count -lt 2) { return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown' }
        if ($parts[0] -eq 'selfupdater') {
            $info = @($script:SelfUpdateInfoOnly | Where-Object { $_.WingetId -eq $parts[1] }) | Select-Object -First 1
            if ($info -or (Get-VuProp $Candidate 'Status') -eq 'Info') { return New-UpdateResult @base -Status Skipped -Message ([string](Get-VuProp $Candidate 'Message' 'msg.vu.unknown')) }
            return Invoke-SelfUpdater -Id $parts[1] -DryRun:$DryRun -Base $base
        }
        if ($parts[0] -ne 'oem') { return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown' }
        if ([bool](Get-VuProp $Candidate 'ManualOnly' $false)) {
            return New-UpdateResult @base -Status Skipped -Message 'msg.vu.biosManual'
        }
        switch ($parts[1]) {
            'dell'   { return Invoke-DellApply -DryRun:$DryRun -Base $base }
            'lenovo' { return Invoke-LenovoInstall -DryRun:$DryRun -Base $base }
            'hp'     { return Invoke-HpInstall -DryRun:$DryRun -Base $base }
            'asus'   { return Invoke-AsusOpen -DryRun:$DryRun -Base $base }
        }
        return New-UpdateResult @base -Status Skipped -Message 'msg.vu.unknown'
    } catch {
        Write-Log -Level WARN -Message "Vendor update $key failed: $($_.Exception.Message)"
        return New-UpdateResult @base -Status Failed -Message $_.Exception.Message
    }
}

Export-ModuleMember -Function *
