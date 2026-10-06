<#
.SYNOPSIS
    wc - print newline, word, and byte counts for each file.

.DESCRIPTION
    A self-contained PowerShell port of the POSIX / GNU coreutils wc utility.
    Runs on Windows PowerShell 5.1 and PowerShell 7+ with no dependencies.

    Usage: Wc.ps1 [OPTION]... [FILE]...
      or:  Wc.ps1 [OPTION]... --files0-from=F

    Print newline, word, and byte counts for each FILE, and a total line if
    more than one FILE is specified.  A word is a nonempty sequence of non
    white space delimited by white space characters or by start or end of
    input.  With no FILE, or when FILE is -, read standard input.

      -c, --bytes            print the byte counts
      -m, --chars            print the character counts
      -l, --lines            print the newline counts
          --files0-from=F    read input from the files specified by
                               NUL-terminated names in file F;
                               If F is - then read names from standard input
      -L, --max-line-length  print the maximum display width
      -w, --words            print the word counts
          --total=WHEN       when to print a line with total counts;
                               WHEN can be: auto, always, only, never
          --help             display this help and exit
          --version          output version information and exit

    Run "Wc.ps1 --help" for the full usage text.

.NOTES
    PowerShell-specific behavior:
    * Objects piped in from PowerShell (e.g. Get-Content x | .\Wc.ps1) are
      treated as standard input: each string becomes one line (UTF-8 encoded,
      terminated by LF); [byte] and [byte[]] items are counted as raw bytes.
    * When run via "powershell -File Wc.ps1 < file", standard input is read
      as raw bytes, exactly like the native utility.
    * PowerShell itself consumes a bare "--" argument before the script sees
      it, so "--" is only honored when PowerShell passes it through.
    * Windows shells do not expand wildcards, so FILE operands containing
      *, ? or [...] that do not name an existing file are expanded the way a
      POSIX shell would before wc sees them.
    * Character decoding follows LC_ALL / LC_CTYPE / LANG; "C" or "POSIX"
      selects single-byte mode, anything else (or nothing) selects UTF-8.
#>

# NOTE: no param() block on purpose - every argument (including things like
# "-lw" or "--total=only") must reach $args untouched so that it can be parsed
# with GNU getopt_long semantics below.

$script:ProgName = 'wc'
$script:VersionText = '1.0.0'
$script:ExitStatus = 0

# ---------------------------------------------------------------------------
# Diagnostics and quoting (mirrors gnulib quotearg shell-escape styles)
# ---------------------------------------------------------------------------

function Write-Diag([string]$Message) {
    [Console]::Error.WriteLine($script:ProgName + ': ' + $Message)
}

function Write-TryHelp {
    [Console]::Error.WriteLine("Try '" + $script:ProgName + " --help' for more information.")
}

function Get-ControlEscape([char]$c) {
    switch ([int]$c) {
        7  { return '\a' }
        8  { return '\b' }
        9  { return '\t' }
        10 { return '\n' }
        11 { return '\v' }
        12 { return '\f' }
        13 { return '\r' }
    }
    return '\' + [Convert]::ToString([int]$c, 8).PadLeft(3, '0')
}

# Shell-escape quoting.  $Always = $true behaves like quoteaf (always quoted),
# $false like quotef (quoted only when the name needs it).
function Format-Quoted([string]$s, [bool]$Always) {
    if ($s.Length -eq 0) { return "''" }
    $hasControl = $s -match '[\x00-\x1F\x7F-\x9F]'
    $needs = $Always -or $hasControl -or
             ($s -match '[^A-Za-z0-9_%+,\-./@{}\]~#\u00A0-\uFFFF]') -or
             $s.StartsWith('~') -or $s.StartsWith('#')
    if (-not $needs) { return $s }
    if (-not $hasControl) {
        if ($s.Contains("'") -and $s -notmatch '[\$`"\\!]') { return '"' + $s + '"' }
        return "'" + $s.Replace("'", "'\''") + "'"
    }
    # Printable runs go in '...', control characters in $'...' (e.g. 'a'$'\n''b').
    $sb = New-Object System.Text.StringBuilder
    $first = [int]$s[0]
    if ($first -lt 0x20 -or ($first -ge 0x7F -and $first -le 0x9F)) { [void]$sb.Append("''") }
    $plain = New-Object System.Text.StringBuilder
    $ctrl = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 0x20 -or ($code -ge 0x7F -and $code -le 0x9F)) {
            if ($plain.Length) { [void]$sb.Append("'" + $plain.ToString().Replace("'", "'\''") + "'"); [void]$plain.Clear() }
            [void]$ctrl.Append((Get-ControlEscape $ch))
        } else {
            if ($ctrl.Length) { [void]$sb.Append('$''' + $ctrl.ToString() + "'"); [void]$ctrl.Clear() }
            [void]$plain.Append($ch)
        }
    }
    if ($plain.Length) { [void]$sb.Append("'" + $plain.ToString().Replace("'", "'\''") + "'") }
    if ($ctrl.Length) { [void]$sb.Append('$''' + $ctrl.ToString() + "'") }
    return $sb.ToString()
}

function Get-ErrnoText([System.Exception]$e) {
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) {
        $e = $e.InnerException
    }
    if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) {
        return 'No such file or directory'
    }
    if ($e -is [System.UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) {
        return 'Permission denied'
    }
    if ($e -is [System.IO.PathTooLongException]) { return 'File name too long' }
    # PowerShell path resolution failures (unknown drive or provider).
    if ($e -is [System.Management.Automation.SessionStateException]) { return 'No such file or directory' }
    # Names Windows cannot represent (e.g. containing * or ?) cannot exist.
    if ($e -is [System.ArgumentException] -or $e -is [System.NotSupportedException]) {
        return 'No such file or directory'
    }
    $hr = $e.HResult -band 0xFFFF
    switch ($hr) {
        2   { return 'No such file or directory' }   # ERROR_FILE_NOT_FOUND
        3   { return 'No such file or directory' }   # ERROR_PATH_NOT_FOUND
        5   { return 'Permission denied' }           # ERROR_ACCESS_DENIED
        123 { return 'No such file or directory' }   # ERROR_INVALID_NAME
        32  { return 'Device or resource busy' }     # ERROR_SHARING_VIOLATION
        33  { return 'Device or resource busy' }     # ERROR_LOCK_VIOLATION
        21  { return 'No such device' }              # ERROR_NOT_READY
        23  { return 'Input/output error' }          # ERROR_CRC
    }
    return $e.Message.TrimEnd()
}

# ---------------------------------------------------------------------------
# Help / version
# ---------------------------------------------------------------------------

function Show-Usage {
    $p = $script:ProgName
    @"
Usage: $p [OPTION]... [FILE]...
  or:  $p [OPTION]... --files0-from=F
Print newline, word, and byte counts for each FILE, and a total line if
more than one FILE is specified.  A word is a nonempty sequence of non white
space delimited by white space characters or by start or end of input.

With no FILE, or when FILE is -, read standard input.

The options below may be used to select which counts are printed, always in
the following order: newline, word, character, byte, maximum line length.
  -c, --bytes            print the byte counts
  -m, --chars            print the character counts
  -l, --lines            print the newline counts
      --files0-from=F    read input from the files specified by
                           NUL-terminated names in file F;
                           If F is - then read names from standard input
  -L, --max-line-length  print the maximum display width
  -w, --words            print the word counts
      --total=WHEN       when to print a line with total counts;
                           WHEN can be: auto, always, only, never
      --help        display this help and exit
      --version     output version information and exit
"@ -split "`r?`n"
}

function Show-Version {
    "$($script:ProgName) (PowerShell port) $($script:VersionText)"
    'A self-contained PowerShell port of the POSIX/GNU wc utility.'
    'This is free software: you are free to change and redistribute it.'
    'There is NO WARRANTY, to the extent permitted by law.'
}

# ---------------------------------------------------------------------------
# Option parsing (GNU getopt_long semantics, including argument permutation,
# bundled short options and unambiguous long-option abbreviations)
# ---------------------------------------------------------------------------

$script:DoLines = $false
$script:DoWords = $false
$script:DoChars = $false
$script:DoBytes = $false
$script:DoMaxLine = $false
$script:Files0From = $null
$script:TotalMode = 'auto'

# Same order as the long_options table of GNU wc (used for ambiguity reports).
$LongOptions = @(
    @{ Name = 'bytes';           Arg = 'none' },
    @{ Name = 'chars';           Arg = 'none' },
    @{ Name = 'lines';           Arg = 'none' },
    @{ Name = 'files0-from';     Arg = 'required' },
    @{ Name = 'max-line-length'; Arg = 'none' },
    @{ Name = 'words';           Arg = 'none' },
    @{ Name = 'total';           Arg = 'required' },
    @{ Name = 'help';            Arg = 'none' },
    @{ Name = 'version';         Arg = 'none' }
)

$TotalArgs = @('auto', 'always', 'only', 'never')

# gnulib argmatch: exact match, or an unambiguous prefix.
function Select-TotalMode([string]$value) {
    $exact = $TotalArgs | Where-Object { $_ -ceq $value }
    if ($exact) { return $exact }
    $matched = @($TotalArgs | Where-Object { $_.StartsWith($value, [StringComparison]::Ordinal) })
    if ($matched.Count -eq 1) { return $matched[0] }
    if ($matched.Count -gt 1) {
        Write-Diag ("ambiguous argument " + (Format-Quoted $value $true) + " for '--total'")
    } else {
        Write-Diag ("invalid argument " + (Format-Quoted $value $true) + " for '--total'")
    }
    $lines = @('Valid arguments are:') + ($TotalArgs | ForEach-Object { "  - '$_'" })
    foreach ($l in $lines) { [Console]::Error.WriteLine($l) }
    Write-TryHelp
    exit 1
}

function Invoke-Option([string]$name, $value) {
    switch -CaseSensitive ($name) {
        'bytes'           { $script:DoBytes = $true }
        'chars'           { $script:DoChars = $true }
        'lines'           { $script:DoLines = $true }
        'words'           { $script:DoWords = $true }
        'max-line-length' { $script:DoMaxLine = $true }
        'files0-from'     { $script:Files0From = [string]$value }
        'total'           { $script:TotalMode = Select-TotalMode ([string]$value) }
        'help'            { Show-Usage; exit 0 }
        'version'         { Show-Version; exit 0 }
    }
}

# Flatten $args (PowerShell turns "a,b" into an array) and stringify.
$argv = New-Object System.Collections.Generic.List[string]
foreach ($a in $args) {
    if ($null -eq $a) { continue }
    if ($a -is [System.Array]) { foreach ($x in $a) { $argv.Add([string]$x) } }
    else { $argv.Add([string]$a) }
}

$posixlyCorrect = $null -ne $env:POSIXLY_CORRECT
$operands = New-Object System.Collections.Generic.List[string]
$endOfOptions = $false
$i = 0
while ($i -lt $argv.Count) {
    $arg = $argv[$i]
    $i++
    if ($endOfOptions -or $arg -eq '-' -or -not $arg.StartsWith('-')) {
        $operands.Add($arg)
        if ($posixlyCorrect) { $endOfOptions = $true }
        continue
    }
    if ($arg -eq '--') { $endOfOptions = $true; continue }

    if ($arg.StartsWith('--')) {
        $body = $arg.Substring(2)
        $eq = $body.IndexOf('=')
        if ($eq -ge 0) { $optName = $body.Substring(0, $eq); $optValue = $body.Substring($eq + 1) }
        else { $optName = $body; $optValue = $null }

        $opt = $LongOptions | Where-Object { $_.Name -ceq $optName } | Select-Object -First 1
        if (-not $opt) {
            $cands = @($LongOptions | Where-Object { $_.Name.StartsWith($optName, [StringComparison]::Ordinal) })
            if ($cands.Count -eq 1) {
                $opt = $cands[0]
            } elseif ($cands.Count -gt 1) {
                $poss = ($cands | ForEach-Object { "'--" + $_.Name + "'" }) -join ' '
                Write-Diag ("option '" + $arg.Split('=')[0] + "' is ambiguous; possibilities: " + $poss)
                Write-TryHelp
                exit 1
            } else {
                Write-Diag ("unrecognized option '" + $arg + "'")
                Write-TryHelp
                exit 1
            }
        }
        if ($opt.Arg -eq 'none' -and $null -ne $optValue) {
            Write-Diag ("option '--" + $opt.Name + "' doesn't allow an argument")
            Write-TryHelp
            exit 1
        }
        if ($opt.Arg -eq 'required' -and $null -eq $optValue) {
            if ($i -lt $argv.Count) { $optValue = $argv[$i]; $i++ }
            else {
                Write-Diag ("option '--" + $opt.Name + "' requires an argument")
                Write-TryHelp
                exit 1
            }
        }
        Invoke-Option $opt.Name $optValue
        continue
    }

    # Bundled short options: -lwc
    for ($j = 1; $j -lt $arg.Length; $j++) {
        $c = $arg[$j]
        switch -CaseSensitive ([string]$c) {
            'c' { $script:DoBytes = $true }
            'm' { $script:DoChars = $true }
            'l' { $script:DoLines = $true }
            'w' { $script:DoWords = $true }
            'L' { $script:DoMaxLine = $true }
            default {
                Write-Diag ("invalid option -- '" + $c + "'")
                Write-TryHelp
                exit 1
            }
        }
    }
}

if (-not ($DoLines -or $DoWords -or $DoChars -or $DoBytes -or $DoMaxLine)) {
    $DoLines = $true; $DoWords = $true; $DoBytes = $true
}
$NeedText = $DoWords -or $DoChars -or $DoMaxLine

# ---------------------------------------------------------------------------
# Locale / character classification
# ---------------------------------------------------------------------------

$localeName = $env:LC_ALL
if (-not $localeName) { $localeName = $env:LC_CTYPE }
if (-not $localeName) { $localeName = $env:LANG }
$Multibyte = -not ($localeName -eq 'C' -or $localeName -eq 'POSIX')

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
if ($Multibyte) {
    # Invalid byte sequences decode to nothing: like GNU wc they are counted
    # as bytes but never as characters, and they neither start nor end words.
    $TextEncoding = [System.Text.Encoding]::GetEncoding('utf-8',
        [System.Text.EncoderFallback]::ReplacementFallback,
        (New-Object System.Text.DecoderReplacementFallback ''))
} else {
    $TextEncoding = $Latin1
}
$Utf8 = New-Object System.Text.UTF8Encoding $false

# White space that separates words.
$spaceCodes = @(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)
if ($Multibyte) {
    $spaceCodes += @(0x1680) + (0x2000..0x2006) + (0x2008..0x200A) + @(0x205F, 0x3000)
    if (-not $posixlyCorrect) { $spaceCodes += @(0x00A0, 0x2007, 0x202F, 0x2060) }   # non-breaking spaces
}
$SpaceChars = [char[]]($spaceCodes | ForEach-Object { [char]$_ })
$spaceClass = -join ($spaceCodes | ForEach-Object { '\u{0:X4}' -f $_ })
$rxOpts = [System.Text.RegularExpressions.RegexOptions]::Compiled
# As in GNU wc, a word is a run of non-space characters that contains at
# least one printable character; non-printable characters neither start nor
# end a word.
# Non-printable supplementary code points: unassigned planes 4-13 and the
# U+xFFFE / U+xFFFF noncharacters at the end of every plane.
$planeEnds = -join (1..16 | ForEach-Object { '\u{0:X4}' -f (0xD800 + $_ * 0x40 - 1) })
$AstralNonPrintable = '[\uD8C0-\uDB3F][\uDC00-\uDFFF]|[' + $planeEnds + '][\uDFFE\uDFFF]'
if ($Multibyte) {
    # A low surrogate is never the start of a character.
    $printableClass = '(?!' + $AstralNonPrintable + ')[^\p{Cc}\p{Cn}\p{Zl}\p{Zp}\uDC00-\uDFFF' + $spaceClass + ']'
} else {
    $printableClass = '[\x21-\x7E]'
}
$PrintableRx = New-Object System.Text.RegularExpressions.Regex $printableClass, $rxOpts
$WordRx = New-Object System.Text.RegularExpressions.Regex ($printableClass + '[^' + $spaceClass + ']*'), $rxOpts
$LowSurrogateRx = New-Object System.Text.RegularExpressions.Regex '[\uDC00-\uDFFF]', $rxOpts
$LineBreakChars = [char[]]@([char]10, [char]13, [char]12)
$TabChar = [char]9

# --max-line-length works on a rewritten copy of the text in which every
# character occupies exactly one column: zero-width and non-printable
# characters are removed and double-width ones are doubled.  Only tabs and
# line breaks then need special handling, and the rewriting is done by the
# regex engine instead of a slow per-character PowerShell loop.

# East Asian Wide / Fullwidth (and emoji presentation) ranges: width 2.
$WideRanges = @(
    0x1100, 0x115F,  0x231A, 0x231B,  0x2329, 0x232A,  0x23E9, 0x23EC,  0x23F0, 0x23F0,
    0x23F3, 0x23F3,  0x25FD, 0x25FE,  0x2614, 0x2615,  0x2648, 0x2653,  0x267F, 0x267F,
    0x2693, 0x2693,  0x26A1, 0x26A1,  0x26AA, 0x26AB,  0x26BD, 0x26BE,  0x26C4, 0x26C5,
    0x26CE, 0x26CE,  0x26D4, 0x26D4,  0x26EA, 0x26EA,  0x26F2, 0x26F3,  0x26F5, 0x26F5,
    0x26FA, 0x26FA,  0x26FD, 0x26FD,  0x2705, 0x2705,  0x270A, 0x270B,  0x2728, 0x2728,
    0x274C, 0x274C,  0x274E, 0x274E,  0x2753, 0x2755,  0x2757, 0x2757,  0x2795, 0x2797,
    0x27B0, 0x27B0,  0x27BF, 0x27BF,  0x2B1B, 0x2B1C,  0x2B50, 0x2B50,  0x2B55, 0x2B55,
    0x2E80, 0x303E,  0x3041, 0x33FF,  0x3400, 0x4DBF,  0x4E00, 0x9FFF,  0xA000, 0xA4CF,
    0xA960, 0xA97F,  0xAC00, 0xD7A3,  0xF900, 0xFAFF,  0xFE10, 0xFE19,  0xFE30, 0xFE6F,
    0xFF00, 0xFF60,  0xFFE0, 0xFFE6,
    0x16FE0, 0x16FE4,  0x17000, 0x18CFF,  0x1B000, 0x1B2FF,  0x1F004, 0x1F004,  0x1F0CF, 0x1F0CF,
    0x1F18E, 0x1F18E,  0x1F191, 0x1F19A,  0x1F200, 0x1F202,  0x1F210, 0x1F23B,  0x1F240, 0x1F248,
    0x1F250, 0x1F251,  0x1F260, 0x1F265,  0x1F300, 0x1F64F,  0x1F680, 0x1F6FF,  0x1F7E0, 0x1F7EB,
    0x1F90C, 0x1F9FF,  0x1FA70, 0x1FAFF,  0x20000, 0x2FFFD,  0x30000, 0x3FFFD)

# Regex alternatives matching the UTF-16 encoding of code points first..last.
function ConvertTo-Utf16Pattern([int]$first, [int]$last) {
    if ($last -lt 0x10000) { return '[\u{0:X4}-\u{1:X4}]' -f $first, $last }
    $a = [char]::ConvertFromUtf32($first); $b = [char]::ConvertFromUtf32($last)
    $hiA = [int]$a[0]; $loA = [int]$a[1]; $hiB = [int]$b[0]; $loB = [int]$b[1]
    if ($hiA -eq $hiB) { return '\u{0:X4}[\u{1:X4}-\u{2:X4}]' -f $hiA, $loA, $loB }
    $alts = @('\u{0:X4}[\u{1:X4}-\uDFFF]' -f $hiA, $loA)
    if ($hiB - $hiA -gt 1) { $alts += '[\u{0:X4}-\u{1:X4}][\uDC00-\uDFFF]' -f ($hiA + 1), ($hiB - 1) }
    $alts += '\u{0:X4}[\uDC00-\u{1:X4}]' -f $hiB, $loB
    return $alts -join '|'
}

if ($Multibyte) {
    # Non-printable (controls other than \t \n \r \f, unassigned) and
    # zero-width (combining marks, format chars except SOFT HYPHEN, Hangul
    # medial vowels / final consonants, line/paragraph separators).
    $ZeroWidthRx = New-Object System.Text.RegularExpressions.Regex (
        '[\x00-\x08\x0B\x0E-\x1F\x7F-\x9F\p{Mn}\p{Me}\p{Cn}\p{Zl}\p{Zp}\u1160-\u11FF]|[\p{Cf}-[\u00AD]]|' +
        $AstralNonPrintable), $rxOpts
    $bmp = New-Object System.Collections.Generic.List[string]
    $astral = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $WideRanges.Length; $k += 2) {
        $pat = ConvertTo-Utf16Pattern $WideRanges[$k] $WideRanges[$k + 1]
        if ($WideRanges[$k] -lt 0x10000) { $bmp.Add($pat) } else { $astral.Add($pat) }
    }
    $WideBmpRx = New-Object System.Text.RegularExpressions.Regex (($bmp -join '|')), $rxOpts
    $WideAstralRx = New-Object System.Text.RegularExpressions.Regex (($astral -join '|')), $rxOpts
    $PairRx = New-Object System.Text.RegularExpressions.Regex '[\uD800-\uDBFF][\uDC00-\uDFFF]', $rxOpts
} else {
    # C locale: only printable ASCII has a width.
    $ZeroWidthRx = New-Object System.Text.RegularExpressions.Regex '[^\x20-\x7E\t\n\r\f]', $rxOpts
}

function ConvertTo-Columns([string]$text) {
    $text = $ZeroWidthRx.Replace($text, '')
    if ($Multibyte -and $text -match '[^\x00-\x7F]') {
        $text = $WideBmpRx.Replace($text, '$0$0')
        $text = $WideAstralRx.Replace($text, '##')
        $text = $PairRx.Replace($text, '#')
    }
    return $text
}

# ---------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------

$BufferSize = 1MB
$Buffer = New-Object byte[] $BufferSize
$CharBuffer = New-Object char[] ($BufferSize + 16)
$EmptyBytes = New-Object byte[] 0

function New-Counter {
    @{
        Lines = [long]0; Words = [long]0; Chars = [long]0; Bytes = [long]0
        MaxLine = [long]0; LinePos = [long]0; InWord = $false
        Decoder = $TextEncoding.GetDecoder()
    }
}

function Add-Text($st, [string]$text) {
    if ($text.Length -eq 0) { return }
    if ($DoLines) {
        $st.Lines += $text.Length - $text.Replace("`n", '').Length
    }
    if ($DoChars) {
        if ($Multibyte) { $st.Chars += $text.Length - $LowSurrogateRx.Matches($text).Count }
        else { $st.Chars += $text.Length }
    }
    if ($DoWords) {
        $w = $WordRx.Matches($text).Count
        $firstSpace = $text.IndexOfAny($SpaceChars)
        if ($firstSpace -lt 0) { $head = $text } else { $head = $text.Substring(0, $firstSpace) }
        $headHasWord = $PrintableRx.IsMatch($head)
        # A word that straddles two chunks was counted in both.
        if ($st.InWord -and $headHasWord) { $w-- }
        $st.Words += $w
        $lastSpace = $text.LastIndexOfAny($SpaceChars)
        if ($lastSpace -lt 0) { $st.InWord = $st.InWord -or $headHasWord }
        else { $st.InWord = $PrintableRx.IsMatch($text.Substring($lastSpace + 1)) }
    }
    if ($DoMaxLine) {
        $cols = ConvertTo-Columns $text
        $pieces = $cols.Split($LineBreakChars)
        $hasTabs = $cols.IndexOf($TabChar) -ge 0
        $last = $pieces.Length - 1
        $pos = $st.LinePos
        $max = $st.MaxLine
        for ($k = 0; $k -le $last; $k++) {
            $p = $pieces[$k]
            if ($hasTabs -and $p.IndexOf($TabChar) -ge 0) {
                # Tabs advance to the next multiple of 8.
                $tabParts = $p.Split($TabChar)
                $tl = $tabParts.Length - 1
                for ($q = 0; $q -lt $tl; $q++) {
                    $pos += $tabParts[$q].Length
                    $pos += 8 - ($pos % 8)
                }
                $pos += $tabParts[$tl].Length
            } else {
                $pos += $p.Length
            }
            if ($k -lt $last) {
                if ($pos -gt $max) { $max = $pos }
                $pos = 0
            }
        }
        $st.LinePos = $pos
        $st.MaxLine = $max
    }
}

function Add-Bytes($st, [byte[]]$buf, [int]$count) {
    # Work in slices no larger than the char buffer.
    for ($offset = 0; $offset -lt $count; $offset += $slice) {
        $slice = [Math]::Min($BufferSize, $count - $offset)
        $st.Bytes += $slice
        if ($NeedText) {
            $n = $st.Decoder.GetChars($buf, $offset, $slice, $CharBuffer, 0, $false)
            if ($n -gt 0) { Add-Text $st (New-Object string $CharBuffer, 0, $n) }
        } elseif ($DoLines) {
            $text = $Latin1.GetString($buf, $offset, $slice)
            $st.Lines += $text.Length - $text.Replace("`n", '').Length
        }
    }
}

function Complete-Counter($st) {
    if ($NeedText) {
        $n = $st.Decoder.GetChars($EmptyBytes, 0, 0, $CharBuffer, 0, $true)
        if ($n -gt 0) { Add-Text $st (New-Object string $CharBuffer, 0, $n) }
    }
    if ($st.LinePos -gt $st.MaxLine) { $st.MaxLine = $st.LinePos }
}

function Read-StreamInto($st, [System.IO.Stream]$stream) {
    while ($true) {
        $n = $stream.Read($Buffer, 0, $Buffer.Length)
        if ($n -le 0) { break }
        Add-Bytes $st $Buffer $n
    }
}

# --- standard input --------------------------------------------------------

# Pipeline input from PowerShell is used as stdin, except when the host runs
# us via "-File" (then $MyInvocation.Line is empty and real stdin is raw).
# The automatic input variable is fetched by name on purpose: if the script
# text mentions it literally, "pwsh -File" pre-reads stdin as text lines and
# the raw bytes are lost.
$script:PipeInput = $null
if ($MyInvocation.ExpectingInput -and $MyInvocation.Line) {
    $script:PipeInput = $ExecutionContext.SessionState.PSVariable.GetValue('input')
}
$script:StdinStream = $null

function Get-StdinStream {
    if (-not $script:StdinStream) { $script:StdinStream = [Console]::OpenStandardInput() }
    return $script:StdinStream
}

function Read-PipelineInto($st) {
    $ms = New-Object System.IO.MemoryStream
    foreach ($item in $script:PipeInput) {
        if ($null -eq $item) { continue }
        if ($item -is [byte]) { $ms.WriteByte($item) }
        elseif ($item -is [byte[]]) { $ms.Write($item, 0, $item.Length) }
        else {
            $bytes = $Utf8.GetBytes([string]$item + "`n")
            $ms.Write($bytes, 0, $bytes.Length)
        }
        if ($ms.Length -ge $BufferSize) {
            Add-Bytes $st $ms.GetBuffer() ([int]$ms.Length)
            $ms.SetLength(0)
        }
    }
    if ($ms.Length -gt 0) { Add-Bytes $st $ms.GetBuffer() ([int]$ms.Length) }
}

function Read-StdinInto($st) {
    if ($null -ne $script:PipeInput) { Read-PipelineInto $st }
    else { Read-StreamInto $st (Get-StdinStream) }
}

function Read-AllStdinBytes {
    $ms = New-Object System.IO.MemoryStream
    if ($null -ne $script:PipeInput) {
        foreach ($item in $script:PipeInput) {
            if ($null -eq $item) { continue }
            if ($item -is [byte]) { $ms.WriteByte($item) }
            elseif ($item -is [byte[]]) { $ms.Write($item, 0, $item.Length) }
            else { $b = $Utf8.GetBytes([string]$item + "`n"); $ms.Write($b, 0, $b.Length) }
        }
    } else {
        (Get-StdinStream).CopyTo($ms)
    }
    return , $ms.ToArray()
}

# --- files -----------------------------------------------------------------

function Resolve-FsPath([string]$name) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($name)
}

# fstat(STDIN) emulation: the size of stdin when it is redirected from a disk
# file ("wc < file"), otherwise $null.  The runtime's internal Win32 interop
# wrappers are used through reflection so that no code has to be compiled.
function Get-StdinFileSize {
    if ($null -ne $script:PipeInput -or -not [Console]::IsInputRedirected) { return $null }
    try {
        $flags = [System.Reflection.BindingFlags]'NonPublic,Public,Static'
        foreach ($asm in @([Console].Assembly, [object].Assembly)) {
            foreach ($typeName in @('Interop+Kernel32', 'Microsoft.Win32.Win32Native')) {
                $t = $asm.GetType($typeName)
                if (-not $t) { continue }
                $getStd = $t.GetMethods($flags) | Where-Object { $_.Name -eq 'GetStdHandle' } | Select-Object -First 1
                $getType = $t.GetMethods($flags) | Where-Object { $_.Name -eq 'GetFileType' } | Select-Object -First 1
                if (-not $getStd -or -not $getType) { continue }
                $handle = [IntPtr]$getStd.Invoke($null, @([int]-10))   # STD_INPUT_HANDLE
                $safe = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($handle, $false)
                $callArgs = [object[]]::new(1)
                if ($getType.GetParameters()[0].ParameterType -eq [IntPtr]) { $callArgs[0] = $handle }
                else { $callArgs[0] = $safe }
                $kind = $getType.Invoke($null, $callArgs)
                if ([int]$kind -ne 1) { return $null }                   # FILE_TYPE_DISK
                $fs = New-Object System.IO.FileStream ($safe, [System.IO.FileAccess]::Read)
                return $fs.Length
            }
        }
    } catch { }
    return $null
}

# Mimics stat(): returns $null on failure, otherwise kind + size.
function Get-InputStatus($name) {
    if ($null -eq $name -or $name -eq '-') {
        $size = Get-StdinFileSize
        if ($null -ne $size) { return @{ Regular = $true; Size = $size } }
        return @{ Regular = $false; Size = 0 }
    }
    if ($name -eq '') { return $null }
    try {
        $path = Resolve-FsPath $name
        if ([System.IO.Directory]::Exists($path)) { return @{ Regular = $false; Size = 0 } }
        if ([System.IO.File]::Exists($path)) {
            return @{ Regular = $true; Size = (New-Object System.IO.FileInfo $path).Length }
        }
    } catch { }
    return $null
}

# Returns $true on success.  Output (counts) is written by the caller.
function Read-FileInto($st, [string]$name) {
    try {
        $path = Resolve-FsPath $name
    } catch {
        Write-Diag ((Format-Quoted $name $false) + ': ' + (Get-ErrnoText $_.Exception))
        return $null
    }
    if ([System.IO.Directory]::Exists($path)) {
        # open() succeeds on a directory but read() fails: GNU wc reports the
        # error and still prints a line of zero counts.
        Write-Diag ((Format-Quoted $name $false) + ': Is a directory')
        return $false
    }
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream ($path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete), 4096)
    } catch {
        Write-Diag ((Format-Quoted $name $false) + ': ' + (Get-ErrnoText $_.Exception))
        return $null
    }
    try {
        if ($DoBytes -and -not ($DoChars -or $DoLines -or $DoWords -or $DoMaxLine)) {
            # Only bytes requested: the size is enough, like GNU's fstat shortcut.
            $st.Bytes = $fs.Length
        } else {
            Read-StreamInto $st $fs
        }
        return $true
    } catch {
        Write-Diag ((Format-Quoted $name $false) + ': ' + (Get-ErrnoText $_.Exception))
        return $false
    } finally {
        $fs.Dispose()
    }
}

# --- shell-style wildcard expansion (Windows shells do not glob) -------------

function Expand-Operand([string]$arg) {
    if ($arg -notmatch '[*?\[]') { return , @($arg) }
    try {
        if (Test-Path -LiteralPath $arg) { return , @($arg) }
    } catch { return , @($arg) }

    # Expand one path component at a time, keeping the text the user typed
    # for literal components (so "../d/*.txt" yields "../d/a.txt").
    $parts = [regex]::Split($arg, '([\\/]+)')     # components and separators
    $prefixes = @('')
    for ($k = 0; $k -lt $parts.Length; $k += 2) {
        $comp = $parts[$k]
        $sep = ''
        if ($k + 1 -lt $parts.Length) { $sep = $parts[$k + 1] }
        $next = @()
        foreach ($prefix in $prefixes) {
            if ($comp -notmatch '[*?\[]') {
                $next += $prefix + $comp + $sep
                continue
            }
            $dir = $prefix
            if ($dir -eq '') { $dir = '.' }
            try {
                $dirPath = Resolve-FsPath $dir
                if (-not [System.IO.Directory]::Exists($dirPath)) { continue }
                $entries = [System.IO.Directory]::GetFileSystemEntries($dirPath)
            } catch { continue }
            $pattern = New-Object System.Management.Automation.WildcardPattern ($comp,
                [System.Management.Automation.WildcardOptions]::IgnoreCase)
            $matched = @(foreach ($e in $entries) {
                $leaf = [System.IO.Path]::GetFileName($e)
                if ($leaf.StartsWith('.') -and -not $comp.StartsWith('.')) { continue }
                if ($pattern.IsMatch($leaf)) { $leaf }
            })
            foreach ($leaf in ($matched | Sort-Object -CaseSensitive)) {
                # Only directories can be followed by further components.
                if ($sep -ne '' -and -not [System.IO.Directory]::Exists((Join-Path $dirPath $leaf))) { continue }
                $next += $prefix + $leaf + $sep
            }
        }
        $prefixes = $next
        if ($prefixes.Count -eq 0) { break }
    }
    if ($prefixes.Count -eq 0) { return , @($arg) }
    return , @($prefixes)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$names = New-Object System.Collections.Generic.List[object]
$streamingNames = $false

if ($null -ne $Files0From) {
    if ($operands.Count -gt 0) {
        Write-Diag ('extra operand ' + (Format-Quoted $operands[0] $true))
        [Console]::Error.WriteLine('file operands cannot be combined with --files0-from')
        Write-TryHelp
        exit 1
    }
    $listBytes = $null
    if ($Files0From -eq '-') {
        $streamingNames = $true      # names from a pipe are read incrementally
        try { $listBytes = Read-AllStdinBytes }
        catch {
            Write-Diag ('cannot read file names from ' + (Format-Quoted '-' $true))
            exit 1
        }
    } else {
        try {
            $listPath = Resolve-FsPath $Files0From
            if ([System.IO.Directory]::Exists($listPath)) {
                Write-Diag ('cannot read file names from ' + (Format-Quoted $Files0From $true) + ': Is a directory')
                exit 1
            }
            $listBytes = [System.IO.File]::ReadAllBytes($listPath)
        } catch {
            Write-Diag ('cannot open ' + (Format-Quoted $Files0From $true) + ' for reading: ' + (Get-ErrnoText $_.Exception))
            exit 1
        }
    }
    $tokens = $Utf8.GetString($listBytes).Split([char]0)
    $count = $tokens.Length
    if ($count -gt 0 -and $tokens[$count - 1] -eq '') { $count-- }   # final terminator
    for ($k = 0; $k -lt $count; $k++) { $names.Add($tokens[$k]) }
} elseif ($operands.Count -eq 0) {
    $names.Add($null)               # stdin, printed without a name
} else {
    foreach ($op in $operands) {
        foreach ($n in (Expand-Operand $op)) { $names.Add($n) }
    }
}

# Field width, computed exactly like GNU wc's compute_number_width().
$countsPrinted = @($DoLines, $DoWords, $DoChars, $DoBytes, $DoMaxLine | Where-Object { $_ }).Count
$NumberWidth = 1
if (-not $streamingNames -and $names.Count -gt 0 -and
    -not ($names.Count -eq 1 -and $countsPrinted -eq 1)) {
    $minimumWidth = 1
    $regularTotal = [decimal]0
    foreach ($n in $names) {
        $s = Get-InputStatus $n
        if ($null -eq $s) { continue }
        if ($s.Regular) { $regularTotal += $s.Size } else { $minimumWidth = 7 }
    }
    while ($regularTotal -ge 10) {
        $regularTotal = [decimal]::Truncate($regularTotal / 10)
        $NumberWidth++
    }
    if ($NumberWidth -lt $minimumWidth) { $NumberWidth = $minimumWidth }
}

function Format-Counts($st, $label) {
    $fields = New-Object System.Collections.Generic.List[string]
    if ($DoLines)   { $fields.Add($st.Lines.ToString().PadLeft($NumberWidth)) }
    if ($DoWords)   { $fields.Add($st.Words.ToString().PadLeft($NumberWidth)) }
    if ($DoChars)   { $fields.Add($st.Chars.ToString().PadLeft($NumberWidth)) }
    if ($DoBytes)   { $fields.Add($st.Bytes.ToString().PadLeft($NumberWidth)) }
    if ($DoMaxLine) { $fields.Add($st.MaxLine.ToString().PadLeft($NumberWidth)) }
    $line = $fields -join ' '
    if ($null -ne $label) {
        if ($label.Contains("`n")) { $label = Format-Quoted $label $false }
        $line += ' ' + $label
    }
    return $line
}

$total = New-Counter
$argsSeen = 0
foreach ($name in $names) {
    $argsSeen++
    $st = New-Counter

    if ($null -ne $Files0From -and $Files0From -eq '-' -and $name -eq '-') {
        Write-Diag "when reading file names from stdin, no file name of '-' allowed"
        $ExitStatus = 1
        continue
    }
    if ($null -ne $name -and $name -eq '') {
        if ($null -eq $Files0From) {
            Write-Diag 'invalid zero-length file name'
        } else {
            Write-Diag ((Format-Quoted $Files0From $false) + ':' + $argsSeen + ': invalid zero-length file name')
        }
        $ExitStatus = 1
        continue
    }

    if ($null -eq $name -or $name -eq '-') {
        try {
            Read-StdinInto $st
            $ok = $true
        } catch {
            $label = '-'
            if ($null -ne $name) { $label = $name }
            Write-Diag ((Format-Quoted $label $false) + ': ' + (Get-ErrnoText $_.Exception))
            $ok = $false
        }
    } else {
        $ok = Read-FileInto $st $name
        if ($null -eq $ok) { $ExitStatus = 1; continue }   # could not open: no counts line
    }
    if (-not $ok) { $ExitStatus = 1 }
    Complete-Counter $st

    if ($TotalMode -ne 'only') { Format-Counts $st $name }

    $total.Lines += $st.Lines
    $total.Words += $st.Words
    $total.Chars += $st.Chars
    $total.Bytes += $st.Bytes
    if ($st.MaxLine -gt $total.MaxLine) { $total.MaxLine = $st.MaxLine }
}

if ($TotalMode -ne 'never' -and ($TotalMode -ne 'auto' -or $argsSeen -gt 1)) {
    if ($TotalMode -eq 'only') { Format-Counts $total $null }
    else { Format-Counts $total 'total' }
}

exit $ExitStatus
