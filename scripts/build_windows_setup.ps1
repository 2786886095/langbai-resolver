param(
    [string]$Version = "1.0.0",
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$UpdateManifestUrl = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ClientRoot = Join-Path $ProjectRoot "client"
$InstallerScript = Join-Path $ProjectRoot "installer\windows\langbai-resolver.iss"

Push-Location $ClientRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed with exit code $LASTEXITCODE."
    }
    flutter build windows --release `
        --build-name $Version `
        --dart-define="APP_VERSION=$Version" `
        --dart-define="API_BASE_URL=$ApiBaseUrl" `
        --dart-define="UPDATE_MANIFEST_URL=$UpdateManifestUrl"
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Windows build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$isccCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
    (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if (-not $isccCandidates) {
    throw "Inno Setup 6 was not found. Install it and run this script again."
}

& ($isccCandidates[0]) "/DAppVersion=$Version" $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

Write-Host "Setup created: $ProjectRoot\dist\langbai-resolver-Setup.exe"
