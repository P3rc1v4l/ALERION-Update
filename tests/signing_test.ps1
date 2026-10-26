<#
.SYNOPSIS
    Test for src/Signing.psm1 and tools/sign.ps1 (no admin). Uses throw-away self-signed certificates in
    CurrentUser\My (removed afterwards; CurrentUser\Root is never touched). A self-signed certificate is not
    trusted, so Authenticode reports UnknownError/NotTrusted; the test therefore uses -AllowUntrustedRoot and
    compares thumbprints and catalog integrity. In production "Valid" requires a trusted chain.
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

Write-Host 'Signing module test' -ForegroundColor Cyan
Import-Module (Join-Path $root 'src\Signing.psm1') -Force -DisableNameChecking

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("uc-sign-test-" + [guid]::NewGuid().ToString('N'))
$certs = New-Object System.Collections.Generic.List[object]
try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    function New-Pkg([string]$Name) {
        $d = Join-Path $tmp $Name
        New-Item -ItemType Directory -Path $d | Out-Null
        foreach ($item in 'src', 'assets', 'Install.ps1', 'Uninstall.ps1', 'VERSION', 'LICENSE', 'README.md', 'CHANGELOG.md') {
            $p = Join-Path $root $item
            if (Test-Path $p) { Copy-Item $p $d -Recurse -Force }
        }
        $d
    }
    function New-TestCert([string]$Cn) {
        $c = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$Cn" -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(2)
        $certs.Add($c); $c
    }
    function Sign-Pkg([string]$Dir, $Cert) {
        & (Join-Path $root 'tools\sign.ps1') -Root $Dir -CertThumbprint $Cert.Thumbprint -TimestampServer '' | Out-Null
    }
    function Trust($New, $Old, [string[]]$Pins = @()) {
        $a = @{ NewRoot = $New; AllowUntrustedRoot = $true; PinnedThumbprints = $Pins }
        if ($Old) { $a.InstalledRoot = $Old }
        Test-UpdatePackageTrust @a
    }

    $certA = New-TestCert 'UC Test A'
    $certB = New-TestCert 'UC Test B'

    $unsignedA = New-Pkg 'unsignedA'
    $unsignedB = New-Pkg 'unsignedB'
    $signedA = New-Pkg 'signedA'; Sign-Pkg $signedA $certA
    $signedA2 = New-Pkg 'signedA2'; Sign-Pkg $signedA2 $certA
    $signedB = New-Pkg 'signedB'; Sign-Pkg $signedB $certB

    Check 'unsigned package: Signed=false' { -not (Get-PackageSignature -Root $unsignedA).Signed }
    Check 'catalog created and signed by cert A' {
        $s = Get-PackageSignature -Root $signedA
        $s.Signed -and $s.Thumbprint -eq $certA.Thumbprint -and $s.CatalogOk -and @($s.Mismatches).Count -eq 0
    }
    Check 'untrusted self-signed reports UnknownError/NotTrusted (Valid=false without -AllowUntrustedRoot)' {
        $s = Get-PackageSignature -Root $signedA
        (-not $s.Valid) -and ($s.Status -in 'UnknownError', 'NotTrusted')
    }
    Check 'ps1 files carry the Authenticode signature' {
        $sig = Get-AuthenticodeSignature (Join-Path $signedA 'Install.ps1')
        $sig.SignerCertificate.Thumbprint -eq $certA.Thumbprint
    }
    Check 'signed installed + same-cert new -> sig.ok' {
        $r = Trust $signedA2 $signedA; $r.Allowed -and $r.Reason -eq 'sig.ok'
    }
    Check 'unsigned installed + unsigned new -> sig.unsignedLegacy (allowed)' {
        $r = Trust $unsignedB $unsignedA; $r.Allowed -and $r.Reason -eq 'sig.unsignedLegacy'
    }
    Check 'unsigned installed + signed new -> sig.ok (upgrade path)' {
        $r = Trust $signedA $unsignedA; $r.Allowed -and $r.Reason -eq 'sig.ok'
    }
    Check 'signed installed + unsigned new -> sig.missing' {
        $r = Trust $unsignedB $signedA; (-not $r.Allowed) -and $r.Reason -eq 'sig.missing'
    }
    Check 'signed installed + other cert -> sig.thumbprintMismatch' {
        $r = Trust $signedB $signedA; (-not $r.Allowed) -and $r.Reason -eq 'sig.thumbprintMismatch'
    }
    Check 'other cert but pinned thumbprint -> sig.ok (rollover)' {
        $r = Trust $signedB $signedA @($certB.Thumbprint); $r.Allowed -and $r.Reason -eq 'sig.ok'
    }
    Check 'without -AllowUntrustedRoot an untrusted signature is not accepted as installed trust' {
        $r = Test-UpdatePackageTrust -NewRoot $unsignedB -InstalledRoot $signedA
        $r.Allowed -and $r.Reason -eq 'sig.unsignedLegacy'
    }
    Check 'tampered file -> sig.catalogMismatch' {
        Add-Content -LiteralPath (Join-Path $signedA2 'src\Gui.xaml') -Value '<!-- evil -->'
        $r = Trust $signedA2 $signedA
        $s = Get-PackageSignature -Root $signedA2
        (-not $r.Allowed) -and $r.Reason -eq 'sig.catalogMismatch' -and (@($s.Mismatches) -match 'Gui\.xaml').Count -ge 1
    }
    Check 'extra file not in catalog -> sig.catalogMismatch' {
        $d = New-Pkg 'extra'; Sign-Pkg $d $certA
        Set-Content (Join-Path $d 'src\payload.ps1') 'x'
        $r = Trust $d $signedA; (-not $r.Allowed) -and $r.Reason -eq 'sig.catalogMismatch'
    }
    Check '*.sha256 next to package is tolerated' {
        $d = New-Pkg 'sha'; Sign-Pkg $d $certA
        Set-Content (Join-Path $d 'x.zip.sha256') 'abc'
        (Get-PackageSignature -Root $d).CatalogOk
    }
    Check 'broken catalog signature -> sig.invalid' {
        $d = New-Pkg 'broken'; Sign-Pkg $d $certA
        $bytes = [IO.File]::ReadAllBytes((Join-Path $d 'UpdateCenter.cat'))
        $bytes[40] = $bytes[40] -bxor 0xFF
        [IO.File]::WriteAllBytes((Join-Path $d 'UpdateCenter.cat'), $bytes)
        $r = Trust $d $signedA; (-not $r.Allowed) -and $r.Reason -in 'sig.invalid', 'sig.catalogMismatch'
    }
} finally {
    foreach ($c in $certs) { Remove-Item "Cert:\CurrentUser\My\$($c.Thumbprint)" -Force -ErrorAction SilentlyContinue }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) checks passed." -ForegroundColor Green
exit 0
