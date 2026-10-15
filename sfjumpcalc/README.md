# Star Frontiers Jump Calculator

A keyboard-driven text user interface (TUI) for working out how long it takes
a Star Frontiers style starship to cross a given distance, using Void jumps or
sub-light drives.

The whole tool is one PowerShell script, `StarFrontierJumpCalculator.ps1`. It
has no dependencies and runs on any Windows 11 machine, under either the
built-in Windows PowerShell 5.1 or PowerShell 7+.

```
  STAR FRONTIERS JUMP CALCULATOR
  ----------------------------------------------------------------------------
  DISTANCE
 > Distance: [25                               ]
      Units: P (default), AU, KP (1K P), MP (1M P).  e.g. 12, 1000 AU, 2.5kp
      = 25 P   =   5.16M AU

  SHIP SPECS
   [ ] Advanced folding array cooling  cool-down 20 h  (std 20 / adv 12 h)
   Folding array:  (*) Standard (10 P) ( ) Dual (20 P) ( ) Quad (40 P)
   [ ] Advanced vectoring array        sub-light 5 AU/h  (std 5 / adv 7 AU/h)

     Max jump: 10 P every 20 h  |  Sub-light: 5 AU/h vectoring, 1 AU/day torch

  RESULTS
     Jumps required ............. 3 jumps         10 P per jump
     Time using jumps ........... 1.67 days       2 x 20 h cool-downs
     Sub-light, vectoring array . 117.65 years    1.03M h at 5 AU/h
     Sub-light, chemical torch .. 14.12K years    5.16M days at 1 AU/day
```

## Running it

Open Windows Terminal or a PowerShell console and run:

```powershell
.\StarFrontierJumpCalculator.ps1
```

If the execution policy blocks the script, run it once with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\StarFrontierJumpCalculator.ps1
# or, with PowerShell 7:
pwsh -ExecutionPolicy Bypass -File .\StarFrontierJumpCalculator.ps1
```

The console window must be at least 80 x 26 characters. The PowerShell ISE is
not supported because it has no real console.

## Entering a distance

Type the distance as free text. The results update as you type.

| Input                  | Meaning                         |
|------------------------|---------------------------------|
| `12`, `12 P`, `12pc`   | 12 parsecs (the default unit)   |
| `1000 AU`, `1000au`    | 1,000 astronomical units        |
| `200K AU`, `200kau`    | 200,000 AU                      |
| `1.5M AU`, `1.5MAU`    | 1,500,000 AU                    |
| `2.5 KP`, `2.5kp`      | 2.5 kilo-parsecs = 2,500 P      |
| `1 MP`, `1mp`          | 1 mega-parsec = 1,000,000 P     |

- Units are case-insensitive, and spaces between the number, prefix and unit
  are optional.
- AU accepts a `K` (thousand), `M` (million) or `G` (billion) prefix.
- Commas (`1,000`) and scientific notation (`1e3`) are accepted.
- If the input is invalid, empty, zero or negative, a message explains the
  problem and asks you to re-enter the distance. The results show `--` until
  the input is valid.

## Ship specs

| Option                         | Default         | Upgraded                      |
|--------------------------------|-----------------|-------------------------------|
| Advanced folding array cooling | 20 h cool-down  | 12 h cool-down                |
| Folding array                  | Standard (10 P) | Dual (20 P) or Quad (40 P)    |
| Advanced vectoring array       | 5 AU/h          | 7 AU/h                        |

The chemical torch drive always travels at 1 AU per day. The spec panel shows
the range and speed of each option, plus a summary of the ship's current max
jump range and sub-light speeds.

## Keyboard controls

| Key                          | Action                                             |
|------------------------------|----------------------------------------------------|
| `Tab` / `Down`               | Next field                                         |
| `Shift+Tab` / `Up`           | Previous field                                     |
| `Space` / `Enter`            | Toggle a checkbox, or cycle the folding array      |
| `Left` / `Right`             | Change the folding array, or move the text cursor  |
| `Home` / `End`               | Jump to the start or end of the distance           |
| `Backspace` / `Delete`       | Edit the distance                                  |
| `Esc` / `Ctrl+L`             | Clear the distance                                 |
| `Ctrl+R` / `F5`              | Reset all ship specs to their defaults             |
| `Ctrl+Q` / `Ctrl+C` / `F10`  | Quit                                               |

If you type a number or letter while a ship spec field has focus, the cursor
moves to the distance field and the character is added there, so you never
need to navigate back first.

## How the numbers are calculated

- **Jumps required** = distance in parsecs / jump range, rounded up (at least
  one jump).
- **Time using jumps**: jumps happen instantly, but the folding array must cool
  down between them. N jumps therefore take (N - 1) x cool-down. A trip that
  needs only one jump is shown as `Instant`.
- **Sub-light time** = distance in AU / speed. 1 parsec = 206,264.8 AU
  (648,000 / pi).
- **Durations** use the largest sensible unit: seconds, minutes, hours, days,
  weeks, months (365.25 / 12 days) or years (365.25 days).
- **Large numbers** are shortened with SI prefixes: K (10^3), M (10^6),
  G (10^9), T (10^12), P (10^15), E (10^18), Z (10^21) and Y (10^24). For
  example, 1,500 is shown as `1.5K` and 1,000,000 as `1M`. Values under 0.01
  use scientific notation.

## Using the functions from a script

When you dot-source the script, its functions load but the UI does not start:

```powershell
. .\StarFrontierJumpCalculator.ps1

$distance = ConvertFrom-DistanceText -Text '2.5 kp'
$state    = New-CalculatorState
$state.FoldingArrayIndex = 2   # Quad array
Get-TravelEstimate -Parsecs $distance.Parsecs -Spec (Get-ShipSpec -State $state)

Format-Duration -Hours 41253   # 4.71 years
Format-SINumber -Value 1234567 # 1.23M
```

## Script layout

| Region             | Contents                                                          |
|--------------------|-------------------------------------------------------------------|
| Constants          | Unit conversions, ship performance figures, folding array table   |
| Calculation        | Parsing, SI number formatting, duration formatting, travel maths  |
| State management   | Creating the state, resetting specs, clearing the distance        |
| Input handling     | Key dispatch for global shortcuts, the distance field, spec fields |
| Rendering          | Builds the screen as coloured segments and draws it in place      |
| Main loop          | Console setup and restore, keyboard polling, resize handling      |
