# Developer junk: which folders can go

Researched 2026-11-03 for task T21. Every row has a source or is marked **unverified**. Unverified rows have no page that was readable when fetched (Apple's developer pages load their text with JavaScript and returned nothing). T25 must keep unverified rows at `review` or `caution` until they are checked on Berat's Mac (the T13-style check).

## Paths

| Path | What it holds | What rebuilds it | Close first | Risk | Source |
|---|---|---|---|---|---|
| `~/Library/Developer/Xcode/DerivedData/` | Xcode build products and indexes, one folder per project | Xcode, on the next build (a full rebuild, so the first build is slow) | Xcode | review | **unverified**. Path and behavior are common knowledge but no readable Apple page was found |
| `~/Library/Developer/Xcode/Archives/` | Archived app builds, including the dSYM files needed to read crash reports from released builds | Not rebuildable. An archive cannot be recreated without the source at that exact state | Xcode | caution | **unverified**. Never pre-select |
| `~/Library/Developer/Xcode/iOS DeviceSupport/` | Debug symbols Xcode copies from each physical iPhone or iPad it connects to | Xcode, the next time that device is connected (takes several minutes) | Xcode | review | **unverified** |
| `~/Library/Developer/CoreSimulator/Devices/` | Simulator devices, with the apps and data installed in them | Unavailable simulators can be removed with `xcrun simctl delete unavailable`. A device you deleted by hand is gone with its data | Xcode and Simulator | caution | **unverified**. Remove through `simctl`, not by deleting folders |
| `~/Library/Caches/Homebrew/` | Downloaded formula and cask files | Homebrew downloads them again. `brew cleanup` removes outdated downloads, and `rm -rf "$(brew --cache)"` removes the rest | None, unless `brew` is running | safe | [Homebrew FAQ](https://docs.brew.sh/FAQ) (path is "usually" this one), [Homebrew manpage, `cleanup`](https://docs.brew.sh/Manpage) |
| `~/.npm/` (the `_cacache` folder inside) | npm's download cache | npm. Its docs call the cache "self-healing", and `npm cache clean` deletes it | None, unless `npm` is running | safe | [npm folders](https://docs.npmjs.com/cli/v10/configuring-npm/folders), [npm cache](https://docs.npmjs.com/cli/v10/commands/npm-cache) |
| pnpm store (`pnpm store path` prints it; the macOS default is not on a fetched page) | One copy of every package any project installed, hard-linked into `node_modules` | pnpm downloads a package again when it is needed. `pnpm store prune` removes only unreferenced packages and its docs say it is "not harmful" | None, unless `pnpm` is running | review | [pnpm store](https://pnpm.io/cli/store). Do not delete the folder by hand: projects hard-link into it |
| `~/Library/Caches/Yarn/` (Yarn 1, run `yarn cache dir` to confirm) | Yarn Classic global package cache | `yarn install` downloads again. `yarn cache clean` clears it | None, unless `yarn` is running | safe | [Yarn Classic `yarn cache`](https://classic.yarnpkg.com/en/docs/cli/cache). The default macOS path is **unverified**; the page only says the path comes from `yarn cache dir` |
| Yarn Berry global cache (`globalFolder`, default not on a fetched page) | Package archives shared by all projects (`enableGlobalCache` is true by default) | `yarn install` | None, unless `yarn` is running | review | [Yarn `.yarnrc.yml`](https://yarnpkg.com/configuration/yarnrc). Projects with Plug'n'Play or offline installs may rely on it |
| `~/Library/Caches/pip/` | pip's wheel and HTTP caches | pip downloads again. `pip cache purge` clears both | None, unless `pip` is running | safe | [pip caching](https://pip.pypa.io/en/stable/topics/caching/), [pip cache](https://pip.pypa.io/en/stable/cli/pip_cache/). Use `pip cache dir` to confirm the path; the macOS default is **unverified** on the fetched pages |
| `~/.cargo/registry/cache/` and `~/.cargo/registry/src/` | Downloaded `.crate` archives, and the unpacked sources of those that a build needed | Cargo downloads and unpacks them again | None, unless `cargo` is running | safe | [Cargo home](https://doc.rust-lang.org/cargo/guide/cargo-home.html). Leave `registry/index` and `~/.cargo/bin` alone: `bin` holds installed tools |
| `~/.cargo/git/` | Checkouts of git dependencies | Cargo clones again | None, unless `cargo` is running | review | [Cargo home](https://doc.rust-lang.org/cargo/guide/cargo-home.html) |
| `~/.gradle/caches/` | Dependency jars, compiled build scripts, and version-specific caches | Gradle recreates them on first use. Gradle itself deletes unused version caches after 30 days | None, unless a Gradle daemon is running | review | [Gradle directory layout](https://docs.gradle.org/current/userguide/directory_layout.html) |
| `<project>/node_modules/` | Installed dependencies for one project | `npm install` (or pnpm or yarn) rebuilds it from the lockfile | The editor or dev server using that project | review | [Node.js, npm introduction](https://nodejs.org/en/learn/getting-started/an-introduction-to-the-npm-package-manager) says `npm install` creates it. Only offer it when the project has a lockfile |
| Docker Desktop disk image (location shown in Docker Desktop, Settings, Resources, Advanced) | Every Linux container, image and volume, in one large file | Not rebuildable by the app. Free space by pruning inside Docker | Docker Desktop | caution | [Docker Desktop for Mac FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/), [docker system prune](https://docs.docker.com/reference/cli/docker/system/prune/) |

## Rules that follow from the rows

- Only the Homebrew, npm, Yarn Classic, pip and Cargo registry caches are candidates for `safe`. Each is a download cache whose own docs say it is re-fetched on demand. Every other row stays `review` or `caution`.
- The rules loader currently rejects a `safe` rule that has no `bundleId` (`safeRuleNeedsBundleId`). Command-line tools (brew, npm, pip, cargo) have no bundle id, so T25 must either keep these at `review` or add a deliberate, tested exception for them. Where a tool could be running, the analyzer should warn the user, because the running-app check cannot see terminal processes.
- Xcode's `Archives` folder and the Docker disk image are never pre-selected. Archives hold symbols for released builds. The Docker image is one file that holds all containers.
- The Docker image lives under `~/Library/Containers/`, which `CleanupEngine` fully protects. That is correct. Offer Docker as an info row with the `docker system prune` command, not as a deletable item.
- Simulators go through `xcrun simctl`, not folder deletes. Rule 1 in `CLAUDE.md` (only `CleanupEngine` may remove files) means T25 shows these as info rows too.
- `node_modules` is per project. T25 finds them with the scan index, shows the project's last-modified date, and never offers one inside an `.app` or the denylist.

## Gaps

- No readable Apple page for the Xcode, DerivedData, Archives, DeviceSupport and CoreSimulator paths. Verify on Berat's Mac before enabling any rule.
- Default macOS paths for the pnpm store, the Yarn Berry global folder and Yarn Classic were not on the fetched pages. Use each tool's own command (`pnpm store path`, `yarn cache dir`, `pip cache dir`) when verifying.
- Not researched: Bun, Deno, CocoaPods, Carthage, SwiftPM caches, Maven, Go module cache, conda. Add them in a follow-up if Berat uses them.
