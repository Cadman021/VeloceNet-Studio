# VeloceNet-Studio

[![CI](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml)
[![Release v1.0.0](https://img.shields.io/badge/release-v1.0.0-green.svg)](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)]()
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.22-02569B.svg)]()
[![Rust](https://img.shields.io/badge/Rust-stable-orange.svg)]()

Cross-platform **network monitoring and analysis studio** built with **Flutter** + a **Rust engine (Tokio, via FFI)**.

Live latency matrix (ICMP / TCP), visual traceroute, bandwidth monitor and Warp endpoint scanner — with Light/Dark/System themes and English/فارسی UI.

> License: **GPL-3.0-or-later** — see [LICENSE](LICENSE).

## Screenshots

> Screenshots live in [`docs/screenshots/`](docs/screenshots/). If an image is missing below, capture it with <kbd>Win</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> at 1600×900 and save it under that path.

| Ping Matrix (dark) | Ping Matrix (light) |
|---|---|
| ![Ping Matrix dark](docs/screenshots/01-ping-matrix-dark.png) | ![Ping Matrix light](docs/screenshots/02-ping-matrix-light.png) |

| Traceroute | Bandwidth |
|---|---|
| ![Traceroute](docs/screenshots/03-traceroute.png) | ![Bandwidth](docs/screenshots/04-bandwidth.png) |

| Warp Scanner | Settings |
|---|---|
| ![Warp Scanner](docs/screenshots/05-warp.png) | ![Settings](docs/screenshots/06-settings.png) |

## Features

- **Ping Matrix** — concurrent ICMP (Windows IP Helper, no admin needed) + TCP-handshake probes, live sparklines, RTT avg/min/max, RFC 3550 jitter, loss %.
- **Traceroute** — TTL-based visual hop chain + data table (Windows native ICMP).
- **Bandwidth** — per-interface live deltas via `GetIfTable`, top processes by connection share (explicitly labeled *estimated*).
- **Warp Scanner** — WireGuard-style UDP probe + TCP fallback, ranking, copy-to-clipboard, one-click add to Ping Matrix.
- **Settings** — Light / Dark / System theme + English / فارسی locale, persisted with `shared_preferences` (default: English).
- **Resilient engine** — if the Rust `.dll`/`.so` isn't built, the app automatically uses the Dart fallback prober so the UI stays usable.

## Download (v1.0.0)

No build needed — grab **`velocenet-studio-windows-x64.zip`** from the
[v1.0.0 release](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0),
extract it anywhere and run the `.exe` inside. `netstudio_engine.dll` is bundled
next to the executable. See [CHANGELOG.md](CHANGELOG.md) for what's in this release.

## Build from source (Windows)

Prerequisites: Flutter SDK ≥ 3.22 · Rust stable (`rustup`) · Windows 10/11 x64 for full native features.

```powershell
.\build_native.ps1      # cargo build --release + stage netstudio_engine.dll
flutter pub get
flutter run -d windows
```

Manual alternative:

```powershell
cd native_engine
cargo build --release
Copy-Item target\release\netstudio_engine.dll ..
cd ..
flutter run -d windows
```

Linux/macOS: `cargo build --release` produces `libnetstudio_engine.so` / `.dylib`; ICMP falls back to TCP where raw sockets aren't available.

## How it works

```
┌──────────── Flutter UI ────────────┐      ┌────────── Rust engine ──────────┐
│ Ping Matrix · Traceroute           │ JSON │ Tokio probers (ICMP/TCP/TTL)    │
│ Bandwidth · Warp · Settings        │◄────►│ stats (RTT/jitter/loss)         │
│ SettingsController (theme+locale)  │  FFI │ traceroute / bandwidth / warp   │
└────────────────────────────────────┘      └─────────────────────────────────┘
```

- FFI boundary: `lib/core/ffi/` (Dart) ↔ `native_engine/src/ffi.rs` (C ABI). All strings are validated in Dart before crossing; numeric ranges are clamped on both sides.
- Native library is resolved from **absolute paths anchored at the running executable only** — never cwd/`PATH` (DLL-hijacking safe).
- State: `PingMatrixController`, `TracerouteController`, `BandwidthController`, `WarpController`, `SettingsController` (all `ChangeNotifier`-based).

## Project structure

```
lib/
  main.dart                      # async boot + SettingsController load
  core/ffi/                      # native_library.dart, native_bindings.dart
  core/theme/                    # app_colors.dart, app_theme.dart, theme_x.dart
  core/settings/                 # settings_controller.dart (theme+locale)
  core/i18n/                     # app_strings.dart (en/fa, default en)
  models/ services/ state/
  views/
    main_shell_view.dart         # sidebar + IndexedStack tabs
    ping_matrix/ traceroute/ bandwidth/ warp/ settings/
native_engine/src/
  engine.rs ffi.rs stats.rs probe/ traceroute.rs bandwidth.rs warp.rs
.github/workflows/              # ci.yml, release.yml
docs/screenshots/               # images used above
```

## Security notes

- No cwd/`PATH` DLL probing; missing engine → Dart fallback (never a crash).
- Warp scan input capped (256 KB / 4096 endpoints); IPv6 handled explicitly (bracketed `[::1]:port`).
- Per-process bandwidth is a **connection-share estimate** (Windows exposes no per-PID byte counters without ETW) — the UI labels it as such.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). TL;DR:

```bash
flutter analyze --no-pub
flutter test --no-pub
cd native_engine && cargo test --release && cargo clippy --release -- -D warnings
```

New UI strings must go through `AppStrings` (en+fa); new colors through `ThemeX`. Bug reports and feature requests use the issue templates.

## Changelog & roadmap

See [CHANGELOG.md](CHANGELOG.md). Near-term ideas: Linux/macOS native ICMP, 64-bit interface counters (`GetIfTable2`), CSV/Prometheus export, real per-process accounting (ETW).
