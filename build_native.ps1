# NetStudio Rust Core Build Script for PowerShell
$ErrorActionPreference = "Stop"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Building NetStudio Rust Core Dynamic Library (DLL)..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EngineDir = Join-Path $ScriptDir "native_engine"

Push-Location $EngineDir
try {
    cargo build --release
} finally {
    Pop-Location
}

$DllPath = Join-Path $EngineDir "target\release\netstudio_engine.dll"

if (Test-Path $DllPath) {
    Copy-Item -Path $DllPath -Destination $ScriptDir -Force
    Write-Host "[SUCCESS] Copied netstudio_engine.dll to project root." -ForegroundColor Green

    $DebugDir = Join-Path $ScriptDir "build\windows\x64\runner\Debug"
    if (Test-Path $DebugDir) {
        Copy-Item -Path $DllPath -Destination $DebugDir -Force
        Write-Host "[SUCCESS] Copied to Windows Debug runner dir." -ForegroundColor Green
    }

    $ReleaseDir = Join-Path $ScriptDir "build\windows\x64\runner\Release"
    if (Test-Path $ReleaseDir) {
        Copy-Item -Path $DllPath -Destination $ReleaseDir -Force
        Write-Host "[SUCCESS] Copied to Windows Release runner dir." -ForegroundColor Green
    }
} else {
    Write-Warning "netstudio_engine.dll was not found at $DllPath"
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Done! Run 'flutter run -d windows' to launch the app." -ForegroundColor Cyan
