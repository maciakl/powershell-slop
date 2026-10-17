<#
.SYNOPSIS
    PSCalendar - a keyboard driven terminal (TUI) calendar with two-way
    iCloud, CalDAV and Google Calendar sync.

.DESCRIPTION
    PSCalendar shows your calendars in month, week, day and agenda views
    right inside the console. Events are created and edited in a full screen
    form that supports the fields used by iCloud and Google Calendar: title,
    calendar, all-day, start/end, time zone, recurrence, location, URL,
    notes, status, availability (busy/free), visibility, colour, reminders
    and attendees.

    Calendars can be synchronised in both directions with:
      * iCloud Calendar     - CalDAV with an app-specific password
      * Google Calendar     - Google Calendar API v3 with OAuth 2.0 (PKCE)
      * Other CalDAV server - Nextcloud, Fastmail, Radicale, ...
    Local calendars that never leave the computer are supported too, as are
    read-only subscribed calendars (any .ics / webcal:// address). A US
    holidays calendar is built in and can be switched off in Options.

    The whole application is this one script. It only uses components that
    ship with Windows 11 (Windows PowerShell 5.1 or PowerShell 7 and .NET).

.PARAMETER Version
    Print the version number and exit.

.PARAMETER Help
    Print usage information and exit.

.PARAMETER View
    The view to open with: Month (default), Week, Day or Agenda.

.PARAMETER Date
    The date to open. Defaults to today.

.PARAMETER DataPath
    Folder that holds the settings and the local event store.
    Defaults to %APPDATA%\PSCalendar.

.PARAMETER NoSync
    Do not synchronise on start-up, even when that is enabled in Options.

.PARAMETER SyncOnly
    Synchronise every account without opening the user interface, print the
    log and exit. Exit code 1 means at least one calendar failed. Useful for
    scheduled tasks.

.EXAMPLE
    .\PSCalendar.ps1
    Opens the calendar in month view.

.EXAMPLE
    .\PSCalendar.ps1 -View Week -Date 2026-12-24
    Opens the week that contains 24 December 2026.

.EXAMPLE
    .\PSCalendar.ps1 -SyncOnly
    Synchronises all accounts and exits.

.NOTES
    Name    : PSCalendar
    Version : 0.2.0
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Interactive application; all functions are internal and confirm destructive actions in the UI.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Only used to encrypt secrets with DPAPI before they are written to disk.')]
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Version')]
    [switch]$Version,

    [Parameter(ParameterSetName = 'Help')]
    [switch]$Help,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Month', 'Week', 'Day', 'Agenda')]
    [string]$View = 'Month',

    [Parameter(ParameterSetName = 'Run')]
    [datetime]$Date = (Get-Date),

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'SyncOnly')]
    [string]$DataPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'PSCalendar'),

    [Parameter(ParameterSetName = 'Run')]
    [switch]$NoSync,

    [Parameter(ParameterSetName = 'SyncOnly', Mandatory = $true)]
    [switch]$SyncOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ------------------------------------------------------------ Constants and state

$script:AppName = 'PSCalendar'
$script:AppVersion = '0.2.0'
$script:ProdId = '-//PSCalendar//PSCalendar ' + $script:AppVersion + '//EN'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:E = [string][char]27

# Box drawing and symbol glyphs. They are built from code points so the file
# stays pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).
# All of them exist in code page 437, so they render in every console font.
$script:G = @{
    H     = [string][char]0x2500
    V     = [string][char]0x2502
    TL    = [string][char]0x250C
    TR    = [string][char]0x2510
    BL    = [string][char]0x2514
    BR    = [string][char]0x2518
    Left  = [string][char]0x25C4
    Right = [string][char]0x25BA
    Up    = [string][char]0x25B2
    Down  = [string][char]0x25BC
    Block = [string][char]0x2588
    Bar   = [string][char]0x258C
}

$script:ICloudUrl = 'https://caldav.icloud.com/'
$script:GoogleAuthUrl = 'https://accounts.google.com/o/oauth2/v2/auth'
$script:GoogleTokenUrl = 'https://oauth2.googleapis.com/token'
$script:GoogleApiBase = 'https://www.googleapis.com/calendar/v3'
$script:GoogleScope = 'https://www.googleapis.com/auth/calendar'

# Built-in US holidays calendar: a read-only subscription to Google's public
# holiday feed (free, no account or key needed, covers about ten years and
# labels each event "Public holiday" or "Observance").
$script:HolidayAccountId = 'holidays'
$script:HolidayCalendarId = 'holidays-us'
$script:HolidayFeedUrl = 'https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics'
$script:HolidayModes = [ordered]@{ Off = 'Off'; Public = 'Public holidays'; All = 'Holidays and observances' }
# Subscribed calendars are downloaded at most this often unless the feed asks
# for another interval (REFRESH-INTERVAL / X-PUBLISHED-TTL) or you press S.
$script:SubscriptionRefreshMinutes = 1440

# iCalendar weekday codes <-> .NET DayOfWeek.
$script:DayCodes = @{
    SU = [DayOfWeek]::Sunday; MO = [DayOfWeek]::Monday; TU = [DayOfWeek]::Tuesday
    WE = [DayOfWeek]::Wednesday; TH = [DayOfWeek]::Thursday; FR = [DayOfWeek]::Friday
    SA = [DayOfWeek]::Saturday
}
$script:DayCodeOf = @('SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA')

# Google event colour ids, their names and the closest console colour.
$script:GoogleColorNames = [ordered]@{
    '' = 'Calendar colour'; '1' = 'Lavender'; '2' = 'Sage'; '3' = 'Grape'; '4' = 'Flamingo'
    '5' = 'Banana'; '6' = 'Tangerine'; '7' = 'Peacock'; '8' = 'Graphite'; '9' = 'Blueberry'
    '10' = 'Basil'; '11' = 'Tomato'
}
$script:GoogleColorConsole = @{
    '1' = 'Blue'; '2' = 'Green'; '3' = 'Magenta'; '4' = 'Red'; '5' = 'Yellow'; '6' = 'DarkYellow'
    '7' = 'Cyan'; '8' = 'DarkGray'; '9' = 'DarkBlue'; '10' = 'DarkGreen'; '11' = 'DarkRed'
}

# RGB values of the 16 console colours, used to map server colours.
$script:ConsoleRgb = [ordered]@{
    DarkBlue = 0x000080; DarkGreen = 0x008000; DarkCyan = 0x008080; DarkRed = 0x800000
    DarkMagenta = 0x800080; DarkYellow = 0x808000; Blue = 0x0000FF; Green = 0x00FF00
    Cyan = 0x00FFFF; Red = 0xFF0000; Magenta = 0xFF00FF; Yellow = 0xFFFF00
}
$script:CalendarPalette = @('Cyan', 'Green', 'Yellow', 'Magenta', 'Red', 'Blue', 'DarkYellow', 'DarkCyan', 'DarkGreen', 'DarkMagenta')
# Console colours that need black text on top of them.
# Cursor highlight: White is never used as an event colour, so it stands out.
$script:CursorFg = 'Black'
$script:CursorBg = 'White'
$script:LightColors = @('Gray', 'Green', 'Cyan', 'Yellow', 'White', 'Magenta', 'DarkYellow', 'DarkCyan')

# ANSI SGR foreground codes indexed by [ConsoleColor] value.
$script:AnsiFg = @(30, 34, 32, 36, 31, 35, 33, 37, 90, 94, 92, 96, 91, 95, 93, 97)

# Windows time zone id -> IANA ids. The first IANA id is the canonical one.
$script:TzMapText = @'
Dateline Standard Time|Etc/GMT+12
UTC-11|Etc/GMT+11
Hawaiian Standard Time|Pacific/Honolulu
Alaskan Standard Time|America/Anchorage America/Juneau
Pacific Standard Time|America/Los_Angeles America/Vancouver America/Tijuana US/Pacific
US Mountain Standard Time|America/Phoenix
Mountain Standard Time|America/Denver America/Edmonton America/Boise US/Mountain
Central Standard Time|America/Chicago America/Winnipeg US/Central
Canada Central Standard Time|America/Regina
Central America Standard Time|America/Guatemala America/Costa_Rica
Central Standard Time (Mexico)|America/Mexico_City
Eastern Standard Time|America/New_York America/Toronto America/Detroit America/Montreal US/Eastern
US Eastern Standard Time|America/Indiana/Indianapolis America/Indianapolis
SA Pacific Standard Time|America/Bogota America/Lima
Atlantic Standard Time|America/Halifax
Venezuela Standard Time|America/Caracas
SA Western Standard Time|America/La_Paz
Pacific SA Standard Time|America/Santiago
Newfoundland Standard Time|America/St_Johns
E. South America Standard Time|America/Sao_Paulo
Argentina Standard Time|America/Argentina/Buenos_Aires America/Buenos_Aires
Greenland Standard Time|America/Nuuk America/Godthab
UTC-02|Etc/GMT+2
Azores Standard Time|Atlantic/Azores
Cape Verde Standard Time|Atlantic/Cape_Verde
GMT Standard Time|Europe/London Europe/Dublin Europe/Lisbon
Greenwich Standard Time|Atlantic/Reykjavik
W. Europe Standard Time|Europe/Berlin Europe/Amsterdam Europe/Rome Europe/Stockholm Europe/Vienna Europe/Zurich Europe/Oslo
Central Europe Standard Time|Europe/Budapest Europe/Prague Europe/Belgrade Europe/Bratislava Europe/Ljubljana
Romance Standard Time|Europe/Paris Europe/Brussels Europe/Copenhagen Europe/Madrid
Central European Standard Time|Europe/Warsaw Europe/Zagreb Europe/Sarajevo
W. Central Africa Standard Time|Africa/Lagos
GTB Standard Time|Europe/Bucharest Europe/Athens
E. Europe Standard Time|Europe/Chisinau
Egypt Standard Time|Africa/Cairo
FLE Standard Time|Europe/Kyiv Europe/Kiev Europe/Helsinki Europe/Riga Europe/Tallinn Europe/Vilnius Europe/Sofia
Israel Standard Time|Asia/Jerusalem
South Africa Standard Time|Africa/Johannesburg
Turkey Standard Time|Europe/Istanbul
Arabic Standard Time|Asia/Baghdad
Arab Standard Time|Asia/Riyadh
Russian Standard Time|Europe/Moscow
E. Africa Standard Time|Africa/Nairobi
Iran Standard Time|Asia/Tehran
Arabian Standard Time|Asia/Dubai
Afghanistan Standard Time|Asia/Kabul
Pakistan Standard Time|Asia/Karachi
West Asia Standard Time|Asia/Tashkent
India Standard Time|Asia/Kolkata Asia/Calcutta
Nepal Standard Time|Asia/Kathmandu
Bangladesh Standard Time|Asia/Dhaka
Myanmar Standard Time|Asia/Yangon Asia/Rangoon
SE Asia Standard Time|Asia/Bangkok Asia/Jakarta Asia/Ho_Chi_Minh
China Standard Time|Asia/Shanghai Asia/Hong_Kong
Singapore Standard Time|Asia/Singapore Asia/Manila Asia/Kuala_Lumpur
Taipei Standard Time|Asia/Taipei
W. Australia Standard Time|Australia/Perth
Korea Standard Time|Asia/Seoul
Tokyo Standard Time|Asia/Tokyo
Cen. Australia Standard Time|Australia/Adelaide
AUS Central Standard Time|Australia/Darwin
E. Australia Standard Time|Australia/Brisbane
AUS Eastern Standard Time|Australia/Sydney Australia/Melbourne Australia/Canberra
Tasmania Standard Time|Australia/Hobart
West Pacific Standard Time|Pacific/Port_Moresby
New Zealand Standard Time|Pacific/Auckland
Tonga Standard Time|Pacific/Tongatapu
'@

# Runtime state.
$script:Config = $null
$script:Events = New-Object 'System.Collections.Generic.List[object]'
$script:DataDir = ''
$script:ConfigFile = ''
$script:EventsFile = ''
$script:DataVersion = 0
$script:InstanceCache = @{}
$script:TzCache = @{}
$script:WinToIana = @{}
$script:IanaToWin = @{}
$script:LocalIana = $null
$script:TokenCache = @{}
$script:HttpClient = $null
$script:SyncLog = New-Object 'System.Collections.Generic.List[string]'
$script:LastSyncTime = $null
$script:LastSyncAttempt = [datetime]::MinValue
$script:SyncSnapshot = $null
$script:TuiActive = $false
$script:Buf = $null
$script:AttrFill = $null
$script:PrevRows = $null
$script:UseAnsi = $false
$script:State = $null

#endregion

#region ------------------------------------------------------------ General helpers

function Get-Prop {
    <# Reads a property from an object or dictionary without tripping StrictMode. #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-PropList {
    <# Emits the items of an array property (nothing when it is missing). Wrap calls in @(). #>
    param($Object, [string]$Name)
    $v = Get-Prop -Object $Object -Name $Name
    if ($null -ne $v) { foreach ($i in @($v)) { if ($null -ne $i) { $i } } }
}

function New-Id {
    <# Returns a new random identifier. #>
    return [guid]::NewGuid().ToString('N')
}

function ConvertTo-DisplayText {
    <# Makes text safe to draw: no control characters, no surrogate pairs. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '[\r\n\t]+', ' '
    $t = $t -replace '[\x00-\x1F\x7F]', ''
    return ($t -replace '[\uD800-\uDBFF][\uDC00-\uDFFF]', '?')
}

function Format-Cell {
    <# Pads or truncates text to exactly the given width. #>
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width) }
    return $Text.PadRight($Width)
}

function Format-Center {
    <# Centres text within the given width. #>
    param([string]$Text, [int]$Width)
    if ($Text.Length -ge $Width) { return (Format-Cell $Text $Width) }
    $left = [int][Math]::Floor(($Width - $Text.Length) / 2)
    return (Format-Cell ((' ' * $left) + $Text) $Width)
}

function Format-WrapText {
    <# Word-wraps text to the given width and emits one string per line. #>
    param([string]$Text, [int]$Width)
    if ($Width -lt 1) { $Width = 1 }
    if ($null -eq $Text) { $Text = '' }
    foreach ($para in (($Text -replace "`r", '') -split "`n")) {
        $para = ConvertTo-DisplayText $para
        $line = ''
        foreach ($word in ($para -split ' ')) {
            while ($word.Length -gt $Width) {
                if ($line) { $line; $line = '' }
                $word.Substring(0, $Width)
                $word = $word.Substring($Width)
            }
            if (-not $line) { $line = $word }
            elseif ($line.Length + 1 + $word.Length -le $Width) { $line += ' ' + $word }
            else { $line; $line = $word }
        }
        $line
    }
}

function Get-InnermostMessage {
    <# Returns the message of the innermost exception. #>
    param([Exception]$Exception)
    $e = $Exception
    while ($null -ne $e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

function Protect-Secret {
    <# Encrypts a secret for the current Windows user (DPAPI). #>
    param([string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}

function Unprotect-Secret {
    <# Decrypts a secret produced by Protect-Secret. #>
    param([string]$CipherText)
    if ([string]::IsNullOrEmpty($CipherText)) { return '' }
    $secure = ConvertTo-SecureString -String $CipherText
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Save-JsonFile {
    <# Writes an object as UTF-8 JSON, replacing the file atomically. #>
    param([string]$Path, $InputObject)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 20
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Read-JsonFile {
    <# Reads a JSON file, returning $null when it is missing or empty. #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function ConvertTo-QueryString {
    <# Builds an URL-encoded query string from a dictionary. #>
    param([System.Collections.IDictionary]$Values)
    $parts = foreach ($k in $Values.Keys) {
        [Uri]::EscapeDataString([string]$k) + '=' + [Uri]::EscapeDataString([string]$Values[$k])
    }
    return ($parts -join '&')
}

function ConvertFrom-QueryString {
    <# Parses an URL query string into a hashtable. #>
    param([string]$Query)
    $result = @{}
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $key = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $value = ''
        if ($kv.Count -gt 1) { $value = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
        $result[$key] = $value
    }
    return $result
}

#endregion

#region ------------------------------------------------------------ Dates and time zones

$script:WallFormats = [string[]]@("yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm", 'yyyyMMdd')

function ConvertFrom-WallString {
    <# Parses a stored wall-clock value ("20261016T093000" or "20261016"). #>
    param([string]$Text)
    $t = $Text.Trim().TrimEnd('Z', 'z')
    return [datetime]::ParseExact($t, $script:WallFormats, $script:Inv, [System.Globalization.DateTimeStyles]::None)
}

function ConvertTo-WallString {
    <# Formats a DateTime as a stored wall-clock value. #>
    param([datetime]$DateTime, [bool]$DateOnly = $false)
    if ($DateOnly) { return $DateTime.ToString('yyyyMMdd', $script:Inv) }
    return $DateTime.ToString("yyyyMMdd'T'HHmmss", $script:Inv)
}

function Get-UtcStamp {
    <# Current time as an iCalendar UTC stamp. #>
    return (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", $script:Inv)
}

function Initialize-TimeZoneMap {
    <# Builds the Windows <-> IANA time zone lookup tables. #>
    foreach ($line in ($script:TzMapText -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $parts = $line.Split('|')
        $win = $parts[0].Trim()
        $ianas = @($parts[1].Trim() -split '\s+')
        $script:WinToIana[$win] = $ianas[0]
        foreach ($i in $ianas) { if (-not $script:IanaToWin.ContainsKey($i)) { $script:IanaToWin[$i] = $win } }
    }
}

function Resolve-TimeZoneId {
    <# Finds a TimeZoneInfo for an IANA or Windows id; $null when unknown. #>
    param([string]$Id)
    if ($Id -match '^(UTC|GMT|Z|Etc/UTC|Etc/GMT|Etc/Universal|Etc/Zulu|Universal|Zulu)$') { return [TimeZoneInfo]::Utc }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch { Write-Verbose "Time zone '$Id' is not a system id." }
    if ($script:IanaToWin.ContainsKey($Id)) {
        try { return [TimeZoneInfo]::FindSystemTimeZoneById($script:IanaToWin[$Id]) } catch { Write-Verbose "No Windows zone for '$Id'." }
    }
    return $null
}

function Get-TimeZoneById {
    <# Returns the TimeZoneInfo for an id. Blank means local (floating) time. #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return [TimeZoneInfo]::Local }
    if ($script:TzCache.ContainsKey($Id)) { return $script:TzCache[$Id] }
    $tz = Resolve-TimeZoneId $Id
    if ($null -eq $tz) { $tz = [TimeZoneInfo]::Local }
    $script:TzCache[$Id] = $tz
    return $tz
}

function Test-TimeZoneId {
    <# True when a time zone id can be resolved (blank counts as valid). #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $true }
    return ($null -ne (Resolve-TimeZoneId $Id.Trim()))
}

function Get-LocalIanaTimeZone {
    <# Returns the IANA name of the local time zone ('' when it is unknown). #>
    if ($null -ne $script:LocalIana) { return $script:LocalIana }
    $local = [TimeZoneInfo]::Local
    $result = ''
    if ($local.Id -match '/') { $result = $local.Id }
    elseif ($script:WinToIana.ContainsKey($local.Id)) { $result = $script:WinToIana[$local.Id] }
    else {
        # .NET 6+ (PowerShell 7) can convert any Windows id.
        $method = [TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType()))
        if ($null -ne $method) {
            $iana = $null
            if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($local.Id, [ref]$iana)) { $result = $iana }
        }
    }
    if (-not $result -and $local.Id -eq 'UTC') { $result = 'UTC' }
    $script:LocalIana = $result
    return $result
}

function ConvertTo-IanaTimeZone {
    <# Converts a stored time zone id to an IANA id for Google ('' when impossible). #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return (Get-LocalIanaTimeZone) }
    if ($Id -match '/' -or $Id -eq 'UTC') { return $Id }
    if ($script:WinToIana.ContainsKey($Id)) { return $script:WinToIana[$Id] }
    return ''
}

function Convert-WallTime {
    <# Converts a wall-clock DateTime from one time zone to another. #>
    param([datetime]$DateTime, [TimeZoneInfo]$From, [TimeZoneInfo]$To)
    $dt = [datetime]::SpecifyKind($DateTime, [DateTimeKind]::Unspecified)
    if ($From.Id -eq $To.Id) { return $dt }
    try { $r = [TimeZoneInfo]::ConvertTime($dt, $From, $To) }
    catch { $r = [TimeZoneInfo]::ConvertTime($dt.AddHours(1), $From, $To) } # time skipped by a DST change
    return [datetime]::SpecifyKind($r, [DateTimeKind]::Unspecified)
}

function ConvertTo-LocalTime {
    <# Converts a stored wall value in a time zone to local time. #>
    param([string]$Wall, [string]$TimeZone, [bool]$AllDay = $false)
    $dt = ConvertFrom-WallString $Wall
    if ($AllDay -or [string]::IsNullOrEmpty($TimeZone)) { return $dt }
    return (Convert-WallTime -DateTime $dt -From (Get-TimeZoneById $TimeZone) -To ([TimeZoneInfo]::Local))
}

function Convert-WallString {
    <# Converts a stored wall value between two time zones. #>
    param([string]$Wall, [string]$FromTz, [string]$ToTz, [bool]$AllDay = $false)
    if ($AllDay -or $FromTz -eq $ToTz) { return $Wall }
    $dt = Convert-WallTime -DateTime (ConvertFrom-WallString $Wall) -From (Get-TimeZoneById $FromTz) -To (Get-TimeZoneById $ToTz)
    return (ConvertTo-WallString $dt)
}

function Get-InstantKey {
    <# Returns a key identifying a point in time, used to match recurrence ids. #>
    param([datetime]$Wall, [string]$TimeZone, [bool]$AllDay)
    if ($AllDay) { return 'D' + $Wall.ToString('yyyyMMdd', $script:Inv) }
    $utc = Convert-WallTime -DateTime $Wall -From (Get-TimeZoneById $TimeZone) -To ([TimeZoneInfo]::Utc)
    return 'T' + $utc.ToString('yyyyMMddHHmm', $script:Inv)
}

function ConvertTo-DateTimeOffsetValue {
    <# Accepts a string or DateTime (PowerShell 7 converts JSON dates) and returns a DateTimeOffset. #>
    param($Value)
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) { return [DateTimeOffset]::new([datetime]$Value) }
    return [DateTimeOffset]::Parse([string]$Value, $script:Inv)
}

function Get-WeekStartDay {
    <# The configured first day of the week. #>
    return [DayOfWeek]$script:Config.Settings.WeekStart
}

function Get-WeekStart {
    <# The first day of the week that contains a date. #>
    param([datetime]$Day)
    $ws = [int](Get-WeekStartDay)
    $offset = (7 + [int]$Day.DayOfWeek - $ws) % 7
    return $Day.Date.AddDays(-$offset)
}

function Format-Time {
    <# Formats a time of day with the configured 12h/24h clock. #>
    param([datetime]$Time)
    if ($script:Config.Settings.TimeFormat -eq '12h') { return $Time.ToString('h:mmtt', $script:Inv).ToLowerInvariant() }
    return $Time.ToString('HH:mm', $script:Inv)
}

function Format-HourLabel {
    <# Short label for the hour gutter in the week and day views. #>
    param([int]$Hour)
    if ($script:Config.Settings.TimeFormat -eq '12h') {
        $h = $Hour % 12; if ($h -eq 0) { $h = 12 }
        $suffix = 'am'; if ($Hour -ge 12) { $suffix = 'pm' }
        return ('{0,2}{1}' -f $h, $suffix)
    }
    return ('{0:00}:00' -f $Hour)
}

function Get-DayName {
    <# Abbreviated day name in the user's language. #>
    param([DayOfWeek]$Day)
    return (Get-Culture).DateTimeFormat.AbbreviatedDayNames[[int]$Day]
}

function ConvertFrom-UserDate {
    <# Parses a date typed by the user. Supports ISO dates, today/tomorrow, weekday names and +3d/-2w/+1m/+1y. #>
    param([string]$Text, [datetime]$Base = (Get-Date).Date)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().ToLowerInvariant()
    $today = (Get-Date).Date
    if ($t -eq 'today' -or $t -eq 'now') { return $today }
    if ($t -eq 'tomorrow' -or $t -eq 'tom') { return $today.AddDays(1) }
    if ($t -eq 'yesterday') { return $today.AddDays(-1) }
    if ($t -match '^([+-])\s*(\d+)\s*([dwmy]?)$') {
        $n = [int]$Matches[2]
        if ($Matches[1] -eq '-') { $n = -$n }
        switch ($Matches[3]) {
            'w' { return $Base.Date.AddDays(7 * $n) }
            'm' { return $Base.Date.AddMonths($n) }
            'y' { return $Base.Date.AddYears($n) }
            default { return $Base.Date.AddDays($n) }
        }
    }
    for ($i = 0; $i -lt 7; $i++) {
        $names = @($script:DayCodeOf[$i].ToLowerInvariant(), ([DayOfWeek]$i).ToString().ToLowerInvariant(),
            ([DayOfWeek]$i).ToString().Substring(0, 3).ToLowerInvariant())
        if ($names -contains $t) {
            $delta = ($i - [int]$today.DayOfWeek + 7) % 7
            return $today.AddDays($delta)
        }
    }
    $dt = [datetime]::MinValue
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-M-d', 'yyyy/M/d', 'yyyyMMdd', 'yyyy.M.d')
    if ([datetime]::TryParseExact($Text.Trim(), $formats, $script:Inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt.Date }
    if ([datetime]::TryParse($Text.Trim(), (Get-Culture), [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt.Date }
    return $null
}

function ConvertFrom-UserTime {
    <# Parses a time typed by the user (9, 930, 9:30, 21:15, 9pm, 9:30am, noon). #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = ($Text.Trim().ToLowerInvariant() -replace '\s+', '')
    if ($t -eq 'noon') { return (New-TimeSpan -Hours 12) }
    if ($t -eq 'midnight') { return [TimeSpan]::Zero }
    if ($t -notmatch '^(\d{1,2})(?:[:.h]?(\d{2}))?(a|p|am|pm)?$') { return $null }
    $h = [int]$Matches[1]
    $m = 0
    if ($Matches[2]) { $m = [int]$Matches[2] }
    $ap = [string]$Matches[3]
    if ($ap) {
        if ($h -lt 1 -or $h -gt 12) { return $null }
        if ($ap.StartsWith('p') -and $h -lt 12) { $h += 12 }
        if ($ap.StartsWith('a') -and $h -eq 12) { $h = 0 }
    }
    if ($h -gt 23 -or $m -gt 59) { return $null }
    return (New-TimeSpan -Hours $h -Minutes $m)
}

#endregion

#region ------------------------------------------------------------ Data model and storage

function New-CalEvent {
    <# Creates an empty event object with every supported field. #>
    param([string]$CalendarId = '')
    $stamp = Get-UtcStamp
    return [pscustomobject]@{
        Id               = New-Id
        CalendarId       = $CalendarId
        Uid              = ''        # iCalendar UID (Google: iCalUID)
        RemoteId         = ''        # Google event id
        MasterId         = ''        # Google id of the recurring master (for exceptions)
        Href             = ''        # CalDAV resource URL
        ETag             = ''
        Summary          = ''
        Location         = ''
        Description      = ''
        Url              = ''
        Start            = ''        # wall clock in TimeZone, "yyyyMMddTHHmmss" or "yyyyMMdd"
        End              = ''        # exclusive end (for all-day events the day after)
        AllDay           = $false
        TimeZone         = ''        # IANA id, 'UTC' or '' for floating time
        RRule            = ''
        ExDates          = [string[]]@()
        RecurrenceId     = ''        # set on a changed occurrence of a recurring event
        Status           = 'CONFIRMED'
        Transparency     = 'OPAQUE'  # OPAQUE = busy, TRANSPARENT = free
        Visibility       = ''        # '', PUBLIC, PRIVATE, CONFIDENTIAL
        ColorId          = ''        # Google colour id
        OrganizerEmail   = ''
        OrganizerName    = ''
        Attendees        = @()
        Reminders        = [int[]]@() # minutes before the start
        RemindersDefault = $false     # Google: use the calendar's default reminders
        ExtraProps       = [string[]]@() # unknown iCalendar properties kept for round trips
        RecurrenceExtra  = [string[]]@() # unknown Google recurrence lines (RDATE ...)
        Sequence         = 0
        Created          = $stamp
        Modified         = $stamp
        Dirty            = $false     # local change that still has to be uploaded
        Deleted          = $false     # deleted locally, delete on the server next sync
    }
}

function New-Attendee {
    <# Creates an attendee record. #>
    param([string]$Email, [string]$Name = '', [string]$Role = 'REQ-PARTICIPANT', [string]$Status = 'NEEDS-ACTION')
    if (-not $Role) { $Role = 'REQ-PARTICIPANT' }
    if (-not $Status) { $Status = 'NEEDS-ACTION' }
    return [pscustomobject]@{ Email = $Email; Name = $Name; Role = $Role.ToUpperInvariant(); Status = $Status.ToUpperInvariant() }
}

function Copy-CalEvent {
    <# Returns a deep copy of an event. #>
    param($Event)
    return (ConvertTo-CalEvent $Event)
}

function ConvertTo-CalEvent {
    <# Normalises an event read from disk (or another event) into a complete event object. #>
    param($Raw)
    $ev = New-CalEvent
    foreach ($p in @($ev.PSObject.Properties)) {
        $sp = $Raw.PSObject.Properties[$p.Name]
        if ($null -eq $sp -or $null -eq $sp.Value) { continue }
        $n = $p.Name
        $v = $sp.Value
        if ($n -eq 'ExDates' -or $n -eq 'ExtraProps' -or $n -eq 'RecurrenceExtra') {
            $ev.$n = [string[]]@(foreach ($x in @($v)) { if ($null -ne $x) { [string]$x } })
        }
        elseif ($n -eq 'Reminders') { $ev.$n = [int[]]@(foreach ($x in @($v)) { if ($null -ne $x) { [int]$x } }) }
        elseif ($n -eq 'Attendees') {
            $ev.$n = @(foreach ($a in @($v)) {
                    if ($null -ne $a) {
                        New-Attendee -Email ([string](Get-Prop $a 'Email' '')) -Name ([string](Get-Prop $a 'Name' '')) `
                            -Role ([string](Get-Prop $a 'Role' '')) -Status ([string](Get-Prop $a 'Status' ''))
                    }
                })
        }
        elseif ($n -eq 'AllDay' -or $n -eq 'Dirty' -or $n -eq 'Deleted' -or $n -eq 'RemindersDefault') { $ev.$n = [bool]$v }
        elseif ($n -eq 'Sequence') { $ev.$n = [int]$v }
        else { $ev.$n = [string]$v }
    }
    return $ev
}

function New-DefaultSettings {
    <# Default application settings. #>
    $culture = Get-Culture
    $timeFormat = '24h'
    if ($culture.DateTimeFormat.ShortTimePattern -match 't') { $timeFormat = '12h' }
    return [pscustomobject]@{
        WeekStart         = $culture.DateTimeFormat.FirstDayOfWeek.ToString()
        TimeFormat        = $timeFormat
        DayStartHour      = 8
        DefaultCalendarId = 'local-personal'
        DefaultDuration   = 60
        DefaultReminder   = '15'
        SyncOnStartup     = $true
        AutoSyncMinutes   = 15
        PastDays          = 90
        FutureDays        = 365
        ConflictPolicy    = 'Server'
        GoogleSendUpdates = 'all'
        AgendaDays        = 60
        Holidays          = 'Public'   # US holidays calendar: Off, Public or All (with observances)
    }
}

function New-AccountObject {
    <# Creates an account record. Type is Local, iCloud, CalDAV, Google or Subscription (read-only .ics URL in ServerUrl). #>
    param([string]$Type = 'Local', [string]$Name = '')
    return [pscustomobject]@{
        Id           = New-Id
        Type         = $Type
        Name         = $Name
        Username     = ''
        Secret       = ''   # DPAPI-encrypted password (CalDAV)
        ServerUrl    = ''
        PrincipalUrl = ''
        ClientId     = ''   # Google OAuth client
        ClientSecret = ''   # DPAPI-encrypted
        RefreshToken = ''   # DPAPI-encrypted
        Enabled      = $true
    }
}

function New-CalendarObject {
    <# Creates a calendar record. RemoteId is the CalDAV URL or the Google calendar id. #>
    param([string]$AccountId, [string]$Name, [string]$RemoteId = '', [string]$Color = 'Cyan')
    return [pscustomobject]@{
        Id         = New-Id
        AccountId  = $AccountId
        Name       = $Name
        RemoteId   = $RemoteId
        Color      = $Color
        Visible    = $true
        Sync       = $true
        ReadOnly   = $false
        TimeZone   = ''
        CTag       = ''
        LastWindow = ''
        LastSync   = ''
        RefreshMinutes = 0   # subscriptions: refresh interval the feed asked for (0 = default)
    }
}

function Copy-KnownProperty {
    <# Copies the values of the target's properties from a source object. #>
    param($Target, $Source)
    if ($null -eq $Source) { return $Target }
    foreach ($p in @($Target.PSObject.Properties)) {
        $sp = $Source.PSObject.Properties[$p.Name]
        if ($null -eq $sp -or $null -eq $sp.Value) { continue }
        if ($p.Value -is [bool]) { $Target.($p.Name) = [bool]$sp.Value }
        elseif ($p.Value -is [int]) { $Target.($p.Name) = [int]$sp.Value }
        else { $Target.($p.Name) = [string]$sp.Value }
    }
    return $Target
}

function Initialize-Storage {
    <# Loads (or creates) the configuration and the local event store. #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    $script:DataDir = (Resolve-Path -LiteralPath $Path).ProviderPath
    $script:ConfigFile = Join-Path $script:DataDir 'config.json'
    $script:EventsFile = Join-Path $script:DataDir 'events.json'

    $raw = Read-JsonFile $script:ConfigFile
    $cfg = [pscustomobject]@{
        FormatVersion = 1
        Settings      = (Copy-KnownProperty (New-DefaultSettings) (Get-Prop $raw 'Settings'))
        Accounts      = New-Object 'System.Collections.Generic.List[object]'
        Calendars     = New-Object 'System.Collections.Generic.List[object]'
    }
    foreach ($a in @(Get-PropList $raw 'Accounts')) {
        $acc = Copy-KnownProperty (New-AccountObject) $a
        $cfg.Accounts.Add($acc)
    }
    foreach ($c in @(Get-PropList $raw 'Calendars')) {
        $cal = Copy-KnownProperty (New-CalendarObject -AccountId '' -Name '') $c
        if (-not [enum]::IsDefined([ConsoleColor], $cal.Color)) { $cal.Color = 'Cyan' }
        $cfg.Calendars.Add($cal)
    }
    # There is always a local account with at least one calendar.
    if (-not @($cfg.Accounts | Where-Object { $_.Type -eq 'Local' })) {
        $local = New-AccountObject -Type 'Local' -Name 'On this computer'
        $local.Id = 'local'
        $cfg.Accounts.Insert(0, $local)
    }
    $localAcc = @($cfg.Accounts | Where-Object { $_.Type -eq 'Local' })[0]
    if (-not @($cfg.Calendars | Where-Object { $_.AccountId -eq $localAcc.Id })) {
        $cal = New-CalendarObject -AccountId $localAcc.Id -Name 'Personal' -Color 'Cyan'
        $cal.Id = 'local-personal'
        $cal.Sync = $false
        $cfg.Calendars.Insert(0, $cal)
    }
    $script:Config = $cfg
    if (-not $script:HolidayModes.Contains([string]$cfg.Settings.Holidays)) { $cfg.Settings.Holidays = 'Public' }
    Update-HolidayCalendar
    if (-not (Get-Calendar $cfg.Settings.DefaultCalendarId)) { $cfg.Settings.DefaultCalendarId = $cfg.Calendars[0].Id }

    $script:Events.Clear()
    $rawEvents = Read-JsonFile $script:EventsFile
    foreach ($e in @(Get-PropList $rawEvents 'Events')) {
        $ev = ConvertTo-CalEvent $e
        if (Get-Calendar $ev.CalendarId) { $script:Events.Add($ev) }
    }
    $script:DataVersion++
    Save-Config
}

function Update-HolidayCalendar {
    <# Adds or removes the built-in US holidays subscription so it matches the Holidays option. #>
    $cfg = $script:Config
    $acc = Get-Account $script:HolidayAccountId
    $cal = Get-Calendar $script:HolidayCalendarId
    if ($cfg.Settings.Holidays -eq 'Off') {
        if ($null -ne $cal) { Remove-LocalCalendar $cal }
        if ($null -ne $acc) { [void]$cfg.Accounts.Remove($acc) }
        return
    }
    if ($null -eq $acc) {
        $acc = New-AccountObject -Type 'Subscription' -Name 'Holidays'
        $acc.Id = $script:HolidayAccountId
        $acc.ServerUrl = $script:HolidayFeedUrl
        $cfg.Accounts.Add($acc)
    }
    if ($null -eq $cal) {
        $cal = New-CalendarObject -AccountId $acc.Id -Name 'US Holidays' -RemoteId $acc.ServerUrl -Color 'DarkGreen'
        $cal.Id = $script:HolidayCalendarId
        $cal.ReadOnly = $true
        $cfg.Calendars.Add($cal)
    }
}

function Test-HiddenObservance {
    <# True for an observance (Valentine's Day, ...) in the holidays calendar while only public holidays are shown. #>
    param($Event)
    return ($Event.CalendarId -eq $script:HolidayCalendarId -and $script:Config.Settings.Holidays -eq 'Public' -and
        $Event.Description.StartsWith('Observance', [StringComparison]::OrdinalIgnoreCase))
}

function Save-Config {
    <# Writes the configuration file. #>
    Save-JsonFile -Path $script:ConfigFile -InputObject $script:Config
}

function Save-EventStore {
    <# Writes the local event store and invalidates cached occurrences. #>
    $script:DataVersion++
    Save-JsonFile -Path $script:EventsFile -InputObject ([pscustomobject]@{ FormatVersion = 1; Events = $script:Events })
}

function Get-Calendar {
    <# Returns a calendar by id. #>
    param([string]$Id)
    foreach ($c in $script:Config.Calendars) { if ($c.Id -eq $Id) { return $c } }
    return $null
}

function Get-Account {
    <# Returns an account by id. #>
    param([string]$Id)
    foreach ($a in $script:Config.Accounts) { if ($a.Id -eq $Id) { return $a } }
    return $null
}

function Get-CalendarLabel {
    <# "Calendar name (account name)" for pickers. #>
    param($Calendar)
    $acc = Get-Account $Calendar.AccountId
    if ($null -eq $acc) { return $Calendar.Name }
    return ('{0} ({1})' -f $Calendar.Name, $acc.Name)
}

function Test-CalendarIsGoogle {
    <# True when a calendar belongs to a Google account. #>
    param($Calendar)
    $acc = Get-Account $Calendar.AccountId
    return ($null -ne $acc -and $acc.Type -eq 'Google')
}

function Test-CalendarIsLocal {
    <# True when a calendar is never synchronised. #>
    param($Calendar)
    $acc = Get-Account $Calendar.AccountId
    return ($null -eq $acc -or $acc.Type -eq 'Local')
}

function Remove-StoredEvent {
    <# Removes events from the local store. #>
    param([object[]]$Items)
    foreach ($i in $Items) { [void]$script:Events.Remove($i) }
    $script:DataVersion++
}

function Get-PendingChangeCount {
    <# Number of local changes waiting to be uploaded. #>
    return @($script:Events | Where-Object { $_.Dirty }).Count
}

function ConvertTo-ConsoleColorName {
    <# Maps a #RRGGBB colour to the closest colourful console colour. #>
    param([string]$Hex)
    if ($Hex -notmatch '^#?([0-9a-fA-F]{6})') { return 'Cyan' }
    $v = [Convert]::ToInt32($Matches[1], 16)
    $r = ($v -shr 16) -band 255; $g = ($v -shr 8) -band 255; $b = $v -band 255
    $best = 'Cyan'; $bestD = [double]::MaxValue
    foreach ($name in $script:ConsoleRgb.Keys) {
        $c = $script:ConsoleRgb[$name]
        $dr = $r - (($c -shr 16) -band 255); $dg = $g - (($c -shr 8) -band 255); $db = $b - ($c -band 255)
        $d = 2 * $dr * $dr + 4 * $dg * $dg + 3 * $db * $db
        if ($d -lt $bestD) { $bestD = $d; $best = $name }
    }
    return $best
}

function Get-ContrastColor {
    <# Black or white text, whichever reads better on a background colour. #>
    param([string]$Background)
    if ($script:LightColors -contains $Background) { return 'Black' }
    return 'White'
}

function Get-EventBlockColor {
    <# Fg/Bg for an event block: a dim shade of its colour normally, the cursor colour when selected.
       -Plain uses gray for unselected blocks instead. #>
    param([string]$Color, [bool]$Selected, [switch]$Plain)
    if ($Selected) { return @{ Fg = $script:CursorFg; Bg = $script:CursorBg } }
    if ($Plain) { return @{ Fg = 'White'; Bg = 'DarkGray' } }
    $c = [int][ConsoleColor]$Color
    if ($c -gt 8) { $c -= 8 }              # Cyan -> DarkCyan, White -> Gray
    $bg = [string][ConsoleColor]$c
    return @{ Fg = (Get-ContrastColor $bg); Bg = $bg }
}

#endregion

#region ------------------------------------------------------------ iCalendar (RFC 5545)

function Split-ICalLine {
    <# Splits an unfolded content line into name, parameters and value. #>
    param([string]$Line)
    if ($Line.IndexOf('"') -lt 0) {
        $colon = $Line.IndexOf(':')
        if ($colon -lt 0) { return $null }
        $head = $Line.Substring(0, $colon)
        $parts = $head.Split(';')
    }
    else {
        # Slow path: parameter values may be quoted and contain ':' or ';'.
        $colon = -1; $inQuote = $false
        for ($i = 0; $i -lt $Line.Length; $i++) {
            $c = $Line[$i]
            if ($c -eq '"') { $inQuote = -not $inQuote }
            elseif ($c -eq ':' -and -not $inQuote) { $colon = $i; break }
        }
        if ($colon -lt 0) { return $null }
        $head = $Line.Substring(0, $colon)
        $list = New-Object 'System.Collections.Generic.List[string]'
        $sb = New-Object System.Text.StringBuilder
        $inQuote = $false
        foreach ($c in $head.ToCharArray()) {
            if ($c -eq '"') { $inQuote = -not $inQuote; [void]$sb.Append($c) }
            elseif ($c -eq ';' -and -not $inQuote) { $list.Add($sb.ToString()); [void]$sb.Clear() }
            else { [void]$sb.Append($c) }
        }
        $list.Add($sb.ToString())
        $parts = $list.ToArray()
    }
    $params = @{}
    for ($j = 1; $j -lt $parts.Count; $j++) {
        $eq = $parts[$j].IndexOf('=')
        if ($eq -gt 0) { $params[$parts[$j].Substring(0, $eq).ToUpperInvariant()] = $parts[$j].Substring($eq + 1).Trim('"') }
    }
    return [pscustomobject]@{ Name = $parts[0].ToUpperInvariant(); Params = $params; Value = $Line.Substring($colon + 1); Raw = $Line }
}

function ConvertFrom-ICalText {
    <# Parses iCalendar text into a tree of components (Type, Props, Children). #>
    param([string]$Text)
    $unfolded = $Text -replace '\r?\n[ \t]', ''
    $root = [pscustomobject]@{ Type = 'ROOT'; Props = (New-Object 'System.Collections.Generic.List[object]'); Children = (New-Object 'System.Collections.Generic.List[object]') }
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push($root)
    foreach ($line in ($unfolded -split '\r?\n')) {
        if ($line.Length -eq 0) { continue }
        $p = Split-ICalLine $line
        if ($null -eq $p) { continue }
        if ($p.Name -eq 'BEGIN') {
            $comp = [pscustomobject]@{ Type = $p.Value.Trim().ToUpperInvariant(); Props = (New-Object 'System.Collections.Generic.List[object]'); Children = (New-Object 'System.Collections.Generic.List[object]') }
            $stack.Peek().Children.Add($comp)
            $stack.Push($comp)
        }
        elseif ($p.Name -eq 'END') { if ($stack.Count -gt 1) { [void]$stack.Pop() } }
        else { $stack.Peek().Props.Add($p) }
    }
    return $root
}

function Get-ICalComponent {
    <# Emits all components of a type anywhere below a node. #>
    param($Node, [string]$Type)
    foreach ($c in $Node.Children) {
        if ($c.Type -eq $Type) { $c }
        Get-ICalComponent -Node $c -Type $Type
    }
}

function ConvertFrom-ICalTextValue {
    <# Unescapes an iCalendar TEXT value. #>
    param([string]$Value)
    if ($Value.IndexOf('\') -lt 0) { return $Value }
    $nul = [string][char]0
    $v = $Value.Replace('\\', $nul).Replace('\n', "`n").Replace('\N', "`n").Replace('\,', ',').Replace('\;', ';')
    return $v.Replace($nul, '\')
}

function ConvertTo-ICalTextValue {
    <# Escapes a value for an iCalendar TEXT property. #>
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace(';', '\;').Replace(',', '\,').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '')
}

function Format-ICalParam {
    <# Quotes a parameter value when needed. #>
    param([string]$Value)
    $v = $Value.Replace('"', "'") -replace '[\r\n]', ' '
    if ($v -match '[:;,]') { return '"' + $v + '"' }
    return $v
}

function Resolve-ICalTzId {
    <# Cleans up a TZID parameter (quotes, "/mozilla.org/..." prefixes). #>
    param([string]$TzId)
    $id = $TzId.Trim().Trim('"')
    if (Test-TimeZoneId $id) { return $id }
    if ($id -match '([A-Za-z_]+/[A-Za-z_+\-]+(?:/[A-Za-z_]+)?)$' -and (Test-TimeZoneId $Matches[1])) { return $Matches[1] }
    return $id.TrimStart('/')
}

function ConvertFrom-ICalDateValue {
    <# Converts a DATE / DATE-TIME value into wall clock, zone and all-day flag. #>
    param([string]$Value, [hashtable]$Params)
    $v = $Value.Trim()
    if ($Params['VALUE'] -eq 'DATE' -or $v -match '^\d{8}$') {
        return [pscustomobject]@{ Wall = $v.Substring(0, 8); Tz = ''; AllDay = $true }
    }
    if ($v.EndsWith('Z') -or $v.EndsWith('z')) {
        return [pscustomobject]@{ Wall = $v.Substring(0, $v.Length - 1); Tz = 'UTC'; AllDay = $false }
    }
    $tz = ''
    if ($Params.ContainsKey('TZID')) { $tz = Resolve-ICalTzId $Params['TZID'] }
    return [pscustomobject]@{ Wall = $v; Tz = $tz; AllDay = $false }
}

function ConvertFrom-ICalDuration {
    <# Parses an iCalendar DURATION (P1D, PT1H30M, -PT15M, P1W). #>
    param([string]$Value)
    if ($Value -notmatch '^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$') { return [TimeSpan]::Zero }
    $days = 7 * [int]$Matches[2] + [int]$Matches[3]
    $ts = New-Object TimeSpan $days, ([int]$Matches[4]), ([int]$Matches[5]), ([int]$Matches[6])
    if ($Matches[1] -eq '-') { $ts = $ts.Negate() }
    return $ts
}

function Format-ICalDateLine {
    <# Builds DTSTART/DTEND/EXDATE/RECURRENCE-ID lines. #>
    param([string]$Name, [string[]]$Walls, [string]$TimeZone, [bool]$AllDay)
    if ($AllDay) { return ($Name + ';VALUE=DATE:' + (($Walls | ForEach-Object { $_.Substring(0, 8) }) -join ',')) }
    $full = $Walls | ForEach-Object { ConvertTo-WallString (ConvertFrom-WallString $_) }
    if ($TimeZone -eq 'UTC') { return ($Name + ':' + (($full | ForEach-Object { $_ + 'Z' }) -join ',')) }
    if (-not $TimeZone) { return ($Name + ':' + ($full -join ',')) }
    return ($Name + ';TZID=' + (Format-ICalParam $TimeZone) + ':' + ($full -join ','))
}

function Format-ICalFold {
    <# Folds a content line at 75 octets as required by RFC 5545. #>
    param([string]$Line)
    $enc = [System.Text.Encoding]::UTF8
    if ($enc.GetByteCount($Line) -le 75) { return $Line }
    $sb = New-Object System.Text.StringBuilder
    $count = 0
    $i = 0
    while ($i -lt $Line.Length) {
        $len = 1
        if ([char]::IsHighSurrogate($Line[$i]) -and $i + 1 -lt $Line.Length) { $len = 2 }
        $chunk = $Line.Substring($i, $len)
        $b = $enc.GetByteCount($chunk)
        if ($count + $b -gt 75) { [void]$sb.Append("`r`n "); $count = 1 }
        [void]$sb.Append($chunk)
        $count += $b
        $i += $len
    }
    return $sb.ToString()
}

function Format-UtcOffset {
    <# Formats a UTC offset as +HHMM / -HHMM. #>
    param([TimeSpan]$Offset)
    $sign = '+'
    if ($Offset.Ticks -lt 0) { $sign = '-'; $Offset = $Offset.Negate() }
    return ('{0}{1:00}{2:00}' -f $sign, $Offset.Hours, $Offset.Minutes)
}

function Get-TransitionDate {
    <# The date and time a DST transition happens in a given year. #>
    param($Transition, [int]$Year)
    $m = $Transition.Month
    if ($Transition.IsFixedDateRule) {
        $d = New-Object DateTime $Year, $m, ([Math]::Min($Transition.Day, [DateTime]::DaysInMonth($Year, $m)))
    }
    else {
        $first = New-Object DateTime $Year, $m, 1
        $offset = ([int]$Transition.DayOfWeek - [int]$first.DayOfWeek + 7) % 7
        $day = 1 + $offset + 7 * ($Transition.Week - 1)
        while ($day -gt [DateTime]::DaysInMonth($Year, $m)) { $day -= 7 }
        $d = New-Object DateTime $Year, $m, $day
    }
    return $d.Add($Transition.TimeOfDay.TimeOfDay)
}

function Get-VTimeZoneLine {
    <# Emits a VTIMEZONE component generated from the Windows time zone rules. #>
    param([string]$TzId)
    $tz = Resolve-TimeZoneId $TzId
    if ($null -eq $tz) { return }
    $now = Get-Date
    $rule = $null
    foreach ($r in $tz.GetAdjustmentRules()) { if ($r.DateStart -le $now -and $r.DateEnd -ge $now) { $rule = $r } }
    $std = $tz.BaseUtcOffset
    'BEGIN:VTIMEZONE'
    'TZID:' + $TzId
    if ($null -eq $rule -or -not $tz.SupportsDaylightSavingTime -or $rule.DaylightDelta -eq [TimeSpan]::Zero) {
        'BEGIN:STANDARD'
        'DTSTART:19700101T000000'
        'TZOFFSETFROM:' + (Format-UtcOffset $std)
        'TZOFFSETTO:' + (Format-UtcOffset $std)
        'END:STANDARD'
    }
    else {
        $dst = $std + $rule.DaylightDelta
        foreach ($kind in 'DAYLIGHT', 'STANDARD') {
            if ($kind -eq 'DAYLIGHT') { $t = $rule.DaylightTransitionStart; $from = $std; $to = $dst }
            else { $t = $rule.DaylightTransitionEnd; $from = $dst; $to = $std }
            if ($t.IsFixedDateRule) { $rr = 'FREQ=YEARLY;BYMONTH={0};BYMONTHDAY={1}' -f $t.Month, $t.Day }
            else {
                $week = $t.Week; if ($week -ge 5) { $week = -1 }
                $rr = 'FREQ=YEARLY;BYMONTH={0};BYDAY={1}{2}' -f $t.Month, $week, $script:DayCodeOf[[int]$t.DayOfWeek]
            }
            'BEGIN:' + $kind
            'DTSTART:' + (ConvertTo-WallString (Get-TransitionDate $t 1970))
            'RRULE:' + $rr
            'TZOFFSETFROM:' + (Format-UtcOffset $from)
            'TZOFFSETTO:' + (Format-UtcOffset $to)
            'END:' + $kind
        }
    }
    'END:VTIMEZONE'
}

function ConvertFrom-ICalEvent {
    <# Converts a VEVENT component into an event object. #>
    param($Component, [string]$CalendarId)
    $ev = New-CalEvent -CalendarId $CalendarId
    $startProp = $null; $endProp = $null; $durProp = $null; $recProp = $null
    $exProps = New-Object 'System.Collections.Generic.List[object]'
    $extra = New-Object 'System.Collections.Generic.List[string]'
    $attendees = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in $Component.Props) {
        switch ($p.Name) {
            'UID' { $ev.Uid = $p.Value.Trim() }
            'SUMMARY' { $ev.Summary = ConvertFrom-ICalTextValue $p.Value }
            'LOCATION' { $ev.Location = ConvertFrom-ICalTextValue $p.Value }
            'DESCRIPTION' { $ev.Description = ConvertFrom-ICalTextValue $p.Value }
            'URL' { $ev.Url = $p.Value.Trim() }
            'STATUS' { $ev.Status = $p.Value.Trim().ToUpperInvariant() }
            'TRANSP' { $ev.Transparency = $p.Value.Trim().ToUpperInvariant() }
            'CLASS' { $ev.Visibility = $p.Value.Trim().ToUpperInvariant() }
            'SEQUENCE' { $seq = 0; if ([int]::TryParse($p.Value, [ref]$seq)) { $ev.Sequence = $seq } }
            'ORGANIZER' { $ev.OrganizerEmail = ($p.Value -replace '^(?i)mailto:', ''); $ev.OrganizerName = [string]$p.Params['CN'] }
            'ATTENDEE' {
                $attendees.Add((New-Attendee -Email ($p.Value -replace '^(?i)mailto:', '') -Name ([string]$p.Params['CN']) `
                            -Role ([string]$p.Params['ROLE']) -Status ([string]$p.Params['PARTSTAT'])))
            }
            'RRULE' { $ev.RRule = $p.Value.Trim() }
            'EXDATE' { $exProps.Add($p) }
            'RECURRENCE-ID' { $recProp = $p }
            'DTSTART' { $startProp = $p }
            'DTEND' { $endProp = $p }
            'DURATION' { $durProp = $p }
            'DTSTAMP' { }
            'CREATED' { $ev.Created = $p.Value.Trim() }
            'LAST-MODIFIED' { $ev.Modified = $p.Value.Trim() }
            default { $extra.Add($p.Raw) }
        }
    }
    if ($null -eq $startProp) { return $null }
    if (-not $ev.Uid) { $ev.Uid = (New-Id) + '@pscalendar' }
    $s = ConvertFrom-ICalDateValue $startProp.Value $startProp.Params
    $ev.AllDay = $s.AllDay
    $ev.TimeZone = $s.Tz
    $ev.Start = ConvertTo-WallString (ConvertFrom-WallString $s.Wall) $s.AllDay
    $startDt = ConvertFrom-WallString $ev.Start
    if ($null -ne $endProp) {
        $e = ConvertFrom-ICalDateValue $endProp.Value $endProp.Params
        $ev.End = Convert-WallString -Wall (ConvertTo-WallString (ConvertFrom-WallString $e.Wall) $e.AllDay) -FromTz $e.Tz -ToTz $ev.TimeZone -AllDay $ev.AllDay
        if ($ev.AllDay) { $ev.End = $ev.End.Substring(0, 8) }
    }
    elseif ($null -ne $durProp) {
        $ev.End = ConvertTo-WallString ($startDt + (ConvertFrom-ICalDuration $durProp.Value)) $ev.AllDay
    }
    elseif ($ev.AllDay) { $ev.End = ConvertTo-WallString $startDt.AddDays(1) $true }
    else { $ev.End = $ev.Start }
    if ((ConvertFrom-WallString $ev.End) -lt $startDt) { $ev.End = $ev.Start }

    $ex = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $exProps) {
        foreach ($v in $p.Value.Split(',')) {
            if (-not $v.Trim()) { continue }
            $d = ConvertFrom-ICalDateValue $v $p.Params
            $w = ConvertTo-WallString (ConvertFrom-WallString $d.Wall) $d.AllDay
            if (-not $d.AllDay) { $w = Convert-WallString -Wall $w -FromTz $d.Tz -ToTz $ev.TimeZone }
            if ($ev.AllDay) { $w = $w.Substring(0, 8) }
            $ex.Add($w)
        }
    }
    $ev.ExDates = $ex.ToArray()
    if ($null -ne $recProp) {
        $d = ConvertFrom-ICalDateValue $recProp.Value $recProp.Params
        $w = ConvertTo-WallString (ConvertFrom-WallString $d.Wall) $d.AllDay
        if (-not $d.AllDay) { $w = Convert-WallString -Wall $w -FromTz $d.Tz -ToTz $ev.TimeZone }
        $ev.RecurrenceId = $w
    }
    $ev.Attendees = $attendees.ToArray()
    $ev.ExtraProps = $extra.ToArray()

    $mins = New-Object 'System.Collections.Generic.List[int]'
    foreach ($alarm in $Component.Children) {
        if ($alarm.Type -ne 'VALARM') { continue }
        foreach ($p in $alarm.Props) {
            if ($p.Name -ne 'TRIGGER' -or $p.Params['VALUE'] -eq 'DATE-TIME') { continue }
            $m = [int](-(ConvertFrom-ICalDuration $p.Value.Trim()).TotalMinutes)
            if ($m -ge 0 -and -not $mins.Contains($m)) { $mins.Add($m) }
        }
    }
    $ev.Reminders = $mins.ToArray()
    return $ev
}

function ConvertTo-ICalText {
    <# Builds a VCALENDAR with the given events (a recurring master and its exceptions). #>
    param([object[]]$Events)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('BEGIN:VCALENDAR')
    $lines.Add('VERSION:2.0')
    $lines.Add('PRODID:' + $script:ProdId)
    $lines.Add('CALSCALE:GREGORIAN')
    $zones = @($Events | Where-Object { -not $_.AllDay -and $_.TimeZone -and $_.TimeZone -ne 'UTC' } | ForEach-Object { $_.TimeZone } | Select-Object -Unique)
    foreach ($z in $zones) { foreach ($l in @(Get-VTimeZoneLine $z)) { $lines.Add($l) } }
    $stamp = Get-UtcStamp
    $ordered = @($Events | Sort-Object -Property @{ Expression = { [bool]$_.RecurrenceId } })
    foreach ($ev in $ordered) {
        $lines.Add('BEGIN:VEVENT')
        $lines.Add('UID:' + $ev.Uid)
        $lines.Add('DTSTAMP:' + $stamp)
        if ($ev.Created -match '^\d{8}T\d{6}Z$') { $lines.Add('CREATED:' + $ev.Created) }
        $lines.Add('LAST-MODIFIED:' + $stamp)
        $lines.Add('SEQUENCE:' + $ev.Sequence)
        $lines.Add((Format-ICalDateLine 'DTSTART' @($ev.Start) $ev.TimeZone $ev.AllDay))
        $lines.Add((Format-ICalDateLine 'DTEND' @($ev.End) $ev.TimeZone $ev.AllDay))
        if ($ev.RecurrenceId) { $lines.Add((Format-ICalDateLine 'RECURRENCE-ID' @($ev.RecurrenceId) $ev.TimeZone ($ev.RecurrenceId.Length -eq 8))) }
        $lines.Add('SUMMARY:' + (ConvertTo-ICalTextValue $ev.Summary))
        if ($ev.Location) { $lines.Add('LOCATION:' + (ConvertTo-ICalTextValue $ev.Location)) }
        if ($ev.Description) { $lines.Add('DESCRIPTION:' + (ConvertTo-ICalTextValue $ev.Description)) }
        if ($ev.Url) { $lines.Add('URL:' + $ev.Url) }
        if ($ev.Status) { $lines.Add('STATUS:' + $ev.Status) }
        if ($ev.Transparency) { $lines.Add('TRANSP:' + $ev.Transparency) }
        if ($ev.Visibility) { $lines.Add('CLASS:' + $ev.Visibility) }
        if ($ev.RRule -and -not $ev.RecurrenceId) {
            $lines.Add('RRULE:' + $ev.RRule)
            if (@($ev.ExDates).Count -gt 0) { $lines.Add((Format-ICalDateLine 'EXDATE' @($ev.ExDates) $ev.TimeZone $ev.AllDay)) }
        }
        if ($ev.OrganizerEmail) {
            $org = 'ORGANIZER'
            if ($ev.OrganizerName) { $org += ';CN=' + (Format-ICalParam $ev.OrganizerName) }
            $lines.Add($org + ':mailto:' + $ev.OrganizerEmail)
        }
        foreach ($a in @($ev.Attendees)) {
            $att = 'ATTENDEE'
            if ($a.Name) { $att += ';CN=' + (Format-ICalParam $a.Name) }
            $att += ';ROLE=' + $a.Role + ';PARTSTAT=' + $a.Status
            if ($a.Status -eq 'NEEDS-ACTION') { $att += ';RSVP=TRUE' }
            $lines.Add($att + ':mailto:' + $a.Email)
        }
        foreach ($x in @($ev.ExtraProps)) { $lines.Add($x) }
        foreach ($m in @($ev.Reminders)) {
            $lines.Add('BEGIN:VALARM')
            $lines.Add('ACTION:DISPLAY')
            $lines.Add('DESCRIPTION:' + (ConvertTo-ICalTextValue $ev.Summary))
            $lines.Add('TRIGGER:-PT' + $m + 'M')
            $lines.Add('END:VALARM')
        }
        $lines.Add('END:VEVENT')
    }
    $lines.Add('END:VCALENDAR')
    return ((($lines | ForEach-Object { Format-ICalFold $_ }) -join "`r`n") + "`r`n")
}

#endregion

#region ------------------------------------------------------------ Recurrence rules

function ConvertFrom-RRule {
    <# Parses an RRULE value into a hashtable. #>
    param([string]$Rule)
    $r = @{ FREQ = ''; INTERVAL = 1; COUNT = 0; UNTIL = ''; BYDAY = @(); BYMONTHDAY = @(); BYMONTH = @(); BYSETPOS = @(); WKST = 'MO'; Other = @() }
    foreach ($part in (($Rule -replace '^(?i)RRULE:', '').Split(';'))) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -ne 2) { continue }
        $k = $kv[0].Trim().ToUpperInvariant()
        $v = $kv[1].Trim()
        if ($k -eq 'FREQ') { $r.FREQ = $v.ToUpperInvariant() }
        elseif ($k -eq 'INTERVAL') { $r.INTERVAL = [Math]::Max(1, [int]$v) }
        elseif ($k -eq 'COUNT') { $r.COUNT = [int]$v }
        elseif ($k -eq 'UNTIL') { $r.UNTIL = $v }
        elseif ($k -eq 'WKST') { $r.WKST = $v.ToUpperInvariant() }
        elseif ($k -eq 'BYDAY') {
            $r.BYDAY = @(foreach ($d in $v.Split(',')) {
                    if ($d.Trim().ToUpperInvariant() -match '^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$') {
                        $n = 0
                        if ($Matches[1]) { $n = [int]$Matches[1] }
                        [pscustomobject]@{ N = $n; Day = $script:DayCodes[$Matches[2]]; Code = $Matches[2] }
                    }
                })
        }
        elseif ($k -eq 'BYMONTHDAY') { $r.BYMONTHDAY = @(foreach ($d in $v.Split(',')) { [int]$d }) }
        elseif ($k -eq 'BYMONTH') { $r.BYMONTH = @(foreach ($d in $v.Split(',')) { [int]$d }) }
        elseif ($k -eq 'BYSETPOS') { $r.BYSETPOS = @(foreach ($d in $v.Split(',')) { [int]$d }) }
        else { $r.Other += $k }
    }
    return $r
}

function Get-MonthDayList {
    <# Emits the day numbers of a month selected by BYMONTHDAY / BYDAY. #>
    param([datetime]$First, [hashtable]$Rule, [int]$DefaultDay)
    $dim = [DateTime]::DaysInMonth($First.Year, $First.Month)
    $hasMd = @($Rule.BYMONTHDAY).Count -gt 0
    $hasDay = @($Rule.BYDAY).Count -gt 0
    $md = New-Object 'System.Collections.Generic.SortedSet[int]'
    $wd = New-Object 'System.Collections.Generic.SortedSet[int]'
    if ($hasMd) {
        foreach ($d in $Rule.BYMONTHDAY) {
            $v = $d
            if ($d -lt 0) { $v = $dim + $d + 1 }
            if ($v -ge 1 -and $v -le $dim) { [void]$md.Add($v) }
        }
    }
    if ($hasDay) {
        $firstDow = [int]$First.DayOfWeek
        foreach ($bd in $Rule.BYDAY) {
            $firstMatch = 1 + (([int]$bd.Day - $firstDow + 7) % 7)
            $days = @(for ($i = $firstMatch; $i -le $dim; $i += 7) { $i })
            if ($bd.N -gt 0) { if ($bd.N -le $days.Count) { [void]$wd.Add($days[$bd.N - 1]) } }
            elseif ($bd.N -lt 0) { if (-$bd.N -le $days.Count) { [void]$wd.Add($days[$days.Count + $bd.N]) } }
            else { foreach ($x in $days) { [void]$wd.Add($x) } }
        }
    }
    if ($hasMd -and $hasDay) { foreach ($x in $md) { if ($wd.Contains($x)) { $x } } }
    elseif ($hasMd) { foreach ($x in $md) { $x } }
    elseif ($hasDay) { foreach ($x in $wd) { $x } }
    elseif ($DefaultDay -le $dim) { $DefaultDay }
}

function Select-SetPosition {
    <# Applies BYSETPOS to a sorted list of candidate dates. #>
    param([object[]]$Dates, [int[]]$Positions)
    if (@($Positions).Count -eq 0) { return $Dates }
    $count = $Dates.Count
    $picked = foreach ($p in $Positions) {
        $i = $p - 1
        if ($p -lt 0) { $i = $count + $p }
        if ($i -ge 0 -and $i -lt $count) { $Dates[$i] }
    }
    return @($picked | Sort-Object -Unique)
}

function Get-RecurrencePeriod {
    <# Returns the candidate occurrences of one period (day/week/month/year) of a rule. #>
    param([hashtable]$Rule, [datetime]$DtStart, [int]$Period)
    $tod = $DtStart.TimeOfDay
    $step = $Period * $Rule.INTERVAL
    $byMonth = @($Rule.BYMONTH)
    $dates = @()
    $base = [datetime]::MaxValue
    if ($DtStart.Year + $step / 12 -gt 9000) { return @{ Base = $base; Dates = @() } }
    switch ($Rule.FREQ) {
        'DAILY' {
            $base = $DtStart.Date.AddDays($step)
            $ok = $true
            if ($byMonth.Count -and $byMonth -notcontains $base.Month) { $ok = $false }
            if ($ok -and @($Rule.BYMONTHDAY).Count) {
                $dim = [DateTime]::DaysInMonth($base.Year, $base.Month)
                $mds = @(foreach ($d in $Rule.BYMONTHDAY) { if ($d -lt 0) { $dim + $d + 1 } else { $d } })
                if ($mds -notcontains $base.Day) { $ok = $false }
            }
            if ($ok -and @($Rule.BYDAY).Count -and (@($Rule.BYDAY | ForEach-Object { $_.Day }) -notcontains $base.DayOfWeek)) { $ok = $false }
            if ($ok) { $dates = @($base + $tod) }
        }
        'WEEKLY' {
            $wkst = $script:DayCodes[$Rule.WKST]
            if ($null -eq $wkst) { $wkst = [DayOfWeek]::Monday }
            $base = $DtStart.Date.AddDays(-((7 + [int]$DtStart.DayOfWeek - [int]$wkst) % 7)).AddDays(7 * $step)
            $days = @($DtStart.DayOfWeek)
            if (@($Rule.BYDAY).Count) { $days = @($Rule.BYDAY | ForEach-Object { $_.Day }) }
            $dates = @(for ($i = 0; $i -lt 7; $i++) {
                    $d = $base.AddDays($i)
                    if ($days -contains $d.DayOfWeek -and (-not $byMonth.Count -or $byMonth -contains $d.Month)) { $d + $tod }
                })
        }
        'MONTHLY' {
            $base = (New-Object DateTime $DtStart.Year, $DtStart.Month, 1).AddMonths($step)
            if (-not $byMonth.Count -or $byMonth -contains $base.Month) {
                $dates = @(foreach ($d in (Get-MonthDayList -First $base -Rule $Rule -DefaultDay $DtStart.Day)) { $base.AddDays($d - 1) + $tod })
                $dates = @(Select-SetPosition -Dates $dates -Positions $Rule.BYSETPOS)
            }
        }
        'YEARLY' {
            $year = $DtStart.Year + $step
            $base = New-Object DateTime $year, 1, 1
            $months = @($DtStart.Month)
            if ($byMonth.Count) { $months = $byMonth }
            elseif (@($Rule.BYDAY).Count -or @($Rule.BYMONTHDAY).Count) { $months = 1..12 }
            $dates = @(foreach ($m in ($months | Sort-Object)) {
                    $first = New-Object DateTime $year, $m, 1
                    foreach ($d in (Get-MonthDayList -First $first -Rule $Rule -DefaultDay $DtStart.Day)) { $first.AddDays($d - 1) + $tod }
                })
            $dates = @(Select-SetPosition -Dates $dates -Positions $Rule.BYSETPOS)
        }
    }
    return @{ Base = $base; Dates = $dates }
}

function Get-RecurrenceStart {
    <# Emits the occurrence starts (wall clock in the event's zone) between From and To. #>
    param($Event, [datetime]$From, [datetime]$To)
    $dtStart = ConvertFrom-WallString $Event.Start
    $rule = ConvertFrom-RRule $Event.RRule
    if (@('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY') -notcontains $rule.FREQ) {
        if ($dtStart -ge $From -and $dtStart -lt $To) { $dtStart }
        return
    }
    $until = [datetime]::MaxValue
    if ($rule.UNTIL) {
        try {
            $u = ConvertFrom-WallString $rule.UNTIL
            if ($Event.AllDay) { $u = $u.Date.AddDays(1).AddTicks(-1) }
            elseif ($rule.UNTIL -match '[Zz]$') { $u = Convert-WallTime -DateTime $u -From ([TimeZoneInfo]::Utc) -To (Get-TimeZoneById $Event.TimeZone) }
            elseif ($rule.UNTIL -match '^\d{8}$') { $u = $u.AddDays(1).AddTicks(-1) }
            $until = $u
        }
        catch { Write-Verbose "Ignoring invalid UNTIL '$($rule.UNTIL)'." }
    }
    $exTimes = New-Object 'System.Collections.Generic.HashSet[long]'
    $exDays = New-Object 'System.Collections.Generic.HashSet[long]'
    foreach ($x in @($Event.ExDates)) {
        try {
            $d = ConvertFrom-WallString $x
            if ($Event.AllDay -or $x.Length -eq 8) { [void]$exDays.Add($d.Date.Ticks) } else { [void]$exTimes.Add($d.Ticks) }
        }
        catch { Write-Verbose "Ignoring invalid EXDATE '$x'." }
    }
    # Without COUNT the periods before the window can be skipped safely.
    $period = 0
    if ($rule.COUNT -le 0 -and $From -gt $dtStart) {
        $skip = 0
        switch ($rule.FREQ) {
            'DAILY' { $skip = [Math]::Floor(($From - $dtStart).TotalDays / $rule.INTERVAL) - 1 }
            'WEEKLY' { $skip = [Math]::Floor(($From - $dtStart).TotalDays / 7 / $rule.INTERVAL) - 1 }
            'MONTHLY' { $skip = [Math]::Floor((($From.Year - $dtStart.Year) * 12 + $From.Month - $dtStart.Month) / $rule.INTERVAL) - 1 }
            'YEARLY' { $skip = [Math]::Floor(($From.Year - $dtStart.Year) / $rule.INTERVAL) - 1 }
        }
        if ($skip -gt 0) { $period = [int]$skip }
    }
    $n = 0
    for ($guard = 0; $guard -lt 5000; $guard++) {
        $p = Get-RecurrencePeriod -Rule $rule -DtStart $dtStart -Period $period
        if ($p.Base -gt $To -or $p.Base -gt $until) { break }
        $stop = $false
        foreach ($c in $p.Dates) {
            if ($c -lt $dtStart) { continue }
            if ($c -gt $until) { $stop = $true; break }
            $n++
            if ($rule.COUNT -gt 0 -and $n -gt $rule.COUNT) { $stop = $true; break }
            if ($c -ge $To) { $stop = $true; break }
            if ($c -ge $From -and -not $exTimes.Contains($c.Ticks) -and -not $exDays.Contains($c.Date.Ticks)) { $c }
        }
        if ($stop) { break }
        $period++
    }
}

function Format-RRuleText {
    <# Describes a recurrence rule in plain English. #>
    param([string]$Rule)
    if (-not $Rule) { return '' }
    $r = ConvertFrom-RRule $Rule
    $unit = @{ DAILY = 'day'; WEEKLY = 'week'; MONTHLY = 'month'; YEARLY = 'year' }[$r.FREQ]
    if (-not $unit) { return $Rule }
    $text = 'Every ' + $unit
    if ($r.INTERVAL -gt 1) { $text = 'Every {0} {1}s' -f $r.INTERVAL, $unit }
    if (@($r.BYDAY).Count) {
        $names = foreach ($d in $r.BYDAY) {
            $nm = ([DayOfWeek]$d.Day).ToString().Substring(0, 3)
            if ($d.N -eq -1) { 'last ' + $nm } elseif ($d.N -gt 0) { '#' + $d.N + ' ' + $nm } else { $nm }
        }
        $text += ' on ' + ($names -join ', ')
    }
    if (@($r.BYMONTHDAY).Count) { $text += ' on day ' + ($r.BYMONTHDAY -join ', ') }
    if (@($r.BYMONTH).Count) { $text += ' in ' + (($r.BYMONTH | ForEach-Object { $script:Inv.DateTimeFormat.AbbreviatedMonthNames[$_ - 1] }) -join ', ') }
    if ($r.COUNT -gt 0) { $text += ', {0} times' -f $r.COUNT }
    if ($r.UNTIL) { try { $text += ', until ' + (ConvertFrom-WallString $r.UNTIL).ToString('yyyy-MM-dd') } catch { $text += ', until ' + $r.UNTIL } }
    return $text
}

#endregion

#region ------------------------------------------------------------ Occurrences

function Get-EventInstance {
    <#
        Emits the visible occurrences between From and To (local time) as
        objects with Event, Calendar, Start, End, AllDay, Occurrence, Color, Key.
        Results are cached until the event store changes.
    #>
    param([datetime]$From, [datetime]$To)
    $cacheKey = '{0}|{1}|{2}' -f $From.Ticks, $To.Ticks, $script:DataVersion
    if ($script:InstanceCache.ContainsKey($cacheKey)) { return $script:InstanceCache[$cacheKey] }
    if ($script:InstanceCache.Count -gt 40) { $script:InstanceCache.Clear() }

    $visible = @{}
    foreach ($c in $script:Config.Calendars) { if ($c.Visible) { $visible[$c.Id] = $c } }
    # Changed or cancelled occurrences replace the generated ones.
    $overrides = @{}
    foreach ($ev in $script:Events) {
        if (-not $ev.RecurrenceId -or $ev.Deleted) { continue }
        $k = $ev.CalendarId + '|' + $ev.Uid
        if (-not $overrides.ContainsKey($k)) { $overrides[$k] = New-Object 'System.Collections.Generic.HashSet[string]' }
        [void]$overrides[$k].Add((Get-InstantKey -Wall (ConvertFrom-WallString $ev.RecurrenceId) -TimeZone $ev.TimeZone -AllDay ($ev.RecurrenceId.Length -eq 8)))
    }
    $local = [TimeZoneInfo]::Local
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ev in $script:Events) {
        if ($ev.Deleted -or -not $ev.Start -or -not $visible.ContainsKey($ev.CalendarId)) { continue }
        if ($ev.RecurrenceId -and $ev.Status -eq 'CANCELLED') { continue }
        if (Test-HiddenObservance $ev) { continue }
        $cal = $visible[$ev.CalendarId]
        try {
            $sw = ConvertFrom-WallString $ev.Start
            $ew = $sw
            if ($ev.End) { $ew = ConvertFrom-WallString $ev.End }
        }
        catch { continue }
        $dur = $ew - $sw
        if ($dur.Ticks -lt 0) { $dur = [TimeSpan]::Zero }
        if ($ev.AllDay -and $dur.Ticks -eq 0) { $dur = [TimeSpan]::FromDays(1) }
        $tzi = $local
        if (-not $ev.AllDay) { $tzi = Get-TimeZoneById $ev.TimeZone }
        $color = $cal.Color
        if ($ev.ColorId -and $script:GoogleColorConsole.ContainsKey($ev.ColorId)) { $color = $script:GoogleColorConsole[$ev.ColorId] }
        $ovSet = $null
        if ($ev.RRule -and -not $ev.RecurrenceId) {
            if ($ev.AllDay) { $fw = $From.Date - $dur; $tw = $To }
            else {
                $fw = (Convert-WallTime -DateTime $From -From $local -To $tzi) - $dur - [TimeSpan]::FromDays(1)
                $tw = (Convert-WallTime -DateTime $To -From $local -To $tzi).AddDays(1)
            }
            $starts = @(Get-RecurrenceStart -Event $ev -From $fw -To $tw)
            $ovSet = $overrides[$ev.CalendarId + '|' + $ev.Uid]
        }
        else { $starts = @($sw) }
        foreach ($occ in $starts) {
            if ($null -ne $ovSet -and $ovSet.Contains((Get-InstantKey -Wall $occ -TimeZone $ev.TimeZone -AllDay $ev.AllDay))) { continue }
            if ($ev.AllDay) { $ls = $occ.Date; $le = $occ.Date + $dur }
            else {
                $ls = Convert-WallTime -DateTime $occ -From $tzi -To $local
                $le = Convert-WallTime -DateTime ($occ + $dur) -From $tzi -To $local
            }
            if ($le -le $ls) { if ($ls -lt $From -or $ls -ge $To) { continue } }
            elseif ($le -le $From -or $ls -ge $To) { continue }
            $list.Add([pscustomobject]@{
                    Event = $ev; Calendar = $cal; Start = $ls; End = $le; AllDay = [bool]$ev.AllDay
                    Occurrence = $occ; Color = $color; Key = $ev.Id + '|' + $occ.Ticks
                })
        }
    }
    $sorted = @($list | Sort-Object -Property Start)
    $script:InstanceCache[$cacheKey] = $sorted
    return $sorted
}

function Get-DayItem {
    <# Occurrences that touch one day: all-day first, then by start time. #>
    param([datetime]$Day)
    $d = $Day.Date
    return @(Get-EventInstance -From $d -To $d.AddDays(1) |
            Sort-Object -Property (@(@{ Expression = { if ($_.AllDay) { 0 } else { 1 } } }) + $script:InstanceOrder))
}

# Display order of occurrences. Shared by Get-DayItem and the timeline so
# Up/Down selection follows what is on screen (top to bottom, left to right).
$script:InstanceOrder = @('Start', 'End', @{ Expression = { $_.Event.Summary } }, 'Key')

function Group-InstanceByDay {
    <# Hashtable of day ticks -> occurrences, multi-day events appear on each day. #>
    param([object[]]$Instances, [datetime]$From, [int]$Days)
    $map = @{}
    $limit = $From.AddDays($Days - 1)
    foreach ($inst in $Instances) {
        $d = $inst.Start.Date
        $last = $inst.Start.Date
        if ($inst.End -gt $inst.Start) { $last = $inst.End.AddTicks(-1).Date }
        if ($d -lt $From) { $d = $From }
        if ($last -gt $limit) { $last = $limit }
        while ($d -le $last) {
            if (-not $map.ContainsKey($d.Ticks)) { $map[$d.Ticks] = New-Object 'System.Collections.Generic.List[object]' }
            $map[$d.Ticks].Add($inst)
            $d = $d.AddDays(1)
        }
    }
    return $map
}

function Get-InstanceTitle {
    <# Display title of an occurrence. #>
    param($Instance)
    $t = $Instance.Event.Summary
    if (-not $t) { $t = '(No title)' }
    if ($Instance.Event.Status -eq 'CANCELLED') { $t = 'Cancelled: ' + $t }
    return (ConvertTo-DisplayText $t)
}

function Format-InstanceWhen {
    <# "09:00-10:00", "All day" or a multi-day range. #>
    param($Instance)
    if ($Instance.AllDay) {
        $lastDay = $Instance.End.AddDays(-1)
        if ($lastDay -gt $Instance.Start) { return ('{0} - {1}' -f $Instance.Start.ToString('MMM d'), $lastDay.ToString('MMM d')) }
        return 'All day'
    }
    if ($Instance.End.Date -gt $Instance.Start.Date -and $Instance.End -ne $Instance.Start.Date.AddDays(1)) {
        return ('{0} {1} - {2} {3}' -f $Instance.Start.ToString('MMM d'), (Format-Time $Instance.Start), $Instance.End.ToString('MMM d'), (Format-Time $Instance.End))
    }
    return ('{0}-{1}' -f (Format-Time $Instance.Start), (Format-Time $Instance.End))
}

#endregion

#region ------------------------------------------------------------ HTTP

function Initialize-Http {
    <# Creates the shared HttpClient (redirects are followed manually so methods and auth are kept). #>
    if ($null -ne $script:HttpClient) { return }
    Add-Type -AssemblyName System.Net.Http
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Verbose 'Could not enable TLS 1.2 explicitly.' }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    # Some feeds (iCloud holidays, for example) are always sent gzip-compressed.
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'PSCalendar/' + $script:AppVersion)
    $script:HttpClient = $client
}

function Invoke-HttpRequest {
    <# Sends an HTTP request with any method (PROPFIND, REPORT, ...) and returns status, body and ETag. #>
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Body = '',
        [string]$ContentType = 'application/xml',
        [int]$MaxRedirects = 5
    )
    Initialize-Http
    $current = $Uri
    for ($hop = 0; $hop -le $MaxRedirects; $hop++) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), [Uri]$current)
        foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation([string]$k, [string]$Headers[$k]) }
        if (-not [string]::IsNullOrEmpty($Body)) {
            $req.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, $ContentType)
        }
        try { $resp = $script:HttpClient.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw ('Network error contacting {0}: {1}' -f ([Uri]$current).Host, (Get-InnermostMessage $_.Exception)) }
        try {
            $code = [int]$resp.StatusCode
            if ((301, 302, 303, 307, 308) -contains $code -and $null -ne $resp.Headers.Location) {
                $current = ([Uri]::new([Uri]$current, $resp.Headers.Location)).AbsoluteUri
                if ($code -eq 303) { $Method = 'GET'; $Body = '' }
                continue
            }
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $etag = ''
            $values = $null
            if ($resp.Headers.TryGetValues('ETag', [ref]$values)) { $etag = @($values)[0] }
            return [pscustomobject]@{ StatusCode = $code; Reason = $resp.ReasonPhrase; Body = $text; ETag = $etag; Uri = $current }
        }
        finally { $resp.Dispose(); $req.Dispose() }
    }
    throw "Too many redirects for $Uri"
}

function Get-ResponseSnippet {
    <# A short, tag-free excerpt of a response body for error messages. #>
    param($Response)
    $t = ($Response.Body -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
    return $t
}

#endregion

#region ------------------------------------------------------------ CalDAV (iCloud and others)

function Invoke-CalDav {
    <# Sends an authenticated CalDAV request. #>
    param($Account, [string]$Method, [string]$Uri, [string]$Body = '', [string]$Depth = '', [hashtable]$Headers = @{}, [string]$ContentType = 'application/xml')
    $pair = $Account.Username + ':' + (Unprotect-Secret $Account.Secret)
    $h = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair)) }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    if ($Depth) { $h['Depth'] = $Depth }
    $r = Invoke-HttpRequest -Method $Method -Uri $Uri -Headers $h -Body $Body -ContentType $ContentType
    if ($r.StatusCode -eq 401) { throw ('{0}: the server rejected the user name or password (for iCloud use an app-specific password).' -f $Account.Name) }
    return $r
}

function ConvertFrom-MultiStatus {
    <# Parses a WebDAV multistatus response into Href + successful prop nodes. #>
    param([string]$Xml, [string]$BaseUri)
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($Xml)
    foreach ($resp in $doc.SelectNodes("//*[local-name()='response']")) {
        $hrefNode = $resp.SelectSingleNode("*[local-name()='href']")
        if ($null -eq $hrefNode) { continue }
        $href = ([Uri]::new([Uri]$BaseUri, $hrefNode.InnerText.Trim())).AbsoluteUri
        $props = New-Object 'System.Collections.Generic.List[object]'
        foreach ($ps in $resp.SelectNodes("*[local-name()='propstat']")) {
            $st = $ps.SelectSingleNode("*[local-name()='status']")
            if ($null -ne $st -and $st.InnerText -notmatch '\s2\d\d(\s|$)') { continue }
            $p = $ps.SelectSingleNode("*[local-name()='prop']")
            if ($null -ne $p) { $props.Add($p) }
        }
        [pscustomobject]@{ Href = $href; Props = $props }
    }
}

function Get-DavProp {
    <# Finds a property node by local name in a multistatus entry. #>
    param($Entry, [string]$LocalName)
    foreach ($p in $Entry.Props) {
        $n = $p.SelectSingleNode("*[local-name()='$LocalName']")
        if ($null -ne $n) { return $n }
    }
    return $null
}

function Get-DavHref {
    <# Resolves the href inside a property such as current-user-principal. #>
    param($Entry, [string]$LocalName, [string]$BaseUri)
    $n = Get-DavProp $Entry $LocalName
    if ($null -eq $n) { return '' }
    $h = $n.SelectSingleNode(".//*[local-name()='href']")
    if ($null -eq $h) { return '' }
    return ([Uri]::new([Uri]$BaseUri, $h.InnerText.Trim())).AbsoluteUri
}

function Find-CalDavCalendar {
    <# Discovers the event calendars of a CalDAV account (principal -> calendar home -> collections). #>
    param($Account)
    $base = $Account.ServerUrl
    if (-not $base) { $base = $script:ICloudUrl }
    $principalXml = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>'
    $principal = ''
    foreach ($u in @($base, ([Uri]::new([Uri]$base, '/.well-known/caldav')).AbsoluteUri)) {
        $r = Invoke-CalDav -Account $Account -Method 'PROPFIND' -Uri $u -Depth '0' -Body $principalXml
        if ($r.StatusCode -ne 207) { continue }
        foreach ($entry in @(ConvertFrom-MultiStatus $r.Body $r.Uri)) {
            $principal = Get-DavHref $entry 'current-user-principal' $r.Uri
            if ($principal) { break }
        }
        if ($principal) { break }
    }
    if (-not $principal) { throw "Could not find a CalDAV account at $base. Check the server address." }
    $Account.PrincipalUrl = $principal

    $homeXml = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>'
    $r = Invoke-CalDav -Account $Account -Method 'PROPFIND' -Uri $principal -Depth '0' -Body $homeXml
    if ($r.StatusCode -ne 207) { throw ('Calendar home lookup failed: HTTP {0} {1}' -f $r.StatusCode, $r.Reason) }
    $calHome = ''
    foreach ($entry in @(ConvertFrom-MultiStatus $r.Body $r.Uri)) {
        $calHome = Get-DavHref $entry 'calendar-home-set' $r.Uri
        if ($calHome) { break }
    }
    if (-not $calHome) { throw 'The server did not report a calendar home.' }

    $listXml = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" ' +
    'xmlns:cs="http://calendarserver.org/ns/" xmlns:ic="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/>' +
    '<cs:getctag/><ic:calendar-color/><c:supported-calendar-component-set/><d:current-user-privilege-set/></d:prop></d:propfind>'
    $r = Invoke-CalDav -Account $Account -Method 'PROPFIND' -Uri $calHome -Depth '1' -Body $listXml
    if ($r.StatusCode -ne 207) { throw ('Listing calendars failed: HTTP {0} {1}' -f $r.StatusCode, $r.Reason) }
    foreach ($entry in @(ConvertFrom-MultiStatus $r.Body $r.Uri)) {
        $rt = Get-DavProp $entry 'resourcetype'
        if ($null -eq $rt -or $null -eq $rt.SelectSingleNode("*[local-name()='calendar']")) { continue }
        $comps = Get-DavProp $entry 'supported-calendar-component-set'
        if ($null -ne $comps) {
            $names = @($comps.SelectNodes("*[local-name()='comp']") | ForEach-Object { $_.GetAttribute('name') })
            if ($names.Count -gt 0 -and $names -notcontains 'VEVENT') { continue }
        }
        $readOnly = $false
        $priv = Get-DavProp $entry 'current-user-privilege-set'
        if ($null -ne $priv) {
            $writable = $priv.SelectSingleNode(".//*[local-name()='write' or local-name()='write-content' or local-name()='all']")
            $readOnly = ($null -eq $writable)
        }
        $nameNode = Get-DavProp $entry 'displayname'
        $name = ''
        if ($null -ne $nameNode) { $name = $nameNode.InnerText.Trim() }
        if (-not $name) { $name = [Uri]::UnescapeDataString(([Uri]$entry.Href).Segments[-1].Trim('/')) }
        $colorNode = Get-DavProp $entry 'calendar-color'
        $ctagNode = Get-DavProp $entry 'getctag'
        $colorText = ''; if ($null -ne $colorNode) { $colorText = $colorNode.InnerText.Trim() }
        $ctagText = ''; if ($null -ne $ctagNode) { $ctagText = $ctagNode.InnerText.Trim() }
        [pscustomobject]@{ Url = $entry.Href; Name = $name; Color = $colorText; CTag = $ctagText; ReadOnly = $readOnly; TimeZone = '' }
    }
}

function Get-CalDavCTag {
    <# Reads the collection tag that changes whenever anything in the calendar changes. #>
    param($Account, [string]$CalendarUrl)
    $xml = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:prop><cs:getctag/></d:prop></d:propfind>'
    $r = Invoke-CalDav -Account $Account -Method 'PROPFIND' -Uri $CalendarUrl -Depth '0' -Body $xml
    if ($r.StatusCode -ne 207) { return '' }
    foreach ($entry in @(ConvertFrom-MultiStatus $r.Body $r.Uri)) {
        $n = Get-DavProp $entry 'getctag'
        if ($null -ne $n) { return $n.InnerText.Trim() }
    }
    return ''
}

function Get-CalDavEvent {
    <# Emits Href/ETag/Data for every event resource that overlaps a UTC window. #>
    param($Account, [string]$CalendarUrl, [datetime]$FromUtc, [datetime]$ToUtc)
    $fmt = "yyyyMMdd'T'HHmmss'Z'"
    $xml = '<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' +
    '<d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">' +
    ('<c:time-range start="{0}" end="{1}"/>' -f $FromUtc.ToString($fmt, $script:Inv), $ToUtc.ToString($fmt, $script:Inv)) +
    '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>'
    $r = Invoke-CalDav -Account $Account -Method 'REPORT' -Uri $CalendarUrl -Depth '1' -Body $xml
    if ($r.StatusCode -ne 207) { throw ('Reading events failed: HTTP {0} {1} {2}' -f $r.StatusCode, $r.Reason, (Get-ResponseSnippet $r)) }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @(ConvertFrom-MultiStatus $r.Body $r.Uri)) {
        if ($entry.Href.TrimEnd('/') -eq $CalendarUrl.TrimEnd('/')) { continue }
        $etagNode = Get-DavProp $entry 'getetag'
        $dataNode = Get-DavProp $entry 'calendar-data'
        $etag = ''; if ($null -ne $etagNode) { $etag = $etagNode.InnerText.Trim() }
        if ($null -ne $dataNode -and $dataNode.InnerText.Trim()) {
            [pscustomobject]@{ Href = $entry.Href; ETag = $etag; Data = $dataNode.InnerText }
        }
        else { $missing.Add($entry.Href) }
    }
    # Some servers only return ETags from calendar-query; fetch the data with multiget.
    if ($missing.Count -gt 0) {
        $hrefs = ($missing | ForEach-Object { '<d:href>' + [Security.SecurityElement]::Escape(([Uri]$_).AbsolutePath) + '</d:href>' }) -join ''
        $mxml = '<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' +
        '<d:prop><d:getetag/><c:calendar-data/></d:prop>' + $hrefs + '</c:calendar-multiget>'
        $m = Invoke-CalDav -Account $Account -Method 'REPORT' -Uri $CalendarUrl -Depth '1' -Body $mxml
        if ($m.StatusCode -eq 207) {
            foreach ($entry in @(ConvertFrom-MultiStatus $m.Body $m.Uri)) {
                $etagNode = Get-DavProp $entry 'getetag'
                $dataNode = Get-DavProp $entry 'calendar-data'
                if ($null -eq $dataNode) { continue }
                $etag = ''; if ($null -ne $etagNode) { $etag = $etagNode.InnerText.Trim() }
                [pscustomobject]@{ Href = $entry.Href; ETag = $etag; Data = $dataNode.InnerText }
            }
        }
    }
}

#endregion

#region ------------------------------------------------------------ Google Calendar API

function ConvertTo-Base64Url {
    <# Base64url encoding without padding (RFC 4648). #>
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RandomString {
    <# Cryptographically random string of URL-safe characters. #>
    param([int]$Length)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function Request-GoogleAuthorization {
    <#
        Runs the OAuth 2.0 "installed app" flow: opens the browser, receives the
        code on a loopback port and exchanges it (with PKCE) for tokens.
    #>
    param([string]$ClientId, [string]$ClientSecret, [scriptblock]$OnUrl)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $port = $listener.LocalEndpoint.Port
        $redirect = 'http://127.0.0.1:' + $port + '/'
        $verifier = New-RandomString 64
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $challenge = ConvertTo-Base64Url ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))) } finally { $sha.Dispose() }
        $state = New-RandomString 24
        $query = [ordered]@{
            client_id = $ClientId; redirect_uri = $redirect; response_type = 'code'; scope = $script:GoogleScope
            code_challenge = $challenge; code_challenge_method = 'S256'; state = $state; access_type = 'offline'; prompt = 'consent'
        }
        $url = $script:GoogleAuthUrl + '?' + (ConvertTo-QueryString $query)
        try { Start-Process -FilePath $url } catch { Write-Verbose 'Could not open the browser automatically.' }
        if ($null -ne $OnUrl) { & $OnUrl $url }

        $deadline = (Get-Date).AddMinutes(5)
        $code = $null
        while (-not $code) {
            if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for the Google sign-in.' }
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) { throw 'Google sign-in cancelled.' }
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
            $client = $listener.AcceptTcpClient()
            $authError = $null
            try {
                $client.ReceiveTimeout = 5000
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
                $requestLine = $reader.ReadLine()
                if (-not $requestLine -or $requestLine -notmatch '^GET\s+(\S+)') { continue }
                $target = $Matches[1]
                $params = @{}
                if ($target.Contains('?')) { $params = ConvertFrom-QueryString ($target.Substring($target.IndexOf('?') + 1)) }
                if (-not $params.ContainsKey('code') -and -not $params.ContainsKey('error')) { continue }
                $message = 'PSCalendar is now connected to Google Calendar. You can close this window.'
                if ($params['state'] -ne $state) { $authError = 'The sign-in response was not for this request.'; $message = $authError }
                elseif ($params.ContainsKey('error')) { $authError = 'Google sign-in failed: ' + $params['error']; $message = $authError }
                else { $code = $params['code'] }
                $html = '<!doctype html><html><head><meta charset="utf-8"><title>PSCalendar</title></head><body style="font-family:sans-serif">' +
                '<h2>PSCalendar</h2><p>' + [Security.SecurityElement]::Escape($message) + '</p></body></html>'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($hb, 0, $hb.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            catch { Write-Verbose ('Ignored a browser connection: ' + $_.Exception.Message) }
            finally { $client.Close() }
            if ($authError) { throw $authError }
        }
        $form = ConvertTo-QueryString ([ordered]@{
                code = $code; client_id = $ClientId; client_secret = $ClientSecret; redirect_uri = $redirect
                grant_type = 'authorization_code'; code_verifier = $verifier
            })
        $r = Invoke-HttpRequest -Method 'POST' -Uri $script:GoogleTokenUrl -Body $form -ContentType 'application/x-www-form-urlencoded'
        if ($r.StatusCode -ne 200) { throw ('Google token exchange failed: HTTP {0} {1}' -f $r.StatusCode, (Get-ResponseSnippet $r)) }
        $tokens = $r.Body | ConvertFrom-Json
        if (-not (Get-Prop $tokens 'refresh_token')) { throw 'Google did not return a refresh token. Remove PSCalendar from your Google account permissions and try again.' }
        return $tokens
    }
    finally { $listener.Stop() }
}

function Get-GoogleAccessToken {
    <# Returns a valid access token, refreshing it when needed. #>
    param($Account, [switch]$Force)
    $cached = $script:TokenCache[$Account.Id]
    if (-not $Force -and $null -ne $cached -and $cached.Expires -gt (Get-Date).AddSeconds(60)) { return $cached.Token }
    $refresh = Unprotect-Secret $Account.RefreshToken
    if (-not $refresh) { throw ('{0} is not authorised. Open Calendars (C), select the account and press Enter to sign in again.' -f $Account.Name) }
    $form = ConvertTo-QueryString ([ordered]@{
            client_id = $Account.ClientId; client_secret = (Unprotect-Secret $Account.ClientSecret)
            refresh_token = $refresh; grant_type = 'refresh_token'
        })
    $r = Invoke-HttpRequest -Method 'POST' -Uri $script:GoogleTokenUrl -Body $form -ContentType 'application/x-www-form-urlencoded'
    if ($r.StatusCode -ne 200) {
        if ($r.Body -match 'invalid_grant') { throw ('Google access for {0} expired or was revoked. Open Calendars (C), select the account and press Enter to sign in again.' -f $Account.Name) }
        throw ('Google token refresh failed: HTTP {0} {1}' -f $r.StatusCode, (Get-ResponseSnippet $r))
    }
    $j = $r.Body | ConvertFrom-Json
    $script:TokenCache[$Account.Id] = @{ Token = [string]$j.access_token; Expires = (Get-Date).AddSeconds([int]$j.expires_in) }
    return [string]$j.access_token
}

function Invoke-GoogleApi {
    <# Calls the Google Calendar API and returns the raw response. #>
    param($Account, [string]$Method, [string]$Path, [System.Collections.IDictionary]$Query = @{}, $Body = $null, [hashtable]$Headers = @{})
    $uri = $script:GoogleApiBase + $Path
    if ($Query.Count -gt 0) { $uri += '?' + (ConvertTo-QueryString $Query) }
    $json = ''
    if ($null -ne $Body) { $json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
    $r = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $h = @{ Authorization = 'Bearer ' + (Get-GoogleAccessToken -Account $Account -Force:($attempt -gt 0)) }
        foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
        $r = Invoke-HttpRequest -Method $Method -Uri $uri -Headers $h -Body $json -ContentType 'application/json'
        if ($r.StatusCode -ne 401) { break }
    }
    return $r
}

function Get-GoogleErrorText {
    <# Extracts the error message from a Google API response. #>
    param($Response, [string]$Action)
    $msg = ''
    try { $msg = [string](Get-Prop (Get-Prop ($Response.Body | ConvertFrom-Json) 'error') 'message' '') } catch { $msg = '' }
    if (-not $msg) { $msg = Get-ResponseSnippet $Response }
    return ('{0} failed: HTTP {1} {2}' -f $Action, $Response.StatusCode, $msg)
}

function Find-GoogleCalendar {
    <# Emits the calendars in the user's Google calendar list. #>
    param($Account)
    $pageToken = ''
    do {
        $q = [ordered]@{ maxResults = '250' }
        if ($pageToken) { $q['pageToken'] = $pageToken }
        $r = Invoke-GoogleApi -Account $Account -Method 'GET' -Path '/users/me/calendarList' -Query $q
        if ($r.StatusCode -ne 200) { throw (Get-GoogleErrorText $r 'Listing Google calendars') }
        $j = $r.Body | ConvertFrom-Json
        foreach ($c in @(Get-PropList $j 'items')) {
            $name = [string](Get-Prop $c 'summaryOverride' (Get-Prop $c 'summary' $c.id))
            $role = [string](Get-Prop $c 'accessRole' 'reader')
            [pscustomobject]@{
                Url = [string]$c.id; Name = $name; Color = [string](Get-Prop $c 'backgroundColor' '')
                CTag = ''; ReadOnly = (@('reader', 'freeBusyReader') -contains $role); TimeZone = [string](Get-Prop $c 'timeZone' '')
            }
        }
        $pageToken = [string](Get-Prop $j 'nextPageToken' '')
    } while ($pageToken)
}

function Get-GoogleEvent {
    <# Emits the raw Google events (masters, exceptions and cancellations) in a UTC window. #>
    param($Account, $Calendar, [datetime]$FromUtc, [datetime]$ToUtc)
    $path = '/calendars/' + [Uri]::EscapeDataString($Calendar.RemoteId) + '/events'
    $fmt = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $pageToken = ''
    do {
        $q = [ordered]@{
            timeMin = $FromUtc.ToString($fmt, $script:Inv); timeMax = $ToUtc.ToString($fmt, $script:Inv)
            singleEvents = 'false'; showDeleted = 'true'; maxResults = '2500'
        }
        if ($pageToken) { $q['pageToken'] = $pageToken }
        $r = Invoke-GoogleApi -Account $Account -Method 'GET' -Path $path -Query $q
        if ($r.StatusCode -ne 200) { throw (Get-GoogleErrorText $r 'Reading Google events') }
        $j = $r.Body | ConvertFrom-Json
        foreach ($item in @(Get-PropList $j 'items')) { $item }
        $pageToken = [string](Get-Prop $j 'nextPageToken' '')
    } while ($pageToken)
}

function ConvertFrom-GoogleTime {
    <# Converts a Google start/end object into wall clock, zone and all-day flag. #>
    param($Time, [string]$DefaultTz, $ForceTz = $null)
    $date = Get-Prop $Time 'date'
    if ($null -ne $date) {
        if ($date -is [datetime]) { $d = [datetime]$date } else { $d = [datetime]::ParseExact([string]$date, 'yyyy-MM-dd', $script:Inv) }
        return [pscustomobject]@{ Wall = (ConvertTo-WallString $d $true); Tz = ''; AllDay = $true }
    }
    $dto = ConvertTo-DateTimeOffsetValue (Get-Prop $Time 'dateTime')
    if ($null -ne $ForceTz) { $tz = [string]$ForceTz } else { $tz = [string](Get-Prop $Time 'timeZone' $DefaultTz) }
    $wall = [TimeZoneInfo]::ConvertTime($dto, (Get-TimeZoneById $tz)).DateTime
    return [pscustomobject]@{ Wall = (ConvertTo-WallString $wall); Tz = $tz; AllDay = $false }
}

function ConvertFrom-GoogleEvent {
    <# Converts a Google API event into an event object. #>
    param($Google, $Calendar)
    $ev = New-CalEvent -CalendarId $Calendar.Id
    $ev.RemoteId = [string]$Google.id
    $ev.ETag = [string](Get-Prop $Google 'etag' '')
    $ev.Uid = [string](Get-Prop $Google 'iCalUID' '')
    $ev.MasterId = [string](Get-Prop $Google 'recurringEventId' '')
    $ev.Summary = [string](Get-Prop $Google 'summary' '')
    $ev.Location = [string](Get-Prop $Google 'location' '')
    $ev.Description = [string](Get-Prop $Google 'description' '')
    $ev.Url = [string](Get-Prop (Get-Prop $Google 'source') 'url' '')
    $ev.Status = ([string](Get-Prop $Google 'status' 'confirmed')).ToUpperInvariant()
    $ev.Transparency = 'OPAQUE'
    if ((Get-Prop $Google 'transparency' '') -eq 'transparent') { $ev.Transparency = 'TRANSPARENT' }
    $vis = [string](Get-Prop $Google 'visibility' 'default')
    if ($vis -ne 'default') { $ev.Visibility = $vis.ToUpperInvariant() }
    $ev.ColorId = [string](Get-Prop $Google 'colorId' '')
    $ev.Sequence = [int](Get-Prop $Google 'sequence' 0)
    $org = Get-Prop $Google 'organizer'
    if ($null -ne $org) { $ev.OrganizerEmail = [string](Get-Prop $org 'email' ''); $ev.OrganizerName = [string](Get-Prop $org 'displayName' '') }
    $statusMap = @{ needsAction = 'NEEDS-ACTION'; accepted = 'ACCEPTED'; declined = 'DECLINED'; tentative = 'TENTATIVE' }
    $ev.Attendees = @(foreach ($a in @(Get-PropList $Google 'attendees')) {
            $role = 'REQ-PARTICIPANT'
            if ([bool](Get-Prop $a 'optional' $false)) { $role = 'OPT-PARTICIPANT' }
            $st = $statusMap[[string](Get-Prop $a 'responseStatus' 'needsAction')]
            New-Attendee -Email ([string](Get-Prop $a 'email' '')) -Name ([string](Get-Prop $a 'displayName' '')) -Role $role -Status $st
        })
    $rem = Get-Prop $Google 'reminders'
    if ($null -ne $rem) {
        $ev.RemindersDefault = [bool](Get-Prop $rem 'useDefault' $false)
        $ev.Reminders = [int[]]@(foreach ($o in @(Get-PropList $rem 'overrides')) { [int](Get-Prop $o 'minutes' 0) })
    }
    $defaultTz = $Calendar.TimeZone
    if (-not $defaultTz) { $defaultTz = Get-LocalIanaTimeZone }
    $startObj = Get-Prop $Google 'start'
    $endObj = Get-Prop $Google 'end'
    $orig = Get-Prop $Google 'originalStartTime'
    if ($null -eq $startObj) { $startObj = $orig; $endObj = $orig } # cancelled occurrences carry no start
    $s = ConvertFrom-GoogleTime -Time $startObj -DefaultTz $defaultTz
    $ev.AllDay = $s.AllDay
    $ev.TimeZone = $s.Tz
    $ev.Start = $s.Wall
    if ($null -ne $endObj) { $ev.End = (ConvertFrom-GoogleTime -Time $endObj -DefaultTz $defaultTz -ForceTz $ev.TimeZone).Wall } else { $ev.End = $ev.Start }
    if ($ev.AllDay -and $ev.End -eq $ev.Start) { $ev.End = ConvertTo-WallString ((ConvertFrom-WallString $ev.Start).AddDays(1)) $true }
    $ex = New-Object 'System.Collections.Generic.List[string]'
    $extra = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @(Get-PropList $Google 'recurrence')) {
        $line = [string]$line
        if ($line -match '^(?i)RRULE:') { $ev.RRule = $line.Substring(6) }
        elseif ($line -match '^(?i)EXDATE') {
            $p = Split-ICalLine $line
            if ($null -eq $p) { continue }
            foreach ($v in $p.Value.Split(',')) {
                if (-not $v.Trim()) { continue }
                $d = ConvertFrom-ICalDateValue $v $p.Params
                $w = ConvertTo-WallString (ConvertFrom-WallString $d.Wall) $d.AllDay
                if (-not $d.AllDay) { $w = Convert-WallString -Wall $w -FromTz $d.Tz -ToTz $ev.TimeZone }
                if ($ev.AllDay) { $w = $w.Substring(0, 8) }
                $ex.Add($w)
            }
        }
        else { $extra.Add($line) }
    }
    $ev.ExDates = $ex.ToArray()
    $ev.RecurrenceExtra = $extra.ToArray()
    if ($null -ne $orig) { $ev.RecurrenceId = (ConvertFrom-GoogleTime -Time $orig -DefaultTz $defaultTz -ForceTz $ev.TimeZone).Wall }
    return $ev
}

function ConvertTo-GoogleEvent {
    <# Builds the Google API request body for an event. #>
    param($Event)
    $tz = ''
    if (-not $Event.AllDay) { $tz = ConvertTo-IanaTimeZone $Event.TimeZone }
    $body = [ordered]@{
        summary     = $Event.Summary
        location    = $Event.Location
        description = $Event.Description
    }
    foreach ($which in 'start', 'end') {
        $wall = $Event.Start
        if ($which -eq 'end') { $wall = $Event.End }
        $dt = ConvertFrom-WallString $wall
        if ($Event.AllDay) { $body[$which] = [ordered]@{ date = $dt.ToString('yyyy-MM-dd', $script:Inv) } }
        elseif ($tz) {
            $body[$which] = [ordered]@{ dateTime = $dt.ToString("yyyy-MM-dd'T'HH:mm:ss", $script:Inv); timeZone = $tz }
        }
        else {
            $utc = Convert-WallTime -DateTime $dt -From (Get-TimeZoneById $Event.TimeZone) -To ([TimeZoneInfo]::Utc)
            $body[$which] = [ordered]@{ dateTime = $utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv); timeZone = 'UTC' }
        }
    }
    $body['status'] = $Event.Status.ToLowerInvariant()
    $body['transparency'] = $Event.Transparency.ToLowerInvariant()
    $body['visibility'] = 'default'
    if ($Event.Visibility) { $body['visibility'] = $Event.Visibility.ToLowerInvariant() }
    if ($Event.ColorId) { $body['colorId'] = $Event.ColorId } else { $body['colorId'] = $null }
    $statusMap = @{ 'NEEDS-ACTION' = 'needsAction'; ACCEPTED = 'accepted'; DECLINED = 'declined'; TENTATIVE = 'tentative' }
    $body['attendees'] = @(foreach ($a in @($Event.Attendees)) {
            $item = [ordered]@{ email = $a.Email; optional = ($a.Role -eq 'OPT-PARTICIPANT') }
            if ($a.Name) { $item['displayName'] = $a.Name }
            if ($statusMap.ContainsKey($a.Status)) { $item['responseStatus'] = $statusMap[$a.Status] }
            $item
        })
    if ($Event.RemindersDefault) { $body['reminders'] = [ordered]@{ useDefault = $true } }
    else {
        $body['reminders'] = [ordered]@{
            useDefault = $false
            overrides  = @(foreach ($m in @($Event.Reminders | Select-Object -First 5)) { [ordered]@{ method = 'popup'; minutes = [int]$m } })
        }
    }
    if ($Event.Url -match '^https?://') { $body['source'] = [ordered]@{ url = $Event.Url; title = 'Link' } }
    if (-not $Event.RecurrenceId) {
        $rec = New-Object 'System.Collections.Generic.List[string]'
        if ($Event.RRule) {
            $rec.Add('RRULE:' + $Event.RRule)
            if (@($Event.ExDates).Count -gt 0) {
                $exTz = $Event.TimeZone
                if (-not $Event.AllDay -and -not $exTz) { $exTz = $tz }
                $rec.Add((Format-ICalDateLine 'EXDATE' @($Event.ExDates) $exTz $Event.AllDay))
            }
            foreach ($x in @($Event.RecurrenceExtra)) { $rec.Add($x) }
        }
        $body['recurrence'] = $rec.ToArray()
    }
    return $body
}

#endregion

#region ------------------------------------------------------------ Synchronisation

function Write-SyncLog {
    <# Adds a line to the sync log (and prints it in -SyncOnly mode). #>
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    $script:SyncLog.Add($line)
    while ($script:SyncLog.Count -gt 500) { $script:SyncLog.RemoveAt(0) }
    if (-not $script:TuiActive) { Write-Information -MessageData $line -InformationAction Continue }
}

function Write-SyncProgress {
    <# Shows what is being synchronised. #>
    param([string]$Text)
    if ($script:TuiActive) {
        if ($null -ne $script:SyncSnapshot) { Restore-ScreenBuffer $script:SyncSnapshot }
        Show-TuiBusy -Title 'Synchronising' -Message $Text
    }
}

function Get-SyncWindow {
    <# The date range that is synchronised (local and UTC). #>
    $s = $script:Config.Settings
    $from = (Get-Date).Date.AddDays(-[int]$s.PastDays)
    $to = (Get-Date).Date.AddDays([int]$s.FutureDays + 1)
    return [pscustomobject]@{ From = $from; To = $to; FromUtc = $from.ToUniversalTime(); ToUtc = $to.ToUniversalTime() }
}

function Test-EventOutsideWindow {
    <# True when a non-recurring event lies completely outside the sync window. #>
    param($Event, $Window)
    if ($Event.RRule) { return $false }
    try {
        $s = ConvertTo-LocalTime $Event.Start $Event.TimeZone $Event.AllDay
        $e = ConvertTo-LocalTime $Event.End $Event.TimeZone $Event.AllDay
        return ($e -lt $Window.From -or $s -gt $Window.To)
    }
    catch { return $false }
}

function Merge-RemoteEvent {
    <#
        Replaces the local copy of a calendar with the server copy while keeping
        local changes that are not uploaded yet and events outside the window.
    #>
    param($Calendar, [object[]]$Remote, [string]$KeyName, $Window)
    $local = @($script:Events | Where-Object { $_.CalendarId -eq $Calendar.Id })
    $dirtyKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $local) { if ($e.Dirty -and $e.$KeyName) { [void]$dirtyKeys.Add($e.$KeyName) } }
    $remoteKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $Remote) { if ($r.$KeyName) { [void]$remoteKeys.Add($r.$KeyName) } }
    $idMap = @{}
    foreach ($e in $local) { if ($e.$KeyName) { $idMap[$e.$KeyName + '|' + $e.RecurrenceId] = $e.Id } }

    $keep = New-Object 'System.Collections.Generic.List[object]'
    $removed = 0
    foreach ($e in $local) {
        $key = $e.$KeyName
        if ($e.Dirty -or -not $key -or $dirtyKeys.Contains($key)) { $keep.Add($e) }
        elseif ($remoteKeys.Contains($key)) { Write-Verbose "Replacing $key" }
        elseif (Test-EventOutsideWindow $e $Window) { $keep.Add($e) }
        else { $removed++ }
    }
    $added = 0
    foreach ($r in $Remote) {
        $key = $r.$KeyName
        if ($key -and $dirtyKeys.Contains($key)) { continue }
        $mk = $key + '|' + $r.RecurrenceId
        if ($idMap.ContainsKey($mk)) { $r.Id = $idMap[$mk] } else { $added++ }
        $keep.Add($r)
    }
    $others = @($script:Events | Where-Object { $_.CalendarId -ne $Calendar.Id })
    $script:Events.Clear()
    foreach ($e in $others) { $script:Events.Add($e) }
    foreach ($e in $keep) { $script:Events.Add($e) }
    $script:DataVersion++
    return [pscustomobject]@{ Added = $added; Removed = $removed; Total = @($Remote).Count }
}

function Reset-ConflictedEvent {
    <# Drops local changes after a conflict so the server copy wins on the next download. #>
    param([object[]]$Events, [string]$Href = '')
    foreach ($e in $Events) {
        $e.Dirty = $false
        $e.Deleted = $false
        if ($Href -and -not $e.Href) { $e.Href = $Href }
    }
    $script:DataVersion++
}

function Send-CalDavChange {
    <# Uploads local changes of a CalDAV calendar. Returns the number of resources written. #>
    param($Account, $Calendar)
    $calEvents = @($script:Events | Where-Object { $_.CalendarId -eq $Calendar.Id })
    $dirty = @($calEvents | Where-Object { $_.Dirty })
    if ($dirty.Count -eq 0) { return 0 }
    $serverWins = ($script:Config.Settings.ConflictPolicy -eq 'Server')
    $groups = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ev in $dirty) {
        $k = 'uid:' + $ev.Uid
        if ($ev.Href) { $k = $ev.Href }
        if (-not $groups.Contains($k)) { $groups.Add($k) }
    }
    $pushed = 0
    foreach ($k in $groups) {
        $isNew = $k.StartsWith('uid:')
        if ($isNew) {
            $uid = $k.Substring(4)
            $members = @($calEvents | Where-Object { -not $_.Href -and $_.Uid -eq $uid })
            $href = $Calendar.RemoteId.TrimEnd('/') + '/' + ($uid -replace '[^A-Za-z0-9._-]', '_') + '.ics'
        }
        else {
            $href = $k
            $members = @($calEvents | Where-Object { $_.Href -eq $href })
        }
        $alive = @($members | Where-Object { -not $_.Deleted })
        $etag = @($members | Where-Object { $_.ETag } | ForEach-Object { $_.ETag } | Select-Object -First 1)
        $title = '(No title)'
        if ($members.Count -gt 0 -and $members[0].Summary) { $title = $members[0].Summary }
        try {
            $headers = @{}
            if ($alive.Count -eq 0) {
                if ($isNew) { Remove-StoredEvent $members; continue }
                if ($etag.Count -and $serverWins) { $headers['If-Match'] = $etag[0] }
                $r = Invoke-CalDav -Account $Account -Method 'DELETE' -Uri $href -Headers $headers
                if ((200, 204, 404) -contains $r.StatusCode) { Remove-StoredEvent $members; $pushed++; Write-SyncLog "Deleted '$title' from $($Calendar.Name)" }
                elseif ($r.StatusCode -eq 412) { Reset-ConflictedEvent $members; $Calendar.CTag = ''; Write-SyncLog "CONFLICT '$title' changed on the server; the server copy was kept." }
                elseif (-not $isNew -and $r.StatusCode -ge 400 -and $r.StatusCode -lt 500) { Reset-ConflictedEvent $members; $Calendar.CTag = ''; Write-SyncLog ("REJECTED the server refused the change to '{0}' (HTTP {1} {2}); the server copy was restored." -f $title, $r.StatusCode, $r.Reason) }
                else { throw ('HTTP {0} {1} {2}' -f $r.StatusCode, $r.Reason, (Get-ResponseSnippet $r)) }
            }
            else {
                if ($isNew) { $headers['If-None-Match'] = '*' }
                elseif ($etag.Count -and $serverWins) { $headers['If-Match'] = $etag[0] }
                $ics = ConvertTo-ICalText $alive
                $r = Invoke-CalDav -Account $Account -Method 'PUT' -Uri $href -Body $ics -ContentType 'text/calendar' -Headers $headers
                if ((200, 201, 204) -contains $r.StatusCode) {
                    foreach ($a in $alive) { $a.Href = $href; $a.ETag = $r.ETag; $a.Dirty = $false }
                    Remove-StoredEvent @($members | Where-Object { $_.Deleted })
                    $pushed++
                    Write-SyncLog "Uploaded '$title' to $($Calendar.Name)"
                }
                elseif ($r.StatusCode -eq 412) { Reset-ConflictedEvent $members $href; $Calendar.CTag = ''; Write-SyncLog "CONFLICT '$title' changed on the server; the server copy was kept." }
                elseif (-not $isNew -and $r.StatusCode -ge 400 -and $r.StatusCode -lt 500) { Reset-ConflictedEvent $members; $Calendar.CTag = ''; Write-SyncLog ("REJECTED the server refused the change to '{0}' (HTTP {1} {2}); the server copy was restored." -f $title, $r.StatusCode, $r.Reason) }
                else { throw ('HTTP {0} {1} {2}' -f $r.StatusCode, $r.Reason, (Get-ResponseSnippet $r)) }
            }
        }
        catch { Write-SyncLog ("ERROR uploading '{0}' to {1}: {2}" -f $title, $Calendar.Name, $_.Exception.Message) }
    }
    $script:DataVersion++
    return $pushed
}

function Sync-CalDavCalendar {
    <# Two-way sync of one CalDAV calendar: upload local changes, then download. #>
    param($Account, $Calendar)
    $pushed = 0
    if (-not $Calendar.ReadOnly) { $pushed = Send-CalDavChange $Account $Calendar }
    $ctag = ''
    try { $ctag = Get-CalDavCTag $Account $Calendar.RemoteId } catch { $ctag = '' }
    $today = (Get-Date).ToString('yyyyMMdd')
    if ($pushed -eq 0 -and $ctag -and $ctag -eq $Calendar.CTag -and $Calendar.LastWindow -eq $today) {
        Write-SyncLog "$($Calendar.Name): no changes on the server"
        return
    }
    $win = Get-SyncWindow
    $remote = New-Object 'System.Collections.Generic.List[object]'
    foreach ($res in @(Get-CalDavEvent -Account $Account -CalendarUrl $Calendar.RemoteId -FromUtc $win.FromUtc -ToUtc $win.ToUtc)) {
        try {
            $root = ConvertFrom-ICalText $res.Data
            foreach ($comp in @(Get-ICalComponent -Node $root -Type 'VEVENT')) {
                $ev = ConvertFrom-ICalEvent -Component $comp -CalendarId $Calendar.Id
                if ($null -eq $ev) { continue }
                $ev.Href = $res.Href
                $ev.ETag = $res.ETag
                $remote.Add($ev)
            }
        }
        catch { Write-SyncLog ('WARNING could not read {0}: {1}' -f $res.Href, $_.Exception.Message) }
    }
    $stats = Merge-RemoteEvent -Calendar $Calendar -Remote $remote.ToArray() -KeyName 'Href' -Window $win
    $Calendar.CTag = $ctag
    $Calendar.LastWindow = $today
    Write-SyncLog ('{0}: {1} events, {2} new, {3} removed' -f $Calendar.Name, $stats.Total, $stats.Added, $stats.Removed)
}

function Send-GoogleChange {
    <# Uploads local changes of a Google calendar. #>
    param($Account, $Calendar)
    $path = '/calendars/' + [Uri]::EscapeDataString($Calendar.RemoteId) + '/events'
    $query = [ordered]@{ sendUpdates = [string]$script:Config.Settings.GoogleSendUpdates }
    $serverWins = ($script:Config.Settings.ConflictPolicy -eq 'Server')
    foreach ($ev in @($script:Events | Where-Object { $_.CalendarId -eq $Calendar.Id -and $_.Dirty })) {
        $title = $ev.Summary
        if (-not $title) { $title = '(No title)' }
        try {
            $headers = @{}
            if ($ev.ETag -and $serverWins) { $headers['If-Match'] = $ev.ETag }
            if ($ev.Deleted) {
                if (-not $ev.RemoteId) { Remove-StoredEvent @($ev); continue }
                $r = Invoke-GoogleApi -Account $Account -Method 'DELETE' -Path ($path + '/' + [Uri]::EscapeDataString($ev.RemoteId)) -Query $query -Headers $headers
                if ((200, 204, 404, 410) -contains $r.StatusCode) { Remove-StoredEvent @($ev); Write-SyncLog "Deleted '$title' from $($Calendar.Name)" }
                elseif ($r.StatusCode -eq 412) { Reset-ConflictedEvent @($ev); Write-SyncLog "CONFLICT '$title' changed on the server; the server copy was kept." }
                elseif ($r.StatusCode -ge 400 -and $r.StatusCode -lt 500) { Reset-ConflictedEvent @($ev); Write-SyncLog ('REJECTED ' + (Get-GoogleErrorText $r "Deleting '$title'") + '; the server copy was restored.') }
                else { throw (Get-GoogleErrorText $r 'Delete') }
                continue
            }
            $wasRemote = [bool]$ev.RemoteId
            if (-not $ev.RemoteId) {
                if ($ev.RecurrenceId) { $ev.Dirty = $false; continue }
                $r = Invoke-GoogleApi -Account $Account -Method 'POST' -Path $path -Query $query -Body (ConvertTo-GoogleEvent $ev)
            }
            else {
                $r = Invoke-GoogleApi -Account $Account -Method 'PATCH' -Path ($path + '/' + [Uri]::EscapeDataString($ev.RemoteId)) -Query $query -Body (ConvertTo-GoogleEvent $ev) -Headers $headers
            }
            if ($r.StatusCode -eq 200) {
                $j = $r.Body | ConvertFrom-Json
                $ev.RemoteId = [string]$j.id
                $ev.ETag = [string](Get-Prop $j 'etag' '')
                $ev.Uid = [string](Get-Prop $j 'iCalUID' $ev.Uid)
                $ev.Dirty = $false
                Write-SyncLog "Uploaded '$title' to $($Calendar.Name)"
            }
            elseif ($r.StatusCode -eq 412) { Reset-ConflictedEvent @($ev); Write-SyncLog "CONFLICT '$title' changed on the server; the server copy was kept." }
            elseif ($wasRemote -and $r.StatusCode -ge 400 -and $r.StatusCode -lt 500) { Reset-ConflictedEvent @($ev); Write-SyncLog ('REJECTED ' + (Get-GoogleErrorText $r "Updating '$title'") + '; the server copy was restored.') }
            else { throw (Get-GoogleErrorText $r 'Upload') }
        }
        catch { Write-SyncLog ("ERROR uploading '{0}' to {1}: {2}" -f $title, $Calendar.Name, $_.Exception.Message) }
    }
    $script:DataVersion++
}

function Sync-GoogleCalendar {
    <# Two-way sync of one Google calendar: upload local changes, then download. #>
    param($Account, $Calendar)
    if (-not $Calendar.ReadOnly) { Send-GoogleChange $Account $Calendar }
    $win = Get-SyncWindow
    $remote = New-Object 'System.Collections.Generic.List[object]'
    foreach ($g in @(Get-GoogleEvent -Account $Account -Calendar $Calendar -FromUtc $win.FromUtc -ToUtc $win.ToUtc)) {
        $status = [string](Get-Prop $g 'status' '')
        # A cancelled event without a master was deleted; a cancelled exception hides one occurrence.
        if ($status -eq 'cancelled' -and -not (Get-Prop $g 'recurringEventId')) { continue }
        try { $remote.Add((ConvertFrom-GoogleEvent -Google $g -Calendar $Calendar)) }
        catch { Write-SyncLog ('WARNING could not read Google event {0}: {1}' -f (Get-Prop $g 'id' '?'), $_.Exception.Message) }
    }
    # Exceptions are matched to their series through the series UID.
    $uidById = @{}
    foreach ($r in $remote) { if ($r.Uid) { $uidById[$r.RemoteId] = $r.Uid } }
    foreach ($r in $remote) { if (-not $r.Uid -and $r.MasterId -and $uidById.ContainsKey($r.MasterId)) { $r.Uid = $uidById[$r.MasterId] } }
    $stats = Merge-RemoteEvent -Calendar $Calendar -Remote $remote.ToArray() -KeyName 'RemoteId' -Window $win
    Write-SyncLog ('{0}: {1} events, {2} new, {3} removed' -f $Calendar.Name, $stats.Total, $stats.Added, $stats.Removed)
}

function ConvertTo-FeedUrl {
    <# Turns a subscription address (webcal://, webcals://, http(s)://) into the URL to download. #>
    param([string]$Url)
    $u = $Url.Trim()
    if ($u -match '^(?i)webcals?://') { $u = 'https://' + ($u -replace '^(?i)webcals?://', '') }
    return $u
}

function Get-SubscriptionFeed {
    <#
        Downloads a subscribed calendar. Sends the last ETag so an unchanged
        feed costs nothing. Returns $null when the feed has not changed,
        otherwise the parsed tree, the ETag and the calendar's own name.
    #>
    param([string]$Url, [string]$ETag = '')
    $headers = @{ Accept = 'text/calendar, */*;q=0.5' }
    if ($ETag) { $headers['If-None-Match'] = $ETag }
    $r = Invoke-HttpRequest -Method 'GET' -Uri (ConvertTo-FeedUrl $Url) -Headers $headers
    if ($r.StatusCode -eq 304) { return $null }
    if ($r.StatusCode -ne 200) { throw ('Download failed: HTTP {0} {1}' -f $r.StatusCode, $r.Reason) }
    if ($r.Body -notmatch 'BEGIN:VCALENDAR') { throw 'The address did not return a calendar (.ics) file.' }
    $root = ConvertFrom-ICalText $r.Body
    $name = ''
    $refresh = 0
    foreach ($vcal in @(Get-ICalComponent -Node $root -Type 'VCALENDAR')) {
        foreach ($p in $vcal.Props) {
            if ($p.Name -eq 'X-WR-CALNAME' -or $p.Name -eq 'NAME') { $name = ConvertFrom-ICalTextValue $p.Value.Trim() }
            elseif ($p.Name -eq 'REFRESH-INTERVAL' -or $p.Name -eq 'X-PUBLISHED-TTL') { $refresh = [int](ConvertFrom-ICalDuration $p.Value.Trim()).TotalMinutes }
        }
    }
    return [pscustomobject]@{ Root = $root; ETag = $r.ETag; Name = $name; RefreshMinutes = $refresh }
}

function Test-SubscriptionDue {
    <# True when a subscribed calendar should be downloaded again. #>
    param($Calendar)
    if (-not $Calendar.LastSync) { return $true }
    $minutes = [int]$Calendar.RefreshMinutes
    if ($minutes -le 0) { $minutes = $script:SubscriptionRefreshMinutes }
    $minutes = [Math]::Min([Math]::Max($minutes, 60), 10080)   # between one hour and one week
    try { return (((Get-Date) - (ConvertFrom-WallString $Calendar.LastSync)).TotalMinutes -ge $minutes) }
    catch { return $true }
}

function Sync-SubscriptionCalendar {
    <# Downloads a read-only subscribed calendar (.ics feed) and replaces the local copy. #>
    param($Account, $Calendar)
    $feed = Get-SubscriptionFeed -Url $Calendar.RemoteId -ETag $Calendar.CTag
    if ($null -eq $feed) { Write-SyncLog "$($Calendar.Name): no changes on the server"; return }
    $remote = New-Object 'System.Collections.Generic.List[object]'
    foreach ($comp in @(Get-ICalComponent -Node $feed.Root -Type 'VEVENT')) {
        try {
            $ev = ConvertFrom-ICalEvent -Component $comp -CalendarId $Calendar.Id
            if ($null -eq $ev) { continue }
            # Google appends instructions for its own settings page; they don't apply here.
            $ev.Description = $ev.Description -replace '(?s)\r?\nTo hide observances.*$', ''
            $remote.Add($ev)
        }
        catch { Write-SyncLog ('WARNING could not read an event in {0}: {1}' -f $Calendar.Name, $_.Exception.Message) }
    }
    # The whole feed is the server copy, so anything missing from it is gone.
    $all = [pscustomobject]@{ From = [datetime]::MinValue; To = [datetime]::MaxValue }
    $stats = Merge-RemoteEvent -Calendar $Calendar -Remote $remote.ToArray() -KeyName 'Uid' -Window $all
    $Calendar.CTag = $feed.ETag
    $Calendar.RefreshMinutes = $feed.RefreshMinutes
    Write-SyncLog ('{0}: {1} events, {2} new, {3} removed' -f $Calendar.Name, $stats.Total, $stats.Added, $stats.Removed)
}

function Sync-AllCalendar {
    <#
        Synchronises every enabled calendar (optionally of one account).
        Subscribed calendars are skipped until their refresh interval has
        passed, unless -Force is given (a sync the user asked for).
    #>
    param([string]$AccountId = '', [switch]$Force)
    $script:LastSyncAttempt = Get-Date
    $errors = 0
    $count = 0
    foreach ($acc in @($script:Config.Accounts | Where-Object { $_.Type -ne 'Local' -and $_.Enabled -and (-not $AccountId -or $_.Id -eq $AccountId) })) {
        foreach ($cal in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $acc.Id -and $_.Sync })) {
            if ($acc.Type -eq 'Subscription' -and -not $Force -and -not (Test-SubscriptionDue $cal)) { continue }
            Write-SyncProgress ('{0}: {1}' -f $acc.Name, $cal.Name)
            try {
                if ($acc.Type -eq 'Google') { Sync-GoogleCalendar $acc $cal }
                elseif ($acc.Type -eq 'Subscription') { Sync-SubscriptionCalendar $acc $cal }
                else { Sync-CalDavCalendar $acc $cal }
                $cal.LastSync = ConvertTo-WallString (Get-Date)
                $count++
            }
            catch {
                $errors++
                Write-SyncLog ('ERROR {0} / {1}: {2}' -f $acc.Name, $cal.Name, $_.Exception.Message)
            }
        }
    }
    Save-Config
    Save-EventStore
    $script:LastSyncTime = Get-Date
    if ($errors) { $summary = 'Sync finished with {0} error(s). Press L to see the log.' -f $errors }
    elseif ($count -eq 0) { $summary = 'Calendars are up to date.' }
    else { $summary = 'Synchronised {0} calendar(s).' -f $count }
    Write-SyncLog $summary
    return [pscustomobject]@{ Errors = $errors; Calendars = $count; Summary = $summary }
}

function Test-HasSyncCalendar {
    <# True when at least one calendar is set to synchronise. #>
    foreach ($c in $script:Config.Calendars) {
        if (-not $c.Sync) { continue }
        $acc = Get-Account $c.AccountId
        if ($null -ne $acc -and $acc.Type -ne 'Local' -and $acc.Enabled) { return $true }
    }
    return $false
}

function Test-AutoSyncDue {
    <# True when the automatic sync interval has passed. #>
    $minutes = [int]$script:Config.Settings.AutoSyncMinutes
    if ($minutes -le 0) { return $false }
    if (((Get-Date) - $script:LastSyncAttempt).TotalMinutes -lt $minutes) { return $false }
    return (Test-HasSyncCalendar)
}

#endregion

#region ------------------------------------------------------------ Screen buffer

function Initialize-ScreenBuffer {
    <# Allocates the off-screen buffer (characters + colour attributes). #>
    param([int]$Width, [int]$Height)
    $n = $Width * $Height
    $script:Buf = @{
        W       = $Width
        H       = $Height
        Ch      = New-Object 'char[]' $n
        At      = New-Object 'char[]' $n
        BlankCh = (' ' * $n).ToCharArray()
        BlankAt = ([string][char]7 * $n).ToCharArray()  # Gray on Black
    }
    $script:AttrFill = New-Object 'object[]' 256
    $script:PrevRows = $null
    Clear-ScreenBuffer
}

function Clear-ScreenBuffer {
    <# Blanks the off-screen buffer. #>
    $b = $script:Buf
    [Array]::Copy($b.BlankCh, $b.Ch, $b.Ch.Length)
    [Array]::Copy($b.BlankAt, $b.At, $b.At.Length)
}

function Write-Buffer {
    <# Draws text into the off-screen buffer (clipped to the screen). #>
    param([int]$X, [int]$Y, [string]$Text, [ConsoleColor]$Fg = [ConsoleColor]::Gray, [ConsoleColor]$Bg = [ConsoleColor]::Black, [int]$Width = -1)
    $b = $script:Buf
    if ($Y -lt 0 -or $Y -ge $b.H) { return }
    if ($null -eq $Text) { $Text = '' }
    if ($Width -ge 0) {
        if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) } else { $Text = $Text.PadRight($Width) }
    }
    if ($X -lt 0) {
        if (-$X -ge $Text.Length) { return }
        $Text = $Text.Substring(-$X)
        $X = 0
    }
    $len = [Math]::Min($Text.Length, $b.W - $X)
    if ($len -le 0) { return }
    $idx = $Y * $b.W + $X
    $Text.CopyTo(0, $b.Ch, $idx, $len)
    $attr = [int]$Fg + 16 * [int]$Bg
    $fill = $script:AttrFill[$attr]
    if ($null -eq $fill) {
        $fill = ([string][char]$attr * $b.W).ToCharArray()
        $script:AttrFill[$attr] = $fill
    }
    [Array]::Copy($fill, 0, $b.At, $idx, $len)
}

function Write-Fill {
    <# Fills a rectangle with a background colour. #>
    param([int]$X, [int]$Y, [int]$Width, [int]$Height, [ConsoleColor]$Bg = [ConsoleColor]::Black, [ConsoleColor]$Fg = [ConsoleColor]::Gray)
    if ($Width -le 0) { return }
    $blank = ' ' * $Width
    for ($i = 0; $i -lt $Height; $i++) { Write-Buffer -X $X -Y ($Y + $i) -Text $blank -Fg $Fg -Bg $Bg }
}

function Save-ScreenBuffer {
    <# Snapshot of the buffer so dialogs can restore what was under them. #>
    $b = $script:Buf
    return @{ W = $b.W; H = $b.H; Ch = $b.Ch.Clone(); At = $b.At.Clone() }
}

function Restore-ScreenBuffer {
    <# Restores a snapshot (or clears the buffer if the window was resized). #>
    param($Snapshot)
    $b = $script:Buf
    if ($null -eq $Snapshot -or $Snapshot.W -ne $b.W -or $Snapshot.H -ne $b.H) { Clear-ScreenBuffer; return }
    [Array]::Copy($Snapshot.Ch, $b.Ch, $b.Ch.Length)
    [Array]::Copy($Snapshot.At, $b.At, $b.At.Length)
}

function Show-ScreenBuffer {
    <# Writes the rows that changed since the last frame to the console. #>
    $b = $script:Buf
    $w = $b.W
    $h = $b.H
    if ($null -eq $script:PrevRows -or $script:PrevRows.Length -ne $h) { $script:PrevRows = New-Object 'string[]' $h }
    $e = $script:E
    $out = New-Object System.Text.StringBuilder
    for ($y = 0; $y -lt $h; $y++) {
        $start = $y * $w
        $len = $w
        if ($y -eq $h - 1) { $len = $w - 1 } # never write the last cell: it would scroll the screen
        $sig = [string]::new($b.Ch, $start, $len) + [string]::new($b.At, $start, $len)
        # Ordinal compare: -eq is culture-aware and ignores the control chars used as colour attributes.
        if ([string]::Equals($script:PrevRows[$y], $sig, [StringComparison]::Ordinal)) { continue }
        $script:PrevRows[$y] = $sig
        if (-not $script:UseAnsi) { [Console]::SetCursorPosition(0, $y) }
        else { [void]$out.Append($e).Append('[').Append($y + 1).Append(';1H') }
        $i = 0
        while ($i -lt $len) {
            $a = $b.At[$start + $i]
            $j = $i + 1
            while ($j -lt $len -and $b.At[$start + $j] -eq $a) { $j++ }
            $text = [string]::new($b.Ch, $start + $i, $j - $i)
            $ai = [int]$a
            if ($script:UseAnsi) {
                [void]$out.Append($e).Append('[').Append($script:AnsiFg[$ai % 16]).Append(';').Append($script:AnsiFg[[int][Math]::Floor($ai / 16)] + 10).Append('m').Append($text)
            }
            else {
                [Console]::ForegroundColor = [ConsoleColor]($ai % 16)
                [Console]::BackgroundColor = [ConsoleColor]([int][Math]::Floor($ai / 16))
                [Console]::Write($text)
            }
            $i = $j
        }
    }
    if ($script:UseAnsi -and $out.Length -gt 0) {
        [void]$out.Append($e).Append('[0m')
        [Console]::Write($out.ToString())
    }
}

function Update-ScreenSize {
    <# Re-creates the buffer when the console window changed size. Returns $true if it did. #>
    param([switch]$Force)
    $w = [Math]::Max(1, [Console]::WindowWidth)
    $h = [Math]::Max(1, [Console]::WindowHeight)
    if ($Force -or $null -eq $script:Buf -or $w -ne $script:Buf.W -or $h -ne $script:Buf.H) {
        Initialize-ScreenBuffer -Width $w -Height $h
        if ($script:UseAnsi) { [Console]::Write($script:E + '[0m' + $script:E + '[2J') } else { [Console]::ResetColor(); [Console]::Clear() }
        return $true
    }
    return $false
}

function Test-ConsoleResized {
    <# True when the console size no longer matches the buffer. #>
    return ([Console]::WindowWidth -ne $script:Buf.W -or [Console]::WindowHeight -ne $script:Buf.H)
}

function Test-AnsiSupport {
    <# Decides whether ANSI escape sequences can be used for drawing. #>
    $env = [Environment]::GetEnvironmentVariable('PSCALENDAR_ANSI')
    if ($env -eq '0') { return $false }
    if ($env -eq '1') { return $true }
    try { return [bool]$Host.UI.SupportsVirtualTerminal } catch { return $false }
}

#endregion

#region ------------------------------------------------------------ Dialog widgets

function Set-TuiCursor {
    <# Moves and shows or hides the console cursor. #>
    param([int]$X = -1, [int]$Y = -1, [bool]$Visible)
    if ($X -ge 0 -and $Y -ge 0) { [Console]::SetCursorPosition($X, $Y) }
    [Console]::CursorVisible = $Visible
}

function Read-TuiKey {
    <# Waits for a key. Returns $null when the window was resized (or the auto-sync timer fired). #>
    param([switch]$AllowTimeout, [switch]$IgnoreResize)
    while (-not [Console]::KeyAvailable) {
        if (-not $IgnoreResize -and (Test-ConsoleResized)) { return $null }
        if ($AllowTimeout -and (Test-AutoSyncDue)) { return $null }
        Start-Sleep -Milliseconds 40
    }
    return [Console]::ReadKey($true)
}

function Test-CtrlKey {
    <# True when Ctrl was held for a key press. #>
    param($Key)
    return (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
}

function Test-ShiftKey {
    <# True when Shift was held for a key press. #>
    param($Key)
    return (($Key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0)
}

function Write-Box {
    <# Draws a framed box with a title. #>
    param([int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Title = '', [ConsoleColor]$Border = 'Cyan', [ConsoleColor]$Bg = 'Black')
    $inner = [Math]::Max(0, $Width - 2)
    $G = $script:G
    Write-Buffer -X $X -Y $Y -Text ($G.TL + ($G.H * $inner) + $G.TR) -Fg $Border -Bg $Bg
    for ($i = 1; $i -lt $Height - 1; $i++) {
        Write-Buffer -X $X -Y ($Y + $i) -Text $G.V -Fg $Border -Bg $Bg
        Write-Buffer -X ($X + 1) -Y ($Y + $i) -Text (' ' * $inner) -Bg $Bg
        Write-Buffer -X ($X + $Width - 1) -Y ($Y + $i) -Text $G.V -Fg $Border -Bg $Bg
    }
    Write-Buffer -X $X -Y ($Y + $Height - 1) -Text ($G.BL + ($G.H * $inner) + $G.BR) -Fg $Border -Bg $Bg
    if ($Title) { Write-Buffer -X ($X + 2) -Y $Y -Text (Format-Cell (' ' + $Title + ' ') ($Width - 4)).TrimEnd() -Fg White -Bg $Bg }
}

function Get-DialogRect {
    <# Centres a dialog of the requested size on the screen. #>
    param([int]$Width, [int]$Height)
    $b = $script:Buf
    $w = [Math]::Max(10, [Math]::Min($Width, $b.W - 2))
    $h = [Math]::Max(3, [Math]::Min($Height, $b.H - 2))
    return @{ X = [int][Math]::Floor(($b.W - $w) / 2); Y = [int][Math]::Floor(($b.H - $h) / 2); W = $w; H = $h }
}

function Read-TuiLine {
    <# Single line text editor. Returns @{ Ok; Text; Key } (Key = Enter, Tab, Up, Down or Escape). #>
    param([int]$X, [int]$Y, [int]$Width, [string]$Text = '', [switch]$Mask, [string]$Original = $null)
    if ($null -eq $Original) { $Original = $Text }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Text)
    $pos = $sb.Length
    $off = 0
    if ($Width -lt 2) { $Width = 2 }
    try {
        while ($true) {
            if ($pos -lt $off) { $off = $pos }
            if ($pos -ge $off + $Width) { $off = $pos - $Width + 1 }
            $s = $sb.ToString()
            if ($Mask) { $s = '*' * $s.Length }
            $vis = ''
            if ($off -lt $s.Length) { $vis = $s.Substring($off) }
            Write-Buffer -X $X -Y $Y -Text (ConvertTo-DisplayText $vis) -Fg Black -Bg Cyan -Width $Width
            Show-ScreenBuffer
            Set-TuiCursor -X ([Math]::Min($X + $pos - $off, $script:Buf.W - 1)) -Y $Y -Visible $true
            # The line editor ignores window resizes; the dialog redraws afterwards.
            $k = Read-TuiKey -IgnoreResize
            $kn = [string]$k.Key
            $ctrl = Test-CtrlKey $k
            $cur = $sb.ToString()
            if ($kn -eq 'Enter') { return @{ Ok = $true; Text = $cur; Key = 'Enter' } }
            elseif ($kn -eq 'Escape') { return @{ Ok = $false; Text = $Original; Key = 'Escape' } }
            elseif ($kn -eq 'Tab' -or $kn -eq 'DownArrow') { return @{ Ok = $true; Text = $cur; Key = 'Down' } }
            elseif ($kn -eq 'UpArrow') { return @{ Ok = $true; Text = $cur; Key = 'Up' } }
            elseif ($kn -eq 'LeftArrow') {
                if ($ctrl) {
                    while ($pos -gt 0 -and $cur[$pos - 1] -eq ' ') { $pos-- }
                    while ($pos -gt 0 -and $cur[$pos - 1] -ne ' ') { $pos-- }
                }
                elseif ($pos -gt 0) { $pos-- }
            }
            elseif ($kn -eq 'RightArrow') {
                if ($ctrl) {
                    while ($pos -lt $cur.Length -and $cur[$pos] -ne ' ') { $pos++ }
                    while ($pos -lt $cur.Length -and $cur[$pos] -eq ' ') { $pos++ }
                }
                elseif ($pos -lt $cur.Length) { $pos++ }
            }
            elseif ($kn -eq 'Home') { $pos = 0 }
            elseif ($kn -eq 'End') { $pos = $sb.Length }
            elseif ($kn -eq 'Backspace') { if ($pos -gt 0) { [void]$sb.Remove($pos - 1, 1); $pos-- } }
            elseif ($kn -eq 'Delete') { if ($pos -lt $sb.Length) { [void]$sb.Remove($pos, 1) } }
            elseif ($ctrl -and $kn -eq 'U') { [void]$sb.Clear(); $pos = 0 }
            elseif ($ctrl -and $kn -eq 'V') {
                try { $clip = ConvertTo-DisplayText ([string](Get-Clipboard -Raw)) } catch { $clip = '' }
                [void]$sb.Insert($pos, $clip); $pos += $clip.Length
            }
            elseif ([int]$k.KeyChar -ge 32 -and (-not $ctrl -or ($k.Modifiers -band [ConsoleModifiers]::Alt))) {
                [void]$sb.Insert($pos, [string]$k.KeyChar); $pos++
            }
        }
    }
    finally { Set-TuiCursor -Visible $false }
}

function Show-TuiBusy {
    <# Draws a "please wait" box without waiting for a key. #>
    param([string]$Title, [string]$Message)
    $lines = @(Format-WrapText $Message 60)
    $width = 8
    foreach ($l in $lines) { $width = [Math]::Max($width, $l.Length + 4) }
    $width = [Math]::Max($width, $Title.Length + 6)
    $r = Get-DialogRect $width ($lines.Count + 2)
    Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title -Border Yellow
    for ($i = 0; $i -lt $lines.Count -and $i -lt $r.H - 2; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $lines[$i] -Fg White }
    Show-ScreenBuffer
}

function Show-TuiText {
    <# Scrollable text viewer. Lines are strings or @{ T = text; F = colour }. #>
    param([string]$Title, [object[]]$Lines, [int]$Width = 90)
    $snap = Save-ScreenBuffer
    $top = 0
    while ($true) {
        if (Update-ScreenSize) { $snap = $null }
        Restore-ScreenBuffer $snap
        $r = Get-DialogRect $Width ($Lines.Count + 4)
        $view = $r.H - 4
        $maxTop = [Math]::Max(0, $Lines.Count - $view)
        $top = [Math]::Max(0, [Math]::Min($top, $maxTop))
        Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title
        for ($i = 0; $i -lt $view; $i++) {
            $idx = $top + $i
            if ($idx -ge $Lines.Count) { break }
            $l = $Lines[$idx]
            $fg = 'Gray'
            $t = $l
            if ($l -is [System.Collections.IDictionary]) { $t = $l.T; if ($l.F) { $fg = $l.F } }
            Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text (ConvertTo-DisplayText ([string]$t)) -Fg $fg -Width ($r.W - 4)
        }
        $hint = 'Esc/Enter close'
        if ($maxTop -gt 0) { $hint = 'Up/Down/PgUp/PgDn scroll  ' + $hint + ('  ({0}/{1})' -f ($top + 1), ($maxTop + 1)) }
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text $hint -Fg DarkGray -Width ($r.W - 4)
        Show-ScreenBuffer
        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        switch ([string]$k.Key) {
            'UpArrow' { $top-- }
            'DownArrow' { $top++ }
            'PageUp' { $top -= $view }
            'PageDown' { $top += $view }
            'Home' { $top = 0 }
            'End' { $top = $maxTop }
            'Escape' { Restore-ScreenBuffer $snap; return }
            'Enter' { Restore-ScreenBuffer $snap; return }
            'Q' { Restore-ScreenBuffer $snap; return }
        }
    }
}

function Show-TuiMessage {
    <# Shows a message box and waits for a key. #>
    param([string]$Title, [string]$Message, [switch]$IsError)
    $lines = @(foreach ($l in (Format-WrapText $Message 70)) { if ($IsError) { @{ T = $l; F = 'Red' } } else { $l } })
    Show-TuiText -Title $Title -Lines $lines -Width 76
}

function Read-TuiConfirm {
    <# Yes/No question. Returns $true for yes. #>
    param([string]$Title, [string]$Message)
    $snap = Save-ScreenBuffer
    while ($true) {
        if (Update-ScreenSize) { $snap = $null }
        Restore-ScreenBuffer $snap
        $lines = @(Format-WrapText $Message 60)
        $r = Get-DialogRect 66 ($lines.Count + 4)
        Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title -Border Yellow
        for ($i = 0; $i -lt $lines.Count; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $lines[$i] -Fg White -Width ($r.W - 4) }
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text '[Y] Yes     [N] No' -Fg Yellow
        Show-ScreenBuffer
        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        $c = [string]$k.KeyChar
        if ($c -eq 'y' -or $c -eq 'Y') { Restore-ScreenBuffer $snap; return $true }
        if ($c -eq 'n' -or $c -eq 'N' -or [string]$k.Key -eq 'Escape') { Restore-ScreenBuffer $snap; return $false }
    }
}

function Read-TuiChoice {
    <# Pick one option from a list. Returns the index or -1 when cancelled. #>
    param([string]$Title, [string[]]$Options, [int]$Selected = 0, [string]$Message = '')
    $snap = Save-ScreenBuffer
    $idx = [Math]::Max(0, [Math]::Min($Selected, $Options.Count - 1))
    $top = 0
    $msgLines = @()
    if ($Message) { $msgLines = @(Format-WrapText $Message 64) }
    while ($true) {
        if (Update-ScreenSize) { $snap = $null }
        Restore-ScreenBuffer $snap
        $width = $Title.Length + 8
        foreach ($o in $Options) { $width = [Math]::Max($width, $o.Length + 8) }
        foreach ($m in $msgLines) { $width = [Math]::Max($width, $m.Length + 4) }
        $extra = $msgLines.Count
        if ($extra) { $extra++ }
        $r = Get-DialogRect ([Math]::Min($width, 80)) ($Options.Count + 4 + $extra)
        $view = [Math]::Max(1, $r.H - 4 - $extra)
        if ($idx -lt $top) { $top = $idx }
        if ($idx -ge $top + $view) { $top = $idx - $view + 1 }
        Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title
        for ($i = 0; $i -lt $msgLines.Count; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $msgLines[$i] -Fg Gray -Width ($r.W - 4) }
        for ($i = 0; $i -lt $view; $i++) {
            $oi = $top + $i
            if ($oi -ge $Options.Count) { break }
            $y = $r.Y + 1 + $extra + $i
            $text = '  ' + (ConvertTo-DisplayText $Options[$oi])
            if ($oi -eq $idx) { Write-Buffer -X ($r.X + 1) -Y $y -Text ($script:G.Right + $text.Substring(1)) -Fg Black -Bg Cyan -Width ($r.W - 2) }
            else { Write-Buffer -X ($r.X + 1) -Y $y -Text $text -Fg White -Width ($r.W - 2) }
        }
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text 'Enter select  Esc cancel' -Fg DarkGray -Width ($r.W - 4)
        Show-ScreenBuffer
        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        $kn = [string]$k.Key
        if ($kn -eq 'UpArrow') { if ($idx -gt 0) { $idx-- } else { $idx = $Options.Count - 1 } }
        elseif ($kn -eq 'DownArrow' -or $kn -eq 'Tab') { if ($idx -lt $Options.Count - 1) { $idx++ } else { $idx = 0 } }
        elseif ($kn -eq 'PageUp') { $idx = [Math]::Max(0, $idx - $view) }
        elseif ($kn -eq 'PageDown') { $idx = [Math]::Min($Options.Count - 1, $idx + $view) }
        elseif ($kn -eq 'Home') { $idx = 0 }
        elseif ($kn -eq 'End') { $idx = $Options.Count - 1 }
        elseif ($kn -eq 'Enter') { Restore-ScreenBuffer $snap; return $idx }
        elseif ($kn -eq 'Escape') { Restore-ScreenBuffer $snap; return -1 }
        elseif ([char]::IsLetterOrDigit($k.KeyChar)) {
            $c = [string]$k.KeyChar
            for ($s = 1; $s -le $Options.Count; $s++) {
                $j = ($idx + $s) % $Options.Count
                if ($Options[$j].StartsWith($c, [StringComparison]::OrdinalIgnoreCase)) { $idx = $j; break }
            }
        }
    }
}

function Read-TuiMultiChoice {
    <# Tick any number of options. Returns a bool array or $null when cancelled. #>
    param([string]$Title, [string[]]$Options, [bool[]]$Checked, [string]$Message = '')
    $snap = Save-ScreenBuffer
    $state = [bool[]]@($Checked)
    $idx = 0
    $top = 0
    $msgLines = @()
    if ($Message) { $msgLines = @(Format-WrapText $Message 70) }
    while ($true) {
        if (Update-ScreenSize) { $snap = $null }
        Restore-ScreenBuffer $snap
        $width = $Title.Length + 8
        foreach ($o in $Options) { $width = [Math]::Max($width, $o.Length + 10) }
        foreach ($m in $msgLines) { $width = [Math]::Max($width, $m.Length + 4) }
        $extra = $msgLines.Count
        if ($extra) { $extra++ }
        $r = Get-DialogRect ([Math]::Min($width, 90)) ($Options.Count + 4 + $extra)
        $view = [Math]::Max(1, $r.H - 4 - $extra)
        if ($idx -lt $top) { $top = $idx }
        if ($idx -ge $top + $view) { $top = $idx - $view + 1 }
        Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title
        for ($i = 0; $i -lt $msgLines.Count; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $msgLines[$i] -Fg Gray -Width ($r.W - 4) }
        for ($i = 0; $i -lt $view; $i++) {
            $oi = $top + $i
            if ($oi -ge $Options.Count) { break }
            $mark = '[ ] '
            if ($state[$oi]) { $mark = '[x] ' }
            $text = ' ' + $mark + (ConvertTo-DisplayText $Options[$oi])
            $y = $r.Y + 1 + $extra + $i
            if ($oi -eq $idx) { Write-Buffer -X ($r.X + 1) -Y $y -Text $text -Fg Black -Bg Cyan -Width ($r.W - 2) }
            else { Write-Buffer -X ($r.X + 1) -Y $y -Text $text -Fg White -Width ($r.W - 2) }
        }
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text 'Space tick  A all/none  Enter OK  Esc cancel' -Fg DarkGray -Width ($r.W - 4)
        Show-ScreenBuffer
        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        $kn = [string]$k.Key
        if ($kn -eq 'UpArrow') { if ($idx -gt 0) { $idx-- } }
        elseif ($kn -eq 'DownArrow') { if ($idx -lt $Options.Count - 1) { $idx++ } }
        elseif ($kn -eq 'PageUp') { $idx = [Math]::Max(0, $idx - $view) }
        elseif ($kn -eq 'PageDown') { $idx = [Math]::Min($Options.Count - 1, $idx + $view) }
        elseif ($kn -eq 'Spacebar') { $state[$idx] = -not $state[$idx] }
        elseif ($kn -eq 'A') {
            $allTicked = ($state -notcontains $false)
            for ($i = 0; $i -lt $state.Count; $i++) { $state[$i] = -not $allTicked }
        }
        elseif ($kn -eq 'Enter') { Restore-ScreenBuffer $snap; return , $state }
        elseif ($kn -eq 'Escape') { Restore-ScreenBuffer $snap; return $null }
    }
}

function Read-TuiInput {
    <# Asks for one line of text. Returns the text or $null when cancelled. #>
    param([string]$Title, [string]$Prompt, [string]$Default = '', [switch]$Mask)
    $snap = Save-ScreenBuffer
    $lines = @(Format-WrapText $Prompt 64)
    $r = Get-DialogRect 70 ($lines.Count + 5)
    Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title
    for ($i = 0; $i -lt $lines.Count; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $lines[$i] -Fg White -Width ($r.W - 4) }
    Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text 'Enter OK  Esc cancel' -Fg DarkGray
    $res = Read-TuiLine -X ($r.X + 2) -Y ($r.Y + $lines.Count + 2) -Width ($r.W - 4) -Text $Default -Mask:$Mask
    Restore-ScreenBuffer $snap
    if (-not $res.Ok) { return $null }
    return $res.Text
}

function New-FormField {
    <#
        Describes one form row. Types: text, password, choice, bool, readonly.
        When is an optional scriptblock ($values, $field) deciding visibility.
    #>
    param([string]$Key, [string]$Label, [string]$Type = 'text', $Value = '', [string[]]$Options = @(), [string]$Hint = '', [scriptblock]$When = $null, $Data = $null)
    return [pscustomobject]@{ Key = $Key; Label = $Label; Type = $Type; Value = $Value; Options = $Options; Hint = $Hint; When = $When; Data = $Data }
}

function Invoke-TuiForm {
    <#
        Generic full-screen form. Returns a hashtable of values, or $null when
        cancelled. Validate gets the values and returns an error text or $null.
        OnChange runs after a field is changed by the user and gets the values
        and the changed key; it may update other values.
    #>
    param([string]$Title, [object[]]$Fields, [scriptblock]$Validate = $null, [string]$Intro = '', [scriptblock]$OnChange = $null)
    $values = @{}
    foreach ($f in $Fields) { $values[$f.Key] = $f.Value }
    $original = @{}
    foreach ($k in $values.Keys) { $original[$k] = [string]$values[$k] }
    $snap = Save-ScreenBuffer
    $idx = 0
    $top = 0
    $msg = ''
    while ($true) {
        if (Update-ScreenSize) { $snap = $null }
        Restore-ScreenBuffer $snap
        $visible = @($Fields | Where-Object { $null -eq $_.When -or (& $_.When $values $_) })
        $rowCount = $visible.Count + 2  # + Save / Cancel
        if ($idx -ge $rowCount) { $idx = $rowCount - 1 }
        if ($idx -lt 0) { $idx = 0 }
        $introLines = @()
        if ($Intro) { $introLines = @(Format-WrapText $Intro ([Math]::Min(88, $script:Buf.W - 8))) }
        $introH = $introLines.Count
        if ($introH) { $introH++ }
        $r = Get-DialogRect 96 ($rowCount + 7 + $introH)
        $listTop = $r.Y + 1 + $introH
        $listH = [Math]::Max(1, $r.H - 5 - $introH)
        if ($idx -lt $top) { $top = $idx }
        if ($idx -ge $top + $listH) { $top = $idx - $listH + 1 }
        $top = [Math]::Max(0, [Math]::Min($top, [Math]::Max(0, $rowCount - $listH)))
        $labelW = 14
        foreach ($f in $visible) { $labelW = [Math]::Max($labelW, $f.Label.Length) }
        $labelW = [Math]::Min($labelW, 20)
        $valX = $r.X + 3 + $labelW + 2
        $valW = $r.X + $r.W - 2 - $valX
        Write-Box -X $r.X -Y $r.Y -Width $r.W -Height $r.H -Title $Title
        for ($i = 0; $i -lt $introLines.Count; $i++) { Write-Buffer -X ($r.X + 2) -Y ($r.Y + 1 + $i) -Text $introLines[$i] -Fg Gray -Width ($r.W - 4) }
        for ($i = 0; $i -lt $listH; $i++) {
            $ri = $top + $i
            if ($ri -ge $rowCount) { break }
            $y = $listTop + $i
            $sel = ($ri -eq $idx)
            if ($ri -ge $visible.Count) {
                $label = '[ Save ]'
                if ($ri -eq $visible.Count + 1) { $label = '[ Cancel ]' }
                if ($sel) { Write-Buffer -X ($valX) -Y $y -Text $label -Fg Black -Bg Cyan }
                else { Write-Buffer -X ($valX) -Y $y -Text $label -Fg White }
                continue
            }
            $f = $visible[$ri]
            $v = $values[$f.Key]
            switch ($f.Type) {
                'password' { $text = '*' * ([string]$v).Length; if (-not $v) { $text = '' } }
                'choice' { $text = '< ' + [string]$v + ' >' }
                'bool' { if ($v) { $text = '[x] Yes' } else { $text = '[ ] No' } }
                default { $text = [string]$v }
            }
            $text = ConvertTo-DisplayText $text
            $lfg = 'Gray'
            if ($sel) { $lfg = 'Cyan'; Write-Buffer -X ($r.X + 1) -Y $y -Text $script:G.Right -Fg Cyan }
            Write-Buffer -X ($r.X + 3) -Y $y -Text ($f.Label.PadLeft($labelW)) -Fg $lfg
            $vfg = 'White'; $vbg = 'Black'
            if ($f.Type -eq 'readonly') { $vfg = 'DarkGray' }
            if ($sel -and $f.Type -ne 'readonly') { $vfg = 'Black'; $vbg = 'DarkCyan' }
            Write-Buffer -X $valX -Y $y -Text $text -Fg $vfg -Bg $vbg -Width $valW
        }
        if ($top -gt 0) { Write-Buffer -X ($r.X + $r.W - 3) -Y $listTop -Text $script:G.Up -Fg Yellow }
        if ($top + $listH -lt $rowCount) { Write-Buffer -X ($r.X + $r.W - 3) -Y ($listTop + $listH - 1) -Text $script:G.Down -Fg Yellow }
        $hint = ''
        if ($idx -lt $visible.Count) {
            $cur = $visible[$idx]
            $hint = $cur.Hint
            if (-not $hint) {
                switch ($cur.Type) {
                    'choice' { $hint = 'Left/Right or Enter to change' }
                    'bool' { $hint = 'Space or Enter to toggle' }
                    'readonly' { $hint = 'Read only' }
                    default { $hint = 'Enter to edit, or just start typing' }
                }
            }
        }
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 4) -Text (ConvertTo-DisplayText $hint) -Fg DarkGray -Width ($r.W - 4)
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 3) -Text $msg -Fg Red -Width ($r.W - 4)
        Write-Buffer -X ($r.X + 2) -Y ($r.Y + $r.H - 2) -Text 'Up/Down move  Enter edit  F10 or Ctrl+S save  Esc cancel' -Fg DarkGray -Width ($r.W - 4)
        Show-ScreenBuffer

        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        $kn = [string]$k.Key
        $ctrl = Test-CtrlKey $k
        $cur = $null
        if ($idx -lt $visible.Count) { $cur = $visible[$idx] }
        $doSave = $false
        $doCancel = $false
        if ($kn -eq 'Escape') { $doCancel = $true }
        elseif (($ctrl -and $kn -eq 'S') -or $kn -eq 'F10') { $doSave = $true }
        elseif ($kn -eq 'UpArrow' -or ($kn -eq 'Tab' -and (Test-ShiftKey $k))) { $idx--; if ($idx -lt 0) { $idx = $rowCount - 1 } }
        elseif ($kn -eq 'DownArrow' -or $kn -eq 'Tab') { $idx++; if ($idx -ge $rowCount) { $idx = 0 } }
        elseif ($kn -eq 'PageUp') { $idx = [Math]::Max(0, $idx - $listH) }
        elseif ($kn -eq 'PageDown') { $idx = [Math]::Min($rowCount - 1, $idx + $listH) }
        elseif ($kn -eq 'Home') { $idx = 0 }
        elseif ($kn -eq 'End') { $idx = $rowCount - 1 }
        elseif ($null -eq $cur) {
            if ($kn -eq 'Enter' -or $kn -eq 'Spacebar') { if ($idx -eq $visible.Count) { $doSave = $true } else { $doCancel = $true } }
        }
        elseif ($cur.Type -eq 'choice' -and @($cur.Options).Count -gt 0) {
            $ci = [Array]::IndexOf([string[]]$cur.Options, [string]$values[$cur.Key])
            if ($kn -eq 'LeftArrow') { $ci--; if ($ci -lt 0) { $ci = $cur.Options.Count - 1 }; $values[$cur.Key] = $cur.Options[$ci] }
            elseif ($kn -eq 'RightArrow' -or $kn -eq 'Spacebar') { $ci = ($ci + 1) % $cur.Options.Count; $values[$cur.Key] = $cur.Options[$ci] }
            elseif ($kn -eq 'Enter') {
                $pick = Read-TuiChoice -Title $cur.Label -Options $cur.Options -Selected ([Math]::Max(0, $ci))
                if ($pick -ge 0) { $values[$cur.Key] = $cur.Options[$pick] }
            }
            if ($null -ne $OnChange -and [string]$values[$cur.Key] -ne $cur.Options[[Math]::Max(0, $ci)]) { & $OnChange $values $cur.Key }
        }
        elseif ($cur.Type -eq 'bool') {
            if ($kn -eq 'Enter' -or $kn -eq 'Spacebar' -or $kn -eq 'LeftArrow' -or $kn -eq 'RightArrow') {
                $values[$cur.Key] = -not [bool]$values[$cur.Key]
                if ($null -ne $OnChange) { & $OnChange $values $cur.Key }
            }
        }
        elseif ($cur.Type -eq 'text' -or $cur.Type -eq 'password') {
            # Enter/F2 edit the value, Backspace edits it minus the last character,
            # typing a character replaces it (like a spreadsheet cell).
            $old = [string]$values[$cur.Key]
            $start = $null
            if ($kn -eq 'Enter' -or $kn -eq 'F2') { $start = $old }
            elseif ($kn -eq 'Backspace') { $start = ''; if ($old.Length -gt 1) { $start = $old.Substring(0, $old.Length - 1) } }
            elseif ([int]$k.KeyChar -ge 32 -and -not $ctrl) { $start = [string]$k.KeyChar }
            if ($null -ne $start) {
                $y = $listTop + ($idx - $top)
                $res = Read-TuiLine -X $valX -Y $y -Width $valW -Text $start -Original $old -Mask:($cur.Type -eq 'password')
                if ($res.Ok) {
                    $values[$cur.Key] = $res.Text
                    if ($null -ne $OnChange -and $res.Text -ne $old) { & $OnChange $values $cur.Key }
                    if ($res.Key -eq 'Down') { $idx++ } elseif ($res.Key -eq 'Up') { $idx-- }
                }
                $msg = ''
            }
        }
        if ($doSave) {
            $err = $null
            if ($null -ne $Validate) { $err = & $Validate $values }
            if ($err) { $msg = [string]$err; continue }
            Restore-ScreenBuffer $snap
            return $values
        }
        if ($doCancel) {
            $changed = $false
            foreach ($key in $values.Keys) { if ([string]$values[$key] -ne $original[$key]) { $changed = $true } }
            if (-not $changed -or (Read-TuiConfirm -Title 'Discard changes?' -Message 'You have unsaved changes. Discard them?')) {
                Restore-ScreenBuffer $snap
                return $null
            }
        }
    }
}

#endregion

#region ------------------------------------------------------------ Event editor

$script:RepeatOptions = @('None', 'Daily', 'Weekly', 'Every weekday', 'Monthly', 'Yearly', 'Custom')

function ConvertTo-RepeatField {
    <# Splits an RRULE into the simple repeat fields of the editor. #>
    param([string]$Rule, [string]$TimeZone)
    $res = @{ Repeat = 'None'; Interval = '1'; Days = ''; Ends = ''; Custom = '' }
    if (-not $Rule) { return $res }
    $r = ConvertFrom-RRule $Rule
    $res.Custom = $Rule
    $simple = (@('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY') -contains $r.FREQ) -and @($r.Other).Count -eq 0 -and @($r.BYMONTHDAY).Count -eq 0 -and
    @($r.BYMONTH).Count -eq 0 -and @($r.BYSETPOS).Count -eq 0 -and -not ($r.COUNT -gt 0 -and $r.UNTIL)
    if ($simple -and @($r.BYDAY).Count -gt 0) {
        if ($r.FREQ -ne 'WEEKLY' -or @($r.BYDAY | Where-Object { $_.N -ne 0 }).Count -gt 0) { $simple = $false }
    }
    if (-not $simple) { $res.Repeat = 'Custom'; return $res }
    $res.Repeat = (Get-Culture).TextInfo.ToTitleCase($r.FREQ.ToLowerInvariant())
    $res.Interval = [string]$r.INTERVAL
    $codes = @($r.BYDAY | ForEach-Object { $_.Code })
    $res.Days = $codes -join ','
    if ($r.FREQ -eq 'WEEKLY' -and $r.INTERVAL -eq 1 -and ($codes | Sort-Object) -join ',' -eq 'FR,MO,TH,TU,WE') { $res.Repeat = 'Every weekday'; $res.Days = '' }
    if ($r.COUNT -gt 0) { $res.Ends = [string]$r.COUNT }
    elseif ($r.UNTIL) {
        try {
            $u = ConvertFrom-WallString $r.UNTIL
            if ($r.UNTIL -match '[Zz]$') { $u = Convert-WallTime -DateTime $u -From ([TimeZoneInfo]::Utc) -To (Get-TimeZoneById $TimeZone) }
            $res.Ends = $u.ToString('yyyy-MM-dd')
        }
        catch { $res.Repeat = 'Custom' }
    }
    return $res
}

function ConvertFrom-RepeatField {
    <# Builds an RRULE from the editor's repeat fields. Throws on invalid input. #>
    param([hashtable]$Values, [datetime]$Start, [string]$TimeZone, [bool]$AllDay)
    $repeat = [string]$Values.Repeat
    if ($repeat -eq 'None') { return '' }
    if ($repeat -eq 'Custom') {
        $rule = ([string]$Values.RepeatRule).Trim() -replace '^(?i)RRULE:', ''
        if (-not $rule) { throw 'Enter a recurrence rule, e.g. FREQ=MONTHLY;BYDAY=2TU' }
        $r = ConvertFrom-RRule $rule
        if (@('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY') -notcontains $r.FREQ) { throw 'The rule needs FREQ=DAILY, WEEKLY, MONTHLY or YEARLY.' }
        return $rule
    }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($repeat -eq 'Every weekday') { $parts.Add('FREQ=WEEKLY'); $parts.Add('BYDAY=MO,TU,WE,TH,FR') }
    else {
        $parts.Add('FREQ=' + $repeat.ToUpperInvariant())
        $interval = 1
        if (-not [int]::TryParse(([string]$Values.RepeatInterval).Trim(), [ref]$interval) -or $interval -lt 1) { throw 'Repeat every must be a whole number of 1 or more.' }
        if ($interval -gt 1) { $parts.Add('INTERVAL=' + $interval) }
        if ($repeat -eq 'Weekly') {
            $days = @(([string]$Values.RepeatDays).ToUpperInvariant() -split '[,; ]+' | Where-Object { $_ })
            foreach ($d in $days) { if ($script:DayCodeOf -notcontains $d) { throw "Unknown day '$d'. Use MO, TU, WE, TH, FR, SA, SU." } }
            if ($days.Count -gt 0) { $parts.Add('BYDAY=' + ($days -join ',')) }
        }
    }
    $ends = ([string]$Values.RepeatEnds).Trim()
    if ($ends -and $ends -ne 'never') {
        $count = 0
        if ([int]::TryParse($ends, [ref]$count)) {
            if ($count -lt 1) { throw 'The number of times must be at least 1.' }
            $parts.Add('COUNT=' + $count)
        }
        else {
            $until = ConvertFrom-UserDate $ends
            if ($null -eq $until) { throw "Ends must be blank, a number of times or a date (got '$ends')." }
            if ($until -lt $Start.Date) { throw 'The repeat end date is before the start.' }
            if ($AllDay) { $parts.Add('UNTIL=' + $until.ToString('yyyyMMdd')) }
            elseif (-not $TimeZone) { $parts.Add('UNTIL=' + (ConvertTo-WallString $until.Date.AddDays(1).AddSeconds(-1))) }
            else {
                $utc = Convert-WallTime -DateTime $until.Date.AddDays(1).AddSeconds(-1) -From (Get-TimeZoneById $TimeZone) -To ([TimeZoneInfo]::Utc)
                $parts.Add('UNTIL=' + (ConvertTo-WallString $utc) + 'Z')
            }
        }
    }
    return ($parts -join ';')
}

function ConvertFrom-ReminderText {
    <# Parses "10, 1h, 1d" (and "default") into minutes. #>
    param([string]$Text)
    $res = @{ Minutes = @(); Default = $false }
    foreach ($tok in (([string]$Text) -split '[,; ]+')) {
        $t = $tok.Trim().ToLowerInvariant()
        if (-not $t) { continue }
        if ($t -eq 'default') { $res.Default = $true; continue }
        if ($t -notmatch '^(\d+)\s*(m|min|mins|minutes?|h|hrs?|hours?|d|days?|w|weeks?)?$') { throw "Unknown reminder '$tok'. Use minutes (15), hours (2h) or days (1d)." }
        $n = [int]$Matches[1]
        $unit = [string]$Matches[2]
        if ($unit.StartsWith('h')) { $n *= 60 } elseif ($unit.StartsWith('d')) { $n *= 1440 } elseif ($unit.StartsWith('w')) { $n *= 10080 }
        if ($res.Minutes -notcontains $n) { $res.Minutes += $n }
    }
    return $res
}

function Format-ReminderText {
    <# Formats reminder minutes for the editor. #>
    param([int[]]$Minutes, [bool]$UseDefault)
    $parts = @()
    if ($UseDefault) { $parts += 'default' }
    foreach ($m in $Minutes) {
        if ($m -gt 0 -and $m % 10080 -eq 0) { $parts += ('{0}w' -f ($m / 10080)) }
        elseif ($m -gt 0 -and $m % 1440 -eq 0) { $parts += ('{0}d' -f ($m / 1440)) }
        elseif ($m -gt 0 -and $m % 60 -eq 0) { $parts += ('{0}h' -f ($m / 60)) }
        else { $parts += [string]$m }
    }
    return ($parts -join ', ')
}

function Format-ReminderHuman {
    <# "15 min, 1 hour before" for the details panel. #>
    param([int]$Minutes)
    if ($Minutes -eq 0) { return 'at start' }
    if ($Minutes % 1440 -eq 0) { return ('{0} day(s) before' -f ($Minutes / 1440)) }
    if ($Minutes % 60 -eq 0) { return ('{0} hour(s) before' -f ($Minutes / 60)) }
    return ('{0} min before' -f $Minutes)
}

function ConvertFrom-AttendeeText {
    <# Parses "Name <a@b.c>, ?optional@x.y" into attendees, keeping known response states. #>
    param([string]$Text, [object[]]$Existing)
    $known = @{}
    foreach ($a in $Existing) { $known[$a.Email.ToLowerInvariant()] = $a }
    foreach ($tok in (([string]$Text) -split '[,;]')) {
        $t = $tok.Trim()
        if (-not $t) { continue }
        $optional = $t.StartsWith('?')
        $t = $t.TrimStart('?').Trim()
        $name = ''
        $email = $t
        if ($t -match '^(.*?)<([^>]+)>$') { $name = $Matches[1].Trim().Trim('"'); $email = $Matches[2].Trim() }
        $email = $email -replace '^(?i)mailto:', ''
        if ($email -notmatch '^[^@\s]+@[^@\s]+$') { throw "'$email' is not an e-mail address." }
        $role = 'REQ-PARTICIPANT'
        if ($optional) { $role = 'OPT-PARTICIPANT' }
        $status = 'NEEDS-ACTION'
        $prev = $known[$email.ToLowerInvariant()]
        if ($null -ne $prev) { $status = $prev.Status; if (-not $name) { $name = $prev.Name } }
        New-Attendee -Email $email -Name $name -Role $role -Status $status
    }
}

function Format-AttendeeText {
    <# Formats attendees for the editor. #>
    param([object[]]$Attendees)
    $parts = foreach ($a in $Attendees) {
        $p = $a.Email
        if ($a.Name) { $p = '{0} <{1}>' -f $a.Name, $a.Email }
        if ($a.Role -eq 'OPT-PARTICIPANT') { $p = '?' + $p }
        $p
    }
    return (@($parts) -join ', ')
}

function Edit-CalEvent {
    <# Opens the event form for a new (Event = $null) or existing event. Returns the saved event or $null. #>
    param($Event = $null, [datetime]$DefaultStart = (Get-Date), [bool]$AllDayDefault = $false, [datetime]$OccurrenceStart = [datetime]::MinValue)
    $settings = $script:Config.Settings
    $writable = @($script:Config.Calendars | Where-Object { -not $_.ReadOnly })
    if ($writable.Count -eq 0) { Show-TuiMessage -Title 'No calendar' -Message 'There is no calendar you can write to.' -IsError; return $null }
    $labels = @($writable | ForEach-Object { Get-CalendarLabel $_ })
    for ($i = 0; $i -lt $labels.Count; $i++) { if (@($labels | Where-Object { $_ -eq $labels[$i] }).Count -gt 1) { $labels[$i] += ' #' + ($i + 1) } }
    $googleLabels = @(for ($i = 0; $i -lt $writable.Count; $i++) { if (Test-CalendarIsGoogle $writable[$i]) { $labels[$i] } })
    $isNew = ($null -eq $Event)
    $timeFmt = 'HH:mm'
    if ($settings.TimeFormat -eq '12h') { $timeFmt = 'h:mmtt' }

    if ($isNew) {
        $cal = Get-Calendar $settings.DefaultCalendarId
        if ($null -eq $cal -or $cal.ReadOnly) { $cal = $writable[0] }
        $calLabel = $labels[[Array]::IndexOf($writable, $cal)]
        $start = $DefaultStart
        $end = $start.AddMinutes([int]$settings.DefaultDuration)
        $allDay = $AllDayDefault
        if ($allDay) { $start = $start.Date; $end = $start }
        $tz = Get-LocalIanaTimeZone
        $ev = New-CalEvent -CalendarId $cal.Id
        $reminders = ConvertFrom-ReminderText ([string]$settings.DefaultReminder)
        if (-not $allDay) { $ev.Reminders = [int[]]$reminders.Minutes }
        if (Test-CalendarIsGoogle $cal) { $ev.RemindersDefault = $true; $ev.Reminders = [int[]]@() }
    }
    else {
        $ev = $Event
        $cal = Get-Calendar $ev.CalendarId
        $ci = [Array]::IndexOf($writable, $cal)
        if ($ci -lt 0) { Show-TuiMessage -Title 'Read only' -Message 'This calendar is read only.' -IsError; return $null }
        $calLabel = $labels[$ci]
        $start = ConvertFrom-WallString $ev.Start
        $end = ConvertFrom-WallString $ev.End
        $allDay = $ev.AllDay
        if ($allDay) { $end = $end.AddDays(-1); if ($end -lt $start) { $end = $start } }
        $tz = $ev.TimeZone
    }
    $rep = ConvertTo-RepeatField -Rule $ev.RRule -TimeZone $ev.TimeZone
    $statusOpts = @('Confirmed', 'Tentative', 'Cancelled')
    $visOpts = @('Default', 'Public', 'Private', 'Confidential')
    $colorOpts = @($script:GoogleColorNames.Values)
    $ti = (Get-Culture).TextInfo
    $statusVal = $ti.ToTitleCase(([string]$ev.Status).ToLowerInvariant()); if ($statusOpts -notcontains $statusVal) { $statusVal = 'Confirmed' }
    $visVal = 'Default'; if ($ev.Visibility) { $visVal = $ti.ToTitleCase($ev.Visibility.ToLowerInvariant()) }; if ($visOpts -notcontains $visVal) { $visVal = 'Default' }
    $colorVal = $script:GoogleColorNames[$ev.ColorId]; if (-not $colorVal) { $colorVal = $colorOpts[0] }
    $showAs = 'Busy'; if ($ev.Transparency -eq 'TRANSPARENT') { $showAs = 'Free' }

    $notAllDay = { param($v) -not $v.AllDay }
    $fields = @(
        New-FormField -Key 'Summary' -Label 'Title' -Value $ev.Summary
        New-FormField -Key 'Calendar' -Label 'Calendar' -Type 'choice' -Value $calLabel -Options $labels
        New-FormField -Key 'AllDay' -Label 'All day' -Type 'bool' -Value ([bool]$allDay)
        New-FormField -Key 'StartDate' -Label 'Start date' -Value $start.ToString('yyyy-MM-dd') -Hint 'YYYY-MM-DD, today, tomorrow, a weekday name or +3d / +1w'
        New-FormField -Key 'StartTime' -Label 'Start time' -Value $start.ToString($timeFmt, $script:Inv).ToLowerInvariant() -Hint 'e.g. 9:30, 14:00, 2pm' -When $notAllDay
        New-FormField -Key 'EndDate' -Label 'End date' -Value $end.ToString('yyyy-MM-dd') -Hint 'Last day of the event (YYYY-MM-DD, +1d ...)'
        New-FormField -Key 'EndTime' -Label 'End time' -Value $end.ToString($timeFmt, $script:Inv).ToLowerInvariant() -Hint 'e.g. 10:30, 15:00, 3pm' -When $notAllDay
        New-FormField -Key 'TimeZone' -Label 'Time zone' -Value $tz -Hint 'IANA name such as America/New_York or Europe/London. Blank = floating local time.' -When $notAllDay
        New-FormField -Key 'Repeat' -Label 'Repeat' -Type 'choice' -Value $rep.Repeat -Options $script:RepeatOptions
        New-FormField -Key 'RepeatInterval' -Label 'Repeat every' -Value $rep.Interval -Hint 'Number of days / weeks / months / years between occurrences' -When { param($v) @('Daily', 'Weekly', 'Monthly', 'Yearly') -contains $v.Repeat }
        New-FormField -Key 'RepeatDays' -Label 'On days' -Value $rep.Days -Hint 'Comma separated: MO,TU,WE,TH,FR,SA,SU (blank = same weekday as the start)' -When { param($v) $v.Repeat -eq 'Weekly' }
        New-FormField -Key 'RepeatEnds' -Label 'Ends' -Value $rep.Ends -Hint 'Blank = never, a number = after that many times, a date = on that date' -When { param($v) @('None', 'Custom') -notcontains $v.Repeat }
        New-FormField -Key 'RepeatRule' -Label 'Rule (RRULE)' -Value $rep.Custom -Hint 'RFC 5545 rule, e.g. FREQ=MONTHLY;BYDAY=-1FR;COUNT=12' -When { param($v) $v.Repeat -eq 'Custom' }
        New-FormField -Key 'Location' -Label 'Location' -Value $ev.Location
        New-FormField -Key 'Url' -Label 'URL' -Value $ev.Url
        New-FormField -Key 'Description' -Label 'Notes' -Value ($ev.Description.Replace("`r`n", "`n").Replace("`n", '\n')) -Hint 'Type \n for a new line'
        New-FormField -Key 'Status' -Label 'Status' -Type 'choice' -Value $statusVal -Options $statusOpts -Hint 'For Google calendars "Cancelled" removes the event'
        New-FormField -Key 'ShowAs' -Label 'Show as' -Type 'choice' -Value $showAs -Options @('Busy', 'Free')
        New-FormField -Key 'Visibility' -Label 'Visibility' -Type 'choice' -Value $visVal -Options $visOpts
        New-FormField -Key 'Color' -Label 'Event colour' -Type 'choice' -Value $colorVal -Options $colorOpts -Data $googleLabels -When { param($v, $f) $f.Data -contains $v.Calendar }
        New-FormField -Key 'Reminders' -Label 'Reminders' -Value (Format-ReminderText -Minutes $ev.Reminders -UseDefault $ev.RemindersDefault) -Hint 'Before the start: 10, 1h, 1d. Google: "default" uses the calendar default.'
        New-FormField -Key 'Attendees' -Label 'Attendees' -Value (Format-AttendeeText @($ev.Attendees)) -Hint 'Comma separated: Name <mail@example.com>, ?optional@example.com'
    )
    if (-not $isNew -and $ev.OrganizerEmail) {
        $orgText = $ev.OrganizerEmail
        if ($ev.OrganizerName) { $orgText = '{0} <{1}>' -f $ev.OrganizerName, $ev.OrganizerEmail }
        $fields += New-FormField -Key 'Organizer' -Label 'Organizer' -Type 'readonly' -Value $orgText
    }

    $validate = {
        param($v)
        $sd = ConvertFrom-UserDate $v.StartDate
        if ($null -eq $sd) { return 'The start date is not valid.' }
        $ed = ConvertFrom-UserDate $v.EndDate $sd
        if ($null -eq $ed) { return 'The end date is not valid.' }
        if (-not $v.AllDay) {
            $st = ConvertFrom-UserTime $v.StartTime
            if ($null -eq $st) { return 'The start time is not valid.' }
            $et = ConvertFrom-UserTime $v.EndTime
            if ($null -eq $et) { return 'The end time is not valid.' }
            if (($ed + $et) -lt ($sd + $st)) { return 'The event ends before it starts.' }
            if (-not (Test-TimeZoneId $v.TimeZone)) { return ("Unknown time zone '{0}'." -f $v.TimeZone) }
        }
        elseif ($ed -lt $sd) { return 'The event ends before it starts.' }
        try { $null = ConvertFrom-RepeatField -Values $v -Start $sd -TimeZone ([string]$v.TimeZone).Trim() -AllDay ([bool]$v.AllDay) } catch { return $_.Exception.Message }
        try { $null = ConvertFrom-ReminderText $v.Reminders } catch { return $_.Exception.Message }
        try { $null = @(ConvertFrom-AttendeeText $v.Attendees @()) } catch { return $_.Exception.Message }
        if ($v.Url -and $v.Url -notmatch '^[A-Za-z][A-Za-z0-9+.-]*:') { return 'The URL must start with http:// or https://' }
        return $null
    }
    # When the start changes, move the end so the event keeps the default
    # length. The user can still set a custom end afterwards.
    $evDuration = [int]$settings.DefaultDuration
    $evTimeFmt = $timeFmt
    $onChange = {
        param($v, $key)
        if ($key -ne 'StartDate' -and $key -ne 'StartTime') { return }
        $sd = ConvertFrom-UserDate $v.StartDate
        if ($null -eq $sd) { return }
        if ($v.AllDay) { $v.EndDate = $sd.ToString('yyyy-MM-dd'); return }
        $st = ConvertFrom-UserTime $v.StartTime
        if ($null -eq $st) { return }
        $newEnd = ($sd + $st).AddMinutes($evDuration)
        $v.EndDate = $newEnd.ToString('yyyy-MM-dd')
        $v.EndTime = $newEnd.ToString($evTimeFmt, $script:Inv).ToLowerInvariant()
    }
    $formTitle = 'New event'
    if (-not $isNew) {
        $formTitle = 'Edit event'
        if ($ev.RRule -and -not $ev.RecurrenceId) { $formTitle = 'Edit recurring event (all occurrences)' }
        elseif ($ev.RecurrenceId) { $formTitle = 'Edit this occurrence' }
    }
    $v = Invoke-TuiForm -Title $formTitle -Fields $fields -Validate $validate -OnChange $onChange
    if ($null -eq $v) { return $null }

    # Apply the form values.
    $targetCal = $writable[[Array]::IndexOf($labels, [string]$v.Calendar)]
    $sd = ConvertFrom-UserDate $v.StartDate
    $ed = ConvertFrom-UserDate $v.EndDate $sd
    $isAllDay = [bool]$v.AllDay
    $tzOut = ''
    if ($isAllDay) { $startDt = $sd; $endDt = $ed.AddDays(1) }
    else {
        $startDt = $sd + (ConvertFrom-UserTime $v.StartTime)
        $endDt = $ed + (ConvertFrom-UserTime $v.EndTime)
        $tzOut = ([string]$v.TimeZone).Trim()
    }
    if (-not $isNew -and $targetCal.Id -ne $ev.CalendarId) {
        # Moving to another calendar: delete from the old one, create in the new one.
        $copy = Copy-CalEvent $ev
        $copy.Id = New-Id
        $copy.RemoteId = ''; $copy.Href = ''; $copy.ETag = ''; $copy.MasterId = ''; $copy.RecurrenceId = ''
        $copy.CalendarId = $targetCal.Id
        Remove-CalEventSeries $ev
        $ev = $copy
        $isNew = $true
    }
    if ($isNew) {
        $ev.CalendarId = $targetCal.Id
        if (-not $ev.Uid) { $ev.Uid = (New-Id) + '@pscalendar' }
    }
    $oldLocation = $ev.Location
    $ev.Summary = ([string]$v.Summary).Trim()
    $ev.AllDay = $isAllDay
    $ev.TimeZone = $tzOut
    $ev.Start = ConvertTo-WallString $startDt $isAllDay
    $ev.End = ConvertTo-WallString $endDt $isAllDay
    if (-not $ev.RecurrenceId) { $ev.RRule = ConvertFrom-RepeatField -Values $v -Start $sd -TimeZone $tzOut -AllDay $isAllDay }
    if (-not $ev.RRule) { $ev.ExDates = [string[]]@() }
    $ev.Location = ([string]$v.Location).Trim()
    if ($ev.Location -ne $oldLocation) { $ev.ExtraProps = [string[]]@($ev.ExtraProps | Where-Object { $_ -notmatch '^(?i)X-APPLE-STRUCTURED-LOCATION' }) }
    $ev.Url = ([string]$v.Url).Trim()
    $ev.Description = ([string]$v.Description).Replace('\n', "`n")
    $ev.Status = ([string]$v.Status).ToUpperInvariant()
    $ev.Transparency = 'OPAQUE'
    if ($v.ShowAs -eq 'Free') { $ev.Transparency = 'TRANSPARENT' }
    $ev.Visibility = ''
    if ($v.Visibility -ne 'Default') { $ev.Visibility = ([string]$v.Visibility).ToUpperInvariant() }
    $ev.ColorId = ''
    if (Test-CalendarIsGoogle $targetCal) {
        foreach ($k in $script:GoogleColorNames.Keys) { if ($script:GoogleColorNames[$k] -eq $v.Color) { $ev.ColorId = $k } }
    }
    $rem = ConvertFrom-ReminderText $v.Reminders
    $ev.Reminders = [int[]]@($rem.Minutes)
    $ev.RemindersDefault = ($rem.Default -and (Test-CalendarIsGoogle $targetCal))
    $ev.Attendees = @(ConvertFrom-AttendeeText $v.Attendees @($ev.Attendees))
    if (@($ev.Attendees).Count -gt 0 -and -not $ev.OrganizerEmail) {
        $acc = Get-Account $targetCal.AccountId
        if ($null -ne $acc -and $acc.Username -match '@') { $ev.OrganizerEmail = $acc.Username }
    }
    if (-not $isNew) { $ev.Sequence++ }
    $ev.Modified = Get-UtcStamp
    $ev.Dirty = -not (Test-CalendarIsLocal $targetCal)
    $ev.Deleted = $false
    if (-not $script:Events.Contains($ev)) { $script:Events.Add($ev) }
    # Keep changed occurrences of a CalDAV series in the same resource.
    if ($ev.RRule -and $ev.Dirty) {
        foreach ($o in @($script:Events | Where-Object { $_.CalendarId -eq $ev.CalendarId -and $_.Uid -eq $ev.Uid -and $_.RecurrenceId })) { $o.Dirty = $true }
    }
    Save-EventStore
    return $ev
}

function Get-SeriesMember {
    <# The master and all changed occurrences that share an event's UID. #>
    param($Event)
    return @($script:Events | Where-Object { $_.CalendarId -eq $Event.CalendarId -and $_.Uid -eq $Event.Uid })
}

function Remove-CalEventSeries {
    <# Deletes an event (and its whole series) locally or marks it for deletion on the server. #>
    param($Event)
    $members = @($Event)
    if ($Event.Uid) { $members = Get-SeriesMember $Event }
    $cal = Get-Calendar $Event.CalendarId
    if (Test-CalendarIsLocal $cal) { Remove-StoredEvent $members }
    else {
        foreach ($m in $members) {
            if (-not $m.Href -and -not $m.RemoteId) { Remove-StoredEvent @($m) }
            else { $m.Deleted = $true; $m.Dirty = $true }
        }
    }
    $script:DataVersion++
}

function Remove-CalEventOccurrence {
    <# Deletes a single occurrence of a recurring event (adds an EXDATE). #>
    param($Instance)
    $ev = $Instance.Event
    $master = $ev
    if ($ev.RecurrenceId) {
        $master = @(Get-SeriesMember $ev | Where-Object { -not $_.RecurrenceId -and $_.RRule }) | Select-Object -First 1
        $occWall = $ev.RecurrenceId
        $cal = Get-Calendar $ev.CalendarId
        if (Test-CalendarIsLocal $cal) { Remove-StoredEvent @($ev) } else { $ev.Deleted = $true; $ev.Dirty = $true }
        if ($null -eq $master) { $script:DataVersion++; return }
    }
    else { $occWall = ConvertTo-WallString $Instance.Occurrence $master.AllDay }
    if (@($master.ExDates) -notcontains $occWall) { $master.ExDates = [string[]](@($master.ExDates) + $occWall) }
    $master.Sequence++
    $master.Modified = Get-UtcStamp
    $master.Dirty = -not (Test-CalendarIsLocal (Get-Calendar $master.CalendarId))
    $script:DataVersion++
}

function Remove-CalEventInteractive {
    <# Asks how to delete the selected occurrence and does it. #>
    param($Instance)
    $ev = $Instance.Event
    $cal = Get-Calendar $ev.CalendarId
    if ($cal.ReadOnly) { Show-TuiMessage -Title 'Read only' -Message 'This calendar is read only.' -IsError; return }
    $title = Get-InstanceTitle $Instance
    $isSeries = [bool]$ev.RRule -or [bool]$ev.RecurrenceId
    if ($isSeries) {
        $c = Read-TuiChoice -Title 'Delete recurring event' -Options @('Only this occurrence', 'All occurrences', 'Cancel') -Message ("'{0}' on {1}" -f $title, $Instance.Start.ToString('D'))
        if ($c -eq 0) { Remove-CalEventOccurrence $Instance }
        elseif ($c -eq 1) { Remove-CalEventSeries $ev }
        else { return }
    }
    else {
        if (-not (Read-TuiConfirm -Title 'Delete event' -Message ("Delete '{0}'?" -f $title))) { return }
        Remove-CalEventSeries $ev
    }
    Save-EventStore
    $script:State.Message = "Deleted '$title'."
}

function Get-EventDetailLine {
    <# Lines describing an occurrence for the details panel and popup. #>
    param($Instance, [int]$Width = 60)
    $ev = $Instance.Event
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in (Format-WrapText (Get-InstanceTitle $Instance) $Width)) { $out.Add(@{ T = $l; F = 'White' }) }
    $out.Add('')
    $when = $Instance.Start.ToString('dddd, MMMM d yyyy')
    if ($Instance.AllDay) {
        $last = $Instance.End.AddDays(-1)
        if ($last -gt $Instance.Start) { $when += ' - ' + $last.ToString('dddd, MMMM d yyyy') }
        $when += ' (all day)'
    }
    else { $when += '  ' + (Format-InstanceWhen $Instance) }
    foreach ($l in (Format-WrapText $when $Width)) { $out.Add(@{ T = $l; F = 'Cyan' }) }
    if ($ev.RRule) { $out.Add(@{ T = 'Repeats: ' + (Format-RRuleText $ev.RRule); F = 'Gray' }) }
    if ($ev.RecurrenceId) { $out.Add(@{ T = 'Changed occurrence of a recurring event'; F = 'Gray' }) }
    if (-not $ev.AllDay -and $ev.TimeZone -and $ev.TimeZone -ne (Get-LocalIanaTimeZone)) { $out.Add('Time zone: ' + $ev.TimeZone) }
    $out.Add(@{ T = 'Calendar: ' + (Get-CalendarLabel $Instance.Calendar); F = $Instance.Color })
    if ($ev.Location) { foreach ($l in (Format-WrapText ('Location: ' + $ev.Location) $Width)) { $out.Add($l) } }
    if ($ev.Url) { foreach ($l in (Format-WrapText ('URL: ' + $ev.Url) $Width)) { $out.Add($l) } }
    $showAs = 'Busy'
    if ($ev.Transparency -eq 'TRANSPARENT') { $showAs = 'Free' }
    $extra = 'Show as: ' + $showAs
    if ($ev.Status -and $ev.Status -ne 'CONFIRMED') { $extra += '   Status: ' + $ev.Status.ToLowerInvariant() }
    if ($ev.Visibility) { $extra += '   Visibility: ' + $ev.Visibility.ToLowerInvariant() }
    $out.Add($extra)
    $rem = @($ev.Reminders | ForEach-Object { Format-ReminderHuman $_ })
    if ($ev.RemindersDefault) { $rem = @('calendar default') + $rem }
    if ($rem.Count) { $out.Add('Reminders: ' + ($rem -join ', ')) }
    if ($ev.OrganizerEmail) {
        $o = $ev.OrganizerEmail
        if ($ev.OrganizerName) { $o = '{0} <{1}>' -f $ev.OrganizerName, $ev.OrganizerEmail }
        $out.Add('Organizer: ' + $o)
    }
    if (@($ev.Attendees).Count) {
        $out.Add(('Attendees ({0}):' -f @($ev.Attendees).Count))
        foreach ($a in $ev.Attendees) {
            $n = $a.Email
            if ($a.Name) { $n = '{0} <{1}>' -f $a.Name, $a.Email }
            $st = $a.Status.ToLowerInvariant()
            if ($a.Role -eq 'OPT-PARTICIPANT') { $st += ', optional' }
            $color = 'Gray'
            if ($a.Status -eq 'ACCEPTED') { $color = 'Green' } elseif ($a.Status -eq 'DECLINED') { $color = 'Red' } elseif ($a.Status -eq 'TENTATIVE') { $color = 'Yellow' }
            foreach ($l in (Format-WrapText ('  ' + $n + ' (' + $st + ')') $Width)) { $out.Add(@{ T = $l; F = $color }) }
        }
    }
    if ($ev.Description) {
        $out.Add('')
        foreach ($l in (Format-WrapText $ev.Description $Width)) { $out.Add($l) }
    }
    if ($ev.Dirty) { $out.Add(''); $out.Add(@{ T = 'Not uploaded yet - press S to sync.'; F = 'Yellow' }) }
    return $out.ToArray()
}

#endregion

#region ------------------------------------------------------------ Accounts, calendars and options

$script:ICloudHelp = 'iCloud needs an app-specific password. Sign in at https://account.apple.com, open Sign-In and Security > App-Specific Passwords, create one and enter it below together with your Apple Account e-mail address.'

$script:GoogleHelp = @'
PSCalendar talks to Google with an OAuth client that you create once (free):

 1. Open https://console.cloud.google.com and create or pick a project.
 2. APIs & Services > Library: enable the "Google Calendar API".
 3. APIs & Services > OAuth consent screen (Google Auth Platform): choose
    "External", enter an app name and your e-mail, and add your Google
    address as a test user. Publishing the app ("In production") stops
    Google from expiring the sign-in after 7 days.
 4. Credentials > Create credentials > OAuth client ID > "Desktop app".
 5. Copy the client ID and client secret into the next screen.

A browser window then opens so you can sign in and allow access. The
secret and the sign-in token are stored encrypted for your Windows user.
'@

function Select-RemoteCalendar {
    <# Lets the user choose which server calendars to sync and updates the local list. #>
    param($Account, [object[]]$Remote)
    if ($Remote.Count -eq 0) { Show-TuiMessage -Title $Account.Name -Message 'The account has no event calendars.'; return }
    $existing = @{}
    foreach ($c in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $Account.Id })) { $existing[$c.RemoteId] = $c }
    $names = @(foreach ($r in $Remote) { $n = $r.Name; if ($r.ReadOnly) { $n += '  (read only)' }; $n })
    $checked = [bool[]]@(foreach ($r in $Remote) { if ($existing.ContainsKey($r.Url)) { $true } else { -not $r.ReadOnly } })
    $res = Read-TuiMultiChoice -Title ('Calendars of ' + $Account.Name) -Options $names -Checked $checked -Message 'Tick the calendars to show and synchronise.'
    if ($null -eq $res) { if ($existing.Count -eq 0) { $res = $checked } else { return } }
    $palette = 0
    for ($i = 0; $i -lt $Remote.Count; $i++) {
        $r = $Remote[$i]
        $cal = $existing[$r.Url]
        if ($res[$i]) {
            if ($null -eq $cal) {
                $color = $script:CalendarPalette[($script:Config.Calendars.Count + $palette) % $script:CalendarPalette.Count]
                if ($r.Color) { $color = ConvertTo-ConsoleColorName $r.Color }
                $palette++
                $cal = New-CalendarObject -AccountId $Account.Id -Name $r.Name -RemoteId $r.Url -Color $color
                $script:Config.Calendars.Add($cal)
            }
            $cal.Name = $r.Name
            $cal.ReadOnly = [bool]$r.ReadOnly
            $cal.TimeZone = [string]$r.TimeZone
        }
        elseif ($null -ne $cal) { Remove-LocalCalendar $cal }
    }
    # Calendars that disappeared from the server.
    $urls = @($Remote | ForEach-Object { $_.Url })
    foreach ($c in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $Account.Id -and $urls -notcontains $_.RemoteId })) { Remove-LocalCalendar $c }
    Save-Config
    Save-EventStore
}

function Remove-LocalCalendar {
    <# Removes a calendar and its events from PSCalendar (never from the server). #>
    param($Calendar)
    Remove-StoredEvent @($script:Events | Where-Object { $_.CalendarId -eq $Calendar.Id })
    [void]$script:Config.Calendars.Remove($Calendar)
    if ($Calendar.Id -eq $script:HolidayCalendarId) { $script:Config.Settings.Holidays = 'Off' }
    $acc = Get-Account $Calendar.AccountId
    if ($null -ne $acc -and $acc.Type -eq 'Subscription' -and -not @($script:Config.Calendars | Where-Object { $_.AccountId -eq $acc.Id })) {
        [void]$script:Config.Accounts.Remove($acc)
    }
    if ($script:Config.Settings.DefaultCalendarId -eq $Calendar.Id) {
        $first = @($script:Config.Calendars | Where-Object { -not $_.ReadOnly }) | Select-Object -First 1
        if ($null -ne $first) { $script:Config.Settings.DefaultCalendarId = $first.Id }
    }
}

function Find-AccountCalendar {
    <# Lists the calendars on the server for any account type. #>
    param($Account)
    if ($Account.Type -eq 'Google') { return @(Find-GoogleCalendar $Account) }
    return @(Find-CalDavCalendar $Account)
}

function Update-AccountCalendar {
    <# Re-reads the calendar list from the server and lets the user pick again. #>
    param($Account)
    Show-TuiBusy -Title $Account.Name -Message 'Reading the calendar list...'
    try { $remote = @(Find-AccountCalendar $Account) }
    catch { Show-TuiMessage -Title 'Connection failed' -Message $_.Exception.Message -IsError; return }
    Select-RemoteCalendar -Account $Account -Remote $remote
}

function Connect-GoogleAccount {
    <# Runs the Google sign-in for an account and stores the refresh token. #>
    param($Account)
    $snap = Save-ScreenBuffer
    $onUrl = {
        param($url)
        try { Set-Clipboard -Value $url } catch { Write-Verbose 'Clipboard not available.' }
        Restore-ScreenBuffer $snap
        Show-TuiBusy -Title 'Google sign-in' -Message ("A browser window was opened. Sign in and allow access to your calendars; PSCalendar continues automatically. If no browser opened, paste the link from the clipboard into one: $url   (Esc cancels)")
    }
    $tokens = Request-GoogleAuthorization -ClientId $Account.ClientId -ClientSecret (Unprotect-Secret $Account.ClientSecret) -OnUrl $onUrl
    $Account.RefreshToken = Protect-Secret ([string]$tokens.refresh_token)
    $script:TokenCache[$Account.Id] = @{ Token = [string]$tokens.access_token; Expires = (Get-Date).AddSeconds([int]$tokens.expires_in) }
    Restore-ScreenBuffer $snap
}

function Add-AccountInteractive {
    <# Guides the user through adding an iCloud, Google, CalDAV, subscribed or local calendar. #>
    $c = Read-TuiChoice -Title 'Add calendars' -Options @('iCloud Calendar', 'Google Calendar', 'Other CalDAV server (Nextcloud, Fastmail, ...)',
        'Subscribe to a calendar address (.ics, webcal://)', 'Local calendar (not synchronised)')
    if ($c -lt 0) { return }
    if ($c -eq 3) { Add-SubscriptionInteractive; return }
    if ($c -eq 4) { New-LocalCalendarInteractive; return }
    $acc = $null
    if ($c -eq 0 -or $c -eq 2) {
        $isICloud = ($c -eq 0)
        $fields = @(New-FormField -Key 'Name' -Label 'Account name' -Value $(if ($isICloud) { 'iCloud' } else { 'CalDAV' }))
        if (-not $isICloud) { $fields += New-FormField -Key 'ServerUrl' -Label 'Server URL' -Value 'https://' -Hint 'e.g. https://cloud.example.com/remote.php/dav' }
        $fields += New-FormField -Key 'Username' -Label 'User name' -Hint $(if ($isICloud) { 'Your Apple Account e-mail address' } else { 'Your user name on the server' })
        $fields += New-FormField -Key 'Password' -Label 'Password' -Type 'password' -Hint $(if ($isICloud) { 'App-specific password (xxxx-xxxx-xxxx-xxxx)' } else { 'Password or app password' })
        $intro = ''
        if ($isICloud) { $intro = $script:ICloudHelp }
        $v = Invoke-TuiForm -Title $(if ($isICloud) { 'Add iCloud account' } else { 'Add CalDAV account' }) -Fields $fields -Intro $intro -Validate {
            param($v)
            if (-not $v.Username) { return 'Enter the user name.' }
            if (-not $v.Password) { return 'Enter the password.' }
            if ($v.ContainsKey('ServerUrl') -and $v.ServerUrl -notmatch '^https?://.+') { return 'Enter the server URL (https://...).' }
            return $null
        }
        if ($null -eq $v) { return }
        $acc = New-AccountObject -Type $(if ($isICloud) { 'iCloud' } else { 'CalDAV' }) -Name ([string]$v.Name).Trim()
        $acc.Username = ([string]$v.Username).Trim()
        $acc.Secret = Protect-Secret ([string]$v.Password).Trim()
        $acc.ServerUrl = $script:ICloudUrl
        if (-not $isICloud) { $acc.ServerUrl = ([string]$v.ServerUrl).Trim() }
        if (-not $acc.Name) { $acc.Name = $acc.Username }
    }
    else {
        Show-TuiText -Title 'Google Calendar set-up' -Lines @(($script:GoogleHelp -split "`r?`n")) -Width 80
        $fields = @(
            New-FormField -Key 'Name' -Label 'Account name' -Value 'Google'
            New-FormField -Key 'ClientId' -Label 'Client ID' -Hint 'Ends with .apps.googleusercontent.com'
            New-FormField -Key 'ClientSecret' -Label 'Client secret' -Type 'password'
        )
        $v = Invoke-TuiForm -Title 'Add Google account' -Fields $fields -Validate {
            param($v)
            if (-not $v.ClientId) { return 'Enter the client ID.' }
            if (-not $v.ClientSecret) { return 'Enter the client secret.' }
            return $null
        }
        if ($null -eq $v) { return }
        $acc = New-AccountObject -Type 'Google' -Name ([string]$v.Name).Trim()
        if (-not $acc.Name) { $acc.Name = 'Google' }
        $acc.ClientId = ([string]$v.ClientId).Trim()
        $acc.ClientSecret = Protect-Secret ([string]$v.ClientSecret).Trim()
        try { Connect-GoogleAccount $acc }
        catch { Show-TuiMessage -Title 'Google sign-in failed' -Message $_.Exception.Message -IsError; return }
    }
    Show-TuiBusy -Title $acc.Name -Message 'Connecting and reading the calendar list...'
    try { $remote = @(Find-AccountCalendar $acc) }
    catch { Show-TuiMessage -Title 'Connection failed' -Message $_.Exception.Message -IsError; return }
    $script:Config.Accounts.Add($acc)
    Select-RemoteCalendar -Account $acc -Remote $remote
    Save-Config
    if (Read-TuiConfirm -Title $acc.Name -Message 'Account added. Synchronise it now?') { Invoke-SyncInteractive -AccountId $acc.Id }
}

function Add-SubscriptionInteractive {
    <# Subscribes to a read-only calendar published as an .ics / webcal:// address. #>
    $fields = @(
        New-FormField -Key 'Url' -Label 'Calendar address' -Value 'https://' -Hint 'An .ics or webcal:// link, e.g. a team, school or sports calendar'
        New-FormField -Key 'Name' -Label 'Name' -Hint 'Leave blank to use the name the calendar gives itself'
    )
    $intro = 'Subscribed calendars are read only. PSCalendar downloads them again once a day (or as often as the calendar asks) and when you press S.'
    $v = Invoke-TuiForm -Title 'Subscribe to a calendar' -Fields $fields -Intro $intro -Validate {
        param($v)
        if (([string]$v.Url).Trim() -notmatch '^(?i)(https?|webcals?)://.+') { return 'Enter the address (https://... or webcal://...).' }
        return $null
    }
    if ($null -eq $v) { return }
    $url = ([string]$v.Url).Trim()
    Show-TuiBusy -Title 'Subscribe' -Message 'Downloading the calendar...'
    try { $feed = Get-SubscriptionFeed -Url $url }
    catch { Show-TuiMessage -Title 'Subscription failed' -Message $_.Exception.Message -IsError; return }
    $name = ([string]$v.Name).Trim()
    if (-not $name) { $name = $feed.Name }
    if (-not $name) { $name = ([Uri](ConvertTo-FeedUrl $url)).Host }
    $acc = New-AccountObject -Type 'Subscription' -Name $name
    $acc.ServerUrl = $url
    $color = $script:CalendarPalette[$script:Config.Calendars.Count % $script:CalendarPalette.Count]
    $cal = New-CalendarObject -AccountId $acc.Id -Name $name -RemoteId $url -Color $color
    $cal.ReadOnly = $true
    $script:Config.Accounts.Add($acc)
    $script:Config.Calendars.Add($cal)
    Save-Config
    Invoke-SyncInteractive -AccountId $acc.Id -Force
}

function New-LocalCalendarInteractive {
    <# Creates a calendar that only exists on this computer. #>
    $name = Read-TuiInput -Title 'New local calendar' -Prompt 'Name of the calendar:'
    if (-not $name) { return }
    $local = @($script:Config.Accounts | Where-Object { $_.Type -eq 'Local' })[0]
    $color = $script:CalendarPalette[$script:Config.Calendars.Count % $script:CalendarPalette.Count]
    $cal = New-CalendarObject -AccountId $local.Id -Name $name.Trim() -Color $color
    $cal.Sync = $false
    $script:Config.Calendars.Add($cal)
    Save-Config
}

function Edit-CalendarSetting {
    <# Form for a calendar's name, colour, visibility, sync and default flag. #>
    param($Calendar)
    $colors = @([enum]::GetNames([ConsoleColor]) | Where-Object { $_ -ne 'Black' })
    $isLocal = Test-CalendarIsLocal $Calendar
    $fields = @(
        New-FormField -Key 'Name' -Label 'Name' -Value $Calendar.Name -Hint 'Shown in PSCalendar only'
        New-FormField -Key 'Color' -Label 'Colour' -Type 'choice' -Value $Calendar.Color -Options $colors
        New-FormField -Key 'Visible' -Label 'Show events' -Type 'bool' -Value ([bool]$Calendar.Visible)
    )
    if (-not $isLocal) { $fields += New-FormField -Key 'Sync' -Label 'Synchronise' -Type 'bool' -Value ([bool]$Calendar.Sync) }
    if (-not $Calendar.ReadOnly) { $fields += New-FormField -Key 'Default' -Label 'Default calendar' -Type 'bool' -Value ($script:Config.Settings.DefaultCalendarId -eq $Calendar.Id) -Hint 'New events go here' }
    $fields += New-FormField -Key 'Info' -Label 'Location' -Type 'readonly' -Value $(if ($Calendar.RemoteId) { $Calendar.RemoteId } else { 'This computer' })
    $v = Invoke-TuiForm -Title ('Calendar: ' + $Calendar.Name) -Fields $fields
    if ($null -eq $v) { return }
    if (([string]$v.Name).Trim()) { $Calendar.Name = ([string]$v.Name).Trim() }
    $Calendar.Color = [string]$v.Color
    $Calendar.Visible = [bool]$v.Visible
    if ($v.ContainsKey('Sync')) { $Calendar.Sync = [bool]$v.Sync }
    if ($v.ContainsKey('Default') -and $v.Default) { $script:Config.Settings.DefaultCalendarId = $Calendar.Id }
    $script:DataVersion++
    Save-Config
}

function Edit-AccountSetting {
    <# Form for an account's name and credentials. #>
    param($Account)
    if ($Account.Type -eq 'Local') {
        $v = Invoke-TuiForm -Title 'Local calendars' -Fields @(New-FormField -Key 'Name' -Label 'Name' -Value $Account.Name)
        if ($null -ne $v -and ([string]$v.Name).Trim()) { $Account.Name = ([string]$v.Name).Trim(); Save-Config }
        return
    }
    $fields = @(
        New-FormField -Key 'Name' -Label 'Account name' -Value $Account.Name
        New-FormField -Key 'Enabled' -Label 'Synchronise' -Type 'bool' -Value ([bool]$Account.Enabled)
    )
    if ($Account.Type -eq 'Subscription') {
        $fields += New-FormField -Key 'ServerUrl' -Label 'Calendar address' -Value $Account.ServerUrl -Hint 'The .ics or webcal:// link'
        $v = Invoke-TuiForm -Title ('Subscription: ' + $Account.Name) -Fields $fields -Validate {
            param($v)
            if (([string]$v.ServerUrl).Trim() -notmatch '^(?i)(https?|webcals?)://.+') { return 'Enter the address (https://... or webcal://...).' }
            return $null
        }
        if ($null -eq $v) { return }
        if (([string]$v.Name).Trim()) { $Account.Name = ([string]$v.Name).Trim() }
        $Account.Enabled = [bool]$v.Enabled
        $url = ([string]$v.ServerUrl).Trim()
        if ($url -ne $Account.ServerUrl) {
            $Account.ServerUrl = $url
            foreach ($c in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $Account.Id })) {
                $c.RemoteId = $url; $c.CTag = ''; $c.LastSync = ''
            }
        }
        Save-Config
        return
    }
    if ($Account.Type -eq 'Google') {
        $fields += New-FormField -Key 'ClientId' -Label 'Client ID' -Value $Account.ClientId
        $fields += New-FormField -Key 'ClientSecret' -Label 'Client secret' -Type 'password' -Hint 'Leave blank to keep the current secret'
        $fields += New-FormField -Key 'Reauth' -Label 'Sign in again' -Type 'bool' -Value $false -Hint 'Opens the browser to authorise PSCalendar again'
    }
    else {
        if ($Account.Type -eq 'CalDAV') { $fields += New-FormField -Key 'ServerUrl' -Label 'Server URL' -Value $Account.ServerUrl }
        $fields += New-FormField -Key 'Username' -Label 'User name' -Value $Account.Username
        $fields += New-FormField -Key 'Password' -Label 'Password' -Type 'password' -Hint 'Leave blank to keep the current password'
    }
    $v = Invoke-TuiForm -Title ('Account: ' + $Account.Name) -Fields $fields
    if ($null -eq $v) { return }
    if (([string]$v.Name).Trim()) { $Account.Name = ([string]$v.Name).Trim() }
    $Account.Enabled = [bool]$v.Enabled
    if ($Account.Type -eq 'Google') {
        $Account.ClientId = ([string]$v.ClientId).Trim()
        if ($v.ClientSecret) { $Account.ClientSecret = Protect-Secret ([string]$v.ClientSecret).Trim() }
        if ($v.Reauth) {
            try { Connect-GoogleAccount $Account; $script:State.Message = 'Google access renewed.' }
            catch { Show-TuiMessage -Title 'Google sign-in failed' -Message $_.Exception.Message -IsError }
        }
    }
    else {
        if ($v.ContainsKey('ServerUrl')) { $Account.ServerUrl = ([string]$v.ServerUrl).Trim(); $Account.PrincipalUrl = '' }
        $Account.Username = ([string]$v.Username).Trim()
        if ($v.Password) { $Account.Secret = Protect-Secret ([string]$v.Password).Trim() }
    }
    Save-Config
}

function Remove-AccountInteractive {
    <# Removes an account and its calendars from PSCalendar. #>
    param($Account)
    if ($Account.Type -eq 'Local') { Show-TuiMessage -Title 'Local calendars' -Message 'The local account cannot be removed. Remove single local calendars instead.'; return }
    $msg = "Remove '{0}' and its calendars from PSCalendar? Nothing is deleted on the server." -f $Account.Name
    if ($Account.Id -eq $script:HolidayAccountId) { $msg = "Remove '{0}'? You can turn it back on in Options (O)." -f $Account.Name }
    if (-not (Read-TuiConfirm -Title 'Remove account' -Message $msg)) { return }
    foreach ($c in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $Account.Id })) { Remove-LocalCalendar $c }
    [void]$script:Config.Accounts.Remove($Account)
    $script:TokenCache.Remove($Account.Id)
    Save-Config
    Save-EventStore
}

function Show-CalendarManager {
    <# Full screen list of accounts and calendars with management keys. #>
    $idx = 0
    while ($true) {
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($a in $script:Config.Accounts) {
            $rows.Add(@{ Kind = 'Account'; Item = $a })
            foreach ($c in @($script:Config.Calendars | Where-Object { $_.AccountId -eq $a.Id })) { $rows.Add(@{ Kind = 'Calendar'; Item = $c }) }
        }
        if ($idx -ge $rows.Count) { $idx = $rows.Count - 1 }
        if ($idx -lt 0) { $idx = 0 }
        $null = Update-ScreenSize
        Clear-ScreenBuffer
        $b = $script:Buf
        Write-Buffer -X 0 -Y 0 -Text ' PSCalendar - Calendars and accounts' -Fg White -Bg DarkBlue -Width $b.W
        $listTop = 2
        $listH = $b.H - 5
        $top = [Math]::Max(0, $idx - $listH + 1)
        for ($i = 0; $i -lt $listH; $i++) {
            $ri = $top + $i
            if ($ri -ge $rows.Count) { break }
            $row = $rows[$ri]
            $y = $listTop + $i
            $sel = ($ri -eq $idx)
            if ($row.Kind -eq 'Account') {
                $a = $row.Item
                $user = ''
                if ($a.Username) { $user = ' - ' + $a.Username }
                $state = ''
                if ($a.Type -ne 'Local' -and -not $a.Enabled) { $state = '  (sync off)' }
                $text = ' {0} [{1}]{2}{3}' -f $a.Name, $a.Type, $user, $state
                $bg = 'DarkGray'; if ($sel) { $bg = 'DarkCyan' }
                Write-Buffer -X 0 -Y $y -Text (ConvertTo-DisplayText $text) -Fg White -Bg $bg -Width $b.W
            }
            else {
                $c = $row.Item
                $bg = 'Black'; if ($sel) { $bg = 'DarkCyan' }
                Write-Fill -X 0 -Y $y -Width $b.W -Height 1 -Bg $bg
                $vis = '[ ]'; if ($c.Visible) { $vis = '[x]' }
                Write-Buffer -X 3 -Y $y -Text $vis -Fg White -Bg $bg
                Write-Buffer -X 7 -Y $y -Text ($script:G.Block + $script:G.Block) -Fg $c.Color -Bg $bg
                Write-Buffer -X 10 -Y $y -Text (ConvertTo-DisplayText $c.Name) -Fg White -Bg $bg -Width 34
                $flags = @()
                if (-not (Test-CalendarIsLocal $c)) { if ($c.Sync) { $flags += 'sync on' } else { $flags += 'sync off' } }
                if ($c.ReadOnly) { $flags += 'read only' }
                if ($script:Config.Settings.DefaultCalendarId -eq $c.Id) { $flags += 'default' }
                if ($c.LastSync) { try { $flags += 'synced ' + (ConvertFrom-WallString $c.LastSync).ToString('g') } catch { Write-Verbose 'bad date' } }
                $count = @($script:Events | Where-Object { $_.CalendarId -eq $c.Id -and -not $_.Deleted }).Count
                $flags += ('{0} events' -f $count)
                Write-Buffer -X 45 -Y $y -Text ($flags -join ', ') -Fg Gray -Bg $bg -Width ([Math]::Max(0, $b.W - 46))
            }
        }
        if ($null -ne $script:State -and $script:State.Message) { Write-Buffer -X 1 -Y ($b.H - 3) -Text $script:State.Message -Fg Yellow -Width ($b.W - 2) }
        Write-KeyHint -Y ($b.H - 2) -Hints @(@('A', 'Add account'), @('N', 'New local calendar'), @('Enter', 'Edit'), @('Space', 'Show/hide'), @('Y', 'Sync on/off'))
        Write-KeyHint -Y ($b.H - 1) -Hints @(@('R', 'Refresh calendar list'), @('S', 'Sync account'), @('Del', 'Remove'), @('Esc', 'Back'))
        Show-ScreenBuffer
        $k = Read-TuiKey
        if ($null -eq $k) { continue }
        if ($null -ne $script:State) { $script:State.Message = '' }
        $kn = [string]$k.Key
        $row = $null
        if ($rows.Count -gt 0) { $row = $rows[$idx] }
        $acc = $null
        if ($null -ne $row) { if ($row.Kind -eq 'Account') { $acc = $row.Item } else { $acc = Get-Account $row.Item.AccountId } }
        try {
            if ($kn -eq 'Escape' -or $kn -eq 'Q') { $script:DataVersion++; return }
            elseif ($kn -eq 'UpArrow') { if ($idx -gt 0) { $idx-- } }
            elseif ($kn -eq 'DownArrow') { if ($idx -lt $rows.Count - 1) { $idx++ } }
            elseif ($kn -eq 'PageUp') { $idx = [Math]::Max(0, $idx - $listH) }
            elseif ($kn -eq 'PageDown') { $idx = [Math]::Min($rows.Count - 1, $idx + $listH) }
            elseif ($kn -eq 'A') { Add-AccountInteractive }
            elseif ($kn -eq 'N') { New-LocalCalendarInteractive }
            elseif ($kn -eq 'Enter' -and $null -ne $row) { if ($row.Kind -eq 'Account') { Edit-AccountSetting $row.Item } else { Edit-CalendarSetting $row.Item } }
            elseif ($kn -eq 'Spacebar' -and $null -ne $row -and $row.Kind -eq 'Calendar') { $row.Item.Visible = -not $row.Item.Visible; $script:DataVersion++; Save-Config }
            elseif ($kn -eq 'Y' -and $null -ne $row -and $row.Kind -eq 'Calendar' -and -not (Test-CalendarIsLocal $row.Item)) { $row.Item.Sync = -not $row.Item.Sync; Save-Config }
            elseif ($kn -eq 'R' -and $null -ne $acc) {
                if ($acc.Type -eq 'Local') { $script:State.Message = 'Local calendars have no server.' }
                elseif ($acc.Type -eq 'Subscription') { $script:State.Message = 'A subscription has a single calendar. Press S to download it again.' }
                else { Update-AccountCalendar $acc }
            }
            elseif ($kn -eq 'S' -and $null -ne $acc) {
                if ($acc.Type -eq 'Local') { $script:State.Message = 'Local calendars are not synchronised.' } else { Invoke-SyncInteractive -AccountId $acc.Id -Force }
            }
            elseif ($kn -eq 'Delete' -and $null -ne $row) {
                if ($row.Kind -eq 'Account') { Remove-AccountInteractive $row.Item }
                else {
                    $c = $row.Item
                    $local = Test-CalendarIsLocal $c
                    $writable = @($script:Config.Calendars | Where-Object { -not $_.ReadOnly })
                    if (-not $c.ReadOnly -and $writable.Count -le 1) {
                        Show-TuiMessage -Title 'Remove calendar' -Message 'You need at least one calendar you can add events to.'
                    }
                    else {
                        $msg = "Remove '{0}' from PSCalendar? Nothing is deleted on the server." -f $c.Name
                        if ($local) { $msg = "Delete the local calendar '{0}' and all its events?" -f $c.Name }
                        if ($c.Id -eq $script:HolidayCalendarId) { $msg = "Remove '{0}'? You can turn it back on in Options (O)." -f $c.Name }
                        if (Read-TuiConfirm -Title 'Remove calendar' -Message $msg) { Remove-LocalCalendar $c; Save-Config; Save-EventStore }
                    }
                }
            }
        }
        catch { Show-TuiMessage -Title 'Error' -Message $_.Exception.Message -IsError }
    }
}

function Edit-AppSetting {
    <# The options form. #>
    $s = $script:Config.Settings
    $writable = @($script:Config.Calendars | Where-Object { -not $_.ReadOnly })
    $labels = @($writable | ForEach-Object { Get-CalendarLabel $_ })
    $defCal = Get-Calendar $s.DefaultCalendarId
    $defLabel = $labels[0]
    if ($null -ne $defCal -and [Array]::IndexOf($writable, $defCal) -ge 0) { $defLabel = $labels[[Array]::IndexOf($writable, $defCal)] }
    $sendMap = [ordered]@{ all = 'Send to all guests'; externalOnly = 'Only to non-Google guests'; none = 'Do not send' }
    $sendLabel = $sendMap[[string]$s.GoogleSendUpdates]
    if (-not $sendLabel) { $sendLabel = 'Send to all guests' }
    $conflict = 'Server copy wins'
    if ($s.ConflictPolicy -eq 'Local') { $conflict = 'My copy wins' }
    $fields = @(
        New-FormField -Key 'WeekStart' -Label 'Week starts on' -Type 'choice' -Value $s.WeekStart -Options @('Monday', 'Sunday', 'Saturday')
        New-FormField -Key 'TimeFormat' -Label 'Clock' -Type 'choice' -Value $s.TimeFormat -Options @('24h', '12h')
        New-FormField -Key 'DayStartHour' -Label 'Day view starts' -Value ([string]$s.DayStartHour) -Hint 'Hour (0-23) the week and day views scroll to'
        New-FormField -Key 'Default' -Label 'Default calendar' -Type 'choice' -Value $defLabel -Options $labels
        New-FormField -Key 'DefaultDuration' -Label 'Event length' -Value ([string]$s.DefaultDuration) -Hint 'Default length of new events in minutes'
        New-FormField -Key 'DefaultReminder' -Label 'Default reminder' -Value ([string]$s.DefaultReminder) -Hint 'For new events, e.g. 15 or 10, 1h. Blank = none.'
        New-FormField -Key 'AgendaDays' -Label 'Agenda days' -Value ([string]$s.AgendaDays) -Hint 'How many days the agenda view lists'
        New-FormField -Key 'Holidays' -Label 'US holidays' -Type 'choice' -Value $script:HolidayModes[[string]$s.Holidays] -Options @($script:HolidayModes.Values) -Hint 'Read-only holidays calendar, downloaded from Google once a day'
        New-FormField -Key 'SyncOnStartup' -Label 'Sync on start' -Type 'bool' -Value ([bool]$s.SyncOnStartup)
        New-FormField -Key 'AutoSyncMinutes' -Label 'Auto sync every' -Value ([string]$s.AutoSyncMinutes) -Hint 'Minutes between automatic syncs while PSCalendar is open (0 = off)'
        New-FormField -Key 'PastDays' -Label 'Sync past days' -Value ([string]$s.PastDays) -Hint 'How far back events are downloaded'
        New-FormField -Key 'FutureDays' -Label 'Sync future days' -Value ([string]$s.FutureDays) -Hint 'How far ahead events are downloaded'
        New-FormField -Key 'Conflict' -Label 'On conflicts' -Type 'choice' -Value $conflict -Options @('Server copy wins', 'My copy wins') -Hint 'When an event changed both here and on the server'
        New-FormField -Key 'Send' -Label 'Google invites' -Type 'choice' -Value $sendLabel -Options @($sendMap.Values) -Hint 'Whether Google e-mails guests about changes'
    )
    $v = Invoke-TuiForm -Title 'Options' -Fields $fields -Validate {
        param($v)
        $checks = @(@('DayStartHour', 0, 23), @('DefaultDuration', 1, 100000), @('AgendaDays', 1, 3650), @('AutoSyncMinutes', 0, 1440), @('PastDays', 0, 3650), @('FutureDays', 1, 3650))
        foreach ($c in $checks) {
            $n = 0
            if (-not [int]::TryParse(([string]$v[$c[0]]).Trim(), [ref]$n) -or $n -lt $c[1] -or $n -gt $c[2]) { return ('{0} must be a number from {1} to {2}.' -f $c[0], $c[1], $c[2]) }
        }
        try { $null = ConvertFrom-ReminderText $v.DefaultReminder } catch { return $_.Exception.Message }
        return $null
    }
    if ($null -eq $v) { return }
    $windowChanged = ([int]$v.PastDays -ne [int]$s.PastDays -or [int]$v.FutureDays -ne [int]$s.FutureDays)
    foreach ($k in $script:HolidayModes.Keys) { if ($script:HolidayModes[$k] -eq $v.Holidays) { $s.Holidays = $k } }
    Update-HolidayCalendar
    $s.WeekStart = [string]$v.WeekStart
    $s.TimeFormat = [string]$v.TimeFormat
    $s.DayStartHour = [int]$v.DayStartHour
    $s.DefaultDuration = [int]$v.DefaultDuration
    $s.DefaultReminder = ([string]$v.DefaultReminder).Trim()
    $s.AgendaDays = [int]$v.AgendaDays
    $s.SyncOnStartup = [bool]$v.SyncOnStartup
    $s.AutoSyncMinutes = [int]$v.AutoSyncMinutes
    $s.PastDays = [int]$v.PastDays
    $s.FutureDays = [int]$v.FutureDays
    $s.ConflictPolicy = 'Server'
    if ($v.Conflict -eq 'My copy wins') { $s.ConflictPolicy = 'Local' }
    foreach ($k in $sendMap.Keys) { if ($sendMap[$k] -eq $v.Send) { $s.GoogleSendUpdates = $k } }
    $i = [Array]::IndexOf($labels, [string]$v.Default)
    if ($i -ge 0) { $s.DefaultCalendarId = $writable[$i].Id }
    if ($windowChanged) { foreach ($c in $script:Config.Calendars) { $c.CTag = '' } }
    $script:DataVersion++
    Save-Config
    Save-EventStore
    # Download the holidays straight away when they were just switched on.
    $hol = Get-Calendar $script:HolidayCalendarId
    if ($null -ne $hol -and $hol.Sync -and -not $hol.LastSync) { Invoke-SyncInteractive -AccountId $script:HolidayAccountId }
}

function Invoke-SyncInteractive {
    <# Runs a sync with a progress box and reports the result in the status line. -Force also refreshes subscriptions. #>
    param([string]$AccountId = '', [switch]$Force)
    if (-not (Test-HasSyncCalendar)) {
        $script:LastSyncAttempt = Get-Date
        $script:State.Message = 'No synchronised calendars yet. Press C to add iCloud or Google accounts.'
        return
    }
    $script:SyncSnapshot = Save-ScreenBuffer
    try { $res = Sync-AllCalendar -AccountId $AccountId -Force:$Force }
    finally { Restore-ScreenBuffer $script:SyncSnapshot; $script:SyncSnapshot = $null }
    # A background sync that had nothing due (only subscriptions) stays quiet.
    if (-not $Force -and $res.Calendars -eq 0 -and $res.Errors -eq 0) { return }
    $script:State.Message = $res.Summary
    if ($res.Errors) { $script:State.MessageColor = 'Red' } else { $script:State.MessageColor = 'Green' }
}

#endregion

#region ------------------------------------------------------------ Main views

function Write-KeyHint {
    <# Draws a row of "Key Label" hints. #>
    param([int]$Y, [object[]]$Hints)
    $b = $script:Buf
    Write-Fill -X 0 -Y $Y -Width $b.W -Height 1 -Bg Black
    $x = 1
    foreach ($h in $Hints) {
        $need = $h[0].Length + $h[1].Length + 3
        if ($x + $need -gt $b.W) { break }
        Write-Buffer -X $x -Y $Y -Text $h[0] -Fg Black -Bg Gray
        Write-Buffer -X ($x + $h[0].Length + 1) -Y $Y -Text $h[1] -Fg Gray
        $x += $need
    }
}

function Get-PeriodLabel {
    <# Text describing the period shown by the current view. #>
    $s = $script:State
    switch ($s.View) {
        'Month' { return $s.Date.ToString('MMMM yyyy') }
        'Week' {
            $ws = Get-WeekStart $s.Date
            $we = $ws.AddDays(6)
            if ($ws.Year -ne $we.Year) { return ('{0} - {1}' -f $ws.ToString('MMM d, yyyy'), $we.ToString('MMM d, yyyy')) }
            return ('{0} - {1}' -f $ws.ToString('MMM d'), $we.ToString('MMM d, yyyy'))
        }
        'Day' { return $s.Date.ToString('dddd, MMMM d, yyyy') }
        default {
            if ($s.Search) { return "Search: '" + $s.Search + "'" }
            return ('From ' + $s.Date.ToString('ddd, MMM d yyyy'))
        }
    }
}

function Write-TitleBar {
    <# Top row: application name, view tabs, period and sync state. #>
    $b = $script:Buf
    $s = $script:State
    Write-Fill -X 0 -Y 0 -Width $b.W -Height 1 -Bg DarkBlue
    Write-Buffer -X 0 -Y 0 -Text ' PSCalendar ' -Fg Yellow -Bg DarkBlue
    $x = 12
    foreach ($v in 'Month', 'Week', 'Day', 'Agenda') {
        $t = ' ' + $v + ' '
        if ($v -eq $s.View) { Write-Buffer -X $x -Y 0 -Text $t -Fg Black -Bg Cyan } else { Write-Buffer -X $x -Y 0 -Text $t -Fg Gray -Bg DarkBlue }
        $x += $t.Length
    }
    $period = ' ' + $script:G.Left + ' ' + (Get-PeriodLabel) + ' ' + $script:G.Right
    Write-Buffer -X ($x + 1) -Y 0 -Text $period -Fg White -Bg DarkBlue
    $right = ''
    $pending = Get-PendingChangeCount
    if ($pending) { $right = '{0} to upload  ' -f $pending }
    if ($null -ne $script:LastSyncTime) { $right += 'synced ' + (Format-Time $script:LastSyncTime) + ' ' }
    elseif (Test-HasSyncCalendar) { $right += 'not synced ' }
    if ($right -and $x + 1 + $period.Length + $right.Length -lt $b.W) { Write-Buffer -X ($b.W - $right.Length) -Y 0 -Text $right -Fg Gray -Bg DarkBlue }
}

function Write-MonthView {
    <# Month grid with event titles in each day cell. #>
    $b = $script:Buf
    $s = $script:State
    $sel = $s.Date
    $today = (Get-Date).Date
    $first = New-Object DateTime $sel.Year, $sel.Month, 1
    $ws = [int](Get-WeekStartDay)
    $offset = (7 + [int]$first.DayOfWeek - $ws) % 7
    $gridStart = $first.AddDays(-$offset)
    $weeks = [int][Math]::Ceiling(($offset + [DateTime]::DaysInMonth($sel.Year, $sel.Month)) / 7)
    $colW = [int][Math]::Floor($b.W / 7)
    $top = 1
    for ($d = 0; $d -lt 7; $d++) {
        $x = $d * $colW
        $w = $colW
        if ($d -eq 6) { $w = $b.W - $x }
        Write-Buffer -X $x -Y $top -Text (Format-Center (Get-DayName ([DayOfWeek](($ws + $d) % 7))) $w) -Fg Cyan
    }
    $gridTop = $top + 1
    $gridBottom = $b.H - 3
    $cellH = [Math]::Max(2, [int][Math]::Floor(($gridBottom - $gridTop + 1) / $weeks))
    $instances = @(Get-EventInstance -From $gridStart -To $gridStart.AddDays($weeks * 7))
    $byDay = Group-InstanceByDay -Instances $instances -From $gridStart -Days ($weeks * 7)
    for ($w = 0; $w -lt $weeks; $w++) {
        for ($d = 0; $d -lt 7; $d++) {
            $date = $gridStart.AddDays($w * 7 + $d)
            $x = $d * $colW
            $cw = $colW
            if ($d -eq 6) { $cw = $b.W - $x }
            $y = $gridTop + $w * $cellH
            $inMonth = ($date.Month -eq $sel.Month)
            $label = ' ' + $date.Day
            if ($date.Day -eq 1 -or ($w -eq 0 -and $d -eq 0)) { $label = ' ' + $date.ToString('MMM d') }
            $hfg = 'White'; $hbg = 'DarkGray'
            if (-not $inMonth) { $hfg = 'Gray'; $hbg = 'Black' }
            if ($date -eq $today) { $hfg = 'Black'; $hbg = 'Yellow'; $label += ' today' }
            if ($date -eq $sel) { $hfg = $script:CursorFg; $hbg = $script:CursorBg }
            $cx = $x
            if ($d -gt 0) {
                for ($i = 0; $i -lt $cellH; $i++) { Write-Buffer -X $x -Y ($y + $i) -Text $script:G.V -Fg DarkGray }
                $cx = $x + 1
                $cw--
            }
            Write-Buffer -X $cx -Y $y -Text $label -Fg $hfg -Bg $hbg -Width $cw
            $items = @()
            if ($byDay.ContainsKey($date.Ticks)) {
                $items = @($byDay[$date.Ticks] | Sort-Object -Property @{ Expression = { if ($_.AllDay) { 0 } else { 1 } } }, Start)
            }
            $lines = $cellH - 1
            for ($i = 0; $i -lt $lines -and $i -lt $items.Count; $i++) {
                $ly = $y + 1 + $i
                if ($i -eq $lines - 1 -and $items.Count -gt $lines) {
                    Write-Buffer -X $cx -Y $ly -Text (' +{0} more' -f ($items.Count - $i)) -Fg DarkGray -Width $cw
                    break
                }
                $it = $items[$i]
                $title = Get-InstanceTitle $it
                if ($it.AllDay) { Write-Buffer -X $cx -Y $ly -Text (' ' + $title) -Fg (Get-ContrastColor $it.Color) -Bg $it.Color -Width $cw }
                else {
                    $prefix = Format-Time $it.Start
                    if ($it.Start.Date -lt $date) { $prefix = '..' }
                    $fg = $it.Color
                    if (-not $inMonth) { $fg = 'DarkGray' }
                    Write-Buffer -X $cx -Y $ly -Text (' ' + $prefix + ' ' + $title) -Fg $fg -Width $cw
                }
            }
        }
    }
    $s.Current = $null
    $dayItems = @(Get-DayItem $sel)
    if ($dayItems.Count -gt 0) {
        $idx = [Math]::Max(0, [Math]::Min($s.SelIndex, $dayItems.Count - 1))
        $s.SelIndex = $idx
        $s.Current = $dayItems[$idx]
    }
}

function Write-Timeline {
    <# Hour grid with event blocks for one or more days (week and day views). #>
    param([datetime[]]$Days, [int]$X, [int]$Width, [int]$Top, [int]$Bottom, [string]$SelectedKey, [switch]$PlainColors)
    $s = $script:State
    $today = (Get-Date).Date
    $gutter = 6
    $n = $Days.Count
    $colW = [int][Math]::Floor(($Width - $gutter) / $n)
    $rangeStart = $Days[0]
    $rangeEnd = $Days[$n - 1].AddDays(1)
    $instances = @(Get-EventInstance -From $rangeStart -To $rangeEnd)
    $cols = @()
    for ($i = 0; $i -lt $n; $i++) {
        $cx = $X + $gutter + $i * $colW
        $cw = $colW
        if ($i -eq $n - 1) { $cw = $X + $Width - $cx }
        $cols += @{ X = $cx; W = $cw; Day = $Days[$i] }
    }
    # Day headers.
    foreach ($c in $cols) {
        $label = (Get-DayName $c.Day.DayOfWeek) + ' ' + $c.Day.Day
        if ($n -eq 1) { $label = $c.Day.ToString('dddd, MMMM d') }
        $fg = 'White'; $bg = 'DarkGray'
        if ($c.Day -eq $today) { $fg = 'Black'; $bg = 'Yellow' }
        if ($c.Day -eq $s.Date) { $fg = $script:CursorFg; $bg = $script:CursorBg }
        Write-Buffer -X $c.X -Y $Top -Text (Format-Center $label ($c.W - 1)) -Fg $fg -Bg $bg -Width ($c.W - 1)
    }
    # All-day rows.
    $allDay = @{}
    $maxAll = 0
    foreach ($c in $cols) {
        $d = $c.Day
        $list = @($instances | Where-Object { $_.AllDay -and $_.Start -lt $d.AddDays(1) -and $_.End -gt $d } | Sort-Object -Property $script:InstanceOrder)
        $allDay[$d.Ticks] = $list
        $maxAll = [Math]::Max($maxAll, $list.Count)
    }
    $allRows = [Math]::Min(3, [Math]::Max(1, $maxAll))
    Write-Buffer -X $X -Y ($Top + 1) -Text 'all' -Fg DarkGray -Width ($gutter - 1)
    foreach ($c in $cols) {
        $list = $allDay[$c.Day.Ticks]
        for ($r = 0; $r -lt $allRows -and $r -lt $list.Count; $r++) {
            $it = $list[$r]
            $y = $Top + 1 + $r
            if ($r -eq $allRows - 1 -and $list.Count -gt $allRows) { Write-Buffer -X $c.X -Y $y -Text (' +{0} more' -f ($list.Count - $r)) -Fg DarkGray -Width ($c.W - 1); break }
            $bc = Get-EventBlockColor $it.Color ($it.Key -eq $SelectedKey) -Plain:$PlainColors; $fg = $bc.Fg; $bg = $bc.Bg
            Write-Buffer -X $c.X -Y $y -Text (' ' + (Get-InstanceTitle $it)) -Fg $fg -Bg $bg -Width ($c.W - 1)
        }
    }
    $sepY = $Top + 1 + $allRows
    Write-Buffer -X $X -Y $sepY -Text ($script:G.H * $Width) -Fg DarkGray
    $tlTop = $sepY + 1
    $rows = $Bottom - $tlTop + 1
    if ($rows -lt 1) { return }
    $slot = 60
    if ($rows -ge 30) { $slot = 30 }
    if ($rows -ge 80) { $slot = 15 }
    $visRows = [Math]::Min($rows, [int](1440 / $slot))
    $maxScroll = 1440 - $visRows * $slot

    # Timed event segments per day, with lanes for overlapping events.
    $segs = @()
    foreach ($c in $cols) {
        $d = $c.Day
        $dayEnd = $d.AddDays(1)
        $list = @($instances | Where-Object { -not $_.AllDay -and $_.Start -lt $dayEnd -and ($_.End -gt $d -or ($_.End -eq $_.Start -and $_.Start -ge $d)) } | Sort-Object -Property $script:InstanceOrder)
        # Overlapping events form a cluster that shares the column width.
        $laneEnds = New-Object 'System.Collections.Generic.List[datetime]'
        $cluster = New-Object 'System.Collections.Generic.List[object]'
        $clusterEnd = [datetime]::MinValue
        foreach ($it in $list) {
            $st = $it.Start; if ($st -lt $d) { $st = $d }
            $en = $it.End; if ($en -gt $dayEnd) { $en = $dayEnd }
            if ($en -le $st) { $en = $st.AddMinutes(15) }
            if ($st -ge $clusterEnd -and $cluster.Count -gt 0) {
                foreach ($sg in $cluster) { $sg.Lanes = $laneEnds.Count }
                $segs += $cluster.ToArray()
                $cluster.Clear()
                $laneEnds.Clear()
            }
            $lane = -1
            for ($l = 0; $l -lt $laneEnds.Count; $l++) { if ($laneEnds[$l] -le $st) { $lane = $l; break } }
            if ($lane -lt 0) { $laneEnds.Add($en); $lane = $laneEnds.Count - 1 } else { $laneEnds[$lane] = $en }
            if ($en -gt $clusterEnd -or $cluster.Count -eq 0) { $clusterEnd = $en }
            $cluster.Add(@{ Inst = $it; S = ($st - $d).TotalMinutes; E = ($en - $d).TotalMinutes; Lane = $lane; Col = $c; Lanes = 1 })
        }
        foreach ($sg in $cluster) { $sg.Lanes = $laneEnds.Count }
        $segs += $cluster.ToArray()
    }
    # Scroll: start at the configured hour and follow the selected event.
    $scroll = $s.ScrollMinutes
    if ($scroll -lt 0) {
        $scroll = [int]$script:Config.Settings.DayStartHour * 60
        $earliest = @($segs | ForEach-Object { $_.S } | Sort-Object | Select-Object -First 1)
        if ($earliest.Count -and $earliest[0] -lt $scroll) { $scroll = [int]$earliest[0] }
    }
    if ($SelectedKey -and $SelectedKey -ne $s.LastSelKey) {
        $selSeg = @($segs | Where-Object { $_.Inst.Key -eq $SelectedKey -and $_.Col.Day -eq $s.Date }) | Select-Object -First 1
        if ($null -ne $selSeg) {
            if ($selSeg.S -lt $scroll) { $scroll = [int]$selSeg.S }
            elseif ($selSeg.E -gt $scroll + $visRows * $slot) { $scroll = [int][Math]::Min($selSeg.S, $selSeg.E - $visRows * $slot) }
        }
    }
    $s.LastSelKey = $SelectedKey
    $scroll = [int]([Math]::Floor([Math]::Max(0, [Math]::Min($scroll, $maxScroll)) / $slot) * $slot)
    $s.ScrollMinutes = $scroll

    for ($r = 0; $r -lt $visRows; $r++) {
        $minute = $scroll + $r * $slot
        $y = $tlTop + $r
        if ($minute % 60 -eq 0) { Write-Buffer -X $X -Y $y -Text (Format-HourLabel ([int]($minute / 60))) -Fg DarkGray -Width ($gutter - 1) }
        if ($n -gt 1) { foreach ($c in $cols) { Write-Buffer -X ($c.X + $c.W - 1) -Y $y -Text $script:G.V -Fg DarkGray } }
    }
    foreach ($sg in $segs) {
        $c = $sg.Col
        $r0 = [int][Math]::Floor(($sg.S - $scroll) / $slot)
        $r1 = [int][Math]::Ceiling(($sg.E - $scroll) / $slot) - 1
        if ($r1 -lt $r0) { $r1 = $r0 }
        $inner = $c.W - 1
        $laneW = [int][Math]::Floor($inner / $sg.Lanes)
        $lx = $c.X + $sg.Lane * $laneW
        $lw = $laneW
        if ($sg.Lane -eq $sg.Lanes - 1) { $lw = $inner - $sg.Lane * $laneW }
        if ($lw -gt 3 -and $sg.Lane -lt $sg.Lanes - 1) { $lw-- }
        if ($lw -lt 1) { continue }
        if ($r1 -lt 0) { Write-Buffer -X $lx -Y $tlTop -Text $script:G.Up -Fg $sg.Inst.Color; continue }
        if ($r0 -ge $visRows) { Write-Buffer -X $lx -Y ($tlTop + $visRows - 1) -Text $script:G.Down -Fg $sg.Inst.Color; continue }
        $bc = Get-EventBlockColor $sg.Inst.Color ($sg.Inst.Key -eq $SelectedKey) -Plain:$PlainColors; $fg = $bc.Fg; $bg = $bc.Bg
        $first = [Math]::Max(0, $r0)
        $last = [Math]::Min($visRows - 1, $r1)
        # Wide blocks: "time title" then location. Narrow blocks: title, then time.
        $title = Get-InstanceTitle $sg.Inst
        $time = Format-Time $sg.Inst.Start
        $lines = @($title, $time)
        if ($lw -ge 14) {
            $lines = @(($time + ' ' + $title))
            if ($sg.Inst.Event.Location) { $lines += ConvertTo-DisplayText $sg.Inst.Event.Location }
        }
        for ($r = $first; $r -le $last; $r++) {
            $text = ''
            if ($r - $first -lt $lines.Count) { $text = $lines[$r - $first] }
            Write-Buffer -X $lx -Y ($tlTop + $r) -Text $text -Fg $fg -Bg $bg -Width $lw
        }
    }
    # Current time marker.
    $now = Get-Date
    if ($Days -contains $today) {
        $r = [int][Math]::Floor(($now.TimeOfDay.TotalMinutes - $scroll) / $slot)
        if ($r -ge 0 -and $r -lt $visRows) { Write-Buffer -X $X -Y ($tlTop + $r) -Text (' now' + $script:G.Right) -Fg Red -Width ($gutter - 1) }
    }
}

function Write-WeekView {
    <# Seven day timeline. #>
    $b = $script:Buf
    $s = $script:State
    $ws = Get-WeekStart $s.Date
    $days = [datetime[]]@(for ($i = 0; $i -lt 7; $i++) { $ws.AddDays($i) })
    $items = @(Get-DayItem $s.Date)
    $s.Current = $null
    if ($items.Count) { $s.SelIndex = [Math]::Max(0, [Math]::Min($s.SelIndex, $items.Count - 1)); $s.Current = $items[$s.SelIndex] }
    $key = ''
    if ($null -ne $s.Current) { $key = $s.Current.Key }
    Write-Timeline -Days $days -X 0 -Width $b.W -Top 1 -Bottom ($b.H - 3) -SelectedKey $key
}

function Write-DayView {
    <# One day timeline with a details panel when the window is wide enough. #>
    $b = $script:Buf
    $s = $script:State
    $items = @(Get-DayItem $s.Date)
    $s.Current = $null
    if ($items.Count) { $s.SelIndex = [Math]::Max(0, [Math]::Min($s.SelIndex, $items.Count - 1)); $s.Current = $items[$s.SelIndex] }
    $key = ''
    if ($null -ne $s.Current) { $key = $s.Current.Key }
    $tlW = $b.W
    if ($b.W -ge 100) { $tlW = $b.W - 44 }
    Write-Timeline -Days ([datetime[]]@($s.Date)) -X 0 -Width $tlW -Top 1 -Bottom ($b.H - 3) -SelectedKey $key -PlainColors
    if ($tlW -lt $b.W) {
        $px = $tlW + 1
        $pw = $b.W - $px - 1
        $h = $b.H - 4
        for ($i = 0; $i -lt $h; $i++) { Write-Buffer -X $tlW -Y (1 + $i) -Text $script:G.V -Fg DarkGray }
        if ($null -eq $s.Current) {
            Write-Buffer -X ($px + 1) -Y 2 -Text 'No events on this day.' -Fg DarkGray
            Write-Buffer -X ($px + 1) -Y 3 -Text 'Press N to add one.' -Fg DarkGray
        }
        else {
            Write-Buffer -X ($px + 1) -Y 1 -Text ('Event {0} of {1}' -f ($s.SelIndex + 1), $items.Count) -Fg DarkGray
            $lines = @(Get-EventDetailLine -Instance $s.Current -Width ($pw - 2))
            for ($i = 0; $i -lt $lines.Count -and $i -lt $h - 2; $i++) {
                $l = $lines[$i]
                $fg = 'Gray'; $t = $l
                if ($l -is [System.Collections.IDictionary]) { $t = $l.T; $fg = $l.F }
                Write-Buffer -X ($px + 1) -Y (3 + $i) -Text (ConvertTo-DisplayText ([string]$t)) -Fg $fg -Width ($pw - 1)
            }
        }
    }
}

function Write-AgendaView {
    <# Chronological list of upcoming events (or search results). #>
    $b = $script:Buf
    $s = $script:State
    $today = (Get-Date).Date
    if ($s.Search) {
        $win = Get-SyncWindow
        $from = $win.From; if ($s.Date -lt $from) { $from = $s.Date.AddDays(-30) }
        $to = $win.To; if ($s.Date -gt $to) { $to = $s.Date.AddDays(365) }
        $needle = $s.Search
        $all = @(Get-EventInstance -From $from -To $to | Where-Object {
                $ev = $_.Event
                $hay = @($ev.Summary, $ev.Location, $ev.Description) + @($ev.Attendees | ForEach-Object { $_.Email; $_.Name })
                @($hay | Where-Object { $_ -and $_.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
            })
    }
    else { $all = @(Get-EventInstance -From $s.Date -To $s.Date.AddDays([int]$script:Config.Settings.AgendaDays)) }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $lastDate = [datetime]::MinValue
    $itemRows = New-Object 'System.Collections.Generic.List[int]'
    foreach ($it in $all) {
        $d = $it.Start.Date
        if (-not $s.Search -and $d -lt $s.Date) { $d = $s.Date }
        if ($d -ne $lastDate) { $rows.Add(@{ Header = $true; Date = $d }); $lastDate = $d }
        $itemRows.Add($rows.Count)
        $rows.Add(@{ Header = $false; Inst = $it })
    }
    $s.Current = $null
    $listTop = 1
    $listH = $b.H - 4
    if ($itemRows.Count -eq 0) {
        $msg = 'No events in the next {0} days. Press N to add one.' -f $script:Config.Settings.AgendaDays
        if ($s.Search) { $msg = "Nothing matches '{0}'. Press Esc to clear the search." -f $s.Search }
        Write-Buffer -X 2 -Y 3 -Text $msg -Fg DarkGray
        return
    }
    $s.AgendaIndex = [Math]::Max(0, [Math]::Min($s.AgendaIndex, $itemRows.Count - 1))
    $selRow = $itemRows[$s.AgendaIndex]
    $s.Current = $rows[$selRow].Inst
    if ($selRow -lt $s.AgendaScroll + 1) { $s.AgendaScroll = [Math]::Max(0, $selRow - 1) }
    if ($selRow -ge $s.AgendaScroll + $listH) { $s.AgendaScroll = $selRow - $listH + 1 }
    for ($i = 0; $i -lt $listH; $i++) {
        $ri = $s.AgendaScroll + $i
        if ($ri -ge $rows.Count) { break }
        $row = $rows[$ri]
        $y = $listTop + $i
        if ($row.Header) {
            $t = ' ' + $row.Date.ToString('dddd, MMMM d, yyyy')
            if ($row.Date -eq $today) { $t += '  (today)' } elseif ($row.Date -eq $today.AddDays(1)) { $t += '  (tomorrow)' }
            Write-Buffer -X 0 -Y $y -Text $t -Fg Cyan -Width $b.W
            continue
        }
        $it = $row.Inst
        $sel = ($ri -eq $selRow)
        $bg = 'Black'; if ($sel) { $bg = 'DarkCyan' }
        Write-Fill -X 0 -Y $y -Width $b.W -Height 1 -Bg $bg
        Write-Buffer -X 2 -Y $y -Text (Format-InstanceWhen $it) -Fg White -Bg $bg -Width 26
        Write-Buffer -X 28 -Y $y -Text $script:G.Bar -Fg $it.Color -Bg $bg
        $calName = ConvertTo-DisplayText $it.Calendar.Name
        $right = [Math]::Max(10, $b.W - 30 - [Math]::Min(24, $calName.Length) - 2)
        $text = Get-InstanceTitle $it
        if ($it.Event.Location) { $text += '  @ ' + (ConvertTo-DisplayText $it.Event.Location) }
        if ($it.Event.RRule -or $it.Event.RecurrenceId) { $text += '  (repeats)' }
        Write-Buffer -X 30 -Y $y -Text $text -Fg White -Bg $bg -Width $right
        if (30 + $right + 1 -lt $b.W) { Write-Buffer -X (30 + $right + 1) -Y $y -Text $calName -Fg $it.Color -Bg $bg -Width ($b.W - 30 - $right - 2) }
    }
}

function Write-StatusLine {
    <# Second to last row: message or a summary of the selection. #>
    $b = $script:Buf
    $s = $script:State
    $y = $b.H - 2
    Write-Fill -X 0 -Y $y -Width $b.W -Height 1 -Bg Black
    if ($s.Message) { Write-Buffer -X 1 -Y $y -Text (ConvertTo-DisplayText $s.Message) -Fg $s.MessageColor -Width ($b.W - 2); return }
    if ($s.View -eq 'Month') {
        $n = @(Get-DayItem $s.Date).Count
        $t = '{0}: {1} event(s)' -f $s.Date.ToString('dddd, MMMM d'), $n
        if ($n) { $t += '  -  Enter opens the day' }
        Write-Buffer -X 1 -Y $y -Text $t -Fg Gray -Width ($b.W - 2)
        return
    }
    if ($null -ne $s.Current) {
        $it = $s.Current
        $t = $script:G.Right + ' ' + (Format-InstanceWhen $it) + '  ' + (Get-InstanceTitle $it)
        if ($it.Event.Location) { $t += '  @ ' + (ConvertTo-DisplayText $it.Event.Location) }
        $t += '  [' + (ConvertTo-DisplayText $it.Calendar.Name) + ']'
        Write-Buffer -X 1 -Y $y -Text $t -Fg $it.Color -Width ($b.W - 2)
    }
    elseif ($s.View -ne 'Agenda') { Write-Buffer -X 1 -Y $y -Text ('{0}: no events - press N to add one' -f $s.Date.ToString('dddd, MMMM d')) -Fg DarkGray -Width ($b.W - 2) }
}

function Write-MainScreen {
    <# Draws the complete main screen for the current view. #>
    $null = Update-ScreenSize
    Clear-ScreenBuffer
    $b = $script:Buf
    if ($b.W -lt 60 -or $b.H -lt 16) {
        Write-Buffer -X 0 -Y 0 -Text 'PSCalendar needs a window of at least 60 x 16 characters.' -Fg Yellow
        Write-Buffer -X 0 -Y 1 -Text 'Make the window larger, or press Q to quit.' -Fg Gray
        Show-ScreenBuffer
        return
    }
    Write-TitleBar
    switch ($script:State.View) {
        'Month' { Write-MonthView }
        'Week' { Write-WeekView }
        'Day' { Write-DayView }
        default { Write-AgendaView }
    }
    Write-StatusLine
    $hints = @(@('N', 'New'), @('E', 'Edit'), @('Del', 'Delete'), @('M/W/D/A', 'View'), @('T', 'Today'), @('G', 'Go to'), @('/', 'Search'),
        @('C', 'Calendars'), @('S', 'Sync'), @('O', 'Options'), @('?', 'Help'), @('Q', 'Quit'))
    if ($script:State.View -eq 'Month') { $hints = @(@('Arrows', 'Move'), @('Enter', 'Open day'), @('PgUp/PgDn', 'Month')) + $hints }
    else { $hints = @(@('Up/Dn', 'Select'), @('PgUp/PgDn', 'Prev/Next')) + $hints }
    Write-KeyHint -Y ($b.H - 1) -Hints $hints
    Show-ScreenBuffer
}

$script:HelpText = @'
VIEWS
  M  Month      W  Week      D  Day      A  Agenda (list)      Tab  next view

MOVING AROUND
  Left / Right        previous / next day
  Up / Down           Month: previous / next week. Other views: select an event
  PgUp / PgDn         previous / next month, week or day ( , and . also work )
  Ctrl+Up / Ctrl+Down scroll the hours in the week and day views
  T or Home           today
  G                   go to a date (2026-12-24, tomorrow, fri, +2w, -1m ...)

EVENTS
  N                   new event (Shift+N: new all-day event)
  Enter               Month: open the day.  Elsewhere: edit the selected event
  E                   edit the selected event
  I or Space          show all details of the selected event
  Del or X            delete the selected event (asks about recurring ones)
  /                   search all events (Esc clears the search)

CALENDARS AND SYNC
  C                   calendars and accounts: add iCloud, Google, CalDAV,
                      subscribed (.ics) and local calendars, show/hide,
                      colours, default calendar
  S or F5             synchronise now
  L                   sync log
  O                   options (week start, clock, US holidays, sync window ...)

  Q or Ctrl+C         quit

IN FORMS
  Up/Down or Tab move between fields, Enter edits a text field (or just start
  typing), Left/Right change a choice, Space toggles a check box.
  F10 or Ctrl+S saves, Esc cancels.  In text fields Ctrl+U clears and Ctrl+V
  pastes.  Dates accept today, tomorrow, mon, +3d; times accept 9, 930, 2pm.
'@

#endregion

#region ------------------------------------------------------------ Main loop

function Move-SelectedDate {
    <# Moves the selected date and resets the event selection. #>
    param([int]$Days)
    $script:State.Date = $script:State.Date.AddDays($Days)
    $script:State.SelIndex = 0
}

function Move-Period {
    <# Moves one month, week or day backward or forward depending on the view. #>
    param([int]$Direction)
    $s = $script:State
    switch ($s.View) {
        'Month' { $s.Date = $s.Date.AddMonths($Direction) }
        'Week' { $s.Date = $s.Date.AddDays(7 * $Direction) }
        'Day' { $s.Date = $s.Date.AddDays($Direction) }
        default { $s.Date = $s.Date.AddDays(7 * $Direction); $s.AgendaIndex = 0; $s.AgendaScroll = 0 }
    }
    $s.SelIndex = 0
}

function Set-View {
    <# Switches to another view. #>
    param([string]$Name)
    $s = $script:State
    if ($s.View -ne $Name) { $s.ScrollMinutes = -1; $s.LastSelKey = '' }
    $s.View = $Name
    if ($Name -eq 'Agenda') { $s.AgendaIndex = 0; $s.AgendaScroll = 0 }
}

function Get-NewEventStart {
    <# A sensible start time for a new event on the selected date. #>
    $s = $script:State
    $now = Get-Date
    if ($s.Date -eq $now.Date) { return $now.Date.AddHours($now.Hour + 1) }
    return $s.Date.AddHours([int]$script:Config.Settings.DayStartHour + 1)
}

function Edit-CurrentEvent {
    <# Edits the selected occurrence (or creates a new event when there is none). #>
    $s = $script:State
    if ($null -eq $s.Current) {
        if ($s.View -eq 'Month' -and @(Get-DayItem $s.Date).Count) { Set-View 'Day'; $s.Message = 'Select an event with Up/Down, then press E.'; return }
        $null = Edit-CalEvent -DefaultStart (Get-NewEventStart)
        return
    }
    if ($s.View -eq 'Month') { Set-View 'Day'; $s.Message = 'Select an event with Up/Down, then press E.'; return }
    $ev = $s.Current.Event
    if ($s.Current.Calendar.ReadOnly) {
        Show-TuiText -Title 'Read-only event' -Lines (Get-EventDetailLine -Instance $s.Current -Width 70) -Width 76
        return
    }
    if ($ev.RRule -and -not $ev.RecurrenceId) { $s.Message = 'Changes apply to every occurrence of this recurring event.' }
    $saved = Edit-CalEvent -Event $ev
    if ($null -ne $saved) {
        $s.Message = "Saved '" + $saved.Summary + "'."
        $s.MessageColor = 'Green'
    }
}

function Invoke-MainKey {
    <# Handles a key press in the main screen. #>
    param($Key)
    $s = $script:State
    $s.Message = ''
    $s.MessageColor = 'Yellow'
    $kn = [string]$Key.Key
    $ch = [string]$Key.KeyChar
    $ctrl = Test-CtrlKey $Key
    if ($ctrl -and $kn -eq 'C') { $s.Quit = $true; return }
    if ($ctrl -and ($kn -eq 'UpArrow' -or $kn -eq 'DownArrow')) {
        $step = 60
        if ($kn -eq 'UpArrow') { $step = -60 }
        if ($s.ScrollMinutes -lt 0) { $s.ScrollMinutes = [int]$script:Config.Settings.DayStartHour * 60 }
        $s.ScrollMinutes = [Math]::Max(0, [Math]::Min(1380, $s.ScrollMinutes + $step))
        return
    }
    switch ($kn) {
        'LeftArrow' { Move-SelectedDate -1; return }
        'RightArrow' { Move-SelectedDate 1; return }
        'UpArrow' {
            if ($s.View -eq 'Month') { Move-SelectedDate -7 }
            elseif ($s.View -eq 'Agenda') { if ($s.AgendaIndex -gt 0) { $s.AgendaIndex-- } }
            elseif ($s.SelIndex -gt 0) { $s.SelIndex-- }
            return
        }
        'DownArrow' {
            if ($s.View -eq 'Month') { Move-SelectedDate 7 }
            elseif ($s.View -eq 'Agenda') { $s.AgendaIndex++ }
            else { $s.SelIndex++ }
            return
        }
        'PageUp' { Move-Period -1; return }
        'PageDown' { Move-Period 1; return }
        'Home' { $s.Date = (Get-Date).Date; $s.SelIndex = 0; $s.AgendaIndex = 0; return }
        'Tab' {
            $views = @('Month', 'Week', 'Day', 'Agenda')
            $i = [Array]::IndexOf($views, $s.View)
            if (Test-ShiftKey $Key) { $i = ($i + 3) % 4 } else { $i = ($i + 1) % 4 }
            Set-View $views[$i]
            return
        }
        'Enter' {
            if ($s.View -eq 'Month') { Set-View 'Day'; return }
            Edit-CurrentEvent
            return
        }
        'Delete' { if ($null -ne $s.Current -and $s.View -ne 'Month') { Remove-CalEventInteractive $s.Current } elseif ($s.View -eq 'Month') { Set-View 'Day'; $s.Message = 'Select an event with Up/Down, then press Del.' }; return }
        'Escape' { if ($s.Search) { $s.Search = ''; $s.AgendaIndex = 0; $s.AgendaScroll = 0 }; return }
        'F1' { Show-TuiText -Title 'PSCalendar help' -Lines @($script:HelpText -split "`r?`n") -Width 84; return }
        'F5' { Invoke-SyncInteractive -Force; return }
        'Spacebar' { if ($null -ne $s.Current -and $s.View -ne 'Month') { Show-TuiText -Title 'Event details' -Lines (Get-EventDetailLine -Instance $s.Current -Width 70) -Width 76 }; return }
    }
    switch -CaseSensitive ($ch) {
        'N' { $null = Edit-CalEvent -DefaultStart $s.Date -AllDayDefault $true; return }
    }
    switch ($ch.ToLowerInvariant()) {
        'q' {
            $pending = Get-PendingChangeCount
            if ($pending -gt 0 -and (Test-HasSyncCalendar)) {
                $c = Read-TuiChoice -Title 'Quit' -Options @('Sync, then quit', 'Quit without syncing', 'Cancel') -Message ('{0} change(s) are not uploaded yet. They are kept and uploaded next time.' -f $pending)
                if ($c -eq 0) { Invoke-SyncInteractive; $s.Quit = $true }
                elseif ($c -eq 1) { $s.Quit = $true }
            }
            else { $s.Quit = $true }
        }
        'm' { Set-View 'Month' }
        'w' { Set-View 'Week' }
        'd' { Set-View 'Day' }
        'a' { Set-View 'Agenda' }
        't' { $s.Date = (Get-Date).Date; $s.SelIndex = 0; $s.AgendaIndex = 0 }
        'n' { $null = Edit-CalEvent -DefaultStart (Get-NewEventStart) }
        'e' { Edit-CurrentEvent }
        'x' { if ($null -ne $s.Current -and $s.View -ne 'Month') { Remove-CalEventInteractive $s.Current } }
        'i' {
            if ($null -ne $s.Current -and $s.View -ne 'Month') { Show-TuiText -Title 'Event details' -Lines (Get-EventDetailLine -Instance $s.Current -Width 70) -Width 76 }
            elseif ($s.View -eq 'Month') { Set-View 'Day' }
        }
        'g' {
            $t = Read-TuiInput -Title 'Go to date' -Prompt 'Date (2026-12-24, today, tomorrow, fri, +2w, -1m):'
            if ($null -ne $t) {
                $d = ConvertFrom-UserDate $t $s.Date
                if ($null -eq $d) { $s.Message = "'$t' is not a date I understand." } else { $s.Date = $d; $s.SelIndex = 0; $s.AgendaIndex = 0 }
            }
        }
        '/' {
            $t = Read-TuiInput -Title 'Search' -Prompt 'Find events whose title, location, notes or attendees contain:' -Default $s.Search
            if ($null -ne $t) { $s.Search = $t.Trim(); Set-View 'Agenda' }
        }
        'c' { Show-CalendarManager }
        's' { Invoke-SyncInteractive -Force }
        'l' {
            $lines = $script:SyncLog.ToArray()
            if ($lines.Count -eq 0) { $lines = @('Nothing synchronised yet.') }
            Show-TuiText -Title 'Sync log' -Lines @($lines | ForEach-Object {
                    if ($_ -match 'ERROR') { @{ T = $_; F = 'Red' } } elseif ($_ -match 'CONFLICT|WARNING|REJECTED') { @{ T = $_; F = 'Yellow' } } else { $_ }
                }) -Width 120
        }
        'o' { Edit-AppSetting }
        '?' { Show-TuiText -Title 'PSCalendar help' -Lines @($script:HelpText -split "`r?`n") -Width 84 }
        'h' { Show-TuiText -Title 'PSCalendar help' -Lines @($script:HelpText -split "`r?`n") -Width 84 }
        ',' { Move-Period -1 }
        '.' { Move-Period 1 }
        '<' { Move-Period -1 }
        '>' { Move-Period 1 }
    }
}

function Start-Tui {
    <# Prepares the console, runs the main loop and restores the console afterwards. #>
    param([string]$InitialView, [datetime]$InitialDate, [bool]$SkipSync)
    if ($Host.Name -eq 'Windows PowerShell ISE Host') { throw 'PSCalendar needs a console window; it cannot run inside the PowerShell ISE.' }
    try { $null = [Console]::KeyAvailable; $null = [Console]::WindowWidth }
    catch { throw 'PSCalendar needs an interactive console (input and output must not be redirected).' }

    $script:State = [pscustomobject]@{
        View = $InitialView; Date = $InitialDate.Date; SelIndex = 0; AgendaIndex = 0; AgendaScroll = 0
        Search = ''; Message = ''; MessageColor = 'Yellow'; Quit = $false; ScrollMinutes = -1; LastSelKey = ''; Current = $null
    }
    $origEncoding = [Console]::OutputEncoding
    $origCtrlC = [Console]::TreatControlCAsInput
    $script:UseAnsi = Test-AnsiSupport
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { Write-Verbose 'Could not switch the console to UTF-8.' }
        [Console]::TreatControlCAsInput = $true
        [Console]::CursorVisible = $false
        if ($script:UseAnsi) { [Console]::Write($script:E + '[?1049h' + $script:E + '[?25l') }
        $script:TuiActive = $true
        $null = Update-ScreenSize -Force
        $ownEvents = @($script:Events | Where-Object { $_.CalendarId -ne $script:HolidayCalendarId }).Count
        $accounts = @($script:Config.Accounts | Where-Object { $_.Type -ne 'Local' -and $_.Id -ne $script:HolidayAccountId }).Count
        if ($accounts -eq 0 -and $ownEvents -eq 0) {
            $script:State.Message = 'Welcome! Press N to add an event, C to connect iCloud or Google calendars, ? for help.'
        }
        if ($script:Config.Settings.SyncOnStartup -and -not $SkipSync -and (Test-HasSyncCalendar)) {
            Write-MainScreen
            Invoke-SyncInteractive
        }
        else { $script:LastSyncAttempt = Get-Date }
        while (-not $script:State.Quit) {
            Write-MainScreen
            $key = Read-TuiKey -AllowTimeout
            if ($null -eq $key) {
                if (Test-AutoSyncDue) { Invoke-SyncInteractive }
                continue
            }
            try { Invoke-MainKey $key }
            catch { Show-TuiMessage -Title 'Error' -Message (Get-InnermostMessage $_.Exception) -IsError }
        }
    }
    finally {
        $script:TuiActive = $false
        if ($script:UseAnsi) { [Console]::Write($script:E + '[0m' + $script:E + '[?25h' + $script:E + '[?1049l') }
        else { [Console]::ResetColor(); [Console]::Clear() }
        try { [Console]::CursorVisible = $true } catch { Write-Verbose 'Cursor state not restored.' }
        [Console]::TreatControlCAsInput = $origCtrlC
        try { [Console]::OutputEncoding = $origEncoding } catch { Write-Verbose 'Encoding not restored.' }
    }
}

function Get-UsageText {
    <# Text printed by -Help. #>
    return @"
PSCalendar $($script:AppVersion) - terminal calendar with iCloud, CalDAV and Google Calendar sync

USAGE
  .\PSCalendar.ps1 [-View Month|Week|Day|Agenda] [-Date <date>] [-DataPath <folder>] [-NoSync]
  .\PSCalendar.ps1 -SyncOnly [-DataPath <folder>]
  .\PSCalendar.ps1 -Version
  .\PSCalendar.ps1 -Help

OPTIONS
  -View       View to open with (default: Month)
  -Date       Date to open (default: today), e.g. 2026-12-24
  -DataPath   Folder for settings and events (default: %APPDATA%\PSCalendar)
  -NoSync     Do not synchronise when the calendar opens
  -SyncOnly   Synchronise all accounts without the user interface and exit
              (exit code 1 when a calendar failed)
  -Version    Show the version number and exit
  -Help       Show this help and exit

KEYS (press ? inside the application for the full list)
  M W D A  month / week / day / agenda view     Arrows, PgUp/PgDn  move
  N  new event      E or Enter  edit            Del  delete          T  today
  G  go to date     /  search                   C  calendars & accounts
  S  sync now       L  sync log                 O  options           Q  quit

See README.md for setting up iCloud and Google Calendar.
"@
}

function Start-PSCalendar {
    <# Entry point. #>
    if ($Version) { Write-Output ('{0} {1}' -f $script:AppName, $script:AppVersion); return }
    if ($Help) { Write-Output (Get-UsageText); return }
    Initialize-TimeZoneMap
    Initialize-Storage -Path $DataPath
    if ($SyncOnly) {
        $res = Sync-AllCalendar
        if ($res.Errors -gt 0) { exit 1 }
        return
    }
    Start-Tui -InitialView $View -InitialDate $Date -SkipSync ([bool]$NoSync)
}

#endregion

# Run unless the script is dot-sourced (dot-sourcing loads the functions for testing).
if ($MyInvocation.InvocationName -ne '.') { Start-PSCalendar }
