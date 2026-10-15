<#
.SYNOPSIS
    Interactive terminal (TUI) password strength analyzer.

.DESCRIPTION
    PasswordAnalyzer.ps1 lets you type a password and see live feedback about
    its strength. Every keystroke updates:

      * Length
      * Number of uppercase letters, lowercase letters, digits and special
        characters
      * The size of the character pool an attacker would have to search
      * Entropy (in bits)
      * A strength rating (Weak / Medium / Strong)
      * Approximate brute-force time for several attack scenarios
      * Suggestions for improving the password

    Input is masked by default. Keys:

      Tab           Show / hide the password
      Backspace     Delete the last character
      Esc, Ctrl+U   Clear the password and start over
      Ctrl+Q, Ctrl+C  Quit

    The password is held only in memory, is never written to disk, and the
    screen is cleared on exit.

    The script has no external dependencies and runs on both Windows
    PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.

.PARAMETER GuessesPerSecond
    Attacker guess rate used for the headline "Time to crack" estimate.
    Defaults to 10 billion guesses per second (a fast offline attack on an
    unsalted, fast hash using GPU hardware).

.EXAMPLE
    .\PasswordAnalyzer.ps1

    Starts the interactive analyzer.

.EXAMPLE
    .\PasswordAnalyzer.ps1 -GuessesPerSecond 1e6

    Starts the analyzer, using one million guesses per second for the
    headline crack-time estimate.

.EXAMPLE
    . .\PasswordAnalyzer.ps1
    Get-PasswordAnalysis -Password 'Tr0ub4dor&3'

    Dot-sources the script (which loads the functions without starting the
    TUI) and analyzes a password non-interactively.

.NOTES
    Entropy is calculated as Length * log2(PoolSize), where the pool size is
    the sum of the character classes present in the password:

      a-z                        26
      A-Z                        26
      0-9                        10
      ASCII symbols and space    33
      Any non-ASCII character   100  (rough approximation)

    This is the classic "brute force" model. It does NOT detect dictionary
    words, keyboard patterns or leaked passwords, so real-world strength of
    passwords built from common words may be much lower than shown.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, [double]::MaxValue)]
    [double]$GuessesPerSecond = 1e10
)

Set-StrictMode -Version Latest

#region Constants -----------------------------------------------------------

# Character pool sizes used for the entropy calculation.
$script:PoolLower   = 26
$script:PoolUpper   = 26
$script:PoolDigit   = 10
$script:PoolSymbol  = 33   # printable ASCII punctuation/symbols plus space
$script:PoolUnicode = 100  # rough allowance for any non-ASCII character

# Attack scenarios shown in the crack-time table.
$script:AttackScenarios = @(
    [pscustomobject]@{ Name = 'Online, throttled';         Rate = 1e2  }
    [pscustomobject]@{ Name = 'Offline, slow hash';        Rate = 1e4  }
    [pscustomobject]@{ Name = 'Offline, fast hash (GPU)';  Rate = 1e10 }
    [pscustomobject]@{ Name = 'Massive cluster';           Rate = 1e12 }
)

# Seconds in an average (Julian) year and the age of the universe in years.
$script:SecondsPerYear  = 31557600.0
$script:UniverseAgeYears = 1.38e10

#endregion

#region Analysis functions --------------------------------------------------

function Get-PasswordAnalysis {
    <#
    .SYNOPSIS
        Analyzes a password and returns its statistics.
    .DESCRIPTION
        Counts character classes, computes pool size and entropy, and rates
        the password as Weak, Medium or Strong. Returns a single object.
    .PARAMETER Password
        The plain-text password to analyze. May be empty.
    .EXAMPLE
        Get-PasswordAnalysis -Password 'correct horse battery staple'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Password
    )

    $upper = 0; $lower = 0; $digit = 0; $special = 0

    # Flags for the entropy pool (ASCII ranges vs. anything else).
    $hasAsciiLower = $false; $hasAsciiUpper = $false; $hasAsciiDigit = $false
    $hasAsciiSymbol = $false; $hasNonAscii = $false

    foreach ($c in $Password.ToCharArray()) {
        # Counts use Unicode categories, so accented letters count as letters.
        if     ([char]::IsUpper($c)) { $upper++ }
        elseif ([char]::IsLower($c)) { $lower++ }
        elseif ([char]::IsDigit($c)) { $digit++ }
        else                         { $special++ }

        $code = [int]$c
        if     ($code -ge 97 -and $code -le 122) { $hasAsciiLower  = $true }  # a-z
        elseif ($code -ge 65 -and $code -le 90)  { $hasAsciiUpper  = $true }  # A-Z
        elseif ($code -ge 48 -and $code -le 57)  { $hasAsciiDigit  = $true }  # 0-9
        elseif ($code -ge 32 -and $code -le 126) { $hasAsciiSymbol = $true }  # symbols, space
        else                                     { $hasNonAscii    = $true }
    }

    $pool = 0
    if ($hasAsciiLower)  { $pool += $script:PoolLower }
    if ($hasAsciiUpper)  { $pool += $script:PoolUpper }
    if ($hasAsciiDigit)  { $pool += $script:PoolDigit }
    if ($hasAsciiSymbol) { $pool += $script:PoolSymbol }
    if ($hasNonAscii)    { $pool += $script:PoolUnicode }

    $length  = $Password.Length
    $entropy = Get-EntropyBit -Length $length -PoolSize $pool

    $classes = @($upper, $lower, $digit, $special | Where-Object { $_ -gt 0 }).Count

    [pscustomobject]@{
        Length      = $length
        Uppercase   = $upper
        Lowercase   = $lower
        Digits      = $digit
        Special     = $special
        ClassCount  = $classes
        PoolSize    = $pool
        Entropy     = $entropy
        Strength    = Get-StrengthRating -Length $length -ClassCount $classes -Entropy $entropy
    }
}

function Get-EntropyBit {
    <#
    .SYNOPSIS
        Returns brute-force entropy in bits: Length * log2(PoolSize).
    .PARAMETER Length
        Number of characters in the password.
    .PARAMETER PoolSize
        Number of possible symbols for each character.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int]$PoolSize
    )

    if ($Length -le 0 -or $PoolSize -le 1) { return 0.0 }
    return $Length * [Math]::Log($PoolSize, 2)
}

function Get-StrengthRating {
    <#
    .SYNOPSIS
        Rates a password as None, Weak, Medium or Strong.
    .DESCRIPTION
        Strong : 12+ characters, 3+ character classes, 60+ bits of entropy
        Medium : 8+ characters,  2+ character classes, 40+ bits of entropy
        Weak   : anything else
        None   : empty password
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int]$ClassCount,
        [Parameter(Mandatory)] [double]$Entropy
    )

    if ($Length -eq 0) { return 'None' }
    if ($Length -ge 12 -and $ClassCount -ge 3 -and $Entropy -ge 60) { return 'Strong' }
    if ($Length -ge 8  -and $ClassCount -ge 2 -and $Entropy -ge 40) { return 'Medium' }
    return 'Weak'
}

function Get-CrackTimeSecond {
    <#
    .SYNOPSIS
        Average seconds needed to brute-force a password of the given entropy.
    .DESCRIPTION
        On average an attacker finds the password after searching half of the
        key space, i.e. 2^(Entropy - 1) guesses.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double]$Entropy,
        [Parameter(Mandatory)] [double]$GuessesPerSecond
    )

    if ($Entropy -le 0) { return 0.0 }
    # Very large entropy overflows to +Infinity, which Format-Duration handles.
    return [Math]::Pow(2, $Entropy - 1) / $GuessesPerSecond
}

function Format-Duration {
    <#
    .SYNOPSIS
        Converts a number of seconds into a short human-readable string.
    .EXAMPLE
        Format-Duration -Seconds 90000   # "1 day"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double]$Seconds
    )

    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return 'longer than the age of the universe'
    }
    if ($Seconds -lt 1) { return 'instantly' }

    if ($Seconds -lt $script:SecondsPerYear) {
        $units = @(
            @{ Name = 'day';    Size = 86400 }
            @{ Name = 'hour';   Size = 3600  }
            @{ Name = 'minute'; Size = 60    }
            @{ Name = 'second'; Size = 1     }
        )
        foreach ($unit in $units) {
            if ($Seconds -ge $unit.Size) {
                $value = [Math]::Floor($Seconds / $unit.Size)
                $plural = if ($value -eq 1) { '' } else { 's' }
                return '{0} {1}{2}' -f $value, $unit.Name, $plural
            }
        }
    }

    $years = $Seconds / $script:SecondsPerYear
    $magnitudes = @(
        @{ Name = 'quadrillion'; Size = 1e15 }
        @{ Name = 'trillion';    Size = 1e12 }
        @{ Name = 'billion';     Size = 1e9  }
        @{ Name = 'million';     Size = 1e6  }
        @{ Name = 'thousand';    Size = 1e3  }
    )

    if ($years -ge 1e18) {
        $text = '{0:0.0e+0} years' -f $years
    }
    else {
        $text = $null
        foreach ($m in $magnitudes) {
            if ($years -ge $m.Size) {
                $text = '{0:N0} {1} years' -f [Math]::Floor($years / $m.Size), $m.Name
                break
            }
        }
        if (-not $text) {
            $value = [Math]::Floor($years)
            $plural = if ($value -eq 1) { '' } else { 's' }
            $text = '{0:N0} year{1}' -f $value, $plural
        }
    }

    if ($years -gt $script:UniverseAgeYears) { $text += ' (> age of universe)' }
    return $text
}

function Format-Rate {
    <#
    .SYNOPSIS
        Formats a guesses-per-second rate, e.g. 1e10 -> "10 billion/s".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double]$Rate)

    $magnitudes = @(
        @{ Name = 'trillion'; Size = 1e12 }
        @{ Name = 'billion';  Size = 1e9  }
        @{ Name = 'million';  Size = 1e6  }
        @{ Name = 'thousand'; Size = 1e3  }
    )
    foreach ($m in $magnitudes) {
        if ($Rate -ge $m.Size) { return '{0:0.##} {1}/s' -f ($Rate / $m.Size), $m.Name }
    }
    return '{0:0.##}/s' -f $Rate
}

function Get-PasswordSuggestion {
    <#
    .SYNOPSIS
        Returns a list of suggestions for improving the analyzed password.
    .PARAMETER Analysis
        Object returned by Get-PasswordAnalysis.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [pscustomobject]$Analysis)

    $tips = New-Object System.Collections.Generic.List[string]
    if ($Analysis.Length -eq 0) {
        $tips.Add('Start typing a password to analyze it.')
        return $tips.ToArray()
    }
    if ($Analysis.Length -lt 12)   { $tips.Add('Use at least 12 characters (16+ is even better).') }
    if ($Analysis.Uppercase -eq 0) { $tips.Add('Add uppercase letters.') }
    if ($Analysis.Lowercase -eq 0) { $tips.Add('Add lowercase letters.') }
    if ($Analysis.Digits -eq 0)    { $tips.Add('Add digits.') }
    if ($Analysis.Special -eq 0)   { $tips.Add('Add special characters (e.g. ! @ # $ %).') }
    if ($tips.Count -eq 0) {
        $tips.Add('Looks good! Avoid dictionary words and never reuse passwords.')
    }
    return $tips.ToArray()
}

#endregion

#region Rendering functions -------------------------------------------------

function New-UiSegment {
    <#
    .SYNOPSIS
        Creates a piece of colored text for Write-UiLine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string]$Text,
        [Parameter(Position = 1)] [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Write-UiLine {
    <#
    .SYNOPSIS
        Writes colored segments on a given screen row, padding the remainder
        of the row with spaces so stale text from a previous frame is erased.
    .DESCRIPTION
        Text is truncated to the window width to avoid line wrapping, which
        would otherwise corrupt the fixed layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Row,
        [Parameter()] [object[]]$Segment = @()
    )

    if ($Row -ge [Console]::BufferHeight) { return }

    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    [Console]::SetCursorPosition(0, $Row)

    $written = 0
    foreach ($seg in $Segment) {
        $remaining = $width - $written
        if ($remaining -le 0) { break }
        $text = $seg.Text
        if ($text.Length -gt $remaining) { $text = $text.Substring(0, $remaining) }
        Write-Host -Object $text -ForegroundColor $seg.Color -NoNewline
        $written += $text.Length
    }
    if ($written -lt $width) {
        Write-Host -Object (' ' * ($width - $written)) -NoNewline
    }
}

function Get-StrengthColor {
    <#
    .SYNOPSIS
        Maps a strength rating to a console color.
    #>
    [CmdletBinding()]
    [OutputType([ConsoleColor])]
    param([Parameter(Mandatory)] [string]$Strength)

    switch ($Strength) {
        'Strong' { [ConsoleColor]::Green }
        'Medium' { [ConsoleColor]::Yellow }
        'Weak'   { [ConsoleColor]::Red }
        default  { [ConsoleColor]::DarkGray }
    }
}

function Get-CrackTimeColor {
    <#
    .SYNOPSIS
        Colors a crack time: red under a day, yellow under a century, green beyond.
    #>
    [CmdletBinding()]
    [OutputType([ConsoleColor])]
    param([Parameter(Mandatory)] [double]$Seconds)

    if ($Seconds -lt 86400)                         { return [ConsoleColor]::Red }
    if ($Seconds -lt 100 * $script:SecondsPerYear)  { return [ConsoleColor]::Yellow }
    return [ConsoleColor]::Green
}

function Show-AnalyzerScreen {
    <#
    .SYNOPSIS
        Draws the entire analyzer UI for the current password state.
    .PARAMETER Password
        The current plain-text password.
    .PARAMETER Reveal
        When set, the password is shown in plain text instead of masked.
    .PARAMETER GuessesPerSecond
        Guess rate used for the headline crack-time estimate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Password,
        [Parameter(Mandatory)] [bool]$Reveal,
        [Parameter(Mandatory)] [double]$GuessesPerSecond
    )

    $a = Get-PasswordAnalysis -Password $Password
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $label = 22   # width of the label column
    $row = 0

    [Console]::CursorVisible = $false

    # --- Header ---------------------------------------------------------
    $rule = '=' * [Math]::Min($width, 72)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  PASSWORD ANALYZER' Cyan)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)
    Write-UiLine -Row ($row++)

    # --- Password field -------------------------------------------------
    $display = if ($Reveal) { $Password } else { '*' * $Password.Length }
    $prefix = '  Password: '
    $fieldWidth = $width - $prefix.Length - 12   # leave room for "[visible]"
    if ($fieldWidth -lt 5) { $fieldWidth = 5 }
    if ($display.Length -gt $fieldWidth) {
        # Show the tail of a long password so the user sees what they type.
        $display = '...' + $display.Substring($display.Length - ($fieldWidth - 3))
    }
    $modeText  = if ($Reveal) { ' [visible]' } else { ' [hidden]' }
    $modeColor = if ($Reveal) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
    $passwordRow = $row
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment $prefix White)
        (New-UiSegment $display White)
        (New-UiSegment $modeText $modeColor)
    )
    $cursorColumn = $prefix.Length + $display.Length
    Write-UiLine -Row ($row++)

    # --- Statistics -----------------------------------------------------
    $countColor = {
        param([int]$n)
        if ($n -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
    }

    $lengthColor = if ($a.Length -ge 12) { [ConsoleColor]::Green }
                   elseif ($a.Length -ge 8) { [ConsoleColor]::Yellow }
                   elseif ($a.Length -gt 0) { [ConsoleColor]::Red }
                   else { [ConsoleColor]::DarkGray }

    $stats = @(
        ,@('Length',            $a.Length,    $lengthColor)
        ,@('Uppercase letters', $a.Uppercase, (& $countColor $a.Uppercase))
        ,@('Lowercase letters', $a.Lowercase, (& $countColor $a.Lowercase))
        ,@('Digits',            $a.Digits,    (& $countColor $a.Digits))
        ,@('Special characters',$a.Special,   (& $countColor $a.Special))
        ,@('Character pool',    $a.PoolSize,  [ConsoleColor]::Cyan)
    )
    foreach ($s in $stats) {
        Write-UiLine -Row ($row++) -Segment @(
            (New-UiSegment ('  ' + $s[0]).PadRight($label) Gray)
            (New-UiSegment ': ' DarkGray)
            (New-UiSegment ([string]$s[1]) $s[2])
        )
    }

    # Entropy with a simple bar (100 bits = full bar).
    $strengthColor = Get-StrengthColor -Strength $a.Strength
    $barSize = 20
    $filled = [int][Math]::Min($barSize, [Math]::Round($a.Entropy / 100 * $barSize))
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Entropy'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment ('{0:N1} bits ' -f $a.Entropy) Cyan)
        (New-UiSegment '[' DarkGray)
        (New-UiSegment ('#' * $filled) $strengthColor)
        (New-UiSegment ('-' * ($barSize - $filled)) DarkGray)
        (New-UiSegment ']' DarkGray)
    )

    $strengthText = if ($a.Strength -eq 'None') { '-' } else { $a.Strength.ToUpper() }
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Strength'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment $strengthText $strengthColor)
    )

    $headline = Get-CrackTimeSecond -Entropy $a.Entropy -GuessesPerSecond $GuessesPerSecond
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Time to crack'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment (Format-Duration -Seconds $headline) (Get-CrackTimeColor -Seconds $headline))
        (New-UiSegment ('  @ ' + (Format-Rate -Rate $GuessesPerSecond)) DarkGray)
    )
    Write-UiLine -Row ($row++)

    # --- Attack scenarios -----------------------------------------------
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  Estimated brute-force time by attack scenario' White)
    foreach ($scenario in $script:AttackScenarios) {
        $secs = Get-CrackTimeSecond -Entropy $a.Entropy -GuessesPerSecond $scenario.Rate
        Write-UiLine -Row ($row++) -Segment @(
            (New-UiSegment ('    ' + $scenario.Name).PadRight(30) Gray)
            (New-UiSegment (Format-Rate -Rate $scenario.Rate).PadLeft(16) DarkGray)
            (New-UiSegment '  ' Gray)
            (New-UiSegment (Format-Duration -Seconds $secs) (Get-CrackTimeColor -Seconds $secs))
        )
    }
    Write-UiLine -Row ($row++)

    # --- Suggestions (fixed number of rows so the layout never shifts) ---
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  Suggestions' White)
    $tips = @(Get-PasswordSuggestion -Analysis $a)
    $maxTips = 5
    for ($i = 0; $i -lt $maxTips; $i++) {
        if ($i -lt $tips.Count) {
            Write-UiLine -Row ($row++) -Segment @(
                (New-UiSegment '    - ' DarkGray)
                (New-UiSegment $tips[$i] Yellow)
            )
        }
        else {
            Write-UiLine -Row ($row++)
        }
    }

    # --- Footer ---------------------------------------------------------
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  [Tab]' Cyan);        (New-UiSegment ' show/hide   ' Gray)
        (New-UiSegment '[Esc]' Cyan);          (New-UiSegment ' clear   ' Gray)
        (New-UiSegment '[Backspace]' Cyan);    (New-UiSegment ' delete   ' Gray)
        (New-UiSegment '[Ctrl+Q]' Cyan);       (New-UiSegment ' quit' Gray)
    )

    # Park the cursor at the end of the password field.
    $cursorColumn = [Math]::Min($cursorColumn, [Console]::WindowWidth - 1)
    if ($passwordRow -lt [Console]::BufferHeight) {
        [Console]::SetCursorPosition($cursorColumn, $passwordRow)
    }
    [Console]::CursorVisible = $true
}

#endregion

#region Main loop -----------------------------------------------------------

function Start-PasswordAnalyzer {
    <#
    .SYNOPSIS
        Runs the interactive password analyzer until the user quits.
    .PARAMETER GuessesPerSecond
        Guess rate used for the headline crack-time estimate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [double]$GuessesPerSecond)

    # The TUI needs a real console (not ISE, not redirected input).
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) {
        throw 'PasswordAnalyzer must be run in an interactive console window (e.g. Windows Terminal, powershell.exe or pwsh.exe).'
    }

    $password = New-Object System.Text.StringBuilder
    $reveal = $false
    $originalCtrlC = [Console]::TreatControlCAsInput
    $lastWidth = [Console]::WindowWidth
    $lastHeight = [Console]::WindowHeight

    try {
        # Read Ctrl+C as a key so we can exit cleanly and wipe the screen.
        [Console]::TreatControlCAsInput = $true
        Clear-Host
        Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond

        $running = $true
        while ($running) {
            # Poll so we can also react to window resizes between keystrokes.
            if (-not [Console]::KeyAvailable) {
                if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                    $lastWidth = [Console]::WindowWidth
                    $lastHeight = [Console]::WindowHeight
                    Clear-Host
                    Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond
                }
                Start-Sleep -Milliseconds 50
                continue
            }

            # Drain every pending key before redrawing (keeps pasting fast).
            while ($running -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0

                if ($ctrl -and ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::C)) {
                    $running = $false
                }
                elseif ($key.Key -eq [ConsoleKey]::Escape -or ($ctrl -and $key.Key -eq [ConsoleKey]::U)) {
                    [void]$password.Clear()
                }
                elseif ($key.Key -eq [ConsoleKey]::Tab) {
                    $reveal = -not $reveal
                }
                elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($password.Length -gt 0) { [void]$password.Remove($password.Length - 1, 1) }
                }
                elseif (-not [char]::IsControl($key.KeyChar) -and $key.KeyChar -ne [char]0) {
                    [void]$password.Append($key.KeyChar)
                }
                # Any other key (arrows, function keys, ...) is ignored.
            }

            if ($running) {
                if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                    $lastWidth = [Console]::WindowWidth
                    $lastHeight = [Console]::WindowHeight
                    Clear-Host
                }
                Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond
            }
        }
    }
    finally {
        # Wipe the password from memory and the screen, restore console state.
        [void]$password.Clear()
        [Console]::TreatControlCAsInput = $originalCtrlC
        [Console]::CursorVisible = $true
        Clear-Host
    }
}

#endregion

# Start the TUI unless the script is being dot-sourced (which only loads the
# functions, e.g. for testing or scripting).
if ($MyInvocation.InvocationName -ne '.') {
    Start-PasswordAnalyzer -GuessesPerSecond $GuessesPerSecond
}
