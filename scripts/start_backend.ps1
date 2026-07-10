$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $Python)) {
    py -3.11 -m venv (Join-Path $ProjectRoot ".venv")
    & $Python -m pip install -r (Join-Path $ProjectRoot "backend\requirements.txt")
}

Push-Location (Join-Path $ProjectRoot "backend")
try {
    & $Python -m uvicorn app.main:app --host 0.0.0.0 --port 8787
}
finally {
    Pop-Location
}

