<#
.SYNOPSIS
    Builds UpdateCenter-Setup-v<version>.exe with Windows' built-in IExpress.
    The EXE contains the release ZIP and a tiny launcher; double-click -> one admin prompt -> installed.
.PARAMETER Zip
    Release ZIP to embed (UpdateCenter-v<version>.zip).
.PARAMETER OutDir
    Where to write the EXE.
.NOTES
    The EXE is not code-signed, so Windows SmartScreen shows "Unknown publisher" on first start
    ("More info" -> "Run anyway"). Signing needs a code-signing certificate.
#>
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$OutDir = (Split-Path -Parent $Zip)
)
$ErrorActionPreference = 'Stop'
$version = [regex]::Match((Split-Path $Zip -Leaf), 'v(\d+\.\d+\.\d+)').Groups[1].Value
if (-not $version) { throw 'Zip name must contain v<major.minor.patch>' }
$stage = Join-Path $env:TEMP ("uc-setup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $Zip (Join-Path $stage 'UpdateCenter.zip')

# IExpress cannot keep folders, so the EXE carries the ZIP and unpacks it itself.
@'
@echo off
set "UCDIR=%TEMP%\UpdateCenterSetup"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath $env:UCDIR -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive -LiteralPath '%~dp0UpdateCenter.zip' -DestinationPath $env:UCDIR -Force; Get-ChildItem $env:UCDIR -Recurse -File | Unblock-File; & (Join-Path $env:UCDIR 'Install.ps1')"
'@ | Set-Content (Join-Path $stage 'setup.cmd') -Encoding ASCII

$final = Join-Path (Resolve-Path $OutDir) "UpdateCenter-Setup-v$version.exe"
# IExpress/makecab fail on long target paths: build inside the short staging folder, move afterwards.
$exe = Join-Path $stage "UpdateCenter-Setup-v$version.exe"
# IExpress is picky: CRLF line endings and all values referenced through [Strings].
$lines = @(
    '[Version]', 'Class=IEXPRESS', 'SEDVersion=3',
    '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=1', 'HideExtractAnimation=1', 'UseLongFileName=1',
    'InsideCompressed=0', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N',
    'InstallPrompt=%InstallPrompt%', 'DisplayLicense=%DisplayLicense%', 'FinishMessage=%FinishMessage%', 'TargetName=%TargetName%',
    'FriendlyName=%FriendlyName%', 'AppLaunched=%AppLaunched%', 'PostInstallCmd=%PostInstallCmd%',
    'AdminQuietInstCmd=%AdminQuietInstCmd%', 'UserQuietInstCmd=%UserQuietInstCmd%', 'SourceFiles=SourceFiles',
    '[Strings]', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=', "TargetName=$exe", 'FriendlyName=Update Center Setup',
    'AppLaunched=cmd.exe /c setup.cmd', 'PostInstallCmd=<None>', 'AdminQuietInstCmd=', 'UserQuietInstCmd=',
    'FILE0="setup.cmd"', 'FILE1="UpdateCenter.zip"',
    '[SourceFiles]', "SourceFiles0=$stage\", '[SourceFiles0]', '%FILE0%=', '%FILE1%='
)
$sedFile = Join-Path $stage 'setup.sed'
[IO.File]::WriteAllText($sedFile, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
$p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\iexpress.exe') -ArgumentList "/N /Q $sedFile" -Wait -PassThru
if (-not (Test-Path $exe)) { throw "IExpress failed (exit $($p.ExitCode))" }
Move-Item $exe $final -Force
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Setup written: $final"
