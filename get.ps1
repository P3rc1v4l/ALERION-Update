<#
.SYNOPSIS
    Online installer for Update Center. Run in PowerShell:

        irm https://raw.githubusercontent.com/P3rc1v4l/ALERION-Update/main/get.ps1 | iex

    Downloads the latest release from GitHub, verifies its SHA-256 checksum, unpacks it to a
    temporary folder and starts the installer (one administrator prompt).
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$repo = 'P3rc1v4l/ALERION-Update'
$headers = @{ 'User-Agent' = 'UpdateCenter-Setup'; 'Accept' = 'application/vnd.github+json' }
Write-Host 'Update Center - downloading the latest version ...' -ForegroundColor Cyan
$rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
$tag = ([string]$rel.tag_name).TrimStart('v')
$zipAsset = @($rel.assets | Where-Object { $_.name -eq "UpdateCenter-v$tag.zip" }) | Select-Object -First 1
$shaAsset = @($rel.assets | Where-Object { $_.name -eq "UpdateCenter-v$tag.zip.sha256" }) | Select-Object -First 1
if (-not $zipAsset -or -not $shaAsset) { throw "Release v$tag has no UpdateCenter package." }
foreach ($a in @($zipAsset, $shaAsset)) { if (([uri]$a.browser_download_url).Host -ne 'github.com') { throw 'Unexpected download host.' } }

$work = Join-Path $env:TEMP ("UpdateCenterSetup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$zip = Join-Path $work 'UpdateCenter.zip'
Invoke-WebRequest -UseBasicParsing -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $headers
$sha = (Invoke-WebRequest -UseBasicParsing -Uri $shaAsset.browser_download_url -Headers $headers).Content
if ($sha -is [byte[]]) { $sha = [Text.Encoding]::ASCII.GetString($sha) }
$expected = ([string]$sha).Trim().Split(' ')[0].ToLowerInvariant()
$actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw 'Checksum mismatch - download rejected.' }
Write-Host "Version $tag verified (SHA-256 OK). Starting the installer ..." -ForegroundColor Green

$app = Join-Path $work 'app'
Expand-Archive -Path $zip -DestinationPath $app -Force
Get-ChildItem $app -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Start-Process -FilePath $ps -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $app 'Install.ps1')`""
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Done. Update Center is on your desktop and in the Start menu.' -ForegroundColor Green
