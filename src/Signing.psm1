<#
    Signing.psm1 - verification of signed Update Center packages (ASCII-only source, PowerShell 5.1).

    A package is "signed" when its root contains UpdateCenter.cat, a Windows file catalog (version 2)
    that lists SHA-256 hashes of every shipped file and itself carries an Authenticode signature.
    Note: "Valid" (Authenticode status) needs a certificate that chains to a trusted root. A self-signed
    test certificate yields Signed=$true, Valid=$false (status UnknownError/NotTrusted) - the catalog
    integrity and the thumbprint are still checked.
#>
Set-StrictMode -Version 2.0

$script:CatalogName = 'UpdateCenter.cat'
$script:CatalogAllowlist = @('*.sha256', 'UpdateCenter.cat')

function Get-PackageSignature {
    <# Get-PackageSignature -Root <dir>
       -> [pscustomobject] Signed, Valid, Status, Thumbprint, Subject, CatalogOk, Mismatches (string[]) #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$AllowUntrustedRoot)

    $r = [pscustomobject]@{
        Signed = $false; Valid = $false; Status = 'NotSigned'; Thumbprint = ''; Subject = ''
        CatalogOk = $false; Mismatches = [string[]]@()
    }
    $cat = Join-Path $Root $script:CatalogName
    if (-not (Test-Path -LiteralPath $cat -PathType Leaf)) { return $r }

    $sig = $null
    try { $sig = Get-AuthenticodeSignature -LiteralPath $cat -ErrorAction Stop } catch { $r.Status = 'Error'; return $r }
    $r.Status = [string]$sig.Status
    # A catalog that exists but whose signature is broken (HashMismatch etc.) still counts as signed-but-invalid.
    $r.Signed = ([string]$sig.Status -ne 'NotSigned')
    if ($sig.SignerCertificate) {
        $r.Thumbprint = ([string]$sig.SignerCertificate.Thumbprint).ToUpperInvariant()
        $r.Subject = [string]$sig.SignerCertificate.Subject
    }
    $r.Valid = ($sig.Status -eq 'Valid')
    # Test only: a self-signed certificate reports UnknownError/NotTrusted; the catalog hash itself is intact.
    if (-not $r.Valid -and $AllowUntrustedRoot -and $r.Signed -and ([string]$sig.Status -in 'UnknownError', 'NotTrusted')) { $r.Valid = $true }

    $mism = New-Object System.Collections.Generic.List[string]
    try {
        $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
        $res = Test-FileCatalog -Detailed -CatalogFilePath $cat -Path $rootFull -ErrorAction Stop
        $catItems = @{}
        foreach ($k in @($res.CatalogItems.Keys)) { $catItems[([string]$k).Replace('/', '\').TrimStart('\').ToLowerInvariant()] = [string]$res.CatalogItems[$k] }
        $pathItems = @{}
        foreach ($k in @($res.PathItems.Keys)) { $pathItems[([string]$k).Replace('/', '\').TrimStart('\').ToLowerInvariant()] = [string]$res.PathItems[$k] }
        foreach ($k in $pathItems.Keys) {
            $leaf = Split-Path $k -Leaf
            $allowed = $false
            foreach ($pat in $script:CatalogAllowlist) { if ($leaf -like $pat -and $k.IndexOf([char]92) -lt 0) { $allowed = $true } }
            if ($allowed) { continue }
            if (-not $catItems.ContainsKey($k)) { $mism.Add("not in catalog: $k") }
            elseif ($catItems[$k] -ne $pathItems[$k]) { $mism.Add("modified: $k") }
        }
        foreach ($k in $catItems.Keys) { if (-not $pathItems.ContainsKey($k)) { $mism.Add("missing: $k") } }
    } catch {
        $mism.Add("catalog check failed: $($_.Exception.Message)")
    }
    $r.Mismatches = [string[]]@($mism.ToArray())
    $r.CatalogOk = (@($mism).Count -eq 0)
    return $r
}

function Test-UpdatePackageTrust {
    <# Test-UpdatePackageTrust -NewRoot <dir> -InstalledRoot <dir> [-PinnedThumbprints <string[]>]
       -> [pscustomobject] Allowed (bool), Reason (sig.ok | sig.unsignedLegacy | sig.missing | sig.invalid |
          sig.thumbprintMismatch | sig.catalogMismatch), Detail (string)
       Trust on first use: an installed copy with a valid signature only accepts packages signed by the same
       certificate (or a pinned one). An unsigned installed copy accepts anything (SHA-256 check stays). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NewRoot,
        [string]$InstalledRoot,
        [string[]]$PinnedThumbprints = @(),
        [switch]$AllowUntrustedRoot   # tests only (self-signed certificates)
    )
    function Out-Trust([bool]$Allowed, [string]$Reason, [string]$Detail) {
        [pscustomobject]@{ Allowed = $Allowed; Reason = $Reason; Detail = $Detail }
    }
    $new = Get-PackageSignature -Root $NewRoot -AllowUntrustedRoot:$AllowUntrustedRoot
    $old = $null
    if ($InstalledRoot -and (Test-Path -LiteralPath $InstalledRoot)) { $old = Get-PackageSignature -Root $InstalledRoot -AllowUntrustedRoot:$AllowUntrustedRoot }
    # The installed copy counts as signed only if its signature is valid; a broken one gives no trust anchor
    # we could rely on, so it behaves like an unsigned install.
    $installedSigned = ($null -ne $old -and $old.Signed -and $old.Valid)

    if (-not $installedSigned) {
        if (-not $new.Signed) { return Out-Trust $true 'sig.unsignedLegacy' 'Installed copy is unsigned; unsigned package accepted (SHA-256 only).' }
        if (-not $new.CatalogOk) { return Out-Trust $false 'sig.catalogMismatch' ($new.Mismatches -join '; ') }
        if (-not $new.Valid) { return Out-Trust $false 'sig.invalid' "Signature status: $($new.Status)" }
        return Out-Trust $true 'sig.ok' "Signed by $($new.Subject) [$($new.Thumbprint)]"
    }

    # Installed copy is signed and valid -> strict policy.
    if (-not $new.Signed) { return Out-Trust $false 'sig.missing' 'Installed copy is signed but the new package has no signature.' }
    if (-not $new.Valid) { return Out-Trust $false 'sig.invalid' "Signature status: $($new.Status)" }
    $allowedThumbs = @($old.Thumbprint) + @($PinnedThumbprints | ForEach-Object { ([string]$_).Replace(' ', '').ToUpperInvariant() })
    if ($allowedThumbs -notcontains $new.Thumbprint) {
        return Out-Trust $false 'sig.thumbprintMismatch' "Signer $($new.Thumbprint) differs from installed signer $($old.Thumbprint)."
    }
    if (-not $new.CatalogOk) { return Out-Trust $false 'sig.catalogMismatch' ($new.Mismatches -join '; ') }
    return Out-Trust $true 'sig.ok' "Signed by $($new.Subject) [$($new.Thumbprint)]"
}

Export-ModuleMember -Function Get-PackageSignature, Test-UpdatePackageTrust
