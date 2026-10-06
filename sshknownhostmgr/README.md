# SSH Known Hosts Manager

A terminal UI for reviewing and pruning entries in an OpenSSH `known_hosts` file, written in plain PowerShell.

It lists every host key with colorized host names (cyan) and IP addresses (yellow), the key type, and an abbreviated key. You can mark entries for deletion, filter the list, and undo marks. Nothing is written until you save.

## Features

- Shows host names, IP addresses, `[host]:port` entries, hashed hosts, and `@cert-authority` / `@revoked` markers
- Detail pane for the selected entry, with its SHA256 fingerprint (the same format `ssh-keygen -lf` prints)
- Live filter by host, IP, key type or comment
- Mark or unmark entries one at a time, or all the shown entries at once
- Keeps comments, blank lines and the file's line endings intact
- Writes a backup to `known_hosts.old` before saving, the same convention `ssh-keygen -R` uses
- Won't save if another program (for example `ssh`) changed the file after it was loaded
- Writes UTF-8 without a BOM, which is what OpenSSH expects
- Flags malformed lines so you can remove them

## Requirements

- Windows PowerShell 5.1 (included with Windows 10/11) or PowerShell 7+
- An interactive console such as Windows Terminal, `powershell.exe` or `pwsh.exe`. The PowerShell ISE and redirected input or output aren't supported.
- A window of at least 60 x 12 characters

No external modules are required.

## Usage

```powershell
# Manage the default file, ~\.ssh\known_hosts
.\SSH-KnownHostsManager.ps1

# Manage a different file
.\SSH-KnownHostsManager.ps1 -Path C:\temp\known_hosts
```

If your execution policy blocks the script, you can run it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\SSH-KnownHostsManager.ps1
```

## Keys

| Key                              | Action                                                   |
| -------------------------------- | -------------------------------------------------------- |
| Up / Down, PgUp / PgDn, Home / End | Move (`j` / `k` also work)                             |
| Space, Delete, `D`               | Mark or unmark the selected entry                        |
| `A`                              | Mark all shown entries (press again to unmark them)      |
| `U`                              | Undo all marks                                           |
| `/`                              | Filter by host, IP, key type or comment                  |
| `R`, F5                          | Reload the file from disk                                |
| `S`, Ctrl+S                      | Save (delete the marked entries)                         |
| `Q`, Esc, Ctrl+C                 | Quit (Esc clears an active filter first)                 |

In filter mode, type to narrow the list, press Enter to keep the filter, or press Esc to cancel it.

You're asked to confirm before saving, before reloading when entries are marked, and before quitting with unsaved marks.

## Restoring a backup

Each save copies the previous file to `known_hosts.old` next to it. To undo the last save:

```powershell
Copy-Item ~\.ssh\known_hosts.old ~\.ssh\known_hosts
```
