<#
.SYNOPSIS
    Windows User PATH Environment Variable TUI Editor.
.DESCRIPTION
    A keyboard-driven Text User Interface (TUI) for viewing, navigating,
    modifying, adding, deleting, and reordering entries in the Windows User
    PATH environment variable (HKCU\Environment\Path).
    
    Compatible with Windows PowerShell 5.1 and PowerShell 7+ on Windows 11.
    Requires no third-party modules or dependencies.
.EXAMPLE
    .\PathEditor.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Character Constants (Pure 7-bit ASCII in source, UTF-8 at runtime)
# -----------------------------------------------------------------------------

$C_H     = [string][char]0x2500  # -
$C_V     = [string][char]0x2502  # |
$C_TL    = [string][char]0x250C  # +
$C_TR    = [string][char]0x2510  # +
$C_BL    = [string][char]0x2514  # +
$C_BR    = [string][char]0x2518  # +
$C_ML    = [string][char]0x251C  # +
$C_MR    = [string][char]0x2524  # +
$C_MT    = [string][char]0x252C  # +
$C_MB    = [string][char]0x2534  # +
$C_X     = [string][char]0x253C  # +

$C_DH    = [string][char]0x2550  # =
$C_DV    = [string][char]0x2551  # |
$C_DTL   = [string][char]0x2554  # +
$C_DTR   = [string][char]0x2557  # +
$C_DBL   = [string][char]0x255A  # +
$C_DBR   = [string][char]0x255D  # +

$C_ARROW = [string][char]0x25BA  # >
$C_CHECK = [string][char]0x2714  # OK
$C_DOT   = [string][char]0x25CF  # *
$C_WARN  = [string][char]0x26A0  # !

# -----------------------------------------------------------------------------
# Console & Terminal Utilities
# -----------------------------------------------------------------------------

function Get-ConsoleWidth {
    try {
        if ($host.UI.RawUI.WindowSize.Width -gt 0) { return [Math]::Max(80, $host.UI.RawUI.WindowSize.Width) }
    } catch {}
    try {
        if ([Console]::WindowWidth -gt 0) { return [Math]::Max(80, [Console]::WindowWidth) }
    } catch {}
    return 100
}

function Get-ConsoleHeight {
    try {
        if ($host.UI.RawUI.WindowSize.Height -gt 0) { return [Math]::Max(24, $host.UI.RawUI.WindowSize.Height) }
    } catch {}
    try {
        if ([Console]::WindowHeight -gt 0) { return [Math]::Max(24, [Console]::WindowHeight) }
    } catch {}
    return 30
}

function Set-CursorPositionSafely([int]$x, [int]$y) {
    try {
        [Console]::SetCursorPosition($x, $y)
        return
    } catch {}
    try {
        $pos = New-Object System.Management.Automation.Host.Coordinates($x, $y)
        $host.UI.RawUI.CursorPosition = $pos
        return
    } catch {}
}

function Set-CursorVisibleSafely([bool]$visible) {
    try {
        [Console]::CursorVisible = $visible
    } catch {}
}

function Get-CursorLeftSafely {
    try {
        if ($host.UI.RawUI.CursorPosition) { return $host.UI.RawUI.CursorPosition.X }
    } catch {}
    try {
        return [Console]::CursorLeft
    } catch {}
    return 0
}

function Get-SafeClipboardText {
    try {
        if (Get-Command -Name Get-Clipboard -ErrorAction SilentlyContinue) {
            $clip = Get-Clipboard -Raw -ErrorAction SilentlyContinue
            if ($clip) { return $clip.Trim().Replace("`r", "").Replace("`n", "") }
        }
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ($clip) { return $clip.Trim().Replace("`r", "").Replace("`n", "") }
        }
    } catch {}
    return ""
}

# -----------------------------------------------------------------------------
# Data Model & State
# -----------------------------------------------------------------------------

$script:items = [System.Collections.Generic.List[PSObject]]::new()
$script:originalPaths = [System.Collections.Generic.List[string]]::new()
$script:selectedIndex = 0
$script:scrollOffset = 0
$script:isDirty = $false
$script:focusArea = 'List' # 'List' or 'Buttons'
$script:selectedButtonIndex = 0
$script:notificationMsg = ""
$script:notificationType = "Info" # "Success", "Warn", "Error", "Info"

$script:buttons = @(
    @{ Id = 'save';   Label = 'Save Changes'; ShortLabel = 'Save'; Hotkey = 'S'; Key = [ConsoleKey]::S }
    @{ Id = 'add';    Label = 'Add Entry';    ShortLabel = 'Add';  Hotkey = 'A'; Key = [ConsoleKey]::A }
    @{ Id = 'edit';   Label = 'Edit Entry';   ShortLabel = 'Edit'; Hotkey = 'E'; Key = [ConsoleKey]::E }
    @{ Id = 'delete'; Label = 'Delete Entry'; ShortLabel = 'Del';  Hotkey = 'D'; Key = [ConsoleKey]::D }
    @{ Id = 'reload'; Label = 'Reload';       ShortLabel = 'Reload'; Hotkey = 'R'; Key = [ConsoleKey]::R }
    @{ Id = 'exit';   Label = 'Exit';         ShortLabel = 'Exit'; Hotkey = 'X'; Key = [ConsoleKey]::X }
)

function Load-UserPath {
    $script:items.Clear()
    $script:originalPaths.Clear()
    
    $rawPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
    if (-not [string]::IsNullOrEmpty($rawPath)) {
        $parts = $rawPath.Split(';')
        foreach ($p in $parts) {
            $trimmed = $p.Trim()
            if (-not [string]::IsNullOrEmpty($trimmed)) {
                $script:originalPaths.Add($trimmed)
                $script:items.Add([PSCustomObject]@{
                    Original = $trimmed
                    Current  = $trimmed
                    Status   = 'Unchanged' # 'Unchanged', 'Modified', 'Added', 'Deleted'
                })
            }
        }
    }
    
    $script:isDirty = $false
    $script:selectedIndex = 0
    $script:scrollOffset = 0
}

function Update-DirtyStatus {
    $dirty = $false
    $active = @($script:items | Where-Object { $_.Status -ne 'Deleted' })
    
    if ($active.Count -ne $script:originalPaths.Count) {
        $dirty = $true
    } else {
        for ($i = 0; $i -lt $active.Count; $i++) {
            if ($active[$i].Current -ne $script:originalPaths[$i]) {
                $dirty = $true
                break
            }
        }
    }
    $script:isDirty = $dirty
}

function Save-UserPath {
    $activeItems = @($script:items | Where-Object { $_.Status -ne 'Deleted' })
    $newPathList = @($activeItems | ForEach-Object { $_.Current })
    $newPathString = $newPathList -join ';'
    
    # Save to User environment variable in Windows registry
    [Environment]::SetEnvironmentVariable("Path", $newPathString, [System.EnvironmentVariableTarget]::User)
    
    # Update current session PATH so child commands also inherit it
    # try {
    #     $env:Path = $newPathString
    # } catch {}
    
    # Reload from User environment to verify and show current saved content
    Load-UserPath
    
    $script:notificationMsg = ($C_CHECK + ' Content was saved! (' + $script:items.Count + ' active entries).')
    $script:notificationType = 'Success'
}

# -----------------------------------------------------------------------------
# Drawing Helpers
# -----------------------------------------------------------------------------

function Write-Chunk([string]$text, [ConsoleColor]$fg = [ConsoleColor]::Gray, [ConsoleColor]$bg = [ConsoleColor]::Black) {
    [Console]::ForegroundColor = $fg
    [Console]::BackgroundColor = $bg
    [Console]::Write($text)
}

function Truncate-String([string]$str, [int]$maxLength) {
    if ([string]::IsNullOrEmpty($str)) { return "" }
    if ($str.Length -le $maxLength) { return $str }
    if ($maxLength -le 3) { return $str.Substring(0, [Math]::Max(0, $maxLength)) }
    return $str.Substring(0, $maxLength - 3) + "..."
}

function Pad-RightSafe([string]$str, [int]$totalWidth) {
    if ([string]::IsNullOrEmpty($str)) { return " " * $totalWidth }
    if ($str.Length -ge $totalWidth) { return $str.Substring(0, $totalWidth) }
    return $str + (" " * ($totalWidth - $str.Length))
}

# -----------------------------------------------------------------------------
# Screen Rendering
# -----------------------------------------------------------------------------

function Render-Screen {
    $W = Get-ConsoleWidth
    $H = Get-ConsoleHeight
    
    Set-CursorVisibleSafely $false
    Set-CursorPositionSafely 0 0
    
    $listTop = 5
    $listBottom = $H - 9
    $visibleCount = [Math]::Max(1, ($listBottom - $listTop + 1))
    
    # Keep selection and scroll offset within bounds
    if ($script:items.Count -gt 0) {
        if ($script:selectedIndex -ge $script:items.Count) { $script:selectedIndex = $script:items.Count - 1 }
        if ($script:selectedIndex -lt 0) { $script:selectedIndex = 0 }
        
        if ($script:selectedIndex -lt $script:scrollOffset) {
            $script:scrollOffset = $script:selectedIndex
        }
        if ($script:selectedIndex -ge ($script:scrollOffset + $visibleCount)) {
            $script:scrollOffset = $script:selectedIndex - $visibleCount + 1
        }
    } else {
        $script:selectedIndex = 0
        $script:scrollOffset = 0
    }
    
    # Row 0: Top Border
    Set-CursorPositionSafely 0 0
    Write-Chunk $C_TL 'DarkCyan'
    $titleText = " Windows User PATH Environment Variable Editor "
    Write-Chunk ($C_H * 3) 'DarkCyan'
    Write-Chunk $titleText 'White' 'DarkBlue'
    $remWidth = $W - 2 - 3 - $titleText.Length
    if ($remWidth -gt 0) {
        Write-Chunk ($C_H * $remWidth) 'DarkCyan'
    }
    Write-Chunk $C_TR 'DarkCyan'
    
    # Row 1: Header / Status Bar
    Set-CursorPositionSafely 0 1
    Write-Chunk ($C_V + " ") 'DarkCyan'
    Write-Chunk "Scope: " 'Gray'
    Write-Chunk "User (HKCU\Environment) " 'Cyan'
    Write-Chunk ($C_V + " Status: ") 'DarkCyan'
    
    if ($script:isDirty) {
        Write-Chunk ('[' + $C_DOT + ' UNSAVED CHANGES] ') 'Yellow' 'DarkRed'
    } else {
        Write-Chunk ('[' + $C_CHECK + ' SAVED / CURRENT] ') 'Green' 'Black'
    }
    
    Write-Chunk ($C_V + " Total: ") 'DarkCyan'
    Write-Chunk ([string]$script:items.Count) 'White'
    
    $activeCount = @($script:items | Where-Object { $_.Status -ne 'Deleted' }).Count
    if ($activeCount -ne $script:items.Count) {
        Write-Chunk (' (' + $activeCount + ' active)') 'DarkYellow'
    }
    
    $curX = Get-CursorLeftSafely
    if ($W - 1 - $curX -gt 0) {
        Write-Chunk (" " * ($W - 1 - $curX)) 'Black'
    }
    Set-CursorPositionSafely ($W - 1) 1
    Write-Chunk $C_V 'DarkCyan'
    
    # Row 2: Header Divider
    Set-CursorPositionSafely 0 2
    Write-Chunk ($C_ML + ($C_H * 6) + $C_MT + ($C_H * 10) + $C_MT) 'DarkCyan'
    Write-Chunk ($C_H * ($W - 20)) 'DarkCyan'
    Write-Chunk $C_MR 'DarkCyan'
    
    # Row 3: Column Headers
    Set-CursorPositionSafely 0 3
    Write-Chunk ($C_V + "  #   " + $C_V + "  STATUS  " + $C_V + " ") 'DarkCyan'
    $pathColHeader = "PATH ENTRY VALUE"
    Write-Chunk $pathColHeader 'White'
    $pathHeaderPad = $W - 21 - $pathColHeader.Length
    if ($pathHeaderPad -gt 0) {
        Write-Chunk (" " * $pathHeaderPad) 'Black'
    }
    Set-CursorPositionSafely ($W - 1) 3
    Write-Chunk $C_V 'DarkCyan'
    
    # Row 4: List Divider
    Set-CursorPositionSafely 0 4
    Write-Chunk ($C_ML + ($C_H * 6) + $C_X + ($C_H * 10) + $C_X) 'DarkCyan'
    Write-Chunk ($C_H * ($W - 20)) 'DarkCyan'
    Write-Chunk $C_MR 'DarkCyan'
    
    # Rows 5..$listBottom: List Items
    $pathColWidth = $W - 21
    for ($row = 0; $row -lt $visibleCount; $row++) {
        $itemIndex = $script:scrollOffset + $row
        $lineY = $listTop + $row
        Set-CursorPositionSafely 0 $lineY
        
        if ($itemIndex -lt $script:items.Count) {
            $item = $script:items[$itemIndex]
            $isSelected = ($itemIndex -eq $script:selectedIndex) -and ($script:focusArea -eq 'List')
            $isRowSelected = ($itemIndex -eq $script:selectedIndex)
            
            $lineBg = if ($isSelected) { 'DarkBlue' } elseif ($isRowSelected) { 'DarkMagenta' } else { 'Black' }
            
            $statusText = "  [UNC]   "
            $statusFg = 'DarkGray'
            $pathFg = 'Gray'
            
            switch ($item.Status) {
                'Added' {
                    $statusText = "  [ADD]   "
                    $statusFg   = 'Green'
                    $pathFg     = 'Green'
                }
                'Modified' {
                    $statusText = "  [MOD]   "
                    $statusFg   = 'Yellow'
                    $pathFg     = 'Yellow'
                }
                'Deleted' {
                    $statusText = "  [DEL]   "
                    $statusFg   = 'Red'
                    $pathFg     = 'DarkRed'
                }
                default {
                    $statusText = "  [UNC]   "
                    $statusFg   = 'DarkGray'
                    $pathFg     = if ($isSelected) { 'White' } else { 'Gray' }
                }
            }
            
            Write-Chunk $C_V 'DarkCyan' 'Black'
            
            $prefix = if ($isSelected) { $C_ARROW } elseif ($isRowSelected) { ">" } else { " " }
            $indexStr = '{0}{1:D2}   ' -f $prefix, ($itemIndex + 1)
            $indexFg = if ($isSelected) { 'Cyan' } else { 'DarkGray' }
            Write-Chunk $indexStr $indexFg $lineBg
            
            Write-Chunk $C_V 'DarkCyan' 'Black'
            Write-Chunk $statusText $statusFg $lineBg
            Write-Chunk $C_V 'DarkCyan' 'Black'
            
            $displayPath = Truncate-String $item.Current ($pathColWidth - 1)
            $paddedPath = Pad-RightSafe (" " + $displayPath) $pathColWidth
            Write-Chunk $paddedPath $pathFg $lineBg
            
            Set-CursorPositionSafely ($W - 1) $lineY
            Write-Chunk $C_V 'DarkCyan' 'Black'
        } else {
            Write-Chunk ($C_V + "      " + $C_V + "          " + $C_V) 'DarkCyan' 'Black'
            if ($script:items.Count -eq 0 -and $row -eq 2) {
                $emptyMsg = " (No entries in User PATH. Press 'A' to add a new directory.)"
                Write-Chunk (Pad-RightSafe $emptyMsg $pathColWidth) 'DarkYellow' 'Black'
            } else {
                Write-Chunk (" " * $pathColWidth) 'Black' 'Black'
            }
            Set-CursorPositionSafely ($W - 1) $lineY
            Write-Chunk $C_V 'DarkCyan' 'Black'
        }
    }
    
    # Divider above Inspector
    Set-CursorPositionSafely 0 ($H - 8)
    Write-Chunk ($C_ML + ($C_H * 6) + $C_MB + ($C_H * 10) + $C_MB) 'DarkCyan'
    Write-Chunk ($C_H * ($W - 20)) 'DarkCyan'
    Write-Chunk $C_MR 'DarkCyan'
    
    # Detail Inspector Line 1 (Row H - 7): Full path
    Set-CursorPositionSafely 0 ($H - 7)
    Write-Chunk ($C_V + " ") 'DarkCyan'
    if ($script:items.Count -gt 0 -and $script:selectedIndex -lt $script:items.Count) {
        $selItem = $script:items[$script:selectedIndex]
        $label = 'Selected [{0}/{1}]: ' -f ($script:selectedIndex + 1), $script:items.Count
        Write-Chunk $label 'Cyan'
        
        $avail = $W - 3 - $label.Length
        $shownPath = Truncate-String $selItem.Current $avail
        $color = switch ($selItem.Status) {
            'Added'    { 'Green' }
            'Modified' { 'Yellow' }
            'Deleted'  { 'Red' }
            default    { 'White' }
        }
        Write-Chunk $shownPath $color
        $curX = Get-CursorLeftSafely
        if ($W - 1 - $curX -gt 0) { Write-Chunk (" " * ($W - 1 - $curX)) 'Black' }
    } else {
        Write-Chunk (Pad-RightSafe "No entry selected." ($W - 3)) 'DarkGray'
    }
    Set-CursorPositionSafely ($W - 1) ($H - 7)
    Write-Chunk $C_V 'DarkCyan'
    
    # Detail Inspector Line 2 (Row H - 6): Status & Disk Existence
    Set-CursorPositionSafely 0 ($H - 6)
    Write-Chunk ($C_V + " ") 'DarkCyan'
    if ($script:items.Count -gt 0 -and $script:selectedIndex -lt $script:items.Count) {
        $selItem = $script:items[$script:selectedIndex]
        
        Write-Chunk "Status: " 'Gray'
        switch ($selItem.Status) {
            'Added' {
                Write-Chunk "ADDED (New Entry) " 'Green'
            }
            'Modified' {
                Write-Chunk "MODIFIED " 'Yellow'
                if ($selItem.Original) {
                    $origShort = Truncate-String $selItem.Original 30
                    Write-Chunk ('(Original: ' + $origShort + ') ') 'DarkYellow'
                }
            }
            'Deleted' {
                Write-Chunk "MARKED FOR DELETION (will be removed on Save) " 'Red'
            }
            default {
                Write-Chunk "UNCHANGED " 'Gray'
            }
        }
        
        Write-Chunk ($C_V + " On Disk: ") 'DarkCyan'
        $expanded = [Environment]::ExpandEnvironmentVariables($selItem.Current)
        if (Test-Path -LiteralPath $expanded) {
            Write-Chunk "YES (Directory exists) " 'Green'
        } else {
            Write-Chunk "NO (Folder not found) " 'Red'
        }
        
        $curX = Get-CursorLeftSafely
        if ($W - 1 - $curX -gt 0) { Write-Chunk (" " * ($W - 1 - $curX)) 'Black' }
    } else {
        Write-Chunk (Pad-RightSafe "" ($W - 3)) 'Black'
    }
    Set-CursorPositionSafely ($W - 1) ($H - 6)
    Write-Chunk $C_V 'DarkCyan'
    
    # Divider above Buttons
    Set-CursorPositionSafely 0 ($H - 5)
    Write-Chunk $C_ML 'DarkCyan'
    Write-Chunk ($C_H * ($W - 2)) 'DarkCyan'
    Write-Chunk $C_MR 'DarkCyan'
    
    # Row H - 4: Interactive Button Bar
    Set-CursorPositionSafely 0 ($H - 4)
    Write-Chunk ($C_V + " ") 'DarkCyan'
    
    for ($b = 0; $b -lt $script:buttons.Count; $b++) {
        $btn = $script:buttons[$b]
        $isBtnFocused = ($script:focusArea -eq 'Buttons') -and ($b -eq $script:selectedButtonIndex)
        $btnText = if ($W -ge 105) { $btn.Label } else { $btn.ShortLabel }
        
        if ($isBtnFocused) {
            Write-Chunk ($C_ARROW + "[") 'Yellow' 'DarkGray'
            Write-Chunk $btn.Hotkey 'White' 'DarkGray'
            Write-Chunk (": " + $btnText + "]" + $C_ARROW + " ") 'Yellow' 'DarkGray'
        } else {
            Write-Chunk "[ " 'DarkGray' 'Black'
            Write-Chunk $btn.Hotkey 'Yellow' 'Black'
            Write-Chunk (": " + $btnText + " ] ") 'White' 'Black'
        }
    }
    $curX = Get-CursorLeftSafely
    if ($W - 1 - $curX -gt 0) { Write-Chunk (" " * ($W - 1 - $curX)) 'Black' }
    Set-CursorPositionSafely ($W - 1) ($H - 4)
    Write-Chunk $C_V 'DarkCyan'
    
    # Row H - 3: Navigation Keyboard Shortcuts
    Set-CursorPositionSafely 0 ($H - 3)
    Write-Chunk ($C_V + " ") 'DarkCyan'
    $helpTips = "[Arrows] Select  [Enter/E] Edit  [A] Add  [D] Delete  [Alt+Up/Dn] Move  [Tab] Focus Buttons  [S] Save  [X/Q] Exit"
    Write-Chunk (Pad-RightSafe $helpTips ($W - 3)) 'DarkGray'
    Set-CursorPositionSafely ($W - 1) ($H - 3)
    Write-Chunk $C_V 'DarkCyan'
    
    # Row H - 2: Notification / Message Bar
    Set-CursorPositionSafely 0 ($H - 2)
    Write-Chunk ($C_V + " ") 'DarkCyan'
    if (-not [string]::IsNullOrEmpty($script:notificationMsg)) {
        $nFg = 'White'
        $nBg = switch ($script:notificationType) {
            'Success' { 'DarkGreen' }
            'Warn'    { 'DarkYellow' }
            'Error'   { 'DarkRed' }
            default   { 'DarkBlue' }
        }
        $msgText = " " + $script:notificationMsg + " "
        Write-Chunk (Pad-RightSafe $msgText ($W - 3)) $nFg $nBg
    } else {
        $statusSummary = if ($script:isDirty) {
            (' ' + $C_DOT + ' You have unsaved changes. Press ''S'' to Save or ''X'' to Exit.')
        } else {
            (' ' + $C_CHECK + ' User PATH is up to date.')
        }
        $sFg = if ($script:isDirty) { 'Yellow' } else { 'DarkGreen' }
        Write-Chunk (Pad-RightSafe $statusSummary ($W - 3)) $sFg 'Black'
    }
    Set-CursorPositionSafely ($W - 1) ($H - 2)
    Write-Chunk $C_V 'DarkCyan'
    
    # Row H - 1: Bottom Border
    Set-CursorPositionSafely 0 ($H - 1)
    Write-Chunk $C_BL 'DarkCyan'
    Write-Chunk ($C_H * ($W - 2)) 'DarkCyan'
    Write-Chunk $C_BR 'DarkCyan'
}

# -----------------------------------------------------------------------------
# Modal Dialogs & Line Editor
# -----------------------------------------------------------------------------

function Read-ModalTextInput {
    param(
        [string]$Title,
        [string]$InitialValue = "",
        [string]$SubTitle = "Folder path:"
    )
    
    $W = Get-ConsoleWidth
    $H = Get-ConsoleHeight
    
    $boxW = [Math]::Min([Math]::Max(70, [int]($W * 0.75)), $W - 4)
    $boxH = 8
    $boxX = [int](($W - $boxW) / 2)
    $boxY = [int](($H - $boxH) / 2)
    
    $buffer = [System.Collections.Generic.List[char]]::new()
    if ($InitialValue) {
        foreach ($ch in $InitialValue.ToCharArray()) { $buffer.Add($ch) }
    }
    $cursorIndex = $buffer.Count
    
    $inputAreaWidth = $boxW - 6
    $inputScroll = 0
    
    $done = $false
    $result = $null
    
    while (-not $done) {
        if ($cursorIndex -lt $inputScroll) {
            $inputScroll = $cursorIndex
        }
        if ($cursorIndex -ge ($inputScroll + $inputAreaWidth)) {
            $inputScroll = $cursorIndex - $inputAreaWidth + 1
        }
        
        # Top border
        Set-CursorPositionSafely $boxX $boxY
        Write-Chunk $C_DTL 'Yellow' 'DarkBlue'
        $titleFormatted = " " + $Title + " "
        Write-Chunk $titleFormatted 'White' 'DarkBlue'
        $padTop = $boxW - 2 - $titleFormatted.Length
        if ($padTop -gt 0) { Write-Chunk ($C_DH * $padTop) 'Yellow' 'DarkBlue' }
        Write-Chunk $C_DTR 'Yellow' 'DarkBlue'
        
        # Line 1: Subtitle
        Set-CursorPositionSafely $boxX ($boxY + 1)
        Write-Chunk ($C_DV + " ") 'Yellow' 'DarkBlue'
        Write-Chunk (Pad-RightSafe $SubTitle ($boxW - 4)) 'Cyan' 'DarkBlue'
        Write-Chunk (" " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Line 2: Input box border top
        Set-CursorPositionSafely $boxX ($boxY + 2)
        Write-Chunk ($C_DV + " " + $C_TL) 'Yellow' 'DarkBlue'
        Write-Chunk ($C_H * ($boxW - 6)) 'White' 'DarkBlue'
        Write-Chunk ($C_TR + " " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Line 3: Input content
        Set-CursorPositionSafely $boxX ($boxY + 3)
        Write-Chunk ($C_DV + " " + $C_V) 'Yellow' 'DarkBlue'
        
        $fullText = -join $buffer
        $visibleChars = ""
        if ($fullText.Length -gt $inputScroll) {
            $len = [Math]::Min($fullText.Length - $inputScroll, $inputAreaWidth)
            $visibleChars = $fullText.Substring($inputScroll, $len)
        }
        $paddedInput = Pad-RightSafe $visibleChars $inputAreaWidth
        Write-Chunk $paddedInput 'White' 'Black'
        Write-Chunk ($C_V + " " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Line 4: Input box border bottom
        Set-CursorPositionSafely $boxX ($boxY + 4)
        Write-Chunk ($C_DV + " " + $C_BL) 'Yellow' 'DarkBlue'
        Write-Chunk ($C_H * ($boxW - 6)) 'White' 'DarkBlue'
        Write-Chunk ($C_BR + " " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Line 5: Disk Check Status
        Set-CursorPositionSafely $boxX ($boxY + 5)
        Write-Chunk ($C_DV + " ") 'Yellow' 'DarkBlue'
        $expanded = [Environment]::ExpandEnvironmentVariables($fullText.Trim())
        $diskInfo = if ([string]::IsNullOrEmpty($fullText.Trim())) {
            "Status: Enter a non-empty directory path"
        } elseif (Test-Path -LiteralPath $expanded) {
            ("Status: " + $C_CHECK + " Folder exists on disk")
        } else {
            ("Status: " + $C_WARN + " Folder does not currently exist on disk")
        }
        $statusFg = if ($diskInfo -like ("*" + $C_CHECK + "*")) { 'Green' } elseif ($diskInfo -like ("*" + $C_WARN + "*")) { 'Yellow' } else { 'Gray' }
        Write-Chunk (Pad-RightSafe $diskInfo ($boxW - 4)) $statusFg 'DarkBlue'
        Write-Chunk (" " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Line 6: Instructions
        Set-CursorPositionSafely $boxX ($boxY + 6)
        Write-Chunk ($C_DV + " ") 'Yellow' 'DarkBlue'
        $tip = "[Enter] Confirm   [Esc] Cancel   [Ctrl+V] Paste"
        Write-Chunk (Pad-RightSafe $tip ($boxW - 4)) 'Gray' 'DarkBlue'
        Write-Chunk (" " + $C_DV) 'Yellow' 'DarkBlue'
        
        # Bottom border
        Set-CursorPositionSafely $boxX ($boxY + 7)
        Write-Chunk $C_DBL 'Yellow' 'DarkBlue'
        Write-Chunk ($C_DH * ($boxW - 2)) 'Yellow' 'DarkBlue'
        Write-Chunk $C_DBR 'Yellow' 'DarkBlue'
        
        # Position cursor inside the input field
        $renderCursorX = $boxX + 3 + ($cursorIndex - $inputScroll)
        Set-CursorPositionSafely $renderCursorX ($boxY + 3)
        Set-CursorVisibleSafely $true
        
        $key = [Console]::ReadKey($true)
        
        switch ($key.Key) {
            ([ConsoleKey]::Enter) {
                $result = (-join $buffer).Trim()
                $done = $true
            }
            ([ConsoleKey]::Escape) {
                $result = $null
                $done = $true
            }
            ([ConsoleKey]::Backspace) {
                if ($cursorIndex -gt 0) {
                    $buffer.RemoveAt($cursorIndex - 1)
                    $cursorIndex--
                }
            }
            ([ConsoleKey]::Delete) {
                if ($cursorIndex -lt $buffer.Count) {
                    $buffer.RemoveAt($cursorIndex)
                }
            }
            ([ConsoleKey]::LeftArrow) {
                if ($cursorIndex -gt 0) { $cursorIndex-- }
            }
            ([ConsoleKey]::RightArrow) {
                if ($cursorIndex -lt $buffer.Count) { $cursorIndex++ }
            }
            ([ConsoleKey]::Home) {
                $cursorIndex = 0
            }
            ([ConsoleKey]::End) {
                $cursorIndex = $buffer.Count
            }
            default {
                $isCtrlV = ($key.Key -eq [ConsoleKey]::V -and ($key.Modifiers -band [ConsoleModifiers]::Control)) -or ($key.KeyChar -eq [char]22)
                if ($isCtrlV) {
                    $pasteText = Get-SafeClipboardText
                    if (-not [string]::IsNullOrEmpty($pasteText)) {
                        foreach ($pChar in $pasteText.ToCharArray()) {
                            $buffer.Insert($cursorIndex, $pChar)
                            $cursorIndex++
                        }
                    }
                } elseif (-not [char]::IsControl($key.KeyChar)) {
                    $buffer.Insert($cursorIndex, $key.KeyChar)
                    $cursorIndex++
                }
            }
        }
    }
    
    Set-CursorVisibleSafely $false
    return $result
}

function Show-ConfirmExitModal {
    $W = Get-ConsoleWidth
    $H = Get-ConsoleHeight
    
    $boxW = 66
    $boxH = 7
    $boxX = [int](($W - $boxW) / 2)
    $boxY = [int](($H - $boxH) / 2)
    
    Set-CursorPositionSafely $boxX $boxY
    Write-Chunk $C_DTL 'Red' 'DarkRed'
    Write-Chunk " UNSAVED CHANGES WARNING " 'White' 'DarkRed'
    Write-Chunk ($C_DH * ($boxW - 27)) 'Red' 'DarkRed'
    Write-Chunk $C_DTR 'Red' 'DarkRed'
    
    Set-CursorPositionSafely $boxX ($boxY + 1)
    Write-Chunk ($C_DV + " ") 'Red' 'Black'
    Write-Chunk (Pad-RightSafe "You have unsaved changes in your User PATH variable!" ($boxW - 4)) 'Yellow' 'Black'
    Write-Chunk (" " + $C_DV) 'Red' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 2)
    Write-Chunk ($C_DV + " ") 'Red' 'Black'
    Write-Chunk (Pad-RightSafe "What would you like to do before exiting?" ($boxW - 4)) 'White' 'Black'
    Write-Chunk (" " + $C_DV) 'Red' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 3)
    Write-Chunk ($C_DV + " ") 'Red' 'Black'
    Write-Chunk (Pad-RightSafe "  [S] Save Changes and Exit" ($boxW - 4)) 'Green' 'Black'
    Write-Chunk (" " + $C_DV) 'Red' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 4)
    Write-Chunk ($C_DV + " ") 'Red' 'Black'
    Write-Chunk (Pad-RightSafe "  [D] Discard Changes and Exit Without Saving" ($boxW - 4)) 'Red' 'Black'
    Write-Chunk (" " + $C_DV) 'Red' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 5)
    Write-Chunk ($C_DV + " ") 'Red' 'Black'
    Write-Chunk (Pad-RightSafe "  [C / Esc] Cancel and Return to Editor" ($boxW - 4)) 'Cyan' 'Black'
    Write-Chunk (" " + $C_DV) 'Red' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 6)
    Write-Chunk $C_DBL 'Red' 'DarkRed'
    Write-Chunk ($C_DH * ($boxW - 2)) 'Red' 'DarkRed'
    Write-Chunk $C_DBR 'Red' 'DarkRed'
    
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::S) { return 'SaveAndExit' }
        if ($k.Key -eq [ConsoleKey]::D) { return 'DiscardAndExit' }
        if ($k.Key -eq [ConsoleKey]::C -or $k.Key -eq [ConsoleKey]::Escape) { return 'Cancel' }
    }
}

function Show-ConfirmReloadModal {
    $W = Get-ConsoleWidth
    $H = Get-ConsoleHeight
    
    $boxW = 60
    $boxH = 6
    $boxX = [int](($W - $boxW) / 2)
    $boxY = [int](($H - $boxH) / 2)
    
    Set-CursorPositionSafely $boxX $boxY
    Write-Chunk $C_DTL 'Yellow' 'DarkBlue'
    Write-Chunk " CONFIRM DISCARD & RELOAD " 'White' 'DarkBlue'
    Write-Chunk ($C_DH * ($boxW - 28)) 'Yellow' 'DarkBlue'
    Write-Chunk $C_DTR 'Yellow' 'DarkBlue'
    
    Set-CursorPositionSafely $boxX ($boxY + 1)
    Write-Chunk ($C_DV + " ") 'Yellow' 'Black'
    Write-Chunk (Pad-RightSafe "Discard all unsaved changes and reload from registry?" ($boxW - 4)) 'Yellow' 'Black'
    Write-Chunk (" " + $C_DV) 'Yellow' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 2)
    Write-Chunk ($C_DV + " ") 'Yellow' 'Black'
    Write-Chunk (Pad-RightSafe "  [Y] Yes, Reload (Discard changes)" ($boxW - 4)) 'Red' 'Black'
    Write-Chunk (" " + $C_DV) 'Yellow' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 3)
    Write-Chunk ($C_DV + " ") 'Yellow' 'Black'
    Write-Chunk (Pad-RightSafe "  [N / Esc] No, Cancel" ($boxW - 4)) 'Green' 'Black'
    Write-Chunk (" " + $C_DV) 'Yellow' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 4)
    Write-Chunk ($C_DV + " ") 'Yellow' 'Black'
    Write-Chunk (Pad-RightSafe "" ($boxW - 4)) 'Black' 'Black'
    Write-Chunk (" " + $C_DV) 'Yellow' 'Black'
    
    Set-CursorPositionSafely $boxX ($boxY + 5)
    Write-Chunk $C_DBL 'Yellow' 'DarkBlue'
    Write-Chunk ($C_DH * ($boxW - 2)) 'Yellow' 'DarkBlue'
    Write-Chunk $C_DBR 'Yellow' 'DarkBlue'
    
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Y) { return $true }
        if ($k.Key -eq [ConsoleKey]::N -or $k.Key -eq [ConsoleKey]::Escape) { return $false }
    }
}

# -----------------------------------------------------------------------------
# Action Handlers
# -----------------------------------------------------------------------------

function Invoke-ActionAdd {
    $newPath = Read-ModalTextInput -Title "Add New PATH Entry" -InitialValue "" -SubTitle "Enter directory path to append to User PATH:"
    if (-not [string]::IsNullOrEmpty($newPath)) {
        $newItem = [PSCustomObject]@{
            Original = $null
            Current  = $newPath
            Status   = 'Added'
        }
        $script:items.Add($newItem)
        $script:selectedIndex = $script:items.Count - 1
        Update-DirtyStatus
        $script:notificationMsg = ($C_CHECK + ' Added new path entry: ' + $newPath)
        $script:notificationType = 'Success'
    }
}

function Invoke-ActionEdit {
    if ($script:items.Count -eq 0 -or $script:selectedIndex -ge $script:items.Count) { return }
    $item = $script:items[$script:selectedIndex]
    
    if ($item.Status -eq 'Deleted') {
        $script:notificationMsg = ($C_WARN + " Item is marked for deletion. Press 'D' to undelete before editing.")
        $script:notificationType = "Warn"
        return
    }
    
    $editTitle = 'Edit PATH Entry (#{0})' -f ($script:selectedIndex + 1)
    $edited = Read-ModalTextInput -Title $editTitle -InitialValue $item.Current -SubTitle "Modify directory path:"
    if ($null -ne $edited) {
        if ($edited -ne $item.Current) {
            $item.Current = $edited
            if ($item.Original) {
                if ($item.Current -eq $item.Original) {
                    $item.Status = 'Unchanged'
                } else {
                    $item.Status = 'Modified'
                }
            } else {
                $item.Status = 'Added'
            }
            Update-DirtyStatus
            $script:notificationMsg = ($C_CHECK + ' Updated entry #' + ($script:selectedIndex + 1))
            $script:notificationType = 'Success'
        }
    }
}

function Invoke-ActionDelete {
    if ($script:items.Count -eq 0 -or $script:selectedIndex -ge $script:items.Count) { return }
    $item = $script:items[$script:selectedIndex]
    
    if ($item.Status -eq 'Deleted') {
        if ($item.Original) {
            if ($item.Current -eq $item.Original) {
                $item.Status = 'Unchanged'
            } else {
                $item.Status = 'Modified'
            }
        } else {
            $item.Status = 'Added'
        }
        $script:notificationMsg = ($C_CHECK + ' Restored entry #' + ($script:selectedIndex + 1))
        $script:notificationType = 'Info'
    } elseif ($item.Status -eq 'Added') {
        $script:items.RemoveAt($script:selectedIndex)
        if ($script:selectedIndex -ge $script:items.Count -and $script:items.Count -gt 0) {
            $script:selectedIndex = $script:items.Count - 1
        }
        $script:notificationMsg = "Removed newly added entry."
        $script:notificationType = "Info"
    } else {
        $item.Status = 'Deleted'
        $script:notificationMsg = ('Marked entry #' + ($script:selectedIndex + 1) + " for deletion (Press 'D' to undo, 'S' to save).")
        $script:notificationType = "Warn"
    }
    Update-DirtyStatus
}

function Invoke-ActionMoveUp {
    if ($script:selectedIndex -gt 0 -and $script:items.Count -gt 1) {
        $idx = $script:selectedIndex
        $temp = $script:items[$idx]
        $script:items[$idx] = $script:items[$idx - 1]
        $script:items[$idx - 1] = $temp
        $script:selectedIndex--
        Update-DirtyStatus
        $script:notificationMsg = ('Moved entry #' + ($idx + 1) + ' up.')
        $script:notificationType = 'Info'
    }
}

function Invoke-ActionMoveDown {
    if ($script:selectedIndex -lt ($script:items.Count - 1) -and $script:items.Count -gt 1) {
        $idx = $script:selectedIndex
        $temp = $script:items[$idx]
        $script:items[$idx] = $script:items[$idx + 1]
        $script:items[$idx + 1] = $temp
        $script:selectedIndex++
        Update-DirtyStatus
        $script:notificationMsg = ('Moved entry #' + ($idx + 1) + ' down.')
        $script:notificationType = 'Info'
    }
}

function Invoke-ActionReload {
    if ($script:isDirty) {
        $confirm = Show-ConfirmReloadModal
        if (-not $confirm) { return }
    }
    Load-UserPath
    $script:notificationMsg = ($C_CHECK + ' Reloaded User PATH from registry (' + $script:items.Count + ' entries).')
    $script:notificationType = 'Success'
}

# -----------------------------------------------------------------------------
# Main Application Loop
# -----------------------------------------------------------------------------

function Start-PathEditor {
    $origEncoding = [Console]::OutputEncoding
    $origCursor = $true
    try { $origCursor = [Console]::CursorVisible } catch {}
    
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::Clear()
        
        Load-UserPath
        
        $running = $true
        $prevW = Get-ConsoleWidth
        $prevH = Get-ConsoleHeight
        
        while ($running) {
            $curW = Get-ConsoleWidth
            $curH = Get-ConsoleHeight
            if ($curW -ne $prevW -or $curH -ne $prevH) {
                [Console]::Clear()
                $prevW = $curW
                $prevH = $curH
            }
            
            Render-Screen
            
            $key = [Console]::ReadKey($true)
            
            $hadNotification = (-not [string]::IsNullOrEmpty($script:notificationMsg))
            $clearNotificationOnNext = $true
            
            # Global Hotkeys
            $isCtrlS = ($key.Key -eq [ConsoleKey]::S -and ($key.Modifiers -band [ConsoleModifiers]::Control)) -or ($key.KeyChar -eq [char]19)
            if ($isCtrlS) {
                Save-UserPath
                $clearNotificationOnNext = $false
                continue
            }
            
            # Reordering with Alt+Up / Alt+Down
            if ($key.Key -eq [ConsoleKey]::UpArrow -and ($key.Modifiers -band [ConsoleModifiers]::Alt)) {
                Invoke-ActionMoveUp
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::DownArrow -and ($key.Modifiers -band [ConsoleModifiers]::Alt)) {
                Invoke-ActionMoveDown
                $clearNotificationOnNext = $false
                continue
            }
            
            # Tab / Shift+Tab toggles focus between List and Buttons
            if ($key.Key -eq [ConsoleKey]::Tab) {
                if ($key.Modifiers -band [ConsoleModifiers]::Shift) {
                    if ($script:focusArea -eq 'Buttons') {
                        if ($script:selectedButtonIndex -gt 0) {
                            $script:selectedButtonIndex--
                        } else {
                            $script:focusArea = 'List'
                        }
                    } else {
                        $script:focusArea = 'Buttons'
                        $script:selectedButtonIndex = $script:buttons.Count - 1
                    }
                } else {
                    if ($script:focusArea -eq 'List') {
                        $script:focusArea = 'Buttons'
                        $script:selectedButtonIndex = 0
                    } else {
                        if ($script:selectedButtonIndex -lt ($script:buttons.Count - 1)) {
                            $script:selectedButtonIndex++
                        } else {
                            $script:focusArea = 'List'
                        }
                    }
                }
                continue
            }
            
            # Direct Action Hotkeys (work anywhere in main screen)
            if ($key.Key -eq [ConsoleKey]::S) {
                Save-UserPath
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::A -or $key.Key -eq [ConsoleKey]::Insert) {
                Invoke-ActionAdd
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::E) {
                Invoke-ActionEdit
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::D -or $key.Key -eq [ConsoleKey]::Delete) {
                Invoke-ActionDelete
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::R) {
                Invoke-ActionReload
                $clearNotificationOnNext = $false
                continue
            }
            if ($key.Key -eq [ConsoleKey]::X -or $key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
                if ($script:isDirty) {
                    $choice = Show-ConfirmExitModal
                    if ($choice -eq 'SaveAndExit') {
                        Save-UserPath
                        $running = $false
                    } elseif ($choice -eq 'DiscardAndExit') {
                        $running = $false
                    }
                } else {
                    $running = $false
                }
                continue
            }
            
            # Focus-specific navigation
            if ($script:focusArea -eq 'List') {
                switch ($key.Key) {
                    ([ConsoleKey]::UpArrow) {
                        if ($script:selectedIndex -gt 0) { $script:selectedIndex-- }
                    }
                    ([ConsoleKey]::DownArrow) {
                        if ($script:selectedIndex -lt ($script:items.Count - 1)) {
                            $script:selectedIndex++
                        } else {
                            $script:focusArea = 'Buttons'
                            $script:selectedButtonIndex = 0
                        }
                    }
                    ([ConsoleKey]::PageUp) {
                        $pageSize = [Math]::Max(5, (Get-ConsoleHeight) - 14)
                        $script:selectedIndex = [Math]::Max(0, $script:selectedIndex - $pageSize)
                    }
                    ([ConsoleKey]::PageDown) {
                        $pageSize = [Math]::Max(5, (Get-ConsoleHeight) - 14)
                        $script:selectedIndex = [Math]::Min([Math]::Max(0, $script:items.Count - 1), $script:selectedIndex + $pageSize)
                    }
                    ([ConsoleKey]::Home) {
                        $script:selectedIndex = 0
                    }
                    ([ConsoleKey]::End) {
                        if ($script:items.Count -gt 0) { $script:selectedIndex = $script:items.Count - 1 }
                    }
                    ([ConsoleKey]::Enter) {
                        Invoke-ActionEdit
                        $clearNotificationOnNext = $false
                    }
                }
            } elseif ($script:focusArea -eq 'Buttons') {
                switch ($key.Key) {
                    ([ConsoleKey]::LeftArrow) {
                        if ($script:selectedButtonIndex -gt 0) {
                            $script:selectedButtonIndex--
                        } else {
                            $script:selectedButtonIndex = $script:buttons.Count - 1
                        }
                    }
                    ([ConsoleKey]::RightArrow) {
                        if ($script:selectedButtonIndex -lt ($script:buttons.Count - 1)) {
                            $script:selectedButtonIndex++
                        } else {
                            $script:selectedButtonIndex = 0
                        }
                    }
                    ([ConsoleKey]::UpArrow) {
                        $script:focusArea = 'List'
                    }
                    { $_ -in [ConsoleKey]::Enter, [ConsoleKey]::Spacebar } {
                        $curBtn = $script:buttons[$script:selectedButtonIndex]
                        switch ($curBtn.Id) {
                            'save'   { Save-UserPath; $clearNotificationOnNext = $false }
                            'add'    { Invoke-ActionAdd; $clearNotificationOnNext = $false }
                            'edit'   { Invoke-ActionEdit; $clearNotificationOnNext = $false }
                            'delete' { Invoke-ActionDelete; $clearNotificationOnNext = $false }
                            'reload' { Invoke-ActionReload; $clearNotificationOnNext = $false }
                            'exit'   {
                                if ($script:isDirty) {
                                    $choice = Show-ConfirmExitModal
                                    if ($choice -eq 'SaveAndExit') {
                                        Save-UserPath
                                        $running = $false
                                    } elseif ($choice -eq 'DiscardAndExit') {
                                        $running = $false
                                    }
                                } else {
                                    $running = $false
                                }
                            }
                        }
                    }
                }
            }
            
            if ($hadNotification -and $clearNotificationOnNext) {
                $script:notificationMsg = ""
            }
        }
    } finally {
        try { [Console]::OutputEncoding = $origEncoding } catch {}
        try { [Console]::CursorVisible = $origCursor } catch {}
        try { [Console]::ResetColor() } catch {}
        try { [Console]::Clear() } catch {}
        Write-Host "Windows User PATH Editor closed." -ForegroundColor Cyan
    }
}

# Run editor if script invoked directly
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s+') {
    Start-PathEditor
}
