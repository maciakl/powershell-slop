# KeepAwake

A single PowerShell script that keeps your Windows PC awake and stops apps like
Teams or Slack from marking you as idle. It sits in the system tray as a small
coffee cup icon.

## Features

- **Prevents sleep and screen timeout.** Tells Windows the system and display
  are in use via `SetThreadExecutionState`.
- **Keeps you "active" in chat apps.** Every 60 seconds (configurable) it sends
  an F15 key press. No normal keyboard has F15 and practically every app ignores
  it, but it resets the system's "last input" timer that Teams, Slack, etc. use
  to detect idleness.
- **Respects manual lock and sleep.** When you lock the screen (Win+L), disconnect
  the session, or put the PC to sleep, the script pauses so the display turns
  off and the PC sleeps on its usual timeouts. It resumes when you unlock.
- **Tray icon.** A monochrome coffee cup that matches your light or dark
  taskbar and updates when you switch themes. Hover to see whether it is active
  or paused; right-click and choose **Exit** to stop.
- **Runs hidden.** It relaunches itself without a console window.
- **Single instance.** Starting it a second time does nothing.
- **No dependencies.** Uses the built-in Windows PowerShell 5.1 (`powershell.exe`).

## Usage

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\KeepAwake.ps1
```

You can also start it from PowerShell 7 (`pwsh`); it always relaunches itself
under Windows PowerShell 5.1.

### Parameters

| Parameter          | Default | Description                                                        |
| ------------------ | ------- | ------------------------------------------------------------------ |
| `-IntervalSeconds` | `60`    | Seconds between keep-awake ticks (F15 press). Minimum is 5.        |
| `-Hidden`          | off     | Internal: set by the script when it relaunches itself hidden.      |

Example with a 30-second interval:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\KeepAwake.ps1 -IntervalSeconds 30
```

### Start automatically at sign-in

1. Press **Win+R**, type `shell:startup`, and press Enter.
2. Create a shortcut in that folder with this target (adjust the path):

   ```
   powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\KeepAwake.ps1"
   ```

## Stopping

Right-click the coffee cup in the system tray and choose **Exit**. Normal power
behavior is restored when the script exits.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows)
