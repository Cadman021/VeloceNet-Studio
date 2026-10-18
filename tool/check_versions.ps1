# Single-version policy check: pubspec.yaml, lib/core/app_info.dart and
# native_engine/Cargo.toml must all carry the same version (the engine
# ships only inside the app bundle, so independent versioning was dropped).
# Runs in CI (see .github/workflows/ci.yml) and locally before tagging.
$ErrorActionPreference = "Stop"

function Get-Version($Path, $Pattern) {
    $m = Select-String -Path $Path -Pattern $Pattern | Select-Object -First 1
    if ($null -eq $m) { throw "version not found in $Path" }
    return $m.Matches[0].Groups[1].Value
}

$root = Split-Path -Parent $PSScriptRoot
$pub = (Get-Version (Join-Path $root "pubspec.yaml") '^version:\s*(\S+)') -replace '\+.*$', ''
$appInfo = Get-Version (Join-Path $root "lib/core/app_info.dart") "kAppVersion = '([^']+)'"
$cargo = Get-Version (Join-Path $root "native_engine/Cargo.toml") '^version\s*=\s*"([^"]+)"'

$failed = $false
if ($pub -ne $appInfo) {
    Write-Output "::error::pubspec ($pub) != app_info.dart ($appInfo)"
    $failed = $true
}
if ($pub -ne $cargo) {
    Write-Output "::error::pubspec ($pub) != Cargo.toml ($cargo)"
    $failed = $true
}
if ($failed) { exit 1 }
Write-Output "versions in sync: $pub"
