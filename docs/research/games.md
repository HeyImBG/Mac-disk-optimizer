# Game paths: where Mac game data lives

Researched 2026-11-03 for task T22 (web search only; the vendors' own pages could not be fetched from the cloud container). Rows marked **unverified** rest on forums or third-party guides, and must be checked on Berat's Mac before T26 uses them. Games hold saves and purchases, so nothing here is `safe`.

## Paths

| Path | What it holds | What rebuilds it | Close first | Risk | Source |
|---|---|---|---|---|---|
| `~/Library/Application Support/Steam/steamapps/common/<game>/` | Installed Steam games, one folder per game | Steam downloads the game again (large download). Saves in the Steam cloud come back; local-only saves do not | Steam and the game | review | **unverified**. [MacRumors thread](https://forums.macrumors.com/threads/how-to-find-steam-apps-folder-location-on-mac.2303715) and [Dr.Buho guide](https://www.drbuho.com/how-to/steam-taking-up-too-much-space-mac) agree on the path. Valve's help pages could not be fetched |
| `~/Library/Application Support/Steam/steamapps/downloading/` and `.../temp/` | Half-finished downloads and temporary files | Steam restarts the download | Steam | review | **unverified**. Named in the [Dr.Buho guide](https://www.drbuho.com/how-to/steam-taking-up-too-much-space-mac) only |
| Steam shader caches | Compiled shaders | Not found for macOS. The only source is a Linux/Proton note (`<steamlibrary>/shadercache/<appid>`) | | not offered | **No macOS source**. Do not add a rule yet. [CachyOS forum, Linux only](https://discuss.cachyos.org/t/shadercache-on-steam-doesnt-work/17989) |
| `/Users/Shared/Epic Games/` | Games installed by the Epic Games Launcher | Epic downloads them again | Epic Games Launcher and the game | review | **unverified**. Only [Wondershare Recoverit](https://recoverit.wondershare.com/computer-tips/where-does-epic-games-install-games.html) names this path. Epic says the install folder is chosen at the first install ([Epic help](https://www.epicgames.com/help/en-US/technical-support-c-202300000001619/a202300000011768)), so it can differ |
| Battle.net game folders | Blizzard games | Battle.net downloads them again | Battle.net and the game | review | **unverified**. No default path: a [TL.net forum post](https://tl.net/forum/starcraft-2/124595-mac-and-sc2) says there is none, and a [Gameskeys guide](https://gameskeys.net/how-to-install-starcraft-remastered-on-mac/) says `/Applications`. Read the location from Battle.net's Game Settings, not from a fixed path |
| `~/Library/Application Support/CrossOver/Bottles/<bottle>/` | CrossOver bottles: a Windows environment with its `C:` drive, installed Windows games and their saves | Not rebuildable. The Windows installs and saves live inside | CrossOver | caution | [CodeWeavers, change where CrossOver stores bottles](https://support.codeweavers.com/change-the-bottle-directory-in-crossover-mac) (default path; `BottleDir` or `CX_BOTTLE_PATH` can change it). A system-wide location, `/Library/Application Support/CrossOver/Bottles`, is also documented |
| `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/<id>/` | Whisky bottles (the original app) | Not rebuildable, same as CrossOver | Whisky | caution | [Whisky issue #943](https://www.Github.com/Whisky-App/Whisky/issues/943) log shows the path, and the [community fork's README](https://github.com/frankea/Whisky) says old bottles stay there. The fork uses `com.franke.Whisky`. Bottles can also sit in a custom folder |

## Rules that follow from the rows

- No game path is `safe`. Game folders and bottles are `review` (re-downloadable) or `caution` (bottles: saves and installs inside). None may be pre-selected.
- `CleanupEngine` fully protects `~/Library/Application Support` and `~/Library/Containers` (see the T19 review). So Steam, CrossOver and Whisky data cannot be trashed by the engine today, and that is fine: T26 should show size per game and per bottle, with Reveal in Finder, and tell the user to remove games from the launcher itself. `/Users/Shared/Epic Games` is the one path outside those folders, so it is the only row that could ever be trashed, and it needs a deliberate rule and a safety review first.
- Never delete a bottle folder by hand while its app is open. Bottles hold registry and save data.
- Custom install locations exist for every launcher. T26 should read launcher settings only if that is cheap and read-only; otherwise it covers the default paths and says so.

## Gaps

- No official Valve, Epic or Blizzard page was readable. Every game-launcher row is unverified.
- No macOS source for shader caches (Steam, Metal or CrossOver). Skip them for now.
- Not researched: GOG Galaxy, Heroic, Mac App Store games, Apple Game Porting Toolkit prefixes, Minecraft launchers.
- Before T26, list `~/Library/Application Support/Steam`, `/Users/Shared`, and the bottle folders on Berat's Mac and mark each row verified or wrong.
