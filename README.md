# EnvEditor

A keyboard-driven terminal UI for viewing and editing Windows environment variables.
Single file, no dependencies; runs in the Windows PowerShell 5.1 that ships with Windows 11
(and PowerShell 7), in conhost or Windows Terminal.

```powershell
.\EnvEditor.ps1                     # edit your USER variables
# from an elevated (Run as Administrator) prompt:
.\EnvEditor.ps1                     # edit SYSTEM-wide variables (red banner, every change confirmed)
```

If scripts are blocked: `powershell -ExecutionPolicy Bypass -File .\EnvEditor.ps1`

## Features

- Colour-coded list of all variables with `LIST` / `PATH` / `TEXT` badges
- Create, edit, delete; deleting standard Windows variables (Path, TEMP, ComSpec, ...) warns
  and requires typing the variable name
- List editor for `;`-separated values (PATH, PATHEXT, PSModulePath, ...): one entry per line,
  add / insert / edit / delete / reorder, remove duplicates or missing paths, undo;
  delimiters are handled automatically
- Path sanity checks: entries that don't exist on disk are flagged in red (also live while typing)
- Registry types are preserved (`REG_EXPAND_SZ` values keep `%VAR%` references)
- Running programs are notified of changes (WM_SETTINGCHANGE)

Press `F1` inside the tool for all key bindings.
