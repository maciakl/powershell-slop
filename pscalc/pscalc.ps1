<#
.SYNOPSIS
    pscalc - a keyboard-driven terminal (TUI) calculator for PowerShell.

.DESCRIPTION
    pscalc is a minimal, non-skeuomorphic calculator that runs inside a console
    window. Type free-form expressions such as "2 * (3 + 4)" or "sqrt(2) ^ 2",
    press Enter, and the expression and its result are added to a history log
    that is saved to disk and survives restarts.

    Features:
      * Standard operators with correct precedence: + - * / % ^ and ! (factorial)
      * Functions: sqrt, cbrt, root, abs, round, floor, ceil, trunc, exp, ln,
        log, log2, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, fact,
        min, max, and the base-formatting functions bin, oct, dec, hex
      * Constants: pi, e, tau, phi, plus "ans" for the previous result
      * Degree and radian modes for trigonometry
      * Binary, octal, decimal and hexadecimal input (0b, 0o, 0x prefixes)
        and output ("255 to hex", or a default output base)
      * Persistent, navigable history (Up/Down), clipboard copy/paste
      * Built-in help screen (F1 or "help")

    The script has no external dependencies and runs on both Windows PowerShell
    5.1 (the version that ships with Windows 11) and PowerShell 7+.

    When -Expression is supplied (or expressions are piped in) pscalc evaluates
    them without starting the interactive interface and writes each result to
    the pipeline. In that mode the history file is read (so "ans" works) but
    never written.

.PARAMETER Expression
    One or more expressions to evaluate non-interactively. Each result is
    written to the pipeline as a string. Within a single invocation "ans"
    refers to the result of the previous expression.

.PARAMETER DataPath
    Folder that holds the history and settings files. Defaults to
    "$env:APPDATA\pscalc" (the roaming application-data folder in the user
    profile, which is the same place PSReadLine keeps its history).

.PARAMETER Ascii
    Draw the interface using plain ASCII characters only. Use this if your
    console font does not display the line-drawing characters correctly.

.EXAMPLE
    .\pscalc.ps1

    Starts the interactive calculator.

.EXAMPLE
    .\pscalc.ps1 -Expression '2^10', 'ans / 4', '255 to hex'

    Evaluates three expressions without starting the interface and outputs
    1024, 256 and 0xFF.

.EXAMPLE
    'sqrt(2)', 'sin(30)' | .\pscalc.ps1

    Evaluates expressions supplied on the pipeline.

.LINK
    README.md in the project folder.

.NOTES
    Author      : Luke Maciak
    Requires    : Windows PowerShell 5.1 or PowerShell 7+, on Windows
    History file: <DataPath>\history.jsonl (one JSON object per line)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string[]] $Expression,

    [ValidateNotNullOrEmpty()]
    [string] $DataPath = (Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath 'pscalc'),

    [switch] $Ascii
)

begin {
    Set-StrictMode -Version Latest

    #region Constants and lookup tables ---------------------------------------

    $script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # Maximum number of entries kept in the history file.
    $script:MaxHistory = 1000

    # Largest integer a [double] can represent exactly (2^53).
    $script:MaxExactInteger = 9007199254740992.0

    # Guard against runaway recursion on absurdly nested input.
    $script:MaxNestingDepth = 200

    $script:BaseNames = @{ 2 = 'BIN'; 8 = 'OCT'; 10 = 'DEC'; 16 = 'HEX' }
    $script:BasePrefixes = @{ 2 = '0b'; 8 = '0o'; 10 = ''; 16 = '0x' }
    $script:BaseCycle = @(10, 16, 2, 8)

    # Row (in buffer coordinates) where the interface starts drawing, and the
    # window size the last frame was drawn for. Set by the TUI at runtime.
    $script:ScreenTop = 0
    $script:RenderedSize = ''

    # Named constants usable in expressions. Keys must be lowercase.
    $script:Constants = [ordered]@{
        'pi'  = @{ Value = [Math]::PI; Description = 'Ratio of a circle''s circumference to its diameter (3.14159...). Also typed as the Greek letter pi.' }
        'e'   = @{ Value = [Math]::E; Description = 'Euler''s number, the base of natural logarithms (2.71828...)' }
        'tau' = @{ Value = 2 * [Math]::PI; Description = 'Full turn in radians, 2*pi (6.28318...)' }
        'phi' = @{ Value = (1 + [Math]::Sqrt(5)) / 2; Description = 'Golden ratio (1.61803...)' }
    }

    #endregion

    #region Math helpers ------------------------------------------------------

    function ConvertTo-CalcRadian {
        # Converts an angle in the current angle mode to radians.
        param([double] $Angle, [hashtable] $Context)
        if ($Context.AngleMode -eq 'Deg') { return $Angle * [Math]::PI / 180 }
        return $Angle
    }

    function ConvertFrom-CalcRadian {
        # Converts an angle in radians to the current angle mode.
        param([double] $Angle, [hashtable] $Context)
        if ($Context.AngleMode -eq 'Deg') { return $Angle * 180 / [Math]::PI }
        return $Angle
    }

    function Get-CalcSnappedTrig {
        # Floating point leaves tiny residues such as sin(pi) = 1.2e-16.
        # Report those as an exact zero when the input angle is not itself tiny.
        param([double] $Result, [double] $Radians)
        if ([Math]::Abs($Result) -lt 1e-15 -and [Math]::Abs($Radians) -gt 1e-7) { return 0.0 }
        return $Result
    }

    function Get-CalcQuadrant {
        # In degree mode, returns 0..3 when the angle is an exact multiple of
        # 90 degrees (so sin/cos/tan can return exact values), otherwise -1.
        param([double] $Angle, [hashtable] $Context)
        if ($Context.AngleMode -ne 'Deg') { return -1 }
        $reduced = $Angle % 360
        if ($reduced % 90 -ne 0) { return -1 }
        $quadrant = [int]($reduced / 90)
        if ($quadrant -lt 0) { $quadrant += 4 }
        return $quadrant
    }

    function Get-CalcSin {
        param([double] $Angle, [hashtable] $Context)
        $quadrant = Get-CalcQuadrant -Angle $Angle -Context $Context
        if ($quadrant -ge 0) { return @(0.0, 1.0, 0.0, -1.0)[$quadrant] }
        $radians = ConvertTo-CalcRadian -Angle $Angle -Context $Context
        return Get-CalcSnappedTrig -Result ([Math]::Sin($radians)) -Radians $radians
    }

    function Get-CalcCos {
        param([double] $Angle, [hashtable] $Context)
        $quadrant = Get-CalcQuadrant -Angle $Angle -Context $Context
        if ($quadrant -ge 0) { return @(1.0, 0.0, -1.0, 0.0)[$quadrant] }
        $radians = ConvertTo-CalcRadian -Angle $Angle -Context $Context
        return Get-CalcSnappedTrig -Result ([Math]::Cos($radians)) -Radians $radians
    }

    function Get-CalcTan {
        param([double] $Angle, [hashtable] $Context)
        $quadrant = Get-CalcQuadrant -Angle $Angle -Context $Context
        if ($quadrant -eq 0 -or $quadrant -eq 2) { return 0.0 }
        if ($quadrant -eq 1 -or $quadrant -eq 3) {
            throw ('tan() is undefined at {0} degrees.' -f $Angle.ToString($script:Invariant))
        }
        $radians = ConvertTo-CalcRadian -Angle $Angle -Context $Context
        return Get-CalcSnappedTrig -Result ([Math]::Tan($radians)) -Radians $radians
    }

    function Get-CalcLog {
        # Logarithm of $Value in base $Base, snapped to an exact integer when
        # the base raised to that integer reproduces the input exactly.
        param([double] $Value, [double] $Base, [string] $Name)
        if ($Value -le 0) { throw "$Name() is only defined for numbers greater than zero." }
        if ($Base -le 0 -or $Base -eq 1) { throw "$Name() base must be greater than zero and not equal to 1." }
        $result = [Math]::Log($Value) / [Math]::Log($Base)
        $rounded = [Math]::Round($result)
        if ([Math]::Pow($Base, $rounded) -eq $Value) { return $rounded }
        return $result
    }

    function Get-CalcRoot {
        # Real n-th root. Negative radicands are allowed for odd integer n.
        param([double] $Value, [double] $Degree)
        if ($Degree -eq 0) { throw 'root() degree cannot be zero.' }
        $negative = $Value -lt 0
        if ($negative) {
            $isOddInteger = ([Math]::Floor($Degree) -eq $Degree) -and ([Math]::Abs($Degree % 2) -eq 1)
            if (-not $isOddInteger) { throw 'Even roots of negative numbers are not real numbers.' }
        }
        $magnitude = [Math]::Abs($Value)
        $result = [Math]::Pow($magnitude, 1.0 / $Degree)
        # Prefer an exact integer when one exists (e.g. cbrt(27) = 3, not 3.0000000000000004).
        $rounded = [Math]::Round($result)
        if ([Math]::Pow($rounded, $Degree) -eq $magnitude) { $result = $rounded }
        if ($negative) { return -$result }
        return $result
    }

    function Get-CalcFactorial {
        param([double] $Value)
        if ($Value -lt 0 -or [Math]::Floor($Value) -ne $Value) {
            throw 'Factorial is only defined for non-negative whole numbers.'
        }
        if ($Value -gt 170) { throw 'Factorial is too large (the maximum is 170!).' }
        $result = 1.0
        for ($i = 2; $i -le $Value; $i++) { $result *= $i }
        return $result
    }

    function Test-CalcInteger {
        param([double] $Value)
        return ([Math]::Floor($Value) -eq $Value)
    }

    #endregion

    #region Function table ----------------------------------------------------

    # Every function callable from an expression. Each body receives an array
    # of [double] arguments ($a) and the evaluation context ($c).
    # Min/Max give the allowed argument count (-1 means unlimited).
    $script:Functions = [ordered]@{
        'sqrt'  = @{ Min = 1; Max = 1; Usage = 'sqrt(x)'; Description = 'Square root'
            Body = { param($a, $c) if ($a[0] -lt 0) { throw 'sqrt() of a negative number is not a real number.' }; [Math]::Sqrt($a[0]) } }
        'cbrt'  = @{ Min = 1; Max = 1; Usage = 'cbrt(x)'; Description = 'Cube root'
            Body = { param($a, $c) Get-CalcRoot -Value $a[0] -Degree 3 } }
        'root'  = @{ Min = 2; Max = 2; Usage = 'root(x, n)'; Description = 'n-th root of x'
            Body = { param($a, $c) Get-CalcRoot -Value $a[0] -Degree $a[1] } }
        'abs'   = @{ Min = 1; Max = 1; Usage = 'abs(x)'; Description = 'Absolute value'
            Body = { param($a, $c) [Math]::Abs($a[0]) } }
        'round' = @{ Min = 1; Max = 2; Usage = 'round(x [, d])'; Description = 'Round to d decimal places (default 0, halves away from zero)'
            Body = {
                param($a, $c)
                $digits = 0
                if ($a.Count -gt 1) {
                    if (-not (Test-CalcInteger $a[1]) -or $a[1] -lt 0 -or $a[1] -gt 15) { throw 'round() decimal places must be a whole number from 0 to 15.' }
                    $digits = [int]$a[1]
                }
                [Math]::Round([double]$a[0], $digits, [MidpointRounding]::AwayFromZero)
            } }
        'floor' = @{ Min = 1; Max = 1; Usage = 'floor(x)'; Description = 'Round down to the nearest whole number'
            Body = { param($a, $c) [Math]::Floor([double]$a[0]) } }
        'ceil'  = @{ Min = 1; Max = 1; Usage = 'ceil(x)'; Description = 'Round up to the nearest whole number'
            Body = { param($a, $c) [Math]::Ceiling([double]$a[0]) } }
        'trunc' = @{ Min = 1; Max = 1; Usage = 'trunc(x)'; Description = 'Drop the fractional part'
            Body = { param($a, $c) [Math]::Truncate([double]$a[0]) } }
        'exp'   = @{ Min = 1; Max = 1; Usage = 'exp(x)'; Description = 'e raised to the power x'
            Body = { param($a, $c) [Math]::Exp($a[0]) } }
        'ln'    = @{ Min = 1; Max = 1; Usage = 'ln(x)'; Description = 'Natural logarithm (base e)'
            Body = { param($a, $c) Get-CalcLog -Value $a[0] -Base ([Math]::E) -Name 'ln' } }
        'log'   = @{ Min = 1; Max = 2; Usage = 'log(x [, b])'; Description = 'Logarithm in base b (default base 10)'
            Body = {
                param($a, $c)
                $base = 10.0
                if ($a.Count -gt 1) { $base = $a[1] }
                Get-CalcLog -Value $a[0] -Base $base -Name 'log'
            } }
        'log2'  = @{ Min = 1; Max = 1; Usage = 'log2(x)'; Description = 'Base 2 logarithm'
            Body = { param($a, $c) Get-CalcLog -Value $a[0] -Base 2 -Name 'log2' } }
        'sin'   = @{ Min = 1; Max = 1; Usage = 'sin(x)'; Description = 'Sine (uses the current DEG/RAD mode)'
            Body = { param($a, $c) Get-CalcSin -Angle $a[0] -Context $c } }
        'cos'   = @{ Min = 1; Max = 1; Usage = 'cos(x)'; Description = 'Cosine (uses the current DEG/RAD mode)'
            Body = { param($a, $c) Get-CalcCos -Angle $a[0] -Context $c } }
        'tan'   = @{ Min = 1; Max = 1; Usage = 'tan(x)'; Description = 'Tangent (uses the current DEG/RAD mode)'
            Body = { param($a, $c) Get-CalcTan -Angle $a[0] -Context $c } }
        'asin'  = @{ Min = 1; Max = 1; Usage = 'asin(x)'; Description = 'Inverse sine, -1 <= x <= 1 (result in DEG/RAD)'
            Body = {
                param($a, $c)
                if ([Math]::Abs($a[0]) -gt 1) { throw 'asin() is only defined for -1 <= x <= 1.' }
                ConvertFrom-CalcRadian -Angle ([Math]::Asin($a[0])) -Context $c
            } }
        'acos'  = @{ Min = 1; Max = 1; Usage = 'acos(x)'; Description = 'Inverse cosine, -1 <= x <= 1 (result in DEG/RAD)'
            Body = {
                param($a, $c)
                if ([Math]::Abs($a[0]) -gt 1) { throw 'acos() is only defined for -1 <= x <= 1.' }
                ConvertFrom-CalcRadian -Angle ([Math]::Acos($a[0])) -Context $c
            } }
        'atan'  = @{ Min = 1; Max = 1; Usage = 'atan(x)'; Description = 'Inverse tangent (result in DEG/RAD)'
            Body = { param($a, $c) ConvertFrom-CalcRadian -Angle ([Math]::Atan($a[0])) -Context $c } }
        'sinh'  = @{ Min = 1; Max = 1; Usage = 'sinh(x)'; Description = 'Hyperbolic sine'
            Body = { param($a, $c) [Math]::Sinh($a[0]) } }
        'cosh'  = @{ Min = 1; Max = 1; Usage = 'cosh(x)'; Description = 'Hyperbolic cosine'
            Body = { param($a, $c) [Math]::Cosh($a[0]) } }
        'tanh'  = @{ Min = 1; Max = 1; Usage = 'tanh(x)'; Description = 'Hyperbolic tangent'
            Body = { param($a, $c) [Math]::Tanh($a[0]) } }
        'fact'  = @{ Min = 1; Max = 1; Usage = 'fact(n)'; Description = 'Factorial, same as n!'
            Body = { param($a, $c) Get-CalcFactorial -Value $a[0] } }
        'min'   = @{ Min = 1; Max = -1; Usage = 'min(a, b, ...)'; Description = 'Smallest of the arguments'
            Body = { param($a, $c) $m = $a[0]; foreach ($v in $a) { if ($v -lt $m) { $m = $v } }; $m } }
        'max'   = @{ Min = 1; Max = -1; Usage = 'max(a, b, ...)'; Description = 'Largest of the arguments'
            Body = { param($a, $c) $m = $a[0]; foreach ($v in $a) { if ($v -gt $m) { $m = $v } }; $m } }
        'bin'   = @{ Min = 1; Max = 1; Usage = 'bin(x)'; Description = 'Show the result in binary (base 2)'
            Body = { param($a, $c) $c.RequestedBase = 2; $a[0] } }
        'oct'   = @{ Min = 1; Max = 1; Usage = 'oct(x)'; Description = 'Show the result in octal (base 8)'
            Body = { param($a, $c) $c.RequestedBase = 8; $a[0] } }
        'dec'   = @{ Min = 1; Max = 1; Usage = 'dec(x)'; Description = 'Show the result in decimal (base 10)'
            Body = { param($a, $c) $c.RequestedBase = 10; $a[0] } }
        'hex'   = @{ Min = 1; Max = 1; Usage = 'hex(x)'; Description = 'Show the result in hexadecimal (base 16)'
            Body = { param($a, $c) $c.RequestedBase = 16; $a[0] } }
    }

    #endregion

    #region Tokenizer ---------------------------------------------------------

    function Test-CalcDigit {
        param([char] $Char)
        return ($Char -ge [char]'0' -and $Char -le [char]'9')
    }

    function ConvertTo-CalcToken {
        <#
        .SYNOPSIS
            Splits an expression into number, identifier and operator tokens.
        .OUTPUTS
            An array of hashtables with Type ('num', 'id', 'op', 'end'),
            Value and Pos (zero-based character index) keys.
        #>
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

        $tokens = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
        $length = $Text.Length
        $i = 0

        while ($i -lt $length) {
            $ch = $Text[$i]
            $start = $i

            if ([char]::IsWhiteSpace($ch)) { $i++; continue }

            $nextIsDigit = ($i + 1 -lt $length) -and (Test-CalcDigit $Text[$i + 1])
            if ((Test-CalcDigit $ch) -or ($ch -eq [char]'.' -and $nextIsDigit)) {
                # Prefixed integer literal: 0b (binary), 0o (octal), 0x (hex).
                $radix = 0
                if ($ch -eq [char]'0' -and $i + 1 -lt $length) {
                    switch ([char]::ToLowerInvariant($Text[$i + 1])) {
                        'b' { $radix = 2 }
                        'o' { $radix = 8 }
                        'x' { $radix = 16 }
                    }
                }

                if ($radix -gt 0) {
                    $baseName = @{ 2 = 'binary'; 8 = 'octal'; 16 = 'hexadecimal' }[$radix]
                    $i += 2
                    $value = 0.0
                    $digitCount = 0
                    while ($i -lt $length) {
                        $c = [char]::ToLowerInvariant($Text[$i])
                        if ($c -eq [char]'_') { $i++; continue }  # allow 0b1111_0000
                        $digit = '0123456789abcdef'.IndexOf($c)
                        if ($digit -lt 0 -or $digit -ge $radix) { break }
                        $value = $value * $radix + $digit
                        $digitCount++
                        $i++
                    }
                    if ($i -lt $length -and [char]::IsLetterOrDigit($Text[$i])) {
                        throw ("Invalid digit '{0}' in {1} number at position {2}." -f $Text[$i], $baseName, ($i + 1))
                    }
                    if ($digitCount -eq 0) {
                        throw ("Missing digits after '{0}' at position {1}." -f $Text.Substring($start, 2), ($start + 1))
                    }
                    $tokens.Add(@{ Type = 'num'; Value = $value; Pos = $start })
                    continue
                }

                # Decimal literal: digits, optional fraction, optional exponent.
                while ($i -lt $length -and (Test-CalcDigit $Text[$i])) { $i++ }
                if ($i -lt $length -and $Text[$i] -eq [char]'.') {
                    $i++
                    while ($i -lt $length -and (Test-CalcDigit $Text[$i])) { $i++ }
                }
                if ($i -lt $length -and ($Text[$i] -eq [char]'e' -or $Text[$i] -eq [char]'E')) {
                    # Only treat 'e' as an exponent when digits follow (so "2e" means 2 * e).
                    $j = $i + 1
                    if ($j -lt $length -and ($Text[$j] -eq [char]'+' -or $Text[$j] -eq [char]'-')) { $j++ }
                    if ($j -lt $length -and (Test-CalcDigit $Text[$j])) {
                        $i = $j
                        while ($i -lt $length -and (Test-CalcDigit $Text[$i])) { $i++ }
                    }
                }
                if ($i -lt $length -and $Text[$i] -eq [char]'.') {
                    throw ("Unexpected '.' at position {0}." -f ($i + 1))
                }
                $literal = $Text.Substring($start, $i - $start)
                $value = [double]::Parse($literal, [System.Globalization.NumberStyles]::Float, $script:Invariant)
                $tokens.Add(@{ Type = 'num'; Value = $value; Pos = $start })
                continue
            }

            # The Greek letter pi is accepted as a synonym for the constant pi.
            if ($ch -eq [char]0x03C0) {
                $tokens.Add(@{ Type = 'id'; Value = 'pi'; Pos = $start })
                $i++
                continue
            }

            if ([char]::IsLetter($ch) -or $ch -eq [char]'_') {
                while ($i -lt $length -and ([char]::IsLetterOrDigit($Text[$i]) -or $Text[$i] -eq [char]'_') -and $Text[$i] -ne [char]0x03C0) { $i++ }
                $name = $Text.Substring($start, $i - $start).ToLowerInvariant()
                $tokens.Add(@{ Type = 'id'; Value = $name; Pos = $start })
                continue
            }

            # Operators. '**' is accepted as an alias for '^', and the
            # typographic multiply, divide and minus signs are normalised.
            $op = $null
            if ($ch -eq [char]'*' -and $i + 1 -lt $length -and $Text[$i + 1] -eq [char]'*') {
                $op = '^'
                $i++
            }
            elseif ('+-*/%^(),!'.IndexOf($ch) -ge 0) { $op = [string]$ch }
            elseif ($ch -eq [char]0x00D7) { $op = '*' }
            elseif ($ch -eq [char]0x00F7) { $op = '/' }
            elseif ($ch -eq [char]0x2212) { $op = '-' }

            if ($null -eq $op) {
                throw ("Unexpected character '{0}' at position {1}." -f $ch, ($i + 1))
            }
            $tokens.Add(@{ Type = 'op'; Value = $op; Pos = $start })
            $i++
        }

        $tokens.Add(@{ Type = 'end'; Value = ''; Pos = $length })
        return , $tokens.ToArray()
    }

    #endregion

    #region Parser / evaluator ------------------------------------------------
    #
    # A recursive-descent parser that evaluates as it parses. Grammar, from
    # lowest to highest precedence:
    #
    #   sum      := product (('+' | '-') product)*
    #   product  := unary (('*' | '/' | '%') unary | implicit-multiply)*
    #   unary    := ('-' | '+') unary | power
    #   power    := postfix ('^' unary)?          (right associative)
    #   postfix  := primary '!'*
    #   primary  := number | constant | 'ans' | function '(' args ')' | '(' sum ')'
    #
    # So -2^2 = -4, 2^3^2 = 2^9 and 2^-1 = 0.5, matching standard mathematical
    # convention. Implicit multiplication ("2pi", "3(4+1)") binds like '*'.

    function Get-CalcTokenText {
        # Human-readable description of a token for error messages.
        param([hashtable] $Token)
        if ($Token.Type -eq 'end') { return 'end of expression' }
        if ($Token.Type -eq 'num') { return "number '{0}'" -f $Token.Value.ToString($script:Invariant) }
        return "'{0}'" -f $Token.Value
    }

    function Test-CalcOperator {
        param([hashtable] $State, [string[]] $Operator)
        $token = $State.Tokens[$State.Pos]
        return ($token.Type -eq 'op' -and $Operator -contains $token.Value)
    }

    function Read-CalcSum {
        param([hashtable] $State)
        $value = Read-CalcProduct -State $State
        while (Test-CalcOperator -State $State -Operator '+', '-') {
            $op = $State.Tokens[$State.Pos].Value
            $State.Pos++
            $right = Read-CalcProduct -State $State
            if ($op -eq '+') { $value = $value + $right } else { $value = $value - $right }
        }
        return $value
    }

    function Read-CalcProduct {
        param([hashtable] $State)
        $value = Read-CalcUnary -State $State
        while ($true) {
            $token = $State.Tokens[$State.Pos]
            if (Test-CalcOperator -State $State -Operator '*', '/', '%') {
                $State.Pos++
                $right = Read-CalcUnary -State $State
                switch ($token.Value) {
                    '*' { $value = $value * $right }
                    '/' {
                        if ($right -eq 0) { throw 'Division by zero.' }
                        $value = $value / $right
                    }
                    '%' {
                        if ($right -eq 0) { throw 'Remainder (%) by zero is undefined.' }
                        $value = $value % $right
                    }
                }
            }
            elseif ($token.Type -eq 'id' -or ($token.Type -eq 'op' -and $token.Value -eq '(')) {
                # Implicit multiplication: 2pi, 3(4 + 1), (1 + 2)(3 + 4), 2 sqrt(9)
                $value = $value * (Read-CalcUnary -State $State)
            }
            else { break }
        }
        return $value
    }

    function Read-CalcUnary {
        param([hashtable] $State)
        if (Test-CalcOperator -State $State -Operator '-') {
            $State.Pos++
            return -(Read-CalcUnary -State $State)
        }
        if (Test-CalcOperator -State $State -Operator '+') {
            $State.Pos++
            return (Read-CalcUnary -State $State)
        }
        return (Read-CalcPower -State $State)
    }

    function Read-CalcPower {
        param([hashtable] $State)
        $base = Read-CalcPostfix -State $State
        if (Test-CalcOperator -State $State -Operator '^') {
            $State.Pos++
            $exponent = Read-CalcUnary -State $State
            if ($base -eq 0 -and $exponent -lt 0) { throw 'Division by zero (zero raised to a negative power).' }
            $result = [Math]::Pow($base, $exponent)
            if ([double]::IsNaN($result)) { throw 'A negative number raised to a fractional power is not a real number.' }
            return $result
        }
        return $base
    }

    function Read-CalcPostfix {
        param([hashtable] $State)
        $value = Read-CalcPrimary -State $State
        while (Test-CalcOperator -State $State -Operator '!') {
            $State.Pos++
            $value = Get-CalcFactorial -Value $value
        }
        return $value
    }

    function Read-CalcPrimary {
        param([hashtable] $State)

        $State.Depth++
        if ($State.Depth -gt $script:MaxNestingDepth) { throw 'Expression is nested too deeply.' }
        try {
            $token = $State.Tokens[$State.Pos]
            $position = $token.Pos + 1

            switch ($token.Type) {
                'num' {
                    $State.Pos++
                    return [double]$token.Value
                }
                'end' {
                    throw 'The expression is incomplete. Something is missing at the end.'
                }
                'op' {
                    if ($token.Value -eq '(') {
                        $State.Pos++
                        $value = Read-CalcSum -State $State
                        if (-not (Test-CalcOperator -State $State -Operator ')')) {
                            $next = $State.Tokens[$State.Pos]
                            throw ("Expected ')' to match '(' at position {0}, but found {1}." -f $position, (Get-CalcTokenText $next))
                        }
                        $State.Pos++
                        return $value
                    }
                    if ($token.Value -eq ')') { throw ("Unexpected ')' at position {0}." -f $position) }
                    throw ("Unexpected '{0}' at position {1}. A number or name was expected." -f $token.Value, $position)
                }
                'id' {
                    $name = [string]$token.Value
                    $State.Pos++
                    $isCall = Test-CalcOperator -State $State -Operator '('

                    if ($script:Functions.Contains($name)) {
                        if (-not $isCall) { throw ("Function '{0}' needs parentheses, for example {1}." -f $name, $script:Functions[$name].Usage) }
                        return (Invoke-CalcFunction -State $State -Name $name -Position $position)
                    }
                    if ($name -eq 'ans') {
                        if ($null -eq $State.Context.Ans) { throw "'ans' has no value yet. It refers to the result of your last calculation." }
                        return [double]$State.Context.Ans
                    }
                    if ($script:Constants.Contains($name)) {
                        return [double]$script:Constants[$name].Value
                    }
                    if ($isCall) { throw ("Unknown function '{0}' at position {1}. Type 'help' to see available functions." -f $name, $position) }
                    throw ("Unknown name '{0}' at position {1}. Type 'help' to see available constants and functions." -f $name, $position)
                }
            }
        }
        finally {
            $State.Depth--
        }
    }

    function Invoke-CalcFunction {
        # Parses a parenthesised argument list and calls the named function.
        param([hashtable] $State, [string] $Name, [int] $Position)

        $definition = $script:Functions[$Name]
        $State.Pos++   # consume '('
        $arguments = New-Object -TypeName 'System.Collections.Generic.List[double]'

        if (-not (Test-CalcOperator -State $State -Operator ')')) {
            while ($true) {
                $arguments.Add((Read-CalcSum -State $State))
                if (Test-CalcOperator -State $State -Operator ',') { $State.Pos++; continue }
                if (Test-CalcOperator -State $State -Operator ')') { break }
                $next = $State.Tokens[$State.Pos]
                throw ("Expected ',' or ')' in call to {0}() at position {1}, but found {2}." -f $Name, ($next.Pos + 1), (Get-CalcTokenText $next))
            }
        }
        $State.Pos++   # consume ')'

        $count = $arguments.Count
        if ($count -lt $definition.Min -or ($definition.Max -ge 0 -and $count -gt $definition.Max)) {
            throw ("{0}() was given {1} argument(s). Usage: {2}" -f $Name, $count, $definition.Usage)
        }

        $result = & $definition.Body $arguments.ToArray() $State.Context
        return [double]$result
    }

    function ConvertTo-CalcBase {
        <#
        .SYNOPSIS
            Converts a base name such as 'hex' or '16' to its radix, or $null.
        #>
        param([string] $Name)
        switch -Regex ($Name.Trim().ToLowerInvariant()) {
            '^(2|b|bin|binary)$' { return 2 }
            '^(8|o|oct|octal)$' { return 8 }
            '^(10|d|dec|decimal)$' { return 10 }
            '^(16|h|x|hex|hexadecimal)$' { return 16 }
        }
        return $null
    }

    function Format-CalcNumber {
        <#
        .SYNOPSIS
            Formats a number for display in the given base.
        .OUTPUTS
            Hashtable with Text and Notice (an explanation when the requested
            base could not be used, otherwise $null).
        #>
        param([double] $Value, [int] $Base = 10)

        if ($Value -eq 0) { $Value = 0.0 }   # normalise negative zero

        $decimalText = if ((Test-CalcInteger $Value) -and [Math]::Abs($Value) -le $script:MaxExactInteger) {
            ([long]$Value).ToString($script:Invariant)
        }
        else {
            # 15 significant digits hides binary rounding noise (0.1 + 0.2 = 0.3).
            $Value.ToString('G15', $script:Invariant)
        }

        if ($Base -eq 10) { return @{ Text = $decimalText; Notice = $null } }

        # Values within rounding noise of a whole number count as whole numbers
        # for base conversion (e.g. log(8, 2) to bin).
        $rounded = [Math]::Round($Value)
        if ([Math]::Abs($Value - $rounded) -gt 1e-9 * [Math]::Max(1, [Math]::Abs($Value))) {
            return @{ Text = $decimalText; Notice = ('{0} needs a whole number, so the result is shown in decimal.' -f $script:BaseNames[$Base]) }
        }
        if ([Math]::Abs($rounded) -gt $script:MaxExactInteger) {
            return @{ Text = $decimalText; Notice = ('The result is too large to convert exactly to {0}, so it is shown in decimal.' -f $script:BaseNames[$Base]) }
        }

        $magnitude = [long][Math]::Abs($rounded)
        $digits = [Convert]::ToString($magnitude, $Base).ToUpperInvariant()
        $sign = if ($rounded -lt 0) { '-' } else { '' }
        return @{ Text = $sign + $script:BasePrefixes[$Base] + $digits; Notice = $null }
    }

    function Invoke-CalcExpression {
        <#
        .SYNOPSIS
            Evaluates one expression and returns the formatted result.
        .DESCRIPTION
            Accepts an optional trailing "to <base>" / "in <base>" / "as <base>"
            clause that selects the output base for this result only.
            Throws a terminating error with a user-friendly message when the
            expression is invalid.
        .OUTPUTS
            PSCustomObject with Expression, Value, Result, Base and Notice.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Expression,
            [Parameter(Mandatory = $true)][hashtable] $Context
        )

        $text = $Expression.Trim()
        if ($text.Length -eq 0) { throw 'Type an expression to calculate, or "help" for a list of functions.' }

        $base = $null
        $basePattern = '^(?<expr>.+?)\s+(?:to|in|as)\s+(?<base>bin(?:ary)?|oct(?:al)?|dec(?:imal)?|hex(?:adecimal)?)\s*$'
        if ($text -match $basePattern) {
            $text = $Matches['expr']
            $base = ConvertTo-CalcBase -Name $Matches['base']
        }

        $Context.RequestedBase = $null
        $state = @{
            Tokens  = (ConvertTo-CalcToken -Text $text)
            Pos     = 0
            Depth   = 0
            Context = $Context
        }

        $value = Read-CalcSum -State $state

        $leftover = $state.Tokens[$state.Pos]
        if ($leftover.Type -ne 'end') {
            if ($leftover.Type -eq 'op' -and $leftover.Value -eq ')') {
                throw ("Unexpected ')' at position {0}. There is no matching '('." -f ($leftover.Pos + 1))
            }
            throw ("Unexpected {0} at position {1}." -f (Get-CalcTokenText $leftover), ($leftover.Pos + 1))
        }

        if ([double]::IsNaN($value)) { throw 'The result is not a real number.' }
        if ([double]::IsInfinity($value)) { throw 'The result is too large to represent (overflow).' }

        if ($null -eq $base) {
            $base = if ($null -ne $Context.RequestedBase) { $Context.RequestedBase } else { $Context.OutputBase }
        }
        $formatted = Format-CalcNumber -Value $value -Base $base

        [pscustomobject]@{
            Expression = $Expression.Trim()
            Value      = $value
            Result     = $formatted.Text
            Base       = $base
            Notice     = $formatted.Notice
        }
    }

    #endregion

    #region Persistence -------------------------------------------------------

    function Get-CalcFilePath {
        # Returns the full path of a data file (history or settings).
        param([string] $DataPath, [ValidateSet('History', 'Settings')][string] $Kind)
        $fileName = if ($Kind -eq 'History') { 'history.jsonl' } else { 'settings.json' }
        return (Join-Path -Path $DataPath -ChildPath $fileName)
    }

    function Initialize-CalcDataFolder {
        param([string] $DataPath)
        if (-not (Test-Path -LiteralPath $DataPath -PathType Container)) {
            $null = New-Item -Path $DataPath -ItemType Directory -Force -ErrorAction Stop
        }
    }

    function New-CalcHistoryEntry {
        # Builds a history record. Pure function; changes no state.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        param([string] $Expression, [string] $Result, [double] $Value, [string] $AngleMode, [string] $Time)
        [pscustomobject]@{
            Expression = $Expression
            Result     = $Result
            Value      = $Value
            AngleMode  = $AngleMode
            Time       = $Time
        }
    }

    function Read-CalcHistory {
        <#
        .SYNOPSIS
            Loads the history file (one JSON object per line). Corrupt lines
            are skipped rather than failing the whole load.
        #>
        param([string] $DataPath)

        $history = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $path = Get-CalcFilePath -DataPath $DataPath -Kind History
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , $history }

        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                $entry = New-CalcHistoryEntry -Expression ([string]$record.Expression) -Result ([string]$record.Result) `
                    -Value ([double]$record.Value) -AngleMode ([string]$record.AngleMode) -Time ([string]$record.Time)
                if ($entry.Expression) { $history.Add($entry) }
            }
            catch {
                Write-Verbose "Skipping unreadable history line: $line"
            }
        }

        if ($history.Count -gt $script:MaxHistory) {
            $history.RemoveRange(0, $history.Count - $script:MaxHistory)
        }
        return , $history
    }

    function Save-CalcHistory {
        # Rewrites the whole history file from the in-memory list.
        param([string] $DataPath, [System.Collections.Generic.List[object]] $History)
        Initialize-CalcDataFolder -DataPath $DataPath
        $lines = foreach ($entry in $History) { $entry | ConvertTo-Json -Compress }
        $text = if ($lines) { ($lines -join "`n") + "`n" } else { '' }
        [System.IO.File]::WriteAllText((Get-CalcFilePath -DataPath $DataPath -Kind History), $text, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Add-CalcHistoryEntry {
        # Appends an entry to the in-memory history and to the history file.
        param([string] $DataPath, [System.Collections.Generic.List[object]] $History, [object] $Entry)
        $History.Add($Entry)
        if ($History.Count -gt $script:MaxHistory) {
            $History.RemoveRange(0, $History.Count - $script:MaxHistory)
            Save-CalcHistory -DataPath $DataPath -History $History
            return
        }
        Initialize-CalcDataFolder -DataPath $DataPath
        $line = ($Entry | ConvertTo-Json -Compress) + "`n"
        [System.IO.File]::AppendAllText((Get-CalcFilePath -DataPath $DataPath -Kind History), $line, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Clear-CalcHistory {
        # Empties the in-memory history and deletes the history file.
        param([string] $DataPath, [System.Collections.Generic.List[object]] $History)
        $History.Clear()
        $path = Get-CalcFilePath -DataPath $DataPath -Kind History
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }

    function Read-CalcSetting {
        # Loads saved preferences (angle mode and default output base).
        param([string] $DataPath)
        $settings = @{ AngleMode = 'Deg'; OutputBase = 10 }
        $path = Get-CalcFilePath -DataPath $DataPath -Kind Settings
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $saved = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
                if ($saved.PSObject.Properties['AngleMode'] -and @('Deg', 'Rad') -contains $saved.AngleMode) {
                    $settings.AngleMode = (Get-Culture).TextInfo.ToTitleCase(([string]$saved.AngleMode).ToLowerInvariant())
                }
                if ($saved.PSObject.Properties['OutputBase'] -and $script:BaseCycle -contains [int]$saved.OutputBase) {
                    $settings.OutputBase = [int]$saved.OutputBase
                }
            }
            catch {
                Write-Verbose "Ignoring unreadable settings file: $path"
            }
        }
        return $settings
    }

    function Save-CalcSetting {
        param([string] $DataPath, [hashtable] $Context)
        Initialize-CalcDataFolder -DataPath $DataPath
        $json = [pscustomobject]@{ AngleMode = $Context.AngleMode; OutputBase = $Context.OutputBase } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Get-CalcFilePath -DataPath $DataPath -Kind Settings), $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    #endregion

    #region Console drawing ---------------------------------------------------

    function Get-CalcGlyphSet {
        # Characters used to draw the interface. Built from code points so the
        # script file itself stays pure ASCII (Windows PowerShell 5.1 reads
        # BOM-less scripts using the legacy ANSI code page).
        param([switch] $Ascii)
        # Only characters from the legacy OEM code page 437 are used, because
        # those render in every Windows console font.
        if ($Ascii) {
            return @{ Rule = '-'; Prompt = '>'; Select = '>'; Ellipsis = '...'; Updown = 'Up/Dn' }
        }
        return @{
            Rule     = [string][char]0x2500   # box drawings light horizontal
            Prompt   = '>'
            Select   = [string][char]0x25BA   # black right-pointing pointer
            Ellipsis = '...'
            Updown   = 'Up/Dn'
        }
    }

    function Get-CalcTruncatedText {
        param([string] $Text, [int] $Max, [string] $Ellipsis)
        if ($Max -le 0) { return '' }
        if ($Text.Length -le $Max) { return $Text }
        if ($Max -le $Ellipsis.Length) { return $Text.Substring(0, $Max) }
        return $Text.Substring(0, $Max - $Ellipsis.Length) + $Ellipsis
    }

    function Write-CalcRow {
        <#
        .SYNOPSIS
            Draws one full screen row from colored segments.
        .DESCRIPTION
            Each segment is a hashtable with Text and optional Fore/Back
            ConsoleColor names. The row is clipped and padded to the window
            width minus one column, so the cursor never wraps or scrolls.
        #>
        param([int] $Row, [object[]] $Segments)

        $width = [Console]::WindowWidth - 1
        [Console]::SetCursorPosition(0, $script:ScreenTop + $Row)
        $used = 0
        foreach ($segment in $Segments) {
            if ($used -ge $width) { break }
            # Indexer syntax: under strict mode a missing key accessed as a
            # property (e.g. $segment.Back) is an error.
            $text = [string]$segment['Text']
            if ($text.Length -eq 0) { continue }
            if ($text.Length -gt $width - $used) { $text = $text.Substring(0, $width - $used) }
            if ($segment['Fore']) { [Console]::ForegroundColor = $segment['Fore'] }
            if ($segment['Back']) { [Console]::BackgroundColor = $segment['Back'] }
            [Console]::Write($text)
            [Console]::ResetColor()
            $used += $text.Length
        }
        if ($used -lt $width) { [Console]::Write(' ' * ($width - $used)) }
    }

    function Read-CalcKey {
        <#
        .SYNOPSIS
            Waits for a key press. Returns $null if the window is resized
            while waiting, so the caller can redraw.
        #>
        while (-not [Console]::KeyAvailable) {
            $size = '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight
            if ($size -ne $script:RenderedSize) {
                [Console]::Clear()
                $script:ScreenTop = [Console]::WindowTop
                return $null
            }
            Start-Sleep -Milliseconds 40
        }
        return [Console]::ReadKey($true)
    }

    function Test-CalcCommand {
        # True when the input is a command (help, clear, deg, ...) rather
        # than an expression.
        param([string] $Text)
        return ($Text.Trim() -match '^(help|\?|exit|quit|clear|deg|degrees|rad|radians|base(\s+\S+)?)$')
    }

    function Show-CalcScreen {
        <#
        .SYNOPSIS
            Draws the main calculator screen.

            Layout (top to bottom):
              title bar          - name, angle mode, output base, entry count
              rule
              history            - oldest at the top, newest just above input
              rule
              input line
              status line        - live preview, errors and messages
              rule
              shortcut hints
        #>
        param([hashtable] $State)

        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        $script:RenderedSize = '{0}x{1}' -f $width, $height
        $glyph = $State.Glyph
        $inner = $width - 1
        [Console]::CursorVisible = $false

        if ($width -lt 40 -or $height -lt 10) {
            [Console]::Clear()
            Write-CalcRow -Row 0 -Segments @(@{ Text = 'Window too small for pscalc. Please enlarge it.'; Fore = 'Yellow' })
            return
        }

        $context = $State.Context
        $history = $State.History
        $rule = @{ Text = ($glyph.Rule * $inner); Fore = 'DarkGray' }

        # --- Title bar ---
        $left = ' pscalc'
        $right = '{0}  {1}  {2} saved ' -f $context.AngleMode.ToUpperInvariant(), $script:BaseNames[$context.OutputBase], $history.Count
        $pad = $inner - $left.Length - $right.Length
        if ($pad -lt 1) { $right = ''; $pad = 0 }
        Write-CalcRow -Row 0 -Segments @(
            @{ Text = $left; Fore = 'Cyan' },
            @{ Text = (' ' * $pad) },
            @{ Text = $right; Fore = 'Gray' }
        )
        Write-CalcRow -Row 1 -Segments @($rule)

        # --- History area ---
        $area = $height - 7
        $count = $history.Count
        $maxScroll = [Math]::Max(0, $count - $area)
        if ($State.HistIndex -lt 0) {
            $State.Scroll = $maxScroll
        }
        else {
            if ($State.HistIndex -lt $State.Scroll) { $State.Scroll = $State.HistIndex }
            if ($State.HistIndex -ge $State.Scroll + $area) { $State.Scroll = $State.HistIndex - $area + 1 }
        }
        $State.Scroll = [Math]::Min([Math]::Max(0, $State.Scroll), $maxScroll)

        $visible = [Math]::Min($area, $count - $State.Scroll)
        $blank = $area - $visible
        for ($i = 0; $i -lt $area; $i++) {
            $row = 2 + $i
            if ($i -lt $blank) {
                if ($count -eq 0 -and $i -eq [int][Math]::Floor($area / 2)) {
                    $hint = 'No calculations yet. Type an expression and press Enter. F1 for help.'
                    $hint = Get-CalcTruncatedText -Text $hint -Max ($inner - 4) -Ellipsis $glyph.Ellipsis
                    $indent = [Math]::Max(0, [int](($inner - $hint.Length) / 2))
                    Write-CalcRow -Row $row -Segments @(@{ Text = (' ' * $indent) + $hint; Fore = 'DarkGray' })
                }
                else {
                    Write-CalcRow -Row $row -Segments @()
                }
                continue
            }

            $index = $State.Scroll + $i - $blank
            $entry = $history[$index]
            $selected = ($index -eq $State.HistIndex)
            $back = if ($selected) { 'DarkGray' } else { $null }
            $marker = if ($selected) { ' ' + $glyph.Select + ' ' } else { '   ' }

            $result = Get-CalcTruncatedText -Text $entry.Result -Max ([Math]::Max(8, [int]($inner / 2))) -Ellipsis $glyph.Ellipsis
            $resultWidth = 2 + $result.Length + 1   # "= " + result + trailing space
            $expression = Get-CalcTruncatedText -Text $entry.Expression -Max ($inner - $marker.Length - $resultWidth - 2) -Ellipsis $glyph.Ellipsis
            $gap = [Math]::Max(1, $inner - $marker.Length - $expression.Length - $resultWidth)

            Write-CalcRow -Row $row -Segments @(
                @{ Text = $marker; Fore = 'Yellow'; Back = $back },
                @{ Text = $expression; Fore = $(if ($selected) { 'White' } else { 'Gray' }); Back = $back },
                @{ Text = (' ' * $gap); Back = $back },
                @{ Text = '= '; Fore = $(if ($selected) { 'Gray' } else { 'DarkGray' }); Back = $back },
                @{ Text = $result + ' '; Fore = 'Green'; Back = $back }
            )
        }

        Write-CalcRow -Row ($height - 5) -Segments @($rule)

        # --- Input line (scrolls horizontally to keep the cursor visible) ---
        $prompt = ' ' + $glyph.Prompt + ' '
        $room = $inner - $prompt.Length - 1
        $line = $State.Input
        $State.ViewOffset = [Math]::Max(0, [Math]::Min($State.ViewOffset, $line.Length))
        if ($State.Cursor -lt $State.ViewOffset) { $State.ViewOffset = $State.Cursor }
        if ($State.Cursor - $State.ViewOffset -gt $room) { $State.ViewOffset = $State.Cursor - $room }
        $shown = $line.Substring($State.ViewOffset, [Math]::Min($room + 1, $line.Length - $State.ViewOffset))

        $inputSegments = @(@{ Text = $prompt; Fore = 'Yellow' })
        if ($line.Length -eq 0) {
            $inputSegments += @{ Text = 'type an expression, or "help"'; Fore = 'DarkGray' }
        }
        else {
            $inputSegments += @{ Text = $shown; Fore = 'White' }
        }
        Write-CalcRow -Row ($height - 4) -Segments $inputSegments

        # --- Status line: message, or a live preview of the result ---
        $status = @()
        if ($State.Message) {
            $status = @(@{ Text = '   ' + $State.Message.Text; Fore = $State.Message.Color })
        }
        elseif ($line.Trim().Length -gt 0 -and -not (Test-CalcCommand -Text $line)) {
            try {
                $preview = Invoke-CalcExpression -Expression $line -Context $context
                $status = @(@{ Text = '   = ' + $preview.Result; Fore = 'DarkGray' })
            }
            catch {
                $status = @()   # incomplete input while typing is normal; stay quiet
            }
        }
        Write-CalcRow -Row ($height - 3) -Segments $status

        Write-CalcRow -Row ($height - 2) -Segments @($rule)

        # --- Shortcut hints ---
        # Most important first, since narrow windows clip the end of the row.
        $hints = @(
            @('Enter', 'calc'), @($glyph.Updown, 'history'), @('F1', 'help'), @('Esc', 'quit'), @('Ctrl+C', 'copy'),
            @('Ctrl+V', 'paste'), @('Ctrl+L', 'clear history'), @('F2', 'deg/rad'), @('F3', 'base')
        )
        $hintSegments = @(@{ Text = ' ' })
        foreach ($hint in $hints) {
            $hintSegments += @{ Text = $hint[0]; Fore = 'Gray' }
            $hintSegments += @{ Text = ' ' + $hint[1] + '  '; Fore = 'DarkGray' }
        }
        Write-CalcRow -Row ($height - 1) -Segments $hintSegments

        # --- Place the cursor in the input line ---
        [Console]::SetCursorPosition($prompt.Length + $State.Cursor - $State.ViewOffset, $script:ScreenTop + $height - 4)
        [Console]::CursorVisible = $true
    }

    function Get-CalcHelpLine {
        # Builds the help text as a list of @{ Text; Color } lines.
        param([hashtable] $State)

        $lines = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
        $heading = { param($t) $lines.Add(@{ Text = ''; Color = 'Gray' }); $lines.Add(@{ Text = ' ' + $t; Color = 'Cyan' }) }
        $text = { param($t) $lines.Add(@{ Text = '   ' + $t; Color = 'Gray' }) }

        $lines.Add(@{ Text = ' pscalc help'; Color = 'White' })
        & $text 'Type an expression and press Enter. The expression and result are saved to the history.'

        & $heading 'NUMBERS'
        & $text 'Whole and decimal numbers: 42   -7   3.14   .5   6.02e23   1.5e-3'
        & $text 'Binary 0b1010   Octal 0o17   Hexadecimal 0xFF   (underscores allowed: 0b1111_0000)'

        & $heading 'OPERATORS (highest precedence first)'
        & $text '( )      grouping'
        & $text 'n!       factorial'
        & $text 'x ^ y    exponentiation, right to left: 2^3^2 = 2^9 (x ** y also works)'
        & $text '-x       negation: -2^2 = -(2^2) = -4'
        & $text 'x * y    multiplication; implicit too: 2pi, 3(4+1), 2 sqrt(9)'
        & $text 'x / y    division'
        & $text 'x % y    remainder'
        & $text 'x + y    addition;  x - y  subtraction'

        & $heading 'FUNCTIONS'
        foreach ($name in $script:Functions.Keys) {
            $definition = $script:Functions[$name]
            & $text ('{0,-16} {1}' -f $definition.Usage, $definition.Description)
        }

        & $heading 'CONSTANTS'
        foreach ($name in $script:Constants.Keys) {
            & $text ('{0,-16} {1}' -f $name, $script:Constants[$name].Description)
        }
        & $text ('{0,-16} {1}' -f 'ans', 'The result of the last calculation in the history')

        & $heading 'NUMBER BASES'
        & $text 'Input:  write numbers with a prefix: 0b (binary), 0o (octal), 0x (hexadecimal).'
        & $text 'Output: add "to bin", "to oct", "to dec" or "to hex" to the end of an expression,'
        & $text '        wrap it in bin(), oct(), dec() or hex(), or change the default with F3.'
        & $text 'Only whole numbers can be shown in binary, octal or hexadecimal.'

        & $heading 'ANGLES'
        & $text 'sin, cos and tan take angles, and asin, acos and atan return angles, in the current'
        & $text 'mode: DEG (degrees) or RAD (radians). Press F2 or type "deg" / "rad" to switch.'

        & $heading 'COMMANDS'
        & $text ('{0,-16} {1}' -f 'help', 'Show this screen (also: ?)')
        & $text ('{0,-16} {1}' -f 'clear', 'Delete all history')
        & $text ('{0,-16} {1}' -f 'deg / rad', 'Switch to degree or radian mode')
        & $text ('{0,-16} {1}' -f 'base <name>', 'Set the default output base: bin, oct, dec or hex')
        & $text ('{0,-16} {1}' -f 'exit', 'Quit (also: quit)')

        & $heading 'KEYBOARD SHORTCUTS'
        $keys = @(
            @('Enter', 'Calculate the expression and add it to the history'),
            @('Up / Down', 'Move through the history; the selected expression can be edited and re-run'),
            @('PgUp / PgDn', 'Move through the history a page at a time'),
            @('Ctrl+C', 'Copy the result (selected entry, live preview, or last result)'),
            @('Ctrl+V', 'Paste text from the clipboard into the input'),
            @('Ctrl+L', 'Clear the history (asks for confirmation)'),
            @('Tab', 'Complete a function or constant name'),
            @('F1', 'Show this help'),
            @('F2', 'Toggle DEG / RAD angle mode'),
            @('F3', 'Cycle the default output base: DEC, HEX, BIN, OCT'),
            @('Left / Right', 'Move the cursor (Ctrl+Left / Ctrl+Right jump by word)'),
            @('Home / End', 'Jump to the start / end of the input'),
            @('Backspace / Del', 'Delete a character (Ctrl+Backspace or Ctrl+W deletes a word)'),
            @('Esc', 'Clear the input; when the input is empty, quit')
        )
        foreach ($key in $keys) { & $text ('{0,-16} {1}' -f $key[0], $key[1]) }

        & $heading 'EXAMPLES'
        $examples = @(
            @('2 + 3 * 4', '14'),
            @('(2 + 3) * 4', '20'),
            @('2^10', '1024'),
            @('sqrt(16) + 3!', '10'),
            @('2pi', '6.28318530717959'),
            @('sin(30)', '0.5 in DEG mode'),
            @('sin(pi / 6)', '0.5 in RAD mode'),
            @('log(1000)', '3'),
            @('log(8, 2)', '3'),
            @('ln(e^3)', '3'),
            @('root(27, 3)', '3'),
            @('10 % 3', '1'),
            @('ans * 2', 'twice the previous result'),
            @('0xFF + 0b1010', '265'),
            @('255 to hex', '0xFF'),
            @('0x1F to bin', '0b11111'),
            @('hex(48879)', '0xBEEF')
        )
        foreach ($example in $examples) { & $text ('{0,-16} = {1}' -f $example[0], $example[1]) }

        & $heading 'FILES'
        & $text ('History:  {0}' -f (Get-CalcFilePath -DataPath $State.DataPath -Kind History))
        & $text ('Settings: {0}' -f (Get-CalcFilePath -DataPath $State.DataPath -Kind Settings))

        return , $lines
    }

    function Show-CalcHelp {
        # Full-screen, scrollable help page. Returns when the user presses
        # Esc, F1, Q, Enter or Backspace.
        param([hashtable] $State)

        $lines = Get-CalcHelpLine -State $State
        $scroll = 0
        [Console]::Clear()

        while ($true) {
            $width = [Console]::WindowWidth
            $height = [Console]::WindowHeight
            $script:RenderedSize = '{0}x{1}' -f $width, $height
            [Console]::CursorVisible = $false
            $page = [Math]::Max(1, $height - 2)
            $scroll = [Math]::Min([Math]::Max(0, $scroll), [Math]::Max(0, $lines.Count - $page))

            for ($i = 0; $i -lt $page; $i++) {
                $index = $scroll + $i
                if ($index -lt $lines.Count) {
                    Write-CalcRow -Row $i -Segments @(@{ Text = $lines[$index].Text; Fore = $lines[$index].Color })
                }
                else {
                    Write-CalcRow -Row $i -Segments @()
                }
            }
            Write-CalcRow -Row ($height - 2) -Segments @(@{ Text = $State.Glyph.Rule * ($width - 1); Fore = 'DarkGray' })
            $last = [Math]::Min($lines.Count, $scroll + $page)
            Write-CalcRow -Row ($height - 1) -Segments @(
                @{ Text = ' ' + $State.Glyph.Updown + ' PgUp PgDn'; Fore = 'Gray' },
                @{ Text = ' scroll   '; Fore = 'DarkGray' },
                @{ Text = 'Esc'; Fore = 'Gray' },
                @{ Text = (' back   lines {0}-{1} of {2}' -f ($scroll + 1), $last, $lines.Count); Fore = 'DarkGray' }
            )

            $key = Read-CalcKey
            if ($null -eq $key) { continue }
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow) { $scroll-- }
                ([ConsoleKey]::DownArrow) { $scroll++ }
                ([ConsoleKey]::PageUp) { $scroll -= $page }
                ([ConsoleKey]::PageDown) { $scroll += $page }
                ([ConsoleKey]::Spacebar) { $scroll += $page }
                ([ConsoleKey]::Home) { $scroll = 0 }
                ([ConsoleKey]::End) { $scroll = $lines.Count }
                { $_ -in [ConsoleKey]::Escape, [ConsoleKey]::F1, [ConsoleKey]::Q, [ConsoleKey]::Enter, [ConsoleKey]::Backspace } {
                    [Console]::Clear()
                    return
                }
            }
        }
    }

    #endregion

    #region Interactive behaviour ---------------------------------------------

    function Set-CalcMessage {
        # Shows a one-off message on the status line until the next key press.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        param([hashtable] $State, [string] $Text, [string] $Color = 'Gray')
        $State.Message = @{ Text = $Text; Color = $Color }
    }

    function Set-CalcInputText {
        # Replaces the input line and puts the cursor at the end.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        param([hashtable] $State, [string] $Text)
        $State.Input = $Text
        $State.Cursor = $Text.Length
    }

    function Add-CalcInputText {
        # Inserts text at the cursor.
        param([hashtable] $State, [string] $Text)
        $State.Input = $State.Input.Insert($State.Cursor, $Text)
        $State.Cursor += $Text.Length
    }

    function Move-CalcHistorySelection {
        <#
        .SYNOPSIS
            Moves the history selection by $Delta entries (negative = older)
            and loads the selected expression into the input line. Moving past
            the newest entry returns to the text that was being typed.
        #>
        param([hashtable] $State, [int] $Delta)
        $count = $State.History.Count
        if ($count -eq 0) { return }

        if ($State.HistIndex -lt 0) {
            if ($Delta -ge 0) { return }
            $State.Draft = $State.Input
            $target = $count + $Delta
        }
        else {
            $target = $State.HistIndex + $Delta
        }

        if ($target -ge $count) {
            $State.HistIndex = -1
            Set-CalcInputText -State $State -Text $State.Draft
            return
        }
        $State.HistIndex = [Math]::Max(0, $target)
        Set-CalcInputText -State $State -Text $State.History[$State.HistIndex].Expression
    }

    function Get-CalcWordStart {
        # Index of the start of the word to the left of $Position.
        param([string] $Text, [int] $Position)
        $i = $Position
        while ($i -gt 0 -and [char]::IsWhiteSpace($Text[$i - 1])) { $i-- }
        if ($i -gt 0 -and ([char]::IsLetterOrDigit($Text[$i - 1]) -or '._'.IndexOf($Text[$i - 1]) -ge 0)) {
            while ($i -gt 0 -and ([char]::IsLetterOrDigit($Text[$i - 1]) -or '._'.IndexOf($Text[$i - 1]) -ge 0)) { $i-- }
        }
        elseif ($i -gt 0) { $i-- }
        return $i
    }

    function Get-CalcWordEnd {
        # Index just past the word to the right of $Position.
        param([string] $Text, [int] $Position)
        $i = $Position
        $length = $Text.Length
        while ($i -lt $length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -lt $length -and ([char]::IsLetterOrDigit($Text[$i]) -or '._'.IndexOf($Text[$i]) -ge 0)) {
            while ($i -lt $length -and ([char]::IsLetterOrDigit($Text[$i]) -or '._'.IndexOf($Text[$i]) -ge 0)) { $i++ }
        }
        elseif ($i -lt $length) { $i++ }
        return $i
    }

    function Complete-CalcName {
        # Tab completion for function and constant names.
        param([hashtable] $State)
        $start = $State.Cursor
        while ($start -gt 0 -and ([char]::IsLetterOrDigit($State.Input[$start - 1]) -or $State.Input[$start - 1] -eq [char]'_')) { $start-- }
        $prefix = $State.Input.Substring($start, $State.Cursor - $start).ToLowerInvariant()
        if ($prefix.Length -eq 0 -or (Test-CalcDigit $prefix[0])) { return }

        $names = @($script:Functions.Keys) + @($script:Constants.Keys) + @('ans')
        $candidates = @($names | Where-Object { $_.StartsWith($prefix) } | Sort-Object)
        if ($candidates.Count -eq 0) {
            Set-CalcMessage -State $State -Text "No function or constant starts with '$prefix'." -Color 'DarkGray'
            return
        }
        if ($candidates.Count -eq 1) {
            $completion = $candidates[0].Substring($prefix.Length)
            $nextChar = if ($State.Cursor -lt $State.Input.Length) { $State.Input[$State.Cursor] } else { [char]0 }
            if ($script:Functions.Contains($candidates[0]) -and $nextChar -ne [char]'(') { $completion += '(' }
            Add-CalcInputText -State $State -Text $completion
            return
        }

        # Several matches: extend to their longest common prefix and list them.
        $common = $candidates[0]
        foreach ($candidate in $candidates) {
            while (-not $candidate.StartsWith($common)) { $common = $common.Substring(0, $common.Length - 1) }
        }
        if ($common.Length -gt $prefix.Length) {
            Add-CalcInputText -State $State -Text $common.Substring($prefix.Length)
        }
        Set-CalcMessage -State $State -Text ($candidates -join '  ') -Color 'DarkGray'
    }

    function Copy-CalcResult {
        # Copies the most relevant result to the clipboard.
        param([hashtable] $State)
        $result = $null
        if ($State.HistIndex -ge 0) {
            $result = $State.History[$State.HistIndex].Result
        }
        elseif ($State.Input.Trim().Length -gt 0 -and -not (Test-CalcCommand -Text $State.Input)) {
            try { $result = (Invoke-CalcExpression -Expression $State.Input -Context $State.Context).Result } catch { $result = $null }
        }
        if ($null -eq $result -and $State.History.Count -gt 0) {
            $result = $State.History[$State.History.Count - 1].Result
        }
        if ($null -eq $result) {
            Set-CalcMessage -State $State -Text 'Nothing to copy yet.' -Color 'DarkGray'
            return
        }
        try {
            Set-Clipboard -Value $result -ErrorAction Stop
            Set-CalcMessage -State $State -Text "Copied $result to the clipboard." -Color 'Green'
        }
        catch {
            Set-CalcMessage -State $State -Text ('Could not copy to the clipboard: {0}' -f $_.Exception.Message) -Color 'Red'
        }
    }

    function Add-CalcClipboardText {
        # Pastes the first non-empty line of the clipboard at the cursor.
        param([hashtable] $State)
        try {
            $clip = Get-Clipboard -Raw -ErrorAction Stop
        }
        catch {
            Set-CalcMessage -State $State -Text ('Could not read the clipboard: {0}' -f $_.Exception.Message) -Color 'Red'
            return
        }
        if ([string]::IsNullOrWhiteSpace($clip)) {
            Set-CalcMessage -State $State -Text 'The clipboard is empty.' -Color 'DarkGray'
            return
        }
        $firstLine = @($clip -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })[0]
        $clean = -join ($firstLine.ToCharArray() | Where-Object { -not [char]::IsControl($_) })
        Add-CalcInputText -State $State -Text $clean.Trim()
    }

    function Invoke-CalcClearHistory {
        # Clears history after the user confirms with Y.
        param([hashtable] $State, [switch] $Confirm)
        if ($State.History.Count -eq 0) {
            Set-CalcMessage -State $State -Text 'The history is already empty.' -Color 'DarkGray'
            return
        }
        if ($Confirm) {
            Set-CalcMessage -State $State -Text ('Delete all {0} history entries? Press Y to confirm, any other key to cancel.' -f $State.History.Count) -Color 'Yellow'
            Show-CalcScreen -State $State
            $answer = $null
            while ($null -eq $answer) { $answer = Read-CalcKey; if ($null -eq $answer) { Show-CalcScreen -State $State } }
            if ($answer.Key -ne [ConsoleKey]::Y) {
                Set-CalcMessage -State $State -Text 'History was not cleared.' -Color 'DarkGray'
                return
            }
        }
        try {
            Clear-CalcHistory -DataPath $State.DataPath -History $State.History
            Set-CalcMessage -State $State -Text 'History cleared.' -Color 'Green'
        }
        catch {
            Set-CalcMessage -State $State -Text ('History was cleared on screen but the file could not be deleted: {0}' -f $_.Exception.Message) -Color 'Red'
        }
        $State.Context.Ans = $null
        $State.HistIndex = -1
        $State.Draft = ''
    }

    function Switch-CalcAngleMode {
        param([hashtable] $State, [string] $Mode)
        if (-not $Mode) { $Mode = if ($State.Context.AngleMode -eq 'Deg') { 'Rad' } else { 'Deg' } }
        $State.Context.AngleMode = $Mode
        $label = if ($Mode -eq 'Deg') { 'degrees (DEG)' } else { 'radians (RAD)' }
        Set-CalcMessage -State $State -Text "Angles are now in $label." -Color 'Cyan'
        Save-CalcStateSetting -State $State
    }

    function Switch-CalcOutputBase {
        param([hashtable] $State, [int] $Base)
        if (-not $Base) {
            $position = [Array]::IndexOf($script:BaseCycle, [int]$State.Context.OutputBase)
            $Base = $script:BaseCycle[($position + 1) % $script:BaseCycle.Count]
        }
        $State.Context.OutputBase = $Base
        Set-CalcMessage -State $State -Text ('Results are now shown in {0} by default.' -f $script:BaseNames[$Base]) -Color 'Cyan'
        Save-CalcStateSetting -State $State
    }

    function Save-CalcStateSetting {
        param([hashtable] $State)
        try { Save-CalcSetting -DataPath $State.DataPath -Context $State.Context }
        catch { Set-CalcMessage -State $State -Text ('Could not save settings: {0}' -f $_.Exception.Message) -Color 'Red' }
    }

    function Invoke-CalcCommand {
        # Runs a command typed into the input. Returns $true if the text was
        # a command, $false if it should be evaluated as an expression.
        param([hashtable] $State, [string] $Text)
        $command = $Text.Trim().ToLowerInvariant()
        switch -Regex ($command) {
            '^(help|\?)$' { Show-CalcHelp -State $State; return $true }
            '^(exit|quit)$' { $State.Running = $false; return $true }
            '^clear$' { Invoke-CalcClearHistory -State $State; return $true }
            '^(deg|degrees)$' { Switch-CalcAngleMode -State $State -Mode 'Deg'; return $true }
            '^(rad|radians)$' { Switch-CalcAngleMode -State $State -Mode 'Rad'; return $true }
            '^base(\s+(?<name>\S+))?$' {
                $base = $null
                if ($Matches['name']) { $base = ConvertTo-CalcBase -Name $Matches['name'] }
                if ($null -eq $base) {
                    Set-CalcMessage -State $State -Text 'Usage: base bin | base oct | base dec | base hex' -Color 'Red'
                    $State.KeepInput = $true
                }
                else {
                    Switch-CalcOutputBase -State $State -Base $base
                }
                return $true
            }
        }
        return $false
    }

    function Submit-CalcInput {
        # Handles Enter: runs a command or evaluates the expression and
        # records it in the history.
        param([hashtable] $State)
        $text = $State.Input.Trim()
        if ($text.Length -eq 0) { return }

        $State.KeepInput = $false
        if (Invoke-CalcCommand -State $State -Text $text) {
            if (-not $State.KeepInput) {
                Set-CalcInputText -State $State -Text ''
                $State.HistIndex = -1
                $State.Draft = ''
            }
            return
        }

        try {
            $result = Invoke-CalcExpression -Expression $text -Context $State.Context
        }
        catch {
            # Keep the input so the user can fix it.
            Set-CalcMessage -State $State -Text ('Error: ' + $_.Exception.Message) -Color 'Red'
            return
        }

        $entry = New-CalcHistoryEntry -Expression $result.Expression -Result $result.Result -Value $result.Value `
            -AngleMode $State.Context.AngleMode -Time ([DateTime]::Now.ToString('o', $script:Invariant))
        try {
            Add-CalcHistoryEntry -DataPath $State.DataPath -History $State.History -Entry $entry
        }
        catch {
            Set-CalcMessage -State $State -Text ('Could not save history: {0}' -f $_.Exception.Message) -Color 'Red'
        }
        $State.Context.Ans = $result.Value
        if ($result.Notice -and -not $State.Message) { Set-CalcMessage -State $State -Text $result.Notice -Color 'Yellow' }

        Set-CalcInputText -State $State -Text ''
        $State.HistIndex = -1
        $State.Draft = ''
    }

    function Invoke-CalcKey {
        # Dispatches a single key press.
        param([hashtable] $State, [System.ConsoleKeyInfo] $Key)

        $control = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $alt = ($Key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
        $State.Message = $null

        # Ctrl shortcuts (Ctrl+Alt is AltGr on many keyboards, which types characters).
        if ($control -and -not $alt) {
            switch ($Key.Key) {
                ([ConsoleKey]::C) { Copy-CalcResult -State $State; return }
                ([ConsoleKey]::V) { Add-CalcClipboardText -State $State; return }
                ([ConsoleKey]::L) { Invoke-CalcClearHistory -State $State -Confirm; return }
                ([ConsoleKey]::W) {
                    $start = Get-CalcWordStart -Text $State.Input -Position $State.Cursor
                    $State.Input = $State.Input.Remove($start, $State.Cursor - $start)
                    $State.Cursor = $start
                    return
                }
            }
        }

        $length = $State.Input.Length
        switch ($Key.Key) {
            ([ConsoleKey]::Enter) { Submit-CalcInput -State $State; return }
            ([ConsoleKey]::UpArrow) { Move-CalcHistorySelection -State $State -Delta -1; return }
            ([ConsoleKey]::DownArrow) { Move-CalcHistorySelection -State $State -Delta 1; return }
            ([ConsoleKey]::PageUp) { Move-CalcHistorySelection -State $State -Delta (-[Math]::Max(1, [Console]::WindowHeight - 7)); return }
            ([ConsoleKey]::PageDown) {
                if ($State.HistIndex -ge 0) { Move-CalcHistorySelection -State $State -Delta ([Math]::Max(1, [Console]::WindowHeight - 7)) }
                return
            }
            ([ConsoleKey]::LeftArrow) {
                if ($control) { $State.Cursor = Get-CalcWordStart -Text $State.Input -Position $State.Cursor }
                elseif ($State.Cursor -gt 0) { $State.Cursor-- }
                return
            }
            ([ConsoleKey]::RightArrow) {
                if ($control) { $State.Cursor = Get-CalcWordEnd -Text $State.Input -Position $State.Cursor }
                elseif ($State.Cursor -lt $length) { $State.Cursor++ }
                return
            }
            ([ConsoleKey]::Home) { $State.Cursor = 0; return }
            ([ConsoleKey]::End) { $State.Cursor = $length; return }
            ([ConsoleKey]::Backspace) {
                if ($State.Cursor -eq 0) { return }
                $start = if ($control) { Get-CalcWordStart -Text $State.Input -Position $State.Cursor } else { $State.Cursor - 1 }
                $State.Input = $State.Input.Remove($start, $State.Cursor - $start)
                $State.Cursor = $start
                return
            }
            ([ConsoleKey]::Delete) {
                if ($State.Cursor -lt $length) { $State.Input = $State.Input.Remove($State.Cursor, 1) }
                return
            }
            ([ConsoleKey]::Escape) {
                if ($length -gt 0 -or $State.HistIndex -ge 0) {
                    Set-CalcInputText -State $State -Text ''
                    $State.HistIndex = -1
                    $State.Draft = ''
                }
                else {
                    $State.Running = $false
                }
                return
            }
            ([ConsoleKey]::Tab) { Complete-CalcName -State $State; return }
            ([ConsoleKey]::F1) { Show-CalcHelp -State $State; return }
            ([ConsoleKey]::F2) { Switch-CalcAngleMode -State $State; return }
            ([ConsoleKey]::F3) { Switch-CalcOutputBase -State $State; return }
        }

        # Any other printable character is typed into the input.
        $char = $Key.KeyChar
        if ($char -ne [char]0 -and -not [char]::IsControl($char)) {
            Add-CalcInputText -State $State -Text ([string]$char)
        }
    }

    function Invoke-CalcTui {
        <#
        .SYNOPSIS
            Runs the interactive calculator until the user quits. Console
            state (colors, encoding, Ctrl+C handling, title, cursor) is
            always restored on exit.
        #>
        param(
            [hashtable] $Context,
            [System.Collections.Generic.List[object]] $History,
            [string] $DataPath,
            [switch] $Ascii
        )

        if ($Host.Name -eq 'Windows PowerShell ISE Host') {
            throw 'The interactive calculator needs a console window and cannot run in the PowerShell ISE. Use -Expression, or run it from Windows Terminal or a PowerShell console.'
        }
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            throw 'The interactive calculator needs an interactive console. Use -Expression to evaluate expressions non-interactively.'
        }

        $state = @{
            Context    = $Context
            History    = $History
            DataPath   = $DataPath
            Glyph      = (Get-CalcGlyphSet -Ascii:$Ascii)
            Input      = ''
            Cursor     = 0
            ViewOffset = 0
            HistIndex  = -1
            Draft      = ''
            Scroll     = 0
            Message    = $null
            KeepInput  = $false
            Running    = $true
        }

        # Use the alternate screen buffer where virtual terminal sequences are
        # reliable (PowerShell 7+), so the user's console contents come back
        # untouched on exit. Windows PowerShell 5.1 clears the screen instead.
        $useAlternateScreen = $false
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            try { $useAlternateScreen = [bool]$Host.UI.SupportsVirtualTerminal } catch { $useAlternateScreen = $false }
        }
        $escape = [char]27

        $saved = @{
            TreatControlCAsInput = [Console]::TreatControlCAsInput
            OutputEncoding       = [Console]::OutputEncoding
            Title                = $Host.UI.RawUI.WindowTitle
        }

        try {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            [Console]::TreatControlCAsInput = $true   # Ctrl+C copies instead of quitting
            $Host.UI.RawUI.WindowTitle = 'pscalc'
            if ($useAlternateScreen) { [Console]::Write("$escape[?1049h") }
            [Console]::Clear()
            $script:ScreenTop = [Console]::WindowTop

            while ($state.Running) {
                try {
                    Show-CalcScreen -State $state
                }
                catch {
                    # A resize in the middle of drawing can push the cursor out
                    # of range; the next loop iteration redraws at the new size.
                    if ($script:RenderedSize -eq ('{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight)) { throw }
                }

                $key = Read-CalcKey
                if ($null -eq $key) { continue }
                Invoke-CalcKey -State $state -Key $key
                # Process keys that are already queued (e.g. pasted text) before redrawing.
                while ($state.Running -and [Console]::KeyAvailable) {
                    Invoke-CalcKey -State $state -Key ([Console]::ReadKey($true))
                }
            }
        }
        finally {
            [Console]::ResetColor()
            if ($useAlternateScreen) { [Console]::Write("$escape[?1049l") } else { [Console]::Clear() }
            [Console]::CursorVisible = $true
            [Console]::TreatControlCAsInput = $saved.TreatControlCAsInput
            [Console]::OutputEncoding = $saved.OutputEncoding
            $Host.UI.RawUI.WindowTitle = $saved.Title
        }
    }

    #endregion

    $pendingExpressions = New-Object -TypeName 'System.Collections.Generic.List[string]'
}

process {
    foreach ($item in $Expression) {
        if ($null -ne $item) { $pendingExpressions.Add($item) }
    }
}

end {
    # Allow the script to be dot-sourced (for example by tests) without
    # starting the calculator.
    if ($MyInvocation.InvocationName -eq '.') { return }

    $settings = Read-CalcSetting -DataPath $DataPath
    $history = Read-CalcHistory -DataPath $DataPath
    $context = @{
        AngleMode     = $settings.AngleMode
        OutputBase    = $settings.OutputBase
        Ans           = $null
        RequestedBase = $null
    }
    if ($history.Count -gt 0) { $context.Ans = $history[$history.Count - 1].Value }

    if ($pendingExpressions.Count -gt 0) {
        # Non-interactive mode: evaluate and output each result.
        foreach ($item in $pendingExpressions) {
            try {
                $result = Invoke-CalcExpression -Expression $item -Context $context
                $context.Ans = $result.Value
                if ($result.Notice) { Write-Warning $result.Notice }
                $result.Result
            }
            catch {
                Write-Error -Message ('{0}: {1}' -f $item, $_.Exception.Message) -Category InvalidArgument -TargetObject $item
            }
        }
        return
    }

    Invoke-CalcTui -Context $context -History $history -DataPath $DataPath -Ascii:$Ascii
}
