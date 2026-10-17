# ShowKey

A sleek terminal UI for Windows that shows everything Windows reports about each
key you press and release. It is a single PowerShell script with no dependencies.

```
 ◆ ShowKey  v0.1.0                                                       17 events
  ╭──────────────────────────────╮    ▼ PRESSED   #17  ·  19:20:49.484
  │                              │   Combo      Ctrl + Shift + A
  │       Ctrl + Shift + A       │   Repeat     ×3 (auto-repeating)  ·  record count 1
  │        KeyA  ·  0x41         │   Timing     held so far 412 ms  ·  +33 ms since last
  ╰──────────────────────────────╯   Keys down  ControlLeft  ShiftLeft  KeyA
  ╭─ Key ───────────────────────────────╮ ╭─ Character ──────────────────────────────╮
  │ Key         A                       │ │ Character   ␁   SOH (Ctrl+A)             │
  │ Layout name A                       │ │ Unicode     U+0001 · Control             │
  │ Virtual key 65 · 0x41               │ │ ASCII       1 · 0x01 · 0o1 · 0b00000001  │
  │ VK constant VK_A · [ConsoleKey]::A  │ │ UTF-8       01                           │
  │ Scan code   1E  (0x1E = 30)         │ │ UTF-16      0001                         │
  │ Physical    KeyA                    │ │ HTML        &#1;  &#x1;                  │
  │ Location    Standard                │ │ PowerShell  [char]0x0001                 │
  │ Category    Letter                  │ │ Key state   0x0038 LCTRL SHIFT NUM       │
  ╰─────────────────────────────────────╯ ╰──────────────────────────────────────────╯
  Shift  L  R   Ctrl  L  R   Alt  L  R   Win  L  R    Caps   Num   Scroll
  ╭─ History ──────────────────────────────────────────────────────────── 17 of 200 ─╮
  │ Time            Combo              VK   Scan  Physical      Char    Repeat       │
  │ 19:20:49.484 ▼  Ctrl+Shift+A       41   1E    KeyA          ␁ 01        ×3       │
  ...
```

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows) or PowerShell 7+
- An interactive console: Windows Terminal, the classic console host or the
  VS Code integrated terminal. The PowerShell ISE is not supported.
- A window of at least 80 x 24 characters

Nothing needs to be installed. The script compiles a small Win32 interop class
at startup with the built-in `Add-Type` cmdlet.

## Usage

```powershell
.\ShowKey.ps1                       # start the viewer
.\ShowKey.ps1 -NoKeyUp              # show key presses only
.\ShowKey.ps1 -HistorySize 50       # keep only the last 50 events
.\ShowKey.ps1 -NoColor              # no colors (NO_COLOR env var also works)
.\ShowKey.ps1 -Version              # print the version and exit
.\ShowKey.ps1 -Help                 # print the help and exit
Get-Help .\ShowKey.ps1 -Full        # same help through PowerShell
```

**Press Esc twice in a row to quit.** Every other key, including Ctrl+C, is
displayed rather than acted on.

If scripts are blocked on your machine, run it once with:

```powershell
powershell -ExecutionPolicy Bypass -File .\ShowKey.ps1
```

## Parameters

| Parameter      | Description                                                    |
| -------------- | -------------------------------------------------------------- |
| `-HistorySize` | Number of events kept in the history (10-10000, default 200).  |
| `-NoKeyUp`     | Ignore key releases.                                           |
| `-NoColor`     | Disable colors. Also disabled when `NO_COLOR` is set.          |
| `-Version`     | Print the version number and exit.                             |
| `-Help`        | Print the help message and exit.                               |

## What is shown

**Summary**

| Field      | Meaning                                                                      |
| ---------- | ---------------------------------------------------------------------------- |
| State      | `PRESSED` or `RELEASED`                                                      |
| Combo      | The modifiers plus the key, e.g. `Ctrl+Shift+A`                              |
| Repeat     | Auto-repeat count while a key is held, plus the record's own repeat count    |
| Timing     | How long the key has been held, and the time since the previous event        |
| Keys down  | All keys currently held (shows keyboard rollover)                            |

**Key panel**

| Field       | Meaning                                                                       |
| ----------- | ----------------------------------------------------------------------------- |
| Key         | A friendly name (`Left Shift`, `Num Home`, `F5`, `;`)                          |
| Layout name | The name the active keyboard layout gives the key (`GetKeyNameText`)          |
| Virtual key | The virtual-key code in decimal and hex                                       |
| VK constant | The `VK_*` constant from `winuser.h` and the .NET `[ConsoleKey]` value        |
| Scan code   | The hardware scan code, with the `E0` prefix for extended keys                |
| Physical    | The physical key in W3C `KeyboardEvent.code` style (`KeyA`, `ShiftRight`)     |
| Location    | `Standard`, `Left`, `Right` or `Numpad`                                       |
| Category    | Letter, Digit, Modifier, Lock, Function, Navigation, Numpad, Media, ...       |

**Character panel**

| Field      | Meaning                                                                       |
| ---------- | ----------------------------------------------------------------------------- |
| Character  | The produced glyph; control characters show their name and Ctrl+ combination  |
| Unicode    | Code point (`U+0041`) and Unicode category                                    |
| ASCII      | Decimal, hex, octal and binary (ASCII characters only)                        |
| UTF-8      | Encoded bytes                                                                 |
| UTF-16     | Code units                                                                    |
| HTML       | Named and numeric entities                                                    |
| PowerShell | How to write the character in PowerShell                                      |
| Key state  | The raw `dwControlKeyState` flags                                             |

The bottom of the screen shows left/right indicators for Shift, Ctrl, Alt and
Win, the Caps/Num/Scroll Lock states, and a history of recent events (newest
first; releases are dimmed and show how long the key was held).

## How it works

`[Console]::ReadKey()` only reports key presses and hides scan codes and
left/right modifiers. ShowKey instead switches the console into raw input mode
and reads `INPUT_RECORD`s with the Win32 `ReadConsoleInput` API. Each key event
carries the down/up state, repeat count, virtual-key code, scan code, character
and modifier flags. `GetAsyncKeyState` supplies left/right modifier and Win key
states, and `GetKeyNameText` / `MapVirtualKey` provide layout-specific names.

The UI is drawn with ANSI escape sequences on the alternate screen buffer, so
your scrollback is untouched. The console mode, output encoding and cursor are
restored when the script exits, even after an error.

## Limitations

- Windows or the terminal handle some combinations before the console sees them,
  for example Win+L, Alt+Tab, Ctrl+Alt+Del, Print Screen key-down, and Windows
  Terminal shortcuts such as Ctrl+Shift+T or Alt+Enter.
- Pressing Win on its own opens the Start menu, which takes focus away.
- Characters from the emoji panel or an IME arrive as `VK_PACKET` events with no
  scan code. Emoji arrive as two events (a UTF-16 surrogate pair) and are joined
  back together.
- Terminal cell widths for emoji and East Asian characters are estimated, so a
  few rare characters may shift a column by one cell.

## Changelog

### 0.1.0 - 2026-10-16

- First release.
- Raw key event capture via `ReadConsoleInput` (press and release events).
- Key, character and modifier panels, keycap display and event history.
- `-HistorySize`, `-NoKeyUp`, `-NoColor`, `-Version` and `-Help` parameters.
- Works on Windows PowerShell 5.1 and PowerShell 7+.
