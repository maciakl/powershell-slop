#Requires -Version 5.1
<#
.SYNOPSIS
    Terminal UI for reviewing and pruning entries in an OpenSSH known_hosts file.

.DESCRIPTION
    Lists every host key in known_hosts with colorized host names (cyan) and
    IP addresses (yellow), the key type and an abbreviated key. Entries can be
    marked for deletion, marks can be undone, and nothing is written until you
    save. Comments and blank lines in the file are preserved, and the previous
    version is kept as known_hosts.old (the same convention ssh-keygen -R uses).

    Runs on the Windows PowerShell 5.1 that ships with Windows 11, and on
    PowerShell 7+. No external modules are required.

    Keys:
      Up/Down, PgUp/PgDn, Home/End   move (j/k also work)
      Space, Delete, D               mark / unmark the selected entry
      A                              mark all shown entries (again to unmark)
      U                              undo all marks
      /                              filter by host, IP, key type or comment
      R, F5                          reload the file from disk
      S, Ctrl+S                      save (delete marked entries)
      Q, Esc, Ctrl+C                 quit (Esc clears an active filter first)

.PARAMETER Path
    The known_hosts file to manage. Defaults to ~\.ssh\known_hosts.

.EXAMPLE
    .\SSH-KnownHostsManager.ps1

.EXAMPLE
    .\SSH-KnownHostsManager.ps1 -Path C:\temp\known_hosts
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Join-Path $HOME '.ssh') 'known_hosts')
)

$ErrorActionPreference = 'Stop'

# Glyphs are built from code points so this file stays pure ASCII: Windows
# PowerShell 5.1 reads BOM-less scripts as ANSI and would mangle literal UTF-8.
$G = @{
    Ellipsis = [string][char]0x2026
    HLine    = [string][char]0x2500
    Pointer  = [string][char]0x25BA
    Arrows   = [string][char]0x2191 + [char]0x2193
}

$C = @{
    Bg        = [ConsoleColor]::Black
    SelBg     = [ConsoleColor]::DarkBlue
    BarBg     = [ConsoleColor]::Gray
    Host      = [ConsoleColor]::Cyan
    Ip        = [ConsoleColor]::Yellow
    Port      = [ConsoleColor]::Gray
    Punct     = [ConsoleColor]::DarkGray
    Hashed    = [ConsoleColor]::Magenta
    KeyType   = [ConsoleColor]::Green
    Key       = [ConsoleColor]::DarkGray
    Label     = [ConsoleColor]::DarkGray
    Text      = [ConsoleColor]::Gray
    Marked    = [ConsoleColor]::Red
    MarkedDim = [ConsoleColor]::DarkRed
}

# Dim colors are hard to read on the selection bar, so they are brightened there.
$SelRemap = @{
    ([ConsoleColor]::DarkGray) = [ConsoleColor]::Gray
    ([ConsoleColor]::DarkRed)  = [ConsoleColor]::Red
}

$KeyTypeNames = @{
    'ssh-ed25519'                        = 'ED25519'
    'ssh-rsa'                            = 'RSA'
    'ssh-dss'                            = 'DSA'
    'ecdsa-sha2-nistp256'                = 'ECDSA-256'
    'ecdsa-sha2-nistp384'                = 'ECDSA-384'
    'ecdsa-sha2-nistp521'                = 'ECDSA-521'
    'sk-ssh-ed25519@openssh.com'         = 'SK-ED25519'
    'sk-ecdsa-sha2-nistp256@openssh.com' = 'SK-ECDSA'
}

$S = @{
    Path            = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    FileExists      = $false
    RawText         = ''
    Lines           = @()
    NewLine         = [Environment]::NewLine
    TrailingNewline = $true
    Entries         = New-Object 'System.Collections.Generic.List[object]'
    View            = New-Object 'System.Collections.Generic.List[int]'
    Cursor          = 0
    Top             = 0
    Filter          = ''
    FilterBackup    = ''
    Mode            = 'normal'
    Status          = ''
    StatusKind      = 'info'
    W               = 0
    LastW           = 0
    LastH           = 0
    H               = 0
}

# ---------------------------------------------------------------------------
# known_hosts file handling
# ---------------------------------------------------------------------------

function Read-KnownHostsFile {
    $S.Entries.Clear()
    $S.FileExists = Test-Path -LiteralPath $S.Path -PathType Leaf
    $raw = ''
    if ($S.FileExists) { $raw = [IO.File]::ReadAllText($S.Path) }
    $S.RawText = $raw

    if ($raw.Contains("`r`n")) { $S.NewLine = "`r`n" }
    elseif ($raw.Contains("`n")) { $S.NewLine = "`n" }
    else { $S.NewLine = [Environment]::NewLine }
    $S.TrailingNewline = $raw.EndsWith("`n")

    $lines = @()
    if ($raw.Length -gt 0) {
        $lines = @($raw -split '\r?\n')
        if ($S.TrailingNewline) { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $S.Lines = $lines

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = $lines[$i].Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }

        # [@marker] hostnames keytype base64key [comment]
        $parts = @($text -split '\s+')
        $p = 0
        $marker = ''
        if ($parts[0].StartsWith('@')) { $marker = $parts[0]; $p = 1 }
        $hostField = ''; $keyType = ''; $key = ''; $comment = ''
        if ($parts.Count -gt $p)     { $hostField = $parts[$p] }
        if ($parts.Count -gt $p + 1) { $keyType = $parts[$p + 1] }
        if ($parts.Count -gt $p + 2) { $key = $parts[$p + 2] }
        if ($parts.Count -gt $p + 3) { $comment = $parts[($p + 3)..($parts.Count - 1)] -join ' ' }

        $S.Entries.Add([pscustomobject]@{
            LineIndex   = $i
            Marker      = $marker
            HostField   = $hostField
            Hosts       = @($hostField -split ',' | Where-Object { $_ -ne '' })
            KeyType     = $keyType
            Key         = $key
            Comment     = $comment
            Valid       = ($key -ne '')
            Fingerprint = $null
            Marked      = $false
            SearchText  = "$marker $hostField $keyType $comment"
        })
    }
}

function Save-KnownHostsFile {
    $marked = @($S.Entries | Where-Object { $_.Marked })
    if ($marked.Count -eq 0) {
        Set-Status 'Nothing is marked for deletion - no changes to save.' 'info'
        return
    }
    if (-not (Read-Confirm "Delete $(Format-Count $marked.Count 'entry' 'entries') from known_hosts and save?")) {
        Set-Status 'Save cancelled.' 'info'
        return
    }

    # Refuse to overwrite changes another program (e.g. ssh) made since we loaded.
    $current = ''
    if (Test-Path -LiteralPath $S.Path -PathType Leaf) { $current = [IO.File]::ReadAllText($S.Path) }
    if ($current -ne $S.RawText) {
        Set-Status 'known_hosts changed on disk since it was loaded. Press R to reload (marks will be lost).' 'error'
        return
    }

    $drop = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($e in $marked) { [void]$drop.Add($e.LineIndex) }
    $keep = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $S.Lines.Count; $i++) {
        if (-not $drop.Contains($i)) { $keep.Add($S.Lines[$i]) }
    }
    $text = $keep -join $S.NewLine
    if ($S.TrailingNewline -and $keep.Count -gt 0) { $text += $S.NewLine }

    try {
        [IO.File]::Copy($S.Path, "$($S.Path).old", $true)
        # OpenSSH expects no BOM; Set-Content -Encoding UTF8 on 5.1 would add one.
        [IO.File]::WriteAllText($S.Path, $text, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        Set-Status "Save failed: $($_.Exception.Message)" 'error'
        return
    }

    Read-KnownHostsFile
    Update-View
    Set-Status ("Saved {0} - removed {1}, {2} remaining. Backup: {3}.old" -f `
        (Get-Date -Format 'HH:mm:ss'), (Format-Count $marked.Count 'entry' 'entries'),
        $S.Entries.Count, (Split-Path -Leaf $S.Path)) 'ok'
}

function Get-Fingerprint($Entry) {
    if ($null -eq $Entry.Fingerprint) {
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = $sha.ComputeHash([Convert]::FromBase64String($Entry.Key))
            $sha.Dispose()
            $Entry.Fingerprint = 'SHA256:' + [Convert]::ToBase64String($hash).TrimEnd('=')
        }
        catch { $Entry.Fingerprint = '(key data is not valid base64)' }
    }
    $Entry.Fingerprint
}

# ---------------------------------------------------------------------------
# View state
# ---------------------------------------------------------------------------

function Format-Count([int]$N, [string]$One, [string]$Many) {
    if ($N -eq 1) { "1 $One" } else { "$N $Many" }
}

function Set-Status([string]$Text, [string]$Kind) {
    $S.Status = $Text
    $S.StatusKind = $Kind
}

function Get-MarkedCount {
    $n = 0
    foreach ($e in $S.Entries) { if ($e.Marked) { $n++ } }
    $n
}

function Get-ListHeight { [Math]::Max(1, [Console]::WindowHeight - 9) }

function Get-SelectedIndex {
    if ($S.View.Count -eq 0) { return -1 }
    $S.View[$S.Cursor]
}

function Limit-Cursor {
    $count = $S.View.Count
    $lh = Get-ListHeight
    if ($S.Cursor -ge $count) { $S.Cursor = $count - 1 }
    if ($S.Cursor -lt 0) { $S.Cursor = 0 }
    if ($S.Cursor -lt $S.Top) { $S.Top = $S.Cursor }
    if ($S.Cursor -ge $S.Top + $lh) { $S.Top = $S.Cursor - $lh + 1 }
    if ($S.Top -gt [Math]::Max(0, $count - $lh)) { $S.Top = [Math]::Max(0, $count - $lh) }
    if ($S.Top -lt 0) { $S.Top = 0 }
}

function Update-View([int]$PreferEntry = -1) {
    $S.View.Clear()
    for ($i = 0; $i -lt $S.Entries.Count; $i++) {
        if ($S.Filter -eq '' -or
            $S.Entries[$i].SearchText.IndexOf($S.Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $S.View.Add($i)
        }
    }
    if ($PreferEntry -ge 0) {
        $pos = $S.View.IndexOf($PreferEntry)
        if ($pos -ge 0) { $S.Cursor = $pos }
    }
    Limit-Cursor
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Seg([string]$T, [ConsoleColor]$F) {
    [pscustomobject]@{ T = $T; F = $F }
}

# Writes colored segments at the cursor, clipped with an ellipsis or padded
# with spaces so the field is exactly $Width cells wide.
function Write-Field([object[]]$Segs, [int]$Width, [ConsoleColor]$Bg) {
    if ($Width -le 0) { return }
    $total = 0
    foreach ($seg in $Segs) { $total += $seg.T.Length }
    $clip = $total -gt $Width
    $budget = $Width
    if ($clip) { $budget = $Width - 1 }

    [Console]::BackgroundColor = $Bg
    $written = 0
    foreach ($seg in $Segs) {
        if ($written -ge $budget) { break }
        $t = $seg.T
        if ($t.Length -gt $budget - $written) { $t = $t.Substring(0, $budget - $written) }
        $fg = $seg.F
        if ($Bg -eq $C.SelBg -and $SelRemap.ContainsKey($fg)) { $fg = $SelRemap[$fg] }
        [Console]::ForegroundColor = $fg
        [Console]::Write($t)
        $written += $t.Length
    }
    if ($clip) {
        [Console]::ForegroundColor = $C.Text
        [Console]::Write($G.Ellipsis)
        $written++
    }
    if ($written -lt $Width) { [Console]::Write(' ' * ($Width - $written)) }
}

function Test-IsIpAddress([string]$Name) {
    ($Name -match '^[\d*?]{1,3}(\.[\d*?]{1,3}){3}$') -or
    ($Name.Contains(':') -and $Name -match '^[0-9A-Fa-f:.%*?]+$')
}

function Get-HostSegs($Entry) {
    $m = $Entry.Marked
    $punct = $C.Punct
    if ($m) { $punct = $C.MarkedDim }

    if ($Entry.Marker -eq '@revoked') { Seg '@revoked ' $C.Marked }
    elseif ($Entry.Marker) {
        $mc = $C.Hashed
        if ($m) { $mc = $C.MarkedDim }
        Seg "$($Entry.Marker) " $mc
    }

    if ($Entry.Hosts.Count -eq 0) { Seg '(no host)' $punct; return }

    $first = $true
    foreach ($h in $Entry.Hosts) {
        if (-not $first) { Seg ', ' $punct }
        $first = $false

        if ($h.StartsWith('|')) {
            $hc = $C.Hashed
            if ($m) { $hc = $C.Marked }
            Seg '<hashed>' $hc
            continue
        }
        if ($h.StartsWith('!')) { Seg '!' $C.Marked; $h = $h.Substring(1) }

        $name = $h
        $port = ''
        if ($h -match '^\[(.*)\]:(\d+)$') { $name = $Matches[1]; $port = $Matches[2] }

        $nc = $C.Host
        if ($m) { $nc = $C.Marked }
        elseif (Test-IsIpAddress $name) { $nc = $C.Ip }

        if ($port) {
            $pc = $C.Port
            if ($m) { $pc = $C.MarkedDim }
            Seg '[' $punct
            Seg $name $nc
            Seg ']:' $punct
            Seg $port $pc
        }
        else { Seg $name $nc }
    }
}

function Get-Layout {
    $W = $S.W
    $numW = [Math]::Max(4, ([string]$S.Lines.Count).Length)
    $typeW = 10
    $keyW = 18
    $hostW = $W - (2 + 5 + 1 + $numW + 2 + 2 + $typeW + 2 + $keyW)
    if ($hostW -lt 30) {
        $keyW = 0
        $hostW = $W - (2 + 5 + 1 + $numW + 2 + 2 + $typeW)
    }
    @{ Num = $numW; Host = $hostW; Type = $typeW; Key = $keyW }
}

function Write-Row([int]$Row, $L, $Ptr, $Mark, $Num, $HostSegs, $Type, $Key, [ConsoleColor]$Bg) {
    [Console]::SetCursorPosition(0, $Row)
    Write-Field $Ptr 2 $Bg
    if ($Mark) { Write-Field @(Seg ' DEL ' ([ConsoleColor]::White)) 5 ([ConsoleColor]::DarkRed) }
    else { Write-Field @() 5 $Bg }
    Write-Field @() 1 $Bg
    Write-Field $Num $L.Num $Bg
    Write-Field @() 2 $Bg
    Write-Field $HostSegs $L.Host $Bg
    Write-Field @() 2 $Bg
    Write-Field $Type $L.Type $Bg
    if ($L.Key -gt 0) {
        Write-Field @() 2 $Bg
        Write-Field $Key $L.Key $Bg
    }
}

function Write-EntryRow([int]$Row, [int]$ViewPos, $L) {
    $e = $S.Entries[$S.View[$ViewPos]]
    $sel = $ViewPos -eq $S.Cursor
    $bg = $C.Bg
    $ptr = @()
    if ($sel) { $bg = $C.SelBg; $ptr = @(Seg $G.Pointer ([ConsoleColor]::White)) }

    $dim = $C.Key
    $typeColor = $C.KeyType
    if ($e.Marked) { $dim = $C.MarkedDim; $typeColor = $C.MarkedDim }

    $lineNo = ([string]($e.LineIndex + 1)).PadLeft($L.Num)

    if ($e.Valid) {
        $typeName = $e.KeyType
        if ($KeyTypeNames.ContainsKey($e.KeyType)) { $typeName = $KeyTypeNames[$e.KeyType] }
        $k = $e.Key.TrimEnd('=')
        $tail = [Math]::Max(1, $L.Key - 1)
        if ($k.Length -gt $tail) { $k = $G.Ellipsis + $k.Substring($k.Length - $tail) }
        $typeSegs = @(Seg $typeName $typeColor)
        $keySegs = @(Seg $k $dim)
    }
    else {
        $typeSegs = @(Seg '?' $C.Marked)
        $keySegs = @(Seg '(malformed line)' $C.Marked)
    }

    Write-Row $Row $L $ptr $e.Marked @(Seg $lineNo $dim) @(Get-HostSegs $e) $typeSegs $keySegs $bg
}

function Write-StatusBar([string]$Text, [string]$Kind, [string]$Right = '') {
    $fg = [ConsoleColor]::White
    switch ($Kind) {
        'ok'     { $bg = [ConsoleColor]::DarkGreen }
        'error'  { $bg = [ConsoleColor]::DarkRed }
        'prompt' { $bg = [ConsoleColor]::Yellow; $fg = [ConsoleColor]::Black }
        default  { $bg = [ConsoleColor]::DarkGray }
    }
    $rw = 0
    if ($Right) { $rw = $Right.Length + 2 }
    [Console]::SetCursorPosition(0, $S.H - 1)
    Write-Field @(Seg " $Text" $fg) ($S.W - $rw) $bg
    if ($rw -gt 0) { Write-Field @(Seg " $Right " $fg) $rw $bg }
}

function Show-Screen {
    $S.W = [Console]::WindowWidth - 1   # never touch the last column: it scrolls the buffer
    $S.H = [Console]::WindowHeight
    $W = $S.W
    $H = $S.H

    if ($W -lt 59 -or $H -lt 12) {
        [Console]::BackgroundColor = $C.Bg
        [Console]::Clear()
        Write-Field @(Seg 'Window too small - please enlarge it (minimum 60 x 12).' ([ConsoleColor]::Yellow)) $W $C.Bg
        return
    }

    Limit-Cursor
    $L = Get-Layout
    $lh = Get-ListHeight
    $markedCount = Get-MarkedCount

    # Title bar
    $right = @(Seg (Format-Count $S.Entries.Count 'entry' 'entries') ([ConsoleColor]::Black))
    if ($markedCount -gt 0) { $right += Seg "  $markedCount marked" ([ConsoleColor]::DarkRed) }
    if ($S.Filter) { $right += Seg "  $($S.View.Count) shown" ([ConsoleColor]::DarkBlue) }
    $right += Seg ' ' ([ConsoleColor]::Black)
    $rw = 0
    foreach ($seg in $right) { $rw += $seg.T.Length }
    [Console]::SetCursorPosition(0, 0)
    Write-Field @((Seg ' SSH Known Hosts Manager' ([ConsoleColor]::Black)),
                  (Seg "   $($S.Path)" ([ConsoleColor]::DarkBlue))) ($W - $rw) $C.BarBg
    Write-Field $right $rw $C.BarBg

    # Column headings
    $hc = [ConsoleColor]::White
    Write-Row 1 $L @() $false @(Seg ('Line'.PadLeft($L.Num)) $hc) @(
        (Seg 'Host names' $C.Host), (Seg ' / ' $C.Punct), (Seg 'IP addresses' $C.Ip)) @(
        Seg 'Type' $hc) @(Seg 'Key' $hc) $C.Bg
    [Console]::SetCursorPosition(0, 2)
    Write-Field @(Seg ($G.HLine * $W) $C.Punct) $W $C.Bg

    # Entry list
    for ($r = 0; $r -lt $lh; $r++) {
        $row = 3 + $r
        $pos = $S.Top + $r
        if ($pos -lt $S.View.Count) {
            Write-EntryRow $row $pos $L
            continue
        }
        [Console]::SetCursorPosition(0, $row)
        $msg = @()
        if ($r -eq 0) {
            if (-not $S.FileExists) { $msg = @(Seg "  File not found: $($S.Path)" $C.Marked) }
            elseif ($S.Entries.Count -eq 0) { $msg = @(Seg '  known_hosts contains no host keys.' $C.Text) }
            else { $msg = @(Seg "  No entries match the filter '$($S.Filter)'." $C.Text) }
        }
        Write-Field $msg $W $C.Bg
    }

    # Scroll hint in the separator line
    $sep = $G.HLine * $W
    if ($S.View.Count -gt $lh) {
        $hint = " $($S.Top + 1)-$([Math]::Min($S.Top + $lh, $S.View.Count)) of $($S.View.Count) "
        $sep = ($G.HLine * 3) + $hint + ($G.HLine * [Math]::Max(0, $W - 3 - $hint.Length))
    }
    [Console]::SetCursorPosition(0, $H - 6)
    Write-Field @(Seg $sep $C.Punct) $W $C.Bg

    # Detail pane for the selected entry
    $idx = Get-SelectedIndex
    $d1 = @(); $d2 = @(); $d3 = @()
    if ($idx -ge 0) {
        $e = $S.Entries[$idx]
        $d1 = @(Seg ' Hosts       ' $C.Label) + @(Get-HostSegs $e)
        if ($e.Valid) {
            $k = $e.Key
            if ($k.Length -gt 40) { $k = $k.Substring(0, 16) + $G.Ellipsis + $k.Substring($k.Length - 16) }
            $d2 = @((Seg ' Type        ' $C.Label), (Seg $e.KeyType $C.KeyType),
                    (Seg '    Fingerprint  ' $C.Label), (Seg (Get-Fingerprint $e) ([ConsoleColor]::White)))
            $d3 = @((Seg ' Key         ' $C.Label), (Seg $k $C.Key),
                    (Seg '    Line  ' $C.Label), (Seg ([string]($e.LineIndex + 1)) $C.Text))
        }
        else {
            $d2 = @((Seg ' Type        ' $C.Label), (Seg 'Malformed line - no key data found' $C.Marked))
            $d3 = @((Seg ' Line        ' $C.Label), (Seg ([string]($e.LineIndex + 1)) $C.Text))
        }
        if ($e.Comment) { $d3 += @((Seg '    Comment  ' $C.Label), (Seg $e.Comment $C.Text)) }
        if ($e.Marked) { $d3 += Seg '    MARKED FOR DELETION' $C.Marked }
    }
    [Console]::SetCursorPosition(0, $H - 5); Write-Field $d1 $W $C.Bg
    [Console]::SetCursorPosition(0, $H - 4); Write-Field $d2 $W $C.Bg
    [Console]::SetCursorPosition(0, $H - 3); Write-Field $d3 $W $C.Bg

    # Key help, most important first so narrow windows still show them
    $help = @()
    foreach ($pair in @(@('Space', 'Mark'), @('U', 'Undo all marks'), @('S', 'Save'), @('Q', 'Quit'),
                        @('/', 'Filter'), @('A', 'Mark all shown'), @('R', 'Reload'),
                        @("$($G.Arrows) PgUp PgDn Home End", 'Move'))) {
        $help += Seg " $($pair[0]) " ([ConsoleColor]::Yellow)
        $help += Seg "$($pair[1]) " $C.Text
    }
    [Console]::SetCursorPosition(0, $H - 2)
    Write-Field $help $W $C.Bg

    # Status bar
    $pos = ''
    if ($S.View.Count -gt 0) { $pos = "$($S.Cursor + 1)/$($S.View.Count)" }
    if ($S.Mode -eq 'filter') {
        Write-StatusBar "Filter: $($S.Filter)_     (Enter to keep, Esc to cancel)" 'prompt' $pos
    }
    else {
        Write-StatusBar $S.Status $S.StatusKind $pos
    }
}

function Read-Confirm([string]$Message) {
    Write-StatusBar "$Message  (y/N)" 'prompt'
    $k = [Console]::ReadKey($true)
    $k.Key -eq [ConsoleKey]::Y
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Switch-Mark {
    $idx = Get-SelectedIndex
    if ($idx -lt 0) { return }
    $e = $S.Entries[$idx]
    $e.Marked = -not $e.Marked
    $S.Cursor++
    Limit-Cursor
}

function Switch-MarkAllShown {
    if ($S.View.Count -eq 0) { return }
    $allMarked = $true
    foreach ($i in $S.View) { if (-not $S.Entries[$i].Marked) { $allMarked = $false; break } }
    foreach ($i in $S.View) { $S.Entries[$i].Marked = -not $allMarked }
    if ($allMarked) { Set-Status "Unmarked $(Format-Count $S.View.Count 'shown entry' 'shown entries')." 'info' }
    else { Set-Status "Marked $(Format-Count $S.View.Count 'shown entry' 'shown entries') for deletion." 'info' }
}

function Clear-AllMarks {
    $n = Get-MarkedCount
    foreach ($e in $S.Entries) { $e.Marked = $false }
    if ($n -gt 0) { Set-Status "Undid $(Format-Count $n 'mark' 'marks'). Nothing will be deleted." 'info' }
    else { Set-Status 'There are no marks to undo.' 'info' }
}

function Invoke-Reload {
    $n = Get-MarkedCount
    if ($n -gt 0 -and -not (Read-Confirm "Discard $(Format-Count $n 'mark' 'marks') and reload from disk?")) {
        Set-Status 'Reload cancelled.' 'info'
        return
    }
    Read-KnownHostsFile
    Update-View
    Set-Status "Reloaded $(Format-Count $S.Entries.Count 'entry' 'entries') at $(Get-Date -Format 'HH:mm:ss')." 'info'
}

function Confirm-Quit {
    $n = Get-MarkedCount
    if ($n -eq 0) { return $true }
    if (Read-Confirm "$(Format-Count $n 'entry is' 'entries are') marked but not saved. Quit without saving?") { return $true }
    Set-Status 'Quit cancelled.' 'info'
    $false
}

function Invoke-FilterKey([ConsoleKeyInfo]$K) {
    $selected = Get-SelectedIndex
    if ($K.Key -eq [ConsoleKey]::Enter) {
        $S.Mode = 'normal'
        if ($S.Filter) { Set-Status "Filter '$($S.Filter)': $(Format-Count $S.View.Count 'match' 'matches'). Esc clears it." 'info' }
        else { Set-Status 'Filter cleared.' 'info' }
        return
    }
    if ($K.Key -eq [ConsoleKey]::Escape) {
        $S.Filter = $S.FilterBackup
        $S.Mode = 'normal'
    }
    elseif ($K.Key -eq [ConsoleKey]::Backspace) {
        if ($S.Filter.Length -gt 0) { $S.Filter = $S.Filter.Substring(0, $S.Filter.Length - 1) }
    }
    elseif (-not [char]::IsControl($K.KeyChar)) {
        $S.Filter += $K.KeyChar
    }
    else { return }
    Update-View $selected
}

# Returns $false when the user chose to quit.
function Invoke-NormalKey([ConsoleKeyInfo]$K) {
    $key = $K.Key
    $ch = ([string]$K.KeyChar).ToLowerInvariant()
    $ctrl = ($K.Modifiers -band [ConsoleModifiers]::Control) -ne 0

    if ($ctrl -and $key -eq [ConsoleKey]::C) { return -not (Confirm-Quit) }
    if ($ctrl -and $key -eq [ConsoleKey]::S) { Save-KnownHostsFile; return $true }

    if ($key -eq [ConsoleKey]::UpArrow -or $ch -eq 'k')   { $S.Cursor--; Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::DownArrow -or $ch -eq 'j') { $S.Cursor++; Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::PageUp)   { $S.Cursor -= (Get-ListHeight); Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::PageDown) { $S.Cursor += (Get-ListHeight); Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::Home)     { $S.Cursor = 0; Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::End)      { $S.Cursor = $S.View.Count - 1; Limit-Cursor }
    elseif ($key -eq [ConsoleKey]::Spacebar -or $key -eq [ConsoleKey]::Delete -or $ch -eq 'd') { Switch-Mark }
    elseif ($ch -eq 'a') { Switch-MarkAllShown }
    elseif ($ch -eq 'u') { Clear-AllMarks }
    elseif ($ch -eq '/') { $S.FilterBackup = $S.Filter; $S.Mode = 'filter' }
    elseif ($ch -eq 'r' -or $key -eq [ConsoleKey]::F5) { Invoke-Reload }
    elseif ($ch -eq 's') { Save-KnownHostsFile }
    elseif ($key -eq [ConsoleKey]::Escape -and $S.Filter) {
        $selected = Get-SelectedIndex
        $S.Filter = ''
        Update-View $selected
        Set-Status 'Filter cleared.' 'info'
    }
    elseif ($ch -eq 'q' -or $key -eq [ConsoleKey]::Escape) { return -not (Confirm-Quit) }
    $true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Host.Name -eq 'Windows PowerShell ISE Host' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    Write-Host 'SSH-KnownHostsManager needs an interactive console (Windows Terminal, powershell.exe or pwsh.exe).' -ForegroundColor Red
    return
}

$saved = @{
    Fg       = [Console]::ForegroundColor
    Bg       = [Console]::BackgroundColor
    Encoding = [Console]::OutputEncoding
    CtrlC    = [Console]::TreatControlCAsInput
    Cursor   = $true
}
try { $saved.Cursor = [Console]::CursorVisible } catch { }
$esc = [char]27

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Console]::TreatControlCAsInput = $true
    [Console]::Write("$esc[?1049h")          # alternate screen: leaves the user's scrollback intact
    [Console]::CursorVisible = $false

    Read-KnownHostsFile
    Update-View
    if ($S.FileExists) { Set-Status "Loaded $(Format-Count $S.Entries.Count 'entry' 'entries') from $($S.Path)" 'info' }
    else { Set-Status "File not found: $($S.Path)" 'error' }

    $dirty = $true
    while ($true) {
        if ([Console]::WindowWidth -ne $S.LastW -or [Console]::WindowHeight -ne $S.LastH) {
            $S.LastW = [Console]::WindowWidth
            $S.LastH = [Console]::WindowHeight
            [Console]::BackgroundColor = $C.Bg
            [Console]::Clear()
            [Console]::CursorVisible = $false
            $dirty = $true
        }
        if ($dirty) {
            Show-Screen
            $dirty = $false
        }
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $k = [Console]::ReadKey($true)
        $dirty = $true
        if ($S.Mode -eq 'filter') {
            Invoke-FilterKey $k
            continue
        }
        if (-not (Invoke-NormalKey $k)) { break }
    }
}
finally {
    [Console]::ForegroundColor = $saved.Fg
    [Console]::BackgroundColor = $saved.Bg
    [Console]::Write("$esc[?1049l")
    [Console]::OutputEncoding = $saved.Encoding
    [Console]::TreatControlCAsInput = $saved.CtrlC
    try { [Console]::CursorVisible = $saved.Cursor } catch { }
}
