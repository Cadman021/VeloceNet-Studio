## What / Why

<!-- What does this change, and why? Link the issue: Fixes #<n> -->

## Validation

- [ ] `flutter analyze --no-pub` — no issues
- [ ] `flutter test --no-pub` — all green (new tests added if logic changed)
- [ ] `cargo test --release` + `cargo clippy --release -- -D warnings` (Rust touched?)

## Checklist

- [ ] New UI strings added to **all four** `assets/lang/*.json` files (`test/i18n_parity_test.dart` passes)
- [ ] New colors go through `ThemeX`, verified in **Light + Dark** themes
- [ ] Screenshots attached (UI changes — Light + Dark where themed)
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] No binaries, secrets, or generated files committed (`git status` is clean of them)

## Reviewer notes

<!-- Anything risky, platform-specific (Windows-only paths?), or intentionally left out -->
