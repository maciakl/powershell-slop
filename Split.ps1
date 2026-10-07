<#
.SYNOPSIS
    split - split a file into pieces.

.DESCRIPTION
    A self-contained PowerShell port of the POSIX / GNU coreutils split
    utility.  Runs on Windows PowerShell 5.1 and PowerShell 7+ with no
    dependencies.

    Usage: Split.ps1 [OPTION]... [FILE [PREFIX]]

    Output pieces of FILE to PREFIXaa, PREFIXab, ...; default size is 1000
    lines, and default PREFIX is 'x'.  With no FILE, or when FILE is -, read
    standard input.

      -a, --suffix-length=N   generate suffixes of length N (default 2)
          --additional-suffix=SUFFIX  append an additional SUFFIX to file names
      -b, --bytes=SIZE        put SIZE bytes per output file
      -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file
      -d                      use numeric suffixes starting at 0, not alphabetic
          --numeric-suffixes[=FROM]  same as -d, but allow setting the start value
      -x                      use hex suffixes starting at 0, not alphabetic
          --hex-suffixes[=FROM]  same as -x, but allow setting the start value
      -e, --elide-empty-files  do not generate empty output files with '-n'
          --filter=COMMAND    write to PowerShell COMMAND; file name is $env:FILE
      -l, --lines=NUMBER      put NUMBER lines/records per output file
      -n, --number=CHUNKS     generate CHUNKS output files
      -t, --separator=SEP     use SEP instead of newline as the record separator
      -u, --unbuffered        immediately copy input to output with '-n r/...'
          --verbose           print a diagnostic just before each output file
                                is opened
          --help              display this help and exit
          --version           output version information and exit

    Run "Split.ps1 --help" for the full usage text.

.NOTES
    PowerShell-specific behavior:
    * Objects piped in from PowerShell (e.g. Get-Content x | .\Split.ps1) are
      treated as standard input: each string becomes one line (UTF-8 encoded,
      terminated by LF); [byte] and [byte[]] items are copied as raw bytes.
    * When run via "powershell -File Split.ps1 < file", standard input is read
      as raw bytes, exactly like the native utility.
    * --filter runs COMMAND with the PowerShell that is running this script
      (powershell.exe or pwsh).  The output file name is in $env:FILE and the
      data arrives on the command's standard input (as text lines through
      the automatic input variable, or as raw bytes through
      [Console]::OpenStandardInput()).
    * Output of K/N and r/K/N chunk extraction (and --verbose messages) goes to
      the PowerShell pipeline as lines of text, unless standard output is
      redirected at the process level, in which case raw bytes are written.
    * PowerShell itself consumes a bare "--" argument before the script sees
      it, so "--" is only honored when PowerShell passes it through.
    * Windows shells do not expand wildcards, so operands containing *, ? or
      [...] that do not name an existing file are expanded the way a POSIX
      shell would before split sees them.
#>

# NOTE: no param() block on purpose - every argument (including things like
# "-l100" or "--number=l/3") must reach $args untouched so that it can be
# parsed with GNU getopt_long semantics below.

$script:ProgName = 'split'
$script:VersionText = '1.0.0'

# ---------------------------------------------------------------------------
# Diagnostics and quoting (mirrors gnulib quotearg shell-escape styles)
# ---------------------------------------------------------------------------

function Write-Diag([string]$Message) {
    [Console]::Error.WriteLine($script:ProgName + ': ' + $Message)
}

function Write-TryHelp {
    [Console]::Error.WriteLine("Try '" + $script:ProgName + " --help' for more information.")
}

function Exit-Usage([string]$Message) {
    Write-Diag $Message
    Write-TryHelp
    exit 1
}

function Exit-Fatal([string]$Message) {
    Write-Diag $Message
    exit 1
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
    while (($e -is [System.Management.Automation.MethodInvocationException] -or
            $e -is [System.Management.Automation.RuntimeException]) -and $e.InnerException) {
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
        206 { return 'File name too long' }          # ERROR_FILENAME_EXCED_RANGE
        32  { return 'Device or resource busy' }     # ERROR_SHARING_VIOLATION
        33  { return 'Device or resource busy' }     # ERROR_LOCK_VIOLATION
        21  { return 'No such device' }              # ERROR_NOT_READY
        23  { return 'Input/output error' }          # ERROR_CRC
        39  { return 'No space left on device' }     # ERROR_HANDLE_DISK_FULL
        112 { return 'No space left on device' }     # ERROR_DISK_FULL
    }
    return $e.Message.TrimEnd()
}

# ---------------------------------------------------------------------------
# Help / version
# ---------------------------------------------------------------------------

function Show-Usage {
    $p = $script:ProgName
    @"
Usage: $p [OPTION]... [FILE [PREFIX]]
Output pieces of FILE to PREFIXaa, PREFIXab, ...;
default size is 1000 lines, and default PREFIX is 'x'.

With no FILE, or when FILE is -, read standard input.

Mandatory arguments to long options are mandatory for short options too.
  -a, --suffix-length=N   generate suffixes of length N (default 2)
      --additional-suffix=SUFFIX  append an additional SUFFIX to file names
  -b, --bytes=SIZE        put SIZE bytes per output file
  -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file
  -d                      use numeric suffixes starting at 0, not alphabetic
      --numeric-suffixes[=FROM]  same as -d, but allow setting the start value
  -x                      use hex suffixes starting at 0, not alphabetic
      --hex-suffixes[=FROM]  same as -x, but allow setting the start value
  -e, --elide-empty-files  do not generate empty output files with '-n'
      --filter=COMMAND    write to PowerShell COMMAND; file name is `$env:FILE
  -l, --lines=NUMBER      put NUMBER lines/records per output file
  -n, --number=CHUNKS     generate CHUNKS output files; see explanation below
  -t, --separator=SEP     use SEP instead of newline as the record separator;
                            '\0' (zero) specifies the NUL character
  -u, --unbuffered        immediately copy input to output with '-n r/...'
      --verbose           print a diagnostic just before each
                            output file is opened
      --help        display this help and exit
      --version     output version information and exit

The SIZE argument is an integer and optional unit (example: 10K is 10*1024).
Units are K,M,G,T,P,E,Z,Y,R,Q (powers of 1024) or KB,MB,... (powers of 1000).
Binary prefixes can be used, too: KiB=K, MiB=M, and so on.

CHUNKS may be:
  N       split into N files based on size of input
  K/N     output Kth of N to stdout
  l/N     split into N files without splitting lines/records
  l/K/N   output Kth of N to stdout without splitting lines/records
  r/N     like 'l' but use round robin distribution
  r/K/N   likewise but only output Kth of N to stdout
"@ -split "`r?`n"
}

function Show-Version {
    "$($script:ProgName) (PowerShell port) $($script:VersionText)"
    'A self-contained PowerShell port of the POSIX/GNU split utility.'
    'This is free software: you are free to change and redistribute it.'
    'There is NO WARRANTY, to the extent permitted by law.'
}

# ---------------------------------------------------------------------------
# Number parsing (gnulib xstrtoimax with multiplier suffixes)
# ---------------------------------------------------------------------------

$IntMax = [decimal][long]::MaxValue
$IntMin = [decimal][long]::MinValue
$Multipliers = 'bEGKkMmPQRTYZ0'

# Returns @{ Status; Value; End }.  Status is one of
#   ok, overflow          - the whole string was a valid number
#   suffix, suffixover    - parsing stopped at an invalid character (End)
#   invalid               - no number at all
function ConvertFrom-IntMax([string]$s, [string]$valid) {
    $p = 0
    while ($p -lt $s.Length -and " `t`n`r`f`v".IndexOf($s[$p]) -ge 0) { $p++ }
    $neg = $false
    if ($p -lt $s.Length -and ($s[$p] -eq '-' -or $s[$p] -eq '+')) { $neg = $s[$p] -eq '-'; $p++ }
    $digStart = $p
    $val = [decimal]0
    $over = $false
    while ($p -lt $s.Length -and $s[$p] -ge '0' -and $s[$p] -le '9') {
        if (-not $over) {
            $val = $val * 10 + ([int]$s[$p] - 48)
            if ($val -gt $IntMax) { $over = $true }
        }
        $p++
    }
    if ($p -eq $digStart) {
        # No digits: a lone valid suffix letter stands for 1 (e.g. "K").
        if ($valid -and $s.Length -gt 0 -and $valid.IndexOf($s[0]) -ge 0) {
            $p = 0; $val = [decimal]1; $neg = $false
        } else {
            return @{ Status = 'invalid'; Value = [decimal]0; End = 0 }
        }
    }
    if ($over) { $val = $IntMax }

    if ($p -lt $s.Length) {
        $ch = [string]$s[$p]
        if (-not $valid -or $valid.IndexOf($ch) -lt 0) {
            if ($over) { $st = 'suffixover' } else { $st = 'suffix' }
            return @{ Status = $st; Value = $val; End = $p }
        }
        $base = 1024
        $suffixes = 1
        if ($valid.IndexOf('0') -ge 0 -and $p + 1 -lt $s.Length) {
            switch -CaseSensitive ([string]$s[$p + 1]) {
                'i' { if ($p + 2 -lt $s.Length -and $s[$p + 2] -ceq 'B') { $suffixes += 2 } }
                'B' { $base = 1000; $suffixes++ }
                'D' { $base = 1000; $suffixes++ }
            }
        }
        $factor = 1; $power = 0
        switch -CaseSensitive ($ch) {
            'b' { $factor = 512 }
            'B' { $factor = 1024 }
            'c' { $factor = 1 }
            'w' { $factor = 2 }
            'k' { $power = 1 } 'K' { $power = 1 }
            'M' { $power = 2 } 'm' { $power = 2 }
            'G' { $power = 3 } 'g' { $power = 3 }
            'T' { $power = 4 } 't' { $power = 4 }
            'P' { $power = 5 }
            'E' { $power = 6 }
            'Z' { $power = 7 }
            'Y' { $power = 8 }
            'R' { $power = 9 }
            'Q' { $power = 10 }
            default {
                if ($over) { $st = 'suffixover' } else { $st = 'suffix' }
                return @{ Status = $st; Value = $val; End = $p }
            }
        }
        $steps = @()
        if ($factor -ne 1) { $steps += $factor }
        for ($k = 0; $k -lt $power; $k++) { $steps += $base }
        foreach ($m in $steps) {
            if ($val -gt [decimal]::Truncate($IntMax / $m)) { $over = $true; $val = $IntMax; break }
            $val *= $m
        }
        $p += $suffixes
        if ($p -lt $s.Length) {
            if ($over) { $st = 'suffixover' } else { $st = 'suffix' }
            return @{ Status = $st; Value = $val; End = $p }
        }
    }
    if ($neg) {
        if ($over) { $val = $IntMin } else { $val = -$val }
    }
    if ($over) { return @{ Status = 'overflow'; Value = $val; End = $p } }
    return @{ Status = 'ok'; Value = $val; End = $p }
}

# A count of units that must be at least 1; overflow saturates.
function ConvertTo-UnitCount([string]$arg, [string]$valid, [string]$what) {
    $r = ConvertFrom-IntMax $arg $valid
    if (($r.Status -ne 'ok' -and $r.Status -ne 'overflow') -or $r.Value -lt 1) {
        Exit-Fatal ($what + ': ' + (Format-Quoted $arg $true))
    }
    return [long]$r.Value
}

# xdectoimax: a number in [min, max], with errno-style diagnostics.
function ConvertTo-BoundedInt([string]$arg, [decimal]$min, [decimal]$max, [string]$valid, [string]$what) {
    $r = ConvertFrom-IntMax $arg $valid
    $msg = $what + ': ' + (Format-Quoted $arg $true)
    if ($r.Status -eq 'overflow') { Exit-Fatal ($msg + ': Value too large for defined data type') }
    if ($r.Status -ne 'ok') { Exit-Fatal $msg }
    if ($r.Value -lt $min -or $r.Value -gt $max) { Exit-Fatal $msg }
    return [long]$r.Value
}

# ---------------------------------------------------------------------------
# Option parsing (GNU getopt_long semantics, including argument permutation,
# bundled short options and unambiguous long-option abbreviations)
# ---------------------------------------------------------------------------

$script:SplitType = 'undef'      # lines, digits, bytes, byteslines, chunk_bytes, chunk_lines, rr
$script:NUnits = [long]0
$script:KUnits = [long]0
$script:SuffixLength = [long]0
$script:SuffixAuto = $true
$script:Alphabet = 'abcdefghijklmnopqrstuvwxyz'
$script:NumericStart = $null
$script:AdditionalSuffix = ''
$script:ElideEmpty = $false
$script:Unbuffered = $false
$script:Verbose = $false
$script:FilterCommand = $null
$script:EolChar = -1
$script:BufSize = 1MB
$script:DigitsArgIndex = -1

# Same order as the long_options table of GNU split (used for ambiguity reports).
$LongOptions = @(
    @{ Name = 'bytes';             Arg = 'required' },
    @{ Name = 'lines';             Arg = 'required' },
    @{ Name = 'line-bytes';        Arg = 'required' },
    @{ Name = 'number';            Arg = 'required' },
    @{ Name = 'elide-empty-files'; Arg = 'none' },
    @{ Name = 'unbuffered';        Arg = 'none' },
    @{ Name = 'suffix-length';     Arg = 'required' },
    @{ Name = 'additional-suffix'; Arg = 'required' },
    @{ Name = 'numeric-suffixes';  Arg = 'optional' },
    @{ Name = 'hex-suffixes';      Arg = 'optional' },
    @{ Name = 'filter';            Arg = 'required' },
    @{ Name = 'verbose';           Arg = 'none' },
    @{ Name = 'separator';         Arg = 'required' },
    @{ Name = '-io-blksize';       Arg = 'required' },
    @{ Name = 'help';              Arg = 'none' },
    @{ Name = 'version';           Arg = 'none' }
)

function Set-SplitType([string]$type) {
    if ($script:SplitType -ne 'undef') { Exit-Usage 'cannot split in more than one way' }
    $script:SplitType = $type
}

function Set-ChunkSpec([string]$arg) {
    $spec = $arg.TrimStart(" `t`n`r`f`v".ToCharArray())
    if ($spec.StartsWith('r/')) { Set-SplitType 'rr'; $spec = $spec.Substring(2) }
    elseif ($spec.StartsWith('l/')) { Set-SplitType 'chunk_lines'; $spec = $spec.Substring(2) }
    else { Set-SplitType 'chunk_bytes' }

    $r = ConvertFrom-IntMax $spec ''
    if ($r.Status -eq 'suffix' -and $spec[$r.End] -eq '/') {
        $k = $r.Value
        $n = ConvertTo-UnitCount $spec.Substring($r.End + 1) '' 'invalid number of chunks'
        if (-not (0 -lt $k -and $k -le $n)) {
            Exit-Fatal ('invalid chunk number: ' + (Format-Quoted $spec.Substring(0, $r.End) $true))
        }
        $script:KUnits = [long]$k
        $script:NUnits = $n
    } elseif (($r.Status -eq 'ok' -or $r.Status -eq 'overflow') -and $r.Value -gt 0) {
        $script:NUnits = [long]$r.Value
    } else {
        Exit-Fatal ('invalid number of chunks: ' + (Format-Quoted $spec $true))
    }
}

function Set-SuffixAlphabet([char]$c, $value) {
    if ($c -eq 'd') { $script:Alphabet = '0123456789' } else { $script:Alphabet = '0123456789abcdef' }
    if ($null -ne $value) {
        $ok = $true
        foreach ($ch in $value.ToCharArray()) {
            if ($script:Alphabet.IndexOf($ch) -lt 0) { $ok = $false; break }
        }
        if (-not $ok) {
            if ($c -eq 'd') { $kind = 'numerical' } else { $kind = 'hexadecimal' }
            Exit-Usage ((Format-Quoted $value $true) + ': invalid start value for ' + $kind + ' suffix')
        }
        # Skip any leading zero.
        $v = $value
        while ($v.Length -gt 1 -and $v[0] -eq '0') { $v = $v.Substring(1) }
        $script:NumericStart = $v
    }
}

function Invoke-Option([string]$name, $value, [int]$argIndex) {
    switch -CaseSensitive ($name) {
        'a' {
            $script:SuffixLength = ConvertTo-BoundedInt $value 0 $IntMax '' 'invalid suffix length'
        }
        'additional-suffix' {
            if ($value -match '[\\/]') {
                Exit-Usage ('invalid suffix ' + (Format-Quoted $value $true) + ', contains directory separator')
            }
            $script:AdditionalSuffix = $value
        }
        'b' {
            Set-SplitType 'bytes'
            $script:NUnits = ConvertTo-UnitCount $value $Multipliers 'invalid number of bytes'
        }
        'l' {
            Set-SplitType 'lines'
            $script:NUnits = ConvertTo-UnitCount $value '' 'invalid number of lines'
        }
        'C' {
            Set-SplitType 'byteslines'
            $script:NUnits = ConvertTo-UnitCount $value $Multipliers 'invalid number of bytes'
        }
        'n' { Set-ChunkSpec $value }
        'u' { $script:Unbuffered = $true }
        't' {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$value)
            if ($bytes.Length -eq 0) { Exit-Fatal 'empty record separator' }
            $newEol = [int]$bytes[0]
            if ($bytes.Length -gt 1) {
                if ($value -ceq '\0') { $newEol = 0 }
                else { Exit-Fatal ('multi-character separator ' + (Format-Quoted $value $true)) }
            }
            if ($script:EolChar -ge 0 -and $newEol -ne $script:EolChar) {
                Exit-Fatal 'multiple separator characters specified'
            }
            $script:EolChar = $newEol
        }
        'd' { Set-SuffixAlphabet 'd' $value }
        'x' { Set-SuffixAlphabet 'x' $value }
        'e' { $script:ElideEmpty = $true }
        'filter' { $script:FilterCommand = [string]$value }
        'verbose' { $script:Verbose = $true }
        '-io-blksize' {
            $script:BufSize = [int](ConvertTo-BoundedInt $value 1 0x7FFFF000 $Multipliers 'invalid IO block size')
        }
        'help' { Show-Usage; exit 0 }
        'version' { Show-Version; exit 0 }
        default {
            # Obsolete -NUM option: the digits of one argument form a line count.
            if ($script:SplitType -eq 'undef') { $script:SplitType = 'digits'; $script:NUnits = 0 }
            if ($script:SplitType -ne 'digits') { Exit-Usage 'cannot split in more than one way' }
            if ($script:DigitsArgIndex -ne -1 -and $script:DigitsArgIndex -ne $argIndex) { $script:NUnits = 0 }
            $script:DigitsArgIndex = $argIndex
            $d = [decimal]$script:NUnits * 10 + [int]$name
            if ($d -gt $IntMax) { $d = $IntMax }
            $script:NUnits = [long]$d
        }
    }
}

$LongToShort = @{
    'bytes' = 'b'; 'lines' = 'l'; 'line-bytes' = 'C'; 'number' = 'n'
    'elide-empty-files' = 'e'; 'unbuffered' = 'u'; 'suffix-length' = 'a'
    'numeric-suffixes' = 'd'; 'hex-suffixes' = 'x'; 'separator' = 't'
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
    $argIndex = $i
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
                Exit-Usage ("option '" + $arg.Split('=')[0] + "' is ambiguous; possibilities: " + $poss)
            } else {
                Exit-Usage ("unrecognized option '" + $arg + "'")
            }
        }
        if ($opt.Arg -eq 'none' -and $null -ne $optValue) {
            Exit-Usage ("option '--" + $opt.Name + "' doesn't allow an argument")
        }
        if ($opt.Arg -eq 'required' -and $null -eq $optValue) {
            if ($i -lt $argv.Count) { $optValue = $argv[$i]; $i++ }
            else { Exit-Usage ("option '--" + $opt.Name + "' requires an argument") }
        }
        $short = $LongToShort[$opt.Name]
        if (-not $short) { $short = $opt.Name }
        Invoke-Option $short $optValue $argIndex
        continue
    }

    # Bundled short options: -del5, -l100, -100
    for ($j = 1; $j -lt $arg.Length; $j++) {
        $c = [string]$arg[$j]
        # Short options as in getopt "0123456789C:a:b:del:n:t:ux".
        if ($c -cmatch '^[Cablnt]$') {
            if ($j + 1 -lt $arg.Length) { $optValue = $arg.Substring($j + 1) }
            elseif ($i -lt $argv.Count) { $optValue = $argv[$i]; $i++ }
            else { Exit-Usage ("option requires an argument -- '" + $c + "'") }
            Invoke-Option $c $optValue $argIndex
            break
        }
        if ($c -cmatch '^[dexu0-9]$') {
            Invoke-Option $c $null $argIndex
            continue
        }
        Exit-Usage ("invalid option -- '" + $c + "'")
    }
}

# ---------------------------------------------------------------------------
# Validation (same order and messages as GNU split)
# ---------------------------------------------------------------------------

if ($KUnits -ne 0 -and $null -ne $FilterCommand) {
    Exit-Usage '--filter does not process a chunk extracted to stdout'
}

if ($SplitType -eq 'undef') {
    $SplitType = 'lines'
    $NUnits = [long]1000
}

if ($NUnits -eq 0) {
    Exit-Usage "invalid number of lines: '0'"
}

if ($EolChar -lt 0) { $EolChar = 10 }
$Eol = [byte]$EolChar

# set_suffix_length(): choose a suffix length able to name every chunk.
$suffixNeeded = 0
if ($null -ne $NumericStart) { $SuffixAuto = $false }
if ($SplitType -eq 'chunk_bytes' -or $SplitType -eq 'chunk_lines' -or $SplitType -eq 'rr') {
    $unitsEnd = [decimal]$NUnits - 1
    if ($null -ne $NumericStart) {
        $ns = ConvertFrom-IntMax $NumericStart ''
        if ($ns.Status -eq 'ok' -and $ns.Value -lt $NUnits) {
            $unitsEnd += $ns.Value
            if ($unitsEnd -gt $IntMax) { $unitsEnd = $IntMax }
        }
    }
    do {
        $suffixNeeded++
        $unitsEnd = [decimal]::Truncate($unitsEnd / $Alphabet.Length)
    } while ($unitsEnd -ne 0)
    $SuffixAuto = $false
}
if ($SuffixLength -gt 0) {
    if ($SuffixLength -lt $suffixNeeded) {
        Exit-Fatal ("the suffix length needs to be at least " + $suffixNeeded)
    }
    $SuffixAuto = $false
} else {
    $SuffixLength = [Math]::Max(2, $suffixNeeded)
}

# --- shell-style wildcard expansion (Windows shells do not glob) -------------

function Resolve-FsPath([string]$name) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($name)
}

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

$expanded = New-Object System.Collections.Generic.List[string]
foreach ($op in $operands) {
    foreach ($n in (Expand-Operand $op)) { $expanded.Add($n) }
}

$InFile = '-'
$OutBase = 'x'
if ($expanded.Count -gt 0) { $InFile = $expanded[0] }
if ($expanded.Count -gt 1) { $OutBase = $expanded[1] }
if ($expanded.Count -gt 2) {
    Exit-Usage ('extra operand ' + (Format-Quoted $expanded[2] $true))
}

if ($null -ne $NumericStart -and $NumericStart.Length -gt $SuffixLength) {
    Exit-Usage 'numerical suffix start value is too large for the suffix length'
}

# ---------------------------------------------------------------------------
# Standard output: raw bytes when the process's stdout is redirected and this
# script's output is not captured by PowerShell, otherwise pipeline lines.
# ---------------------------------------------------------------------------

$Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Invocation = $MyInvocation

# True when this script's output would reach the process's stdout untouched
# by PowerShell: it is the -File entry point, or a top-level command typed at
# the host that is not piped, redirected, assigned or otherwise captured.
function Test-UncapturedTopLevel([System.Management.Automation.InvocationInfo]$Info) {
    if ($Info.CommandOrigin -ne 'Runspace') { return $false }
    if ([string]::IsNullOrEmpty($Info.Line)) { return $true }   # powershell -File
    if ($Info.PipelinePosition -ne $Info.PipelineLength) { return $false }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Info.Line, [ref]$tokens, [ref]$errors)
    $offset = $Info.OffsetInLine - 1
    $cmd = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.Extent.StartOffset -eq $offset
    }, $true)
    if ($null -eq $cmd -or $cmd.Redirections.Count -gt 0) { return $false }
    $parent = $cmd.Parent
    if ($parent -isnot [System.Management.Automation.Language.PipelineAst] -or $parent.PipelineElements.Count -ne 1) {
        return $false
    }
    $node = $parent.Parent
    while ($null -ne $node) {
        if ($node -isnot [System.Management.Automation.Language.NamedBlockAst] -and
            $node -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
            return $false
        }
        $node = $node.Parent
    }
    return $true
}

$script:RawOut = $null
try {
    if ([Console]::IsOutputRedirected -and (Test-UncapturedTopLevel $script:Invocation)) {
        $script:RawOut = [Console]::OpenStandardOutput()
    }
} catch { $script:RawOut = $null }
$script:OutPend = New-Object System.IO.MemoryStream

# NOTE: functions that can write to the pipeline (directly or through the
# functions they call) are only ever invoked as statements, never inside an
# expression or assignment, so that their output is not captured by mistake.

function Write-StdoutRaw([byte[]]$buf, [int]$off, [int]$count) {
    try {
        $script:RawOut.Write($buf, $off, $count)
        if ($script:Unbuffered) { $script:RawOut.Flush() }
    } catch {
        # The reader went away (EPIPE): stop quietly.
        exit 1
    }
}

function Write-StdoutBytes([byte[]]$buf, [int]$off, [int]$count) {
    if ($count -le 0) { return }
    if ($null -ne $script:RawOut) { Write-StdoutRaw $buf $off $count; return }
    $ms = $script:OutPend
    $ms.Write($buf, $off, $count)
    $len = [int]$ms.Length
    $data = $ms.GetBuffer()
    $last = [Array]::LastIndexOf($data, $Eol, $len - 1, $len)
    if ($last -lt 0) { return }
    $text = $Utf8.GetString($data, 0, $last)
    $rest = $len - $last - 1
    $tail = New-Object byte[] $rest
    [Array]::Copy($data, $last + 1, $tail, 0, $rest)
    $ms.SetLength(0)
    $ms.Write($tail, 0, $rest)
    foreach ($line in $text.Split([char]$Eol)) {
        if ($Eol -eq 10 -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        Write-Output $line
    }
}

function Write-StdoutText([string]$text) {
    if ($null -ne $script:RawOut) {
        $b = $Utf8.GetBytes($text + "`n")
        Write-StdoutRaw $b 0 $b.Length
    } else {
        Write-Output $text
    }
}

function Complete-Stdout {
    if ($null -ne $script:RawOut) {
        try { $script:RawOut.Flush() } catch { exit 1 }
        return
    }
    if ($script:OutPend.Length -gt 0) {
        $line = $Utf8.GetString($script:OutPend.GetBuffer(), 0, [int]$script:OutPend.Length)
        if ($Eol -eq 10 -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
        $script:OutPend.SetLength(0)
        Write-Output $line
    }
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

# Pipeline input from PowerShell is used as stdin, except when the host runs
# us via "-File" (then $MyInvocation.Line is empty and real stdin is raw).
# The automatic input variable is fetched by name on purpose: if the script
# text mentions it literally, "pwsh -File" pre-reads stdin as text lines and
# the raw bytes are lost.
$script:PipeEnum = $null
$script:InStream = $null
$script:InPath = $null
$script:Pend = $null
$script:PendPos = 0

if ($InFile -eq '-') {
    if ($MyInvocation.ExpectingInput -and $MyInvocation.Line) {
        $pipe = $ExecutionContext.SessionState.PSVariable.GetValue('input')
        if ($pipe -isnot [System.Collections.IEnumerator]) { $pipe = @($pipe).GetEnumerator() }
        $script:PipeEnum = $pipe
    } else {
        $script:InStream = [Console]::OpenStandardInput()
    }
} else {
    try {
        $path = Resolve-FsPath $InFile
    } catch {
        Exit-Fatal ('cannot open ' + (Format-Quoted $InFile $true) + ' for reading: ' + (Get-ErrnoText $_.Exception))
    }
    if ([System.IO.Directory]::Exists($path)) {
        Exit-Fatal ((Format-Quoted $InFile $false) + ': Is a directory')
    }
    try {
        $script:InStream = New-Object System.IO.FileStream ($path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete), 4096)
    } catch {
        Exit-Fatal ('cannot open ' + (Format-Quoted $InFile $true) + ' for reading: ' + (Get-ErrnoText $_.Exception))
    }
    $script:InPath = [System.IO.Path]::GetFullPath($path)
}

function ConvertTo-InputBytes($item) {
    if ($item -is [byte[]]) { return , $item }
    if ($item -is [byte]) { return , ([byte[]]@($item)) }
    if ($item -is [System.Array]) {
        # Arrays arrive e.g. from "Get-Content -Encoding Byte -ReadCount 0".
        $ms = New-Object System.IO.MemoryStream
        foreach ($element in $item) {
            if ($null -eq $element) { continue }
            $b = ConvertTo-InputBytes $element
            $ms.Write($b, 0, $b.Length)
        }
        return , $ms.ToArray()
    }
    return , $Utf8.GetBytes([string]$item + "`n")
}

# read(): returns the number of bytes stored in $buf (0 at end of input).
function Read-Input([byte[]]$buf, [int]$off, [int]$count) {
    if ($null -ne $script:InStream) {
        try {
            return $script:InStream.Read($buf, $off, $count)
        } catch {
            Exit-Fatal ((Format-Quoted $InFile $false) + ': ' + (Get-ErrnoText $_.Exception))
        }
    }
    $got = 0
    while ($got -lt $count) {
        if ($null -eq $script:Pend -or $script:PendPos -ge $script:Pend.Length) {
            if (-not $script:PipeEnum.MoveNext()) { break }
            $item = $script:PipeEnum.Current
            if ($null -eq $item) { $script:Pend = $null; continue }
            $script:Pend = ConvertTo-InputBytes $item
            $script:PendPos = 0
            continue
        }
        $take = [Math]::Min($count - $got, $script:Pend.Length - $script:PendPos)
        [Array]::Copy($script:Pend, $script:PendPos, $buf, $off + $got, $take)
        $script:PendPos += $take
        $got += $take
    }
    return $got
}

# Input size for the -n modes.  Input that cannot be seeked (a pipe or the
# PowerShell pipeline) is first copied to a temporary file.
function Get-InputSize {
    $s = $script:InStream
    if ($s -is [System.IO.FileStream] -and $s.CanSeek) {
        return [long]($s.Length - $s.Position)
    }
    $tmpName = [System.IO.Path]::GetTempFileName()
    try {
        $tmp = New-Object System.IO.FileStream ($tmpName, [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096,
            [System.IO.FileOptions]::DeleteOnClose)
    } catch {
        Exit-Fatal ((Format-Quoted $InFile $false) + ': cannot determine file size')
    }
    while ($true) {
        $n = Read-Input $Buf 0 $Buf.Length
        if ($n -le 0) { break }
        $tmp.Write($Buf, 0, $n)
    }
    $tmp.Position = 0
    $script:InStream = $tmp
    $script:PipeEnum = $null
    return [long]$tmp.Length
}

# ---------------------------------------------------------------------------
# Output file names
# ---------------------------------------------------------------------------

$script:OutFile = $null
$script:NameStarted = $false
$script:BaseCur = $null
$script:SufIdx = $null
$script:Mid = $null

function Update-OutFile {
    $script:OutFile = $script:BaseCur + (New-Object string (, $script:Mid)) + $AdditionalSuffix
}

# next_file_name(): advance to the next output file name, widening the suffix
# when the alphabet runs out (xyz -> xzaaa) unless its length was fixed.
function Step-FileName {
    if ($null -eq $script:OutFile) {
        if (-not $script:NameStarted) {
            $script:BaseCur = $OutBase
            $script:NameStarted = $true
        } else {
            # Subsume the unchanging part of the suffix into the base.
            $script:BaseCur += $Alphabet[$script:SufIdx[0]]
            $script:SuffixLength++
        }
        $len = [int]$script:SuffixLength
        $script:SufIdx = New-Object int[] $len
        $script:Mid = New-Object char[] $len
        for ($k = 0; $k -lt $len; $k++) { $script:Mid[$k] = $Alphabet[0] }
        if ($null -ne $NumericStart) {
            $L = $NumericStart.Length
            for ($k = 0; $k -lt $L; $k++) {
                $pos = $len - $L + $k
                $script:Mid[$pos] = $NumericStart[$k]
                $script:SufIdx[$pos] = $Alphabet.IndexOf($NumericStart[$k])
            }
        }
        Update-OutFile
        return
    }
    $k = [int]$script:SuffixLength
    while ($k-- -ne 0) {
        $script:SufIdx[$k]++
        if ($script:SuffixAuto -and $k -eq 0 -and $script:SufIdx[0] + 1 -ge $Alphabet.Length) {
            # Switch to a wider suffix.
            $script:OutFile = $null
            Step-FileName
            return
        }
        if ($script:SufIdx[$k] -lt $Alphabet.Length) {
            $script:Mid[$k] = $Alphabet[$script:SufIdx[$k]]
            Update-OutFile
            return
        }
        $script:SufIdx[$k] = 0
        $script:Mid[$k] = $Alphabet[0]
    }
    Exit-Fatal 'output file suffixes exhausted'
}

# ---------------------------------------------------------------------------
# Output sinks: a file, or a PowerShell process for --filter
# ---------------------------------------------------------------------------

$script:Cur = $null          # current sink
$script:NewSink = $null       # result of Open-Sink
$script:WriteOk = $true      # result of Write-Sink / Write-Chunk
$script:AllSinks = New-Object System.Collections.Generic.List[object]

function Get-FilterHost {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($IsWindows) { return Join-Path $PSHOME 'pwsh.exe' }
        return Join-Path $PSHOME 'pwsh'
    }
    return Join-Path $PSHOME 'powershell.exe'
}

# Creates the output for $name and stores it in $script:NewSink.
function Open-Sink([string]$name) {
    if ($null -eq $FilterCommand) {
        if ($script:Verbose) { Write-StdoutText ('creating file ' + (Format-Quoted $name $true)) }
        try {
            $path = [System.IO.Path]::GetFullPath((Resolve-FsPath $name))
        } catch {
            Exit-Fatal ((Format-Quoted $name $false) + ': ' + (Get-ErrnoText $_.Exception))
        }
        if ($null -ne $script:InPath -and
            [string]::Equals($path, $script:InPath, [StringComparison]::OrdinalIgnoreCase)) {
            Exit-Fatal ((Format-Quoted $name $true) + ' would overwrite input; aborting')
        }
        if ([System.IO.Directory]::Exists($path)) {
            Exit-Fatal ((Format-Quoted $name $false) + ': Is a directory')
        }
        try {
            $fs = New-Object System.IO.FileStream ($path, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 65536)
            if ($fs.Length -gt 0) { $fs.SetLength(0) }
        } catch {
            Exit-Fatal ((Format-Quoted $name $false) + ': ' + (Get-ErrnoText $_.Exception))
        }
        $sink = @{ Name = $name; Stream = $fs; Proc = $null; Broken = $false }
    } else {
        if ($script:Verbose) { Write-StdoutText ('executing with FILE=' + (Format-Quoted $name $false)) }
        $exe = Get-FilterHost
        $command = "`$ProgressPreference = 'SilentlyContinue'`n" + $FilterCommand
        $psi = New-Object System.Diagnostics.ProcessStartInfo $exe
        $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' +
            [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['FILE'] = $name
        try {
            $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
        } catch { }
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        } catch {
            Exit-Fatal ('failed to run command: "' + $exe + ' -Command ' + $FilterCommand + '": ' +
                (Get-ErrnoText $_.Exception))
        }
        $sink = @{ Name = $name; Stream = $proc.StandardInput.BaseStream; Proc = $proc; Broken = $false }
    }
    $script:AllSinks.Add($sink)
    $script:NewSink = $sink
}

# Writes to a sink; sets $script:WriteOk to $false when a filter has stopped
# reading (EPIPE, which is ignored like in GNU split).
function Write-Sink($sink, [byte[]]$buf, [int]$off, [long]$count) {
    $script:WriteOk = $true
    if ($count -le 0 -or $null -eq $buf) { return }
    if ($sink.Broken) { $script:WriteOk = $false; return }
    try {
        $sink.Stream.Write($buf, $off, [int]$count)
        if ($script:Unbuffered) { $sink.Stream.Flush() }
    } catch {
        if ($null -ne $sink.Proc) {
            $sink.Broken = $true
            $script:WriteOk = $false
            return
        }
        Exit-Fatal ((Format-Quoted $sink.Name $false) + ': ' + (Get-ErrnoText $_.Exception))
    }
}

function Close-Sink($sink) {
    if ($null -eq $sink -or $null -eq $sink.Stream) { return }
    $stream = $sink.Stream
    $sink.Stream = $null
    if ($null -eq $sink.Proc) {
        try { $stream.Dispose() } catch {
            Exit-Fatal ((Format-Quoted $sink.Name $false) + ': ' + (Get-ErrnoText $_.Exception))
        }
        return
    }
    try { $stream.Dispose() } catch { }
    $sink.Proc.WaitForExit()
    $code = $sink.Proc.ExitCode
    if ($code -ne 0) {
        Write-Diag ('with FILE=' + (Format-Quoted $sink.Name $false) + ', exit ' + $code +
            ' from command: ' + $FilterCommand)
        exit $code
    }
}

# cwrite(): write to the current output, first opening the next output file
# when $NewFile is set.  A $null buffer with $NewFile creates an empty file
# (skipped with --elide-empty-files).
function Write-Chunk([bool]$NewFile, [byte[]]$buf, [int]$off, [long]$count) {
    if ($NewFile) {
        if ($null -eq $buf -and $count -eq 0 -and $ElideEmpty) { $script:WriteOk = $true; return }
        Close-Sink $script:Cur
        $script:Cur = $null
        Step-FileName
        Open-Sink $script:OutFile
        $script:Cur = $script:NewSink
    }
    Write-Sink $script:Cur $buf $off $count
}

# ---------------------------------------------------------------------------
# Splitting
# ---------------------------------------------------------------------------

# -l / -NUM: NLINES records per output file.
function Split-Lines([long]$nLines) {
    $newFile = $true
    $n = [long]0
    while ($true) {
        $nRead = Read-Input $Buf 0 $BufSize
        if ($nRead -le 0) { break }
        $bp = 0
        $bpOut = 0
        while ($true) {
            $idx = [Array]::IndexOf($Buf, $Eol, $bp, $nRead - $bp)
            if ($idx -lt 0) {
                if ($nRead -ne $bpOut) {
                    Write-Chunk $newFile $Buf $bpOut ($nRead - $bpOut)
                    $newFile = $false
                }
                break
            }
            $bp = $idx + 1
            if (++$n -ge $nLines) {
                Write-Chunk $newFile $Buf $bpOut ($bp - $bpOut)
                $bpOut = $bp
                $newFile = $true
                $n = 0
            }
        }
    }
}

# -b SIZE (maxFiles = 0), or -n N (SIZE = size / N, the first size % N files
# get one extra byte, exactly maxFiles files are produced).
function Split-Bytes([long]$nBytes, [long]$remBytes, [long]$maxFiles) {
    $newFile = $true
    $filterOk = $true
    $opened = [long]0
    $toWrite = $nBytes + [int](0 -lt $remBytes)
    $eof = $toWrite -eq 0
    while (-not $eof) {
        $nRead = Read-Input $Buf 0 $BufSize
        $eof = $nRead -eq 0
        $bpOut = 0
        while (0 -lt $toWrite -and $toWrite -le $nRead) {
            if ($newFile -or $filterOk) {
                Write-Chunk $newFile $Buf $bpOut $toWrite
                $filterOk = $script:WriteOk
            }
            if ($newFile) { $opened++ }
            $newFile = ($maxFiles -eq 0) -or ($opened -lt $maxFiles)
            if (-not $newFile -and -not $filterOk) {
                # Filters no longer accept input: stop reading.
                $nRead = 0
                $eof = $true
                break
            }
            $bpOut += [int]$toWrite
            $nRead -= [int]$toWrite
            $toWrite = $nBytes + [int]($opened -lt $remBytes)
        }
        if (0 -lt $nRead) {
            if ($newFile -or $filterOk) {
                Write-Chunk $newFile $Buf $bpOut $nRead
                $filterOk = $script:WriteOk
            }
            if ($newFile) { $opened++ }
            $newFile = $false
            if (-not $filterOk -and $opened -eq $maxFiles) { break }
            $toWrite -= $nRead
        }
    }
    # Ensure exactly maxFiles files exist.
    if (-not $ElideEmpty) {
        while ($opened++ -lt $maxFiles) { Write-Chunk $true $null 0 0 }
    }
}

# -C SIZE: as many complete records as fit in SIZE bytes; records longer than
# SIZE are broken across files.
function Split-LineBytes([long]$nBytes) {
    $nOut = [long]0
    $hold = New-Object System.IO.MemoryStream
    $splitLine = $false
    while ($true) {
        $nRead = Read-Input $Buf 0 $BufSize
        if ($nRead -le 0) { break }
        $nLeft = [long]$nRead
        $sob = 0
        while ($nLeft -gt 0) {
            $splitRest = [long]0
            $eoc = $false
            $nHold = [long]$hold.Length
            if ($nBytes - $nOut - $nHold -le $nLeft) {
                # Enough data to fill this output file.
                $splitRest = $nBytes - $nOut - $nHold
                $eoc = $true
                $span = $splitRest
            } else {
                $span = $nLeft
            }
            $eolPos = -1
            if ($span -gt 0) { $eolPos = [Array]::LastIndexOf($Buf, $Eol, $sob + [int]$span - 1, [int]$span) }

            # Output hold space if possible.
            if ($nHold -gt 0 -and -not ($eolPos -lt 0 -and $nOut -gt 0)) {
                Write-Chunk ($nOut -eq 0) $hold.GetBuffer() 0 $nHold
                $nOut += $nHold
                $hold.SetLength(0)
            }
            # Output to end of line if present.
            if ($eolPos -ge 0) {
                $splitLine = $true
                $nWrite = $eolPos - $sob + 1
                Write-Chunk ($nOut -eq 0) $Buf $sob $nWrite
                $nOut += $nWrite
                $nLeft -= $nWrite
                $sob += $nWrite
                if ($eoc) { $splitRest -= $nWrite }
            }
            # Output to end of chunk or end of buffer if possible.
            if ($nLeft -gt 0 -and -not $splitLine) {
                if ($eoc) { $nWrite = $splitRest } else { $nWrite = $nLeft }
                Write-Chunk ($nOut -eq 0) $Buf $sob $nWrite
                $nOut += $nWrite
                $nLeft -= $nWrite
                $sob += [int]$nWrite
                if ($eoc) { $splitRest -= $nWrite }
            }
            # Update hold if needed.
            if (($eoc -and $splitRest -gt 0) -or (-not $eoc -and $nLeft -gt 0)) {
                if ($eoc) { $nBuf = $splitRest } else { $nBuf = $nLeft }
                $hold.Write($Buf, $sob, [int]$nBuf)
                $nLeft -= $nBuf
                $sob += [int]$nBuf
            }
            # Reset for new split.
            if ($eoc) {
                $nOut = 0
                $splitLine = $false
            }
        }
    }
    # Handle no eol at end of file.
    if ($hold.Length -gt 0) {
        Write-Chunk ($nOut -eq 0) $hold.GetBuffer() 0 $hold.Length
    }
}

# -n K/N: copy the Kth of N byte chunks to standard output.
function Export-ByteChunk([long]$k, [long]$n, [long]$fileSize) {
    $rem = [long]0
    $chunkSize = [Math]::DivRem($fileSize, $n, [ref]$rem)
    $start = ($k - 1) * $chunkSize + [Math]::Min($k - 1, $rem)
    if ($k -eq $n) { $end = $fileSize } else { $end = $k * $chunkSize + [Math]::Min($k, $rem) }
    $script:InStream.Position += $start
    while ($start -lt $end) {
        $nRead = Read-Input $Buf 0 ([int][Math]::Min([long]$BufSize, $end - $start))
        if ($nRead -le 0) { break }
        Write-StdoutBytes $Buf 0 $nRead
        $start += $nRead
    }
}

# -n l/N and l/K/N: N chunks of about size / N bytes each, where every chunk
# ends at the first record end at or after its last nominal byte.  A record
# that spans whole chunks leaves those chunks empty.
function Split-LineChunks([long]$k, [long]$n, [long]$fileSize) {
    $rem = [long]0
    $chunkSize = [Math]::DivRem($fileSize, $n, [ref]$rem)
    $c = [long]1
    $opened = $false
    $base = [long]0
    if ($k -gt 1 -and $fileSize -gt 0) {
        # Start at the last nominal byte of chunk K-1.
        $c = $k - 1
        $base = $c * $chunkSize + [Math]::Min($c, $rem) - 1
        $script:InStream.Position += $base
    }
    $cEnd = $c * $chunkSize + [Math]::Min($c, $rem)
    while ($base -lt $fileSize -and $c -le $n) {
        $nRead = Read-Input $Buf 0 ([int][Math]::Min([long]$BufSize, $fileSize - $base))
        if ($nRead -le 0) { break }
        $bp = 0
        while ($bp -lt $nRead -and $c -le $n) {
            $from = [long][Math]::Max($bp, $cEnd - 1 - $base)
            $idx = -1
            if ($from -lt $nRead) { $idx = [Array]::IndexOf($Buf, $Eol, [int]$from, $nRead - [int]$from) }
            if ($idx -ge 0) { $stop = $idx + 1 } else { $stop = $nRead }
            if ($k -eq 0) {
                Write-Chunk (-not $opened) $Buf $bp ($stop - $bp)
                $opened = $true
            } elseif ($k -eq $c) {
                Write-StdoutBytes $Buf $bp ($stop - $bp)
            }
            $bp = $stop
            if ($idx -lt 0) { continue }
            # Chunk $c is complete; skip chunks that ended before this point.
            if ($k -eq $c) { return }
            $c++
            $opened = $false
            $cEnd = $c * $chunkSize + [Math]::Min($c, $rem)
            while ($c -le $n -and $cEnd -le $base + $bp) {
                if ($k -eq 0) { Write-Chunk $true $null 0 0 }
                elseif ($k -eq $c) { return }
                $c++
                $cEnd = $c * $chunkSize + [Math]::Min($c, $rem)
            }
        }
        $base += $nRead
    }
    if ($k -eq 0) {
        if ($opened) { $c++ }
        while ($c -le $n) { Write-Chunk $true $null 0 0; $c++ }
    }
}

# -n r/N and r/K/N: distribute records round robin.
function Split-RoundRobin([long]$k, [long]$n) {
    $lineNo = [long]1
    $iFile = 0
    $wrapped = $false
    $wrote = $false
    if ($k -eq 0) {
        $names = New-Object string[] $n
        $sinks = New-Object object[] $n
        for ($f = 0; $f -lt $n; $f++) {
            Step-FileName
            $names[$f] = $script:OutFile
        }
    }
    :reading while ($true) {
        $nRead = Read-Input $Buf 0 $BufSize
        if ($nRead -le 0) { break }
        $bp = 0
        while ($bp -lt $nRead) {
            $idx = [Array]::IndexOf($Buf, $Eol, $bp, $nRead - $bp)
            if ($idx -ge 0) { $stop = $idx + 1; $next = $true } else { $stop = $nRead; $next = $false }
            if ($k -ne 0) {
                if ($lineNo -eq $k) { Write-StdoutBytes $Buf $bp ($stop - $bp) }
                if ($next) { if ($lineNo -eq $n) { $lineNo = 1 } else { $lineNo++ } }
            } else {
                $sink = $sinks[$iFile]
                if ($null -eq $sink) {
                    Open-Sink $names[$iFile]
                    $sink = $script:NewSink
                    $sinks[$iFile] = $sink
                }
                if ($null -eq $sink.Proc -and -not $script:Unbuffered) {
                    # Fast path for plain files (one call per record adds up).
                    try { $sink.Stream.Write($Buf, $bp, $stop - $bp) }
                    catch { Exit-Fatal ((Format-Quoted $sink.Name $false) + ': ' + (Get-ErrnoText $_.Exception)) }
                    $wrote = $true
                } else {
                    Write-Sink $sink $Buf $bp ($stop - $bp)
                    if ($script:WriteOk) { $wrote = $true }
                }
                if ($next -and ++$iFile -eq $n) {
                    $wrapped = $true
                    # If no filters are accepting input, stop reading.
                    if (-not $wrote) { break reading }
                    $wrote = $false
                    $iFile = 0
                }
            }
            $bp = $stop
        }
    }
    if ($k -eq 0) {
        # Ensure all files are created (truncating existing ones), then close.
        if ($wrapped) { $ceiling = $n } else { $ceiling = $iFile }
        for ($f = 0; $f -lt $n; $f++) {
            if ($f -ge $ceiling -and -not $ElideEmpty -and $null -eq $sinks[$f]) {
                Open-Sink $names[$f]
                $sinks[$f] = $script:NewSink
            }
            Close-Sink $sinks[$f]
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$Buf = New-Object byte[] $BufSize

try {
    switch ($SplitType) {
        'lines'      { Split-Lines $NUnits }
        'digits'     { Split-Lines $NUnits }
        'bytes'      { Split-Bytes $NUnits 0 0 }
        'byteslines' { Split-LineBytes $NUnits }
        'chunk_bytes' {
            $fileSize = Get-InputSize
            if ($KUnits -eq 0) {
                $rem = [long]0
                $q = [Math]::DivRem($fileSize, $NUnits, [ref]$rem)
                Split-Bytes $q $rem $NUnits
            } else {
                Export-ByteChunk $KUnits $NUnits $fileSize
            }
        }
        'chunk_lines' {
            $fileSize = Get-InputSize
            Split-LineChunks $KUnits $NUnits $fileSize
        }
        'rr' { Split-RoundRobin $KUnits $NUnits }
    }
    Close-Sink $script:Cur
    $script:Cur = $null
    Complete-Stdout
} catch {
    Exit-Fatal (Get-ErrnoText $_.Exception)
} finally {
    foreach ($s in $script:AllSinks) {
        if ($null -ne $s.Stream) { try { $s.Stream.Dispose() } catch { } }
    }
    if ($null -ne $script:InStream) { try { $script:InStream.Dispose() } catch { } }
}

exit 0
