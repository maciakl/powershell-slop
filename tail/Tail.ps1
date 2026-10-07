# Tail.ps1 - a PowerShell port of the POSIX tail(1) utility.
# Copyright (C) 2026 Luke Maciak
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

<#
.SYNOPSIS
    Output the last part of files. A port of the POSIX tail(1) utility.

.DESCRIPTION
    Print the last 10 lines of each FILE to standard output. With more than
    one FILE, precede each with a header giving the file name. With no FILE,
    or when FILE is -, read standard input (the PowerShell pipeline, or the
    process's redirected standard input).

    Options follow POSIX/GNU syntax rather than PowerShell syntax:

      -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to
                               output starting with byte NUM of each file
      -f, --follow[={name|descriptor}]
                               output appended data as the file grows;
                               an absent option argument means 'descriptor'
      -F                       same as --follow=name --retry
      -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
                               or use -n +NUM to output starting with line NUM
          --pid=PID            with -f, terminate after process ID, PID dies
      -q, --quiet, --silent    never output headers giving file names
          --retry              keep trying to open a file if it is inaccessible
      -s, --sleep-interval=N   with -f, sleep for approximately N seconds
                               (default 1.0) between iterations
      -v, --verbose            always output headers giving file names
      -z, --zero-terminated    line delimiter is NUL, not newline
          --encoding=NAME      text encoding for files without a byte order
                               mark (default utf-8; e.g. ansi, oem, 1252)
          --help               display this help and exit
          --version            output version information and exit

    NUM may have a multiplier suffix: b 512, kB 1000, K 1024, MB 1000*1000,
    M 1024*1024, GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E.
    Binary prefixes can be used, too: KiB=K, MiB=M, and so on.

    The obsolete forms 'tail -NUM[bcl][f]' and 'tail +NUM[bcl][f]' are
    accepted as the first argument.

    Lines are written to the pipeline as strings (without their trailing line
    delimiter), so output can be piped into other PowerShell commands.
    Non-string objects piped in are treated as one line each and passed
    through unchanged in line mode.

    Note: PowerShell itself consumes a bare -- argument. To end option
    processing, quote it: Tail.ps1 '--' -oddly-named-file

.EXAMPLE
    .\Tail.ps1 -n 20 app.log

.EXAMPLE
    .\Tail.ps1 -F C:\logs\service.log

.EXAMPLE
    Get-Content big.txt | .\Tail.ps1 -n +100

.EXAMPLE
    .\Tail.ps1 -c 1K data.bin
#>

$script:Version = '1.0.0'
$script:ExitCode = 0
$script:IsWin = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function Write-TailError([string]$Message) {
    [Console]::Error.WriteLine("tail: $Message")
}

function Exit-Usage([string]$Message) {
    Write-TailError $Message
    [Console]::Error.WriteLine("Try 'tail --help' for more information.")
    exit 1
}

function Show-Help {
    @'
Usage: tail [OPTION]... [FILE]...
Print the last 10 lines of each FILE to standard output.
With more than one FILE, precede each with a header giving the file name.

With no FILE, or when FILE is -, read standard input.

  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to
                             output starting with byte NUM of each file
  -f, --follow[={name|descriptor}]
                           output appended data as the file grows;
                             an absent option argument means 'descriptor'
  -F                       same as --follow=name --retry
  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
                             or use -n +NUM to output starting with line NUM
      --pid=PID            with -f, terminate after process ID, PID dies
  -q, --quiet, --silent    never output headers giving file names
      --retry              keep trying to open a file if it is inaccessible
  -s, --sleep-interval=N   with -f, sleep for approximately N seconds
                             (default 1.0) between iterations
  -v, --verbose            always output headers giving file names
  -z, --zero-terminated    line delimiter is NUL, not newline
      --encoding=NAME      encoding for files without a byte order mark
                             (default utf-8; e.g. ansi, oem, 1252, utf-16)
      --help               display this help and exit
      --version            output version information and exit

NUM may have a multiplier suffix:
b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E.
Binary prefixes can be used, too: KiB=K, MiB=M, and so on.

PowerShell consumes a bare -- argument; quote it ('--') to end options.
'@
}

# Parse a [+-]NUM[suffix] count. Returns @{ FromStart; Value } or $null.
function ConvertTo-Count([string]$Text) {
    if ($Text -cnotmatch '^([+-]?)(\d+)([A-Za-z]*)$') { return $null }
    $sign = $Matches[1]; $digits = $Matches[2]; $suffix = $Matches[3]
    $mult = [decimal]1
    if ($suffix) {
        if ($suffix -ceq 'b') {
            $mult = [decimal]512
        } elseif ($suffix -cmatch '^([kKMGTPE])(B|iB)?$') {
            $power = 'kMGTPE'.IndexOf($Matches[1].ToUpperInvariant().Replace('K', 'k')) + 1
            if ($Matches[1] -ceq 'k' -and $Matches[2] -cne 'B') { return $null }
            $base = if ($Matches[2] -ceq 'B') { [decimal]1000 } else { [decimal]1024 }
            for ($p = 0; $p -lt $power; $p++) { $mult *= $base }
        } else {
            return $null
        }
    }
    # Clamp absurdly large values instead of overflowing.
    $value = [long]::MaxValue
    if ($digits.Length -le 19) {
        $d = [decimal]::Parse($digits, [Globalization.CultureInfo]::InvariantCulture)
        if ($d -le ([decimal][long]::MaxValue / $mult)) { $value = [long]($d * $mult) }
    }
    return @{ FromStart = ($sign -eq '+'); Value = $value }
}

function Resolve-Encoding([string]$Name) {
    try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
    switch -Regex ($Name.ToLowerInvariant()) {
        '^utf-?8$'                   { return (New-Object Text.UTF8Encoding($false)) }
        '^(utf-?16|utf-?16le|unicode)$' { return (New-Object Text.UnicodeEncoding($false, $false)) }
        '^(utf-?16be|bigendianunicode)$' { return (New-Object Text.UnicodeEncoding($true, $false)) }
        '^(utf-?32|utf-?32le)$'      { return (New-Object Text.UTF32Encoding($false, $false)) }
        '^utf-?32be$'                { return (New-Object Text.UTF32Encoding($true, $false)) }
        '^(ascii|us-ascii)$'         { return [Text.Encoding]::ASCII }
        '^(ansi|default)$'           { return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) }
        '^oem$'                      { return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        '^\d+$'                      { return [Text.Encoding]::GetEncoding([int]$Name) }
    }
    return [Text.Encoding]::GetEncoding($Name)
}

# ---------------------------------------------------------------------------
# Argument parsing (getopt-style, case-sensitive, options may follow files)
# ---------------------------------------------------------------------------

$argv = New-Object 'System.Collections.Generic.List[string]'
foreach ($a in $args) {
    if ($a -is [array]) { foreach ($x in $a) { $argv.Add([string]$x) } }
    elseif ($null -ne $a) { $argv.Add([string]$a) }
}

$bytesMode = $false
$countSpec = $null          # set by -n / -c; parsed after option processing
$countOpt = 'lines'
$follow = $null             # $null, 'descriptor' or 'name'
$retry = $false
$quiet = $false
$verbose = $false
$sleepSeconds = 1.0
$watchPid = $null
$delimChar = [char]10
$encodingName = $null
$files = New-Object 'System.Collections.Generic.List[string]'

# Obsolete usage: tail -NUM[bcl][f] / tail +NUM[bcl][f] as the first argument.
if ($argv.Count -gt 0 -and $argv[0] -cmatch '^([+-])(\d+)([bcl]?)(f?)$' -and
    -not ($argv[0].StartsWith('+') -and (Test-Path -LiteralPath $argv[0]))) {
    $sign = $Matches[1]; $num = $Matches[2]; $unit = $Matches[3]
    $prefix = if ($sign -eq '+') { '+' } else { '' }
    switch -CaseSensitive ($unit) {
        'b' { $bytesMode = $true; $countOpt = 'bytes'; $countSpec = "$prefix${num}b" }
        'c' { $bytesMode = $true; $countOpt = 'bytes'; $countSpec = "$prefix$num" }
        default { $countSpec = "$prefix$num" }
    }
    if ($Matches[4]) { $follow = 'descriptor' }
    $argv.RemoveAt(0)
}

$longOptions = @('bytes', 'encoding', 'follow', 'help', 'lines', 'max-unchanged-stats',
                 'pid', 'quiet', 'retry', 'silent', 'sleep-interval', 'verbose',
                 'version', 'zero-terminated')
$longWithArg = @('bytes', 'encoding', 'lines', 'max-unchanged-stats', 'pid', 'sleep-interval')

$endOfOptions = $false
$i = 0
while ($i -lt $argv.Count) {
    $arg = $argv[$i]; $i++

    if ($endOfOptions -or $arg -eq '-' -or $arg.Length -lt 2 -or -not $arg.StartsWith('-')) {
        $files.Add($arg); continue
    }
    if ($arg -eq '--') { $endOfOptions = $true; continue }

    # PowerShell splits "-n:5" into "-n:" and "5"; accept that shape.
    if ($arg -cmatch '^-[^-:]+:$') { $arg = $arg.Substring(0, $arg.Length - 1) }

    if ($arg.StartsWith('--')) {
        $body = $arg.Substring(2)
        $value = $null
        $eq = $body.IndexOf('=')
        if ($eq -ge 0) { $value = $body.Substring($eq + 1); $body = $body.Substring(0, $eq) }

        $name = $null
        if ($longOptions -ccontains $body) {
            $name = $body
        } else {
            $candidates = @($longOptions | Where-Object { $_.StartsWith($body, [StringComparison]::Ordinal) })
            if ($candidates.Count -eq 1) { $name = $candidates[0] }
            elseif ($candidates.Count -gt 1) { Exit-Usage "option '--$body' is ambiguous" }
            else { Exit-Usage "unrecognized option '$arg'" }
        }

        if ($longWithArg -contains $name) {
            if ($null -eq $value) {
                if ($i -ge $argv.Count) { Exit-Usage "option '--$name' requires an argument" }
                $value = $argv[$i]; $i++
            }
        } elseif ($null -ne $value -and $name -ne 'follow') {
            Exit-Usage "option '--$name' doesn't allow an argument"
        }

        switch ($name) {
            'bytes'               { $bytesMode = $true; $countOpt = 'bytes'; $countSpec = $value }
            'lines'               { $bytesMode = $false; $countOpt = 'lines'; $countSpec = $value }
            'encoding'            { $encodingName = $value }
            'follow' {
                if ($null -eq $value -or $value -eq 'descriptor') { $follow = 'descriptor' }
                elseif ($value -eq 'name') { $follow = 'name' }
                else { Exit-Usage "invalid argument '$value' for '--follow'`nValid arguments are:`n  - 'descriptor'`n  - 'name'" }
            }
            'help'                { Show-Help; exit 0 }
            'version' {
                "tail (PowerShell port) $script:Version"
                'Copyright (C) 2026 Luke Maciak'
                'License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.'
                'This is free software: you are free to change and redistribute it.'
                'There is NO WARRANTY, to the extent permitted by law.'
                exit 0
            }
            'max-unchanged-stats' { }   # accepted for compatibility; polling makes it moot
            'pid'                 { $watchPid = $value }
            'quiet'               { $quiet = $true; $verbose = $false }
            'silent'              { $quiet = $true; $verbose = $false }
            'retry'               { $retry = $true }
            'sleep-interval'      { $sleepSeconds = $value }
            'verbose'             { $verbose = $true; $quiet = $false }
            'zero-terminated'     { $delimChar = [char]0 }
        }
        continue
    }

    # Cluster of short options, e.g. -fqn20
    for ($j = 1; $j -lt $arg.Length; $j++) {
        $c = [string]$arg[$j]
        switch -CaseSensitive ($c) {
            'f' { $follow = 'descriptor' }
            'F' { $follow = 'name'; $retry = $true }
            'q' { $quiet = $true; $verbose = $false }
            'v' { $verbose = $true; $quiet = $false }
            'z' { $delimChar = [char]0 }
            { 'n', 'c', 's' -ccontains $_ } {
                if ($j + 1 -lt $arg.Length) { $value = $arg.Substring($j + 1) }
                elseif ($i -lt $argv.Count) { $value = $argv[$i]; $i++ }
                else { Exit-Usage "option requires an argument -- '$c'" }
                $j = $arg.Length
                if ($c -ceq 'n') { $bytesMode = $false; $countOpt = 'lines'; $countSpec = $value }
                elseif ($c -ceq 'c') { $bytesMode = $true; $countOpt = 'bytes'; $countSpec = $value }
                else { $sleepSeconds = $value }
            }
            default { Exit-Usage "invalid option -- '$c'" }
        }
    }
}

$count = [long]10
$fromStart = $false
if ($null -ne $countSpec) {
    $parsed = ConvertTo-Count $countSpec
    if ($null -eq $parsed) { Write-TailError "invalid number of ${countOpt}: '$countSpec'"; exit 1 }
    $count = $parsed.Value
    $fromStart = $parsed.FromStart
}

$sleepValue = 0.0
if (-not [double]::TryParse([string]$sleepSeconds, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$sleepValue) -or $sleepValue -lt 0) {
    Write-TailError "invalid number of seconds: '$sleepSeconds'"; exit 1
}
$sleepMs = [int][Math]::Min([Math]::Ceiling($sleepValue * 1000), [int]::MaxValue)

$pidValue = 0
if ($null -ne $watchPid -and -not [int]::TryParse($watchPid, [ref]$pidValue)) {
    Write-TailError "invalid PID: '$watchPid'"; exit 1
}

$defaultEncoding = New-Object Text.UTF8Encoding($false)
if ($encodingName) {
    try { $defaultEncoding = Resolve-Encoding $encodingName }
    catch { Write-TailError "unsupported encoding: '$encodingName'"; exit 1 }
}
$delimString = [string]$delimChar
$stripCR = $delimChar -eq [char]10

# ---------------------------------------------------------------------------
# Stream helpers
# ---------------------------------------------------------------------------

$script:Buffer = New-Object byte[] 65536

function Read-Fully([IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count) {
    $total = 0
    while ($total -lt $Count) {
        $r = $Stream.Read($Buffer, $total, $Count - $total)
        if ($r -le 0) { break }
        $total += $r
    }
    return $total
}

function Test-Delimiter([byte[]]$Buffer, [int]$Index, [byte[]]$Delim) {
    for ($k = 1; $k -lt $Delim.Length; $k++) {
        if ($Buffer[$Index + $k] -ne $Delim[$k]) { return $false }
    }
    return $true
}

# Detect a byte order mark and set up decoding state for $St.
function Initialize-Encoding($St) {
    $s = $St.Stream
    $hdr = New-Object byte[] 4
    $s.Position = 0
    $r = Read-Fully $s $hdr ([int][Math]::Min([long]4, $s.Length))
    $enc = $defaultEncoding; $bom = 0
    if ($r -ge 3 -and $hdr[0] -eq 0xEF -and $hdr[1] -eq 0xBB -and $hdr[2] -eq 0xBF) {
        $enc = New-Object Text.UTF8Encoding($false); $bom = 3
    } elseif ($r -ge 4 -and $hdr[0] -eq 0xFF -and $hdr[1] -eq 0xFE -and $hdr[2] -eq 0 -and $hdr[3] -eq 0) {
        $enc = New-Object Text.UTF32Encoding($false, $false); $bom = 4
    } elseif ($r -ge 4 -and $hdr[0] -eq 0 -and $hdr[1] -eq 0 -and $hdr[2] -eq 0xFE -and $hdr[3] -eq 0xFF) {
        $enc = New-Object Text.UTF32Encoding($true, $false); $bom = 4
    } elseif ($r -ge 2 -and $hdr[0] -eq 0xFF -and $hdr[1] -eq 0xFE) {
        $enc = New-Object Text.UnicodeEncoding($false, $false); $bom = 2
    } elseif ($r -ge 2 -and $hdr[0] -eq 0xFE -and $hdr[1] -eq 0xFF) {
        $enc = New-Object Text.UnicodeEncoding($true, $false); $bom = 2
    }
    $St.Encoding = $enc
    $St.Bom = $bom
    $St.Decoder = $enc.GetDecoder()
    $St.Delim = $enc.GetBytes($delimString)
    $St.Chars = New-Object char[] ($enc.GetMaxCharCount($script:Buffer.Length) + 1)
    $St.Partial = ''
}

# Offset of the start of the last $N records (delimiter-terminated, with the
# final record possibly unterminated).
function Find-LastRecords([IO.Stream]$S, [long]$Bom, [byte[]]$Delim, [long]$N) {
    $len = $S.Length
    if ($N -le 0) { return $len }
    $unit = $Delim.Length
    $buf = $script:Buffer
    $end = $Bom + [long][Math]::Floor(($len - $Bom) / $unit) * $unit

    # A delimiter at the very end terminates the last record; it does not
    # begin a new one.
    if ($end -eq $len -and $end - $unit -ge $Bom) {
        $S.Position = $end - $unit
        [void](Read-Fully $S $buf $unit)
        if ((Test-Delimiter $buf 0 $Delim) -and $buf[0] -eq $Delim[0]) { $end -= $unit }
    }

    $found = [long]0
    while ($end -gt $Bom) {
        $start = [Math]::Max($Bom, $end - $buf.Length)
        $S.Position = $start
        $got = Read-Fully $S $buf ([int]($end - $start))
        $idx = $got - $unit
        while ($idx -ge 0) {
            $k = [Array]::LastIndexOf($buf, $Delim[0], $idx)
            if ($k -lt 0) { break }
            if (($k % $unit) -eq 0 -and (Test-Delimiter $buf $k $Delim)) {
                $found++
                if ($found -ge $N) { return $start + $k + $unit }
                $idx = $k - $unit
            } else {
                $idx = $k - 1
            }
        }
        $end = $start
    }
    return $Bom
}

# Offset of the start of record number $N (1-based) counted from the start.
function Find-RecordFromStart([IO.Stream]$S, [long]$Bom, [byte[]]$Delim, [long]$N) {
    $len = $S.Length
    if ($N -le 1) { return $Bom }
    $unit = $Delim.Length
    $buf = $script:Buffer
    $need = $N - 1
    $pos = $Bom
    while ($pos -lt $len) {
        $S.Position = $pos
        $r = Read-Fully $S $buf ([int][Math]::Min([long]$buf.Length, $len - $pos))
        if ($r -le 0) { break }
        $idx = 0
        while ($idx -le $r - $unit) {
            $k = [Array]::IndexOf($buf, $Delim[0], $idx, $r - $idx)
            if ($k -lt 0 -or $k + $unit -gt $r) { break }
            if (($k % $unit) -eq 0 -and (Test-Delimiter $buf $k $Delim)) {
                $need--
                if ($need -le 0) { return $pos + $k + $unit }
                $idx = $k + $unit
            } else {
                $idx = $k + 1
            }
        }
        $pos += $r
    }
    return $len
}

function Get-StartOffset($St) {
    $s = $St.Stream
    $len = $s.Length
    $bom = [long]$St.Bom
    $unit = $St.Delim.Length
    if ($bytesMode) {
        if ($fromStart) { $off = [Math]::Max([long]1, $count) - 1 } else { $off = $len - $count }
        if ($off -lt $bom) { $off = $bom }
        $rem = ($off - $bom) % $unit
        if ($rem -ne 0) { $off += $unit - $rem }
        if ($off -gt $len) { $off = $len }
        return $off
    }
    if ($fromStart) { return Find-RecordFromStart $s $bom $St.Delim ([Math]::Max([long]1, $count)) }
    return Find-LastRecords $s $bom $St.Delim $count
}

# Decode everything from $St.Position to the current end of the stream and
# write each complete record to the pipeline. An unterminated tail is kept in
# $St.Partial. Sets $St.GotData when new bytes were consumed.
function Read-Available($St) {
    $St.GotData = $false
    $s = $St.Stream
    if ($St.Position -ge $s.Length) { return }
    if ($St.Position -eq 0) { Initialize-Encoding $St; $St.Position = $St.Bom }
    $s.Position = $St.Position
    $buf = $script:Buffer
    $chars = $St.Chars
    while (($r = $s.Read($buf, 0, $buf.Length)) -gt 0) {
        $St.Position += $r
        $St.GotData = $true
        $nc = $St.Decoder.GetChars($buf, 0, $r, $chars, 0)
        if ($nc -eq 0) { continue }
        $parts = ($St.Partial + [string]::new($chars, 0, $nc)).Split($delimChar)
        $last = $parts.Length - 1
        for ($p = 0; $p -lt $last; $p++) {
            $line = $parts[$p]
            if ($stripCR -and $line.EndsWith("`r")) { $line.Substring(0, $line.Length - 1) } else { $line }
        }
        $St.Partial = $parts[$last]
    }
}

function Write-Partial($St) {
    if ($null -eq $St.Decoder) { return }
    $nc = $St.Decoder.GetChars($script:Buffer, 0, 0, $St.Chars, 0, $true)
    $line = $St.Partial + [string]::new($St.Chars, 0, $nc)
    $St.Partial = ''
    if ($line.Length -gt 0) {
        if ($stripCR -and $line.EndsWith("`r")) { $line.Substring(0, $line.Length - 1) } else { $line }
    }
}

function Open-TailFile([string]$Path) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    return New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 4096)
}

function New-TailState([string]$Name, [string]$Path, [IO.Stream]$Stream) {
    return @{
        Name = $Name; Path = $Path; Stream = $Stream; Position = [long]0
        Encoding = $null; Bom = 0; Decoder = $null; Delim = $null; Chars = $null
        Partial = ''; GotData = $false; Id = $null; Created = $null; Present = $false
    }
}

# File identity (volume serial + file index) so --follow=name can notice a
# file being replaced, even when Windows file-name tunneling keeps the old
# creation time. Compiled lazily from inline C#; falls back to creation time.
$script:CanGetId = $false
function Initialize-FileId {
    if (-not $script:IsWin) { return }
    try {
        if (-not ([Management.Automation.PSTypeName]'TailPs1.FileId').Type) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace TailPs1 {
    public static class FileId {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);
        public static string Get(SafeFileHandle h) {
            BY_HANDLE_FILE_INFORMATION i;
            if (!GetFileInformationByHandle(h, out i)) return null;
            return i.VolumeSerial.ToString("X8") + ":" + i.IndexHigh.ToString("X8") + i.IndexLow.ToString("X8");
        }
    }
}
'@
        }
        $script:CanGetId = $true
    } catch { }
}

function Get-StreamId([IO.Stream]$Stream) {
    if (-not $script:CanGetId -or $Stream -isnot [IO.FileStream]) { return $null }
    try { return [TailPs1.FileId]::Get($Stream.SafeFileHandle) } catch { return $null }
}

function Set-Identity($St) {
    $St.Id = Get-StreamId $St.Stream
    try { $St.Created = [IO.File]::GetCreationTimeUtc($St.Path) } catch { $St.Created = $null }
}

# Requires $St.Stream to be a freshly opened handle on $St.Path.
function Test-Replaced($St) {
    if ($St.Id) {
        $id = Get-StreamId $St.Stream
        return ($id -and $id -ne $St.Id)
    }
    try { return ([IO.File]::GetCreationTimeUtc($St.Path) -ne $St.Created) } catch { return $false }
}

# In follow mode with several files, print a header whenever output switches
# to a different file.
function Write-HeaderIfNeeded($St) {
    if ($script:Multi -and -not [object]::ReferenceEquals($script:LastShown, $St)) {
        ''
        "==> $($St.Name) <=="
        $script:LastShown = $St
    }
}

function Get-OpenErrorText($Err) {
    $ex = $Err.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [IO.FileNotFoundException] -or $ex -is [IO.DirectoryNotFoundException]) { return 'No such file or directory' }
    if ($ex -is [UnauthorizedAccessException]) { return 'Permission denied' }
    return $ex.Message
}

# ---------------------------------------------------------------------------
# Standard input from the PowerShell pipeline
# ---------------------------------------------------------------------------

$pipelineInput = $MyInvocation.ExpectingInput
if ($files.Count -eq 0) { $files.Add('-') }
$showHeaders = $verbose -or ($files.Count -gt 1 -and -not $quiet)

function Write-PipelineTail([object[]]$Items) {
    if ($bytesMode) {
        $sb = New-Object Text.StringBuilder
        foreach ($item in $Items) {
            if ($item -is [string]) { [void]$sb.Append($item) }
            else { [void]$sb.Append(($item | Out-String).TrimEnd()) }
            [void]$sb.Append($delimChar)
        }
        $enc = New-Object Text.UTF8Encoding($false)
        $bytes = $enc.GetBytes($sb.ToString())
        if ($fromStart) { $off = [Math]::Max([long]1, $count) - 1 } else { $off = [Math]::Max([long]0, $bytes.Length - $count) }
        if ($off -ge $bytes.Length) { return }
        $parts = $enc.GetString($bytes, [int]$off, [int]($bytes.Length - $off)).Split($delimChar)
        $last = $parts.Length - 1
        if ($parts[$last].Length -gt 0) { $last++ }
        for ($p = 0; $p -lt $last; $p++) {
            $line = $parts[$p]
            if ($stripCR -and $line.EndsWith("`r")) { $line.Substring(0, $line.Length - 1) } else { $line }
        }
        return
    }

    # Line mode: strings are split into lines; other objects pass through.
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) {
        if ($item -is [string]) {
            $lines = $item.Split($delimChar)
            $n = $lines.Length
            if ($n -gt 1 -and $lines[$n - 1].Length -eq 0) { $n-- }
            for ($p = 0; $p -lt $n; $p++) {
                $line = $lines[$p]
                if ($stripCR -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
                $records.Add($line)
            }
        } else {
            $records.Add($item)
        }
    }
    if ($fromStart) {
        $first = [Math]::Max([long]1, $count) - 1
    } else {
        $first = [Math]::Max([long]0, $records.Count - $count)
    }
    for ($p = $first; $p -lt $records.Count; $p++) { $records[[int]$p] }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$states = New-Object 'System.Collections.Generic.List[object]'
$script:LastShown = $null
$firstOutput = $true

if ($follow -eq 'name') { Initialize-FileId }

try {
    foreach ($fileArg in $files) {
        if ($fileArg -eq '-') {
            $name = 'standard input'
            if ($showHeaders) {
                if (-not $firstOutput) { '' }
                "==> $name <=="
            }
            $firstOutput = $false
            if ($pipelineInput) {
                Write-PipelineTail @($input)
                $pipelineInput = $false   # the pipeline can only be consumed once
                continue
            }
            # Process-level standard input (e.g. invoked via powershell -File
            # from another shell). Buffer it so it can be read like a file.
            $ms = New-Object IO.MemoryStream
            try {
                $stdin = [Console]::OpenStandardInput()
                $stdin.CopyTo($ms)
            } catch {
                Write-TailError "error reading 'standard input': $($_.Exception.Message)"
                $script:ExitCode = 1
                continue
            }
            $st = New-TailState $name $null $ms
            if ($ms.Length -gt 0) {
                Initialize-Encoding $st
                $st.Position = Get-StartOffset $st
                if ($st.Position -eq 0) { $st.Position = [long]$st.Bom }
                Read-Available $st
                Write-Partial $st
            }
            $ms.Dispose()
            continue
        }

        # Resolve the path relative to the PowerShell location (which can
        # differ from the process working directory) and expand wildcards,
        # since Windows shells do not glob.
        $targets = @()
        $literal = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($fileArg)
        if (-not (Test-Path -LiteralPath $literal) -and $fileArg -match '[*?]') {
            $resolved = @(Resolve-Path -Path $fileArg -ErrorAction SilentlyContinue)
            $parent = Split-Path -Path $fileArg -Parent
            foreach ($r in $resolved) {
                $leaf = Split-Path -Path $r.ProviderPath -Leaf
                $display = if ($parent) { Join-Path $parent $leaf } else { $leaf }
                $targets += , @($display, $r.ProviderPath)
            }
            if ($targets.Count -gt 1 -and -not $quiet) { $showHeaders = $true }
        }
        if ($targets.Count -eq 0) { $targets = , @($fileArg, $literal) }

        foreach ($t in $targets) {
            $name = $t[0]; $path = $t[1]

            if ([IO.Directory]::Exists($path)) {
                if ($showHeaders) {
                    if (-not $firstOutput) { '' }
                    "==> $name <=="
                    $firstOutput = $false
                }
                Write-TailError "error reading '$name': Is a directory"
                $script:ExitCode = 1
                continue
            }

            $stream = $null
            try {
                $stream = Open-TailFile $path
            } catch {
                Write-TailError "cannot open '$name' for reading: $(Get-OpenErrorText $_)"
                $script:ExitCode = 1
                if ($follow -and $retry) { $states.Add((New-TailState $name $path $null)) }
                continue
            }

            $st = New-TailState $name $path $stream
            if ($showHeaders) {
                if (-not $firstOutput) { '' }
                "==> $name <=="
            }
            $firstOutput = $false
            $script:LastShown = $st

            if ($stream.Length -gt 0) {
                Initialize-Encoding $st
                $st.Position = Get-StartOffset $st
                # Position 0 means "not yet started" to Read-Available.
                if ($st.Position -eq 0) { $st.Position = [long]$st.Bom }
                Read-Available $st
            }

            if ($follow) {
                Set-Identity $st
                $st.Present = $true
                if ($follow -eq 'name') {
                    # Following by name reopens the file on every poll, so no
                    # handle is held in between. Some Windows writers (such as
                    # Set-Content, or Add-Content in Windows PowerShell) refuse
                    # to open a file that anyone else has open.
                    $stream.Dispose()
                    $st.Stream = $null
                }
                $states.Add($st)
            } else {
                Write-Partial $st
                $stream.Dispose()
            }
        }
    }

    if (-not $follow) { exit $script:ExitCode }
    if ($states.Count -eq 0) { Write-TailError 'no files remaining'; exit 1 }

    # -----------------------------------------------------------------------
    # Follow loop (polling)
    # -----------------------------------------------------------------------
    $script:Multi = $showHeaders
    while ($true) {
        $pidDead = $false
        if ($pidValue -gt 0) {
            try { [void][Diagnostics.Process]::GetProcessById($pidValue) } catch { $pidDead = $true }
        }

        $anyData = $false
        $remove = New-Object 'System.Collections.Generic.List[object]'
        foreach ($st in $states) {
            $opened = $false
            if ($follow -eq 'name') {
                if (-not [IO.File]::Exists($st.Path)) {
                    if ($st.Present) {
                        if ($st.Partial.Length) { Write-HeaderIfNeeded $st; Write-Partial $st }
                        Write-TailError "'$($st.Name)' has become inaccessible: No such file or directory"
                        $st.Present = $false
                        if (-not $retry) { $remove.Add($st) }
                    }
                    continue
                }
                # A failed open (e.g. the writer holds it exclusively) is
                # simply retried on the next poll.
                try { $st.Stream = Open-TailFile $st.Path; $opened = $true } catch { continue }
                $msg = $null
                if (-not $st.Present) { $msg = "'$($st.Name)' has appeared;  following new file" }
                elseif (Test-Replaced $st) { $msg = "'$($st.Name)' has been replaced;  following new file" }
                if ($msg) {
                    if ($st.Partial.Length) { Write-HeaderIfNeeded $st; Write-Partial $st }
                    Write-TailError $msg
                    $st.Position = [long]0
                    Set-Identity $st
                }
                $st.Present = $true
            } elseif ($null -eq $st.Stream) {
                # --retry: a file that could not be opened at startup.
                try { $st.Stream = Open-TailFile $st.Path } catch { continue }
                Write-TailError "'$($st.Name)' has appeared;  following new file"
                $st.Position = [long]0
            }

            try {
                $len = $st.Stream.Length
                if ($len -lt $st.Position) {
                    Write-TailError "$($st.Name): file truncated"
                    $st.Position = [long]0
                    $st.Partial = ''
                }
                if ($len -gt $st.Position) {
                    Write-HeaderIfNeeded $st
                    Read-Available $st
                    if ($st.GotData) { $anyData = $true }
                } elseif ($st.Partial.Length -gt 0) {
                    # Show an unterminated last line once it has stopped growing.
                    Write-HeaderIfNeeded $st
                    Write-Partial $st
                }
            } catch {
                # Transient read failure; try again on the next poll.
            } finally {
                if ($opened) { $st.Stream.Dispose(); $st.Stream = $null }
            }
        }
        foreach ($st in $remove) { [void]$states.Remove($st) }
        if ($states.Count -eq 0) { Write-TailError 'no files remaining'; exit 1 }

        if ($pidDead) {
            foreach ($st in $states) { if ($st.Partial.Length) { Write-HeaderIfNeeded $st; Write-Partial $st } }
            break
        }
        if (-not $anyData) { Start-Sleep -Milliseconds $sleepMs }
    }
} finally {
    foreach ($st in $states) { if ($st.Stream) { $st.Stream.Dispose() } }
}

exit $script:ExitCode
