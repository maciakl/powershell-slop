# Base64.ps1

A port of the GNU coreutils `base64` utility to PowerShell. It's one file
with no dependencies, and it runs on the Windows PowerShell 5.1 that ships
with Windows 11 as well as on PowerShell 7+.

```
Usage: Base64.ps1 [OPTION]... [FILE]
Base64 encode or decode FILE, or standard input, to standard output.

With no FILE, or when FILE is -, read standard input.

  -d, --decode          decode data
  -i, --ignore-garbage  when decoding, ignore non-alphabet characters
  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).
                          Use 0 to disable line wrapping
  -o, --output=FILE     write output to FILE instead of standard output
      --help            display this help and exit
      --version         output version information and exit
```

## Compatibility with GNU base64

- Options are parsed like GNU `getopt_long`. You can bundle short options
  (`-di`, `-w76`, `-dw 0`), abbreviate long options (`--dec`, `--wr=0`) and
  put options after the FILE operand.
- Error messages and exit codes are the same as on Linux, for example
  `invalid wrap size`, `extra operand`, `unrecognized option` and
  `invalid input`, each with exit status 1.
- Encoding wraps at 76 columns by default. Output ends with a newline,
  except with `-w 0`, which adds none. Empty input gives empty output.
- Decoding skips newlines. Without `-i`, any other non-alphabet character
  stops decoding with `invalid input`, after writing everything decoded up
  to that point. As in GNU, missing or misplaced padding is an error, and
  concatenated padded blocks (`QQ==QQ==`) are accepted.
- One deliberate difference: carriage returns are also skipped while
  decoding, so CRLF files from Windows decode without needing `-i`.
- Large files are streamed in chunks, not loaded into memory.

## Using it on Windows

PowerShell's object pipeline means some things work differently from a
POSIX shell.

**From cmd.exe, or with real stdout redirection**, the script writes raw
bytes, exactly like the Linux tool:

```bat
powershell -NoProfile -File Base64.ps1 picture.png > picture.b64
powershell -NoProfile -File Base64.ps1 -d picture.b64 > picture.png
```

**Inside a PowerShell session**, output goes to the pipeline as one string
per line, so assignment and piping work as expected:

```powershell
"hello" | .\Base64.ps1                  # aGVsbG8K
$b64 = .\Base64.ps1 -w 0 .\picture.png
"aGVsbG8K" | .\Base64.ps1 -d            # hello
```

When decoding in this mode, the decoded bytes are read as UTF-8 text. In
Windows PowerShell 5.1, `>` writes text, not bytes, so to get decoded
binary data byte-for-byte use `-o`:

```powershell
.\Base64.ps1 -d .\picture.b64 -o .\picture.png
```

**Pipeline input** works like piping to a native program:

- Strings are sent as UTF-8, with a newline after each one.
- Bytes and byte arrays are sent unchanged, for example
  `Get-Content -Encoding Byte -ReadCount 0 file` (5.1) or
  `Get-Content -AsByteStream file` (7+).

### Limitations of the Windows PowerShell 5.1 host

- With `powershell -File`, the host itself reads a redirected stdin and
  turns it into lines of text. Pass binary files as the FILE operand
  instead of redirecting them (`Base64.ps1 file.bin`, not
  `Base64.ps1 < file.bin`). Decoding base64 text from stdin works fine.
- PowerShell removes a bare `--` before the script sees it, and
  `powershell -File` rejects a bare `-` or `--` argument. To read stdin,
  leave out FILE. To name a file that starts with `-`, write it as
  `.\-name`.
