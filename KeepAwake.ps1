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
# Direct2D + DirectWrite (built into Windows) render the colour emoji; GDI+ and
# WPF on .NET Framework can only draw emoji in monochrome.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class EmojiRenderer {
    [DllImport("d2d1.dll")]   static extern int D2D1CreateFactory(int type, ref Guid riid, IntPtr options, out IntPtr factory);
    [DllImport("dwrite.dll")] static extern int DWriteCreateFactory(int type, ref Guid riid, out IntPtr factory);
    [DllImport("gdi32.dll")]  static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]  static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]  static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes; public ushort biBitCount;
        public uint biCompression; public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public uint biClrUsed; public uint biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct RenderTargetProperties {
        public int type; public int format; public int alphaMode; public float dpiX; public float dpiY; public int usage; public int minLevel;
    }
    [StructLayout(LayoutKind.Sequential)] struct RECT   { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct RECTF  { public float left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct COLORF { public float r, g, b, a; }

    delegate int  CreateDCRenderTargetFn(IntPtr self, ref RenderTargetProperties props, out IntPtr rt);
    delegate int  BindDCFn(IntPtr self, IntPtr hdc, ref RECT rect);
    delegate int  CreateTextFormatFn(IntPtr self, [MarshalAs(UnmanagedType.LPWStr)] string family, IntPtr collection,
                                     int weight, int style, int stretch, float size,
                                     [MarshalAs(UnmanagedType.LPWStr)] string locale, out IntPtr format);
    delegate int  SetIntFn(IntPtr self, int value);
    delegate int  CreateSolidColorBrushFn(IntPtr self, ref COLORF color, IntPtr props, out IntPtr brush);
    delegate void BeginDrawFn(IntPtr self);
    delegate void DrawTextFn(IntPtr self, [MarshalAs(UnmanagedType.LPWStr)] string text, uint length, IntPtr format,
                             ref RECTF rect, IntPtr brush, int options, int measuringMode);
    delegate int  EndDrawFn(IntPtr self, IntPtr tag1, IntPtr tag2);
    delegate uint ReleaseFn(IntPtr self);

    // Fetch a COM method by vtable slot.
    static T Method<T>(IntPtr com, int slot) where T : class {
        IntPtr vtbl = Marshal.ReadIntPtr(com);
        return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T)) as T;
    }
    static void Release(IntPtr com) { if (com != IntPtr.Zero) Method<ReleaseFn>(com, 2)(com); }
    static void Check(int hr, string what) { if (hr < 0) throw new COMException(what + " failed", hr); }

    // Returns top-down premultiplied BGRA pixels (size * size * 4 bytes).
    public static byte[] Render(string text, int size) {
        IntPtr d2d = IntPtr.Zero, dw = IntPtr.Zero, rt = IntPtr.Zero, fmt = IntPtr.Zero, brush = IntPtr.Zero;
        IntPtr hdc = IntPtr.Zero, dib = IntPtr.Zero, old = IntPtr.Zero, bits;
        try {
            Guid iidD2D = new Guid("06152247-6f50-465a-9245-118bfd3b6007");   // ID2D1Factory
            Guid iidDW  = new Guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");   // IDWriteFactory
            Check(D2D1CreateFactory(0, ref iidD2D, IntPtr.Zero, out d2d), "D2D1CreateFactory");
            Check(DWriteCreateFactory(0, ref iidDW, out dw), "DWriteCreateFactory");

            BITMAPINFOHEADER bmi = new BITMAPINFOHEADER();
            bmi.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bmi.biWidth = size; bmi.biHeight = -size; bmi.biPlanes = 1; bmi.biBitCount = 32;
            hdc = CreateCompatibleDC(IntPtr.Zero);
            dib = CreateDIBSection(hdc, ref bmi, 0, out bits, IntPtr.Zero, 0);
            if (dib == IntPtr.Zero) throw new Exception("CreateDIBSection failed");
            old = SelectObject(hdc, dib);

            RenderTargetProperties props = new RenderTargetProperties();
            props.format = 87;      // DXGI_FORMAT_B8G8R8A8_UNORM
            props.alphaMode = 1;    // D2D1_ALPHA_MODE_PREMULTIPLIED
            props.dpiX = 96; props.dpiY = 96;
            Check(Method<CreateDCRenderTargetFn>(d2d, 16)(d2d, ref props, out rt), "CreateDCRenderTarget");
            RECT rc = new RECT(); rc.right = size; rc.bottom = size;
            Check(Method<BindDCFn>(rt, 57)(rt, hdc, ref rc), "BindDC");

            Check(Method<CreateTextFormatFn>(dw, 15)(dw, "Segoe UI Emoji", IntPtr.Zero, 400, 0, 5, size * 0.78f, "en-us", out fmt), "CreateTextFormat");
            Method<SetIntFn>(fmt, 3)(fmt, 2);   // SetTextAlignment(CENTER)
            Method<SetIntFn>(fmt, 4)(fmt, 2);   // SetParagraphAlignment(CENTER)

            COLORF black = new COLORF(); black.a = 1;
            Check(Method<CreateSolidColorBrushFn>(rt, 8)(rt, ref black, IntPtr.Zero, out brush), "CreateSolidColorBrush");

            RECTF layout = new RECTF(); layout.right = size; layout.bottom = size;
            Method<BeginDrawFn>(rt, 48)(rt);
            Method<DrawTextFn>(rt, 27)(rt, text, (uint)text.Length, fmt, ref layout, brush, 4 /* ENABLE_COLOR_FONT */, 0);
            Check(Method<EndDrawFn>(rt, 49)(rt, IntPtr.Zero, IntPtr.Zero), "EndDraw");

            byte[] pixels = new byte[size * size * 4];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            return pixels;
        } finally {
            Release(brush); Release(fmt); Release(rt); Release(dw); Release(d2d);
            if (old != IntPtr.Zero) SelectObject(hdc, old);
            if (dib != IntPtr.Zero) DeleteObject(dib);
            if (hdc != IntPtr.Zero) DeleteDC(hdc);
        }
    }
}
'@

function New-CoffeeIcon {
    $size = 32
    $cup  = [string][char]0x2615   # ☕

    try {
        $pixels = [EmojiRenderer]::Render($cup + [char]0xFE0F, $size)
        $bmp  = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $data = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $size, $size)),
                    [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
        [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
        $bmp.UnlockBits($data)
    } catch {
        # Fallback: GDI+ monochrome glyph in a coffee colour.
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font('Segoe UI Emoji', ($size * 0.6), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString($cup, $font, [System.Drawing.Brushes]::Peru, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $fmt)
        $g.Dispose(); $font.Dispose()
    }

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
    [void][KeepAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS)
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    $icon.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
