param(
    [string]$Version = "1.0.7",
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$UpdateManifestUrl = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ClientRoot = Join-Path $ProjectRoot "client"
$BackendRoot = Join-Path $ProjectRoot "backend"
$InstallerScript = Join-Path $ProjectRoot "installer\windows\langbai-resolver.iss"

$BundledPython = Join-Path $BackendRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $BundledPython)) {
    $BundledPython = Get-Command python.exe -ErrorAction Stop | Select-Object -ExpandProperty Source
}

& $BundledPython -m pip install --disable-pip-version-check -q `
    -r (Join-Path $BackendRoot "requirements.txt") `
    "pyinstaller>=6.11,<7"
if ($LASTEXITCODE -ne 0) {
    throw "Installing backend build dependencies failed with exit code $LASTEXITCODE."
}

$BackendDist = Join-Path $BackendRoot "dist\langbai_backend"
$BackendWork = Join-Path $BackendRoot ".pyinstaller"
New-Item -ItemType Directory -Path $BackendWork -Force | Out-Null
Push-Location $BackendRoot
try {
    & $BundledPython -m PyInstaller `
        --noconfirm `
        --clean `
        --onedir `
        --name langbai_backend `
        --distpath (Join-Path $BackendRoot "dist") `
        --workpath $BackendWork `
        --specpath $BackendWork `
        --paths $BackendRoot `
        --collect-all yt_dlp `
        --collect-submodules uvicorn `
        --collect-submodules anyio `
        run_backend.py
    if ($LASTEXITCODE -ne 0) {
        throw "Bundled backend build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

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

$ReleaseRoot = Join-Path $ClientRoot "build\windows\x64\runner\Release"
$BackendBundle = Join-Path $ReleaseRoot "backend"
$releaseFullPath = [IO.Path]::GetFullPath($ReleaseRoot)
$bundleFullPath = [IO.Path]::GetFullPath($BackendBundle)
if (-not $bundleFullPath.StartsWith($releaseFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace backend bundle outside the Windows release directory."
}
if (Test-Path -LiteralPath $BackendBundle) {
    Remove-Item -LiteralPath $BackendBundle -Recurse -Force
}
New-Item -ItemType Directory -Path $BackendBundle -Force | Out-Null
Copy-Item -Path (Join-Path $BackendDist "*") -Destination $BackendBundle -Recurse -Force

function Find-NativeTool([string]$Name) {
    $candidates = @()
    $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source)) {
        $candidates += Get-Item -LiteralPath $command.Source
    }
    if ($env:ChocolateyInstall) {
        $library = Join-Path $env:ChocolateyInstall "lib"
        if (Test-Path -LiteralPath $library) {
            $candidates += Get-ChildItem -Path $library -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    $candidates | Sort-Object Length -Descending | Select-Object -First 1
}

foreach ($toolName in @("ffmpeg", "ffprobe", "aria2c")) {
    $tool = Find-NativeTool $toolName
    if (-not $tool) {
        throw "$toolName.exe was not found. Install FFmpeg and aria2 before building Setup."
    }
    Copy-Item -LiteralPath $tool.FullName -Destination (Join-Path $BackendBundle "$toolName.exe") -Force
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
