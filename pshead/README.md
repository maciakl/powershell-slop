# PSHead.ps1

A port of the POSIX/GNU `head` utility to PowerShell, in a single file with no
external dependencies.

Runs on:

- Windows PowerShell 5.1 (ships with Windows 11)
- PowerShell 7.x

## Usage

```powershell
.\PSHead.ps1 [OPTION]... [FILE]...
```

Prints the first 10 lines of each FILE. With more than one FILE, each is
preceded by a `==> name <==` header. With no FILE, or when FILE is `-`, reads
standard input: the PowerShell pipeline, or the console input stream when
nothing is piped in.

| Option | Description |
| --- | --- |
| `-n`, `--lines=[-]NUM` | Print the first NUM lines instead of the first 10. With a leading `-`, print all but the last NUM lines. |
| `-c`, `--bytes=[-]NUM` | Print the first NUM bytes. With a leading `-`, print all but the last NUM bytes. |
| `-q`, `--quiet`, `--silent` | Never print file name headers. |
| `-v`, `--verbose` | Always print file name headers. |
| `-z`, `--zero-terminated` | Use NUL as the line delimiter instead of newline. |
| `-NUM` | Same as `-n NUM` (obsolete form). |
| `--help` | Display help and exit. |
| `--version` | Output version information and exit. |

NUM may have a multiplier suffix: `b` 512, `kB` 1000, `K` 1024, `MB`
1000×1000, `M` 1024×1024, and so on for `G`, `T`, `P` and `E`. Binary forms
also work: `KiB` = `K`, `MiB` = `M`, and so on.

Options follow GNU conventions:

- Short options can be bundled: `-qn5`.
- Long options can be abbreviated: `--li=5`.
- Options can appear after file names.

Exit status is 0 on success and 1 if any error occurred. `Get-Help .\PSHead.ps1`
shows the built-in help.

## Recommended: alias it to `head`

The script is named `PSHead.ps1`, but it's meant to be typed as `head`. Add an
alias to your PowerShell profile (`notepad $PROFILE`):

```powershell
Set-Alias head C:\path\to\PSHead.ps1
```

Then `head -n 5 file.txt` works as it does on Linux. Skip this on PowerShell 7
for Linux and macOS, which already have a native `head` that the alias would
shadow.

## Examples

```powershell
.\PSHead.ps1 file.txt                  # first 10 lines
.\PSHead.ps1 -n 5 a.txt b.txt          # first 5 lines of each, with headers
.\PSHead.ps1 -n -2 file.txt            # all but the last 2 lines
.\PSHead.ps1 -c 1K file.txt            # first 1024 bytes
.\PSHead.ps1 -3 *.log                  # first 3 lines of every .log file
Get-Content log.txt | .\PSHead.ps1 -5  # first 5 lines of piped text
Get-Process | .\PSHead.ps1 -3          # first 3 process objects
```

From `cmd.exe` or another shell:

```bat
type file.txt | powershell -NoProfile -File PSHead.ps1 -n 5
```

## Differences from GNU head

- **Output is one line per pipeline object**, with line terminators removed, so
  it composes with other cmdlets (`.\PSHead.ps1 f.txt | Select-String x`). When
  displayed, a final line without a trailing newline (common with `-c`) still
  ends with one.
- **Piped objects that aren't strings pass through unchanged** in line mode.
  Piped strings are split into lines, so `Get-Content -Raw` output works.
- **Encoding:** files are decoded as UTF-8 unless they start with a UTF-8,
  UTF-16 or UTF-32 byte order mark. CRLF line endings are handled.
- **Wildcards** in file names (`*.txt`) are expanded by the script, since
  Windows shells don't expand them. A file whose literal name contains
  wildcard characters takes precedence.

## PowerShell quirks

- PowerShell removes a bare `--` before the script sees it. Quote it
  (`'--'`) to end option processing.
- PowerShell converts an unquoted `5kb`, `5mb`, `5gb`, `5tb` or `5pb` to a
  1024-based number before the script sees it. Use `5K` or quote the value
  (`'5kB'`) instead.
