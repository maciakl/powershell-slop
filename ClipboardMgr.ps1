<#
.SYNOPSIS
    ClipboardMgr - a compact, colorized clipboard manager TUI for Windows PowerShell 5.1.

.DESCRIPTION
    Shows the current clipboard and, when Windows clipboard history (Win+V) is enabled, the
    previous entries stored there. Anything copied while the manager is running is also captured
    into a session history (this covers file lists, which Windows history does not keep).

    Entries can be browsed with the keyboard, copied back to the clipboard, pasted into the
    previous window, viewed, edited (text), saved (images/binary) and deleted.

    No external dependencies: uses only .NET Framework, WinRT projections and Win32 APIs that
    ship with Windows 11.

.NOTES
    Keys (press ? inside the app for the full list):
      Up/Down/PgUp/PgDn/Home/End  move          Enter / C   copy to clipboard
      P   paste into previous window            V           view full entry
      E   edit text (built-in editor)           N           edit text in Notepad / $env:EDITOR
      Del delete entry                          O           open file location / file
      S   save image/binary/text to file        /           filter
      R   refresh                               X           clear all history
      Q / Esc  quit
#>
[CmdletBinding()]
param(
    # Do not read Windows clipboard history; only track the current clipboard and this session.
    [switch]$SessionOnly
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------------------------
if ($Host.Name -ne 'ConsoleHost') {
    Write-Warning 'ClipboardMgr needs a real console (powershell.exe / Windows Terminal), not the ISE.'
    return
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    # Clipboard access requires a single-threaded apartment; relaunch ourselves in one.
    $exe = (Get-Process -Id $PID).Path
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($SessionOnly) { $relaunch += '-SessionOnly' }
    & $exe @relaunch
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('ClipMgr.Native' -as [type])) {
    Add-Type -Namespace ClipMgr -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
[DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
}

# ---------------------------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------------------------
$Esc = [char]27
$S = @{
    Running        = $true
    Entries        = @()          # what is displayed (after filter)
    AllEntries     = @()          # merged, unfiltered
    Session        = New-Object System.Collections.ArrayList   # entries captured while running
    HistoryCache   = @{}          # WinRT history item Id -> entry
    HistoryOk      = $false
    HistoryState   = 'off'
    Current        = $null        # entry describing the live clipboard
    Sel            = 0
    Top            = 0
    Filter         = ''
    Seq            = [uint32]0
    NextPoll       = [datetime]::MinValue
    PendingRefresh = [datetime]::MaxValue
    Msg            = ''
    MsgColor       = 'info'
    MsgUntil       = [datetime]::MinValue
    Width          = 0
    Height         = 0
    Dirty          = $true
    SelfHwnd       = [ClipMgr.Native]::GetForegroundWindow()
    NextId         = 1
}

# Box drawing / glyphs built from code points so this file stays pure ASCII (PS 5.1 reads
# BOM-less scripts using the ANSI code page).
$G = @{
    H = [string][char]0x2500; V = [string][char]0x2502
    TL = [string][char]0x250C; TR = [string][char]0x2510; BL = [string][char]0x2514; BR = [string][char]0x2518
    Ell = [string][char]0x2026; Dot = [string][char]0x00B7; Tab = [string][char]0x2192; Ret = [string][char]0x21B5
    Ptr = [string][char]0x25B6; Star = [string][char]0x25CF; Ctl = [string][char]0x00B7; Wide = [string][char]0xFFFD
    Up = [string][char]0x2191; Dn = [string][char]0x2193
}

# ANSI palette (basic 16 colors so the terminal theme is respected)
$C = @{
    Reset = "$Esc[0m"; Bold = "$Esc[1m"; Rev = "$Esc[7m"
    Frame = "$Esc[90m"; Title = "$Esc[1;96m"; Head = "$Esc[1;97m"; Label = "$Esc[36m"; Value = "$Esc[97m"
    Muted = "$Esc[90m"; Key = "$Esc[1;93m"; Text = "$Esc[37m"
    TXT = "$Esc[92m"; FILE = "$Esc[93m"; IMG = "$Esc[95m"; BIN = "$Esc[91m"; NONE = "$Esc[90m"
    SelBg = "$Esc[44m"; SelFg = "$Esc[97m"
    ok = "$Esc[92m"; err = "$Esc[91m"; warn = "$Esc[93m"; info = "$Esc[96m"
    Cur = "$Esc[1;92m"; Src = "$Esc[34m"
}

# ---------------------------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------------------------
function Format-Size([double]$bytes) {
    if ($bytes -lt 1024) { return ('{0:N0} B' -f $bytes) }
    $units = 'KB', 'MB', 'GB', 'TB'
    $i = -1
    do { $bytes /= 1024; $i++ } while ($bytes -ge 1024 -and $i -lt 3)
    return ('{0:N1} {1}' -f $bytes, $units[$i])
}

function Format-Age([datetime]$t) {
    $d = (Get-Date) - $t
    if ($d.TotalSeconds -lt 60) { return ('{0}s' -f [int][Math]::Max(0, $d.TotalSeconds)) }
    if ($d.TotalMinutes -lt 60) { return ('{0}m' -f [int][Math]::Floor($d.TotalMinutes)) }
    if ($d.TotalHours -lt 24) { return ('{0}h' -f [int][Math]::Floor($d.TotalHours)) }
    return ('{0}d' -f [int][Math]::Floor($d.TotalDays))
}

# Makes a string safe for single-row display: one console cell per character. Control chars,
# surrogate pairs (emoji) and double-width CJK are replaced by single-cell glyphs so that the
# column math stays honest.
function Get-CharRange([int]$from, [int]$to) { return ([string][char]$from) + '-' + ([string][char]$to) }
$RxCtl = [regex]'[\x00-\x08\x0B-\x1F\x7F]'
$RxWide = [regex](
    '[' + (Get-CharRange 0xD800 0xDBFF) + '][' + (Get-CharRange 0xDC00 0xDFFF) + ']|' +
    '[' + (Get-CharRange 0xD800 0xDFFF) + ']|' +
    '[' + (Get-CharRange 0x1100 0x115F) + (Get-CharRange 0x2E80 0xA4CF) + (Get-CharRange 0xAC00 0xD7A3) +
    (Get-CharRange 0xF900 0xFAFF) + (Get-CharRange 0xFE30 0xFE4F) + (Get-CharRange 0xFF00 0xFF60) +
    (Get-CharRange 0xFFE0 0xFFE6) + ']')
function ConvertTo-DisplayText([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s = $s.Replace("`r", '').Replace("`t", $G.Tab).Replace("`n", $G.Ret)
    $s = $RxCtl.Replace($s, $G.Ctl)
    return $RxWide.Replace($s, $G.Wide)
}

# Format-Fit already-display-safe text into exactly $w cells.
function Format-Fit([string]$s, [int]$w) {
    if ($w -le 0) { return '' }
    if ($null -eq $s) { $s = '' }
    if ($s.Length -gt $w) { return $s.Substring(0, [Math]::Max(0, $w - 1)) + $G.Ell }
    return $s.PadRight($w)
}

# Wrap a (display-safe) line into chunks of width $w.
function Split-Wrap([string]$s, [int]$w) {
    if ($w -lt 1) { return , @() }
    if ($s.Length -le $w) { return , @($s) }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $s.Length; $i += $w) { $out.Add($s.Substring($i, [Math]::Min($w, $s.Length - $i))) }
    return , $out.ToArray()
}

function Set-Message([string]$text, [string]$kind = 'info') {
    $S.Msg = $text; $S.MsgColor = $kind; $S.MsgUntil = (Get-Date).AddSeconds(4); $S.Dirty = $true
}

function Invoke-Clipboard([scriptblock]$action) {
    # The clipboard can be briefly locked by another process; retry a few times.
    for ($try = 0; $try -lt 6; $try++) {
        try { return (& $action) }
        catch [System.Runtime.InteropServices.ExternalException] { Start-Sleep -Milliseconds 60 }
    }
    return (& $action)
}

# ---------------------------------------------------------------------------------------------
# Binary sniffing
# ---------------------------------------------------------------------------------------------
function Get-BlobType([byte[]]$b) {
    # Returns a short description of the data based on its leading bytes (and dimensions for images).
    if ($null -eq $b -or $b.Length -lt 2) { return 'unknown' }
    $n = $b.Length
    $hex = (($b[0..([Math]::Min(15, $n - 1))] | ForEach-Object { $_.ToString('X2') }) -join '')
    $ascii = -join ($b[0..([Math]::Min(15, $n - 1))] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    function U32LE($o) { if ($o + 3 -lt $n) { [BitConverter]::ToUInt32($b, $o) } else { 0 } }
    function I32LE($o) { if ($o + 3 -lt $n) { [BitConverter]::ToInt32($b, $o) } else { 0 } }
    function U16LE($o) { if ($o + 1 -lt $n) { [BitConverter]::ToUInt16($b, $o) } else { 0 } }
    function U32BE($o) { if ($o + 3 -lt $n) { [long]$b[$o] * 16777216 + [long]$b[$o + 1] * 65536 + [long]$b[$o + 2] * 256 + $b[$o + 3] } else { 0 } }

    if ($hex.StartsWith('89504E47')) { return ('PNG image, {0} x {1}' -f (U32BE 16), (U32BE 20)) }
    if ($hex.StartsWith('FFD8FF')) {
        $dims = ''
        $i = 2
        while ($i + 9 -lt $n) {
            if ($b[$i] -ne 0xFF) { break }
            $m = $b[$i + 1]
            $len = ([int]$b[$i + 2] -shl 8) -bor $b[$i + 3]
            if (($m -ge 0xC0 -and $m -le 0xC3) -or ($m -ge 0xC5 -and $m -le 0xC7) -or ($m -ge 0xC9 -and $m -le 0xCB) -or ($m -ge 0xCD -and $m -le 0xCF)) {
                $h = ([int]$b[$i + 5] -shl 8) -bor $b[$i + 6]; $w = ([int]$b[$i + 7] -shl 8) -bor $b[$i + 8]
                $dims = ", $w x $h"; break
            }
            $i += 2 + $len
        }
        return "JPEG image$dims"
    }
    if ($hex.StartsWith('47494638')) { return ('GIF image, {0} x {1}' -f (U16LE 6), (U16LE 8)) }
    if ($hex.StartsWith('424D') -and $n -gt 26) { return ('BMP image, {0} x {1}, {2} bpp' -f (I32LE 18), [Math]::Abs((I32LE 22)), (U16LE 28)) }
    if ($n -ge 16 -and ((U32LE 0) -in 40, 52, 56, 108, 124)) {
        return ('DIB image, {0} x {1}, {2} bpp' -f (I32LE 4), [Math]::Abs((I32LE 8)), (U16LE 14))
    }
    if ($hex.StartsWith('52494646') -and $n -ge 12) {
        $sub = [Text.Encoding]::ASCII.GetString($b, 8, 4)
        switch ($sub) { 'WEBP' { return 'WebP image' } 'WAVE' { return 'WAV audio' } 'AVI ' { return 'AVI video' } default { return "RIFF container ($sub)" } }
    }
    if ($hex.StartsWith('49492A00') -or $hex.StartsWith('4D4D002A')) { return 'TIFF image' }
    if ($hex.StartsWith('00000100')) { return ('ICO icon, {0} image(s)' -f (U16LE 4)) }
    if ($n -ge 12 -and [Text.Encoding]::ASCII.GetString($b, 4, 4) -eq 'ftyp') {
        $brand = [Text.Encoding]::ASCII.GetString($b, 8, 4)
        if ($brand -match 'hei|mif1|avif') { return "HEIF/AVIF image ($brand)" }
        return "MP4/QuickTime media ($brand)"
    }
    if ($hex.StartsWith('25504446')) { return 'PDF document' }
    if ($hex.StartsWith('504B0304')) { return 'ZIP archive (or DOCX/XLSX/JAR...)' }
    if ($hex.StartsWith('D0CF11E0')) { return 'OLE compound file (legacy Office / MSI)' }
    if ($hex.StartsWith('1F8B')) { return 'GZIP compressed data' }
    if ($hex.StartsWith('377ABCAF')) { return '7-Zip archive' }
    if ($hex.StartsWith('52617221')) { return 'RAR archive' }
    if ($hex.StartsWith('4D5A')) { return 'Windows executable (PE/MZ)' }
    if ($hex.StartsWith('7F454C46')) { return 'ELF executable' }
    if ($hex.StartsWith('494433') -or $hex.StartsWith('FFFB')) { return 'MP3 audio' }
    if ($hex.StartsWith('4F676753')) { return 'OGG media' }
    if ($hex.StartsWith('664C6143')) { return 'FLAC audio' }
    if ($hex.StartsWith('01000000') -and $n -ge 44 -and [Text.Encoding]::ASCII.GetString($b, 40, 4) -eq ' EMF') { return 'Enhanced metafile (EMF)' }
    if ($hex.StartsWith('D7CDC69A')) { return 'Windows metafile (WMF)' }
    if ($hex.StartsWith('EFBBBF')) { return 'UTF-8 text (BOM)' }
    if ($hex.StartsWith('FFFE')) { return 'UTF-16 LE text (BOM)' }
    if ($hex.StartsWith('FEFF')) { return 'UTF-16 BE text (BOM)' }
    if ($ascii.StartsWith('{\rtf')) { return 'RTF text' }
    if ($ascii.StartsWith('Version:')) { return 'CF_HTML fragment' }
    if ($ascii.StartsWith('%!PS')) { return 'PostScript' }
    if ($ascii -match '^\s*<\?xml') { return 'XML' }
    if ($ascii -match '^\s*<(!doctype|html)') { return 'HTML' }

    # Heuristic: mostly printable -> text-like
    $sample = [Math]::Min($n, 512); $printable = 0; $zeros = 0
    for ($i = 0; $i -lt $sample; $i++) {
        $v = $b[$i]
        if ($v -eq 0) { $zeros++ }
        if (($v -ge 32 -and $v -lt 127) -or $v -in 9, 10, 13) { $printable++ }
    }
    if ($zeros -ge $sample / 3 -and $printable + $zeros -ge $sample * 0.9) { return 'UTF-16 text (probably)' }
    if ($printable -ge $sample * 0.95) {
        if ($ascii -match '^\s*[\{\[]') { return 'JSON / text (probably)' }
        return 'ASCII text'
    }
    return 'unknown binary data'
}

# Hex dump; $width picks 16, 8 or 4 bytes per row so that rows fit.
function Get-HexDump([byte[]]$b, [int]$max = 256, [int]$width = 80) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $b) { return , $lines.ToArray() }
    $per = if ($width -ge 75) { 16 } elseif ($width -ge 41) { 8 } else { 4 }
    $len = [Math]::Min($b.Length, $max)
    for ($o = 0; $o -lt $len; $o += $per) {
        $cnt = [Math]::Min($per, $len - $o)
        $hx = (($b[$o..($o + $cnt - 1)] | ForEach-Object { $_.ToString('X2') }) -join ' ')
        $as = -join ($b[$o..($o + $cnt - 1)] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
        $lines.Add(('{0:X6}  {1}  {2}' -f $o, $hx.PadRight($per * 3 - 1), $as))
    }
    return , $lines.ToArray()
}

function Read-StreamHead($stream, [int]$count = 4096) {
    if ($null -eq $stream) { return $null }
    try { if ($stream.CanSeek) { $stream.Position = 0 } } catch { }
    $buf = New-Object byte[] $count
    $read = 0
    while ($read -lt $count) {
        $r = $stream.Read($buf, $read, $count - $read)
        if ($r -le 0) { break }
        $read += $r
    }
    try { if ($stream.CanSeek) { $stream.Position = 0 } } catch { }
    if ($read -lt $count) { $tmp = New-Object byte[] $read; [Array]::Copy($buf, $tmp, $read); return , $tmp }
    return , $buf
}

# ---------------------------------------------------------------------------------------------
# Entry model
# ---------------------------------------------------------------------------------------------
# Kind: Text | Files | Image | Binary | Empty
# Source: History (Windows clipboard history) | Session (captured while running) | Clipboard (live only)
function New-Entry([string]$kind, [string]$source) {
    $id = $S.NextId; $S.NextId++
    [pscustomobject]@{
        Key = "e$id"; Kind = $kind; Source = $source; Time = (Get-Date)
        Text = $null; Files = @(); Image = $null; ImageInfo = ''; ImgW = 0; ImgH = 0
        BinFormat = ''; BinData = $null; BinSize = 0; BinType = ''
        Formats = @(); FormatSizes = $null; HistoryItem = $null; IsCurrent = $false
        Summary = ''; Sig = ''; Details = $null; DetailsCur = $false; PreviewCache = $null; Private = $false
    }
}

function Update-EntrySummary($e) {
    switch ($e.Kind) {
        'Text' {
            $t = $e.Text.TrimStart()
            if ($t.Length -gt 400) { $t = $t.Substring(0, 400) }
            $first = ($t -split "`r?`n", 2)[0]
            $e.Summary = ConvertTo-DisplayText $first.TrimEnd()
            if ($e.Text.Trim().Length -gt $first.Length) { $e.Summary += ' ' + $G.Ell }
            if (-not $e.Summary.Trim()) { $e.Summary = "(whitespace, $($e.Text.Length) chars)" }
            $e.Sig = 'T:' + $e.Text.GetHashCode() + ':' + $e.Text.Length
        }
        'Files' {
            $names = @($e.Files | ForEach-Object { Split-Path $_ -Leaf })
            $e.Summary = ConvertTo-DisplayText ($names -join ', ')
            if ($e.Files.Count -gt 1) { $e.Summary = "[$($e.Files.Count)] " + $e.Summary }
            $e.Sig = 'F:' + ($e.Files -join '|')
        }
        'Image' { $e.Summary = $e.ImageInfo; $e.Sig = 'I:{0}x{1}' -f $e.ImgW, $e.ImgH }
        'Binary' {
            $e.Summary = '{0} {1} {2}' -f $e.BinFormat, $G.Dot, (Format-Size $e.BinSize)
            if ($e.BinType) { $e.Summary += " $($G.Dot) $($e.BinType)" }
            $e.Sig = 'B:' + $e.BinFormat + ':' + $e.BinSize
        }
        default { $e.Summary = '(clipboard is empty)'; $e.Sig = 'E' }
    }
}

# Reads the live clipboard into an entry (all formats, sizes, best representation).
function Get-CurrentClipboardEntry {
    $do = Invoke-Clipboard { [System.Windows.Forms.Clipboard]::GetDataObject() }
    if ($null -eq $do) { $e = New-Entry 'Empty' 'Clipboard'; Update-EntrySummary $e; return $e }
    $formats = @()
    try { $formats = @($do.GetFormats($false)) } catch { }

    $e = $null
    if ($formats -contains 'FileDrop') {
        $files = @($do.GetData('FileDrop'))
        if ($files.Count -gt 0) { $e = New-Entry 'Files' 'Clipboard'; $e.Files = [string[]]$files }
    }
    if (-not $e -and ($formats -contains 'UnicodeText' -or $formats -contains 'Text')) {
        $t = [System.Windows.Forms.Clipboard]::GetText()
        if (-not [string]::IsNullOrEmpty($t)) { $e = New-Entry 'Text' 'Clipboard'; $e.Text = $t }
    }
    if (-not $e -and ($formats -contains 'Bitmap' -or $formats -contains 'DeviceIndependentBitmap' -or $formats -contains 'PNG')) {
        $img = $null
        try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { }
        if (-not $img -and $formats -contains 'PNG') {
            try { $img = [System.Drawing.Image]::FromStream($do.GetData('PNG')) } catch { }
        }
        if ($img) {
            $e = New-Entry 'Image' 'Clipboard'
            $e.Image = New-Object System.Drawing.Bitmap $img
            $bpp = [System.Drawing.Image]::GetPixelFormatSize($img.PixelFormat)
            $e.ImgW = $img.Width; $e.ImgH = $img.Height
            $e.ImageInfo = '{0} x {1} {2} {3} bpp' -f $img.Width, $img.Height, $G.Dot, $bpp
            $img.Dispose()
        }
    }
    if (-not $e -and $formats.Count -gt 0) {
        # Some other, possibly app-specific format: keep the first one that yields data.
        foreach ($f in $formats) {
            try {
                $d = $do.GetData($f)
                $bytes = $null
                if ($d -is [string] -and $d.Length -gt 0) {
                    # e.g. HTML Format or RTF without a plain-text version: show it as text
                    $e = New-Entry 'Text' 'Clipboard'; $e.Text = $d
                    break
                }
                if ($d -is [System.IO.MemoryStream]) { $bytes = $d.ToArray() }
                elseif ($d -is [byte[]]) { $bytes = $d }
                if ($bytes) {
                    $e = New-Entry 'Binary' 'Clipboard'
                    $e.BinFormat = $f; $e.BinData = $bytes; $e.BinSize = $bytes.Length
                    $e.BinType = Get-BlobType $bytes
                    break
                }
            }
            catch { }
        }
    }
    if (-not $e) { $e = New-Entry 'Empty' 'Clipboard' }
    $e.Formats = $formats

    # Password managers and other apps flag sensitive data; such content is never captured into
    # the session history (Windows applies the same rules to its own history).
    if ($formats -contains 'ExcludeClipboardContentFromMonitorProcessing' -or $formats -contains 'Clipboard Viewer Ignore') { $e.Private = $true }
    if ($formats -contains 'CanIncludeInClipboardHistory') {
        try {
            $v = $do.GetData('CanIncludeInClipboardHistory')
            if ($v -is [IO.MemoryStream] -and $v.Length -ge 1 -and $v.ToArray()[0] -eq 0) { $e.Private = $true }
        }
        catch { }
    }

    # Sizes of every format (best effort; skip the ones that are expensive to convert).
    $sizes = [ordered]@{}
    foreach ($f in $formats) {
        if ($f -in 'EnhancedMetafile', 'MetaFilePict', 'Bitmap') { $sizes[$f] = '-'; continue }
        try {
            $d = $do.GetData($f, $false)
            if ($d -is [System.IO.MemoryStream]) { $sizes[$f] = Format-Size $d.Length }
            elseif ($d -is [string]) { $sizes[$f] = ('{0:N0} chars' -f $d.Length) }
            elseif ($d -is [string[]]) { $sizes[$f] = ('{0} item(s)' -f $d.Count) }
            elseif ($d -is [System.Drawing.Image]) { $sizes[$f] = ('{0} x {1}' -f $d.Width, $d.Height) }
            elseif ($null -ne $d) { $sizes[$f] = $d.GetType().Name }
            else { $sizes[$f] = '-' }
        }
        catch { $sizes[$f] = '?' }
    }
    $e.FormatSizes = $sizes
    if ($e.Kind -eq 'Image' -and $formats -contains 'PNG') {
        try { $e.BinData = $do.GetData('PNG').ToArray(); $e.BinSize = $e.BinData.Length; $e.BinType = Get-BlobType $e.BinData } catch { }
    }
    Update-EntrySummary $e
    return $e
}

# ---------------------------------------------------------------------------------------------
# Windows clipboard history (WinRT)
# ---------------------------------------------------------------------------------------------
$WinRT = @{ AsTask = $null; Clipboard = $null }

function Initialize-History {
    if ($SessionOnly) { $S.HistoryState = 'disabled (-SessionOnly)'; return }
    if ($PSVersionTable.PSVersion.Major -gt 5) { $S.HistoryState = 'n/a (needs Windows PowerShell 5.1)'; return }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $WinRT.Clipboard = [Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType = WindowsRuntime]
        $null = [Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult, Windows.ApplicationModel.DataTransfer, ContentType = WindowsRuntime]
        $null = [Windows.Storage.IStorageItem, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $WinRT.AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
        if (-not $WinRT.Clipboard::IsHistoryEnabled()) {
            $S.HistoryState = 'off (Settings > System > Clipboard)'; return
        }
        $S.HistoryOk = $true; $S.HistoryState = 'on'
    }
    catch { $S.HistoryState = 'unavailable'; $S.HistoryOk = $false }
}

function Wait-WinRT($op, [type]$type, [int]$timeout = 4000) {
    $task = $WinRT.AsTask.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait($timeout)) { throw 'WinRT call timed out' }
    return $task.Result
}

function Open-HistoryBitmap($item) {
    # PowerShell only sees the returned stream as a bare __ComObject, so its interface members
    # are reached through reflection (the CLR then does the COM QueryInterface for us).
    $ref = Wait-WinRT ($item.Content.GetBitmapAsync()) ([Windows.Storage.Streams.RandomAccessStreamReference])
    $rs = Wait-WinRT ($ref.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    $size = [Windows.Storage.Streams.IRandomAccessStream].GetProperty('Size').GetValue($rs)
    $ct = [Windows.Storage.Streams.IContentTypeProvider].GetProperty('ContentType').GetValue($rs)
    $asStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream]))
    return @{ Size = [long]$size; ContentType = $ct; Stream = $asStream.Invoke($null, @($rs)) }
}

function ConvertFrom-HistoryItem($item) {
    $view = $item.Content
    $formats = @($view.AvailableFormats)
    $e = $null
    if ($formats -contains 'Text') {
        $e = New-Entry 'Text' 'History'
        $e.Text = Wait-WinRT ($view.GetTextAsync()) ([string])
    }
    elseif ($formats -contains 'Shell IDList Array' -or $formats -contains 'StorageItems') {
        $e = New-Entry 'Files' 'History'
        try {
            $items = Wait-WinRT ($view.GetStorageItemsAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Storage.IStorageItem]])
            $e.Files = [string[]]@($items | ForEach-Object { $_.Path })
        }
        catch { $e.Files = @() }
    }
    elseif ($formats -contains 'Bitmap') {
        $e = New-Entry 'Image' 'History'
        try {
            $bmp = Open-HistoryBitmap $item
            $head = Read-StreamHead $bmp.Stream 4096
            $bmp.Stream.Dispose()
            $e.BinSize = $bmp.Size
            $e.BinType = Get-BlobType $head
            $e.BinData = $head    # header only; the full image is fetched on demand
            $e.BinFormat = if ($bmp.ContentType) { $bmp.ContentType } else { 'Bitmap' }
            $fmtName = ($e.BinType -split ' ')[0]
            if ($e.BinType -match '(\d+) x (\d+)') {
                $e.ImgW = [int]$Matches[1]; $e.ImgH = [int]$Matches[2]
                $e.ImageInfo = '{0} x {1} {2} {3}' -f $e.ImgW, $e.ImgH, $G.Dot, $fmtName
            }
            else { $e.ImageInfo = "image $($G.Dot) $fmtName" }
            $e.ImageInfo += " $($G.Dot) " + (Format-Size $e.BinSize)
        }
        catch { $e.ImageInfo = 'image (unreadable)' }
    }
    elseif ($formats -contains 'HTML Format') {
        $e = New-Entry 'Text' 'History'
        $e.Text = Wait-WinRT ($view.GetHtmlFormatAsync()) ([string])
    }
    elseif ($formats -contains 'Rich Text Format') {
        $e = New-Entry 'Text' 'History'
        $e.Text = Wait-WinRT ($view.GetRtfAsync()) ([string])
    }
    else {
        $e = New-Entry 'Binary' 'History'
        $e.BinFormat = ($formats | Select-Object -First 1)
        $e.BinType = 'stored in Windows clipboard history'
    }
    $e.HistoryItem = $item
    $e.Formats = $formats
    $e.Time = $item.Timestamp.LocalDateTime
    Update-EntrySummary $e
    return $e
}

function Get-HistoryEntries {
    if (-not $S.HistoryOk) { return @() }
    try {
        $res = Wait-WinRT ($WinRT.Clipboard::GetHistoryItemsAsync()) ([Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult])
        if ("$($res.Status)" -ne 'Success') { $S.HistoryState = "error: $($res.Status)"; return @() }
        $S.HistoryState = 'on'
        $list = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($item in @($res.Items)) {
            $seen[$item.Id] = $true
            $e = $S.HistoryCache[$item.Id]
            if (-not $e) {
                try { $e = ConvertFrom-HistoryItem $item } catch { continue }
                $S.HistoryCache[$item.Id] = $e
            }
            $e.HistoryItem = $item
            [void]$list.Add($e)
        }
        foreach ($k in @($S.HistoryCache.Keys)) { if (-not $seen[$k]) { $S.HistoryCache.Remove($k) } }
        return $list.ToArray()
    }
    catch { $S.HistoryState = 'error'; return @() }
}

# ---------------------------------------------------------------------------------------------
# Building the list
# ---------------------------------------------------------------------------------------------
function Update-Entries([switch]$CaptureCurrent) {
    $selKey = $null
    if ($S.Entries.Count -gt 0 -and $S.Sel -lt $S.Entries.Count) { $selKey = $S.Entries[$S.Sel].Key }

    if ($CaptureCurrent -or -not $S.Current) {
        try { $S.Current = Get-CurrentClipboardEntry }
        catch { $S.Current = New-Entry 'Empty' 'Clipboard'; Update-EntrySummary $S.Current; Set-Message "Cannot read clipboard: $($_.Exception.Message)" 'err' }
        # Capture into the session list (dedupe by signature; newest first)
        if ($S.Current.Kind -ne 'Empty' -and -not $S.Current.Private) {
            $dupe = $S.Session | Where-Object { $_.Sig -eq $S.Current.Sig } | Select-Object -First 1
            if ($dupe) { $S.Session.Remove($dupe) }
            $copy = $S.Current.PSObject.Copy(); $copy.Source = 'Session'; $copy.Key = 's' + $copy.Key
            $S.Session.Insert(0, $copy)
            while ($S.Session.Count -gt 200) { $S.Session.RemoveAt($S.Session.Count - 1) }
        }
    }

    $hist = @(Get-HistoryEntries)
    foreach ($h in $hist) { $h.IsCurrent = $false }
    $merged = New-Object System.Collections.ArrayList

    # The live clipboard always comes first. Prefer the matching history item (it can be
    # restored with all formats intact); otherwise show the live entry itself.
    $cur = $S.Current
    $curHist = $null
    if ($cur.Kind -ne 'Empty') { $curHist = $hist | Where-Object { $_.Sig -eq $cur.Sig } | Select-Object -First 1 }
    $first = $cur
    if ($curHist) {
        # The live entry knows more about formats; share it for the details pane.
        $curHist.FormatSizes = $cur.FormatSizes
        $first = $curHist
    }
    $first.IsCurrent = $true
    [void]$merged.Add($first)

    # History and session entries, newest first. A session entry that Windows history also has
    # is dropped (the history copy can be restored with all its formats).
    $sigs = @{ $cur.Sig = $true }
    foreach ($h in $hist) { $sigs[$h.Sig] = $true }
    $rest = @($hist | Where-Object { $_ -ne $curHist }) + @($S.Session | Where-Object { -not $sigs[$_.Sig] })
    $seen = @{ $cur.Sig = $true }
    foreach ($e in ($rest | Sort-Object -Property Time -Descending)) {
        if ($seen[$e.Sig]) { continue }
        $seen[$e.Sig] = $true
        [void]$merged.Add($e)
    }
    # Details mention "current clipboard"; rebuild them when that changes.
    foreach ($e in $merged) { if ($e.Details -and $e.DetailsCur -ne $e.IsCurrent) { $e.Details = $null } }
    $S.AllEntries = $merged.ToArray()
    Update-Filter -KeepKey $selKey
}

function Update-Filter([string]$KeepKey) {
    if ($S.Filter) {
        $f = $S.Filter
        $ci = [StringComparison]::OrdinalIgnoreCase
        $S.Entries = @($S.AllEntries | Where-Object {
                $_.Summary.IndexOf($f, $ci) -ge 0 -or $_.Kind.StartsWith($f, $ci) -or
                ($_.Kind -eq 'Text' -and $_.Text.IndexOf($f, $ci) -ge 0) -or
                ($_.Kind -eq 'Files' -and ($_.Files -join '|').IndexOf($f, $ci) -ge 0)
            })
    }
    else { $S.Entries = @($S.AllEntries) }
    $S.Sel = 0
    if ($KeepKey) {
        for ($i = 0; $i -lt $S.Entries.Count; $i++) { if ($S.Entries[$i].Key -eq $KeepKey) { $S.Sel = $i; break } }
    }
    $S.Dirty = $true
}

# ---------------------------------------------------------------------------------------------
# Details for the preview pane / viewer
# ---------------------------------------------------------------------------------------------
# Detail lines: @('kv', label, value) rendered as "Label: value", or @('t', style, text).
function New-DetailPair([string]$label, [string]$value) { , @('kv', $label, $value) }
function New-DetailText([string]$text, [string]$style = 'Text') { , @('t', $style, $text) }

function Get-TextStats([string]$t) {
    $lines = ($t -split "`r?`n").Count
    $words = ([regex]::Matches($t, '\S+')).Count
    $eol = if ($t.Contains("`r`n")) { 'CRLF' } elseif ($t.Contains("`n")) { 'LF' } else { '-' }
    $nonAscii = ([regex]::Matches($t, '[^\x00-\x7F]')).Count
    $tt = $t.Trim()
    $looks = ''
    if ($tt.Length -gt 100000) { }
    elseif ($tt -match '^(https?|ftp)://\S+$') { $looks = 'URL' }
    elseif ($tt -match '^[\w.+-]+@[\w-]+\.[\w.-]+$') { $looks = 'e-mail address' }
    elseif ($tt -match '^[a-zA-Z]:\\[^\r\n]*$' -or $tt -match '^\\\\[^\r\n]+$') { $looks = 'Windows path' + $(if (Test-Path -LiteralPath $tt -ErrorAction SilentlyContinue) { ' (exists)' } else { '' }) }
    elseif ($tt -match '^-?\d+([.,]\d+)?$') { $looks = 'number' }
    elseif ($tt -match '^#?[0-9a-fA-F]{6}$') { $looks = 'hex color' }
    elseif ($tt -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { $looks = 'GUID' }
    elseif ($tt -match '^[{\[]' -and $tt -match '[}\]]$') { try { $null = ConvertFrom-Json $tt; $looks = 'JSON' } catch { } }
    elseif ($tt -match '^Version:\d') { $looks = 'CF_HTML fragment' }
    elseif ($tt -match '^\{\\rtf') { $looks = 'RTF' }
    elseif ($tt -match '^\s*<') { $looks = 'XML / HTML' }
    elseif ($tt -match '^[A-Za-z0-9+/]{40,}={0,2}$') { $looks = 'Base64 (probably)' }
    @{ Lines = $lines; Words = $words; Eol = $eol; NonAscii = $nonAscii; Looks = $looks }
}

function Get-FileTypeName([string]$ext) {
    if (-not $ext) { return '' }
    try {
        $prog = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$ext" -ErrorAction Stop).'(default)'
        if ($prog) {
            $name = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$prog" -ErrorAction Stop).'(default)'
            if ($name) { return $name }
        }
    }
    catch { }
    return ''
}

function Get-FileDetails([string]$path) {
    $out = New-Object System.Collections.ArrayList
    $item = $null
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { }
    if (-not $item) {
        [void]$out.Add((New-DetailText (ConvertTo-DisplayText (Split-Path $path -Leaf)) 'FILE'))
        [void]$out.Add((New-DetailPair 'Path' (ConvertTo-DisplayText $path)))
        [void]$out.Add((New-DetailText '(file no longer exists or is not accessible)' 'err'))
        return @{ Lines = $out; Size = 0; Missing = $true }
    }
    $size = 0
    if ($item.PSIsContainer) {
        [void]$out.Add((New-DetailText ((ConvertTo-DisplayText $item.Name) + '\') 'FILE'))
        [void]$out.Add((New-DetailPair 'Path' (ConvertTo-DisplayText $item.FullName)))
        $count = 0; $more = $false
        try {
            foreach ($x in [IO.Directory]::EnumerateFileSystemEntries($item.FullName)) { $count++; if ($count -ge 10000) { $more = $true; break } }
            [void]$out.Add((New-DetailPair 'Type' (('Folder {0} {1:N0}{2} items' -f $G.Dot, $count, $(if ($more) { '+' } else { '' })))))
        }
        catch { [void]$out.Add((New-DetailPair 'Type' 'Folder (contents not accessible)')) }
    }
    else {
        $size = $item.Length
        [void]$out.Add((New-DetailText (ConvertTo-DisplayText $item.Name) 'FILE'))
        [void]$out.Add((New-DetailPair 'Folder' (ConvertTo-DisplayText $item.DirectoryName)))
        [void]$out.Add((New-DetailPair 'Size' ('{0}  ({1:N0} bytes)' -f (Format-Size $size), $size)))
        $tn = Get-FileTypeName $item.Extension
        $type = if ($tn) { "$tn ($($item.Extension))" } elseif ($item.Extension) { $item.Extension } else { '(no extension)' }
        [void]$out.Add((New-DetailPair 'Type' $type))
        try {
            $fs = [IO.File]::Open($item.FullName, 'Open', 'Read', 'ReadWrite')
            try { $head = Read-StreamHead $fs 65536 } finally { $fs.Dispose() }
            if ($head.Length -gt 0) { [void]$out.Add((New-DetailPair 'Content' (Get-BlobType $head))) }
            else { [void]$out.Add((New-DetailPair 'Content' 'empty file')) }
        }
        catch { [void]$out.Add((New-DetailPair 'Content' '(cannot read)')) }
        $vi = $item.VersionInfo
        if ($vi -and ($vi.FileVersion -or $vi.ProductName)) {
            [void]$out.Add((New-DetailPair 'Version' (ConvertTo-DisplayText (('{0} {1}' -f $vi.ProductName, $vi.FileVersion).Trim()))))
            if ($vi.CompanyName) { [void]$out.Add((New-DetailPair 'Company' (ConvertTo-DisplayText $vi.CompanyName))) }
        }
    }
    [void]$out.Add((New-DetailPair 'Modified' $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$out.Add((New-DetailPair 'Created' $item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$out.Add((New-DetailPair 'Attrib' ($item.Attributes.ToString())))
    return @{ Lines = $out; Size = $size; Missing = $false }
}

function Get-EntryDetails($e) {
    if ($e.Details) { return $e.Details }
    $lines = New-Object System.Collections.ArrayList
    $src = switch ($e.Source) { 'History' { 'Windows clipboard history' } 'Session' { 'captured this session' } default { 'live clipboard' } }
    if ($e.IsCurrent) { $src = "current clipboard $($G.Dot) $src" }
    if ($e.Private -and $e.Source -eq 'Clipboard') { $src += " $($G.Dot) marked private by the source app (not recorded)" }
    switch ($e.Kind) {
        'Text' {
            $st = Get-TextStats $e.Text
            [void]$lines.Add((New-DetailPair 'Text' ('{0:N0} chars {1} {2:N0} lines {1} {3:N0} words {1} {4}' -f $e.Text.Length, $G.Dot, $st.Lines, $st.Words, $st.Eol)))
            if ($st.NonAscii) { [void]$lines.Add((New-DetailPair 'Unicode' ('{0:N0} non-ASCII chars' -f $st.NonAscii))) }
            if ($st.Looks) { [void]$lines.Add((New-DetailPair 'Looks like' $st.Looks)) }
        }
        'Files' {
            $dets = @(); $total = 0; $missing = 0
            foreach ($f in $e.Files) {
                $d = Get-FileDetails $f; $dets += , $d; $total += $d.Size
                if ($d.Missing) { $missing++ }
            }
            $summary = '{0} item(s) {1} {2} total' -f $e.Files.Count, $G.Dot, (Format-Size $total)
            if ($missing) { $summary += " $($G.Dot) $missing missing" }
            [void]$lines.Add((New-DetailPair 'Files' $summary))
            foreach ($d in $dets) { [void]$lines.Add((New-DetailText '' 'Text')); foreach ($l in $d.Lines) { [void]$lines.Add($l) } }
            [void]$lines.Add((New-DetailText '' 'Text'))
        }
        'Image' {
            [void]$lines.Add((New-DetailPair 'Image' $e.ImageInfo))
            if ($e.BinType) { [void]$lines.Add((New-DetailPair 'Data' ('{0} {1} {2}' -f $e.BinType, $G.Dot, (Format-Size $e.BinSize)))) }
            if ($e.ImgW -gt 0) {
                $px = [long]$e.ImgW * $e.ImgH
                [void]$lines.Add((New-DetailPair 'Pixels' ('{0:N0} px {1} ~{2} as 32-bit RGBA' -f $px, $G.Dot, (Format-Size ($px * 4)))))
            }
            if ($e.Image) {
                try { [void]$lines.Add((New-DetailPair 'DPI' ('{0:N0} x {1:N0}' -f $e.Image.HorizontalResolution, $e.Image.VerticalResolution))) } catch { }
            }
        }
        'Binary' {
            [void]$lines.Add((New-DetailPair 'Format' $e.BinFormat))
            [void]$lines.Add((New-DetailPair 'Size' ('{0}  ({1:N0} bytes)' -f (Format-Size $e.BinSize), $e.BinSize)))
            [void]$lines.Add((New-DetailPair 'Detected' $e.BinType))
            if ($e.BinData) {
                [void]$lines.Add((New-DetailText '' 'Text'))
                [void]$lines.Add(@('hex', $e.BinData, 128))
                [void]$lines.Add((New-DetailText '' 'Text'))
            }
        }
        default { [void]$lines.Add((New-DetailText 'Nothing on the clipboard.' 'Muted')) }
    }
    [void]$lines.Add((New-DetailPair 'Source' $src))
    [void]$lines.Add((New-DetailPair 'Copied' $e.Time.ToString('yyyy-MM-dd HH:mm:ss')))
    if ($e.Formats.Count -gt 0) {
        if ($e.FormatSizes) {
            $parts = foreach ($k in $e.FormatSizes.Keys) { "$k ($($e.FormatSizes[$k]))" }
            [void]$lines.Add((New-DetailPair 'Formats' ($parts -join ', ')))
        }
        else { [void]$lines.Add((New-DetailPair 'Formats' ($e.Formats -join ', '))) }
    }
    $e.Details = $lines.ToArray()
    $e.DetailsCur = $e.IsCurrent
    return $e.Details
}

# Renders detail lines into display rows of width $w (label/value pairs wrapped with indent).
function Format-DetailRows($details, [int]$w) {
    $rows = New-Object System.Collections.Generic.List[string]
    $lw = 9
    foreach ($d in $details) {
        if ($d[0] -eq 'kv') {
            $label = $d[1]; $value = [string]$d[2]
            $lwa = [Math]::Max($lw, $label.Length)
            $chunks = Split-Wrap $value ([Math]::Max(4, $w - $lwa - 2))
            if ($chunks.Count -eq 0) { $chunks = @('') }
            $first = $true
            foreach ($ch in $chunks) {
                if ($first) { $rows.Add($C.Label + $label.PadRight($lwa) + $C.Frame + ': ' + $C.Value + $ch + $C.Reset); $first = $false }
                else { $rows.Add((' ' * ($lwa + 2)) + $C.Value + $ch + $C.Reset) }
            }
        }
        elseif ($d[0] -eq 'hex') {
            foreach ($h in (Get-HexDump $d[1] $d[2] $w)) { $rows.Add($C.Muted + $h) }
        }
        else {
            $style = $C[$d[1]]; if (-not $style) { $style = $C.Text }
            if ($d[2] -eq '') { $rows.Add(''); continue }
            foreach ($ch in (Split-Wrap $d[2] $w)) { $rows.Add($style + $ch + $C.Reset) }
        }
    }
    return , $rows.ToArray()
}

# Visible length of a string that contains ANSI sequences, and padding/cutting by visible width.
$AnsiRx = [regex]"$Esc\[[0-9;?]*[A-Za-z]"
function Get-VisibleLength([string]$s) { return $AnsiRx.Replace($s, '').Length }
function Pad-Ansi([string]$s, [int]$w) {
    $len = Get-VisibleLength $s
    if ($len -gt $w) {
        $sb = New-Object System.Text.StringBuilder; $vis = 0; $i = 0
        while ($i -lt $s.Length -and $vis -lt $w - 1) {
            $m = $AnsiRx.Match($s, $i)
            if ($m.Success -and $m.Index -eq $i) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
            [void]$sb.Append($s[$i]); $i++; $vis++
        }
        return $sb.ToString() + $G.Ell + $C.Reset
    }
    return $s + (' ' * ($w - $len))
}

# Text body rows (display-safe, wrapped) for previews/viewer. Total = number of wrapped rows the
# whole text needs (approximate for exotic characters). Only the rows we keep are converted.
function Get-TextRows([string]$t, [int]$w, [int]$maxRows = [int]::MaxValue) {
    $rows = New-Object System.Collections.Generic.List[string]
    $total = 0
    $w = [Math]::Max(1, $w)
    foreach ($ln in $t.Split("`n")) {
        $len = $ln.Length; if ($len -gt 0 -and $ln[$len - 1] -eq "`r") { $len-- }
        $need = [Math]::Max(1, [int][Math]::Ceiling($len / $w))
        if ($rows.Count -lt $maxRows) {
            $take = [Math]::Min($ln.Length, [long]($maxRows - $rows.Count) * $w + 1)
            $chunks = Split-Wrap (ConvertTo-DisplayText $ln.Substring(0, $take)) $w
            if ($chunks.Count -eq 0) { $chunks = @('') }
            foreach ($chunk in $chunks) { if ($rows.Count -lt $maxRows) { $rows.Add($chunk) } }
        }
        $total += $need
    }
    return @{ Rows = $rows.ToArray(); Total = $total }
}

# ---------------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------------
function Get-KindTag($e) {
    switch ($e.Kind) {
        'Text' { return $C.TXT + 'TXT ' } 'Files' { return $C.FILE + 'FILE' } 'Image' { return $C.IMG + 'IMG ' }
        'Binary' { return $C.BIN + 'BIN ' } default { return $C.NONE + ' -- ' }
    }
}

function Write-Frame([string[]]$rows) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$Esc[?25l")
    for ($i = 0; $i -lt $rows.Count; $i++) {
        [void]$sb.Append("$Esc[$($i + 1);1H").Append($rows[$i]).Append($C.Reset)
    }
    [Console]::Write($sb.ToString())
}

function Get-BoxTop([string]$title, [int]$w) {
    $t = (Format-Fit $title ([Math]::Max(1, $w - 4))).TrimEnd()
    if ($t -and -not $t.EndsWith(' ')) { $t += ' ' }
    return $C.Frame + $G.TL + $G.H + $C.Head + $t + $C.Frame + ($G.H * [Math]::Max(0, $w - 3 - $t.Length)) + $G.TR
}

function Get-BoxBottom([int]$w, [string]$hint) {
    if ($hint -and $w - 4 -gt $hint.Length) {
        return $C.Frame + $G.BL + ($G.H * ($w - 3 - $hint.Length)) + $C.Key + $hint + $C.Frame + $G.H + $G.BR
    }
    return $C.Frame + $G.BL + ($G.H * ($w - 2)) + $G.BR
}

function Show-Main {
    $W = [Math]::Max(40, [Console]::WindowWidth)
    $H = [Math]::Max(10, [Console]::WindowHeight)
    $S.Width = [Console]::WindowWidth; $S.Height = [Console]::WindowHeight
    $rows = New-Object System.Collections.Generic.List[string]
    $sep = " $($C.Frame)$($G.V)$($C.Reset) "

    # Header
    $hist = if ($S.HistoryOk) { "$($C.ok)Win history on" } else { "$($C.warn)Win history $($S.HistoryState)" }
    $left = " $($C.Title)Clipboard Manager$($C.Reset)$sep$($S.AllEntries.Count) entries$sep$hist$($C.Reset)"
    if ($S.Filter) { $left += "$sep$($C.Key)filter:$($C.Reset) $($S.Filter) $($C.Muted)($($S.Entries.Count) match)" }
    $rows.Add((Pad-Ansi $left ($W - 9)) + $C.Muted + (Get-Date).ToString('HH:mm:ss').PadLeft(9))

    $bodyH = $H - 3   # header + message line + key bar
    $side = $W -ge 90
    if ($side) {
        $lw = [Math]::Min(56, [int]($W * 0.42)); $rw = $W - $lw - 1
        $listRect = @{ W = $lw; H = $bodyH }; $prevRect = @{ W = $rw; H = $bodyH }
    }
    else {
        $lh = [Math]::Max(4, [int]($bodyH * 0.45))
        $listRect = @{ W = $W; H = $lh }; $prevRect = @{ W = $W; H = $bodyH - $lh }
    }

    # ---- list box
    $inner = $listRect.H - 2
    $n = $S.Entries.Count
    if ($S.Sel -ge $n) { $S.Sel = [Math]::Max(0, $n - 1) }
    if ($S.Sel -lt $S.Top) { $S.Top = $S.Sel }
    if ($S.Sel -ge $S.Top + $inner) { $S.Top = $S.Sel - $inner + 1 }
    if ($S.Top -gt [Math]::Max(0, $n - $inner)) { $S.Top = [Math]::Max(0, $n - $inner) }
    $listRows = New-Object System.Collections.Generic.List[string]
    $iw = $listRect.W - 2
    $numW = ([string]$n).Length
    # row layout: mark(1) num(numW) sp kind(4) sp summary sp src(1) age(4)
    $sumW = $iw - $numW - 13
    for ($r = 0; $r -lt $inner; $r++) {
        $i = $S.Top + $r
        if ($i -ge $n) { $listRows.Add(''); continue }
        $e = $S.Entries[$i]
        $mark = if ($e.IsCurrent) { $C.Cur + $G.Star } else { ' ' }
        $src = if ($e.Source -eq 'History') { ' ' } elseif ($e.Source -eq 'Session') { $C.Src + 's' } else { $C.Src + 'c' }
        $age = (Format-Age $e.Time).PadLeft(4)
        $num = ([string]($i + 1)).PadLeft($numW)
        $line = "$mark$($C.Reset)$($C.Muted)$num$($C.Reset) $(Get-KindTag $e)$($C.Reset) "
        $line += $C.Text + (Format-Fit $e.Summary $sumW) + ' ' + $src + $C.Reset + $C.Muted + $age
        if ($i -eq $S.Sel) {
            $plain = $AnsiRx.Replace($line, '')
            if (-not $e.IsCurrent) { $plain = $G.Ptr + $plain.Substring(1) }
            $line = $C.SelBg + $C.SelFg + $C.Bold + $plain.PadRight($iw) + $C.Reset
        }
        $listRows.Add($line)
    }
    if ($n -eq 0) { $listRows[0] = $C.Muted + '  (no entries)' }

    # ---- preview box
    $pInner = $prevRect.H - 2; $pw = $prevRect.W - 2
    $prevRows = New-Object System.Collections.Generic.List[string]
    $hint = ''
    if ($n -gt 0) {
        $e = $S.Entries[$S.Sel]
        foreach ($r in (Format-DetailRows (Get-EntryDetails $e) $pw)) { $prevRows.Add($r) }
        if ($e.Kind -eq 'Text') {
            $prevRows.Add($C.Frame + ($G.H * $pw))
            $room = $pInner - $prevRows.Count
            if ($room -ge 1) {
                $ck = "$pw,$room"
                if (-not $e.PreviewCache -or $e.PreviewCache.Key -ne $ck) { $e.PreviewCache = @{ Key = $ck; Val = (Get-TextRows $e.Text $pw $room) } }
                $tr = $e.PreviewCache.Val
                if ($tr.Total -le $room) { foreach ($r in $tr.Rows) { $prevRows.Add($C.Text + $r) } }
                else {
                    # Excerpt: as many rows as fit, then a marker; the border says how to see the rest.
                    for ($i = 0; $i -lt $room - 1; $i++) { $prevRows.Add($C.Text + $tr.Rows[$i]) }
                    $prevRows.Add($C.Muted + $G.Ell)
                    $hint = " +{0:N0} rows {1} V view {1} E edit " -f ($tr.Total - $room + 1), $G.Dot
                }
            }
            else { $hint = " V view $($G.Dot) E edit " }
        }
        elseif ($prevRows.Count -gt $pInner) {
            $hint = " +{0} rows {1} V view " -f ($prevRows.Count - $pInner + 1), $G.Dot
            while ($prevRows.Count -gt $pInner - 1) { $prevRows.RemoveAt($prevRows.Count - 1) }
            $prevRows.Add($C.Muted + $G.Ell)
        }
    }
    while ($prevRows.Count -lt $pInner) { $prevRows.Add('') }

    # ---- assemble boxes
    $listTitle = if ($n -gt $inner) { " Entries $($S.Sel + 1)/$n " } else { ' Entries ' }
    $prevTitle = ' Preview '
    if ($n -gt 0) {
        $prevTitle = switch ($S.Entries[$S.Sel].Kind) { 'Text' { ' Text ' } 'Files' { ' File(s) ' } 'Image' { ' Image ' } 'Binary' { ' Binary data ' } default { ' Empty ' } }
    }
    $listTop = Get-BoxTop $listTitle $listRect.W
    $prevTop = Get-BoxTop $prevTitle $prevRect.W
    $listBot = Get-BoxBottom $listRect.W ''
    $prevBot = Get-BoxBottom $prevRect.W $hint

    $V = $C.Frame + $G.V + $C.Reset
    if ($side) {
        $rows.Add($listTop + ' ' + $prevTop)
        for ($r = 0; $r -lt $inner; $r++) {
            $rows.Add($V + (Pad-Ansi $listRows[$r] $iw) + $C.Reset + $V + ' ' + $V + (Pad-Ansi $prevRows[$r] $pw) + $C.Reset + $V)
        }
        $rows.Add($listBot + ' ' + $prevBot)
    }
    else {
        $rows.Add($listTop)
        for ($r = 0; $r -lt $inner; $r++) { $rows.Add($V + (Pad-Ansi $listRows[$r] $iw) + $C.Reset + $V) }
        $rows.Add($listBot)
        $rows.Add($prevTop)
        for ($r = 0; $r -lt $pInner; $r++) { $rows.Add($V + (Pad-Ansi $prevRows[$r] $pw) + $C.Reset + $V) }
        $rows.Add($prevBot)
    }

    # Message line + key bar
    if ($S.Msg -and (Get-Date) -lt $S.MsgUntil) { $rows.Add((Pad-Ansi (' ' + $C[$S.MsgColor] + $S.Msg) $W)) }
    else {
        $S.Msg = ''
        $rows.Add((Pad-Ansi (" $($C.Cur)$($G.Star)$($C.Muted) current  $($C.Src)s$($C.Muted) session-only  $($C.Src)c$($C.Muted) clipboard-only  $($C.Key)?$($C.Muted) help") $W))
    }
    $keys = @('Enter', 'copy', 'P', 'paste', 'V', 'view', 'E', 'edit', 'Del', 'delete', 'S', 'save', 'O', 'open', '/', 'filter', 'Q', 'quit')
    $kb = ''
    for ($i = 0; $i -lt $keys.Count; $i += 2) { $kb += " $($C.Key)$($keys[$i])$($C.Reset)$($C.Muted) $($keys[$i + 1])" }
    $rows.Add((Pad-Ansi $kb ($W - 1)))

    Write-Frame $rows.ToArray()
}

# Full-screen scrollable viewer. $rows: pre-rendered display rows.
function Show-Pager([string]$title, [string[]]$rows) {
    $top = 0
    while ($true) {
        $W = [Math]::Max(40, [Console]::WindowWidth); $H = [Math]::Max(10, [Console]::WindowHeight)
        $inner = $H - 3
        $maxTop = [Math]::Max(0, $rows.Count - $inner)
        if ($top -gt $maxTop) { $top = $maxTop }
        if ($top -lt 0) { $top = 0 }
        $out = New-Object System.Collections.Generic.List[string]
        $pos = if ($rows.Count -gt $inner) { " {0}-{1}/{2} " -f ($top + 1), [Math]::Min($rows.Count, $top + $inner), $rows.Count } else { " $($rows.Count) rows " }
        $t = (Format-Fit " $title " ($W - 5 - $pos.Length)).TrimEnd() + ' '
        $out.Add($C.Frame + $G.TL + $G.H + $C.Head + $t + $C.Frame + ($G.H * ($W - 4 - $t.Length - $pos.Length)) + $C.Muted + $pos + $C.Frame + $G.H + $G.TR)
        for ($r = 0; $r -lt $inner; $r++) {
            $i = $top + $r
            $content = if ($i -lt $rows.Count) { $rows[$i] } else { '' }
            $out.Add($C.Frame + $G.V + $C.Reset + (Pad-Ansi $content ($W - 2)) + $C.Reset + $C.Frame + $G.V)
        }
        $out.Add($C.Frame + $G.BL + ($G.H * ($W - 2)) + $G.BR)
        $out.Add((Pad-Ansi " $($C.Key)$($G.Up)$($G.Dn) PgUp PgDn Space Home End$($C.Muted) scroll   $($C.Key)Esc/Q$($C.Muted) back" ($W - 1)))
        Write-Frame $out.ToArray()
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow' { $top-- } 'DownArrow' { $top++ } 'PageUp' { $top -= $inner } 'PageDown' { $top += $inner }
            'Spacebar' { $top += $inner } 'Home' { $top = 0 } 'End' { $top = $maxTop }
            'Escape' { return } 'Q' { return } 'V' { return } 'Enter' { return } 'Backspace' { return }
        }
    }
}

# Modal one-line prompt on the message line; returns the typed string or $null on Esc.
function Read-Line([string]$prompt, [string]$initial = '', [scriptblock]$onChange) {
    $buf = $initial
    while ($true) {
        $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
        $vis = $buf; $room = $W - $prompt.Length - 4
        if ($vis.Length -gt $room) { $vis = $vis.Substring($vis.Length - $room) }
        [Console]::Write("$Esc[$($H - 1);1H" + (Pad-Ansi (" $($C.Key)$prompt$($C.Reset) $vis$($C.Rev) $($C.Reset)") $W) + $C.Reset)
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Escape') { return $null }
        if ($k.Key -eq 'Enter') { return $buf }
        if ($k.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) } }
        elseif ($k.KeyChar -and [int]$k.KeyChar -ge 32) { $buf += $k.KeyChar }
        else { continue }
        if ($onChange) { & $onChange $buf }
    }
}

function Confirm-Action([string]$question) {
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    [Console]::Write("$Esc[$($H - 1);1H" + (Pad-Ansi (" $($C.warn)$question $($C.Key)(y/N)$($C.Reset)") $W))
    $k = [Console]::ReadKey($true)
    $S.Dirty = $true
    return ($k.Key -eq 'Y')
}

# ---------------------------------------------------------------------------------------------
# Built-in text editor
# ---------------------------------------------------------------------------------------------
function Edit-TextInline([string]$text, [string]$title) {
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -split "`r?`n")) { $lines.Add($l) }
    $row = 0; $col = 0; $top = 0; $left = 0; $modified = $false
    while ($true) {
        $W = [Math]::Max(40, [Console]::WindowWidth); $H = [Math]::Max(10, [Console]::WindowHeight)
        $inner = $H - 3; $iw = $W - 2 - 6   # 5-digit gutter + space
        if ($row -lt $top) { $top = $row }
        if ($row -ge $top + $inner) { $top = $row - $inner + 1 }
        if ($col -lt $left) { $left = $col }
        if ($col -ge $left + $iw) { $left = $col - $iw + 1 }
        $out = New-Object System.Collections.Generic.List[string]
        $mod = if ($modified) { '[modified] ' } else { '' }
        $pos = " Ln $($row + 1), Col $($col + 1) $($G.Dot) $($lines.Count) lines "
        $t = " Edit: $title "
        $fill = [Math]::Max(0, $W - 4 - $t.Length - $mod.Length - $pos.Length)
        $out.Add($C.Frame + $G.TL + $G.H + $C.Head + $t + $C.warn + $mod + $C.Frame + ($G.H * $fill) + $C.Muted + $pos + $C.Frame + $G.H + $G.TR)
        for ($r = 0; $r -lt $inner; $r++) {
            $i = $top + $r
            if ($i -lt $lines.Count) {
                $l = ConvertTo-DisplayText $lines[$i]
                $seg = if ($left -lt $l.Length) { $l.Substring($left, [Math]::Min($iw, $l.Length - $left)) } else { '' }
                $gc = if ($i -eq $row) { $C.Key } else { $C.Muted }
                $out.Add($C.Frame + $G.V + $gc + ([string]($i + 1)).PadLeft(5) + ' ' + $C.Reset + $C.Value + $seg.PadRight($iw) + $C.Frame + $G.V)
            }
            else { $out.Add($C.Frame + $G.V + $C.Muted + '    ~'.PadRight($iw + 6) + $C.Frame + $G.V) }
        }
        $out.Add($C.Frame + $G.BL + ($G.H * ($W - 2)) + $G.BR)
        $out.Add((Pad-Ansi " $($C.Key)Ctrl+S/F2$($C.Muted) save & copy  $($C.Key)Esc$($C.Muted) cancel  $($C.Key)Ctrl+K$($C.Muted) delete line  $($C.Key)Tab$($C.Muted) insert tab" ($W - 1)))
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("$Esc[?25l")
        for ($i = 0; $i -lt $out.Count; $i++) { [void]$sb.Append("$Esc[$($i + 1);1H").Append($out[$i]).Append($C.Reset) }
        [void]$sb.Append("$Esc[$($row - $top + 2);$($col - $left + 8)H$Esc[?25h")   # place the real cursor
        [Console]::Write($sb.ToString())

        $k = [Console]::ReadKey($true)
        [Console]::Write("$Esc[?25l")
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $alt = ($k.Modifiers -band [ConsoleModifiers]::Alt) -ne 0
        $cur = $lines[$row]
        $handled = $true
        switch ($k.Key) {
            'Escape' {
                if (-not $modified -or (Confirm-Action 'Discard changes?')) { return $null }
            }
            'F2' { return ($lines -join $nl) }
            'LeftArrow' {
                if ($ctrl) {
                    while ($col -gt 0 -and [char]::IsWhiteSpace($cur[$col - 1])) { $col-- }
                    while ($col -gt 0 -and -not [char]::IsWhiteSpace($cur[$col - 1])) { $col-- }
                }
                elseif ($col -gt 0) { $col-- } elseif ($row -gt 0) { $row--; $col = $lines[$row].Length }
            }
            'RightArrow' {
                if ($ctrl) {
                    while ($col -lt $cur.Length -and -not [char]::IsWhiteSpace($cur[$col])) { $col++ }
                    while ($col -lt $cur.Length -and [char]::IsWhiteSpace($cur[$col])) { $col++ }
                }
                elseif ($col -lt $cur.Length) { $col++ } elseif ($row -lt $lines.Count - 1) { $row++; $col = 0 }
            }
            'UpArrow' { if ($row -gt 0) { $row-- }; $col = [Math]::Min($col, $lines[$row].Length) }
            'DownArrow' { if ($row -lt $lines.Count - 1) { $row++ }; $col = [Math]::Min($col, $lines[$row].Length) }
            'PageUp' { $row = [Math]::Max(0, $row - $inner); $col = [Math]::Min($col, $lines[$row].Length) }
            'PageDown' { $row = [Math]::Min($lines.Count - 1, $row + $inner); $col = [Math]::Min($col, $lines[$row].Length) }
            'Home' { if ($ctrl) { $row = 0 }; $col = 0 }
            'End' { if ($ctrl) { $row = $lines.Count - 1 }; $col = $lines[$row].Length }
            'Enter' {
                $lines[$row] = $cur.Substring(0, $col)
                $indent = ([regex]::Match($cur, '^[ \t]*')).Value
                if ($indent.Length -gt $col) { $indent = $indent.Substring(0, $col) }
                $lines.Insert($row + 1, $indent + $cur.Substring($col))
                $row++; $col = $indent.Length; $modified = $true
            }
            'Backspace' {
                if ($col -gt 0) { $lines[$row] = $cur.Remove($col - 1, 1); $col--; $modified = $true }
                elseif ($row -gt 0) { $col = $lines[$row - 1].Length; $lines[$row - 1] += $cur; $lines.RemoveAt($row); $row--; $modified = $true }
            }
            'Delete' {
                if ($col -lt $cur.Length) { $lines[$row] = $cur.Remove($col, 1); $modified = $true }
                elseif ($row -lt $lines.Count - 1) { $lines[$row] = $cur + $lines[$row + 1]; $lines.RemoveAt($row + 1); $modified = $true }
            }
            'Tab' { $lines[$row] = $cur.Insert($col, "`t"); $col++; $modified = $true }
            default { $handled = $false }
        }
        if ($handled) { continue }
        if ($ctrl -and -not $alt -and $k.Key -eq 'S') { return ($lines -join $nl) }
        if ($ctrl -and -not $alt -and $k.Key -eq 'K') {
            if ($lines.Count -gt 1) { $lines.RemoveAt($row); if ($row -ge $lines.Count) { $row = $lines.Count - 1 } } else { $lines[0] = '' }
            $col = [Math]::Min($col, $lines[$row].Length); $modified = $true; continue
        }
        $ch = $k.KeyChar
        # Ctrl+Alt (AltGr) combinations produce real characters on many keyboard layouts.
        if ([int]$ch -ge 32 -and (-not $ctrl -or $alt)) {
            $lines[$row] = $cur.Insert($col, [string]$ch); $col++; $modified = $true
        }
    }
}

function Edit-TextExternal([string]$text) {
    $tmp = Join-Path $env:TEMP ('ClipboardMgr-{0}.txt' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    $before = (Get-Item -LiteralPath $tmp).LastWriteTimeUtc
    try {
        if ($env:EDITOR) { Start-Process -FilePath $env:EDITOR -ArgumentList "`"$tmp`"" }
        else { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$tmp`"" }
    }
    catch { Set-Message "Cannot start editor: $($_.Exception.Message)" 'err'; Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; return $null }
    # Windows 11 Notepad may open the file as a tab in an existing window and return at once,
    # so instead of waiting for the process the user confirms here when done.
    Show-Main
    $W = [Console]::WindowWidth; $H = [Console]::WindowHeight
    [Console]::Write("$Esc[$($H - 1);1H" + (Pad-Ansi (" $($C.info)Editing externally $($G.Dot) save the file, then press $($C.Key)Enter$($C.info) to apply or $($C.Key)Esc$($C.info) to cancel") $W))
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Escape') { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; return $null }
        if ($k.Key -eq 'Enter') { break }
    }
    $after = (Get-Item -LiteralPath $tmp).LastWriteTimeUtc
    $result = [IO.File]::ReadAllText($tmp)
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    if ($after -eq $before) { Set-Message 'File was not saved - nothing changed.' 'warn'; return $null }
    # Some editors add a trailing newline; keep the original's convention.
    if (-not $text.EndsWith("`n") -and $result.EndsWith("`n")) { $result = $result -replace '\r?\n$', '' }
    return $result
}

# ---------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------
function Get-Selected { if ($S.Entries.Count -gt 0) { return $S.Entries[$S.Sel] } return $null }

function Set-ClipboardFromEntry($e) {
    if (-not $e -or $e.Kind -eq 'Empty') { return $false }
    if ($e.HistoryItem) {
        $st = $WinRT.Clipboard::SetHistoryItemAsContent($e.HistoryItem)
        if ("$st" -eq 'Success') { return $true }
        if ($e.Kind -ne 'Text') { Set-Message "Windows refused to restore the item: $st" 'err'; return $false }
    }
    switch ($e.Kind) {
        'Text' { Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetText($e.Text) } }
        'Files' {
            $sc = New-Object System.Collections.Specialized.StringCollection
            foreach ($f in $e.Files) { [void]$sc.Add($f) }
            Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetFileDropList($sc) }
        }
        'Image' {
            if (-not $e.Image) { return $false }
            $do = New-Object System.Windows.Forms.DataObject
            $do.SetImage($e.Image)
            if ($e.BinData -and $e.BinType -like 'PNG*') { $do.SetData('PNG', (New-Object IO.MemoryStream(, $e.BinData))) }
            Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetDataObject($do, $true) }
        }
        'Binary' {
            if (-not $e.BinData) { return $false }
            $do = New-Object System.Windows.Forms.DataObject
            $do.SetData($e.BinFormat, (New-Object IO.MemoryStream(, $e.BinData)))
            Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetDataObject($do, $true) }
        }
    }
    return $true
}

function Invoke-Copy {
    $e = Get-Selected
    if (-not $e -or $e.Kind -eq 'Empty') { Set-Message 'Nothing to copy.' 'warn'; return }
    if ($e.IsCurrent) { Set-Message 'Already on the clipboard.' 'info'; return }
    try {
        if (Set-ClipboardFromEntry $e) {
            Set-Message "Copied $($e.Kind.ToLower()) entry to the clipboard." 'ok'
            $S.Sel = 0
            Request-Refresh
        }
        elseif (-not $S.Msg) { Set-Message 'This entry cannot be restored.' 'err' }
    }
    catch { Set-Message "Copy failed: $($_.Exception.Message)" 'err' }
}

function Find-PreviousWindow {
    # Walk the z-order below our own console window and pick the first normal app window.
    $self = $S.SelfHwnd
    if ($self -eq [IntPtr]::Zero) { $self = [ClipMgr.Native]::GetForegroundWindow() }
    $h = [ClipMgr.Native]::GetWindow($self, 2)   # GW_HWNDNEXT
    $guard = 0
    while ($h -ne [IntPtr]::Zero -and $guard -lt 1000) {
        $guard++
        if ([ClipMgr.Native]::IsWindowVisible($h) -and [ClipMgr.Native]::GetAncestor($h, 3) -eq $h) {
            $ex = [ClipMgr.Native]::GetWindowLongPtr($h, -20).ToInt64()
            $cloaked = 0
            [void][ClipMgr.Native]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)
            $len = [ClipMgr.Native]::GetWindowTextLength($h)
            if (($ex -band 0x80) -eq 0 -and $cloaked -eq 0 -and $len -gt 0) {   # not a tool window, not cloaked
                $sb = New-Object System.Text.StringBuilder ($len + 1)
                [void][ClipMgr.Native]::GetWindowText($h, $sb, $sb.Capacity)
                $title = $sb.ToString()
                if ($title -ne 'Program Manager') { return @{ Hwnd = $h; Title = $title } }
            }
        }
        $h = [ClipMgr.Native]::GetWindow($h, 2)
    }
    return $null
}

function Invoke-Paste {
    $e = Get-Selected
    if (-not $e -or $e.Kind -eq 'Empty') { Set-Message 'Nothing to paste.' 'warn'; return }
    $target = Find-PreviousWindow
    if (-not $target) { Set-Message 'No previous window found to paste into.' 'err'; return }
    try {
        if (-not $e.IsCurrent) {
            if (-not (Set-ClipboardFromEntry $e)) { if (-not $S.Msg) { Set-Message 'This entry cannot be restored.' 'err' }; return }
            Start-Sleep -Milliseconds 120
        }
        if ([ClipMgr.Native]::IsIconic($target.Hwnd)) { [void][ClipMgr.Native]::ShowWindow($target.Hwnd, 9) }
        # Tapping Alt allows a background process to move the foreground window.
        [ClipMgr.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [ClipMgr.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [void][ClipMgr.Native]::SetForegroundWindow($target.Hwnd)
        Start-Sleep -Milliseconds 200
        $t = $target.Title; if ($t.Length -gt 40) { $t = $t.Substring(0, 39) + $G.Ell }
        if ([ClipMgr.Native]::GetForegroundWindow() -ne $target.Hwnd) {
            Set-Message "Could not activate '$t'; the entry is on the clipboard." 'warn'; Request-Refresh; return
        }
        [ClipMgr.Native]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)   # Ctrl down
        [ClipMgr.Native]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)   # V down
        [ClipMgr.Native]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)   # V up
        [ClipMgr.Native]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)   # Ctrl up
        Set-Message "Pasted into '$t'." 'ok'
        $S.Sel = 0
        Request-Refresh
    }
    catch { Set-Message "Paste failed: $($_.Exception.Message)" 'err' }
}

function Invoke-Delete {
    $e = Get-Selected
    if (-not $e -or $e.Kind -eq 'Empty') { return }
    try {
        if ($e.HistoryItem) {
            if (-not $WinRT.Clipboard::DeleteItemFromHistory($e.HistoryItem)) { Set-Message 'Windows refused to delete the item.' 'err'; return }
            $S.HistoryCache.Remove($e.HistoryItem.Id)
        }
        foreach ($d in @($S.Session | Where-Object { $_.Sig -eq $e.Sig })) { $S.Session.Remove($d) }
        if ($e.IsCurrent) {
            Invoke-Clipboard { [System.Windows.Forms.Clipboard]::Clear() }
            $S.Seq = [ClipMgr.Native]::GetClipboardSequenceNumber()
            $S.Current = New-Entry 'Empty' 'Clipboard'; Update-EntrySummary $S.Current
            Set-Message 'Deleted and cleared the clipboard.' 'ok'
        }
        else { Set-Message 'Entry deleted.' 'ok' }
        Update-Entries
    }
    catch { Set-Message "Delete failed: $($_.Exception.Message)" 'err' }
}

function Invoke-ClearAll {
    if (-not (Confirm-Action 'Clear the clipboard, Windows clipboard history (except pinned) and session history?')) { return }
    try {
        if ($S.HistoryOk) { [void]$WinRT.Clipboard::ClearHistory() }
        $S.Session.Clear(); $S.HistoryCache.Clear()
        Invoke-Clipboard { [System.Windows.Forms.Clipboard]::Clear() }
        Set-Message 'Clipboard and history cleared.' 'ok'
        Request-Refresh -Now
    }
    catch { Set-Message "Clear failed: $($_.Exception.Message)" 'err' }
}

function Invoke-View {
    $e = Get-Selected
    if (-not $e) { return }
    $W = [Math]::Max(40, [Console]::WindowWidth) - 2
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Format-DetailRows (Get-EntryDetails $e) $W)) { $rows.Add($r) }
    if ($e.Kind -eq 'Text') {
        $rows.Add($C.Frame + ($G.H * $W))
        foreach ($r in (Get-TextRows $e.Text $W).Rows) { $rows.Add($C.Text + $r) }
    }
    elseif ($e.Kind -eq 'Image') {
        $data = $e.BinData
        try {
            if ($e.HistoryItem) { $bmp = Open-HistoryBitmap $e.HistoryItem; $data = Read-StreamHead $bmp.Stream 1024; $bmp.Stream.Dispose() }
            elseif (-not $data -and $e.Image) {
                $ms = New-Object IO.MemoryStream; $e.Image.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $data = $ms.ToArray()
            }
        }
        catch { }
        if ($data) {
            $rows.Add(''); $rows.Add($C.Label + 'Hex dump (first 1 KB):')
            foreach ($h in (Get-HexDump $data 1024 $W)) { $rows.Add($C.Muted + $h) }
        }
    }
    elseif ($e.Kind -eq 'Binary' -and $e.BinData) {
        $rows.Add(''); $rows.Add($C.Label + 'Hex dump (first 4 KB):')
        foreach ($h in (Get-HexDump $e.BinData 4096 $W)) { $rows.Add($C.Muted + $h) }
    }
    Show-Pager ('{0} entry' -f $e.Kind) $rows.ToArray()
    $S.Dirty = $true
}

function Invoke-Edit([switch]$External) {
    $e = Get-Selected
    if (-not $e) { return }
    if ($e.Kind -ne 'Text') {
        if ($e.Kind -eq 'Files') { Set-Message 'File entries cannot be edited; O opens the file location.' 'warn' }
        else { Set-Message 'Only text entries can be edited.' 'warn' }
        return
    }
    $new = if ($External) { Edit-TextExternal $e.Text } else { Edit-TextInline $e.Text ('{0:N0} chars' -f $e.Text.Length) }
    $S.Dirty = $true
    if ($null -eq $new) { if (-not $S.Msg) { Set-Message 'Edit cancelled.' 'info' }; return }
    if ($new -ceq $e.Text) { Set-Message 'No changes.' 'info'; return }
    try {
        # Replace: the edited text becomes the current clipboard and the original entry goes away.
        if ($new.Length -gt 0) { Invoke-Clipboard { [System.Windows.Forms.Clipboard]::SetText($new) } }
        else { Invoke-Clipboard { [System.Windows.Forms.Clipboard]::Clear() } }
        if ($e.HistoryItem) { [void]$WinRT.Clipboard::DeleteItemFromHistory($e.HistoryItem); $S.HistoryCache.Remove($e.HistoryItem.Id) }
        foreach ($d in @($S.Session | Where-Object { $_.Sig -eq $e.Sig })) { $S.Session.Remove($d) }
        Set-Message 'Edited text copied to the clipboard.' 'ok'
        $S.Sel = 0
        Request-Refresh -Now
    }
    catch { Set-Message "Could not set clipboard: $($_.Exception.Message)" 'err' }
}

function Invoke-Open {
    $e = Get-Selected
    if (-not $e) { return }
    $p = if ($e.Kind -eq 'Text') { $e.Text.Trim().Trim('"') } else { '' }
    if ($e.Kind -eq 'Files' -and $e.Files.Count -gt 0) {
        $f = $e.Files[0]
        if (Test-Path -LiteralPath $f) { Start-Process explorer.exe -ArgumentList "/select,`"$f`""; Set-Message "Opened location of $(Split-Path $f -Leaf)" 'ok' }
        else { Set-Message 'File no longer exists.' 'err' }
    }
    elseif ($p -match '^https?://\S+$') { Start-Process $p; Set-Message 'Opened URL in the browser.' 'ok' }
    elseif ($p -and $p.Length -lt 260 -and $p -notmatch '[\r\n]' -and (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe -ArgumentList "/select,`"$p`""; Set-Message 'Opened path in Explorer.' 'ok'
    }
    else { Set-Message 'O opens files, folders, paths and URLs.' 'warn' }
}

function Invoke-Save {
    $e = Get-Selected
    if (-not $e -or $e.Kind -eq 'Empty' -or $e.Kind -eq 'Files') { Set-Message 'Save works for text, image and binary entries.' 'warn'; return }
    $dir = [Environment]::GetFolderPath('MyDocuments')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $ext = switch ($e.Kind) { 'Text' { '.txt' } 'Image' { '.png' } default { '.bin' } }
    if ($e.Kind -eq 'Image' -and $e.HistoryItem -and $e.BinType -match '^(PNG|JPEG|GIF|BMP|DIB)') { $ext = '.' + ($Matches[1].ToLower() -replace 'jpeg', 'jpg' -replace 'dib', 'bmp') }
    if ($e.Kind -eq 'Binary' -and $e.BinType -match '^(PNG|JPEG|GIF|PDF|ZIP|BMP)') { $ext = '.' + ($Matches[1].ToLower() -replace 'jpeg', 'jpg') }
    $path = Read-Line 'Save as:' (Join-Path $dir "clipboard-$stamp$ext")
    $S.Dirty = $true
    if (-not $path) { return }
    try {
        switch ($e.Kind) {
            'Text' { [IO.File]::WriteAllText($path, $e.Text, (New-Object Text.UTF8Encoding $false)) }
            'Image' {
                if ($e.Image) {
                    $fmt = switch -regex ([IO.Path]::GetExtension($path)) { '\.jpe?g' { 'Jpeg' } '\.bmp' { 'Bmp' } '\.gif' { 'Gif' } default { 'Png' } }
                    $e.Image.Save($path, [System.Drawing.Imaging.ImageFormat]::$fmt)
                }
                elseif ($e.HistoryItem) {
                    # Windows history gives us the stored bytes; written as-is.
                    $bmp = Open-HistoryBitmap $e.HistoryItem
                    $fs = [IO.File]::Create($path)
                    try { $bmp.Stream.CopyTo($fs) } finally { $fs.Dispose(); $bmp.Stream.Dispose() }
                }
            }
            default { [IO.File]::WriteAllBytes($path, $e.BinData) }
        }
        Set-Message "Saved to $path" 'ok'
    }
    catch { Set-Message "Save failed: $($_.Exception.Message)" 'err' }
}

function Invoke-Filter {
    $orig = $S.Filter
    $res = Read-Line 'Filter:' $S.Filter { param($t) $S.Filter = $t; Update-Filter; Show-Main }
    if ($null -eq $res) { $S.Filter = $orig } else { $S.Filter = $res }
    Update-Filter
}

function Show-Help {
    $k = { param($key, $desc) "  $($C.Key)$($key.PadRight(18))$($C.Reset)$desc" }
    $rows = @(
        "$($C.Head)Navigation"
        (& $k 'Up/Down, j/k' 'move selection')
        (& $k 'PgUp/PgDn Home/End' 'jump')
        (& $k '1-9' 'select entry by number')
        ''
        "$($C.Head)Actions"
        (& $k 'Enter, C, Ctrl+C' 'copy selected entry to the clipboard (makes it current)')
        (& $k 'P' 'paste selected entry into the previously active window')
        (& $k 'V, Space' 'view the full entry (text, file details, hex dump)')
        (& $k 'E' 'edit text in the built-in editor (Ctrl+S save, Esc cancel)')
        (& $k 'N' 'edit text in Notepad (or $env:EDITOR)')
        (& $k 'Del, D' 'delete entry (from Windows history too; clears clipboard if current)')
        (& $k 'O' 'open file location / URL / path')
        (& $k 'S' 'save text, image or binary data to a file')
        (& $k '/' 'filter entries (Esc on the list clears the filter)')
        (& $k 'R, F5' 'refresh')
        (& $k 'X' 'clear clipboard and all history')
        (& $k 'Q, Esc' 'quit')
        ''
        "$($C.Head)Markers"
        "  $($C.Cur)$($G.Star)$($C.Reset)  current clipboard content"
        "  $($C.Src)s$($C.Reset)  captured by ClipboardMgr this session (not in Windows history, e.g. files)"
        "  $($C.Src)c$($C.Reset)  live clipboard only (not stored in Windows history)"
        "  $($C.TXT)TXT $($C.FILE)FILE $($C.IMG)IMG $($C.BIN)BIN$($C.Reset)  entry type"
        ''
        "$($C.Head)Windows clipboard history: $($C.Reset)$($S.HistoryState)"
        "  $($C.Muted)Windows history keeps text, HTML/RTF and images up to 4 MB (max 25 items);"
        "  $($C.Muted)anything else is tracked only while ClipboardMgr is running."
    )
    Show-Pager 'Help' $rows
    $S.Dirty = $true
}

function Request-Refresh([switch]$Now) {
    if ($Now) { $S.PendingRefresh = [datetime]::MinValue }
    # WinRT history is updated asynchronously after a clipboard change; refresh a bit later too.
    else { $S.PendingRefresh = (Get-Date).AddMilliseconds(400) }
}

# ---------------------------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------------------------
$saved = @{
    TreatCtrlC = [Console]::TreatControlCAsInput
    OutEnc     = [Console]::OutputEncoding
    Title      = $Host.UI.RawUI.WindowTitle
}
try {
    # Enable VT processing (Windows 10+ console); harmless if already on.
    $hOut = [ClipMgr.Native]::GetStdHandle(-11); $mode = 0
    if ([ClipMgr.Native]::GetConsoleMode($hOut, [ref]$mode)) { [void][ClipMgr.Native]::SetConsoleMode($hOut, $mode -bor 0x0004) }
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::TreatControlCAsInput = $true
    $Host.UI.RawUI.WindowTitle = 'Clipboard Manager'
    [Console]::Write("$Esc[?1049h$Esc[?25l$Esc[2J")

    Initialize-History
    $S.Seq = [ClipMgr.Native]::GetClipboardSequenceNumber()
    Update-Entries -CaptureCurrent
    $lastSecond = -1

    while ($S.Running) {
        $now = Get-Date
        # Clipboard change detection
        if ($now -ge $S.NextPoll) {
            $S.NextPoll = $now.AddMilliseconds(250)
            $seq = [ClipMgr.Native]::GetClipboardSequenceNumber()
            if ($seq -ne $S.Seq) {
                $S.Seq = $seq
                Start-Sleep -Milliseconds 50   # let the source app finish writing all formats
                Update-Entries -CaptureCurrent
                Request-Refresh
            }
        }
        if ($now -ge $S.PendingRefresh) {
            $S.PendingRefresh = [datetime]::MaxValue
            $seq = [ClipMgr.Native]::GetClipboardSequenceNumber()
            Update-Entries -CaptureCurrent:($seq -ne $S.Seq)
            $S.Seq = $seq
        }
        if ([Console]::WindowWidth -ne $S.Width -or [Console]::WindowHeight -ne $S.Height) { [Console]::Write("$Esc[2J"); $S.Dirty = $true }
        if ($now.Second -ne $lastSecond) { $lastSecond = $now.Second; $S.Dirty = $true }   # clock / ages / message expiry
        if ($S.Dirty) { $S.Dirty = $false; Show-Main }

        if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 40; continue }
        $k = [Console]::ReadKey($true)
        # Keys only arrive while our console window is focused: remember it for "paste".
        $S.SelfHwnd = [ClipMgr.Native]::GetForegroundWindow()
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $n = $S.Entries.Count
        $pageSize = [Math]::Max(1, $(if ($S.Width -ge 90) { $S.Height - 5 } else { [int](($S.Height - 3) * 0.45) - 2 }))
        $S.Dirty = $true
        $handled = $true
        switch ($k.Key) {
            'UpArrow' { if ($S.Sel -gt 0) { $S.Sel-- } }
            'DownArrow' { if ($S.Sel -lt $n - 1) { $S.Sel++ } }
            'PageUp' { $S.Sel = [Math]::Max(0, $S.Sel - $pageSize) }
            'PageDown' { $S.Sel = [Math]::Max(0, [Math]::Min($n - 1, $S.Sel + $pageSize)) }
            'Home' { $S.Sel = 0 }
            'End' { $S.Sel = [Math]::Max(0, $n - 1) }
            'Enter' { Invoke-Copy }
            'Delete' { Invoke-Delete }
            'Escape' { if ($S.Filter) { $S.Filter = ''; Update-Filter } else { $S.Running = $false } }
            'F1' { Show-Help }
            'F5' { $S.HistoryCache.Clear(); foreach ($e in $S.Session) { $e.Details = $null }; Request-Refresh -Now }
            default { $handled = $false }
        }
        if ($handled) { continue }
        if ($ctrl) {
            switch ($k.Key) {
                'C' { Invoke-Copy } 'Q' { $S.Running = $false } 'R' { Request-Refresh -Now }
            }
            continue
        }
        switch -CaseSensitive ([string]$k.KeyChar) {
            'k' { if ($S.Sel -gt 0) { $S.Sel-- } }
            'j' { if ($S.Sel -lt $n - 1) { $S.Sel++ } }
            { $_ -in 'c', 'C' } { Invoke-Copy }
            { $_ -in 'p', 'P' } { Invoke-Paste }
            { $_ -in 'v', 'V', ' ' } { Invoke-View }
            { $_ -in 'e', 'E' } { Invoke-Edit }
            { $_ -in 'n', 'N' } { Invoke-Edit -External }
            { $_ -in 'd', 'D' } { Invoke-Delete }
            { $_ -in 'o', 'O' } { Invoke-Open }
            { $_ -in 's', 'S' } { Invoke-Save }
            { $_ -in 'r', 'R' } {
                $S.HistoryCache.Clear()
                foreach ($e in $S.Session) { $e.Details = $null }
                Request-Refresh -Now; Set-Message 'Refreshed.' 'info'
            }
            { $_ -in 'x', 'X' } { Invoke-ClearAll }
            { $_ -in 'q', 'Q' } { $S.Running = $false }
            { $_ -in '?', 'h', 'H' } { Show-Help }
            '/' { Invoke-Filter }
            { $_ -match '^[1-9]$' } { $i = [int]$_ - 1; if ($i -lt $n) { $S.Sel = $i } }
        }
    }
}
finally {
    [Console]::Write("$Esc[0m$Esc[?25h$Esc[?1049l")
    [Console]::TreatControlCAsInput = $saved.TreatCtrlC
    try { [Console]::OutputEncoding = $saved.OutEnc } catch { }
    try { $Host.UI.RawUI.WindowTitle = $saved.Title } catch { }
    foreach ($e in @($S.Session) + @($S.Current)) { if ($e -and $e.Image) { try { $e.Image.Dispose() } catch { } } }
}
