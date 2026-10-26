<#
.SYNOPSIS
    Signs a staged Update Center package folder (code-signing infrastructure).
.DESCRIPTION
    1. Authenticode-signs every .ps1/.psm1 in -Root (helps AppLocker/WDAC users).
    2. Creates the file catalog UpdateCenter.cat (New-FileCatalog, version 2) over the whole folder. The catalog
       also protects .xaml/.json/.cs/.png/... which cannot carry their own signature.
    3. Authenticode-signs the catalog (SHA-256 + RFC 3161 timestamp).
    4. Optionally signs additional files (-ExtraFiles, e.g. Setup.exe).
    The folder must be the FINAL content of the package: any change after signing breaks the catalog.

    Choose ONE signing source:
      -PfxPath + -PfxPassword (SecureString) or env SIGN_PFX_PASSWORD
      -CertThumbprint          certificate in CurrentUser\My or LocalMachine\My
      -TrustedSigning          Azure Trusted Signing through signtool + Azure.CodeSigning.Dlib. Needs env:
                                 TS_ENDPOINT  e.g. https://weu.codesigning.azure.net
                                 TS_ACCOUNT   Trusted Signing account name
                                 TS_PROFILE   certificate profile name
                                 AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET (service principal)
                                 optional: SIGNTOOL_PATH, TS_DLIB_PATH (Azure.CodeSigning.Dlib.dll)
      -SelfSignedForTesting    creates a throw-away CurrentUser code-signing certificate. LOCAL TESTS ONLY, never CI.
.EXAMPLE
    .\tools\sign.ps1 -Root C:\stage\pkg -PfxPath cert.pfx
    .\tools\sign.ps1 -Root C:\stage\pkg -ExtraFiles C:\out\UpdateCenter-Setup-v1.5.0.exe -CertThumbprint ABCD...
#>
[CmdletBinding(DefaultParameterSetName = 'Pfx')]
param(
    [string]$Root,
    [Parameter(ParameterSetName = 'Pfx', Mandatory)][string]$PfxPath,
    [Parameter(ParameterSetName = 'Pfx')][securestring]$PfxPassword,
    [Parameter(ParameterSetName = 'Thumb', Mandatory)][string]$CertThumbprint,
    [Parameter(ParameterSetName = 'TS', Mandatory)][switch]$TrustedSigning,
    [Parameter(ParameterSetName = 'Self', Mandatory)][switch]$SelfSignedForTesting,
    [string[]]$ExtraFiles = @(),
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [switch]$KeepTestCertificate,
    [switch]$FilesOnly   # sign only -ExtraFiles (e.g. Setup.exe); no scripts, no catalog
)
$ErrorActionPreference = 'Stop'
if (-not $FilesOnly) {
    if (-not $Root) { throw '-Root is required (unless -FilesOnly).' }
    $Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
}
$catName = 'UpdateCenter.cat'

# --- resolve signing source -----------------------------------------------------------------
$cert = $null; $createdCert = $false; $tsMeta = $null
switch ($PSCmdlet.ParameterSetName) {
    'Pfx' {
        $pw = $PfxPassword
        if (-not $pw -and $env:SIGN_PFX_PASSWORD) {
            # CI passes the secret as an env var; build the SecureString directly (no plain-text conversion cmdlet).
            $pw = New-Object System.Security.SecureString
            foreach ($ch in $env:SIGN_PFX_PASSWORD.ToCharArray()) { $pw.AppendChar($ch) }
            $pw.MakeReadOnly()
        }
        if (-not $pw) { throw 'PFX password missing: pass -PfxPassword or set env SIGN_PFX_PASSWORD.' }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            (Resolve-Path -LiteralPath $PfxPath).ProviderPath, $pw, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    }
    'Thumb' {
        $t = $CertThumbprint.Replace(' ', '')
        $cert = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $t -and $_.HasPrivateKey }) | Select-Object -First 1
        if (-not $cert) { throw "Certificate with private key and thumbprint $t not found in CurrentUser\My / LocalMachine\My." }
    }
    'Self' {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Update Center TEST signing' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(30)
        $createdCert = $true
        Write-Warning 'Self-signed TEST certificate created in CurrentUser\My (not trusted; Authenticode status will not be Valid).'
    }
    'TS' {
        foreach ($n in 'TS_ENDPOINT', 'TS_ACCOUNT', 'TS_PROFILE') { if (-not [Environment]::GetEnvironmentVariable($n)) { throw "Trusted Signing: env $n is not set." } }
        $signtool = $env:SIGNTOOL_PATH
        if (-not $signtool) {
            $signtool = @(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending) | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $signtool -or -not (Test-Path $signtool)) { throw 'signtool.exe not found. Install the Windows SDK or set SIGNTOOL_PATH.' }
        $dlib = $env:TS_DLIB_PATH
        if (-not $dlib) {
            $dlib = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\MicrosoftTrustedSigningClientTools\Azure.CodeSigning.Dlib.dll", "$env:ProgramFiles\Microsoft Trusted Signing Client\*\Azure.CodeSigning.Dlib.dll" -ErrorAction SilentlyContinue) | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $dlib -or -not (Test-Path $dlib)) { throw 'Azure.CodeSigning.Dlib.dll not found. Install the Trusted Signing client tools (winget install -e --id Microsoft.Azure.TrustedSigningClientTools) or set TS_DLIB_PATH.' }
        $metaPath = Join-Path ([IO.Path]::GetTempPath()) ("ts-meta-" + [guid]::NewGuid().ToString('N') + '.json')
        (@{ Endpoint = $env:TS_ENDPOINT; CodeSigningAccountName = $env:TS_ACCOUNT; CertificateProfileName = $env:TS_PROFILE } | ConvertTo-Json) | Set-Content $metaPath -Encoding ASCII
        $tsMeta = @{ SignTool = $signtool; Dlib = $dlib; Meta = $metaPath }
    }
}
if ($cert -and -not $cert.HasPrivateKey) { throw 'The certificate has no private key.' }

function Sign-One([string]$Path) {
    if ($tsMeta) {
        $out = & $tsMeta.SignTool sign /v /fd SHA256 /tr 'http://timestamp.acs.microsoft.com' /td SHA256 /dlib $tsMeta.Dlib /dmdf $tsMeta.Meta $Path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "signtool failed for $Path (exit $LASTEXITCODE): $($out | Select-Object -Last 5 | Out-String)" }
        return
    }
    $args2 = @{ FilePath = $Path; Certificate = $cert; HashAlgorithm = 'SHA256'; IncludeChain = 'NotRoot' }
    if ($TimestampServer) { $args2.TimestampServer = $TimestampServer }   # empty = no timestamp (offline tests)
    $s = Set-AuthenticodeSignature @args2
    # Self-signed/untrusted roots report UnknownError; that is expected for test certificates.
    if ($s.Status -notin 'Valid', 'UnknownError') { throw "Signing $Path failed: $($s.Status) $($s.StatusMessage)" }
}

try {
    if ($FilesOnly) {
        foreach ($x in $ExtraFiles) { Write-Host "Signing $x ..."; Sign-One (Resolve-Path -LiteralPath $x).ProviderPath }
        return
    }
    # Never sign with a stale catalog around.
    Remove-Item -LiteralPath (Join-Path $Root $catName) -Force -ErrorAction SilentlyContinue

    $scripts = @(Get-ChildItem $Root -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\\.git\\' })
    Write-Host "Signing $($scripts.Count) script(s) ..."
    foreach ($f in $scripts) { Sign-One $f.FullName }

    # Catalog is built AFTER script signing (signing changes the file hashes), outside the folder first.
    $tmpCat = Join-Path ([IO.Path]::GetTempPath()) ("uc-" + [guid]::NewGuid().ToString('N') + '.cat')
    New-FileCatalog -Path $Root -CatalogFilePath $tmpCat -CatalogVersion 2 | Out-Null
    $cat = Join-Path $Root $catName
    Move-Item -LiteralPath $tmpCat -Destination $cat -Force
    Write-Host 'Signing catalog ...'
    Sign-One $cat

    foreach ($x in $ExtraFiles) { Write-Host "Signing $x ..."; Sign-One (Resolve-Path -LiteralPath $x).ProviderPath }

    $sig = Get-AuthenticodeSignature -LiteralPath $cat
    Write-Host ("Done. Catalog signer: {0} [{1}], status {2}" -f $sig.SignerCertificate.Subject, $sig.SignerCertificate.Thumbprint, $sig.Status) -ForegroundColor Green
    [pscustomobject]@{ Catalog = $cat; Thumbprint = $sig.SignerCertificate.Thumbprint; Status = [string]$sig.Status }
} finally {
    if ($tsMeta) { Remove-Item $tsMeta.Meta -Force -ErrorAction SilentlyContinue }
    if ($createdCert -and -not $KeepTestCertificate) { Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue }
}
