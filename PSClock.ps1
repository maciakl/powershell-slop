#Requires -Version 5.1
<#
.SYNOPSIS
    PSClock - an interactive terminal (TUI) world clock.

.DESCRIPTION
    PSClock shows the current time in your local time zone and in any number of
    additional time zones that you choose. For every zone it displays the time,
    date, day of the week, a day/night indicator and whether it is currently
    business hours, after hours or a weekend there.

    Time zones can be added by searching for a city or country name ("Tokyo",
    "Brazil"), by a common abbreviation ("EST", "CET", "JST") or by a UTC offset
    ("+2", "-5", "+5:30"). The list can be filtered, sorted (by city, time zone
    name, offset or time of day) and any date/time can be converted into all of
    the listed zones at once.

    The list of zones is saved to a JSON file in your roaming application data
    folder (%APPDATA%\PSClock\PSClock.json) and restored on the next start. A
    backup of the previous version is kept next to it (PSClock.json.bak).

    The script has no external dependencies and runs on Windows PowerShell 5.1
    (built into Windows 11) as well as on PowerShell 7+.

    Keys (press ? inside the app for the full list):
        Up/Down/PgUp/PgDn/Home/End  Move the selection
        A or Insert                 Add a time zone
        D or Delete                 Remove the selected time zone
        /  or F                     Filter the list
        S / R                       Change sort column / reverse sort order
        T                           Convert a date/time into all zones
        L                           Return to live time
        H                           Toggle 12/24 hour clock
        C                           Clear the whole list
        Q or Ctrl+C                 Quit

.PARAMETER ConfigPath
    Path of the JSON file used to persist the list of time zones and display
    preferences. Defaults to %APPDATA%\PSClock\PSClock.json.

.PARAMETER Symbols
    Controls the use of Unicode symbols (sun/moon, box drawing characters).
    'Auto' (default) uses Unicode in Windows Terminal and plain ASCII in the
    classic console host, whose default fonts lack some of the glyphs.

.PARAMETER BusinessStart
    Hour (0-23) when the business day starts. Default 9.

.PARAMETER BusinessEnd
    Hour (1-24) when the business day ends. Default 17.

.EXAMPLE
    .\PSClock.ps1

    Starts the world clock using the saved list of time zones.

.EXAMPLE
    .\PSClock.ps1 -BusinessStart 8 -BusinessEnd 18 -Symbols Ascii

    Starts the clock with an 08:00-18:00 business day and ASCII-only output.

.NOTES
    Name:     PSClock.ps1
    Requires: Windows PowerShell 5.1 or PowerShell 7+, an interactive console.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath 'PSClock\PSClock.json'),

    [Parameter()]
    [ValidateSet('Auto', 'Unicode', 'Ascii')]
    [string]$Symbols = 'Auto',

    [Parameter()]
    [ValidateRange(0, 23)]
    [int]$BusinessStart = 9,

    [Parameter()]
    [ValidateRange(1, 24)]
    [int]$BusinessEnd = 17
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ---------------------------------------------------------------- Data

# City lookup table: City | Country | Windows time zone ID.
# Windows time zone IDs are used (rather than IANA IDs) because they are the
# only kind understood by Windows PowerShell 5.1 / .NET Framework.
$script:CityData = @'
Abidjan|Ivory Coast|Greenwich Standard Time
Abu Dhabi|United Arab Emirates|Arabian Standard Time
Accra|Ghana|Greenwich Standard Time
Adelaide|Australia|Cen. Australia Standard Time
Addis Ababa|Ethiopia|E. Africa Standard Time
Albuquerque|United States|Mountain Standard Time
Algiers|Algeria|W. Central Africa Standard Time
Almaty|Kazakhstan|Central Asia Standard Time
Amman|Jordan|Jordan Standard Time
Amsterdam|Netherlands|W. Europe Standard Time
Anchorage|United States|Alaskan Standard Time
Apia|Samoa|Samoa Standard Time
Asuncion|Paraguay|Paraguay Standard Time
Athens|Greece|GTB Standard Time
Atlanta|United States|Eastern Standard Time
Auckland|New Zealand|New Zealand Standard Time
Austin|United States|Central Standard Time
Baghdad|Iraq|Arabic Standard Time
Baku|Azerbaijan|Azerbaijan Standard Time
Bangalore|India|India Standard Time
Bangkok|Thailand|SE Asia Standard Time
Barcelona|Spain|Romance Standard Time
Beijing|China|China Standard Time
Beirut|Lebanon|Middle East Standard Time
Belgrade|Serbia|Central Europe Standard Time
Berlin|Germany|W. Europe Standard Time
Bern|Switzerland|W. Europe Standard Time
Bogota|Colombia|SA Pacific Standard Time
Boise|United States|Mountain Standard Time
Boston|United States|Eastern Standard Time
Brasilia|Brazil|E. South America Standard Time
Bratislava|Slovakia|Central Europe Standard Time
Brisbane|Australia|E. Australia Standard Time
Brussels|Belgium|Romance Standard Time
Bucharest|Romania|GTB Standard Time
Budapest|Hungary|Central Europe Standard Time
Buenos Aires|Argentina|Argentina Standard Time
Cairo|Egypt|Egypt Standard Time
Calgary|Canada|Mountain Standard Time
Canberra|Australia|AUS Eastern Standard Time
Cape Town|South Africa|South Africa Standard Time
Caracas|Venezuela|Venezuela Standard Time
Casablanca|Morocco|Morocco Standard Time
Chennai|India|India Standard Time
Chicago|United States|Central Standard Time
Chisinau|Moldova|E. Europe Standard Time
Colombo|Sri Lanka|Sri Lanka Standard Time
Copenhagen|Denmark|Romance Standard Time
Dakar|Senegal|Greenwich Standard Time
Dallas|United States|Central Standard Time
Damascus|Syria|Syria Standard Time
Dar es Salaam|Tanzania|E. Africa Standard Time
Darwin|Australia|AUS Central Standard Time
Delhi|India|India Standard Time
Denver|United States|Mountain Standard Time
Detroit|United States|Eastern Standard Time
Dhaka|Bangladesh|Bangladesh Standard Time
Doha|Qatar|Arab Standard Time
Dubai|United Arab Emirates|Arabian Standard Time
Dublin|Ireland|GMT Standard Time
Edinburgh|United Kingdom|GMT Standard Time
Edmonton|Canada|Mountain Standard Time
Frankfurt|Germany|W. Europe Standard Time
Geneva|Switzerland|W. Europe Standard Time
Guadalajara|Mexico|Central Standard Time (Mexico)
Guam|Guam|West Pacific Standard Time
Guatemala City|Guatemala|Central America Standard Time
Halifax|Canada|Atlantic Standard Time
Hamburg|Germany|W. Europe Standard Time
Hanoi|Vietnam|SE Asia Standard Time
Harare|Zimbabwe|South Africa Standard Time
Havana|Cuba|Cuba Standard Time
Helsinki|Finland|FLE Standard Time
Ho Chi Minh City|Vietnam|SE Asia Standard Time
Hobart|Australia|Tasmania Standard Time
Hong Kong|China|China Standard Time
Honolulu|United States|Hawaiian Standard Time
Houston|United States|Central Standard Time
Hyderabad|India|India Standard Time
Indianapolis|United States|US Eastern Standard Time
Irkutsk|Russia|North Asia East Standard Time
Islamabad|Pakistan|Pakistan Standard Time
Istanbul|Turkey|Turkey Standard Time
Jakarta|Indonesia|SE Asia Standard Time
Jerusalem|Israel|Israel Standard Time
Johannesburg|South Africa|South Africa Standard Time
Kabul|Afghanistan|Afghanistan Standard Time
Kaliningrad|Russia|Kaliningrad Standard Time
Kansas City|United States|Central Standard Time
Karachi|Pakistan|Pakistan Standard Time
Kathmandu|Nepal|Nepal Standard Time
Khartoum|Sudan|Sudan Standard Time
Kinshasa|DR Congo|W. Central Africa Standard Time
Kiritimati|Kiribati|Line Islands Standard Time
Kolkata|India|India Standard Time
Krasnoyarsk|Russia|North Asia Standard Time
Kuala Lumpur|Malaysia|Singapore Standard Time
Kuwait City|Kuwait|Arab Standard Time
Kyiv|Ukraine|FLE Standard Time
La Paz|Bolivia|SA Western Standard Time
Lagos|Nigeria|W. Central Africa Standard Time
Lahore|Pakistan|Pakistan Standard Time
Las Vegas|United States|Pacific Standard Time
Lima|Peru|SA Pacific Standard Time
Lisbon|Portugal|GMT Standard Time
Ljubljana|Slovenia|Central Europe Standard Time
London|United Kingdom|GMT Standard Time
Los Angeles|United States|Pacific Standard Time
Luxembourg|Luxembourg|W. Europe Standard Time
Madrid|Spain|Romance Standard Time
Magadan|Russia|Magadan Standard Time
Manama|Bahrain|Arab Standard Time
Manila|Philippines|Singapore Standard Time
Melbourne|Australia|AUS Eastern Standard Time
Mexico City|Mexico|Central Standard Time (Mexico)
Miami|United States|Eastern Standard Time
Milan|Italy|W. Europe Standard Time
Minneapolis|United States|Central Standard Time
Minsk|Belarus|Belarus Standard Time
Monterrey|Mexico|Central Standard Time (Mexico)
Montevideo|Uruguay|Montevideo Standard Time
Montreal|Canada|Eastern Standard Time
Moscow|Russia|Russian Standard Time
Mumbai|India|India Standard Time
Munich|Germany|W. Europe Standard Time
Muscat|Oman|Arabian Standard Time
Nairobi|Kenya|E. Africa Standard Time
Nashville|United States|Central Standard Time
New Delhi|India|India Standard Time
New Orleans|United States|Central Standard Time
New York|United States|Eastern Standard Time
Novosibirsk|Russia|N. Central Asia Standard Time
Nuku'alofa|Tonga|Tonga Standard Time
Nuuk|Greenland|Greenland Standard Time
Osaka|Japan|Tokyo Standard Time
Oslo|Norway|W. Europe Standard Time
Ottawa|Canada|Eastern Standard Time
Panama City|Panama|SA Pacific Standard Time
Paris|France|Romance Standard Time
Perth|Australia|W. Australia Standard Time
Philadelphia|United States|Eastern Standard Time
Phoenix|United States|US Mountain Standard Time
Port Louis|Mauritius|Mauritius Standard Time
Port Moresby|Papua New Guinea|West Pacific Standard Time
Portland|United States|Pacific Standard Time
Prague|Czech Republic|Central Europe Standard Time
Praia|Cape Verde|Cape Verde Standard Time
Pyongyang|North Korea|North Korea Standard Time
Quito|Ecuador|SA Pacific Standard Time
Regina|Canada|Canada Central Standard Time
Reykjavik|Iceland|Greenwich Standard Time
Riga|Latvia|FLE Standard Time
Rio de Janeiro|Brazil|E. South America Standard Time
Riyadh|Saudi Arabia|Arab Standard Time
Rome|Italy|W. Europe Standard Time
Salt Lake City|United States|Mountain Standard Time
Samara|Russia|Russia Time Zone 3
San Diego|United States|Pacific Standard Time
San Francisco|United States|Pacific Standard Time
San Jose|Costa Rica|Central America Standard Time
San Juan|Puerto Rico|SA Western Standard Time
San Salvador|El Salvador|Central America Standard Time
Santiago|Chile|Pacific SA Standard Time
Santo Domingo|Dominican Republic|SA Western Standard Time
Sao Paulo|Brazil|E. South America Standard Time
Sarajevo|Bosnia and Herzegovina|Central European Standard Time
Seattle|United States|Pacific Standard Time
Seoul|South Korea|Korea Standard Time
Shanghai|China|China Standard Time
Shenzhen|China|China Standard Time
Singapore|Singapore|Singapore Standard Time
Sofia|Bulgaria|FLE Standard Time
St. John's|Canada|Newfoundland Standard Time
St. Petersburg|Russia|Russian Standard Time
Stockholm|Sweden|W. Europe Standard Time
Suva|Fiji|Fiji Standard Time
Sydney|Australia|AUS Eastern Standard Time
Taipei|Taiwan|Taipei Standard Time
Tallinn|Estonia|FLE Standard Time
Tashkent|Uzbekistan|West Asia Standard Time
Tbilisi|Georgia|Georgian Standard Time
Tegucigalpa|Honduras|Central America Standard Time
Tehran|Iran|Iran Standard Time
Tel Aviv|Israel|Israel Standard Time
Tijuana|Mexico|Pacific Standard Time (Mexico)
Tokyo|Japan|Tokyo Standard Time
Toronto|Canada|Eastern Standard Time
Tripoli|Libya|Libya Standard Time
Tunis|Tunisia|W. Central Africa Standard Time
Ulaanbaatar|Mongolia|Ulaanbaatar Standard Time
Vancouver|Canada|Pacific Standard Time
Vienna|Austria|W. Europe Standard Time
Vilnius|Lithuania|FLE Standard Time
Vladivostok|Russia|Vladivostok Standard Time
Volgograd|Russia|Volgograd Standard Time
Warsaw|Poland|Central European Standard Time
Washington DC|United States|Eastern Standard Time
Wellington|New Zealand|New Zealand Standard Time
Windhoek|Namibia|Namibia Standard Time
Winnipeg|Canada|Central Standard Time
Yangon|Myanmar|Myanmar Standard Time
Yekaterinburg|Russia|Ekaterinburg Standard Time
Yerevan|Armenia|Caucasus Standard Time
Zagreb|Croatia|Central European Standard Time
Zurich|Switzerland|W. Europe Standard Time
'@

# Common time zone abbreviations mapped to Windows time zone IDs. Several
# abbreviations are ambiguous (CST, IST, AST, ...), so each maps to a list and
# the user picks the one they meant from the search results.
$script:Abbreviations = @{
    'UTC'  = @('UTC')
    'GMT'  = @('Greenwich Standard Time', 'GMT Standard Time')
    'Z'    = @('UTC')
    'WET'  = @('GMT Standard Time')
    'WEST' = @('GMT Standard Time')
    'BST'  = @('GMT Standard Time')
    'IST'  = @('India Standard Time', 'Israel Standard Time', 'GMT Standard Time')
    'CET'  = @('W. Europe Standard Time', 'Central Europe Standard Time', 'Romance Standard Time')
    'CEST' = @('W. Europe Standard Time', 'Central Europe Standard Time', 'Romance Standard Time')
    'MET'  = @('W. Europe Standard Time')
    'EET'  = @('FLE Standard Time', 'GTB Standard Time', 'Egypt Standard Time')
    'EEST' = @('FLE Standard Time', 'GTB Standard Time')
    'MSK'  = @('Russian Standard Time')
    'TRT'  = @('Turkey Standard Time')
    'SAST' = @('South Africa Standard Time')
    'CAT'  = @('South Africa Standard Time')
    'WAT'  = @('W. Central Africa Standard Time')
    'EAT'  = @('E. Africa Standard Time')
    'GST'  = @('Arabian Standard Time')
    'AST'  = @('Atlantic Standard Time', 'Arab Standard Time')
    'ADT'  = @('Atlantic Standard Time')
    'IRST' = @('Iran Standard Time')
    'AFT'  = @('Afghanistan Standard Time')
    'PKT'  = @('Pakistan Standard Time')
    'NPT'  = @('Nepal Standard Time')
    'ICT'  = @('SE Asia Standard Time')
    'WIB'  = @('SE Asia Standard Time')
    'SGT'  = @('Singapore Standard Time')
    'MYT'  = @('Singapore Standard Time')
    'PHT'  = @('Singapore Standard Time')
    'HKT'  = @('China Standard Time')
    'CST'  = @('Central Standard Time', 'China Standard Time', 'Central Standard Time (Mexico)', 'Cuba Standard Time')
    'CDT'  = @('Central Standard Time')
    'CT'   = @('Central Standard Time')
    'JST'  = @('Tokyo Standard Time')
    'KST'  = @('Korea Standard Time')
    'AWST' = @('W. Australia Standard Time')
    'ACST' = @('Cen. Australia Standard Time', 'AUS Central Standard Time')
    'ACDT' = @('Cen. Australia Standard Time')
    'AEST' = @('AUS Eastern Standard Time', 'E. Australia Standard Time')
    'AEDT' = @('AUS Eastern Standard Time')
    'NZST' = @('New Zealand Standard Time')
    'NZDT' = @('New Zealand Standard Time')
    'CHST' = @('West Pacific Standard Time')
    'HST'  = @('Hawaiian Standard Time')
    'AKST' = @('Alaskan Standard Time')
    'AKDT' = @('Alaskan Standard Time')
    'PST'  = @('Pacific Standard Time')
    'PDT'  = @('Pacific Standard Time')
    'PT'   = @('Pacific Standard Time')
    'MST'  = @('Mountain Standard Time', 'US Mountain Standard Time')
    'MDT'  = @('Mountain Standard Time')
    'MT'   = @('Mountain Standard Time')
    'EST'  = @('Eastern Standard Time')
    'EDT'  = @('Eastern Standard Time')
    'ET'   = @('Eastern Standard Time')
    'NST'  = @('Newfoundland Standard Time')
    'NDT'  = @('Newfoundland Standard Time')
    'BRT'  = @('E. South America Standard Time')
    'ART'  = @('Argentina Standard Time')
    'CLT'  = @('Pacific SA Standard Time')
    'COT'  = @('SA Pacific Standard Time')
    'PET'  = @('SA Pacific Standard Time')
    'VET'  = @('Venezuela Standard Time')
}

# Zones added on the very first run, before a configuration file exists.
$script:DefaultZones = @(
    @{ Label = 'New York'; ZoneId = 'Eastern Standard Time' }
    @{ Label = 'London'; ZoneId = 'GMT Standard Time' }
    @{ Label = 'Tokyo'; ZoneId = 'Tokyo Standard Time' }
)

# Sort columns in the order the S key cycles through them.
$script:SortColumns = @('City', 'Zone', 'Offset', 'Time')

# Lazily populated caches.
$script:CityCache = $null
$script:SystemZones = $null
$script:ZoneCache = @{}

#endregion

#region ------------------------------------------------------ Time zone logic

function Get-ClockCity {
    <#
    .SYNOPSIS
        Returns the built-in city table as objects (parsed once and cached).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if ($null -eq $script:CityCache) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($line in ($script:CityData -split '\r?\n')) {
            $parts = $line.Split('|')
            if ($parts.Count -ne 3) { continue }
            $list.Add([pscustomobject]@{
                    City    = $parts[0].Trim()
                    Country = $parts[1].Trim()
                    ZoneId  = $parts[2].Trim()
                })
        }
        $script:CityCache = $list
    }
    $script:CityCache
}

function Get-ClockSystemZone {
    <#
    .SYNOPSIS
        Returns all time zones known to the operating system (cached).
    #>
    [CmdletBinding()]
    [OutputType([TimeZoneInfo])]
    param()

    if ($null -eq $script:SystemZones) {
        $script:SystemZones = @([TimeZoneInfo]::GetSystemTimeZones())
    }
    $script:SystemZones
}

function Format-UtcOffset {
    <#
    .SYNOPSIS
        Formats a UTC offset as text, e.g. "UTC+05:30" or "UTC-08:00".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Offset
    )

    $sign = if ($Offset -lt [TimeSpan]::Zero) { '-' } else { '+' }
    $abs = $Offset.Duration()
    'UTC{0}{1:00}:{2:00}' -f $sign, [int][Math]::Floor($abs.TotalHours), $abs.Minutes
}

function Format-OffsetDifference {
    <#
    .SYNOPSIS
        Formats the difference between two offsets compactly, e.g. "+9h", "-5:30h".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Difference
    )

    if ($Difference -eq [TimeSpan]::Zero) { return '0h' }
    $sign = if ($Difference -lt [TimeSpan]::Zero) { '-' } else { '+' }
    $abs = $Difference.Duration()
    $text = '{0}{1}' -f $sign, [int][Math]::Floor($abs.TotalHours)
    if ($abs.Minutes -ne 0) { $text += ':{0:00}' -f $abs.Minutes }
    $text + 'h'
}

function ConvertFrom-OffsetText {
    <#
    .SYNOPSIS
        Parses a UTC offset such as "+2", "-5", "+05:30", "UTC-3" or "GMT+0545".
        Returns a TimeSpan, or $null when the text is not an offset.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($Text -notmatch '^\s*(?:UTC|GMT)?\s*([+-])\s*(\d{1,2})(?:[:.]?(\d{2}))?\s*$') { return $null }

    $hours = [int]$Matches[2]
    $minutes = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
    if ($hours -gt 14 -or $minutes -ge 60 -or ($hours -eq 14 -and $minutes -gt 0)) { return $null }

    $span = New-Object -TypeName TimeSpan -ArgumentList $hours, $minutes, 0
    if ($Matches[1] -eq '-') { $span = $span.Negate() }
    $span
}

function Get-ClockTimeZone {
    <#
    .SYNOPSIS
        Resolves a stored zone ID to a TimeZoneInfo object.
    .DESCRIPTION
        Zone IDs are either Windows time zone IDs ("Tokyo Standard Time") or
        fixed offsets in the form "UTC+02:00", which are turned into custom
        zones without daylight saving time. Returns $null for unknown IDs.
    #>
    [CmdletBinding()]
    [OutputType([TimeZoneInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$ZoneId
    )

    if ($script:ZoneCache.ContainsKey($ZoneId)) { return $script:ZoneCache[$ZoneId] }

    $zone = $null
    if ($ZoneId -match '^UTC[+-]\d{2}:\d{2}$') {
        $offset = ConvertFrom-OffsetText -Text $ZoneId
        if ($null -ne $offset) {
            $zone = [TimeZoneInfo]::CreateCustomTimeZone($ZoneId, $offset, $ZoneId, $ZoneId)
        }
    }
    else {
        try {
            $zone = [TimeZoneInfo]::FindSystemTimeZoneById($ZoneId)
        }
        catch {
            Write-Verbose -Message "Time zone '$ZoneId' was not found: $($_.Exception.Message)"
        }
    }

    if ($null -ne $zone) { $script:ZoneCache[$ZoneId] = $zone }
    $zone
}

function Get-ZoneShortLabel {
    <#
    .SYNOPSIS
        Builds a short display label from a system time zone, e.g.
        "Pacific Standard Time" -> "Pacific".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [TimeZoneInfo]$Zone
    )

    $Zone.Id -replace ' Standard Time', '' -replace ' Time$', ''
}

function Find-ClockZone {
    <#
    .SYNOPSIS
        Searches for time zones matching a city, country, abbreviation, offset
        or Windows time zone name.
    .OUTPUTS
        Objects with Label, ZoneId and Detail properties, best matches first.
    .EXAMPLE
        Find-ClockZone -Query 'EST'
    .EXAMPLE
        Find-ClockZone -Query '+5:30'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxResults', Justification = 'Used inside the $addCandidate script block.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Query,

        [Parameter()]
        [ValidateRange(1, 500)]
        [int]$MaxResults = 50
    )

    $q = $Query.Trim()
    if (-not $q) { return }

    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase

    # Adds a candidate to the result list, skipping duplicates and IDs that
    # do not exist on this machine.
    $addCandidate = {
        param([string]$Label, [string]$ZoneId, [string]$Detail)
        if ($results.Count -ge $MaxResults) { return }
        $zone = Get-ClockTimeZone -ZoneId $ZoneId
        if ($null -eq $zone) { return }
        if (-not $seen.Add("$Label|$ZoneId")) { return }
        if (-not $Detail) { $Detail = $zone.DisplayName }
        $results.Add([pscustomobject]@{ Label = $Label; ZoneId = $ZoneId; Detail = $Detail })
    }

    # 1. A UTC offset: offer a fixed-offset zone plus every system zone whose
    #    standard offset matches (those also follow daylight saving rules).
    $offset = ConvertFrom-OffsetText -Text $q
    if ($null -ne $offset) {
        $fixedId = Format-UtcOffset -Offset $offset
        & $addCandidate $fixedId $fixedId "Fixed offset $fixedId (no daylight saving time)"
        foreach ($zone in Get-ClockSystemZone) {
            if ($zone.BaseUtcOffset -eq $offset) {
                & $addCandidate (Get-ZoneShortLabel -Zone $zone) $zone.Id $null
            }
        }
        return $results.ToArray()
    }

    # 2. A known abbreviation (exact match). Ambiguous abbreviations get the
    #    zone name appended so the entries can be told apart, e.g. "CST (China)".
    $key = $q.ToUpperInvariant()
    $isAbbreviation = $script:Abbreviations.ContainsKey($key)
    if ($isAbbreviation) {
        $zoneIds = @($script:Abbreviations[$key])
        foreach ($zoneId in $zoneIds) {
            $zone = Get-ClockTimeZone -ZoneId $zoneId
            if ($null -eq $zone) { continue }
            $label = if ($zoneIds.Count -gt 1) { '{0} ({1})' -f $key, (Get-ZoneShortLabel -Zone $zone) } else { $key }
            & $addCandidate $label $zoneId $null
        }
    }

    # 3. Cities and countries from the built-in table, ranked by match quality.
    #    After an abbreviation hit only strong matches are added, so "EST"
    #    does not also list every city containing "est" (Budapest, ...).
    $maxRank = if ($isAbbreviation) { 1 } else { 4 }
    $ranked = foreach ($city in Get-ClockCity) {
        $rank = -1
        if ($city.City -eq $q) { $rank = 0 }
        elseif ($city.City.StartsWith($q, $ignoreCase)) { $rank = 1 }
        elseif ($city.City.IndexOf($q, $ignoreCase) -ge 0) { $rank = 2 }
        elseif ($city.Country -eq $q) { $rank = 3 }
        elseif ($city.Country.IndexOf($q, $ignoreCase) -ge 0) { $rank = 4 }
        if ($rank -ge 0 -and $rank -le $maxRank) { [pscustomobject]@{ Rank = $rank; City = $city } }
    }
    foreach ($match in ($ranked | Sort-Object -Property Rank, { $_.City.City })) {
        $zone = Get-ClockTimeZone -ZoneId $match.City.ZoneId
        if ($null -eq $zone) { continue }
        & $addCandidate $match.City.City $match.City.ZoneId ('{0} - {1}' -f $match.City.Country, $zone.DisplayName)
    }

    # 4. System time zones: city names listed in the display name (for
    #    example "(UTC+09:00) Osaka, Sapporo, Tokyo"), then the zone ID and
    #    standard/daylight names.
    if ($q.Length -ge 2 -and -not $isAbbreviation) {
        foreach ($zone in Get-ClockSystemZone) {
            $label = $null
            $cityList = $zone.DisplayName
            $paren = $cityList.IndexOf(')')
            if ($paren -ge 0) { $cityList = $cityList.Substring($paren + 1) }
            foreach ($part in $cityList.Split(',')) {
                $name = $part.Trim()
                if ($name.IndexOf($q, $ignoreCase) -ge 0) { $label = $name; break }
            }
            if (-not $label) {
                foreach ($name in @($zone.Id, $zone.StandardName, $zone.DaylightName)) {
                    if ($name.IndexOf($q, $ignoreCase) -ge 0) { $label = Get-ZoneShortLabel -Zone $zone; break }
                }
            }
            if ($label) { & $addCandidate $label $zone.Id $null }
        }
    }

    $results.ToArray()
}

function Get-ClockRow {
    <#
    .SYNOPSIS
        Calculates everything shown for one zone at a given instant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Entry,

        [Parameter(Mandatory)]
        [DateTimeOffset]$Instant,

        [Parameter(Mandatory)]
        [TimeSpan]$LocalOffset,

        [Parameter()]
        [int]$BusinessStart = 9,

        [Parameter()]
        [int]$BusinessEnd = 17,

        [Parameter()]
        [switch]$IsLocal
    )

    $zone = Get-ClockTimeZone -ZoneId $Entry.ZoneId
    if ($null -eq $zone) {
        # Unknown ID (e.g. config copied from another machine). Keep the row so
        # the user can see and remove it, rather than silently dropping it.
        return [pscustomobject]@{
            Entry = $Entry; Label = $Entry.Label; ZoneId = $Entry.ZoneId; Valid = $false
            IsLocal = [bool]$IsLocal; ZoneName = '(unknown time zone)'; Time = $Instant
            Offset = [TimeSpan]::Zero; OffsetText = ''; DiffText = ''; DayName = ''
            IsDay = $true; Status = 'Unknown'
        }
    }

    $time = [TimeZoneInfo]::ConvertTime($Instant, $zone)
    $offset = $time.Offset
    $zoneName = if ($Entry.ZoneId -match '^UTC[+-]') { "$($Entry.ZoneId) (fixed)" }
    elseif ($zone.IsDaylightSavingTime($time)) { $zone.DaylightName }
    else { $zone.StandardName }

    # Day/night uses a simple 06:00-18:00 rule on the zone's wall clock.
    $hour = $time.TimeOfDay.TotalHours
    $isWeekend = $time.DayOfWeek -eq [DayOfWeek]::Saturday -or $time.DayOfWeek -eq [DayOfWeek]::Sunday
    $status = if ($isWeekend) { 'Weekend' }
    elseif ($hour -ge $BusinessStart -and $hour -lt $BusinessEnd) { 'Business' }
    else { 'Off hours' }

    [pscustomobject]@{
        Entry      = $Entry
        Label      = $Entry.Label
        ZoneId     = $Entry.ZoneId
        Valid      = $true
        IsLocal    = [bool]$IsLocal
        ZoneName   = $zoneName
        Time       = $time
        Offset     = $offset
        OffsetText = Format-UtcOffset -Offset $offset
        DiffText   = Format-OffsetDifference -Difference ($offset - $LocalOffset)
        DayName    = $time.ToString('ddd', [Globalization.CultureInfo]::CurrentCulture)
        IsDay      = $hour -ge 6 -and $hour -lt 18
        Status     = $status
    }
}

function Test-ClockRowFilter {
    <#
    .SYNOPSIS
        Returns $true when a row matches the filter text (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Filter
    )

    if (-not $Filter) { return $true }
    $zone = Get-ClockTimeZone -ZoneId $Row.ZoneId
    $fields = @($Row.Label, $Row.ZoneName, $Row.ZoneId, $Row.OffsetText, $Row.Status, $Row.DayName)
    if ($null -ne $zone) { $fields += @($zone.StandardName, $zone.DaylightName, $zone.DisplayName) }
    foreach ($field in $fields) {
        if ($field -and $field.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    $false
}

function ConvertFrom-WallClockText {
    <#
    .SYNOPSIS
        Parses user-entered date/time text into a wall-clock DateTime
        (Kind = Unspecified) for the given zone. Returns $null on failure.
    .DESCRIPTION
        Accepts "now", times such as "14:30", "9am", "6:15 pm" (meaning today
        in the given zone), optional "today"/"tomorrow"/"yesterday" prefixes,
        and anything [datetime]::TryParse understands in the current or the
        invariant culture ("2026-12-24 18:00", "Dec 24 2026 6 PM", ...).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [TimeZoneInfo]$Zone
    )

    $now = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $Zone).DateTime
    $t = $Text.Trim()
    $dayShift = 0
    $hasDayWord = $false

    if ($t -eq 'now') { return $now }
    if ($t -match '^(today|tomorrow|yesterday)\b\s*(.*)$') {
        $hasDayWord = $true
        $dayShift = switch ($Matches[1].ToLowerInvariant()) { 'tomorrow' { 1 } 'yesterday' { -1 } default { 0 } }
        $t = $Matches[2]
        if (-not $t) { return $now.AddDays($dayShift) }
    }

    # Time of day only.
    if ($t -match '^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(a\.?m?\.?|p\.?m?\.?)?$') {
        $h = [int]$Matches[1]
        $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $s = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        $suffix = $Matches[4]
        if ($suffix) {
            if ($h -lt 1 -or $h -gt 12) { return $null }
            $h = $h % 12
            if ($suffix.StartsWith('p', [StringComparison]::OrdinalIgnoreCase)) { $h += 12 }
        }
        elseif (-not $Matches[2]) {
            # A bare number such as "15" is only accepted as an hour.
            if ($h -gt 23) { return $null }
        }
        if ($h -gt 23 -or $m -gt 59 -or $s -gt 59) { return $null }
        return $now.Date.AddDays($dayShift).Add((New-Object -TypeName TimeSpan -ArgumentList $h, $m, $s))
    }
    if ($hasDayWord) { return $null }

    # Full date and/or time. Normalise "6pm" to "6 PM", which TryParse accepts.
    $normalized = $t -replace '(\d)\s*([ap])\.?m\.?$', '$1 $2M'
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces
    $parsed = [datetime]::MinValue
    foreach ($culture in @([Globalization.CultureInfo]::CurrentCulture, [Globalization.CultureInfo]::InvariantCulture)) {
        if ([datetime]::TryParse($normalized, $culture, $styles, [ref]$parsed)) {
            return [datetime]::SpecifyKind($parsed, [DateTimeKind]::Unspecified)
        }
    }
    $null
}

function ConvertFrom-ClockTimeText {
    <#
    .SYNOPSIS
        Parses "<date/time> [zone]" text into an absolute instant.
    .DESCRIPTION
        The trailing words may name a zone (a label in the list, a city, an
        abbreviation or an offset). Without one, the time is interpreted in
        DefaultZone. Throws when the text cannot be understood.
    .OUTPUTS
        Object with Instant (DateTimeOffset) and Description properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [object]$DefaultEntry,

        [Parameter()]
        [object[]]$Entries = @()
    )

    $tokens = @($Text.Trim() -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { throw 'Please enter a date and/or time.' }

    # Try the longest possible date/time prefix first; the rest is the zone.
    for ($n = $tokens.Count; $n -ge 1; $n--) {
        $dateText = $tokens[0..($n - 1)] -join ' '
        $zoneText = if ($n -lt $tokens.Count) { $tokens[$n..($tokens.Count - 1)] -join ' ' } else { '' }

        $entry = $DefaultEntry
        if ($zoneText) {
            $entry = $Entries | Where-Object { $_.Label -eq $zoneText } | Select-Object -First 1
            if (-not $entry) { $entry = Find-ClockZone -Query $zoneText -MaxResults 1 | Select-Object -First 1 }
            if (-not $entry) { continue }
        }

        $zone = Get-ClockTimeZone -ZoneId $entry.ZoneId
        if ($null -eq $zone) { continue }
        $wall = ConvertFrom-WallClockText -Text $dateText -Zone $zone
        if ($null -eq $wall) { continue }

        if ($zone.IsInvalidTime($wall)) {
            throw ('{0:yyyy-MM-dd HH:mm} does not exist in {1} (skipped by a daylight saving time change).' -f $wall, $entry.Label)
        }
        $utc = [TimeZoneInfo]::ConvertTimeToUtc($wall, $zone)
        return [pscustomobject]@{
            Instant     = New-Object -TypeName DateTimeOffset -ArgumentList $utc
            Description = '{0:ddd yyyy-MM-dd HH:mm:ss} in {1}' -f $wall, $entry.Label
        }
    }
    throw "Could not understand '$Text'. Try e.g. '14:30', '9am Tokyo' or '2026-12-24 18:00 PST'."
}

#endregion

#region ------------------------------------------------------- Persistence

function Import-ClockConfig {
    <#
    .SYNOPSIS
        Loads the saved zone list and preferences.
    .DESCRIPTION
        Falls back to the backup file if the main file is unreadable. A
        damaged file is copied aside (PSClock.json.corrupt-<timestamp>) so the
        data is never silently lost. When no file exists yet the default
        zones are returned.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $config = @{
        Zones      = New-Object -TypeName 'System.Collections.Generic.List[object]'
        Sort       = 'City'
        Descending = $false
        TwelveHour = $false
        Warning    = $null
    }

    if (-not (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "$Path.bak")) {
        foreach ($zone in $script:DefaultZones) {
            $config.Zones.Add([pscustomobject]@{ Label = $zone.Label; ZoneId = $zone.ZoneId })
        }
        return $config
    }

    $aside = $null
    foreach ($candidate in @($Path, "$Path.bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $data = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
            $properties = $data.PSObject.Properties
            if ($properties['Zones']) {
                foreach ($zone in @($data.Zones)) {
                    if ($null -eq $zone -or -not $zone.PSObject.Properties['ZoneId']) { continue }
                    $label = if ($zone.PSObject.Properties['Label'] -and $zone.Label) { [string]$zone.Label } else { [string]$zone.ZoneId }
                    $config.Zones.Add([pscustomobject]@{ Label = $label; ZoneId = [string]$zone.ZoneId })
                }
            }
            if ($properties['Sort'] -and $script:SortColumns -contains $data.Sort) { $config.Sort = [string]$data.Sort }
            if ($properties['Descending']) { $config.Descending = [bool]$data.Descending }
            if ($properties['TwelveHour']) { $config.TwelveHour = [bool]$data.TwelveHour }
            if ($candidate -ne $Path) {
                $config.Warning = 'Settings file was damaged; restored from backup.'
                if ($aside) { $config.Warning += " The damaged file was kept as $aside" }
            }
            return $config
        }
        catch {
            $config.Zones.Clear()
            if ($candidate -eq $Path) {
                $aside = '{0}.corrupt-{1:yyyyMMddHHmmss}' -f $Path, (Get-Date)
                Copy-Item -LiteralPath $Path -Destination $aside -ErrorAction SilentlyContinue
                $config.Warning = "Settings file could not be read; a copy was saved as $aside"
            }
        }
    }
    $config
}

function Export-ClockConfig {
    <#
    .SYNOPSIS
        Saves the zone list and preferences as JSON.
    .DESCRIPTION
        Writes to a temporary file first and then swaps it in, keeping the
        previous version as <file>.bak, so a crash or full disk can never
        leave a half-written settings file behind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $path = $State.ConfigPath
    $directory = Split-Path -Path $path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $data = [ordered]@{
        Version    = 1
        Sort       = $State.Sort
        Descending = $State.Descending
        TwelveHour = $State.TwelveHour
        Zones      = @(foreach ($zone in $State.Zones) { [ordered]@{ Label = $zone.Label; ZoneId = $zone.ZoneId } })
    }
    $json = ConvertTo-Json -InputObject $data -Depth 5

    $temp = "$path.tmp"
    [IO.File]::WriteAllText($temp, $json, (New-Object -TypeName Text.UTF8Encoding -ArgumentList $false))
    if (Test-Path -LiteralPath $path) {
        try {
            [IO.File]::Replace($temp, $path, "$path.bak")
        }
        catch {
            # File.Replace is not supported on every file system; fall back.
            Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
            Move-Item -LiteralPath $temp -Destination $path -Force
        }
    }
    else {
        Move-Item -LiteralPath $temp -Destination $path -Force
    }
}

function Save-ClockState {
    <#
    .SYNOPSIS
        Persists the state, reporting failures on the status line instead of
        crashing the user interface. Returns $true when the save succeeded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    try {
        Export-ClockConfig -State $State
        $true
    }
    catch {
        Set-ClockMessage -State $State -Text "Could not save settings: $($_.Exception.Message)" -IsError
        $false
    }
}

#endregion

#region ---------------------------------------------------------- UI state

function New-ClockState {
    <#
    .SYNOPSIS
        Creates the hashtable holding the complete application state.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter()]
        [bool]$Unicode = $false,

        [Parameter()]
        [int]$BusinessStart = 9,

        [Parameter()]
        [int]$BusinessEnd = 17
    )

    $config = Import-ClockConfig -Path $ConfigPath
    $localZone = [TimeZoneInfo]::Local
    $script:ZoneCache[$localZone.Id] = $localZone

    $baseFg = [Console]::ForegroundColor
    $baseBg = [Console]::BackgroundColor
    if ([int]$baseFg -lt 0) { $baseFg = [ConsoleColor]::Gray }
    if ([int]$baseBg -lt 0) { $baseBg = [ConsoleColor]::Black }

    $symbols = if ($Unicode) {
        @{ Day = [string][char]0x2600; Night = [string][char]0x263E; Local = [string][char]0x25BA
            Line = [string][char]0x2500; Up = [string][char]0x2191; Down = [string][char]0x2193; Cursor = [string][char]0x2588 }
    }
    else {
        @{ Day = ''; Night = ''; Local = '>'; Line = '-'; Up = '^'; Down = 'v'; Cursor = '_' }
    }

    @{
        Running       = $true
        Mode          = 'Normal'          # Normal, Filter, AddQuery, Convert, ConfirmClear, Help
        ConfigPath    = $ConfigPath
        Zones         = $config.Zones
        LocalEntry    = [pscustomobject]@{ Label = 'Local time'; ZoneId = $localZone.Id }
        Sort          = $config.Sort
        Descending    = $config.Descending
        TwelveHour    = $config.TwelveHour
        BusinessStart = $BusinessStart
        BusinessEnd   = $BusinessEnd
        Filter        = ''
        Input         = ''
        Selected      = 0                 # 0 = local row, 1..n = listed zones
        Scroll        = 0
        PendingSelect = $null
        VisibleRows   = @()
        Results       = @()
        ResultIndex   = 0
        RefInstant    = $null             # set while showing a converted time
        RefText       = ''
        Message       = $(if ($config.Warning) { $config.Warning } else { '' })
        MessageError  = [bool]$config.Warning
        MessageUntil  = $(if ($config.Warning) { (Get-Date).AddSeconds(10) } else { [datetime]::MinValue })
        Symbols       = $symbols
        Theme         = @{
            Fg = $baseFg; Bg = $baseBg
            TitleFg = [ConsoleColor]::White
            TitleBg = $(if ($baseBg -eq [ConsoleColor]::DarkBlue) { [ConsoleColor]::DarkMagenta } else { [ConsoleColor]::DarkBlue })
            ConvertBg = [ConsoleColor]::DarkMagenta
            Header = [ConsoleColor]::Yellow
            Dim = [ConsoleColor]::DarkGray
            Accent = [ConsoleColor]::Cyan
            LocalFg = [ConsoleColor]::White; LocalBg = [ConsoleColor]::DarkCyan
            SelFg = [ConsoleColor]::Black; SelBg = [ConsoleColor]::Gray
            LocalSelFg = [ConsoleColor]::Black; LocalSelBg = [ConsoleColor]::Cyan
            Business = [ConsoleColor]::Green; OffHours = [ConsoleColor]::DarkYellow; Weekend = [ConsoleColor]::Magenta
            Day = [ConsoleColor]::Yellow; Night = [ConsoleColor]::Blue
            Error = [ConsoleColor]::Red; Ok = [ConsoleColor]::Green
        }
    }
}

function Set-ClockMessage {
    <#
    .SYNOPSIS
        Shows a transient message on the status line.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only changes in-memory UI state.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter()]
        [switch]$IsError
    )

    $State.Message = $Text
    $State.MessageError = [bool]$IsError
    $State.MessageUntil = (Get-Date).AddSeconds(6)
}

function Update-ClockRows {
    <#
    .SYNOPSIS
        Recalculates the visible rows (local zone first, then the filtered and
        sorted list) for the current or converted instant.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Updates the full row collection.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only changes in-memory UI state.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $instant = if ($null -ne $State.RefInstant) { $State.RefInstant } else { [DateTimeOffset]::UtcNow }
    $localOffset = [TimeZoneInfo]::Local.GetUtcOffset($instant)
    $common = @{ Instant = $instant; LocalOffset = $localOffset; BusinessStart = $State.BusinessStart; BusinessEnd = $State.BusinessEnd }

    $localRow = Get-ClockRow -Entry $State.LocalEntry -IsLocal @common
    $rows = @(foreach ($entry in $State.Zones) {
            $row = Get-ClockRow -Entry $entry @common
            if (Test-ClockRowFilter -Row $row -Filter $State.Filter) { $row }
        })

    $sortKeys = switch ($State.Sort) {
        'Zone' { @({ $_.ZoneName }, { $_.Label }) }
        'Offset' { @({ $_.Offset.Ticks }, { $_.Label }) }
        'Time' { @({ $_.Time.TimeOfDay.Ticks }, { $_.Label }) }
        default { @({ $_.Label }, { $_.ZoneName }) }
    }
    if ($rows.Count -gt 1) {
        $rows = @($rows | Sort-Object -Property $sortKeys -Descending:$State.Descending)
    }

    $State.VisibleRows = @($localRow) + $rows

    if ($null -ne $State.PendingSelect) {
        for ($i = 1; $i -lt $State.VisibleRows.Count; $i++) {
            if ([object]::ReferenceEquals($State.VisibleRows[$i].Entry, $State.PendingSelect)) { $State.Selected = $i; break }
        }
        $State.PendingSelect = $null
    }
    $State.Selected = [Math]::Max(0, [Math]::Min($State.Selected, $State.VisibleRows.Count - 1))
}

#endregion

#region ------------------------------------------------------------ Rendering

function Format-ClockCell {
    <#
    .SYNOPSIS
        Pads or truncates text to exactly the given width.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width) }
    $Text.PadRight($Width)
}

function New-ClockLine {
    <#
    .SYNOPSIS
        Creates an empty screen line; Background fills the unused part.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    param(
        [Parameter(Mandatory)]
        [ConsoleColor]$Background
    )

    @{ Bg = $Background; Segments = New-Object -TypeName 'System.Collections.Generic.List[object]' }
}

function Add-ClockSegment {
    <#
    .SYNOPSIS
        Appends a coloured piece of text to a screen line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Line,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Text = '',

        [Parameter(Mandatory)]
        [ConsoleColor]$Foreground,

        [Parameter()]
        [Nullable[ConsoleColor]]$Background
    )

    $bg = if ($null -ne $Background) { [ConsoleColor]$Background } else { $Line.Bg }
    $Line.Segments.Add(@{ Text = $Text; Fg = $Foreground; Bg = $bg })
}

function Add-ClockRowLine {
    <#
    .SYNOPSIS
        Renders one time zone row into a screen line.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter()]
        [bool]$Selected
    )

    $theme = $State.Theme
    $sym = $State.Symbols
    if ($Row.IsLocal -and $Selected) { $fg = $theme.LocalSelFg; $bg = $theme.LocalSelBg }
    elseif ($Row.IsLocal) { $fg = $theme.LocalFg; $bg = $theme.LocalBg }
    elseif ($Selected) { $fg = $theme.SelFg; $bg = $theme.SelBg }
    else { $fg = $theme.Fg; $bg = $theme.Bg }
    $highlight = $Row.IsLocal -or $Selected

    $line = New-ClockLine -Background $bg
    $marker = if ($Row.IsLocal) { $sym.Local } else { ' ' }
    Add-ClockSegment -Line $line -Text (Format-ClockCell -Text $marker -Width 2) -Foreground $fg
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.Label -Width 20) + ' ') -Foreground $fg

    if (-not $Row.Valid) {
        Add-ClockSegment -Line $line -Text "Time zone '$($Row.ZoneId)' is not available on this system" -Foreground $(if ($highlight) { $fg } else { $theme.Error })
        return $line
    }

    $timeFormat = if ($State.TwelveHour) { 'hh:mm:ss tt' } else { 'HH:mm:ss' }
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $sunText = if ($Row.IsDay) { "$($sym.Day) Day".Trim() } else { "$($sym.Night) Night".Trim() }
    $sunColor = if ($highlight) { $fg } elseif ($Row.IsDay) { $theme.Day } else { $theme.Night }
    $statusColor = if ($highlight) { $fg } else {
        switch ($Row.Status) { 'Business' { $theme.Business } 'Weekend' { $theme.Weekend } default { $theme.OffHours } }
    }

    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.Time.ToString($timeFormat, $invariant) -Width 11) + ' ') -Foreground $fg
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.Time.ToString('yyyy-MM-dd', $invariant) -Width 10) + ' ') -Foreground $fg
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.DayName -Width 4) + ' ') -Foreground $fg
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $sunText -Width 7) + ' ') -Foreground $sunColor
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.Status -Width 9) + ' ') -Foreground $statusColor
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.OffsetText -Width 9) + ' ') -Foreground $fg
    Add-ClockSegment -Line $line -Text ((Format-ClockCell -Text $Row.DiffText -Width 7) + ' ') -Foreground $fg
    Add-ClockSegment -Line $line -Text $Row.ZoneName -Foreground $fg
    $line
}

function Get-ClockHelpText {
    <#
    .SYNOPSIS
        Returns the lines shown on the help screen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $help = @(
        'PSClock - keyboard reference'
        ''
        '  Up/Down, PgUp/PgDn, Home/End   Move the selection'
        '  A  or Insert                   Add a time zone (city, country, abbreviation or offset)'
        '  D  or Delete                   Remove the selected time zone'
        '  /  or F                        Filter the list by city or time zone name (Esc clears)'
        "  S                              Cycle sort column: $($script:SortColumns -join ' > ')"
        '  R                              Reverse the sort order'
        '  T                              Convert a date/time into all zones'
        '  L                              Back to live time (after a conversion)'
        '  H                              Toggle 12/24 hour clock'
        '  C                              Clear the whole list (asks for confirmation)'
        '  Q  or Ctrl+C                   Quit'
        ''
        'Adding zones - examples:  Tokyo   brazil   EST   CET   IST   +2   -5   +5:30   UTC-3'
        'Converting - the time is read in the selected row''s zone unless a zone follows it:'
        '  14:30     9am Tokyo     tomorrow 8:00 +2     2026-12-24 18:00 PST     now'
        ''
        ('Business hours are Mon-Fri {0:00}:00-{1:00}:00; day is 06:00-18:00 local wall-clock time.' -f $State.BusinessStart, $State.BusinessEnd)
        'Sort by Time orders zones by their time of day, ignoring the date.'
        "Settings file: $($State.ConfigPath)"
        ''
        'Press any key to return.'
    )
    $help | Write-Output
}

function Get-ClockFrame {
    <#
    .SYNOPSIS
        Builds the complete screen (a list of lines) for the current state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [int]$Width,

        [Parameter(Mandatory)]
        [int]$Height
    )

    $theme = $State.Theme
    $sym = $State.Symbols
    $lines = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $blank = { New-ClockLine -Background $theme.Bg }

    if ($Width -lt 40 -or $Height -lt 12) {
        $line = & $blank
        Add-ClockSegment -Line $line -Text 'Window too small for PSClock - please enlarge it (Q quits).' -Foreground $theme.Error
        $lines.Add($line)
        while ($lines.Count -lt $Height) { $lines.Add((& $blank)) }
        return $lines.ToArray()
    }

    Update-ClockRows -State $State
    $rows = $State.VisibleRows
    $converted = $null -ne $State.RefInstant

    # --- Row 0: title bar
    $titleBg = if ($converted) { $theme.ConvertBg } else { $theme.TitleBg }
    $title = New-ClockLine -Background $titleBg
    $left = ' PSClock - World Clock '
    $right = if ($converted) { "Converted: $($State.RefText)  [L] live " }
    else {
        $fmt = if ($State.TwelveHour) { 'ddd yyyy-MM-dd hh:mm:ss tt' } else { 'ddd yyyy-MM-dd HH:mm:ss' }
        'Live  {0} ' -f [DateTime]::Now.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
    }
    Add-ClockSegment -Line $title -Text $left -Foreground $theme.TitleFg
    Add-ClockSegment -Line $title -Text ($right.PadLeft([Math]::Max(0, $Width - $left.Length))) -Foreground $theme.TitleFg
    $lines.Add($title)

    # --- Row 1: sort / filter information
    $info = & $blank
    $arrow = if ($State.Descending) { $sym.Down } else { $sym.Up }
    Add-ClockSegment -Line $info -Text ' Sort: ' -Foreground $theme.Dim
    Add-ClockSegment -Line $info -Text "$($State.Sort) $arrow" -Foreground $theme.Accent
    Add-ClockSegment -Line $info -Text '   Filter: ' -Foreground $theme.Dim
    Add-ClockSegment -Line $info -Text $(if ($State.Filter) { "'$($State.Filter)'" } else { '(none)' }) -Foreground $(if ($State.Filter) { $theme.Accent } else { $theme.Dim })
    Add-ClockSegment -Line $info -Text ('   Showing {0} of {1} zones' -f ($rows.Count - 1), $State.Zones.Count) -Foreground $theme.Dim
    $lines.Add($info)

    $footerTop = $Height - 4          # separator line above the footer
    $bodyTop = 2

    if ($State.Mode -eq 'Help') {
        foreach ($text in (Get-ClockHelpText -State $State)) {
            if ($lines.Count -ge $footerTop) { break }
            $line = & $blank
            Add-ClockSegment -Line $line -Text " $text" -Foreground $(if ($lines.Count -eq $bodyTop) { $theme.Header } else { $theme.Fg })
            $lines.Add($line)
        }
    }
    elseif ($State.Mode -eq 'AddQuery') {
        # Live search results while the user types.
        $header = & $blank
        $headerText = if ($State.Input) { " Matches for '$($State.Input)' ($($State.Results.Count)) - Up/Down to choose, Enter to add" } else { ' Start typing to search...' }
        Add-ClockSegment -Line $header -Text $headerText -Foreground $theme.Header
        $lines.Add($header)
        $capacity = $footerTop - $lines.Count
        $start = [Math]::Max(0, [Math]::Min($State.ResultIndex - $capacity + 1, $State.Results.Count - $capacity))
        $start = [Math]::Max(0, [Math]::Min($start, $State.ResultIndex))
        for ($i = $start; $i -lt $State.Results.Count -and $lines.Count -lt $footerTop; $i++) {
            $result = $State.Results[$i]
            $isSel = $i -eq $State.ResultIndex
            $line = New-ClockLine -Background $(if ($isSel) { $theme.SelBg } else { $theme.Bg })
            $fg = if ($isSel) { $theme.SelFg } else { $theme.Fg }
            Add-ClockSegment -Line $line -Text ('  ' + (Format-ClockCell -Text $result.Label -Width 22) + ' ') -Foreground $fg
            Add-ClockSegment -Line $line -Text $result.Detail -Foreground $(if ($isSel) { $fg } else { $theme.Dim })
            $lines.Add($line)
        }
    }
    else {
        # --- Column header, separator, pinned local row, scrolling list.
        $header = & $blank
        $headerText = '  ' + (Format-ClockCell 'City' 20) + ' ' + (Format-ClockCell 'Time' 11) + ' ' + (Format-ClockCell 'Date' 10) + ' ' +
        (Format-ClockCell 'Day' 4) + ' ' + (Format-ClockCell 'Sun' 7) + ' ' + (Format-ClockCell 'Status' 9) + ' ' +
        (Format-ClockCell 'Offset' 9) + ' ' + (Format-ClockCell 'vsLocal' 7) + ' ' + 'Time zone'
        Add-ClockSegment -Line $header -Text $headerText -Foreground $theme.Header
        $lines.Add($header)

        $separator = & $blank
        Add-ClockSegment -Line $separator -Text ($sym.Line * $Width) -Foreground $theme.Dim
        $lines.Add($separator)

        $lines.Add((Add-ClockRowLine -State $State -Row $rows[0] -Selected ($State.Selected -eq 0)))

        $capacity = $footerTop - $lines.Count
        $count = $rows.Count - 1
        if ($count -eq 0) {
            $line = & $blank
            $emptyText = if ($State.Filter) { "   No zones match the filter '$($State.Filter)'." } else { '   No time zones yet - press A to add one.' }
            Add-ClockSegment -Line $line -Text $emptyText -Foreground $theme.Dim
            $lines.Add($line)
        }
        else {
            # Keep the selection visible (list index = Selected - 1).
            $listIndex = $State.Selected - 1
            if ($listIndex -ge 0) {
                if ($listIndex -lt $State.Scroll) { $State.Scroll = $listIndex }
                if ($listIndex -ge $State.Scroll + $capacity) { $State.Scroll = $listIndex - $capacity + 1 }
            }
            $State.Scroll = [Math]::Max(0, [Math]::Min($State.Scroll, $count - $capacity))
            for ($i = $State.Scroll; $i -lt $count -and $lines.Count -lt $footerTop; $i++) {
                $lines.Add((Add-ClockRowLine -State $State -Row $rows[$i + 1] -Selected ($State.Selected -eq $i + 1)))
            }
        }
    }

    while ($lines.Count -lt $footerTop) { $lines.Add((& $blank)) }

    # --- Footer: separator (with scroll hints), legend, keys, input/message.
    $separator = & $blank
    $scrollHint = ''
    if ($State.Mode -notin 'Help', 'AddQuery') {
        $capacity = $footerTop - 5
        $count = $rows.Count - 1
        if ($count -gt $capacity) {
            $scrollHint = ' {0}-{1} of {2} {3}{4} ' -f ($State.Scroll + 1), [Math]::Min($count, $State.Scroll + $capacity), $count, $(if ($State.Scroll -gt 0) { $sym.Up } else { '' }), $(if ($State.Scroll + $capacity -lt $count) { $sym.Down } else { '' })
        }
    }
    $lineWidth = [Math]::Max(0, $Width - $scrollHint.Length)
    Add-ClockSegment -Line $separator -Text ($sym.Line * $lineWidth) -Foreground $theme.Dim
    Add-ClockSegment -Line $separator -Text $scrollHint -Foreground $theme.Accent
    $lines.Add($separator)

    $legend = & $blank
    Add-ClockSegment -Line $legend -Text ' Business' -Foreground $theme.Business
    Add-ClockSegment -Line $legend -Text (' Mon-Fri {0:00}-{1:00}h  ' -f $State.BusinessStart, $State.BusinessEnd) -Foreground $theme.Dim
    Add-ClockSegment -Line $legend -Text 'Off hours' -Foreground $theme.OffHours
    Add-ClockSegment -Line $legend -Text '  ' -Foreground $theme.Dim
    Add-ClockSegment -Line $legend -Text 'Weekend' -Foreground $theme.Weekend
    Add-ClockSegment -Line $legend -Text '   ' -Foreground $theme.Dim
    Add-ClockSegment -Line $legend -Text ("$($sym.Day) Day".Trim()) -Foreground $theme.Day
    Add-ClockSegment -Line $legend -Text ' 06-18h  ' -Foreground $theme.Dim
    Add-ClockSegment -Line $legend -Text ("$($sym.Night) Night".Trim()) -Foreground $theme.Night
    Add-ClockSegment -Line $legend -Text '   ' -Foreground $theme.Dim
    Add-ClockSegment -Line $legend -Text "$($sym.Local) Local time zone" -Foreground $theme.Accent
    $lines.Add($legend)

    $keys = & $blank
    $keyText = switch ($State.Mode) {
        'Filter' { ' Type to filter by city or zone name   Up/Down select   Enter keep filter   Esc clear filter' }
        'AddQuery' { ' City, country, abbreviation (EST, CET) or offset (+2, -5:30)   Up/Down choose   Enter add   Esc cancel' }
        'Convert' { ' e.g. 14:30 | 9am Tokyo | tomorrow 8:00 +2 | 2026-12-24 18:00 PST   Up/Down change source zone   Esc cancel' }
        'ConfirmClear' { ' Y = remove all zones from the list   any other key = cancel' }
        'Help' { ' Press any key to return' }
        default {
            $liveKey = if ($converted) { 'L live  ' } else { '' }
            " A add  D remove  / filter  S sort  R reverse  T convert  ${liveKey}H 12/24h  C clear  ? help  Q quit"
        }
    }
    Add-ClockSegment -Line $keys -Text $keyText -Foreground $theme.Dim
    $lines.Add($keys)

    $status = & $blank
    switch ($State.Mode) {
        'Filter' {
            Add-ClockSegment -Line $status -Text ' Filter: ' -Foreground $theme.Accent
            Add-ClockSegment -Line $status -Text ($State.Input + $sym.Cursor) -Foreground $theme.Fg
        }
        'AddQuery' {
            Add-ClockSegment -Line $status -Text ' Add time zone: ' -Foreground $theme.Accent
            Add-ClockSegment -Line $status -Text ($State.Input + $sym.Cursor) -Foreground $theme.Fg
        }
        'Convert' {
            Add-ClockSegment -Line $status -Text (" Convert (time in {0}): " -f $rows[$State.Selected].Label) -Foreground $theme.Accent
            Add-ClockSegment -Line $status -Text ($State.Input + $sym.Cursor) -Foreground $theme.Fg
        }
        'ConfirmClear' {
            Add-ClockSegment -Line $status -Text (" Remove all {0} time zones from the list? (y/N) " -f $State.Zones.Count) -Foreground $theme.Error
        }
        default {
            if ($State.Message -and (Get-Date) -lt $State.MessageUntil) {
                Add-ClockSegment -Line $status -Text " $($State.Message)" -Foreground $(if ($State.MessageError) { $theme.Error } else { $theme.Ok })
            }
        }
    }
    # Error messages from the input modes are shown after the input.
    if ($State.Mode -in 'Filter', 'AddQuery', 'Convert' -and $State.Message -and $State.MessageError -and (Get-Date) -lt $State.MessageUntil) {
        Add-ClockSegment -Line $status -Text "   $($State.Message)" -Foreground $theme.Error
    }
    $lines.Add($status)

    $lines.ToArray()
}

function Write-ClockFrame {
    <#
    .SYNOPSIS
        Draws a frame to the console in place, without clearing the screen
        (which avoids flicker).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A full-screen TUI must position and colour text directly on the console.')]
    param(
        [Parameter(Mandatory)]
        [object[]]$Lines,

        [Parameter(Mandatory)]
        [int]$Width
    )

    $top = [Console]::WindowTop
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        [Console]::SetCursorPosition(0, $top + $i)
        $used = 0
        foreach ($segment in $line.Segments) {
            $remaining = $Width - $used
            if ($remaining -le 0) { break }
            $text = [string]$segment.Text
            if ($text.Length -gt $remaining) { $text = $text.Substring(0, $remaining) }
            if ($text.Length -eq 0) { continue }
            [Console]::ForegroundColor = $segment.Fg
            [Console]::BackgroundColor = $segment.Bg
            [Console]::Write($text)
            $used += $text.Length
        }
        if ($used -lt $Width) {
            [Console]::BackgroundColor = $line.Bg
            [Console]::Write(' ' * ($Width - $used))
        }
    }
}

#endregion

#region -------------------------------------------------------------- Input

function Add-ClockZone {
    <#
    .SYNOPSIS
        Adds a search result to the zone list and saves it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [object]$Candidate
    )

    foreach ($zone in $State.Zones) {
        if ($zone.ZoneId -eq $Candidate.ZoneId -and $zone.Label -eq $Candidate.Label) {
            Set-ClockMessage -State $State -Text "$($Candidate.Label) is already in the list." -IsError
            $State.PendingSelect = $zone
            return
        }
    }
    $entry = [pscustomobject]@{ Label = $Candidate.Label; ZoneId = $Candidate.ZoneId }
    $State.Zones.Add($entry)
    $State.Filter = ''
    $State.PendingSelect = $entry
    $saved = Save-ClockState -State $State
    if ($saved) {
        Set-ClockMessage -State $State -Text "Added $($entry.Label) ($($entry.ZoneId))."
    }
}

function Move-ClockSelection {
    <#
    .SYNOPSIS
        Handles navigation keys for the zone list. Returns $true if the key
        was a navigation key.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ConsoleKeyInfo]$Key
    )

    $last = [Math]::Max(0, $State.VisibleRows.Count - 1)
    $page = 10
    try { $page = [Math]::Max(1, [Console]::WindowHeight - 10) } catch { Write-Verbose -Message 'Window height unavailable; using default page size.' }
    switch ($Key.Key) {
        'UpArrow' { $State.Selected = [Math]::Max(0, $State.Selected - 1); return $true }
        'DownArrow' { $State.Selected = [Math]::Min($last, $State.Selected + 1); return $true }
        'PageUp' { $State.Selected = [Math]::Max(0, $State.Selected - $page); return $true }
        'PageDown' { $State.Selected = [Math]::Min($last, $State.Selected + $page); return $true }
        'Home' { $State.Selected = 0; return $true }
        'End' { $State.Selected = $last; return $true }
    }
    $false
}

function Invoke-ClockTextKey {
    <#
    .SYNOPSIS
        Handles a key press in the text entry modes (Filter, AddQuery, Convert).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ConsoleKeyInfo]$Key
    )

    $mode = $State.Mode
    $changed = $false

    if ($Key.Key -eq [ConsoleKey]::Escape) {
        if ($mode -eq 'Filter') { $State.Filter = '' }
        $State.Mode = 'Normal'
        $State.Input = ''
        $State.Message = ''
        return
    }

    if ($Key.Key -eq [ConsoleKey]::Enter) {
        switch ($mode) {
            'Filter' {
                $State.Mode = 'Normal'
            }
            'AddQuery' {
                if ($State.Results.Count -eq 0) {
                    Set-ClockMessage -State $State -Text "No time zone matches '$($State.Input)'." -IsError
                    return
                }
                $State.Mode = 'Normal'
                $State.Message = ''
                Add-ClockZone -State $State -Candidate $State.Results[$State.ResultIndex]
            }
            'Convert' {
                $default = $State.VisibleRows[$State.Selected].Entry
                $entries = @($State.LocalEntry) + $State.Zones.ToArray()
                try {
                    $result = ConvertFrom-ClockTimeText -Text $State.Input -DefaultEntry $default -Entries $entries
                    $State.RefInstant = $result.Instant
                    $State.RefText = $result.Description
                    $State.Mode = 'Normal'
                    Set-ClockMessage -State $State -Text "Showing $($result.Description) in all zones. Press L to return to live time."
                }
                catch {
                    Set-ClockMessage -State $State -Text $_.Exception.Message -IsError
                    return
                }
            }
        }
        $State.Input = ''
        return
    }

    if ($mode -eq 'AddQuery') {
        $max = $State.Results.Count - 1
        switch ($Key.Key) {
            'UpArrow' { $State.ResultIndex = [Math]::Max(0, $State.ResultIndex - 1); return }
            'DownArrow' { $State.ResultIndex = [Math]::Max(0, [Math]::Min($max, $State.ResultIndex + 1)); return }
            'PageUp' { $State.ResultIndex = [Math]::Max(0, $State.ResultIndex - 10); return }
            'PageDown' { $State.ResultIndex = [Math]::Max(0, [Math]::Min($max, $State.ResultIndex + 10)); return }
        }
    }
    elseif (Move-ClockSelection -State $State -Key $Key) {
        return
    }

    if ($Key.Key -eq [ConsoleKey]::Backspace) {
        if ($State.Input.Length -gt 0) {
            $State.Input = $State.Input.Substring(0, $State.Input.Length - 1)
            $changed = $true
        }
    }
    elseif ($Key.KeyChar -and -not [char]::IsControl($Key.KeyChar)) {
        $State.Input += $Key.KeyChar
        $changed = $true
    }

    if ($changed) {
        $State.Message = ''
        if ($mode -eq 'Filter') {
            $State.Filter = $State.Input
            $State.Selected = 0
        }
        elseif ($mode -eq 'AddQuery') {
            $State.Results = @(Find-ClockZone -Query $State.Input)
            $State.ResultIndex = 0
        }
    }
}

function Invoke-ClockKey {
    <#
    .SYNOPSIS
        Dispatches a key press according to the current mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ConsoleKeyInfo]$Key
    )

    # Ctrl+C always quits (the console is in TreatControlCAsInput mode).
    if ($Key.Key -eq [ConsoleKey]::C -and ($Key.Modifiers -band [ConsoleModifiers]::Control)) {
        $State.Running = $false
        return
    }

    switch ($State.Mode) {
        'Help' { $State.Mode = 'Normal'; return }
        'ConfirmClear' {
            $State.Mode = 'Normal'
            if ($Key.Key -eq [ConsoleKey]::Y) {
                $count = $State.Zones.Count
                $State.Zones.Clear()
                $State.Filter = ''
                $State.Selected = 0
                $saved = Save-ClockState -State $State
                if ($saved) {
                    Set-ClockMessage -State $State -Text "Cleared $count time zones."
                }
            }
            else {
                Set-ClockMessage -State $State -Text 'Clear cancelled.'
            }
            return
        }
        { $_ -in 'Filter', 'AddQuery', 'Convert' } {
            Invoke-ClockTextKey -State $State -Key $Key
            return
        }
    }

    # Normal mode.
    if (Move-ClockSelection -State $State -Key $Key) { return }

    switch ($Key.Key) {
        'Insert' { $State.Mode = 'AddQuery'; $State.Input = ''; $State.Results = @(); $State.ResultIndex = 0; return }
        'Delete' { Remove-ClockSelectedZone -State $State; return }
        'F1' { $State.Mode = 'Help'; return }
        'Escape' {
            if ($null -ne $State.RefInstant) { $State.RefInstant = $null; Set-ClockMessage -State $State -Text 'Back to live time.' }
            elseif ($State.Filter) { $State.Filter = '' }
            return
        }
    }

    switch ([string]$Key.KeyChar) {
        { $_ -in 'a', 'A', '+' } { $State.Mode = 'AddQuery'; $State.Input = ''; $State.Results = @(); $State.ResultIndex = 0; return }
        { $_ -in 'd', 'D', '-' } { Remove-ClockSelectedZone -State $State; return }
        { $_ -in '/', 'f', 'F' } { $State.Mode = 'Filter'; $State.Input = $State.Filter; return }
        { $_ -in 's', 'S' } {
            $index = [Array]::IndexOf($script:SortColumns, $State.Sort)
            $State.Sort = $script:SortColumns[($index + 1) % $script:SortColumns.Count]
            $null = Save-ClockState -State $State
            return
        }
        { $_ -in 'r', 'R' } { $State.Descending = -not $State.Descending; $null = Save-ClockState -State $State; return }
        { $_ -in 't', 'T' } { $State.Mode = 'Convert'; $State.Input = ''; return }
        { $_ -in 'l', 'L' } {
            if ($null -ne $State.RefInstant) { $State.RefInstant = $null; Set-ClockMessage -State $State -Text 'Back to live time.' }
            return
        }
        { $_ -in 'h', 'H' } { $State.TwelveHour = -not $State.TwelveHour; $null = Save-ClockState -State $State; return }
        { $_ -in 'c', 'C' } {
            if ($State.Zones.Count -eq 0) { Set-ClockMessage -State $State -Text 'The list is already empty.' }
            else { $State.Mode = 'ConfirmClear' }
            return
        }
        { $_ -in '?' } { $State.Mode = 'Help'; return }
        { $_ -in 'q', 'Q' } { $State.Running = $false; return }
    }
}

function Remove-ClockSelectedZone {
    <#
    .SYNOPSIS
        Removes the selected zone from the list and saves it.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive key handler; the user pressed Delete.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if ($State.Selected -le 0 -or $State.Selected -ge $State.VisibleRows.Count) {
        Set-ClockMessage -State $State -Text 'The local time zone cannot be removed. Select another row first.' -IsError
        return
    }
    $entry = $State.VisibleRows[$State.Selected].Entry
    $null = $State.Zones.Remove($entry)
    $saved = Save-ClockState -State $State
    if ($saved) {
        Set-ClockMessage -State $State -Text "Removed $($entry.Label)."
    }
}

#endregion

#region --------------------------------------------------------------- Main

function Start-PSClock {
    <#
    .SYNOPSIS
        Runs the interactive world clock until the user quits.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive application entry point; every change is an explicit user action.')]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$Symbols,

        [Parameter(Mandatory)]
        [int]$BusinessStart,

        [Parameter(Mandatory)]
        [int]$BusinessEnd
    )

    if ($BusinessEnd -le $BusinessStart) {
        throw "BusinessEnd ($BusinessEnd) must be later than BusinessStart ($BusinessStart)."
    }

    # The TUI needs a real, interactive console (not the ISE, not redirected).
    $interactive = $true
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $interactive = $false }
        else { $null = [Console]::KeyAvailable }
    }
    catch { $interactive = $false }
    if (-not $interactive) {
        throw 'PSClock needs an interactive console window (Windows Terminal, the PowerShell console or the VS Code terminal).'
    }

    $unicode = switch ($Symbols) {
        'Unicode' { $true }
        'Ascii' { $false }
        default { [bool]($env:WT_SESSION -or $env:TERM_PROGRAM) }
    }

    $state = New-ClockState -ConfigPath $ConfigPath -Unicode $unicode -BusinessStart $BusinessStart -BusinessEnd $BusinessEnd

    # Remember console settings so they can be restored on exit.
    $originalFg = [Console]::ForegroundColor
    $originalBg = [Console]::BackgroundColor
    $originalCtrlC = [Console]::TreatControlCAsInput
    $originalEncoding = [Console]::OutputEncoding
    $originalCursor = $true
    try { $originalCursor = [Console]::CursorVisible } catch { Write-Verbose -Message 'Cursor visibility is not readable on this platform.' }

    try {
        [Console]::TreatControlCAsInput = $true
        [Console]::CursorVisible = $false
        if ($unicode) { [Console]::OutputEncoding = New-Object -TypeName Text.UTF8Encoding -ArgumentList $false }
        [Console]::Clear()

        $lastSize = ''
        $lastTick = ''
        $dirty = $true
        while ($state.Running) {
            while ([Console]::KeyAvailable -and $state.Running) {
                Invoke-ClockKey -State $state -Key ([Console]::ReadKey($true))
                $dirty = $true
            }
            if (-not $state.Running) { break }

            $width = [Console]::WindowWidth - 1      # never write the last column: avoids line wrapping
            $height = [Console]::WindowHeight
            $size = "$width x $height"
            if ($size -ne $lastSize) {
                [Console]::BackgroundColor = $state.Theme.Bg
                [Console]::Clear()
                $lastSize = $size
                $dirty = $true
            }

            $tick = [DateTime]::Now.ToString('HHmmss')
            if ($tick -ne $lastTick) { $lastTick = $tick; $dirty = $true }

            if ($dirty) {
                Write-ClockFrame -Lines (Get-ClockFrame -State $state -Width $width -Height $height) -Width $width
                $dirty = $false
            }
            Start-Sleep -Milliseconds 50
        }
    }
    finally {
        [Console]::ForegroundColor = $originalFg
        [Console]::BackgroundColor = $originalBg
        [Console]::Clear()
        [Console]::TreatControlCAsInput = $originalCtrlC
        try { [Console]::CursorVisible = $originalCursor } catch { Write-Verbose -Message 'Could not restore cursor visibility.' }
        if ($unicode) { [Console]::OutputEncoding = $originalEncoding }
    }
}

# Run the app unless the script is being dot-sourced (e.g. by tests), in
# which case only the functions are loaded.
if ($MyInvocation.InvocationName -ne '.') {
    Start-PSClock -ConfigPath $ConfigPath -Symbols $Symbols -BusinessStart $BusinessStart -BusinessEnd $BusinessEnd
}

#endregion
