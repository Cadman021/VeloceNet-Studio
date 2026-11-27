# NetStudio Rust Core Build Script for PowerShell
$ErrorActionPreference = "Stop"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Building NetStudio Rust Core Dynamic Library (DLL)..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EngineDir = Join-Path $ScriptDir "native_engine"
$DebugDir = Join-Path $ScriptDir "build\windows\x64\runner\Debug"
$ReleaseDir = Join-Path $ScriptDir "build\windows\x64\runner\Release"

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

    if (Test-Path $DebugDir) {
        Copy-Item -Path $DllPath -Destination $DebugDir -Force
        Write-Host "[SUCCESS] Copied to Windows Debug runner dir." -ForegroundColor Green
    }

    if (Test-Path $ReleaseDir) {
        Copy-Item -Path $DllPath -Destination $ReleaseDir -Force
        Write-Host "[SUCCESS] Copied to Windows Release runner dir." -ForegroundColor Green
    }
} else {
    Write-Warning "netstudio_engine.dll was not found at $DllPath"
}

$HeadlessPath = Join-Path $EngineDir "target\release\netstudio-headless.exe"

if (Test-Path $HeadlessPath) {
    Copy-Item -Path $HeadlessPath -Destination $ScriptDir -Force
    Write-Host "[SUCCESS] Copied netstudio-headless.exe to project root." -ForegroundColor Green

    if (Test-Path $DebugDir) {
        Copy-Item -Path $HeadlessPath -Destination $DebugDir -Force
        Write-Host "[SUCCESS] Copied headless daemon to Windows Debug runner dir." -ForegroundColor Green
    }

    if (Test-Path $ReleaseDir) {
        Copy-Item -Path $HeadlessPath -Destination $ReleaseDir -Force
        Write-Host "[SUCCESS] Copied headless daemon to Windows Release runner dir." -ForegroundColor Green
    }
} else {
    Write-Warning "netstudio-headless.exe was not found at $HeadlessPath"
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Done! Run 'flutter run -d windows' to launch the app." -ForegroundColor Cyan
