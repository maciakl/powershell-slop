<#
.SYNOPSIS
    Runs a command with administrator rights, like sudo.

.DESCRIPTION
    Sudo.ps1 emulates the sudo command on Windows systems where the built-in
    sudo (Settings > System > For developers) is turned off or unavailable.

    It shows a UAC prompt and runs the given command in an elevated
    PowerShell process. By default the elevated process runs in a hidden
    window and its output, warnings and errors are streamed back into the
    current console, and its exit code becomes the exit code of Sudo.ps1.
    Input is not forwarded; use -NewWindow for interactive commands.

    Works in Windows PowerShell 5.1 and PowerShell 7+. The elevated process
    uses the same PowerShell edition as the caller and starts in the current
    directory, without loading profiles.

    The command can be given as:
      * plain words:     sudo Stop-Service -Name Spooler -Force
                         sudo netsh winsock reset
      * a script block:  sudo { Get-Service Spool* | Restart-Service }
      * a string:        sudo 'Get-Process | Sort-Object CPU | Select -Last 5'
      * !! (repeats the previous command from history): sudo !!

    Variables in plain words are expanded before elevating. Inside a script
    block or string, refer to the caller's variables with $using:Name.
    Aliases and functions defined in the current session are carried over
    when they are used as the command name.

    Sudo options must come before the command:
      -n, -NewWindow, --new-window   Run in a new elevated console window that
                                     supports input, and wait for it to close.
      -k, -NoExit, --no-exit         Like -NewWindow, but leave an elevated
                                     prompt open afterwards and don't wait.
      -h, -Help, --help              Show this help.
      --                             Stop parsing sudo options.

    With no command, an elevated PowerShell window opens in the current
    directory. The same happens for 'sudo cmd', 'sudo powershell' and
    'sudo pwsh'.

    Output streamed back from the elevated process is text, not objects.
    If the session is already elevated, the command runs directly in the
    current session and returns objects as usual.

.EXAMPLE
    PS> Set-Alias sudo C:\Tools\Sudo.ps1
    PS> sudo Restart-Service Spooler

    Puts Sudo.ps1 behind the 'sudo' name (add the alias to $PROFILE), then
    restarts a service.

.EXAMPLE
    PS> sudo Get-ChildItem C:\Windows\System32\config

.EXAMPLE
    PS> $svc = 'Spooler'
    PS> sudo { Stop-Service $using:svc; Get-Service $using:svc }

.EXAMPLE
    PS> sudo -n diskpart

    Runs an interactive program in a new elevated window.

.EXAMPLE
    PS> Set-Content C:\Windows\test.txt hi
    Set-Content: Access to the path 'C:\Windows\test.txt' is denied.
    PS> sudo !!
#>

# No param() block on purpose: an advanced script would swallow common
# parameters such as -Verbose or -ErrorAction meant for the elevated command.

$SudoMarker = [char]1   # prefixes non-output lines sent back over the pipe

function Test-SudoElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-SudoBase64([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
}

function ConvertTo-SudoQuoted([string]$Text) {
    # Doubles every kind of single quote PowerShell recognizes.
    "'" + ($Text -replace "[\u2018\u2019\u201A\u201B']", '$0$0') + "'"
}

# Turns an argument received by this script back into PowerShell source.
function ConvertTo-SudoLiteral($Value) {
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [scriptblock]) { return '{' + $Value.ToString() + '}' }
    if ($Value -is [bool]) { return '$' + $Value.ToString().ToLowerInvariant() }
    if ($Value -is [switch]) { return '$' + $Value.IsPresent.ToString().ToLowerInvariant() }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64] -or
        $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $text = $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        if ($text -match '^-?[\d.]+(E[+-]?\d+)?$') { return "($text)" }
        return ConvertTo-SudoQuoted $text   # NaN, Infinity
    }
    if ($Value -is [array]) {
        return '@(' + (($Value | ForEach-Object { ConvertTo-SudoLiteral $_ }) -join ',') + ')'
    }
    $text = [string]$Value
    # Parameter names typed by the caller (-Force, -Path:) carry this note property;
    # quoted strings that merely look like parameters do not.
    if ($Value.PSObject.Properties['<CommandParameterName>'] -and $text -match '^-[^\s''"`$;|&(){}@,<>]+:?$') {
        return $text
    }
    ConvertTo-SudoQuoted $text
}

function Write-SudoLine([string]$Line) {
    if ($Line.Length -lt 2 -or $Line[0] -ne $SudoMarker) { return $Line }
    $text = $Line.Substring(2)
    switch ($Line[1]) {
        'E' { $Host.UI.WriteErrorLine($text) }
        'W' { Write-Warning $text }
        'V' { Write-Host "VERBOSE: $text" -ForegroundColor Yellow }
        'D' { Write-Host "DEBUG: $text" -ForegroundColor Yellow }
        'I' { Write-Host $text }
    }
}

# Start of every elevated process: connects back to the caller, proves it is
# the process the caller started, and receives the command to run. Sending the
# command over the pipe avoids command-line length limits.
$SudoConnectTemplate = @'
function d($s) { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($s)) }
$p = New-Object IO.Pipes.NamedPipeClientStream('.', '%PIPE%', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Identification)
try { $p.Connect(30000) } catch { exit 255 }
$utf8 = New-Object Text.UTF8Encoding($false)
$w = New-Object IO.StreamWriter($p, $utf8)
$w.AutoFlush = $true
$w.WriteLine('%NONCE%')
$code = (New-Object IO.StreamReader($p, $utf8)).ReadLine()
if ($null -eq $code) { exit 255 }
$code = d $code
'@

# Runs in the hidden elevated process: executes the command and streams every
# output stream back to the caller.
$SudoPipedTemplate = @'
$ProgressPreference = 'SilentlyContinue'
if (Get-Variable PSStyle -ErrorAction Ignore) { $PSStyle.OutputRendering = 'PlainText' }
$t = [char]1; $wd = %WIDTH%
function lines($tag, $text) { foreach ($l in ([string]$text).TrimEnd() -split '\r?\n') { $t + $tag + $l } }
$s = @{ Err = $false }
try { Set-Location -LiteralPath (d '%DIR%') -ErrorAction Stop }
catch { foreach ($l in (lines 'W' "Could not change to directory '$(d '%DIR%')': $($_.Exception.Message)")) { $w.WriteLine($l) } }
$global:LASTEXITCODE = 0
try {
    $sb = [scriptblock]::Create($code)
    & $sb *>&1 | ForEach-Object {
        $r = $_
        if ($r -is [Management.Automation.ErrorRecord]) {
            if ($r.FullyQualifiedErrorId -like 'NativeCommandError*') { lines 'E' $r.ToString() }
            else { $s.Err = $true; lines 'E' ($r | Out-String -Width $wd) }
        }
        elseif ($r -is [Management.Automation.WarningRecord]) { lines 'W' $r.Message }
        elseif ($r -is [Management.Automation.VerboseRecord]) { lines 'V' $r.Message }
        elseif ($r -is [Management.Automation.DebugRecord]) { lines 'D' $r.Message }
        elseif ($r -is [Management.Automation.InformationRecord]) { lines 'I' $r.MessageData }
        else { $r }
    } | Out-String -Stream -Width $wd | ForEach-Object { $w.WriteLine($_) }
}
catch {
    $s.Err = $true
    foreach ($l in (lines 'E' ($_ | Out-String -Width $wd))) { $w.WriteLine($l) }
}
$c = 0
if ($global:LASTEXITCODE) { $c = $global:LASTEXITCODE } elseif ($s.Err) { $c = 1 }
$w.WriteLine($t + 'X' + $c)
$p.Dispose()
exit $c
'@

# Runs in a visible elevated console window.
$SudoWindowTemplate = @'
$p.Dispose()
Remove-Variable p, w, utf8
try { $Host.UI.RawUI.WindowTitle = 'Administrator: sudo ' + (d '%TITLE%') } catch { }
try { Set-Location -LiteralPath (d '%DIR%') -ErrorAction Stop }
catch { Write-Warning "Could not change to directory '$(d '%DIR%')': $($_.Exception.Message)" }
if ($code) {
    $global:LASTEXITCODE = 0
    $e = $Error.Count
    try { & ([scriptblock]::Create($code)) } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue }
    $c = 0
    if ($global:LASTEXITCODE) { $c = $global:LASTEXITCODE } elseif ($Error.Count -ne $e) { $c = 1 }
    if (-not %NOEXIT%) {
        if (%PAUSE%) { Write-Host; $null = Read-Host "[sudo] Exited with code $c. Press Enter to close" }
        exit $c
    }
}
'@

#region Parse sudo options

$newWindow = $false
$noExit = $false
$index = 0
while ($index -lt $args.Count -and $args[$index] -is [string]) {
    $option = $args[$index]
    if ($option -in '-n', '-NewWindow', '--new-window') { $newWindow = $true }
    elseif ($option -in '-k', '-NoExit', '--no-exit') { $newWindow = $true; $noExit = $true }
    elseif ($option -in '-h', '-Help', '--help', '/?') {
        Get-Help -Name $PSCommandPath -Detailed
        return
    }
    elseif ($option -eq '--') { $index++; break }
    else { break }
    $index++
}
$commandArgs = @()
if ($index -lt $args.Count) { $commandArgs = @($args[$index..($args.Count - 1)]) }

#endregion

#region Build the script to run elevated

$script = ''
$title = 'PowerShell'
$isShell = $false

if ($commandArgs.Count -eq 0) {
    $isShell = $true
}
elseif ($commandArgs.Count -eq 1 -and $commandArgs[0] -is [scriptblock]) {
    $script = $commandArgs[0].ToString()
}
elseif ($commandArgs.Count -eq 1 -and $commandArgs[0] -eq '!!') {
    $last = Get-History -Count 1
    if (-not $last) {
        Write-Error 'sudo: there is no previous command in the history.'
        exit 1
    }
    $script = $last.CommandLine
    Write-Host $script -ForegroundColor DarkGray
}
elseif ($commandArgs.Count -eq 1 -and $commandArgs[0] -is [string] -and $commandArgs[0] -match '\s' -and
        -not (Get-Command -Name $commandArgs[0] -ErrorAction Ignore)) {
    # A whole command line passed as one string.
    $script = $commandArgs[0]
}
else {
    $name = [string]$commandArgs[0]
    $prefix = ''
    $command = Get-Command -Name $name -ErrorAction Ignore | Select-Object -First 1
    while ($command -and $command.CommandType -eq 'Alias') { $command = $command.ResolvedCommand }
    if ($command) {
        switch ($command.CommandType.ToString()) {
            'Application' { $name = $command.Path }
            'ExternalScript' { $name = $command.Path }
            'Function' {
                $name = $command.Name
                # Session-defined functions don't exist in the new process; module
                # functions are left to autoloading.
                if (-not $command.Module) {
                    $prefix = 'Set-Item -LiteralPath ' + (ConvertTo-SudoQuoted "function:$name") +
                        ' -Value {' + $command.ScriptBlock.ToString() + "}`n"
                }
            }
            'Filter' { $name = $command.Name }
            'Cmdlet' { $name = $command.Name }
        }
        if ($commandArgs.Count -eq 1 -and $command.CommandType -eq 'Application' -and
            [IO.Path]::GetFileName($command.Path) -in 'cmd.exe', 'powershell.exe', 'pwsh.exe') {
            $isShell = $true
        }
    }
    $script = $prefix + '& ' + (ConvertTo-SudoQuoted $name)
    for ($i = 1; $i -lt $commandArgs.Count; $i++) {
        $script += ' ' + (ConvertTo-SudoLiteral $commandArgs[$i])
    }
}

if ($script) {
    # Check syntax before bothering the user with a UAC prompt.
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            Write-Error ("sudo: syntax error at line {0}, column {1}: {2}" -f
                $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
        }
        exit 1
    }

    # Replace $using:Name with a serialized copy of the caller's variable.
    $usingVariables = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.UsingExpressionAst] }, $true) |
        ForEach-Object { [Management.Automation.Language.UsingExpressionAst]::ExtractUsingVariable($_) } |
        Sort-Object { $_.Extent.StartOffset } -Descending)
    if ($usingVariables.Count -gt 0) {
        $definitions = [ordered]@{}
        foreach ($usingVariable in $usingVariables) {
            $variableName = $usingVariable.VariablePath.UserPath
            $localName = '__sudo_using_' + ($variableName -replace '\W', '_')
            $script = $script.Substring(0, $usingVariable.Extent.StartOffset) + '${' + $localName + '}' +
                $script.Substring($usingVariable.Extent.EndOffset)
            if ($definitions.Contains($localName)) { continue }
            # Scope 1 is whoever called this script; fall back to global.
            $variable = Get-Variable -Name $variableName -Scope 1 -ErrorAction Ignore
            if (-not $variable) { $variable = Get-Variable -Name $variableName -Scope Global -ErrorAction Ignore }
            if (-not $variable) {
                Write-Error "sudo: the variable `$using:$variableName is not defined."
                exit 1
            }
            $xml = [Management.Automation.PSSerializer]::Serialize($variable.Value, 2)
            $definitions[$localName] = '${' + $localName + '} = [Management.Automation.PSSerializer]::Deserialize(' +
                '[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + (ConvertTo-SudoBase64 $xml) + ''')))'
        }
        $script = (@($definitions.Values) -join "`n") + "`n" + $script
    }

    $title = ($commandArgs | ForEach-Object { if ($_ -is [scriptblock]) { "{$_}" } else { "$_" } }) -join ' '
    if ($title.Length -gt 80) { $title = $title.Substring(0, 77) + '...' }
}

#endregion

#region Run

$elevated = Test-SudoElevated

if ($elevated -and -not $newWindow -and $script) {
    # Already elevated: run in this session so objects flow as usual.
    $global:LASTEXITCODE = 0
    $errorCount = $Error.Count
    try { & ([scriptblock]::Create($script)) }
    catch { Write-Error -ErrorRecord $_ -ErrorAction Continue }
    if ($global:LASTEXITCODE) { exit $global:LASTEXITCODE }
    if ($Error.Count -ne $errorCount) { exit 1 }
    exit 0
}

if ($PSVersionTable.PSEdition -eq 'Core') { $exe = Join-Path $PSHOME 'pwsh.exe' }
else { $exe = Join-Path $PSHOME 'powershell.exe' }

$directory = $PWD.ProviderPath
if ($PWD.Provider.Name -ne 'FileSystem') { $directory = $PWD.Path }

$psArgs = @('-NoLogo', '-NoProfile')
try {
    $processPolicy = Get-ExecutionPolicy -Scope Process -ErrorAction Stop
    if ($processPolicy -ne 'Undefined') { $psArgs += '-ExecutionPolicy', $processPolicy.ToString() }
}
catch { }

if ($isShell -and -not $elevated) { $newWindow = $true }
$windowMode = $newWindow -or -not $script
$keepOpen = $noExit -or -not $script

$pipeName = 'sudo-' + [guid]::NewGuid().ToString('N')
$nonce = [guid]::NewGuid().ToString('N')
$wrapper = $SudoConnectTemplate.Replace('%PIPE%', $pipeName).Replace('%NONCE%', $nonce) + "`n"
$startParams = @{ FilePath = $exe; Verb = 'RunAs'; PassThru = $true; ErrorAction = 'Stop' }
if ($windowMode) {
    $wrapper += $SudoWindowTemplate.
        Replace('%TITLE%', (ConvertTo-SudoBase64 $title)).
        Replace('%DIR%', (ConvertTo-SudoBase64 $directory)).
        Replace('%NOEXIT%', '$' + $keepOpen.ToString().ToLowerInvariant()).
        Replace('%PAUSE%', '$' + (-not $isShell).ToString().ToLowerInvariant())
    if ($keepOpen) { $psArgs += '-NoExit' }
}
else {
    $width = 120
    try { if ($Host.UI.RawUI.BufferSize.Width -gt 20) { $width = $Host.UI.RawUI.BufferSize.Width } } catch { }
    $wrapper += $SudoPipedTemplate.
        Replace('%WIDTH%', $width).
        Replace('%DIR%', (ConvertTo-SudoBase64 $directory))
    $psArgs += '-NonInteractive'
    $startParams.WindowStyle = 'Hidden'
}
$psArgs += '-EncodedCommand', (ConvertTo-SudoBase64 $wrapper)
$startParams.ArgumentList = $psArgs

# Single-instance server, created before the elevated process starts, so no
# other process can claim the pipe name.
$server = New-Object IO.Pipes.NamedPipeServerStream($pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
    [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
$process = $null
$exitCode = 1
$reportedCode = $null
try {
    try { $process = Start-Process @startParams }
    catch {
        Write-Error "sudo: elevation failed: $($_.Exception.Message)"
        exit 1
    }
    $null = $process.Handle

    # Short waits everywhere keep Ctrl+C responsive.
    $connection = $server.BeginWaitForConnection($null, $null)
    while (-not $connection.AsyncWaitHandle.WaitOne(100)) {
        if ($process.HasExited) { break }
    }
    if (-not $connection.IsCompleted) {
        Write-Error "sudo: the elevated process exited before connecting back (exit code $($process.ExitCode))."
        exit 1
    }
    $server.EndWaitForConnection($connection)

    $utf8 = New-Object Text.UTF8Encoding($false)
    $reader = New-Object IO.StreamReader($server, $utf8)
    $writer = New-Object IO.StreamWriter($server, $utf8)
    $writer.AutoFlush = $true

    $read = $reader.ReadLineAsync()
    while (-not $read.Wait(100)) { }
    if ($read.Result -ne $nonce) {
        Write-Error 'sudo: an unexpected process connected to the elevation pipe; aborting.'
        exit 1
    }
    $writer.WriteLine((ConvertTo-SudoBase64 $script))

    if ($windowMode) {
        $server.WaitForPipeDrain()
        # Shells and -NoExit windows live on independently.
        if ($keepOpen -or $isShell) { exit 0 }
        while (-not $process.WaitForExit(200)) { }
        exit $process.ExitCode
    }

    while ($true) {
        $read = $reader.ReadLineAsync()
        while (-not $read.Wait(100)) { }
        $line = $read.Result
        if ($null -eq $line) { break }
        if ($line.Length -gt 1 -and $line[0] -eq $SudoMarker -and $line[1] -eq 'X') {
            $reportedCode = [int]$line.Substring(2)
            continue
        }
        Write-SudoLine $line
    }

    while (-not $process.WaitForExit(100)) { }
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) { $exitCode = $reportedCode }
}
finally {
    if (-not $windowMode -and $process -and -not $process.HasExited) {
        try { $process.Kill() }
        catch { Write-Warning "sudo: could not stop the elevated process (PID $($process.Id)): $($_.Exception.Message)" }
    }
    $server.Dispose()
}
exit $exitCode

#endregion
