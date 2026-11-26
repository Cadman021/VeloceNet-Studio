# Headless mode

`netstudio-headless` is the same Rust probing engine as the desktop app,
without Flutter, windows, or a tray icon. It is meant for servers and
containers: run it as a daemon, scrape Prometheus, or use `--once` from a
cron job / CI pipeline.

The binary is small because it only links the engine crate. It uses the
app's existing JSON target format, so no separate configuration language is
needed.

## Build

```bash
cd native_engine
cargo build --release
# Linux/macOS: target/release/netstudio-headless
# Windows:     target\release\netstudio-headless.exe
```

On Windows, `build_native.ps1` / `build_native.bat` build both the DLL and
the headless executable and copy them to the project root (and to the
Flutter runner directories when they exist). Release archives ship the
headless binary next to the desktop app.

The engine still probes ICMP through the platform APIs: Windows IP Helper,
and unprivileged ping sockets on Linux/macOS. No root is required for ICMP;
only ports below 1024 need extra privileges.

## Quick start

These commands assume you are in the repository root and have just built the
binary. Replace the paths if `netstudio-headless` is installed elsewhere.

### Windows (PowerShell)

```powershell
cargo build --release --manifest-path native_engine\Cargo.toml
Copy-Item docs\examples\targets.json targets.json

# 1. Validate the file (does not send probes).
.\native_engine\target\release\netstudio-headless.exe --config targets.json --check

# 2. One probe of every target, then exit.
.\native_engine\target\release\netstudio-headless.exe --config targets.json --once

# 3. Run as a daemon with HTTP enabled.
.\native_engine\target\release\netstudio-headless.exe --config targets.json --listen 127.0.0.1:9187 --output status.json --interval 5
```

Open a second PowerShell window for the endpoints:

```powershell
curl.exe -s http://127.0.0.1:9187/healthz
curl.exe -s http://127.0.0.1:9187/readyz
curl.exe -s http://127.0.0.1:9187/metrics
curl.exe -s http://127.0.0.1:9187/api/v1/status
```

### Linux / macOS

```bash
cargo build --release --manifest-path native_engine/Cargo.toml
cp docs/examples/targets.json targets.json

./native_engine/target/release/netstudio-headless --config targets.json --check
./native_engine/target/release/netstudio-headless --config targets.json --once
./native_engine/target/release/netstudio-headless --config targets.json \
  --listen 127.0.0.1:9187 --output status.json --interval 5
```

```bash
curl -s http://127.0.0.1:9187/healthz
curl -s http://127.0.0.1:9187/readyz
curl -s http://127.0.0.1:9187/metrics
curl -s http://127.0.0.1:9187/api/v1/status
```

Notes:

* On Windows, use **one line** or PowerShell's backtick (`` ` ``) for
  continuation. A trailing backslash is a bash/zsh convention and is passed
  to the program as an argument by PowerShell.
* `/readyz` returns `503` until the first probe sample exists; wait a few
  seconds and retry. `/healthz` is alive immediately.
* `--once` exits with `3` when at least one target is down. That is a valid
  test result, not a crash; the JSON snapshot is still printed.
* Press `Ctrl+C` to stop the daemon gracefully.
* `docs/examples/targets.json` uses `1.1.1.1` over ICMP and TCP/53, so it
  exercises two probe types without DNS. Edit it or export your own targets
  from the desktop app.

## Configuration

Use **Export JSON** in the app (or a hand-written file). Both forms are
accepted:

* the full app backup envelope;
* a bare array of targets.

```json
{
  "app": "velocenet-studio",
  "version": 1,
  "settings": { "offline_after": 3, "recover_after": 2 },
  "targets": [
    {
      "id": 1,
      "name": "API",
      "host": "api.example.com",
      "port": 443,
      "protocol": "HTTPS",
      "http_path": "/health",
      "interval_ms": 5000,
      "timeout_ms": 1500
    },
    { "host": "1.1.1.1", "protocol": "ICMP" }
  ]
}
```

`protocol` accepts `ICMP` / `TCP` / `HTTP` / `HTTPS` (or `0`–`3`). Missing
fields use the same defaults as the app: ICMP, port 80, 1000 ms interval,
1500 ms timeout. Values are clamped instead of rejected: interval
200–60000 ms, timeout 100–10000 ms, thresholds 1–20. Up to 500 targets are
loaded.

`app`, `version`, and `settings` are optional. Targets with
`"is_enabled": false` are skipped. Invalid hosts (spaces, bad labels,
octets above 255, malformed IPv6) are skipped with a warning; one bad
target never prevents the rest from running. Structural JSON errors and a
file with zero usable targets are fatal (`exit 2`).

Duplicate or missing `id` values are assigned fresh ids so Prometheus labels
and snapshots stay stable within a run.

## Usage

```bash
netstudio-headless --config targets.json --check
netstudio-headless --config targets.json --once
netstudio-headless --config targets.json --interval 15 --listen 127.0.0.1:9101 --output /var/lib/netstudio/status.json
```

| Flag | Meaning |
|---|---|
| `-c`, `--config <PATH>` | Target file (required for run/check/once) |
| `--check` | Validate the file and exit |
| `--once` | Probe every target once, print one JSON snapshot, exit |
| `--interval <SECS>` | Snapshot interval, 1–3600 (default 5) |
| `--listen <IP:PORT>` | Enable HTTP (disabled by default) |
| `--output <PATH>` | Atomically replace this file with the latest snapshot |
| `--pid-file <PATH>` | Write the process id while running |
| `-q`, `--quiet` | Do not stream NDJSON snapshots to stdout |
| `--log-level <LEVEL>` | `error`, `warn`, `info` (default), `debug` |
| `-h`, `--help` | Usage |
| `-V`, `--version` | Version |

`--once` prints pretty JSON to stdout (`--quiet` does not suppress it) and
returns:

* `0` — every probed target answered;
* `3` — at least one target is down;
* `2` — configuration/CLI error;
* `1` — runtime failure (for example the output directory does not exist).

The daemon streams one compact JSON snapshot per line (NDJSON) to stdout
unless `--quiet` is given. Each line has the same shape:

```json
{
  "schema": 1,
  "type": "snapshot",
  "time": "2026-01-01T00:00:00.000Z",
  "epoch_ms": 1767225600000,
  "version": "1.6.0",
  "summary": {
    "targets": 2, "pending": 0, "online": 1, "degraded": 0,
    "offline": 1, "down": 1
  },
  "targets": [ /* TargetStats, identical to the app/FFI JSON */ ]
}
```

`summary.down` counts targets whose most recent probe failed. A target that
has not been probed yet is `pending`, not down.

### Daemon lifecycle

* `SIGINT` / `SIGTERM` (Windows: console Ctrl+C / Ctrl+Break) trigger a
  graceful stop: probes are cancelled, the HTTP listener closes, and the pid
  file is removed.
* Configuration is read once at startup. Restart the process after editing
  the file; there is no `SIGHUP` reload yet.
* Logs go to stderr as `TIMESTAMP LEVEL message`; stdout is reserved for
  snapshots.
* `--output` writes a temporary file in the same directory and renames it
  over the target, so readers never see a half-written JSON document. The
  directory must already exist.

Example systemd unit:

```ini
[Unit]
Description=NetStudio headless monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/netstudio-headless \
  --config /etc/netstudio/targets.json \
  --listen 127.0.0.1:9101 \
  --output /var/lib/netstudio/status.json \
  --pid-file /run/netstudio/headless.pid \
  --log-level info
Restart=on-failure
RestartSec=5
DynamicUser=yes
RuntimeDirectory=netstudio
StateDirectory=netstudio

[Install]
WantedBy=multi-user.target
```

## HTTP endpoints

HTTP is off unless `--listen` is passed. Bind to loopback and put an
authenticating reverse proxy in front of it if the metrics must be reachable
from another host; the built-in server has no TLS and no authentication.

| Path | Response |
|---|---|
| `/` | Short plain-text index |
| `/healthz` | `200 ok` whenever the process is alive |
| `/readyz` | `200 ready` after at least one sample; `503 starting` before |
| `/metrics` | Prometheus text format |
| `/api/v1/status` | The latest snapshot as JSON |

Only `GET` and `HEAD` are allowed (`405` otherwise). Unknown paths return
`404`. Requests are capped at 8 KiB and the server closes each connection
after one response.

### Prometheus metrics

All target metrics carry the labels
`id`, `name`, `host`, `port`, `protocol`.

| Metric | Type | Meaning |
|---|---|---|
| `netstudio_build_info` | gauge | Always `1`, labelled with `version` |
| `netstudio_target_info` | gauge | Always `1`; the target exists |
| `netstudio_target_up` | gauge | `1` if the latest probe answered |
| `netstudio_target_status` | gauge | `0` pending, `1` online, `2` degraded, `3` offline |
| `netstudio_target_sent_total` | counter | Probes sent |
| `netstudio_target_received_total` | counter | Replies received |
| `netstudio_target_lost_total` | counter | Probes without a reply |
| `netstudio_target_loss_rate_percent` | gauge | Lifetime loss, percent |
| `netstudio_target_rtt_last_ms` | gauge | Last RTT; `-1` means down |
| `netstudio_target_rtt_min_ms` | gauge | Minimum successful RTT |
| `netstudio_target_rtt_max_ms` | gauge | Maximum successful RTT |
| `netstudio_target_rtt_avg_ms` | gauge | Mean successful RTT |
| `netstudio_target_jitter_ms` | gauge | RFC 3550 jitter estimate |
| `netstudio_target_last_check_timestamp_seconds` | gauge | Unix time of the latest sample |
| `netstudio_target_http_status_code` | gauge | Latest HTTP code (HTTP/HTTPS only) |
| `netstudio_target_cert_days_left` | gauge | TLS certificate days left (HTTPS only) |

Example alert:

```yaml
- alert: NetStudioTargetDown
  expr: netstudio_target_up == 0 and netstudio_target_sent_total > 0
  for: 2m
```

Note that the engine has no persistence: counters and the 40-sample RTT
window reset when the process restarts. Uptime history and the alert log
remain desktop-app features.

## What is not included

This first headless release covers the Ping Matrix engine (ICMP/TCP/HTTP/HTTPS,
statuses, RTT/jitter/loss, HTTP status, TLS expiry) and its HTTP surface.
Desktop-only features are intentionally absent:

* traceroute/MTR, bandwidth, Warp, port scan and DNS lookup;
* desktop notifications, webhooks, Telegram/Discord/ntfy alerts;
* 30-day uptime history and CSV/JSON export;
* hot reload (`SIGHUP`) and TLS/authentication on the HTTP server.

For container deployments, mount the config read-only, publish only the
loopback metrics port, and set a memory limit; history is bounded per target
and the target count is capped at 500.
