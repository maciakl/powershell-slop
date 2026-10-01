# Figlet.ps1

A port of the classic [FIGlet](http://www.figlet.org/) 2.2.5 banner program to
PowerShell, in one self-contained file.

```
 _____ _       _      _               _ 
|  ___(_) __ _| | ___| |_   _ __  ___/ |
| |_  | |/ _` | |/ _ \ __| | '_ \/ __| |
|  _| | | (_| | |  __/ |_ _| |_) \__ \ |
|_|   |_|\__, |_|\___|\__(_) .__/|___/_|
         |___/             |_|          
```

- Runs on the Windows PowerShell 5.1 that ships with Windows (and on PowerShell 7).
- Has no dependencies: no modules, no compiled code, no font files needed.
- Is a single file. All 18 standard FIGlet fonts and all 39 control files
  are embedded (compressed) in the script.
- Implements every `figlet` switch with the same semantics, and its output
  matches the original byte for byte (see [Compatibility](#compatibility)).

## Usage

```
Figlet.ps1 [ -cklnoprstvxDELNRSWX ] [ -d fontdirectory ]
           [ -f fontfile ] [ -m smushmode ] [ -w outputwidth ]
           [ -C controlfile ] [ -I infocode ] [ message ]
```

```powershell
.\Figlet.ps1 Hello, World!
.\Figlet.ps1 -f slant -c -w 60 PowerShell
Get-Content .\motd.txt | .\Figlet.ps1 -f small -p
.\Figlet.ps1 -C utf8 -f mnemonic "Grüße"
```

Run `Get-Help .\Figlet.ps1` for a summary of the options. They are the same
as figlet's (see `man figlet`):

| Option | Meaning |
| --- | --- |
| `-f font` | Font to use (`.flf` or `.tlf`; the suffix is optional) |
| `-d dir` | Directory to search for fonts and control files |
| `-C file` / `-N` | Add a control file (`.flc`) / clear the control file list |
| `-c` `-l` `-r` `-x` | Center / left / right / font-default justification |
| `-L` `-R` `-X` | Left-to-right / right-to-left / font-default direction |
| `-w n` / `-t` | Output width / use the console window width |
| `-s` `-S` `-k` `-W` `-o` `-m n` | Layout: font default, force smushing, kerning, full width, overlapping, explicit mode |
| `-p` / `-n` | Paragraph mode / normal mode |
| `-D` / `-E` | German umlaut substitution for `[\]{\|}~` on / off |
| `-A` | Take the message from the command line |
| `-v` / `-I n` | Version and copyright / info code (0-5) |

With no message words the text is read from the pipeline, or from standard
input. In an interactive console, each line is rendered as you type it, and
Ctrl+Z then Enter ends input.

## Install as `figlet`

Put `Figlet.ps1` in a folder on your `PATH`. PowerShell then runs it as
`figlet`. Running local scripts needs an execution policy such as
`RemoteSigned`. To call it from `cmd.exe` or batch files, add a
`figlet.cmd` next to it:

```bat
@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Figlet.ps1" %*
```

## Fonts

Fonts and control files are looked up the way figlet does it: first
`<fontdir>\<name>.flf`, then `<name>.flf` relative to the current directory.
Zipped font files work too. The font directory is, in order of precedence:

1. `-d dir`
2. `$env:FIGLET_FONTDIR`
3. a `fonts` folder next to `Figlet.ps1`, if one exists, or else the folder
   that holds the script

If a font or control file isn't found on disk, the embedded copy is used.
The embedded fonts are banner, big, block, bubble, digital, ivrit, lean,
mini, mnemonic, script, shadow, slant, small, smscript, smshadow, smslant,
standard and term. The embedded control files are the whole standard set
(`utf8`, `upper`, `hz`, `jis0201`, `koi8r`, `8859-*`, `646-*`, and the
others).

## Compatibility

The script follows `figlet.c` 2.2.5 function by function: getopt-style option
parsing with GNU argument permutation, the font and control file readers, the
smushing rules, line breaking, paragraph mode, ISO 2022, DBCS, UTF-8, HZ and
Shift-JIS input, and the info codes. It was tested against the real figlet
2.2.5 on 1,330 cases covering every font, layout mode, justification,
direction, width, control file and error path. All of them give identical
output except the intentional differences below.

Intentional differences:

- **Input is Unicode text.** PowerShell passes strings, not bytes. By
  default, characters up to U+00FF are treated as figlet's default Latin-1
  bytes. Characters above U+00FF are passed straight through as code points,
  so `.\Figlet.ps1 -f mnemonic Ж` works without `-C utf8`. Real figlet would
  print the separate UTF-8 bytes. With `-C utf8` the results are the same.
  CRLF line endings in piped input are treated as a single newline.
- **Font lines that aren't valid UTF-8** are read as Latin-1. Real figlet
  shows those glyphs as empty. This only affects fonts such as `term.flf`
  that contain raw Latin-1 bytes.
- **Embedded fonts are a fallback.** A font that real figlet would report as
  "Unable to open font file" still works if it is one of the embedded ones.
- **PowerShell argument quirks.** PowerShell turns `Hello, World!` into an
  array; the script joins it back with `", "`. Inside a PowerShell session,
  PowerShell itself removes a bare `--` and handles `-?` as a help request.
  Both work as figlet expects under `powershell -File` and `figlet.cmd`.
- **`-I2`** prints this port's font directory, not `/usr/share/figlet`.

Output goes to the PowerShell pipeline as one string per line, so it can be
piped to `Set-Content`, `Set-Clipboard`, and so on. Errors go to standard
error, with exit code 1 like figlet.

## License

FIGlet is Copyright (C) 1991-2012 Glenn Chappell, Ian Chai, John Cowan,
Christiaan Keet and Claudio Matsuoka, and is distributed under the New BSD
License. The embedded fonts and control files come from the FIGlet 2.2.5
distribution and keep their own headers and notices.
