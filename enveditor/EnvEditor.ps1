#Requires -Version 5.1
<#
.SYNOPSIS
    EnvEditor - a keyboard-driven terminal UI for viewing and editing Windows environment variables.

.DESCRIPTION
    Run normally   -> edits YOUR user variables         (HKCU\Environment)
    Run elevated   -> edits SYSTEM-WIDE machine variables (HKLM\SYSTEM\...\Session Manager\Environment)

    * Lists every variable with type badges and colour-coded path checks
    * Create, edit and delete variables; deleting Windows-required variables shows a warning
    * List variables (PATH, PATHEXT, PSModulePath, or any value containing ';') open in a
      list editor: one entry per line, add / edit / delete / reorder, ';' delimiters are
      handled automatically
    * Values that look like filesystem paths are checked on disk; missing ones are flagged
    * In elevated (system-wide) mode every change must be confirmed before it is written

    Values are read from and written to the registry directly so REG_EXPAND_SZ values
    (e.g. %SystemRoot%\system32) keep their unexpanded form and type. Running programs are
    notified of the change (WM_SETTINGCHANGE); open a new terminal to see the new values.

    No external modules or dependencies. Works with Windows PowerShell 5.1 (built into
    Windows 11) and PowerShell 7, in conhost or Windows Terminal. The PowerShell ISE is not
    supported because it has no real console.

.EXAMPLE
    .\EnvEditor.ps1
    Edit the current user's environment variables.

.EXAMPLE
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\EnvEditor.ps1"'
    Launch elevated to edit system-wide variables.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ============================================================================ host checks

if ($Host.Name -eq 'Windows PowerShell ISE Host') {
    Write-Error 'EnvEditor needs a real console window (powershell.exe, pwsh.exe or Windows Terminal); the ISE is not supported.'
    return
}
try {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { throw 'redirected' }
    $null = [Console]::WindowWidth
    $null = [Console]::KeyAvailable
} catch {
    Write-Error 'EnvEditor needs an interactive console window (input/output must not be redirected).'
    return
}

# ============================================================================ configuration

# Glyphs are built from code points so this file stays pure ASCII (Windows PowerShell 5.1
# reads BOM-less scripts using the ANSI code page).
$script:G = @{
    H   = [string][char]0x2500; V   = [string][char]0x2502
    TL  = [string][char]0x250C; TR  = [string][char]0x2510
    BL  = [string][char]0x2514; BR  = [string][char]0x2518
    Ptr = [string][char]0x25BA; Ell = [string][char]0x2026
    Ok  = [string][char]0x221A; Bad = [string][char]0x00D7
    Up  = [string][char]0x2191; Dn  = [string][char]0x2193
    Dot = [string][char]0x00B7; Arr = [string][char]0x2192
    Tri = [string][char]0x25B2
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:UserName = $identity.Name
$script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($script:IsAdmin) {
    $script:Scope      = 'Machine'
    $script:ScopeLabel = 'SYSTEM'
    $script:RegDisplay = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $script:Theme      = @{ BannerBg = 'DarkRed';  BannerFg = 'White'; Accent = 'Red';  Rule = 'DarkRed'  }
} else {
    $script:Scope      = 'User'
    $script:ScopeLabel = 'USER'
    $script:RegDisplay = 'HKCU\Environment'
    $script:Theme      = @{ BannerBg = 'DarkCyan'; BannerFg = 'White'; Accent = 'Cyan'; Rule = 'DarkGray' }
}

# Variables that are always treated as ';'-delimited lists, even with a single entry.
$script:ListNames = @{}
foreach ($n in 'Path', 'PATHEXT', 'PSModulePath', 'CLASSPATH', 'INCLUDE', 'LIB', 'LIBPATH', 'PYTHONPATH') {
    $script:ListNames[$n] = $true
}

# Standard variables Windows (or nearly all software) expects to exist. Deleting one needs
# the user to type its name. Hashtable keys are case-insensitive.
$script:ProtectedInfo = @{
    'Path'                    = 'Windows and nearly every program use PATH to locate executables.'
    'PATHEXT'                 = 'Defines which file extensions can be run as commands.'
    'ComSpec'                 = 'Points to the command interpreter (cmd.exe) used by Windows and many tools.'
    'windir'                  = 'Points to the Windows directory; used by Windows components and installers.'
    'SystemRoot'              = 'Points to the Windows directory; used by Windows components and installers.'
    'SystemDrive'             = 'Identifies the drive Windows is installed on.'
    'OS'                      = 'Identifies the operating system to scripts and build tools.'
    'TEMP'                    = 'Location for temporary files used by Windows, installers and applications.'
    'TMP'                     = 'Location for temporary files used by Windows, installers and applications.'
    'PSModulePath'            = 'PowerShell uses this to locate its modules.'
    'DriverData'              = 'Data directory used by device drivers.'
    'NUMBER_OF_PROCESSORS'    = 'Describes the CPU; set by Windows and read by scripts and build tools.'
    'PROCESSOR_ARCHITECTURE'  = 'Describes the CPU; set by Windows and read by scripts and installers.'
    'PROCESSOR_IDENTIFIER'    = 'Describes the CPU; set by Windows and read by scripts and build tools.'
    'PROCESSOR_LEVEL'         = 'Describes the CPU; set by Windows and read by scripts and build tools.'
    'PROCESSOR_REVISION'      = 'Describes the CPU; set by Windows and read by scripts and build tools.'
    'USERNAME'                = 'Identifies the account; set by Windows.'
    'USERPROFILE'             = 'Points to the user profile folder.'
    'APPDATA'                 = 'Points to the roaming application data folder.'
    'LOCALAPPDATA'            = 'Points to the local application data folder.'
    'ProgramData'             = 'Points to the shared application data folder.'
    'ProgramFiles'            = 'Points to the Program Files folder.'
    'ProgramFiles(x86)'       = 'Points to the 32-bit Program Files folder.'
    'ProgramW6432'            = 'Points to the 64-bit Program Files folder.'
    'CommonProgramFiles'      = 'Points to the Common Files folder.'
    'CommonProgramFiles(x86)' = 'Points to the 32-bit Common Files folder.'
    'CommonProgramW6432'      = 'Points to the 64-bit Common Files folder.'
    'ALLUSERSPROFILE'         = 'Points to the shared profile folder.'
    'PUBLIC'                  = 'Points to the Public user folder.'
    'HOMEDRIVE'               = 'Identifies the drive of the user home folder.'
    'HOMEPATH'                = 'Identifies the user home folder.'
    'OneDrive'                = 'Used by OneDrive and Known Folder redirection.'
}

$script:MaxValueLength = 32767
$script:PathCache   = @{}
$script:VarLookup   = @{}
$script:Vars        = New-Object System.Collections.Generic.List[object]
$script:ChangeLog   = New-Object System.Collections.Generic.List[string]
$script:StatusText  = $null
$script:StatusColor = 'Gray'
$script:SelectName  = $null

# ============================================================================ registry access

function Open-EnvKey([bool]$Writable) {
    if ($script:IsAdmin) {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $Writable)
    } else {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $Writable)
        if ($null -eq $k) { $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    }
    if ($null -eq $k) { throw "Unable to open registry key $($script:RegDisplay)" }
    return $k
}

function Import-EnvVars {
    $items = New-Object System.Collections.Generic.List[object]
    $key = Open-EnvKey $false
    try {
        foreach ($n in $key.GetValueNames()) {
            if ([string]::IsNullOrEmpty($n)) { continue }
            $kind = $key.GetValueKind($n)
            $raw = $key.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($raw -is [array]) { $raw = ($raw | ForEach-Object { [string]$_ }) -join ';' }
            $items.Add([pscustomobject]@{ Name = $n; Value = [string]$raw; Kind = $kind })
        }
    } finally { $key.Close() }

    $script:VarLookup = @{}
    foreach ($i in $items) { $script:VarLookup[$i.Name] = $i.Value }
    $script:PathCache = @{}
    $script:Vars = New-Object System.Collections.Generic.List[object]
    foreach ($i in ($items | Sort-Object Name)) { $script:Vars.Add((Get-VarInfo $i)) }
}

function Save-EnvVar([string]$Name, [string]$Value, $Kind) {
    $k = [Microsoft.Win32.RegistryValueKind]::String
    if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString -or $Value -match '%[^%;]+%') {
        $k = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }
    $key = Open-EnvKey $true
    try { $key.SetValue($Name, $Value, $k) } finally { $key.Close() }
}

function Remove-EnvVar([string]$Name) {
    $key = Open-EnvKey $true
    try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
}

# Removing a variable that does not exist is a no-op for the registry, but .NET still
# broadcasts WM_SETTINGCHANGE("Environment") - which is exactly what we want, without P/Invoke.
function Send-EnvChangeNotification {
    try { [Environment]::SetEnvironmentVariable('__EnvEditor_Notify__', $null, $script:Scope) } catch { }
}

# ============================================================================ analysis

function Split-EnvList([string]$Value) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in ($Value -split ';')) {
        $t = $p.Trim()
        if ($t.Length -gt 0) { $list.Add($t) }
    }
    return , $list
}

# Expands %NAME% using the variables of the scope being edited first (so freshly created
# variables resolve), then the process environment.
function Expand-EnvText([string]$Text) {
    if ($null -eq $Text -or $Text.IndexOf('%') -lt 0) { return $Text }
    $eval = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $n = $m.Groups[1].Value
        $v = $script:VarLookup[$n]
        if ($null -ne $v) { return [Environment]::ExpandEnvironmentVariables($v) }
        $pv = [Environment]::GetEnvironmentVariable($n)
        if ($null -ne $pv) { return $pv }
        return $m.Value
    }
    return [regex]::Replace($Text, '%([^%;]+)%', $eval)
}

# Returns: none | ok | missing | unresolved | network
function Get-PathState([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    if ($script:PathCache.ContainsKey($Text)) { return $script:PathCache[$Text] }
    $t = $Text.Trim().Trim('"')
    $e = (Expand-EnvText $t).Trim().Trim('"')
    $state = 'none'
    if ($e -match '%[^%;]+%' -and ($t -match '^%' -or $t -match '\\')) {
        $state = 'unresolved'
    } elseif ($e -match '^\\\\') {
        $state = 'network'          # UNC paths are not probed: unreachable hosts can hang the UI
    } elseif ($e -match '^[A-Za-z]:([\\/]|$)') {
        try {
            if ([IO.Directory]::Exists($e) -or [IO.File]::Exists($e)) { $state = 'ok' } else { $state = 'missing' }
        } catch { $state = 'missing' }
    }
    $script:PathCache[$Text] = $state
    return $state
}

function Get-VarInfo($Item) {
    $entries = Split-EnvList $Item.Value
    $isList = $script:ListNames.ContainsKey($Item.Name) -or $entries.Count -ge 2
    $missing = 0; $unresolved = 0; $paths = 0
    $state = 'none'
    if ($isList) {
        foreach ($e in $entries) {
            switch (Get-PathState $e) {
                'ok'         { $paths++ }
                'network'    { $paths++ }
                'missing'    { $paths++; $missing++ }
                'unresolved' { $unresolved++ }
            }
        }
        if ($missing -gt 0) { $state = 'missing' }
        elseif ($unresolved -gt 0) { $state = 'unresolved' }
        elseif ($paths -gt 0) { $state = 'ok' }
        $badge = 'LIST'
    } else {
        $state = Get-PathState $Item.Value
        if ($state -eq 'missing') { $missing = 1 }
        if ($state -eq 'none') { $badge = 'TEXT' } else { $badge = 'PATH' }
    }
    return [pscustomobject]@{
        Name       = $Item.Name
        Value      = $Item.Value
        Kind       = $Item.Kind
        IsList     = $isList
        Entries    = $entries
        State      = $state
        Missing    = $missing
        Unresolved = $unresolved
        Paths      = $paths
        Badge      = $badge
        Protected  = $script:ProtectedInfo.ContainsKey($Item.Name)
    }
}

function Get-NormalizedEntry([string]$Entry) {
    $e = (Expand-EnvText $Entry).Trim().Trim('"').TrimEnd('\', '/')
    if ($e.Length -eq 0) { $e = $Entry }
    return $e.ToLowerInvariant()
}

function Get-KindLabel($Kind) {
    switch ([string]$Kind) {
        'String'       { return 'REG_SZ' }
        'ExpandString' { return 'REG_EXPAND_SZ' }
        default        { return ('REG_' + ([string]$Kind).ToUpper()) }
    }
}

# ============================================================================ drawing primitives

function Get-Printable([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '[\x00-\x1F]', ' ')
}

function Format-Fit([string]$s, [int]$n) {
    if ($n -le 0) { return '' }
    if ($s.Length -gt $n) {
        if ($n -ge 2) { return $s.Substring(0, $n - 1) + $script:G.Ell }
        return $s.Substring(0, $n)
    }
    return $s.PadRight($n)
}

# Builds a line from alternating text/colour arguments: Segs 'a' 'Red' 'b' 'Gray'
function Segs {
    $l = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $args.Count; $i += 2) {
        $fg = 'Gray'
        if ($i + 1 -lt $args.Count) { $fg = $args[$i + 1] }
        $l.Add(@([string]$args[$i], $fg, $null))
    }
    return , $l
}

function New-Body { return , (New-Object System.Collections.Generic.List[object]) }

# Writes a line of segments (text, fg, bg) at X,Row, clipped / padded to exactly Width chars.
function Write-Segs {
    param([int]$X, [int]$Row, $Line, [int]$Width, [string]$FillBg = 'Black')
    if ($Width -le 0) { return }
    try { [Console]::SetCursorPosition($X, $Row) } catch { return }
    $used = 0
    if ($null -ne $Line) {
        foreach ($s in $Line) {
            $room = $Width - $used
            if ($room -le 0) { break }
            $t = [string]$s[0]
            if ($t.Length -eq 0) { continue }
            if ($t.Length -gt $room) {
                if ($room -ge 2) { $t = $t.Substring(0, $room - 1) + $script:G.Ell } else { $t = $t.Substring(0, $room) }
            }
            $bg = $s[2]
            if (-not $bg) { $bg = $FillBg }
            [Console]::ForegroundColor = $s[1]
            [Console]::BackgroundColor = $bg
            [Console]::Write($t)
            $used += $t.Length
        }
    }
    if ($used -lt $Width) {
        [Console]::BackgroundColor = $FillBg
        [Console]::Write(' ' * ($Width - $used))
    }
}

function Reset-Screen {
    [Console]::BackgroundColor = 'Black'
    [Console]::ForegroundColor = 'Gray'
    [Console]::Clear()
}

function Get-Layout([int]$DetailRows) {
    $H = [Console]::WindowHeight
    $W = [Console]::WindowWidth
    if ($H -lt 24) { $DetailRows = [Math]::Min($DetailRows, 3) }
    $listRows = $H - 4 - $DetailRows - 2
    return @{
        W = $W; H = $H
        ListTop = 3; ListRows = $listRows
        SepRow = 3 + $listRows
        DetailTop = 4 + $listRows; DetailRows = $DetailRows
        StatusRow = $H - 2; HelpRow = $H - 1
    }
}

function Test-WindowSize($Lay) {
    if ($Lay.W -ge 60 -and $Lay.H -ge 16) { return $true }
    Reset-Screen
    [Console]::ForegroundColor = 'Yellow'
    [Console]::Write("Window too small ($($Lay.W)x$($Lay.H)).`r`nEnlarge to at least 60x16, or press Q to quit.")
    return $false
}

# Waits for a key; returns $null if the window was resized (caller redraws).
function Read-Key {
    $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
    while (-not [Console]::KeyAvailable) {
        Start-Sleep -Milliseconds 50
        if ([Console]::WindowWidth -ne $w -or [Console]::WindowHeight -ne $h) {
            Reset-Screen
            return $null
        }
    }
    return [Console]::ReadKey($true)
}

function Get-ScrollTop([int]$Sel, [int]$Top, [int]$Rows, [int]$Count) {
    if ($Rows -lt 1) { return 0 }
    if ($Sel -lt $Top) { $Top = $Sel }
    if ($Sel -ge $Top + $Rows) { $Top = $Sel - $Rows + 1 }
    $max = [Math]::Max(0, $Count - $Rows)
    if ($Top -gt $max) { $Top = $max }
    if ($Top -lt 0) { $Top = 0 }
    return $Top
}

# Returns the new selection index for navigation keys, or $null for anything else.
function Get-NavIndex($Key, [int]$Sel, [int]$Count, [int]$Page) {
    $mods = $Key.Modifiers -band ([ConsoleModifiers]::Shift -bor [ConsoleModifiers]::Control -bor [ConsoleModifiers]::Alt)
    if ($mods -ne 0 -and ($Key.Key -eq 'UpArrow' -or $Key.Key -eq 'DownArrow')) { return $null }
    $step = [Math]::Max(1, $Page - 1)
    $n = $null
    switch ([string]$Key.Key) {
        'UpArrow'   { $n = $Sel - 1 }
        'DownArrow' { $n = $Sel + 1 }
        'PageUp'    { $n = $Sel - $step }
        'PageDown'  { $n = $Sel + $step }
        'Home'      { $n = 0 }
        'End'       { $n = $Count - 1 }
    }
    if ($null -eq $n) { return $null }
    if ($n -ge $Count) { $n = $Count - 1 }
    if ($n -lt 0) { $n = 0 }
    return $n
}

function Set-Status([string]$Text, [string]$Color = 'Gray') {
    $script:StatusText = $Text
    $script:StatusColor = $Color
}

function Split-Wrap([string]$Text, [int]$Width) {
    $out = New-Object System.Collections.Generic.List[string]
    if ($Width -lt 1) { $Width = 1 }
    if ([string]::IsNullOrEmpty($Text)) { $out.Add(''); return , $out }
    for ($i = 0; $i -lt $Text.Length; $i += $Width) {
        $out.Add($Text.Substring($i, [Math]::Min($Width, $Text.Length - $i)))
    }
    return , $out
}

function Get-StateGlyph([string]$State) {
    switch ($State) {
        'ok'         { return @($script:G.Ok, 'Green') }
        'missing'    { return @($script:G.Bad, 'Red') }
        'unresolved' { return @('?', 'Yellow') }
        'network'    { return @('~', 'DarkGray') }
    }
    return @(' ', 'Gray')
}

function Get-StateColor([string]$State, [bool]$Selected) {
    switch ($State) {
        'missing'    { return 'Red' }
        'unresolved' { return 'Yellow' }
        'network'    { return 'DarkGray' }
    }
    if ($Selected) { return 'White' }
    return 'Gray'
}

# ============================================================================ common screen parts

function Write-Banner([string]$Right) {
    $W = [Console]::WindowWidth - 1
    $bg = $script:Theme.BannerBg
    $fg = $script:Theme.BannerFg
    $l = New-Object System.Collections.Generic.List[object]
    if ($script:IsAdmin) {
        $left = " $($script:G.Tri) ELEVATED $($script:G.Tri)  ADMINISTRATOR MODE: EDITING SYSTEM-WIDE (MACHINE) VARIABLES - changes affect ALL users "
        $l.Add(@($left, 'Yellow', $bg))
    } else {
        $l.Add(@(' EnvEditor ', 'Black', 'Cyan'))
        $l.Add(@("  USER environment variables for $($script:UserName) ", $fg, $bg))
    }
    $len = 0
    foreach ($s in $l) { $len += $s[0].Length }
    $r = " $Right "
    if ($len + $r.Length -lt $W) {
        $l.Add(@((' ' * ($W - $len - $r.Length)), $fg, $bg))
        $l.Add(@($r, $fg, $bg))
    }
    Write-Segs 0 0 $l $W $bg
}

function Write-Rule([int]$Row, [string]$Label) {
    $W = [Console]::WindowWidth - 1
    $c = $script:Theme.Rule
    $lbl = ''
    if ($Label) { $lbl = " $Label " }
    $rest = [Math]::Max(0, $W - 2 - $lbl.Length)
    Write-Segs 0 $Row (Segs ($script:G.H * 2) $c $lbl 'Gray' ($script:G.H * $rest) $c) $W
}

function Write-Help([int]$Row, [string[]]$Pairs) {
    $l = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Pairs.Count; $i += 2) {
        $l.Add(@(" $($Pairs[$i]) ", 'Black', 'Gray'))
        $l.Add(@(" $($Pairs[$i + 1])  ", 'Gray', 'Black'))
    }
    Write-Segs 0 $Row $l ([Console]::WindowWidth - 1)
}

function Write-StatusRow([int]$Row, $Override) {
    $W = [Console]::WindowWidth - 1
    if ($null -ne $Override) { Write-Segs 0 $Row $Override $W; return }
    if ($script:StatusText) {
        Write-Segs 0 $Row (Segs " $($script:StatusText)" $script:StatusColor) $W
    } elseif ($script:IsAdmin) {
        Write-Segs 0 $Row (Segs ' SYSTEM-WIDE MODE: ' 'Red' 'every change is shown for confirmation before it is written.' 'DarkGray') $W
    } else {
        Write-Segs 0 $Row $null $W
    }
}

function Draw-Box([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title, [string]$Color) {
    $G = $script:G
    $t = ''
    if ($Title) { $t = " $Title " }
    if ($t.Length -gt $W - 4) { $t = $t.Substring(0, [Math]::Max(0, $W - 4)) }
    $l = New-Object System.Collections.Generic.List[object]
    $l.Add(@(($G.TL + $G.H), $Color, $null))
    $l.Add(@($t, 'Black', $Color))
    $l.Add(@((($G.H * ($W - 3 - $t.Length)) + $G.TR), $Color, $null))
    Write-Segs $X $Y $l $W
    for ($r = 1; $r -lt $H - 1; $r++) {
        Write-Segs $X ($Y + $r) (Segs $G.V $Color (' ' * ($W - 2)) 'Gray' $G.V $Color) $W
    }
    Write-Segs $X ($Y + $H - 1) (Segs ($G.BL + ($G.H * ($W - 2)) + $G.BR) $Color) $W
}

# Single-line editor. Returns the text on Enter, $null on Esc.
# $Check (optional) is called with the current text and returns a line shown at CheckRow.
function Read-InputLine {
    param([int]$X, [int]$Row, [int]$Width, [string]$Initial = '',
          [scriptblock]$Check, [int]$CheckX, [int]$CheckRow, [int]$CheckW)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Initial)
    $pos = $sb.Length
    $scroll = 0
    $lastCheck = $null
    try {
        while ($true) {
            $text = $sb.ToString()
            $viewW = [Math]::Max(1, $Width - 1)
            if ($pos -lt $scroll) { $scroll = $pos }
            if ($pos - $scroll -gt $viewW) { $scroll = $pos - $viewW }
            $vis = ''
            if ($scroll -lt $text.Length) { $vis = $text.Substring($scroll, [Math]::Min($Width, $text.Length - $scroll)) }
            [Console]::CursorVisible = $false
            $line = New-Object System.Collections.Generic.List[object]
            if ($scroll -gt 0 -and $vis.Length -gt 0) {
                $line.Add(@('<', 'Cyan', 'DarkBlue'))
                $vis = $vis.Substring(1)
            }
            $line.Add(@((Get-Printable $vis), 'White', 'DarkBlue'))
            Write-Segs $X $Row $line $Width 'DarkBlue'
            if ($Check -and $text -cne $lastCheck) {
                Write-Segs $CheckX $CheckRow (& $Check $text) $CheckW
                $lastCheck = $text
            }
            [Console]::SetCursorPosition($X + $pos - $scroll, $Row)
            [Console]::CursorVisible = $true

            # Process every queued key before redrawing (keeps pasting fast).
            do {
                $k = [Console]::ReadKey($true)
                $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
                switch ([string]$k.Key) {
                    'Enter'      { return $sb.ToString() }
                    'Escape'     { return $null }
                    'LeftArrow'  {
                        if ($ctrl) {
                            while ($pos -gt 0 -and $sb[$pos - 1] -match '[\s\\;/]') { $pos-- }
                            while ($pos -gt 0 -and $sb[$pos - 1] -notmatch '[\s\\;/]') { $pos-- }
                        } elseif ($pos -gt 0) { $pos-- }
                    }
                    'RightArrow' {
                        if ($ctrl) {
                            while ($pos -lt $sb.Length -and $sb[$pos] -notmatch '[\s\\;/]') { $pos++ }
                            while ($pos -lt $sb.Length -and $sb[$pos] -match '[\s\\;/]') { $pos++ }
                        } elseif ($pos -lt $sb.Length) { $pos++ }
                    }
                    'Home'       { $pos = 0 }
                    'End'        { $pos = $sb.Length }
                    'Backspace'  { if ($pos -gt 0) { [void]$sb.Remove($pos - 1, 1); $pos-- } }
                    'Delete'     { if ($pos -lt $sb.Length) { [void]$sb.Remove($pos, 1) } }
                    default {
                        if ($ctrl -and $k.Key -eq 'U') { [void]$sb.Clear(); $pos = 0 }
                        elseif ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                            [void]$sb.Insert($pos, [string]$k.KeyChar); $pos++
                        }
                    }
                }
            } while ([Console]::KeyAvailable)
        }
    } finally {
        [Console]::CursorVisible = $false
    }
}

# Live feedback line shown under the input box while typing a value.
function Get-ValueCheckSegs([string]$Text) {
    $G = $script:G
    if ($Text.Length -gt $script:MaxValueLength) {
        return , (Segs "$($G.Bad) Too long: $($Text.Length) chars (max $($script:MaxValueLength))" 'Red')
    }
    $entries = Split-EnvList $Text
    if ($entries.Count -ge 2) {
        $miss = 0
        foreach ($e in $entries) { if ((Get-PathState $e) -eq 'missing') { $miss++ } }
        if ($miss -gt 0) { return , (Segs "$($entries.Count) entries  " 'Cyan' "$($G.Bad) $miss not found on disk" 'Red') }
        return , (Segs "$($entries.Count) entries" 'Cyan')
    }
    switch (Get-PathState $Text) {
        'ok'         { return , (Segs "$($G.Ok) Path exists" 'Green') }
        'missing'    { return , (Segs "$($G.Bad) Not found on disk: " 'Red' (Get-Printable (Expand-EnvText $Text.Trim())) 'DarkGray') }
        'unresolved' { return , (Segs '? Contains an undefined %variable% reference' 'Yellow') }
        'network'    { return , (Segs '~ Network path (not checked)' 'DarkGray') }
    }
    return , (Segs '' 'Gray')
}

function Read-InputDialog {
    param([string]$Title, [string]$Label = 'Value:', [string]$Initial = '', $Body, [switch]$CheckPath)
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    $bw = [Math]::Max(40, $W - 6)
    $bx = [Math]::Floor(($W - $bw) / 2)
    $bodyCount = 0
    if ($null -ne $Body) { $bodyCount = $Body.Count }
    $bh = 2 + $bodyCount + 1 + 1 + 2   # borders, body, input, check row, blank + hint
    $by = [Math]::Max(0, [Math]::Floor(($H - $bh) / 2))
    $accent = $script:Theme.Accent
    Draw-Box $bx $by $bw $bh $Title $accent
    for ($i = 0; $i -lt $bodyCount; $i++) { Write-Segs ($bx + 2) ($by + 1 + $i) $Body[$i] ($bw - 4) }
    $inRow = $by + 1 + $bodyCount
    $checkRow = $inRow + 1
    $hintRow = $by + $bh - 2
    Write-Segs ($bx + 2) $inRow (Segs "$Label " 'Yellow') ($Label.Length + 1)
    Write-Segs ($bx + 2) $hintRow (Segs 'Enter' 'Yellow' ' accept   ' 'DarkGray' 'Esc' 'Yellow' ' cancel   ' 'DarkGray' `
            "$([char]0x2190)$([char]0x2192) Home End Ctrl+$([char]0x2190)$([char]0x2192)" 'Yellow' ' move   ' 'DarkGray' 'Ctrl+U' 'Yellow' ' clear' 'DarkGray') ($bw - 4)
    $check = $null
    if ($CheckPath) { $check = { param($t) Get-ValueCheckSegs $t } }
    $ix = $bx + 2 + $Label.Length + 1
    return Read-InputLine -X $ix -Row $inRow -Width ($bw - 4 - $Label.Length - 1) -Initial $Initial `
        -Check $check -CheckX ($bx + 2) -CheckRow $checkRow -CheckW ($bw - 4)
}

# Modal confirmation. Returns $true only on 'Y' (or when RequireText is typed exactly).
function Show-Confirm {
    param([string]$Title, $Body, [string]$Prompt = 'Proceed? [y/N]', [string]$Accent = 'Yellow', [string]$RequireText)
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    $contentW = [Math]::Max(30, $Prompt.Length + 20)
    foreach ($ln in $Body) {
        $len = 0
        foreach ($s in $ln) { $len += ([string]$s[0]).Length }
        if ($len -gt $contentW) { $contentW = $len }
    }
    $bw = [Math]::Min($W - 4, $contentW + 4)
    $lines = New-Object System.Collections.Generic.List[object]
    $maxBody = [Math]::Max(1, $H - 8)
    foreach ($ln in $Body) { $lines.Add($ln) }
    if ($lines.Count -gt $maxBody) {
        $extra = $lines.Count - $maxBody + 1
        $lines.RemoveRange($maxBody - 1, $lines.Count - $maxBody + 1)
        $lines.Add((Segs "$($script:G.Ell) and $extra more line(s)" 'DarkGray'))
    }
    $bh = $lines.Count + 4
    $bx = [Math]::Floor(($W - $bw) / 2)
    $by = [Math]::Max(0, [Math]::Floor(($H - $bh) / 2))
    Draw-Box $bx $by $bw $bh $Title $Accent
    for ($i = 0; $i -lt $lines.Count; $i++) { Write-Segs ($bx + 2) ($by + 1 + $i) $lines[$i] ($bw - 4) }
    $prow = $by + $bh - 2
    Write-Segs ($bx + 2) $prow (Segs $Prompt 'Yellow') ($bw - 4)
    if ($RequireText) {
        $px = $bx + 2 + $Prompt.Length + 1
        $in = Read-InputLine -X $px -Row $prow -Width ([Math]::Max(10, $bw - 4 - $Prompt.Length - 1))
        return ($null -ne $in -and $in.Trim() -eq $RequireText)
    }
    [Console]::CursorVisible = $false
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Y') { return $true }
        if ($k.Key -eq 'N' -or $k.Key -eq 'Escape' -or $k.Key -eq 'Enter') { return $false }
    }
}

# ============================================================================ change operations

function Add-WrappedLines($Body, [string]$Prefix, [string]$PrefixColor, [string]$Text, [string]$Color, [int]$MaxLines = 4) {
    $w = [Math]::Max(20, [Console]::WindowWidth - 12 - $Prefix.Length)
    $parts = Split-Wrap (Get-Printable $Text) $w
    $pad = ' ' * $Prefix.Length
    for ($i = 0; $i -lt $parts.Count -and $i -lt $MaxLines; $i++) {
        $p = $pad; if ($i -eq 0) { $p = $Prefix }
        $t = $parts[$i]
        if ($i -eq $MaxLines - 1 -and $parts.Count -gt $MaxLines) { $t += $script:G.Ell }
        $Body.Add((Segs $p $PrefixColor $t $Color))
    }
}

function Get-ChangeBody([string]$Name, $OldValue, [string]$NewValue, [bool]$IsList) {
    $body = New-Body
    $body.Add((Segs 'Variable: ' 'DarkGray' $Name 'White' '    Scope: ' 'DarkGray' 'SYSTEM - all users of this computer' 'Red'))
    $body.Add((Segs '' 'Gray'))
    if ($null -eq $OldValue) {
        $body.Add((Segs 'New variable' 'Cyan'))
        Add-WrappedLines $body '  + ' 'Green' $NewValue 'Green' 8
    } elseif ($IsList -or ($OldValue.Contains(';') -and $NewValue.Contains(';'))) {
        $old = Split-EnvList $OldValue
        $new = Split-EnvList $NewValue
        $oldSet = @{}; foreach ($e in $old) { $oldSet[$e] = $true }
        $newSet = @{}; foreach ($e in $new) { $newSet[$e] = $true }
        $changes = 0
        foreach ($e in $old) { if (-not $newSet.ContainsKey($e)) { $body.Add((Segs '  - ' 'Red' (Get-Printable $e) 'Red')); $changes++ } }
        foreach ($e in $new) { if (-not $oldSet.ContainsKey($e)) { $body.Add((Segs '  + ' 'Green' (Get-Printable $e) 'Green')); $changes++ } }
        if (($old -join ';') -cne ($new -join ';') -and $changes -eq 0) {
            $body.Add((Segs '  Entry order changed / duplicates removed' 'Yellow'))
        } elseif ($changes -eq 0) {
            $body.Add((Segs '  Formatting only (empty entries / whitespace removed)' 'Yellow'))
        }
        $body.Add((Segs '' 'Gray'))
        $body.Add((Segs "Entries: $($old.Count) $($script:G.Arr) $($new.Count)" 'DarkGray'))
    } else {
        Add-WrappedLines $body 'Old: ' 'DarkGray' $OldValue 'Red'
        Add-WrappedLines $body 'New: ' 'DarkGray' $NewValue 'Green'
    }
    $body.Add((Segs '' 'Gray'))
    return , $body
}

# Writes a new or changed value. $OldValue = $null for a new variable.
function Invoke-SaveVar {
    param([string]$Name, $OldValue, [string]$NewValue, $Kind, [bool]$IsList = $false)
    if ($null -ne $OldValue -and $NewValue -ceq $OldValue) { Set-Status 'No changes to save.' 'DarkGray'; return $false }
    if ($NewValue.Trim().Length -eq 0) { Set-Status 'A value cannot be empty - delete the variable instead.' 'Red'; return $false }
    if ($NewValue.Length -gt $script:MaxValueLength) {
        Set-Status "Value is $($NewValue.Length) chars; the Windows limit is $($script:MaxValueLength). Nothing saved." 'Red'
        return $false
    }
    if ($script:IsAdmin) {
        $body = Get-ChangeBody $Name $OldValue $NewValue $IsList
        $ok = Show-Confirm -Title 'CONFIRM SYSTEM-WIDE CHANGE' -Body $body -Accent 'Red' `
            -Prompt 'Write this change to the SYSTEM environment? [y/N]'
        if (-not $ok) { Set-Status 'Cancelled - nothing was saved.' 'Yellow'; return $false }
    }
    try {
        Save-EnvVar $Name $NewValue $Kind
        Send-EnvChangeNotification
    } catch {
        Set-Status "Save failed: $($_.Exception.Message)" 'Red'
        return $false
    }
    if ($null -eq $OldValue) { $script:ChangeLog.Add("Created  $Name") } else { $script:ChangeLog.Add("Modified $Name") }
    Import-EnvVars
    $script:SelectName = $Name
    Set-Status "Saved $Name to the $($script:ScopeLabel) environment. New terminals will see the change." 'Green'
    return $true
}

function Edit-Var($V) {
    $body = New-Body
    $body.Add((Segs 'Editing the raw value of ' 'DarkGray' $V.Name 'White' "  ($(Get-KindLabel $V.Kind))" 'DarkGray'))
    if ($V.IsList) { $body.Add((Segs "Tip: press Esc, then L to edit this as a list (one entry per line)." 'DarkGray')) }
    $new = Read-InputDialog -Title "Edit $($V.Name)" -Initial $V.Value -Body $body -CheckPath
    if ($null -eq $new) { Set-Status 'Edit cancelled.' 'DarkGray'; return }
    [void](Invoke-SaveVar -Name $V.Name -OldValue $V.Value -NewValue $new -Kind $V.Kind)
}

function New-Var {
    $body = New-Body
    $body.Add((Segs "Create a new $($script:ScopeLabel) environment variable." 'Gray'))
    $name = Read-InputDialog -Title 'New variable (1/2)' -Label 'Name:' -Body $body
    if ($null -eq $name) { Set-Status 'Cancelled.' 'DarkGray'; return }
    $name = $name.Trim()
    if ($name.Length -eq 0) { Set-Status 'A variable name is required.' 'Red'; return }
    if ($name.Contains('=') -or $name -match '[\x00-\x1F]') { Set-Status "Invalid name '$name' (no '=' or control characters allowed)." 'Red'; return }
    foreach ($v in $script:Vars) {
        if ($v.Name -eq $name) {
            $script:SelectName = $v.Name
            Set-Status "'$($v.Name)' already exists - editing it instead." 'Yellow'
            if ($v.IsList) { Invoke-ListEditor $v } else { Edit-Var $v }
            return
        }
    }
    $body = New-Body
    $body.Add((Segs 'Name: ' 'DarkGray' $name 'White'))
    $body.Add((Segs "Separate multiple entries with ';' to create a list (e.g. a PATH-style variable)." 'DarkGray'))
    $value = Read-InputDialog -Title "New variable (2/2): $name" -Body $body -CheckPath
    if ($null -eq $value) { Set-Status 'Cancelled - variable not created.' 'DarkGray'; return }
    [void](Invoke-SaveVar -Name $name -OldValue $null -NewValue $value -Kind $null -IsList $false)
}

function Remove-Var($V) {
    $body = New-Body
    if ($V.Protected) {
        $body.Add((Segs 'WARNING: ' 'Red' "$($V.Name) is a standard Windows variable that needs to exist." 'Yellow'))
        $body.Add((Segs $script:ProtectedInfo[$V.Name] 'Gray'))
        $body.Add((Segs 'Deleting it can break Windows features, the shell, installers and many programs.' 'Gray'))
        $body.Add((Segs '' 'Gray'))
    }
    $body.Add((Segs 'Variable: ' 'DarkGray' $V.Name 'White'))
    Add-WrappedLines $body 'Value:    ' 'DarkGray' $V.Value 'Gray' 3
    $body.Add((Segs '' 'Gray'))
    if ($script:IsAdmin) {
        $body.Add((Segs 'This deletes the SYSTEM-WIDE variable for ALL users of this computer.' 'Red'))
    } else {
        $body.Add((Segs "This deletes your USER variable. A SYSTEM variable with the same name (if any) is not affected." 'DarkGray'))
    }
    if ($V.Protected) {
        $ok = Show-Confirm -Title 'DELETE WINDOWS-REQUIRED VARIABLE' -Body $body -Accent 'Red' `
            -RequireText $V.Name -Prompt 'Type the variable name to confirm:'
    } else {
        $accent = 'Yellow'; if ($script:IsAdmin) { $accent = 'Red' }
        $ok = Show-Confirm -Title "Delete $($V.Name)?" -Body $body -Accent $accent -Prompt 'Delete this variable? [y/N]'
    }
    if (-not $ok) { Set-Status 'Not deleted.' 'Yellow'; return }
    try {
        Remove-EnvVar $V.Name
        Send-EnvChangeNotification
    } catch {
        Set-Status "Delete failed: $($_.Exception.Message)" 'Red'
        return
    }
    $script:ChangeLog.Add("Deleted  $($V.Name)")
    Import-EnvVars
    Set-Status "Deleted $($V.Name) from the $($script:ScopeLabel) environment." 'Green'
}

# ============================================================================ main screen

function Get-VarRowSegs($V, [bool]$Selected, [int]$NameW) {
    $bg = 'Black'; if ($Selected) { $bg = 'DarkBlue' }
    $l = New-Object System.Collections.Generic.List[object]
    if ($Selected) { $l.Add(@(" $($script:G.Ptr) ", $script:Theme.Accent, $bg)) } else { $l.Add(@('   ', 'Gray', $bg)) }
    $nfg = 'White'; if ($V.Protected) { $nfg = 'Yellow' }
    $l.Add(@((Format-Fit $V.Name $NameW), $nfg, $bg))
    $l.Add(@(' ', 'Gray', $bg))
    $bfg = 'DarkGray'
    if ($V.Badge -eq 'LIST') { $bfg = 'Cyan' } elseif ($V.Badge -eq 'PATH') { $bfg = 'Green' }
    $l.Add(@($V.Badge, $bfg, $bg))
    $gl = Get-StateGlyph $V.State
    $l.Add(@(' ', 'Gray', $bg))
    $l.Add(@($gl[0], $gl[1], $bg))
    $l.Add(@(' ', 'Gray', $bg))
    if ($V.IsList) {
        $l.Add(@("[$($V.Entries.Count)] ", 'DarkCyan', $bg))
        $n = 0
        foreach ($e in $V.Entries) {
            if ($n -gt 0) { $l.Add(@(';', 'DarkCyan', $bg)) }
            $l.Add(@((Get-Printable $e), (Get-StateColor (Get-PathState $e) $Selected), $bg))
            $n++
            if ($n -ge 40) { break }
        }
    } else {
        $l.Add(@((Get-Printable $V.Value), (Get-StateColor $V.State $Selected), $bg))
    }
    return , $l
}

function Show-VarDetail($V, $Lay) {
    $W = $Lay.W - 1
    $G = $script:G
    $rows = New-Object System.Collections.Generic.List[object]
    if ($null -ne $V) {
        $l1 = Segs ' ' 'Gray' $V.Name 'White' "   $(Get-KindLabel $V.Kind)" 'DarkGray' "   $($V.Value.Length) chars" 'DarkGray'
        if ($V.Protected) { $l1.Add(@('   [Windows-required variable]', 'Yellow', $null)) }
        $rows.Add($l1)

        if ($V.IsList) {
            $l2 = Segs ' ' 'Gray' "List of $($V.Entries.Count) entries" 'Cyan'
            if ($V.Missing -gt 0) { $l2.Add(@("   $($G.Bad) $($V.Missing) not found on disk", 'Red', $null)) }
            if ($V.Unresolved -gt 0) { $l2.Add(@("   ? $($V.Unresolved) with undefined %variables%", 'Yellow', $null)) }
            if ($V.Missing -eq 0 -and $V.Unresolved -eq 0 -and $V.Paths -gt 0) { $l2.Add(@("   $($G.Ok) all paths exist", 'Green', $null)) }
            $l2.Add(@('    Enter = open list editor', 'DarkGray', $null))
            $rows.Add($l2)
        } else {
            switch ($V.State) {
                'ok'         { $rows.Add((Segs ' ' 'Gray' "$($G.Ok) Path exists on disk" 'Green')) }
                'missing'    { $rows.Add((Segs ' ' 'Gray' "$($G.Bad) Path does NOT exist on disk: " 'Red' (Get-Printable (Expand-EnvText $V.Value)) 'Red')) }
                'unresolved' { $rows.Add((Segs ' ' 'Gray' '? References an undefined %variable% - cannot check the path' 'Yellow')) }
                'network'    { $rows.Add((Segs ' ' 'Gray' '~ Network (UNC) path - not checked' 'DarkGray')) }
                default      { $rows.Add((Segs ' ' 'Gray' 'Plain value (not a filesystem path)' 'DarkGray')) }
            }
        }

        $exp = Expand-EnvText $V.Value
        $showExp = (-not $V.IsList) -and ($exp -cne $V.Value)
        $avail = $Lay.DetailRows - $rows.Count
        if ($showExp) { $avail-- }
        if ($V.IsList) { $text = $V.Entries -join '; ' } else { $text = $V.Value }
        $wrapped = Split-Wrap (Get-Printable $text) ($W - 3)
        for ($i = 0; $i -lt $avail -and $i -lt $wrapped.Count; $i++) {
            $t = $wrapped[$i]
            if ($i -eq $avail - 1 -and $wrapped.Count -gt $avail) { $t = $t.Substring(0, [Math]::Max(0, $t.Length - 1)) + $G.Ell }
            $rows.Add((Segs '   ' 'Gray' $t 'Gray'))
        }
        if ($showExp) { $rows.Add((Segs '   ' 'Gray' "$($G.Arr) " 'DarkCyan' (Get-Printable $exp) 'DarkCyan')) }
    }
    for ($i = 0; $i -lt $Lay.DetailRows; $i++) {
        $segs = $null
        if ($i -lt $rows.Count) { $segs = $rows[$i] }
        Write-Segs 0 ($Lay.DetailTop + $i) $segs $W
    }
}

function Show-MainScreen($View, [int]$Sel, [int]$Top, [string]$Filter, [bool]$FilterMode, $Lay) {
    [Console]::CursorVisible = $false
    $W = $Lay.W - 1
    Write-Banner "$($script:Vars.Count) variables"

    $info = Segs ' Registry: ' 'DarkGray' $script:RegDisplay 'Gray'
    if ($Filter) { $info.Add(@("    filter: ", 'DarkGray', $null)); $info.Add(@($Filter, 'Yellow', $null)) }
    Write-Segs 0 1 $info $W

    $nameW = 4
    foreach ($v in $View) { if ($v.Name.Length -gt $nameW) { $nameW = $v.Name.Length } }
    $nameW = [Math]::Min($nameW, [Math]::Max(12, [Math]::Floor($Lay.W * 0.3)))
    Write-Segs 0 2 (Segs ('   ' + (Format-Fit 'NAME' $nameW) + ' TYPE   VALUE') 'DarkGray') $W

    for ($i = 0; $i -lt $Lay.ListRows; $i++) {
        $idx = $Top + $i
        $segs = $null
        if ($idx -lt $View.Count) { $segs = Get-VarRowSegs $View[$idx] ($idx -eq $Sel) $nameW }
        elseif ($i -eq 0) {
            if ($Filter) { $segs = Segs '   (no variables match the filter - Esc clears it)' 'DarkGray' }
            else { $segs = Segs '   (no variables defined - press N to create one)' 'DarkGray' }
        }
        Write-Segs 0 ($Lay.ListTop + $i) $segs $W
    }

    $label = '0 / 0'
    if ($View.Count -gt 0) { $label = "$($Sel + 1) / $($View.Count)" }
    Write-Rule $Lay.SepRow $label
    $cur = $null
    if ($View.Count -gt 0) { $cur = $View[$Sel] }
    Show-VarDetail $cur $Lay

    $override = $null
    if ($FilterMode) {
        $override = Segs ' Filter: ' 'Yellow' $Filter 'White' '_' 'Yellow' '    type to filter by name or value  Enter keep  Esc clear' 'DarkGray'
    }
    Write-StatusRow $Lay.StatusRow $override
    Write-Help $Lay.HelpRow @("$($script:G.Up)$($script:G.Dn)", 'Move', 'Enter', 'Edit', 'N', 'New', 'Del', 'Delete',
        'L', 'List editor', '/', 'Filter', 'C', 'Copy', 'R', 'Reload', 'F1', 'Help', 'Q', 'Quit')
}

function Show-HelpScreen {
    Reset-Screen
    $G = $script:G
    $W = [Console]::WindowWidth - 1
    $lines = New-Body
    $lines.Add((Segs ''))
    $lines.Add((Segs ' MAIN SCREEN' 'Cyan'))
    $lines.Add((Segs "   $($G.Up) $($G.Dn) PgUp PgDn Home End  " 'Yellow' 'move the selection' 'Gray'))
    $lines.Add((Segs '   Enter                    ' 'Yellow' 'edit (list variables open the list editor)' 'Gray'))
    $lines.Add((Segs '   E / F2                   ' 'Yellow' 'edit the raw value on one line' 'Gray'))
    $lines.Add((Segs '   L                        ' 'Yellow' 'open any variable in the list editor' 'Gray'))
    $lines.Add((Segs '   N / Insert               ' 'Yellow' 'create a new variable' 'Gray'))
    $lines.Add((Segs '   D / Delete               ' 'Yellow' 'delete the selected variable' 'Gray'))
    $lines.Add((Segs '   / or Ctrl+F              ' 'Yellow' 'filter by name or value (Esc clears)' 'Gray'))
    $lines.Add((Segs '   C                        ' 'Yellow' 'copy the value to the clipboard' 'Gray'))
    $lines.Add((Segs '   R / F5                   ' 'Yellow' 'reload from the registry' 'Gray'))
    $lines.Add((Segs '   Q / Esc / Ctrl+C         ' 'Yellow' 'quit' 'Gray'))
    $lines.Add((Segs ''))
    $lines.Add((Segs ' LIST EDITOR' 'Cyan'))
    $lines.Add((Segs '   Enter / E                ' 'Yellow' "edit entry (typing ';' splits it into several entries)" 'Gray'))
    $lines.Add((Segs '   A / Insert,  I           ' 'Yellow' 'add entry below / insert entry above' 'Gray'))
    $lines.Add((Segs '   D / Delete               ' 'Yellow' 'remove entry' 'Gray'))
    $lines.Add((Segs "   Shift+$($G.Up)$($G.Dn) or Ctrl+$($G.Up)$($G.Dn)    " 'Yellow' 'move entry up / down  (also + and -)' 'Gray'))
    $lines.Add((Segs '   C  /  X                  ' 'Yellow' 'remove duplicate entries / remove entries missing on disk' 'Gray'))
    $lines.Add((Segs '   U / Ctrl+Z               ' 'Yellow' 'undo' 'Gray'))
    $lines.Add((Segs '   S / Ctrl+S               ' 'Yellow' 'save    Esc: back (asks before discarding changes)' 'Gray'))
    $lines.Add((Segs ''))
    $lines.Add((Segs ' LEGEND' 'Cyan'))
    $lines.Add((Segs '   LIST ' 'Cyan' "';'-separated list    " 'Gray' 'PATH ' 'Green' 'filesystem path    ' 'Gray' 'TEXT ' 'DarkGray' 'other value' 'Gray'))
    $lines.Add((Segs "   $($G.Ok) " 'Green' 'path exists    ' 'Gray' "$($G.Bad) " 'Red' 'not found on disk    ' 'Gray' '? ' 'Yellow' 'undefined %var%    ' 'Gray' '~ ' 'DarkGray' 'network path (not checked)' 'Gray'))
    $lines.Add((Segs '   Yellow names ' 'Yellow' 'are standard Windows variables; deleting one requires typing its name.' 'Gray'))
    $lines.Add((Segs ''))
    if ($script:IsAdmin) {
        $lines.Add((Segs ' Running ELEVATED: editing SYSTEM variables for all users. Every change is confirmed before saving.' 'Red'))
    } else {
        $lines.Add((Segs ' Editing USER variables. Run PowerShell as Administrator to edit SYSTEM-wide variables.' 'DarkGray'))
    }
    Write-Banner 'Help'
    $H = [Console]::WindowHeight
    for ($i = 0; $i -lt $H - 2; $i++) {
        $segs = $null
        if ($i -lt $lines.Count) { $segs = $lines[$i] }
        Write-Segs 0 (1 + $i) $segs $W
    }
    Write-Help ($H - 1) @('any key', 'Back')
    $null = [Console]::ReadKey($true)
}

function Invoke-MainLoop {
    $sel = 0; $top = 0; $filter = ''; $filterMode = $false
    while ($true) {
        $view = New-Object System.Collections.Generic.List[object]
        foreach ($v in $script:Vars) {
            if ($filter.Length -eq 0 -or
                $v.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $v.Value.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $view.Add($v) }
        }
        if ($script:SelectName) {
            for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Name -eq $script:SelectName) { $sel = $i; break } }
            $script:SelectName = $null
        }
        if ($sel -ge $view.Count) { $sel = $view.Count - 1 }
        if ($sel -lt 0) { $sel = 0 }

        $lay = Get-Layout 7
        if (-not (Test-WindowSize $lay)) {
            $k = Read-Key
            if ($null -ne $k -and ($k.Key -eq 'Q' -or $k.Key -eq 'Escape')) { return }
            Reset-Screen
            continue
        }
        $top = Get-ScrollTop $sel $top $lay.ListRows $view.Count
        Show-MainScreen $view $sel $top $filter $filterMode $lay

        $k = Read-Key
        if ($null -eq $k) { continue }
        $script:StatusText = $null
        $cur = $null
        if ($view.Count -gt 0) { $cur = $view[$sel] }
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $key = [string]$k.Key

        if ($ctrl -and $key -eq 'C') { return }
        $nav = Get-NavIndex $k $sel $view.Count $lay.ListRows
        if ($null -ne $nav) { $sel = $nav; continue }

        if ($filterMode) {
            if ($key -eq 'Enter') { $filterMode = $false }
            elseif ($key -eq 'Escape') { $filter = ''; $filterMode = $false }
            elseif ($key -eq 'Backspace') { if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) }; $sel = 0 }
            elseif ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) { $filter += $k.KeyChar; $sel = 0 }
            continue
        }

        if ($key -eq 'Escape' -or $key -eq 'Q') {
            if ($filter) { $filter = ''; continue }
            return
        }
        elseif ($key -eq 'Enter') {
            if ($cur) { if ($cur.IsList) { Invoke-ListEditor $cur } else { Edit-Var $cur } }
        }
        elseif ($key -eq 'E' -or $key -eq 'F2') { if ($cur) { Edit-Var $cur } }
        elseif ($key -eq 'L') { if ($cur) { Invoke-ListEditor $cur } }
        elseif ($key -eq 'N' -or $key -eq 'Insert') { New-Var }
        elseif ($key -eq 'D' -or $key -eq 'Delete') { if ($cur) { Remove-Var $cur } }
        elseif ($k.KeyChar -eq '/' -or ($ctrl -and $key -eq 'F')) { $filterMode = $true }
        elseif ($key -eq 'C') {
            if ($cur) {
                try { Set-Clipboard -Value $cur.Value; Set-Status "Copied the value of $($cur.Name) to the clipboard." 'Green' }
                catch { Set-Status "Clipboard error: $($_.Exception.Message)" 'Red' }
            }
        }
        elseif ($key -eq 'R' -or $key -eq 'F5') {
            if ($cur) { $script:SelectName = $cur.Name }
            Import-EnvVars
            Set-Status 'Reloaded from the registry.' 'Green'
        }
        elseif ($key -eq 'F1' -or $k.KeyChar -eq '?' -or $key -eq 'H') { Show-HelpScreen; Reset-Screen }
    }
}

# ============================================================================ list editor

function Invoke-ListEditor($V) {
    $G = $script:G
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($e in $V.Entries) { $entries.Add($e) }
    $undo = New-Object System.Collections.Generic.List[object]
    $sel = 0; $top = 0
    $script:StatusText = $null

    # Snapshot for undo before each change.
    $push = { $undo.Add($entries.ToArray()); if ($undo.Count -gt 100) { $undo.RemoveAt(0) } }
    # Splits user input on ';' and inserts the parts at $at. Returns the number inserted.
    $insertParts = {
        param([string]$Text, [int]$At)
        $parts = Split-EnvList $Text
        for ($j = 0; $j -lt $parts.Count; $j++) { $entries.Insert($At + $j, $parts[$j]) }
        return $parts.Count
    }

    while ($true) {
        $lay = Get-Layout 4
        if (-not (Test-WindowSize $lay)) {
            $k = Read-Key
            if ($null -ne $k -and ($k.Key -eq 'Q' -or $k.Key -eq 'Escape')) { return }
            Reset-Screen
            continue
        }
        $W = $lay.W - 1
        if ($sel -ge $entries.Count) { $sel = $entries.Count - 1 }
        if ($sel -lt 0) { $sel = 0 }
        $top = Get-ScrollTop $sel $top $lay.ListRows $entries.Count

        # Analyse entries: path state + duplicates.
        $states = New-Object 'string[]' $entries.Count
        $dupOf = New-Object 'int[]' $entries.Count
        $seen = @{}
        $missing = 0; $dups = 0
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $states[$i] = Get-PathState $entries[$i]
            if ($states[$i] -eq 'missing') { $missing++ }
            $nk = Get-NormalizedEntry $entries[$i]
            if ($seen.ContainsKey($nk)) { $dupOf[$i] = $seen[$nk] + 1; $dups++ } else { $seen[$nk] = $i }
        }
        $newValue = $entries -join ';'
        $dirty = $newValue -cne $V.Value

        # ---- draw
        [Console]::CursorVisible = $false
        Write-Banner "List editor: $($V.Name)"
        $info = Segs ' ' 'Gray' $V.Name 'White' "   $($entries.Count) entries" 'Cyan'
        if ($missing -gt 0) { $info.Add(@("   $($G.Bad) $missing missing", 'Red', $null)) }
        if ($dups -gt 0) { $info.Add(@("   $dups duplicate(s)", 'Yellow', $null)) }
        $lenColor = 'DarkGray'; if ($newValue.Length -gt $script:MaxValueLength) { $lenColor = 'Red' }
        $info.Add(@("   $($newValue.Length) chars", $lenColor, $null))
        if ($dirty) { $info.Add(@('   * MODIFIED - not saved yet (S to save)', 'Yellow', $null)) }
        Write-Segs 0 1 $info $W
        $numW = [Math]::Max(2, ([string]$entries.Count).Length)
        Write-Segs 0 2 (Segs ('   ' + '#'.PadLeft($numW) + '     ENTRY') 'DarkGray') $W

        for ($i = 0; $i -lt $lay.ListRows; $i++) {
            $idx = $top + $i
            $segs = $null
            if ($idx -lt $entries.Count) {
                $isSel = ($idx -eq $sel)
                $bg = 'Black'; if ($isSel) { $bg = 'DarkBlue' }
                $segs = New-Object System.Collections.Generic.List[object]
                if ($isSel) { $segs.Add(@(" $($G.Ptr) ", $script:Theme.Accent, $bg)) } else { $segs.Add(@('   ', 'Gray', $bg)) }
                $segs.Add(@(([string]($idx + 1)).PadLeft($numW), 'DarkGray', $bg))
                $gl = Get-StateGlyph $states[$idx]
                $segs.Add(@('  ', 'Gray', $bg))
                $segs.Add(@($gl[0], $gl[1], $bg))
                $segs.Add(@('  ', 'Gray', $bg))
                $fg = Get-StateColor $states[$idx] $isSel
                if ($dupOf[$idx] -gt 0 -and $states[$idx] -ne 'missing') { $fg = 'Yellow' }
                $segs.Add(@((Get-Printable $entries[$idx]), $fg, $bg))
                if ($dupOf[$idx] -gt 0) { $segs.Add(@("   (duplicate of #$($dupOf[$idx]))", 'Yellow', $bg)) }
                if ($states[$idx] -eq 'missing') { $segs.Add(@('   (not found on disk)', 'Red', $bg)) }
            } elseif ($i -eq 0 -and $entries.Count -eq 0) {
                $segs = Segs '   (list is empty - press A to add an entry)' 'DarkGray'
            }
            Write-Segs 0 ($lay.ListTop + $i) $segs $W
        }

        $label = '0 / 0'
        if ($entries.Count -gt 0) { $label = "$($sel + 1) / $($entries.Count)" }
        Write-Rule $lay.SepRow $label

        $drows = New-Object System.Collections.Generic.List[object]
        if ($entries.Count -gt 0) {
            $e = $entries[$sel]
            $drows.Add((Segs ' Entry: ' 'DarkGray' (Get-Printable $e) 'White'))
            $exp = Expand-EnvText $e
            if ($exp -cne $e) { $drows.Add((Segs ' Expands to: ' 'DarkGray' (Get-Printable $exp) 'DarkCyan')) }
            switch ($states[$sel]) {
                'ok'         { $drows.Add((Segs " $($G.Ok) Exists on disk" 'Green')) }
                'missing'    { $drows.Add((Segs " $($G.Bad) Does NOT exist on disk" 'Red')) }
                'unresolved' { $drows.Add((Segs ' ? References an undefined %variable%' 'Yellow')) }
                'network'    { $drows.Add((Segs ' ~ Network (UNC) path - not checked' 'DarkGray')) }
                default      { $drows.Add((Segs ' Not a filesystem path' 'DarkGray')) }
            }
            if ($dupOf[$sel] -gt 0) { $drows.Add((Segs " Duplicate of entry #$($dupOf[$sel]) - press C to remove duplicates" 'Yellow')) }
        }
        for ($i = 0; $i -lt $lay.DetailRows; $i++) {
            $segs = $null
            if ($i -lt $drows.Count) { $segs = $drows[$i] }
            Write-Segs 0 ($lay.DetailTop + $i) $segs $W
        }
        Write-StatusRow $lay.StatusRow $null
        Write-Help $lay.HelpRow @("$($G.Up)$($G.Dn)", 'Move', "Shift+$($G.Up)$($G.Dn)", 'Reorder', 'Enter', 'Edit', 'A', 'Add',
            'I', 'Insert above', 'Del', 'Remove', 'C', 'Dedupe', 'X', 'Drop missing', 'U', 'Undo', 'S', 'Save', 'Esc', 'Back')

        # ---- input
        $k = Read-Key
        if ($null -eq $k) { continue }
        $script:StatusText = $null
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
        $key = [string]$k.Key

        $nav = Get-NavIndex $k $sel $entries.Count $lay.ListRows
        if ($null -ne $nav) { $sel = $nav; continue }

        if (($key -eq 'UpArrow' -and ($shift -or $ctrl)) -or $k.KeyChar -eq '-') {
            if ($sel -gt 0) {
                & $push
                $t = $entries[$sel]; $entries[$sel] = $entries[$sel - 1]; $entries[$sel - 1] = $t; $sel--
            }
        }
        elseif (($key -eq 'DownArrow' -and ($shift -or $ctrl)) -or $k.KeyChar -eq '+') {
            if ($sel -lt $entries.Count - 1) {
                & $push
                $t = $entries[$sel]; $entries[$sel] = $entries[$sel + 1]; $entries[$sel + 1] = $t; $sel++
            }
        }
        elseif ($key -eq 'Enter' -or $key -eq 'E' -or $key -eq 'F2') {
            if ($entries.Count -eq 0) { continue }
            $body = New-Body
            $body.Add((Segs "Entry #$($sel + 1) of $($V.Name). Typing ';' splits it into several entries; clearing it removes the entry." 'DarkGray'))
            $r = Read-InputDialog -Title "Edit entry #$($sel + 1)" -Label 'Entry:' -Initial $entries[$sel] -Body $body -CheckPath
            if ($null -eq $r) { Set-Status 'Edit cancelled.' 'DarkGray'; continue }
            if ($r.Trim() -ceq $entries[$sel]) { continue }
            & $push
            $entries.RemoveAt($sel)
            $n = & $insertParts $r $sel
            if ($n -eq 0) { Set-Status 'Entry removed (it was cleared).' 'Yellow' }
            elseif ($n -gt 1) { Set-Status "Entry split into $n entries." 'Cyan' }
        }
        elseif ($key -eq 'A' -or $key -eq 'Insert' -or $key -eq 'I') {
            $above = ($key -eq 'I')
            $at = 0
            if ($entries.Count -gt 0) { if ($above) { $at = $sel } else { $at = $sel + 1 } }
            $body = New-Body
            $where = 'at the end'
            if ($entries.Count -gt 0) { if ($above) { $where = "above #$($sel + 1)" } else { $where = "below #$($sel + 1)" } }
            $body.Add((Segs "New entry for $($V.Name), inserted $where. Separate several entries with ';'." 'DarkGray'))
            $r = Read-InputDialog -Title 'Add entry' -Label 'Entry:' -Body $body -CheckPath
            if ($null -eq $r) { Set-Status 'Cancelled.' 'DarkGray'; continue }
            $parts = Split-EnvList $r
            if ($parts.Count -eq 0) { Set-Status 'Nothing added (entry was empty).' 'DarkGray'; continue }
            & $push
            $n = & $insertParts $r $at
            $sel = $at
            Set-Status "Added $n entr$(if ($n -eq 1) { 'y' } else { 'ies' }) - press S to save." 'Cyan'
        }
        elseif ($key -eq 'D' -or $key -eq 'Delete') {
            if ($entries.Count -eq 0) { continue }
            & $push
            $removed = $entries[$sel]
            $entries.RemoveAt($sel)
            Set-Status "Removed '$removed' - U to undo, S to save." 'Yellow'
        }
        elseif ($key -eq 'C' -and -not $ctrl) {
            if ($dups -eq 0) { Set-Status 'No duplicates found.' 'DarkGray'; continue }
            & $push
            for ($i = $entries.Count - 1; $i -ge 0; $i--) { if ($dupOf[$i] -gt 0) { $entries.RemoveAt($i) } }
            Set-Status "Removed $dups duplicate entr$(if ($dups -eq 1) { 'y' } else { 'ies' })." 'Cyan'
        }
        elseif ($key -eq 'X') {
            if ($missing -eq 0) { Set-Status 'No missing paths.' 'DarkGray'; continue }
            $body = New-Body
            $body.Add((Segs 'These entries do not exist on disk and will be removed from the list:' 'Gray'))
            for ($i = 0; $i -lt $entries.Count; $i++) {
                if ($states[$i] -eq 'missing') { $body.Add((Segs "  $($G.Bad) " 'Red' (Get-Printable $entries[$i]) 'Red')) }
            }
            $body.Add((Segs '(Nothing is written until you press S.)' 'DarkGray'))
            if (Show-Confirm -Title 'Remove missing paths' -Body $body -Prompt "Remove $missing entr$(if ($missing -eq 1) { 'y' } else { 'ies' })? [y/N]") {
                & $push
                for ($i = $entries.Count - 1; $i -ge 0; $i--) { if ($states[$i] -eq 'missing') { $entries.RemoveAt($i) } }
                Set-Status "Removed $missing missing entr$(if ($missing -eq 1) { 'y' } else { 'ies' })." 'Cyan'
            }
        }
        elseif ($key -eq 'U' -or ($ctrl -and $key -eq 'Z')) {
            if ($undo.Count -eq 0) { Set-Status 'Nothing to undo.' 'DarkGray'; continue }
            $snap = $undo[$undo.Count - 1]
            $undo.RemoveAt($undo.Count - 1)
            $entries.Clear()
            foreach ($e in $snap) { $entries.Add($e) }
            Set-Status 'Undone.' 'Cyan'
        }
        elseif ($key -eq 'S') {
            if (-not $dirty) { Set-Status 'No changes to save.' 'DarkGray'; continue }
            if ($entries.Count -eq 0) { Set-Status 'The list is empty - delete the variable from the main screen instead.' 'Red'; continue }
            if (Invoke-SaveVar -Name $V.Name -OldValue $V.Value -NewValue $newValue -Kind $V.Kind -IsList $true) { return }
        }
        elseif ($key -eq 'Escape' -or $key -eq 'Q' -or ($ctrl -and $key -eq 'C')) {
            if ($dirty) {
                $body = New-Body
                $body.Add((Segs "$($V.Name) has unsaved changes." 'Gray'))
                if (-not (Show-Confirm -Title 'Discard changes?' -Body $body -Prompt 'Discard changes and go back? [y/N]')) { continue }
                Set-Status "Changes to $($V.Name) discarded." 'Yellow'
            }
            $script:SelectName = $V.Name
            return
        }
        elseif ($key -eq 'F1' -or $k.KeyChar -eq '?') { Show-HelpScreen; Reset-Screen }
    }
}

# ============================================================================ entry point

$saved = @{
    Fg    = [Console]::ForegroundColor
    Bg    = [Console]::BackgroundColor
    Enc   = [Console]::OutputEncoding
    CtrlC = [Console]::TreatControlCAsInput
    Title = $Host.UI.RawUI.WindowTitle
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Console]::TreatControlCAsInput = $true
    if ($script:IsAdmin) { $Host.UI.RawUI.WindowTitle = 'EnvEditor - ADMINISTRATOR - SYSTEM-WIDE variables' }
    else { $Host.UI.RawUI.WindowTitle = "EnvEditor - USER variables ($($script:UserName))" }

    Import-EnvVars
    Reset-Screen
    Invoke-MainLoop
} finally {
    [Console]::TreatControlCAsInput = $saved.CtrlC
    [Console]::ForegroundColor = $saved.Fg
    [Console]::BackgroundColor = $saved.Bg
    [Console]::CursorVisible = $true
    [Console]::Clear()
    [Console]::OutputEncoding = $saved.Enc
    $Host.UI.RawUI.WindowTitle = $saved.Title
}

if ($script:ChangeLog.Count -gt 0) {
    Write-Host "EnvEditor: $($script:ChangeLog.Count) change(s) written to the $($script:ScopeLabel) environment:" -ForegroundColor Green
    foreach ($c in $script:ChangeLog) { Write-Host "  $c" }
    Write-Host 'Open a new terminal (or restart programs) to pick up the new values.' -ForegroundColor DarkGray
} else {
    Write-Host 'EnvEditor: no changes made.' -ForegroundColor DarkGray
}
