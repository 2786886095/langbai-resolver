param(
    [string]$Version = "1.0.8",
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$UpdateManifestUrl = ""
)

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "build_windows_setup.ps1") `
    -Version $Version `
    -ApiBaseUrl $ApiBaseUrl `
    -UpdateManifestUrl $UpdateManifestUrl
