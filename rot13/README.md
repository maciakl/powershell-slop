# Rot13

A single-file PowerShell implementation of the [ROT13](https://en.wikipedia.org/wiki/ROT13) cipher.

ROT13 rotates each letter 13 places through the alphabet (`A` → `N`, `n` → `a`). Applying it twice restores the original text, so the same command both encodes and decodes.

## Requirements

- Windows PowerShell 5.1 (included with Windows 10/11) or PowerShell 7+
- No external modules or dependencies

## Usage

```
Rot13.ps1 [-Path] <file>
<command> | Rot13.ps1
Rot13.ps1 -Help
```

| Argument / Option | Description |
| --- | --- |
| `<file>` | Path of a text file to read. If omitted, standard input is read. |
| `-Help`, `-h` | Show usage information and exit. |

Output is written to standard output.

## Examples

Encode a file:

```powershell
.\Rot13.ps1 secret.txt
```

Encode piped text:

```powershell
"Hello, World!" | .\Rot13.ps1
# Uryyb, Jbeyq!
```

Decode by running the output through the script again:

```powershell
"Hello, World!" | .\Rot13.ps1 | .\Rot13.ps1
# Hello, World!
```

Write the result to a file:

```powershell
Get-Content secret.txt | .\Rot13.ps1 > decoded.txt
```

Use from `cmd.exe`:

```bat
type secret.txt | powershell -NoProfile -File Rot13.ps1
```

When run with no file and no piped input, the script reads lines typed at the console. Press `Ctrl+Z`, then `Enter`, to finish.

Full help is also available through PowerShell's built-in help system:

```powershell
Get-Help .\Rot13.ps1 -Full
```

## Behavior

- Only ASCII letters `A`–`Z` and `a`–`z` are rotated, and case is preserved.
- Digits, punctuation, whitespace, and non-ASCII characters pass through unchanged.
- Exit code `0` on success; `1` if the file cannot be found or read.

## Execution policy

If script execution is blocked on your system, run it with a one-off bypass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Rot13.ps1 secret.txt
```
