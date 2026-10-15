#Requires -Version 5.1
<#
.SYNOPSIS
    Translates text into the NATO phonetic alphabet using an interactive text UI.

.DESCRIPTION
    TextToNato.ps1 is a small terminal user interface (TUI). As you type, it
    shows the NATO phonetic alphabet equivalent of your text live, below the
    input line.

    - Letters are matched without regard to case. Each character is shown
      as typed, so you can still see which letters are capitals.
    - Digits use their spoken names (Zero, One, Two, ...).
    - Common punctuation gets a descriptive name (Period, Comma, Dash, ...).
    - A space starts a new output line, so each word gets its own row.
    - Code words alternate between two colors so they are easy to tell apart.

    Keys in the interactive UI:
        Esc / Ctrl+L        Clear the input and start over
        Backspace           Delete the last character
        Ctrl+Backspace      Delete the last word
        Ctrl+Q / Ctrl+C     Quit

    When you quit, the last translation is printed to the console so it stays
    in your scrollback.

    If you pass -Text (or pipe strings in), the script translates them once
    and exits without starting the interactive UI.

    The script needs only Windows PowerShell 5.1 (included with Windows 11)
    or PowerShell 7+. It has no external dependencies.

.PARAMETER Text
    One or more strings to translate without starting the interactive UI.
    Also accepts pipeline input.

.PARAMETER AsObject
    With -Text, emit one object per character (Character, CodeWord, Category)
    instead of writing colored output to the console. Useful for scripting.

.EXAMPLE
    .\TextToNato.ps1

    Starts the interactive TUI.

.EXAMPLE
    .\TextToNato.ps1 -Text 'Hello, World!'

    Prints the colored translation of "Hello, World!" and exits.

.EXAMPLE
    'abc', 'xyz' | .\TextToNato.ps1 -AsObject | Format-Table

    Emits one object per character and formats them as a table.

.NOTES
    File name : TextToNato.ps1
    Requires  : Windows PowerShell 5.1 or PowerShell 7+
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'This is an interactive console UI; host output is intentional.')]
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Text', Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string[]] $Text,

    [Parameter(ParameterSetName = 'Text')]
    [switch] $AsObject
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    #region Lookup tables ---------------------------------------------------

    # Official ICAO/NATO spellings. "Alfa" and "Juliett" are spelled this way
    # on purpose, so that speakers of other languages pronounce them correctly.
    # PowerShell hashtables are case-insensitive for string keys, so 'a' and
    # 'A' both find 'Alfa'.
    $script:Letters = @{
        A = 'Alfa';   B = 'Bravo';   C = 'Charlie'; D = 'Delta';   E = 'Echo'
        F = 'Foxtrot'; G = 'Golf';   H = 'Hotel';   I = 'India';   J = 'Juliett'
        K = 'Kilo';   L = 'Lima';    M = 'Mike';    N = 'November'; O = 'Oscar'
        P = 'Papa';   Q = 'Quebec';  R = 'Romeo';   S = 'Sierra';  T = 'Tango'
        U = 'Uniform'; V = 'Victor'; W = 'Whiskey'; X = 'X-ray';   Y = 'Yankee'
        Z = 'Zulu'
    }

    $script:Digits = @{
        '0' = 'Zero'; '1' = 'One'; '2' = 'Two';   '3' = 'Three'; '4' = 'Four'
        '5' = 'Five'; '6' = 'Six'; '7' = 'Seven'; '8' = 'Eight'; '9' = 'Nine'
    }

    $script:Punctuation = @{
        '.' = 'Period';      ',' = 'Comma';        '!' = 'Exclamation'
        '?' = 'Question';    "'" = 'Apostrophe';   '"' = 'Quote'
        '-' = 'Dash';        '_' = 'Underscore';   ':' = 'Colon'
        ';' = 'Semicolon';   '/' = 'Slash';        '\' = 'Backslash'
        '(' = 'Open-Paren';  ')' = 'Close-Paren';  '[' = 'Open-Bracket'
        ']' = 'Close-Bracket'; '{' = 'Open-Brace'; '}' = 'Close-Brace'
        '<' = 'Less-Than';   '>' = 'Greater-Than'; '@' = 'At'
        '#' = 'Hash';        '$' = 'Dollar';       '%' = 'Percent'
        '^' = 'Caret';       '&' = 'Ampersand';    '*' = 'Asterisk'
        '+' = 'Plus';        '=' = 'Equals';       '~' = 'Tilde'
        '`' = 'Backtick';    '|' = 'Pipe'
    }

    #endregion

    #region Theme -----------------------------------------------------------

    # Code words alternate between these colors so neighboring words are easy
    # to tell apart.
    $script:AlternatingColors = @([ConsoleColor]::Cyan, [ConsoleColor]::Yellow)

    $script:Theme = @{
        TitleFore   = [ConsoleColor]::Black
        TitleBack   = [ConsoleColor]::DarkCyan
        Prompt      = [ConsoleColor]::Green
        InputText   = [ConsoleColor]::White
        Caret       = [ConsoleColor]::Green
        Rule        = [ConsoleColor]::DarkGray
        SourceChar  = [ConsoleColor]::DarkGray
        Punctuation = [ConsoleColor]::Magenta
        Other       = [ConsoleColor]::DarkYellow
        Hint        = [ConsoleColor]::DarkGray
        Key         = [ConsoleColor]::White
    }

    # Box-drawing characters are created from code points so this file stays
    # pure ASCII. That avoids encoding problems in Windows PowerShell 5.1,
    # which reads BOM-less files as ANSI.
    $script:HorizontalRule = [char]0x2500   # light horizontal line
    $script:UpArrow        = [char]0x25B2   # black up-pointing triangle

    #endregion

    #region Translation -----------------------------------------------------

    function ConvertTo-NatoToken {
        <#
        .SYNOPSIS
            Converts a string into a list of NATO token objects, one per character.
        .OUTPUTS
            PSCustomObject with Character, CodeWord and Category properties.
            Category is one of: Letter, Digit, Punctuation, Space, Other.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $InputText
        )

        foreach ($char in $InputText.ToCharArray()) {
            $key = [string]$char

            if ($script:Letters.ContainsKey($key)) {
                $category = 'Letter'; $word = $script:Letters[$key]
            }
            elseif ($script:Digits.ContainsKey($key)) {
                $category = 'Digit'; $word = $script:Digits[$key]
            }
            elseif ([char]::IsWhiteSpace($char)) {
                $category = 'Space'; $word = 'Space'
            }
            elseif ($script:Punctuation.ContainsKey($key)) {
                $category = 'Punctuation'; $word = $script:Punctuation[$key]
            }
            else {
                # Anything not in the tables (accented letters, emoji, and so
                # on) is shown as itself, so the user can see it was not
                # translated.
                $category = 'Other'; $word = $key
            }

            [pscustomobject]@{
                Character = $char
                CodeWord  = $word
                Category  = $category
            }
        }
    }

    #endregion

    #region Layout ----------------------------------------------------------
    # The UI is built from "lines". Each line is a list of segments. A segment
    # is a piece of text with a foreground color and an optional background
    # color. Building lines separately from drawing them keeps the layout
    # logic simple and lets interactive mode and -Text mode share it.

    function New-Segment {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
            [Parameter(Mandatory = $true)] [ConsoleColor] $Fore,
            [Nullable[ConsoleColor]] $Back = $null
        )
        [pscustomobject]@{ Text = $Text; Fore = $Fore; Back = $Back }
    }

    function Get-NatoLine {
        <#
        .SYNOPSIS
            Lays out NATO tokens as lines of colored segments that fit in $Width.
        .DESCRIPTION
            Each word of the input starts a new line. Each character is shown
            as "<char> <CodeWord>", with the code words in alternating colors.
            A word too long for one line wraps onto indented continuation lines.
        #>
        [CmdletBinding()]
        [OutputType([System.Collections.Generic.List[object]])]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Token,
            [Parameter(Mandatory = $true)] [int] $Width
        )

        $lines      = New-Object 'System.Collections.Generic.List[object]'
        $indent     = '  '
        $wrapIndent = '      '
        $gap        = '   '
        # Keep one column free so the console never wraps a line on its own.
        $maxLen     = [Math]::Max(20, $Width - 1)

        $current    = $null
        $currentLen = 0
        $colorIndex = 0

        foreach ($t in $Token) {
            if ($t.Category -eq 'Space') {
                # End the current word. Consecutive spaces are collapsed.
                if ($null -ne $current) { $lines.Add($current); $current = $null }
                continue
            }

            $tokenLen = 2 + $t.CodeWord.Length   # "<char> <word>"

            if ($null -eq $current) {
                # Start a new word. The color alternation restarts with each
                # word, so a word always looks the same.
                $current    = New-Object 'System.Collections.Generic.List[object]'
                $current.Add((New-Segment -Text $indent -Fore $script:Theme.Rule))
                $currentLen = $indent.Length
                $colorIndex = 0
            }
            elseif ($currentLen + $gap.Length + $tokenLen -gt $maxLen) {
                # Word does not fit; continue it on an indented line.
                $lines.Add($current)
                $current    = New-Object 'System.Collections.Generic.List[object]'
                $current.Add((New-Segment -Text $wrapIndent -Fore $script:Theme.Rule))
                $currentLen = $wrapIndent.Length
            }
            else {
                $current.Add((New-Segment -Text $gap -Fore $script:Theme.Rule))
                $currentLen += $gap.Length
            }

            switch ($t.Category) {
                'Punctuation' { $wordColor = $script:Theme.Punctuation }
                'Other'       { $wordColor = $script:Theme.Other }
                default {
                    $wordColor  = $script:AlternatingColors[$colorIndex % $script:AlternatingColors.Count]
                    $colorIndex++
                }
            }

            $current.Add((New-Segment -Text ([string]$t.Character + ' ') -Fore $script:Theme.SourceChar))
            $current.Add((New-Segment -Text $t.CodeWord -Fore $wordColor))
            $currentLen += $tokenLen
        }

        if ($null -ne $current) { $lines.Add($current) }

        # The comma keeps PowerShell from unrolling the list into its items.
        , $lines
    }

    function Write-SegmentLine {
        <#
        .SYNOPSIS
            Writes one line of segments to the host, clipped to $Width columns.
        .PARAMETER PadBack
            If set, fills the rest of the line with spaces in this background
            color. Used for the title bar.
        .PARAMETER Pad
            Fill the rest of the line with spaces, so text left over from the
            previous frame is overwritten.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Segment,
            [Parameter(Mandatory = $true)] [int] $Width,
            [switch] $Pad,
            [Nullable[ConsoleColor]] $PadBack = $null
        )

        $remaining = $Width
        foreach ($s in $Segment) {
            if ($remaining -le 0) { break }
            $out = $s.Text
            if ($out.Length -gt $remaining) { $out = $out.Substring(0, $remaining) }
            if ($out.Length -eq 0) { continue }

            if ($null -ne $s.Back) {
                Write-Host $out -ForegroundColor $s.Fore -BackgroundColor $s.Back -NoNewline
            }
            else {
                Write-Host $out -ForegroundColor $s.Fore -NoNewline
            }
            $remaining -= $out.Length
        }

        if ($Pad -and $remaining -gt 0) {
            if ($null -ne $PadBack) {
                Write-Host (' ' * $remaining) -BackgroundColor $PadBack -NoNewline
            }
            else {
                Write-Host (' ' * $remaining) -NoNewline
            }
        }
    }

    #endregion

    #region Interactive UI --------------------------------------------------

    function Show-NatoFrame {
        <#
        .SYNOPSIS
            Draws the whole UI for the current input text.
        .DESCRIPTION
            Instead of clearing the screen, every row of the window is
            overwritten in place. This avoids flicker while typing.

            Layout (rows):
              0         title bar
              1         input line
              2         horizontal rule
              3 .. H-3  translation output
              H-2       horizontal rule
              H-1       key help
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $InputText,
            [Parameter(Mandatory = $true)] [int] $Top
        )

        $width  = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        # Never write into the last column. Some hosts wrap or scroll if you do.
        $usable = $width - 1

        if ($width -lt 30 -or $height -lt 8) {
            [Console]::SetCursorPosition(0, $Top)
            Write-SegmentLine -Width $usable -Pad -Segment @(
                New-Segment -Text 'Window too small - please enlarge.' -Fore Red)
            for ($r = 1; $r -lt $height; $r++) {
                [Console]::SetCursorPosition(0, $Top + $r)
                Write-SegmentLine -Width $usable -Pad -Segment @()
            }
            return
        }

        $rule = New-Segment -Text ([string]$script:HorizontalRule * $usable) -Fore $script:Theme.Rule
        $rows = New-Object 'System.Collections.Generic.List[object]'

        # --- Title bar ---------------------------------------------------
        $title   = 'TextToNato - NATO Phonetic Alphabet Translator'
        $leftPad = [Math]::Max(0, [int](($usable - $title.Length) / 2))
        $rows.Add(@(New-Segment -Text ((' ' * $leftPad) + $title) `
                    -Fore $script:Theme.TitleFore -Back $script:Theme.TitleBack))

        # --- Input line --------------------------------------------------
        # If the text is too long to fit, show its end with a "..." marker,
        # so the most recently typed characters are always visible.
        $prompt    = ' Text > '
        $available = $usable - $prompt.Length - 1   # 1 column for the caret
        $shown     = $InputText
        if ($shown.Length -gt $available) {
            $shown = '...' + $shown.Substring($shown.Length - ($available - 3))
        }
        $rows.Add(@(
                (New-Segment -Text $prompt -Fore $script:Theme.Prompt),
                (New-Segment -Text $shown  -Fore $script:Theme.InputText),
                (New-Segment -Text '_'     -Fore $script:Theme.Caret)
            ))

        $rows.Add(@($rule))

        # --- Translation output ------------------------------------------
        $outputHeight = $height - 5   # title, input, 2 rules, help
        $tokens       = @(ConvertTo-NatoToken -InputText $InputText)
        $outLines     = Get-NatoLine -Token $tokens -Width $width

        if ($outLines.Count -eq 0) {
            $outLines.Add(@(New-Segment -Text '  Start typing to see the NATO phonetic alphabet...' `
                        -Fore $script:Theme.Hint))
        }
        elseif ($outLines.Count -gt $outputHeight) {
            # Too much to show: keep the newest lines (where the user is typing)
            # and say how many lines are hidden above.
            $hidden   = $outLines.Count - ($outputHeight - 1)
            $kept     = $outLines.GetRange($hidden, $outputHeight - 1)
            $outLines = New-Object 'System.Collections.Generic.List[object]'
            $outLines.Add(@(New-Segment -Text ("  {0} {1} more line(s) above" -f $script:UpArrow, $hidden) `
                        -Fore $script:Theme.Hint))
            $outLines.AddRange($kept)
        }

        for ($i = 0; $i -lt $outputHeight; $i++) {
            if ($i -lt $outLines.Count) { $rows.Add(@($outLines[$i])) } else { $rows.Add(@()) }
        }

        $rows.Add(@($rule))

        # --- Key help ----------------------------------------------------
        $help = New-Object 'System.Collections.Generic.List[object]'
        $help.Add((New-Segment -Text ' ' -Fore $script:Theme.Hint))
        $keys = @(
            @('Esc', 'clear'), @('Backspace', 'delete'),
            @('Ctrl+Backspace', 'delete word'), @('Ctrl+Q', 'quit')
        )
        foreach ($k in $keys) {
            $help.Add((New-Segment -Text $k[0] -Fore $script:Theme.Key))
            $help.Add((New-Segment -Text (' ' + $k[1] + '   ') -Fore $script:Theme.Hint))
        }
        $rows.Add($help.ToArray())

        # --- Draw ----------------------------------------------------------
        for ($r = 0; $r -lt $rows.Count -and $r -lt $height; $r++) {
            [Console]::SetCursorPosition(0, $Top + $r)
            if ($r -eq 0) {
                Write-SegmentLine -Segment $rows[$r] -Width $usable -Pad -PadBack $script:Theme.TitleBack
            }
            else {
                Write-SegmentLine -Segment $rows[$r] -Width $usable -Pad
            }
        }
    }

    function Start-NatoTui {
        <#
        .SYNOPSIS
            Runs the interactive key loop until the user quits.
        .OUTPUTS
            The final input text, so the caller can print it after the UI closes.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param()

        if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) {
            throw ('The interactive UI needs a real console window. ' +
                'Run it in Windows Terminal or a PowerShell console, or use -Text instead.')
        }

        $buffer      = New-Object System.Text.StringBuilder
        $maxLength   = 2000
        $savedCtrlC  = [Console]::TreatControlCAsInput
        $savedCursor = $true
        try { $savedCursor = [Console]::CursorVisible } catch { Write-Verbose 'CursorVisible is not readable here.' }

        try {
            # Handle Ctrl+C ourselves so we can restore the console on exit.
            [Console]::TreatControlCAsInput = $true
            [Console]::CursorVisible = $false
            Clear-Host

            $top        = [Console]::WindowTop
            $lastWidth  = [Console]::WindowWidth
            $lastHeight = [Console]::WindowHeight
            $dirty      = $true
            $running    = $true

            while ($running) {
                # Redraw from scratch if the window was resized.
                if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                    $lastWidth  = [Console]::WindowWidth
                    $lastHeight = [Console]::WindowHeight
                    Clear-Host
                    $top   = [Console]::WindowTop
                    $dirty = $true
                }

                if ($dirty) {
                    Show-NatoFrame -InputText $buffer.ToString() -Top $top
                    $dirty = $false
                }

                # Poll instead of blocking on ReadKey, so window resizes are
                # still noticed while the user is not typing.
                if (-not [Console]::KeyAvailable) {
                    Start-Sleep -Milliseconds 40
                    continue
                }

                # Handle every key that is waiting before redrawing once. This
                # keeps pasting a long string fast.
                do {
                    $key  = [Console]::ReadKey($true)
                    $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0

                    if ($ctrl -and ($key.Key -eq [ConsoleKey]::C -or $key.Key -eq [ConsoleKey]::Q)) {
                        $running = $false
                    }
                    elseif ($key.Key -eq [ConsoleKey]::Escape -or
                        ($ctrl -and $key.Key -eq [ConsoleKey]::L)) {
                        [void]$buffer.Clear()
                    }
                    elseif (($key.Key -eq [ConsoleKey]::Backspace -and $ctrl) -or
                        $key.KeyChar -eq [char]0x7F) {
                        # Ctrl+Backspace: remove trailing spaces, then the last
                        # word. Some terminals send DEL (0x7F) for this.
                        $s = $buffer.ToString().TrimEnd()
                        $cut = $s.LastIndexOf(' ') + 1
                        [void]$buffer.Clear().Append($s.Substring(0, $cut))
                    }
                    elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                        if ($buffer.Length -gt 0) { [void]$buffer.Remove($buffer.Length - 1, 1) }
                    }
                    elseif ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                        # Any printable character. Enter, Tab and other control
                        # keys are ignored.
                        if ($buffer.Length -lt $maxLength) { [void]$buffer.Append($key.KeyChar) }
                    }
                } while ($running -and [Console]::KeyAvailable)

                $dirty = $true
            }
        }
        finally {
            # Always put the console back the way we found it, even on errors.
            [Console]::TreatControlCAsInput = $savedCtrlC
            try { [Console]::CursorVisible = $savedCursor } catch { Write-Verbose 'Could not restore cursor.' }
            [Console]::ResetColor()
            Clear-Host
        }

        $buffer.ToString()
    }

    #endregion

    #region Non-interactive output -----------------------------------------

    function Write-NatoTranslation {
        <#
        .SYNOPSIS
            Writes a colored translation of $InputText to the console.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $InputText
        )

        $width = 80
        try { if ([Console]::WindowWidth -gt 0) { $width = [Console]::WindowWidth } }
        catch { Write-Verbose 'No console window; using a width of 80.' }

        Write-Host ''
        Write-Host ' Text > ' -ForegroundColor $script:Theme.Prompt -NoNewline
        Write-Host $InputText -ForegroundColor $script:Theme.InputText
        Write-Host ''

        $tokens = @(ConvertTo-NatoToken -InputText $InputText)
        foreach ($line in (Get-NatoLine -Token $tokens -Width $width)) {
            Write-SegmentLine -Segment $line -Width ($width - 1)
            Write-Host ''
        }
        Write-Host ''
    }

    #endregion
}

process {
    if ($PSCmdlet.ParameterSetName -ne 'Text') { return }

    foreach ($item in $Text) {
        if ($AsObject) {
            ConvertTo-NatoToken -InputText $item
        }
        else {
            Write-NatoTranslation -InputText $item
        }
    }
}

end {
    if ($PSCmdlet.ParameterSetName -ne 'Interactive') { return }

    $finalText = Start-NatoTui

    # Leave the last translation on screen so it is not lost when the UI closes.
    if (-not [string]::IsNullOrWhiteSpace($finalText)) {
        Write-NatoTranslation -InputText $finalText
    }
}
