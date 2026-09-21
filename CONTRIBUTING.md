# Contributing to VeloceNet-Studio

Thanks for your interest! This project is GPL-3.0 licensed — by contributing you agree your changes will be distributed under the same license.

## Quick start

Prerequisites: Flutter SDK ≥ 3.22, Rust stable (`rustup`), Windows 10/11 x64 for full native features.

```powershell
.\build_native.ps1        # builds native_engine -> netstudio_engine.dll
flutter pub get
flutter run -d windows
```

> If the DLL is missing, the app automatically uses the Dart fallback prober — the UI stays usable.

## Before pushing

```bash
flutter analyze --no-pub
flutter test --no-pub
cd native_engine
cargo test --release
cargo clippy --release -- -D warnings
```

CI (`.github/workflows/ci.yml`) runs exactly these checks on Windows. Keep them green.

## Project conventions

- **i18n:** user-visible strings go through `AppStrings` (`lib/core/i18n/app_strings.dart`) with both `en` and `fa` entries. No hardcoded Persian/English in widgets.
- **Theming:** never use `AppColors.surface/background/text*` directly in new UI — use the `ThemeX` context extension (`lib/core/theme/theme_x.dart`) so Light/Dark/System keeps working.
- **FFI safety:** validate every string crossing FFI in `NativeBindings` (host regex, port `1–65535`, clamped intervals). Never load DLLs from cwd/`PATH` — see `native_library.dart`.
- **Rust:** no `unwrap()` on hot paths crossing FFI; cap unbounded inputs (CSV sizes, endpoint counts); abort spawned probe tasks when targets/sessions are removed.
- **Commits:** short imperative subject (`Add warp empty-state string`), reference issues (`Fixes #12`). One logical change per commit.
- **PRs:** describe what/why, include screenshots for UI changes (Light + Dark if themed), confirm the checklist above. Small PRs get reviewed faster.

## Reporting bugs / requesting features

Use the issue templates (bug report / feature request). For bugs include: app version/commit, OS, engine (Rust/Dart, see sidebar footer), repro steps, and logs/screenshots.

## Security

Do **not** open public issues for vulnerabilities. See `SECURITY.md` if present, otherwise contact the maintainers privately via the emails on the GitHub profile.
