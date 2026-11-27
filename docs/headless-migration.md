# Migrating from the desktop app to headless mode

`netstudio-headless` is the same Rust engine as the desktop app, so this is
not a re-implementation to validate: it is the same probes, thresholds and
JSON. What changes is everything around the engine — the UI that showed the
results, the tray that raised alerts, and the history the app kept in memory.

This page is the checklist for moving a working desktop setup to a server,
and the honest list of what you give up.

## What carries over unchanged

* **The target file.** The daemon reads the same JSON the app writes —
  including the full backup envelope (`app`, `version`, `settings`),
  `is_enabled`, `is_muted` and `group`.
* **The alert thresholds.** `settings.offline_after` and
  `settings.recover_after` are the app's Settings values, carried in the
  export, so a target flips Offline after the same number of misses.
* **The measurements.** ICMP/TCP/HTTP/HTTPS, RTT min/avg/max, RFC 3550
  jitter, lifetime loss, HTTP status, TLS days left, failure kind, TCP
  fallback and staleness are the engine's own numbers, not a port.
* **The snapshot shape.** `--once`, `--output` and `/api/v1/status` emit the
  same `TargetStats` JSON the app's FFI returns, so any script that read the
  app's export reads this too.

## What you have to replace

| Desktop app | Headless equivalent |
| --- | --- |
| Live target table | `--once` for a one-off, `--output`/`/api/v1/status` for the latest snapshot, Grafana for a screen |
| Tray notifications | Event feed `/api/v1/events` plus `deploy/alerting/netstudio-alert-bridge.py`, or Prometheus alerts to Alertmanager |
| 30-day uptime history | Prometheus retention and the dashboard in `deploy/grafana/` |
| Settings page | The `settings` block of the config file |
| Start at login / tray icon | systemd unit, Windows service (`--windows-service`), container or Kubernetes restart policy |
| Traceroute/MTR, bandwidth, Warp, port scan, DNS lookup | No headless equivalent in this release |

The daemon pushes nothing by itself. If alerts matter, pick a delivery path
in step 5 before you turn the app off.

## 1. Take the app's own export

Export the target list from the app (or copy the file the app already uses)
and validate it where the daemon will run:

```bash
netstudio-headless -c targets.json --check
```

`--check` parses the file, checks the `--output`, `--pid-file` and
`--log-file` directories, and binds `--listen` once. Exit `2` means the
daemon would refuse to start — fix that here rather than in a restart loop.
Warnings name the offending field (`config: unknown key "porrt" is
ignored`, `skipped target 3: invalid host`); one bad target never blocks the
rest.

## 2. Compare one pass with the app

Run the app next to it for a few minutes and diff the two views:

```bash
netstudio-headless -c targets.json --once --format json \
  | jq -r '.targets[] | "\(.status)\t\(.name)\t\(.last_rtt_ms) ms\t\(.loss_rate)%"'
```

Expect the first pass to report `Pending` (no sample yet), then
`Degraded`, and `Offline` only after `offline_after` misses: statuses are
edge-triggered exactly as in the app, so compare after a few intervals, not
on the first one. The JSON carries the enum names (`Pending`, `Online`,
`Degraded`, `Offline`); the Prometheus gauge carries `0`-`3`. `--once` exits
`3` when a non-muted target is down, which makes it usable as a cron check.

Muted targets are still probed and still counted, but never alert in either
UI.

## 3. Pick how it runs

| Shape | Use it when | Start with |
| --- | --- | --- |
| systemd (deb/rpm) | A Linux host you own | `docs/headless.md` -> Linux packages; `systemctl enable --now netstudio-headless` |
| Container | You already run containers | `docs/headless.md` -> Docker; add `--cap-add NET_RAW` for ICMP |
| Kubernetes | You have a cluster and Prometheus | `deploy/kubernetes/` |
| Windows service | The probes must run on Windows | `--windows-service` and `sc.exe create`, see *Run as a Windows service* |
| Cron / CI | You only want a periodic verdict | `--once` on a schedule, no daemon at all |

The first three install the man page, the completions and the same config
format; nothing else changes between them.

## 4. Expose the HTTP surface

The daemon serves nothing until you ask it to:

```bash
netstudio-headless -c /etc/netstudio/targets.json \
  --listen 127.0.0.1:9101 \
  --http-token-file /etc/netstudio/http-token \
  --output /var/lib/netstudio/status.json
```

`/healthz` stays open for probes; everything else needs the bearer token.
There is **no TLS in the daemon** — keep `--listen` on loopback and put a
proxy in front when Prometheus or Grafana live on another host:

```nginx
server {
  listen 443 ssl;
  server_name probes.example.com;
  # ssl_certificate / ssl_certificate_key ...
  location / {
    proxy_pass http://127.0.0.1:9101;
    proxy_set_header Authorization $http_authorization;
  }
}
```

Caddy is the same idea in one line (`reverse_proxy 127.0.0.1:9101`) with
automatic certificates; it forwards `Authorization` by default. The token
type is plain `Bearer`, so Prometheus' `authorization.credentials_file` and
`curl -H "Authorization: Bearer $(cat token)"` both work.

## 5. Replace the notifications

Two ways, both fed by the daemon rather than by a UI:

* **Event feed + webhook bridge.** `/api/v1/events?since=<seq>` returns the
  Down/Up transitions after a cursor; `deploy/alerting/netstudio-alert-bridge.py`
  keeps the cursor in a state file and POSTs to Slack/Discord/Teams/generic
  webhooks. It retries, resumes after a restart and survives a daemon
  restart (`seq` starts over, and the bridge notices).
* **Prometheus + Alertmanager.** Scrape `/metrics` and alert on
  `netstudio_target_up == 0`; `docs/headless.md` has the rules. This is the
  path to take if you already page from Alertmanager, and it keeps firing
  while the daemon is unreachable (`absent()`), which the event feed cannot
  do by itself.

Desktop toasts, the app's chat senders and its CSV/JSON history export have
no direct equivalent — the feed, the bridge and Prometheus are the
replacements.

## 6. Keep the history

The app kept a 30-day in-memory history; the daemon keeps one snapshot and a
256-event ring buffer. History is now Prometheus' job:

```yaml
scrape_configs:
  - job_name: netstudio
    static_configs:
      - targets: ["127.0.0.1:9101"]
    authorization:
      credentials_file: /etc/netstudio/http-token
```

Then import `deploy/grafana/netstudio-headless.json` (see
`deploy/grafana/README.md`). Retention is
`--storage.tsdb.retention.time`; 30 days is a common match for the app's
window and costs far more disk than the daemon ever did.

If you do not run Prometheus, you lose charts and history: `--output` is
only the latest snapshot. Decide that before decommissioning the app.

## 7. Run both, then switch

Keep the app running for a day or two and compare its table with
`/api/v1/status` or Grafana. Two probers mean double ICMP/HTTP traffic and
two sets of numbers — harmless, but agree on which one you trust before you
decide a target is flapping.

During the overlap, `--once` from a different machine is the tie-breaker:
if the app and the daemon disagree, a third probe tells you which side of
the network the problem is on.

## 8. Rollback

There is nothing to convert back: the daemon never writes the config file,
so the app opens the same targets it always did.

```bash
sudo systemctl disable --now netstudio-headless   # or: docker stop netstudio
rm -f /run/netstudio/headless.pid                 # only after a hard kill
```

Keep the desktop install until Prometheus retention covers the window you
care about, then remove it.

## Things that surprise people

* **`netstudio_target_up` is absent, not 0, before the first sample.** An
  alert on `up == 0` therefore cannot fire on a fresh daemon or on a target
  whose interval is longer than the scrape.
* **Sentinels are `-1`.** `netstudio_target_rtt_last_ms` is `-1` while a
  target is down, and `netstudio_target_last_success_timestamp_seconds` is
  `-1` until the first success. Filter before subtracting from `time()`.
* **Counters and the event cursor reset on restart.** `rate()`/`increase()`
  handle the counters; the bridge detects `stored > head` and starts over.
* **`--listen` is the only network surface**, and it is plain HTTP with an
  optional bearer token — no user accounts, no TLS.
* **Two daemons on the same targets produce identical series.** Deduplicate
  in Prometheus or give them different `group` labels before you run one per
  environment.
* **ICMP is still unprivileged**, but a hardening systemd unit or a
  container needs `CAP_NET_RAW` (the packaged unit sets
  `AmbientCapabilities=CAP_NET_RAW`; `--cap-add NET_RAW` for Docker).

## See also

* [headless.md](headless.md) — every flag, endpoint, exit code and metric;
* [netstudio-headless.1](netstudio-headless.1) — the man page;
* [../deploy/alerting/README.md](../deploy/alerting/README.md) — the webhook bridge;
* [../deploy/grafana/README.md](../deploy/grafana/README.md) — the dashboard.
