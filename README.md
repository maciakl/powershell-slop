# wc for PowerShell

A self-contained PowerShell port of the POSIX / GNU coreutils `wc` utility.
It prints newline, word, character, and byte counts for files or standard input.

- Single script (`Wc.ps1`) with no dependencies
- Works on Windows PowerShell 5.1 and PowerShell 7+
- Follows GNU `wc` options, output format, error messages, and exit codes

## Installation

Copy `Wc.ps1` to a directory on your `PATH`, or run it in place:

```powershell
.\Wc.ps1 --help
```

You can also add an alias in your PowerShell profile:

```powershell
Set-Alias wc C:\path\to\Wc.ps1
```

## Usage

```
Wc.ps1 [OPTION]... [FILE]...
Wc.ps1 [OPTION]... --files0-from=F
```

For each FILE, `wc` prints newline, word, and byte counts. If there is more than
one FILE, it also prints a total line. If there is no FILE, or FILE is `-`, it
reads standard input.

A word is a non-empty run of characters other than white space. Words are
separated by white space or by the start or end of the input.

### Options

| Option | Description |
| --- | --- |
| `-c`, `--bytes` | print the byte counts |
| `-m`, `--chars` | print the character counts |
| `-l`, `--lines` | print the newline counts |
| `-w`, `--words` | print the word counts |
| `-L`, `--max-line-length` | print the maximum display width |
| `--files0-from=F` | read input file names from F, separated by NUL characters (`-` reads the names from standard input) |
| `--total=WHEN` | when to print a total line: `auto`, `always`, `only`, or `never` |
| `--help` | display help and exit |
| `--version` | output version information and exit |

You can combine short options (for example `-lw`). Long options can be
shortened to any unique prefix, as with GNU `getopt_long`.

## Examples

```powershell
PS> .\Wc.ps1 notes.txt todo.txt
  12   87  514 notes.txt
   3   10   61 todo.txt
  15   97  575 total

PS> "hello world" | .\Wc.ps1 -w
2

PS> .\Wc.ps1 -l --total=only *.txt
15

PS> .\Wc.ps1 -l (Get-ChildItem -Recurse -Filter *.ps1).FullName
```

## PowerShell-specific behavior

- **Piped objects.** When you pipe PowerShell objects (for example
  `Get-Content x | .\Wc.ps1`), the script treats them as standard input. Each
  string counts as one line, encoded as UTF-8 and ended with LF. `[byte]` and
  `[byte[]]` items count as raw bytes.
- **Redirected input.** If you run `powershell -File Wc.ps1 < file`, the script
  reads standard input as raw bytes, the same way the native utility does.
- **`--` argument.** PowerShell removes a bare `--` before the script receives
  it. The script only honors `--` when PowerShell passes it through.
- **Wildcards.** Windows shells do not expand wildcards. If a FILE operand
  contains `*`, `?`, or `[...]` and no file has that exact name, the script
  expands it the way a POSIX shell would.
- **Locale.** Character decoding depends on `LC_ALL`, `LC_CTYPE`, or `LANG`.
  A value of `C` or `POSIX` selects single-byte mode. Any other value, or no
  value, selects UTF-8.

## Exit status

`0` on success. `1` if an error occurred, such as a file that could not be read.
