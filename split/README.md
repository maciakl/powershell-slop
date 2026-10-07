# split for PowerShell

A self-contained PowerShell port of the POSIX / GNU coreutils `split` utility.
It splits a file into pieces by line count, byte size, or number of chunks.

- Single script (`Split.ps1`) with no dependencies
- Works on Windows PowerShell 5.1 (the version that ships with Windows) and PowerShell 7+
- Follows GNU `split` options, file naming, error messages, and exit codes
- Uses POSIX/GNU option syntax (`-l 100`, `-b10M`, `--number=l/4`), not PowerShell syntax

## Installation

Copy `Split.ps1` to a directory on your `PATH`, or run it in place:

```powershell
.\Split.ps1 --help
```

To type `split` instead of `Split.ps1`, add an alias to your PowerShell profile:

```powershell
Set-Alias split C:\path\to\Split.ps1
```

If scripts are blocked on your machine, allow local scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If you downloaded the file, you may also need to run `Unblock-File .\Split.ps1`.

## Usage

```
Split.ps1 [OPTION]... [FILE [PREFIX]]
```

Writes pieces of FILE to `PREFIXaa`, `PREFIXab`, and so on. The default size is
1000 lines, and the default PREFIX is `x`. If there is no FILE, or FILE is `-`,
it reads standard input.

### Options

| Option | Description |
| --- | --- |
| `-a`, `--suffix-length=N` | use suffixes of length N (default 2) |
| `--additional-suffix=SUFFIX` | append SUFFIX to each file name (for example `.txt`) |
| `-b`, `--bytes=SIZE` | put SIZE bytes in each output file |
| `-C`, `--line-bytes=SIZE` | put at most SIZE bytes of whole records in each output file |
| `-d` | use numeric suffixes starting at 0, not alphabetic |
| `--numeric-suffixes[=FROM]` | same as `-d`, but start at FROM |
| `-x` | use hex suffixes starting at 0, not alphabetic |
| `--hex-suffixes[=FROM]` | same as `-x`, but start at FROM |
| `-e`, `--elide-empty-files` | don't create empty output files with `-n` |
| `--filter=COMMAND` | send each piece to the PowerShell COMMAND; the file name is in `$env:FILE` |
| `-l`, `--lines=NUMBER` | put NUMBER lines (records) in each output file |
| `-n`, `--number=CHUNKS` | create CHUNKS output files (see below) |
| `-t`, `--separator=SEP` | use the character SEP instead of newline as the record separator; `'\0'` means NUL |
| `-u`, `--unbuffered` | copy input to output immediately with `-n r/...` |
| `--verbose` | print a message before opening each output file |
| `--help` | display help and exit |
| `--version` | output version information and exit |

SIZE is an integer with an optional unit: `K`, `M`, `G`, `T`, `P`, `E`, `Z`,
`Y`, `R`, `Q` are powers of 1024, and `KB`, `MB`, ... are powers of 1000.
Binary prefixes work too: `KiB` = `K`, `MiB` = `M`, and so on.

CHUNKS can be:

| CHUNKS | Meaning |
| --- | --- |
| `N` | split into N files by size |
| `K/N` | write only the Kth of N chunks to standard output |
| `l/N` | split into N files without splitting lines (records) |
| `l/K/N` | write only the Kth of N chunks to standard output, without splitting lines |
| `r/N` | like `l/N`, but distribute lines round robin |
| `r/K/N` | like `r/N`, but write only the Kth chunk to standard output |

The obsolete form `-NUMBER` (for example `split -500 file`) is the same as
`-l NUMBER`. You can combine short options (for example `-del5`). Options can
come after the file names. Long options can be shortened to any unique prefix,
as with GNU `getopt_long`.

When the alphabetic suffixes run out, longer names are used automatically,
just as in GNU split (`xyz` is followed by `xzaaa`). This doesn't happen when
you set `-a`, use a start value, or use `-n`. In that case split stops with
`output file suffixes exhausted`.

## Examples

```powershell
# 1000-line pieces named xaa, xab, ...
.\Split.ps1 big.log

# 10 MB pieces named part-00.bin, part-01.bin, ...
.\Split.ps1 -b 10M -d --additional-suffix=.bin archive.zip part-

# exactly 4 files, without breaking any line
.\Split.ps1 -n l/4 data.csv chunk_

# print the 2nd of 3 chunks
.\Split.ps1 -n l/2/3 data.csv

# deal lines round robin into 5 files
.\Split.ps1 -n r/5 records.txt

# read from the pipeline
Get-Content words.txt | .\Split.ps1 -l 100 - words_

# compress each piece as it is written
.\Split.ps1 -b 100M --filter='$i=[Console]::OpenStandardInput(); $o=[IO.File]::Create("$env:FILE.gz"); $z=New-Object IO.Compression.GZipStream($o,[IO.Compression.CompressionMode]::Compress); $i.CopyTo($z); $z.Dispose()' big.iso

# put files back together
cmd /c copy /b "xa*" joined.bin
```

## PowerShell-specific behavior

- **Binary safe.** Files are read and written as raw bytes, so any file
  (text or binary) can be split and joined back without changes.
- **Piped objects.** When you pipe PowerShell objects (for example
  `Get-Content x | .\Split.ps1`), the script treats them as standard input.
  Each string becomes one line, encoded as UTF-8 and ended with LF. `[byte]`
  and `[byte[]]` items are copied as raw bytes. To split a file byte for byte,
  pass its name instead of piping it.
- **Redirected input.** If you run `powershell -File Split.ps1 < file`, the
  script reads standard input as raw bytes, the same way the native utility does.
- **Output to standard output** (`-n K/N`, `-n l/K/N`, `-n r/K/N`, and
  `--verbose` messages) goes to the PowerShell pipeline as lines of text, so
  you can pipe it into other cmdlets. When the script is the top-level command
  of a process whose standard output is redirected (for example
  `powershell -File Split.ps1 -n 2/3 f > out`), it writes raw bytes instead.
- **`--filter`** runs COMMAND in the same PowerShell that runs the script
  (`powershell.exe` or `pwsh`), not in `/bin/sh`. The output file name is in
  `$env:FILE`. The data arrives on the command's standard input: use `$input`
  to read it as lines of text, or `[Console]::OpenStandardInput()` for raw
  bytes. To use a `cmd.exe` command line instead, wrap it:
  `--filter='cmd /c "mytool > %FILE%.out"'`. If COMMAND exits with a non-zero
  status, split reports it and exits with that status. Output from the command
  goes straight to the console.
- **Input of unknown size.** `-n N` and `-n l/N` need the input size. If the
  input is standard input or the pipeline, it's first copied to a temporary
  file, which is deleted afterward.
- **`--` argument.** PowerShell removes a bare `--` before the script receives
  it. The script only honors `--` when PowerShell passes it through. To use
  it anyway, quote it: `.\Split.ps1 '--' -oddname`.
- **Wildcards.** Windows shells don't expand wildcards. If an operand
  contains `*`, `?`, or `[...]` and no file has that exact name, the script
  expands it the way a POSIX shell would.
- **Paths** are resolved against the current PowerShell location. The script
  refuses to overwrite its own input file (`'x' would overwrite input; aborting`).

## Exit status

`0` on success. `1` if an error occurred, such as an invalid option or a file
that could not be read or written. With `--filter`, if a command exits with a
non-zero status, split exits with that status.

## License

Split.ps1 is a from-scratch PowerShell implementation. Like GNU coreutils
`split`, which its behavior and help text are based on, it is licensed under
the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).
