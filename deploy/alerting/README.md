# Alert bridge

`netstudio-alert-bridge.py` turns the daemon's `/api/v1/events` feed into
push notifications for Slack, Mattermost, ntfy or any HTTP endpoint.

The daemon itself never posts webhooks: it has no TLS client and no
certificate store, and receivers are HTTPS-only. Keeping the sender outside
the daemon is what makes TLS, retries and a restart-safe cursor possible
with the Python standard library alone.

## Run

```bash
python3 deploy/alerting/netstudio-alert-bridge.py \
  --url http://127.0.0.1:9101 \
  --token-file /etc/netstudio/http.token \
  --state-file /var/lib/netstudio/alert-bridge.json \
  --webhook https://hooks.slack.com/services/T000/B000/XXXX
```

Try it without sending anything with `--dry-run --once`; it prints the
message it would have posted and exits.

| Flag | Meaning |
|---|---|
| `--url` | Daemon base URL; only its `/api/v1/events` feed is read |
| `--webhook` | POST target, repeatable; also accepts `https://` |
| `--token-file` | Bearer token file; falls back to `NETSTUDIO_HTTP_TOKEN` |
| `--state-file` | Cursor, so a restart does not replay or skip alerts |
| `--format json\|text` | `json` = `{"text": ..., "event": {...}}` (Slack, Mattermost); `text` = bare message (ntfy) |
| `--interval` | Poll period, default 2 s |
| `--retries` | Delivery attempts per webhook, default 3, backoff 1-2-4 s |
| `--once` | One batch then exit, for cron or a smoke test |
| `--strict` | Exit 1 when the feed is down or a webhook rejects a message |

Messages look like:

```text
[netstudio] edge-gw (ICMP 1.1.1.1) DOWN: icmp timeout
[netstudio] edge-gw (ICMP 1.1.1.1) recovered after 4m12s
```

## systemd unit

The packages install the daemon as `netstudio-headless.service`; the bridge
is not packaged because it needs its own webhook secret. Drop this next to
it after copying the script and a token file:

```ini
[Unit]
Description=VeloceNet alert bridge
After=netstudio-headless.service
Wants=netstudio-headless.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/netstudio/netstudio-alert-bridge.py \
  --url http://127.0.0.1:9101 --token-file /etc/netstudio/http.token \
  --state-file /var/lib/netstudio/alert-bridge.json \
  --webhook https://hooks.slack.com/services/T000/B000/XXXX
User=netstudio
Group=netstudio
Restart=on-failure
RestartSec=10s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
StateDirectory=netstudio

[Install]
WantedBy=multi-user.target
```

`systemctl edit netstudio-alert-bridge` keeps the webhook URL out of the
unit if you prefer an override with `Environment=`; the URL itself contains
the secret for Slack and Mattermost, so treat it like a password and keep
the file `0640 root:netstudio`.

## Delivery

* The cursor advances after every event, so a restart resumes exactly where
  it stopped; a crash between delivery and the write can repeat one alert,
  which is the right side to err on.
* A target that flaps faster than the poll interval is still reported once
  per transition: the daemon's ring buffer holds the last 256 events and
  `dropped` in the response says how many were evicted before your cursor.
* After a daemon restart the stored cursor can be ahead of the new process;
  the bridge notices and replays that process's buffer from the beginning.
* A webhook that keeps failing is logged and skipped so one broken receiver
  does not block the others; `--strict` turns that into a non-zero exit.
* Only `http://` and `https://` are accepted, and HTTPS is verified against
  the system trust store: there is no `--insecure`.

Exit codes: `0` success, `1` runtime failure (`--strict`), `2` usage or
configuration (unreachable daemon, missing token file, unknown API).
