param(
    [Parameter(Mandatory = $true)]
    [string]$SetupPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSignerSha256
)

$ErrorActionPreference = "Stop"
$SetupPath = [IO.Path]::GetFullPath($SetupPath)
$ExpectedSignerSha256 = $ExpectedSignerSha256.Trim().ToLowerInvariant()
$signature = Get-AuthenticodeSignature -LiteralPath $SetupPath
$actualSigner = ""
if ($signature.SignerCertificate) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $actualSigner = ([BitConverter]::ToString(
            $sha256.ComputeHash($signature.SignerCertificate.RawData)
        ) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}
if ($signature.Status -ne 'Valid' -or $actualSigner -ne $ExpectedSignerSha256) {
    throw "Setup signature check failed: $($signature.Status), signer=$actualSigner"
}

$TestRoot = Join-Path $env:RUNNER_TEMP "langbai-setup-smoke"
$InstallRoot = Join-Path $TestRoot "app"
$InstallLog = Join-Path $TestRoot "install.log"
if (Test-Path -LiteralPath $TestRoot) {
    $resolved = [IO.Path]::GetFullPath($TestRoot)
    $runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
    if (-not $resolved.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a smoke-test path outside RUNNER_TEMP."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

$appProcess = $null
try {
    $install = Start-Process -FilePath $SetupPath -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=$InstallRoot", "/LOG=$InstallLog"
    )
    if ($install.ExitCode -ne 0) {
        throw "Setup smoke installation failed with exit code $($install.ExitCode)."
    }
    $appPath = Join-Path $InstallRoot "langbai_resolver.exe"
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        throw "Installed application executable was not found."
    }
    $appProcess = Start-Process -FilePath $appPath -WindowStyle Hidden -PassThru
    $healthy = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8787/api/v1/health" -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                $healthy = $true
                break
            }
        } catch {
            if ($_.Exception.Response -and
                [int]$_.Exception.Response.StatusCode -eq 401) {
                $healthy = $true
                break
            }
        }
        if ($appProcess.HasExited) { break }
    }
    if (-not $healthy) {
        throw "Installed application did not start a healthy bundled backend."
    }
}
finally {
    if ($appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
        $appProcess.WaitForExit(5000)
    }
    $uninstaller = Join-Path $InstallRoot "unins000.exe"
    if (Test-Path -LiteralPath $uninstaller) {
        Start-Process -FilePath $uninstaller -WindowStyle Hidden -Wait -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        )
    }
}
