# Cal.ps1

A single-file PowerShell port of the Unix `cal` command. It runs on the Windows
PowerShell 5.1 that ships with Windows 11 (and on PowerShell 7) with no modules
or other dependencies.

```powershell
.\Cal.ps1                 # current month
.\Cal.ps1 2027            # whole year
.\Cal.ps1 9 1752          # month and year (shows the 1752 Gregorian reform)
.\Cal.ps1 25 12 2026      # day, month and year (day is highlighted)
.\Cal.ps1 march           # month by name
.\Cal.ps1 2026-12-25      # timestamp (also @unixseconds, today, tomorrow...)
.\Cal.ps1 -3 -w -m        # three months, Monday first, ISO week numbers
.\Cal.ps1 -v -y           # whole year, vertical (ncal) layout
.\Cal.ps1 --help          # all options
```

## Options

Options follow Unix conventions and are **case-sensitive** (`-y` year vs `-Y`
next twelve months). Short options can be bundled (`-3wm`), arguments can be
attached (`-n4`, `-w12`), and long options can be written `--months=4`,
`--months 4`, `-months 4`, or shortened to any unique prefix (`--vert`).

| Option | Meaning |
| --- | --- |
| `-1`, `--one` | single month (default) |
| `-3`, `--three` | previous, current and next month |
| `-n`, `--months <num>` | show *num* months |
| `-S`, `--span` | center multi-month output on the date |
| `-A <num>` / `-B <num>` | add months after / before |
| `-s`, `--sunday` | Sunday first (default) |
| `-m`, `-M`, `--monday` | Monday first |
| `-j`, `--julian` | day-of-year numbers |
| `-J`, `--reform <1752\|gregorian\|iso\|julian>`, `--iso` | calendar system (default: switch to Gregorian in Sept 1752) |
| `-y`, `--year` / `-Y`, `--twelve` | whole year / next twelve months |
| `-w`, `--week[=<num>]` | week numbers (US with Sunday first, ISO 8601 with Monday first); `-w<num>` highlights a week |
| `-v`, `-N`, `--vertical` / `-C` | vertical (ncal) / horizontal layout |
| `-c`, `--columns <num\|auto>` | months per row |
| `-d <yyyy-mm[-dd]>` | pretend today is this date |
| `-H <yyyy-mm-dd>` | highlight this date |
| `-e` / `-o` | print the date of Western / Orthodox Easter |
| `--color[=auto\|always\|never]` | colorize output |
| `-h`, `--help` / `-V`, `--version` | help / version |

## Colour

When the output goes straight to the console, the calendar is colorized and
today's date is shown in reverse video. When the output is piped, redirected,
assigned to a variable or captured (`.\Cal.ps1 > cal.txt`, `$c = .\Cal.ps1`,
`.\Cal.ps1 | Select-String 15`), it is plain text.
`--color=always` forces ANSI escape codes into piped output, and
`--color=never` or the `NO_COLOR` environment variable turns colour off.

Note: PowerShell handles `-?` itself and consumes a bare `--`.
