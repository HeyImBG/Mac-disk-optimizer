# VM and security paths: where the big files live

Researched 2026-11-03 for task T23 (web search; some vendor pages could only be read as search summaries). Rows marked **unverified** rest on community posts or third-party guides. Check them on Berat's Mac before T26 uses them. A VM is a whole computer: nothing here is `safe`.

## Paths

| Path | What it holds | What rebuilds it | Close first | Risk | Source |
|---|---|---|---|---|---|
| `~/Library/Containers/com.utmapp.UTM/Data/Documents/*.utm` | UTM virtual machines (each `.utm` is a bundle with its disk images) | Not rebuildable. The guest's files and installed OS live inside | UTM | caution | UTM [v2.0.20 release notes](https://newreleases.io/project/github/utmapp/UTM/release/v2.0.20) (since 2.0.17 the sandboxed UTM keeps VMs here; before that `~/Documents`). Release notes mirrored by a third party, so **unverified** against UTM's own docs. VMs can also be stored elsewhere, for example on an external drive ([UTM discussion #3355](https://github.kxpsado.workers.dev/utmapp/UTM/discussions/3355)) |
| `~/Parallels/*.pvm` | Parallels Desktop virtual machines | Not rebuildable | Parallels Desktop and the VM | caution | [Parallels user guide, set where virtual machines are stored](https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/advanced-topics/working-with-virtual-machines/about-virtual-machines/set-where-virtual-machines-are-stored) (default `~/Parallels`; the folder is changeable in preferences, and existing VMs stay where they were) |
| `~/Library/Group Containers/4C6364ACTX.com.parallels.desktop.appstore/Shared/Parallels/` | VMs of the Mac App Store edition of Parallels | Not rebuildable | Parallels Desktop and the VM | caution | [Parallels KB 117333](https://kb.parallels.com/117333) as quoted in search results. **Unverified**: the team id in the quoted path was copied from a search summary, so check it on the Mac |
| `~/Documents/Parallels/*.pvm` | VMs from Parallels Desktop 11 and earlier | Not rebuildable | Parallels Desktop and the VM | caution | Old default per the same Parallels forum and KB results. **Unverified**; probably absent on a recent Mac |
| `~/Virtual Machines.localized/*.vmwarevm` or `~/Documents/Virtual Machines.localized/*.vmwarevm` | VMware Fusion VMs (each `.vmwarevm` is a bundle) | Not rebuildable | VMware Fusion and the VM | caution | [Broadcom KB 344570, locating the virtual machine bundle](https://knowledge.broadcom.com/external/article/344570/) (folder name may carry `.localized`). [Fusion 11 docs](https://docs.vmware.com/en/VMware-Fusion/11/com.vmware.fusion.using.doc/GUID-ECE9C823-8EE2-44AB-A72B-3C37B76F5193.html): new Fusion 11+ installs use `~/Virtual Machines`, older and upgraded installs use `~/Documents/Virtual Machines` |
| `~/Library/Application Support/VMware Fusion/Virtual Machines/` | Fusion Boot Camp VMs | Not rebuildable | VMware Fusion | caution | **Unverified**. One [VMware Communities answer](https://communities.vmware.com/t5/VMware-Fusion-Discussions/How-to-change-default-location-of-Virtual-Machines/m-p/1323681) as summarized in search results |
| `~/VirtualBox VMs/<vm>/` | VirtualBox machine folders: settings and disk images | Not rebuildable | VirtualBox and the VM | caution | [Oracle VirtualBox docs, where VirtualBox stores its files](https://docs.oracle.com/en/virtualization/virtualbox/6.0/admin/vboxconfigdata.html) (default machine folder in the home directory; global config in `~/Library/VirtualBox`). Changeable with `VBoxManage setproperty machinefolder` |
| `*.iso` (anywhere, mostly `~/Downloads`) | Installer images for operating systems | Download again from the vendor, if the vendor still hosts that version | None, unless a VM has it mounted | review | **Unverified** as a rule (no vendor page; it is a file-type convention). Offer by extension and size only, and never an `.iso` inside a VM bundle |
| `rockyou.txt` and `rockyou.txt.gz` | A common password wordlist. Kali ships it gzipped at about 53 MB, about 134 to 140 MB extracted | Download again (Kali `wordlists` package) | None | review | Kali package listing and [guides](https://www.charlesreid1.com/wiki/Kali/Wordlists), search summary only, so sizes are approximate |
| `SecLists` folder (for example a git clone, or `/usr/share/seclists` in Kali) | A large collection of wordlists and payloads, about 1.8 GB installed | `git clone` again | None | review | Search summary of the Kali package listing, **unverified**. Berat's own copy may differ or hold his edits |

## Rules that follow from the rows

- Every VM bundle is `caution` and is never pre-selected. A VM cannot be rebuilt, and the user may have unsaved work or a snapshot inside.
- A VM's folder or bundle is not a file to trash while the VM app is open. Even closed, T26 should only show size, the VM name, and Reveal in Finder, then let the user delete from the VM app (UTM, Parallels, Fusion, VirtualBox) so the app's library stays consistent.
- `~/Library/Containers/` (UTM) and `~/Library/Group Containers/` (Parallels App Store edition) are protected by `CleanupEngine`, as is `~/Library/Application Support` (Fusion Boot Camp). Only the home-folder VM locations (`~/Parallels`, `~/Virtual Machines`, `~/VirtualBox VMs`) could ever be offered for the Trash, and that needs its own safety review (T29) before it is enabled.
- Detect VM bundles by extension (`.utm`, `.pvm`, `.vmwarevm`) as well as by default folder, because every product lets the user choose another location.
- ISOs and wordlists are the only `review` items here. Offer them by size and type, with the reason "you can download this again". Never claim a hash or a vendor URL.

## Gaps

- UTM's own documentation and the Parallels KB page were not read directly; the paths come from search summaries.
- Not researched: Tart, Lima, OrbStack, Docker (see `dev.md`), QEMU raw images, Apple's Virtualization framework bundles outside UTM.
- No source for where Berat keeps ISOs and wordlists. Ask him, or list `~/Downloads` and `~` on his Mac before T26.
- Before T26, list each default folder on Berat's Mac and mark rows verified or wrong.
