# Android Rapid Transfer — Project Notes

## Repository

**Android Rapid Transfer** (ART) — a native macOS app for fast file transfer between
Android and Mac, bundle ID `com.sameh.AndroidRapidTransfer`, repository
`sameh0/android-rapid-transfer`. The name and identifiers live in `AppIdentity`
(Swift) and `Scripts/release-config.sh` (packaging), kept in step by
`AppIdentityTests`.

Layout: `native/AndroidRapidTransfer` (SwiftUI app `AndroidRapidTransfer`, its tests,
packaging scripts), `native/ARTCore` (platform-neutral core library
`AndroidRapidTransferCore`, its tests and the device probes; builds on macOS and Linux),
`native/MTPKit` (library `MTPKit`: the `MTPDeviceProvider` protocol, models, errors
and `MockMTPProvider`; `SwiftMTP`: the pure-Swift MTP engine over IOUSBHost,
`SwiftMTPProvider`; `USBWatcher`: USB hotplug). `docs/media` holds the README's
demo video and screenshots.

`main` is the only branch. Commit messages are the project's changelog: keep them
self-contained.

## Build and test

- **`DEVELOPER_DIR` is mandatory** when `xcode-select` points at Command Line Tools:
  they ship no `libSwiftUIMacros.dylib`, so every `@State` fails to expand. Use
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `cd native/AndroidRapidTransfer && swift build && swift test`; same in `native/ARTCore` and
  `native/MTPKit` (both also build and test on Linux).
- Run: `swift run AndroidRapidTransfer` (real device) or `swift run AndroidRapidTransfer --mock`
  (a built-in mock phone; debug builds add a Debug menu for failure injection).
- Dev bundle: `native/AndroidRapidTransfer/make-app.sh` → `native/AndroidRapidTransfer/dist/Android Rapid Transfer.app`.
  Every packaging script checks
  the bundle with `verify_bundle_layout` (only the app and Sparkle in MacOS/Frameworks).
- CI: `.github/workflows/ci.yml` (tests) and `release.yml` (DMG artifact; draft release on
  `v*` tags) only call `native/AndroidRapidTransfer/Scripts/ci-build.sh test|package|appcast`,
  so reproduce CI failures locally with that script. Signing secrets are optional (ad-hoc
  `*-adhoc.dmg` without them).
- Cold `swift build` in a fresh checkout or worktree takes minutes — run it in the
  background, not as a silent foreground command.
- Animation: use the tokens and helpers in `Sources/AndroidRapidTransfer/Motion.swift`
  (`Motion.snappy`/`.bouncy`/`.gentle`/`.celebrate`/`.progressFill`, `.motion(_:value:)`,
  `withMotion`, `.motionTransition`, `.motionMatchedGeometry`, `.motionBounce`,
  `.motionSpin`, `.motionShake`, `.motionPop`, `.staggeredAppearance`); they honour
  Reduce Motion. Never call `withAnimation`, `.symbolEffect(.bounce…)` or a looping
  animator directly. Any loop (`TimelineView`, `phaseAnimator`, trigger-less
  `keyframeAnimator`, `repeatForever`) must be gated on the `motionIsLive`
  environment value (window visible and active, app frontmost), and purely
  decorative idle loops on `motionAllowsIdleLoops` (settles after 12 s idle), so an
  idle window costs ~0% CPU. Corner radii: `Radius.card`/`.row`/`.small`/`.keycap`.
- MTP engine diagnostics (environment): `ART_MTP_DISABLE_PROPLIST=1` (list per object),
  `ART_MTP_PROPLIST_WILDCARD_MAX_CHILDREN=N` (GetObjectPropList wildcard size gate).

## Device testing (physical phone)

- Probes: `ScanProbe`, `RecursiveWalkProbe`, `SeedTestPhotos`, `LifecycleProbe` in
  `native/ARTCore`; `mtp-probe`, `swift-provider-probe` in `native/MTPKit`.
- **A run counts only if it completes**: require its completion marker
  (`^VERIFICATION` / `^COMPARABILITY`). `SIGSEGV`, `fatal error:`, or exit code > 1
  is a crash — never count those as passes, and never
  judge success by the absence of `^ERROR:` lines.
- ADB (`brew install --cask android-platform-tools`, with USB debugging authorized on
  the phone) can restore File transfer mode: `adb shell svc usb setFunctions mtp`, and
  `adb shell svc usb resetUsbGadget` re-enumerates the phone (~0.5 s).
- **`adb shell svc usb getFunctions` prints to STDERR** — capture it with `2>&1`, or
  it always reads empty. Don't re-select MTP unless it has genuinely left `mtp`:
  setting it re-enumerates the phone.
- A locked or dozing phone drops out of File transfer after re-enumeration: keep a
  test phone awake for long runs.
- Only one agent or session may drive the phone at a time.

## Maintainer notes

Maintainers keep internal notes elsewhere; when present, they are imported here:

@internal/CLAUDE.md
