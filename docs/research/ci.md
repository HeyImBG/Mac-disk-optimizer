# CI research: GitHub macOS runners, Xcode, XcodeGen

Researched 2026-11-03 for task T01. Every fact has a source link.

## Runner labels (GitHub-hosted)

Source: [actions/runner-images README](https://github.com/actions/runner-images/blob/main/README.md)

| Image | Architecture | Labels |
|---|---|---|
| macOS 26 | arm64 | `macos-latest`, `macos-26`, `macos-26-xlarge` |
| macOS 26 | x64 | `macos-latest-large`, `macos-26-large`, `macos-26-intel` |
| macOS 15 | arm64 | `macos-15`, `macos-15-xlarge` |
| macOS 15 | x64 | `macos-15-large`, `macos-15-intel` |
| macOS 14 | x64 | `macos-14` (listed as deprecated) |
| Xcode 27 preview (macOS 26 image) | arm64 | `xcode-27`, `xcode-27-xlarge` |

- The `-xlarge` and `-large` suffixes are available only on GitHub Actions. Source: the same README.
- macOS 13 does not appear in the README. No retirement date was found for it.
- `macos-latest` points to the newest stable image (macOS 26 arm64). GitHub migrates it gradually over 1 to 2 months and recommends pinning a version such as `macos-15` to avoid surprise changes. Source: the same README.

## Retirement of macOS 14

- All macOS 14 images retired from GitHub Actions on **November 2, 2026**. The `macos-14` label should no longer run jobs. Source: [runner-images README](https://github.com/actions/runner-images/blob/main/README.md).
- The deprecation notice is [actions/runner-images issue 13518](https://github.com/actions/runner-images/issues/13518). It says the images "will begin deprecation on July 6th and will be fully unsupported by November 2nd."

## Xcode on the hosted images

Source: [macOS 15 image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) (image 20260824.0482.1, macOS 15.7.9)

- Default: Xcode 16.4.
- Installed: 26.3, 26.2, 26.1.1, 26.0.1, 16.4 (default), 16.3, 16.2, 16.1, 16.0.

Source: [macOS 26 image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) (image 20260824.0517.1, macOS 26.6.1)

- Default: Xcode 26.6 (build 17F113). The default changed from an earlier Xcode on 2026-07-21, per the same page.
- Installed: 26.6 (default), 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1.
- Xcode 27 is in public preview on this image only.

**What this means for the app:** `macos-26` with Xcode 26.6 is the best default for a macOS 14+ target. `macos-15` with Xcode 16.4 is the fallback. Pin the label rather than using `macos-latest`.

## XcodeGen

- Latest release: **2.46.0**, from [XcodeGen releases](https://github.com/yonaskolb/XcodeGen/releases/latest). The release page shows it as released 16 Jul. The year was not visible in the text fetched.
- A search result listed 2.45.4 (April 2026) as latest. The releases page is newer, so 2.46.0 is the value to use. Re-check before pinning.
- Install with Homebrew: `brew install xcodegen`. Source: [Homebrew formula](https://formulae.brew.sh/formula/xcodegen). The formula builds with Xcode 15.3 or later and has bottles for Sonoma, Sequoia and Tahoe on Apple Silicon.

## Open items

- macOS 13 retirement date: not found.
- The XcodeGen release year on the releases page was not confirmed.
