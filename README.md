# Hosts Editor

A keyboard-driven terminal editor for the Windows `hosts` file
(`%SystemRoot%\System32\drivers\etc\hosts`), packaged as one PowerShell script with no dependencies.

## Features

- **Elevates itself.** If you start it without Administrator rights, it shows a UAC prompt and relaunches. Started from Windows Terminal, it reopens in a new Windows Terminal tab rather than a plain console window.
- **Checks every line.** Each line is checked for a valid IPv4/IPv6 address and valid host names. Invalid lines are shown in red, and the status bar says what is wrong with the selected line.
- **Shows changes before you save.** New, modified and deleted lines are color-coded and marked until you save. You can undo the changes to any single line.
- **Adds entries from a paste.** Paste several lines at once with `Ctrl+V` or a terminal paste, and each line becomes its own entry.
- **Comments lines in and out.** One key disables or re-enables an entry.
- **Hides comments.** You can hide comments and blank lines to see only the active entries.
- **Saves safely.** Before writing, it copies the current file to `hosts.bak`. It writes UTF-8 without a BOM, keeps the read-only attribute if the file had it, then reloads the file from disk and shows a confirmation.
- **Asks before losing work.** Quitting or reloading with unsaved changes asks you to confirm first.
- Handles terminal resizing and long lines (with horizontal scrolling).

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10/11) or PowerShell 7+
- Administrator rights (requested automatically)
- A real console window. The PowerShell ISE is not supported, so the script relaunches itself in a console when started from there.

## Usage

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\HostsEditor.ps1
```

Run it from a file on disk; it cannot elevate itself when pasted into a session.

## Keys

### List view

| Key | Action |
| --- | --- |
| `↑` `↓` / `k` `j` | Move selection up / down |
| `←` `→` / `h` `l` | Scroll long lines left / right |
| `PgUp` `PgDn` `Home` `End` | Move by page / to first / to last line |
| `Enter` / `E` / `F2` | Edit the selected line |
| `A` / `Insert` | Add new entries below the selected line |
| `Del` / `D` | Mark the line for deletion (press again to restore) |
| `U` | Undo changes to the selected line |
| `C` / `#` | Comment / uncomment the selected line |
| `F` | Show / hide comments and blank lines |
| `S` | Save |
| `R` / `F5` | Reload from disk |
| `Q` / `Esc` / `Ctrl+C` | Quit |

### Line editor

| Key | Action |
| --- | --- |
| `Enter` | Accept |
| `Esc` / `Ctrl+C` | Cancel |
| `Ctrl+V` / `Shift+Insert` | Paste from the clipboard |
| `Ctrl+U` | Clear the line |
| `Tab` | Insert a tab character |
| `←` `→` `Home` `End` `Backspace` `Del` | Move the cursor / delete text |

## Colors

| Marker | Color | Meaning |
| --- | --- | --- |
| | White | Host entry |
| | Dark gray | Comment or blank line |
| `*` | Yellow | Modified |
| `+` | Green | New |
| `-` | Magenta | Marked for deletion |
| `!` | Red | Invalid |

The title bar turns from cyan to yellow while there are unsaved changes.

## Entry format

```
<IP address> <host name> [more host names] [# comment]
```

For example:

```
127.0.0.1    myapp.local api.myapp.local   # local dev
::1          myapp.local
```
