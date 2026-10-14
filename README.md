# PSClock

An interactive terminal world clock written in PowerShell. It is a single script with no
dependencies and runs on any Windows 11 machine in either **Windows PowerShell 5.1** (built in)
or **PowerShell 7+**.

```
 PSClock - World Clock                                              Live  Wed 2026-10-14 19:35:41
 Sort: City ^   Filter: (none)   Showing 3 of 3 zones
  City                 Time        Date       Day  Sun     Status    Offset    vsLocal Time zone
 ------------------------------------------------------------------------------------------------
 > Local time           19:35:41    2026-10-14 Wed  Night   Off hours UTC-04:00 0h      Eastern Daylight Time
   London               00:35:41    2026-10-15 Thu  Night   Off hours UTC+01:00 +5h     GMT Daylight Time
   New York             19:35:41    2026-10-14 Wed  Night   Off hours UTC-04:00 0h      Eastern Daylight Time
   Tokyo                08:35:41    2026-10-15 Thu  Day     Off hours UTC+09:00 +13h    Tokyo Standard Time
```

## Features

- **Live clock** for your local time zone (detected automatically from Windows settings) plus any
  number of other zones. The local zone is pinned to the top and highlighted.
- For every zone: **time, date, day of the week, day/night indicator, offset from UTC, difference
  from local time** and the time zone name (standard or daylight).
- **Business status**: each zone shows *Business* (Mon-Fri, 09:00-17:00 by default),
  *Off hours* or *Weekend*, colour coded.
- **Add zones** by
  - city name: `Tokyo`, `sao paulo`, `New York` (about 200 built-in cities plus every city named
    in the Windows time zone list),
  - country: `Japan`, `Brazil`,
  - abbreviation: `EST`, `PST`, `CET`, `JST`, `IST`, ... (ambiguous ones such as `CST` or `IST`
    list every meaning to pick from),
  - UTC offset: `+2`, `-5`, `+5:30`, `UTC-3`, `GMT+0545` (offers a fixed offset as well as the
    real zones with that offset, which follow daylight saving time).
- **Filter** the list by typing part of a city or zone name.
- **Sort** by city, time zone name, UTC offset or time of day, ascending or descending.
- **Convert** any date/time into all listed zones, e.g. `9am Tokyo`, `tomorrow 8:00 +2` or
  `2026-12-24 18:00 PST`.
- **12/24-hour** display.
- **Persistent** list and preferences, with an option to clear the list at any time.

## Requirements

- Windows 11 (or Windows 10) with Windows PowerShell 5.1 or PowerShell 7+.
- An interactive console: Windows Terminal (recommended), the classic PowerShell console or the
  VS Code terminal. The PowerShell ISE is not supported.

Nothing needs to be installed.

## Running

```powershell
.\PSClock.ps1
```

If script execution is blocked on your machine, run it once with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\PSClock.ps1
```

or unblock the downloaded file with `Unblock-File .\PSClock.ps1`.

### Parameters

| Parameter        | Default                            | Description                                                                 |
|------------------|------------------------------------|-----------------------------------------------------------------------------|
| `-ConfigPath`    | `%APPDATA%\PSClock\PSClock.json`   | Where the zone list and preferences are stored.                             |
| `-Symbols`       | `Auto`                             | `Unicode`, `Ascii` or `Auto` (Unicode in Windows Terminal, ASCII elsewhere). |
| `-BusinessStart` | `9`                                | Hour the business day starts (0-23).                                        |
| `-BusinessEnd`   | `17`                               | Hour the business day ends (1-24).                                          |

Full help is available with `Get-Help .\PSClock.ps1 -Full`.

## Keys

| Key                          | Action                                                         |
|------------------------------|----------------------------------------------------------------|
| Up / Down, PgUp / PgDn, Home / End | Move the selection                                       |
| `A`, `+` or Insert           | Add a time zone (search as you type, Enter adds the highlighted match) |
| `D`, `-` or Delete           | Remove the selected time zone                                  |
| `/` or `F`                   | Filter the list (Enter keeps the filter, Esc clears it)        |
| `S`                          | Cycle the sort column: City, Zone, Offset, Time                |
| `R`                          | Reverse the sort order                                         |
| `T`                          | Convert a date/time into all zones                             |
| `L` or Esc                   | Return to live time after a conversion                         |
| `H`                          | Toggle 12/24-hour clock                                        |
| `C`                          | Clear the whole list (asks for confirmation)                   |
| `?` or F1                    | Help screen                                                    |
| `Q` or Ctrl+C                | Quit                                                           |

### Converting times

Press `T` and type a date and/or time, optionally followed by a zone. Without a zone, the time
is read in the zone of the **selected row** (use Up/Down while typing to change it).

| Input                     | Meaning                                                  |
|---------------------------|----------------------------------------------------------|
| `14:30`                   | Today at 14:30 in the selected zone                      |
| `9am Tokyo`               | Today at 09:00 in Tokyo                                  |
| `6:15 pm New York`        | Today at 18:15 in New York                               |
| `tomorrow 8:00 +2`        | Tomorrow at 08:00 at UTC+02:00                           |
| `2026-12-24 18:00 PST`    | That date and time in US Pacific time                    |
| `now`                     | The current moment                                       |

Dates are accepted in ISO format (`yyyy-MM-dd`) or in your Windows regional format. The title
bar turns magenta while a converted time is shown; press `L` to go back to the live clock.
Times that do not exist because of a daylight saving change are reported as such.

## Where the list is stored

The list of zones and the display preferences (sort column/order, 12/24-hour clock) are saved
as JSON in your roaming application data folder:

```
%APPDATA%\PSClock\PSClock.json
```

This is the standard Windows location for per-user application settings: it is not cleaned up
by Disk Cleanup or temp-file tools and roams with your profile in domain environments.
To protect the list from accidental loss:

- Every save is written to a temporary file first and then swapped in, so the file is never
  left half-written.
- The previous version is kept as `PSClock.json.bak`, and is used automatically if the main
  file is damaged.
- A damaged file is never overwritten silently; a copy is kept as
  `PSClock.json.corrupt-<timestamp>`.

On first start (when no settings file exists) the list contains New York, London and Tokyo.
Press `C` to clear the list at any time; the empty list is saved and stays empty. To reset
PSClock completely, delete the `%APPDATA%\PSClock` folder.

## Notes and limitations

- Day/night is a simple rule: 06:00-18:00 local wall-clock time counts as day. It does not
  calculate actual sunrise/sunset.
- Business hours assume a Monday-Friday working week in every zone.
- *Sort by Time* orders zones by time of day, ignoring the date (sorting by full date and time
  would be identical to sorting by offset).
- Zones use Windows time zone IDs so that they work in Windows PowerShell 5.1. Daylight saving
  rules come from Windows and are kept current by Windows Update.
- If the settings file contains a zone that does not exist on the current machine (for example
  copied from another system), it is shown with a warning so it can be removed.

## Development

The script can be dot-sourced to load its functions without starting the UI, which is handy
for testing:

```powershell
. .\PSClock.ps1 -ConfigPath "$env:TEMP\psclock-test.json"
Find-ClockZone -Query 'CST'
ConvertFrom-ClockTimeText -Text '9am Tokyo' -DefaultEntry ([pscustomobject]@{ Label = 'Local'; ZoneId = [TimeZoneInfo]::Local.Id })
```

The script passes PSScriptAnalyzer with no warnings.
