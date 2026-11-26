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
* `--probe-concurrency` bounds sockets, DNS lookups, and blocking-pool work
  independently of the target count (up to 500). Raise it only after checking
  file-descriptor and resolver limits; the default 32 is safe for a small VM.
* `/readyz` returns `503` until the first probe sample exists; wait a few
  seconds and retry. `/healthz` is alive immediately.
* `--once` exits with `3` when at least one target is down. That is a valid
  test result, not a crash; the snapshot is still printed. Add `--format json`
  if you need machine-readable output in a terminal.
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
netstudio-headless --config targets.json --interval 15 --probe-concurrency 32 --listen 127.0.0.1:9101 --output /var/lib/netstudio/status.json
```

| Flag | Meaning |
|---|---|
| `-c`, `--config <PATH>` | Target file (required for run/check/once) |
| `--check` | Validate the file and exit |
| `--once` | Probe every target once, print a snapshot, exit |
| `--interval <SECS>` | Snapshot interval, 1–3600 (default 5) |
| `--probe-concurrency <N>` | Maximum probes in flight, 1–256 (default 32) |
| `--listen <IP:PORT>` | Enable HTTP (disabled by default) |
| `--output <PATH>` | Atomically replace this file with the latest snapshot |
| `--pid-file <PATH>` | Write the process id while running |
| `-q`, `--quiet` | Do not stream snapshots to stdout |
| `--format <MODE>` | `auto` (default), `json` (NDJSON/pretty JSON), `text` (human table) |
| `--color <WHEN>` | `auto` (default), `always`, `never`; `--no-color` is an alias for `never` |
| `--log-level <LEVEL>` | `error`, `warn`, `info` (default), `debug` |
| `-h`, `--help` | Usage |
| `-V`, `--version` | Version |

On a terminal, `--once` prints a human-readable table; when stdout is piped
or redirected it prints pretty JSON so scripts keep working. Use
`--format json` or `--format text` to force either form. `--quiet` does not
suppress the `--once` result. It returns:

* `0` — every probed target answered;
* `3` — at least one target is down;
* `2` — configuration/CLI error;
* `1` — runtime failure (for example the output directory does not exist).

The daemon streams a snapshot to stdout unless `--quiet` is given. `auto`
chooses a color-coded table on a terminal and compact NDJSON when stdout
is piped; `--format` overrides that choice. The JSON/NDJSON never contains
ANSI escape codes. A terminal snapshot looks like:

```text
------------------------------------------------------------------------------------------
NetStudio Headless v1.6.0  2026-01-01T00:00:00.000Z
STATUS    TARGET                PROBE                   RTT     JITTER     LOSS    OK/SENT
------------------------------------------------------------------------------------------
ONLINE    Cloudflare DNS        ICMP 1.1.1.1:53     0.72 ms    0.00 ms     0.0%        1/1
ONLINE    Cloudflare DNS (TCP)  TCP 1.1.1.1:53      1.26 ms    6.18 ms     0.0%        1/1
2 online  |  0 degraded  |  0 offline  |  0 pending  |  0 stale  |  0 down
```

Statuses are green/yellow/red/dim, headers and separators are dim, and
`--color always` keeps the colors when the output is redirected. `NO_COLOR`
and `--no-color` disable them. Use `--format json` for the machine form
(pretty JSON for `--once`, compact NDJSON for the daemon):

```json
{
  "schema": 1,
  "type": "snapshot",
  "time": "2026-01-01T00:00:00.000Z",
  "epoch_ms": 1767225600000,
  "version": "1.6.0",
  "summary": {
    "targets": 2, "pending": 0, "online": 1, "degraded": 0,
    "offline": 1, "down": 1, "stale": 0
  },
  "targets": [ /* TargetStats, identical to the app/FFI JSON */ ]
}
```

`summary.down` counts targets whose most recent probe failed. A target that
has not been probed yet is `pending`, not down. `summary.stale` counts
targets whose latest sample is older than `2 × interval + timeout`; a stalled
probe therefore stops looking fresh even though the daemon is still running.

Each target also carries the reason for its last failure:

| Field | Meaning |
|---|---|
| `last_error` | Short, single-line, sanitized reason (max 160 chars), cleared on success |
| `last_error_kind` | `dns`, `timeout`, `refused`, `unreachable`, `icmp_unavailable`, `tls`, `http`, or `other` |
| `tcp_fallback` | `true` when ICMP was unavailable and the probe used TCP |
| `last_sample_age_ms` | Age of the latest sample; `null` before the first one |
| `stale` | `true` after `stale_after_ms` without a fresh sample |
| `stale_after_ms` | This target's `2 × interval + timeout` threshold |

The text table adds a `DETAIL` column only when at least one target has an
error, a fallback, or a stale sample; the compact table for healthy targets is
unchanged. Stale targets are also logged once when they cross the threshold
and once when samples resume, so a dead prober does not repeat a warning on
every scrape.

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
Binding to a non-loopback address logs an explicit warning at startup, because
anyone who can reach the port can read target names, hosts, and errors.
Network access should be restricted by the firewall or the proxy.

| Path | Response |
|---|---|
| `/` | Short plain-text index |
| `/healthz` | `200 ok` whenever the process is alive |
| `/readyz` | `200 ready` after at least one sample; `503 starting` before |
| `/metrics` | Prometheus text format |
| `/api/v1/status` | The latest snapshot as JSON |

Only `GET` and `HEAD` are allowed (`405` otherwise). Unknown paths return
`404`. The request line and headers are capped at 8 KiB: oversized requests
get `413`, malformed or incomplete ones get `400`, and a request that is not
finished within 3 seconds gets `408`. Connections are served by a fixed pool
of 8 workers with a 16-connection queue; excess connections get `503` instead
of creating threads, and every worker is joined during shutdown. Each
connection is closed after one response.

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
| `netstudio_target_last_check_timestamp_seconds` | gauge | Unix time when the latest probe sample completed (does not advance on scrapes) |
| `netstudio_target_last_sample_age_seconds` | gauge | Age of the latest sample; `-1` before the first sample |
| `netstudio_target_stale` | gauge | `1` when no fresh sample arrived within `2 × interval + timeout` |
| `netstudio_target_tcp_fallback` | gauge | `1` when the latest ICMP probe used TCP fallback |
| `netstudio_target_error_info` | gauge | `1` with a `kind` label for the latest failure; one series per failed target |
| `netstudio_target_http_status_code` | gauge | Latest HTTP code (HTTP/HTTPS only) |
| `netstudio_target_cert_days_left` | gauge | TLS certificate days left (HTTPS only) |

Example alerts:

```yaml
- alert: NetStudioTargetDown
  expr: netstudio_target_up == 0 and netstudio_target_sent_total > 0
  for: 2m

- alert: NetStudioProbeStalled
  expr: netstudio_target_stale == 1
  for: 1m

- alert: NetStudioDNSFailures
  expr: netstudio_target_error_info{kind="dns"} == 1
  for: 5m
```

`last_error` itself is deliberately not a metric label: it is unbounded
cardinality and may contain attacker-controlled text. Use
`netstudio_target_error_info{kind=...}` for alerting and read the sanitized
message from `/api/v1/status` or the snapshot file.

Note that the engine has no persistence: counters and the 40-sample RTT
window reset when the process restarts. Uptime history and the alert log
remain desktop-app features.

## What is not included

This first headless release covers the Ping Matrix engine (ICMP/TCP/HTTP/HTTPS,
statuses, RTT/jitter/loss, HTTP status, TLS expiry, failure reasons, and
staleness) and its HTTP surface.
Desktop-only features are intentionally absent:

* traceroute/MTR, bandwidth, Warp, port scan and DNS lookup;
* desktop notifications, webhooks, Telegram/Discord/ntfy alerts;
* 30-day uptime history and CSV/JSON export;
* hot reload (`SIGHUP`) and TLS/authentication on the HTTP server.

For container deployments, mount the config read-only, publish only the
loopback metrics port, and set a memory limit; history is bounded per target
and the target count is capped at 500.
