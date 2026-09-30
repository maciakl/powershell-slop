<#
.SYNOPSIS
    Displays a calendar. A PowerShell port of the POSIX/Unix cal(1) utility.

.DESCRIPTION
    Cal.ps1 [options] [[[day] month] year]
    Cal.ps1 [options] <timestamp|monthname>

    With no arguments the current month is shown. A single numeric argument is
    a year (1-9999) and the whole year is shown. Two arguments are month and
    year; three are day, month and year. A month may be given as a number or a
    (possibly abbreviated) name. A timestamp may be YYYY-MM-DD, @<unix-seconds>,
    now, today, yesterday or tomorrow.

    Like the Unix original, the default calendar switches from Julian to
    Gregorian in September 1752 (3-13 September 1752 do not exist).

    Options are case-sensitive and follow Unix conventions: short options may
    be bundled (-3wm), arguments may be attached (-n4, -w12) and long options
    may be written --name=value, --name value or -name value, and abbreviated
    to any unique prefix.

    -1, --one            show only a single month (default)
    -3, --three          show previous, current and next month
    -n, --months <num>   show num months starting with date's month
    -S, --span           span the date when displaying multiple months
    -A <num>             also show num months after the date's month
    -B <num>             also show num months before the date's month
    -s, --sunday         Sunday as first day of week (default)
    -m, -M, --monday     Monday as first day of week
    -j, --julian         show day-of-year numbers instead of day-of-month
    -J                   use the Julian calendar exclusively (--reform julian)
        --reform <val>   Gregorian reform date: 1752, gregorian, iso, julian
        --iso            proleptic Gregorian calendar (--reform iso)
    -y, --year           show the whole year
    -Y, --twelve         show the next twelve months
    -w, --week[=<num>]   show week numbers (US with Sunday first, ISO 8601 with
                         Monday first); optionally highlight week num (-w<num>)
    -v, -N, --vertical   show days vertically (ncal style)
    -C                   show days horizontally (cal style, default)
    -c, --columns <num>  number of months per row, or 'auto'
    -d <yyyy-mm[-dd]>    use the given date as today
    -H <yyyy-mm-dd>      highlight the given date
    -e                   print the date of Western Easter for the year
    -o                   print the date of Orthodox Easter for the year
        --color[=<when>] colorize output: auto (default), always or never
    -h, --help           show this help
    -V, --version        show version

    Output is colorized when written directly to the console and plain text
    when piped, redirected or captured. Setting NO_COLOR disables automatic
    colorization.

.EXAMPLE
    .\Cal.ps1
    Shows the current month.

.EXAMPLE
    .\Cal.ps1 -3 -w -m
    Shows the previous, current and next month, Monday first, with ISO week numbers.

.EXAMPLE
    .\Cal.ps1 9 1752
    Shows September 1752, the month of the Gregorian reform.

.EXAMPLE
    .\Cal.ps1 -y 2027 > year.txt
    Writes the 2027 calendar to a file as plain text.
#>

# No param() block on purpose: PowerShell parameter binding is case-insensitive,
# while cal's options are not (-y/-Y, -s/-S, -v/-V, -j/-J ...). Arguments are
# parsed by hand from $args using Unix conventions.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Invocation = $MyInvocation
$script:Version = '1.0.0'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Stop-WithError([string]$Message) {
    [Console]::Error.WriteLine("cal: $Message")
    [Console]::Error.WriteLine("Try 'Cal.ps1 --help' for more information.")
    exit 1
}

function Get-FloorDiv([long]$a, [long]$b) {
    [long][Math]::Floor([double]$a / $b)
}

function Get-FloorMod([long]$a, [long]$b) {
    $a - $b * (Get-FloorDiv $a $b)
}

# ---------------------------------------------------------------------------
# Calendar arithmetic (Julian day numbers, honouring the selected reform)
# ---------------------------------------------------------------------------

$script:Reform = '1752'          # '1752', 'gregorian' or 'julian'
$script:ReformJdn = 2361222      # 14 September 1752 (Gregorian)
$script:MonthDays = @(0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)

function Test-JulianDate([int]$y, [int]$m, [int]$d) {
    switch ($script:Reform) {
        'julian'    { return $true }
        'gregorian' { return $false }
        default     { return (($y * 10000 + $m * 100 + $d) -lt 17520914) }
    }
}

function Test-LeapYear([int]$y) {
    $julianRule = switch ($script:Reform) {
        'julian'    { $true }
        'gregorian' { $false }
        default     { $y -le 1752 }
    }
    if ($julianRule) { return ((Get-FloorMod $y 4) -eq 0) }
    return ((($y % 4) -eq 0 -and ($y % 100) -ne 0) -or ($y % 400) -eq 0)
}

function Get-MonthLength([int]$y, [int]$m) {
    if ($m -eq 2 -and (Test-LeapYear $y)) { return 29 }
    return $script:MonthDays[$m]
}

function Test-DayExists([int]$y, [int]$m, [int]$d) {
    if ($m -lt 1 -or $m -gt 12 -or $d -lt 1 -or $d -gt (Get-MonthLength $y $m)) { return $false }
    return -not ($script:Reform -eq '1752' -and $y -eq 1752 -and $m -eq 9 -and $d -ge 3 -and $d -le 13)
}

function Get-Jdn([int]$y, [int]$m, [int]$d, [switch]$Gregorian) {
    $a = Get-FloorDiv (14 - $m) 12
    $yy = [long]$y + 4800 - $a
    $mm = $m + 12 * $a - 3
    $base = $d + (Get-FloorDiv (153 * $mm + 2) 5) + 365 * $yy + (Get-FloorDiv $yy 4)
    if (-not $Gregorian -and (Test-JulianDate $y $m $d)) { return ($base - 32083) }
    return ($base - (Get-FloorDiv $yy 100) + (Get-FloorDiv $yy 400) - 32045)
}

# Returns @(year, month, day) in the calendar in force for that day.
function ConvertFrom-Jdn([long]$j) {
    $gregorian = switch ($script:Reform) {
        'julian'    { $false }
        'gregorian' { $true }
        default     { $j -ge $script:ReformJdn }
    }
    if ($gregorian) {
        $f = $j + 1401 + (Get-FloorDiv ((Get-FloorDiv (4 * $j + 274277) 146097) * 3) 4) - 38
    } else {
        $f = $j + 1401
    }
    $e = 4 * $f + 3
    $g = Get-FloorDiv (Get-FloorMod $e 1461) 4
    $h = 5 * $g + 2
    $day = (Get-FloorDiv (Get-FloorMod $h 153) 5) + 1
    $month = (Get-FloorMod ((Get-FloorDiv $h 153) + 2) 12) + 1
    $year = (Get-FloorDiv $e 1461) - 4716 + (Get-FloorDiv (12 + 2 - $month) 12)
    return , @([int]$year, [int]$month, [int]$day)
}

function Get-Weekday([long]$jdn) {
    [int](Get-FloorMod ($jdn + 1) 7)   # 0 = Sunday
}

function Get-DayOfYear([int]$y, [int]$m, [int]$d) {
    $n = $d
    for ($i = 1; $i -lt $m; $i++) { $n += Get-MonthLength $y $i }
    return $n
}

# Week number of the display week starting on JDN $start.
# Monday first: ISO 8601 (week 1 holds the first Thursday).
# Sunday first: North American (week 1 holds 1 January).
function Get-WeekNumber([long]$start) {
    if ($script:FirstDay -eq 1) {
        $thursday = $start + 3
        $y = (ConvertFrom-Jdn $thursday)[0]
        return [int]((Get-FloorDiv ($thursday - (Get-Jdn $y 1 1)) 7) + 1)
    }
    $last = $start + 6
    $y = (ConvertFrom-Jdn $last)[0]
    $jan1 = Get-Jdn $y 1 1
    $weekStart = $jan1 - (Get-FloorMod ((Get-Weekday $jan1) - $script:FirstDay) 7)
    return [int]((Get-FloorDiv ($last - $weekStart) 7) + 1)
}

function Get-Easter([int]$y, [switch]$Orthodox) {
    if ($Orthodox -or (Test-JulianDate $y 4 1)) {
        # Julian computus (Meeus); the result is a Julian calendar date
        $a = $y % 4; $b = $y % 7; $c = $y % 19
        $d = (19 * $c + 15) % 30
        $e = (2 * $a + 4 * $b - $d + 34) % 7
        $month = [int][Math]::Floor(($d + $e + 114) / 31)
        $day = (($d + $e + 114) % 31) + 1
        $saved = $script:Reform
        $script:Reform = 'julian'
        $jdn = Get-Jdn $y $month $day
        $script:Reform = $saved
        return (ConvertFrom-Jdn $jdn)
    }
    # Anonymous Gregorian algorithm
    $a = $y % 19; $b = [Math]::Floor($y / 100); $c = $y % 100
    $d = [Math]::Floor($b / 4); $e = $b % 4
    $f = [Math]::Floor(($b + 8) / 25); $g = [Math]::Floor(($b - $f + 1) / 3)
    $h = (19 * $a + $b - $d - $g + 15) % 30
    $i = [Math]::Floor($c / 4); $k = $c % 4
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
    $mm = [Math]::Floor(($a + 11 * $h + 22 * $l) / 451)
    $month = [int][Math]::Floor(($h + $l - 7 * $mm + 114) / 31)
    $day = [int](($h + $l - 7 * $mm + 114) % 31) + 1
    return , @($y, $month, $day)
}

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------

$script:Culture = [Globalization.CultureInfo]::CurrentCulture
$script:Dtf = $script:Culture.DateTimeFormat

function Get-TitleCase([string]$s) {
    if (-not $s) { return $s }
    return $script:Culture.TextInfo.ToUpper($s[0]) + $s.Substring(1)
}

function Get-MonthName([int]$m) {
    $name = $script:Dtf.MonthNames[$m - 1]
    if (-not $name) { $name = [Globalization.CultureInfo]::InvariantCulture.DateTimeFormat.MonthNames[$m - 1] }
    return (Get-TitleCase $name)
}

function Get-DayName([int]$wd, [int]$width) {
    # truncate the abbreviated name (ShortestDayNames is one letter on some runtimes)
    $name = Get-TitleCase ($script:Dtf.AbbreviatedDayNames[$wd].TrimEnd('.'))
    if ($name.Length -gt $width) { $name = $name.Substring(0, $width) }
    return $name.PadLeft($width)
}

function Find-Month([string]$text) {
    $t = $text.Trim().TrimEnd('.').ToLowerInvariant()
    if (-not $t) { return 0 }
    $sets = @($script:Dtf, [Globalization.CultureInfo]::InvariantCulture.DateTimeFormat)
    foreach ($f in $sets) {
        for ($i = 0; $i -lt 12; $i++) {
            if ($f.MonthNames[$i].ToLowerInvariant() -eq $t -or
                $f.AbbreviatedMonthNames[$i].TrimEnd('.').ToLowerInvariant() -eq $t) { return $i + 1 }
        }
    }
    if ($t.Length -ge 3) {
        $hits = @{}
        foreach ($f in $sets) {
            for ($i = 0; $i -lt 12; $i++) {
                if ($f.MonthNames[$i].ToLowerInvariant().StartsWith($t)) { $hits[$i + 1] = $true }
            }
        }
        if ($hits.Count -eq 1) { return @($hits.Keys)[0] }
    }
    return 0
}

# ---------------------------------------------------------------------------
# Output detection
# ---------------------------------------------------------------------------

# True when this script's success output goes straight to the host (the
# console), i.e. it is not piped, redirected, assigned or captured.
function Test-HostOutput {
    $inv = $script:Invocation
    if ($Host.Name -eq 'ConsoleHost') {
        try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    }
    if ($inv.PipelineLength -gt $inv.PipelinePosition) { return $false }
    if ("$($inv.CommandOrigin)" -ne 'Runspace') { return $false }

    $line = $inv.Line
    if ([string]::IsNullOrWhiteSpace($line)) {
        # powershell.exe -File Cal.ps1: stdout redirection was checked above
        return ($Host.Name -eq 'ConsoleHost')
    }

    try {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
    } catch { return $false }

    $offset = $inv.OffsetInLine - 1
    $command = $null
    $candidates = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $candidates) {
        if ($c.Extent.StartOffset -le $offset -and $offset -lt $c.Extent.EndOffset) {
            if ($null -eq $command -or $c.Extent.Text.Length -lt $command.Extent.Text.Length) { $command = $c }
        }
    }
    if ($null -eq $command) { return $false }

    foreach ($r in $command.Redirections) {
        if ($r -is [System.Management.Automation.Language.FileRedirectionAst] -and
            ("$($r.FromStream)" -eq 'Output' -or "$($r.FromStream)" -eq 'All')) { return $false }
    }
    $pipeline = $command.Parent
    if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
        $pipeline.PipelineElements.Count -ne 1) { return $false }
    $block = $pipeline.Parent
    return ($block -is [System.Management.Automation.Language.NamedBlockAst] -and
            $block.Parent -is [System.Management.Automation.Language.ScriptBlockAst] -and
            $null -eq $block.Parent.Parent)
}

# ---------------------------------------------------------------------------
# Text layout: a line is a list of @(text, style) segments
# ---------------------------------------------------------------------------

function New-Line { , (New-Object System.Collections.Generic.List[object]) }

function Add-Segment($line, [string]$text, [string]$style = '') {
    if ($text.Length -gt 0) { $line.Add(@($text, $style)) }
}

function Get-LineWidth($line) {
    $w = 0
    foreach ($s in $line) { $w += $s[0].Length }
    return $w
}

function Add-Padding($line, [int]$width) {
    $w = Get-LineWidth $line
    if ($w -lt $width) { Add-Segment $line (' ' * ($width - $w)) }
}

function Add-Centered($line, [string]$text, [int]$width, [string]$style) {
    if ($text.Length -ge $width) { Add-Segment $line $text $style; return }
    $left = [int][Math]::Floor(($width - $text.Length) / 2)
    Add-Segment $line (' ' * $left)
    Add-Segment $line $text $style
    Add-Segment $line (' ' * ($width - $text.Length - $left))
}

function New-Block([int]$width) {
    return @{ Width = $width; Lines = (New-Object System.Collections.Generic.List[object]) }
}

# Lays out one month as a 6x7 grid of day cells.
function Get-MonthGrid([int]$y, [int]$m) {
    $first = Get-Jdn $y $m 1
    $offset = Get-FloorMod ((Get-Weekday $first) - $script:FirstDay) 7
    $grid = New-Object 'object[,]' 6, 7
    $rowUsed = New-Object 'bool[]' 6
    $doyBase = (Get-DayOfYear $y $m 1) - 1
    $pos = $offset
    $jdn = $first
    $len = Get-MonthLength $y $m
    for ($d = 1; $d -le $len; $d++) {
        if (-not (Test-DayExists $y $m $d)) { continue }
        $r = [int][Math]::Floor($pos / 7)
        $c = $pos % 7
        $grid[$r, $c] = @{ Day = $d; Doy = $doyBase + $d; Weekday = (Get-Weekday $jdn) }
        $rowUsed[$r] = $true
        $pos++
        $jdn++
    }
    $rowWeek = New-Object 'int[]' 6
    if ($script:ShowWeeks) {
        for ($r = 0; $r -lt 6; $r++) {
            if ($rowUsed[$r]) { $rowWeek[$r] = Get-WeekNumber ($first - $offset + 7 * $r) }
        }
    }
    return @{ Year = $y; Month = $m; Grid = $grid; RowUsed = $rowUsed; RowWeek = $rowWeek }
}

function Get-CellStyle($model, $cell, [int]$row) {
    if ($script:Highlight -and $model.Year -eq $script:Highlight[0] -and
        $model.Month -eq $script:Highlight[1] -and $cell.Day -eq $script:Highlight[2]) { return 'today' }
    if ($script:ShowWeeks -and $script:WeekHighlight -gt 0 -and
        $model.RowWeek[$row] -eq $script:WeekHighlight) { return 'weekhl' }
    if ($cell.Weekday -eq 0 -or $cell.Weekday -eq 6) { return 'weekend' }
    return ''
}

function Get-CellText($cell, [int]$width) {
    $n = if ($script:Julian) { $cell.Doy } else { $cell.Day }
    return ([string]$n).PadLeft($width)
}

function Get-WeekStyle($model, [int]$row) {
    if ($script:WeekHighlight -gt 0 -and $model.RowWeek[$row] -eq $script:WeekHighlight) { return 'weekhl' }
    return 'week'
}

# Traditional layout: weeks are rows.
function New-HorizontalBlock([int]$y, [int]$m, [string]$title) {
    $model = Get-MonthGrid $y $m
    $cw = if ($script:Julian) { 3 } else { 2 }
    $gridWidth = 7 * $cw + 6
    $prefix = if ($script:ShowWeeks) { 3 } else { 0 }
    $block = New-Block ($prefix + $gridWidth)

    $line = New-Line
    Add-Segment $line (' ' * $prefix)
    Add-Centered $line $title $gridWidth 'title'
    $block.Lines.Add($line)

    $line = New-Line
    Add-Segment $line (' ' * $prefix)
    for ($c = 0; $c -lt 7; $c++) {
        if ($c -gt 0) { Add-Segment $line ' ' }
        Add-Segment $line (Get-DayName (($script:FirstDay + $c) % 7) $cw) 'head'
    }
    $block.Lines.Add($line)

    for ($r = 0; $r -lt 6; $r++) {
        $line = New-Line
        if ($script:ShowWeeks) {
            if ($model.RowUsed[$r]) {
                Add-Segment $line ('{0,2}' -f $model.RowWeek[$r]) (Get-WeekStyle $model $r)
                Add-Segment $line ' '
            } else {
                Add-Segment $line '   '
            }
        }
        for ($c = 0; $c -lt 7; $c++) {
            if ($c -gt 0) { Add-Segment $line ' ' }
            $cell = $model.Grid[$r, $c]
            if ($null -eq $cell) { Add-Segment $line (' ' * $cw) }
            else { Add-Segment $line (Get-CellText $cell $cw) (Get-CellStyle $model $cell $r) }
        }
        $block.Lines.Add($line)
    }
    foreach ($l in $block.Lines) { Add-Padding $l $block.Width }
    return $block
}

# ncal layout: weeks are columns, weekdays are rows.
function New-VerticalBlock([int]$y, [int]$m, [string]$title) {
    $model = Get-MonthGrid $y $m
    $cw = if ($script:Julian) { 3 } else { 2 }
    $block = New-Block (6 * ($cw + 1))

    $line = New-Line
    Add-Centered $line $title $block.Width 'title'
    $block.Lines.Add($line)

    for ($c = 0; $c -lt 7; $c++) {
        $line = New-Line
        for ($r = 0; $r -lt 6; $r++) {
            Add-Segment $line ' '
            $cell = $model.Grid[$r, $c]
            if ($null -eq $cell) { Add-Segment $line (' ' * $cw) }
            else { Add-Segment $line (Get-CellText $cell $cw) (Get-CellStyle $model $cell $r) }
        }
        $block.Lines.Add($line)
    }
    if ($script:ShowWeeks) {
        $line = New-Line
        for ($r = 0; $r -lt 6; $r++) {
            Add-Segment $line ' '
            if ($model.RowUsed[$r]) {
                Add-Segment $line (([string]$model.RowWeek[$r]).PadLeft($cw)) (Get-WeekStyle $model $r)
            } else {
                Add-Segment $line (' ' * $cw)
            }
        }
        $block.Lines.Add($line)
    }
    foreach ($l in $block.Lines) { Add-Padding $l $block.Width }
    return $block
}

# Weekday names column shown left of each row of vertical months.
function New-DayNamesBlock {
    $block = New-Block 2
    $block.Lines.Add((New-Line))
    for ($c = 0; $c -lt 7; $c++) {
        $line = New-Line
        Add-Segment $line (Get-DayName (($script:FirstDay + $c) % 7) 2) 'head'
        $block.Lines.Add($line)
    }
    if ($script:ShowWeeks) { $block.Lines.Add((New-Line)) }
    foreach ($l in $block.Lines) { Add-Padding $l $block.Width }
    return $block
}

function Join-Blocks($blocks, [string]$gap, $leader) {
    $result = New-Object System.Collections.Generic.List[object]
    $height = $blocks[0].Lines.Count
    for ($i = 0; $i -lt $height; $i++) {
        $line = New-Line
        if ($leader) { foreach ($s in $leader.Lines[$i]) { $line.Add($s) } }
        for ($b = 0; $b -lt $blocks.Count; $b++) {
            if ($b -gt 0) { Add-Segment $line $gap }
            foreach ($s in $blocks[$b].Lines[$i]) { $line.Add($s) }
        }
        $result.Add($line)
    }
    return , $result
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

$script:HostColors = @{
    title   = @('Cyan', $null)
    head    = @('Yellow', $null)
    weekend = @('Red', $null)
    week    = @('DarkGray', $null)
    weekhl  = @('Green', $null)
}
$script:AnsiColors = @{
    title = '36'; head = '33'; weekend = '31'; week = '90'; weekhl = '32'; today = '7'
}

function Get-InverseColors {
    $fg = 'Black'; $bg = 'Gray'
    try {
        $rawFg = $Host.UI.RawUI.ForegroundColor
        $rawBg = $Host.UI.RawUI.BackgroundColor
        if ([Enum]::IsDefined([ConsoleColor], $rawFg) -and [Enum]::IsDefined([ConsoleColor], $rawBg) -and
            $rawFg -ne $rawBg) {
            $fg = [string][ConsoleColor]$rawBg
            $bg = [string][ConsoleColor]$rawFg
        }
    } catch { }
    return , @($fg, $bg)
}

function Write-Calendar($lines, [string]$mode) {
    if ($mode -eq 'host') {
        $script:HostColors['today'] = Get-InverseColors
        foreach ($line in $lines) {
            # merge adjacent segments sharing a style to keep Write-Host calls down
            $text = ''; $style = $null
            $segments = @($line) + , @('', '<end>')
            foreach ($s in $segments) {
                if ($null -ne $style -and $s[1] -ne $style) {
                    if ($style -eq '' -or -not $script:HostColors.ContainsKey($style)) {
                        Write-Host $text -NoNewline
                    } else {
                        $colors = $script:HostColors[$style]
                        if ($colors[1]) { Write-Host $text -NoNewline -ForegroundColor $colors[0] -BackgroundColor $colors[1] }
                        else { Write-Host $text -NoNewline -ForegroundColor $colors[0] }
                    }
                    $text = ''
                }
                $style = $s[1]
                $text += $s[0]
            }
            Write-Host ''
        }
        return
    }

    $esc = [char]27
    foreach ($line in $lines) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($s in $line) {
            if ($mode -eq 'ansi' -and $s[1] -and $script:AnsiColors.ContainsKey($s[1])) {
                [void]$sb.Append("$esc[$($script:AnsiColors[$s[1]])m$($s[0])$esc[0m")
            } else {
                [void]$sb.Append($s[0])
            }
        }
        Write-Output $sb.ToString().TrimEnd()
    }
}

function Show-Usage {
    @'
Usage:
 Cal.ps1 [options] [[[day] month] year]
 Cal.ps1 [options] <timestamp|monthname>

Display a calendar, or some part of it.
Without any arguments, display the current month.

Options:
 -1, --one             show only a single month (default)
 -3, --three           show three months spanning the date
 -n, --months <num>    show num months starting with date's month
 -S, --span            span the date when displaying multiple months
 -A <num>              show num months after the date's month too
 -B <num>              show num months before the date's month too
 -s, --sunday          Sunday as first day of week
 -m, -M, --monday      Monday as first day of week
 -j, --julian          use day-of-year numbering for all calendars
 -J                    use the Julian calendar exclusively
     --reform <val>    Gregorian reform date (1752|gregorian|iso|julian)
     --iso             alias for --reform=iso
 -y, --year            show the whole year
 -Y, --twelve          show the next twelve months
 -w, --week[=<num>]    show US or ISO-8601 week numbers (-w<num> highlights)
 -v, -N, --vertical    show day and date columns vertically
 -C                    show days horizontally (default)
 -c, --columns <width> number of months per row, or 'auto'
 -d <yyyy-mm[-dd]>     use the given date as today
 -H <yyyy-mm-dd>       highlight the given date
 -e                    display the date of Easter (Western churches)
 -o                    display the date of Easter (Orthodox churches)
     --color[=<when>]  colorize output; <when> is auto, always or never

 -h, --help            display this help
 -V, --version         display version
'@ -split "`r?`n"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

$opt = @{
    Mode = $null; Months = 0; Span = $false; After = 0; Before = 0
    FirstDay = 0; Julian = $false; Reform = '1752'; Week = $false; WeekHighlight = 0
    Vertical = $false; Columns = $null; Color = 'auto'; Today = $null; Highlight = $null
    Easter = $null; Help = $false; Version = $false
}

$longOptions = [ordered]@{
    'one' = 'none'; 'three' = 'none'; 'months' = 'required'; 'span' = 'none'
    'sunday' = 'none'; 'monday' = 'none'; 'julian' = 'none'; 'reform' = 'required'
    'iso' = 'none'; 'year' = 'none'; 'twelve' = 'none'; 'week' = 'optional'
    'vertical' = 'none'; 'columns' = 'required'; 'color' = 'optional'
    'help' = 'none'; 'version' = 'none'
}

function ConvertTo-Count([string]$value, [string]$what, [int]$min) {
    $n = 0
    if (-not [int]::TryParse($value, [ref]$n) -or $n -lt $min) { Stop-WithError "invalid $what argument: '$value'" }
    return $n
}

function ConvertFrom-DateText([string]$text) {
    if ($text -match '^\s*(\d{1,4})-(\d{1,2})(?:-(\d{1,2}))?(?:[T ]+\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?)?\s*$') {
        $d = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        return , @([int]$Matches[1], [int]$Matches[2], $d)
    }
    return $null
}

function Set-Option([string]$name, $value) {
    switch -CaseSensitive ($name) {
        'one'      { $opt.Mode = '1' }
        'three'    { $opt.Mode = '3' }
        'months'   { $opt.Mode = 'n'; $opt.Months = ConvertTo-Count $value 'number of months' 1 }
        'span'     { $opt.Span = $true }
        'sunday'   { $opt.FirstDay = 0 }
        'monday'   { $opt.FirstDay = 1 }
        'julian'   { $opt.Julian = $true }
        'iso'      { $opt.Reform = 'gregorian' }
        'reform-julian' { $opt.Reform = 'julian' }
        'reform'   {
            switch ("$value".ToLowerInvariant()) {
                '1752'      { $opt.Reform = '1752' }
                'gregorian' { $opt.Reform = 'gregorian' }
                'iso'       { $opt.Reform = 'gregorian' }
                'julian'    { $opt.Reform = 'julian' }
                default     { Stop-WithError "invalid --reform value: '$value'" }
            }
        }
        'year'     { $opt.Mode = 'y' }
        'twelve'   { $opt.Mode = 'Y' }
        'week'     {
            $opt.Week = $true
            if ($null -ne $value -and "$value" -ne '') {
                $opt.WeekHighlight = ConvertTo-Count $value 'week' 1
                if ($opt.WeekHighlight -gt 53) { Stop-WithError "illegal week value: use 1-53" }
            }
        }
        'vertical' { $opt.Vertical = $true }
        'horizontal' { $opt.Vertical = $false }
        'columns'  {
            if ("$value" -eq 'auto') { $opt.Columns = $null }
            else { $opt.Columns = ConvertTo-Count $value 'columns' 1 }
        }
        'color'    {
            $when = if ($null -eq $value -or "$value" -eq '') { 'auto' } else { "$value".ToLowerInvariant() }
            if ($when -notin @('auto', 'always', 'never')) { Stop-WithError "unsupported color mode: '$value'" }
            $opt.Color = $when
        }
        'after'    { $opt.After = ConvertTo-Count $value 'months after' 0 }
        'before'   { $opt.Before = ConvertTo-Count $value 'months before' 0 }
        'today'    {
            $d = ConvertFrom-DateText $value
            if (-not $d) { Stop-WithError "invalid date: '$value'" }
            $opt.Today = $d
        }
        'highlight' {
            $d = ConvertFrom-DateText $value
            if (-not $d -or $d[2] -eq 0) { Stop-WithError "invalid date: '$value'" }
            $opt.Highlight = $d
        }
        'easter'   { $opt.Easter = 'western' }
        'orthodox' { $opt.Easter = 'orthodox' }
        'help'     { $opt.Help = $true }
        'version'  { $opt.Version = $true }
    }
}

# short option -> (long name, argument kind); case-sensitive, unlike a hashtable literal
$shortOptions = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
foreach ($entry in @(
        @('1', 'one', 'none'), @('3', 'three', 'none'), @('n', 'months', 'required'),
        @('S', 'span', 'none'), @('s', 'sunday', 'none'), @('m', 'monday', 'none'),
        @('M', 'monday', 'none'), @('j', 'julian', 'none'), @('J', 'reform-julian', 'none'),
        @('y', 'year', 'none'), @('Y', 'twelve', 'none'), @('w', 'week', 'optional'),
        @('v', 'vertical', 'none'), @('N', 'vertical', 'none'), @('C', 'horizontal', 'none'),
        @('c', 'columns', 'required'), @('A', 'after', 'required'), @('B', 'before', 'required'),
        @('d', 'today', 'required'), @('H', 'highlight', 'required'), @('e', 'easter', 'none'),
        @('o', 'orthodox', 'none'), @('h', 'help', 'none'), @('V', 'version', 'none'))) {
    $shortOptions[$entry[0]] = @($entry[1], $entry[2])
}

$argv = @(foreach ($a in $args) { [string]$a })
$positional = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $argv.Count) {
    $a = $argv[$i]
    if ($a.Length -lt 2 -or $a[0] -ne '-') {
        $positional.Add($a); $i++; continue
    }
    if ($a -eq '--') {
        for ($i++; $i -lt $argv.Count; $i++) { $positional.Add($argv[$i]) }
        break
    }

    # Long option: --name[=value], or -name[=value] (PowerShell style, 3+ chars)
    $body = $a.TrimStart('-')
    $name = $body; $value = $null; $hasValue = $false
    $sep = $body.IndexOfAny([char[]]'=:')
    if ($sep -ge 0) { $name = $body.Substring(0, $sep); $value = $body.Substring($sep + 1); $hasValue = $true }
    $lname = $name.ToLowerInvariant()
    $isDouble = $a.StartsWith('--')
    $matchesLong = @($longOptions.Keys | Where-Object { $_.StartsWith($lname) })
    if ($longOptions.Contains($lname)) { $matchesLong = @($lname) }
    if ($isDouble -or ($lname.Length -ge 3 -and $matchesLong.Count -ge 1)) {
        if ($matchesLong.Count -eq 0 -or $lname -eq '') { Stop-WithError "unrecognized option '$a'" }
        if ($matchesLong.Count -gt 1) { Stop-WithError "option '$a' is ambiguous; possibilities: $(($matchesLong | ForEach-Object { "--$_" }) -join ' ')" }
        $long = $matchesLong[0]
        $kind = $longOptions[$long]
        if ($kind -eq 'none' -and $hasValue -and $value -ne '') { Stop-WithError "option '--$long' doesn't allow an argument" }
        if ($kind -eq 'required' -and -not ($hasValue -and $value -ne '')) {
            $i++
            if ($i -ge $argv.Count) { Stop-WithError "option '--$long' requires an argument" }
            $value = $argv[$i]
        }
        Set-Option $long $value
        $i++
        continue
    }

    # Cluster of short options: -3wm, -n4, -w12
    $k = 1
    while ($k -lt $a.Length) {
        $ch = [string]$a[$k]
        $rest = $a.Substring($k + 1).TrimStart(':', '=')
        $def = $null
        if (-not $shortOptions.TryGetValue($ch, [ref]$def)) { Stop-WithError "invalid option -- '$ch'" }
        $value = $null
        if ($def[1] -eq 'required') {
            if ($rest) { $value = $rest }
            else {
                $i++
                if ($i -ge $argv.Count) { Stop-WithError "option requires an argument -- '$ch'" }
                $value = $argv[$i]
            }
            $k = $a.Length
        } elseif ($def[1] -eq 'optional') {
            if ($rest -match '^\d+$') { $value = $rest; $k = $a.Length } else { $k++ }
        } else {
            $k++
        }
        Set-Option $def[0] $value
    }
    $i++
}

if ($opt.Help) { Show-Usage; exit 0 }
if ($opt.Version) { "cal (PowerShell port) $script:Version"; exit 0 }

$script:Reform = $opt.Reform
$script:FirstDay = $opt.FirstDay
$script:Julian = $opt.Julian
$script:ShowWeeks = $opt.Week
$script:WeekHighlight = $opt.WeekHighlight

function Assert-Year([int]$y) {
    if ($y -lt 1 -or $y -gt 9999) { Stop-WithError "illegal year value: use 1-9999" }
}
function Assert-Month([int]$m) {
    if ($m -lt 1 -or $m -gt 12) { Stop-WithError "illegal month value: use 1-12" }
}
function Assert-Day([int]$y, [int]$m, [int]$d) {
    if (-not (Test-DayExists $y $m $d)) { Stop-WithError "illegal day value: $d is not a valid day of $(Get-MonthName $m) $y" }
}

function ConvertFrom-SystemDate([datetime]$dt) {
    return (ConvertFrom-Jdn (Get-Jdn $dt.Year $dt.Month $dt.Day -Gregorian))
}

function ConvertTo-MonthNumber([string]$text) {
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) { Assert-Month $n; return $n }
    $n = Find-Month $text
    if ($n -eq 0) { Stop-WithError "unknown month name: $text" }
    return $n
}

function ConvertTo-YearNumber([string]$text) {
    $n = 0
    if (-not [int]::TryParse($text, [ref]$n)) { Stop-WithError "invalid year: '$text'" }
    Assert-Year $n
    return $n
}

# "today" in the selected calendar
if ($opt.Today) {
    Assert-Year $opt.Today[0]; Assert-Month $opt.Today[1]
    if ($opt.Today[2] -ne 0) { Assert-Day $opt.Today[0] $opt.Today[1] $opt.Today[2] }
    $today = $opt.Today
} else {
    $today = ConvertFrom-SystemDate (Get-Date)
}

$refYear = $today[0]; $refMonth = $today[1]
$highlight = if ($today[2] -ne 0) { $today } else { $null }
$yearOnly = $false

switch ($positional.Count) {
    0 { }
    1 {
        $p = $positional[0]
        $date = $null
        if ($p -match '^@(-?\d+)$') {
            $date = ConvertFrom-SystemDate ([DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime)
        } elseif ($p -match '^(now|today)$') {
            $date = ConvertFrom-SystemDate (Get-Date)
        } elseif ($p -eq 'yesterday') {
            $date = ConvertFrom-SystemDate ((Get-Date).AddDays(-1))
        } elseif ($p -eq 'tomorrow') {
            $date = ConvertFrom-SystemDate ((Get-Date).AddDays(1))
        } elseif ($p -match '^\d+$') {
            $refYear = ConvertTo-YearNumber $p
            $yearOnly = $true
        } elseif ($null -ne ($parsed = ConvertFrom-DateText $p) -and $parsed[2] -ne 0) {
            Assert-Year $parsed[0]; Assert-Month $parsed[1]; Assert-Day $parsed[0] $parsed[1] $parsed[2]
            $date = $parsed
        } else {
            $m = Find-Month $p
            if ($m -eq 0) { Stop-WithError "failed to parse timestamp or unknown month name: $p" }
            $refMonth = $m
        }
        if ($date) { $refYear = $date[0]; $refMonth = $date[1]; $highlight = $date }
    }
    2 {
        $refMonth = ConvertTo-MonthNumber $positional[0]
        $refYear = ConvertTo-YearNumber $positional[1]
    }
    3 {
        $n = 0
        if (-not [int]::TryParse($positional[0], [ref]$n)) { Stop-WithError "illegal day value: '$($positional[0])'" }
        $refMonth = ConvertTo-MonthNumber $positional[1]
        $refYear = ConvertTo-YearNumber $positional[2]
        Assert-Day $refYear $refMonth $n
        $highlight = @($refYear, $refMonth, $n)
    }
    default { Stop-WithError "too many arguments" }
}

if ($opt.Highlight) {
    Assert-Year $opt.Highlight[0]; Assert-Month $opt.Highlight[1]
    Assert-Day $opt.Highlight[0] $opt.Highlight[1] $opt.Highlight[2]
    $highlight = $opt.Highlight
}
$script:Highlight = $highlight

# ---------------------------------------------------------------------------
# Easter
# ---------------------------------------------------------------------------

if ($opt.Easter) {
    $e = Get-Easter $refYear -Orthodox:($opt.Easter -eq 'orthodox')
    "{0} {1} {2}" -f (Get-MonthName $e[1]), $e[2], $e[0]
    exit 0
}

# ---------------------------------------------------------------------------
# Which months to show
# ---------------------------------------------------------------------------

$mode = $opt.Mode
if ($null -eq $mode) { $mode = if ($yearOnly) { 'y' } else { '1' } }

$ref = $refYear * 12 + ($refMonth - 1)
switch -CaseSensitive ($mode) {
    'y' { $start = $refYear * 12; $count = 12 }
    'Y' { $count = 12; $start = if ($opt.Span) { $ref - 6 } else { $ref } }
    '3' { $start = $ref - 1; $count = 3 }
    'n' { $count = $opt.Months; $start = if ($opt.Span) { $ref - [int][Math]::Floor($count / 2) } else { $ref } }
    default { $start = $ref; $count = 1 }
}
$start -= $opt.Before
$count += $opt.Before + $opt.After

$months = New-Object System.Collections.Generic.List[object]
for ($idx = $start; $idx -lt $start + $count; $idx++) {
    $y = [int][Math]::Floor($idx / 12)
    if ($y -ge 1 -and $y -le 9999) { $months.Add(@($y, ($idx - 12 * $y + 1))) }
}
if ($months.Count -eq 0) { Stop-WithError "illegal year value: use 1-9999" }

$yearLayout = ($mode -ceq 'y' -and $opt.Before -eq 0 -and $opt.After -eq 0)

# ---------------------------------------------------------------------------
# Output mode
# ---------------------------------------------------------------------------

$toHost = Test-HostOutput
$colorWhen = $opt.Color
if ($colorWhen -eq 'auto' -and $env:NO_COLOR) { $colorWhen = 'never' }
$renderMode = switch ($colorWhen) {
    'always' { if ($toHost) { 'host' } else { 'ansi' } }
    'never'  { 'plain' }
    default  { if ($toHost) { 'host' } else { 'plain' } }
}

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

$gap = '  '
$cellWidth = if ($script:Julian) { 3 } else { 2 }
if ($opt.Vertical) {
    $blockWidth = 6 * ($cellWidth + 1)
    $leadWidth = 2
} else {
    $blockWidth = 7 * $cellWidth + 6 + $(if ($script:ShowWeeks) { 3 } else { 0 })
    $leadWidth = 0
}

if ($opt.Columns) {
    $columns = $opt.Columns
} else {
    $columns = 3
    if ($toHost) {
        $termWidth = 80
        try { $termWidth = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
        if ($termWidth -le 0) { $termWidth = 80 }
        while ($columns -gt 1 -and ($leadWidth + $columns * $blockWidth + ($columns - 1) * $gap.Length) -ge $termWidth) {
            $columns--
        }
    }
}
$columns = [Math]::Min($columns, $months.Count)

$output = New-Object System.Collections.Generic.List[object]
if ($yearLayout) {
    $line = New-Line
    Add-Centered $line ([string]$refYear) ($leadWidth + $columns * $blockWidth + ($columns - 1) * $gap.Length) 'title'
    $output.Add($line)
    $output.Add((New-Line))
}

$leader = if ($opt.Vertical) { New-DayNamesBlock } else { $null }
for ($row = 0; $row * $columns -lt $months.Count; $row++) {
    if ($row -gt 0) { $output.Add((New-Line)) }
    $blocks = @()
    for ($c = 0; $c -lt $columns -and $row * $columns + $c -lt $months.Count; $c++) {
        $ym = $months[$row * $columns + $c]
        $title = if ($yearLayout) { Get-MonthName $ym[1] } else { "$(Get-MonthName $ym[1]) $($ym[0])" }
        if ($opt.Vertical) { $blocks += , (New-VerticalBlock $ym[0] $ym[1] $title) }
        else { $blocks += , (New-HorizontalBlock $ym[0] $ym[1] $title) }
    }
    $joined = Join-Blocks $blocks $gap $leader
    # drop trailing week rows that are empty in every month of this row
    while ($joined.Count -gt 2 -and
           [string]::IsNullOrWhiteSpace((($joined[$joined.Count - 1] | ForEach-Object { $_[0] }) -join ''))) {
        $joined.RemoveAt($joined.Count - 1)
    }
    foreach ($l in $joined) { $output.Add($l) }
}

Write-Calendar $output $renderMode
