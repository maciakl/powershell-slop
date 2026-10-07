<#
.SYNOPSIS
    Output the first part of files. A port of the POSIX/GNU 'head' utility.

.DESCRIPTION
    Print the first 10 lines of each FILE. With more than one FILE, precede
    each with a header giving the file name. With no FILE, or when FILE is -,
    read standard input (the PowerShell pipeline, or the console input stream
    when nothing is piped in).

    Options use POSIX/GNU syntax rather than PowerShell parameter syntax:

      -n, --lines=[-]NUM   print the first NUM lines instead of the first 10;
                           with a leading '-', print all but the last NUM lines
      -c, --bytes=[-]NUM   print the first NUM bytes; with a leading '-',
                           print all but the last NUM bytes
      -q, --quiet, --silent  never print headers giving file names
      -v, --verbose        always print headers giving file names
      -z, --zero-terminated  line delimiter is NUL, not newline
      -NUM                 same as -n NUM (obsolete form)
          --help           display help and exit
          --version        output version information and exit

    NUM may have a multiplier suffix: b 512, kB 1000, K 1024, MB 1000*1000,
    M 1024*1024, GB, G, TB, T, PB, P, EB, E (KiB, MiB, ... are the same as
    K, M, ...). Note that PowerShell itself converts an unquoted 5kb, 5mb,
    5gb, 5tb or 5pb argument to a 1024-based number before head sees it.

    Short options may be bundled (-qn5), long options may be abbreviated
    (--li=5), and options may appear after file names. PowerShell consumes a
    bare -- itself, so quote it ('--') to end option processing. Wildcards in
    file names are expanded.

    Output is written to the pipeline one line per object, with line
    terminators removed. Files are decoded as UTF-8 unless they start with a
    UTF-8, UTF-16 or UTF-32 byte order mark. Pipeline input that is not a
    string is passed through unchanged in line mode, so
    'Get-Process | .\PSHead.ps1 -3' returns three process objects.

    Exit status is 0 on success and 1 if any error occurred.

.EXAMPLE
    .\PSHead.ps1 file.txt
    Print the first 10 lines of file.txt.

.EXAMPLE
    .\PSHead.ps1 -n 5 a.txt b.txt
    Print the first 5 lines of each file, each preceded by a header.

.EXAMPLE
    .\PSHead.ps1 -n -2 file.txt
    Print all but the last 2 lines of file.txt.

.EXAMPLE
    Get-Content log.txt | .\PSHead.ps1 -c 1K
    Print the first 1024 bytes of the piped text.
#>

# Errors are written only from the script's top level (never from inside a
# helper function) so that PowerShell attributes them to PSHead.ps1.

begin {
    Set-StrictMode -Version 2.0

    $script:Version   = '1.0.0'
    $script:HadError  = $false
    $script:FirstFile = $true

    function New-HeadError([string]$Message, $Category = 'NotSpecified', $Target = $null) {
        $exception = New-Object System.Exception "head: $Message"
        New-Object System.Management.Automation.ErrorRecord $exception, 'HeadError', $Category, $Target
    }

    function Show-Help {
        @'
Usage: PSHead [OPTION]... [FILE]...
Print the first 10 lines of each FILE to standard output.
With more than one FILE, precede each with a header giving the file name.

With no FILE, or when FILE is -, read standard input.

Mandatory arguments to long options are mandatory for short options too.
  -c, --bytes=[-]NUM       print the first NUM bytes of each file;
                             with the leading '-', print all but the last
                             NUM bytes of each file
  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;
                             with the leading '-', print all but the last
                             NUM lines of each file
  -q, --quiet, --silent    never print headers giving file names
  -v, --verbose            always print headers giving file names
  -z, --zero-terminated    line delimiter is NUL, not newline
      --help               display this help and exit
      --version            output version information and exit

NUM may have a multiplier suffix:
b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E.
Binary prefixes can be used, too: KiB=K, MiB=M, and so on.

PowerShell consumes a bare -- itself; quote it ('--') to end options.
'@
    }

    # Parses a [-]NUM[suffix] count. Returns @{ Count; AllBut }, or an error
    # message string.
    function ConvertTo-Count([string]$Text, [string]$What) {
        $m = [regex]::Match($Text, '^\s*([+-]?)(\d+)(b|[kKMGTPE](?:B|iB)?)?$')
        if (-not $m.Success) { return "invalid number of ${What}: '$Text'" }

        # Like GNU, accept anything up to 2^64-1; larger values are errors.
        $max = [decimal][uint64]::MaxValue
        $tooLarge = "invalid number of ${What}: '$Text': Value too large for defined data type"
        $value = [decimal]0
        $digits = $m.Groups[2].Value.TrimStart('0')
        if ($digits.Length -gt 20) { return $tooLarge }
        if ($digits.Length -gt 0) { $value = [decimal]::Parse($digits) }

        $suffix = $m.Groups[3].Value
        if ($suffix) {
            if ($suffix -ceq 'b') { $mult = [decimal]512 }
            else {
                $power = 'KMGTPE'.IndexOf([char]::ToUpperInvariant($suffix[0])) + 1
                $base = if ($suffix.Length -eq 2) { [decimal]1000 } else { [decimal]1024 }
                $mult = [decimal]1
                for ($i = 0; $i -lt $power; $i++) { $mult *= $base }
            }
            if ($value -gt ($max / $mult)) { return $tooLarge }
            $value *= $mult
        }
        if ($value -gt $max) { return $tooLarge }
        if ($value -gt [decimal][long]::MaxValue) { $value = [decimal][long]::MaxValue }

        @{ Count = [long]$value; AllBut = ($m.Groups[1].Value -eq '-') }
    }

    # ---------------------------------------------------------------- options

    $mode       = 'lines'
    $countSpec  = @{ Count = 10L; AllBut = $false }
    $headers    = $null          # $null = default, $true = -v, $false = -q
    $delimiter  = [char]"`n"
    $operands   = New-Object System.Collections.Generic.List[string]
    $usageError = $null
    $action     = $null          # 'help' or 'version'

    $longOptions = @('bytes', 'lines', 'quiet', 'silent', 'verbose', 'zero-terminated', 'help', 'version')

    # Flatten arrays (e.g. a.txt,b.txt) and stringify numbers PowerShell parsed.
    $argv = New-Object System.Collections.Generic.List[string]
    foreach ($a in $args) {
        if ($a -is [array]) { foreach ($x in $a) { $argv.Add([string]$x) } }
        else { $argv.Add([string]$a) }
    }

    $i = 0
    $endOfOptions = $false
    :parse while ($i -lt $argv.Count) {
        $arg = $argv[$i]
        $i++

        if ($endOfOptions -or $arg -eq '-' -or -not $arg.StartsWith('-')) {
            $operands.Add($arg)
            continue
        }
        if ($arg -eq '--') { $endOfOptions = $true; continue }

        $value = $null
        if ($arg.StartsWith('--')) {
            $name, $value = $arg.Substring(2).Split([char[]]'=', 2)
            $hits = @($longOptions | Where-Object { $_.StartsWith($name) })
            if ($longOptions -contains $name) { $hits = @($name) }
            if ($hits.Count -eq 0) { $usageError = "unrecognized option '$arg'"; break }
            if ($hits.Count -gt 1) { $usageError = "option '$arg' is ambiguous"; break }
            $opt = $hits[0]

            if ($opt -eq 'bytes' -or $opt -eq 'lines') {
                if ($null -eq $value) {
                    if ($i -ge $argv.Count) { $usageError = "option '--$opt' requires an argument"; break }
                    $value = $argv[$i]; $i++
                }
                $mode = $opt
                $countSpec = ConvertTo-Count $value $opt
                if ($countSpec -is [string]) { $usageError = $countSpec; break }
                continue
            }
            if ($null -ne $value) { $usageError = "option '--$opt' doesn't allow an argument"; break }
            switch ($opt) {
                'quiet'           { $headers = $false }
                'silent'          { $headers = $false }
                'verbose'         { $headers = $true }
                'zero-terminated' { $delimiter = [char]0 }
                default           { $action = $opt; break parse }
            }
            continue
        }

        # Obsolete -NUM form.
        if ($arg -match '^-\d+$') {
            $mode = 'lines'
            $countSpec = ConvertTo-Count $arg.Substring(1) 'lines'
            if ($countSpec -is [string]) { $usageError = $countSpec; break }
            continue
        }

        # Bundled short options, e.g. -qvn5.
        $j = 1
        while ($j -lt $arg.Length) {
            $c = $arg[$j]
            $j++
            switch -CaseSensitive ($c) {
                'q' { $headers = $false }
                'v' { $headers = $true }
                'z' { $delimiter = [char]0 }
                { $_ -ceq 'n' -or $_ -ceq 'c' } {
                    $value = $arg.Substring($j)
                    # PowerShell splits '-n:5' into '-n:' and 5.
                    if ($value -eq ':') { $value = '' }
                    if ($value -eq '') {
                        if ($i -ge $argv.Count) { $usageError = "option requires an argument -- '$c'"; break parse }
                        $value = $argv[$i]; $i++
                    }
                    if ($c -ceq 'n') { $mode = 'lines' } else { $mode = 'bytes' }
                    $countSpec = ConvertTo-Count $value $mode
                    if ($countSpec -is [string]) { $usageError = $countSpec; break parse }
                    $j = $arg.Length
                }
                default { $usageError = "invalid option -- '$c'"; break parse }
            }
        }
    }

    if ($null -ne $usageError) {
        $record = New-HeadError "$usageError`nTry 'PSHead --help' for more information." 'InvalidArgument'
        Write-Error -ErrorRecord $record -ErrorAction Continue
        exit 1
    }
    if ($action -eq 'help') { (Show-Help) -split "`r?`n"; exit 0 }
    if ($action -eq 'version') { "head (PowerShell port) $script:Version"; exit 0 }

    $count  = $countSpec.Count
    $allBut = $countSpec.AllBut

    # -------------------------------------------------------------- helpers

    function Write-Header([string]$Name) {
        if (-not $script:FirstFile) { '' }
        $script:FirstFile = $false
        "==> $Name <=="
    }

    # Reads delimited records from a TextReader and writes the selected ones.
    function Read-HeadLines([System.IO.TextReader]$Reader) {
        if (-not $allBut -and $count -eq 0) { return }
        $buffer  = New-Object char[] 65536
        $pending = New-Object System.Text.StringBuilder
        $queue   = New-Object 'System.Collections.Generic.Queue[string]'
        $emitted = 0L
        $eof     = $false
        while (-not $eof) {
            $n = $Reader.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) {
                $eof = $true
                if ($pending.Length -eq 0) { break }
                $chunk = [string]$delimiter   # flush an unterminated last line
            }
            else { $chunk = New-Object string -ArgumentList $buffer, 0, $n }

            $start = 0
            while (($idx = $chunk.IndexOf($delimiter, $start)) -ge 0) {
                # Substring rather than Append(string, int, int): PowerShell 7
                # binds that call to an overload that copies the whole chunk.
                $line = $chunk.Substring($start, $idx - $start)
                if ($pending.Length -gt 0) {
                    $line = $pending.Append($line).ToString()
                    [void]$pending.Clear()
                }
                $start = $idx + 1
                if ($delimiter -eq "`n" -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }

                if ($allBut) {
                    $queue.Enqueue($line)
                    if ($queue.Count -gt $count) { $queue.Dequeue() }
                }
                else {
                    $line
                    $emitted++
                    if ($emitted -ge $count) { return }
                }
            }
            if ($start -lt $chunk.Length) { [void]$pending.Append($chunk.Substring($start)) }
        }
    }

    # Returns the selected bytes of a stream as a byte[].
    function Read-HeadBytes([System.IO.Stream]$Stream) {
        $out = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 65536
        if ($allBut) {
            if ($Stream.CanSeek) { $want = [Math]::Max(0L, $Stream.Length - $Stream.Position - $count) }
            else {
                $Stream.CopyTo($out)
                $out.SetLength([Math]::Max(0L, $out.Length - $count))
                return , $out.ToArray()
            }
        }
        else { $want = $count }

        while ($out.Length -lt $want) {
            $n = $Stream.Read($buffer, 0, [int][Math]::Min([long]$buffer.Length, $want - $out.Length))
            if ($n -le 0) { break }
            $out.Write($buffer, 0, $n)
        }
        , $out.ToArray()
    }

    # Splits text into records on the delimiter, dropping the empty record
    # after a trailing delimiter and the CR of a CRLF line ending.
    function Split-Records([string]$Text) {
        $parts = $Text.Split($delimiter)
        $last = $parts.Length - 1
        if ($last -gt 0 -and $parts[$last] -eq '') { $last-- }
        for ($k = 0; $k -le $last; $k++) {
            $line = $parts[$k]
            if ($delimiter -eq "`n" -and $line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
            $line
        }
    }

    # Decodes bytes (honouring a BOM, defaulting to UTF-8) and writes lines.
    function Write-BytesAsLines([byte[]]$Bytes) {
        if ($Bytes.Length -eq 0) { return }
        $encoding = New-Object System.Text.UTF8Encoding $false
        $skip = 0
        if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
            $encoding = New-Object System.Text.UTF32Encoding $false, $false; $skip = 4
        }
        elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
            $encoding = New-Object System.Text.UTF32Encoding $true, $false; $skip = 4
        }
        elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $skip = 3 }
        elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
            $encoding = [System.Text.Encoding]::Unicode; $skip = 2
        }
        elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
            $encoding = [System.Text.Encoding]::BigEndianUnicode; $skip = 2
        }
        if ($Bytes.Length -gt $skip) { Split-Records $encoding.GetString($Bytes, $skip, $Bytes.Length - $skip) }
    }

    function Invoke-HeadStream([System.IO.Stream]$Stream) {
        if ($mode -eq 'bytes') { Write-BytesAsLines (Read-HeadBytes $Stream) }
        else {
            $reader = New-Object System.IO.StreamReader -ArgumentList $Stream, (New-Object System.Text.UTF8Encoding $false), $true
            try { Read-HeadLines $reader } finally { $reader.Dispose() }
        }
    }

    # Expands one FILE operand to @{ Path; Display } entries. Wildcards are
    # expanded only when no file has that literal name.
    function Resolve-Operand([string]$Operand) {
        $path = $Operand
        try {
            $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Operand)
            if ([System.IO.File]::Exists($path) -or [System.IO.Directory]::Exists($path)) {
                return @{ Path = $path; Display = $Operand }
            }
        }
        catch { }

        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Operand)) {
            $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            $found = @(Resolve-Path -Path $Operand -ErrorAction SilentlyContinue |
                Where-Object { $_.Provider.Name -eq 'FileSystem' })
            if ($found.Count -gt 0) {
                foreach ($f in $found) {
                    $display = $f.ProviderPath
                    if ($display.StartsWith($cwd, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $display = $display.Substring($cwd.Length)
                    }
                    @{ Path = $f.ProviderPath; Display = $display }
                }
                return
            }
        }
        @{ Path = $path; Display = $Operand }
    }

    # Opens a file for reading. Returns the stream, or an error message.
    function Open-HeadFile([string]$Path) {
        try { return [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite') }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            switch ($inner.GetType().Name) {
                'FileNotFoundException'       { 'No such file or directory' }
                'DirectoryNotFoundException'  { 'No such file or directory' }
                'UnauthorizedAccessException' { 'Permission denied' }
                default                       { $inner.Message }
            }
        }
    }

    # ------------------------------------------------------- pipeline input

    # Pipeline input is standard input. It is streamed directly when it is
    # the only input, and buffered when it must be interleaved with files.
    $expectingInput = $MyInvocation.ExpectingInput

    # Windows PowerShell 5.1 run with -File and redirected stdin reports
    # pipeline input but never delivers it; read the console stream instead.
    if ($expectingInput -and [Console]::IsInputRedirected -and -not $MyInvocation.Line) {
        $expectingInput = $false
    }

    $stdinOnly = $operands.Count -eq 0 -or ($operands.Count -eq 1 -and $operands[0] -eq '-')
    $streamPipeline = $expectingInput -and $stdinOnly

    $pipeEmitted  = 0L
    $pipeDone     = $false
    $pipeQueue    = New-Object 'System.Collections.Generic.Queue[object]'
    $pipeRecords  = New-Object 'System.Collections.Generic.List[object]'
    $pipeBytes    = New-Object System.IO.MemoryStream
    $utf8         = New-Object System.Text.UTF8Encoding $false

    # Takes one pipeline object; strings are split into lines, anything else
    # is a single record passed through as is.
    function Add-PipelineObject($InputObject) {
        if ($InputObject -is [string]) { $records = Split-Records $InputObject }
        else { $records = , $InputObject }
        foreach ($record in $records) {
            if ($allBut) {
                $pipeQueue.Enqueue($record)
                if ($pipeQueue.Count -gt $count) { , $pipeQueue.Dequeue() }
            }
            elseif ($script:pipeEmitted -lt $count) {
                , $record
                $script:pipeEmitted++
            }
            if (-not $allBut -and $script:pipeEmitted -ge $count) { $script:pipeDone = $true; return }
        }
    }

    function Add-PipelineBytes($InputObject) {
        if (-not $allBut -and $pipeBytes.Length -ge $count) { $script:pipeDone = $true; return }
        $text = [string]$InputObject
        if (-not $text.EndsWith([string]$delimiter)) { $text += $delimiter }
        $bytes = $utf8.GetBytes($text)
        $pipeBytes.Write($bytes, 0, $bytes.Length)
    }

    $showHeaders = if ($null -ne $headers) { $headers } else { $operands.Count -gt 1 }
    if ($streamPipeline) {
        if ($showHeaders) { Write-Header 'standard input' }
        if (-not $allBut -and $count -eq 0) { $pipeDone = $true }
    }
}

process {
    if (-not $expectingInput -or $null -eq $_) { return }
    if ($streamPipeline) {
        if ($pipeDone) { return }
        if ($mode -eq 'bytes') { Add-PipelineBytes $_ }
        else { Add-PipelineObject $_ }
    }
    else { $pipeRecords.Add($_) }
}

end {
    if ($streamPipeline) {
        if ($mode -eq 'bytes') {
            $pipeBytes.Position = 0
            Write-BytesAsLines (Read-HeadBytes $pipeBytes)
        }
    }
    else {
        if ($operands.Count -eq 0) { $operands.Add('-') }
        $stdinUsed = $false
        foreach ($operand in $operands) {
            if ($operand -ne '-') {
                foreach ($file in (Resolve-Operand $operand)) {
                    $display = $file.Display
                    if ([System.IO.Directory]::Exists($file.Path)) {
                        if ($showHeaders) { Write-Header $display }
                        $script:HadError = $true
                        Write-Error -ErrorRecord (New-HeadError "error reading '$display': Is a directory" 'ReadError' $display) -ErrorAction Continue
                        continue
                    }
                    $stream = Open-HeadFile $file.Path
                    if ($stream -is [string]) {
                        $script:HadError = $true
                        Write-Error -ErrorRecord (New-HeadError "cannot open '$display' for reading: $stream" 'ObjectNotFound' $display) -ErrorAction Continue
                        continue
                    }
                    if ($showHeaders) { Write-Header $display }
                    try { Invoke-HeadStream $stream }
                    catch {
                        $script:HadError = $true
                        Write-Error -ErrorRecord (New-HeadError "error reading '$display': $($_.Exception.Message)" 'ReadError' $display) -ErrorAction Continue
                    }
                    finally { $stream.Dispose() }
                }
                continue
            }

            if ($showHeaders) { Write-Header 'standard input' }
            if ($expectingInput) {
                # Standard input can only be consumed once.
                if ($stdinUsed) { continue }
                $stdinUsed = $true
                if ($mode -eq 'bytes') {
                    foreach ($item in $pipeRecords) { Add-PipelineBytes $item }
                    $pipeBytes.Position = 0
                    Write-BytesAsLines (Read-HeadBytes $pipeBytes)
                }
                elseif ($allBut -or $count -gt 0) {
                    foreach ($item in $pipeRecords) {
                        Add-PipelineObject $item
                        if ($pipeDone) { break }
                    }
                }
            }
            else {
                $stdin = [Console]::OpenStandardInput()
                try { Invoke-HeadStream $stdin }
                catch {
                    $script:HadError = $true
                    Write-Error -ErrorRecord (New-HeadError "error reading 'standard input': $($_.Exception.Message)" 'ReadError') -ErrorAction Continue
                }
            }
        }
    }

    if ($script:HadError) { exit 1 }
    exit 0
}
