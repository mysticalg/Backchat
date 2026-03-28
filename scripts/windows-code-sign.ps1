[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Files,

    [string]$CertificateBase64 = $env:WINDOWS_SIGN_PFX_BASE64,

    [string]$CertificatePassword = $env:WINDOWS_SIGN_PFX_PASSWORD,

    [string]$TimestampUrl = $(if ($env:WINDOWS_SIGN_TIMESTAMP_URL) {
        $env:WINDOWS_SIGN_TIMESTAMP_URL
    } else {
        "http://timestamp.digicert.com"
    }),

    [string]$Description = "Backchat",

    [string]$DescriptionUrl = "https://github.com/mysticalg/Backchat"
)

$ErrorActionPreference = "Stop"

function Get-SignToolPath {
    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path $_) }

    $matches = foreach ($root in $roots) {
        $kitsRoot = Join-Path $root "Windows Kits\10\bin"
        if (-not (Test-Path $kitsRoot)) {
            continue
        }

        Get-ChildItem -Path $kitsRoot -Filter "signtool.exe" -Recurse -File -ErrorAction SilentlyContinue
    }

    $signTool = $matches | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $signTool) {
        throw "Could not find signtool.exe in the Windows SDK."
    }

    return $signTool.FullName
}

function Import-CodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base64,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $tempPfx = Join-Path ([System.IO.Path]::GetTempPath()) ("backchat-signing-" + [System.Guid]::NewGuid().ToString("N") + ".pfx")

    try {
        $bytes = [System.Convert]::FromBase64String($Base64)
        [System.IO.File]::WriteAllBytes($tempPfx, $bytes)

        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        $imported = Import-PfxCertificate `
            -FilePath $tempPfx `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -Password $securePassword `
            -Exportable

        $certificate = $imported | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
        if (-not $certificate) {
            throw "The PFX was imported, but no code-signing certificate with a private key was found."
        }

        return $certificate
    } finally {
        Remove-Item -LiteralPath $tempPfx -Force -ErrorAction SilentlyContinue
    }
}

if (-not $CertificateBase64) {
    throw "CertificateBase64 is required. Provide -CertificateBase64 or set WINDOWS_SIGN_PFX_BASE64."
}

if (-not $CertificatePassword) {
    throw "CertificatePassword is required. Provide -CertificatePassword or set WINDOWS_SIGN_PFX_PASSWORD."
}

$resolvedFiles = foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File not found: $file"
    }

    (Resolve-Path -LiteralPath $file).Path
}

$signToolPath = Get-SignToolPath
$certificate = Import-CodeSigningCertificate -Base64 $CertificateBase64 -Password $CertificatePassword

try {
    foreach ($filePath in $resolvedFiles) {
        Write-Host "Signing $filePath"
        & $signToolPath sign `
            /sha1 $certificate.Thumbprint `
            /fd SHA256 `
            /td SHA256 `
            /tr $TimestampUrl `
            /d $Description `
            /du $DescriptionUrl `
            $filePath

        if ($LASTEXITCODE -ne 0) {
            throw "signtool.exe failed while signing $filePath"
        }

        $signature = Get-AuthenticodeSignature -FilePath $filePath
        if (-not $signature.SignerCertificate) {
            throw "Signing completed but no Authenticode signer certificate was found on $filePath"
        }

        Write-Host "Authenticode status for $filePath: $($signature.Status)"
    }
} finally {
    Remove-Item -LiteralPath ("Cert:\CurrentUser\My\" + $certificate.Thumbprint) -Force -ErrorAction SilentlyContinue
}
