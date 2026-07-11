param(
    [string]$Version = "",
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$UpdateManifestUrl = "",
    [string]$SigningCertificatePath = "",
    [string]$SigningCertificatePassword = "",
    [switch]$RequireSignedInstaller
)

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "build_windows_setup.ps1") `
    -Version $Version `
    -ApiBaseUrl $ApiBaseUrl `
    -UpdateManifestUrl $UpdateManifestUrl `
    -SigningCertificatePath $SigningCertificatePath `
    -SigningCertificatePassword $SigningCertificatePassword `
    -RequireSignedInstaller:$RequireSignedInstaller
