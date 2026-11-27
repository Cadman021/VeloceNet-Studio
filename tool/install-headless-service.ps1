<#
.SYNOPSIS
Registers netstudio-headless as a Windows service and controls it.

.DESCRIPTION
The headless daemon registers itself with the Service Control Manager when it
is started with --windows-service; this script only writes the registration,
checks the config first, and sets a restart policy. Logs must go to a file:
a service has no console, so -LogPath is strongly recommended.

.PARAMETER Action
install (default), uninstall, start, stop, restart or status.

.PARAMETER ConfigPath
Target file exported by the app. Validated with --check before installing.

.PARAMETER LogPath
File the daemon appends its logs to (rotated to <path>.1 at 8 MiB).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool/install-headless-service.ps1 `
  -ExePath C:\ProgramData\netstudio\netstudio-headless.exe `
  -ConfigPath C:\ProgramData\netstudio\targets.json `
  -LogPath C:\ProgramData\netstudio\headless.log -Listen 127.0.0.1:9101
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'restart', 'status')]
    [string]$Action = 'install',

    [string]$ServiceName = 'netstudio-headless',

    [string]$ExePath,

    [string]$ConfigPath,

    [string]$LogPath,

    [string]$Listen,

    [string]$TokenFile,

    [int]$WatchConfig = 0,

    [int]$RestartDelaySeconds = 5,

    [switch]$DoNotStart
)

$ErrorActionPreference = 'Stop'

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RequiredPath([string]$path, [string]$what) {
    if (-not $path) {
        throw "-$what is required."
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "-$what does not exist: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
}

function Get-ServiceOrNull([string]$name) {
    return Get-Service -Name $name -ErrorAction SilentlyContinue
}

function Assert-Elevated {
    if (-not (Test-Elevated)) {
        throw "Run this from an elevated PowerShell: registering or controlling a service needs administrator rights."
    }
}

function Show-Status {
    $service = Get-ServiceOrNull $ServiceName
    if (-not $service) {
        Write-Output "service $ServiceName is not installed"
        return
    }
    $query = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    Write-Output "service ${ServiceName}: $($service.Status) ($($query.StartMode))"
    Write-Output "  binary: $($query.PathName)"
    if ($query.ProcessId) {
        Write-Output "  process id: $($query.ProcessId)"
    }
}

function Invoke-RestartPolicy([string]$name) {
    $millis = $RestartDelaySeconds * 1000
    # Restart three times, then give up: an endless restart loop hides a
    # permanently broken config instead of surfacing it.
    $actions = "restart/$millis/restart/$millis/restart/$millis"
    & sc.exe failure $name reset= 86400 actions= $actions | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "could not set the restart policy for $name (sc.exe exit $LASTEXITCODE)"
    }
}

function Install-Service {
    Assert-Elevated
    $exe = Resolve-RequiredPath $ExePath "ExePath"
    $config = Resolve-RequiredPath $ConfigPath "ConfigPath"

    if (Get-ServiceOrNull $ServiceName) {
        throw "service $ServiceName is already installed; use -Action restart, or -Action uninstall first."
    }

    $arguments = @("`"$config`"")
    # Pre-flight the same file the service will read, as the operator.
    & $exe --config $config --check | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "--check failed for $config (exit $LASTEXITCODE); not installing a service that cannot start."
    }

    $arguments += "--windows-service"
    $arguments += "--quiet"
    if ($LogPath) {
        $log = [IO.Path]::GetFullPath($LogPath)
        $logDir = Split-Path -Parent $log
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            throw "log directory does not exist: $logDir"
        }
        $arguments += "--log-file `"$log`""
    } else {
        Write-Warning "no -LogPath: the service has no console, so its output will be lost. Pass -LogPath next time."
    }
    if ($Listen) {
        $arguments += "--listen $Listen"
    }
    if ($TokenFile) {
        $token = Resolve-RequiredPath $TokenFile "TokenFile"
        $arguments += "--http-token-file `"$token`""
    }
    if ($WatchConfig -gt 0) {
        $arguments += "--watch-config $WatchConfig"
    }

    $binaryPath = "`"$exe`" --config $($arguments -join ' ')"
    New-Service -Name $ServiceName -BinaryPathName $binaryPath -StartupType Automatic `
        -Description "NetStudio headless probe daemon" | Out-Null
    Invoke-RestartPolicy $ServiceName

    if ($DoNotStart) {
        Write-Output "installed $ServiceName (not started)"
        Write-Output "  binary: $binaryPath"
        return
    }
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 2
    Show-Status
    if ((Get-ServiceOrNull $ServiceName).Status -ne "Running") {
        throw "service $ServiceName did not reach Running; check the log file and Get-EventLog -LogName System -Source Service Control Manager"
    }
}

switch ($Action) {
    'install' {
        Install-Service
    }
    'uninstall' {
        Assert-Elevated
        $service = Get-ServiceOrNull $ServiceName
        if (-not $service) {
            Write-Output "service $ServiceName is not installed"
            break
        }
        if ($service.Status -ne "Stopped") {
            Stop-Service -Name $ServiceName -Force
        }
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "sc.exe delete failed with exit $LASTEXITCODE"
        }
        Write-Output "removed $ServiceName"
    }
    'start' {
        Assert-Elevated
        Start-Service -Name $ServiceName
        Start-Sleep -Seconds 2
        Show-Status
    }
    'stop' {
        Assert-Elevated
        Stop-Service -Name $ServiceName
        Show-Status
    }
    'restart' {
        Assert-Elevated
        Restart-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2
        Show-Status
    }
    'status' {
        Show-Status
    }
}