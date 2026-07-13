param(
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$Version = "1.1.3",
    [string]$UpdateManifestUrl = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $ProjectRoot "client")
try {
    flutter pub get
    flutter build apk --release --split-per-abi `
        --build-name $Version `
        --dart-define="APP_VERSION=$Version" `
        --dart-define="API_BASE_URL=$ApiBaseUrl" `
        --dart-define="UPDATE_MANIFEST_URL=$UpdateManifestUrl"
}
finally {
    Pop-Location
}
