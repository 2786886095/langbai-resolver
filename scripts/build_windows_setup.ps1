param(
    [string]$Version = "",
    [string]$ApiBaseUrl = "http://127.0.0.1:8787",
    [string]$UpdateManifestUrl = "",
    [string]$SigningCertificatePath = "",
    [string]$SigningCertificatePassword = "",
    [switch]$RequireSignedInstaller
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ClientRoot = Join-Path $ProjectRoot "client"
$BackendRoot = Join-Path $ProjectRoot "backend"
$InstallerScript = Join-Path $ProjectRoot "installer\windows\langbai-resolver.iss"

if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspec = Get-Content -LiteralPath (Join-Path $ClientRoot "pubspec.yaml") -Raw
    $match = [regex]::Match($pubspec, '(?m)^version:\s*([^\s+#]+)')
    if (-not $match.Success) {
        throw "Unable to read the project version from client/pubspec.yaml."
    }
    $Version = $match.Groups[1].Value
}

if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
    throw "Version must be valid SemVer without a v prefix."
}
$VersionCore = ($Version -split '[-+]')[0]
if ($ApiBaseUrl -ne "http://127.0.0.1:8787") {
    throw "The bundled Windows backend currently requires ApiBaseUrl=http://127.0.0.1:8787."
}

$SigningCertificate = $null
$SigningCertificateSha256 = ""
if ($SigningCertificatePath) {
    $SigningCertificatePath = [IO.Path]::GetFullPath($SigningCertificatePath)
    if (-not (Test-Path -LiteralPath $SigningCertificatePath -PathType Leaf)) {
        throw "Windows signing certificate was not found: $SigningCertificatePath"
    }
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $SigningCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $SigningCertificatePath,
        $SigningCertificatePassword,
        $flags
    )
    if (-not $SigningCertificate.HasPrivateKey) {
        throw "Windows signing certificate does not contain a private key."
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $SigningCertificateSha256 = ([BitConverter]::ToString(
            $sha256.ComputeHash($SigningCertificate.RawData)
        ) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}
elseif ($RequireSignedInstaller) {
    throw "A trusted Authenticode certificate is required for a release Setup. Configure WINDOWS_SIGNING_CERTIFICATE_BASE64 and WINDOWS_SIGNING_CERTIFICATE_PASSWORD."
}

function Find-SignTool {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"),
        (Join-Path $env:ProgramFiles "Windows Kits\10\bin")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $tools = foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Filter signtool.exe -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' }
    }
    $tools | Sort-Object FullName -Descending | Select-Object -First 1
}

$SignTool = if ($SigningCertificate) { Find-SignTool } else { $null }
if ($SigningCertificate -and -not $SignTool) {
    throw "signtool.exe was not found in the Windows SDK."
}

function Sign-WindowsFile([string]$Path) {
    if (-not $SigningCertificate) { return }
    & $SignTool.FullName sign /fd SHA256 /td SHA256 `
        /tr "http://timestamp.digicert.com" `
        /f $SigningCertificatePath /p $SigningCertificatePassword $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode signing failed for $Path."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $actualFingerprint = ""
    if ($signature.SignerCertificate) {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $actualFingerprint = ([BitConverter]::ToString(
                $sha256.ComputeHash($signature.SignerCertificate.RawData)
            ) -replace '-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    if ($signature.Status -ne 'Valid' -or $actualFingerprint -ne $SigningCertificateSha256) {
        throw "Authenticode verification failed for $Path ($($signature.Status))."
    }
}

$BundledPython = Join-Path $BackendRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $BundledPython)) {
    $BundledPython = Get-Command python.exe -ErrorAction Stop | Select-Object -ExpandProperty Source
}

& $BundledPython -m pip install --disable-pip-version-check -q `
    --require-hashes `
    -r (Join-Path $BackendRoot "requirements-build.lock")
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
        --build-name $VersionCore `
        --dart-define="APP_VERSION=$Version" `
        --dart-define="API_BASE_URL=$ApiBaseUrl" `
        --dart-define="UPDATE_MANIFEST_URL=$UpdateManifestUrl" `
        --dart-define="WINDOWS_UPDATE_CERT_SHA256=$SigningCertificateSha256"
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

# Ship the supported Visual C++ runtime app-locally, so a clean non-admin
# Windows account does not need a separate redistributable installation.
$VcRedistRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022"
$VcRuntimeDirectory = Get-ChildItem -Path $VcRedistRoot `
    -Filter "Microsoft.VC143.CRT" -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Redist\\MSVC\\[^\\]+\\x64\\Microsoft\.VC143\.CRT$' } |
    Sort-Object { [version]$_.Parent.Parent.Name } -Descending |
    Select-Object -First 1
if (-not $VcRuntimeDirectory) {
    throw "The Visual C++ x64 app-local runtime was not found. Install the Visual Studio 2022 C++ desktop workload."
}
foreach ($runtime in Get-ChildItem -LiteralPath $VcRuntimeDirectory.FullName -Filter "*.dll" -File) {
    $signature = Get-AuthenticodeSignature -LiteralPath $runtime.FullName
    if ($signature.Status -ne 'Valid' -or
        -not $signature.SignerCertificate.Subject.Contains('Microsoft Corporation')) {
        throw "Visual C++ runtime signature verification failed: $($runtime.FullName)"
    }
    Copy-Item -LiteralPath $runtime.FullName -Destination $ReleaseRoot -Force
}

function Find-NativeTool([string]$Name) {
    $candidates = @()
    if ($env:ChocolateyInstall) {
        $packageName = if ($Name -eq 'aria2c') { 'aria2' } else { 'ffmpeg' }
        $package = Join-Path $env:ChocolateyInstall "lib\$packageName"
        if (Test-Path -LiteralPath $package) {
            $candidates += Get-ChildItem -LiteralPath $package -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    if (-not $candidates) {
        $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
        if ($command -and (Test-Path -LiteralPath $command.Source)) {
            $candidates += Get-Item -LiteralPath $command.Source
        }
    }
    $candidates | Sort-Object FullName | Select-Object -First 1
}

foreach ($toolName in @("ffmpeg", "ffprobe", "aria2c")) {
    $tool = Find-NativeTool $toolName
    if (-not $tool) {
        throw "$toolName.exe was not found. Install FFmpeg and aria2 before building Setup."
    }
    Copy-Item -LiteralPath $tool.FullName -Destination (Join-Path $BackendBundle "$toolName.exe") -Force
}

# yt-dlp uses a JavaScript runtime for full YouTube support. Keep the runtime
# version and checksum immutable so a release cannot silently pick up new code.
$DenoVersion = "2.9.2"
$DenoArchiveSha256 = "5fe194d26ac5ef77fcc5288c2c438c7a0465f3b6180440ebf04092714bf2dcdf"
$DenoArchive = Join-Path $BackendWork "deno-$DenoVersion-windows-x64.zip"
if (-not (Test-Path -LiteralPath $DenoArchive -PathType Leaf) -or
    (Get-FileHash -LiteralPath $DenoArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $DenoArchiveSha256) {
    Invoke-WebRequest `
        -Uri "https://github.com/denoland/deno/releases/download/v$DenoVersion/deno-x86_64-pc-windows-msvc.zip" `
        -OutFile $DenoArchive
}
if ((Get-FileHash -LiteralPath $DenoArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $DenoArchiveSha256) {
    throw "Pinned Deno archive checksum verification failed."
}
$DenoExtract = Join-Path $BackendWork "deno-$DenoVersion"
if (Test-Path -LiteralPath $DenoExtract) {
    $resolvedDenoExtract = [IO.Path]::GetFullPath($DenoExtract)
    $resolvedBackendWork = [IO.Path]::GetFullPath($BackendWork)
    if (-not $resolvedDenoExtract.StartsWith($resolvedBackendWork, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a Deno directory outside the PyInstaller work directory."
    }
    Remove-Item -LiteralPath $resolvedDenoExtract -Recurse -Force
}
Expand-Archive -LiteralPath $DenoArchive -DestinationPath $DenoExtract -Force
Copy-Item -LiteralPath (Join-Path $DenoExtract "deno.exe") -Destination $BackendBundle -Force

Sign-WindowsFile (Join-Path $ReleaseRoot "langbai_resolver.exe")
Sign-WindowsFile (Join-Path $BackendBundle "langbai_backend.exe")

$isccCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
    (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

if (-not $isccCandidates) {
    throw "Inno Setup 6 was not found. Install it and run this script again."
}

$InnoTranslationCommit = "c25dc6479cdc3be28e682a025fcf60765bba3de0"
$InnoTranslationSha256 = "6753be2c5e2740d859900fd902824db2ec568da5c5b52486524c9762d778b0b0"
$ChineseLanguageFile = Join-Path $BackendWork "ChineseSimplified-$InnoTranslationCommit.isl"
if (-not (Test-Path -LiteralPath $ChineseLanguageFile -PathType Leaf) -or
    (Get-FileHash -LiteralPath $ChineseLanguageFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $InnoTranslationSha256) {
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/jrsoftware/issrc/$InnoTranslationCommit/Files/Languages/ChineseSimplified.isl" `
        -OutFile $ChineseLanguageFile
}
if ((Get-FileHash -LiteralPath $ChineseLanguageFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $InnoTranslationSha256) {
    throw "Pinned Inno Setup Chinese translation checksum verification failed."
}

& ($isccCandidates[0]) "/DAppVersion=$Version" "/DAppNumericVersion=$VersionCore" "/DChineseLanguageFile=$ChineseLanguageFile" $InstallerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

$SetupPath = Join-Path $ProjectRoot "dist\langbai-resolver-Setup.exe"
Sign-WindowsFile $SetupPath
if ($SigningCertificateSha256) {
    Set-Content -LiteralPath (Join-Path $ProjectRoot "dist\windows-signing-cert-sha256.txt") `
        -Value $SigningCertificateSha256 -Encoding ascii -NoNewline
}

Write-Host "Setup created: $SetupPath"
