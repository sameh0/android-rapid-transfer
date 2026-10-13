fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac app

```sh
[bundle exec] fastlane mac app
```

Universal Android Rapid Transfer.app, ad-hoc signed, in native/AndroidRapidTransfer/release

Options: version, build_number

### mac dmg

```sh
[bundle exec] fastlane mac dmg
```

Release DMG in native/AndroidRapidTransfer/ci-artifacts: Developer ID signed,

notarized and stapled, with the Sparkle appcast.xml, SHA256SUMS and build-info.txt

Options: adhoc:true (ad-hoc signed, no appcast), version, build_number

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
