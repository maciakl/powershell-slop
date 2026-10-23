# Get-TimeInterval

A single-file PowerShell script that calculates the time between two dates/times. You type
both ends in plain language, in an interactive terminal UI or on the command line.

```
┌─ Time Interval ───────────────────────────────────────── v0.1.0 ─┐
│                                                                  │
│    Start    friday 9am                                           │
│           √ Friday, 10/23/2026 9:00:00 AM  Eastern Daylight Time │
│                                                                  │
│  ► End      monday 5:30pm pst                                    │
│           √ Monday, 10/26/2026 5:30:00 PM  Pacific Daylight Time │
│             = Monday, 10/26/2026 8:30:00 PM local time           │
├─ Interval ───────────────────────────────────────────────────────┤
│   3 days, 11 hours, and 30 minutes                               │
│   Totals  300,600 seconds · 5,010 minutes · 83.50 hours · ...    │
│   Exact   3d 11h 30m   (3.11:30:00  d.hh:mm:ss)                  │
│   • Monday comes before the start, so the following Monday ...   │
└──────────────────────────────────────────────────────────────────┘
```

- **Version:** 0.1.0
- **Requirements:** Windows 11 with Windows PowerShell 5.1 (built in) or PowerShell 7+.
  Nothing else to install.

## Usage

```powershell
# Interactive interface
.\Get-TimeInterval.ps1

# Direct calculation (no interface)
.\Get-TimeInterval.ps1 -Start '9am' -End '5:30pm'
.\Get-TimeInterval.ps1 -End 'friday 5pm EST' | Select-Object Human, TotalHours
(.\Get-TimeInterval.ps1 'last monday' 'next monday').TotalDays

# Version and help
.\Get-TimeInterval.ps1 -Version
.\Get-TimeInterval.ps1 -Help
Get-Help .\Get-TimeInterval.ps1 -Full
```

If `-Start` or `-End` is given, the interface is skipped and a missing or blank value means
*now*. Input that can't be parsed raises a terminating error (exit code 1 when run with
`pwsh -File`) that says what went wrong. Adjustments the script made are written to the verbose
stream (`-Verbose`).

If scripts are blocked on your machine, run
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` or
`powershell -ExecutionPolicy Bypass -File .\Get-TimeInterval.ps1`.

### Interactive keys

| Key | Action |
| --- | --- |
| Type | Edit the field. The display updates as you type. |
| Tab, ↑, ↓ | Move between Start and End |
| Enter | Go to the next field; on End, finish and return the result |
| Esc | Finish and return the result (closes help if it's open) |
| Ctrl+R, F5 | Reset both fields and start over |
| Ctrl+U / Ctrl+K | Delete to the start / end of the field |
| Ctrl+W, Ctrl+Backspace | Delete the previous word |
| Ctrl+←/→, Home, End | Move the cursor |
| F1 | Show or hide help and examples |
| Ctrl+C | Cancel without returning a result |

Blank fields mean *now* and keep updating every second. The interface uses the alternate
screen buffer, so your console looks the same as before once it closes. It needs a real console
(Windows Terminal or the classic console host). The PowerShell ISE can't run it, but `-Start`
and `-End` still work there.

## What you can type

| Kind | Examples |
| --- | --- |
| Times | `5pm`, `5 PM`, `5:30pm`, `5.30am`, `17:30`, `17:30:15`, `at 5`, `noon`, `midnight`, `9 in the morning`, `tomorrow evening`, `eod` |
| Dates | `5/7`, `5/7/2027`, `5/7/27`, `2027-05-07`, `7.5.`, `May 7`, `May 7th 2027`, `7th of May`, `Dec. 25`, `December`, `the 15th` |
| Relative | `now`, `today`, `tomorrow`, `yesterday`, `day after tomorrow`, `tonight`, `next week`, `last month`, `next year`, `week after next` |
| Weekdays | `friday`, `this friday`, `next friday`, `last monday`, `friday next week`, `next week friday`, `fri 3pm` |
| Durations | `in 3 hours`, `2 days ago`, `3 months and 7 days from today`, `a week from tomorrow at noon`, `3 days before friday`, `today + 90 minutes`, `1h30m`, `-2d`, `half an hour`, `an hour and a half ago`, `in 2 days at 5pm` |
| Time zones | `5pm EST`, `9am Eastern`, `noon Tokyo`, `5pm in London`, `14:00 UTC+2`, `9am GMT-5`, `10:00 +0530`, `2026-05-07T14:00Z`, `8am America/New_York`, `3pm Pacific Standard Time` |
| Other | Anything .NET's own parser understands, e.g. `Wed, 07 May 2025 10:00:00 GMT` |

### Rules and defaults

- A blank field means **now**.
- No date means **today**. No year means **the current year**. No minutes means **:00**.
- No time zone means your **local time zone** from Windows settings.
- A calendar date or weekday without a time means **midnight (00:00)**. Relative words such as
  `tomorrow`, `next week` and `in 3 days` keep the **current time of day**.
- Numeric dates like `5/7` follow your system's date order: MM/DD on en-US, DD/MM on en-GB.
  If the numbers only make sense the other way round (`13/5`), they are swapped and a note
  says so. `2027-05-07` is always year-month-day.
- A weekday on its own means that day in **the current week**. The first day of the week comes
  from your culture settings. `next friday` is the next Friday after today, `last monday` is the
  most recent Monday before today, and `friday next week` is the Friday of next week.
- Time zone abbreviations follow daylight saving time: `EST` in July is treated as Eastern time
  (UTC-4). Use `UTC-5` for a fixed offset. `IST` means India, `CST` means US Central and `BST`
  means British Summer Time.
- Months and years can't be fractional (`1.5 months` is rejected). Days, weeks and hours can be.
- Hours and minutes in durations count elapsed time, so `in 3 hours` is correct across daylight
  saving changes. Days, months and years follow the calendar.
- The parsed value appears under each field in your system's short date and long time format,
  with the day of the week. When you give a zone other than your own, the local equivalent is
  shown too.

### Backwards intervals

When the end comes before the start, the script tries to fix it:

1. A time-only end takes the start's date: `friday 9am` → `5pm` means Friday 5 PM.
2. A time-only end that is still earlier moves to the next day: `10pm` → `2am` is 4 hours, and
   a blank start → `midnight` counts to the coming midnight.
3. A time-only start later than the end moves to the previous day.
4. Weekdays given backwards (`friday` → `monday`) use next week's Monday or last week's Friday.
   The script picks whichever arrangement includes the current moment, and otherwise uses the
   next week.

Every adjustment is reported as a note. If nothing applies, the result is negative and
`IsNegative` is `$true`.

## Output

The script returns a `TimeInterval.Result` object. The default view shows the key properties;
use `| Format-List *` to see all of them.

| Property | Type | Example |
| --- | --- | --- |
| `Start`, `End` | `[datetime]` (local) | `10/23/2026 9:00:00 AM` |
| `StartUtc`, `EndUtc` | `[datetime]` (UTC) | `10/23/2026 1:00:00 PM` |
| `StartTimeZone`, `EndTimeZone` | `[string]` | `Eastern Daylight Time (UTC-04:00)` |
| `Human` | `[string]` | `2 hours, 30 minutes, and 15 seconds` |
| `Compact` | `[string]` | `2h 30m 15s` |
| `IsNegative` | `[bool]` | `$false` |
| `Duration` | `[timespan]` | `02:30:15` |
| `TotalSeconds`, `TotalMinutes`, `TotalHours`, `TotalDays`, `TotalWeeks` | `[double]` | `9015`, `150.25`, ... |
| `Breakdown` | object | `Years, Months, Days, Hours, Minutes, Seconds` |
| `StartInput`, `EndInput` | `[string]` | what you typed |
| `Notes` | `[string[]]` | adjustments the script made |

## Development

The script loads its functions without starting anything when it is dot-sourced, which makes
the parser easy to try out:

```powershell
. .\Get-TimeInterval.ps1
$now = [datetime]::UtcNow
(ConvertFrom-TimeText -Text 'next friday 5pm EST' -NowUtc $now).Local
New-IntervalResult (Resolve-Interval -StartText 'friday' -EndText 'monday' -NowUtc $now)
```

The source file is plain ASCII. Box-drawing characters are built from code points, so Windows
PowerShell 5.1 reads the file correctly without a byte-order mark.

## Changelog

### 0.1.0 (2026-10-22)

- First release.
- Interactive TUI with live parsing, parsed-date confirmation in the system's locale format,
  live interval display, reset (Ctrl+R/F5), help panel (F1) and window-resize handling.
- Free-form parser for 12/24-hour times, numeric and named dates, relative words, weekdays,
  compound durations, named times (noon, midnight, morning, EOD) and time zones (abbreviations,
  region names, cities, UTC offsets, IANA and Windows zone names).
- Automatic fixes for backwards intervals (time-only ends, weekdays given backwards).
- `-Start`/`-End` for direct calculation, plus `-Version` and `-Help`.
- Returns a `TimeInterval.Result` object with `[datetime]` endpoints, a human-readable interval
  and machine-readable totals.
