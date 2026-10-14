# pscalc

A minimal, keyboard-driven calculator that runs in your PowerShell console.

It doesn't draw a calculator keypad. You type expressions as free-form text, such as `2 * (3 + 4)`, `sqrt(2)^2` or `255 to hex`, and press **Enter**. Every calculation goes into a history log that is saved to disk, so it is still there the next time you open pscalc.

```
 pscalc                                                            DEG  DEC  4 saved
────────────────────────────────────────────────────────────────────────────────────

   2 + 3 * 4                                                                   = 14
   sqrt(2)                                                        = 1.4142135623731
 ► ans * 2                                                       = 2.82842712474619
   255 to hex                                                                = 0xFF
────────────────────────────────────────────────────────────────────────────────────
 > ans * 2
   = 2.82842712474619
────────────────────────────────────────────────────────────────────────────────────
 Enter calc  Up/Dn history  F1 help  Esc quit  Ctrl+C copy  Ctrl+V paste  ...
```

## Contents

- [Requirements](#requirements)
- [Getting started](#getting-started)
- [The screen](#the-screen)
- [Writing expressions](#writing-expressions)
- [Functions](#functions)
- [Constants and `ans`](#constants-and-ans)
- [Degrees and radians](#degrees-and-radians)
- [Number bases](#number-bases)
- [Commands](#commands)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [History](#history)
- [Examples](#examples)
- [Error messages](#error-messages)
- [Non-interactive use](#non-interactive-use)
- [Files and settings](#files-and-settings)
- [Limitations](#limitations)
- [How it works](#how-it-works)

## Requirements

- Windows 11 (or Windows 10).
- **Windows PowerShell 5.1**, which ships with Windows, or **PowerShell 7+**.
- Nothing else. pscalc is a single `.ps1` file with no modules, packages or external programs.

It runs in Windows Terminal, the classic console window (conhost), and the VS Code integrated terminal. It does **not** run in the PowerShell ISE, which has no real console. In the ISE, use `-Expression` instead.

## Getting started

```powershell
# From the folder that contains pscalc.ps1
.\pscalc.ps1
```

If PowerShell refuses to run the script because of the execution policy, allow local scripts for your user account (a one-time change):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Or run it once without changing the policy:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\pscalc.ps1
```

If you downloaded the file, Windows may have marked it as coming from the internet. Run `Unblock-File .\pscalc.ps1` to clear that mark.

Type an expression, press **Enter**, and press **F1** at any time for the built-in help. Press **Esc** on an empty line, or type `exit`, to quit.

### Parameters

| Parameter     | Description |
|---------------|-------------|
| `-Expression` | One or more expressions to evaluate without opening the interface. See [Non-interactive use](#non-interactive-use). |
| `-DataPath`   | Folder for the history and settings files. Default: `$env:APPDATA\pscalc`. |
| `-Ascii`      | Draw the interface with plain ASCII characters only, for console fonts that don't show line-drawing characters. |

Full parameter help is available through `Get-Help .\pscalc.ps1 -Full`.

## The screen

From top to bottom:

1. **Title bar**: shows the current angle mode (`DEG`/`RAD`), the default output base (`DEC`/`HEX`/`BIN`/`OCT`) and how many history entries are saved.
2. **History**: your past calculations, oldest at the top and newest just above the input line. The selected entry is highlighted while you browse with the arrow keys.
3. **Input line**: where you type. Long input scrolls sideways to keep the cursor visible.
4. **Status line**: shows a live preview of the result while you type (`= 14`), plus errors and confirmations.
5. **Shortcut bar**: a reminder of the most useful keys.

The layout adjusts to the window size. If you resize the window, pscalc redraws automatically.

## Writing expressions

### Numbers

| Form              | Example                  |
|-------------------|--------------------------|
| Whole numbers     | `42`, `-7`               |
| Decimals          | `3.14`, `.5`             |
| Scientific        | `6.02e23`, `1.5e-3`      |
| Binary            | `0b1010`                 |
| Octal             | `0o17`                   |
| Hexadecimal       | `0xFF`, `0xbeef`         |

The decimal separator is always `.`, whatever your Windows regional settings are, because `,` separates function arguments. Underscores can group digits in prefixed numbers: `0b1111_0000`.

### Operators

Highest precedence first:

| Operator  | Meaning | Notes |
|-----------|---------|-------|
| `( )`     | Grouping | |
| `n!`      | Factorial | `5!` = 120 |
| `x ^ y`   | Power | Right-associative: `2^3^2` = `2^9` = 512. `**` also works. |
| `-x`      | Negation | `-2^2` = `-(2^2)` = -4, the standard mathematical convention |
| `x * y`   | Multiplication | `×` also works |
| `x / y`   | Division | `÷` also works |
| `x % y`   | Remainder | `10 % 3` = 1 |
| `x + y`, `x - y` | Addition, subtraction | |

This is the standard order of operations (PEMDAS/BODMAS). Operators of equal precedence are evaluated left to right, except `^`, which is evaluated right to left.

**Implicit multiplication.** A number or closing parenthesis directly followed by a name or an opening parenthesis is multiplied. It works the same as `*`:

```
2pi          = 6.28318530717959
3(4 + 1)     = 15
(1 + 2)(3 + 4) = 21
2 sqrt(9)    = 6
```

Spaces are optional everywhere, and names are not case-sensitive (`PI`, `Sqrt(4)` and `pi`, `sqrt(4)` are equivalent).

## Functions

| Function         | Description |
|------------------|-------------|
| `sqrt(x)`        | Square root |
| `cbrt(x)`        | Cube root (works for negative numbers: `cbrt(-8)` = -2) |
| `root(x, n)`     | n-th root of x |
| `abs(x)`         | Absolute value |
| `round(x [, d])` | Round to `d` decimal places (default 0). Halves round away from zero: `round(2.5)` = 3 |
| `floor(x)`       | Round down |
| `ceil(x)`        | Round up |
| `trunc(x)`       | Drop the fractional part |
| `exp(x)`         | e<sup>x</sup> |
| `ln(x)`          | Natural logarithm (base e) |
| `log(x [, b])`   | Logarithm in base `b`; base 10 if `b` is omitted |
| `log2(x)`        | Base-2 logarithm |
| `sin(x)`, `cos(x)`, `tan(x)` | Trigonometric functions, using the current angle mode |
| `asin(x)`, `acos(x)`, `atan(x)` | Inverse trigonometric functions; the result is in the current angle mode |
| `sinh(x)`, `cosh(x)`, `tanh(x)` | Hyperbolic functions |
| `fact(n)`        | Factorial, same as `n!` (0 to 170) |
| `min(a, b, ...)` | Smallest argument |
| `max(a, b, ...)` | Largest argument |
| `bin(x)`, `oct(x)`, `dec(x)`, `hex(x)` | Return `x` unchanged but display the result in that base. See [Number bases](#number-bases). |

## Constants and `ans`

| Name  | Value |
|-------|-------|
| `pi`  | 3.14159265358979… (you can also type `π`) |
| `e`   | 2.71828182845905… |
| `tau` | 2π = 6.28318530717959… |
| `phi` | Golden ratio, 1.61803398874989… |
| `ans` | The result of the most recent calculation in the history |

`ans` is saved with the history, so it still holds your last result after you close and reopen pscalc. Clearing the history clears `ans` too.

`e` is the constant only when it stands alone. In `1e5` it is part of scientific notation, and `2e` means `2 × e`.

## Degrees and radians

`sin`, `cos` and `tan` take an angle in the current mode, and `asin`, `acos` and `atan` return one. The title bar shows the mode.

- Press **F2** to switch between degrees and radians, or
- type `deg` or `rad` and press Enter.

The default is **degrees**. Your choice is saved and kept for the next session.

In degree mode, exact multiples of 90° give exact answers: `sin(180)` = 0, `cos(90)` = 0, and `tan(90)` is reported as undefined instead of returning a huge number. In radian mode, tiny floating-point leftovers are rounded to zero, so `sin(pi)` = 0.

## Number bases

**Input.** Write a number in another base with a prefix: `0b` for binary, `0o` for octal, `0x` for hexadecimal. You can mix bases freely: `0xFF + 0b1010` = 265.

**Output.** There are three ways to choose the base of a result:

1. **For one result**, add `to <base>` (or `in`/`as`) at the end of the expression:
   ```
   255 to hex       = 0xFF
   0x1F to bin      = 0b11111
   0b1010 to dec    = 10
   64 in oct        = 0o100
   ```
   Base names: `bin`/`binary`, `oct`/`octal`, `dec`/`decimal`, `hex`/`hexadecimal`.
2. **With a function**: `hex(48879)` = `0xBEEF`.
3. **For all results**: press **F3** to cycle the default output base (DEC → HEX → BIN → OCT), or type `base hex` (or `base bin`, `base oct`, `base dec`). The title bar shows the current default, and the setting is saved.

Binary, octal and hexadecimal output needs a whole number. If a result has a fractional part, such as `2.5 to hex`, pscalc shows it in decimal and says why on the status line. Negative numbers are shown with a minus sign (`-255 to hex` = `-0xFF`), not in two's complement.

## Commands

Type these on the input line and press Enter. They are not added to the history.

| Command          | Action |
|------------------|--------|
| `help` or `?`    | Open the help screen |
| `clear`          | Delete the whole history |
| `deg` / `rad`    | Switch angle mode |
| `base <name>`    | Set the default output base (`bin`, `oct`, `dec`, `hex`) |
| `exit` / `quit`  | Quit |

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| **Enter** | Calculate the expression and add it to the history |
| **Up / Down** | Move through the history. The selected expression is loaded into the input line, where you can edit it and press Enter to calculate it again (as a new entry). Moving down past the newest entry restores whatever you were typing. |
| **PgUp / PgDn** | Move through the history a page at a time |
| **Ctrl+C** | Copy a result to the clipboard: the selected history entry if you are browsing, otherwise the live preview of the current input, otherwise the last result |
| **Ctrl+V** | Paste the first line of the clipboard at the cursor |
| **Ctrl+L** | Clear the history (asks you to press Y to confirm) |
| **Tab** | Complete a function or constant name (`sq` + Tab → `sqrt(`). If several names match, they are listed. |
| **F1** | Help screen (scroll with Up/Down/PgUp/PgDn; Esc to return) |
| **F2** | Toggle degrees / radians |
| **F3** | Cycle the default output base |
| **Left / Right** | Move the cursor. Hold **Ctrl** to jump by word. |
| **Home / End** | Jump to the start / end of the input |
| **Backspace / Delete** | Delete a character. **Ctrl+Backspace** or **Ctrl+W** deletes a word. |
| **Esc** | Clear the input. On an empty line, quit. |

In Windows Terminal, **Ctrl+C** and **Ctrl+V** may be handled by the terminal itself, for example when text is selected with the mouse. Pasting through the terminal works the same way, because the text arrives as typed input.

## History

- Each successful calculation is saved with its expression, result, numeric value, angle mode and timestamp. Expressions that produce an error are **not** saved. They stay on the input line so you can fix them.
- The history is kept between sessions (see [Files and settings](#files-and-settings)) and is capped at the most recent **1000** entries.
- Clear it at any time with **Ctrl+L** (with confirmation) or the `clear` command.

## Examples

| Expression | Result |
|------------|--------|
| `2 + 3 * 4` | 14 |
| `(2 + 3) * 4` | 20 |
| `2^10` | 1024 |
| `-2^2` | -4 |
| `sqrt(16) + 3!` | 10 |
| `2pi` | 6.28318530717959 |
| `sin(30)` | 0.5 (DEG mode) |
| `sin(pi / 6)` | 0.5 (RAD mode) |
| `asin(1)` | 90 (DEG mode) |
| `log(1000)` | 3 |
| `log(8, 2)` | 3 |
| `ln(e^3)` | 3 |
| `root(27, 3)` | 3 |
| `round(3.14159, 2)` | 3.14 |
| `10 % 3` | 1 |
| `0.1 + 0.2` | 0.3 |
| `ans * 2` | twice the previous result |
| `0xFF + 0b1010` | 265 |
| `255 to hex` | 0xFF |
| `0x1F to bin` | 0b11111 |
| `hex(48879)` | 0xBEEF |
| `max(3, 9, 4) - min(3, 9, 4)` | 6 |

## Error messages

Invalid input never crashes the calculator. The status line explains the problem, usually with the character position, and your input is left in place to fix:

```
2 +        The expression is incomplete. Something is missing at the end.
(2 + 3     Expected ')' to match '(' at position 1, but found end of expression.
2 + 3)     Unexpected ')' at position 6. There is no matching '('.
foo        Unknown name 'foo' at position 1. Type 'help' to see available constants and functions.
sqrt       Function 'sqrt' needs parentheses, for example sqrt(x).
1/0        Division by zero.
ln(-1)     ln() is only defined for numbers greater than zero.
0b102      Invalid digit '2' in binary number at position 5.
ans        'ans' has no value yet. It refers to the result of your last calculation.
```

## Non-interactive use

Pass expressions with `-Expression`, or pipe them in, to get results without opening the interface. Each result is written to the pipeline as a string, and `ans` refers to the previous expression in the same call:

```powershell
PS> .\pscalc.ps1 -Expression '2^10', 'ans / 4', '255 to hex'
1024
256
0xFF

PS> 'sqrt(2)', 'sin(30)' | .\pscalc.ps1
1.4142135623731
0.5
```

Invalid expressions produce a non-terminating error (so `-ErrorAction` works as usual). In this mode the saved angle mode and output base are used and `ans` starts from the last saved result, but **nothing is written to the history**.

## Files and settings

pscalc stores its data under your roaming application-data folder in your user profile. PSReadLine keeps PowerShell's own command history in the same place. Windows Disk Cleanup and temp-file cleaners don't touch this folder.

| File | Contents |
|------|----------|
| `%APPDATA%\pscalc\history.jsonl` | History, one JSON object per line |
| `%APPDATA%\pscalc\settings.json` | Angle mode and default output base |

`%APPDATA%` is normally `C:\Users\<you>\AppData\Roaming`. Use `-DataPath` to keep the files somewhere else. Both files are plain text. You can delete them at any time to reset pscalc. A damaged history line is skipped rather than stopping the calculator from starting.

## Limitations

- Numbers are 64-bit floating point (`[double]`), with about 15–16 significant digits. Results are displayed with up to 15 significant digits, so `0.1 + 0.2` shows as `0.3`.
- Whole numbers are exact up to 2<sup>53</sup> (9,007,199,254,740,992). Base conversion of larger values is refused, with a message, because they can't be represented exactly.
- There are no user-defined variables. `ans` is the only memory.
- The interface needs a console window at least 40 columns by 10 rows.

## How it works

The script is organised into regions:

- **Tokenizer** (`ConvertTo-CalcToken`) turns the input into numbers, names and operators, and handles base prefixes and scientific notation.
- **Parser/evaluator** (`Read-CalcSum` … `Read-CalcPrimary`) is a recursive-descent parser that computes the value as it parses. Expressions are never passed to `Invoke-Expression`, so typed input cannot run PowerShell code.
- **Functions table** (`$script:Functions`) defines each function's argument count, help text and implementation. The help screen is generated from it.
- **Persistence** reads and writes the history and settings files.
- **Console drawing and the interactive loop** draw the interface with the .NET `[Console]` API. In PowerShell 7 they use the terminal's alternate screen, so your previous console contents return when you quit. Console state (colors, Ctrl+C handling, encoding, window title) is always restored on exit, even after an error.

The script can be dot-sourced (`. .\pscalc.ps1`) to load its functions without starting the calculator, which is useful for testing:

```powershell
. .\pscalc.ps1
$context = @{ AngleMode = 'Deg'; OutputBase = 10; Ans = $null; RequestedBase = $null }
Invoke-CalcExpression -Expression 'sin(30) + 1' -Context $context
```
