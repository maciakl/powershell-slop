# Tail.ps1

A port of the POSIX `tail` utility to PowerShell. It prints the last part of files and can follow them as they grow.

- One self-contained file, no external dependencies or modules.
- Runs on Windows PowerShell 5.1 (the version that ships with Windows 11) and on PowerShell 7+.
- Uses POSIX/GNU option syntax (`-n 20`, `-fn5`, `--lines=+3`, `-F`), not PowerShell syntax.

## Installation

Copy `Tail.ps1` somewhere on your `PATH`, or call it by path. To type `tail` instead of `Tail.ps1`, add an alias to your profile:

```powershell
Set-Alias tail C:\path\to\Tail.ps1
```

If scripts are blocked on your machine, allow local scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If you downloaded the file, you may also need to run `Unblock-File .\Tail.ps1`.

## Usage

```
tail [OPTION]... [FILE]...
```

Prints the last 10 lines of each FILE. With more than one FILE, each is preceded by a header with the file name. With no FILE, or when FILE is `-`, reads standard input.

| Option | Description |
| --- | --- |
| `-c`, `--bytes=[+]NUM` | Output the last NUM bytes; with `+NUM`, start at byte NUM of each file |
| `-n`, `--lines=[+]NUM` | Output the last NUM lines (default 10); with `+NUM`, start at line NUM |
| `-f`, `--follow[={name\|descriptor}]` | Output appended data as the file grows (default: `descriptor`) |
| `-F` | Same as `--follow=name --retry` |
| `--retry` | Keep trying to open a file that is inaccessible |
| `-s`, `--sleep-interval=N` | With `-f`, poll about every N seconds (default 1.0) |
| `--pid=PID` | With `-f`, exit after process PID dies |
| `-q`, `--quiet`, `--silent` | Never output file name headers |
| `-v`, `--verbose` | Always output file name headers |
| `-z`, `--zero-terminated` | Line delimiter is NUL, not newline |
| `--encoding=NAME` | Encoding for files without a byte order mark (default `utf-8`; e.g. `ansi`, `oem`, `1252`, `utf-16`) |
| `--help` | Show help and exit |
| `--version` | Show version and exit |

NUM may have a multiplier suffix: `b` 512, `kB` 1000, `K` 1024, `MB` 1000², `M` 1024², and so on for `G`, `T`, `P`, `E`. Binary prefixes work too: `KiB` = `K`, `MiB` = `M`, and so on.

The obsolete forms `tail -NUM[bcl][f]` and `tail +NUM[bcl][f]` are accepted as the first argument. Short options can be combined (`-fqn20`). Options may come after file names. Long options may be abbreviated when unambiguous (`--li 5`).

`Get-Help .\Tail.ps1 -Full` shows the same documentation.

## Examples

```powershell
tail app.log                         # last 10 lines
tail -n 50 app.log                   # last 50 lines
tail -n +100 app.log                 # everything from line 100 on
tail -c 1K data.bin                  # last 1024 bytes
tail -F C:\logs\service.log          # follow by name across rotation
tail -f -s 0.2 a.log b.log           # follow two files, poll every 200 ms
tail -f --pid=1234 build.log         # stop following when process 1234 exits
tail *.log                           # wildcards are expanded by tail itself
Get-Content big.txt | tail -n 3      # read from the pipeline
Get-ChildItem | tail -n 2            # objects pass through unchanged
tail -n 1000 app.log | Select-String ERROR
```

## Behavior notes

- **Output is PowerShell strings.** Each line goes to the pipeline as a string, without its line ending, so it can be piped into other cmdlets. As a result, a final line with no trailing newline is still printed as a full line.
- **Pipeline input:** strings are split into lines. Non-string objects count as one line each and pass through unchanged, so `Get-ChildItem | tail -n 2` returns `FileInfo` objects.
- **Large files** are read backwards from the end in blocks, so tailing a huge file is fast.
- **Encodings:** UTF-8, UTF-16 LE/BE and UTF-32 LE/BE are detected from the byte order mark. Files without one are read as UTF-8 unless `--encoding` is given. Windows line endings (CRLF) are handled; the `\r` is removed.
- **Paths:** relative paths are resolved against the current PowerShell location. Wildcards (`*`, `?`) are expanded when no file matches the name literally, because Windows shells do not expand them.
- **Files are opened with full sharing,** so other programs can keep writing to, rotating, or deleting them.
- **Follow mode** checks files at the `-s` interval.
  - `-f` (descriptor) keeps the file open and follows it even if it is renamed.
  - `-F` (name) opens the file for each check and reports when it is truncated, replaced, removed, or recreated. Replacement is detected by file ID on Windows.
  - Use `-F` when the writing program won't share the file. `Set-Content`, `Clear-Content` and Windows PowerShell's `Add-Content` all fail on a file that another program has open.
- **Partial lines while following:** an unfinished final line is printed once it has not grown for one interval. If more text is added to that line later, it appears as a new line.
- **Errors** go to stderr in GNU format (`tail: cannot open 'x' for reading: No such file or directory`). The exit status is 1 if any file could not be read.

### Differences from POSIX tail

- PowerShell consumes a bare `--` before the script sees it. To end option processing, quote it: `tail '--' -strange-name`.
- PowerShell re-encodes all text it writes. When output is redirected, non-ASCII characters are written in the console's output encoding (`[Console]::OutputEncoding`), not copied byte for byte.

## License

Tail.ps1 is a from-scratch PowerShell implementation. Like GNU coreutils `tail`, which its help text is based on, it is licensed under the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).
