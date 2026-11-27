#!/usr/bin/env python3
"""Forward netstudio-headless state transitions to an HTTP webhook.

The daemon deliberately has no outbound TLS client or certificate store, so
it exposes alerts as a pull feed (`GET /api/v1/events?since=N`) and this
bridge turns that into push notifications. Running outside the daemon buys
three things it cannot have without new dependencies: proper TLS with the
system trust store, retries, and a cursor that survives a restart.

    netstudio-alert-bridge.py --url http://127.0.0.1:9101 \
        --token-file /etc/netstudio/http.token \
        --webhook https://hooks.slack.com/services/T000/B000/XXXX \
        --state-file /var/lib/netstudio/alert-bridge.json

Delivery is at-least-once per event: the cursor advances after the webhooks
were offered the message, so a crash mid-batch can repeat one alert. A
webhook that keeps failing is logged and skipped so one broken receiver does
not block the others forever; --strict makes any failure fatal instead.

Standard library only, so the bridge can be dropped next to the daemon
without a virtualenv.
"""

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SCHEMA = 1
STOP = False


def log(message):
    print(message, file=sys.stderr, flush=True)


def fail(message, code=1):
    log(message)
    raise SystemExit(code)


def check_url(url, name):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        fail("{} must be an http:// or https:// URL: {}".format(name, url), 2)
    return url.rstrip("/")


def read_token(path):
    if path:
        try:
            with open(path, encoding="utf-8") as handle:
                token = handle.read().strip()
        except OSError as error:
            fail("cannot read --token-file {}: {}".format(path, error), 2)
        if not token:
            fail("{} is empty".format(path), 2)
        return token
    return os.environ.get("NETSTUDIO_HTTP_TOKEN") or None


def fetch(url, token, timeout):
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def load_cursor(path, url):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("url") != url:
        return None
    since = data.get("since")
    return since if isinstance(since, int) and since >= 0 else None


def save_cursor(path, url, since):
    directory = os.path.dirname(os.path.abspath(path))
    try:
        os.makedirs(directory, exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump({"url": url, "since": since}, handle)
            handle.write("\n")
        os.replace(temporary, path)
    except OSError as error:
        # Not fatal: the bridge keeps running and may repeat alerts after a
        # restart, which beats not alerting at all.
        log("warning: cannot write cursor {}: {}".format(path, error))


def duration(milliseconds):
    seconds = max(0, int(milliseconds or 0)) // 1000
    if seconds < 60:
        return "{}s".format(seconds)
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return "{}m{:02d}s".format(minutes, seconds)
    hours, minutes = divmod(minutes, 60)
    return "{}h{:02d}m".format(hours, minutes)


def describe(event):
    name = event.get("name") or "target {}".format(event.get("target_id"))
    where = "{} {}".format(event.get("protocol") or "?", event.get("host") or "?")
    if event.get("kind") == "down":
        reason = event.get("error") or "no response"
        return "[netstudio] {} ({}) DOWN: {}".format(name, where, reason)
    return "[netstudio] {} ({}) recovered after {}".format(
        name, where, duration(event.get("outage_ms"))
    )


def deliver(webhook, payload, content_type, timeout, retries):
    delay = 1.0
    problem = "not attempted"
    for attempt in range(1, max(1, retries) + 1):
        request = urllib.request.Request(webhook, data=payload, method="POST")
        request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                response.read()
            return True
        except urllib.error.HTTPError as error:
            # A rejected payload or a bad token will not improve by retrying;
            # rate limits and server errors might.
            if 400 <= error.code < 500 and error.code not in (408, 429):
                log("{} rejected the alert with HTTP {}".format(webhook, error.code))
                return False
            problem = "HTTP {}".format(error.code)
        except (urllib.error.URLError, OSError) as error:
            problem = str(error)
        if attempt < max(1, retries):
            time.sleep(delay)
            delay = min(delay * 2, 30.0)
    log("{} failed {} times: {}".format(webhook, retries, problem))
    return False


def notify(webhooks, message, event, fmt, timeout, retries, dry_run):
    if dry_run:
        log("dry-run: " + message)
        return True
    if fmt == "json":
        payload = json.dumps({"text": message, "event": event}).encode("utf-8")
    else:
        payload = message.encode("utf-8")
    content_type = "application/json" if fmt == "json" else "text/plain; charset=utf-8"
    delivered = True
    for webhook in webhooks:
        delivered = deliver(webhook, payload, content_type, timeout, retries) and delivered
    return delivered


def poll(base, token, since, args):
    document = fetch(
        "{}/api/v1/events?since={}".format(base, since), token, args.timeout
    )
    if document.get("schema") != SCHEMA:
        log("warning: unexpected event schema {}".format(document.get("schema")))
    head = int(document.get("seq") or since)
    dropped = int(document.get("dropped") or 0)
    if dropped:
        notify(
            args.webhook,
            "[netstudio] alert bridge missed {} transition(s)".format(dropped),
            {"kind": "dropped", "dropped": dropped, "since": since},
            args.format, args.timeout, args.retries, args.dry_run,
        )
    for event in document.get("events") or []:
        message = describe(event)
        if not notify(
            args.webhook, message, event, args.format, args.timeout, args.retries, args.dry_run
        ):
            # Advance anyway unless asked to stop: one broken receiver must
            # not silence the others forever.
            if args.strict:
                return since, head, False
        since = max(since, int(event.get("seq") or since))
        save_cursor(args.state_file, base, since)
        log("sent seq {}: {}".format(event.get("seq"), message))
    return since, head, True


def main(argv):
    parser = argparse.ArgumentParser(
        description="Forward netstudio-headless alerts to webhooks",
    )
    parser.add_argument("--url", required=True, help="daemon base URL, e.g. http://127.0.0.1:9101")
    parser.add_argument("--webhook", action="append", default=[], help="POST target; repeatable")
    parser.add_argument("--token-file", help="file with the bearer token (default: NETSTUDIO_HTTP_TOKEN)")
    parser.add_argument("--state-file", default=default_state_file(), help="cursor file")
    parser.add_argument("--format", choices=("json", "text"), default="json", help="json sends {\"text\": message, \"event\": {...}} for Slack and Mattermost; text sends the message as the body for ntfy")
    parser.add_argument("--interval", type=float, default=2.0, help="seconds between polls")
    parser.add_argument("--timeout", type=float, default=5.0, help="per-request timeout in seconds")
    parser.add_argument("--retries", type=int, default=3, help="delivery attempts per webhook")
    parser.add_argument("--once", action="store_true", help="poll one batch and exit")
    parser.add_argument("--dry-run", action="store_true", help="print alerts instead of sending")
    parser.add_argument("--strict", action="store_true", help="stop when a webhook fails")
    args = parser.parse_args(argv)

    args.url = check_url(args.url, "--url")
    args.webhook = [check_url(url, "--webhook") for url in args.webhook]
    if not args.webhook and not args.dry_run:
        fail("at least one --webhook is required (or use --dry-run)", 2)
    if args.interval <= 0:
        fail("--interval must be greater than 0", 2)
    token = read_token(args.token_file)

    def stop(_signum, _frame):
        global STOP
        STOP = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    # Ask for the current head before the first poll: a fresh install must
    # not replay whatever the ring buffer still holds (nor alert on it).
    # After a daemon restart the head is below the stored cursor, which means
    # the buffered events are new to us and are replayed from the start.
    try:
        head = int(fetch(args.url + "/api/v1/events", token, args.timeout).get("seq") or 0)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            fail("{} has no /api/v1/events; this daemon predates the event feed".format(args.url), 2)
        if error.code == 401:
            fail("the daemon rejected the token; check --token-file")
        fail("cannot read the event feed: HTTP {}".format(error.code))
    except (urllib.error.URLError, OSError, ValueError) as error:
        fail("cannot reach {}: {}".format(args.url, error))

    stored = load_cursor(args.state_file, args.url)
    if stored is None:
        since = head
        log("starting at seq {} (older transitions are not replayed)".format(since))
        save_cursor(args.state_file, args.url, since)
    elif stored > head:
        since = 0
        log("daemon restarted (cursor {} > head {}); replaying its buffer".format(stored, head))
    else:
        since = stored
        log("resuming after seq {}".format(since))

    while not STOP:
        try:
            since, head, ok = poll(args.url, token, since, args)
        except urllib.error.HTTPError as error:
            if error.code == 401:
                log("the daemon rejected the token; check --token-file")
            else:
                log("event feed returned HTTP {}".format(error.code))
            ok = False
        except (urllib.error.URLError, OSError, ValueError) as error:
            log("event feed unavailable: {}".format(error))
            ok = False
        if args.strict and not ok:
            return 1
        if args.once:
            return 0
        deadline = time.monotonic() + args.interval
        while not STOP and time.monotonic() < deadline:
            time.sleep(min(0.25, args.interval))
    return 0


def default_state_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "netstudio", "alert-bridge.json")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))