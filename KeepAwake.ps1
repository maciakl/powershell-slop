<#
.SYNOPSIS
    Keeps the PC awake and prevents apps like Teams from showing you as idle.

.DESCRIPTION
    - Tells Windows the system and display are in use (no sleep, no screensaver,
      no display timeout) via SetThreadExecutionState.
    - Every 60 seconds injects an F15 key press (a key that exists on no normal
      keyboard and is ignored by practically every app). This resets the
      system's "last input" timer, which is what Teams/Slack/etc. use to
      decide you are idle.
    - Shows a coffee cup tray icon; right-click it and choose Exit to stop.
    - Hides its console window by relaunching itself hidden.

    Works with the built-in Windows PowerShell 5.1 (powershell.exe). No dependencies.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\KeepAwake.ps1
#>
param(
    [int]$IntervalSeconds = 60,
    [switch]$Hidden
)

# --- Relaunch ourselves in a hidden window so no terminal stays visible -----
if (-not $Hidden) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", '-Hidden', '-IntervalSeconds', $IntervalSeconds
    )
    # Always use the built-in Windows PowerShell, even when launched from pwsh 7.
    $winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $winPS -ArgumentList $argList -WindowStyle Hidden
    exit
}

# --- Single instance -------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\KeepAwake-CoffeeCup', [ref]$createdNew)
if (-not $createdNew) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace KeepAwake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);

[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);

[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
}
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
}
[StructLayout(LayoutKind.Explicit)]
public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
}
[StructLayout(LayoutKind.Sequential)]
public struct INPUT {
    public uint type; public INPUTUNION u;
}

[DllImport("user32.dll", SetLastError = true)]
public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

public static void PressF15() {
    const ushort VK_F15 = 0x7E;
    const uint KEYEVENTF_KEYUP = 0x0002;
    INPUT[] inputs = new INPUT[2];
    inputs[0].type = 1; // INPUT_KEYBOARD
    inputs[0].u.ki.wVk = VK_F15;
    inputs[1].type = 1;
    inputs[1].u.ki.wVk = VK_F15;
    inputs[1].u.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, inputs, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
}
'@

# Belt and braces: hide the console window if one is still visible.
$consoleHwnd = [KeepAwake.Native]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) { [void][KeepAwake.Native]::ShowWindow($consoleHwnd, 0) }

$ES_CONTINUOUS       = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED  = [uint32]'0x00000001'
$ES_DISPLAY_REQUIRED = [uint32]'0x00000002'

function Set-Awake {
    [void][KeepAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
}

# --- Build the coffee cup icon ---------------------------------------------
# The taskbar follows the "system" theme (SystemUsesLightTheme), which can
# differ from the apps theme.
function Test-LightTaskbar {
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' -ErrorAction Stop
        return ($v -eq 1)
    } catch {
        return $false   # Windows 11 default is a dark taskbar
    }
}

function New-CoffeeIcon {
    $size  = 32
    $cup   = [string][char]0x2615 + [char]0xFE0E   # ☕ with text (monochrome) presentation
    $color = if (Test-LightTaskbar) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }

    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Draw the glyph as a path so it can be centred and scaled on its real outline.
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddString($cup, (New-Object System.Drawing.FontFamily('Segoe UI Emoji')), 0, 100,
                    (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $scale = ($size - 2) / [Math]::Max($b.Width, $b.Height)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate($size / 2, $size / 2)
    $m.Scale($scale, $scale)
    $m.Translate(-($b.X + $b.Width / 2), -($b.Y + $b.Height / 2))
    $path.Transform($m)

    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($brush, $path)
    $g.Dispose(); $path.Dispose(); $m.Dispose(); $brush.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hIcon).Clone()
    [void][KeepAwake.Native]::DestroyIcon($hIcon)
    $bmp.Dispose()
    return $icon
}

# --- Tray icon & menu ------------------------------------------------------
$icon = New-CoffeeIcon

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = $icon
$tray.Text    = 'Keep Awake - active'
$tray.Visible = $true

# Redraw the icon when the user switches between light and dark mode.
# SystemEvents posts to the sync context captured at subscribe time, so install
# the WinForms one first to have the handler run on this (UI) thread.
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    (New-Object System.Windows.Forms.WindowsFormsSynchronizationContext))
$themeHandler = [Microsoft.Win32.UserPreferenceChangedEventHandler]{
    param($s, $e)
    if ($e.Category -eq [Microsoft.Win32.UserPreferenceCategory]::General) {
        $old = $icon
        $script:icon = New-CoffeeIcon
        $tray.Icon = $script:icon
        $old.Dispose()
    }
}
[Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged($themeHandler)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$title = $menu.Items.Add("$([char]0x2615) Keep Awake is active")
$title.Enabled = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

# --- Keep-awake timer ------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(5, $IntervalSeconds) * 1000
$timer.Add_Tick({
    Set-Awake
    [KeepAwake.Native]::PressF15()
})

$exitItem.Add_Click({
    $timer.Stop()
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

Set-Awake
[KeepAwake.Native]::PressF15()
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    # Restore normal power behaviour and clean up.
    [Microsoft.Win32.SystemEvents]::remove_UserPreferenceChanged($themeHandler)
    [void][KeepAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS)
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    $icon.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
