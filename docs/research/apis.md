# macOS disk APIs (T05)

Research note for the scanner, volume overview and Full Disk Access onboarding.
Each fact has a source link. Items marked **Not verified** could not be confirmed from Apple's pages and need a check on a real Mac before code depends on them.

## 1. URLResourceKey keys for scanning

All keys are read with `URL.resourceValues(forKeys:)` (Foundation). Apple's pages say each key is read-only.

| Key | What it gives | Value type | Notes | Source |
|---|---|---|---|---|
| `fileAllocatedSizeKey` | Total allocated size on disk for the file | NSNumber | Use for the on-disk footprint. Apple: "The key for the total allocated size on-disk for the file." Available macOS 10.6+ | [docs](https://developer.apple.com/tutorials/data/documentation/foundation/urlresourcekey/fileallocatedsizekey.md) |
| `totalFileAllocatedSizeKey` | Total allocated size, including file metadata | NSNumber | Apple: "The key for the total allocated size of the file, in bytes." Metadata is included, so it can be larger than `fileAllocatedSizeKey`. Available macOS 10.7+ | [docs](https://developer.apple.com/documentation/foundation/urlresourcekey/totalfileallocatedsizekey.md) |
| `linkCountKey` | Number of hard links to the resource | NSNumber | Apple: "The number of hard links to the resource." Use it with `fileResourceIdentifierKey` to count a hard-linked file once. Available macOS 10.6+ | [docs](https://developer.apple.com/documentation/foundation/urlresourcekey/linkcountkey.md) |
| `fileResourceIdentifierKey` | Unique identifier of the resource | id (read-only) | Two resources are equal if they share a path or link to the same inode on the same file system. Apple: "The value of this identifier isn't persistent across system restarts." So do not store it between runs. Available macOS 10.7+ | [docs](https://developer.apple.com/documentation/foundation/urlresourcekey/fileresourceidentifierkey.md) |
| `isSymbolicLinkKey`, `isDirectoryKey`, `isRegularFileKey`, `isVolumeKey` | File type checks, used to skip symlinks and other volumes | Bool | Not re-verified in this pass. The Scanner needs symlinks skipped, so check these on the first Scanner PR (T07) | [file property keys](https://developer.apple.com/documentation/corefoundation/file-property-keys.md) |

Equivalent Core Foundation keys (`kCFURLFileAllocatedSizeKey`, `kCFURLTotalFileAllocatedSizeKey`) return CFNumber. Source: [File Property Keys](https://developer.apple.com/documentation/corefoundation/file-property-keys.md).

## 2. Volume and purgeable capacity

| Key or property | What it gives | Value type | Notes | Source |
|---|---|---|---|---|
| `volumeTotalCapacityKey` | Total capacity of the volume, in bytes | Int (read-only) | Apple flags it as a fingerprinting risk. Use must be declared in `PrivacyInfo.xcprivacy`. Available macOS 10.6+ | [docs](https://developer.apple.com/tutorials/data/documentation/foundation/urlresourcekey/volumetotalcapacitykey.md) |
| `volumeAvailableCapacityForImportantUsageKey` | Available capacity for storing important resources, in bytes | Int64? via `URLResourceValues.volumeAvailableCapacityForImportantUsage` | Includes purgeable space that macOS can free on demand. Apple also flags fingerprinting. Available macOS 10.13+ | [URLResourceValues property](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage.md), [key](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey.md) |
| `volumeAvailableCapacityKey` | Plain free space on the volume | Int | Excludes purgeable space. Listed on the same index page; its own page was not read in full | [URLResourceKey index](https://developer.apple.com/documentation/foundation/urlresourcekey.md) |
| `volumeResourceCountKey` | Total number of resources on the volume | NSNumber | Not needed for the volume overview | [docs](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeresourcecountkey.md) |

**Purgeable space.** No public Apple key was found that reports purgeable bytes by itself. The closest is `volumeAvailableCapacityForImportantUsage` minus `volumeAvailableCapacityKey`, which gives an estimate of purgeable space. This is an inference, not an Apple-documented figure. **Not verified** that the difference matches what Finder shows. Check it on Berat's Mac in T08.

A forum post reports `volumeAvailableCapacityForImportantUsage` returning 0 when queried on the root path `/` on iOS 11, and working on the app's own directory. Query the user's home folder, and test this on macOS. Source: [Stack Overflow mirror](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/56474397/why-is-volumeavailablecapacityforimportantusage-zero) (anecdotal).

## 3. APFS local snapshots

- Command: `tmutil listlocalsnapshots <mount_point>`, for example `tmutil listlocalsnapshots /`. Output starts with `Snapshots for volume group containing disk /:`, then one name per line in the form `com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local`. Some lines carry a `(dataless)` marker. Source: [Apple Developer Forums 81171](https://developer.apple.com/forums/thread/81171), [650026](https://developer.apple.com/forums/thread/650026), [117274](https://developer.apple.com/forums/thread/117274).
- The output lists names and dates only. It does not give the size of each snapshot. Source: [81171](https://developer.apple.com/forums/thread/81171).
- Related commands: `tmutil deletelocalsnapshots <date>` (do not use from the app without a safety review), `tmutil thinlocalsnapshots <mount_point> <purgeamount> <urgency>`. Source: [cleverfiles guide](https://www.cleverfiles.com/help/apfs-snapshots.html) (third party).
- **Not verified:** the official `man tmutil` text. Run `man tmutil` on a Mac to confirm the syntax before coding against it.
- Running `tmutil` from a sandboxed app may need a different route. Check this in T08.

## 4. Full Disk Access deep link

- Candidate URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. Source: [Rust crate constant](https://docs.rs/runner-manager-platform/0.4.21/runner_manager_platform/os/constant.FULL_DISK_ACCESS_SETTINGS_URL.html).
- Ventura reports say old deep links broke, and that opening them with `NSWorkspace.shared.open()` works where `open <url>` in Terminal does not. Source: [Apple Developer Forums 709289](https://developer.apple.com/forums/thread/709289).
- A LiveCode forum post from a macOS 15.6 user reports the link opening System Settings. Source: [LiveCode forum](https://www.forums.livecode.com/viewtopic.php?p=216240). This is a user report.
- **Not verified:** the link on macOS 14, 15 and 26 (Tahoe). Apple's Full Disk Access help article could not be fetched. Test the link on each OS in T09. Keep a fallback that opens System Settings at the top level.
- The user still has to add the app to the list and unlock with an admin password.

## Open items

1. Verify purgeable-space estimate on Berat's Mac (T08).
2. Confirm `tmutil listlocalsnapshots` syntax and sandbox behavior (T08).
3. Test the Full Disk Access link on macOS 14, 15 and 26 (T09).
4. Confirm symlink and file-type key names when writing the Scanner (T07).
