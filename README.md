# Password Analyzer

An interactive terminal app (TUI) that analyzes password strength as you type.
It is a single PowerShell script, `PasswordAnalyzer.ps1`, with no external
dependencies.

```
========================================================================
  PASSWORD ANALYZER
========================================================================
  Password: Password-123 [visible]

  Length              : 12
  Uppercase letters   : 1
  Lowercase letters   : 7
  Digits              : 3
  Special characters  : 1
  Character pool      : 95
  Entropy             : 12.7 bits [###-----------------]  (brute force: 78.8)
  Patterns            : common password "Password", sequence "123"
  Strength            : WEAK  - built on a common password
  Time to crack       : instantly  @ 10 billion/s

  Estimated time to crack by attack scenario
    Online, throttled                    100/s  34 seconds
    Offline, slow hash           10 thousand/s  instantly
    Offline, fast hash (GPU)      10 billion/s  instantly
    Massive cluster               1 trillion/s  instantly

  Suggestions
    - Built on a very common password; adding digits or symbols barely helps.
    - Avoid sequences such as abc or 123.

========================================================================
  [Tab] show/hide   [Esc] clear   [Backspace] delete   [Ctrl+Q] quit
```

## Features

- Live updates on every keystroke (pasting works too)
- Length and counts of uppercase letters, lowercase letters, digits and
  special characters
- Character pool size and entropy in bits, with a bar
- Detection of guessable patterns: the most common passwords, dictionary
  words and names, l33t substitutions (`p@ssw0rd`), reversed words,
  keyboard walks (`qwerty`, `1qaz2wsx`), sequences (`abc`, `123`), repeats
  (`aaa`, `abcabc`), years and dates
- Entropy and crack times that account for those patterns, with the naive
  brute-force figure shown alongside
- Strength rating: **Weak**, **Medium** or **Strong**. A password that is,
  or is mostly made of, a known common password is always **Weak**
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
Length                 : 11
Uppercase              : 1
Lowercase              : 6
Digits                 : 3
Special                : 1
ClassCount             : 4
PoolSize               : 95
BruteForceEntropy      : 72.2709...
Entropy                : 62.8...
Patterns               : {@{Type=Dictionary; Start=4; End=7; Token=b4d; Word=bad; ...}}
IsCommonPassword       : False
CommonPasswordRank     : 0
ContainsCommonPassword : False
Strength               : Medium
```

`Entropy` is the pattern-adjusted figure that the rating and crack times
use. `Find-PasswordPattern -Password '...'` lists every pattern match found,
not only the ones used in the cheapest split.

Get help with `Get-Help .\PasswordAnalyzer.ps1 -Full`.

## How the numbers are calculated

### Character counts

Characters are classified with .NET's Unicode-aware `Char.IsUpper`,
`Char.IsLower` and `Char.IsDigit`. Everything else, including spaces, is a
special character.

### Brute-force entropy

```
brute-force entropy (bits) = length * log2(pool size)
```

The pool size is the sum of the character sets used in the password:

| Character set                      | Size |
| ---------------------------------- | ---- |
| Lowercase `a-z`                    | 26   |
| Uppercase `A-Z`                    | 26   |
| Digits `0-9`                       | 10   |
| ASCII symbols and space            | 33   |
| Any non-ASCII character (estimate) | 100  |

### Pattern-adjusted (effective) entropy

Attackers don't brute force blindly. They try leaked and common passwords,
then words and names with common tweaks, then keyboard walks, dates and so
on. The analyzer works out the cheapest way to build the password from
these patterns plus plain characters, in the spirit of Dropbox's
[zxcvbn](https://github.com/dropbox/zxcvbn), and uses that as the entropy:

| Pattern          | Example            | Cost in bits                                    |
| ---------------- | ------------------ | ----------------------------------------------- |
| Common password  | `password`, `123456` | log2(rank + 1); rank 1 is the most popular    |
| Dictionary word  | `summer`, `michael` | log2(size of the word list), about 9.2         |
| Keyboard walk    | `qwerty`, `zaq1xsw2` | log2(47) + log2(length)                       |
| Sequence         | `abc`, `9876`      | log2(4, 10 or 26) + log2(length), +1 if descending |
| Repeat           | `aaa`, `abcabc`    | cost of the repeated chunk + log2(repeat count) |
| Year             | `1990`, `2024`     | log2(max(\|year - this year\|, 20))             |
| Date             | `01011990`         | log2(365) + year cost                           |
| Any other character | `-`, `x`        | log2(pool size)                                 |

Words are matched case-insensitively, with l33t substitutions undone
(`@`=a, `0`=o, `3`=e, `1`=i/l, `$`=s, ...) and reversed. Each costs a
little extra: 1 bit for `Capitalized` or `ALL CAPS` (more for odd mixes),
1 bit per substitution, and 1 bit for reversal.

For example, `Password-123` costs 2.6 bits (`Password`, #2 on the
common-password list, capitalized) + 6.6 bits (`-`) + 3.6 bits (`123`),
about 12.7 bits. The naive brute-force figure is 78.8 bits.

The embedded lists (about 300 common passwords and 600 words and names)
are far smaller than real cracking dictionaries. A password that passes
here can still be weak.

### Strength rating

The rating uses the pattern-adjusted entropy:

| Rating     | Rule                                                        |
| ---------- | ----------------------------------------------------------- |
| **Strong** | 12+ characters, 3+ character classes, 60+ bits of entropy   |
| **Medium** | 8+ characters, 2+ character classes, 40+ bits of entropy    |
| **Weak**   | Anything else                                               |

Common passwords are treated harshly. If the password is on the
common-password list (ignoring case and l33t, e.g. `P@ssw0rd`), or common
passwords make up at least half its characters (e.g. `Password-123`,
`MyPassword2024!`), it is rated **Weak** no matter what the other rules
say.

### Crack time

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

- The word lists are small and English-only, so they are nowhere near a
  full breach corpus such as Have I Been Pwned. Words, names and leaked
  passwords that aren't on the lists are scored as random characters.
- Patterns are scored on their own. The extra effort an attacker needs to
  combine several of them is ignored, which makes the estimates
  slightly pessimistic for long multi-word passphrases.
- The best defense is still a long, random, unique password from a password
  manager.

## Privacy

The password stays in memory. It is never written to disk or sent over the
network. The screen and the in-memory buffer are cleared when you quit.
While the password is hidden, the **Patterns** line shows only the kind and
length of each pattern, not the matched text.

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
