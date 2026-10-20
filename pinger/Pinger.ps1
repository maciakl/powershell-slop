#Requires -Version 5.1
<#
.SYNOPSIS
    Pinger - a real-time, colourful terminal (TUI) ping monitor.

.DESCRIPTION
    Pinger continuously pings a list of IP addresses and/or hostnames and shows
    their status (up / down), the last and average response time, packet loss,
    the time of the last ping and a small trend graph - all updating live.

    Features:
      * Add, edit and remove addresses, each with an optional text label.
      * Global ping interval / timeout, overridable per address.
      * Pause pinging for a single address or for everything.
      * Hostnames show the IP address they resolve to.
      * Ping history is saved to disk and can be browsed per address, with a
        summary (average response time, average downtime, total pings, ...)
        and outages highlighted.

    The script has no external dependencies. It runs on Windows PowerShell 5.1
    (built into Windows 11) and on PowerShell 7+.

    Data is stored as JSON in the folder given by -DataPath:
      settings.json  - global settings and the list of addresses
      history.json   - saved ping history for every address

.PARAMETER Address
    One or more IP addresses or hostnames to add to the monitored list at
    start-up. Addresses that are already in the list are ignored.

.PARAMETER DataPath
    Folder where settings and history are stored.
    Defaults to "%APPDATA%\Pinger".

.PARAMETER Version
    Print the version number and exit.

.PARAMETER Help
    Print usage information and exit.

.EXAMPLE
    .\Pinger.ps1
    Starts the monitor with the saved list of addresses.

.EXAMPLE
    .\Pinger.ps1 8.8.8.8, 1.1.1.1, github.com
    Starts the monitor and adds three addresses.

.EXAMPLE
    .\Pinger.ps1 -DataPath D:\PingerData
    Uses a custom folder for settings and history.

.NOTES
    Name    : Pinger.ps1
    Version : 0.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Address = @(),

    [string] $DataPath = (Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath 'Pinger'),

    [switch] $Version,

    [Alias('h')]
    [switch] $Help
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region ---------------------------------------------------------------- Constants

$script:AppName    = 'Pinger'
$script:AppVersion = '0.1.0'

# Default and allowed values for the user-adjustable settings.
$script:Defaults = @{ Interval = 5.0; Timeout = 1000; HistorySize = 1000 }
$script:Limits   = @{
    IntervalMin = 0.5;  IntervalMax = 3600
    TimeoutMin  = 100;  TimeoutMax  = 60000
    HistoryMin  = 50;   HistoryMax  = 100000
}

# How often hostnames are re-resolved (seconds), and how often history is saved.
$script:DnsRefreshSeconds   = 300
$script:DnsRetrySeconds     = 30
$script:HistorySaveSeconds  = 60
$script:MinWidth            = 60
$script:MinHeight           = 12

# The escape character. "`e" does not exist in Windows PowerShell 5.1.
$script:E = [char]27

# Non-ASCII glyphs are built from code points so the script file itself stays
# pure ASCII (Windows PowerShell 5.1 misreads BOM-less UTF-8 source files).
$script:G = @{
    Dot      = [string][char]0x25CF   # filled circle
    Ring     = [string][char]0x25CB   # hollow circle
    Pause    = [string][char]0x2016   # double vertical bar
    Pointer  = [string][char]0x25B6   # right-pointing triangle
    UpTri    = [string][char]0x25B2
    DownTri  = [string][char]0x25BC
    Ellipsis = [string][char]0x2026
    Cross    = [string][char]0x00D7
    Middot   = [string][char]0x00B7
    Arrow    = [string][char]0x2192
    ArrowUD  = [string][char]0x2191 + [string][char]0x2193
    HLine    = [string][char]0x2500
    VLine    = [string][char]0x2502
    TL       = [string][char]0x250C
    TR       = [string][char]0x2510
    BL       = [string][char]0x2514
    BR       = [string][char]0x2518
    Spark    = @(0x2581..0x2588 | ForEach-Object { [string][char]$_ })
}

#endregion

#region ---------------------------------------------------------------- Help / version

function Get-UsageText {
    <# Returns the text printed by -Help. #>
    @"
$script:AppName $script:AppVersion - real-time terminal ping monitor

USAGE
    .\Pinger.ps1 [[-Address] <string[]>] [-DataPath <path>]
    .\Pinger.ps1 -Version
    .\Pinger.ps1 -Help

PARAMETERS
    -Address   IP addresses / hostnames to add at start-up (comma separated).
    -DataPath  Folder for settings.json and history.json
               (default: %APPDATA%\Pinger).
    -Version   Print the version number and exit.
    -Help      Print this help and exit.

KEYS (main screen)
    Up/Down, J/K      Move selection          PgUp/PgDn, Home/End  Jump
    Enter             View history            A / Insert           Add address
    E / F2            Edit address            D / Delete           Delete address
    Space             Pause/resume selected   P                    Pause/resume all
    R                 Ping selected now       S                    Global settings
    ? / F1            Help                    Q / Ctrl+C           Quit

KEYS (history screen)
    Up/Down, PgUp/PgDn, Home/End  Scroll      F  Show failures only
    C                             Clear       Esc / Backspace  Back

EXAMPLES
    .\Pinger.ps1
    .\Pinger.ps1 8.8.8.8, 1.1.1.1, github.com
"@
}

if ($Version) {
    Write-Output "$script:AppName $script:AppVersion"
    exit 0
}

if ($Help) {
    Write-Output (Get-UsageText)
    exit 0
}

#endregion

#region ---------------------------------------------------------------- Theme

function New-FgColor {
    <# Returns an ANSI 24-bit foreground colour sequence. #>
    param([int] $R, [int] $G, [int] $B)
    "$script:E[38;2;$R;$G;${B}m"
}

function New-BgColor {
    <# Returns an ANSI 24-bit background colour sequence. #>
    param([int] $R, [int] $G, [int] $B)
    "$script:E[48;2;$R;$G;${B}m"
}

$script:C = @{
    Reset     = "$script:E[0m"
    Bold      = "$script:E[1m"
    NoBold    = "$script:E[22m"
    Inverse   = "$script:E[7m"
    NoInverse = "$script:E[27m"
    DefBg     = "$script:E[49m"
    Text      = New-FgColor 222 226 238
    White     = New-FgColor 255 255 255
    Dim       = New-FgColor 125 133 156
    Faint     = New-FgColor 80 88 110
    Accent    = New-FgColor 95 205 255
    Accent2   = New-FgColor 190 145 255
    Up        = New-FgColor 85 225 135
    Down      = New-FgColor 255 95 105
    Warn      = New-FgColor 245 200 75
    Orange    = New-FgColor 255 150 65
    BarBg     = New-BgColor 30 38 68
    SelBg     = New-BgColor 46 60 100
    DownBg    = New-BgColor 95 24 36
    DownSelBg = New-BgColor 130 36 52
    BoxBg     = New-BgColor 24 28 46
    FieldBg   = New-BgColor 42 48 74
    FocusBg   = New-BgColor 58 74 128
    KeyBg     = New-BgColor 72 92 155
    UpBg      = New-BgColor 30 110 65
    PauseBg   = New-BgColor 130 100 20
}

#endregion

#region ---------------------------------------------------------------- Formatting helpers

function Format-Cell {
    <# Pads or truncates plain text to exactly $Width characters. #>
    param([AllowNull()][string] $Text, [int] $Width, [switch] $Right)
    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) {
        if ($Width -eq 1) { return $Text.Substring(0, 1) }
        return $Text.Substring(0, $Width - 1) + $script:G.Ellipsis
    }
    if ($Right) { return $Text.PadLeft($Width) }
    return $Text.PadRight($Width)
}

function Format-Line {
    <#
        Builds one screen line from a flat list of (colour, text) pairs, padded
        or truncated to exactly $Width visible characters, on background $Bg.
    #>
    param([object[]] $Segments, [int] $Width, [string] $Bg = $script:C.DefBg)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($Bg)
    $used = 0
    for ($i = 0; $i -lt $Segments.Count; $i += 2) {
        if ($used -ge $Width) { break }
        $text = [string]$Segments[$i + 1]
        $room = $Width - $used
        if ($text.Length -gt $room) { $text = $text.Substring(0, $room) }
        [void]$sb.Append([string]$Segments[$i]).Append($text)
        $used += $text.Length
    }
    if ($used -lt $Width) { [void]$sb.Append($Bg).Append(' ' * ($Width - $used)) }
    [void]$sb.Append($script:C.Reset)
    $sb.ToString()
}

function Get-SegmentLength {
    <# Visible length of a flat (colour, text) segment list. #>
    param([object[]] $Segments)
    $n = 0
    for ($i = 1; $i -lt $Segments.Count; $i += 2) { $n += ([string]$Segments[$i]).Length }
    $n
}

function Format-Bar {
    <# A full-width bar with left-aligned and right-aligned segment groups. #>
    param([object[]] $Left, [object[]] $Right = @(), [int] $Width, [string] $Bg = $script:C.BarBg)
    $gap = $Width - (Get-SegmentLength $Left) - (Get-SegmentLength $Right)
    if ($gap -lt 1) { return Format-Line -Segments $Left -Width $Width -Bg $Bg }
    Format-Line -Segments ($Left + @($Bg, (' ' * $gap)) + $Right) -Width $Width -Bg $Bg
}

function Format-KeyHints {
    <# Footer with highlighted key names, e.g. [A] Add [E] Edit ... #>
    param([string[]] $Pairs, [int] $Width)
    $segs = @($script:C.Text, ' ')
    $used = 1
    for ($i = 0; $i -lt $Pairs.Count; $i += 2) {
        $key = " $($Pairs[$i]) "
        $desc = " $($Pairs[$i + 1])  "
        if ($used + $key.Length + $desc.Length -gt $Width) { break }
        $segs += @(($script:C.KeyBg + $script:C.White + $script:C.Bold), $key,
                   ($script:C.BarBg + $script:C.NoBold + $script:C.Text), $desc)
        $used += $key.Length + $desc.Length
    }
    Format-Line -Segments $segs -Width $Width -Bg $script:C.BarBg
}

function Format-Duration {
    <# Short, human-friendly duration: "<1s", "42s", "3m 05s", "2h 10m", "1d 4h". #>
    param([TimeSpan] $Span)
    $s = [Math]::Floor([Math]::Max(0.0, $Span.TotalSeconds))
    if ($s -lt 1)     { return '<1s' }
    if ($s -lt 60)    { return ('{0}s' -f [int]$s) }
    if ($s -lt 3600)  { return ('{0}m {1:00}s' -f [int][Math]::Floor($s / 60), [int]($s % 60)) }
    if ($s -lt 86400) { return ('{0}h {1:00}m' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60)) }
    '{0}d {1}h' -f [int][Math]::Floor($s / 86400), [int][Math]::Floor(($s % 86400) / 3600)
}

function Format-Seconds {
    <# "5s" or "2.5s" for an interval value. #>
    param([double] $Seconds)
    if ($Seconds -eq [Math]::Floor($Seconds)) { return ('{0}s' -f [int]$Seconds) }
    '{0:0.##}s' -f $Seconds
}

function Format-PingStatus {
    <# Turns an IPStatus name like "DestinationHostUnreachable" into "Destination host unreachable". #>
    param([string] $Status)
    $spaced = [regex]::Replace($Status, '(?<=[a-z])(?=[A-Z])', ' ')
    if ($spaced.Length -gt 1) { return $spaced.Substring(0, 1) + $spaced.Substring(1).ToLowerInvariant() }
    $spaced
}

function Get-RttColor {
    <# Green for fast, yellow for medium, orange for slow responses. #>
    param([double] $Rtt)
    if ($Rtt -lt 50)  { return $script:C.Up }
    if ($Rtt -lt 150) { return $script:C.Warn }
    $script:C.Orange
}

function Get-InnermostMessage {
    <# Digs the most specific message out of a (possibly nested) exception. #>
    param($Exception)
    $ex = $Exception
    while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
    $ex.Message.Trim()
}

function Get-Spark {
    <#
        Returns a sparkline string of exactly $Width visible characters for the
        most recent history entries. Bar height = response time, red cross = failure.
    #>
    param($History, [int] $Width)
    if ($Width -le 0) { return '' }
    $n = $History.Count
    $start = [Math]::Max(0, $n - $Width)
    $max = 1.0
    for ($i = $start; $i -lt $n; $i++) {
        $e = $History[$i]
        if ($e.Ok -and $e.Rtt -gt $max) { $max = [double]$e.Rtt }
    }
    $sb = New-Object System.Text.StringBuilder
    $pad = $Width - ($n - $start)
    if ($pad -gt 0) { [void]$sb.Append($script:C.Faint).Append($script:G.Middot * $pad) }
    $last = ''
    for ($i = $start; $i -lt $n; $i++) {
        $e = $History[$i]
        if ($e.Ok) {
            $color = Get-RttColor $e.Rtt
            $level = [int][Math]::Floor(($e.Rtt / $max) * 7.999)
            $glyph = $script:G.Spark[[Math]::Max(0, [Math]::Min(7, $level))]
        } else {
            $color = $script:C.Down
            $glyph = $script:G.Cross
        }
        if ($color -ne $last) { [void]$sb.Append($color); $last = $color }
        [void]$sb.Append($glyph)
    }
    $sb.ToString()
}

#endregion

#region ---------------------------------------------------------------- Host model

function Test-IpAddressText {
    <# True when the text is a literal IPv4 (dotted quad) or IPv6 address. #>
    param([string] $Text)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$ip)) { return $false }
    # TryParse also accepts things like "1" or "10.1"; only treat full forms as IPs.
    ($Text -match '^\d{1,3}(\.\d{1,3}){3}$') -or ($Text.Contains(':'))
}

function New-PingHost {
    <# Creates the in-memory object for one monitored address. #>
    param(
        [string] $Address,
        [string] $Label = '',
        $Interval = $null,
        $Timeout = $null,
        [bool] $Paused = $false,
        [string] $Id = ([guid]::NewGuid().ToString('N'))
    )
    $isIp = Test-IpAddressText $Address
    [pscustomobject]@{
        # --- persisted
        Id          = $Id
        Address     = $Address
        Label       = $Label
        Interval    = $Interval    # $null = use global setting
        Timeout     = $Timeout     # $null = use global setting
        Paused      = $Paused
        History     = New-Object 'System.Collections.Generic.List[object]'
        # --- runtime only
        IsIp        = $isIp
        ResolvedIp  = ''
        DnsError    = ''
        Status      = 'Pending'    # Pending | Up | Down
        LastRtt     = $null
        LastTime    = $null
        LastMessage = 'Waiting for first ping'
        NextDue     = [datetime]::MinValue
        ForceNext   = $false
        PingTask    = $null
        PingObj     = $null
        PingStart   = [datetime]::MinValue
        DnsTask     = $null
        NextDns     = [datetime]::MinValue
        Sent        = 0
        Received    = 0
        RttSum      = [long]0
    }
}

function Get-HostInterval {
    param($HostItem)
    if ($null -ne $HostItem.Interval) { return [double]$HostItem.Interval }
    [double]$script:State.Settings.Interval
}

function Get-HostTimeout {
    param($HostItem)
    if ($null -ne $HostItem.Timeout) { return [int]$HostItem.Timeout }
    [int]$script:State.Settings.Timeout
}

function Test-HostPaused {
    param($HostItem)
    $HostItem.Paused -or $script:State.GlobalPaused
}

function Add-HistoryEntry {
    <# Appends a result to a host's history, keeping running totals and the size cap. #>
    param($HostItem, $Entry)
    $HostItem.History.Add($Entry)
    $HostItem.Sent++
    if ($Entry.Ok) { $HostItem.Received++; $HostItem.RttSum += $Entry.Rtt }
    Limit-History $HostItem
}

function Limit-History {
    <# Drops the oldest entries above the configured history size. #>
    param($HostItem)
    $excess = $HostItem.History.Count - [int]$script:State.Settings.HistorySize
    if ($excess -le 0) { return }
    for ($i = 0; $i -lt $excess; $i++) {
        $old = $HostItem.History[$i]
        $HostItem.Sent--
        if ($old.Ok) { $HostItem.Received--; $HostItem.RttSum -= $old.Rtt }
    }
    $HostItem.History.RemoveRange(0, $excess)
}

function Reset-HostStats {
    <# Recalculates the running totals from the stored history. #>
    param($HostItem)
    $HostItem.Sent = 0; $HostItem.Received = 0; $HostItem.RttSum = [long]0
    foreach ($e in $HostItem.History) {
        $HostItem.Sent++
        if ($e.Ok) { $HostItem.Received++; $HostItem.RttSum += $e.Rtt }
    }
    if ($HostItem.History.Count -gt 0) {
        $last = $HostItem.History[$HostItem.History.Count - 1]
        $HostItem.LastTime = $last.Time
        $HostItem.LastMessage = $last.Status
        if ($last.Ok) { $HostItem.Status = 'Up'; $HostItem.LastRtt = $last.Rtt }
        else { $HostItem.Status = 'Down'; $HostItem.LastRtt = $null }
    }
}

function Stop-HostActivity {
    <# Abandons any ping or DNS lookup in flight for a host. #>
    param($HostItem)
    if ($null -ne $HostItem.PingObj) {
        try { $HostItem.PingObj.SendAsyncCancel() } catch { Write-Verbose "Cancel failed: $_" }
    }
    $HostItem.PingTask = $null
    $HostItem.PingObj = $null
    $HostItem.DnsTask = $null
}

#endregion

#region ---------------------------------------------------------------- Ping engine

function New-HistoryEntry {
    param([datetime] $Time, [bool] $Ok, [int] $Rtt, [string] $Status)
    [pscustomobject]@{ Time = $Time; Ok = $Ok; Rtt = $Rtt; Status = $Status }
}

function Complete-Ping {
    <# Records a finished (or failed) ping for a host. #>
    param($HostItem, [bool] $Ok, [int] $Rtt, [string] $Message)
    $now = [datetime]::Now
    Add-HistoryEntry $HostItem (New-HistoryEntry -Time $now -Ok $Ok -Rtt $Rtt -Status $Message)
    $HostItem.LastTime = $now
    $HostItem.LastMessage = $Message
    if ($Ok) { $HostItem.Status = 'Up'; $HostItem.LastRtt = $Rtt }
    else     { $HostItem.Status = 'Down'; $HostItem.LastRtt = $null }
}

function Start-HostPing {
    <# Starts an asynchronous ping. The result is collected later by Update-PingEngine. #>
    param($HostItem, [datetime] $Now)
    $HostItem.NextDue = $Now.AddSeconds((Get-HostInterval $HostItem))
    $HostItem.ForceNext = $false
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $HostItem.PingTask = $ping.SendPingAsync([string]$HostItem.Address, [int](Get-HostTimeout $HostItem))
        $HostItem.PingObj = $ping
        $HostItem.PingStart = $Now
    } catch {
        $ping.Dispose()
        Complete-Ping $HostItem $false 0 (Get-InnermostMessage $_.Exception)
    }
}

function Receive-HostPing {
    <# Collects the result of a completed ping task. #>
    param($HostItem)
    $task = $HostItem.PingTask
    try {
        if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $reply = $task.Result
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                if (-not $HostItem.IsIp -and $null -ne $reply.Address) {
                    $HostItem.ResolvedIp = $reply.Address.ToString()
                    $HostItem.DnsError = ''
                }
                Complete-Ping $HostItem $true ([int]$reply.RoundtripTime) 'Success'
            } else {
                Complete-Ping $HostItem $false 0 (Format-PingStatus $reply.Status.ToString())
            }
        } elseif ($task.IsCanceled) {
            Complete-Ping $HostItem $false 0 'Cancelled'
        } else {
            Complete-Ping $HostItem $false 0 (Get-InnermostMessage $task.Exception)
        }
    } catch {
        Complete-Ping $HostItem $false 0 (Get-InnermostMessage $_.Exception)
    } finally {
        if ($null -ne $HostItem.PingObj) { $HostItem.PingObj.Dispose() }
        $HostItem.PingTask = $null
        $HostItem.PingObj = $null
    }
}

function Update-HostDns {
    <# Starts / collects background DNS lookups so hostnames show their IP. #>
    param($HostItem, [datetime] $Now)
    if ($HostItem.IsIp) { return $false }
    $task = $HostItem.DnsTask
    if ($null -ne $task) {
        if (-not $task.IsCompleted) { return $false }
        $HostItem.DnsTask = $null
        if ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $task.Result.Count -gt 0) {
            # Prefer IPv4 - that is what most people expect to see.
            $addrs = @($task.Result)
            $v4 = @($addrs | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            $pick = if ($v4.Count -gt 0) { $v4[0] } else { $addrs[0] }
            $HostItem.ResolvedIp = $pick.ToString()
            $HostItem.DnsError = ''
            $HostItem.NextDns = $Now.AddSeconds($script:DnsRefreshSeconds)
        } else {
            $HostItem.ResolvedIp = ''
            $HostItem.DnsError = if ($task.Exception) { Get-InnermostMessage $task.Exception } else { 'No addresses found' }
            $HostItem.NextDns = $Now.AddSeconds($script:DnsRetrySeconds)
        }
        return $true
    }
    if ($Now -ge $HostItem.NextDns -and -not (Test-HostPaused $HostItem)) {
        try {
            $HostItem.DnsTask = [System.Net.Dns]::GetHostAddressesAsync($HostItem.Address)
        } catch {
            $HostItem.DnsError = Get-InnermostMessage $_.Exception
            $HostItem.NextDns = $Now.AddSeconds($script:DnsRetrySeconds)
            return $true
        }
    }
    $false
}

function Update-PingEngine {
    <#
        One tick of the scheduler: collects finished pings, starts pings that
        are due and handles DNS. Returns $true when anything visible changed.
    #>
    $now = [datetime]::Now
    $changed = $false
    foreach ($h in $script:State.Hosts) {
        if (Update-HostDns $h $now) { $changed = $true }

        if ($null -ne $h.PingTask) {
            if ($h.PingTask.IsCompleted) {
                Receive-HostPing $h
                $changed = $true
            } elseif (($now - $h.PingStart).TotalMilliseconds -gt ((Get-HostTimeout $h) + 5000)) {
                # The OS never answered - treat as a failure rather than waiting forever.
                Stop-HostActivity $h
                Complete-Ping $h $false 0 'No response from network stack'
                $changed = $true
            }
        } elseif (($h.ForceNext -or -not (Test-HostPaused $h)) -and ($h.ForceNext -or $now -ge $h.NextDue)) {
            Start-HostPing $h $now
            if ($null -eq $h.PingTask) { $changed = $true }
        }
    }
    $changed
}

#endregion

#region ---------------------------------------------------------------- Persistence

function Get-JsonValue {
    <# Safely reads an optional property from a ConvertFrom-Json object. #>
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    $p.Value
}

function ConvertTo-JsonText {
    <# Escapes a string as a JSON string literal (with quotes). #>
    param([string] $Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); break }
            '\'  { [void]$sb.Append('\\'); break }
            default {
                if ([int]$ch -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Write-FileAtomic {
    <# Writes text to a temp file and swaps it in, so a crash never leaves a half-written file. #>
    param([string] $Path, [string] $Content)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Save-Settings {
    <# Saves global settings and the address list. #>
    try {
        $hosts = @(foreach ($h in $script:State.Hosts) {
            [ordered]@{
                id       = $h.Id
                address  = $h.Address
                label    = $h.Label
                interval = $h.Interval
                timeout  = $h.Timeout
                paused   = $h.Paused
            }
        })
        $doc = [ordered]@{
            app          = $script:AppName
            version      = $script:AppVersion
            settings     = [ordered]@{
                interval    = $script:State.Settings.Interval
                timeout     = $script:State.Settings.Timeout
                historySize = $script:State.Settings.HistorySize
            }
            globalPaused = $script:State.GlobalPaused
            hosts        = $hosts
        }
        Write-FileAtomic $script:State.SettingsFile (ConvertTo-Json -InputObject $doc -Depth 5)
    } catch {
        Show-Message "Could not save settings: $(Get-InnermostMessage $_.Exception)" -IsError
    }
}

function Save-History {
    <#
        Saves ping history. Written by hand rather than with ConvertTo-Json
        because it is much faster for tens of thousands of entries.
        Format: { "hosts": { "<id>": [ [ticks, ok(1/0), rtt, "status"], ... ] } }
    #>
    try {
        $escaped = @{}
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"version":1,"hosts":{')
        $firstHost = $true
        foreach ($h in $script:State.Hosts) {
            if (-not $firstHost) { [void]$sb.Append(',') }
            $firstHost = $false
            [void]$sb.Append('"').Append($h.Id).Append('":[')
            $firstEntry = $true
            foreach ($e in $h.History) {
                if (-not $firstEntry) { [void]$sb.Append(',') }
                $firstEntry = $false
                $s = $escaped[$e.Status]
                if ($null -eq $s) { $s = ConvertTo-JsonText $e.Status; $escaped[$e.Status] = $s }
                $ok = if ($e.Ok) { '1' } else { '0' }
                [void]$sb.Append('[').Append($e.Time.Ticks).Append(',').Append($ok).Append(',').Append($e.Rtt).Append(',').Append($s).Append(']')
            }
            [void]$sb.Append(']')
        }
        [void]$sb.Append('}}')
        Write-FileAtomic $script:State.HistoryFile $sb.ToString()
        $script:State.LastHistorySave = [datetime]::Now
    } catch {
        Show-Message "Could not save history: $(Get-InnermostMessage $_.Exception)" -IsError
    }
}

function Backup-BrokenFile {
    <# Keeps a copy of an unreadable data file so it is not silently overwritten. #>
    param([string] $Path)
    try {
        $backup = '{0}.broken-{1:yyyyMMdd-HHmmss}' -f $Path, [datetime]::Now
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    } catch { Write-Verbose "Backup failed: $_" }
}

function Import-PingerData {
    <# Loads settings, hosts and history from disk. Problems are reported, never fatal. #>
    $s = $script:State
    if (Test-Path -LiteralPath $s.SettingsFile) {
        try {
            $data = [System.IO.File]::ReadAllText($s.SettingsFile) | ConvertFrom-Json
            $set = Get-JsonValue $data 'settings'
            $s.Settings.Interval    = [double](Get-JsonValue $set 'interval' $script:Defaults.Interval)
            $s.Settings.Timeout     = [int](Get-JsonValue $set 'timeout' $script:Defaults.Timeout)
            $s.Settings.HistorySize = [int](Get-JsonValue $set 'historySize' $script:Defaults.HistorySize)
            $s.GlobalPaused         = [bool](Get-JsonValue $data 'globalPaused' $false)
            foreach ($hd in @(Get-JsonValue $data 'hosts' @())) {
                if ($null -eq $hd) { continue }
                $addr = [string](Get-JsonValue $hd 'address' '')
                if ([string]::IsNullOrWhiteSpace($addr)) { continue }
                $interval = Get-JsonValue $hd 'interval'
                $timeout  = Get-JsonValue $hd 'timeout'
                $s.Hosts.Add((New-PingHost -Address $addr `
                    -Label ([string](Get-JsonValue $hd 'label' '')) `
                    -Interval $(if ($null -ne $interval) { [double]$interval } else { $null }) `
                    -Timeout $(if ($null -ne $timeout) { [int]$timeout } else { $null }) `
                    -Paused ([bool](Get-JsonValue $hd 'paused' $false)) `
                    -Id ([string](Get-JsonValue $hd 'id' ([guid]::NewGuid().ToString('N'))))))
            }
        } catch {
            Backup-BrokenFile $s.SettingsFile
            Show-Message "Settings file unreadable (backup kept): $(Get-InnermostMessage $_.Exception)" -IsError
        }
    }

    if ((Test-Path -LiteralPath $s.HistoryFile) -and $s.Hosts.Count -gt 0) {
        try {
            $data = [System.IO.File]::ReadAllText($s.HistoryFile) | ConvertFrom-Json
            $byId = Get-JsonValue $data 'hosts'
            foreach ($h in $s.Hosts) {
                $rows = Get-JsonValue $byId $h.Id
                if ($null -eq $rows) { continue }
                foreach ($row in @($rows)) {
                    if ($null -eq $row -or @($row).Count -lt 4) { continue }
                    $h.History.Add((New-HistoryEntry `
                        -Time ([datetime]::new([long]$row[0], [System.DateTimeKind]::Local)) `
                        -Ok ([int]$row[1] -eq 1) -Rtt ([int]$row[2]) -Status ([string]$row[3])))
                }
                Limit-History $h
                Reset-HostStats $h
            }
        } catch {
            Backup-BrokenFile $s.HistoryFile
            Show-Message "History file unreadable (backup kept): $(Get-InnermostMessage $_.Exception)" -IsError
        }
    }
}

#endregion

#region ---------------------------------------------------------------- Application state

function Show-Message {
    <# Shows a temporary message in the status line. #>
    param([string] $Text, [switch] $IsError, [int] $Seconds = 5)
    $script:State.Message = $Text
    $script:State.MessageIsError = [bool]$IsError
    $script:State.MessageUntil = [datetime]::Now.AddSeconds($Seconds)
}

function Initialize-State {
    param([string] $Folder)
    $script:State = [pscustomobject]@{
        Settings        = @{
            Interval    = $script:Defaults.Interval
            Timeout     = $script:Defaults.Timeout
            HistorySize = $script:Defaults.HistorySize
        }
        Hosts           = New-Object 'System.Collections.Generic.List[object]'
        GlobalPaused    = $false
        Selected        = 0
        Scroll          = 0
        Mode            = 'Main'      # Main | History
        Overlay         = $null       # form / confirm / help dialog, or $null
        HistoryHost     = $null
        HistoryScroll   = 0
        HistoryFailOnly = $false
        Quit            = $false
        Message         = ''
        MessageIsError  = $false
        MessageUntil    = [datetime]::MinValue
        DataPath        = $Folder
        SettingsFile    = Join-Path $Folder 'settings.json'
        HistoryFile     = Join-Path $Folder 'history.json'
        LastHistorySave = [datetime]::Now
        ListHeight      = 10
        HistoryHeight   = 10
    }
}

function Get-SelectedHost {
    $s = $script:State
    if ($s.Hosts.Count -eq 0) { return $null }
    $s.Selected = [Math]::Max(0, [Math]::Min($s.Selected, $s.Hosts.Count - 1))
    $s.Hosts[$s.Selected]
}

function Find-Host {
    <# Finds a host by address (case-insensitive), optionally ignoring one host. #>
    param([string] $Address, $Except = $null)
    foreach ($h in $script:State.Hosts) {
        if ($h -ne $Except -and $h.Address -ieq $Address) { return $h }
    }
    $null
}

#endregion

#region ---------------------------------------------------------------- Input validation

function Test-HostnameText {
    <# RFC 1123-ish hostname check. #>
    param([string] $Text)
    if ($Text.Length -gt 253) { return $false }
    $Text -match '^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$'
}

function ConvertTo-OptionalNumber {
    <#
        Parses an optional numeric field. Returns @{ Ok; Value; Error }.
        Empty text gives $null (= "use the global setting") when -AllowEmpty is set.
    #>
    param([string] $Text, [string] $Name, [double] $Min, [double] $Max, [string] $Suffix, [switch] $AllowEmpty, [switch] $Integer)
    $t = $Text.Trim().ToLowerInvariant()
    if ($Suffix -and $t.EndsWith($Suffix)) { $t = $t.Substring(0, $t.Length - $Suffix.Length).Trim() }
    if ($t -eq '') {
        if ($AllowEmpty) { return @{ Ok = $true; Value = $null; Error = '' } }
        return @{ Ok = $false; Value = $null; Error = "$Name is required." }
    }
    $d = 0.0
    $ok = [double]::TryParse($t.Replace(',', '.'), [System.Globalization.NumberStyles]::Float,
                             [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)
    if (-not $ok) { return @{ Ok = $false; Value = $null; Error = "$Name must be a number." } }
    if ($Integer -and $d -ne [Math]::Floor($d)) { return @{ Ok = $false; Value = $null; Error = "$Name must be a whole number." } }
    if ($d -lt $Min -or $d -gt $Max) { return @{ Ok = $false; Value = $null; Error = "$Name must be between $Min and $Max." } }
    if ($Integer) { return @{ Ok = $true; Value = [int]$d; Error = '' } }
    @{ Ok = $true; Value = $d; Error = '' }
}

#endregion

#region ---------------------------------------------------------------- Dialogs (overlays)

function New-FormField {
    param([string] $Name, [string] $Label, [string] $Value = '', [string] $Hint = '')
    @{ Name = $Name; Label = $Label; Value = $Value; Hint = $Hint }
}

function Open-HostForm {
    <# Opens the add (no host) or edit (host given) dialog. #>
    param($HostItem = $null)
    $g = $script:State.Settings
    $intHint = "Seconds, blank = global ($(Format-Seconds $g.Interval))"
    $tmoHint = "Milliseconds, blank = global ($($g.Timeout) ms)"
    if ($null -eq $HostItem) {
        $title = 'Add address'
        $fields = @(
            (New-FormField 'Address' 'Address' '' 'IP address or hostname, e.g. 8.8.8.8 or example.com'),
            (New-FormField 'Label' 'Label' '' 'Optional friendly name'),
            (New-FormField 'Interval' 'Interval' '' $intHint),
            (New-FormField 'Timeout' 'Timeout' '' $tmoHint)
        )
    } else {
        $title = 'Edit address'
        $fields = @(
            (New-FormField 'Address' 'Address' $HostItem.Address 'Changing the address clears its history'),
            (New-FormField 'Label' 'Label' $HostItem.Label 'Optional friendly name'),
            (New-FormField 'Interval' 'Interval' $(if ($null -ne $HostItem.Interval) { [string]$HostItem.Interval } else { '' }) $intHint),
            (New-FormField 'Timeout' 'Timeout' $(if ($null -ne $HostItem.Timeout) { [string]$HostItem.Timeout } else { '' }) $tmoHint)
        )
    }
    $script:State.Overlay = @{ Type = 'Form'; Kind = 'Host'; Title = $title; Target = $HostItem; Fields = $fields; Focus = 0; Error = '' }
}

function Open-SettingsForm {
    $g = $script:State.Settings
    $L = $script:Limits
    $script:State.Overlay = @{
        Type = 'Form'; Kind = 'Settings'; Title = 'Global settings'; Target = $null; Focus = 0; Error = ''
        Fields = @(
            (New-FormField 'Interval' 'Interval' ([string]$g.Interval) "Seconds between pings ($($L.IntervalMin)-$($L.IntervalMax))"),
            (New-FormField 'Timeout' 'Timeout' ([string]$g.Timeout) "Milliseconds to wait for a reply ($($L.TimeoutMin)-$($L.TimeoutMax))"),
            (New-FormField 'History' 'History size' ([string]$g.HistorySize) "Results kept per address ($($L.HistoryMin)-$($L.HistoryMax))")
        )
    }
}

function Open-Confirm {
    param([string] $Kind, [string] $Title, [string] $Text, $Target = $null)
    $script:State.Overlay = @{ Type = 'Confirm'; Kind = $Kind; Title = $Title; Text = $Text; Target = $Target }
}

function Get-FieldValue {
    param($Form, [string] $Name)
    foreach ($f in $Form.Fields) { if ($f.Name -eq $Name) { return $f.Value } }
    ''
}

function Submit-HostForm {
    <# Validates and applies the add/edit dialog. Returns an error message or ''. #>
    param($Form)
    $L = $script:Limits
    $addr = (Get-FieldValue $Form 'Address').Trim()
    $label = (Get-FieldValue $Form 'Label').Trim()
    if ($addr -eq '') { return 'Address is required.' }
    if (-not (Test-IpAddressText $addr) -and -not (Test-HostnameText $addr)) { return "'$addr' is not a valid IP address or hostname." }
    if ($null -ne (Find-Host $addr $Form.Target)) { return "'$addr' is already in the list." }
    $int = ConvertTo-OptionalNumber (Get-FieldValue $Form 'Interval') 'Interval' $L.IntervalMin $L.IntervalMax 's' -AllowEmpty
    if (-not $int.Ok) { return $int.Error }
    $tmo = ConvertTo-OptionalNumber (Get-FieldValue $Form 'Timeout') 'Timeout' $L.TimeoutMin $L.TimeoutMax 'ms' -AllowEmpty -Integer
    if (-not $tmo.Ok) { return $tmo.Error }

    $h = $Form.Target
    if ($null -eq $h) {
        $h = New-PingHost -Address $addr -Label $label -Interval $int.Value -Timeout $tmo.Value
        $script:State.Hosts.Add($h)
        $script:State.Selected = $script:State.Hosts.Count - 1
        Show-Message "Added $addr"
    } else {
        if ($h.Address -cne $addr) {
            # A new target: start from a clean slate.
            Stop-HostActivity $h
            $h.Address = $addr
            $h.IsIp = Test-IpAddressText $addr
            $h.ResolvedIp = ''; $h.DnsError = ''; $h.NextDns = [datetime]::MinValue
            $h.History.Clear(); Reset-HostStats $h
            $h.Status = 'Pending'; $h.LastRtt = $null; $h.LastTime = $null; $h.LastMessage = 'Waiting for first ping'
        }
        $h.Label = $label
        $h.Interval = $int.Value
        $h.Timeout = $tmo.Value
        $h.NextDue = [datetime]::MinValue
        Show-Message "Updated $addr"
    }
    Save-Settings
    Save-History
    ''
}

function Submit-SettingsForm {
    <# Validates and applies the global settings dialog. Returns an error message or ''. #>
    param($Form)
    $L = $script:Limits
    $int = ConvertTo-OptionalNumber (Get-FieldValue $Form 'Interval') 'Interval' $L.IntervalMin $L.IntervalMax 's'
    if (-not $int.Ok) { return $int.Error }
    $tmo = ConvertTo-OptionalNumber (Get-FieldValue $Form 'Timeout') 'Timeout' $L.TimeoutMin $L.TimeoutMax 'ms' -Integer
    if (-not $tmo.Ok) { return $tmo.Error }
    $hist = ConvertTo-OptionalNumber (Get-FieldValue $Form 'History') 'History size' $L.HistoryMin $L.HistoryMax '' -Integer
    if (-not $hist.Ok) { return $hist.Error }
    $g = $script:State.Settings
    $g.Interval = $int.Value
    $g.Timeout = $tmo.Value
    $g.HistorySize = $hist.Value
    foreach ($h in $script:State.Hosts) {
        Limit-History $h
        # Re-schedule hosts that follow the global interval.
        if ($null -eq $h.Interval) { $h.NextDue = [datetime]::MinValue }
    }
    Save-Settings
    Save-History
    Show-Message 'Settings saved'
    ''
}

function Invoke-ConfirmYes {
    <# Carries out the action of a confirmation dialog. #>
    param($Dialog)
    $s = $script:State
    switch ($Dialog.Kind) {
        'Delete' {
            $h = $Dialog.Target
            Stop-HostActivity $h
            [void]$s.Hosts.Remove($h)
            if ($s.Selected -ge $s.Hosts.Count) { $s.Selected = [Math]::Max(0, $s.Hosts.Count - 1) }
            Save-Settings
            Save-History
            Show-Message "Deleted $($h.Address)"
        }
        'ClearHistory' {
            $h = $Dialog.Target
            $h.History.Clear()
            Reset-HostStats $h
            $s.HistoryScroll = 0
            Save-History
            Show-Message "History cleared for $($h.Address)"
        }
        'Quit' { $s.Quit = $true }
    }
}

#endregion

#region ---------------------------------------------------------------- Keyboard handling

function Test-CtrlC {
    param([System.ConsoleKeyInfo] $Key)
    ($Key.Key -eq [ConsoleKey]::C) -and (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
}

function Invoke-OverlayKey {
    <# Keys while a dialog is open. #>
    param([System.ConsoleKeyInfo] $Key)
    $s = $script:State
    $o = $s.Overlay
    switch ($o.Type) {
        'Help' { $s.Overlay = $null; return }
        'Confirm' {
            $ch = ([string]$Key.KeyChar).ToLowerInvariant()
            if ($ch -eq 'y' -or $Key.Key -eq [ConsoleKey]::Enter) { $s.Overlay = $null; Invoke-ConfirmYes $o }
            elseif ($ch -eq 'n' -or $Key.Key -eq [ConsoleKey]::Escape) { $s.Overlay = $null }
            return
        }
        'Form' {
            $field = $o.Fields[$o.Focus]
            $count = $o.Fields.Count
            $shift = ($Key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
            $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            switch ($Key.Key) {
                ([ConsoleKey]::Escape)    { $s.Overlay = $null; return }
                ([ConsoleKey]::Enter)     {
                    $err = if ($o.Kind -eq 'Settings') { Submit-SettingsForm $o } else { Submit-HostForm $o }
                    if ($err) { $o.Error = $err } else { $s.Overlay = $null }
                    return
                }
                ([ConsoleKey]::Tab)       { if ($shift) { $o.Focus = ($o.Focus + $count - 1) % $count } else { $o.Focus = ($o.Focus + 1) % $count }; return }
                ([ConsoleKey]::UpArrow)   { $o.Focus = ($o.Focus + $count - 1) % $count; return }
                ([ConsoleKey]::DownArrow) { $o.Focus = ($o.Focus + 1) % $count; return }
                ([ConsoleKey]::Backspace) {
                    if ($ctrl) { $field.Value = '' }
                    elseif ($field.Value.Length -gt 0) { $field.Value = $field.Value.Substring(0, $field.Value.Length - 1) }
                    $o.Error = ''
                    return
                }
            }
            if ($ctrl -and $Key.Key -eq [ConsoleKey]::U) { $field.Value = ''; return }
            $ch = $Key.KeyChar
            if ([int]$ch -ne 0 -and -not [char]::IsControl($ch) -and $field.Value.Length -lt 253) {
                $field.Value += $ch
                $o.Error = ''
            }
        }
    }
}

function Move-Selection {
    param([int] $Delta)
    $s = $script:State
    if ($s.Hosts.Count -eq 0) { return }
    $s.Selected = [Math]::Max(0, [Math]::Min($s.Hosts.Count - 1, $s.Selected + $Delta))
}

function Invoke-MainKey {
    <# Keys on the main (address list) screen. #>
    param([System.ConsoleKeyInfo] $Key)
    $s = $script:State
    $sel = Get-SelectedHost
    switch ($Key.Key) {
        ([ConsoleKey]::UpArrow)   { Move-Selection -1; return }
        ([ConsoleKey]::DownArrow) { Move-Selection 1; return }
        ([ConsoleKey]::PageUp)    { Move-Selection (-$s.ListHeight); return }
        ([ConsoleKey]::PageDown)  { Move-Selection $s.ListHeight; return }
        ([ConsoleKey]::Home)      { Move-Selection (-$s.Hosts.Count); return }
        ([ConsoleKey]::End)       { Move-Selection $s.Hosts.Count; return }
        ([ConsoleKey]::Insert)    { Open-HostForm; return }
        ([ConsoleKey]::F1)        { $s.Overlay = @{ Type = 'Help' }; return }
        ([ConsoleKey]::Escape)    { return }
        ([ConsoleKey]::Enter)     {
            if ($sel) { $s.Mode = 'History'; $s.HistoryHost = $sel; $s.HistoryScroll = 0 }
            return
        }
    }
    $ch = ([string]$Key.KeyChar).ToLowerInvariant()
    if ($Key.Key -eq [ConsoleKey]::F2) { $ch = 'e' }
    if ($Key.Key -eq [ConsoleKey]::Delete) { $ch = 'd' }
    switch ($ch) {
        'k' { Move-Selection -1 }
        'j' { Move-Selection 1 }
        'a' { Open-HostForm }
        'e' { if ($sel) { Open-HostForm $sel } }
        'd' {
            if ($sel) {
                $name = if ($sel.Label) { "$($sel.Label) ($($sel.Address))" } else { $sel.Address }
                Open-Confirm 'Delete' 'Delete address' "Delete $name and its history?" $sel
            }
        }
        ' ' {
            if ($sel) {
                $sel.Paused = -not $sel.Paused
                if (-not $sel.Paused) { $sel.NextDue = [datetime]::MinValue }
                Show-Message ("{0} {1}" -f $(if ($sel.Paused) { 'Paused' } else { 'Resumed' }), $sel.Address)
                Save-Settings
            }
        }
        'p' {
            $s.GlobalPaused = -not $s.GlobalPaused
            if (-not $s.GlobalPaused) { foreach ($h in $s.Hosts) { $h.NextDue = [datetime]::MinValue } }
            Show-Message $(if ($s.GlobalPaused) { 'All pinging paused' } else { 'All pinging resumed' })
            Save-Settings
        }
        'r' {
            if ($sel) { $sel.ForceNext = $true; Show-Message "Pinging $($sel.Address) now" -Seconds 2 }
        }
        's' { Open-SettingsForm }
        '?' { $s.Overlay = @{ Type = 'Help' } }
        'h' { $s.Overlay = @{ Type = 'Help' } }
        'q' { $s.Quit = $true }
    }
}

function Invoke-HistoryKey {
    <# Keys on the history screen. #>
    param([System.ConsoleKeyInfo] $Key)
    $s = $script:State
    $page = [Math]::Max(1, $s.HistoryHeight - 1)
    switch ($Key.Key) {
        ([ConsoleKey]::Escape)    { $s.Mode = 'Main'; return }
        ([ConsoleKey]::Backspace) { $s.Mode = 'Main'; return }
        ([ConsoleKey]::UpArrow)   { $s.HistoryScroll--; return }
        ([ConsoleKey]::DownArrow) { $s.HistoryScroll++; return }
        ([ConsoleKey]::PageUp)    { $s.HistoryScroll -= $page; return }
        ([ConsoleKey]::PageDown)  { $s.HistoryScroll += $page; return }
        ([ConsoleKey]::Home)      { $s.HistoryScroll = 0; return }
        ([ConsoleKey]::End)       { $s.HistoryScroll = [int]::MaxValue; return }
        ([ConsoleKey]::F1)        { $s.Overlay = @{ Type = 'Help' }; return }
    }
    switch (([string]$Key.KeyChar).ToLowerInvariant()) {
        'k' { $s.HistoryScroll-- }
        'j' { $s.HistoryScroll++ }
        'f' { $s.HistoryFailOnly = -not $s.HistoryFailOnly; $s.HistoryScroll = 0 }
        'c' { Open-Confirm 'ClearHistory' 'Clear history' "Clear all history for $($s.HistoryHost.Address)?" $s.HistoryHost }
        'r' { $s.HistoryHost.ForceNext = $true; Show-Message "Pinging $($s.HistoryHost.Address) now" -Seconds 2 }
        ' ' { $s.HistoryHost.Paused = -not $s.HistoryHost.Paused; if (-not $s.HistoryHost.Paused) { $s.HistoryHost.NextDue = [datetime]::MinValue }; Save-Settings }
        '?' { $s.Overlay = @{ Type = 'Help' } }
        'h' { $s.Overlay = @{ Type = 'Help' } }
        'q' { $s.Mode = 'Main' }
    }
}

function Invoke-Key {
    <# Routes a key press to the active screen or dialog. #>
    param([System.ConsoleKeyInfo] $Key)
    if (Test-CtrlC $Key) { $script:State.Quit = $true; return }
    if ($null -ne $script:State.Overlay) { Invoke-OverlayKey $Key; return }
    if ($script:State.Mode -eq 'History') { Invoke-HistoryKey $Key } else { Invoke-MainKey $Key }
}

#endregion

#region ---------------------------------------------------------------- Rendering: main screen

function Get-MainColumns {
    <#
        Decides which columns fit in the current width and how wide each is.
        Low-priority columns are dropped first on narrow windows.
    #>
    param([int] $Width)
    $cols = @(
        @{ Key = 'status'; Title = 'STATUS';      Min = 8;  Pri = 0; Right = $false; Grow = 0 }
        @{ Key = 'label';  Title = 'LABEL';       Min = 10; Pri = 3; Right = $false; Grow = 12 }
        @{ Key = 'addr';   Title = 'ADDRESS';     Min = 14; Pri = 0; Right = $false; Grow = 18 }
        @{ Key = 'ip';     Title = 'RESOLVED IP'; Min = 15; Pri = 4; Right = $false; Grow = 24 }
        @{ Key = 'last';   Title = 'LAST';        Min = 7;  Pri = 1; Right = $true;  Grow = 0 }
        @{ Key = 'avg';    Title = 'AVG';         Min = 9;  Pri = 1; Right = $true;  Grow = 0 }
        @{ Key = 'loss';   Title = 'LOSS';        Min = 6;  Pri = 5; Right = $true;  Grow = 0 }
        @{ Key = 'time';   Title = 'PINGED';      Min = 8;  Pri = 2; Right = $false; Grow = 0 }
        @{ Key = 'cfg';    Title = 'EVERY/WAIT';  Min = 12; Pri = 6; Right = $false; Grow = 0 }
        @{ Key = 'spark';  Title = 'TREND';       Min = 10; Pri = 7; Right = $false; Grow = 1000 }
    )
    $avail = $Width - 3   # 2 for the selection marker, 1 right margin
    $active = New-Object System.Collections.ArrayList
    foreach ($c in $cols) { [void]$active.Add($c) }
    while ($true) {
        $need = 0
        foreach ($c in $active) { $need += $c.Min + 1 }
        if ($need -le $avail) { break }
        $drop = $null
        foreach ($c in $active) { if ($c.Pri -gt 0 -and ($null -eq $drop -or $c.Pri -gt $drop.Pri)) { $drop = $c } }
        if ($null -eq $drop) { break }
        $active.Remove($drop)
    }
    $extra = $avail - $need
    foreach ($c in $active) { $c.Width = $c.Min }
    # Hand out spare space: text columns first (capped), then the trend graph.
    foreach ($c in ($active | Sort-Object { $_.Grow })) {
        if ($extra -le 0) { break }
        $add = [Math]::Min($extra, $c.Grow)
        $c.Width += $add
        $extra -= $add
    }
    if ($extra -gt 0) { foreach ($c in $active) { if ($c.Key -eq 'addr') { $c.Width += $extra } } }
    , $active.ToArray()
}

function Get-HostCell {
    <# Returns @(colour, text) for one cell of the address list. #>
    param($HostItem, [string] $Key)
    $C = $script:C
    $h = $HostItem
    switch ($Key) {
        'status' {
            if (Test-HostPaused $h) { return @($C.Warn, "$($script:G.Pause) PAUSED") }
            switch ($h.Status) {
                'Up'    { return @($C.Up, "$($script:G.Dot) UP") }
                'Down'  { return @($C.Down, "$($script:G.Dot) DOWN") }
                default { return @($C.Dim, "$($script:G.Ring) WAIT") }
            }
        }
        'label' { return @(($C.White + $C.Bold), $h.Label) }
        'addr'  { return @(($C.NoBold + $C.Text), $h.Address) }
        'ip' {
            if ($h.IsIp) { return @($C.Faint, $script:G.Middot) }
            if ($h.ResolvedIp) { return @($C.Accent, $h.ResolvedIp) }
            if ($h.DnsError) { return @($C.Down, 'unresolved') }
            return @($C.Dim, 'resolving' + $script:G.Ellipsis)
        }
        'last' {
            if ($null -ne $h.LastRtt) { return @((Get-RttColor $h.LastRtt), "$($h.LastRtt) ms") }
            if ($h.Status -eq 'Down') { return @($C.Down, 'fail') }
            return @($C.Faint, '-')
        }
        'avg' {
            if ($h.Received -gt 0) {
                $avg = $h.RttSum / $h.Received
                return @((Get-RttColor $avg), ('{0:0.0} ms' -f $avg))
            }
            return @($C.Faint, '-')
        }
        'loss' {
            if ($h.Sent -eq 0) { return @($C.Faint, '-') }
            $loss = 100.0 * ($h.Sent - $h.Received) / $h.Sent
            $color = if ($loss -eq 0) { $C.Up } elseif ($loss -lt 5) { $C.Warn } else { $C.Down }
            return @($color, ('{0:0.#}%' -f $loss))
        }
        'time' {
            if ($null -eq $h.LastTime) { return @($C.Faint, '--:--:--') }
            return @($C.Dim, $h.LastTime.ToString('HH:mm:ss'))
        }
        'cfg' {
            # Per-address overrides are shown in purple, global values dimmed.
            $txt = '{0}/{1}ms' -f (Format-Seconds (Get-HostInterval $h)), (Get-HostTimeout $h)
            $color = if ($null -ne $h.Interval -or $null -ne $h.Timeout) { $C.Accent2 } else { $C.Dim }
            return @($color, $txt)
        }
    }
    @($C.Text, '')
}

function Get-HostRow {
    <# One fully formatted row of the address list. #>
    param($HostItem, [object[]] $Columns, [bool] $Selected, [int] $Width)
    $C = $script:C
    $bg = if ($Selected) { $C.SelBg } else { $C.DefBg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($bg)
    if ($Selected) { [void]$sb.Append($C.Accent).Append($script:G.Pointer).Append(' ') } else { [void]$sb.Append('  ') }
    $used = 2
    foreach ($col in $Columns) {
        if ($col.Key -eq 'spark') {
            [void]$sb.Append((Get-Spark $HostItem.History $col.Width)).Append(' ')
        } else {
            $cell = Get-HostCell $HostItem $col.Key
            [void]$sb.Append($cell[0]).Append((Format-Cell $cell[1] $col.Width -Right:$col.Right)).Append($C.NoBold).Append(' ')
        }
        $used += $col.Width + 1
    }
    if ($used -lt $Width) { [void]$sb.Append(' ' * ($Width - $used)) }
    [void]$sb.Append($C.Reset)
    $sb.ToString()
}

function Get-StatusLine {
    <# The thin separator line with an optional message on the right. #>
    param([string] $Title, [int] $Width)
    $C = $script:C
    $s = $script:State
    $left = @($C.Faint, (($script:G.HLine * 2) + ' '), $C.Dim, ($Title + ' '))
    $right = @()
    if ($s.Message -and [datetime]::Now -lt $s.MessageUntil) {
        $color = if ($s.MessageIsError) { $C.Down } else { $C.Up }
        $right = @($color, " $($s.Message) ", $C.Faint, ($script:G.HLine * 2))
    }
    $fill = $Width - (Get-SegmentLength $left) - (Get-SegmentLength $right)
    if ($fill -lt 0) { $fill = 0; $right = @() ; $fill = $Width - (Get-SegmentLength $left) }
    Format-Line -Segments ($left + @($C.Faint, ($script:G.HLine * [Math]::Max(0, $fill))) + $right) -Width $Width
}

function Get-MainLines {
    <# Builds every line of the main screen. #>
    param([int] $Width, [int] $Height)
    $C = $script:C
    $G = $script:G
    $s = $script:State
    $lines = New-Object 'System.Collections.Generic.List[string]'

    # --- title bar
    $up = 0; $down = 0; $paused = 0
    foreach ($h in $s.Hosts) {
        if (Test-HostPaused $h) { $paused++ }
        elseif ($h.Status -eq 'Up') { $up++ }
        elseif ($h.Status -eq 'Down') { $down++ }
    }
    $state = if ($s.GlobalPaused) { @(($C.PauseBg + $C.White + $C.Bold), ' PAUSED ', ($C.BarBg + $C.NoBold), ' ') }
             else { @(($C.UpBg + $C.White + $C.Bold), ' LIVE ', ($C.BarBg + $C.NoBold), ' ') }
    $left = @(($C.Accent + $C.Bold), " $($G.Dot) PINGER", ($C.NoBold + $C.Dim), " v$script:AppVersion  ",
              $C.Text, "$($s.Hosts.Count) hosts  ",
              $C.Up, "$($G.UpTri) $up up  ", $C.Down, "$($G.DownTri) $down down  ", $C.Warn, "$($G.Pause) $paused paused  ")
    $right = $state + @($C.Dim, ('every {0} {1} timeout {2}ms  ' -f (Format-Seconds $s.Settings.Interval), $G.Middot, $s.Settings.Timeout),
                        $C.Text, ([datetime]::Now.ToString('HH:mm:ss') + ' '))
    $lines.Add((Format-Bar -Left $left -Right $right -Width $Width))

    # --- column headers
    $cols = Get-MainColumns $Width
    $titles = foreach ($col in $cols) { Format-Cell $col.Title $col.Width -Right:$col.Right }
    $lines.Add((Format-Line -Segments @(($C.Dim + $C.Bold), ('  ' + ($titles -join ' '))) -Width $Width))

    # --- address list
    $showDetail = $Height -ge 16
    $reserved = 3 + $(if ($showDetail) { 3 } else { 1 })   # title + header + footer (+ detail panel or status line)
    $listH = [Math]::Max(1, $Height - $reserved)
    $s.ListHeight = $listH
    if ($s.Hosts.Count -gt 0) {
        $null = Get-SelectedHost
        if ($s.Selected -lt $s.Scroll) { $s.Scroll = $s.Selected }
        if ($s.Selected -ge $s.Scroll + $listH) { $s.Scroll = $s.Selected - $listH + 1 }
        $s.Scroll = [Math]::Max(0, [Math]::Min($s.Scroll, [Math]::Max(0, $s.Hosts.Count - $listH)))
    } else { $s.Scroll = 0 }

    for ($i = 0; $i -lt $listH; $i++) {
        $idx = $s.Scroll + $i
        if ($idx -lt $s.Hosts.Count) {
            $lines.Add((Get-HostRow $s.Hosts[$idx] $cols ($idx -eq $s.Selected) $Width))
        } elseif ($s.Hosts.Count -eq 0 -and $i -eq [int]($listH / 3)) {
            $msg = 'No addresses yet - press  A  to add one, or  ?  for help.'
            $lines.Add($C.Dim + (' ' * [Math]::Max(0, [int](($Width - $msg.Length) / 2))) + $msg + $C.Reset)
        } else {
            $lines.Add('')
        }
    }

    # --- detail panel for the selected address
    $sel = Get-SelectedHost
    $scrollInfo = if ($s.Hosts.Count -gt $listH) { "$($s.Selected + 1)/$($s.Hosts.Count)" } else { 'Details' }
    $lines.Add((Get-StatusLine $scrollInfo $Width))
    if ($showDetail) {
        if ($null -ne $sel) {
            $name = if ($sel.Label) { $sel.Label } else { $sel.Address }
            $target = $sel.Address
            if (-not $sel.IsIp) {
                if ($sel.ResolvedIp) { $target += " $($G.Arrow) $($sel.ResolvedIp)" }
                elseif ($sel.DnsError) { $target += " $($G.Arrow) DNS: $($sel.DnsError)" }
            }
            $uptime = if ($sel.Sent -gt 0) { '{0:0.##}%' -f (100.0 * $sel.Received / $sel.Sent) } else { '-' }
            $l1 = @(($C.White + $C.Bold), " $name", ($C.NoBold + $C.Dim), "  $target   ",
                    $C.Dim, 'uptime ', $C.Text, "$uptime   ", $C.Dim, 'sent ', $C.Text, "$($sel.Sent)   ",
                    $C.Dim, 'lost ', $C.Text, "$($sel.Sent - $sel.Received)")
            $iv = if ($null -ne $sel.Interval) { "$(Format-Seconds $sel.Interval) (own)" } else { "$(Format-Seconds $s.Settings.Interval) (global)" }
            $tm = if ($null -ne $sel.Timeout) { "$($sel.Timeout) ms (own)" } else { "$($s.Settings.Timeout) ms (global)" }
            $next = if ($null -ne $sel.PingTask) { 'pinging' + $G.Ellipsis }
                    elseif (Test-HostPaused $sel) { 'paused' }
                    elseif ($sel.NextDue -le [datetime]::Now) { 'now' }
                    else { 'in ' + (Format-Duration ($sel.NextDue - [datetime]::Now)) }
            $resColor = if ($sel.Status -eq 'Down') { $C.Down } elseif ($sel.Status -eq 'Up') { $C.Up } else { $C.Dim }
            $l2 = @($C.Dim, ' interval ', $C.Text, "$iv   ", $C.Dim, 'timeout ', $C.Text, "$tm   ",
                    $C.Dim, 'next ', $C.Text, "$next   ", $C.Dim, 'last result ', $resColor, $sel.LastMessage)
            $lines.Add((Format-Line -Segments $l1 -Width $Width))
            $lines.Add((Format-Line -Segments $l2 -Width $Width))
        } else {
            $lines.Add(''); $lines.Add('')
        }
    }

    # --- footer
    $lines.Add((Format-KeyHints -Width ($Width - 1) -Pairs @(
        $G.ArrowUD, 'Move', 'Enter', 'History', 'A', 'Add', 'E', 'Edit', 'D', 'Delete',
        'Space', 'Pause', 'P', 'Pause all', 'R', 'Ping now', 'S', 'Settings', '?', 'Help', 'Q', 'Quit')))
    , $lines.ToArray()
}

#endregion

#region ---------------------------------------------------------------- Rendering: history screen

function Get-HistoryStats {
    <#
        Summarises a host's history: totals, response times and outages
        (a run of consecutive failed pings). Also returns per-entry notes
        ("Outage started", "Recovered after 12s").
    #>
    param($HostItem)
    $hist = $HostItem.History
    $n = $hist.Count
    $ok = 0; $sum = 0.0; $min = [double]::MaxValue; $max = 0.0
    $outages = New-Object 'System.Collections.Generic.List[TimeSpan]'
    $notes = New-Object 'string[]' ([Math]::Max(1, $n))
    $inOutage = $false; $outStart = [datetime]::MinValue; $upSince = $null
    for ($i = 0; $i -lt $n; $i++) {
        $e = $hist[$i]
        if ($e.Ok) {
            $ok++; $sum += $e.Rtt
            if ($e.Rtt -lt $min) { $min = $e.Rtt }
            if ($e.Rtt -gt $max) { $max = $e.Rtt }
            if ($inOutage) {
                $d = $e.Time - $outStart
                $outages.Add($d)
                $notes[$i] = "Recovered after $(Format-Duration $d)"
                $inOutage = $false
                $upSince = $e.Time
            } elseif ($i -eq 0) { $upSince = $e.Time }
        } else {
            if (-not $inOutage) { $inOutage = $true; $outStart = $e.Time; $notes[$i] = 'Outage started' }
        }
    }
    $ongoing = $null
    if ($inOutage) { $ongoing = [datetime]::Now - $outStart }
    $allOutages = New-Object 'System.Collections.Generic.List[TimeSpan]'
    foreach ($o in $outages) { $allOutages.Add($o) }
    if ($null -ne $ongoing) { $allOutages.Add($ongoing) }
    $totalDown = [TimeSpan]::Zero; $longest = [TimeSpan]::Zero
    foreach ($o in $allOutages) { $totalDown += $o; if ($o -gt $longest) { $longest = $o } }
    [pscustomobject]@{
        Total       = $n
        Received    = $ok
        Lost        = $n - $ok
        Uptime      = if ($n -gt 0) { 100.0 * $ok / $n } else { $null }
        AvgRtt      = if ($ok -gt 0) { $sum / $ok } else { $null }
        MinRtt      = if ($ok -gt 0) { $min } else { $null }
        MaxRtt      = if ($ok -gt 0) { $max } else { $null }
        Outages     = $allOutages.Count
        AvgDown     = if ($allOutages.Count -gt 0) { [TimeSpan]::FromTicks([long]($totalDown.Ticks / $allOutages.Count)) } else { $null }
        LongestDown = $longest
        TotalDown   = $totalDown
        Ongoing     = $ongoing
        DownSince   = if ($inOutage) { $outStart } else { $null }
        UpSince     = if (-not $inOutage) { $upSince } else { $null }
        First       = if ($n -gt 0) { $hist[0].Time } else { $null }
        Notes       = $notes
    }
}

function Get-HistoryLines {
    <# Builds every line of the history screen for the selected host. #>
    param([int] $Width, [int] $Height)
    $C = $script:C
    $G = $script:G
    $s = $script:State
    $h = $s.HistoryHost
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $st = Get-HistoryStats $h

    # --- title bar
    $title = if ($h.Label) { "$($h.Label)  $($G.Middot)  $($h.Address)" } else { $h.Address }
    if (-not $h.IsIp -and $h.ResolvedIp) { $title += "  $($G.Arrow) $($h.ResolvedIp)" }
    $badge = if (Test-HostPaused $h) { @(($C.PauseBg + $C.White + $C.Bold), ' PAUSED ') }
             elseif ($h.Status -eq 'Up') { @(($C.UpBg + $C.White + $C.Bold), ' UP ') }
             elseif ($h.Status -eq 'Down') { @(($C.DownBg + $C.White + $C.Bold), ' DOWN ') }
             else { @(($C.FieldBg + $C.White + $C.Bold), ' WAIT ') }
    $lines.Add((Format-Bar -Width $Width `
        -Left (@(($C.Accent + $C.Bold), ' HISTORY ', ($C.NoBold + $C.Faint), "$($G.VLine) ", ($C.White + $C.Bold), "$title  ") + $badge) `
        -Right @(($C.BarBg + $C.NoBold + $C.Dim), ([datetime]::Now.ToString('HH:mm:ss') + ' '))))

    # --- summary
    $fmtMs = { param($v) if ($null -eq $v) { '-' } else { '{0:0.0} ms' -f $v } }
    $uptime = if ($null -ne $st.Uptime) { '{0:0.##}%' -f $st.Uptime } else { '-' }
    $upColor = if ($null -eq $st.Uptime) { $C.Dim } elseif ($st.Uptime -ge 99) { $C.Up } elseif ($st.Uptime -ge 90) { $C.Warn } else { $C.Down }
    $avgColor = if ($null -ne $st.AvgRtt) { Get-RttColor $st.AvgRtt } else { $C.Dim }
    $avgDown = if ($null -ne $st.AvgDown) { Format-Duration $st.AvgDown } else { '-' }
    $now = if ($null -ne $st.DownSince) { @($C.Down, "DOWN for $(Format-Duration $st.Ongoing) (since $($st.DownSince.ToString('HH:mm:ss')))") }
           elseif ($null -ne $st.UpSince) { @($C.Up, "UP for $(Format-Duration ([datetime]::Now - $st.UpSince)) (since $($st.UpSince.ToString('HH:mm:ss')))") }
           else { @($C.Dim, 'no data yet') }
    $since = if ($null -ne $st.First) { "since $($st.First.ToString('yyyy-MM-dd HH:mm'))" } else { '' }
    $lines.Add('')
    $lines.Add((Format-Line -Width $Width -Segments @(
        $C.Dim, '  Total pings    ', ($C.White + $C.Bold), ('{0,-10}' -f $st.Total),
        ($C.NoBold + $C.Dim), 'Received  ', $C.Up, ('{0,-10}' -f $st.Received),
        $C.Dim, 'Lost    ', $(if ($st.Lost -gt 0) { $C.Down } else { $C.Up }), ('{0,-10}' -f $st.Lost),
        $C.Dim, 'Uptime      ', ($upColor + $C.Bold), ('{0,-10}' -f $uptime), ($C.NoBold + $C.Faint), $since)))
    $lines.Add((Format-Line -Width $Width -Segments @(
        $C.Dim, '  Avg response   ', ($avgColor + $C.Bold), ('{0,-10}' -f (& $fmtMs $st.AvgRtt)),
        ($C.NoBold + $C.Dim), 'Fastest   ', $C.Text, ('{0,-10}' -f (& $fmtMs $st.MinRtt)),
        $C.Dim, 'Slowest ', $C.Text, ('{0,-10}' -f (& $fmtMs $st.MaxRtt)))))
    $lines.Add((Format-Line -Width $Width -Segments @(
        $C.Dim, '  Avg downtime   ', ($(if ($st.Outages -gt 0) { $C.Down } else { $C.Up }) + $C.Bold), ('{0,-10}' -f $avgDown),
        ($C.NoBold + $C.Dim), 'Outages   ', $C.Text, ('{0,-10}' -f $st.Outages),
        $C.Dim, 'Longest ', $C.Text, ('{0,-10}' -f $(if ($st.Outages -gt 0) { Format-Duration $st.LongestDown } else { '-' })),
        $C.Dim, 'Total down  ', $C.Text, $(if ($st.Outages -gt 0) { Format-Duration $st.TotalDown } else { '-' }))))
    $lines.Add((Format-Line -Width $Width -Segments (@($C.Dim, '  Current state  ') + $now)))
    $lines.Add('')

    # --- timeline graph of the most recent pings
    $graphW = [Math]::Max(1, $Width - 4)
    $lines.Add($C.Dim + (Format-Cell "  Timeline (last $([Math]::Min($graphW, $st.Total)) pings, newest on the right)" $Width) + $C.Reset)
    $lines.Add('  ' + (Get-Spark $h.History $graphW) + $C.Reset)

    # --- table of entries (newest first)
    $filter = if ($s.HistoryFailOnly) { ' (failures only)' } else { '' }
    $lines.Add((Get-StatusLine "Log$filter" $Width))
    $tw = @{ Time = 21; Result = 10; Rtt = 9 }
    $tw.Detail = [Math]::Max(5, $Width - $tw.Time - $tw.Result - $tw.Rtt - 5)
    $lines.Add($C.Dim + $C.Bold + (Format-Cell ('  ' + (Format-Cell 'TIME' $tw.Time) + ' ' + (Format-Cell 'RESULT' $tw.Result) + ' ' +
        (Format-Cell 'RTT' $tw.Rtt -Right) + '  ' + 'DETAILS') $Width) + $C.Reset)

    $tableH = [Math]::Max(1, $Height - $lines.Count - 1)
    $s.HistoryHeight = $tableH
    $rows = New-Object 'System.Collections.Generic.List[int]'
    for ($i = $h.History.Count - 1; $i -ge 0; $i--) {
        if (-not $s.HistoryFailOnly -or -not $h.History[$i].Ok) { $rows.Add($i) }
    }
    $s.HistoryScroll = [Math]::Max(0, [Math]::Min($s.HistoryScroll, [Math]::Max(0, $rows.Count - $tableH)))
    for ($r = 0; $r -lt $tableH; $r++) {
        $ri = $s.HistoryScroll + $r
        if ($ri -ge $rows.Count) {
            if ($rows.Count -eq 0 -and $r -eq 0) { $lines.Add($C.Dim + '  No entries to show.' + $C.Reset) } else { $lines.Add('') }
            continue
        }
        $idx = $rows[$ri]
        $e = $h.History[$idx]
        $note = $st.Notes[$idx]
        if ($e.Ok) {
            $detail = if ($note) { $note } else { $e.Status }
            $noteColor = if ($note) { $C.Up + $C.Bold } else { $C.Dim }
            $lines.Add((Format-Line -Width $Width -Segments @(
                $C.Dim, '  ', $C.Text, ((Format-Cell $e.Time.ToString('yyyy-MM-dd HH:mm:ss') $tw.Time) + ' '),
                $C.Up, ((Format-Cell "$($G.Dot) UP" $tw.Result) + ' '),
                (Get-RttColor $e.Rtt), ((Format-Cell "$($e.Rtt) ms" $tw.Rtt -Right) + '  '),
                $noteColor, (Format-Cell $detail $tw.Detail))))
        } else {
            # Downtime is highlighted with a red background across the whole row.
            $detail = if ($note) { "$($e.Status)  $($G.Middot)  $note" } else { $e.Status }
            $lines.Add((Format-Line -Width $Width -Bg $C.DownBg -Segments @(
                $C.White, '  ', $C.White, ((Format-Cell $e.Time.ToString('yyyy-MM-dd HH:mm:ss') $tw.Time) + ' '),
                ($C.Down + $C.Bold), ((Format-Cell "$($G.Dot) DOWN" $tw.Result) + ' '),
                ($C.NoBold + $C.White), ((Format-Cell '-' $tw.Rtt -Right) + '  '),
                $C.White, (Format-Cell $detail $tw.Detail))))
        }
    }

    # --- footer
    $fLabel = if ($s.HistoryFailOnly) { 'Show all' } else { 'Failures only' }
    $lines.Add((Format-KeyHints -Width ($Width - 1) -Pairs @(
        $G.ArrowUD, 'Scroll', 'PgUp/PgDn', 'Page', 'F', $fLabel, 'R', 'Ping now', 'Space', 'Pause',
        'C', 'Clear', 'Esc', 'Back')))
    , $lines.ToArray()
}

#endregion

#region ---------------------------------------------------------------- Rendering: dialogs and frame

function Get-BoxText {
    <#
        Draws a framed box at the given position. $Body is a list of already
        formatted inner lines, each exactly $Inner characters wide.
    #>
    param([int] $Top, [int] $Left, [int] $Inner, [string] $Title, [string[]] $Body)
    $C = $script:C
    $G = $script:G
    $E = $script:E
    $sb = New-Object System.Text.StringBuilder
    $t = " $Title "
    $topLine = $G.TL + $G.HLine + $t + ($G.HLine * [Math]::Max(0, $Inner - $t.Length - 1)) + $G.TR
    [void]$sb.Append("$E[$($Top + 1);$($Left + 1)H").Append($C.BoxBg).Append($C.Accent).Append($C.Bold).Append($topLine).Append($C.NoBold)
    $row = $Top + 1
    foreach ($b in $Body) {
        [void]$sb.Append("$E[$($row + 1);$($Left + 1)H").Append($C.BoxBg).Append($C.Accent).Append($G.VLine)
        [void]$sb.Append($b).Append($C.BoxBg).Append($C.Accent).Append($G.VLine)
        $row++
    }
    [void]$sb.Append("$E[$($row + 1);$($Left + 1)H").Append($C.BoxBg).Append($C.Accent).Append($G.BL + ($G.HLine * $Inner) + $G.BR).Append($C.Reset)
    $sb.ToString()
}

function Get-OverlayText {
    <# Renders the active dialog (form, confirmation or help) on top of the screen. #>
    param([int] $Width, [int] $Height)
    $o = $script:State.Overlay
    if ($null -eq $o) { return '' }
    $C = $script:C
    $bg = $C.BoxBg
    $inner = [Math]::Min(68, $Width - 4)
    $body = New-Object 'System.Collections.Generic.List[string]'
    $blank = Format-Line -Segments @() -Width $inner -Bg $bg

    switch ($o.Type) {
        'Form' {
            $labelW = 14
            $fieldW = [Math]::Max(5, $inner - $labelW - 3)
            $body.Add($blank)
            for ($i = 0; $i -lt $o.Fields.Count; $i++) {
                $f = $o.Fields[$i]
                $focused = $i -eq $o.Focus
                $val = $f.Value
                if ($val.Length -gt $fieldW - 1) { $val = $val.Substring($val.Length - ($fieldW - 1)) }
                $fbg = if ($focused) { $C.FocusBg } else { $C.FieldBg }
                $lblColor = if ($focused) { $C.White + $C.Bold } else { $C.Dim }
                $marker = if ($focused) { $script:G.Pointer } else { ' ' }
                $segs = @(($bg + $C.Accent), " $marker ", ($bg + $lblColor), (Format-Cell $f.Label ($labelW - 3)), ($bg + $C.NoBold), ' ',
                          ($fbg + $C.White), $val)
                if ($focused) { $segs += @(($fbg + $C.Inverse), ' ', $C.NoInverse, '') }
                $pad = $fieldW - $val.Length - $(if ($focused) { 1 } else { 0 })
                $segs += @($fbg, (' ' * [Math]::Max(0, $pad)), $bg, ' ')
                $body.Add((Format-Line -Segments $segs -Width $inner -Bg $bg))
                if ($focused) {
                    $body.Add((Format-Line -Segments @(($bg + $C.Faint), ((' ' * $labelW) + $f.Hint)) -Width $inner -Bg $bg))
                } else {
                    $body.Add($blank)
                }
            }
            $errText = if ($o.Error) { " $($o.Error)" } else { '' }
            $body.Add((Format-Line -Segments @(($bg + $C.Down + $C.Bold), $errText) -Width $inner -Bg $bg))
            $body.Add((Format-Line -Segments @(($bg + $C.Dim), ' Enter save   Tab/Up/Down move   Ctrl+U clear   Esc cancel') -Width $inner -Bg $bg))
        }
        'Confirm' {
            $body.Add($blank)
            $body.Add((Format-Line -Segments @(($bg + $C.White + $C.Bold), "  $($o.Text)") -Width $inner -Bg $bg))
            $body.Add($blank)
            $body.Add((Format-Line -Segments @(($bg + $C.Dim), '  Press ', ($C.KeyBg + $C.White + $C.Bold), ' Y ', ($bg + $C.NoBold + $C.Dim), ' to confirm or ',
                                              ($C.KeyBg + $C.White + $C.Bold), ' N ', ($bg + $C.NoBold + $C.Dim), ' / Esc to cancel') -Width $inner -Bg $bg))
            $body.Add($blank)
        }
        'Help' {
            $o.Title = "$script:AppName $script:AppVersion - help"
            $rows = @(
                @('', 'MAIN SCREEN'),
                @("$($script:G.ArrowUD)  J/K", 'Move selection (PgUp/PgDn, Home/End to jump)'),
                @('Enter', 'Open history for the selected address'),
                @('A  Insert', 'Add an address'),
                @('E  F2', 'Edit address, label, interval and timeout'),
                @('D  Delete', 'Delete the selected address'),
                @('Space', 'Pause / resume the selected address'),
                @('P', 'Pause / resume all pinging'),
                @('R', 'Ping the selected address right now'),
                @('S', 'Global interval, timeout and history size'),
                @('Q  Ctrl+C', 'Quit (settings and history are saved)'),
                @('', ''),
                @('', 'HISTORY SCREEN'),
                @("$($script:G.ArrowUD)  PgUp/PgDn", 'Scroll the log (Home/End to jump)'),
                @('F', 'Toggle "failures only"'),
                @('C', 'Clear the history of this address'),
                @('Esc  Bksp', 'Back to the list'),
                @('', ''),
                @('', 'Purple EVERY/WAIT values are per-address overrides.')
            )
            $body.Add($blank)
            foreach ($r in $rows) {
                if ($r[0] -eq '') {
                    $body.Add((Format-Line -Segments @(($bg + $C.Accent + $C.Bold), "  $($r[1])") -Width $inner -Bg $bg))
                } else {
                    $body.Add((Format-Line -Segments @(($bg + $C.Warn + $C.Bold), ('  ' + (Format-Cell $r[0] 16)), ($bg + $C.NoBold + $C.Text), $r[1]) -Width $inner -Bg $bg))
                }
            }
            $body.Add($blank)
            $body.Add((Format-Line -Segments @(($bg + $C.Dim), '  Press any key to close') -Width $inner -Bg $bg))
        }
    }
    # Clip the dialog to the window height.
    $maxBody = [Math]::Max(1, $Height - 2)
    $lines = $body.ToArray()
    if ($lines.Count -gt $maxBody) { $lines = $lines[0..($maxBody - 1)] }
    $boxH = $lines.Count + 2
    $top = [Math]::Max(0, [int](($Height - $boxH) / 2))
    $left = [Math]::Max(0, [int](($Width - $inner - 2) / 2))
    $title = if ($o.ContainsKey('Title')) { $o.Title } else { '' }
    Get-BoxText -Top $top -Left $left -Inner $inner -Title $title -Body $lines
}

function Write-Frame {
    <#
        Writes a whole frame in a single call (no flicker): every line is
        positioned explicitly, cleared, and redrawn; then the dialog on top.
    #>
    param([string[]] $Lines, [string] $Overlay, [int] $Height)
    $E = $script:E
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$E[?25l")
    for ($i = 0; $i -lt $Height; $i++) {
        [void]$sb.Append("$E[$($i + 1);1H$E[0m$E[2K")
        if ($i -lt $Lines.Count -and $Lines[$i]) { [void]$sb.Append($Lines[$i]) }
    }
    [void]$sb.Append($Overlay).Append("$E[0m")
    [Console]::Write($sb.ToString())
}

function Show-Screen {
    <# Renders the current screen and dialog. #>
    $W = [Console]::WindowWidth
    $H = [Console]::WindowHeight
    if ($W -lt $script:MinWidth -or $H -lt $script:MinHeight) {
        $msg = "Window too small ($W x $H). Need at least $($script:MinWidth) x $($script:MinHeight)."
        Write-Frame -Lines @(($script:C.Warn + (Format-Cell $msg ($W - 1)) + $script:C.Reset)) -Overlay '' -Height $H
        return
    }
    if ($script:State.Mode -eq 'History' -and $null -ne $script:State.HistoryHost) {
        $lines = Get-HistoryLines -Width $W -Height $H
    } else {
        $script:State.Mode = 'Main'
        $lines = Get-MainLines -Width $W -Height $H
    }
    Write-Frame -Lines $lines -Overlay (Get-OverlayText -Width $W -Height $H) -Height $H
}

#endregion

#region ---------------------------------------------------------------- Console setup

function Enable-VirtualTerminal {
    <#
        Turns on ANSI escape-sequence processing for the console (needed by
        conhost under Windows PowerShell 5.1; Windows Terminal has it already).
        Returns the previous console mode so it can be restored, or $null.
    #>
    try {
        if (-not ('PingerNative.ConsoleMode' -as [type])) {
            Add-Type -Namespace PingerNative -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [PingerNative.ConsoleMode]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if (-not [PingerNative.ConsoleMode]::GetConsoleMode($handle, [ref]$mode)) { return $null }
        $ENABLE_VIRTUAL_TERMINAL_PROCESSING = [uint32]0x0004
        [void][PingerNative.ConsoleMode]::SetConsoleMode($handle, ($mode -bor $ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        return $mode
    } catch {
        # E.g. constrained language mode. Windows Terminal still works without this.
        Write-Verbose "Could not enable virtual terminal mode: $_"
        return $null
    }
}

function Restore-ConsoleMode {
    param($Mode)
    if ($null -eq $Mode) { return }
    try {
        $handle = [PingerNative.ConsoleMode]::GetStdHandle(-11)
        [void][PingerNative.ConsoleMode]::SetConsoleMode($handle, [uint32]$Mode)
    } catch { Write-Verbose "Could not restore console mode: $_" }
}

function Test-InteractiveConsole {
    <# Returns an error message when the TUI cannot run in this host, else ''. #>
    if ($Host.Name -match 'ISE') { return 'Pinger needs a real console window; it cannot run inside PowerShell ISE.' }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            return 'Pinger needs an interactive console (input/output must not be redirected).'
        }
        $null = [Console]::WindowWidth
    } catch {
        return "No usable console: $(Get-InnermostMessage $_.Exception)"
    }
    ''
}

#endregion

#region ---------------------------------------------------------------- Main

function Start-Pinger {
    <# Runs the application: load data, then the input/ping/render loop until quit. #>
    param([string[]] $InitialAddresses, [string] $Folder)

    $problem = Test-InteractiveConsole
    if ($problem) { Write-Error -Message $problem -Category InvalidOperation -ErrorAction Continue; return 1 }

    try {
        if (-not (Test-Path -LiteralPath $Folder)) { $null = New-Item -ItemType Directory -Path $Folder -Force }
    } catch {
        Write-Error -Message "Cannot create data folder '$Folder': $(Get-InnermostMessage $_.Exception)" -ErrorAction Continue
        return 1
    }

    Initialize-State -Folder $Folder
    Import-PingerData

    $added = 0
    foreach ($a in $InitialAddresses) {
        foreach ($part in ($a -split '[,;\s]+')) {
            if ($part -and $null -eq (Find-Host $part) -and ((Test-IpAddressText $part) -or (Test-HostnameText $part))) {
                $script:State.Hosts.Add((New-PingHost -Address $part)); $added++
            }
        }
    }
    if ($added -gt 0) { Save-Settings; Show-Message "Added $added address(es) from the command line" }

    $E = $script:E
    $oldMode = Enable-VirtualTerminal
    $oldEncoding = [Console]::OutputEncoding
    $oldCtrlC = [Console]::TreatControlCAsInput
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        [Console]::TreatControlCAsInput = $true
        # Switch to the alternate screen buffer so the user's scroll-back is untouched.
        [Console]::Write("$E[?1049h$E[?25l$E[2J")

        $lastW = 0; $lastH = 0
        $lastRender = [datetime]::MinValue
        $dirty = $true
        while (-not $script:State.Quit) {
            if (Update-PingEngine) { $dirty = $true }

            while ([Console]::KeyAvailable -and -not $script:State.Quit) {
                Invoke-Key ([Console]::ReadKey($true))
                $dirty = $true
                $lastRender = [datetime]::MinValue   # respond to keys immediately
            }

            $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
            if ($w -ne $lastW -or $h -ne $lastH) {
                [Console]::Write("$E[0m$E[2J")
                $lastW = $w; $lastH = $h; $dirty = $true; $lastRender = [datetime]::MinValue
            }

            $now = [datetime]::Now
            $sinceRender = ($now - $lastRender).TotalMilliseconds
            # Redraw on changes (at most ~10 fps) and once a second for the clocks.
            if (($dirty -and $sinceRender -ge 100) -or $sinceRender -ge 1000) {
                Show-Screen
                $dirty = $false
                $lastRender = $now
            }

            if (($now - $script:State.LastHistorySave).TotalSeconds -ge $script:HistorySaveSeconds) { Save-History }

            Start-Sleep -Milliseconds 30
        }
    } finally {
        foreach ($hostItem in $script:State.Hosts) { Stop-HostActivity $hostItem }
        Save-Settings
        Save-History
        [Console]::Write("$E[0m$E[?25h$E[?1049l")
        [Console]::TreatControlCAsInput = $oldCtrlC
        [Console]::OutputEncoding = $oldEncoding
        Restore-ConsoleMode $oldMode
    }
    Write-Host "$script:AppName stopped. Data saved in $Folder"
    return 0
}

exit (Start-Pinger -InitialAddresses $Address -Folder $DataPath)

#endregion
