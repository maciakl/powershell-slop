<#
.SYNOPSIS
    Base64 encode or decode FILE, or standard input, to standard output.

.DESCRIPTION
    A self-contained PowerShell port of the GNU coreutils base64 utility.
    Runs on Windows PowerShell 5.1 (as shipped with Windows 11) and on
    PowerShell 7+, with no external dependencies.

    Usage: Base64.ps1 [OPTION]... [FILE]

      -d, --decode          decode data
      -i, --ignore-garbage  when decoding, ignore non-alphabet characters
      -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).
                              Use 0 to disable line wrapping
      -o, --output=FILE     write output to FILE instead of standard output
                              (extension; byte-exact output from inside a
                              PowerShell session)
          --help            display this help and exit
          --version         output version information and exit

    Options use GNU syntax: short options may be bundled (-di, -w76, -dw 0),
    long options may be abbreviated (--dec, --wr=0) and may appear after the
    FILE operand. Run "Base64.ps1 --help" for the full help text.

    Output handling:
      * When the process's standard output is redirected (for example
        "powershell -File Base64.ps1 -d in.b64 > out.bin" from cmd.exe, or a
        native pipe), raw bytes are written to standard output, exactly like
        the Linux tool.
      * Inside a PowerShell session the output goes to the PowerShell
        pipeline as strings, one per line, so it can be assigned to
        variables or piped to other cmdlets. Decoded data is interpreted as
        UTF-8 text in that mode. Use -o FILE to write decoded binary data
        byte-for-byte.

    Input handling:
      * FILE, or "-" / no FILE for standard input.
      * Pipeline input is accepted: strings are sent as UTF-8 text with a
        newline after each item (like piping to a native program), bytes and
        byte arrays are sent as-is.

.EXAMPLE
    "hello" | .\Base64.ps1
    aGVsbG8K

.EXAMPLE
    .\Base64.ps1 -w 0 .\picture.png

.EXAMPLE
    .\Base64.ps1 -d .\picture.b64 -o .\picture.png

.EXAMPLE
    powershell -NoProfile -File Base64.ps1 --decode in.b64 > out.bin
#>

# No param() block on purpose: arguments are parsed GNU getopt style from $args.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProgName = 'base64'
$script:ProgVersion = '1.0.0'

$script:HelpText = @'
Usage: base64 [OPTION]... [FILE]
Base64 encode or decode FILE, or standard input, to standard output.

With no FILE, or when FILE is -, read standard input.

Mandatory arguments to long options are mandatory for short options too.
  -d, --decode          decode data
  -i, --ignore-garbage  when decoding, ignore non-alphabet characters
  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).
                          Use 0 to disable line wrapping
  -o, --output=FILE     write output to FILE instead of standard output
      --help        display this help and exit
      --version     output version information and exit

The data are encoded as described for the base64 alphabet in RFC 4648.
When decoding, the input may contain newlines in addition to the bytes of
the formal base64 alphabet.  Use --ignore-garbage to attempt to recover
from any other non-alphabet bytes in the encoded stream.

When run inside a PowerShell session, output is written to the pipeline as
lines of text (decoded data is read as UTF-8); use --output for byte-exact
results.
'@

$script:VersionText = @"
base64 (PowerShell port) $($script:ProgVersion)
A port of the GNU coreutils base64 utility to Windows PowerShell 5.1+.
This is free software: you are free to change and redistribute it.
"@

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

function Write-Diag([string]$Message) {
    [Console]::Error.Write("$($script:ProgName): $Message`n")
}

function Exit-Usage([string]$Message) {
    Write-Diag $Message
    [Console]::Error.Write("Try '$($script:ProgName) --help' for more information.`n")
    exit 1
}

function Exit-Fatal([string]$Message) {
    Write-Diag $Message
    exit 1
}

# ---------------------------------------------------------------------------
# Output sink: either a raw byte stream or the PowerShell pipeline
# ---------------------------------------------------------------------------

$script:RawOut = $null                                   # Stream in raw mode
$script:LineBuf = New-Object System.Text.StringBuilder   # pending partial line (pipeline mode, text)
$script:ByteBuf = New-Object System.IO.MemoryStream      # decoded bytes (pipeline mode, decode)
$script:Ascii = [System.Text.Encoding]::ASCII

function Write-OutText([string]$Text) {
    if ($null -ne $script:RawOut) {
        $bytes = $script:Ascii.GetBytes($Text)
        $script:RawOut.Write($bytes, 0, $bytes.Length)
        return
    }
    [void]$script:LineBuf.Append($Text)
    $s = $script:LineBuf.ToString()
    $last = $s.LastIndexOf("`n")
    if ($last -lt 0) { return }
    $lines = $s.Substring(0, $last).Split("`n")
    [void]$script:LineBuf.Clear()
    [void]$script:LineBuf.Append($s.Substring($last + 1))
    foreach ($line in $lines) { Write-Output $line }
}

function Write-OutBytes([byte[]]$Bytes) {
    if ($Bytes.Length -eq 0) { return }
    if ($null -ne $script:RawOut) {
        $script:RawOut.Write($Bytes, 0, $Bytes.Length)
    } else {
        $script:ByteBuf.Write($Bytes, 0, $Bytes.Length)
    }
}

function Complete-Output {
    if ($null -ne $script:RawOut) {
        $script:RawOut.Flush()
        return
    }
    if ($script:LineBuf.Length -gt 0) {
        Write-Output $script:LineBuf.ToString()
        [void]$script:LineBuf.Clear()
    }
    if ($script:ByteBuf.Length -gt 0) {
        $text = [System.Text.Encoding]::UTF8.GetString($script:ByteBuf.ToArray())
        $lines = $text -split "`r?`n"
        $count = $lines.Length
        if ($count -gt 0 -and $lines[$count - 1] -eq '') { $count-- }
        for ($k = 0; $k -lt $count; $k++) { Write-Output $lines[$k] }
        $script:ByteBuf.SetLength(0)
    }
}

# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

# Read until $Buffer is full or the stream ends; returns the byte count.
function Read-Full([System.IO.Stream]$Stream, [byte[]]$Buffer) {
    $total = 0
    while ($total -lt $Buffer.Length) {
        $n = $Stream.Read($Buffer, $total, $Buffer.Length - $total)
        if ($n -le 0) { break }
        $total += $n
    }
    return $total
}

function Invoke-Encode([System.IO.Stream]$InStream, [long]$Wrap) {
    # Multiple of 3 so that every chunk but the last encodes without padding.
    $buf = New-Object byte[] (3 * 65536)
    $col = 0L
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $n = Read-Full $InStream $buf
        if ($n -eq 0) { break }
        $enc = [Convert]::ToBase64String($buf, 0, $n)
        if ($Wrap -eq 0) {
            Write-OutText $enc
        } else {
            [void]$sb.Clear()
            $pos = 0
            while ($pos -lt $enc.Length) {
                $take = [int][Math]::Min($Wrap - $col, [long]($enc.Length - $pos))
                [void]$sb.Append($enc, $pos, $take)
                $pos += $take
                $col += $take
                if ($col -eq $Wrap) {
                    [void]$sb.Append("`n")
                    $col = 0
                }
            }
            Write-OutText $sb.ToString()
        }
        if ($n -lt $buf.Length) { break }
    }
    if ($col -gt 0) {
        Write-OutText "`n"
    }
}

# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

$script:DecodeFailed = $false

# Decode a run of alphabet characters with no padding. A trailing partial
# group of 2 or 3 characters yields 1 or 2 bytes (as GNU does before reporting
# the error); a lone trailing character yields nothing.
function Write-DecodedPartial([string]$Chars) {
    $r = $Chars.Length % 4
    if ($r -eq 1) { $Chars = $Chars.Substring(0, $Chars.Length - 1) }
    elseif ($r -eq 2) { $Chars += '==' }
    elseif ($r -eq 3) { $Chars += '=' }
    if ($Chars.Length -gt 0) {
        Write-OutBytes ([Convert]::FromBase64String($Chars))
    }
}

# $Text contains only alphabet characters and '=' and starts on a 4-character
# group boundary. Decodes every complete group, returns the unconsumed tail.
# When $Final is set the input ends here: any leftover is an error.
function Invoke-DecodeGroups([string]$Text, [bool]$Final) {
    $start = 0
    while ($true) {
        $p = $Text.IndexOf('=', $start)
        if ($p -lt 0) {
            $len = $Text.Length - $start
            $full = $len - ($len % 4)
            if ($full -gt 0) {
                Write-OutBytes ([Convert]::FromBase64String($Text.Substring($start, $full)))
                $start += $full
            }
            if ($Final -and $start -lt $Text.Length) {
                Write-DecodedPartial $Text.Substring($start)
                $script:DecodeFailed = $true
                return ''
            }
            return $Text.Substring($start)
        }

        # '=' found: it is valid only as the 3rd ("xx==") or 4th ("xxx=") char of a group.
        $q = ($p - $start) % 4
        $groupEnd = -1
        if ($q -eq 3) {
            $groupEnd = $p + 1
        } elseif ($q -eq 2) {
            if ($p + 1 -lt $Text.Length) {
                if ($Text[$p + 1] -eq '=') { $groupEnd = $p + 2 }
            } elseif (-not $Final) {
                # Need the next chunk to know whether the second '=' follows.
                $keep = $p - $q
                if ($keep -gt $start) {
                    Write-OutBytes ([Convert]::FromBase64String($Text.Substring($start, $keep - $start)))
                }
                return $Text.Substring($keep)
            }
        }
        if ($groupEnd -lt 0) {
            Write-DecodedPartial $Text.Substring($start, $p - $start)
            $script:DecodeFailed = $true
            return ''
        }
        Write-OutBytes ([Convert]::FromBase64String($Text.Substring($start, $groupEnd - $start)))
        $start = $groupEnd
    }
}

function Invoke-Decode([System.IO.Stream]$InStream, [bool]$IgnoreGarbage) {
    # Latin-1 maps every byte to the char of the same value, so non-ASCII
    # garbage is preserved as a non-alphabet char instead of being folded.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $garbage = New-Object System.Text.RegularExpressions.Regex '[^A-Za-z0-9+/=]'
    $newlines = New-Object System.Text.RegularExpressions.Regex '[\r\n]'
    $buf = New-Object byte[] 65536
    $pending = ''
    while ($true) {
        $n = Read-Full $InStream $buf
        $final = $n -lt $buf.Length
        $text = $latin1.GetString($buf, 0, $n)
        if ($IgnoreGarbage) {
            $text = $garbage.Replace($text, '')
        } else {
            # GNU skips newlines; CR is skipped too so CRLF files decode on Windows.
            $text = $newlines.Replace($text, '')
            $m = $garbage.Match($text)
            if ($m.Success) {
                $text = $text.Substring(0, $m.Index)
                $final = $true
                $script:DecodeFailed = $true
            }
        }
        $pending = Invoke-DecodeGroups ($pending + $text) $final
        if ($final -or $script:DecodeFailed) { break }
    }
}

# ---------------------------------------------------------------------------
# Command line parsing (GNU getopt_long semantics)
# ---------------------------------------------------------------------------

function ConvertTo-WrapSize([string]$Value) {
    if ($Value -notmatch '^\s*\+?[0-9]+$') {
        Exit-Fatal "invalid wrap size: '$Value'"
    }
    $digits = $Value.Trim().TrimStart('+')
    $result = 0L
    if (-not [long]::TryParse($digits, [ref]$result)) { $result = [long]::MaxValue }
    return $result
}

$argv = @($args | ForEach-Object { [string]$_ })
$decode = $false
$ignoreGarbage = $false
$wrap = 76L
$outFile = $null
$operands = New-Object System.Collections.Generic.List[string]
$longOptions = @('decode', 'ignore-garbage', 'wrap', 'output', 'help', 'version')

$i = 0
$endOfOptions = $false
while ($i -lt $argv.Count) {
    $arg = $argv[$i]
    $i++

    if ($endOfOptions -or $arg -eq '-' -or -not $arg.StartsWith('-')) {
        $operands.Add($arg)
        continue
    }
    if ($arg -eq '--') {
        $endOfOptions = $true
        continue
    }

    if ($arg.StartsWith('--')) {
        $body = $arg.Substring(2)
        $value = $null
        $eq = $body.IndexOf('=')
        if ($eq -ge 0) {
            $value = $body.Substring($eq + 1)
            $body = $body.Substring(0, $eq)
        }
        $candidates = @($longOptions | Where-Object { $_.StartsWith($body, [StringComparison]::Ordinal) })
        if ($candidates -contains $body) { $candidates = @($body) }
        if ($candidates.Count -eq 0) {
            Exit-Usage "unrecognized option '$arg'"
        }
        if ($candidates.Count -gt 1) {
            $list = ($candidates | ForEach-Object { "'--$_'" }) -join ' '
            Exit-Usage "option '--$body' is ambiguous; possibilities: $list"
        }
        $name = $candidates[0]
        if ($name -eq 'wrap' -or $name -eq 'output') {
            if ($null -eq $value) {
                if ($i -ge $argv.Count) { Exit-Usage "option '--$name' requires an argument" }
                $value = $argv[$i]
                $i++
            }
        } elseif ($null -ne $value) {
            Exit-Usage "option '--$name' doesn't allow an argument"
        }
        switch ($name) {
            'decode'         { $decode = $true }
            'ignore-garbage' { $ignoreGarbage = $true }
            'wrap'           { $wrap = ConvertTo-WrapSize $value }
            'output'         { $outFile = $value }
            'help'           { Write-Output $script:HelpText; exit 0 }
            'version'        { Write-Output $script:VersionText; exit 0 }
        }
        continue
    }

    # Bundle of short options, e.g. -di, -w76, -dw 76.
    $j = 1
    while ($j -lt $arg.Length) {
        $c = [string]$arg[$j]
        $j++
        if ($c -ceq 'd') { $decode = $true; continue }
        if ($c -ceq 'i') { $ignoreGarbage = $true; continue }
        if ($c -ceq 'w' -or $c -ceq 'o') {
            $value = $arg.Substring($j)
            # PowerShell splits "-w:76" into "-w:" and "76".
            if ($value -eq '' -or $value -eq ':') {
                if ($i -ge $argv.Count) { Exit-Usage "option requires an argument -- '$c'" }
                $value = $argv[$i]
                $i++
            }
            if ($c -ceq 'w') { $wrap = ConvertTo-WrapSize $value } else { $outFile = $value }
            break
        }
        Exit-Usage "invalid option -- '$c'"
    }
}

if ($operands.Count -gt 1) {
    Exit-Usage "extra operand '$($operands[1])'"
}
$inName = '-'
if ($operands.Count -eq 1) { $inName = $operands[0] }

# ---------------------------------------------------------------------------
# Choose output mode
# ---------------------------------------------------------------------------

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

try {
    if ($null -ne $outFile -and $outFile -ne '-') {
        $outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outFile)
        try {
            $script:RawOut = New-Object System.IO.FileStream($outPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        } catch {
            Exit-Fatal "${outFile}: $($_.Exception.InnerException.Message)"
        }
    } elseif ([Console]::IsOutputRedirected -and (Test-UncapturedTopLevel $MyInvocation)) {
        $script:RawOut = [Console]::OpenStandardOutput()
    }
} catch {
    Exit-Fatal $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Open input
# ---------------------------------------------------------------------------

$inStream = $null
if ($inName -eq '-') {
    # Note: under "powershell -File" a redirected stdin is consumed by the host
    # and delivered here as lines of text, so binary data should be passed as
    # a FILE operand rather than through stdin.
    if ($MyInvocation.ExpectingInput) {
        $inStream = New-Object System.IO.MemoryStream
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $newline = [byte[]](10)
        foreach ($item in $input) {
            if ($item -is [byte[]]) {
                $inStream.Write($item, 0, $item.Length)
                continue
            }
            # Arrays arrive e.g. from "Get-Content -Encoding Byte -ReadCount 0".
            foreach ($element in @($item)) {
                if ($element -is [byte]) {
                    $inStream.WriteByte($element)
                } elseif ($null -ne $element) {
                    $bytes = $utf8.GetBytes([string]$element)
                    $inStream.Write($bytes, 0, $bytes.Length)
                    $inStream.Write($newline, 0, 1)
                }
            }
        }
        $inStream.Position = 0
    } else {
        $inStream = [Console]::OpenStandardInput()
    }
} else {
    $inPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inName)
    if ([System.IO.Directory]::Exists($inPath)) {
        Exit-Fatal 'read error: Is a directory'
    }
    if (-not [System.IO.File]::Exists($inPath)) {
        Exit-Fatal "${inName}: No such file or directory"
    }
    try {
        $inStream = New-Object System.IO.FileStream($inPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch [System.UnauthorizedAccessException] {
        Exit-Fatal "${inName}: Permission denied"
    } catch {
        $e = $_.Exception
        if ($null -ne $e.InnerException) { $e = $e.InnerException }
        Exit-Fatal "${inName}: $($e.Message)"
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$exitCode = 0
try {
    if ($decode) {
        Invoke-Decode $inStream $ignoreGarbage
    } else {
        Invoke-Encode $inStream $wrap
    }
    Complete-Output
    if ($script:DecodeFailed) {
        Write-Diag 'invalid input'
        $exitCode = 1
    }
} catch [System.IO.IOException] {
    # Reader went away (e.g. "| more" quit) or a read/write error occurred.
    $msg = $_.Exception.Message
    if ($null -ne $_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
    Write-Diag $msg
    $exitCode = 1
} finally {
    if ($null -ne $inStream) { $inStream.Dispose() }
    if ($null -ne $script:RawOut) { try { $script:RawOut.Dispose() } catch { } }
}
exit $exitCode
