<#
.SYNOPSIS
    A modern terminal UI that shows detailed information about every key you press.

.DESCRIPTION
    ShowKey listens to raw console keyboard input and displays everything Windows
    reports about each key stroke:

      * Friendly key name, keyboard-layout key name and key category
      * Virtual-key code (decimal / hex), VK_ constant and .NET [ConsoleKey] name
      * Hardware scan code (including the E0 "extended" prefix)
      * Physical key code (W3C KeyboardEvent.code style, e.g. KeyA, ShiftLeft)
      * Key location (Standard, Left, Right, Numpad)
      * Key state (pressed / released), auto-repeat count and record repeat count
      * How long the key was held and the time since the previous event
      * Modifier keys (Shift, Ctrl, Alt, Win - left and right) and lock keys
      * The produced character: glyph, Unicode code point and category, ASCII,
        UTF-8 and UTF-16 encodings, HTML entity and PowerShell literal
      * Raw console control-key-state flags
      * A scrolling history of recent key events

    Input is read with the Win32 ReadConsoleInput API, so key releases, scan codes
    and left/right modifiers are reported, which [Console]::ReadKey cannot do.

    Press Esc twice in a row to quit. Every other key (including Ctrl+C) is shown
    instead of being acted upon.

.PARAMETER HistorySize
    Maximum number of key events kept in the history list. Default: 200.

.PARAMETER NoKeyUp
    Ignore key release events. Only key presses are shown and added to the history.

.PARAMETER NoColor
    Disable colors. Colors are also disabled when the NO_COLOR environment
    variable is set.

.PARAMETER Version
    Print the version number and exit.

.PARAMETER Help
    Print this help message and exit.

.EXAMPLE
    .\ShowKey.ps1

    Starts the key viewer. Press Esc twice to quit.

.EXAMPLE
    .\ShowKey.ps1 -NoKeyUp -HistorySize 50

    Shows key presses only and keeps the last 50 events.

.EXAMPLE
    .\ShowKey.ps1 -Version

    Prints the version number.

.NOTES
    Name    : ShowKey.ps1
    Version : 0.1.0
    Requires: Windows, PowerShell 5.1 or PowerShell 7+, an interactive console
              (Windows Terminal, the classic console host or the VS Code terminal).
    Some key combinations are taken by Windows or by the terminal before they
    reach the console (for example Win+L, Alt+Tab, or Windows Terminal shortcuts
    such as Ctrl+Shift+T) and therefore cannot be shown.

.LINK
    https://learn.microsoft.com/windows/console/readconsoleinput
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10, 10000)]
    [int] $HistorySize = 200,

    [switch] $NoKeyUp,

    [switch] $NoColor,

    [switch] $Version,

    [switch] $Help
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The single source of truth for the version number (major.minor.patch).
$script:AppVersion = '0.1.0'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# The source file is kept pure ASCII so Windows PowerShell 5.1 reads it correctly
# regardless of file encoding. Non-ASCII glyphs are built from code points here.

$script:Esc = [char]27
$script:G = @{
    TL      = [string][char]0x256D   # rounded top-left corner
    TR      = [string][char]0x256E   # rounded top-right corner
    BL      = [string][char]0x2570   # rounded bottom-left corner
    BR      = [string][char]0x256F   # rounded bottom-right corner
    H       = [string][char]0x2500   # horizontal line
    V       = [string][char]0x2502   # vertical line
    Down    = [string][char]0x25BC   # down-pointing triangle (pressed)
    Up      = [string][char]0x25B2   # up-pointing triangle (released)
    Dot     = [string][char]0x00B7   # middle dot separator
    Ellipsis = [string][char]0x2026
    Times   = [string][char]0x00D7
    Dash    = [string][char]0x2014
    Diamond = [string][char]0x25C6
    Circle  = [string][char]0x25CC   # dotted circle, base for combining marks
}

# Win32 console constants.
$script:STD_INPUT_HANDLE  = -10
$script:STD_OUTPUT_HANDLE = -11
$script:KEY_EVENT         = 0x0001
$script:FOCUS_EVENT       = 0x0010
$script:ENABLE_PROCESSED_OUTPUT            = 0x0001
$script:ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
$script:ENABLE_WINDOW_INPUT                = 0x0008
$script:ENABLE_EXTENDED_FLAGS              = 0x0080

# dwControlKeyState flags, in display order.
$script:ControlKeyFlags = [ordered]@{
    0x0008 = 'LCTRL'
    0x0004 = 'RCTRL'
    0x0002 = 'LALT'
    0x0001 = 'RALT'
    0x0010 = 'SHIFT'
    0x0080 = 'CAPS'
    0x0020 = 'NUM'
    0x0040 = 'SCROLL'
    0x0100 = 'ENH'
}

# Virtual-key constant names (winuser.h). Letters and digits are added below.
$script:VkNames = @{
    0x01 = 'VK_LBUTTON'; 0x02 = 'VK_RBUTTON'; 0x03 = 'VK_CANCEL'; 0x04 = 'VK_MBUTTON'
    0x05 = 'VK_XBUTTON1'; 0x06 = 'VK_XBUTTON2'; 0x08 = 'VK_BACK'; 0x09 = 'VK_TAB'
    0x0C = 'VK_CLEAR'; 0x0D = 'VK_RETURN'; 0x10 = 'VK_SHIFT'; 0x11 = 'VK_CONTROL'
    0x12 = 'VK_MENU'; 0x13 = 'VK_PAUSE'; 0x14 = 'VK_CAPITAL'; 0x15 = 'VK_KANA'
    0x16 = 'VK_IME_ON'; 0x17 = 'VK_JUNJA'; 0x18 = 'VK_FINAL'; 0x19 = 'VK_KANJI'
    0x1A = 'VK_IME_OFF'; 0x1B = 'VK_ESCAPE'; 0x1C = 'VK_CONVERT'; 0x1D = 'VK_NONCONVERT'
    0x1E = 'VK_ACCEPT'; 0x1F = 'VK_MODECHANGE'; 0x20 = 'VK_SPACE'; 0x21 = 'VK_PRIOR'
    0x22 = 'VK_NEXT'; 0x23 = 'VK_END'; 0x24 = 'VK_HOME'; 0x25 = 'VK_LEFT'
    0x26 = 'VK_UP'; 0x27 = 'VK_RIGHT'; 0x28 = 'VK_DOWN'; 0x29 = 'VK_SELECT'
    0x2A = 'VK_PRINT'; 0x2B = 'VK_EXECUTE'; 0x2C = 'VK_SNAPSHOT'; 0x2D = 'VK_INSERT'
    0x2E = 'VK_DELETE'; 0x2F = 'VK_HELP'; 0x5B = 'VK_LWIN'; 0x5C = 'VK_RWIN'
    0x5D = 'VK_APPS'; 0x5F = 'VK_SLEEP'; 0x6A = 'VK_MULTIPLY'; 0x6B = 'VK_ADD'
    0x6C = 'VK_SEPARATOR'; 0x6D = 'VK_SUBTRACT'; 0x6E = 'VK_DECIMAL'; 0x6F = 'VK_DIVIDE'
    0x90 = 'VK_NUMLOCK'; 0x91 = 'VK_SCROLL'; 0xA0 = 'VK_LSHIFT'; 0xA1 = 'VK_RSHIFT'
    0xA2 = 'VK_LCONTROL'; 0xA3 = 'VK_RCONTROL'; 0xA4 = 'VK_LMENU'; 0xA5 = 'VK_RMENU'
    0xA6 = 'VK_BROWSER_BACK'; 0xA7 = 'VK_BROWSER_FORWARD'; 0xA8 = 'VK_BROWSER_REFRESH'
    0xA9 = 'VK_BROWSER_STOP'; 0xAA = 'VK_BROWSER_SEARCH'; 0xAB = 'VK_BROWSER_FAVORITES'
    0xAC = 'VK_BROWSER_HOME'; 0xAD = 'VK_VOLUME_MUTE'; 0xAE = 'VK_VOLUME_DOWN'
    0xAF = 'VK_VOLUME_UP'; 0xB0 = 'VK_MEDIA_NEXT_TRACK'; 0xB1 = 'VK_MEDIA_PREV_TRACK'
    0xB2 = 'VK_MEDIA_STOP'; 0xB3 = 'VK_MEDIA_PLAY_PAUSE'; 0xB4 = 'VK_LAUNCH_MAIL'
    0xB5 = 'VK_LAUNCH_MEDIA_SELECT'; 0xB6 = 'VK_LAUNCH_APP1'; 0xB7 = 'VK_LAUNCH_APP2'
    0xBA = 'VK_OEM_1'; 0xBB = 'VK_OEM_PLUS'; 0xBC = 'VK_OEM_COMMA'; 0xBD = 'VK_OEM_MINUS'
    0xBE = 'VK_OEM_PERIOD'; 0xBF = 'VK_OEM_2'; 0xC0 = 'VK_OEM_3'; 0xDB = 'VK_OEM_4'
    0xDC = 'VK_OEM_5'; 0xDD = 'VK_OEM_6'; 0xDE = 'VK_OEM_7'; 0xDF = 'VK_OEM_8'
    0xE2 = 'VK_OEM_102'; 0xE5 = 'VK_PROCESSKEY'; 0xE7 = 'VK_PACKET'; 0xF6 = 'VK_ATTN'
    0xF7 = 'VK_CRSEL'; 0xF8 = 'VK_EXSEL'; 0xF9 = 'VK_EREOF'; 0xFA = 'VK_PLAY'
    0xFB = 'VK_ZOOM'; 0xFC = 'VK_NONAME'; 0xFD = 'VK_PA1'; 0xFE = 'VK_OEM_CLEAR'
}
foreach ($vk in 0x30..0x39) { $script:VkNames[$vk] = 'VK_' + [char]$vk }
foreach ($vk in 0x41..0x5A) { $script:VkNames[$vk] = 'VK_' + [char]$vk }
foreach ($i in 0..9)       { $script:VkNames[0x60 + $i] = "VK_NUMPAD$i" }
foreach ($i in 1..24)      { $script:VkNames[0x6F + $i] = "VK_F$i" }

# Human friendly key names, keyed by virtual-key code.
$script:FriendlyNames = @{
    0x03 = 'Break'; 0x08 = 'Backspace'; 0x09 = 'Tab'; 0x0C = 'Clear'; 0x0D = 'Enter'
    0x10 = 'Shift'; 0x11 = 'Ctrl'; 0x12 = 'Alt'; 0x13 = 'Pause'; 0x14 = 'Caps Lock'
    0x15 = 'Kana/Hangul'; 0x16 = 'IME On'; 0x17 = 'Junja'; 0x18 = 'Final'; 0x19 = 'Kanji/Hanja'
    0x1A = 'IME Off'; 0x1B = 'Esc'; 0x1C = 'Convert'; 0x1D = 'Non-convert'; 0x1E = 'Accept'
    0x1F = 'Mode Change'; 0x20 = 'Space'; 0x21 = 'Page Up'; 0x22 = 'Page Down'; 0x23 = 'End'
    0x24 = 'Home'; 0x25 = 'Left Arrow'; 0x26 = 'Up Arrow'; 0x27 = 'Right Arrow'
    0x28 = 'Down Arrow'; 0x29 = 'Select'; 0x2A = 'Print'; 0x2B = 'Execute'
    0x2C = 'Print Screen'; 0x2D = 'Insert'; 0x2E = 'Delete'; 0x2F = 'Help'
    0x5B = 'Left Win'; 0x5C = 'Right Win'; 0x5D = 'Menu'; 0x5F = 'Sleep'
    0x6A = 'Num *'; 0x6B = 'Num +'; 0x6C = 'Num Separator'; 0x6D = 'Num -'; 0x6E = 'Num .'
    0x6F = 'Num /'; 0x90 = 'Num Lock'; 0x91 = 'Scroll Lock'
    0xA0 = 'Left Shift'; 0xA1 = 'Right Shift'; 0xA2 = 'Left Ctrl'; 0xA3 = 'Right Ctrl'
    0xA4 = 'Left Alt'; 0xA5 = 'Right Alt'
    0xA6 = 'Browser Back'; 0xA7 = 'Browser Forward'; 0xA8 = 'Browser Refresh'
    0xA9 = 'Browser Stop'; 0xAA = 'Browser Search'; 0xAB = 'Browser Favorites'
    0xAC = 'Browser Home'; 0xAD = 'Volume Mute'; 0xAE = 'Volume Down'; 0xAF = 'Volume Up'
    0xB0 = 'Next Track'; 0xB1 = 'Previous Track'; 0xB2 = 'Media Stop'; 0xB3 = 'Play/Pause'
    0xB4 = 'Mail'; 0xB5 = 'Media Select'; 0xB6 = 'Launch App 1'; 0xB7 = 'Launch App 2'
    0xE5 = 'IME Process'; 0xE7 = 'Unicode Packet'; 0xF6 = 'Attn'; 0xFA = 'Play'; 0xFB = 'Zoom'
}
foreach ($i in 0..9)  { $script:FriendlyNames[0x60 + $i] = "Num $i" }
foreach ($i in 1..24) { $script:FriendlyNames[0x6F + $i] = "F$i" }

# Physical key codes (W3C UI Events KeyboardEvent.code) keyed by scan code.
# Extended keys (E0 prefix) are stored as 0xE000 + scan code.
$script:PhysicalCodes = @{
    0x01 = 'Escape'; 0x02 = 'Digit1'; 0x03 = 'Digit2'; 0x04 = 'Digit3'; 0x05 = 'Digit4'
    0x06 = 'Digit5'; 0x07 = 'Digit6'; 0x08 = 'Digit7'; 0x09 = 'Digit8'; 0x0A = 'Digit9'
    0x0B = 'Digit0'; 0x0C = 'Minus'; 0x0D = 'Equal'; 0x0E = 'Backspace'; 0x0F = 'Tab'
    0x10 = 'KeyQ'; 0x11 = 'KeyW'; 0x12 = 'KeyE'; 0x13 = 'KeyR'; 0x14 = 'KeyT'
    0x15 = 'KeyY'; 0x16 = 'KeyU'; 0x17 = 'KeyI'; 0x18 = 'KeyO'; 0x19 = 'KeyP'
    0x1A = 'BracketLeft'; 0x1B = 'BracketRight'; 0x1C = 'Enter'; 0x1D = 'ControlLeft'
    0x1E = 'KeyA'; 0x1F = 'KeyS'; 0x20 = 'KeyD'; 0x21 = 'KeyF'; 0x22 = 'KeyG'
    0x23 = 'KeyH'; 0x24 = 'KeyJ'; 0x25 = 'KeyK'; 0x26 = 'KeyL'; 0x27 = 'Semicolon'
    0x28 = 'Quote'; 0x29 = 'Backquote'; 0x2A = 'ShiftLeft'; 0x2B = 'Backslash'
    0x2C = 'KeyZ'; 0x2D = 'KeyX'; 0x2E = 'KeyC'; 0x2F = 'KeyV'; 0x30 = 'KeyB'
    0x31 = 'KeyN'; 0x32 = 'KeyM'; 0x33 = 'Comma'; 0x34 = 'Period'; 0x35 = 'Slash'
    0x36 = 'ShiftRight'; 0x37 = 'NumpadMultiply'; 0x38 = 'AltLeft'; 0x39 = 'Space'
    0x3A = 'CapsLock'; 0x3B = 'F1'; 0x3C = 'F2'; 0x3D = 'F3'; 0x3E = 'F4'; 0x3F = 'F5'
    0x40 = 'F6'; 0x41 = 'F7'; 0x42 = 'F8'; 0x43 = 'F9'; 0x44 = 'F10'; 0x45 = 'NumLock'
    0x46 = 'ScrollLock'; 0x47 = 'Numpad7'; 0x48 = 'Numpad8'; 0x49 = 'Numpad9'
    0x4A = 'NumpadSubtract'; 0x4B = 'Numpad4'; 0x4C = 'Numpad5'; 0x4D = 'Numpad6'
    0x4E = 'NumpadAdd'; 0x4F = 'Numpad1'; 0x50 = 'Numpad2'; 0x51 = 'Numpad3'
    0x52 = 'Numpad0'; 0x53 = 'NumpadDecimal'; 0x54 = 'PrintScreen'; 0x56 = 'IntlBackslash'
    0x57 = 'F11'; 0x58 = 'F12'; 0x59 = 'NumpadEqual'; 0x64 = 'F13'; 0x65 = 'F14'
    0x66 = 'F15'; 0x67 = 'F16'; 0x68 = 'F17'; 0x69 = 'F18'; 0x6A = 'F19'; 0x6B = 'F20'
    0x6C = 'F21'; 0x6D = 'F22'; 0x6E = 'F23'; 0x70 = 'KanaMode'; 0x73 = 'IntlRo'
    0x76 = 'F24'; 0x79 = 'Convert'; 0x7B = 'NonConvert'; 0x7D = 'IntlYen'; 0x7E = 'NumpadComma'
    0xE010 = 'MediaTrackPrevious'; 0xE019 = 'MediaTrackNext'; 0xE01C = 'NumpadEnter'
    0xE01D = 'ControlRight'; 0xE020 = 'AudioVolumeMute'; 0xE021 = 'LaunchApp2'
    0xE022 = 'MediaPlayPause'; 0xE024 = 'MediaStop'; 0xE02E = 'AudioVolumeDown'
    0xE030 = 'AudioVolumeUp'; 0xE032 = 'BrowserHome'; 0xE035 = 'NumpadDivide'
    0xE037 = 'PrintScreen'; 0xE038 = 'AltRight'; 0xE045 = 'NumLock'; 0xE046 = 'Pause'
    0xE047 = 'Home'; 0xE048 = 'ArrowUp'; 0xE049 = 'PageUp'; 0xE04B = 'ArrowLeft'
    0xE04D = 'ArrowRight'; 0xE04F = 'End'; 0xE050 = 'ArrowDown'; 0xE051 = 'PageDown'
    0xE052 = 'Insert'; 0xE053 = 'Delete'; 0xE05B = 'MetaLeft'; 0xE05C = 'MetaRight'
    0xE05D = 'ContextMenu'; 0xE05E = 'Power'; 0xE05F = 'Sleep'; 0xE063 = 'WakeUp'
    0xE065 = 'BrowserSearch'; 0xE066 = 'BrowserFavorites'; 0xE067 = 'BrowserRefresh'
    0xE068 = 'BrowserStop'; 0xE069 = 'BrowserForward'; 0xE06A = 'BrowserBack'
    0xE06B = 'LaunchApp1'; 0xE06C = 'LaunchMail'; 0xE06D = 'MediaSelect'
}

# Physical codes of modifier keys -> family, side and the side-specific VK used
# with GetAsyncKeyState.
$script:ModifierCodes = @{
    'ShiftLeft'    = @{ Family = 'Shift'; Side = 'Left';  Vk = 0xA0 }
    'ShiftRight'   = @{ Family = 'Shift'; Side = 'Right'; Vk = 0xA1 }
    'ControlLeft'  = @{ Family = 'Ctrl';  Side = 'Left';  Vk = 0xA2 }
    'ControlRight' = @{ Family = 'Ctrl';  Side = 'Right'; Vk = 0xA3 }
    'AltLeft'      = @{ Family = 'Alt';   Side = 'Left';  Vk = 0xA4 }
    'AltRight'     = @{ Family = 'Alt';   Side = 'Right'; Vk = 0xA5 }
    'MetaLeft'     = @{ Family = 'Win';   Side = 'Left';  Vk = 0x5B }
    'MetaRight'    = @{ Family = 'Win';   Side = 'Right'; Vk = 0x5C }
}

# ASCII control character abbreviations (0-31).
$script:ControlNames = @(
    'NUL', 'SOH', 'STX', 'ETX', 'EOT', 'ENQ', 'ACK', 'BEL', 'BS', 'HT', 'LF', 'VT', 'FF', 'CR',
    'SO', 'SI', 'DLE', 'DC1', 'DC2', 'DC3', 'DC4', 'NAK', 'SYN', 'ETB', 'CAN', 'EM', 'SUB',
    'ESC', 'FS', 'GS', 'RS', 'US'
)

# ---------------------------------------------------------------------------
# Native interop
# ---------------------------------------------------------------------------

function Initialize-NativeMethod {
    <#
    .SYNOPSIS
        Compiles the small Win32 interop class used to read raw console input.
    .DESCRIPTION
        Uses Add-Type, which is built into both Windows PowerShell 5.1 and
        PowerShell 7, so nothing has to be installed. The type is only compiled
        once per PowerShell session.
    #>
    [CmdletBinding()]
    param()

    if ('ShowKey.Native.Win32' -as [type]) { return }

    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ShowKey.Native
{
    // INPUT_RECORD with the KEY_EVENT_RECORD, WINDOW_BUFFER_SIZE_RECORD and
    // FOCUS_EVENT_RECORD members of its union overlaid at offset 4.
    [StructLayout(LayoutKind.Explicit)]
    public struct InputRecord
    {
        [FieldOffset(0)]  public ushort EventType;
        [FieldOffset(4)]  public int    KeyDown;          // also bSetFocus for FOCUS_EVENT
        [FieldOffset(8)]  public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public ushort UnicodeChar;
        [FieldOffset(16)] public uint   ControlKeyState;
    }

    public static class Win32
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleMode(IntPtr hConsole, out uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleMode(IntPtr hConsole, uint mode);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ReadConsoleInputW")]
        public static extern bool ReadConsoleInput(IntPtr hConsoleInput, [Out] InputRecord[] buffer, uint length, out uint eventsRead);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetNumberOfConsoleInputEvents(IntPtr hConsoleInput, out uint count);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FlushConsoleInputBuffer(IntPtr hConsoleInput);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        public static extern short GetKeyState(int vKey);

        [DllImport("user32.dll", EntryPoint = "MapVirtualKeyW")]
        public static extern uint MapVirtualKey(uint code, uint mapType);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetKeyNameTextW")]
        private static extern int GetKeyNameTextNative(int lParam, StringBuilder buffer, int size);

        // Returns the key name the active keyboard layout uses for a scan code.
        public static string KeyNameText(int scanCode, bool extended)
        {
            int lParam = (scanCode & 0xFF) << 16;
            if (extended) { lParam |= 1 << 24; }
            var sb = new StringBuilder(64);
            int len = GetKeyNameTextNative(lParam, sb, sb.Capacity);
            return len > 0 ? sb.ToString() : string.Empty;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Test-KeyDown {
    <#
    .SYNOPSIS
        Returns $true if the given virtual key is physically held down right now.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int] $VirtualKey)

    return (([int][ShowKey.Native.Win32]::GetAsyncKeyState($VirtualKey)) -band 0x8000) -ne 0
}

# ---------------------------------------------------------------------------
# Text helpers (display width aware)
# ---------------------------------------------------------------------------

function Get-CharWidth {
    <#
    .SYNOPSIS
        Returns the number of terminal cells a UTF-16 code unit occupies (0, 1 or 2).
    .DESCRIPTION
        A high surrogate counts as 2 (most astral characters are emoji or CJK) and
        its low surrogate as 0. Combining marks and zero-width characters count as 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][char] $Char)

    $c = [int]$Char
    if ($c -lt 0x0300) { return 1 }
    if ($c -le 0x036F) { return 0 }                              # combining diacritics
    if ($c -ge 0xD800 -and $c -le 0xDBFF) { return 2 }           # high surrogate
    if ($c -ge 0xDC00 -and $c -le 0xDFFF) { return 0 }           # low surrogate
    if (($c -ge 0x200B -and $c -le 0x200F) -or ($c -ge 0xFE00 -and $c -le 0xFE0F)) { return 0 }
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE4F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { return 2 }
    return 1
}

function Get-TextWidth {
    <#
    .SYNOPSIS
        Returns the number of terminal cells a plain (no ANSI codes) string occupies.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    if ($Text -match '^[\x20-\x7E]*$') { return $Text.Length }   # fast path: printable ASCII
    $width = 0
    foreach ($ch in $Text.ToCharArray()) { $width += Get-CharWidth -Char $ch }
    return $width
}

function Format-Fit {
    <#
    .SYNOPSIS
        Pads or truncates plain text to exactly the given display width.
    .DESCRIPTION
        Truncated text ends with an ellipsis. Alignment can be Left, Center or Right.
        Only pass plain text; apply colors after fitting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string] $Text,
        [Parameter(Mandatory)][int] $Width,
        [ValidateSet('Left', 'Center', 'Right')][string] $Align = 'Left'
    )

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }

    $textWidth = Get-TextWidth -Text $Text
    if ($textWidth -gt $Width) {
        # Keep as many cells as fit, leaving room for the ellipsis.
        $sb = [System.Text.StringBuilder]::new()
        $used = 0
        $i = 0
        while ($i -lt $Text.Length) {
            $unit = [string]$Text[$i]
            if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length) {
                $unit = $Text.Substring($i, 2)
            }
            $unitWidth = Get-TextWidth -Text $unit
            if ($used + $unitWidth -gt $Width - 1) { break }
            [void]$sb.Append($unit)
            $used += $unitWidth
            $i += $unit.Length
        }
        [void]$sb.Append($script:G.Ellipsis)
        $used += 1
        return $sb.ToString() + (' ' * ($Width - $used))
    }

    $pad = $Width - $textWidth
    switch ($Align) {
        'Right'  { return (' ' * $pad) + $Text }
        'Center' {
            $left = [Math]::Floor($pad / 2)
            return (' ' * $left) + $Text + (' ' * ($pad - $left))
        }
        default  { return $Text + (' ' * $pad) }
    }
}

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

function ConvertTo-AnsiColor {
    <#
    .SYNOPSIS
        Converts an RRGGBB hex color into a 24-bit ANSI SGR parameter string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{6}$')][string] $Hex,
        [switch] $Background
    )

    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
    $kind = if ($Background) { 48 } else { 38 }
    return "$kind;2;$r;$g;$b"
}

function New-Theme {
    <#
    .SYNOPSIS
        Builds the table of ANSI styles used by the renderer.
    .DESCRIPTION
        Values are left at the terminal's default foreground so the UI is readable
        on both dark and light terminal themes; only accents carry color.
        With -Plain every style is an empty string.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch] $Plain)

    $definitions = [ordered]@{
        Header    = @{ Fg = '1A1B26'; Bg = '7AA2F7'; Bold = $true }
        Label     = @{ Fg = '7A82A8' }
        Value     = @{}
        Strong    = @{ Bold = $true }
        Muted     = @{ Fg = '6B7089' }
        Accent    = @{ Fg = '7AA2F7'; Bold = $true }
        Border    = @{ Fg = '565F89' }
        BorderHot = @{ Fg = '7AA2F7' }
        Good      = @{ Fg = '1A1B26'; Bg = '9ECE6A'; Bold = $true }
        GoodFg    = @{ Fg = '9ECE6A'; Bold = $true }
        Warn      = @{ Fg = '1A1B26'; Bg = 'FF9E64'; Bold = $true }
        WarnFg    = @{ Fg = 'FF9E64'; Bold = $true }
        Idle      = @{ Fg = 'FFFFFF'; Bg = '565F89'; Bold = $true }
        Alert     = @{ Fg = '1A1B26'; Bg = 'F7768E'; Bold = $true }
        PillOn    = @{ Fg = '1A1B26'; Bg = 'BB9AF7'; Bold = $true }
        PillOff   = @{ Fg = '565F89' }
        Glyph     = @{ Fg = 'E0AF68'; Bold = $true }
        Column    = @{ Fg = '7DCFFF'; Bold = $true }
    }

    $theme = @{ Plain = [bool]$Plain; Reset = '' }
    if ($Plain) {
        foreach ($name in $definitions.Keys) { $theme[$name] = '' }
        return $theme
    }

    $theme.Reset = "$($script:Esc)[0m"
    foreach ($name in $definitions.Keys) {
        $d = $definitions[$name]
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($d.Contains('Bold')) { $parts.Add('1') }
        if ($d.Contains('Fg'))   { $parts.Add((ConvertTo-AnsiColor -Hex $d.Fg)) }
        if ($d.Contains('Bg'))   { $parts.Add((ConvertTo-AnsiColor -Hex $d.Bg -Background)) }
        $theme[$name] = if ($parts.Count -gt 0) { "$($script:Esc)[$($parts -join ';')m" } else { '' }
    }
    return $theme
}

function Format-Paint {
    <#
    .SYNOPSIS
        Wraps text in a theme style followed by a reset (no-op for empty styles).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Style,
        [AllowEmptyString()][string] $Text
    )

    if ([string]::IsNullOrEmpty($Style)) { return $Text }
    return "$Style$Text$($script:Theme.Reset)"
}

# ---------------------------------------------------------------------------
# Key analysis
# ---------------------------------------------------------------------------

function Get-PhysicalKeyCode {
    <#
    .SYNOPSIS
        Maps a scan code to a W3C KeyboardEvent.code style physical key name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $VirtualKey, [int] $ScanCode, [bool] $Extended)

    # A few keys share scan codes; the virtual key disambiguates them.
    if ($VirtualKey -eq 0x13) { return 'Pause' }
    if ($VirtualKey -eq 0x90) { return 'NumLock' }
    if ($VirtualKey -eq 0x2C) { return 'PrintScreen' }
    if ($ScanCode -eq 0) { return 'Unidentified' }
    $lookup = if ($Extended) { 0xE000 + $ScanCode } else { $ScanCode }
    $code = $script:PhysicalCodes[$lookup]
    if (-not $code -and $Extended) { $code = $script:PhysicalCodes[$ScanCode] }
    if ($code) { return $code }
    return 'Unidentified'
}

function Get-KeyLocation {
    <#
    .SYNOPSIS
        Returns Standard, Left, Right or Numpad for a physical key code.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $PhysicalCode)

    $modifier = $script:ModifierCodes[$PhysicalCode]
    if ($modifier) { return $modifier.Side }
    if ($PhysicalCode -like 'Numpad*') { return 'Numpad' }
    return 'Standard'
}

function Get-FriendlyKeyName {
    <#
    .SYNOPSIS
        Returns a human friendly name for a key, e.g. "A", "Left Shift", "Num Home".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $VirtualKey, [string] $PhysicalCode)

    switch ($PhysicalCode) {
        'ShiftLeft'    { return 'Left Shift' }
        'ShiftRight'   { return 'Right Shift' }
        'ControlLeft'  { return 'Left Ctrl' }
        'ControlRight' { return 'Right Ctrl' }
        'AltLeft'      { return 'Left Alt' }
        'AltRight'     { return 'Right Alt' }
        'NumpadEnter'  { return 'Num Enter' }
    }

    # Numpad keys with Num Lock off report navigation virtual keys.
    if ($PhysicalCode -like 'Numpad*' -and $VirtualKey -ge 0x21 -and $VirtualKey -le 0x2E) {
        $nav = $script:FriendlyNames[$VirtualKey]
        if ($nav) { return "Num $($nav -replace ' Arrow$', '')" }
    }

    if (($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) -or ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A)) {
        return [string][char]$VirtualKey
    }

    $name = $script:FriendlyNames[$VirtualKey]
    if ($name) { return $name }

    # OEM keys: ask the keyboard layout which character the key produces.
    # MAPVK_VK_TO_CHAR (2) sets the top bit for dead keys.
    $mapped = [ShowKey.Native.Win32]::MapVirtualKey([uint32]$VirtualKey, 2)
    $charCode = [int]($mapped -band 0xFFFF)
    if ($charCode -gt 32) {
        $dead = ($mapped -band 0x80000000) -ne 0
        $text = [string][char]$charCode
        if ($dead) { return "$text (dead key)" }
        return $text
    }

    $vkName = $script:VkNames[$VirtualKey]
    if ($vkName) { return $vkName }
    return ('VK 0x{0:X2}' -f $VirtualKey)
}

function Get-KeyCategory {
    <#
    .SYNOPSIS
        Classifies a key (Letter, Digit, Modifier, Navigation, Numpad, ...).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $VirtualKey, [string] $PhysicalCode)

    if ($script:ModifierCodes[$PhysicalCode] -or $VirtualKey -in 0x10, 0x11, 0x12) { return 'Modifier' }
    if ($VirtualKey -in 0x14, 0x90, 0x91) { return 'Lock' }
    if ($VirtualKey -ge 0x41 -and $VirtualKey -le 0x5A) { return 'Letter' }
    if ($VirtualKey -ge 0x30 -and $VirtualKey -le 0x39) { return 'Digit' }
    if ($VirtualKey -ge 0x70 -and $VirtualKey -le 0x87) { return 'Function' }
    if ($PhysicalCode -like 'Numpad*' -or ($VirtualKey -ge 0x60 -and $VirtualKey -le 0x6F)) { return 'Numpad' }
    if (($VirtualKey -ge 0x21 -and $VirtualKey -le 0x28) -or $VirtualKey -in 0x2D, 0x2E) { return 'Navigation' }
    if ($VirtualKey -in 0x08, 0x09, 0x0D, 0x20) { return 'Editing / Whitespace' }
    if ($VirtualKey -eq 0x1B) { return 'Control' }
    if (($VirtualKey -ge 0xBA -and $VirtualKey -le 0xC0) -or ($VirtualKey -ge 0xDB -and $VirtualKey -le 0xDF) -or $VirtualKey -eq 0xE2) {
        return 'Punctuation (OEM)'
    }
    if ($VirtualKey -ge 0xAD -and $VirtualKey -le 0xB3) { return 'Media' }
    if ($VirtualKey -ge 0xA6 -and $VirtualKey -le 0xAC) { return 'Browser' }
    if ($VirtualKey -ge 0xB4 -and $VirtualKey -le 0xB7) { return 'Launch' }
    if ($VirtualKey -in 0x03, 0x13, 0x2C, 0x5D, 0x5F) { return 'System' }
    if (($VirtualKey -ge 0x15 -and $VirtualKey -le 0x1F) -or $VirtualKey -eq 0xE5) { return 'IME' }
    if ($VirtualKey -eq 0xE7) { return 'Unicode packet (IME / injected)' }
    return 'Other'
}

function Format-ControlKeyState {
    <#
    .SYNOPSIS
        Formats raw dwControlKeyState flags, e.g. "0x0128 LCTRL NUM ENH".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Flags)

    # Enumerate pairs: indexing an ordered dictionary with an int selects by position.
    $names = foreach ($pair in $script:ControlKeyFlags.GetEnumerator()) {
        if ($Flags -band [int]$pair.Key) { $pair.Value }
    }
    return (('0x{0:X4} ' -f $Flags) + ($names -join ' ')).TrimEnd()
}

function Get-CharInfo {
    <#
    .SYNOPSIS
        Describes a Unicode code point: glyph, name, encodings and literals.
    .PARAMETER CodePoint
        The code point, or -1 when the key produced no character.
    .PARAMETER SurrogateHalf
        Set when the code point is an unpaired UTF-16 surrogate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int] $CodePoint, [switch] $SurrogateHalf)

    $none = $script:G.Dash
    $info = @{
        HasChar = $false; Glyph = ''; Name = 'none'; Unicode = $none; Ascii = $none
        Utf8 = $none; Utf16 = $none; Html = $none; Literal = $none; Short = ''
    }
    if ($CodePoint -lt 0) { return $info }

    $info.HasChar = $true
    $hex = if ($CodePoint -gt 0xFFFF) { '{0:X5}' -f $CodePoint } else { '{0:X4}' -f $CodePoint }

    if ($SurrogateHalf) {
        $half = if ($CodePoint -lt 0xDC00) { 'high' } else { 'low' }
        $info.Name = "$half surrogate"
        $info.Unicode = "U+$hex $($script:G.Dot) Surrogate"
        $info.Utf16 = $hex
        $info.Utf8 = 'n/a (unpaired)'
        $info.Ascii = 'n/a'
        $info.Literal = "[char]0x$hex"
        $info.Short = $hex
        return $info
    }

    $text = [char]::ConvertFromUtf32($CodePoint)
    $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($text, 0)

    # Pick a printable representation for the glyph column.
    if ($CodePoint -lt 32) {
        $info.Glyph = [string][char](0x2400 + $CodePoint)        # Control Pictures block
        $info.Name = "$($script:ControlNames[$CodePoint]) (Ctrl+$([char](64 + $CodePoint)))"
    }
    elseif ($CodePoint -eq 32) {
        $info.Glyph = [string][char]0x2423
        $info.Name = 'SP (space)'
    }
    elseif ($CodePoint -eq 127) {
        $info.Glyph = [string][char]0x2421
        $info.Name = 'DEL'
    }
    elseif ($CodePoint -ge 0x80 -and $CodePoint -le 0x9F) {
        $info.Glyph = ''
        $info.Name = 'C1 control'
    }
    elseif ($CodePoint -eq 0xA0) {
        $info.Glyph = [string][char]0x2423
        $info.Name = 'NBSP (no-break space)'
    }
    elseif ($category -in 'NonSpacingMark', 'EnclosingMark', 'SpacingCombiningMark') {
        $info.Glyph = $script:G.Circle + $text
        $info.Name = 'combining mark'
    }
    elseif ($category -eq 'Format') {
        $info.Glyph = ''
        $info.Name = 'format character'
    }
    else {
        $info.Glyph = $text
        $info.Name = ''
    }

    $info.Unicode = "U+$hex $($script:G.Dot) $category"
    $info.Short = (($info.Glyph + ' ' + $hex.TrimStart('0').PadLeft(2, '0'))).Trim()

    if ($CodePoint -lt 128) {
        $info.Ascii = '{0} {1} 0x{2:X2} {1} 0o{3} {1} 0b{4}' -f $CodePoint, $script:G.Dot, $CodePoint,
            [Convert]::ToString($CodePoint, 8), [Convert]::ToString($CodePoint, 2).PadLeft(8, '0')
    }
    else {
        $info.Ascii = 'n/a (not ASCII)'
    }

    $info.Utf8  = ([System.Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $info.Utf16 = ($text.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '

    $named = @{ 34 = '&quot;'; 38 = '&amp;'; 39 = '&apos;'; 60 = '&lt;'; 62 = '&gt;'; 160 = '&nbsp;' }
    $info.Html = if ($named.ContainsKey($CodePoint)) { "$($named[$CodePoint])  &#$CodePoint;" }
                 else { '&#{0};  &#x{1:X};' -f $CodePoint, $CodePoint }

    # How to write the character in PowerShell source.
    $escapes = @{ 0 = '"`0"'; 7 = '"`a"'; 8 = '"`b"'; 9 = '"`t"'; 10 = '"`n"'; 11 = '"`v"'; 12 = '"`f"'; 13 = '"`r"' }
    if ($escapes.ContainsKey($CodePoint)) {
        $info.Literal = $escapes[$CodePoint]
    }
    elseif ($CodePoint -eq 27) {
        $info.Literal = '[char]27  or "`e" (PS 6+)'
    }
    elseif ($CodePoint -eq 39) {
        $info.Literal = '"''"'
    }
    elseif ($CodePoint -ge 33 -and $CodePoint -le 126) {
        $info.Literal = "'$text'"
    }
    elseif ($CodePoint -gt 0xFFFF) {
        $info.Literal = '"`u{{{0:X}}}" (PS 6+)' -f $CodePoint
    }
    else {
        $info.Literal = '[char]0x{0:X4}' -f $CodePoint
    }
    return $info
}

# ---------------------------------------------------------------------------
# State and event handling
# ---------------------------------------------------------------------------

function New-AppState {
    <#
    .SYNOPSIS
        Creates the mutable application state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int] $HistorySize, [bool] $NoKeyUp)

    return @{
        HistorySize = $HistorySize
        NoKeyUp     = $NoKeyUp
        Clock       = [System.Diagnostics.Stopwatch]::StartNew()
        Events      = 0
        Last        = $null
        History     = [System.Collections.Generic.List[hashtable]]::new()
        Held        = [ordered]@{}    # physical key -> @{ Since; Repeat; Vk }
        Flags       = 0
        HasFlags    = $false
        LastEventMs = -1L
        SeenKeyDown = $false
        PendingHigh = -1              # high surrogate waiting for its low half
        EscArmedAt  = -1L             # time of the first Esc press, -1 when not armed
        Quit        = $false
    }
}

function Get-ModifierPrefix {
    <#
    .SYNOPSIS
        Returns the active modifiers (Ctrl, Alt, Shift, Win) except the key's own family.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([int] $Flags, [string] $OwnFamily)

    $mods = [System.Collections.Generic.List[string]]::new()
    if (($Flags -band 0x000C) -and $OwnFamily -ne 'Ctrl')  { $mods.Add('Ctrl') }
    if (($Flags -band 0x0003) -and $OwnFamily -ne 'Alt')   { $mods.Add('Alt') }
    if (($Flags -band 0x0010) -and $OwnFamily -ne 'Shift') { $mods.Add('Shift') }
    if ($OwnFamily -ne 'Win' -and ((Test-KeyDown -VirtualKey 0x5B) -or (Test-KeyDown -VirtualKey 0x5C))) {
        $mods.Add('Win')
    }
    return , $mods.ToArray()
}

function Invoke-KeyRecord {
    <#
    .SYNOPSIS
        Analyses one KEY_EVENT input record and updates the application state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)][hashtable] $State)

    $vk       = [int]$Record.VirtualKeyCode
    $scan     = [int]$Record.VirtualScanCode
    $flags    = [int]$Record.ControlKeyState
    $down     = $Record.KeyDown -ne 0
    $extended = ($flags -band 0x0100) -ne 0
    $now      = $State.Clock.ElapsedMilliseconds

    $code = Get-PhysicalKeyCode -VirtualKey $vk -ScanCode $scan -Extended $extended
    $id = if ($code -ne 'Unidentified') { $code } else { 'VK_{0:X2}' -f $vk }

    # Skip stray releases of keys pressed before ShowKey started (e.g. the Enter
    # that launched it), until the first real key press has been seen.
    if (-not $down -and -not $State.SeenKeyDown -and -not $State.Held.Contains($id)) { return }

    $modifier = $script:ModifierCodes[$code]
    $family = if ($modifier) { $modifier.Family } elseif ($vk -eq 0x10) { 'Shift' } elseif ($vk -eq 0x11) { 'Ctrl' } elseif ($vk -eq 0x12) { 'Alt' } else { '' }

    # Track held keys for auto-repeat counting and hold duration.
    $repeat = 0
    $heldMs = $null
    if ($down) {
        $State.SeenKeyDown = $true
        # VK_PACKET events are injected characters (IME, emoji panel), never auto-repeat.
        if ($vk -eq 0xE7) { $State.Held.Remove($id) }
        if ($State.Held.Contains($id)) {
            $entry = $State.Held[$id]
            $entry.Repeat++
        }
        else {
            $asyncVk = if ($modifier) { $modifier.Vk } else { $vk }
            $entry = @{ Since = $now; Repeat = 1; Vk = $asyncVk }
            $State.Held[$id] = $entry
        }
        $repeat = $entry.Repeat
        $heldMs = $now - $entry.Since
    }
    elseif ($State.Held.Contains($id)) {
        $entry = $State.Held[$id]
        $repeat = $entry.Repeat
        $heldMs = $now - $entry.Since
        $State.Held.Remove($id)
    }

    $State.Flags = $flags
    $State.HasFlags = $true

    # Character, pairing UTF-16 surrogates that arrive as two separate events.
    $unit = [int]$Record.UnicodeChar
    $charInfo = $null
    if ($unit -ge 0xD800 -and $unit -le 0xDBFF) {
        if ($down) { $State.PendingHigh = $unit }
        $charInfo = Get-CharInfo -CodePoint $unit -SurrogateHalf
    }
    elseif ($unit -ge 0xDC00 -and $unit -le 0xDFFF) {
        if ($State.PendingHigh -ge 0) {
            $cp = [char]::ConvertToUtf32([char]$State.PendingHigh, [char]$unit)
            $charInfo = Get-CharInfo -CodePoint $cp
            if ($down) { $State.PendingHigh = -1 }
        }
        else {
            $charInfo = Get-CharInfo -CodePoint $unit -SurrogateHalf
        }
    }
    elseif ($unit -gt 0) {
        $charInfo = Get-CharInfo -CodePoint $unit
    }
    elseif ($vk -eq 0x32 -and ($flags -band 0x000C)) {
        # Ctrl+2 / Ctrl+@ produces NUL, which the console reports as 0.
        $charInfo = Get-CharInfo -CodePoint 0
    }
    else {
        $charInfo = Get-CharInfo -CodePoint -1
    }

    # Esc pressed twice in a row (without auto-repeat) quits.
    if ($down -and $repeat -eq 1) {
        if ($vk -eq 0x1B) {
            if ($State.EscArmedAt -ge 0 -and ($now - $State.EscArmedAt) -le 1500) {
                $State.Quit = $true
                return
            }
            $State.EscArmedAt = $now
        }
        else {
            $State.EscArmedAt = -1L
        }
    }

    if (-not $down -and $State.NoKeyUp) { return }

    $name = Get-FriendlyKeyName -VirtualKey $vk -PhysicalCode $code
    $mods = Get-ModifierPrefix -Flags $flags -OwnFamily $family
    $combo = (@($mods) + $name) -join '+'

    $sinceLast = if ($State.LastEventMs -ge 0) { $now - $State.LastEventMs } else { $null }
    $State.LastEventMs = $now
    $State.Events++

    $consoleKey = if ([Enum]::IsDefined([ConsoleKey], $vk)) { [string][ConsoleKey]$vk } else { $script:G.Dash }
    $vkName = $script:VkNames[$vk]
    if (-not $vkName) { $vkName = 'unassigned' }
    $layoutName = [ShowKey.Native.Win32]::KeyNameText($scan, $extended)
    if (-not $layoutName) { $layoutName = $script:G.Dash }
    $scanText = if ($scan -eq 0) { 'none' }
                elseif ($extended) { 'E0 {0:X2}  (0x{0:X2} = {0}, extended)' -f $scan }
                else { '{0:X2}  (0x{0:X2} = {0})' -f $scan }

    $info = @{
        Time        = [DateTime]::Now
        Down        = $down
        Vk          = $vk
        Scan        = $scan
        Extended    = $extended
        Flags       = $flags
        Code        = $code
        Name        = $name
        Combo       = $combo
        Location    = Get-KeyLocation -PhysicalCode $code
        Category    = Get-KeyCategory -VirtualKey $vk -PhysicalCode $code
        LayoutName  = $layoutName
        VkText      = '{0} {1} 0x{0:X2}' -f $vk, $script:G.Dot
        VkName      = "$vkName $($script:G.Dot) [ConsoleKey]::$consoleKey"
        ScanText    = $scanText
        ScanShort   = if ($scan -eq 0) { '--' } elseif ($extended) { 'E0 {0:X2}' -f $scan } else { '{0:X2}' -f $scan }
        Repeat      = $repeat
        RecordCount = [int]$Record.RepeatCount
        HeldMs      = $heldMs
        SinceLastMs = $sinceLast
        Char        = $charInfo
        Number      = $State.Events
    }
    $State.Last = $info
    $State.History.Insert(0, $info)
    if ($State.History.Count -gt $State.HistorySize) {
        $State.History.RemoveRange($State.HistorySize, $State.History.Count - $State.HistorySize)
    }
}

function Update-HeldKey {
    <#
    .SYNOPSIS
        Drops keys from the held list that are no longer physically down.
    .DESCRIPTION
        Key releases can be missed, for example when the Win key opens the Start
        menu and the console loses focus. Entries younger than 250 ms are kept to
        avoid racing against events still in the input queue.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State)

    $now = $State.Clock.ElapsedMilliseconds
    foreach ($id in @($State.Held.Keys)) {
        $entry = $State.Held[$id]
        if (($now - $entry.Since) -gt 250 -and -not (Test-KeyDown -VirtualKey $entry.Vk)) {
            $State.Held.Remove($id)
        }
    }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Format-Field {
    <#
    .SYNOPSIS
        Renders "label  value" fitted to exactly the given width.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Label, [AllowEmptyString()][string] $Value, [int] $Width, [int] $LabelWidth = 12, [string] $ValueStyle = $script:Theme.Value)

    $labelText = Format-Fit -Text $Label -Width $LabelWidth
    $valueText = Format-Fit -Text $Value -Width ($Width - $LabelWidth)
    return (Format-Paint -Style $script:Theme.Label -Text $labelText) + (Format-Paint -Style $ValueStyle -Text $valueText)
}

function Format-BoxTop {
    <#
    .SYNOPSIS
        Renders a rounded box top border with an optional title and right-hand note.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Width, [string] $Title = '', [string] $Note = '', [string] $BorderStyle = $script:Theme.Border)

    $G = $script:G
    $T = $script:Theme
    $inner = $Width - 2
    $titleText = if ($Title) { " $Title " } else { '' }
    $noteText = if ($Note) { " $Note " } else { '' }
    $titleWidth = Get-TextWidth -Text $titleText
    $noteWidth = Get-TextWidth -Text $noteText
    if ($titleWidth + $noteWidth + 2 -gt $inner) { $noteText = ''; $noteWidth = 0 }
    $fill = [Math]::Max(0, $inner - 1 - $titleWidth - $noteWidth - 1)
    return (Format-Paint -Style $BorderStyle -Text ($G.TL + $G.H)) +
           (Format-Paint -Style $T.Accent -Text $titleText) +
           (Format-Paint -Style $BorderStyle -Text ($G.H * $fill)) +
           (Format-Paint -Style $T.Muted -Text $noteText) +
           (Format-Paint -Style $BorderStyle -Text ($G.H + $G.TR))
}

function Format-BoxBottom {
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Width, [string] $BorderStyle = $script:Theme.Border)

    return Format-Paint -Style $BorderStyle -Text ($script:G.BL + ($script:G.H * ($Width - 2)) + $script:G.BR)
}

function Format-BoxRow {
    <#
    .SYNOPSIS
        Wraps already-rendered content (exactly Width-4 cells wide) in box sides.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Content, [string] $BorderStyle = $script:Theme.Border)

    $side = Format-Paint -Style $BorderStyle -Text $script:G.V
    return "$side $Content $side"
}

function Format-Pill {
    <#
    .SYNOPSIS
        Renders a small on/off indicator. In plain mode "on" is shown in brackets.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Text, [bool] $On)

    $T = $script:Theme
    if ($T.Plain) {
        if ($On) { return "[$Text]" }
        return " $(('-' * $Text.Length)) "
    }
    if ($On) { return Format-Paint -Style $T.PillOn -Text " $Text " }
    return Format-Paint -Style $T.PillOff -Text " $Text "
}

function Format-Duration {
    [CmdletBinding()]
    [OutputType([string])]
    param($Milliseconds)

    if ($null -eq $Milliseconds) { return $script:G.Dash }
    $ms = [long]$Milliseconds
    if ($ms -lt 10000) { return "$ms ms" }
    return ('{0:N1} s' -f ($ms / 1000.0))
}

function Get-FrameLine {
    <#
    .SYNOPSIS
        Builds every screen line (each exactly $Width cells) for the current state.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable] $State, [int] $Width, [int] $Height)

    $T = $script:Theme
    $G = $script:G
    $lines = [System.Collections.Generic.List[string]]::new()
    $last = $State.Last
    $margin = 2
    $pad = ' ' * $margin
    $blank = ' ' * $Width

    # Spare rows become breathing space between sections (up to 3).
    $gaps = [Math]::Min(3, [Math]::Max(0, [Math]::Floor(($Height - 24) / 2)))

    # --- Header bar --------------------------------------------------------
    $left = " $($G.Diamond) ShowKey  v$($script:AppVersion)"
    $right = "$($State.Events) events  "
    $mid = [Math]::Max(1, $Width - (Get-TextWidth $left) - (Get-TextWidth $right))
    $lines.Add((Format-Paint -Style $T.Header -Text (Format-Fit -Text ($left + (' ' * $mid) + $right) -Width $Width)))
    if ($gaps -ge 1) { $lines.Add($blank) }

    # --- Keycap and summary -----------------------------------------------
    $kw = [Math]::Min(36, [Math]::Max(26, [int]($Width * 0.36)))
    $rx = $margin + $kw + 3
    $rw = $Width - $rx - 1
    $capStyle = if ($last -and $last.Down) { $T.BorderHot } else { $T.Border }

    if ($last) {
        $capLabel = $last.Combo -replace '\+', ' + '
        $capSub = '{0}  {1}  0x{2:X2}' -f $last.Code, $G.Dot, $last.Vk
    }
    else {
        $capLabel = 'press any key'
        $capSub = 'Esc twice to quit'
    }
    $capLabelStyle = if ($last) { $T.Strong } else { $T.Muted }
    $cap = @(
        (Format-Paint -Style $capStyle -Text ($G.TL + ($G.H * ($kw - 2)) + $G.TR)),
        ((Format-Paint -Style $capStyle -Text $G.V) + (' ' * ($kw - 2)) + (Format-Paint -Style $capStyle -Text $G.V)),
        ((Format-Paint -Style $capStyle -Text $G.V) + (Format-Paint -Style $capLabelStyle -Text (Format-Fit -Text $capLabel -Width ($kw - 2) -Align Center)) + (Format-Paint -Style $capStyle -Text $G.V)),
        ((Format-Paint -Style $capStyle -Text $G.V) + (Format-Paint -Style $T.Muted -Text (Format-Fit -Text $capSub -Width ($kw - 2) -Align Center)) + (Format-Paint -Style $capStyle -Text $G.V)),
        (Format-Paint -Style $capStyle -Text ($G.BL + ($G.H * ($kw - 2)) + $G.BR))
    )

    # Right-hand summary.
    if ($last) {
        if ($last.Down) { $badge = " $($G.Down) PRESSED "; $badgeStyle = $T.Good }
        else            { $badge = " $($G.Up) RELEASED "; $badgeStyle = $T.Warn }
        $stamp = "  #$($last.Number)  $($G.Dot)  $($last.Time.ToString('HH:mm:ss.fff'))"
        if ($last.Down -and $last.Repeat -gt 1) {
            $repeatText = "$($G.Times)$($last.Repeat) (auto-repeating)"
        }
        elseif ($last.Down) {
            $repeatText = 'first press'
        }
        else {
            $repeatText = "$($G.Times)$($last.Repeat) key-down events"
        }
        $repeatText += "  $($G.Dot)  record count $($last.RecordCount)"
        $heldLabel = if ($last.Down) { 'held so far' } else { 'held for' }
        $since = if ($null -eq $last.SinceLastMs) { 'first event' } else { "+$(Format-Duration $last.SinceLastMs) since last" }
        $timing = "$heldLabel $(Format-Duration $last.HeldMs)  $($G.Dot)  $since"
        $summary = @(
            @{ L = 'Combo'; V = $last.Combo },
            @{ L = 'Repeat'; V = $repeatText },
            @{ L = 'Timing'; V = $timing }
        )
    }
    else {
        $badge = ' WAITING '; $badgeStyle = $T.Idle
        $stamp = '  listening for keyboard input'
        $summary = @(
            @{ L = 'Combo'; V = $G.Dash },
            @{ L = 'Repeat'; V = $G.Dash },
            @{ L = 'Timing'; V = $G.Dash }
        )
    }
    $heldText = if ($State.Held.Count -gt 0) { @($State.Held.Keys) -join '  ' } else { 'none' }

    $badgeWidth = Get-TextWidth $badge
    $right = @(
        ((Format-Paint -Style $badgeStyle -Text $badge) + (Format-Paint -Style $T.Muted -Text (Format-Fit -Text $stamp -Width ($rw - $badgeWidth))))
    )
    foreach ($row in $summary) { $right += Format-Field -Label $row.L -Value $row.V -Width $rw -LabelWidth 11 }
    $right += Format-Field -Label 'Keys down' -Value $heldText -Width $rw -LabelWidth 11

    for ($i = 0; $i -lt 5; $i++) {
        $lines.Add($pad + $cap[$i] + '   ' + $right[$i] + ' ')
    }
    if ($gaps -ge 2) { $lines.Add($blank) }

    # --- Detail panels ------------------------------------------------------
    $total = $Width - (2 * $margin) - 1
    $pw1 = [Math]::Floor($total / 2)
    $pw2 = $total - $pw1
    $c1 = $pw1 - 4
    $c2 = $pw2 - 4

    if ($last) {
        $ch = $last.Char
        $charText = if ($ch.HasChar) { (($ch.Glyph + '   ' + $ch.Name)).Trim() } else { 'none (key produces no character)' }
        $keyRows = @(
            @('Key', $last.Name),
            @('Layout name', $last.LayoutName),
            @('Virtual key', $last.VkText),
            @('VK constant', $last.VkName),
            @('Scan code', $last.ScanText),
            @('Physical', $last.Code),
            @('Location', $last.Location),
            @('Category', $last.Category)
        )
        $charRows = @(
            @('Character', $charText),
            @('Unicode', $ch.Unicode),
            @('ASCII', $ch.Ascii),
            @('UTF-8', $ch.Utf8),
            @('UTF-16', $ch.Utf16),
            @('HTML', $ch.Html),
            @('PowerShell', $ch.Literal),
            @('Key state', (Format-ControlKeyState -Flags $last.Flags))
        )
    }
    else {
        $keyRows = foreach ($l in 'Key', 'Layout name', 'Virtual key', 'VK constant', 'Scan code', 'Physical', 'Location', 'Category') { , @($l, $G.Dash) }
        $charRows = foreach ($l in 'Character', 'Unicode', 'ASCII', 'UTF-8', 'UTF-16', 'HTML', 'PowerShell', 'Key state') { , @($l, $G.Dash) }
    }

    $lines.Add($pad + (Format-BoxTop -Width $pw1 -Title 'Key') + ' ' + (Format-BoxTop -Width $pw2 -Title 'Character') + $pad)
    for ($i = 0; $i -lt 8; $i++) {
        $leftStyle = if ($i -eq 0) { $T.Strong } else { $T.Value }
        $rightStyle = if ($i -eq 0 -and $last -and $last.Char.HasChar) { $T.Glyph } else { $T.Value }
        $l = Format-BoxRow -Content (Format-Field -Label $keyRows[$i][0] -Value $keyRows[$i][1] -Width $c1 -ValueStyle $leftStyle)
        $r = Format-BoxRow -Content (Format-Field -Label $charRows[$i][0] -Value $charRows[$i][1] -Width $c2 -ValueStyle $rightStyle)
        $lines.Add($pad + $l + ' ' + $r + $pad)
    }
    $lines.Add($pad + (Format-BoxBottom -Width $pw1) + ' ' + (Format-BoxBottom -Width $pw2) + $pad)

    # --- Modifier and lock indicators ---------------------------------------
    $modLine = [System.Text.StringBuilder]::new()
    $modWidth = 0
    foreach ($group in @(
            @{ Name = 'Shift'; L = 0xA0; R = 0xA1 },
            @{ Name = 'Ctrl';  L = 0xA2; R = 0xA3 },
            @{ Name = 'Alt';   L = 0xA4; R = 0xA5 },
            @{ Name = 'Win';   L = 0x5B; R = 0x5C })) {
        [void]$modLine.Append((Format-Paint -Style $T.Label -Text "$($group.Name) "))
        [void]$modLine.Append((Format-Pill -Text 'L' -On (Test-KeyDown -VirtualKey $group.L)))
        [void]$modLine.Append((Format-Pill -Text 'R' -On (Test-KeyDown -VirtualKey $group.R)))
        [void]$modLine.Append('  ')
        $modWidth += $group.Name.Length + 1 + 6 + 2
    }
    if ($State.HasFlags) {
        $caps = ($State.Flags -band 0x80) -ne 0
        $num = ($State.Flags -band 0x20) -ne 0
        $scroll = ($State.Flags -band 0x40) -ne 0
    }
    else {
        $caps = ([ShowKey.Native.Win32]::GetKeyState(0x14) -band 1) -ne 0
        $num = ([ShowKey.Native.Win32]::GetKeyState(0x90) -band 1) -ne 0
        $scroll = ([ShowKey.Native.Win32]::GetKeyState(0x91) -band 1) -ne 0
    }
    [void]$modLine.Append((Format-Pill -Text 'Caps' -On $caps) + ' ')
    [void]$modLine.Append((Format-Pill -Text 'Num' -On $num) + ' ')
    [void]$modLine.Append((Format-Pill -Text 'Scroll' -On $scroll))
    $modWidth += 6 + 1 + 5 + 1 + 8
    $lines.Add($pad + $modLine.ToString() + (' ' * [Math]::Max(0, $Width - $margin - $modWidth)))
    if ($gaps -ge 3) { $lines.Add($blank) }

    # --- History --------------------------------------------------------------
    $histHeight = $Height - $lines.Count - 1          # leave one row for the footer
    $hw = $Width - (2 * $margin)
    $hc = $hw - 4
    $cols = @{ Time = 12; St = 2; Vk = 4; Scan = 5; Code = 13; Char = 7; Info = 7 }
    $comboWidth = [Math]::Max(6, $hc - ($cols.Time + $cols.St + $cols.Vk + $cols.Scan + $cols.Code + $cols.Char + $cols.Info) - 7)
    $note = "$($State.History.Count) of $($State.HistorySize)"

    $lines.Add($pad + (Format-BoxTop -Width $hw -Title 'History' -Note $note) + $pad)
    $header = (Format-Fit 'Time' $cols.Time) + ' ' + (Format-Fit '' $cols.St) + ' ' + (Format-Fit 'Combo' $comboWidth) + ' ' +
              (Format-Fit 'VK' $cols.Vk) + ' ' + (Format-Fit 'Scan' $cols.Scan) + ' ' + (Format-Fit 'Physical' $cols.Code) + ' ' +
              (Format-Fit 'Char' $cols.Char) + ' ' + (Format-Fit 'Repeat' $cols.Info -Align Right)
    $lines.Add($pad + (Format-BoxRow -Content (Format-Paint -Style $T.Column -Text $header)) + $pad)

    $rows = [Math]::Max(0, $histHeight - 3)
    for ($i = 0; $i -lt $rows; $i++) {
        if ($i -lt $State.History.Count) {
            $h = $State.History[$i]
            $rowStyle = if ($h.Down) { $T.Value } else { $T.Muted }
            if ($h.Down) { $arrow = Format-Paint -Style $T.GoodFg -Text (Format-Fit $G.Down $cols.St) }
            else { $arrow = Format-Paint -Style $T.WarnFg -Text (Format-Fit $G.Up $cols.St) }
            $infoText = if ($h.Down) { if ($h.Repeat -gt 1) { "$($G.Times)$($h.Repeat)" } else { '' } }
                        else { Format-Duration $h.HeldMs }
            $content = (Format-Paint -Style $T.Muted -Text (Format-Fit $h.Time.ToString('HH:mm:ss.fff') $cols.Time)) + ' ' + $arrow + ' ' +
                       (Format-Paint -Style $rowStyle -Text ((Format-Fit $h.Combo $comboWidth) + ' ' +
                           (Format-Fit ('{0:X2}' -f $h.Vk) $cols.Vk) + ' ' + (Format-Fit $h.ScanShort $cols.Scan) + ' ' +
                           (Format-Fit $h.Code $cols.Code) + ' ' + (Format-Fit $h.Char.Short $cols.Char) + ' ' +
                           (Format-Fit $infoText $cols.Info -Align Right)))
        }
        elseif ($i -eq 0) {
            $content = Format-Paint -Style $T.Muted -Text (Format-Fit -Text 'No key events yet.' -Width $hc -Align Center)
        }
        else {
            $content = ' ' * $hc
        }
        $lines.Add($pad + (Format-BoxRow -Content $content) + $pad)
    }
    $lines.Add($pad + (Format-BoxBottom -Width $hw) + $pad)

    # --- Footer ---------------------------------------------------------------
    $terminal = if ($env:WT_SESSION) { 'Windows Terminal' } elseif ($env:TERM_PROGRAM -eq 'vscode') { 'VS Code' } else { 'Console Host' }
    $hostInfo = "PowerShell $($PSVersionTable.PSVersion) $($G.Dot) $terminal "
    if ($State.EscArmedAt -ge 0) {
        $hint = ' Press Esc again to quit '
        $hintText = Format-Paint -Style $T.Alert -Text $hint
    }
    else {
        $hint = ' Esc Esc  quit  ' + $G.Dot + '  all other keys are shown, not handled '
        $hintText = Format-Paint -Style $T.Muted -Text $hint
    }
    $hintWidth = Get-TextWidth $hint
    # One cell short of the full width so the bottom-right cell never triggers a scroll.
    $hostWidth = [Math]::Max(0, $Width - 1 - $hintWidth)
    $lines.Add($hintText + (Format-Paint -Style $T.Muted -Text (Format-Fit -Text $hostInfo -Width $hostWidth -Align Right)))

    return , $lines.ToArray()
}

function Write-Frame {
    <#
    .SYNOPSIS
        Draws the whole screen in a single console write to avoid flicker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $State, [switch] $Clear)

    $e = $script:Esc
    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $minWidth = 80
    $minHeight = 24

    $sb = [System.Text.StringBuilder]::new(16384)
    [void]$sb.Append("$e[?2026h")          # begin synchronized update (ignored if unsupported)
    if ($Clear) { [void]$sb.Append("$e[0m$e[2J") }

    if ($width -lt $minWidth -or $height -lt $minHeight) {
        [void]$sb.Append("$e[0m$e[2J")
        $message = "Window too small ($width x $height). Need at least $minWidth x $minHeight."
        $row = [Math]::Max(1, [Math]::Floor($height / 2))
        [void]$sb.Append("$e[$row;1H")
        [void]$sb.Append((Format-Fit -Text $message -Width ([Math]::Max(1, $width - 1)) -Align Center))
    }
    else {
        $lines = Get-FrameLine -State $State -Width $width -Height $height
        $count = [Math]::Min($lines.Count, $height)
        for ($r = 0; $r -lt $count; $r++) {
            [void]$sb.Append("$e[$($r + 1);1H")
            [void]$sb.Append($lines[$r])
        }
    }
    [void]$sb.Append("$e[0m$e[?2026l")
    [Console]::Write($sb.ToString())
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Start-ShowKey {
    <#
    .SYNOPSIS
        Sets up the console, runs the input/render loop and restores the console.
    #>
    [CmdletBinding()]
    param([int] $HistorySize, [switch] $NoKeyUp, [switch] $NoColor)

    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        throw 'ShowKey uses the Windows console API and only runs on Windows.'
    }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'ShowKey needs an interactive console; input and output must not be redirected.'
    }

    Initialize-NativeMethod
    $native = [ShowKey.Native.Win32]
    $hIn = $native::GetStdHandle($script:STD_INPUT_HANDLE)
    $hOut = $native::GetStdHandle($script:STD_OUTPUT_HANDLE)

    [uint32]$inMode = 0
    [uint32]$outMode = 0
    if (-not $native::GetConsoleMode($hIn, [ref]$inMode) -or -not $native::GetConsoleMode($hOut, [ref]$outMode)) {
        throw 'ShowKey needs a real console window (Windows Terminal, the console host or the VS Code terminal). The PowerShell ISE is not supported.'
    }

    $script:Theme = New-Theme -Plain:($NoColor -or [bool]$env:NO_COLOR)
    $state = New-AppState -HistorySize $HistorySize -NoKeyUp $NoKeyUp.IsPresent
    $originalEncoding = [Console]::OutputEncoding
    $e = $script:Esc

    try {
        # Raw input: no line editing, no echo, Ctrl+C delivered as a key, no mouse,
        # no Quick Edit, no VT input translation; window size events enabled.
        [void]$native::SetConsoleMode($hIn, [uint32]($script:ENABLE_WINDOW_INPUT -bor $script:ENABLE_EXTENDED_FLAGS))
        # Make sure ANSI escape sequences are interpreted (needed by Windows PowerShell).
        [void]$native::SetConsoleMode($hOut, [uint32]($outMode -bor $script:ENABLE_PROCESSED_OUTPUT -bor $script:ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

        # Alternate screen buffer + hidden cursor keep the user's scrollback intact.
        [Console]::Write("$e[?1049h$e[?25l$e[2J")
        [void]$native::FlushConsoleInputBuffer($hIn)

        $buffer = New-Object 'ShowKey.Native.InputRecord[]' 64
        $lastSize = ''
        $dirty = $true
        $clear = $true

        while (-not $state.Quit) {
            # Redraw on window resize (polled; resize events are not reliable in every terminal).
            $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
            if ($size -ne $lastSize) { $lastSize = $size; $dirty = $true; $clear = $true }

            # Wait up to 100 ms for input so the loop stays responsive to resizes and timeouts.
            if ($native::WaitForSingleObject($hIn, 100) -eq 0) {
                [uint32]$pending = 0
                if ($native::GetNumberOfConsoleInputEvents($hIn, [ref]$pending) -and $pending -gt 0) {
                    [uint32]$read = 0
                    $toRead = [uint32][Math]::Min([int]$pending, $buffer.Length)
                    if ($native::ReadConsoleInput($hIn, $buffer, $toRead, [ref]$read)) {
                        for ($i = 0; $i -lt $read -and -not $state.Quit; $i++) {
                            $record = $buffer[$i]
                            if ($record.EventType -eq $script:KEY_EVENT) {
                                Invoke-KeyRecord -Record $record -State $state
                                $dirty = $true
                            }
                            elseif ($record.EventType -eq $script:FOCUS_EVENT -and $record.KeyDown -eq 0) {
                                # Focus lost: releases will not be delivered, forget held keys.
                                $state.Held.Clear()
                                $dirty = $true
                            }
                        }
                    }
                }
            }

            # The "press Esc again" prompt expires after 1.5 seconds.
            if ($state.EscArmedAt -ge 0 -and ($state.Clock.ElapsedMilliseconds - $state.EscArmedAt) -gt 1500) {
                $state.EscArmedAt = -1L
                $dirty = $true
            }

            if ($dirty -and -not $state.Quit) {
                Update-HeldKey -State $state
                Write-Frame -State $state -Clear:$clear
                $dirty = $false
                $clear = $false
            }
        }
    }
    finally {
        # Always restore the terminal, even after an error or Ctrl+Break.
        [Console]::Write("$e[0m$e[?25h$e[?1049l")
        [void]$native::SetConsoleMode($hIn, $inMode)
        [void]$native::SetConsoleMode($hOut, $outMode)
        [Console]::OutputEncoding = $originalEncoding
        [void]$native::FlushConsoleInputBuffer($hIn)
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($Help) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Get-Help -Name $scriptPath -Full
    return
}

if ($Version) {
    Write-Output "ShowKey $script:AppVersion"
    return
}

Start-ShowKey -HistorySize $HistorySize -NoKeyUp:$NoKeyUp -NoColor:$NoColor
