# TextToNato

An interactive terminal app (TUI) that turns text into the
[NATO phonetic alphabet](https://en.wikipedia.org/wiki/NATO_phonetic_alphabet)
as you type.

```
                 TextToNato - NATO Phonetic Alphabet Translator
 Text > Hello, World!_
───────────────────────────────────────────────────────────────────────────────
  H Hotel   e Echo   l Lima   l Lima   o Oscar   , Comma
  W Whiskey   o Oscar   r Romeo   l Lima   d Delta   ! Exclamation

───────────────────────────────────────────────────────────────────────────────
 Esc clear   Backspace delete   Ctrl+Backspace delete word   Ctrl+Q quit
```

## Features

- **Live translation** that updates with every keystroke.
- **Upper- and lowercase** letters are both translated. Each character is
  shown as you typed it, so you can still see the capitals.
- **Digits** become their spoken names (`Zero` to `Nine`).
- **Punctuation** gets a descriptive name (`Period`, `Comma`, `Dash`,
  `Question`, `At`, ...).
- **Spaces** start a new output line, so each word gets its own row.
- **Alternating colors** (cyan and yellow) for code words so they are easy to
  tell apart. Punctuation is magenta. Characters that cannot be translated
  are dark yellow.
- **Quick clear**: press `Esc` to clear the input and start over.
- Long input wraps neatly and redraws when you resize the window.
- When you quit, the last translation is printed to the console so it stays in
  your scrollback.

## Requirements

- Windows 11 with **Windows PowerShell 5.1** (built in) or **PowerShell 7+**.
- No modules, no external dependencies, nothing to install.

## Usage

### Interactive mode

```powershell
.\TextToNato.ps1
```

| Key              | Action                          |
| ---------------- | ------------------------------- |
| Any character    | Add it to the input             |
| `Backspace`      | Delete the last character       |
| `Ctrl+Backspace` | Delete the last word            |
| `Esc` / `Ctrl+L` | Clear the input and start over  |
| `Ctrl+Q` / `Ctrl+C` | Quit                         |

The interactive mode needs a real console window, such as Windows Terminal or
a PowerShell console. It does not work in the PowerShell ISE.

### One-shot mode

To translate text without starting the UI:

```powershell
.\TextToNato.ps1 -Text 'Hello, World!'
'first line', 'second line' | .\TextToNato.ps1
```

### Objects for scripting

`-AsObject` outputs one object per character instead of colored text:

```powershell
PS> .\TextToNato.ps1 -Text 'Hi!' -AsObject

Character CodeWord    Category
--------- --------    --------
        H Hotel       Letter
        i India       Letter
        ! Exclamation Punctuation
```

`Category` is one of `Letter`, `Digit`, `Punctuation`, `Space` or `Other`.

### Help

```powershell
Get-Help .\TextToNato.ps1 -Full
```

## Execution policy

If Windows blocks the script because running scripts is disabled, you can
either allow local scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

or bypass the policy for a single run:

```powershell
powershell -ExecutionPolicy Bypass -File .\TextToNato.ps1
```

If you downloaded the file, you may also need to run
`Unblock-File .\TextToNato.ps1`.

## Notes

- Code words use the official ICAO spellings: **Alfa** and **Juliett**.
- The script file is pure ASCII. Box-drawing characters are built from code
  points at runtime, so the file reads correctly in Windows PowerShell 5.1
  whatever its encoding.
