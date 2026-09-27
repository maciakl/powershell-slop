# Windows User PATH TUI Editor

A standalone, keyboard-driven Text User Interface (TUI) tool for managing your Windows **User** `PATH` environment variable (`HKCU\Environment\Path`).

Written in pure PowerShell compatible with Windows PowerShell 5.1 (shipped out-of-the-box with Windows 11) and PowerShell 7+. Requires no external dependencies or modules.

---

## Features

- **User Scope Only**: Strictly modifies the current user's PATH environment variable in `HKCU\Environment`, never altering system-wide variables and requiring no administrator privileges.
- **Line-by-Line Path Display**: Every path entry is displayed on its own line with index numbers, status indicators, and full path values.
- **Color-Coded Change Tracking**:
  - `Green` / `[ADD]`: Newly added entries.
  - `Yellow` / `[MOD]`: Modified existing entries.
  - `Red` / `[DEL]`: Entries marked for deletion.
  - `Gray/White` / `[UNC]`: Unchanged entries.
- **Saved / Unsaved State Indicator**:
  - `[✔ SAVED / CURRENT]` (Green) when clean.
  - `[● UNSAVED CHANGES]` (Yellow/Red) when modifications have been made.
- **Interactive Action Buttons & Hotkeys**:
  - Focusable visual buttons at the bottom for saving, adding, editing, deleting, reloading, and exiting.
  - Full keyboard accessibility: navigate buttons using `Tab` and `Arrow` keys, or trigger actions with direct hotkeys (`S`, `A`, `E`, `D`, `R`, `X`).
- **Safe Save & Automatic Reload**:
  - Writes new PATH entries directly to the Windows User environment in the registry.
  - Broadcasts environment changes and updates the calling PowerShell session.
  - Displays a success notification banner upon saving: `✔ Content was saved! Reloaded User PATH (N active entries).`
  - Instantly reloads the variable from the registry and resets colors/status badges to reflect the clean saved state.
- **In-Place Modal Editors**:
  - Interactive text editor dialogs for adding and modifying entries with full line editing (arrows, Backspace, Delete, Home, End).
  - Clipboard paste support (`Ctrl+V`).
  - Real-time on-disk validation (`✔ Folder exists on disk` vs `⚠ Folder does not currently exist on disk`).
- **Unsaved Changes Guard**: Prompts confirmation before exiting or discarding unsaved changes.
- **Reordering Support**: Easily change PATH resolution priority by moving entries up or down (`Alt+Up` / `Alt+Down`).

---

## Quick Start

Run the script from Windows Terminal, PowerShell console, or Command Prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\PathEditor.ps1
```

Or from within an active PowerShell session:

```powershell
.\PathEditor.ps1
```

---

## Keyboard Controls

### List Navigation
| Key | Action |
| --- | --- |
| `↑` / `↓` | Move selection up / down |
| `PageUp` / `PageDown` | Scroll up / down by page |
| `Home` / `End` | Jump to first / last entry |
| `Enter` or `E` | Edit selected path entry |
| `A` or `Insert` | Add new path entry |
| `D` or `Delete` | Mark selected entry for deletion (or undelete) |
| `Alt+↑` / `Alt+↓` | Move selected entry up / down (reorder search priority) |
| `Tab` | Switch focus between the Path List and the Action Buttons |

### Button Navigation
| Key | Action |
| --- | --- |
| `←` / `→` | Cycle between buttons |
| `Enter` / `Space` | Activate focused button |
| `↑` / `Shift+Tab` | Return focus to the Path List |

### Global Shortcuts & Actions
| Shortcut | Action |
| --- | --- |
| `S` or `Ctrl+S` | **Save Changes**: Write to User PATH registry and reload |
| `A` | **Add Entry**: Open modal to add a new path |
| `E` | **Edit Entry**: Open modal to edit selected path |
| `D` | **Delete Entry**: Toggle delete on selected path |
| `R` | **Reload**: Discard unsaved changes and reload from registry |
| `X` / `Q` / `Esc` | **Exit**: Close the editor (prompts if unsaved changes exist) |

### Modal Dialog Controls (Add / Edit)
| Key | Action |
| --- | --- |
| `Typing` | Insert character at cursor |
| `←` / `→` | Move cursor inside text field |
| `Home` / `End` | Jump to start / end of path |
| `Backspace` / `Delete` | Delete character before / at cursor |
| `Ctrl+V` | Paste text from Windows clipboard |
| `Enter` | Confirm and apply path |
| `Escape` | Cancel and discard input |
