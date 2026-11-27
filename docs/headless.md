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

Release archives contain a standalone
`netstudio-headless-<os>-<arch>` (plus `targets.example.json`) next to the
full app bundle, so a daemon host does not download Flutter.

### Docker

The repository includes a multi-stage `native_engine/Dockerfile`; the image
contains only the daemon and `ca-certificates` (~30 MB), and runs as the
unprivileged `netstudio` user:

```bash
docker build -f native_engine/Dockerfile -t netstudio-headless:1.6.0 .
docker run --rm -p 9101:9101 --cap-add NET_RAW \
  -v "$PWD/targets.json:/etc/netstudio/targets.json:ro" \
  netstudio-headless:1.6.0
```

`--cap-add NET_RAW` is what unprivileged ICMP needs inside a container;
without it, ICMP targets fall back to TCP or report a permission error while
TCP/HTTP/HTTPS targets keep working. Mount a token file and add
`--http-token-file` when the port is published beyond `127.0.0.1`.

The image ships a `HEALTHCHECK` that runs the binary itself — there is no curl
or wget inside — against `http://127.0.0.1:9101/readyz`:

```bash
docker run -d --name netstudio -p 9101:9101 --cap-add NET_RAW \
  -v "$PWD/targets.json:/etc/netstudio/targets.json:ro" netstudio-headless:1.6.0
docker inspect --format '{{.State.Health.Status}}' netstudio   # healthy
```

`healthy` therefore means `/readyz` answered `200` — every target has a
sample — not merely that the process is alive. If you change `CMD` to listen
on another port, override `HEALTHCHECK` too. With `--http-token-file`, pass the
token as `NETSTUDIO_HTTP_TOKEN` instead: the server and the built-in client
both read it, whereas a file path is only visible to the server.

### Kubernetes

`deploy/kubernetes/` has a `ConfigMap` (an exported targets file), a
`Deployment` and a `Service`:

```bash
docker build -f native_engine/Dockerfile -t netstudio-headless:1.6.0 .
kubectl apply -f deploy/kubernetes/
kubectl port-forward svc/netstudio-headless 9101:9101
```

The pod runs as uid `10001` with `readOnlyRootFilesystem`, keeps its snapshot
in an `emptyDir`, and gets `NET_RAW` only because ICMP may need it. `liveness`
probes `/healthz` (a network outage must not restart the pod) while
`readiness` probes `/readyz` (a pod that cannot reach its targets stays out of
the Service). `--watch-config 60` picks up a re-applied `ConfigMap` without a
restart; kubelet never sends `SIGHUP`.

If you enable `--http-token-file`, kubelet cannot send the token: switch the
readiness probe to an `exec` one that runs `--health-check` with
`NETSTUDIO_HTTP_TOKEN` from a `Secret` — `deploy/kubernetes/README.md` shows
the exact YAML.

### Linux packages (deb and rpm)

`deploy/linux/build-package.sh` turns the release binary into a `.deb` or an
`.rpm`; both install the daemon as a systemd service under an unprivileged
`netstudio` account:

```bash
sudo dpkg -i netstudio-headless_1.6.0_amd64.deb     # Debian, Ubuntu
sudo rpm -i netstudio-headless-1.6.0-1.x86_64.rpm   # Fedora, RHEL, openSUSE
systemctl status netstudio-headless
journalctl -u netstudio-headless -f
systemctl reload netstudio-headless                 # SIGHUP: re-read targets
```

The unit runs `--config /etc/netstudio/targets.json --listen 127.0.0.1:9101
--output /var/lib/netstudio/status.json --watch-config 60`, adds
`$NETSTUDIO_ARGS` from `/etc/default/netstudio-headless` (so extra flags
survive upgrades), and is hardened with `ProtectSystem=strict`, `ProtectHome`,
`PrivateTmp`, `NoNewPrivileges`, `MemoryDenyWriteExecute` and
`SystemCallFilter=@system-service`. `CAP_NET_RAW` is the only ambient
capability, for ICMP; remove it when no target needs a raw socket.

`/etc/netstudio/targets.json` is a conffile: upgrades never overwrite it, and
edit it together with `systemctl reload`. Publishing beyond loopback belongs
in `/etc/default/netstudio-headless` — set `--listen` and a token file readable
by `netstudio` there — not in the unit, which the package replaces. Purge with
`apt purge netstudio-headless` or `rpm -e netstudio-headless`; both remove the
account and `/var/lib/netstudio`.

Package locally with `bash deploy/linux/build-package.sh --format deb --outdir
dist` on Linux with `dpkg-deb`/`rpmbuild` installed, or `--check` to validate
the assets without building. Build on the oldest distribution you support: the
release job uses `debian:bullseye` (glibc 2.31) so one build runs on Debian
11-13, Ubuntu 20.04+ and RHEL 9+. Each release also carries a CycloneDX SBOM
from `tool/headless-sbom.py`, listing the crates linked into the binary with
their `Cargo.lock` checksums.

### Man page and shell completions

`docs/netstudio-headless.1` documents every flag and exit code;
`docs/completions/netstudio-headless.bash` and
`docs/completions/netstudio-headless.zsh` complete flags, choice values and
file paths. Install them wherever the platform expects:

```bash
sudo install -m 644 docs/netstudio-headless.1 /usr/local/share/man/man1/
sudo install -m 644 docs/completions/netstudio-headless.bash \
  /usr/share/bash-completion/completions/netstudio-headless
sudo install -m 644 docs/completions/netstudio-headless.zsh \
  /usr/local/share/zsh/site-functions/_netstudio-headless
```

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
* Every target is probed once immediately at startup, so `/readyz` does not
  wait a full interval. It still returns `503` until **every** target has a
  sample: one slow DNS lookup in a 500-target file delays readiness rather
  than reporting a false `ready`.
* `--interval` controls how often a snapshot is printed or written;
  `--probe-interval` controls how often each target is probed. Without the
  override, every target keeps its own `interval_ms` from the file, and
  staleness is derived from that effective interval.
* `--once` exits with `3` when at least one target is down. That is a valid
  test result, not a crash; the snapshot is still printed. Muted targets are
  still probed and reported, but they do not make `--once` fail. Add
  `--format json` if you need machine-readable output in a terminal.
* Press `Ctrl+C` to stop the daemon gracefully.
* `docs/examples/targets.json` uses `1.1.1.1` over ICMP and TCP/53, so it
  exercises two probe types without DNS. Edit it or export your own targets
  from the desktop app.

### Run as a Windows service

A daemon started from a shell dies with the console. `tool/install-headless-service.ps1`
registers it with the Service Control Manager instead:

```powershell
# Elevated PowerShell, once.
pwsh -File tool\install-headless-service.ps1 `
  -ExePath C:\ProgramData\netstudio\netstudio-headless.exe `
  -ConfigPath C:\ProgramData\netstudio\targets.json `
  -LogPath C:\ProgramData\netstudio\headless.log `
  -Listen 127.0.0.1:9101 `
  -WatchConfig 60
```

The script validates the config with `--check` first, registers the service as
`netstudio-headless` with the command line it prints, sets a restart policy
(three restarts five seconds apart, then stop), and starts it. `-TokenFile`,
`-RestartDelaySeconds` and `-DoNotStart` adjust that. Later operations go
through the same script: `-Action status`, `start`, `stop`, `restart` or
`uninstall`.

* `--windows-service` makes the process call `StartServiceCtrlDispatcherW` and
  report `SERVICE_RUNNING` only after the config is validated, the listener is
  bound and the pid file is claimed, so `sc.exe start` actually waits for a
  working daemon. Started from a shell it exits `2` with a message explaining
  that SCM must launch it — it never probes invisibly.
* A service has **no console**, so pass `-LogPath`: `--log-file` mirrors every
  line there (rotated to `headless.log.1` at 8 MiB). Without it the diagnostics
  are lost.
* There is no `SIGHUP` on Windows, so `-WatchConfig <SECS>` is how a service
  picks up a re-exported config file. Without it, a config change needs a
  restart.
* Stop is graceful: SCM sends `SERVICE_CONTROL_STOP`, which sets the same flag
  as `Ctrl+C`, so in-flight probes are cancelled and the pid file is removed.
* `sc.exe queryex netstudio-headless` shows the exit code of the last run
  (`1066` plus a service-specific code: `2` invalid config, `3` targets down).

Registering a service needs administrator rights, so the registration itself
is not exercised by the automated tests; the console refusal, the argument
plumbing and the script logic are.

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

`protocol` accepts `ICMP` / `TCP` / `HTTP` / `HTTPS` (or `0`–`3`); anything
else — including a typo such as `"HTTTP"` — skips that target with a warning
instead of silently probing ICMP. Missing fields use the same defaults as the
app: ICMP, port 80, 1000 ms interval,
1500 ms timeout. Values are clamped instead of rejected: interval
200–60000 ms, timeout 100–10000 ms, thresholds 1–20. Up to 500 targets are
loaded.

`app`, `version`, and `settings` are optional. `settings.offline_after` and
`settings.recover_after` are the same alert thresholds as the app's Settings
page; the app writes them when it exports a backup, so the exported file
behaves identically under the daemon. Targets with `"is_enabled": false` are
skipped. Invalid hosts (spaces, bad labels, octets above 255, malformed
IPv6) are skipped with a warning; one bad target never prevents the rest from
running. Structural JSON errors and a file with zero usable targets are
fatal (`exit 2`).

Keys the loader does not read are reported (`config: unknown key "porrt" is
ignored`), and two targets that probe the same `protocol host:port` are
flagged as duplicates: both still probe, but their rows are indistinguishable
on a dashboard. [`netstudio-headless.schema.json`](netstudio-headless.schema.json)
is the authoritative key list with types and ranges; add
`"$schema": "./docs/netstudio-headless.schema.json"` to a hand-written file
to get completion and inline errors in VS Code.

Duplicate or missing `id` values are assigned fresh ids so Prometheus labels
and snapshots stay stable within a run. `group` (capped at 40 characters) and
`"is_muted": true` are carried through to the text table, the snapshot JSON,
and Prometheus labels.

### Validate before deploying

`--check` answers "would this start right now?" without probing or listening:
it parses the file, checks that the `--output`, `--pid-file` and `--log-file`
directories exist and are writable (and that a `--pid-file` is not held by a
live process), and binds `--listen` once. Any failure exits `2`, so a CI job
or a systemd `ExecStartPre` catches a bad mount or a taken port before the
service goes into a restart loop.

```text
$ netstudio-headless -c docs/examples/targets.json --check --output /tmp/status.json
config OK: 2 target(s) in docs/examples/targets.json
  config   2 usable target(s), 0 muted
  output   /tmp/status.json is writable
```

A terminal gets the text form above; when stdout is piped or redirected the
report is JSON (`"type": "check"`, one entry per channel under `checks`), so
`netstudio-headless -c targets.json --check | jq` works without extra flags and
matches how `--once` and the daemon choose their format. `--format text` forces
the table on a pipe, `--format json` forces JSON on a terminal. A failing
channel is also logged to stderr with exit `2`.

## Usage

```bash
netstudio-headless --config targets.json --check
netstudio-headless --config targets.json --once
netstudio-headless --config targets.json --interval 15 --probe-concurrency 32 --listen 127.0.0.1:9101 --output /var/lib/netstudio/status.json
```

| Flag | Meaning |
|---|---|
| `-c`, `--config <PATH>` | Target file (required for run/check/once) |
| `--check` | Validate the file, output/pid paths, and listen address, then exit |
| `--health-check <URL>` | GET an `http://` URL and exit `0` only on `200`; for container health checks |
| `--once` | Probe every target once, print a snapshot, exit |
| `--interval <SECS>` | Snapshot interval, 1–3600 (default 5) |
| `--probe-interval <SECS>` | Probe every target this often, overriding each `interval_ms` (1–3600) |
| `--probe-concurrency <N>` | Maximum probes in flight, 1–256 (default 32) |
| `--watch-config <SECS>` | Reload the config file when it changes, checked every 1–3600 s; daemon only |
| `--listen <IP:PORT>` | Enable HTTP (disabled by default); daemon only |
| `--windows-service` | Let the Service Control Manager own the process; daemon only, Windows |
| `--output <PATH>` | Atomically replace this file with the latest snapshot |
| `--pid-file <PATH>` | Write the process id while running; daemon only |
| `--http-token-file <PATH>` | Require a bearer token on every endpoint but `/healthz`; daemon only |
| `-q`, `--quiet` | Do not stream snapshots to stdout |
| `--format <MODE>` | `auto` (default: text on a terminal, JSON when piped), `json`, `text` |
| `--color <WHEN>` | `auto` (default), `always`, `never`; `--no-color` is an alias for `never` |
| `--log-level <LEVEL>` | `error`, `warn`, `info` (default), `debug` |
| `--log-format <FMT>` | `text` (default) or `json` (one JSON object per line) |
| `--log-file <PATH>` | Append every line to `PATH` too, rotated to `PATH.1` at 8 MiB |
| `-h`, `--help` | Usage |
| `-V`, `--version` | Version |

On a terminal, `--once` prints a human-readable table; when stdout is piped
or redirected it prints pretty JSON so scripts keep working. Use
`--format json` or `--format text` to force either form. `--quiet` does not
suppress the `--once` result. It returns:

* `0` — every probed target answered;
* `3` — at least one non-muted target is down;
* `2` — configuration/CLI error, including an unusable `--output` or
  `--pid-file` path, a held pid file, or a `--listen` address that cannot be
  bound. Paths are checked before the first probe, so `--once` prints
  nothing on this path;
* `1` — runtime failure after startup (for example the output directory is
  removed while the daemon is running, or the HTTP server fails).

`--health-check <URL>` is the one mode that needs no `--config`: it sends a
single `GET` and exits `0` on `200`, `1` on any other status or transport
failure, and `2` for a URL it cannot parse (including `https://`, which would
need a proxy). `--http-token-file` (or `NETSTUDIO_HTTP_TOKEN`) supplies the
bearer token, so it also works against a daemon with authentication enabled;
it cannot be combined with `--once`, `--check`, `--listen`, `--output`,
`--pid-file`, `--watch-config` or `--windows-service`.

`--listen`, `--pid-file` and `--http-token-file` are daemon options; combining
them with `--once` is rejected with exit `2` instead of being silently ignored.

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
    "offline": 1, "down": 1, "stale": 0, "muted": 0
  },
  "targets": [ /* TargetStats, identical to the app/FFI JSON */ ]
}
```

`summary.down` counts targets whose most recent probe failed; `summary.muted`
counts muted targets among them. A target that has not been probed yet is
`pending`, not down. `summary.stale` counts
targets whose latest sample is older than `2 × interval + timeout`; a stalled
probe therefore stops looking fresh even though the daemon is still running.

Each target also carries the reason for its last failure:

| Field | Meaning |
|---|---|
| `last_error` | Short, single-line, sanitized reason (max 160 chars), cleared on success |
| `last_error_kind` | `dns`, `timeout`, `refused`, `unreachable`, `icmp_unavailable`, `tls`, `http`, or `other` |
| `tcp_fallback` | `true` when ICMP was unavailable and the probe used TCP |
| `last_sample_age_ms` | Age of the latest sample; `null` before the first one |
| `last_success_epoch_ms` | Unix ms of the last successful probe; `0` until the target answers |
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
* On Unix, `SIGHUP` re-reads the config file without a restart: removed
  targets stop, new ones start, edited ones restart with fresh counters, and
  unchanged targets keep their history. Alert thresholds (`settings`) apply
  immediately, and `/readyz` expects the new target count. A file that does not
  parse is logged as an error and the running configuration stays in place, so
  a bad edit never takes the daemon down.
* Windows delivers no `SIGHUP`, and neither do most containers, so pass
  `--watch-config <SECS>` there: the daemon compares the file's modification
  time and size every 1–3600 seconds and runs the same reload, logging
  `<path> changed; reloading`. A file that stays broken is attempted once,
  not once per poll; the next edit retries. `--watch-config` works on Unix
  too and does nothing while the file is unchanged.
* On Unix the same `SIGHUP` also re-reads `--http-token-file`, so a secret can
  be rotated without a restart: the new token applies to the next connection
  and the old one is refused at once. A file that is missing, empty or invalid
  keeps the previous token in force and is logged as a warning, so a broken
  mount can never leave the endpoint unauthenticated.
* `--log-file` appends the same lines to a file, which is what a Windows
  service or a container with no console to attach to needs. The file never
  contains ANSI colour, even when stderr is a terminal, and it is opened in
  append mode: a restart adds to it instead of starting over. Past 8 MiB the
  current file becomes `PATH.1` (one generation) and logging continues in a
  fresh `PATH`; a write failure is reported once and the daemon keeps running
  instead of dying over a log path.
* Logs go to stderr as `TIMESTAMP LEVEL message`; stdout is reserved for
  snapshots. With `--log-format json` each line is
  `{"time":"…","level":"warn","msg":"…"}` and never contains ANSI colour, so
  `systemd`/`docker`/`jq` consume it without a parser. Messages with newlines
  and quotes are escaped inside `msg`, so one record is always one line.
* `--output` writes a temporary file in the same directory and renames it
  over the target, so readers never see a half-written JSON document. The
  directory must already exist; the daemon validates it at startup and exits
  `2` otherwise, instead of logging a failure on every tick. A failure that
  appears later (disk unmounted, permissions changed) is logged once, and a
  successful write afterwards logs that the file is writable again.
* `--pid-file` is claimed with an exclusive create. A file left behind by a
  killed process is taken over when its pid is no longer alive; a file held
  by a live process aborts startup with exit `2`. The file is removed on a
  graceful stop, and only if it still contains this process's pid.

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

HTTP is off unless `--listen` is passed. Bind to loopback and put a TLS
reverse proxy in front of it if the metrics must be reachable from another
host: the built-in server has no TLS. It does support a static bearer token:
pass `--http-token-file /etc/netstudio/http.token` (a file containing the
token, so it never appears in the process list or shell history) or set
`NETSTUDIO_HTTP_TOKEN`. The file wins when both are present. Every endpoint
except `/healthz` then requires `Authorization: Bearer <token>` and answers
`401` with `WWW-Authenticate: Bearer` otherwise; `/healthz` stays open because
container and systemd probes usually cannot send headers. The comparison is
constant-time, tokens are capped at 256 characters, and `--check` fails if the
file is missing or empty. On Unix, `SIGHUP` re-reads the file, so the secret can
be rotated without a restart; an unreadable or empty file keeps the previous
token and only logs a warning.
Binding to a non-loopback address logs an explicit warning at startup, because
anyone who can reach the port can read target names, hosts, and errors.
Network access should be restricted by the firewall or the proxy.

| Path | Response |
|---|---|
| `/` | Short plain-text index |
| `/healthz` | `200 ok` whenever the process is alive |
| `/readyz` | `200 ready` once every target has at least one sample; `503 starting` before |
| `/metrics` | Prometheus text format |
| `/api/v1/status` | The latest snapshot as JSON |

Only `GET` and `HEAD` are allowed (`405` otherwise). Unknown paths return
`404`. The request line and headers are capped at 8 KiB: oversized requests
get `413`, malformed or incomplete ones get `400`, and a request that is not
finished within 3 seconds gets `408`. Connections are served by a fixed pool
of 8 workers with a 16-connection queue; excess connections get `503` instead
of creating threads, and every worker is joined during shutdown. Each
connection is closed after one response, every response is
`Cache-Control: no-store`, and `/readyz` answers `503` with `Retry-After: 1`
while the first sample is still missing. Bodies embed the current time, sample
age and uptime, so `If-None-Match`/`If-Modified-Since` would never match; poll
at the snapshot cadence instead. The server does not compress: put a
gzip-capable proxy in front if `/metrics` payloads matter at scale.

### Prometheus metrics

All target metrics carry the labels
`id`, `name`, `host`, `port`, `protocol`, `group` (`""` when unset).

| Metric | Type | Meaning |
|---|---|---|
| `netstudio_build_info` | gauge | Always `1`, labelled with `version` |
| `netstudio_uptime_seconds` | gauge | Seconds since the daemon started |
| `netstudio_ready` | gauge | `1` when `/readyz` would answer `200` |
| `netstudio_targets_configured` | gauge | Targets in the running configuration (changes after `SIGHUP`) |
| `netstudio_stale_targets` | gauge | Targets whose latest sample is older than `2 × interval + timeout` |
| `netstudio_last_snapshot_duration_seconds` | gauge | Wall time spent producing the last snapshot; absent before the first tick |
| `netstudio_config_reloads_total` | counter | `SIGHUP` reload attempts, labelled `result="ok"\|"error"` |
| `netstudio_http_requests_total` | counter | Served HTTP requests, labelled `path` and `status` |
| `netstudio_target_info` | gauge | Always `1`; the target exists |
| `netstudio_target_up` | gauge | `1` if the latest probe answered; absent until the first sample |
| `netstudio_target_status` | gauge | `0` pending, `1` online, `2` degraded, `3` offline |
| `netstudio_target_muted` | gauge | `1` when the target is muted (still probed, excluded from `--once` failure) |
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
| `netstudio_target_last_success_timestamp_seconds` | gauge | Unix time of the last successful probe; `-1` if the target never answered |
| `netstudio_target_stale` | gauge | `1` when no fresh sample arrived within `2 × interval + timeout` |
| `netstudio_target_tcp_fallback` | gauge | `1` when the latest ICMP probe used TCP fallback |
| `netstudio_target_error_info` | gauge | `1` with a `kind` label for the latest failure; one series per failed target |
| `netstudio_target_http_status_code` | gauge | Latest HTTP code (HTTP/HTTPS only) |
| `netstudio_target_cert_days_left` | gauge | TLS certificate days left (HTTPS only) |

Example alerts:

```yaml
- alert: NetStudioTargetDown
  expr: netstudio_target_up == 0 and netstudio_target_muted == 0
  for: 2m

- alert: NetStudioProbeStalled
  expr: netstudio_target_stale == 1
  for: 1m

- alert: NetStudioSnapshotFrozen
  expr: changes(netstudio_last_snapshot_duration_seconds[5m]) == 0 and netstudio_uptime_seconds > 300
  for: 2m

- alert: NetStudioReloadFailing
  expr: increase(netstudio_config_reloads_total{result="error"}[15m]) > 0

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
