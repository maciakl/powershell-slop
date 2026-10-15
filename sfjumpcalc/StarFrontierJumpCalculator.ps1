#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive text user interface (TUI) travel calculator for Star Frontiers
    style starships.

.DESCRIPTION
    StarFrontierJumpCalculator lets you type a distance and instantly see:

      * how many Void jumps a ship needs to cover it,
      * how long the jumps take once the folding array cool-down is included,
      * how long the trip takes at sub-light speed, both with a vectoring
        array and with a chemical torch drive.

    Results update in real time as you type. Ship specs (advanced cooling,
    folding array size and advanced vectoring array) can be toggled from the
    keyboard and reset to defaults at any time.

    Distance input is free form:
        12          -> 12 parsecs (parsecs are the default unit)
        12 P, 12pc  -> 12 parsecs
        1000 AU     -> 1,000 astronomical units
        200K AU     -> 200,000 AU  (also 200kau; M and G prefixes work too)
        2.5kp       -> 2.5 kilo-parsecs  (2,500 P)
        1 MP        -> 1 mega-parsec     (1,000,000 P)
    Units are case-insensitive and spaces between the number, prefix and
    unit are optional.

    Keyboard:
        Tab / Shift+Tab, Up / Down   Move between fields
        Space / Enter                Toggle the focused option
        Left / Right                 Change folding array (or move the text cursor)
        Home / End, Backspace, Del   Edit the distance
        Esc or Ctrl+L                Clear the distance
        Ctrl+R or F5                 Reset ship specs to defaults
        Ctrl+Q, Ctrl+C or F10        Quit

    The script has no external dependencies and runs on Windows PowerShell 5.1
    (the version that ships with Windows 11) as well as PowerShell 7+.

.EXAMPLE
    PS> .\StarFrontierJumpCalculator.ps1

    Starts the interactive calculator.

.EXAMPLE
    PS> . .\StarFrontierJumpCalculator.ps1
    PS> ConvertFrom-DistanceText -Text '2.5 kp'

    Dot-sourcing loads the functions without starting the UI, which is useful
    for testing or scripting the calculations.

.NOTES
    File name : StarFrontierJumpCalculator.ps1
    Requires  : An interactive console (Windows Terminal, conhost, VS Code
                terminal). The PowerShell ISE is not supported.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants ----------------------------------------------------------

# Astronomical units in one parsec (IAU definition: 648000 / pi).
$script:AuPerParsec = 648000 / [math]::PI

# Calendar conversions used when picking a display unit for durations.
$script:HoursPerDay  = 24.0
$script:DaysPerWeek  = 7.0
$script:DaysPerYear  = 365.25
$script:DaysPerMonth = $script:DaysPerYear / 12

# Ship performance figures.
$script:StandardCooldownHours  = 20.0   # Folding array cool-down between jumps.
$script:AdvancedCooldownHours  = 12.0   # ...with advanced cooling installed.
$script:StandardVectoringAuPerHour = 5.0
$script:AdvancedVectoringAuPerHour = 7.0
$script:TorchAuPerHour = 1.0 / $script:HoursPerDay   # Chemical torch: 1 AU per day.

# Folding array options, in display order. Range is in parsecs per jump.
$script:FoldingArrays = @(
    [pscustomobject]@{ Name = 'Standard'; RangeParsecs = 10.0 }
    [pscustomobject]@{ Name = 'Dual';     RangeParsecs = 20.0 }
    [pscustomobject]@{ Name = 'Quad';     RangeParsecs = 40.0 }
)

# Multipliers that convert an input unit to parsecs. Keys are lower case.
$script:UnitToParsecs = @{
    ''        = 1.0
    'p'       = 1.0
    'pc'      = 1.0
    'parsec'  = 1.0
    'parsecs' = 1.0
    'au'      = 1.0 / $script:AuPerParsec
    'kau'     = 1e3 / $script:AuPerParsec
    'mau'     = 1e6 / $script:AuPerParsec
    'gau'     = 1e9 / $script:AuPerParsec
    'kp'      = 1e3
    'kpc'     = 1e3
    'mp'      = 1e6
    'mpc'     = 1e6
}

# Longest distance string the input box accepts.
$script:MaxDistanceLength = 32

# Focusable fields, in Tab order.
$script:FieldDistance  = 0
$script:FieldCooling   = 1
$script:FieldArray     = 2
$script:FieldVectoring = 3
$script:FieldCount     = 4

# Minimum console size required to draw the full interface.
$script:MinWidth  = 80
$script:MinHeight = 26

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

#endregion

#region Calculation functions ----------------------------------------------

function Format-SINumber {
    <#
    .SYNOPSIS
        Formats a number, abbreviating large values with SI prefixes.
    .DESCRIPTION
        Values of 1,000 or more are scaled and suffixed with K, M, G, T, P, E,
        Z or Y (e.g. 1500 -> "1.5K", 1000000 -> "1M"). Smaller values are shown
        with up to two decimals; tiny values use scientific notation.
    .EXAMPLE
        Format-SINumber -Value 1234567   # 1.23M
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 'n/a' }
    if ($Value -eq 0) { return '0' }

    $magnitude = [math]::Abs($Value)
    $sign = if ($Value -lt 0) { '-' } else { '' }

    if ($magnitude -lt 0.01) {
        return $sign + $magnitude.ToString('0.##E+0', $script:Invariant)
    }

    $prefixes = @('', 'K', 'M', 'G', 'T', 'P', 'E', 'Z', 'Y')
    $index = 0
    # Compare against the rounded value so 999,999 becomes "1M" rather than "1000K".
    while ([math]::Round($magnitude, 2) -ge 1000 -and $index -lt $prefixes.Count - 1) {
        $magnitude /= 1000
        $index++
    }

    if ([math]::Round($magnitude, 2) -ge 1000) {
        # Beyond yotta: fall back to scientific notation.
        return $sign + [math]::Abs($Value).ToString('0.##E+0', $script:Invariant)
    }

    return $sign + $magnitude.ToString('0.##', $script:Invariant) + $prefixes[$index]
}

function Format-Duration {
    <#
    .SYNOPSIS
        Converts a number of hours into a human friendly duration string.
    .DESCRIPTION
        Chooses the most appropriate unit (seconds, minutes, hours, days, weeks,
        months or years) and abbreviates large numbers with SI prefixes.
    .EXAMPLE
        Format-Duration -Hours 40    # 1.67 days
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Hours
    )

    if ($Hours -le 0) { return 'Instant' }

    $days = $Hours / $script:HoursPerDay

    if     ($Hours -lt (1.0 / 60)) { $amount = $Hours * 3600;                 $unit = 'second' }
    elseif ($Hours -lt 1)          { $amount = $Hours * 60;                   $unit = 'minute' }
    elseif ($days -lt 1)           { $amount = $Hours;                        $unit = 'hour' }
    elseif ($days -lt $script:DaysPerWeek)  { $amount = $days;                $unit = 'day' }
    elseif ($days -lt $script:DaysPerMonth) { $amount = $days / $script:DaysPerWeek;  $unit = 'week' }
    elseif ($days -lt $script:DaysPerYear)  { $amount = $days / $script:DaysPerMonth; $unit = 'month' }
    else                           { $amount = $days / $script:DaysPerYear;  $unit = 'year' }

    $text = Format-SINumber -Value $amount
    if ($text -ne '1') { $unit += 's' }
    return "$text $unit"
}

function ConvertFrom-DistanceText {
    <#
    .SYNOPSIS
        Parses free-form distance text into parsecs.
    .DESCRIPTION
        Accepts a positive number optionally followed by a unit: P (default),
        AU, KP or MP. AU also takes a K, M or G prefix (200K AU, 1.5MAU).
        Units are case-insensitive and spaces between the number, prefix and
        unit are optional. Thousands separators (commas) and exponents are
        allowed. Returns an object with IsValid, IsEmpty, Parsecs and Message.
    .EXAMPLE
        ConvertFrom-DistanceText -Text '1000 au'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $result = [pscustomobject]@{
        IsValid = $false
        IsEmpty = $false
        Parsecs = 0.0
        Message = ''
    }

    $trimmed = $Text.Trim()
    if ($trimmed.Length -eq 0) {
        $result.IsEmpty = $true
        $result.Message = 'Enter a distance, e.g. 12, 1000 AU, 2.5 KP or 1 MP.'
        return $result
    }

    $pattern = '^(?<number>[+-]?(?:\d[\d,]*(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)\s*(?<unit>[a-z][a-z\s]*)?$'
    $match = [regex]::Match($trimmed, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        $result.Message = 'Not a valid distance. Please re-enter, e.g. 12, 1000 AU or 2.5 KP.'
        return $result
    }

    $number = 0.0
    $numberText = $match.Groups['number'].Value -replace ',', ''
    $parsed = [double]::TryParse($numberText, [System.Globalization.NumberStyles]::Float,
        $script:Invariant, [ref]$number)
    if (-not $parsed -or [double]::IsInfinity($number) -or [double]::IsNaN($number)) {
        $result.Message = 'Not a valid number. Please re-enter.'
        return $result
    }

    # Drop spaces so '200 K AU' and '200KAU' resolve to the same unit.
    $unit = ($match.Groups['unit'].Value -replace '\s', '').ToLowerInvariant()
    if (-not $script:UnitToParsecs.ContainsKey($unit)) {
        $result.Message = "Unknown unit '$($match.Groups['unit'].Value)'. Use P, AU, KAU, MAU, KP or MP."
        return $result
    }

    if ($number -le 0) {
        $result.Message = 'Distance must be greater than zero. Please re-enter.'
        return $result
    }

    $parsecs = $number * $script:UnitToParsecs[$unit]
    if ([double]::IsInfinity($parsecs)) {
        $result.Message = 'Distance is too large. Please re-enter.'
        return $result
    }

    $result.IsValid = $true
    $result.Parsecs = $parsecs
    return $result
}

function Get-ShipSpec {
    <#
    .SYNOPSIS
        Returns the effective performance figures for the current ship options.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $cooldown  = if ($State.AdvancedCooling) { $script:AdvancedCooldownHours } else { $script:StandardCooldownHours }
    $vectoring = if ($State.AdvancedVectoring) { $script:AdvancedVectoringAuPerHour } else { $script:StandardVectoringAuPerHour }
    $array     = $script:FoldingArrays[$State.FoldingArrayIndex]

    [pscustomobject]@{
        FoldingArrayName   = $array.Name
        JumpRangeParsecs   = $array.RangeParsecs
        CooldownHours      = $cooldown
        VectoringAuPerHour = $vectoring
        TorchAuPerHour     = $script:TorchAuPerHour
    }
}

function Get-TravelEstimate {
    <#
    .SYNOPSIS
        Calculates jump count and travel times for a distance and ship spec.
    .DESCRIPTION
        Jumps are instantaneous; the ship must wait the folding array cool-down
        between jumps, so N jumps take (N - 1) cool-down periods. Sub-light
        times are simply distance divided by speed.
    .EXAMPLE
        Get-TravelEstimate -Parsecs 25 -Spec (Get-ShipSpec -State $state)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [double]$Parsecs,

        [Parameter(Mandatory)]
        [pscustomobject]$Spec
    )

    $au = $Parsecs * $script:AuPerParsec

    # Small tolerance so floating point noise (e.g. 30.000000001 / 10) does not
    # add a spurious extra jump.
    $jumps = [math]::Max(1, [math]::Ceiling(($Parsecs / $Spec.JumpRangeParsecs) - 1e-9))

    [pscustomobject]@{
        Parsecs        = $Parsecs
        AU             = $au
        Jumps          = $jumps
        JumpHours      = ($jumps - 1) * $Spec.CooldownHours
        VectoringHours = $au / $Spec.VectoringAuPerHour
        TorchHours     = $au / $Spec.TorchAuPerHour
    }
}

#endregion

#region State management --------------------------------------------------

function New-CalculatorState {
    <#
    .SYNOPSIS
        Creates the mutable UI state with default ship specs and no distance.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $state = [pscustomobject]@{
        DistanceText      = ''
        CursorIndex       = 0
        Focus             = $script:FieldDistance
        AdvancedCooling   = $false
        FoldingArrayIndex = 0
        AdvancedVectoring = $false
        Status            = ''
        Running           = $true
    }
    Reset-ShipSpec -State $state
    return $state
}

function Reset-ShipSpec {
    <#
    .SYNOPSIS
        Restores the default ship: standard cooling, standard folding array,
        standard vectoring array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $State.AdvancedCooling   = $false
    $State.FoldingArrayIndex = 0
    $State.AdvancedVectoring = $false
}

function Clear-Distance {
    <#
    .SYNOPSIS
        Empties the distance input and moves focus back to it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $State.DistanceText = ''
    $State.CursorIndex  = 0
    $State.Focus        = $script:FieldDistance
}

function Test-IsDefaultShipSpec {
    <#
    .SYNOPSIS
        Returns $true when every ship option is at its default value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    return (-not $State.AdvancedCooling) -and ($State.FoldingArrayIndex -eq 0) -and (-not $State.AdvancedVectoring)
}

#endregion

#region Input handling -----------------------------------------------------

function Move-Focus {
    <#
    .SYNOPSIS
        Moves focus forward or backward through the fields, wrapping around.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [ValidateSet(-1, 1)]
        [int]$Direction
    )

    $State.Focus = ($State.Focus + $Direction + $script:FieldCount) % $script:FieldCount
    if ($State.Focus -eq $script:FieldDistance) {
        $State.CursorIndex = $State.DistanceText.Length
    }
}

function Add-DistanceCharacter {
    <#
    .SYNOPSIS
        Inserts a typed character into the distance at the cursor position.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [char]$Character
    )

    if ($State.DistanceText.Length -ge $script:MaxDistanceLength) {
        $State.Status = "Distance is limited to $($script:MaxDistanceLength) characters."
        return
    }
    $State.DistanceText = $State.DistanceText.Insert($State.CursorIndex, [string]$Character)
    $State.CursorIndex++
}

function Invoke-DistanceKey {
    <#
    .SYNOPSIS
        Handles a key press while the distance field has focus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [System.ConsoleKeyInfo]$KeyInfo
    )

    switch ($KeyInfo.Key) {
        ([ConsoleKey]::Backspace) {
            if ($State.CursorIndex -gt 0) {
                $State.DistanceText = $State.DistanceText.Remove($State.CursorIndex - 1, 1)
                $State.CursorIndex--
            }
            return
        }
        ([ConsoleKey]::Delete) {
            if ($State.CursorIndex -lt $State.DistanceText.Length) {
                $State.DistanceText = $State.DistanceText.Remove($State.CursorIndex, 1)
            }
            return
        }
        ([ConsoleKey]::LeftArrow)  { if ($State.CursorIndex -gt 0) { $State.CursorIndex-- }; return }
        ([ConsoleKey]::RightArrow) { if ($State.CursorIndex -lt $State.DistanceText.Length) { $State.CursorIndex++ }; return }
        ([ConsoleKey]::Home)       { $State.CursorIndex = 0; return }
        ([ConsoleKey]::End)        { $State.CursorIndex = $State.DistanceText.Length; return }
        ([ConsoleKey]::Enter) {
            # Results are already live; Enter just confirms or asks for a fix.
            $parsed = ConvertFrom-DistanceText -Text $State.DistanceText
            if ($parsed.IsValid) { Move-Focus -State $State -Direction 1 }
            else { $State.Status = 'Please re-enter the distance.' }
            return
        }
    }

    $char = $KeyInfo.KeyChar
    if ($char -ne [char]0 -and -not [char]::IsControl($char)) {
        Add-DistanceCharacter -State $State -Character $char
    }
}

function Invoke-ShipSpecKey {
    <#
    .SYNOPSIS
        Handles a key press while one of the ship spec fields has focus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [System.ConsoleKeyInfo]$KeyInfo
    )

    $key = $KeyInfo.Key
    $isToggle = $key -eq [ConsoleKey]::Spacebar -or $key -eq [ConsoleKey]::Enter
    $isLeft   = $key -eq [ConsoleKey]::LeftArrow
    $isRight  = $key -eq [ConsoleKey]::RightArrow

    switch ($State.Focus) {
        $script:FieldCooling {
            if ($isToggle -or $isLeft -or $isRight) { $State.AdvancedCooling = -not $State.AdvancedCooling; return }
        }
        $script:FieldVectoring {
            if ($isToggle -or $isLeft -or $isRight) { $State.AdvancedVectoring = -not $State.AdvancedVectoring; return }
        }
        $script:FieldArray {
            $count = $script:FoldingArrays.Count
            if ($isLeft) { $State.FoldingArrayIndex = ($State.FoldingArrayIndex - 1 + $count) % $count; return }
            if ($isToggle -or $isRight) { $State.FoldingArrayIndex = ($State.FoldingArrayIndex + 1) % $count; return }
        }
    }

    # Typing anything printable (other than Space) jumps straight to the
    # distance field so the user never has to navigate there first.
    $char = $KeyInfo.KeyChar
    if ($char -ne [char]0 -and -not [char]::IsControl($char) -and -not [char]::IsWhiteSpace($char)) {
        $State.Focus = $script:FieldDistance
        $State.CursorIndex = $State.DistanceText.Length
        Add-DistanceCharacter -State $State -Character $char
    }
}

function Invoke-KeyInput {
    <#
    .SYNOPSIS
        Dispatches a single key press: global shortcuts first, then the
        handler for the focused field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [System.ConsoleKeyInfo]$KeyInfo
    )

    $State.Status = ''
    $key   = $KeyInfo.Key
    $ctrl  = ($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $alt   = ($KeyInfo.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
    $shift = ($KeyInfo.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
    # Ctrl+Alt is AltGr on many keyboard layouts and produces normal characters.
    $command = $ctrl -and -not $alt

    if ($key -eq [ConsoleKey]::F10 -or ($command -and ($key -eq [ConsoleKey]::Q -or $key -eq [ConsoleKey]::C))) {
        $State.Running = $false
        return
    }
    if ($key -eq [ConsoleKey]::F5 -or ($command -and $key -eq [ConsoleKey]::R)) {
        Reset-ShipSpec -State $State
        $State.Status = 'Ship specs reset to defaults.'
        return
    }
    if ($key -eq [ConsoleKey]::Escape -or ($command -and $key -eq [ConsoleKey]::L)) {
        Clear-Distance -State $State
        $State.Status = 'Distance cleared.'
        return
    }
    if ($key -eq [ConsoleKey]::Tab) {
        $direction = if ($shift) { -1 } else { 1 }
        Move-Focus -State $State -Direction $direction
        return
    }
    if ($key -eq [ConsoleKey]::UpArrow)   { Move-Focus -State $State -Direction -1; return }
    if ($key -eq [ConsoleKey]::DownArrow) { Move-Focus -State $State -Direction 1; return }
    if ($command) { return }   # Ignore any other Ctrl shortcut.

    if ($State.Focus -eq $script:FieldDistance) {
        Invoke-DistanceKey -State $State -KeyInfo $KeyInfo
    }
    else {
        Invoke-ShipSpecKey -State $State -KeyInfo $KeyInfo
    }
}

#endregion

#region Rendering ----------------------------------------------------------

function New-Segment {
    <#
    .SYNOPSIS
        Creates a coloured run of text for the screen frame.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Position = 1)]
        [ConsoleColor]$Foreground = [ConsoleColor]::Gray,

        [Parameter(Position = 2)]
        [Nullable[ConsoleColor]]$Background = $null
    )

    [pscustomobject]@{ Text = $Text; Foreground = $Foreground; Background = $Background }
}

function Get-ScreenFrame {
    <#
    .SYNOPSIS
        Builds the full screen as a list of lines made of coloured segments.
    .DESCRIPTION
        Rendering is split from drawing so the layout is easy to read and the
        console is written in a single pass. Also records where the text cursor
        should be placed when the distance field has focus.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $lines = New-Object 'System.Collections.Generic.List[object]'
    $frame = [pscustomobject]@{ Lines = $lines; CursorRow = -1; CursorColumn = -1 }

    $spec     = Get-ShipSpec -State $State
    $distance = ConvertFrom-DistanceText -Text $State.DistanceText

    # Focus helpers: a marker in the left margin and a highlighted label.
    $marker = {
        param([int]$Field)
        if ($State.Focus -eq $Field) { New-Segment ' > ' Yellow } else { New-Segment '   ' }
    }
    $label = {
        param([int]$Field, [string]$Text)
        if ($State.Focus -eq $Field) { New-Segment $Text Black Cyan } else { New-Segment $Text White }
    }
    $checkbox = {
        param([bool]$Checked)
        if ($Checked) { New-Segment '[x] ' Green } else { New-Segment '[ ] ' DarkGray }
    }

    $rule = '-' * 76

    # --- Title -------------------------------------------------------------
    $lines.Add(@())
    $lines.Add(@((New-Segment '  STAR FRONTIERS JUMP CALCULATOR' Yellow)))
    $lines.Add(@((New-Segment "  $rule" DarkGray)))

    # --- Distance ----------------------------------------------------------
    $lines.Add(@((New-Segment '  DISTANCE' Cyan)))
    $boxWidth = $script:MaxDistanceLength + 1
    $prefix = & $marker $script:FieldDistance
    $fieldLabel = & $label $script:FieldDistance 'Distance:'
    $boxText = $State.DistanceText.PadRight($boxWidth)
    $lines.Add(@($prefix, $fieldLabel, (New-Segment ' ['), (New-Segment $boxText White DarkBlue), (New-Segment ']')))
    $frame.CursorRow    = $lines.Count - 1
    $frame.CursorColumn = $prefix.Text.Length + $fieldLabel.Text.Length + 2 + $State.CursorIndex

    $lines.Add(@((New-Segment '      Units: P (default), AU, KAU, MAU, KP, MP.  e.g. 12, 200K AU, 2.5kp' DarkGray)))

    if ($distance.IsValid) {
        $lines.Add(@(
            (New-Segment '      = '),
            (New-Segment "$(Format-SINumber $distance.Parsecs) P" Green),
            (New-Segment '   =   '),
            (New-Segment "$(Format-SINumber ($distance.Parsecs * $script:AuPerParsec)) AU" Green)
        ))
    }
    elseif ($distance.IsEmpty) {
        $lines.Add(@((New-Segment "      $($distance.Message)" DarkYellow)))
    }
    else {
        $lines.Add(@((New-Segment "      $($distance.Message)" Red)))
    }
    $lines.Add(@())

    # --- Ship specs --------------------------------------------------------
    $specHeader = @((New-Segment '  SHIP SPECS' Cyan))
    if (-not (Test-IsDefaultShipSpec -State $State)) { $specHeader += New-Segment '  (modified - Ctrl+R / F5 resets)' DarkYellow }
    $lines.Add($specHeader)

    $lines.Add(@(
        (& $marker $script:FieldCooling),
        (& $checkbox $State.AdvancedCooling),
        (& $label $script:FieldCooling 'Advanced folding array cooling'),
        (New-Segment ('  cool-down {0} h  (std {1} / adv {2} h)' -f $spec.CooldownHours,
            $script:StandardCooldownHours, $script:AdvancedCooldownHours) DarkGray)
    ))

    $arrayLine = @((& $marker $script:FieldArray), (& $label $script:FieldArray 'Folding array:'), (New-Segment ' '))
    for ($i = 0; $i -lt $script:FoldingArrays.Count; $i++) {
        $option = $script:FoldingArrays[$i]
        $text = '{0} ({1} P)' -f $option.Name, $option.RangeParsecs
        if ($i -eq $State.FoldingArrayIndex) {
            $arrayLine += New-Segment " (*) $text" Green
        }
        else {
            $arrayLine += New-Segment " ( ) $text" DarkGray
        }
    }
    $lines.Add($arrayLine)

    $lines.Add(@(
        (& $marker $script:FieldVectoring),
        (& $checkbox $State.AdvancedVectoring),
        (& $label $script:FieldVectoring 'Advanced vectoring array'),
        (New-Segment ('        sub-light {0} AU/h  (std {1} / adv {2} AU/h)' -f $spec.VectoringAuPerHour,
            $script:StandardVectoringAuPerHour, $script:AdvancedVectoringAuPerHour) DarkGray)
    ))

    $lines.Add(@())
    $lines.Add(@(
        (New-Segment '     Max jump: '),
        (New-Segment "$($spec.JumpRangeParsecs) P" White),
        (New-Segment ' every '),
        (New-Segment "$($spec.CooldownHours) h" White),
        (New-Segment '  |  Sub-light: '),
        (New-Segment "$($spec.VectoringAuPerHour) AU/h" White),
        (New-Segment ' vectoring, '),
        (New-Segment '1 AU/day' White),
        (New-Segment ' torch')
    ))
    $lines.Add(@())

    # --- Results -----------------------------------------------------------
    $lines.Add(@((New-Segment '  RESULTS' Cyan)))
    if ($distance.IsValid) {
        $estimate = Get-TravelEstimate -Parsecs $distance.Parsecs -Spec $spec
        $jumpWord = if ($estimate.Jumps -eq 1) { 'jump' } else { 'jumps' }
        $jumpDetail = if ($estimate.Jumps -eq 1) {
            'no cool-down needed'
        }
        else {
            '{0} x {1} h cool-downs' -f (Format-SINumber ($estimate.Jumps - 1)), $spec.CooldownHours
        }
        $results = @(
            @('Jumps required',             "$(Format-SINumber $estimate.Jumps) $jumpWord", "$($spec.JumpRangeParsecs) P per jump"),
            @('Time using jumps',           (Format-Duration $estimate.JumpHours),  $jumpDetail),
            @('Sub-light, vectoring array', (Format-Duration $estimate.VectoringHours), "$(Format-SINumber $estimate.VectoringHours) h at $($spec.VectoringAuPerHour) AU/h"),
            @('Sub-light, chemical torch',  (Format-Duration $estimate.TorchHours), "$(Format-SINumber ($estimate.TorchHours / $script:HoursPerDay)) days at 1 AU/day")
        )
    }
    else {
        $results = @(
            @('Jumps required', '--', ''),
            @('Time using jumps', '--', ''),
            @('Sub-light, vectoring array', '--', ''),
            @('Sub-light, chemical torch', '--', '')
        )
    }
    foreach ($row in $results) {
        $lines.Add(@(
            (New-Segment ('     ' + ($row[0] + ' ').PadRight(28, '.') + ' ')),
            (New-Segment $row[1].PadRight(16) Green),
            (New-Segment $row[2] DarkGray)
        ))
    }
    $lines.Add(@())

    # --- Status and help ---------------------------------------------------
    $lines.Add(@((New-Segment "  $($State.Status)" Yellow)))
    $lines.Add(@((New-Segment "  $rule" DarkGray)))
    $lines.Add(@(
        (New-Segment '  Tab/Up/Down' White), (New-Segment ' move   '),
        (New-Segment 'Space/Enter' White), (New-Segment ' toggle   '),
        (New-Segment 'Left/Right' White), (New-Segment ' change array / cursor')
    ))
    $lines.Add(@(
        (New-Segment '  Esc/Ctrl+L' White), (New-Segment ' clear distance   '),
        (New-Segment 'Ctrl+R/F5' White), (New-Segment ' reset specs   '),
        (New-Segment 'Ctrl+Q/F10' White), (New-Segment ' quit')
    ))

    return $frame
}

function Write-Frame {
    <#
    .SYNOPSIS
        Draws a frame to the console in place, without clearing the screen,
        to avoid flicker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Frame,

        [Parameter(Mandatory)]
        [pscustomobject]$State,

        [Parameter(Mandatory)]
        [ConsoleColor]$DefaultForeground,

        [Parameter(Mandatory)]
        [ConsoleColor]$DefaultBackground
    )

    $width  = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    # Never write into the last column/row: doing so can scroll the buffer.
    $usableWidth = [math]::Max(1, $width - 1)
    $usableRows  = [math]::Max(1, $height - 1)

    [Console]::CursorVisible = $false

    if ($width -lt $script:MinWidth -or $height -lt $script:MinHeight) {
        $Frame = [pscustomobject]@{
            Lines        = @(
                @(),
                @((New-Segment '  Please enlarge the console window.' Yellow)),
                @((New-Segment ("  Needs at least {0} x {1}; current size {2} x {3}." -f $script:MinWidth, $script:MinHeight, $width, $height))),
                @((New-Segment '  Press Ctrl+Q or F10 to quit.' DarkGray))
            )
            CursorRow    = -1
            CursorColumn = -1
        }
    }

    $row = 0
    foreach ($line in $Frame.Lines) {
        if ($row -ge $usableRows) { break }
        [Console]::SetCursorPosition(0, $row)
        $column = 0
        foreach ($segment in $line) {
            $remaining = $usableWidth - $column
            if ($remaining -le 0) { break }
            $text = $segment.Text
            if ($text.Length -gt $remaining) { $text = $text.Substring(0, $remaining) }
            [Console]::ForegroundColor = $segment.Foreground
            [Console]::BackgroundColor = if ($null -ne $segment.Background) { $segment.Background } else { $DefaultBackground }
            [Console]::Write($text)
            $column += $text.Length
        }
        [Console]::ForegroundColor = $DefaultForeground
        [Console]::BackgroundColor = $DefaultBackground
        if ($column -lt $usableWidth) { [Console]::Write(' ' * ($usableWidth - $column)) }
        $row++
    }

    # Blank any rows left over from a previous, longer frame.
    $blank = ' ' * $usableWidth
    for (; $row -lt $usableRows; $row++) {
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write($blank)
    }

    # Show the text cursor only while the distance field is being edited.
    if ($State.Focus -eq $script:FieldDistance -and $Frame.CursorRow -ge 0 -and
        $Frame.CursorRow -lt $usableRows -and $Frame.CursorColumn -lt $usableWidth) {
        [Console]::SetCursorPosition($Frame.CursorColumn, $Frame.CursorRow)
        [Console]::CursorVisible = $true
    }
    else {
        [Console]::SetCursorPosition(0, [math]::Min($row, $usableRows - 1))
    }
}

#endregion

#region Main loop ----------------------------------------------------------

function Assert-InteractiveConsole {
    <#
    .SYNOPSIS
        Throws a friendly error when the host cannot run a keyboard driven TUI.
    #>
    [CmdletBinding()]
    param()

    if ($Host.Name -eq 'Windows PowerShell ISE Host') {
        throw 'This calculator needs a real console. Run it from Windows Terminal or a PowerShell console window, not the ISE.'
    }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'This calculator is interactive and cannot run with redirected input or output.'
    }
}

function Start-JumpCalculator {
    <#
    .SYNOPSIS
        Runs the interactive calculator until the user quits.
    .DESCRIPTION
        Polls the keyboard so the screen can also be redrawn when the console
        window is resized. All pending keys are processed before redrawing, so
        pasted text appears in one update. Console settings are restored on
        exit, even if an error occurs.
    #>
    [CmdletBinding()]
    param()

    Assert-InteractiveConsole

    $state = New-CalculatorState
    $originalForeground = [Console]::ForegroundColor
    $originalBackground = [Console]::BackgroundColor
    $originalTreatCtrlC = [Console]::TreatControlCAsInput
    $originalTitle      = $Host.UI.RawUI.WindowTitle

    try {
        # Let Ctrl+C arrive as a key so it exits cleanly instead of aborting.
        [Console]::TreatControlCAsInput = $true
        $Host.UI.RawUI.WindowTitle = 'Star Frontiers Jump Calculator'
        Clear-Host

        $lastWidth  = [Console]::WindowWidth
        $lastHeight = [Console]::WindowHeight
        $needsDraw  = $true

        while ($state.Running) {
            if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                $lastWidth  = [Console]::WindowWidth
                $lastHeight = [Console]::WindowHeight
                Clear-Host
                $needsDraw = $true
            }

            if ($needsDraw) {
                $frame = Get-ScreenFrame -State $state
                Write-Frame -Frame $frame -State $state -DefaultForeground $originalForeground -DefaultBackground $originalBackground
                $needsDraw = $false
            }

            if ([Console]::KeyAvailable) {
                while ([Console]::KeyAvailable -and $state.Running) {
                    Invoke-KeyInput -State $state -KeyInfo ([Console]::ReadKey($true))
                }
                $needsDraw = $true
            }
            else {
                Start-Sleep -Milliseconds 30
            }
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $originalTreatCtrlC
        [Console]::ForegroundColor = $originalForeground
        [Console]::BackgroundColor = $originalBackground
        [Console]::CursorVisible = $true
        $Host.UI.RawUI.WindowTitle = $originalTitle
        Clear-Host
    }
}

#endregion

# Start the UI unless the script is being dot-sourced (e.g. for testing).
if ($MyInvocation.InvocationName -ne '.') {
    Start-JumpCalculator
}
