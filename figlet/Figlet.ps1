<#
.SYNOPSIS
    FIGlet for PowerShell: display large characters made up of ordinary
    screen characters.

.DESCRIPTION
    A single-file, dependency-free port of FIGlet 2.2.5 (the classic Unix
    "figlet" program) for Windows PowerShell 5.1 and later.  It accepts the
    same command line switches as the original, reads the same FIGlet (.flf),
    TOIlet (.tlf) and control (.flc) files (plain or zipped), and produces the
    same output.  All fonts and control files from the standard FIGlet
    distribution are embedded in this script, so it works with no other files.

    Usage: Figlet.ps1 [ -cklnoprstvxDELNRSWX ] [ -d fontdirectory ]
                      [ -f fontfile ] [ -m smushmode ] [ -w outputwidth ]
                      [ -C controlfile ] [ -I infocode ] [ message ]

    -f font     Use the given font (file name, with or without .flf/.tlf).
    -d dir      Look for fonts and control files in dir (default: the "fonts"
                folder next to this script if present, otherwise the script's
                own folder, or $env:FIGLET_FONTDIR).  Embedded fonts are used
                when a font is not found on disk.
    -C file     Add a control file (.flc).  May be given more than once.
    -N          Clear the list of control files.
    -c -l -r    Center, left, or right justify.  -x uses the font's default.
    -L -R       Left-to-right or right-to-left.  -X uses the font's default.
    -w width    Set the output width (default 80).
    -t          Use the width of the console window.
    -s          Use the font's default layout (smushing) mode.
    -S          Force smushing.        -k  Kerning.
    -W          Full width.            -o  Overlapping.
    -m mode     Set the layout mode directly (see the FIGlet documentation).
    -p          Paragraph mode.        -n  Normal mode (default).
    -D          Map [\]{|}~ to German umlauts.  -E  Undo -D.
    -A          Read the message from the command line (the default when
                any message words are given).
    -v          Print version and copyright information.
    -I code     Print information: 0 version/copyright, 1 version number,
                2 font directory, 3 font, 4 output width, 5 font formats.

    With no message on the command line, text is read from the pipeline or
    from standard input.

.EXAMPLE
    .\Figlet.ps1 Hello, World!

.EXAMPLE
    .\Figlet.ps1 -f slant -c -w 60 PowerShell

.EXAMPLE
    Get-Content .\motd.txt | .\Figlet.ps1 -f small -p

.NOTES
    FIGlet Copyright (C) 1991-2012 Glenn Chappell, Ian Chai, John Cowan,
    Christiaan Keet and Claudio Matsuoka.  FIGlet, along with the various
    FIGlet fonts and documentation, is distributed under the New BSD License.
    This PowerShell port follows figlet.c 2.2.5 function by function.
#>

# No param() block on purpose: figlet-style switches such as "-f" and "-c"
# must reach the script untouched instead of being bound by PowerShell.
Set-StrictMode -Off
$script:FigletArgs = $args
$script:FigletInput = $input
$script:FigletExpectingInput = $MyInvocation.ExpectingInput
$script:FigletScriptDir = $PSScriptRoot

class FigletError : System.Exception {
    FigletError([string]$message) : base($message) { }
}

# Byte stream with one character of push-back; stands in for zipio's ZFILE.
class FigStream {
    [byte[]]$Buf
    [int]$Pos = 0
    [int]$Pb = -1

    FigStream([byte[]]$buf) { $this.Buf = $buf }

    [int] Getc() {
        if ($this.Pb -ge 0) { $c = $this.Pb; $this.Pb = -1; return $c }
        if ($this.Pos -lt $this.Buf.Length) { $c = $this.Buf[$this.Pos]; $this.Pos++; return $c }
        return -1
    }

    [void] Ungetc([int]$c) {
        if ($c -eq -1) { return }
        $c = $c -band 0xFF
        if ($this.Pb -lt 0 -and $this.Pos -gt 0 -and $this.Buf[$this.Pos - 1] -eq $c) { $this.Pos-- }
        else { $this.Pb = $c }
    }

    [bool] AtEof() { return $this.Pb -lt 0 -and $this.Pos -ge $this.Buf.Length }

    # Skips to the end of a line.  Handles \r, \n, or \r\n.
    [void] SkipToEol() {
        while ($true) {
            $c = $this.Getc()
            if ($c -eq -1 -or $c -eq 10) { return }
            if ($c -eq 13) {
                $c = $this.Getc()
                if ($c -ne -1 -and $c -ne 10) { $this.Ungetc($c) }
                return
            }
        }
    }

    # myfgets(): reads up to maxlen bytes of a line; \r, \n and \r\n all end
    # a line and are returned as \n.  Returns $null when EOF was reached,
    # exactly like the original (even if some bytes were read).
    [byte[]] FGets([int]$maxlen) {
        if ($this.Pb -ge 0) { return $this.FGetsSlow($maxlen) }
        $b = $this.Buf
        $n = $b.Length
        $start = $this.Pos
        if ($start -ge $n) { return $null }
        $cnt = [Math]::Min($maxlen, $n - $start)
        $t = -1
        if ($cnt -gt 0) {
            $t = [Array]::IndexOf($b, [byte]10, $start, $cnt)
            $cr = [Array]::IndexOf($b, [byte]13, $start, $cnt)
            if ($cr -ge 0 -and ($t -lt 0 -or $cr -lt $t)) { $t = $cr }
        }
        if ($t -ge 0) {
            $len = $t - $start
            $res = [byte[]]::new($len + 1)
            [Array]::Copy($b, $start, $res, 0, $len)
            $res[$len] = 10
            $this.Pos = $t + 1
            if ($b[$t] -eq 13) {
                if ($this.Pos -ge $n) { return $null }
                if ($b[$this.Pos] -eq 10) { $this.Pos++ }
            }
            return $res
        }
        if ($n - $start -le $maxlen) { $this.Pos = $n; return $null }
        $res = [byte[]]::new($maxlen)
        [Array]::Copy($b, $start, $res, 0, $maxlen)
        $this.Pos = $start + $maxlen + 1   # the original drops one extra byte here
        return $res
    }

    [byte[]] FGetsSlow([int]$maxlen) {
        $list = [System.Collections.Generic.List[byte]]::new()
        $c = 0
        while ($true) {
            $c = $this.Getc()
            if ($c -eq -1 -or $maxlen -eq 0) { break }
            $list.Add([byte]$c)
            $maxlen--
            if ($c -eq 10) { break }
            if ($c -eq 13) {
                $c = $this.Getc()
                if ($c -ne -1 -and $c -ne 10) { $this.Ungetc($c) }
                $list[$list.Count - 1] = 10
                break
            }
        }
        if ($c -eq -1) { return $null }
        return $list.ToArray()
    }
}

class FigletEngine {
    static [long] $DIRECT = 0x40000000   # marks an already-decoded code point
    static [long[]] $Deutsch = @(196, 214, 220, 228, 246, 252, 223)
    static [System.Text.Encoding] $StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    static [System.Text.Encoding] $Latin1 = [System.Text.Encoding]::GetEncoding(28591)

    [string]$MyName = 'figlet'

    # Globals affected by command line options
    [int]$DeutschFlag = 0
    [int]$Justification = -1
    [int]$ParagraphFlag = 0
    [int]$Right2Left = -1
    [int]$Multibyte = 0
    [int]$CmdInput = 0
    [int]$SmushMode = 0
    [int]$SmushOverride = 0     # 0 = SMO_NO, 1 = SMO_YES, 2 = SMO_FORCE
    [int]$OutputWidth = 80
    [int]$OutLineLenLimit = 79

    # ISO 2022 / multibyte input state
    [long[]]$Gn = @(0, 0x80, 0, 0)
    [int[]]$Gndbl = @(0, 0, 0, 0)
    [int]$Gl = 0
    [int]$Gr = 1
    [int]$HzMode = 0

    # Font
    [int]$HardBlank = 0
    [int]$CharHeight = 1
    [System.Collections.Generic.Dictionary[long, string[]]]$Chars
    [string[]]$CurrChar
    [int]$CurrCharWidth = 0
    [int]$PreviousCharWidth = 0

    # Output line under construction
    [string[]]$OutputLine
    [int]$OutLineLen = 0
    [System.Collections.Generic.List[long]]$InchrLine
    [int]$InchrLineLenLimit = 0

    # Control file commands: @(thecommand, rangelo, rangehi, offset)
    [System.Collections.Generic.List[long[]]]$Commands

    # Input
    [System.Collections.Generic.List[long]]$InBuf
    [int]$InPos = 0
    [bool]$InEof = $false
    [scriptblock]$Refill
    [long]$UngetBuffer = 0
    [int]$UngetFlag = 0

    # Main loop state
    [int]$WordBreakMode = 0
    [int]$LastWasEol = 0
    [System.Collections.Generic.List[string]]$Out

    FigletEngine() {
        $this.Chars = [System.Collections.Generic.Dictionary[long, string[]]]::new()
        $this.InchrLine = [System.Collections.Generic.List[long]]::new()
        $this.Commands = [System.Collections.Generic.List[long[]]]::new()
        $this.InBuf = [System.Collections.Generic.List[long]]::new()
        $this.Out = [System.Collections.Generic.List[string]]::new()
    }

    [void] Fail([string]$message) {
        throw [FigletError]::new("$($this.MyName): $message")
    }

    static [bool] IsSpaceCode([long]$c) {
        return $c -eq 32 -or ($c -ge 9 -and $c -le 13)
    }

    # ------------------------------------------------------------------
    # Control files
    # ------------------------------------------------------------------

    [void] SkipWs([FigStream]$f) {
        $c = $f.Getc()
        while ([FigletEngine]::IsSpaceCode($c)) { $c = $f.Getc() }
        $f.Ungetc($c)
    }

    # Reads a number; "0" prefix means octal, "0x" hexadecimal.
    [long] ReadNum([FigStream]$f) {
        $acc = [long]0
        $sign = 1
        $this.SkipWs($f)
        $c = $f.Getc()
        if ($c -eq 45) { $sign = -1 } else { $f.Ungetc($c) }
        $c = $f.Getc()
        if ($c -eq 48) {
            $c = $f.Getc()
            if ($c -eq 120 -or $c -eq 88) { $base = 16 }
            else { $base = 8; $f.Ungetc($c) }
        }
        else {
            $base = 10
            $f.Ungetc($c)
        }
        while (($c = $f.Getc()) -ne -1) {
            if ($c -ge 97 -and $c -le 122) { $c -= 32 }
            $p = if ($c -eq 0) { 16 } else { '0123456789ABCDEF'.IndexOf([char]$c) }
            if ($p -lt 0) {
                $f.Ungetc($c)
                return $acc * $sign
            }
            $acc = $acc * $base + $p
        }
        return $acc * $sign
    }

    # Reads a control file "t" command character: a single byte, an escape
    # sequence, or an escaped number.
    [long] ReadTchar([FigStream]$f) {
        $thechar = $f.Getc()
        if ($thechar -eq 10 -or $thechar -eq 13) {
            $f.Ungetc($thechar)
            return 0
        }
        if ($thechar -ne 92) { return $thechar }
        $next = $f.Getc()
        if ($next -ge 128) { $next -= 256 }   # "char next" is signed
        switch ($next) {
            97 { return 7 }
            98 { return 8 }
            101 { return 27 }
            102 { return 12 }
            110 { return 10 }
            114 { return 13 }
            116 { return 9 }
            118 { return 11 }
        }
        if ($next -eq 45 -or $next -eq 120 -or ($next -ge 48 -and $next -le 57)) {
            $f.Ungetc($next)
            return $this.ReadNum($f)
        }
        return $next
    }

    [long] CharsetName([FigStream]$f) {
        $result = $this.ReadTchar($f)
        if ($result -eq 10 -or $result -eq 13) {
            $result = 0
            $f.Ungetc($result)
        }
        return $result
    }

    # Processes a "g[0123]" character set specifier.
    [void] Charset([int]$n, [FigStream]$f) {
        $this.SkipWs($f)
        if ($f.Getc() -ne 57) { $f.SkipToEol(); return }
        $ch = $f.Getc()
        if ($ch -eq 54) {
            $this.Gn[$n] = 65536 * $this.CharsetName($f) + 0x80
            $this.Gndbl[$n] = 0
            $f.SkipToEol()
            return
        }
        if ($ch -ne 52) { $f.SkipToEol(); return }
        $ch = $f.Getc()
        if ($ch -eq 120) {
            if ($f.Getc() -ne 57) { $f.SkipToEol(); return }
            if ($f.Getc() -ne 52) { $f.SkipToEol(); return }
            $this.SkipWs($f)
            $this.Gn[$n] = 65536 * $this.CharsetName($f)
            $this.Gndbl[$n] = 1
            $f.SkipToEol()
            return
        }
        $f.Ungetc($ch)
        $this.SkipWs($f)
        $this.Gn[$n] = 65536 * $this.CharsetName($f)
        $this.Gndbl[$n] = 0
    }

    [void] ReadControl([byte[]]$bytes) {
        $f = [FigStream]::new($bytes)
        $this.Commands.Add([long[]]@(0, 0, 0, 0))   # begin with a freeze command
        while (($command = $f.Getc()) -ne -1) {
            if ($command -eq 116) {                          # t: translate
                $this.SkipWs($f)
                $firstch = $this.ReadTchar($f)
                $dashcheck = $f.Getc()
                if ($dashcheck -ge 128) { $dashcheck -= 256 }
                if ($dashcheck -eq 45) {
                    $lastch = $this.ReadTchar($f)
                }
                else {
                    $f.Ungetc($dashcheck)
                    $lastch = $firstch
                }
                $this.SkipWs($f)
                $offset = $this.ReadTchar($f) - $firstch
                $f.SkipToEol()
                $this.Commands.Add([long[]]@(1, $firstch, $lastch, $offset))
            }
            elseif (($command -ge 48 -and $command -le 57) -or $command -eq 45) {   # mapping table entry
                $f.Ungetc($command)
                $firstch = $this.ReadNum($f)
                $this.SkipWs($f)
                $lastch = $this.ReadNum($f)
                $offset = $lastch - $firstch
                $f.SkipToEol()
                $this.Commands.Add([long[]]@(1, $firstch, $firstch, $offset))
            }
            elseif ($command -eq 102) {                      # f: freeze
                $f.SkipToEol()
                $this.Commands.Add([long[]]@(0, 0, 0, 0))
            }
            elseif ($command -eq 98) { $this.Multibyte = 1 }     # b: DBCS
            elseif ($command -eq 117) { $this.Multibyte = 2 }    # u: UTF-8
            elseif ($command -eq 104) { $this.Multibyte = 3 }    # h: HZ
            elseif ($command -eq 106) { $this.Multibyte = 4 }    # j: Shift-JIS
            elseif ($command -eq 103) {                      # g: ISO 2022 character sets
                $this.Multibyte = 0
                $this.SkipWs($f)
                $command = $f.Getc()
                if ($command -ge 48 -and $command -le 51) {
                    $this.Charset($command - 48, $f)
                }
                elseif ($command -eq 108 -or $command -eq 76) {
                    $this.SkipWs($f)
                    $this.Gl = ($f.Getc() - 48) -band 3
                    $f.SkipToEol()
                }
                elseif ($command -eq 114 -or $command -eq 82) {
                    $this.SkipWs($f)
                    $this.Gr = ($f.Getc() - 48) -band 3
                    $f.SkipToEol()
                }
                else {
                    $f.SkipToEol()
                }
            }
            elseif ($command -eq 13 -or $command -eq 10) { }  # blank line
            else { $f.SkipToEol() }                          # includes '#'
        }
    }

    # ------------------------------------------------------------------
    # Fonts
    # ------------------------------------------------------------------

    static [string] DecodeLine([byte[]]$b) {
        try { return [FigletEngine]::StrictUtf8.GetString($b) }
        catch { return [FigletEngine]::Latin1.GetString($b) }
    }

    # sscanf("%li"): decimal, 0x-prefixed hex or 0-prefixed octal.
    static [object] ParseLi([string]$s) {
        $i = 0
        $n = $s.Length
        while ($i -lt $n -and [FigletEngine]::IsSpaceCode([int]$s[$i])) { $i++ }
        $neg = $false
        if ($i -lt $n -and ($s[$i] -eq [char]'+' -or $s[$i] -eq [char]'-')) {
            $neg = $s[$i] -eq [char]'-'
            $i++
        }
        $base = 10
        if ($i -lt $n -and $s[$i] -eq [char]'0') {
            $base = 8
            if ($i + 2 -lt $n -and ($s[$i + 1] -eq [char]'x' -or $s[$i + 1] -eq [char]'X') -and
                '0123456789abcdefABCDEF'.IndexOf($s[$i + 2]) -ge 0) {
                $base = 16
                $i += 2
            }
        }
        $acc = [long]0
        $digits = 0
        while ($i -lt $n) {
            $d = '0123456789abcdef'.IndexOf([char]::ToLowerInvariant($s[$i]))
            if ($d -lt 0 -or $d -ge $base) { break }
            if ($acc -gt ([long]::MaxValue - $d) / $base) { $acc = [long]::MaxValue }
            else { $acc = $acc * $base + $d }
            $digits++
            $i++
        }
        if ($digits -eq 0) { return $null }
        if ($neg) { return -$acc }
        return $acc
    }

    [void] ReadFontChar([FigStream]$f, [long]$theord) {
        $rows = [string[]]::new($this.CharHeight)
        for ($row = 0; $row -lt $this.CharHeight; $row++) {
            $b = $f.FGets(255)
            $s = if ($null -eq $b) { '' } else { [FigletEngine]::DecodeLine($b) }
            $k = $s.Length - 1
            while ($k -ge 0 -and [FigletEngine]::IsSpaceCode([int]$s[$k])) { $k-- }   # trailing spaces
            if ($k -ge 0) {
                $endchar = [int]$s[$k]                                               # endmarks
                while ($k -ge 0 -and [int]$s[$k] -eq $endchar) { $k-- }
            }
            $rows[$row] = $s.Substring(0, $k + 1)
        }
        $this.Chars[$theord] = $rows
    }

    [void] ReadFont([byte[]]$bytes, [string]$fontname, [bool]$toilet) {
        $f = [FigStream]::new($bytes)
        $magic = ''
        for ($i = 0; $i -lt 4; $i++) {
            $c = $f.Getc()
            if ($c -lt 0) { $c = 0xFF }
            $magic += [char]$c
        }
        $lineBytes = $f.FGets(255)
        if ($null -eq $lineBytes) { $lineBytes = [byte[]]::new(0) }
        if ($lineBytes.Length -gt 0 -and $lineBytes[$lineBytes.Length - 1] -ne 10) { $f.SkipToEol() }
        $line = [FigletEngine]::Latin1.GetString($lineBytes)

        # sscanf(fileline, "%*c%c %d %*d %d %d %d %d %d", &hardblank,
        #   &charheight, &maxlen, &smush, &cmtlines, &ffright2left, &smush2)
        $vals = [long[]]::new(7)
        $numsread = 0
        $hb = 0
        if ($line.Length -ge 2) {
            $hb = [int]$line[1]
            $numsread = 1
            $p = 2
            for ($k = 0; $k -lt 7; $k++) {
                while ($p -lt $line.Length -and [FigletEngine]::IsSpaceCode([int]$line[$p])) { $p++ }
                $q = $p
                if ($q -lt $line.Length -and ($line[$q] -eq [char]'+' -or $line[$q] -eq [char]'-')) { $q++ }
                $ds = $q
                while ($q -lt $line.Length -and [int]$line[$q] -ge 48 -and [int]$line[$q] -le 57) { $q++ }
                if ($q -eq $ds) { break }
                $v = [long]0
                if (-not [long]::TryParse($line.Substring($p, $q - $p), [ref]$v)) {
                    $v = if ($line[$p] -eq [char]'-') { [int]::MinValue } else { [int]::MaxValue }
                }
                $vals[$k] = [Math]::Max([int]::MinValue, [Math]::Min([int]::MaxValue, $v))
                $p = $q
                if ($k -ne 1) { $numsread++ }   # %*d (baseline) is not counted
            }
        }
        $height = [int]$vals[0]
        $maxlen = [int]$vals[2]
        $smush = [int]$vals[3]
        $cmtlines = [int]$vals[4]
        $ffright2left = [int]$vals[5]
        $smush2 = [int]$vals[6]

        if ($numsread -ge 3 -and $maxlen -gt 255) {
            $this.Fail("${fontname}: character is too wide")
        }
        $expected = if ($toilet) { 'tlf2' } else { 'flf2' }
        if ($magic -cne $expected -or $numsread -lt 5) {
            $this.Fail("${fontname}: Not a FIGlet 2 font file")
        }
        for ($i = 1; $i -le $cmtlines -and -not $f.AtEof(); $i++) { $f.SkipToEol() }

        if ($numsread -lt 6) { $ffright2left = 0 }
        if ($numsread -lt 7) {   # if no smush2, decode smush into smush2
            if ($smush -eq 0) { $smush2 = 64 }
            elseif ($smush -lt 0) { $smush2 = 0 }
            else { $smush2 = ($smush -band 31) -bor 128 }
        }
        if ($height -lt 1) { $height = 1 }
        if ($maxlen -lt 1) { $maxlen = 1 }
        $maxlen += 100

        if ($this.SmushOverride -eq 0) { $this.SmushMode = $smush2 }
        elseif ($this.SmushOverride -eq 2) { $this.SmushMode = $this.SmushMode -bor $smush2 }
        if ($this.Right2Left -lt 0) { $this.Right2Left = $ffright2left }
        if ($this.Justification -lt 0) { $this.Justification = 2 * $this.Right2Left }

        $this.HardBlank = $hb
        $this.CharHeight = $height
        $this.Chars.Clear()
        $missing = [string[]]::new($height)
        for ($row = 0; $row -lt $height; $row++) { $missing[$row] = '' }
        $this.Chars[[long]0] = $missing   # the "missing" character

        for ($theord = 32; $theord -le 126; $theord++) { $this.ReadFontChar($f, $theord) }
        foreach ($theord in [FigletEngine]::Deutsch) { $this.ReadFontChar($f, $theord) }
        while ($true) {
            $lb = $f.FGets($maxlen + 1)
            if ($null -eq $lb) { break }
            $theord = [FigletEngine]::ParseLi([FigletEngine]::Latin1.GetString($lb))
            if ($null -eq $theord) { break }
            $this.ReadFontChar($f, [long]$theord)
        }
    }

    [void] LineAlloc() {
        $this.OutputLine = [string[]]::new($this.CharHeight)
        $this.InchrLineLenLimit = $this.OutputWidth * 4 + 100
        $this.ClearLine()
    }

    [void] ClearLine() {
        for ($i = 0; $i -lt $this.CharHeight; $i++) { $this.OutputLine[$i] = '' }
        $this.OutLineLen = 0
        $this.InchrLine.Clear()
    }

    # ------------------------------------------------------------------
    # Rendering
    # ------------------------------------------------------------------

    [void] GetLetter([long]$c) {
        $rows = $null
        if (-not $this.Chars.TryGetValue($c, [ref]$rows)) { $rows = $this.Chars[[long]0] }
        $this.CurrChar = $rows
        $this.PreviousCharWidth = $this.CurrCharWidth
        $this.CurrCharWidth = $rows[0].Length
    }

    # strchr(set, c) -- note that strchr also finds the terminating NUL.
    static [bool] InSet([string]$set, [int]$c) {
        return $c -eq 0 -or $set.IndexOf([char]$c) -ge 0
    }

    # Given 2 characters, attempts to smush them into 1, according to
    # smushmode.  Returns smushed character or 0 if no smushing can be done.
    [int] Smushem([int]$lch, [int]$rch) {
        if ($lch -eq 32) { return $rch }
        if ($rch -eq 32) { return $lch }
        if ($this.PreviousCharWidth -lt 2 -or $this.CurrCharWidth -lt 2) { return 0 }
        $sm = $this.SmushMode
        if (($sm -band 128) -eq 0) { return 0 }   # kerning
        $hb = $this.HardBlank
        if (($sm -band 63) -eq 0) {
            # universal overlapping
            if ($lch -eq $hb) { return $rch }
            if ($rch -eq $hb) { return $lch }
            if ($this.Right2Left -eq 1) { return $lch }
            return $rch
        }
        if ($sm -band 32) {
            if ($lch -eq $hb -and $rch -eq $hb) { return $lch }
        }
        if ($lch -eq $hb -or $rch -eq $hb) { return 0 }
        if ($sm -band 1) {
            if ($lch -eq $rch) { return $lch }
        }
        if ($sm -band 2) {
            if ($lch -eq 95 -and [FigletEngine]::InSet('|/\[]{}()<>', $rch)) { return $rch }
            if ($rch -eq 95 -and [FigletEngine]::InSet('|/\[]{}()<>', $lch)) { return $lch }
        }
        if ($sm -band 4) {
            if ($lch -eq 124 -and [FigletEngine]::InSet('/\[]{}()<>', $rch)) { return $rch }
            if ($rch -eq 124 -and [FigletEngine]::InSet('/\[]{}()<>', $lch)) { return $lch }
            if ([FigletEngine]::InSet('/\', $lch) -and [FigletEngine]::InSet('[]{}()<>', $rch)) { return $rch }
            if ([FigletEngine]::InSet('/\', $rch) -and [FigletEngine]::InSet('[]{}()<>', $lch)) { return $lch }
            if ([FigletEngine]::InSet('[]', $lch) -and [FigletEngine]::InSet('{}()<>', $rch)) { return $rch }
            if ([FigletEngine]::InSet('[]', $rch) -and [FigletEngine]::InSet('{}()<>', $lch)) { return $lch }
            if ([FigletEngine]::InSet('{}', $lch) -and [FigletEngine]::InSet('()<>', $rch)) { return $rch }
            if ([FigletEngine]::InSet('{}', $rch) -and [FigletEngine]::InSet('()<>', $lch)) { return $lch }
            if ([FigletEngine]::InSet('()', $lch) -and [FigletEngine]::InSet('<>', $rch)) { return $rch }
            if ([FigletEngine]::InSet('()', $rch) -and [FigletEngine]::InSet('<>', $lch)) { return $lch }
        }
        if ($sm -band 8) {
            if ($lch -eq 91 -and $rch -eq 93) { return 124 }
            if ($rch -eq 91 -and $lch -eq 93) { return 124 }
            if ($lch -eq 123 -and $rch -eq 125) { return 124 }
            if ($rch -eq 123 -and $lch -eq 125) { return 124 }
            if ($lch -eq 40 -and $rch -eq 41) { return 124 }
            if ($rch -eq 40 -and $lch -eq 41) { return 124 }
        }
        if ($sm -band 16) {
            if ($lch -eq 47 -and $rch -eq 92) { return 124 }
            if ($rch -eq 47 -and $lch -eq 92) { return 89 }
            if ($lch -eq 62 -and $rch -eq 60) { return 88 }   # not the reverse
        }
        return 0
    }

    # Returns the maximum amount that the current character can be smushed
    # into the current line.
    [int] SmushAmt() {
        if (($this.SmushMode -band (128 -bor 64)) -eq 0) { return 0 }
        $maxsmush = $this.CurrCharWidth
        for ($row = 0; $row -lt $this.CharHeight; $row++) {
            $line = $this.OutputLine[$row]
            $cc = $this.CurrChar[$row]
            $ch1 = 0
            $ch2 = 0
            if ($this.Right2Left) {
                if ($maxsmush -gt $line.Length) { $maxsmush = $line.Length }
                $charbd = $cc.Length
                while ($true) {
                    $ch1 = if ($charbd -lt $cc.Length) { [int]$cc[$charbd] } else { 0 }
                    if ($charbd -gt 0 -and ($ch1 -eq 0 -or $ch1 -eq 32)) { $charbd-- } else { break }
                }
                $linebd = 0
                while ($true) {
                    $ch2 = if ($linebd -lt $line.Length) { [int]$line[$linebd] } else { 0 }
                    if ($ch2 -eq 32) { $linebd++ } else { break }
                }
                $amt = $linebd + $this.CurrCharWidth - 1 - $charbd
            }
            else {
                $linebd = $line.Length
                while ($true) {
                    $ch1 = if ($linebd -lt $line.Length) { [int]$line[$linebd] } else { 0 }
                    if ($linebd -gt 0 -and ($ch1 -eq 0 -or $ch1 -eq 32)) { $linebd-- } else { break }
                }
                $charbd = 0
                while ($true) {
                    $ch2 = if ($charbd -lt $cc.Length) { [int]$cc[$charbd] } else { 0 }
                    if ($ch2 -eq 32) { $charbd++ } else { break }
                }
                $amt = $charbd + $this.OutLineLen - 1 - $linebd
            }
            if ($ch1 -eq 0 -or $ch1 -eq 32) {
                $amt++
            }
            elseif ($ch2 -ne 0) {
                if ($this.Smushem($ch1, $ch2) -ne 0) { $amt++ }
            }
            if ($amt -lt $maxsmush) { $maxsmush = $amt }
        }
        return $maxsmush
    }

    static [string] CStr([char[]]$a) {
        $s = [string]::new($a)
        $z = $s.IndexOf([char]0)
        if ($z -ge 0) { return $s.Substring(0, $z) }
        return $s
    }

    # Attempts to add the given character onto the end of the current line.
    [bool] AddChar([long]$c) {
        $this.GetLetter($c)
        $smushamount = $this.SmushAmt()
        if ($this.OutLineLen + $this.CurrCharWidth - $smushamount -gt $this.OutLineLenLimit -or
            $this.InchrLine.Count + 1 -gt $this.InchrLineLenLimit) {
            return $false
        }
        for ($row = 0; $row -lt $this.CharHeight; $row++) {
            $cc = $this.CurrChar[$row]
            $line = $this.OutputLine[$row]
            if ($this.Right2Left) {
                $tail = if ($smushamount -lt $line.Length) { $line.Substring($smushamount) } else { '' }
                if ($smushamount -le 0) { $this.OutputLine[$row] = $cc + $tail; continue }
                $t = $cc.ToCharArray()
                for ($k = 0; $k -lt $smushamount; $k++) {
                    $idx = $this.CurrCharWidth - $smushamount + $k
                    if ($idx -lt 0 -or $idx -ge $t.Length) { continue }
                    $r = if ($k -lt $line.Length) { [int]$line[$k] } else { 0 }
                    $t[$idx] = [char]$this.Smushem([int]$t[$idx], $r)
                }
                $this.OutputLine[$row] = [FigletEngine]::CStr($t) + $tail
            }
            else {
                $tail = if ($smushamount -lt $cc.Length) { $cc.Substring($smushamount) } else { '' }
                if ($smushamount -le 0) { $this.OutputLine[$row] = $line + $tail; continue }
                $t = $line.ToCharArray()
                for ($k = 0; $k -lt $smushamount; $k++) {
                    $column = $this.OutLineLen - $smushamount + $k
                    if ($column -lt 0) { $column = 0 }
                    $r = if ($k -lt $cc.Length) { [int]$cc[$k] } else { 0 }
                    # Writing at or past the end only happens for malformed fonts.
                    if ($column -lt $t.Length) {
                        $t[$column] = [char]$this.Smushem([int]$t[$column], $r)
                    }
                }
                $this.OutputLine[$row] = [FigletEngine]::CStr($t) + $tail
            }
        }
        $this.OutLineLen = $this.OutputLine[0].Length
        $this.InchrLine.Add($c)
        return $true
    }

    # Emits the given string, substituting blanks for hardblanks, truncated
    # to outputwidth-1 characters and justified as requested.
    [void] PutString([string]$s) {
        $len = $s.Length
        $pad = 0
        if ($this.OutputWidth -gt 1) {
            if ($len -gt $this.OutputWidth - 1) { $len = $this.OutputWidth - 1 }
            if ($this.Justification -gt 0) {
                $j = $this.Justification
                for ($i = 1; (3 - $j) * $i + $len + $j - 2 -lt $this.OutputWidth -and $pad -lt $this.OutputWidth; $i++) {
                    $pad++
                }
            }
        }
        $body = $s.Substring(0, $len)
        if ($this.HardBlank -lt 128) {
            $body = $body.Replace([char]$this.HardBlank, [char]32)
        }
        $this.Out.Add((' ' * $pad) + $body)
    }

    [void] PrintLine() {
        for ($i = 0; $i -lt $this.CharHeight; $i++) { $this.PutString($this.OutputLine[$i]) }
        $this.ClearLine()
    }

    # Splits the line at the last word break (bunch of consecutive blanks),
    # prints the first part and keeps the second part.
    [void] SplitLine() {
        $n = $this.InchrLine.Count
        $gotspace = $false
        $lastspace = $n - 1
        $i = $n - 1
        while ($i -ge 0) {
            if (-not $gotspace -and $this.InchrLine[$i] -eq 32) {
                $gotspace = $true
                $lastspace = $i
            }
            if ($gotspace -and $this.InchrLine[$i] -ne 32) { break }
            $i--
        }
        $len1 = $i + 1
        $len2 = $n - $lastspace - 1
        $part1 = $this.InchrLine.GetRange(0, $len1).ToArray()
        $part2 = $this.InchrLine.GetRange($lastspace + 1, $len2).ToArray()
        $this.ClearLine()
        foreach ($ch in $part1) { [void]$this.AddChar($ch) }
        $this.PrintLine()
        foreach ($ch in $part2) { [void]$this.AddChar($ch) }
    }

    [long] HandleMapping([long]$c) {
        $i = 0
        $n = $this.Commands.Count
        while ($i -lt $n) {
            $cm = $this.Commands[$i]
            if ($cm[0] -ne 0 -and $c -ge $cm[1] -and $c -le $cm[2]) {
                $c += $cm[3]
                while ($i -lt $n -and $this.Commands[$i][0] -ne 0) { $i++ }
            }
            else {
                $i++
            }
        }
        return $c
    }

    # ------------------------------------------------------------------
    # Input
    # ------------------------------------------------------------------

    # Converts text to the byte stream the original would have read, using
    # the input encoding selected by the control files.  In the default
    # ISO 2022 mode, characters beyond Latin-1 are passed through as
    # already-decoded code points.  In HZ mode the text is taken to be HZ
    # already, except that characters beyond Latin-1 are converted to the
    # GB 2312 code an HZ font is indexed by.
    [void] EncodeInto([string]$s, [System.Collections.Generic.List[long]]$dst) {
        $enc = $null
        switch ($this.Multibyte) {
            1 { $enc = [System.Text.Encoding]::Default }
            2 { $enc = [System.Text.Encoding]::UTF8 }
            4 { try { $enc = [System.Text.Encoding]::GetEncoding(932) } catch { $enc = $null } }
        }
        if ($null -ne $enc) {
            foreach ($b in $enc.GetBytes($s)) { $dst.Add([long]$b) }
            return
        }
        $gb = $null
        if ($this.Multibyte -eq 3) {
            try { $gb = [System.Text.Encoding]::GetEncoding(936) } catch { $gb = $null }
        }
        for ($i = 0; $i -lt $s.Length; $i++) {
            $cp = [int]$s[$i]
            if ([char]::IsHighSurrogate($s[$i]) -and $i + 1 -lt $s.Length -and [char]::IsLowSurrogate($s[$i + 1])) {
                $cp = [char]::ConvertToUtf32($s[$i], $s[$i + 1])
                $i++
            }
            if ($cp -le 0xFF) { $dst.Add([long]$cp); continue }
            if ($null -ne $gb) {
                $b = $gb.GetBytes([char]::ConvertFromUtf32($cp))
                if ($b.Length -eq 2) { $cp = (($b[0] -band 0x7F) -shl 8) -bor ($b[1] -band 0x7F) }
            }
            $dst.Add([long]$cp + [FigletEngine]::DIRECT)
        }
    }

    [long] AgetcharRaw() {
        while ($this.InPos -ge $this.InBuf.Count) {
            if ($this.InEof -or $null -eq $this.Refill) { $this.InEof = $true; return -1 }
            $this.InBuf.Clear()
            $this.InPos = 0
            $r = $this.Refill.Invoke()
            if ($r.Count -eq 0 -or $null -eq $r[0]) { $this.InEof = $true; return -1 }
            $this.EncodeInto([string]$r[0], $this.InBuf)
        }
        $c = $this.InBuf[$this.InPos]
        $this.InPos++
        return $c
    }

    [long] Agetchar() {
        $c = $this.AgetcharRaw()
        if ($c -ge [FigletEngine]::DIRECT) { $c -= [FigletEngine]::DIRECT }
        return $c
    }

    # Interprets ISO 2022 sequences.
    [long] Iso2022() {
        $ch = $this.AgetcharRaw()
        if ($ch -ge [FigletEngine]::DIRECT) { return $ch - [FigletEngine]::DIRECT }
        if ($ch -eq -1) { return $ch }
        if ($ch -eq 27) { $ch = $this.Agetchar() + 0x100 }             # ESC x
        if ($ch -eq 0x100 + 36) { $ch = $this.Agetchar() + 0x200 }     # ESC $ x
        if ($ch -eq 14) { $this.Gl = 1; return $this.Iso2022() }       # invoke G1 into GL
        if ($ch -eq 15) { $this.Gl = 0; return $this.Iso2022() }       # invoke G0 into GL
        if ($ch -eq 142 -or $ch -eq 0x100 + 78) {                      # G2 for next char
            $save_gl = $this.Gl; $save_gr = $this.Gr
            $this.Gl = 2; $this.Gr = 2
            $ch = $this.Iso2022()
            $this.Gl = $save_gl; $this.Gr = $save_gr
            return $ch
        }
        if ($ch -eq 143 -or $ch -eq 0x100 + 79) {                      # G3 for next char
            $save_gl = $this.Gl; $save_gr = $this.Gr
            $this.Gl = 3; $this.Gr = 3
            $ch = $this.Iso2022()
            $this.Gl = $save_gl; $this.Gr = $save_gr
            return $ch
        }
        if ($ch -eq 0x100 + 110) { $this.Gl = 2; return $this.Iso2022() }   # ESC n
        if ($ch -eq 0x100 + 111) { $this.Gl = 3; return $this.Iso2022() }   # ESC o
        if ($ch -eq 0x100 + 126) { $this.Gr = 1; return $this.Iso2022() }   # ESC ~
        if ($ch -eq 0x100 + 125) { $this.Gr = 2; return $this.Iso2022() }   # ESC }
        if ($ch -eq 0x100 + 124) { $this.Gr = 3; return $this.Iso2022() }   # ESC |
        if ($ch -ge 0x100 + 40 -and $ch -le 0x100 + 43) {                   # ESC ( ) * +  94-char set
            $n = $ch - 0x100 - 40
            $ch = $this.Agetchar()
            if ($ch -eq 66) { $ch = 0 }   # ASCII
            $this.Gn[$n] = $ch -shl 16
            $this.Gndbl[$n] = 0
            return $this.Iso2022()
        }
        if ($ch -ge 0x100 + 45 -and $ch -le 0x100 + 47) {                   # ESC - . /  96-char set
            $n = $ch - 0x100 - 44
            $ch = $this.Agetchar()
            if ($ch -eq 65) { $ch = 0 }   # Latin-1 top half
            $this.Gn[$n] = ($ch -shl 16) -bor 0x80
            $this.Gndbl[$n] = 0
            return $this.Iso2022()
        }
        if ($ch -ge 0x200 + 40 -and $ch -le 0x200 + 43) {                   # ESC $ ( ) * +  94x94 set
            $n = $ch - 0x200 - 40
            $ch = $this.Agetchar()
            $this.Gn[$n] = $ch -shl 16
            $this.Gndbl[$n] = 1
            return $this.Iso2022()
        }
        if ($ch -band 0x200) {                                              # ESC $ x (deprecated)
            $this.Gn[0] = ($ch -band (-bnot [long]0x200)) -shl 16
            $this.Gndbl[0] = 1
            return $this.Iso2022()
        }
        if ($ch -ge 0x21 -and $ch -le 0x7E) {                               # process GL
            if ($this.Gndbl[$this.Gl]) {
                $ch2 = $this.Agetchar()
                return $this.Gn[$this.Gl] -bor ($ch -shl 8) -bor $ch2
            }
            return $this.Gn[$this.Gl] -bor $ch
        }
        if ($ch -ge 0xA0 -and $ch -le 0xFF) {                               # process GR
            if ($this.Gndbl[$this.Gr]) {
                $ch2 = $this.Agetchar()
                return $this.Gn[$this.Gr] -bor ($ch -shl 8) -bor $ch2
            }
            return $this.Gn[$this.Gr] -bor ($ch -band (-bnot [long]0x80))
        }
        return $ch
    }

    [void] UngetInchr([long]$c) {
        $this.UngetBuffer = $c
        $this.UngetFlag = 1
    }

    # Processes multibyte characters.
    [long] GetInchr() {
        if ($this.UngetFlag) {
            $this.UngetFlag = 0
            return $this.UngetBuffer
        }
        switch ($this.Multibyte) {
            0 { return $this.Iso2022() }
            { $_ -eq 1 -or $_ -eq 4 } {   # DBCS, Shift-JIS
                $ch = $this.Agetchar()
                if (($ch -ge 0x80 -and $ch -le 0x9F) -or ($ch -ge 0xE0 -and $ch -le 0xEF)) {
                    $ch = ($ch -shl 8) + $this.Agetchar()
                }
                return $ch
            }
            2 {   # UTF-8
                $ch = $this.Agetchar()
                if ($ch -lt 0x80) { return $ch }   # handles EOF, too
                if ($ch -lt 0xC0 -or $ch -gt 0xFD) { return 0x0080 }
                $ch2 = $this.Agetchar() -band 0x3F
                if ($ch -lt 0xE0) { return (($ch -band 0x1F) -shl 6) + $ch2 }
                $ch3 = $this.Agetchar() -band 0x3F
                if ($ch -lt 0xF0) { return (($ch -band 0x0F) -shl 12) + ($ch2 -shl 6) + $ch3 }
                $ch4 = $this.Agetchar() -band 0x3F
                if ($ch -lt 0xF8) { return (($ch -band 0x07) -shl 18) + ($ch2 -shl 12) + ($ch3 -shl 6) + $ch4 }
                $ch5 = $this.Agetchar() -band 0x3F
                if ($ch -lt 0xFC) {
                    return (($ch -band 0x03) -shl 24) + ($ch2 -shl 18) + ($ch3 -shl 12) + ($ch4 -shl 6) + $ch5
                }
                $ch6 = $this.Agetchar() -band 0x3F
                return (($ch -band 0x01) -shl 30) + ($ch2 -shl 24) + ($ch3 -shl 18) + ($ch4 -shl 12) + ($ch5 -shl 6) + $ch6
            }
            3 {   # HZ
                $ch = $this.AgetcharRaw()
                if ($ch -ge [FigletEngine]::DIRECT) { return $ch - [FigletEngine]::DIRECT }
                if ($ch -eq -1) { return $ch }
                if ($this.HzMode) {
                    $ch = ($ch -shl 8) + $this.Agetchar()
                    if ($ch -eq (125 -shl 8) + 126) {
                        $this.HzMode = 0
                        return $this.GetInchr()
                    }
                    return $ch
                }
                if ($ch -eq 126) {
                    $ch = $this.Agetchar()
                    if ($ch -eq 123) {
                        $this.HzMode = 1
                        return $this.GetInchr()
                    }
                    if ($ch -eq 126) { return $ch }
                    return $this.GetInchr()
                }
                return $ch
            }
        }
        return 0x80
    }

    # ------------------------------------------------------------------
    # Main loop body: handles one input character, including line breaking.
    # ------------------------------------------------------------------

    [void] Step([long]$c) {
        if ($c -eq 10 -and $this.ParagraphFlag -and -not $this.LastWasEol) {
            $c2 = $this.GetInchr()
            $this.UngetInchr($c2)
            $c = if ($c2 -ge 0 -and $c2 -lt 128 -and [FigletEngine]::IsSpaceCode($c2)) { 10 } else { 32 }
        }
        $this.LastWasEol = [int]([FigletEngine]::IsSpaceCode($c) -and $c -ne 9 -and $c -ne 32)
        if ($this.DeutschFlag) {
            if ($c -ge 91 -and $c -le 93) { $c = [FigletEngine]::Deutsch[$c - 91] }
            elseif ($c -ge 123 -and $c -le 126) { $c = [FigletEngine]::Deutsch[$c - 123 + 3] }
        }
        $c = $this.HandleMapping($c)
        if ([FigletEngine]::IsSpaceCode($c)) {
            $c = if ($c -eq 9 -or $c -eq 32) { 32 } else { 10 }
        }
        if (($c -gt 0 -and $c -lt 32 -and $c -ne 10) -or $c -eq 127) { return }

        # wordbreakmode:
        #  -1: /^$/ and blanks are to be absorbed (when line break was forced
        #      by a blank or character larger than outlinelenlimit)
        #   0: /^ *$/ and blanks are not to be absorbed
        #   1: /[^ ]$/ no word break yet
        #   2: /[^ ]  *$/
        #   3: /[^ ]$/ had a word break
        do {
            $charNotAdded = $false
            if ($this.WordBreakMode -eq -1) {
                if ($c -eq 32) { break }
                elseif ($c -eq 10) { $this.WordBreakMode = 0; break }
                $this.WordBreakMode = 0
            }
            if ($c -eq 10) {
                $this.PrintLine()
                $this.WordBreakMode = 0
            }
            elseif ($this.AddChar($c)) {
                if ($c -ne 32) {
                    $this.WordBreakMode = if ($this.WordBreakMode -ge 2) { 3 } else { 1 }
                }
                else {
                    $this.WordBreakMode = if ($this.WordBreakMode -gt 0) { 2 } else { 0 }
                }
            }
            elseif ($this.OutLineLen -eq 0) {
                for ($i = 0; $i -lt $this.CharHeight; $i++) {
                    $s = $this.CurrChar[$i]
                    if ($this.Right2Left -and $this.OutputWidth -gt 1 -and $s.Length -gt $this.OutLineLenLimit) {
                        $s = $s.Substring($s.Length - $this.OutLineLenLimit)
                    }
                    $this.PutString($s)
                }
                $this.WordBreakMode = -1
            }
            elseif ($c -eq 32) {
                if ($this.WordBreakMode -eq 2) { $this.SplitLine() } else { $this.PrintLine() }
                $this.WordBreakMode = -1
            }
            else {
                if ($this.WordBreakMode -ge 2) { $this.SplitLine() } else { $this.PrintLine() }
                $this.WordBreakMode = if ($this.WordBreakMode -eq 3) { 1 } else { 0 }
                $charNotAdded = $true
            }
        } while ($charNotAdded)
    }

    [void] Finish() {
        if ($this.OutLineLen -ne 0) { $this.PrintLine() }
    }
}

# ----------------------------------------------------------------------
# Script-level helpers
# ----------------------------------------------------------------------

function Write-FigletError([string]$text) {
    [Console]::Error.WriteLine($text)
}

function Get-FigletUsage([string]$myname) {
    "Usage: $myname [ -cklnoprstvxDELNRSWX ] [ -d fontdirectory ]"
    "              [ -f fontfile ] [ -m smushmode ] [ -w outputwidth ]"
    "              [ -C controlfile ] [ -I infocode ] [ message ]"
}

# C atoi(): leading whitespace, optional sign, digits; anything else is 0.
function ConvertFrom-Atoi([string]$s) {
    if ($s -match '^[ \t\n\v\f\r]*([+-]?[0-9]+)') {
        $v = [long]0
        if ([long]::TryParse($Matches[1], [ref]$v)) {
            return [int][Math]::Max([int]::MinValue, [Math]::Min([int]::MaxValue, $v))
        }
        if ($Matches[1].StartsWith('-')) { return [int]::MinValue }
        return [int]::MaxValue
    }
    return 0
}

# Unpacks the first member of a zip archive (FIGlet accepts zipped fonts and
# control files); any other data is returned unchanged.
function Expand-FigletData([byte[]]$bytes) {
    if ($bytes.Length -ge 30 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and
        $bytes[2] -eq 3 -and $bytes[3] -eq 4) {
        $flags = [BitConverter]::ToUInt16($bytes, 6)
        $method = [BitConverter]::ToUInt16($bytes, 8)
        $csize = [BitConverter]::ToUInt32($bytes, 18)
        $start = 30 + [BitConverter]::ToUInt16($bytes, 26) + [BitConverter]::ToUInt16($bytes, 28)
        $avail = $bytes.Length - $start
        if ($avail -lt 0) { return , $bytes }
        $len = if (($flags -band 8) -or $csize -eq 0 -or $csize -gt $avail) { $avail } else { [int]$csize }
        if ($method -eq 0) {
            $out = [byte[]]::new($len)
            [Array]::Copy($bytes, $start, $out, 0, $len)
            return , $out
        }
        if ($method -eq 8) {
            $src = New-Object System.IO.MemoryStream($bytes, $start, $len)
            $inflater = New-Object System.IO.Compression.DeflateStream($src, [System.IO.Compression.CompressionMode]::Decompress)
            $dst = New-Object System.IO.MemoryStream
            try { $inflater.CopyTo($dst) } catch { }
            $inflater.Dispose()
            return , $dst.ToArray()
        }
    }
    return , $bytes
}

$script:FigletEmbedded = $null

# Returns the fonts and control files embedded at the end of this script.
function Get-FigletEmbeddedFiles {
    if ($null -eq $script:FigletEmbedded) {
        $table = @{}
        $packed = [Convert]::FromBase64String((Get-FigletEmbeddedBlob))
        $src = New-Object System.IO.MemoryStream(, $packed)
        $inflater = New-Object System.IO.Compression.DeflateStream($src, [System.IO.Compression.CompressionMode]::Decompress)
        $dst = New-Object System.IO.MemoryStream
        $inflater.CopyTo($dst)
        $inflater.Dispose()
        $data = $dst.ToArray()
        $p = 0
        while ($p -lt $data.Length) {
            $z1 = [Array]::IndexOf($data, [byte]0, $p)
            $z2 = [Array]::IndexOf($data, [byte]0, $z1 + 1)
            $name = [System.Text.Encoding]::ASCII.GetString($data, $p, $z1 - $p)
            $len = [int][System.Text.Encoding]::ASCII.GetString($data, $z1 + 1, $z2 - $z1 - 1)
            $file = [byte[]]::new($len)
            [Array]::Copy($data, $z2 + 1, $file, 0, $len)
            $table[$name] = $file
            $p = $z2 + 1 + $len
        }
        $script:FigletEmbedded = $table
    }
    return $script:FigletEmbedded
}

# FIGopen(): looks for fontdir/name+suffix, then name+suffix, then the
# embedded copy.  Returns the (unzipped) file contents or $null.
function Open-FigletFile([string]$name, [string]$suffix, [string]$fontdir) {
    $hasdirsep = $name.Contains('/') -or $name.Contains('\')
    $candidates = @()
    if (-not $hasdirsep) { $candidates += $fontdir + '\' + $name + $suffix }
    $candidates += $name + $suffix
    foreach ($candidate in $candidates) {
        try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate) }
        catch { $full = $candidate }
        if ([System.IO.File]::Exists($full)) {
            try { return , (Expand-FigletData ([System.IO.File]::ReadAllBytes($full))) }
            catch { }
        }
    }
    if (-not $hasdirsep) {
        $embedded = Get-FigletEmbeddedFiles
        $key = $name + $suffix
        if ($embedded.ContainsKey($key)) { return , (Expand-FigletData $embedded[$key]) }
    }
    return $null
}

function Invoke-Figlet {
    $myname = 'figlet'
    $fig = [FigletEngine]::new()
    $fig.MyName = $myname

    if ($null -ne $env:FIGLET_FONTDIR) {
        $fontdirname = $env:FIGLET_FONTDIR
    }
    else {
        $fontdirname = $script:FigletScriptDir
        $sub = Join-Path $script:FigletScriptDir 'fonts'
        if (Test-Path -LiteralPath $sub -PathType Container) { $fontdirname = $sub }
    }
    $fontname = 'standard'
    $cfilelist = New-Object System.Collections.Generic.List[string]
    $infoprint = -1

    # PowerShell turns "Hello, World!" into an array; put the comma back.
    $argv = New-Object System.Collections.Generic.List[string]
    foreach ($a in $script:FigletArgs) {
        if ($null -eq $a) { $argv.Add('') }
        elseif ($a -is [System.Array]) { $argv.Add((@($a | ForEach-Object { "$_" }) -join ', ')) }
        else { $argv.Add("$a") }
    }

    # getopt(argc, argv, "ADEXLRI:xlcrpntvm:w:d:f:C:NFskSWo") with GNU-style
    # argument permutation: options may appear anywhere, "--" ends them.
    $optstring = 'ADEXLRI:xlcrpntvm:w:d:f:C:NFskSWo'
    $posix = $null -ne $env:POSIXLY_CORRECT
    $words = New-Object System.Collections.Generic.List[string]
    $endopts = $false
    $ai = 0
    while ($ai -lt $argv.Count) {
        $arg = $argv[$ai]
        $ai++
        if ($endopts) { $words.Add($arg); continue }
        if ($arg -ceq '--') { $endopts = $true; continue }
        if ($arg.Length -lt 2 -or $arg[0] -ne [char]'-') {
            $words.Add($arg)
            if ($posix) { $endopts = $true }
            continue
        }
        $j = 1
        while ($j -lt $arg.Length) {
            $c = $arg[$j]
            $j++
            $idx = if ($c -eq [char]':') { -1 } else { $optstring.IndexOf($c) }
            if ($idx -lt 0) {
                Write-FigletError "${myname}: invalid option -- '$c'"
                Get-FigletUsage $myname | ForEach-Object { Write-FigletError $_ }
                exit 1
            }
            $optarg = $null
            if ($idx + 1 -lt $optstring.Length -and $optstring[$idx + 1] -eq [char]':') {
                if ($j -lt $arg.Length) {
                    $optarg = $arg.Substring($j)
                    $j = $arg.Length
                }
                elseif ($ai -lt $argv.Count) {
                    $optarg = $argv[$ai]
                    $ai++
                }
                else {
                    Write-FigletError "${myname}: option requires an argument -- '$c'"
                    Get-FigletUsage $myname | ForEach-Object { Write-FigletError $_ }
                    exit 1
                }
            }
            switch -CaseSensitive ([string]$c) {
                'A' { $fig.CmdInput = 1 }
                'D' { $fig.DeutschFlag = 1 }
                'E' { $fig.DeutschFlag = 0 }
                'X' { $fig.Right2Left = -1 }
                'L' { $fig.Right2Left = 0 }
                'R' { $fig.Right2Left = 1 }
                'x' { $fig.Justification = -1 }
                'l' { $fig.Justification = 0 }
                'c' { $fig.Justification = 1 }
                'r' { $fig.Justification = 2 }
                'p' { $fig.ParagraphFlag = 1 }
                'n' { $fig.ParagraphFlag = 0 }
                's' { $fig.SmushOverride = 0 }
                'k' { $fig.SmushMode = 64; $fig.SmushOverride = 1 }
                'S' { $fig.SmushMode = 128; $fig.SmushOverride = 2 }
                'o' { $fig.SmushMode = 128; $fig.SmushOverride = 1 }
                'W' { $fig.SmushMode = 0; $fig.SmushOverride = 1 }
                't' {
                    try {
                        $columns = [Console]::WindowWidth
                        if ($columns -gt 0) { $fig.OutputWidth = $columns }
                    }
                    catch { }
                }
                'v' { $infoprint = 0 }
                'I' { $infoprint = ConvertFrom-Atoi $optarg }
                'm' {
                    $mode = ConvertFrom-Atoi $optarg
                    if ($mode -lt -1) {
                        $fig.SmushMode = $mode
                        $fig.SmushOverride = 0
                    }
                    else {
                        if ($mode -eq 0) { $mode = 64 }
                        elseif ($mode -eq -1) { $mode = 0 }
                        else { $mode = ($mode -band 63) -bor 128 }
                        $fig.SmushMode = $mode
                        $fig.SmushOverride = 1
                    }
                }
                'w' {
                    $columns = ConvertFrom-Atoi $optarg
                    if ($columns -gt 0) { $fig.OutputWidth = $columns }
                }
                'd' { $fontdirname = $optarg }
                'f' {
                    $fontname = $optarg
                    if ($fontname.EndsWith('.flf', [System.StringComparison]::OrdinalIgnoreCase) -or
                        $fontname.EndsWith('.tlf', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $fontname = $fontname.Substring(0, $fontname.Length - 4)
                    }
                }
                'C' {
                    $controlname = $optarg
                    if ($controlname.EndsWith('.flc', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $controlname = $controlname.Substring(0, $controlname.Length - 4)
                    }
                    $cfilelist.Add($controlname)
                }
                'N' {
                    $cfilelist.Clear()
                    $fig.Multibyte = 0
                    $fig.Gn = [long[]]@(0, 0x80, 0, 0)
                    $fig.Gndbl = [int[]]@(0, 0, 0, 0)
                    $fig.Gl = 0
                    $fig.Gr = 1
                }
                'F' {
                    Write-FigletError "${myname}: illegal option -- F"
                    Get-FigletUsage $myname | ForEach-Object { Write-FigletError $_ }
                    Write-FigletError ''
                    Write-FigletError 'Because of numerous incompatibilities, the "-F" option has been'
                    Write-FigletError 'removed.  It has been replaced by the "figlist" program, which is now'
                    Write-FigletError 'included in the basic FIGlet package.  "figlist" is also available'
                    Write-FigletError 'from  http://www.figlet.org/under UNIX utilities.'
                    exit 1
                }
            }
        }
    }
    if ($words.Count -gt 0) { $fig.CmdInput = 1 }   # force cmdinput if more arguments
    $fig.OutLineLenLimit = $fig.OutputWidth - 1

    if ($infoprint -ge 0) {
        switch ($infoprint) {
            0 {
                'FIGlet Copyright (C) 1991-2012 Glenn Chappell, Ian Chai, John Cowan,'
                'Christiaan Keet and Claudio Matsuoka'
                'Internet: <info@figlet.org> Version: 2.2.5, date: 31 May 2012'
                ''
                'FIGlet, along with the various FIGlet fonts and documentation, may be'
                'freely copied and distributed.'
                ''
                'If you use FIGlet, please send an e-mail message to <info@figlet.org>.'
                ''
                'The latest version of FIGlet is available from the web site,'
                "`thttp://www.figlet.org/"
                ''
                Get-FigletUsage $myname
            }
            1 { '20205' }
            2 { $fontdirname }
            3 { $fontname }
            4 { "$($fig.OutputWidth)" }
            5 { 'flf2 tlf2' }
        }
        exit 0
    }

    try {
        foreach ($controlname in $cfilelist) {
            $bytes = Open-FigletFile $controlname '.flc' $fontdirname
            if ($null -eq $bytes) {
                Write-FigletError "${myname}: ${controlname}: Unable to open control file"
                exit 1
            }
            $fig.ReadControl($bytes)
        }

        $toilet = $false
        $bytes = Open-FigletFile $fontname '.flf' $fontdirname
        if ($null -eq $bytes) {
            $bytes = Open-FigletFile $fontname '.tlf' $fontdirname
            $toilet = $true
        }
        if ($null -eq $bytes) {
            Write-FigletError "${myname}: ${fontname}: Unable to open font file"
            exit 1
        }
        $fig.ReadFont($bytes, $fontname, $toilet)
        $fig.LineAlloc()

        if ($fig.CmdInput) {
            # Agetchar(): words are joined by blanks; an empty word is a newline.
            for ($w = 0; $w -lt $words.Count; $w++) {
                $fig.EncodeInto($words[$w], $fig.InBuf)
                if ($w -lt $words.Count - 1) {
                    $fig.InBuf.Add($(if ($words[$w].Length -eq 0) { 10 } else { 32 }))
                }
            }
            $fig.InEof = $true
        }
        elseif ($script:FigletExpectingInput) {
            $text = New-Object System.Text.StringBuilder
            foreach ($item in $script:FigletInput) {
                $s = if ($null -eq $item) { '' } else { "$item" }
                $s = $s.Replace("`r`n", "`n")
                if (-not $s.EndsWith("`n")) { $s += "`n" }
                [void]$text.Append($s)
            }
            $fig.EncodeInto($text.ToString(), $fig.InBuf)
            $fig.InEof = $true
        }
        elseif ([Console]::IsInputRedirected) {
            $fig.EncodeInto([Console]::In.ReadToEnd().Replace("`r`n", "`n"), $fig.InBuf)
            $fig.InEof = $true
        }
        else {
            # Interactive: render each line as soon as it is entered (Ctrl+Z ends input).
            $fig.Refill = {
                $line = [Console]::In.ReadLine()
                if ($null -eq $line) { return $null }
                return $line + "`n"
            }
        }

        while ($true) {
            $c = $fig.GetInchr()
            if ($c -eq -1) { break }
            $fig.Step($c)
            if ($fig.Out.Count -gt 0) {
                $fig.Out.ToArray()
                $fig.Out.Clear()
            }
        }
        $fig.Finish()
        $fig.Out.ToArray()
    }
    catch {
        $e = $_.Exception
        while ($null -ne $e.InnerException -and -not ($e -is [FigletError])) { $e = $e.InnerException }
        Write-FigletError $e.Message
        exit 1
    }
}

# Deflate-compressed, base64-encoded archive of the standard FIGlet 2.2.5
# fonts (*.flf) and control files (*.flc).  Records are "name\0size\0data".
function Get-FigletEmbeddedBlob {
    @'
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
'@
}

Invoke-Figlet
