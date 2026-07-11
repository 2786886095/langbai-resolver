$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $Python)) {
    throw "Run scripts\start_backend.ps1 before updating the extractor."
}

& $Python -m pip install --upgrade yt-dlp
& $Python -m yt_dlp --version
