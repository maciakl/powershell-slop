# SpaceFinder

An interactive console explorer that finds the largest folders on a Windows drive.

SpaceFinder scans a folder in the background on a pool of native worker threads and
lists its subfolders from largest to smallest, with proportional data bars. The list
updates live while the scan runs, so you can start navigating right away.

Works on Windows PowerShell 5.1 and PowerShell 7+. Single script, no external dependencies.

## Usage

```powershell
.\SpaceFinder.ps1                  # analyze the current folder
.\SpaceFinder.ps1 -Path C:\Users   # analyze a specific folder
```

It needs an interactive console: it does not run in the PowerShell ISE or with
redirected input/output. Windows Terminal is recommended.

## Keys

| Key                              | Action                              |
| -------------------------------- | ----------------------------------- |
| Up/Down, PgUp/PgDn, Home/End     | move the selection (`j`/`k` also work) |
| Enter, Right                     | open the selected folder (`l`)      |
| Backspace, Left                  | go to the parent folder (`h`)       |
| O                                | open the selected folder in Explorer |
| R                                | rescan the current folder           |
| Q, Esc, Ctrl+C                   | quit                                |

Going above the folder you started from scans the parent folder, reusing the
results already collected for the current one.

## What the screen shows

- **Header:** the current path, its total size, folder and file counts, and scan progress.
- **List:** each subfolder's rank, size, share of the current folder, and a bar relative
  to the largest subfolder. The five largest are highlighted.
- **Markers:** a spinner means the folder is still being scanned, `!` means access was
  denied, and `~` marks a junction or symbolic link.
- **Info line:** the size of the files sitting directly in the current folder.

## Cloud storage folders

OneDrive, Dropbox, iCloud and other providers built on the Windows Cloud Files API are
scanned like normal folders. For these folders SpaceFinder splits the size into:

- **on disk:** files that are downloaded and take up local space
- **online-only:** files that exist only in the cloud (shown by their full size, but
  using almost no local space)

The breakdown appears in the totals row, next to each cloud folder's name, and on the
info line when a cloud folder is selected. In the bar, the online-only part is dimmed.
Folders are sorted by the combined total.

## Links and junctions

Junctions and symbolic links are listed but not followed, so their targets aren't
counted twice (for example `Application Data` or `My Documents` inside a user profile).

## How it works

The scanner is a small C# class embedded in the script. It enumerates folders with
`FindFirstFileEx` (large fetch, basic info) and reads file sizes straight from the
result buffer, so it scans hundreds of thousands of folders in a few seconds.

It's compiled on first run and cached in `%TEMP%` as `SpaceFinder_<hash>.dll`. The hash
covers the source and the PowerShell version, so editing the script automatically
produces and loads a fresh build, even in a session that ran an older version.

Sizes are logical file sizes. Compression, sparse files and cluster slack are not taken
into account, so the numbers can differ slightly from "Size on disk" in Explorer.
