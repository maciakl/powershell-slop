# ClipboardMgr

A compact, colorized clipboard manager TUI in a single PowerShell file. Runs on the
Windows PowerShell 5.1 that ships with Windows 11, with no external dependencies.

```powershell
powershell -ExecutionPolicy Bypass -File .\ClipboardMgr.ps1
```

## What it shows

- **Current clipboard** (marked `●`), plus **Windows clipboard history** (Win+V) when enabled
  in *Settings > System > Clipboard*.
- Anything copied while the app is running is captured into a **session history** (marked `s`).
  This covers content Windows history doesn't keep, like copied files.
- **Text**: stats (chars/lines/words/line endings) and a guess at what it is (URL, path, JSON,
  GUID...), then an excerpt. Longer text says how many rows are hidden and points to view/edit.
- **Files**: name, folder, size, type, content type detected from the file header, version
  info, timestamps, attributes. Folders show an item count; missing files are flagged.
- **Images / binary**: dimensions, bit depth, size, the format detected from header bytes
  (PNG, JPEG, BMP/DIB, GIF, PDF, ZIP, EXE...), every clipboard format with its size, and a hex dump.

Content flagged as private by password managers (`ExcludeClipboardContentFromMonitorProcessing`,
`CanIncludeInClipboardHistory = 0`) is never recorded into the session history.

## Keys

| Key | Action |
| --- | --- |
| `↑` `↓` `j` `k` `PgUp` `PgDn` `Home` `End` `1`-`9` | move |
| `Enter` / `C` | copy the entry to the clipboard |
| `P` | paste the entry into the previously active window |
| `V` / `Space` | view the full entry (scrollable) |
| `E` | edit text in the built-in editor (`Ctrl+S`/`F2` saves, `Esc` cancels) |
| `N` | edit text in Notepad (or `$env:EDITOR`) |
| `Del` / `D` | delete the entry (from Windows history too; clears the clipboard if it's current) |
| `O` | open a file's location, a URL, or a path |
| `S` | save text, image or binary data to a file |
| `/` | filter (`Esc` clears) |
| `R` / `F5` | refresh |
| `X` | clear the clipboard and all history |
| `?` / `F1` | help |
| `Q` / `Esc` | quit |

Use `-SessionOnly` to skip Windows clipboard history.
