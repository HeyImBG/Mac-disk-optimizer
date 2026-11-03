# Mac Disk Optimizer

A macOS app (Swift + SwiftUI, macOS 14+) that analyzes your disk and suggests safe cleanups. It only suggests: you confirm every deletion, and files go to the Trash.

## Layout

- `Packages/DiskEngine`: SwiftPM library with the scanning, rules and cleanup logic. Test with `swift test --package-path Packages/DiskEngine`.
- `App/`: SwiftUI app sources and tests.
- `project.yml`: XcodeGen spec. The Xcode project is generated, never hand-edited or committed.
- `docs/research/`: sourced research notes.

## Build (on a Mac)

```
brew install xcodegen
xcodegen generate
open DiskOptimizer.xcodeproj
```

## License

MIT, see `LICENSE`.
