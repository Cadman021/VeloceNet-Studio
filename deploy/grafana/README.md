# Grafana dashboard

`netstudio-headless.json` is a single dashboard (uid `netstudio-headless`) for
the Prometheus metrics the daemon exposes on `/metrics`. It covers what the
desktop app's screen showed live, plus the history Prometheus keeps.

## Before you import

Prometheus has to scrape the daemon. `netstudio_build_info`, the `up`
family and the daemon gauges are all on the same endpoint:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: netstudio
    static_configs:
      - targets: ["127.0.0.1:9101"]
    # Only when the daemon was started with --http-token-file.
    authorization:
      credentials_file: /etc/netstudio/http-token
```

The daemon listens on plain HTTP and requires a bearer token when one is
configured; terminate TLS at a reverse proxy if the endpoint leaves the host.

## Import

Dashboards -> New -> Import -> Upload JSON file, then pick the Prometheus
data source. The dashboard asks for it as the `datasource` variable, so the
same file works in every environment.

In Kubernetes with the kube-prometheus-stack Grafana sidecar, label the
ConfigMap instead of clicking:

```bash
kubectl create configmap netstudio-dashboard -n monitoring \
  --from-file=netstudio-headless.json=deploy/grafana/netstudio-headless.json
kubectl label configmap netstudio-dashboard -n monitoring grafana_dashboard=1
```

For a plain Grafana container, either mount this directory at
`/var/lib/grafana/dashboards` and add a provisioning provider, or upload the
file once — the uid is fixed, so re-importing replaces the dashboard instead
of duplicating it.

## What the panels answer

| Row | Question |
| --- | --- |
| (top stats) | Is the daemon ready, how many targets are offline/degraded/stale, how long has it been up, how long does a snapshot take |
| Targets | State of every target right now, the state history, RTT (avg and max), jitter, lifetime loss, time since each target last answered |
| Daemon | Request rate by endpoint and status, config reload outcomes, TLS certificates by days left, failures by kind |

## Reading it correctly

* `netstudio_target_up` is **absent** until a target has one sample, and
  `netstudio_target_rtt_last_ms` is `-1` while a target is down. Panels use
  `netstudio_target_status`, so a target that has never been probed shows as
  `pending` instead of dropping out.
* `netstudio_target_last_success_timestamp_seconds` is `-1` before the first
  success, so the "time since the last success" panel filters on `> 0`.
* Counters (`*_total`) reset when the daemon restarts; every panel uses
  `rate()` or `increase()`, which handle a reset.
* History is Prometheus' retention, not the daemon's: the app's 30-day view
  becomes `--storage.tsdb.retention.time`, and the daemon keeps only one
  snapshot.
* Muted targets still appear (they are probed) but never alert; see
  `netstudio_target_muted`.

See `docs/headless.md` for the metric list and example alert rules.
