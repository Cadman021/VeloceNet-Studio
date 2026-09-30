# Changelog

All notable changes to VeloceNet-Studio are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- DNS Lookup tab: raw UDP client for A/AAAA/MX/TXT/NS/CNAME/SOA records against Cloudflare/Google/Quad9 or a custom server IP, with NXDOMAIN distinction, query-time display and zone-copy. Fully localized (en/fa/ru/zh) and theme-aware.
- Server backup: versioned JSON export of the target list plus paste-to-import with hardened validation (bad hosts/ports skipped, ids reassigned collision-free, 500-entry cap). Import/export lives in the matrix toolbar menu.

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

[Unreleased]: https://github.com/Cadman021/VeloceNet-Studio/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.1.0
[1.0.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0
