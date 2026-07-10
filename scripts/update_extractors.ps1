$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $Python)) {
    throw "请先运行 scripts\start_backend.ps1 创建后端环境。"
}

& $Python -m pip install --upgrade yt-dlp
& $Python -m yt_dlp --version

