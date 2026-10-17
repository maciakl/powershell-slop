# PSCalendar

A keyboard-driven calendar for the Windows terminal, written as a single
PowerShell script. It shows month, week, day and agenda views, lets you add
and edit events with all the fields iCloud and Google Calendar use, and
synchronises in both directions with **iCloud Calendar**, **Google Calendar**
and any other **CalDAV** server. A **US holidays** calendar is built in, and
you can subscribe to any published `.ics` / `webcal://` calendar.

```
 PSCalendar  Month  Week  Day  Agenda   ◄ October 2026 ►
       Sun              Mon              Tue              Wed              Thu              Fri              Sat
 11              │ 12             │ 13             │ 14             │ 15             │ 16 today       │ 17
                 │                │ 9:00am Standup │                │ 9:00am Standup │ Gym            │
                 │                │                │                │                │ 2:00pm Planning│
                 │                │                │                │                │ 10:00pm Dentist│
```

Version: **0.2.0**

## Contents

- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Command line](#command-line)
- [Using the calendar](#using-the-calendar)
- [Connecting iCloud](#connecting-icloud)
- [Connecting Google Calendar](#connecting-google-calendar)
- [Other CalDAV servers](#other-caldav-servers)
- [Holidays and subscribed calendars](#holidays-and-subscribed-calendars)
- [How synchronisation works](#how-synchronisation-works)
- [Event fields](#event-fields)
- [Where data is stored](#where-data-is-stored)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Changelog](#changelog)

## Requirements

- Windows 11 (Windows 10 works as well).
- Windows PowerShell 5.1 (built into Windows) **or** PowerShell 7.x.
- Nothing else. PSCalendar is one file (`PSCalendar.ps1`) and only uses
  PowerShell and the .NET libraries that ship with Windows.

A window of at least 60 × 16 characters is needed; 120 × 30 or larger is
recommended. Windows Terminal (the default terminal on Windows 11) gives the
best result, but the classic console window works too.

## Getting started

1. Save `PSCalendar.ps1` in a folder, for example `C:\Tools\PSCalendar`.
2. Windows blocks scripts downloaded from the internet until you allow them.
   Either unblock the file once and allow local scripts for your user:

   ```powershell
   Unblock-File C:\Tools\PSCalendar\PSCalendar.ps1
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

   or start it with a one-off bypass:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File C:\Tools\PSCalendar\PSCalendar.ps1
   ```

3. Run it:

   ```powershell
   .\PSCalendar.ps1
   ```

4. Press **N** to add an event, **C** to connect iCloud or Google calendars,
   and **?** to see all keys.

## Command line

```text
.\PSCalendar.ps1 [-View Month|Week|Day|Agenda] [-Date <date>] [-DataPath <folder>] [-NoSync]
.\PSCalendar.ps1 -SyncOnly [-DataPath <folder>]
.\PSCalendar.ps1 -Version
.\PSCalendar.ps1 -Help
```

| Parameter   | Meaning |
|-------------|---------|
| `-View`     | View to open with. Default `Month`. |
| `-Date`     | Date to open, e.g. `2026-12-24`. Default today. |
| `-DataPath` | Folder for settings and events. Default `%APPDATA%\PSCalendar`. |
| `-NoSync`   | Don't synchronise on start-up. |
| `-SyncOnly` | Synchronise all accounts without opening the interface, print the log and exit. The exit code is 1 when a calendar failed. Handy for Task Scheduler. |
| `-Version`  | Print the version number and exit. |
| `-Help`     | Print usage information and exit. |

`Get-Help .\PSCalendar.ps1 -Full` shows the built-in documentation too.

## Using the calendar

### Views

| Key | View |
|-----|------|
| **M** | Month: a grid with event titles in each day. |
| **W** | Week: seven days with an hourly timeline. Overlapping events are shown side by side. |
| **D** | Day: one day's timeline plus a panel with every detail of the selected event. |
| **A** | Agenda: a list of upcoming events from all calendars (60 days by default). |
| **Tab** / **Shift+Tab** | Next / previous view. |

### Keys

| Key | Action |
|-----|--------|
| Left / Right | Previous / next day |
| Up / Down | Month view: previous / next week. Other views: select an event |
| PgUp / PgDn (or `,` and `.`) | Previous / next month, week or day |
| Ctrl+Up / Ctrl+Down | Scroll the hours in the week and day views |
| T or Home | Today |
| G | Go to a date: `2026-12-24`, `today`, `tomorrow`, `fri`, `+2w`, `-1m` ... |
| N | New event (Shift+N: new all-day event) |
| Enter | Month view: open the day. Other views: edit the selected event |
| E | Edit the selected event |
| I or Space | Show all details of the selected event |
| Del or X | Delete the selected event (for repeating events you choose this occurrence or the whole series) |
| / | Search titles, locations, notes and attendees of all events. Esc clears the search |
| C | Calendars and accounts |
| S or F5 | Synchronise now |
| L | Sync log |
| O | Options |
| ? or F1 | Help |
| Q or Ctrl+C | Quit (asks whether to sync first if changes are waiting) |

### Forms

Event, account and option screens are forms:

- Up/Down or Tab move between fields.
- **Enter** edits a text field. Typing a character replaces the value, like a
  spreadsheet cell. Ctrl+U clears the field, Ctrl+V pastes.
- Left/Right (or Enter) change a choice, Space toggles a check box.
- **F10** or **Ctrl+S** saves (or choose `[ Save ]`). **Esc** cancels.
- Dates accept `2026-10-16`, `today`, `tomorrow`, weekday names and `+3d`,
  `+1w`, `+2m`. Times accept `9`, `930`, `9:30`, `14:00`, `2pm`, `noon`.

### Calendars screen (C)

| Key | Action |
|-----|--------|
| A | Add an account: iCloud, Google, other CalDAV, a subscribed calendar (`.ics` / `webcal://` address), or a local calendar |
| N | New local calendar (stays on this computer) |
| Enter | Edit the selected account (name, password, re-sign-in) or calendar (name, colour, show/hide, sync, default) |
| Space | Show or hide the selected calendar |
| Y | Turn sync on or off for the selected calendar |
| R | Re-read the calendar list from the server and choose calendars again |
| S | Synchronise the selected account now (subscriptions are downloaded again) |
| Del | Remove the account or calendar from PSCalendar (nothing is deleted on the server) |
| Esc | Back |

### Options (O)

Week start, 12/24-hour clock, the hour the timeline scrolls to, default
calendar, default event length and reminder, agenda length, US holidays
(off, public holidays, or holidays and observances), sync on start,
automatic sync interval, how far back and ahead to sync, conflict handling,
and whether Google e-mails guests about changes.

## Connecting iCloud

iCloud requires an **app-specific password**. Your normal Apple Account
password won't work.

1. Sign in at <https://account.apple.com>.
2. Go to **Sign-In and Security → App-Specific Passwords** and create one,
   e.g. named "PSCalendar".
3. In PSCalendar press **C**, then **A**, then choose **iCloud Calendar**.
4. Enter your Apple Account e-mail and the app-specific password
   (`xxxx-xxxx-xxxx-xxxx`).
5. Tick the calendars you want and confirm. PSCalendar offers to sync right
   away.

## Connecting Google Calendar

Google requires each desktop application to use its own OAuth client. You
create it once, for free:

1. Open <https://console.cloud.google.com> and create or select a project.
2. **APIs & Services → Library**: enable the **Google Calendar API**.
3. **APIs & Services → OAuth consent screen** (also called Google Auth
   Platform): choose **External**, enter an app name and your e-mail address,
   and add your Google address as a **test user**.
   - Apps left in *Testing* mode get sign-ins that expire after 7 days. To
     avoid signing in again every week, set the publishing status to
     **In production**. For personal use you can ignore the "unverified app"
     warning Google shows when you sign in.
4. **Credentials → Create credentials → OAuth client ID**, application type
   **Desktop app**. Copy the **client ID** and **client secret**.
5. In PSCalendar press **C**, **A**, choose **Google Calendar**, and paste the
   client ID and secret.
6. A browser window opens. Sign in and allow access. PSCalendar receives the
   answer on a temporary local port (`http://127.0.0.1:<port>/`) and
   continues by itself. If no browser opens, the sign-in link is copied to the
   clipboard; paste it into a browser. Esc cancels.
7. Tick the calendars to sync. Read-only calendars (holidays, other people's
   calendars) are unticked by default but can be added for viewing.

The sign-in uses the OAuth 2.0 *installed application* flow with PKCE and
asks for the `https://www.googleapis.com/auth/calendar` scope.

To sign in again later (for example after revoking access), open **C**,
select the Google account, press **Enter** and tick **Sign in again**.

## Other CalDAV servers

Choose **Other CalDAV server** and enter the server address, your user name
and password (or an app password). PSCalendar finds the calendars through
the standard CalDAV discovery (`current-user-principal` →
`calendar-home-set`, with `/.well-known/caldav` as fallback). Examples:

| Service | Server URL |
|---------|------------|
| Nextcloud | `https://cloud.example.com/remote.php/dav` |
| Fastmail | `https://caldav.fastmail.com/` |
| Radicale | `https://radicale.example.com/` |

## Holidays and subscribed calendars

### US holidays

A read-only **US Holidays** calendar is switched on by default. It is a
subscription to Google's free public holiday calendar
(`Holidays in United States`), so no Google account or sign-in is needed.
The feed covers about five years back and five years ahead and is kept up to
date by Google (new federal holidays, substitute days and so on).

Choose what you see in **Options (O) → US holidays**:

| Setting | Shows |
|---------|-------|
| **Public holidays** (default) | Federal holidays and their substitute days: New Year's Day, MLK Day, Juneteenth, Thanksgiving ... |
| **Holidays and observances** | Also observances such as Valentine's Day, Mother's Day, Halloween and daylight saving time changes |
| **Off** | Nothing. The calendar and its downloaded events are removed and nothing is downloaded |

To hide the holidays for a while without turning them off, select
**US Holidays** on the Calendars screen (**C**) and press **Space**. You can
also change its colour there. Removing it with **Del** is the same as
choosing **Off**.

The holidays are downloaded at start-up when they are more than a day old,
and whenever you press **S**. They stay on this computer, so they are shown
offline too. Downloading them sends an ordinary web request to
`calendar.google.com`; choose **Off** if you don't want that.

To show another country's holidays, subscribe to that country's feed (see
below), for example
`https://calendar.google.com/calendar/ical/en.uk%23holiday%40group.v.calendar.google.com/public/basic.ics`
for the United Kingdom, and switch the US holidays off.

### Subscribing to a calendar address

Many sites publish calendars as a link ending in `.ics` or starting with
`webcal://` (sports fixtures, school terms, a colleague's shared calendar,
the "secret address in iCal format" of a Google calendar ...). To add one:

1. Press **C**, then **A**, and choose **Subscribe to a calendar address**.
2. Paste the address. Leave the name empty to use the calendar's own name.
3. PSCalendar downloads it right away.

Subscribed calendars are **read only**. They are downloaded again once a day
(or as often as the calendar asks with `REFRESH-INTERVAL` /
`X-PUBLISHED-TTL`, between one hour and one week) and whenever you press
**S**. When the server supports it, an unchanged calendar isn't downloaded
again (`If-None-Match`). The whole calendar is downloaded, not only the sync
window, and events removed from it are removed here. Press **Enter** on the
subscription in the Calendars screen to rename it, change its address or
pause it.

## How synchronisation works

- **Two-way.** Local changes (new, edited and deleted events) are uploaded
  first. Then the server copy of every synchronised calendar is downloaded
  for the *sync window* (90 days back and 365 days ahead by default;
  adjustable in Options). Events deleted on the server are removed locally.
- **When.** On start-up (unless `-NoSync`), every 15 minutes while
  PSCalendar is open (adjustable, 0 turns it off), when you press **S**, and
  with `-SyncOnly`. Subscribed calendars (including the holidays) only
  download when they are due, see
  [above](#holidays-and-subscribed-calendars), or when you press **S**.
- **Offline.** Changes made while offline stay on this computer and are
  uploaded at the next successful sync. The title bar shows how many changes
  are waiting.
- **Conflicts.** Uploads use ETags. If an event changed on the server since
  it was downloaded, the default is that the **server copy wins** and the
  conflict is written to the sync log (**L**). In Options you can choose
  **My copy wins** instead, which overwrites the server.
- **Rejected changes.** If the server refuses a change permanently (for
  example editing an invitation you don't own), the server copy is restored
  and the log says so, so the change doesn't retry forever.
- **iCloud / CalDAV** uses `PROPFIND`, `REPORT` (`calendar-query`, with
  `calendar-multiget` as fallback), `PUT` and `DELETE`. The calendar's
  `getctag` is checked first, so an unchanged calendar isn't downloaded again.
  Properties PSCalendar doesn't edit (for example Apple travel-time settings,
  categories, attachments) are kept when an event is written back.
- **Google** uses the Calendar API v3 (`calendarList`, `events.list`,
  `insert`, `patch`, `delete`). Updates are sent with `PATCH`, so fields
  PSCalendar doesn't edit (such as Meet links and attachments) are left
  alone.

## Event fields

| Field | iCloud / CalDAV | Google |
|-------|-----------------|--------|
| Title, location, notes | `SUMMARY`, `LOCATION`, `DESCRIPTION` | `summary`, `location`, `description` |
| Calendar | the collection | the calendar |
| All day / start / end | `DTSTART` / `DTEND` (`VALUE=DATE`) | `start` / `end` (`date` or `dateTime`) |
| Time zone | `TZID` + generated `VTIMEZONE` | `timeZone` (IANA name) |
| Repeat | `RRULE` + `EXDATE` | `recurrence` |
| URL | `URL` | `source.url` |
| Status | `STATUS` | `status` |
| Show as busy/free | `TRANSP` | `transparency` |
| Visibility | `CLASS` | `visibility` |
| Event colour | n/a (calendar colour is used) | `colorId` |
| Reminders | `VALARM` (display, minutes before start) | `reminders` (popup), or the calendar default |
| Attendees | `ATTENDEE` (role, response) | `attendees` (optional, response) |
| Organizer | `ORGANIZER` (shown) | `organizer` (shown) |

The **Repeat** field has quick choices (daily, weekly on chosen days, every
weekday, monthly, yearly, with an interval and an end: never, after *N*
times, or on a date) and **Custom** for any RFC 5545 rule, for example
`FREQ=MONTHLY;BYDAY=-1FR;COUNT=12` (last Friday of the month, 12 times).
Rules from other apps (`BYDAY` with positions, `BYMONTHDAY`, `BYMONTH`,
`BYSETPOS`, `COUNT`, `UNTIL`, `INTERVAL`) are displayed correctly.

In the **Notes** field type `\n` for a new line.

## Where data is stored

Everything lives in `%APPDATA%\PSCalendar` (or the `-DataPath` folder):

| File | Contents |
|------|----------|
| `config.json` | Options, accounts and calendars |
| `events.json` | Local copy of all events, including changes not uploaded yet |

Passwords, the Google client secret and the Google sign-in token are
encrypted with Windows DPAPI for the current Windows user (via
`ConvertFrom-SecureString`). They can't be read by other users or on another
computer. Copying the folder to another PC therefore needs a new sign-in to
each account.

To start over, quit PSCalendar and delete the folder.

## Troubleshooting

- **"cannot be loaded because running scripts is disabled"**: see
  [Getting started](#getting-started) step 2.
- **Ctrl+S doesn't save in the classic console window**: the old console uses
  Ctrl+S to pause output. Use **F10**, or Windows Terminal.
- **Odd characters instead of lines**: use a font with box-drawing characters
  (Cascadia Mono, Consolas). If colours look wrong in an old console, set the
  environment variable `PSCALENDAR_ANSI=0` to draw with classic console
  colours instead of ANSI sequences (`PSCALENDAR_ANSI=1` forces ANSI).
- **iCloud says the password is wrong**: use an app-specific password, not
  your Apple Account password, and the Apple Account e-mail as user name.
- **Google: "access expired or was revoked"**: the OAuth app is probably still
  in *Testing* mode (7-day sign-ins). Publish it, then sign in again from the
  Calendars screen.
- **Something didn't sync**: press **L** for the sync log. Errors are red,
  conflicts and rejected changes yellow.
- PSCalendar can't run inside the PowerShell ISE; use a console or Windows
  Terminal.

## Known limitations

- Editing a repeating event changes **all** occurrences. A single occurrence
  can be deleted on its own, and occurrences already changed in another app
  can be edited, but a new single-occurrence change can't be made yet.
- Moving a repeating event to another calendar moves the series but not
  occurrences that were changed individually.
- Reminders are display/popup reminders measured before the start. E-mail
  and absolute-time alarms from other apps are not kept when an event is
  saved from PSCalendar.
- Extra dates added with `RDATE` are kept but not displayed.
- Only events inside the sync window are downloaded; older and later events
  stay as they were last downloaded.
- Wide characters (CJK, emoji) can push columns out of line.
- Subscribed calendars can't be edited, and only one calendar is read from
  each address.
- The built-in holidays are the US ones; other countries are added as a
  subscription.
- Events in Google calendars you can only read, and invitations you don't
  own, may be refused by the server when edited (see "Rejected changes"
  above).

## Changelog

### 0.2.0 - 2026-10-17

- Built-in **US Holidays** calendar from Google's public holiday feed, on by
  default. **Options → US holidays** chooses public holidays only, holidays
  and observances, or off. It can be hidden, recoloured or removed on the
  Calendars screen like any other calendar.
- New account type: **subscribe to a calendar address** (`.ics`,
  `webcal://`). Subscriptions are read only, refresh once a day (or as the
  feed asks) and on **S**, and skip the download when the server reports no
  change.
- Downloads accept gzip/deflate compression.
- A calendar can only be removed if another calendar that accepts new
  events is left.
- Automatic syncs that have nothing to do no longer overwrite the status
  line.

### 0.1.0 - 2026-10-16

First release.

- Month, week, day and agenda views with keyboard navigation, go-to-date and
  search across all calendars.
- Event form with title, calendar, all-day, start/end, time zone,
  recurrence (presets and custom RRULE), location, URL, notes, status,
  busy/free, visibility, Google event colour, reminders and attendees.
- Delete a single occurrence or a whole series of repeating events.
- Two-way sync with iCloud (CalDAV, app-specific password), Google Calendar
  (API v3, OAuth 2.0 with PKCE and loopback redirect) and other CalDAV
  servers, with ETag conflict detection, offline changes and automatic
  sync.
- Calendars screen to add accounts, pick calendars, set colours, show/hide,
  toggle sync, choose the default calendar and remove accounts.
- Options for week start, clock format, sync window, auto-sync interval,
  conflict policy and Google guest notifications.
- `-SyncOnly` for scheduled, non-interactive sync. `-Version` and `-Help`
  switches.
- Secrets stored encrypted with Windows DPAPI.
- Runs on Windows PowerShell 5.1 and PowerShell 7 without extra software.

## License

PSCalendar is an original work, not a port, so no upstream license applies.
