# Changelog

All notable changes to VeloceNet-Studio are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Nothing yet — see `main` for work toward the next release.

## [1.5.0] — 2026-10-18

### Added
- Genuine WireGuard handshake construction (boringtun): the Warp UDP path builds real 148-byte Noise_IK initiations; only validated 92-byte responses count. Loopback-tested deterministically, plus live `#[ignore]` checks. Status: UNVALIDATED against real servers — live probes stay silent, which is ambiguous (unregistered identity vs. wrong peer key vs. reserved-bits policy). UDP verdicts therefore still come via TCP fallback; a known-good profile validation plus identity import (user-supplied `.conf`/wgcf profile) are the follow-ups. New `boringtun` + `rand_core` engine dependencies.
- DNS health: hand-rolled RFC 3492 punycode (IDN domains encode correctly, verified against Python's idna oracle), trailing-dot FQDN tolerance, `Random.secure()` txids, and EDNS(0) OPT (4096-byte buffers, fewer truncations). Host validator accepts trailing dots too.
- Native TCP probes resolve once per target (cached ~5 min) and try all resolved addresses in order instead of only the first (broken-IPv6-first no longer condemns dual-stack targets).
- Configurable alert thresholds (offline after N consecutive failures, recovery after M consecutive successes, 1–20) in Settings, applied live to the native engine and the Dart fallback; recovery hysteresis shows a recovering target as Degraded instead of flapping Online.
- Per-target alert mute (maintenance primitive): muted targets keep probing with live metrics but emit no alert events or webhooks; toggle in the card menu with a bell-off indicator.
- Honest Warp rows: TCP-indicated endpoints render amber with a `TCP` badge, tooltip and footnote — never identical to confirmed UDP replies (the probe is heuristic, not a real WireGuard handshake).
- Uptime history recovers orphaned `.tmp` day files on init and splits outage spans across data gaps (closed-app hours no longer merge into mega-outages).
- CI now runs `cargo fmt --check`, Flutter tests on Ubuntu, and tests inside every release job; release artifacts ship with SHA256 checksums; Dependabot covers pub/Cargo/Actions.
- Single-version policy (`tool/check_versions.ps1`, enforced in CI): pubspec, `AppInfo` and the engine crate all carry the app version.
- Warp polling is incremental (counters + only new results per tick instead of re-serializing up to 4096 rows).
- Host validation lives in `core/validation/` (moved out of the traceroute controller) with Discord webhook domain checks.
- Target persistence: user-added/removed/imported servers now survive restarts (auto-saved JSON in prefs, validated on load with preset fallback). Also fixed a latent crash — presets load as an unmodifiable list, so Add/Remove threw on it.
- Target groups and tags: each target carries an optional group and up to 8 tags (edit dialog reuses the add flow); cards render a group badge plus tag chips, and the Ping Matrix header gains a group dropdown and tap-to-filter tag chips whose facets come from live targets. Search matches group/tag text; sanitized on every import path (list, comma string, legacy singular `tag`).
- Unprivileged ICMP on Linux/macOS: ping matrix and native traceroute probe through kernel "ping" sockets (`SOCK_DGRAM`, `IPPROTO_ICMP` — no root/CAP_NET_RAW; TTL-expired replies arrive via the Linux error queue `IP_RECVERR`/`MSG_ERRQUEUE` or macOS datagrams). `ProbeResult` now separates "ICMP unavailable" from a genuine failure, so the TCP fallback fires only where the OS refuses ping sockets instead of masking every miss; traceroute prefers the native engine on all platforms and drops to the system binary only when ICMP is refused at runtime.
- HTTP/HTTPS probes in the Ping Matrix: a new `ProbeProtocol::Http`/`Https` pair (protocol ids 2/3) sends a real `GET <path> HTTP/1.1` and reports TTFB as the latency (connect + TLS handshake + server think-time), the HTTP status code and, for TLS, days until the certificate expires. Success is status < 400; 4xx/5xx still display their code in red. TLS uses rustls with a capturing verifier that accepts any certificate (expired/self-signed endpoints keep being measured) and extracts `notAfter` via a small DER walker; the cert-days value is sticky between samples while the status is per-sample. New "HTTP path" field in the target dialog (defaults to `/`), protocol-aware port defaults, and HTTP/TLS badges on cards (TLS turns amber ≤14 days and red ≤3). The Dart fallback prober mirrors the same behavior via `Socket`/`SecureSocket`.
- Windows IPv6 ICMP: `Icmp6SendEcho2` is used when a target resolves to AAAA only (previously reported "No IPv4 address resolved"); bare IPv6 literals are bracketed during resolution. ICMPv6 handle failures degrade like unprivileged-ICMP refusals, so a port-carrying target still falls back to TCP.
- Traceroute resolves PTR names in the Dart layer (bounded concurrency, 2s timeout, per-IP cache, overlaid on every poll) and shows them under each hop's address; a router's Destination Unreachable now terminates the trace instead of wasting probes up to `max_hops`.
- Port scanner uses a worker pool instead of batch barriers, tries every resolved address per port (dual-stack), and sorts results before completion so runs are deterministic.

### Changed
- The four largest screens (Warp, DNS Lookup, Port Scanner, Settings) are split into focused widget files: headers, config cards, results tables and reusable fields now live in `widgets/` subfolders, and each screen owns only its mutable state (89–153 lines each, down from 600).
- Engine handles crossing the FFI boundary are opaque numeric ids (process-wide table) instead of raw `*mut Engine` pointers: a stale/double free from Dart is now a no-op, never use-after-free. Dart keeps `int` handles (0 = invalid).
- Uptime history is append-only JSONL per day (`YYYY-MM-DD.jsonl`, one line per finalized minute) instead of rewriting the whole day map on every rollover; legacy `.json` map files are still read. Day files and the 24h dialog now follow LOCAL midnight instead of UTC.

### Fixed
- DPAPI failures are surfaced: a new `secretsUnprotected` warning in Settings when a secret lands as plaintext; stale `flutter_secure_storage` references removed; DPAPI FFI uses correct 32-bit `Int32` returns.
- Settings secret fields save debounced (600ms batch) instead of three DPAPI+prefs writes per keystroke; the test-send path flushes pending edits first.
- Bandwidth totals no longer 2–3× from virtual/filter adapters: only hardware interfaces (NDIS flag) count toward totals (all adapters still listed); `stop()` joins within ~100ms instead of blocking up to 5s on the UI thread.
- Process list counts ESTABLISHED TCP connections only (idle LISTEN/TIME_WAIT sockets no longer outrank real traffic) and resolves exe names as UTF-16 (non-ASCII names were mangled via ANSI).
- Removed the unused direct `rand` engine dependency (supply chain); `socket2` is now Unix-only, scoped to unprivileged ICMP sockets.
- Traceroute/warp session managers cap concurrent sessions (8/4) with prune-then-refuse, so forgotten `free()` calls can no longer leak threads unboundedly.
- Rust tests use local `TcpListener` fixtures with real asserts instead of a live 8.8.8.8 probe with none.
- Engine teardown no longer blocks the UI thread: `Engine::drop` uses `shutdown_background()` instead of joining in-flight blocking probes (up to ~10s DNS/ICMP waits).
- Metrics stream filters snapshots to live target ids (a target removed mid-decode can no longer resurrect) and clears instead of keeping a stale frame when all targets are gone.
- Dart fallback honors per-target `intervalMs` and judges degraded status on windowed (not lifetime) loss, matching the native engine.
- Uptime history records counter deltas between frames (not one sample per UI tick): slow targets are no longer over-counted, fast ones no longer drop samples, and pre-probe pending frames no longer count as losses.
- Webhook cooldown is per (target, event kind), so a recovery is never swallowed by a recent down-alert; failed sends queue in a persistent-retry outbox (1–15 min backoff, 24 h cap) with a "delayed, connectivity was down" annotation.

## [1.4.0] — 2026-10-10

### Added
- Update checker: daily-throttled GitHub Releases poll shortly after startup plus a manual check in Settings → About, with a download action when a newer tag exists. Honors the configured webhook proxy, skips pre-release tags, and can be opted out entirely (manual checks always run). Silent on failure; no new dependencies.
- Update prompt dialog on startup: version comparison, release-notes preview and Download/Later actions, shown at most once per released version.
- System tray mode (tray_manager + window_manager): tray icon with Show/Hide/Quit menu, close-to-tray while monitoring continues, toggleable in Settings. Best-effort everywhere: no tray support (or widget tests) never breaks the app.
- Alert message templates: user-editable format with {icon} {name} {from} {to} {detail} placeholders (status words stay English enum names so messages remain greppable).
- HTTP proxy support for webhook delivery (`host:port`, persisted; SOCKS explicitly out of scope — Dart's HttpClient only speaks HTTP CONNECT).
- Uptime history dialog now navigates all 7 retained days (was: last 24h only).
- MTR re-trace button: restarts discovery on the same host so route changes don't leave stale hops monitored forever.

### Changed
- Uptime day files are written atomically (temp + rename) so a mid-flush crash can't erase a day.

### Fixed
- Tray on Linux without an appindicator host no longer hides into a ghost process: close falls through to a real quit when no tray icon materialized.

### Security
- Webhook secrets moved out of plaintext prefs into DPAPI-protected storage on Windows, with one-time migration; all secret-store calls are timeout-bounded and degrade gracefully. Linux/macOS still store them as plaintext in the app preferences — a documented limitation, see SECURITY.md.

## [1.3.0] — 2026-10-08

### Added
- Alert webhooks: Telegram bot + Discord delivery on every status transition (fixed English format, 5-minute per-target anti-flap cooldown), configured in Settings with per-channel test buttons. Secrets persist locally next to other preferences.
- MTR tab: trace once, then ping every responding hop continuously on a dedicated engine instance (isolated from the matrix tab), with per-hop loss/avg/best/worst and copyable IPs. Fully localized and theme-aware.
- Uptime history: per-minute rollups (avg RTT, loss, worst status) persisted as one JSON file per UTC day (7-day retention), with a per-target 24-hour dialog (hourly status bars, uptime %, outage list with durations). Pure-Dart storage — no native database dependencies on any release platform.

## [1.2.0] — 2026-09-30

### Added
- Server backup: versioned JSON export of the target list plus paste-to-import with hardened validation (bad hosts/ports skipped, ids reassigned collision-free, 500-entry cap). Import/export lives in the matrix toolbar menu.
- Community health files: `CODE_OF_CONDUCT.md` (Contributor Covenant), `SECURITY.md` (supported versions + private reporting), and a PR template wired to this repo's checklist.
- Heatmap accessibility (thanks @ayanesato, PR #8): localized LOSS badge plus screen-reader labels in all four locales, with widget/semantics tests.
- DNS Lookup tab: raw UDP client for A/AAAA/MX/TXT/NS/CNAME/SOA records against Cloudflare/Google/Quad9 or a custom server IP, with NXDOMAIN distinction, query-time display and zone-copy. Fully localized (en/fa/ru/zh) and theme-aware.

### Fixed
- Windows ICMP targets no longer silently fall back to TCP on failure (mixed fake stats, doubled timeouts); the TCP fallback now runs only where native ICMP is unavailable (non-Windows).
- Warp UDP reachability detection now treats Windows `ConnectionReset` (WSAECONNRESET) like POSIX `ConnectionRefused` — the refused branch was previously dead on Windows.
- Sub-millisecond RTT reports the measured wall-clock time instead of a fabricated `0.5` constant (ping and traceroute paths).
- Removed the dead `netstudio_quick_ping` FFI (no call sites; it also owned the only `expect()` in the engine and blocked the calling thread).
- FFI resilience: release profile switched from `panic = "abort"` to `"unwind"` and every `extern "C"` entry point runs inside a `catch_unwind` guard — an engine-internal bug now degrades to an error return instead of killing (or UB-unwinding into) the host process.
- Probe scheduling no longer drifts: per-target loops tick on a fixed `tokio::time::interval` with `MissedTickBehavior::Skip` instead of `sleep(period)` after each probe.
- Dart fallback prober: overlapping 800ms ticks no longer double-count sockets and corrupt histories (reentrancy guard); offline status now needs 3 *consecutive* failures instead of 3 lifetime losses ever.
- Port scanner: `Socket.connect` timeouts surface as `SocketException`, so the old `TimeoutException` branch was dead and everything showed "closed" — timeout vs refused is now distinguished by OS error code + message; DNS resolves once per scan instead of per port.
- Warp fallback: generation counter kills the stale-loop-overwrites-new-run race; scans over the 4096 endpoint cap are refused with an error instead of firing ~22k fallback sockets; the header badge now shows the actual path in use.
- Traceroute uses the native engine on Windows only; Linux/macOS go straight to the system `traceroute` binary (native bindings exist there but can only emit timeouts).
- Traceroute output decodes leniently (`allowMalformed` + stream `onError`) so non-UTF8 console codepages (e.g. cp866/cp936) can't crash the app via an unhandled `FormatException`.
- Sidebar footer is capability-honest on non-Windows ("TCP mode").
- DLL loader: cwd-anchored dev paths are now debug-only (`kDebugMode`); release builds load exclusively from the executable directory, matching the documented policy.
- Add-Server dialog validates hosts with the same normalizer the engines use (URLs normalize, bad hosts fail in the form) and uses millisecond ids so same-second double adds can't collide.
- DNS hardening: family-matched socket bind (custom IPv6 servers work), source-address check against spoofed replies, and automatic TCP retry on truncated (TC) responses per RFC 1035 §4.2.2.
- CSV hardening: formula-injection neutralization (leading `=+-@` cells are text-marked) and empty timestamps for never-checked targets instead of 1970.
- Metrics decode moved from per-tick `compute()` spawns to one persistent worker isolate (with inline fallback), killing 500ms spawn overhead and GC churn.
- Sparkline and bandwidth chart repaint only when the visible shape can differ instead of every frame.
- Target status now follows windowed loss over the recent 40-sample ring (a host down for 10 minutes recovers promptly after reconnecting) while lifetime counters stay intact for totals.
- Native traceroute probes each TTL 3× and averages successful samples, matching the system `tracert` behavior instead of letting one slow router define the hop.
- Non-Windows lints fixed (`c_void`/`size_of` imports gated to Windows, unused `host` renamed in the ICMP stub) and CI gained an Ubuntu clippy+test job so the `#[cfg(not(windows))]` paths can never rot silently again.
- Warp scans now publish live progress (tested/succeeded/failed counts plus incremental results) instead of staying at 0% until completion.
- Warp endpoints resolve via explicit IP parsing with family-matched socket binding — IPv6 targets (e.g. `[::1]:443`) actually work now instead of timing out; bare unbracketed IPv6 stays rejected (port ambiguity).

## [1.1.0] — 2026-09-24

### Added
- JSON dictionaries: one file per language in `assets/lang/` (`en`, `fa`, `ru`, `zh`), loaded at startup with English fallback; `test/i18n_parity_test.dart` enforces identical key sets.
- Russian and Chinese UI (locale switch in Settings, persisted; Persian stays the only RTL locale).
- Release workflow now ships Windows x64 (zip), Linux x64 (tarball) and macOS arm64 (zipped `.app`, Gatekeeper note in README).
- Port Scanner tab: TCP sweep with `host` + `ports` spec (`80,443,8000-8010`, max 4096 ports), bounded-concurrency batches, open/closed/filtered states with well-known service guesses, copy-open and clear actions. Fully localized and theme-aware.
- Alert log: status transitions recorded with severity (critical/warning/info), unread badge on the matrix bell (red when the latest is critical), newest-first dialog with per-event RTT/loss detail and clear-all. Boot baselines (`pending` → anything) are not logged.
- Unit tests for traceroute host validation, metrics-snapshot decoding, the alert log and CSV export.
- CSV export: one-click snapshot of all target metrics (RFC 4180 quoting, sorted by id) to `Documents/VeloceNet-Studio/velocenet-metrics-<timestamp>.csv`, with copy-path feedback. The button shows a spinner and ignores taps while exporting (no duplicate downloads), then confirms with file name + size.

### Fixed
- Traceroute fallback races: stale stdout/exit-code/DNS callbacks from a killed run can no longer overwrite the new trace (generation counter + subscription cancel in `stop()`).
- Traceroute host validation: IPv4 (octet-checked), IPv6 (±brackets) and hostnames accepted; shell metacharacters and empty hosts rejected with an error instead of a silent no-op.
- Traceroute parser: IPv6 hop addresses recognized; RTT now averages all samples per line (was first-sample only, decimals truncated on Linux).
- Traceroute `maxHops`/`timeoutMs` clamped in Dart before FFI (unclamped `maxHops` truncated to `u8`) and before system-prober arguments.
- Metrics snapshot JSON now decodes in a background isolate (`compute`) with backpressure (overlapping ticks skipped); malformed payloads keep the previous frame.

### Changed
- Bandwidth interface counters migrated from `GetIfTable` (32-bit, wraps every ~4 GiB) to `GetIfTable2` (64-bit `InOctets`/`OutOctets`, real `TransmitLinkSpeed`, UTF-16 friendly names). Requires the `Win32_NetworkManagement_Ndis` windows-sys feature.

## [1.0.0] — 2026-09-21

First public release.

### Added
- Ping Matrix with ICMP (Windows IP Helper, no admin needed) + TCP-handshake probes, live sparklines, RTT avg/min/max, RFC 3550 jitter, loss %.
- Traceroute (TTL-based visual hop chain + data table, Windows native ICMP).
- Bandwidth monitor (per-interface live deltas via `GetIfTable`, top processes by connection share, explicitly labeled *estimated*).
- Warp Scanner (WireGuard-style UDP probe + TCP fallback, ranking, copy-to-clipboard, one-click add to Ping Matrix).
- Settings page: Light / Dark / System theme + English / فارسی locale, persisted with `shared_preferences` (default: English).
- Full i18n + theming migration for Ping Matrix, Traceroute, Bandwidth, Warp Scanner and sidebar (`AppStrings`, `ThemeX` adaptive colors).
- GitHub community files: issue templates, CI + Windows release workflows, `CONTRIBUTING.md`, expanded `README.md`.
- `LICENSE` (GPL-3.0-or-later) and repository metadata (`repository`, `homepage`, `issue_tracker`).

### Fixed
- Secure native-library loading (executable-anchored absolute paths only, no cwd/`PATH` probing → no DLL hijacking).
- FFI input validation (host/port/protocol/interval/timeout) on the Dart side, clamped ranges in the Rust engine.
- Native engine task leaks: per-target `JoinHandle` tracking, abort on `remove_target` / `start` / `stop`.
- `quick_ping` reuses a shared Tokio runtime instead of creating one per call.
- Warp CSV hardening: 256 KB / 4096-endpoint caps, bracketed-IPv6 parsing, rejection of bare IPv6 without port.
- Sidebar overflow crashes in narrow windows (flexible brand + engine-status rows).
- `AddTargetDialog` preset-name truncation (`split(' ')[0]` removed) and missing port/interval validators.
- `IndexedStack` tab navigation preserves Traceroute/Bandwidth/Warp state across tab switches.
- Native metrics polling interval 200 ms → 500 ms (less UI-thread JSON pressure); `print` → `debugPrint` in the engine service.
- Rank medals (🥇🥈🥉) replaced with text ranks (`#1`, `#2`, …) for font/i18n safety.

[Unreleased]: https://github.com/Cadman021/VeloceNet-Studio/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.5.0
[1.4.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.4.0
[1.3.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.3.0
[1.2.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.2.0
[1.1.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.1.0
[1.0.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0
