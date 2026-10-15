# Password Analyzer

An interactive terminal app (TUI) that analyzes password strength as you type.
It is a single PowerShell script, `PasswordAnalyzer.ps1`, with no external
dependencies.

```
========================================================================
  PASSWORD ANALYZER
========================================================================

  Password: *********** [hidden]

  Length              : 11
  Uppercase letters   : 1
  Lowercase letters   : 6
  Digits              : 3
  Special characters  : 1
  Character pool      : 95
  Entropy             : 72.3 bits [##############------]
  Strength            : MEDIUM
  Time to crack       : 9 thousand years  @ 10 billion/s

  Estimated brute-force time by attack scenario
    Online, throttled                    100/s  901 billion years (> age of universe)
    Offline, slow hash           10 thousand/s  9 billion years
    Offline, fast hash (GPU)      10 billion/s  9 thousand years
    Massive cluster               1 trillion/s  90 years

  Suggestions
    - Use at least 12 characters (16+ is even better).

========================================================================
  [Tab] show/hide   [Esc] clear   [Backspace] delete   [Ctrl+Q] quit
```

## Features

- Live updates on every keystroke (pasting works too)
- Length and counts of uppercase letters, lowercase letters, digits and
  special characters
- Character pool size and entropy in bits, with a bar
- Strength rating: **Weak**, **Medium** or **Strong**
- Estimated brute-force time, both as a headline figure and for four attack
  scenarios
- Tips for improving the password
- Input is masked by default and can be revealed at any time
- Color-coded output: red is bad, yellow is so-so, green is good
- Redraws itself when the console window is resized
- Clears the screen and the in-memory password on exit

## Requirements

- Windows 11 with either:
  - Windows PowerShell 5.1 (`powershell.exe`, ships with Windows), or
  - PowerShell 7+ (`pwsh.exe`)
- An interactive console window such as Windows Terminal. The PowerShell ISE
  and redirected input are not supported.

Nothing else needs to be installed.

## Usage

```powershell
.\PasswordAnalyzer.ps1
```

If the execution policy blocks the script, run it for this session only:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\PasswordAnalyzer.ps1
```

### Keys

| Key                | Action                            |
| ------------------ | --------------------------------- |
| Any printable key  | Add a character                   |
| `Backspace`        | Delete the last character         |
| `Tab`              | Show or hide the password         |
| `Esc` / `Ctrl+U`   | Clear the password and start over |
| `Ctrl+Q` / `Ctrl+C`| Quit                              |

### Parameters

| Parameter           | Default | Description                                                        |
| ------------------- | ------- | ------------------------------------------------------------------ |
| `-GuessesPerSecond` | `1e10`  | Guess rate used for the headline "Time to crack" figure.           |

```powershell
.\PasswordAnalyzer.ps1 -GuessesPerSecond 1e6
```

### Using the functions from a script

Dot-sourcing the file loads its functions without starting the TUI:

```powershell
. .\PasswordAnalyzer.ps1
Get-PasswordAnalysis -Password 'Tr0ub4dor&3'
```

```
Length     : 11
Uppercase  : 1
Lowercase  : 6
Digits     : 3
Special    : 1
ClassCount : 4
PoolSize   : 95
Entropy    : 72.2709...
Strength   : Medium
```

Get help with `Get-Help .\PasswordAnalyzer.ps1 -Full`.

## How the numbers are calculated

### Character counts

Characters are classified with .NET's Unicode-aware `Char.IsUpper`,
`Char.IsLower` and `Char.IsDigit`. Everything else, including spaces, is a
special character.

### Entropy

```
entropy (bits) = length * log2(pool size)
```

The pool size is the sum of the character sets used in the password:

| Character set                      | Size |
| ---------------------------------- | ---- |
| Lowercase `a-z`                    | 26   |
| Uppercase `A-Z`                    | 26   |
| Digits `0-9`                       | 10   |
| ASCII symbols and space            | 33   |
| Any non-ASCII character (estimate) | 100  |

### Strength rating

| Rating     | Rule                                                        |
| ---------- | ----------------------------------------------------------- |
| **Strong** | 12+ characters, 3+ character classes, 60+ bits of entropy   |
| **Medium** | 8+ characters, 2+ character classes, 40+ bits of entropy    |
| **Weak**   | Anything else                                               |

### Brute-force time

On average an attacker finds the password after trying half of all
combinations:

```
seconds = 2^(entropy - 1) / guesses per second
```

| Scenario                 | Guesses/second | Example                                   |
| ------------------------ | -------------- | ----------------------------------------- |
| Online, throttled        | 100            | Login form with rate limiting             |
| Offline, slow hash       | 10 thousand    | Stolen bcrypt/scrypt/Argon2 hashes        |
| Offline, fast hash (GPU) | 10 billion     | Stolen MD5/SHA-1/NTLM hashes, GPU rig     |
| Massive cluster          | 1 trillion     | Well-funded attacker                      |

Times are colored red under one day, yellow under 100 years, and green
beyond that.

### Limitations

This is a pure brute-force model. It does **not** detect dictionary words,
names, keyboard patterns (`qwerty`), substitutions (`p@ssw0rd`) or passwords
from known breaches. Attackers try those first, so a password such as
`Password123!` is far weaker than the numbers here suggest. Use a password
manager to generate long, random passwords.

## Privacy

The password stays in memory. It is never written to disk or sent over the
network. The screen and the in-memory buffer are cleared when you quit.

## Implementation notes

- The script is plain ASCII so Windows PowerShell 5.1 reads it correctly
  without a byte-order mark.
- The UI uses `Write-Host` with `-ForegroundColor` and
  `[Console]::SetCursorPosition` rather than ANSI escape sequences, so
  colors work in the classic console host as well as Windows Terminal.
- The screen uses a fixed layout and redraws in place without clearing,
  so it does not flicker while you type.
- `Set-StrictMode -Version Latest` is enabled, functions use approved verbs
  and comment-based help, and the console state (cursor, Ctrl+C handling)
  is restored in a `finally` block.
