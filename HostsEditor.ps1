#Requires -Version 5.1
<#
.SYNOPSIS
    Keyboard-driven TUI editor for the Windows hosts file.

.DESCRIPTION
    Single-file editor for %SystemRoot%\System32\drivers\etc\hosts, written for
    Windows PowerShell 5.1 (the version that ships with Windows 11).

    - Relaunches itself elevated (UAC prompt) when not running as Administrator.
    - Invalid lines are shown in red, new lines in green, modified lines in
      yellow and lines marked for deletion in magenta.
    - New entries can be typed or pasted; a multi-line paste adds one entry per line.
    - Saving writes the file (after copying the old one to hosts.bak), reloads it
      from disk and confirms that the file was saved.

.NOTES
    Run with:  powershell.exe -ExecutionPolicy Bypass -File .\HostsEditor.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ elevation --

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The ISE has no real console (no ReadKey), so always relaunch from there too.
if (-not (Test-IsAdministrator) -or $Host.Name -eq 'Windows PowerShell ISE Host') {
    if (-not $PSCommandPath) {
        Write-Host 'Save this script as a .ps1 file and run it from disk so it can elevate itself.' -ForegroundColor Red
        return
    }
    $exe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $PSHOME 'pwsh.exe' }
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath

    # Inside Windows Terminal (WT_SESSION is set), reopen in Windows Terminal rather than
    # letting Windows pick the default console host. wt.exe treats ';' as a command separator.
    $launches = @()
    $wt = Get-Command 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($env:WT_SESSION -and $wt) {
        $wtArgs = 'new-tab --title "Hosts Editor" "{0}" {1}' -f $exe, $argList
        $launches += ,@($wt.Source, ($wtArgs -replace ';', '\;'))
    }
    $launches += ,@($exe, $argList)

    for ($i = 0; $i -lt $launches.Count; $i++) {
        try {
            # Process.Start (unlike Start-Process) surfaces the Win32 error code.
            $psi = New-Object System.Diagnostics.ProcessStartInfo $launches[$i][0], $launches[$i][1]
            $psi.UseShellExecute = $true
            $psi.Verb = 'runas'
            [void][System.Diagnostics.Process]::Start($psi)
            break
        } catch {
            $native = $_.Exception.GetBaseException() -as [System.ComponentModel.Win32Exception]
            # 1223 = the user declined the UAC prompt; don't ask again with the fallback.
            if ($i -eq $launches.Count - 1 -or ($native -and $native.NativeErrorCode -eq 1223)) {
                Write-Host 'Administrator rights are required to edit the hosts file. Elevation was cancelled or failed:' -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
                break
            }
        }
    }
    return
}

# ---------------------------------------------------------------------- state --

$script:HostsPath    = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:Entries      = New-Object 'System.Collections.Generic.List[object]'
$script:Visible      = New-Object 'System.Collections.Generic.List[int]'   # indexes into Entries
$script:Pos          = 0        # selected row (index into Visible)
$script:Top          = 0        # first row of Visible shown on screen
$script:HideComments = $false
$script:Status       = ''
$script:StatusColor  = [ConsoleColor]::Gray
$script:Stats        = @{ Changed = 0; Invalid = 0; Hosts = 0 }
$script:LastW        = 0
$script:LastH        = 0
$script:Running      = $true

$script:TabGlyph = [string][char]0x00BB   # how a tab character is shown in the line editor
$script:Ellipsis = [string][char]0x2026
$script:BoxH  = [string][char]0x2500
$script:BoxV  = [string][char]0x2502
$script:BoxTL = [string][char]0x250C
$script:BoxTR = [string][char]0x2510
$script:BoxBL = [string][char]0x2514
$script:BoxBR = [string][char]0x2518

$script:IPv4Regex = [regex]'^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
$script:HostRegex = [regex]'^(?=.{1,253}\.?$)[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?$'
$script:Whitespace = [char[]]@(' ', "`t")

# ----------------------------------------------------------------- validation --

function Test-IPAddress([string]$Text) {
    if ($script:IPv4Regex.IsMatch($Text)) { return $true }
    if ($Text.Contains(':')) {
        $address = $null
        if ([System.Net.IPAddress]::TryParse($Text, [ref]$address)) {
            return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
        }
    }
    return $false
}

# Returns Kind (Blank / Comment / Entry), Valid and a Reason for invalid lines.
function Test-HostsLine([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return [pscustomobject]@{ Kind = 'Blank'; Valid = $true; Reason = '' } }
    if ($t[0] -eq '#')   { return [pscustomobject]@{ Kind = 'Comment'; Valid = $true; Reason = '' } }

    $hash = $t.IndexOf('#')
    if ($hash -ge 0) { $t = $t.Substring(0, $hash) }
    $tokens = $t.Split($script:Whitespace, [StringSplitOptions]::RemoveEmptyEntries)

    $reason = ''
    if (-not (Test-IPAddress $tokens[0])) {
        $reason = "'{0}' is not a valid IPv4 or IPv6 address." -f $tokens[0]
    } elseif ($tokens.Count -lt 2) {
        $reason = 'A host name is missing after the IP address.'
    } else {
        for ($i = 1; $i -lt $tokens.Count; $i++) {
            if (-not $script:HostRegex.IsMatch($tokens[$i])) {
                $reason = "'{0}' is not a valid host name." -f $tokens[$i]
                break
            }
        }
    }
    return [pscustomobject]@{ Kind = 'Entry'; Valid = ($reason -eq ''); Reason = $reason }
}

# -------------------------------------------------------------------- entries --

function New-Entry([string]$Text, [bool]$IsNew) {
    $original = $Text
    if ($IsNew) { $original = $null }
    return [pscustomobject]@{
        Original = $original       # $null for lines added in this session
        Text     = $Text
        Deleted  = $false
        Check    = (Test-HostsLine $Text)
    }
}

function Set-EntryText($Entry, [string]$Text) {
    $Entry.Text  = $Text
    $Entry.Check = Test-HostsLine $Text
}

function Get-EntryState($Entry) {
    if ($Entry.Deleted)                   { return 'Deleted' }
    if ($null -eq $Entry.Original)        { return 'New' }
    if ($Entry.Text -cne $Entry.Original) { return 'Modified' }
    return 'Unchanged'
}

function Format-Count([int]$Count, [string]$Singular, [string]$Plural) {
    if ($Count -eq 1) { return "1 $Singular" }
    return "$Count $Plural"
}

function Set-Status([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    $script:Status = $Text
    $script:StatusColor = $Color
}

# Rebuilds the visible row list and the statistics. Selects the first visible
# row at or after entry index $SelectIndex (or keeps the current selection).
function Update-View([int]$SelectIndex = -1) {
    if ($SelectIndex -lt 0 -and $script:Pos -ge 0 -and $script:Pos -lt $script:Visible.Count) {
        $SelectIndex = $script:Visible[$script:Pos]
    }
    $script:Visible.Clear()
    $changed = 0; $invalid = 0; $hostCount = 0
    for ($i = 0; $i -lt $script:Entries.Count; $i++) {
        $e = $script:Entries[$i]
        $state = Get-EntryState $e
        if ($state -ne 'Unchanged') { $changed++ }
        if (-not $e.Deleted) {
            if (-not $e.Check.Valid) { $invalid++ }
            elseif ($e.Check.Kind -eq 'Entry') { $hostCount++ }
        }
        if ($script:HideComments -and $e.Check.Kind -ne 'Entry' -and $state -eq 'Unchanged') { continue }
        $script:Visible.Add($i)
    }
    $script:Stats = @{ Changed = $changed; Invalid = $invalid; Hosts = $hostCount }

    $script:Pos = 0
    if ($SelectIndex -ge 0) {
        for ($p = 0; $p -lt $script:Visible.Count; $p++) {
            $script:Pos = $p
            if ($script:Visible[$p] -ge $SelectIndex) { break }
        }
    }
}

function Get-SelectedIndex {
    if ($script:Visible.Count -eq 0) { return -1 }
    $script:Pos = [Math]::Max(0, [Math]::Min($script:Pos, $script:Visible.Count - 1))
    return $script:Visible[$script:Pos]
}

function Move-Selection([int]$Delta) {
    $script:Pos = [Math]::Max(0, [Math]::Min($script:Pos + $Delta, $script:Visible.Count - 1))
}

function Import-HostsFile {
    $script:Entries.Clear()
    if (Test-Path -LiteralPath $script:HostsPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($script:HostsPath)) {
            $script:Entries.Add((New-Entry $line $false))
        }
    }
    $script:Visible.Clear()
    Update-View 0
}

# ------------------------------------------------------------------ rendering --

function Write-At([int]$X, [int]$Y, [string]$Text, [ConsoleColor]$Fg = [ConsoleColor]::Gray, [ConsoleColor]$Bg = [ConsoleColor]::Black) {
    if ($Text.Length -eq 0) { return }
    [Console]::SetCursorPosition($X, $Y)
    [Console]::ForegroundColor = $Fg
    [Console]::BackgroundColor = $Bg
    [Console]::Write($Text)
}

# Pads or truncates $Text to exactly $Width characters.
function Get-Fitted([string]$Text, [int]$Width) {
    if ($Width -le 0) { return '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width) }
    return $Text.PadRight($Width)
}

function Expand-Tabs([string]$Text) {
    if ($Text.IndexOf([char]9) -lt 0) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq [char]9) { [void]$sb.Append([char]' ', 8 - ($sb.Length % 8)) }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

# $Segments is a list of @(text, color) pairs written left to right on row $Y.
function Write-Segments([int]$Y, $Segments) {
    $w = [Console]::WindowWidth - 1
    $x = 0
    foreach ($s in $Segments) {
        if ($x -ge $w) { break }
        $t = [string]$s[0]
        if ($x + $t.Length -gt $w) { $t = $t.Substring(0, $w - $x) }
        Write-At $x $Y $t $s[1]
        $x += $t.Length
    }
    if ($x -lt $w) { Write-At $x $Y (' ' * ($w - $x)) }
}

# Builds key-help segments from alternating key / description strings.
function Get-KeyHelp([string[]]$Pairs) {
    $segments = @()
    for ($i = 0; $i -lt $Pairs.Count; $i += 2) {
        $segments += ,@((' ' + $Pairs[$i]), [ConsoleColor]::Cyan)
        $segments += ,@((' ' + $Pairs[$i + 1] + ' '), [ConsoleColor]::Gray)
    }
    return ,$segments
}

function Get-EntryColor($Entry, [string]$State) {
    if ($State -eq 'Deleted')     { return [ConsoleColor]::Magenta }
    if (-not $Entry.Check.Valid)  { return [ConsoleColor]::Red }
    if ($State -eq 'New')         { return [ConsoleColor]::Green }
    if ($State -eq 'Modified')    { return [ConsoleColor]::Yellow }
    if ($Entry.Check.Kind -ne 'Entry') { return [ConsoleColor]::DarkGray }
    return [ConsoleColor]::White
}

function Show-Screen {
    try {
        $W = [Console]::WindowWidth
        $H = [Console]::WindowHeight
        if ($W -ne $script:LastW -or $H -ne $script:LastH) {
            [Console]::BackgroundColor = [ConsoleColor]::Black
            [Console]::Clear()
            $script:LastW = $W
            $script:LastH = $H
        }
        $w = $W - 1
        if ($W -lt 40 -or $H -lt 10) {
            Write-At 0 0 (Get-Fitted ' Window too small - please enlarge it.' $w) Red
            return
        }
        $listH = $H - 5
        $count = $script:Visible.Count

        # keep the selection on screen
        $script:Pos = [Math]::Max(0, [Math]::Min($script:Pos, $count - 1))
        if ($script:Pos -lt $script:Top) { $script:Top = $script:Pos }
        if ($script:Pos -ge $script:Top + $listH) { $script:Top = $script:Pos - $listH + 1 }
        $script:Top = [Math]::Max(0, [Math]::Min($script:Top, $count - $listH))

        # title bar
        $left  = ' Hosts Editor  ' + $script:HostsPath
        $right = 'Hosts: {0}  Unsaved changes: {1}  Invalid: {2}  Line {3}/{4} ' -f `
            $script:Stats.Hosts, $script:Stats.Changed, $script:Stats.Invalid, ([Math]::Min($script:Pos + 1, $count)), $count
        if ($left.Length + $right.Length + 2 -le $w) { $title = $left + (' ' * ($w - $left.Length - $right.Length)) + $right }
        else { $title = $left + '  ' + $right }
        $titleBg = [ConsoleColor]::DarkCyan
        if ($script:Stats.Changed -gt 0) { $titleBg = [ConsoleColor]::DarkYellow }
        Write-At 0 0 (Get-Fitted $title $w) Black $titleBg

        # legend
        $legend = @(
            @(' Legend: ', [ConsoleColor]::DarkCyan),
            @('Entry  ', [ConsoleColor]::White),
            @('Comment  ', [ConsoleColor]::DarkGray),
            @('* Modified  ', [ConsoleColor]::Yellow),
            @('+ New  ', [ConsoleColor]::Green),
            @('- Deleted  ', [ConsoleColor]::Magenta),
            @('! Invalid', [ConsoleColor]::Red)
        )
        if ($script:HideComments) { $legend += ,@('   [comments hidden]', [ConsoleColor]::DarkYellow) }
        Write-Segments 1 $legend

        # list
        $numW = [Math]::Max(3, $script:Entries.Count.ToString().Length)
        for ($r = 0; $r -lt $listH; $r++) {
            $y = 2 + $r
            $p = $script:Top + $r
            if ($p -ge $count) {
                $blank = ''
                if ($count -eq 0 -and $r -eq 0) { $blank = '  (no lines - press A to add an entry)' }
                Write-At 0 $y (Get-Fitted $blank $w) DarkGray
                continue
            }
            $idx   = $script:Visible[$p]
            $e     = $script:Entries[$idx]
            $state = Get-EntryState $e
            $fg    = Get-EntryColor $e $state
            $bg    = [ConsoleColor]::Black
            $numFg = [ConsoleColor]::DarkGray
            if ($p -eq $script:Pos) {
                $bg = [ConsoleColor]::DarkBlue
                $numFg = [ConsoleColor]::Gray
                if ($fg -eq [ConsoleColor]::DarkGray) { $fg = [ConsoleColor]::Gray }
            }
            $m1 = ' '
            switch ($state) { 'New' { $m1 = '+' } 'Modified' { $m1 = '*' } 'Deleted' { $m1 = '-' } }
            $m2 = ' '
            if (-not $e.Deleted -and -not $e.Check.Valid) { $m2 = '!' }

            $num  = ($idx + 1).ToString().PadLeft($numW) + '  '
            $textX = 3 + $num.Length
            $avail = $w - $textX
            $text = Expand-Tabs $e.Text
            if ($text.Length -gt $avail) { $text = $text.Substring(0, [Math]::Max(0, $avail - 1)) + $script:Ellipsis }

            Write-At 0 $y ($m1 + $m2 + ' ') $fg $bg
            Write-At 3 $y $num $numFg $bg
            Write-At $textX $y (Get-Fitted $text $avail) $fg $bg
        }

        # status line: explicit message, otherwise why the selected line is invalid
        $statusText = ''
        $statusColor = $script:StatusColor
        if ($script:Status) { $statusText = ' ' + $script:Status }
        elseif ($count -gt 0) {
            $sel = $script:Entries[$script:Visible[$script:Pos]]
            if (-not $sel.Deleted -and -not $sel.Check.Valid) {
                $statusText = ' Invalid line: ' + $sel.Check.Reason
                $statusColor = [ConsoleColor]::Red
            }
        }
        Write-At 0 ($H - 3) (Get-Fitted $statusText $w) $statusColor

        Write-Segments ($H - 2) (Get-KeyHelp @('Enter', 'Edit', 'A', 'Add', 'Del', 'Delete/restore', 'U', 'Undo', 'C/#', 'Comment/uncomment', 'H', 'Hide comments'))
        Write-Segments ($H - 1) (Get-KeyHelp @('S', 'Save', 'R', 'Reload', 'Q/Esc', 'Quit', 'Arrows PgUp PgDn Home End', 'Move'))
    } catch {
        # The window was probably resized while drawing; force a full redraw next time.
        $script:LastW = 0
    }
}

# Centered modal box. Waits for one of $Keys (any key when empty) and returns it.
function Show-Dialog {
    param(
        [string]$Title,
        [string[]]$Lines,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan,
        [string[]]$Keys = @()
    )
    try {
        $W = [Console]::WindowWidth
        $H = [Console]::WindowHeight
        $maxInner = [Math]::Max(10, $W - 8)
        $wrapped = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $Lines) {
            $rest = [string]$line
            while ($rest.Length -gt $maxInner) {
                $wrapped.Add($rest.Substring(0, $maxInner))
                $rest = $rest.Substring($maxInner)
            }
            $wrapped.Add($rest)
        }
        $inner = $Title.Length + 4
        foreach ($line in $wrapped) { if ($line.Length -gt $inner) { $inner = $line.Length } }
        $inner = [Math]::Min($inner, $maxInner)
        $boxW = $inner + 4
        $x = [Math]::Max(0, [int][Math]::Floor(($W - $boxW) / 2))
        $y = [Math]::Max(0, [int][Math]::Floor(($H - $wrapped.Count - 4) / 2))

        $top = $script:BoxTL + $script:BoxH + ' ' + $Title + ' ' + ($script:BoxH * [Math]::Max(0, $boxW - $Title.Length - 5)) + $script:BoxTR
        $empty = $script:BoxV + (' ' * ($boxW - 2)) + $script:BoxV
        Write-At $x $y $top $Color
        $row = $y + 1
        Write-At $x $row $empty $Color; $row++
        foreach ($line in $wrapped) {
            Write-At $x $row ($script:BoxV + ' ') $Color
            Write-At ($x + 2) $row (Get-Fitted $line $inner) White
            Write-At ($x + 2 + $inner) $row (' ' + $script:BoxV) $Color
            $row++
        }
        Write-At $x $row $empty $Color; $row++
        Write-At $x $row ($script:BoxBL + ($script:BoxH * ($boxW - 2)) + $script:BoxBR) $Color
    } catch { }

    [Console]::CursorVisible = $false
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($Keys.Count -eq 0 -or $Keys -contains $k.Key.ToString()) { return $k }
    }
}

# ---------------------------------------------------------------------- input --

# Waits for a key press, redrawing the screen if the window is resized meanwhile.
function Wait-Key([scriptblock]$Redraw) {
    while (-not [Console]::KeyAvailable) {
        if ([Console]::WindowWidth -ne $script:LastW -or [Console]::WindowHeight -ne $script:LastH) {
            Show-Screen
            if ($Redraw) { & $Redraw }
        }
        Start-Sleep -Milliseconds 40
    }
    return [Console]::ReadKey($true)
}

# True when more keystrokes are already queued, i.e. we are in the middle of a paste.
function Test-PendingInput {
    if ([Console]::KeyAvailable) { return $true }
    Start-Sleep -Milliseconds 25
    return [Console]::KeyAvailable
}

function Show-LineEditor($State) {
    try {
        $W = [Console]::WindowWidth
        $H = [Console]::WindowHeight
        $w = $W - 1
        if ($W -lt 40 -or $H -lt 10) { return }
        $row = $H - 3

        $prompt = ' ' + $State.Prompt
        if ($State.Done.Count -gt 0) { $prompt = ' [{0} more pasted] {1}' -f $State.Done.Count, $State.Prompt }
        $fieldW = $w - $prompt.Length

        $text = $State.Buf.ToString()
        if ($State.Cur -lt $State.Off) { $State.Off = $State.Cur }
        if ($State.Cur -gt $State.Off + $fieldW - 1) { $State.Off = $State.Cur - $fieldW + 1 }
        $display = $text.Replace([string][char]9, $script:TabGlyph)
        $shown = ''
        if ($display.Length -gt $State.Off) { $shown = $display.Substring($State.Off) }

        $check = Test-HostsLine $text
        $fg = [ConsoleColor]::White
        if (-not $check.Valid) { $fg = [ConsoleColor]::Red }

        Write-At 0 $row $prompt Cyan
        Write-At $prompt.Length $row (Get-Fitted $shown $fieldW) $fg
        Write-Segments ($H - 2) (Get-KeyHelp @('Enter', 'Accept', 'Esc', 'Cancel', 'Ctrl+V', 'Paste', 'Ctrl+U', 'Clear', 'Tab', 'Insert tab'))
        if ($check.Valid) { Write-At 0 ($H - 1) (Get-Fitted (' ' + $State.Hint) $w) DarkGray }
        else { Write-At 0 ($H - 1) (Get-Fitted (' Invalid: ' + $check.Reason) $w) Red }

        [Console]::SetCursorPosition($prompt.Length + $State.Cur - $State.Off, $row)
    } catch {
        $script:LastW = 0
    }
}

function Add-ClipboardText($State) {
    $clip = $null
    try { $clip = Get-Clipboard -Raw -ErrorAction Stop } catch { }
    if ([string]::IsNullOrEmpty($clip)) { return }
    $clip = [regex]::Replace($clip, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    $parts = [regex]::Split($clip, '\r\n|\r|\n')

    $text = $State.Buf.ToString()
    $head = $text.Substring(0, $State.Cur)
    $tail = $text.Substring($State.Cur)
    if ($parts.Count -eq 1) {
        $newText = $head + $parts[0]
        $State.Cur = $newText.Length
    } else {
        $State.Done.Add($head + $parts[0])
        for ($i = 1; $i -lt $parts.Count - 1; $i++) { $State.Done.Add($parts[$i]) }
        $newText = $parts[$parts.Count - 1]
        $State.Cur = $newText.Length
        $State.Off = 0
    }
    [void]$State.Buf.Clear()
    [void]$State.Buf.Append($newText + $tail)
}

# Single-line editor on the status row. Newlines that arrive as part of a paste
# (more keys already queued) start a new line instead of accepting the input.
# Returns the list of lines entered, or $null when cancelled.
function Read-LineInput {
    param([string]$Prompt, [string]$Initial = '', [string]$Hint = '')
    $st = @{
        Prompt = $Prompt
        Hint   = $Hint
        Buf    = New-Object System.Text.StringBuilder
        Cur    = 0
        Off    = 0
        Done   = New-Object 'System.Collections.Generic.List[string]'
    }
    [void]$st.Buf.Append($Initial)
    $st.Cur = $st.Buf.Length
    $afterCR = $false

    [Console]::CursorVisible = $true
    try {
        while ($true) {
            if (-not [Console]::KeyAvailable) { Show-LineEditor $st }
            $k = Wait-Key { Show-LineEditor $st }
            $ctrl  = (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and (($k.Modifiers -band [ConsoleModifiers]::Alt) -eq 0)
            $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
            $ch = $k.KeyChar

            if ($ch -eq [char]10 -and $afterCR) { $afterCR = $false; continue }   # LF of a pasted CRLF
            $afterCR = ($ch -eq [char]13)

            if ($k.Key -eq 'Enter' -or $ch -eq [char]13 -or $ch -eq [char]10) {
                $st.Done.Add($st.Buf.ToString())
                if (-not (Test-PendingInput)) { return ,$st.Done }
                [void]$st.Buf.Clear()
                $st.Cur = 0
                $st.Off = 0
            }
            elseif ($k.Key -eq 'Escape' -or ($ctrl -and $k.Key -eq 'C')) { return $null }
            elseif (($ctrl -and $k.Key -eq 'V') -or ($shift -and $k.Key -eq 'Insert')) { Add-ClipboardText $st }
            elseif ($ctrl -and $k.Key -eq 'U') { [void]$st.Buf.Clear(); $st.Cur = 0; $st.Off = 0 }
            elseif ($k.Key -eq 'Backspace') {
                if ($st.Cur -gt 0) { [void]$st.Buf.Remove($st.Cur - 1, 1); $st.Cur -= 1 }
            }
            elseif ($k.Key -eq 'Delete') {
                if ($st.Cur -lt $st.Buf.Length) { [void]$st.Buf.Remove($st.Cur, 1) }
            }
            elseif ($k.Key -eq 'LeftArrow')  { if ($st.Cur -gt 0) { $st.Cur -= 1 } }
            elseif ($k.Key -eq 'RightArrow') { if ($st.Cur -lt $st.Buf.Length) { $st.Cur += 1 } }
            elseif ($k.Key -eq 'Home') { $st.Cur = 0 }
            elseif ($k.Key -eq 'End')  { $st.Cur = $st.Buf.Length }
            elseif ($ch -eq [char]9) { [void]$st.Buf.Insert($st.Cur, [string][char]9); $st.Cur += 1 }
            elseif ([int]$ch -ge 32) { [void]$st.Buf.Insert($st.Cur, [string]$ch); $st.Cur += 1 }
        }
    } finally {
        [Console]::CursorVisible = $false
    }
}

# -------------------------------------------------------------------- actions --

$script:EntryHint = 'Format: <IP address> <host name> [more host names] [# comment]   Pasting several lines adds one entry per line.'

function Add-Entries {
    $result = Read-LineInput -Prompt 'Add: ' -Hint $script:EntryHint
    if ($null -eq $result) { Set-Status 'Add cancelled.' DarkGray; return }
    $lines = @($result | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { Set-Status 'Nothing was added.' DarkGray; return }

    $insertAt = $script:Entries.Count
    $sel = Get-SelectedIndex
    if ($sel -ge 0) { $insertAt = $sel + 1 }
    $bad = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $entry = New-Entry $lines[$i] $true
        if (-not $entry.Check.Valid) { $bad++ }
        $script:Entries.Insert($insertAt + $i, $entry)
    }
    Update-View ($insertAt + $lines.Count - 1)

    $message = 'Added {0}.' -f (Format-Count $lines.Count 'entry' 'entries')
    if ($bad -gt 0) { Set-Status ('{0} {1} invalid (shown in red).' -f $message, (Format-Count $bad 'entry is' 'entries are')) Red }
    else { Set-Status $message Green }
}

function Edit-CurrentEntry {
    $idx = Get-SelectedIndex
    if ($idx -lt 0) { Add-Entries; return }
    $e = $script:Entries[$idx]
    if ($e.Deleted) { Set-Status 'This line is marked for deletion - press Del to restore it before editing.' DarkYellow; return }

    $result = Read-LineInput -Prompt ('Edit line {0}: ' -f ($idx + 1)) -Initial $e.Text -Hint $script:EntryHint
    if ($null -eq $result) { Set-Status 'Edit cancelled.' DarkGray; return }

    $before = $e.Text
    if ($result[0] -cne $e.Text) { Set-EntryText $e $result[0] }
    $added = 0
    for ($i = 1; $i -lt $result.Count; $i++) {
        if ($result[$i].Trim().Length -eq 0) { continue }
        $added++
        $script:Entries.Insert($idx + $added, (New-Entry $result[$i] $true))
    }
    Update-View $idx

    if ($added -gt 0) { $message = 'Line updated and {0} added.' -f (Format-Count $added 'pasted entry' 'pasted entries') }
    elseif ($e.Text -ceq $before) { $message = 'No changes.' }
    else { $message = 'Line updated.' }
    if (-not $e.Check.Valid) { Set-Status ('{0} Warning: {1}' -f $message, $e.Check.Reason) Red }
    else { Set-Status $message Green }
}

function Switch-Delete {
    $idx = Get-SelectedIndex
    if ($idx -lt 0) { return }
    $e = $script:Entries[$idx]
    if ($null -eq $e.Original) {
        $script:Entries.RemoveAt($idx)
        Set-Status 'New line removed.' Magenta
    } else {
        $e.Deleted = -not $e.Deleted
        if ($e.Deleted) { Set-Status 'Line marked for deletion (press Del again to restore it).' Magenta }
        else { Set-Status 'Line restored.' Green }
    }
    Update-View $idx
}

function Undo-CurrentEntry {
    $idx = Get-SelectedIndex
    if ($idx -lt 0) { return }
    $e = $script:Entries[$idx]
    switch (Get-EntryState $e) {
        'New'       { $script:Entries.RemoveAt($idx); Set-Status 'New line removed.' Magenta }
        'Unchanged' { Set-Status 'This line has no changes to undo.' DarkGray }
        default     { $e.Deleted = $false; Set-EntryText $e $e.Original; Set-Status 'Line restored to its original content.' Green }
    }
    Update-View $idx
}

function Switch-Comment {
    $idx = Get-SelectedIndex
    if ($idx -lt 0) { return }
    $e = $script:Entries[$idx]
    if ($e.Deleted) { Set-Status 'This line is marked for deletion.' DarkYellow; return }
    if ($e.Check.Kind -eq 'Blank') { Set-Status 'Blank line - nothing to comment out.' DarkGray; return }
    if ($e.Check.Kind -eq 'Comment') {
        Set-EntryText $e ($e.Text -replace '^(\s*)#\s?', '$1')
        Set-Status 'Line uncommented.' Yellow
    } else {
        Set-EntryText $e ('# ' + $e.Text)
        Set-Status 'Line commented out (disabled).' Yellow
    }
    Update-View $idx
}

function Switch-HideComments {
    $sel = Get-SelectedIndex
    $script:HideComments = -not $script:HideComments
    Update-View $sel
    if ($script:HideComments) { Set-Status 'Unchanged comments and blank lines are hidden (H to show them).' DarkYellow }
    else { Set-Status 'Showing all lines.' DarkYellow }
}

# Returns $true when the file was written.
function Save-HostsFile {
    if ($script:Stats.Changed -eq 0) { Set-Status 'There are no changes to save.' DarkYellow; return $true }

    if ($script:Stats.Invalid -gt 0) {
        $k = Show-Dialog 'Invalid entries' @(
            ('The file contains {0} (shown in red).' -f (Format-Count $script:Stats.Invalid 'invalid entry' 'invalid entries')),
            'Windows ignores lines it cannot parse.',
            '',
            'Save anyway?   [Y] Yes   [N] No') Yellow @('Y', 'N', 'Escape')
        if ($k.Key -ne 'Y') { Set-Status 'Save cancelled.' DarkYellow; return $false }
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $script:Entries) { if (-not $e.Deleted) { $lines.Add($e.Text) } }
    $backup = $script:HostsPath + '.bak'

    try {
        $wasReadOnly = $false
        if (Test-Path -LiteralPath $script:HostsPath) {
            Copy-Item -LiteralPath $script:HostsPath -Destination $backup -Force
            $item = Get-Item -LiteralPath $script:HostsPath -Force
            if ($item.IsReadOnly) { $wasReadOnly = $true; $item.IsReadOnly = $false }
        }
        # UTF-8 without BOM: a BOM would corrupt the first line for the Windows resolver.
        [System.IO.File]::WriteAllLines($script:HostsPath, $lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
        if ($wasReadOnly) { (Get-Item -LiteralPath $script:HostsPath -Force).IsReadOnly = $true }
    } catch {
        [void](Show-Dialog 'Save failed' @('The hosts file could not be saved:', '', $_.Exception.Message, '', 'Your changes are still pending. Press any key.') Red)
        Set-Status 'Save failed - your changes are still pending.' Red
        return $false
    }

    $oldPos = $script:Pos
    Import-HostsFile
    $script:Pos = [Math]::Min($oldPos, [Math]::Max(0, $script:Visible.Count - 1))
    Show-Screen

    $time = Get-Date -Format 'HH:mm:ss'
    [void](Show-Dialog 'Saved' @(
        'The hosts file was saved and reloaded from disk.',
        '',
        ('File:    {0}' -f $script:HostsPath),
        ('Lines:   {0}' -f $script:Entries.Count),
        ('Backup:  {0}' -f $backup),
        ('Time:    {0}' -f $time),
        '',
        'Press any key to continue.') Green)
    Set-Status ('Saved and reloaded at {0}.' -f $time) Green
    return $true
}

function Request-Reload {
    if ($script:Stats.Changed -gt 0) {
        $k = Show-Dialog 'Reload' @(
            ('Discard {0} and reload the file from disk?' -f (Format-Count $script:Stats.Changed 'unsaved change' 'unsaved changes')),
            '',
            '[Y] Yes   [N] No') Yellow @('Y', 'N', 'Escape')
        if ($k.Key -ne 'Y') { Set-Status 'Reload cancelled.' DarkGray; return }
    }
    Import-HostsFile
    Set-Status 'Reloaded from disk.' Green
}

function Request-Quit {
    if ($script:Stats.Changed -eq 0) { $script:Running = $false; return }
    $k = Show-Dialog 'Unsaved changes' @(
        ('You have {0}.' -f (Format-Count $script:Stats.Changed 'unsaved change' 'unsaved changes')),
        '',
        '[S]   Save and exit',
        '[D]   Discard changes and exit',
        '[Esc] Return to the editor') Yellow @('S', 'D', 'Escape')
    switch ($k.Key) {
        'S' { if (Save-HostsFile) { $script:Running = $false } }
        'D' { $script:Running = $false }
    }
}

function Invoke-ListKey([ConsoleKeyInfo]$Key) {
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $alt  = ($Key.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
    $page = [Math]::Max(1, [Console]::WindowHeight - 6)

    if ($Key.KeyChar -eq '#') { Switch-Comment; return }
    if ($alt) { return }   # ignore Alt / AltGr combinations
    if ($ctrl -and $Key.Key -eq 'C') { Request-Quit; return }

    switch ($Key.Key) {
        'UpArrow'   { Move-Selection -1 }
        'DownArrow' { Move-Selection 1 }
        'PageUp'    { Move-Selection (-$page) }
        'PageDown'  { Move-Selection $page }
        'Home'      { $script:Pos = 0 }
        'End'       { $script:Pos = [Math]::Max(0, $script:Visible.Count - 1) }
        'Enter'     { Edit-CurrentEntry }
        'F2'        { Edit-CurrentEntry }
        'E'         { Edit-CurrentEntry }
        'A'         { Add-Entries }
        'Insert'    { Add-Entries }
        'Delete'    { Switch-Delete }
        'D'         { Switch-Delete }
        'U'         { Undo-CurrentEntry }
        'C'         { Switch-Comment }
        'H'         { Switch-HideComments }
        'S'         { [void](Save-HostsFile) }
        'R'         { Request-Reload }
        'F5'        { Request-Reload }
        'Q'         { Request-Quit }
        'Escape'    { Request-Quit }
    }
}

# ----------------------------------------------------------------------- main --

$origFg       = [Console]::ForegroundColor
$origBg       = [Console]::BackgroundColor
$origEncoding = [Console]::OutputEncoding
$origCtrlC    = [Console]::TreatControlCAsInput

try {
    try { $Host.UI.RawUI.WindowTitle = 'Hosts Editor (Administrator)' } catch { }
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Console]::TreatControlCAsInput = $true
    [Console]::CursorVisible = $false

    Import-HostsFile
    while ($script:Running) {
        if (-not [Console]::KeyAvailable) { Show-Screen }   # skip redraws while keys are queued
        $key = Wait-Key
        $script:Status = ''
        Invoke-ListKey $key
    }
}
catch {
    [Console]::ForegroundColor = $origFg
    [Console]::BackgroundColor = $origBg
    [Console]::Clear()
    Write-Host 'Hosts Editor stopped because of an unexpected error:' -ForegroundColor Red
    Write-Host ($_ | Out-String) -ForegroundColor Red
    Write-Host 'Press any key to exit...'
    try { [void][Console]::ReadKey($true) } catch { }
}
finally {
    [Console]::ForegroundColor = $origFg
    [Console]::BackgroundColor = $origBg
    [Console]::CursorVisible = $true
    [Console]::TreatControlCAsInput = $origCtrlC
    [Console]::OutputEncoding = $origEncoding
    [Console]::Clear()
}
