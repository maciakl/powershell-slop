# Ln.ps1

A port of the POSIX `ln` command (modeled on GNU coreutils `ln`) to PowerShell.
It creates native Windows hard links and symbolic links using the familiar
`ln` command-line syntax.

- One file: `Ln.ps1`
- No external dependencies. It uses only PowerShell and the Win32 API. Native
  calls are compiled in-process with the built-in `Add-Type`.
- Runs on **Windows PowerShell 5.1** (included with Windows 11) and on
  **PowerShell 7.x**.
- Windows only. On Linux and macOS, use the system `ln`.

## Installation

1. Copy `Ln.ps1` to a directory on your `PATH`, or to any directory you like.
2. If you downloaded the file, unblock it so the execution policy allows it to run:

   ```powershell
   Unblock-File .\Ln.ps1
   ```

3. Optional: add an alias to your profile (`notepad $PROFILE`):

   ```powershell
   Set-Alias ln C:\path\to\Ln.ps1
   ```

### Symbolic link privileges

By default, Windows only lets administrators create symbolic links. To create
them from a normal (non-elevated) prompt, turn on **Developer Mode**
(*Settings → System → For developers → Developer Mode*). `Ln.ps1` requests
unprivileged creation automatically, so Developer Mode is all you need. Hard
links do not need any special privilege.

## Usage

```
ln [OPTION]... [-T] TARGET LINK_NAME
ln [OPTION]... TARGET
ln [OPTION]... TARGET... DIRECTORY
ln [OPTION]... -t DIRECTORY TARGET...
```

1. The first form creates a link to TARGET named LINK_NAME.
2. The second form creates a link to TARGET in the current directory.
3. The third and fourth forms create links to each TARGET inside DIRECTORY.

`ln` creates hard links by default and symbolic links with `--symbolic`.

| Option | Description |
| --- | --- |
| `--backup[=CONTROL]` | Make a backup of each existing destination file |
| `-b` | Like `--backup`, but does not accept an argument |
| `-d`, `-F`, `--directory` | Hard link directories. Accepted, but always fails on Windows (see below) |
| `-f`, `--force` | Remove existing destination files |
| `-i`, `--interactive` | Prompt before removing destinations |
| `-L`, `--logical` | Dereference TARGETs that are symbolic links |
| `-n`, `--no-dereference` | Treat LINK_NAME as a normal file if it is a symbolic link to a directory |
| `-P`, `--physical` | Make hard links directly to symbolic links (default) |
| `-r`, `--relative` | With `-s`, create links relative to the link location |
| `-s`, `--symbolic` | Make symbolic links instead of hard links |
| `-S`, `--suffix=SUFFIX` | Override the usual backup suffix |
| `-t`, `--target-directory=DIRECTORY` | Create the links in DIRECTORY |
| `-T`, `--no-target-directory` | Always treat LINK_NAME as a normal file |
| `-v`, `--verbose` | Print the name of each linked file |
| `--help` | Display help and exit |
| `--version` | Display version information and exit |

The command line is parsed the way GNU `getopt_long` parses it:

- Short options can be combined: `-sfv`.
- Option arguments can be attached (`-tDIR`, `--suffix=.bak`) or separate (`-t DIR`).
- Long options can be shortened to any unambiguous prefix: `--sym`, `--verb`.
- Options can appear after operands.

Backups follow GNU rules:

- `CONTROL` is one of `none`/`off`, `numbered`/`t`, `existing`/`nil` or
  `simple`/`never`. It can also come from the `VERSION_CONTROL` environment
  variable. The default is `existing`.
- The suffix comes from `-S` or `SIMPLE_BACKUP_SUFFIX`. The default is `~`.

Exit status: `0` on success, `1` if any link could not be created or the
command line was invalid.

### Examples

```powershell
# Hard link
.\Ln.ps1 data.csv data-copy.csv

# Symbolic link to a file, verbose
.\Ln.ps1 -sv C:\tools\app\app.exe app.exe

# Symbolic link to a directory, stored as a relative path
.\Ln.ps1 -sr ..\shared\assets assets

# Replace an existing link that points to a directory
.\Ln.ps1 -sfn C:\sdk\v2 current

# Link several files into a directory
.\Ln.ps1 -s (Get-ChildItem ..\src\*.ps1) .\bin

# Back up the destination before replacing it
.\Ln.ps1 -sv --backup=numbered new.conf app.conf
```

## Differences from POSIX/GNU ln

The Windows file system model differs from Unix in several ways that make
some `ln` behaviour impossible to reproduce. This port does not emulate those
features. They are listed below.

### Impossible on Windows

- **Hard links to directories (`-d`, `-F`, `--directory`).** NTFS does not
  allow hard links to directories, even for administrators. The options are
  accepted for compatibility, but hard linking a directory always fails with
  `Operation not permitted`.
- **Hard links to directory symbolic links or junctions with `-P`.** On Unix, a
  symbolic link is its own file type and can be hard linked. On Windows, a
  directory symbolic link is a directory with a reparse point, so the
  restriction above applies. Hard links to *file* symbolic links do work: the
  new name is another symbolic link that shares the same file record.
- **Untyped symbolic links.** A Windows symbolic link is permanently either a
  *file* link or a *directory* link. A link of the wrong type cannot be
  followed. `Ln.ps1` picks the type when it creates the link:
  - It resolves TARGET relative to the link's directory, exactly as the link
    will be resolved later. If TARGET exists, the link gets TARGET's type.
  - If TARGET does not exist (a dangling link), the link is a file link, unless
    TARGET ends in `\` or `/`. In that case it is a directory link.

  If TARGET is later replaced by an object of the other type, you must recreate
  the link. On Unix the same link would keep working.
- **Symbolic links need a privilege.** Unix lets any user create symbolic
  links. Windows requires `SeCreateSymbolicLinkPrivilege` (held by
  administrators) or Developer Mode.
- **Symbolic link text is not arbitrary.** On Unix, a symbolic link can hold
  any byte string. Windows link targets must be valid Windows paths, so `/`
  is converted to `\`. Trailing separators are also removed, because Windows
  cannot always follow a target that ends in one.
- **Hard links need a file system that supports them.** Hard links work on
  NTFS and ReFS. FAT32 and exFAT do not support them, so the link fails with
  `Operation not supported`. Both hard links and symbolic links may fail on
  network shares, depending on the server. Like on Unix, hard links cannot
  cross volumes (`Invalid cross-device link`).
- **Link count limit.** NTFS allows at most 1024 hard links per file. When a
  file reaches the limit, the link fails with `Too many links`.
- **Remote symbolic links.** Whether Windows follows a link that points to a
  remote location depends on the system's `fsutil behavior set
  SymlinkEvaluation` policy. `ln` cannot change this policy.

### Behaviour that differs by design

- **`--relative` across drives.** Two paths on different drives or shares have
  no relative path between them. In that case the link stores the absolute
  path. The relative path is also computed from the path text: unlike GNU
  `ln`, which canonicalizes both paths, this port does not resolve symbolic
  links inside them first.
- **Junctions.** Junctions are not a POSIX concept, so this port never creates
  them. It does recognise existing junctions and treats them like directory
  symbolic links for `-n`, `-L`, `-P`, and `-f`.
- **Non-atomic `--force`.** GNU `ln -f` creates the new link under a temporary
  name and renames it over the destination. This port removes the destination
  and then creates the link. If creation fails after the removal, the
  destination is gone. (When a backup was made, the backup is restored.)
- **Read-only files.** On Unix, a file's own permission bits do not affect
  `unlink`. To match, `-f` removes destinations even when they have the
  Windows read-only attribute.
- **Case-insensitive names.** Comparisons between paths, such as the
  "will not overwrite just-created" check and the "are the same file" check,
  ignore case, like the default NTFS behaviour.
- **`POSIXLY_CORRECT` is ignored.** Options are always permuted, and `-P`
  remains the default.

### PowerShell command-line notes

- **`--` must be quoted.** PowerShell removes a bare `--` before the script
  receives its arguments. To end option parsing, write `'--'`:

  ```powershell
  .\Ln.ps1 -s '--' -strange-name link
  ```

- **No wildcard expansion.** Unix shells expand `*.txt` before `ln` runs.
  PowerShell does not, so `Ln.ps1` treats every name literally (`[` and `]`
  are common in Windows file names). Pass objects instead, for example
  `(Get-ChildItem *.txt)` or `(Resolve-Path *.txt)`. These are always treated
  as operands, never as options.
- **`-opt:value` syntax.** PowerShell splits `-t:dir` into `-t:` and `dir`.
  `Ln.ps1` accepts this form and treats it the same as `-t dir`.
- **`-?`** shows PowerShell's help for the script, not `ln --help`.
- **Current directory.** Relative paths are resolved against PowerShell's
  current file system location (`Get-Location`), not the process working
  directory. The two can differ in PowerShell.

## License

Copyright (C) 2026 Luke Maciak

GNU coreutils `ln` is licensed under the GNU General Public License, and so is
this port. This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See [LICENSE](LICENSE) for the full text.
