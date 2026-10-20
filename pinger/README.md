# Pinger

A real-time, colourful terminal (TUI) ping monitor written in a single PowerShell script.

Pinger keeps pinging a list of IP addresses and hostnames. For each one it shows whether it is up or down, the last and average response time, packet loss, when it was last pinged, and a small trend graph. Everything updates live as results come in.

```
 ● PINGER v0.1.0  4 hosts  ▲ 2 up  ▼ 2 down  ‖ 0 paused          LIVE  every 5s · timeout 1000ms  20:25:54
  STATUS   LABEL        ADDRESS          RESOLVED IP      LAST      AVG   LOSS PINGED   EVERY/WAIT   TREND
▶ ● UP     Router       192.168.1.1      ·                3 ms   2.8 ms     0% 20:25:53 5s/1000ms    ▁▁▂▁▁▃▁▁
  ● UP     Google DNS   8.8.8.8          ·               14 ms  15.1 ms     0% 20:25:53 5s/1000ms    ▂▂▃▂▂▂▅▂
  ● DOWN   NAS          10.0.0.20        ·                fail        -   100% 20:25:54 10s/300ms    ××××××××
  ● UP     Web          example.com      93.184.216.34   92 ms  95.4 ms   1.2% 20:25:53 5s/1000ms    ▅▆▅×▅▆▇▅
```

## Requirements

- Windows 11 (or Windows 10 1809+). Nothing to install.
- Windows PowerShell 5.1 (built into Windows) **or** PowerShell 7+.
- A real console window: Windows Terminal (recommended) or the classic console host. PowerShell ISE is not supported.

## Running

```powershell
# Start with the saved list of addresses
.\Pinger.ps1

# Add some addresses at start-up
.\Pinger.ps1 8.8.8.8, 1.1.1.1, github.com

# Keep data somewhere else
.\Pinger.ps1 -DataPath D:\PingerData

# Version / help
.\Pinger.ps1 -Version
.\Pinger.ps1 -Help
Get-Help .\Pinger.ps1 -Full
```

If scripts are blocked on your machine, run it once with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Pinger.ps1
```

### Parameters

| Parameter   | Description |
|-------------|-------------|
| `-Address`  | IP addresses or hostnames to add at start-up (comma separated). Addresses already in the list are skipped. |
| `-DataPath` | Folder for `settings.json` and `history.json`. Default: `%APPDATA%\Pinger`. |
| `-Version`  | Print the version number and exit. |
| `-Help`     | Print usage information and exit. |

## Features

- **Add, edit and delete** addresses (IPv4, IPv6 or hostnames), each with an optional **label**.
- **Live status**: up / down / paused, last response time, average response time, packet loss, time of last ping and a trend graph (bar height = response time, red `×` = failed ping).
- **Hostnames show their resolved IP** next to the name. DNS failures are shown instead of crashing.
- **Ping interval and timeout** can be set globally and overridden per address. Overrides are shown in purple.
- **Pause** a single address (Space) or everything (P). **Ping now** (R) works even when paused.
- **History** is kept per address and saved to disk. The history screen shows:
  - total pings, received, lost, uptime %
  - average, fastest and slowest response time
  - number of outages, **average downtime**, longest outage, total downtime
  - the current state ("UP for 3m 20s") and a timeline graph
  - a scrollable log with **downtime highlighted in red**, plus "Outage started" / "Recovered after …" markers
- Adapts to the window size: less important columns are hidden on narrow windows.
- Errors such as unreachable hosts, unknown hostnames and network problems are recorded as failed pings, never crashes.

## Keys

### Main screen

| Key                  | Action |
|----------------------|--------|
| ↑ ↓ / J K            | Move selection |
| PgUp PgDn / Home End | Jump |
| Enter                | Open history for the selected address |
| A / Insert           | Add address |
| E / F2               | Edit address, label, interval and timeout |
| D / Delete           | Delete address (asks first) |
| Space                | Pause / resume the selected address |
| P                    | Pause / resume all pinging |
| R                    | Ping the selected address now |
| S                    | Global settings (interval, timeout, history size) |
| ? / H / F1           | Help |
| Q / Ctrl+C           | Quit (settings and history are saved) |

### History screen

| Key                        | Action |
|----------------------------|--------|
| ↑ ↓ / PgUp PgDn / Home End | Scroll the log |
| F                          | Toggle "failures only" |
| R                          | Ping now |
| Space                      | Pause / resume this address |
| C                          | Clear this address's history (asks first) |
| Esc / Backspace / Q        | Back to the list |

### Dialogs

Tab / Shift+Tab / ↑ ↓ move between fields, Enter saves, Esc cancels, Backspace deletes a character, Ctrl+U or Ctrl+Backspace clears the field. In the add/edit dialog, leave **Interval** or **Timeout** blank to use the global setting. Units are optional (`10`, `10s`, `500ms`).

## Settings and limits

| Setting      | Default | Range |
|--------------|---------|-------|
| Interval     | 5 s     | 0.5 – 3600 s |
| Timeout      | 1000 ms | 100 – 60000 ms |
| History size | 1000 results per address | 50 – 100000 |

## Data files

Stored in `%APPDATA%\Pinger` (or `-DataPath`):

- `settings.json`: global settings and the address list (readable and hand-editable).
- `history.json`: ping history, saved every 60 seconds, after changes, and on exit.

Files are written to a temporary file first and then swapped in, so a crash cannot leave a half-written file. If a file can't be read at start-up, a copy named `*.broken-<timestamp>` is kept and Pinger starts without it.

Changing an address in the edit dialog clears that address's history, because the old results belong to a different target.

## How it works

- Pings use `System.Net.NetworkInformation.Ping.SendPingAsync`. Hostname lookups use `System.Net.Dns.GetHostAddressesAsync`. Both are part of .NET, so nothing extra is needed.
- One loop polls the running ping tasks, reads keys, and redraws. There are no background threads or runspaces, so the UI never blocks on a slow host.
- The screen is drawn with ANSI/VT escape sequences (24-bit colour) in the alternate screen buffer, one write per frame to avoid flicker. VT processing is switched on for the classic console host and restored on exit.
- The script source is pure ASCII (box and graph characters are built from code points), so Windows PowerShell 5.1 reads it correctly whatever encoding the file is saved with.

## Changelog

### 0.1.0 (2026-10-19)

- First release.
- Live TUI address list with status, last/average response time, loss, last ping time and trend graph.
- Add / edit / delete addresses with optional labels; resolved IP shown for hostnames.
- Global and per-address ping interval and timeout.
- Pause per address and globally; ping-now.
- Persistent history with a history screen: summary (average response, average downtime, total pings, outages, uptime), timeline graph, and a scrollable log with downtime highlighted.
- `-Version`, `-Help`, `-Address` and `-DataPath` command-line parameters.
- Works on Windows PowerShell 5.1 and PowerShell 7+, with no dependencies.
