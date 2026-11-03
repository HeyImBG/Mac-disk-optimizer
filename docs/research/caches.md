# Cache and log folders: what is safe to remove

Researched 2026-11-03 for task T14. Every row has a source. Rows marked **unverified** have no Apple source yet and must be checked before any rule uses them.

## Paths

| Path | What it holds | What rebuilds it | Close first | Risk | Source |
|---|---|---|---|---|---|
| `~/Library/Caches/<bundle id>/` | Per-app cache files. Apple says they "can be regenerated as needed" and that apps "should never rely on the existence of cache files" | The owning app, on its next launch or next use | The app named by the folder's bundle id (`<bundle id>` is the folder name) | safe | [Apple archived File System Programming Guide, Library directory](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html) |
| `~/Library/Logs/` | Log files for the console and some system services. Users can read them in Console | Services write new logs as they run | None for files that are not open. Skip a log that a running app is writing | review | [Apple archived File System Programming Guide, Library directory](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html) |
| `~/Library/Logs/DiagnosticReports/` | Crash reports (`.ips` and older `.crash` files) | Nothing needed. New reports appear when an app crashes | None | review | **unverified**. Found only in third-party guides. [AppleInsider, how to delete macOS logs and crash reports](https://appleinsider.com/inside/macos/tips/how-to-delete-macos-logs-and-crash-reports). Keep any report that is still being debugged |

## Rules that follow from the rows

- Only paths under `~/Library/Caches/<bundle id>/` are candidates for the safe risk level. Each one must name its bundle id so the engine can check whether that app is running.
- Do not touch `~/Library/Application Support`. Apple says it "can include files that contain user data" ([Apple archived File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html)).
- Leave out Apple's own caches in `~/Library/Caches` (`com.apple.*` plus non-bundle-id ones like `CloudKit`, `GeoServices`, `SiriTTS`). They belong to system services that are always running, and the running-app check cannot see them. Verified on Berat's Mac on 2026-11-03: trashing 118 of them while they ran was followed by a Finder crash. Defenses since then: the cache rule only matches bundle-id-shaped folder names, only pre-selects caches whose bundle id is an installed app, and `CleanupEngine` refuses `~/Library/Caches/com.apple.*` outright.
- Do not touch `/Library/Caches` or `/System/Library/Caches`. They are system-wide, and the sources found so far do not cover them. Leave them out of T15 until they are researched.
- Deleting caches can slow the next launch while they rebuild. One Apple Community answer says clearing the user cache often frees little, because apps refill it ([Apple Community thread](https://discussions.apple.com/thread/254749384)). This is a secondary source.

## Gaps

- No Apple page was found that lists which apps must be closed. The rule above (close the app that matches the bundle id) comes from the folder layout, not from a cited list.
- The Apple Support storage page did not describe cache or log folders when fetched.
- The Apple Developer crash-report page returned only its title when fetched, so it is not used here.
- Before T15, check the `~/Library/Caches` and `DiagnosticReports` rows on Berat's Mac (the T13 check) and mark them verified.
