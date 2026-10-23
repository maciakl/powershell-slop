#Requires -Version 5.1
<#
.SYNOPSIS
    Calculates the time between two free-form dates/times, in an interactive TUI or from the
    command line.

.DESCRIPTION
    Get-TimeInterval opens a small terminal user interface (TUI) with two free-form text fields,
    Start and End. As you type, each field is parsed, the parsed date is shown underneath it (in
    your system's date format, including the day of the week) and the interval between the two
    is recalculated live.

    The fields accept almost any way of writing a date or time, for example:

        (blank)        5pm            17:30          noon           midnight
        5/7            May 7th 2027   2026-05-07T14:00Z              the 15th
        tomorrow 9am   next friday    last monday    friday next week
        in 3 hours     2 days ago     3 months and 7 days from today
        today + 90 minutes            1h30m          a week from tomorrow at noon
        5pm EST        9am Tokyo      14:00 UTC+2    noon America/New_York

    Defaults: a blank field means "now", a missing date means today, a missing year means the
    current year, missing minutes mean :00 and a missing time zone means the local time zone.

    When the TUI closes (Enter on the End field, or Esc) the script returns a
    TimeInterval.Result object containing the start and end as [datetime] values, the interval
    in a human-readable form and machine-readable totals.

    Use -Start and/or -End to skip the TUI and get the result directly.

.PARAMETER Start
    The start of the interval as free-form text. Blank means now. Using -Start or -End skips the
    interactive interface.

.PARAMETER End
    The end of the interval as free-form text. Blank (or omitted) means now.

.PARAMETER Version
    Displays the version number and exits.

.PARAMETER Help
    Displays usage information and exits.

.EXAMPLE
    .\Get-TimeInterval.ps1

    Opens the interactive interface. Press Enter on the End field (or Esc) to return the result.

.EXAMPLE
    .\Get-TimeInterval.ps1 -Start '9am' -End '5:30pm'

    Returns the interval between 9:00 and 17:30 today without opening the interface.

.EXAMPLE
    .\Get-TimeInterval.ps1 -End 'friday 5pm EST' | Select-Object Human, TotalHours

    Shows how long it is from now until Friday at 5 PM Eastern time.

.EXAMPLE
    $r = .\Get-TimeInterval.ps1 'last monday' 'next monday'; $r.TotalDays

.OUTPUTS
    TimeInterval.Result. A custom object with Start, End, StartUtc, EndUtc, StartTimeZone,
    EndTimeZone, Human, Compact, IsNegative, Duration, TotalSeconds, TotalMinutes, TotalHours,
    TotalDays, TotalWeeks, Breakdown, StartInput, EndInput and Notes properties.

.NOTES
    Name:    Get-TimeInterval.ps1
    Version: 0.1.0
    Runs on Windows PowerShell 5.1 and PowerShell 7+, with no external dependencies.
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
[OutputType('TimeInterval.Result')]
param(
    [Parameter(ParameterSetName = 'Direct', Position = 0)]
    [AllowEmptyString()]
    [string] $Start,

    [Parameter(ParameterSetName = 'Direct', Position = 1)]
    [AllowEmptyString()]
    [string] $End,

    [Parameter(ParameterSetName = 'Version', Mandatory)]
    [switch] $Version,

    [Parameter(ParameterSetName = 'Help', Mandatory)]
    [switch] $Help
)

#region Constants and lookup tables ------------------------------------------------------------

$script:AppName    = 'Get-TimeInterval'
$script:AppVersion = '0.1.0'

# Lazily-initialised caches (declared up front so they are safe under Set-StrictMode).
$script:Ui             = $null
$script:Glyph          = $null
$script:WinZoneRegex   = $null
$script:WinZoneMap     = $null
$script:DisplayPattern = $null

$script:RxOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

# Words that can stand in for a number in durations ("an hour ago", "two weeks from now").
$script:NumberWords = @{
    'a' = 1; 'an' = 1; 'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4; 'five' = 5; 'six' = 6
    'seven' = 7; 'eight' = 8; 'nine' = 9; 'ten' = 10; 'eleven' = 11; 'twelve' = 12
    'thirteen' = 13; 'fourteen' = 14; 'fifteen' = 15; 'sixteen' = 16; 'seventeen' = 17
    'eighteen' = 18; 'nineteen' = 19; 'twenty' = 20; 'thirty' = 30; 'forty' = 40; 'fifty' = 50
    'sixty' = 60; 'ninety' = 90; 'hundred' = 100
    'a couple of' = 2; 'a couple' = 2; 'couple of' = 2; 'a few' = 3; 'few' = 3
}

# Duration unit spellings mapped to an internal unit code.
$script:UnitMap = @{
    'seconds' = 's'; 'second' = 's'; 'secs' = 's'; 'sec' = 's'; 's' = 's'
    'minutes' = 'min'; 'minute' = 'min'; 'mins' = 'min'; 'min' = 'min'; 'm' = 'min'
    'hours' = 'h'; 'hour' = 'h'; 'hrs' = 'h'; 'hr' = 'h'; 'h' = 'h'
    'days' = 'd'; 'day' = 'd'; 'd' = 'd'
    'weeks' = 'w'; 'week' = 'w'; 'wks' = 'w'; 'wk' = 'w'; 'w' = 'w'
    'fortnights' = 'fn'; 'fortnight' = 'fn'
    'months' = 'mo'; 'month' = 'mo'; 'mos' = 'mo'; 'mo' = 'mo'
    'years' = 'y'; 'year' = 'y'; 'yrs' = 'y'; 'yr' = 'y'; 'y' = 'y'
    'decades' = 'dec'; 'decade' = 'dec'
}

# Time zone abbreviations, region names and cities mapped to Windows time zone IDs (these IDs
# exist on every Windows 11 machine and work in both Windows PowerShell and PowerShell 7).
# Abbreviations map to the region's zone, so daylight saving time is applied automatically
# ("EST" in July is treated as Eastern time, i.e. UTC-4).
$script:TzAliasSource = [ordered]@{
    'Local'                          = 'local|local time'
    'UTC'                            = 'utc|gmt|zulu|universal'
    'Eastern Standard Time'          = 'est|edt|et|eastern|us eastern|new york|nyc|boston|miami|atlanta|washington dc|philadelphia|detroit|toronto|montreal|ottawa'
    'Central Standard Time'          = 'cst|cdt|ct|central|us central|chicago|dallas|houston|austin|minneapolis|new orleans|st louis|kansas city|nashville|winnipeg|san antonio'
    'Mountain Standard Time'         = 'mst|mdt|mt|mountain|us mountain|denver|salt lake city|boise|calgary|edmonton|albuquerque'
    'US Mountain Standard Time'      = 'arizona|phoenix|tucson'
    'Pacific Standard Time'          = 'pst|pdt|pt|pacific|us pacific|los angeles|san francisco|seattle|portland|las vegas|san diego|san jose|vancouver'
    'Alaskan Standard Time'          = 'akst|akdt|alaska|anchorage|juneau'
    'Hawaiian Standard Time'         = 'hst|hawaii|honolulu'
    'Atlantic Standard Time'         = 'ast|adt|atlantic|halifax'
    'Newfoundland Standard Time'     = 'nst|ndt|newfoundland|st johns'
    'SA Western Standard Time'       = 'puerto rico|la paz|bolivia'
    'GMT Standard Time'              = 'bst|wet|uk|british|london|dublin|lisbon|edinburgh|manchester|ireland|portugal'
    'Greenwich Standard Time'        = 'reykjavik|iceland'
    'W. Europe Standard Time'        = 'cet|cest|central european|central europe|berlin|amsterdam|rome|vienna|zurich|stockholm|oslo|frankfurt|munich|milan|germany|italy|netherlands|switzerland|austria|sweden|norway'
    'Romance Standard Time'          = 'paris|madrid|brussels|copenhagen|barcelona|france|spain|belgium|denmark'
    'Central European Standard Time' = 'warsaw|zagreb|sarajevo|poland'
    'Central Europe Standard Time'   = 'prague|budapest|belgrade|bratislava|czechia|hungary'
    'GTB Standard Time'              = 'eet|eest|eastern european|athens|bucharest|greece|romania'
    'FLE Standard Time'              = 'helsinki|kyiv|kiev|riga|tallinn|vilnius|sofia|finland|ukraine'
    'Israel Standard Time'           = 'israel|jerusalem|tel aviv'
    'Turkey Standard Time'           = 'trt|istanbul|ankara|turkey'
    'Russian Standard Time'          = 'msk|moscow|st petersburg|saint petersburg'
    'Egypt Standard Time'            = 'cairo|egypt'
    'South Africa Standard Time'     = 'sast|johannesburg|cape town|south africa'
    'E. Africa Standard Time'        = 'nairobi|kenya'
    'W. Central Africa Standard Time' = 'lagos|nigeria'
    'Morocco Standard Time'          = 'casablanca|morocco'
    'Arabian Standard Time'          = 'gst|dubai|abu dhabi|uae'
    'Arab Standard Time'             = 'riyadh|kuwait|qatar|doha|saudi arabia'
    'Iran Standard Time'             = 'irst|tehran|iran'
    'Pakistan Standard Time'         = 'pkt|karachi|islamabad|lahore|pakistan'
    'India Standard Time'            = 'ist|india|mumbai|delhi|new delhi|kolkata|calcutta|bangalore|bengaluru|chennai|hyderabad'
    'Nepal Standard Time'            = 'npt|kathmandu|nepal'
    'Bangladesh Standard Time'       = 'dhaka|bangladesh'
    'SE Asia Standard Time'          = 'ict|bangkok|jakarta|hanoi|ho chi minh|thailand|vietnam'
    'Singapore Standard Time'        = 'sgt|singapore|kuala lumpur|manila|philippines|malaysia'
    'China Standard Time'            = 'hkt|beijing|shanghai|shenzhen|guangzhou|hong kong|china'
    'Taipei Standard Time'           = 'taipei|taiwan'
    'Tokyo Standard Time'            = 'jst|tokyo|osaka|kyoto|japan'
    'Korea Standard Time'            = 'kst|seoul|korea|south korea'
    'W. Australia Standard Time'     = 'awst|perth'
    'Cen. Australia Standard Time'   = 'acst|acdt|adelaide'
    'AUS Central Standard Time'      = 'darwin'
    'E. Australia Standard Time'     = 'brisbane|queensland'
    'AUS Eastern Standard Time'      = 'aest|aedt|sydney|melbourne|canberra'
    'Tasmania Standard Time'         = 'hobart|tasmania'
    'New Zealand Standard Time'      = 'nzst|nzdt|auckland|wellington|new zealand'
    'E. South America Standard Time' = 'brt|sao paulo|rio de janeiro|brasilia|brazil'
    'Argentina Standard Time'        = 'buenos aires|argentina'
    'SA Pacific Standard Time'       = 'bogota|lima|colombia|peru'
    'Pacific SA Standard Time'       = 'santiago|chile'
    'Venezuela Standard Time'        = 'caracas|venezuela'
    'Central Standard Time (Mexico)' = 'mexico city|guadalajara|mexico'
}

#endregion

#region Small helpers --------------------------------------------------------------------------

function New-Regex {
    <# Creates a case-insensitive, culture-invariant regular expression. #>
    param([Parameter(Mandatory)][string] $Pattern)
    [regex]::new($Pattern, $script:RxOptions)
}

function Join-Alternation {
    <# Builds a regex alternation from literal words, longest first, allowing flexible spaces. #>
    param([Parameter(Mandatory)][string[]] $Word)
    $escaped = $Word | Sort-Object -Property Length -Descending | ForEach-Object {
        [regex]::Escape($_).Replace('\ ', '\s+')
    }
    $escaped -join '|'
}

function Get-NowUtc {
    <# Returns the current UTC time truncated to whole seconds (keeps results tidy). #>
    $now = [DateTime]::UtcNow
    [DateTime]::new($now.Ticks - ($now.Ticks % [TimeSpan]::TicksPerSecond), [DateTimeKind]::Utc)
}

function Remove-RegexMatch {
    <# Blanks out a match with spaces so the indexes of later text do not move. #>
    param([string] $Text, [System.Text.RegularExpressions.Match] $Match)
    $Text.Remove($Match.Index, $Match.Length).Insert($Match.Index, (' ' * $Match.Length))
}

#endregion

#region Lookup initialisation ------------------------------------------------------------------

function Initialize-Lookup {
    <#
        Builds the month/day name maps (English plus the current culture's names) and compiles
        every regular expression the parser uses. Called once when the script loads.
    #>
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $dtf = $culture.DateTimeFormat

    $reserved = @{}
    foreach ($k in $script:UnitMap.Keys) { $reserved[$k] = $true }
    foreach ($k in $script:NumberWords.Keys) { $reserved[$k] = $true }

    # Month names -> month number.
    $months = @{}
    $english = 'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august',
               'september', 'october', 'november', 'december'
    for ($i = 0; $i -lt 12; $i++) {
        $months[$english[$i]] = $i + 1
        $months[$english[$i].Substring(0, 3)] = $i + 1
    }
    $months['sept'] = 9
    for ($i = 0; $i -lt 12; $i++) {
        foreach ($name in @($dtf.MonthNames[$i], $dtf.AbbreviatedMonthNames[$i],
                            $dtf.MonthGenitiveNames[$i], $dtf.AbbreviatedMonthGenitiveNames[$i])) {
            $key = "$name".Trim().TrimEnd('.').ToLowerInvariant()
            if ($key.Length -ge 3 -and -not $months.ContainsKey($key) -and -not $reserved.ContainsKey($key)) {
                $months[$key] = $i + 1
            }
        }
    }

    # Day names -> [int][DayOfWeek].
    $days = @{
        'sunday' = 0; 'sun' = 0
        'monday' = 1; 'mon' = 1
        'tuesday' = 2; 'tue' = 2; 'tues' = 2
        'wednesday' = 3; 'wed' = 3; 'weds' = 3
        'thursday' = 4; 'thu' = 4; 'thur' = 4; 'thurs' = 4
        'friday' = 5; 'fri' = 5
        'saturday' = 6; 'sat' = 6
    }
    for ($i = 0; $i -lt 7; $i++) {
        foreach ($name in @($dtf.DayNames[$i], $dtf.AbbreviatedDayNames[$i])) {
            $key = "$name".Trim().TrimEnd('.').ToLowerInvariant()
            if ($key.Length -ge 3 -and -not $days.ContainsKey($key) -and -not $months.ContainsKey($key) -and -not $reserved.ContainsKey($key)) {
                $days[$key] = $i
            }
        }
    }
    $script:MonthMap = $months
    $script:DayMap = $days

    # Time zone aliases -> Windows ID.
    $tzMap = @{}
    foreach ($id in $script:TzAliasSource.Keys) {
        foreach ($alias in ($script:TzAliasSource[$id] -split '\|')) { $tzMap[$alias] = $id }
    }
    $script:TzAliasMap = $tzMap

    # Numeric date order for ambiguous dates like 5/7, taken from the system's short date
    # pattern: d before M means day-first (DD/MM), otherwise month-first (MM/DD).
    $pattern = $dtf.ShortDatePattern
    $script:DayFirst = ($pattern.IndexOf('d') -ge 0 -and $pattern.IndexOf('M') -ge 0 -and
                        $pattern.IndexOf('d') -lt $pattern.IndexOf('M'))

    $mon  = Join-Alternation -Word @($months.Keys)
    $dow  = Join-Alternation -Word @($days.Keys)
    $unit = Join-Alternation -Word @($script:UnitMap.Keys)
    $numw = Join-Alternation -Word @($script:NumberWords.Keys)

    # --- Durations ("3 days", "1h30m", "two weeks and a day") ---
    $item = '(?:(?<n>\d+(?:\.\d+)?|\.\d+)\s*|\b(?<w>NUMW)\s+)(?<u>UNIT)(?![a-z])'.Replace('NUMW', $numw).Replace('UNIT', $unit)
    $list = $item + '(?:\s*(?:and\s+|&\s*)?' + $item + ')*'
    $script:RxDurItem  = New-Regex $item
    $script:RxDurLead  = New-Regex ('^(?:(?<pre>in|\+|-)\s*)?(?<dur>' + $list + ')(?:\s+(?<dir>from|after|before|prior\s+to|ago|later|earlier|hence|back)\b)?\s*(?<rest>.*)$')
    $script:RxDurTrail = New-Regex ('^(?<anchor>.+?)\s*(?<op>\+|-|\bplus\b|\bminus\b)\s*(?<dur>' + $list + ')$')
    $script:RxAndHalf  = New-Regex ('(?<n>\d+(?:\.\d+)?|\b(?:NUMW))\s+(?<u>UNIT)\s+and\s+a\s+half\b'.Replace('NUMW', $numw).Replace('UNIT', $unit))

    # --- Time zones ---
    $script:RxTzUtcOffset   = New-Regex '\b(?:utc|gmt)\s*(?<sign>[+-])\s*(?<h>\d{1,2})(?::?(?<m>\d{2}))?(?!\d)'
    $script:RxTzTrailOffset = New-Regex '(?<=(?:\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?|[ap]\.?m\.?)\s?)(?<sign>[+-])(?<h>0\d|1[0-4]):?(?<m>[0-5]\d)$'
    $script:RxTzZulu        = New-Regex '(?<=\d)z\b'
    $script:RxTzIana        = New-Regex '\b[a-z]+(?:[_-][a-z]+)*/[a-z]+(?:[_-][a-z]+)*(?:/[a-z]+(?:[_-][a-z]+)*)?\b'
    $script:RxTzAlias       = New-Regex ('(?:\bin\s+)?\b(?<tz>' + (Join-Alternation -Word @($tzMap.Keys)) + ')\b(?:\s+time\b)?')

    # --- Dates ---
    $script:RxNow       = New-Regex '\b(?:right\s+)?now\b'
    $script:RxRelDay    = New-Regex '\b(?<w>(?:the\s+)?day\s+after\s+tomorrow|(?:the\s+)?day\s+before\s+yesterday|tomorrow|tomorow|tmrw|tmr|yesterday|today|tonight)\b'
    $script:RxIsoDate   = New-Regex '(?<![\d/.-])(?<y>\d{4})[-/.](?<mo>\d{1,2})[-/.](?<d>\d{1,2})(?![\d/.-])'
    $script:RxNumDate3  = New-Regex '(?<![\d/.:-])(?<a>\d{1,2})(?<sep>[/.-])(?<b>\d{1,2})\k<sep>(?<y>\d{4}|\d{2})(?![\d/.:-])'
    $script:RxDotDate   = New-Regex '(?<![\d/.:-])(?<a>\d{1,2})\.(?<b>\d{1,2})\.(?!\d)'
    $script:RxNumDate2  = New-Regex '(?<![\d/.:-])(?<a>\d{1,2})(?<sep>[/-])(?<b>\d{1,2})(?![\d/.:-])(?!\s*(?:[ap]\.?m\.?(?![a-z])|o''?clock))'
    $script:RxMonDay    = New-Regex ('\b(?<mon>MON)\.?\s+(?<d>\d{1,2})(?:st|nd|rd|th)?(?![\d:])(?!\s*(?:[ap]\.?m\.?(?![a-z])|o''?clock|h(?:ours?|rs?)?\b))(?:\s+(?<y>\d{4}))?(?!\d)'.Replace('MON', $mon))
    $script:RxDayMon    = New-Regex ('(?<![\d:.])\b(?<d>\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(?<mon>MON)\b\.?(?:\s+(?<y>\d{4}))?(?!\d)'.Replace('MON', $mon))
    $script:RxMonOnly   = New-Regex ('\b(?<mon>MON)\b\.?(?:\s+(?<y>\d{4}))?(?!\d)'.Replace('MON', $mon))
    $script:RxOrdinal   = New-Regex '\b(?:the\s+)?(?<d>\d{1,2})(?:st|nd|rd|th)\b'
    $script:RxWeekdayA  = New-Regex ('\b(?<wk>next|last|this)\s+week(?:''s)?\s+(?:on\s+)?(?<dow>DOW)\b'.Replace('DOW', $dow))
    $script:RxWeekdayB  = New-Regex ('\b(?:(?<mod>next|last|this|coming|previous|past)\s+)?(?<dow>DOW)\b(?:\s+(?:of\s+)?(?<wk>next|last|this)\s+week\b)?'.Replace('DOW', $dow))
    $script:RxAfterNext = New-Regex '\b(?:the\s+)?(?<unit>week|month|year)\s+after\s+next\b'
    $script:RxRelPeriod = New-Regex '\b(?<mod>next|last|this|previous|past|coming)\s+(?<unit>week|month|year|fortnight|decade)\b'

    # --- Times ---
    $script:RxOClock    = New-Regex '(?<h>\d{1,2})\s*o''?clock\b'
    $script:RxNoon      = New-Regex '\b(?:12\s*)?(?:noon|midday)\b'
    $script:RxMidnight  = New-Regex '\b(?:12\s*)?midnight\b'
    $script:RxEod       = New-Regex '\b(?:eod|cob|close\s+of\s+business|end\s+of\s+(?:the\s+)?business\s+day)\b'
    $script:RxTimeWord  = New-Regex '(?:(?<![\d:])(?<h>\d{1,2})(?::(?<mi>\d{2}))?\s+)?(?:in\s+the\s+|this\s+|at\s+)?\b(?<w>morning|afternoon|evening|night)\b'
    $script:RxClock     = New-Regex '(?<![\d:/.])(?<h>\d{1,2})(?:(?<sep>[:.])(?<mi>\d{2}))?(?::(?<s>\d{2})(?:[.,](?<f>\d{1,7}))?)?\s*(?<ap>a\.?m\.?|p\.?m\.?|a|p)?(?![a-z\d])'
    $script:RxFiller    = New-Regex '\b(?:at|on|of|the|and|by|around|about|for|in)\b|[@.!?;:,]'
}

#endregion

#region Time zone handling ---------------------------------------------------------------------

function New-OffsetTimeZone {
    <# Creates a fixed-offset time zone such as UTC+05:30. #>
    param([string] $Sign, [int] $Hours, [int] $Minutes)
    if ($Minutes -gt 59) { throw [System.ArgumentException]::new("'$Minutes' is not a valid number of minutes in a UTC offset.") }
    $total = $Hours * 60 + $Minutes
    if ($total -gt 14 * 60) { throw [System.ArgumentException]::new("UTC offsets range from -14:00 to +14:00; $Sign$Hours is out of range.") }
    if ($total -eq 0) { return [TimeZoneInfo]::Utc }
    if ($Sign -eq '-') { $total = -$total }
    $name = 'UTC{0}{1:00}:{2:00}' -f $Sign, $Hours, $Minutes
    [TimeZoneInfo]::CreateCustomTimeZone($name, [TimeSpan]::FromMinutes($total), $name, $name)
}

function Get-TimeZoneById {
    <# Returns a TimeZoneInfo for a Windows ID ('UTC' and 'Local' are special), or $null. #>
    param([string] $Id)
    if ($Id -eq 'UTC') { return [TimeZoneInfo]::Utc }
    if ($Id -eq 'Local') { return [TimeZoneInfo]::Local }
    try { [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch { $null }
}

function Resolve-IanaTimeZone {
    <#
        Resolves an IANA zone name such as america/new_york. PowerShell 7 can usually look these
        up directly; Windows PowerShell falls back to the city alias table.
    #>
    param([string] $Name)
    $title = (($Name -split '/') | ForEach-Object {
        (($_ -split '_') | ForEach-Object { if ($_.Length) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) } }) -join '_'
    }) -join '/'
    foreach ($candidate in @($title, $Name)) {
        try { return [TimeZoneInfo]::FindSystemTimeZoneById($candidate) } catch { Write-Debug "No zone '$candidate'" }
    }
    $method = [TimeZoneInfo].GetMethod('TryConvertIanaIdToWindowsId', [type[]]@([string], [string].MakeByRefType()))
    if ($null -ne $method) {
        $invokeArgs = [object[]]@($title, $null)
        if ($method.Invoke($null, $invokeArgs)) {
            $zone = Get-TimeZoneById -Id ([string]$invokeArgs[1])
            if ($null -ne $zone) { return $zone }
        }
    }
    $city = (($Name -split '/')[-1]) -replace '[_-]', ' '
    if ($script:TzAliasMap.ContainsKey($city)) { return Get-TimeZoneById -Id $script:TzAliasMap[$city] }
    $null
}

function Initialize-WindowsZoneIndex {
    <# Indexes the system's own zone names ("Pacific Standard Time", "Eastern Daylight Time"). #>
    if ($null -ne $script:WinZoneRegex) { return }
    $map = @{}
    foreach ($zone in [TimeZoneInfo]::GetSystemTimeZones()) {
        foreach ($name in @($zone.Id, $zone.StandardName, $zone.DaylightName)) {
            $key = "$name".Trim().ToLowerInvariant()
            if ($key.Length -gt 4 -and $key -notmatch '^utc[+-]' -and -not $map.ContainsKey($key)) { $map[$key] = $zone }
        }
    }
    $script:WinZoneMap = $map
    $script:WinZoneRegex = New-Regex ('(?:\bin\s+)?(?<![a-z])(?<tz>' + (Join-Alternation -Word @($map.Keys)) + ')(?![a-z])')
}

function Find-TimeZoneInText {
    <#
        Looks for a time zone in normalised text and removes it.
        Returns @{ Zone = [TimeZoneInfo] or $null; Text = the remaining text }.
    #>
    param([string] $Text)

    $found = $null
    $match = $script:RxTzUtcOffset.Match($Text)
    if (-not $match.Success) { $match = $script:RxTzTrailOffset.Match($Text) }
    if ($match.Success) {
        $minutes = 0
        if ($match.Groups['m'].Success) { $minutes = [int]$match.Groups['m'].Value }
        $found = New-OffsetTimeZone -Sign $match.Groups['sign'].Value -Hours ([int]$match.Groups['h'].Value) -Minutes $minutes
    }
    if ($null -eq $found) {
        $match = $script:RxTzZulu.Match($Text)
        if ($match.Success) { $found = [TimeZoneInfo]::Utc }
    }
    if ($null -eq $found) {
        $match = $script:RxTzIana.Match($Text)
        if ($match.Success) {
            $found = Resolve-IanaTimeZone -Name $match.Value
            if ($null -eq $found) { throw [System.ArgumentException]::new("Unknown time zone '$($match.Value)'.") }
        }
    }
    if ($null -eq $found) {
        Initialize-WindowsZoneIndex
        $match = $script:WinZoneRegex.Match($Text)
        if ($match.Success) { $found = $script:WinZoneMap[($match.Groups['tz'].Value -replace '\s+', ' ')] }
    }
    if ($null -eq $found) {
        $match = $script:RxTzAlias.Match($Text)
        if ($match.Success) {
            $id = $script:TzAliasMap[($match.Groups['tz'].Value -replace '\s+', ' ')]
            $found = Get-TimeZoneById -Id $id
            if ($null -eq $found) { throw [System.ArgumentException]::new("The time zone '$id' is not available on this computer.") }
        }
    }
    if ($null -eq $found) { return @{ Zone = $null; Text = $Text } }

    $rest = (Remove-RegexMatch -Text $Text -Match $match) -replace '\s+', ' '
    $rest = ($rest.Trim() -replace '\s+(?:in|at)$', '').Trim()
    @{ Zone = $found; Text = $rest }
}

function ConvertTo-UtcTime {
    <#
        Converts a wall-clock time in a zone to UTC. With -Strict, a time that does not exist
        (skipped by a daylight saving change) is an error; otherwise it is moved forward an hour.
    #>
    param([datetime] $Wall, [TimeZoneInfo] $Zone, [switch] $Strict)
    $w = [DateTime]::SpecifyKind($Wall, [DateTimeKind]::Unspecified)
    if ($Zone.IsInvalidTime($w)) {
        if ($Strict) {
            throw [System.ArgumentException]::new(('{0} does not exist on {1} in {2}; the clocks skip that hour for daylight saving time.' -f
                $w.ToString('t', [System.Globalization.CultureInfo]::CurrentCulture),
                $w.ToString('d', [System.Globalization.CultureInfo]::CurrentCulture), $Zone.StandardName))
        }
        $w = $w.AddHours(1)
    }
    [TimeZoneInfo]::ConvertTimeToUtc($w, $Zone)
}

function Get-ZoneLabel {
    <# Returns a readable zone label such as "Eastern Daylight Time (UTC-04:00)". #>
    param([TimeZoneInfo] $Zone, [datetime] $Utc)
    if ($Zone.Id -eq [TimeZoneInfo]::Utc.Id) { return 'UTC' }
    if ($Zone.Id -match '^UTC[+-]\d') { return $Zone.Id }
    $u = [DateTime]::SpecifyKind($Utc, [DateTimeKind]::Utc)
    $offset = $Zone.GetUtcOffset($u)
    $wall = [TimeZoneInfo]::ConvertTimeFromUtc($u, $Zone)
    $name = $Zone.StandardName
    if ($Zone.IsDaylightSavingTime($wall)) { $name = $Zone.DaylightName }
    $sign = '+'
    if ($offset -lt [TimeSpan]::Zero) { $sign = '-' }
    '{0} (UTC{1}{2:hh\:mm})' -f $name, $sign, $offset
}

#endregion

#region Free-form date parser ------------------------------------------------------------------

function ConvertTo-NormalizedText {
    <# Lower-cases the input and smooths out punctuation the parser does not care about. #>
    param([string] $Text)
    $t = $Text.ToLowerInvariant()
    $t = $t.Replace([string][char]0x2019, "'").Replace([string][char]0x2013, '-').Replace([string][char]0x2014, '-')
    $t = $t -replace '(?<=\d)t(?=\d)', ' '      # ISO 8601 date/time separator
    $t = $t -replace ',', ' '
    $t = $t -replace '@', ' at '
    $t = $t -replace '\s+', ' '
    $t.Trim().TrimEnd('!', '?', ';').Trim()
}

function Get-DurationPart {
    <#
        Adds up a duration such as "3 months and 7 days" or "1h30m".
        Returns @{ Months; Days; Ticks } - calendar parts are kept separate from elapsed time so
        "1 month" respects month lengths and "3 hours" respects daylight saving changes.
    #>
    param([string] $Text)
    $months = 0
    $days = 0
    [double] $ticks = 0
    foreach ($m in $script:RxDurItem.Matches($Text)) {
        if ($m.Groups['n'].Success) {
            $value = [double]::Parse($m.Groups['n'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            $value = [double]$script:NumberWords[($m.Groups['w'].Value -replace '\s+', ' ')]
        }
        $unit = $script:UnitMap[$m.Groups['u'].Value]
        $dayCount = $null
        switch ($unit) {
            's'   { $ticks += $value * [TimeSpan]::TicksPerSecond }
            'min' { $ticks += $value * [TimeSpan]::TicksPerMinute }
            'h'   { $ticks += $value * [TimeSpan]::TicksPerHour }
            'd'   { $dayCount = $value }
            'w'   { $dayCount = $value * 7 }
            'fn'  { $dayCount = $value * 14 }
            'mo'  { $months += Assert-WholeNumber -Value $value -What $m.Value }
            'y'   { $months += Assert-WholeNumber -Value ($value * 12) -What $m.Value }
            'dec' { $months += Assert-WholeNumber -Value ($value * 120) -What $m.Value }
        }
        if ($null -ne $dayCount) {
            $whole = [Math]::Truncate($dayCount)
            $days += $whole
            $ticks += ($dayCount - $whole) * [TimeSpan]::TicksPerDay
        }
    }
    @{ Months = [int]$months; Days = [int]$days; Ticks = [long][Math]::Round($ticks) }
}

function Assert-WholeNumber {
    <# Months and years have no fixed length, so fractions of them are rejected. #>
    param([double] $Value, [string] $What)
    if ($Value -ne [Math]::Floor($Value)) {
        throw [System.ArgumentException]::new("Fractional months can't be calculated exactly ('$What'). Use days or weeks instead, e.g. '45 days'.")
    }
    [int]$Value
}

function Add-Duration {
    <# Applies a duration to a wall-clock time: calendar parts on the calendar, the rest as elapsed time. #>
    param([datetime] $Wall, [hashtable] $Part, [int] $Sign, [TimeZoneInfo] $Zone)
    $w = $Wall.AddMonths($Sign * $Part.Months).AddDays($Sign * $Part.Days)
    if ($Part.Ticks -ne 0) {
        $utc = (ConvertTo-UtcTime -Wall $w -Zone $Zone).AddTicks($Sign * $Part.Ticks)
        $w = [DateTime]::SpecifyKind([TimeZoneInfo]::ConvertTimeFromUtc($utc, $Zone), [DateTimeKind]::Unspecified)
    }
    $w
}

function Read-DateExpression {
    <#
        Parses an expression (without its time zone) relative to $Ref, the current wall-clock
        time in the target zone. Handles duration forms ("in 3 days", "2 hours ago",
        "3 months and 7 days from today", "friday + 2h") and hands everything else to
        Read-DateComponent. Returns @{ Wall; HasDate; TimeOnly; BareWeekday }.
    #>
    param([string] $Text, [datetime] $Ref, [TimeZoneInfo] $Zone, [System.Collections.Generic.List[string]] $Notes)

    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -eq 0) { throw [System.FormatException]::new('Expected a date or time.') }

    # Friendlier spellings of fractions: "half an hour", "a quarter of an hour", "an hour and a half".
    $t = $t -replace '\ba\s+half\s+(?=(?:hour|day|minute|week|second)s?\b)', '0.5 '
    $t = $t -replace '\bhalf\s+(?:an?\s+)?(?=(?:hour|day|minute|week|second)s?\b)', '0.5 '
    $t = $t -replace '\b(?:a\s+)?quarter\s+(?:of\s+)?an\s+hour\b', '15 minutes'
    $t = $script:RxAndHalf.Replace($t, [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $n = $m.Groups['n'].Value
        if ($n -match '^[\d.]+$') { $v = [double]::Parse($n, [System.Globalization.CultureInfo]::InvariantCulture) }
        else { $v = [double]$script:NumberWords[($n -replace '\s+', ' ')] }
        '{0} {1}' -f ($v + 0.5).ToString([System.Globalization.CultureInfo]::InvariantCulture), $m.Groups['u'].Value
    })

    # Leading duration: "in 3 days", "-2h", "3 days ago", "a week from tomorrow at noon", "2 days 5pm".
    $m = $script:RxDurLead.Match($t)
    if ($m.Success) {
        $part = Get-DurationPart -Text $m.Groups['dur'].Value
        $dir = ($m.Groups['dir'].Value -replace '\s+', ' ')
        $rest = $m.Groups['rest'].Value.Trim()
        $sign = 1
        if ($m.Groups['pre'].Value -eq '-') { $sign = -1 }
        $anchorText = $null
        if ($dir -in 'from', 'after') { $anchorText = $rest; $rest = '' }
        elseif ($dir -in 'before', 'prior to') { $sign = -1; $anchorText = $rest; $rest = '' }
        elseif ($dir -in 'ago', 'earlier', 'back') { $sign = -1 }

        $base = $Ref
        if ($null -ne $anchorText) {
            if ($anchorText -eq '') { throw [System.FormatException]::new("Expected a date after '$dir', e.g. '3 days $dir tomorrow'.") }
            $base = (Read-DateExpression -Text $anchorText -Ref $Ref -Zone $Zone -Notes $Notes).Wall
        }
        $wall = Add-Duration -Wall $base -Part $part -Sign $sign -Zone $Zone
        if ($rest -ne '') {
            $timePart = Read-DateComponent -Text $rest -Ref $wall -Notes $Notes
            if ($timePart.HasDate) {
                throw [System.FormatException]::new("Only a time can follow '$($m.Groups['dur'].Value.Trim())', e.g. 'in 2 days at 5pm'.")
            }
            $wall = $wall.Date + $timePart.Wall.TimeOfDay
        }
        return @{ Wall = $wall; HasDate = $true; TimeOnly = $false; BareWeekday = $false }
    }

    # Trailing duration: "tomorrow 9am + 90 minutes", "friday minus 2 days".
    $m = $script:RxDurTrail.Match($t)
    if ($m.Success) {
        $anchor = Read-DateExpression -Text $m.Groups['anchor'].Value -Ref $Ref -Zone $Zone -Notes $Notes
        $sign = 1
        if ($m.Groups['op'].Value -in '-', 'minus') { $sign = -1 }
        $wall = Add-Duration -Wall $anchor.Wall -Part (Get-DurationPart -Text $m.Groups['dur'].Value) -Sign $sign -Zone $Zone
        return @{ Wall = $wall; HasDate = $true; TimeOnly = $false; BareWeekday = $false }
    }

    Read-DateComponent -Text $t -Ref $Ref -Notes $Notes
}

function Set-ParsedDate {
    <# Records the date part of an expression, rejecting a second, conflicting date. #>
    param([hashtable] $State, [datetime] $Date, [string] $Source, [string] $Kind)
    if ($null -ne $State.Date) {
        throw [System.ArgumentException]::new("Conflicting dates: '$($State.DateSource)' and '$($Source.Trim())'. Use only one.")
    }
    $State.Date = $Date.Date
    $State.DateSource = $Source.Trim()
    $State.DateKind = $Kind
}

function Set-ParsedTime {
    <# Records the time part of an expression, rejecting a second, conflicting time. #>
    param([hashtable] $State, [timespan] $Time, [string] $Source)
    if ($null -ne $State.Time) {
        throw [System.ArgumentException]::new("Conflicting times: '$($State.TimeSource)' and '$($Source.Trim())'. Use only one.")
    }
    $State.Time = $Time
    $State.TimeSource = $Source.Trim()
}

function New-CalendarDate {
    <# Builds a date, explaining exactly what is wrong when it does not exist. #>
    param([int] $Year, [int] $Month, [int] $Day, [string] $Source)
    if ($Year -lt 1 -or $Year -gt 9999) { throw [System.ArgumentException]::new("The year in '$Source' is out of range.") }
    if ($Month -lt 1 -or $Month -gt 12) {
        throw [System.ArgumentException]::new("'$($Source.Trim())' has month $Month, but months go from 1 to 12.")
    }
    $max = [DateTime]::DaysInMonth($Year, $Month)
    if ($Day -lt 1 -or $Day -gt $max) {
        $monthName = [System.Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.GetMonthName($Month)
        throw [System.ArgumentException]::new("$monthName $Year has $max days, so '$($Source.Trim())' is not a valid date.")
    }
    [DateTime]::new($Year, $Month, $Day)
}

function ConvertTo-FullYear {
    <# Turns a two-digit year into a four-digit one using the system calendar's rules. #>
    param([string] $Year)
    if ($Year.Length -le 2) { return [System.Globalization.CultureInfo]::CurrentCulture.Calendar.ToFourDigitYear([int]$Year) }
    [int]$Year
}

function Get-WeekdayDate {
    <#
        Finds a weekday relative to $Today.
          This - the day in the current week (week start comes from the system's culture)
          Next - the next occurrence after today;  Last - the most recent occurrence before today
    #>
    param([datetime] $Today, [int] $Target, [ValidateSet('This', 'Next', 'Last')][string] $Mode)
    $current = [int]$Today.DayOfWeek
    switch ($Mode) {
        'Next' {
            $diff = ($Target - $current + 7) % 7
            if ($diff -eq 0) { $diff = 7 }
            return $Today.Date.AddDays($diff)
        }
        'Last' {
            $diff = ($current - $Target + 7) % 7
            if ($diff -eq 0) { $diff = 7 }
            return $Today.Date.AddDays(-$diff)
        }
        default {
            $first = [int][System.Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.FirstDayOfWeek
            $weekStart = $Today.Date.AddDays(-(($current - $first + 7) % 7))
            return $weekStart.AddDays(($Target - $first + 7) % 7)
        }
    }
}

function Read-DateComponent {
    <#
        Parses a plain date/time expression - no durations, no time zone - such as
        "next friday 5pm", "may 7th 2027 at noon", "5/7", "tomorrow morning" or "17:30".
        Each recognised piece is blanked out of the text; anything left over is an error.
        Returns @{ Wall; HasDate; TimeOnly; BareWeekday }.
    #>
    param([string] $Text, [datetime] $Ref, [System.Collections.Generic.List[string]] $Notes)

    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $s = ' ' + ($script:RxOClock.Replace($Text, '${h}:00')) + ' '
    $st = @{
        Date = $null; DateSource = $null; DateKind = $null; KeepTime = $false
        Time = $null; TimeSource = $null; DefaultTime = $null
        BareWeekday = $false; Tonight = $false; Midnight = $false; DayShift = 0
    }

    # "now"
    foreach ($m in $script:RxNow.Matches($s)) {
        Set-ParsedDate -State $st -Date $Ref -Source $m.Value -Kind 'relative'
        Set-ParsedTime -State $st -Time $Ref.TimeOfDay -Source $m.Value
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # today, tomorrow, yesterday, tonight, the day after tomorrow, ...
    foreach ($m in $script:RxRelDay.Matches($s)) {
        $word = $m.Groups['w'].Value -replace '\s+', ' '
        $offset = 0
        if ($word -match 'after tomorrow') { $offset = 2 }
        elseif ($word -match 'before yesterday') { $offset = -2 }
        elseif ($word -match '^(tomorrow|tomorow|tmrw|tmr)$') { $offset = 1 }
        elseif ($word -eq 'yesterday') { $offset = -1 }
        elseif ($word -eq 'tonight') { $st.Tonight = $true }
        Set-ParsedDate -State $st -Date $Ref.Date.AddDays($offset) -Source $m.Value -Kind 'relative'
        $st.KeepTime = $true
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # Calendar dates. ISO (year first) is unambiguous; other numeric dates follow the system's
    # day/month order, unless the numbers only make sense the other way round.
    foreach ($m in $script:RxIsoDate.Matches($s)) {
        $date = New-CalendarDate -Year ([int]$m.Groups['y'].Value) -Month ([int]$m.Groups['mo'].Value) -Day ([int]$m.Groups['d'].Value) -Source $m.Value
        Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'calendar'
        $s = Remove-RegexMatch -Text $s -Match $m
    }
    foreach ($rx in @($script:RxNumDate3, $script:RxDotDate, $script:RxNumDate2)) {
        foreach ($m in $rx.Matches($s)) {
            $a = [int]$m.Groups['a'].Value
            $b = [int]$m.Groups['b'].Value
            $year = $Ref.Year
            if ($m.Groups['y'].Success) { $year = ConvertTo-FullYear -Year $m.Groups['y'].Value }
            $dayFirst = $script:DayFirst -or ($rx -eq $script:RxDotDate)
            if (-not $dayFirst -and $a -gt 12 -and $b -le 12) {
                $dayFirst = $true
                $Notes.Add("Read '$($m.Value.Trim())' as day/month because $a can't be a month.")
            }
            elseif ($dayFirst -and $rx -ne $script:RxDotDate -and $b -gt 12 -and $a -le 12) {
                $dayFirst = $false
                $Notes.Add("Read '$($m.Value.Trim())' as month/day because $b can't be a month.")
            }
            if ($dayFirst) { $day = $a; $month = $b } else { $month = $a; $day = $b }
            $date = New-CalendarDate -Year $year -Month $month -Day $day -Source $m.Value
            Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'calendar'
            $s = Remove-RegexMatch -Text $s -Match $m
        }
    }
    foreach ($rx in @($script:RxMonDay, $script:RxDayMon, $script:RxMonOnly)) {
        foreach ($m in $rx.Matches($s)) {
            $month = $script:MonthMap[($m.Groups['mon'].Value -replace '\s+', ' ')]
            $day = 1
            if ($m.Groups['d'].Success) { $day = [int]$m.Groups['d'].Value }
            $year = $Ref.Year
            if ($m.Groups['y'].Success) { $year = [int]$m.Groups['y'].Value }
            $date = New-CalendarDate -Year $year -Month $month -Day $day -Source $m.Value
            Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'calendar'
            $s = Remove-RegexMatch -Text $s -Match $m
        }
    }
    foreach ($m in $script:RxOrdinal.Matches($s)) {
        $date = New-CalendarDate -Year $Ref.Year -Month $Ref.Month -Day ([int]$m.Groups['d'].Value) -Source $m.Value
        Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'calendar'
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # Weekdays: "friday", "next friday", "last monday", "friday next week", "next week friday".
    foreach ($rx in @($script:RxWeekdayA, $script:RxWeekdayB)) {
        foreach ($m in $rx.Matches($s)) {
            $target = [int]$script:DayMap[$m.Groups['dow'].Value]
            $mod = ''
            if ($m.Groups['mod'].Success) { $mod = $m.Groups['mod'].Value.ToLowerInvariant() }
            $wk = ''
            if ($m.Groups['wk'].Success) { $wk = $m.Groups['wk'].Value.ToLowerInvariant() }

            if ($wk -eq 'next') { $date = (Get-WeekdayDate -Today $Ref -Target $target -Mode This).AddDays(7) }
            elseif ($wk -eq 'last') { $date = (Get-WeekdayDate -Today $Ref -Target $target -Mode This).AddDays(-7) }
            elseif ($mod -in 'next', 'coming') { $date = Get-WeekdayDate -Today $Ref -Target $target -Mode Next }
            elseif ($mod -in 'last', 'previous', 'past') { $date = Get-WeekdayDate -Today $Ref -Target $target -Mode Last }
            else { $date = Get-WeekdayDate -Today $Ref -Target $target -Mode This }

            if ($st.DateKind -eq 'calendar' -and $mod -eq '' -and $wk -eq '') {
                # A weekday next to an explicit date ("Friday, May 7") only double-checks it.
                if ([int]$st.Date.DayOfWeek -ne $target) {
                    $Notes.Add(('{0} is a {1}, not a {2}.' -f $st.Date.ToString('d', $culture),
                        $culture.DateTimeFormat.GetDayName($st.Date.DayOfWeek),
                        $culture.DateTimeFormat.GetDayName([DayOfWeek]$target)))
                }
            }
            else {
                Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'weekday'
                $st.BareWeekday = ($mod -eq '' -and $wk -eq '')
            }
            $s = Remove-RegexMatch -Text $s -Match $m
        }
    }

    # Relative periods: "next week", "last month", "this year", "the week after next".
    foreach ($m in $script:RxAfterNext.Matches($s)) {
        switch ($m.Groups['unit'].Value.ToLowerInvariant()) {
            'week'  { $date = $Ref.AddDays(14) }
            'month' { $date = $Ref.AddMonths(2) }
            'year'  { $date = $Ref.AddYears(2) }
        }
        Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'relative'
        $st.KeepTime = $true
        $s = Remove-RegexMatch -Text $s -Match $m
    }
    foreach ($m in $script:RxRelPeriod.Matches($s)) {
        $sign = 1
        switch ($m.Groups['mod'].Value.ToLowerInvariant()) {
            'this' { $sign = 0 }
            { $_ -in 'last', 'previous', 'past' } { $sign = -1 }
        }
        switch ($m.Groups['unit'].Value.ToLowerInvariant()) {
            'week'      { $date = $Ref.AddDays(7 * $sign) }
            'fortnight' { $date = $Ref.AddDays(14 * $sign) }
            'month'     { $date = $Ref.AddMonths($sign) }
            'year'      { $date = $Ref.AddYears($sign) }
            'decade'    { $date = $Ref.AddYears(10 * $sign) }
        }
        Set-ParsedDate -State $st -Date $date -Source $m.Value -Kind 'relative'
        $st.KeepTime = $true
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # Named times.
    foreach ($m in $script:RxNoon.Matches($s)) {
        Set-ParsedTime -State $st -Time ([TimeSpan]::FromHours(12)) -Source $m.Value
        $s = Remove-RegexMatch -Text $s -Match $m
    }
    foreach ($m in $script:RxMidnight.Matches($s)) {
        Set-ParsedTime -State $st -Time ([TimeSpan]::Zero) -Source $m.Value
        $st.Midnight = $true
        $s = Remove-RegexMatch -Text $s -Match $m
    }
    foreach ($m in $script:RxEod.Matches($s)) {
        Set-ParsedTime -State $st -Time ([TimeSpan]::FromHours(17)) -Source $m.Value
        $s = Remove-RegexMatch -Text $s -Match $m
    }
    # Parts of the day, optionally with an hour: "tomorrow morning", "7 in the evening".
    foreach ($m in $script:RxTimeWord.Matches($s)) {
        $word = $m.Groups['w'].Value.ToLowerInvariant()
        if ($m.Groups['h'].Success) {
            $h = [int]$m.Groups['h'].Value
            $mi = 0
            if ($m.Groups['mi'].Success) { $mi = [int]$m.Groups['mi'].Value }
            if ($h -gt 12 -or $mi -gt 59) { throw [System.ArgumentException]::new("'$($m.Value.Trim())' is not a valid time.") }
            switch ($word) {
                'morning' { if ($h -eq 12) { $h = 0 } }
                'night'   { if ($h -eq 12) { $h = 0 } elseif ($h -ge 6) { $h += 12 } }
                default   { if ($h -lt 12) { $h += 12 } }
            }
            Set-ParsedTime -State $st -Time ([TimeSpan]::new($h, $mi, 0)) -Source $m.Value
        }
        else {
            $hours = @{ 'morning' = 9; 'afternoon' = 15; 'evening' = 18; 'night' = 21 }
            $st.DefaultTime = [TimeSpan]::FromHours($hours[$word])
        }
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # Clock times: 5pm, 5:30 pm, 17:30, 17:30:15.250, 5.30am, "at 5".
    foreach ($m in $script:RxClock.Matches($s)) {
        $hasColon = $m.Groups['sep'].Success -and $m.Groups['sep'].Value -eq ':'
        $ap = ''
        if ($m.Groups['ap'].Success) { $ap = $m.Groups['ap'].Value.Substring(0, 1).ToLowerInvariant() }
        $atBefore = $s.Substring(0, $m.Index) -match '(?:\bat|@)\s*$'
        if (-not ($hasColon -or $ap -or $atBefore)) { continue }
        if ($m.Groups['sep'].Success -and -not $hasColon -and -not $ap) { continue }

        $h = [int]$m.Groups['h'].Value
        $mi = 0
        if ($m.Groups['mi'].Success) { $mi = [int]$m.Groups['mi'].Value }
        $sec = 0
        if ($m.Groups['s'].Success) { $sec = [int]$m.Groups['s'].Value }
        $frac = 0L
        if ($m.Groups['f'].Success) { $frac = [long]($m.Groups['f'].Value.PadRight(7, '0')) }
        $what = $m.Value.Trim()
        if ($mi -gt 59 -or $sec -gt 59) { throw [System.ArgumentException]::new("'$what' is not a valid time: minutes and seconds go up to 59.") }
        if ($ap) {
            if ($h -lt 1 -or $h -gt 12) { throw [System.ArgumentException]::new("'$what' is not a valid 12-hour time: the hour must be 1-12. For 24-hour times leave out AM/PM.") }
            if ($h -eq 12) { $h = 0 }
            if ($ap -eq 'p') { $h += 12 }
        }
        elseif ($h -eq 24 -and $mi -eq 0 -and $sec -eq 0) {
            $h = 0
            $st.DayShift = 1
        }
        elseif ($h -gt 23) { throw [System.ArgumentException]::new("'$what' is not a valid time: hours go from 0 to 23.") }
        Set-ParsedTime -State $st -Time ([TimeSpan]::new(0, $h, $mi, $sec).Add([TimeSpan]::FromTicks($frac))) -Source $m.Value
        $s = Remove-RegexMatch -Text $s -Match $m
    }

    # Whatever is left must be filler words - or a lone year or hour.
    $left = ($script:RxFiller.Replace($s, ' ') -replace '\s+', ' ').Trim()
    if ($left -match '^\d{4}$' -and $null -eq $st.Date) {
        Set-ParsedDate -State $st -Date (New-CalendarDate -Year ([int]$left) -Month 1 -Day 1 -Source $left) -Source $left -Kind 'calendar'
        $left = ''
    }
    elseif ($left -match '^\d{1,2}$' -and $null -eq $st.Time -and [int]$left -le 24) {
        $h = [int]$left
        if ($h -eq 24) { $h = 0; $st.DayShift = 1 }
        Set-ParsedTime -State $st -Time ([TimeSpan]::FromHours($h)) -Source $left
        $left = ''
    }
    if ($left -ne '') {
        throw [System.FormatException]::new("Didn't understand '$left'.")
    }
    if ($null -eq $st.Date -and $null -eq $st.Time -and $null -eq $st.DefaultTime) {
        throw [System.FormatException]::new("Couldn't find a date or time in '$($Text.Trim())'.")
    }

    # Fill in the defaults: no date = today; no time = midnight for calendar dates and weekdays,
    # or the current time for relative words like "tomorrow" and "next week".
    $timeOnly = $null -eq $st.Date
    $date = $Ref.Date
    if (-not $timeOnly) { $date = $st.Date }
    if ($null -ne $st.Time) { $tod = $st.Time }
    elseif ($null -ne $st.DefaultTime) { $tod = $st.DefaultTime }
    elseif ($st.KeepTime) { $tod = $Ref.TimeOfDay }
    else { $tod = [TimeSpan]::Zero }
    if ($st.Midnight -and $st.Tonight) { $date = $date.AddDays(1) }   # "midnight tonight"
    $date = $date.AddDays($st.DayShift)

    @{
        Wall        = [DateTime]::SpecifyKind($date + $tod, [DateTimeKind]::Unspecified)
        HasDate     = -not $timeOnly
        TimeOnly    = $timeOnly
        BareWeekday = [bool]$st.BareWeekday
    }
}

function ConvertFrom-TimeText {
    <#
        Parses one free-form field. Returns a hashtable describing the outcome:
          Success, Error, Input, Utc, Local, Wall (time in the zone), Zone, ZoneExplicit,
          IsBlank, TimeOnly, BareWeekday, Notes.
        -ShiftDays moves the parsed date (used to resolve "Friday -> Monday" style intervals).
        -DateAnchorUtc gives a time-only input the date of another instant instead of today.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][datetime] $NowUtc,
        [int] $ShiftDays = 0,
        [object] $DateAnchorUtc = $null   # a UTC [datetime] or $null
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    $result = @{
        Input = "$Text"; Success = $false; Error = $null; Utc = $null; Local = $null; Wall = $null
        Zone = [TimeZoneInfo]::Local; ZoneExplicit = $false; IsBlank = $false
        TimeOnly = $false; BareWeekday = $false; Notes = $notes
    }
    $raw = "$Text".Trim()

    try {
        if ($raw -eq '') {
            $result.IsBlank = $true
            $result.Utc = $NowUtc.AddDays($ShiftDays)
        }
        else {
            $norm = ConvertTo-NormalizedText -Text $raw
            $tz = Find-TimeZoneInText -Text $norm
            if ($null -ne $tz.Zone) { $result.Zone = $tz.Zone; $result.ZoneExplicit = $true }
            $ref = [DateTime]::SpecifyKind([TimeZoneInfo]::ConvertTimeFromUtc($NowUtc, $result.Zone), [DateTimeKind]::Unspecified)
            if ($tz.Text -eq '') {
                $parsed = @{ Wall = $ref; TimeOnly = $false; BareWeekday = $false }   # just a zone: "now in Tokyo"
            }
            else {
                $parsed = Read-DateExpression -Text $tz.Text -Ref $ref -Zone $result.Zone -Notes $notes
            }
            $wall = $parsed.Wall
            if ($parsed.TimeOnly -and $null -ne $DateAnchorUtc) {
                $anchorWall = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind([datetime]$DateAnchorUtc, [DateTimeKind]::Utc), $result.Zone)
                $wall = [DateTime]::SpecifyKind($anchorWall.Date + $wall.TimeOfDay, [DateTimeKind]::Unspecified)
            }
            if ($ShiftDays -ne 0) { $wall = $wall.AddDays($ShiftDays) }
            $result.Utc = ConvertTo-UtcTime -Wall $wall -Zone $result.Zone -Strict
            $result.TimeOnly = [bool]$parsed.TimeOnly
            $result.BareWeekday = [bool]$parsed.BareWeekday
        }
        $result.Success = $true
    }
    catch [System.FormatException] {
        # Our grammar did not recognise the text; give .NET's own parser a try before giving up
        # (it knows formats such as RFC 1123: "Wed, 07 May 2025 10:00:00 GMT").
        $message = $_.Exception.Message
        $dto = [DateTimeOffset]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
        $ok = [DateTimeOffset]::TryParse($raw, [System.Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$dto)
        if (-not $ok) { $ok = [DateTimeOffset]::TryParse($raw, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dto) }
        if ($ok) {
            $result.Utc = $dto.UtcDateTime.AddDays($ShiftDays)
            if ($dto.Offset -ne [TimeZoneInfo]::Local.GetUtcOffset($dto.UtcDateTime)) {
                $sign = '+'
                if ($dto.Offset -lt [TimeSpan]::Zero) { $sign = '-' }
                $result.Zone = New-OffsetTimeZone -Sign $sign -Hours ([Math]::Abs($dto.Offset.Hours)) -Minutes ([Math]::Abs($dto.Offset.Minutes))
                $result.ZoneExplicit = $true
            }
            $result.Success = $true
        }
        else {
            $result.Error = $message
        }
    }
    catch [System.ArgumentException] {
        $result.Error = $_.Exception.Message
    }
    catch {
        $result.Error = "That date is out of range or invalid ($($_.Exception.Message))."
    }

    if ($result.Success) {
        $result.Utc = [DateTime]::SpecifyKind($result.Utc, [DateTimeKind]::Utc)
        $result.Wall = [DateTime]::SpecifyKind([TimeZoneInfo]::ConvertTimeFromUtc($result.Utc, $result.Zone), [DateTimeKind]::Unspecified)
        $result.Local = $result.Utc.ToLocalTime()
    }
    $result
}

#endregion

#region Interval calculation -------------------------------------------------------------------

function Resolve-Interval {
    <#
        Parses both fields and fixes up intervals that run backwards because of missing context:
          - a time-only end ("5pm") uses the start's date when the start has one
          - a time-only end earlier than the start moves to the next day ("10pm" -> "2am")
          - a time-only start later than the end moves to the previous day
          - bare weekdays given backwards ("Friday" -> "Monday") use the previous/next week,
            choosing the arrangement that contains the current moment when possible
        Returns @{ Start; End; Notes }.
    #>
    param([string] $StartText, [string] $EndText, [datetime] $NowUtc)
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $notes = [System.Collections.Generic.List[string]]::new()
    $s = ConvertFrom-TimeText -Text $StartText -NowUtc $NowUtc
    $e = ConvertFrom-TimeText -Text $EndText -NowUtc $NowUtc

    if ($s.Success -and $e.Success) {
        $endAnchor = $null
        if ($e.TimeOnly -and -not $s.IsBlank -and -not $s.TimeOnly) {
            $endAnchor = $s.Utc
            $e2 = ConvertFrom-TimeText -Text $EndText -NowUtc $NowUtc -DateAnchorUtc $endAnchor
            if ($e2.Success) { $e = $e2 }
        }
        if ($e.Utc -lt $s.Utc) {
            if ($e.TimeOnly) {
                $e2 = ConvertFrom-TimeText -Text $EndText -NowUtc $NowUtc -ShiftDays 1 -DateAnchorUtc $endAnchor
                if ($e2.Success -and $e2.Utc -ge $s.Utc) {
                    $e = $e2
                    $notes.Add('The end time is earlier than the start, so it was moved to the next day.')
                }
            }
            elseif ($s.TimeOnly) {
                $s2 = ConvertFrom-TimeText -Text $StartText -NowUtc $NowUtc -ShiftDays -1
                if ($s2.Success -and $s2.Utc -le $e.Utc) {
                    $s = $s2
                    $notes.Add('The start time is later than the end, so it was moved to the previous day.')
                }
            }
            elseif ($s.BareWeekday -or $e.BareWeekday) {
                $options = [System.Collections.Generic.List[hashtable]]::new()
                if ($e.BareWeekday) {
                    $e2 = ConvertFrom-TimeText -Text $EndText -NowUtc $NowUtc -ShiftDays 7
                    if ($e2.Success -and $e2.Utc -ge $s.Utc) {
                        $options.Add(@{ S = $s; E = $e2; Note = ('{0} comes before the start, so the following {0} ({1}) was used.' -f
                            $culture.DateTimeFormat.GetDayName($e2.Wall.DayOfWeek), $e2.Wall.ToString('d', $culture)) })
                    }
                }
                if ($s.BareWeekday) {
                    $s2 = ConvertFrom-TimeText -Text $StartText -NowUtc $NowUtc -ShiftDays -7
                    if ($s2.Success -and $s2.Utc -le $e.Utc) {
                        $options.Add(@{ S = $s2; E = $e; Note = ('{0} comes after the end, so the previous {0} ({1}) was used.' -f
                            $culture.DateTimeFormat.GetDayName($s2.Wall.DayOfWeek), $s2.Wall.ToString('d', $culture)) })
                    }
                }
                if ($options.Count -gt 0) {
                    $pick = $options[0]
                    foreach ($option in $options) {
                        if ($option.S.Utc -le $NowUtc -and $NowUtc -le $option.E.Utc) { $pick = $option; break }
                    }
                    $s = $pick.S
                    $e = $pick.E
                    $notes.Add($pick.Note)
                }
            }
        }
    }
    @{ Start = $s; End = $e; Notes = $notes }
}

function Get-CalendarBreakdown {
    <# Splits the span between two local times into years, months, days, hours, minutes, seconds. #>
    param([datetime] $From, [datetime] $To)
    $months = ($To.Year - $From.Year) * 12 + $To.Month - $From.Month
    if ($months -lt 0) { $months = 0 }
    while ($months -gt 0 -and $From.AddMonths($months) -gt $To) { $months-- }
    $cursor = $From.AddMonths($months)
    $rest = $To.ToUniversalTime() - $cursor.ToUniversalTime()
    if ($rest.Ticks -lt 0) { $rest = [TimeSpan]::Zero }
    [pscustomobject]@{
        Years   = [int][Math]::Floor($months / 12)
        Months  = [int]($months % 12)
        Days    = $rest.Days
        Hours   = $rest.Hours
        Minutes = $rest.Minutes
        Seconds = $rest.Seconds
    }
}

function Format-HumanDuration {
    <# "1 year, 2 months, and 3 days" - zero parts are left out. #>
    param($Breakdown)
    $units = [ordered]@{
        year = $Breakdown.Years; month = $Breakdown.Months; day = $Breakdown.Days
        hour = $Breakdown.Hours; minute = $Breakdown.Minutes; second = $Breakdown.Seconds
    }
    $parts = @(foreach ($unit in $units.Keys) {
        $value = $units[$unit]
        if ($value -eq 1) { "1 $unit" } elseif ($value -gt 1) { "$value ${unit}s" }
    })
    switch ($parts.Count) {
        0 { '0 seconds' }
        1 { $parts[0] }
        2 { '{0} and {1}' -f $parts[0], $parts[1] }
        default { ($parts[0..($parts.Count - 2)] -join ', ') + ', and ' + $parts[-1] }
    }
}

function Format-CompactDuration {
    <# "1y 2mo 3d 4h 5m 6s" - zero parts are left out. #>
    param($Breakdown)
    $parts = @()
    if ($Breakdown.Years) { $parts += "$($Breakdown.Years)y" }
    if ($Breakdown.Months) { $parts += "$($Breakdown.Months)mo" }
    if ($Breakdown.Days) { $parts += "$($Breakdown.Days)d" }
    if ($Breakdown.Hours) { $parts += "$($Breakdown.Hours)h" }
    if ($Breakdown.Minutes) { $parts += "$($Breakdown.Minutes)m" }
    if ($Breakdown.Seconds -or $parts.Count -eq 0) { $parts += "$($Breakdown.Seconds)s" }
    $parts -join ' '
}

function New-IntervalResult {
    <# Builds the TimeInterval.Result object returned to the pipeline. #>
    param([hashtable] $Resolved)
    $s = $Resolved.Start
    $e = $Resolved.End
    $span = $e.Utc - $s.Utc
    $negative = $span.Ticks -lt 0
    if ($negative) { $breakdown = Get-CalendarBreakdown -From $e.Local -To $s.Local }
    else { $breakdown = Get-CalendarBreakdown -From $s.Local -To $e.Local }

    $human = Format-HumanDuration -Breakdown $breakdown
    $compact = Format-CompactDuration -Breakdown $breakdown
    if ($negative) {
        $human += ' (the end is before the start)'
        $compact = '-' + $compact
    }
    $allNotes = [string[]]@(@($s.Notes) + @($e.Notes) + @($Resolved.Notes) | Where-Object { $_ })

    $result = [pscustomobject]@{
        PSTypeName    = 'TimeInterval.Result'
        Start         = $s.Local
        End           = $e.Local
        StartUtc      = $s.Utc
        EndUtc        = $e.Utc
        StartTimeZone = Get-ZoneLabel -Zone $s.Zone -Utc $s.Utc
        EndTimeZone   = Get-ZoneLabel -Zone $e.Zone -Utc $e.Utc
        Human         = $human
        Compact       = $compact
        IsNegative    = $negative
        Duration      = $span
        TotalSeconds  = $span.TotalSeconds
        TotalMinutes  = $span.TotalMinutes
        TotalHours    = $span.TotalHours
        TotalDays     = $span.TotalDays
        TotalWeeks    = $span.TotalDays / 7
        Breakdown     = $breakdown
        StartInput    = $s.Input
        EndInput      = $e.Input
        Notes         = $allNotes
    }
    # Show the most useful properties by default; Format-List * shows everything.
    $display = [System.Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet',
        [string[]]@('Start', 'End', 'Human', 'TotalSeconds', 'TotalMinutes', 'TotalHours', 'TotalDays'))
    $result | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value ([System.Management.Automation.PSMemberInfo[]]@($display))
    $result
}

function Get-DisplayPattern {
    <# The system's short date and long time formats, with the day of the week in front. #>
    if ($null -eq $script:DisplayPattern) {
        $dtf = [System.Globalization.CultureInfo]::CurrentCulture.DateTimeFormat
        $date = $dtf.ShortDatePattern
        if ($date -notmatch 'ddd') { $date = 'dddd, ' + $date }
        $script:DisplayPattern = $date + ' ' + $dtf.LongTimePattern
    }
    $script:DisplayPattern
}

function Format-Number {
    <# Whole numbers without decimals, everything else with two, in the system's number format. #>
    param([double] $Value)
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if ($Value -eq [Math]::Truncate($Value)) { return $Value.ToString('N0', $culture) }
    $Value.ToString('N2', $culture)
}

#endregion

#region Terminal user interface ----------------------------------------------------------------

function Initialize-TuiTheme {
    <# ANSI styles and box-drawing glyphs (built from code points so the file stays ASCII). #>
    if ($null -ne $script:Ui) { return }
    $e = [string][char]27
    $fg = { param($r, $g, $b) '{0}[38;2;{1};{2};{3}m' -f $e, $r, $g, $b }
    $bg = { param($r, $g, $b) '{0}[48;2;{1};{2};{3}m' -f $e, $r, $g, $b }
    $script:Ui = @{
        Esc      = $e
        Reset    = "$e[0m"
        Border   = & $fg 88 98 122
        Title    = "$e[1m" + (& $fg 125 207 255)
        Accent   = & $fg 125 207 255
        Label    = "$e[1m"
        LabelDim = & $fg 128 134 150
        Dim      = & $fg 128 134 150
        Ok       = & $fg 110 210 130
        Err      = & $fg 245 105 105
        Warn     = & $fg 230 180 70
        Big      = "$e[1m"
        Key      = "$e[1m" + (& $fg 125 207 255)
        FieldOn  = (& $bg 44 52 72) + (& $fg 245 247 250)
        FieldOff = (& $bg 34 37 47) + (& $fg 185 190 200)
        PlaceOn  = (& $bg 44 52 72) + (& $fg 125 133 155) + "$e[3m"
        PlaceOff = (& $bg 34 37 47) + (& $fg 105 111 130) + "$e[3m"
    }
    $script:Glyph = @{
        H = [string][char]0x2500; V = [string][char]0x2502
        TL = [string][char]0x250C; TR = [string][char]0x2510
        BL = [string][char]0x2514; BR = [string][char]0x2518
        LT = [string][char]0x251C; RT = [string][char]0x2524
        Pointer = [string][char]0x25BA; Check = [string][char]0x221A; Cross = [string][char]0x00D7
        Dot = [string][char]0x00B7; Bullet = [string][char]0x2022; Ellipsis = [string][char]0x2026
        Up = [string][char]0x2191; Down = [string][char]0x2193
    }
}

function New-Segment {
    <# A piece of text with a style, used to build screen rows. #>
    param([string] $Text, [string] $Style = '')
    @{ T = $Text; S = $Style }
}

function Format-Row {
    <# Joins styled segments into exactly $Width visible characters (truncating with an ellipsis). #>
    param([object[]] $Segments, [int] $Width)
    $sb = [System.Text.StringBuilder]::new()
    $len = 0
    foreach ($seg in $Segments) {
        if ($null -eq $seg) { continue }
        $text = [string]$seg.T
        $room = $Width - $len
        if ($room -le 0) { break }
        if ($text.Length -gt $room) { $text = $text.Substring(0, [Math]::Max(0, $room - 1)) + $script:Glyph.Ellipsis }
        [void]$sb.Append($seg.S).Append($text).Append($script:Ui.Reset)
        $len += $text.Length
    }
    if ($len -lt $Width) { [void]$sb.Append(' ' * ($Width - $len)) }
    $sb.ToString()
}

function Split-Word {
    <# Word-wraps text into at most $MaxLines lines of $Width characters. #>
    param([string] $Text, [int] $Width, [int] $MaxLines = 2)
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ($Text -split ' ')) {
        if ($current.Length -eq 0) { $current = $word }
        elseif ($current.Length + 1 + $word.Length -le $Width) { $current += ' ' + $word }
        else { $lines.Add($current); $current = $word }
    }
    if ($current.Length) { $lines.Add($current) }
    while ($lines.Count -gt $MaxLines) {
        $lines[$MaxLines - 1] = $lines[$MaxLines - 1] + ' ' + $lines[$MaxLines]
        $lines.RemoveAt($MaxLines)
    }
    , $lines.ToArray()
}

function Get-EndpointLine {
    <# The two status lines under a field: the parsed date (or the error) and extra detail. #>
    param([hashtable] $Parsed, [int] $Inner)
    $u = $script:Ui
    $g = $script:Glyph
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $pad = New-Segment (' ' * 9)
    if (-not $Parsed.Success) {
        $msg = Split-Word -Text $Parsed.Error -Width ($Inner - 11) -MaxLines 2
        $line1 = @($pad, (New-Segment ($g.Cross + ' ') $u.Err), (New-Segment $msg[0] $u.Err))
        if ($msg.Count -gt 1) { $line2 = @($pad, (New-Segment '  '), (New-Segment $msg[1] $u.Err)) }
        else { $line2 = @($pad, (New-Segment '  Try: tomorrow 5pm, 3/14 9:30am, in 2 hours, friday noon EST' $u.Dim)) }
        return @{ L1 = $line1; L2 = $line2 }
    }
    $when = $Parsed.Wall.ToString((Get-DisplayPattern), $culture)
    $line1 = [System.Collections.Generic.List[object]]::new()
    $line1.Add($pad)
    $line1.Add((New-Segment ($g.Check + ' ') $u.Ok))
    if ($Parsed.IsBlank) { $line1.Add((New-Segment 'Now ' $u.Accent)) }
    $line1.Add((New-Segment $when))
    $line1.Add((New-Segment ('  ' + (Get-ZoneLabel -Zone $Parsed.Zone -Utc $Parsed.Utc)) $u.Dim))

    $line2 = @()
    $differs = $Parsed.ZoneExplicit -and ($Parsed.Zone.GetUtcOffset($Parsed.Utc) -ne [TimeZoneInfo]::Local.GetUtcOffset($Parsed.Utc))
    if ($differs) {
        $line2 = @($pad, (New-Segment ('  = ' + $Parsed.Local.ToString((Get-DisplayPattern), $culture) + ' local time') $u.Dim))
    }
    elseif ($Parsed.Notes.Count -gt 0) {
        $line2 = @($pad, (New-Segment ('  ' + $Parsed.Notes[0]) $u.Warn))
    }
    @{ L1 = $line1.ToArray(); L2 = $line2 }
}

function Get-TuiFrame {
    <#
        Renders the whole screen as one string of ANSI sequences (written in a single call to
        avoid flicker). Also keeps each field's horizontal scroll position up to date.
    #>
    param([hashtable] $State, [int] $Width, [int] $Height, [datetime] $NowUtc)
    Initialize-TuiTheme
    $u = $script:Ui
    $g = $script:Glyph
    $esc = $u.Esc
    $culture = [System.Globalization.CultureInfo]::CurrentCulture

    $w = [Math]::Min($Width - 1, 100)
    if ($w -lt 46 -or $Height -lt 12) {
        return "$esc[?25l$esc[H$esc[0m$esc[2JPlease make the window larger (at least 47 x 12).$esc[K"
    }
    $inner = $w - 4
    $rows = [System.Collections.Generic.List[string]]::new()
    $boxRow = {
        param([object[]] $Segments)
        $u.Border + $g.V + $u.Reset + ' ' + (Format-Row -Segments $Segments -Width $inner) + ' ' + $u.Border + $g.V + $u.Reset
    }

    # Title bar.
    $title = ' Time Interval '
    $ver = " v$script:AppVersion "
    $fill = $w - 4 - $title.Length - $ver.Length
    $rows.Add($u.Border + $g.TL + $g.H + $u.Title + $title + $u.Reset + $u.Border + ($g.H * $fill) + $u.Reset + $u.Dim + $ver + $u.Reset + $u.Border + $g.H + $g.TR + $u.Reset)
    $rows.Add((& $boxRow @()))

    # Input fields with their parsed values underneath.
    $resolved = Resolve-Interval -StartText $State.Fields[0].Text -EndText $State.Fields[1].Text -NowUtc $NowUtc
    $placeholders = @("blank = now   try: yesterday 9am, last friday, 5/7 14:00",
                      "blank = now   try: in 3 hours, friday 5pm EST, midnight")
    $cursorRow = 0
    $cursorCol = 0
    for ($i = 0; $i -lt 2; $i++) {
        $field = $State.Fields[$i]
        $active = $State.Active -eq $i
        $parsed = $resolved.Start
        if ($i -eq 1) { $parsed = $resolved.End }
        $visible = $inner - 11
        if ($field.Cursor -lt $field.Scroll) { $field.Scroll = $field.Cursor }
        if ($field.Cursor - $field.Scroll -gt $visible - 1) { $field.Scroll = $field.Cursor - $visible + 1 }
        if ($field.Text.Length -eq 0) {
            $content = $placeholders[$i]
            if ($content.Length -gt $visible) { $content = $content.Substring(0, $visible) }
            $style = $u.PlaceOff
            if ($active) { $style = $u.PlaceOn }
        }
        else {
            $content = $field.Text.Substring($field.Scroll, [Math]::Min($visible, $field.Text.Length - $field.Scroll))
            $style = $u.FieldOff
            if ($active) { $style = $u.FieldOn }
        }
        $marker = '  '
        $labelStyle = $u.LabelDim
        if ($active) { $marker = $g.Pointer + ' '; $labelStyle = $u.Label }
        $rows.Add((& $boxRow @(
            (New-Segment $marker $u.Accent),
            (New-Segment $field.Name.PadRight(6) $labelStyle),
            (New-Segment ' '),
            (New-Segment (' ' + $content.PadRight($visible) + ' ') $style))))
        if ($active) {
            $cursorRow = $rows.Count
            $cursorCol = 13 + ($field.Cursor - $field.Scroll)
        }
        $lines = Get-EndpointLine -Parsed $parsed -Inner $inner
        $rows.Add((& $boxRow $lines.L1))
        $rows.Add((& $boxRow $lines.L2))
        $rows.Add((& $boxRow @()))
    }

    # Interval (or help) section.
    $section = ' Interval '
    if ($State.ShowHelp) { $section = ' Help ' }
    $rows.Add($u.Border + $g.LT + $g.H + $u.Reset + $u.Title + $section + $u.Reset + $u.Border + ($g.H * ($w - 3 - $section.Length)) + $g.RT + $u.Reset)
    $body = [System.Collections.Generic.List[object]]::new()
    if ($State.ShowHelp) {
        $k = $u.Key
        $d = $u.Dim
        $keyRows = @(
            @("Tab $($g.Up) $($g.Down)", 'move between fields', 'Enter', 'next field / finish'),
            @('Ctrl+R  F5', 'reset everything', 'Esc', 'finish and return result'),
            @('Ctrl+U', 'clear this field', 'Ctrl+C', 'cancel, no result'))
        foreach ($kr in $keyRows) {
            $body.Add(@((New-Segment ('  ' + $kr[0].PadRight(12)) $k), (New-Segment $kr[1].PadRight(24) $d),
                        (New-Segment $kr[2].PadRight(8) $k), (New-Segment $kr[3] $d)))
        }
        $body.Add(@())
        $body.Add(@((New-Segment '  5pm  17:30  noon  midnight  5/7  May 7th 2027  2026-05-07T14:00Z')))
        $body.Add(@((New-Segment '  tomorrow 9am  next friday  last monday  friday next week  the 15th')))
        $body.Add(@((New-Segment '  in 3 hours  2 days ago  3 months and 7 days from today  1h30m')))
        $body.Add(@((New-Segment '  today + 90 minutes  5pm EST  9am Tokyo  14:00 UTC+2  America/Chicago')))
        $body.Add(@())
        $body.Add(@((New-Segment '  Blank = now. No date = today. No year = this year. No zone = local time.' $d)))
        $body.Add(@((New-Segment '  Press F1 or Esc to close this help.' $d)))
    }
    elseif ($resolved.Start.Success -and $resolved.End.Success) {
        $iv = New-IntervalResult -Resolved $resolved
        $body.Add(@())
        $human = Split-Word -Text $iv.Human -Width ($inner - 4) -MaxLines 2
        foreach ($line in $human) { $body.Add(@((New-Segment '  '), (New-Segment $line $u.Big))) }
        if ($human.Count -lt 2) { $body.Add(@()) }
        # Show as many totals as fit on one line.
        $pieces = @(
            ((Format-Number $iv.TotalSeconds) + ' seconds'),
            ((Format-Number ([Math]::Round($iv.TotalMinutes, 2))) + ' minutes'),
            ((Format-Number ([Math]::Round($iv.TotalHours, 2))) + ' hours'),
            ((Format-Number ([Math]::Round($iv.TotalDays, 2))) + ' days'),
            ((Format-Number ([Math]::Round($iv.TotalWeeks, 2))) + ' weeks'))
        $totals = $pieces[0]
        foreach ($piece in $pieces[1..($pieces.Count - 1)]) {
            $candidate = $totals + " $($g.Dot) " + $piece
            if ($candidate.Length -gt $inner - 10) { break }
            $totals = $candidate
        }
        $body.Add(@((New-Segment '  Totals  ' $u.Dim), (New-Segment $totals)))
        $exact = $iv.Duration.Duration().ToString('d\.hh\:mm\:ss', $culture)
        if ($iv.IsNegative) { $exact = '-' + $exact }
        $body.Add(@((New-Segment '  Exact   ' $u.Dim), (New-Segment $iv.Compact), (New-Segment "   ($exact  d.hh:mm:ss)" $u.Dim)))
        $body.Add(@())
        $noteLines = 0
        foreach ($note in $resolved.Notes) {
            $prefix = "  $($g.Bullet) "
            foreach ($line in (Split-Word -Text $note -Width ($inner - 4) -MaxLines (2 - $noteLines))) {
                $body.Add(@((New-Segment ($prefix + $line) $u.Warn)))
                $prefix = '    '
                $noteLines++
            }
            if ($noteLines -ge 2) { break }
        }
    }
    else {
        $body.Add(@())
        $body.Add(@((New-Segment '  Waiting for a valid start and end ...' $u.Dim)))
    }
    while ($body.Count -lt 8) { $body.Add(@()) }
    foreach ($segments in $body) { $rows.Add((& $boxRow $segments)) }
    $rows.Add($u.Border + $g.BL + ($g.H * ($w - 2)) + $g.BR + $u.Reset)

    # Key hints, or a short-lived status message.
    if ($State.Status -and [DateTime]::UtcNow -lt $State.StatusUntil) {
        $hint = @((New-Segment ' '), (New-Segment $State.Status $u.Warn))
    }
    else {
        $k = $u.Key
        $d = $u.Dim
        $hint = @((New-Segment ' Tab' $k), (New-Segment ' move   ' $d), (New-Segment 'Enter' $k), (New-Segment ' next/finish   ' $d),
                  (New-Segment 'Ctrl+R' $k), (New-Segment ' reset   ' $d), (New-Segment 'F1' $k), (New-Segment ' help   ' $d),
                  (New-Segment 'Esc' $k), (New-Segment ' done   ' $d), (New-Segment 'Ctrl+C' $k), (New-Segment ' cancel' $d))
    }
    $rows.Add((Format-Row -Segments $hint -Width $w))

    # Assemble: hide the cursor while drawing, draw each row, then park the cursor in the field.
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("$esc[?25l")
    $count = [Math]::Min($rows.Count, $Height)
    for ($r = 0; $r -lt $count; $r++) {
        [void]$sb.Append("$esc[$($r + 1);1H").Append($rows[$r]).Append("$esc[0m$esc[K")
    }
    if ($count -lt $Height) { [void]$sb.Append("$esc[$($count + 1);1H$esc[0J") }
    if ($cursorRow -gt 0 -and $cursorRow -le $count -and -not $State.ShowHelp) {
        [void]$sb.Append("$esc[$cursorRow;${cursorCol}H$esc[5 q$esc[?25h")
    }
    $sb.ToString()
}

function Get-WordBoundary {
    <# Finds the start of the previous word (-Left) or the end of the next word. #>
    param([string] $Text, [int] $Position, [switch] $Left)
    $p = $Position
    if ($Left) {
        while ($p -gt 0 -and $Text[$p - 1] -eq ' ') { $p-- }
        while ($p -gt 0 -and $Text[$p - 1] -ne ' ') { $p-- }
    }
    else {
        while ($p -lt $Text.Length -and $Text[$p] -eq ' ') { $p++ }
        while ($p -lt $Text.Length -and $Text[$p] -ne ' ') { $p++ }
    }
    $p
}

function Set-TuiStatus {
    <# Shows a message in the hint bar for a few seconds. #>
    param([hashtable] $State, [string] $Message)
    $State.Status = $Message
    $State.StatusUntil = [DateTime]::UtcNow.AddSeconds(3)
}

function Invoke-TuiKey {
    <#
        Applies one key press to the TUI state. Returns 'finish' or 'cancel' to leave the loop,
        or $null to keep going.
    #>
    param([hashtable] $State, [System.ConsoleKeyInfo] $Key)
    $field = $State.Fields[$State.Active]
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $alt = ($Key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
    
    $text = $field.Text
    $pos = $field.Cursor

    switch ($Key.Key) {
        'Escape' {
            if ($State.ShowHelp) { $State.ShowHelp = $false; return $null }
            return 'finish'
        }
        'Enter' {
            if ($State.Active -eq 0) { $State.Active = 1; return $null }
            $check = Resolve-Interval -StartText $State.Fields[0].Text -EndText $State.Fields[1].Text -NowUtc (Get-NowUtc)
            if ($check.Start.Success -and $check.End.Success) { return 'finish' }
            Set-TuiStatus -State $State -Message 'Please fix the field marked with an error first (or press Esc to quit).'
            return $null
        }
        'Tab' {
            $State.Active = ($State.Active + 1) % 2   # two fields, so Tab and Shift+Tab both toggle
            return $null
        }
        'UpArrow' { $State.Active = 0; return $null }
        'DownArrow' { $State.Active = 1; return $null }
        'F1' { $State.ShowHelp = -not $State.ShowHelp; return $null }
        'F5' { Reset-TuiState -State $State; return $null }
        'LeftArrow' {
            if ($ctrl) { $field.Cursor = Get-WordBoundary -Text $text -Position $pos -Left }
            elseif ($pos -gt 0) { $field.Cursor = $pos - 1 }
            return $null
        }
        'RightArrow' {
            if ($ctrl) { $field.Cursor = Get-WordBoundary -Text $text -Position $pos }
            elseif ($pos -lt $text.Length) { $field.Cursor = $pos + 1 }
            return $null
        }
        'Home' { $field.Cursor = 0; return $null }
        'End' { $field.Cursor = $text.Length; return $null }
        'Backspace' {
            if ($ctrl -or [int]$Key.KeyChar -eq 127) {
                $from = Get-WordBoundary -Text $text -Position $pos -Left
                $field.Text = $text.Remove($from, $pos - $from)
                $field.Cursor = $from
            }
            elseif ($pos -gt 0) {
                $field.Text = $text.Remove($pos - 1, 1)
                $field.Cursor = $pos - 1
            }
            return $null
        }
        'Delete' {
            if ($ctrl) {
                $to = Get-WordBoundary -Text $text -Position $pos
                $field.Text = $text.Remove($pos, $to - $pos)
            }
            elseif ($pos -lt $text.Length) { $field.Text = $text.Remove($pos, 1) }
            return $null
        }
    }

    if ($ctrl -and -not $alt) {
        switch ($Key.Key) {
            'C' { return 'cancel' }
            'R' { Reset-TuiState -State $State; return $null }
            'U' { $field.Text = $text.Substring($pos); $field.Cursor = 0; return $null }
            'K' { $field.Text = $text.Substring(0, $pos); return $null }
            'A' { $field.Cursor = 0; return $null }
            'E' { $field.Cursor = $text.Length; return $null }
            'W' {
                $from = Get-WordBoundary -Text $text -Position $pos -Left
                $field.Text = $text.Remove($from, $pos - $from)
                $field.Cursor = $from
                return $null
            }
        }
        return $null
    }

    $char = $Key.KeyChar
    if ([int]$char -ge 32 -and [int]$char -ne 127) {
        $field.Text = $text.Insert($pos, [string]$char)
        $field.Cursor = $pos + 1
    }
    $null
}

function Reset-TuiState {
    <# Clears both fields so the user can start over. #>
    param([hashtable] $State)
    foreach ($field in $State.Fields) { $field.Text = ''; $field.Cursor = 0; $field.Scroll = 0 }
    $State.Active = 0
    $State.ShowHelp = $false
    Set-TuiStatus -State $State -Message 'Cleared. Start over.'
}

function Test-TuiSupport {
    <# Returns $null when the console can run the TUI, otherwise the reason it can't. #>
    if ($Host.Name -eq 'Windows PowerShell ISE Host') {
        return 'The interactive interface needs a console window and does not run in the PowerShell ISE.'
    }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            return 'The interactive interface needs an interactive console, but input or output is redirected.'
        }
    }
    catch { return 'The interactive interface needs a console window.' }
    try {
        if (-not $Host.UI.SupportsVirtualTerminal) {
            return 'This console does not support virtual terminal (ANSI) sequences. Try Windows Terminal.'
        }
    }
    catch { Write-Debug 'SupportsVirtualTerminal is not available; assuming it is supported.' }
    $null
}

function Enable-VirtualTerminal {
    <# Makes sure ANSI processing is switched on (Windows PowerShell can leave it off). #>
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return }
    try {
        if (-not ('TimeInterval.NativeConsole' -as [type])) {
            Add-Type -Namespace TimeInterval -Name NativeConsole -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [TimeInterval.NativeConsole]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if ([TimeInterval.NativeConsole]::GetConsoleMode($handle, [ref]$mode)) {
            [void][TimeInterval.NativeConsole]::SetConsoleMode($handle, $mode -bor 0x0004)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        }
    }
    catch { Write-Debug "Could not enable VT processing: $($_.Exception.Message)" }
}

function Start-IntervalTui {
    <#
        Runs the interactive interface until the user finishes (Enter/Esc) or cancels (Ctrl+C).
        Returns the TimeInterval.Result, or nothing when cancelled or invalid.
    #>
    $problem = Test-TuiSupport
    if ($problem) { throw [System.InvalidOperationException]::new("$problem Use -Start and -End instead (see -Help).") }
    Enable-VirtualTerminal
    Initialize-TuiTheme
    $esc = $script:Ui.Esc

    $state = @{
        Fields      = @(@{ Name = 'Start'; Text = ''; Cursor = 0; Scroll = 0 }, @{ Name = 'End'; Text = ''; Cursor = 0; Scroll = 0 })
        Active      = 0
        ShowHelp    = $false
        Status      = ''
        StatusUntil = [DateTime]::MinValue
    }
    $savedCtrlC = [Console]::TreatControlCAsInput
    $savedEncoding = [Console]::OutputEncoding
    $outcome = $null
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        [Console]::TreatControlCAsInput = $true
        [Console]::Write("$esc[?1049h$esc[?25l$esc[2J")   # alternate screen buffer, hidden cursor
        $lastFrame = ''
        $lastSize = ''
        $lastTick = ''
        $dirty = $true
        while ($null -eq $outcome) {
            while ([Console]::KeyAvailable) {
                $outcome = Invoke-TuiKey -State $state -Key ([Console]::ReadKey($true))
                $dirty = $true
                if ($null -ne $outcome) { break }
            }
            if ($null -ne $outcome) { break }

            $size = '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight
            if ($size -ne $lastSize) {
                [Console]::Write("$esc[2J")
                $lastSize = $size
                $lastFrame = ''
                $dirty = $true
            }
            $tick = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')   # redraw every second: "now" moves
            if ($tick -ne $lastTick) { $lastTick = $tick; $dirty = $true }
            if ($State.Status -and [DateTime]::UtcNow -ge $state.StatusUntil) { $state.Status = ''; $dirty = $true }

            if ($dirty) {
                $frame = Get-TuiFrame -State $state -Width ([Console]::WindowWidth) -Height ([Console]::WindowHeight) -NowUtc (Get-NowUtc)
                if ($frame -ne $lastFrame) { [Console]::Write($frame); $lastFrame = $frame }
                $dirty = $false
            }
            Start-Sleep -Milliseconds 30
        }
    }
    finally {
        [Console]::Write("$esc[0m$esc[0 q$esc[?25h$esc[?1049l")   # restore the normal screen
        [Console]::TreatControlCAsInput = $savedCtrlC
        [Console]::OutputEncoding = $savedEncoding
    }

    if ($outcome -eq 'finish') {
        $final = Resolve-Interval -StartText $state.Fields[0].Text -EndText $state.Fields[1].Text -NowUtc (Get-NowUtc)
        if ($final.Start.Success -and $final.End.Success) { return New-IntervalResult -Resolved $final }
        Write-Warning 'No result: the start or end could not be understood.'
    }
}

#endregion

#region Usage ----------------------------------------------------------------------------------

function Show-Usage {
    <# Prints the -Help text. #>
    @"
$script:AppName $script:AppVersion
Calculates the time between two free-form dates/times.

USAGE
  .\Get-TimeInterval.ps1                       Open the interactive interface
  .\Get-TimeInterval.ps1 [-Start] <text> [[-End] <text>]
                                               Calculate directly, no interface
  .\Get-TimeInterval.ps1 -Version              Show the version number and exit
  .\Get-TimeInterval.ps1 -Help                 Show this help and exit
  Get-Help .\Get-TimeInterval.ps1 -Full        Full PowerShell help

PARAMETERS
  -Start <text>   Start of the interval. Blank or omitted means now.
  -End <text>     End of the interval. Blank or omitted means now.
  -Version        Display the version number and exit.
  -Help           Display this help and exit.

INTERACTIVE KEYS
  Tab, Up, Down   Move between the Start and End fields
  Enter           Next field; on End, finish and return the result
  Esc             Finish and return the result (closes help if open)
  Ctrl+R, F5      Reset both fields and start over
  Ctrl+U / Ctrl+K Delete to the start / end of the field
  Ctrl+W, Ctrl+Backspace   Delete the previous word
  F1              Show or hide help and examples
  Ctrl+C          Cancel without returning a result

INPUT EXAMPLES
  Times       5pm  5:30 pm  17:30  17:30:15  noon  midnight  9 in the morning  eod
  Dates       5/7  5/7/2027  2027-05-07  May 7  7th of May 2027  the 15th
  Relative    now  today  tomorrow  yesterday  next week  last month  next year
  Weekdays    friday  this friday  next friday  last monday  friday next week
  Durations   in 3 hours  2 days ago  3 months and 7 days from today
              a week from tomorrow at noon  today + 90 minutes  1h30m  -2d
  Time zones  5pm EST  9am Eastern  noon Tokyo  14:00 UTC+2  10:00-05:00
              8am America/New_York  3pm Pacific Standard Time

RULES
  * A blank field means now. No date means today. No year means this year.
  * No minutes means :00. No time zone means your local time zone.
  * Calendar dates and weekdays without a time mean midnight (00:00);
    relative words like "tomorrow" or "next week" keep the current time.
  * 5/7 follows your system's date order (MM/DD on en-US, DD/MM on en-GB).
  * A weekday on its own means that day in the current week.
  * If the end is earlier than the start, the script tries to fix it:
    a time-only end moves to the next day ("10pm" to "2am"), and weekdays
    given backwards ("friday" to "monday") use the next/previous week.
  * Time zone abbreviations follow daylight saving time (EST in July = UTC-4).

OUTPUT
  A TimeInterval.Result object with Start and End ([datetime], local time),
  StartUtc, EndUtc, StartTimeZone, EndTimeZone, Human ("2 hours and 30 minutes"),
  Compact ("2h 30m"), IsNegative, Duration ([timespan]), TotalSeconds,
  TotalMinutes, TotalHours, TotalDays, TotalWeeks, Breakdown (years, months,
  days, hours, minutes, seconds), StartInput, EndInput and Notes.

EXAMPLES
  .\Get-TimeInterval.ps1 -Start 9am -End 5:30pm
  .\Get-TimeInterval.ps1 -End 'friday 5pm EST' | Select-Object Human, TotalHours
  (.\Get-TimeInterval.ps1 'last monday' 'next monday').TotalDays
"@
}

#endregion

#region Main -----------------------------------------------------------------------------------

Initialize-Lookup

# When dot-sourced (for example by tests), only load the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

switch ($PSCmdlet.ParameterSetName) {
    'Version' {
        "$script:AppName $script:AppVersion"
    }
    'Help' {
        Show-Usage
    }
    'Direct' {
        $resolved = Resolve-Interval -StartText $Start -EndText $End -NowUtc (Get-NowUtc)
        $problems = @()
        if (-not $resolved.Start.Success) { $problems += "Could not understand -Start '$Start': $($resolved.Start.Error)" }
        if (-not $resolved.End.Success) { $problems += "Could not understand -End '$End': $($resolved.End.Error)" }
        if ($problems.Count -gt 0) {
            $message = ($problems -join [Environment]::NewLine) + [Environment]::NewLine +
                "Examples: 'tomorrow 9am', '5/7 17:30', 'next friday 5pm EST', '3 days ago'. Run with -Help for more."
            $record = [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new($message), 'InvalidTimeInput',
                [System.Management.Automation.ErrorCategory]::InvalidArgument, $null)
            $PSCmdlet.ThrowTerminatingError($record)
        }
        foreach ($note in @($resolved.Start.Notes) + @($resolved.End.Notes) + @($resolved.Notes)) {
            if ($note) { Write-Verbose $note }
        }
        New-IntervalResult -Resolved $resolved
    }
    default {
        try {
            Start-IntervalTui
        }
        catch [System.InvalidOperationException] {
            $record = [System.Management.Automation.ErrorRecord]::new($_.Exception, 'TuiNotSupported',
                [System.Management.Automation.ErrorCategory]::NotEnabled, $null)
            $PSCmdlet.ThrowTerminatingError($record)
        }
    }
}

#endregion
