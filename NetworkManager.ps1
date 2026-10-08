#Requires -Version 5.1
<#
.SYNOPSIS
    Network Manager - a console (TUI) tool for managing Wi-Fi and Ethernet connections.

.DESCRIPTION
    - Shows the current IP address, gateway and DNS servers for every Wi-Fi and Ethernet adapter
    - Enables / disables Wi-Fi and Ethernet adapters
    - Scans for Wi-Fi networks, connects (open / WPA / WPA2 / WPA3 personal), hidden networks,
      disconnect, forget saved networks
    - Switches IPv4 between DHCP and a static address, renews / releases DHCP leases
    - Sets DNS servers per adapter without touching DHCP for the IP address, with presets
      (Google, Cloudflare, AdGuard, Quad9) or back to the DHCP-provided default

    Runs on Windows PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.
    No external modules: uses the built-in NetAdapter / NetTCPIP / DnsClient modules and
    the Native Wi-Fi API (wlanapi.dll).

    Changing adapter settings requires administrator rights. When started without them the
    script elevates itself, relaunching under the same PowerShell edition it was started from.
    If Sudo for Windows is enabled in "inline" mode, the elevated copy runs inside the same
    console window; otherwise a new elevated window is opened and this one waits for it.

.PARAMETER NoElevate
    Do not request administrator rights. Status and Wi-Fi connections still work; changes to
    adapters, IP and DNS settings will fail.

.EXAMPLE
    .\NetworkManager.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [Parameter(DontShow = $true)][switch]$Elevated
)

$ErrorActionPreference = 'Stop'

#region Startup / elevation -----------------------------------------------------------------

if ($env:OS -ne 'Windows_NT') {
    Write-Error 'NetworkManager.ps1 only runs on Windows.'
    exit 1
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:IsAdmin = Test-IsAdmin

if (-not $NoElevate -and -not $script:IsAdmin) {
    if (-not $PSCommandPath) {
        Write-Warning 'Cannot elevate: run NetworkManager.ps1 as a saved file, or use -NoElevate.'
        exit 1
    }

    # Relaunch with the same host executable (powershell.exe or pwsh.exe) we are running in.
    $hostExe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Elevated')

    # Sudo for Windows: Enabled = 1 (new window), 2 (input disabled), 3 (inline).
    $sudoMode = $null
    try {
        $sudoMode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' -Name Enabled -ErrorAction Stop).Enabled
    } catch { }
    $sudo = Get-Command -Name 'sudo.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($sudo -and $sudoMode -eq 3) {
        # Inline sudo: the elevated process shares this console window.
        & $sudo.Source $hostExe @argList
        exit $LASTEXITCODE
    }

    Write-Host 'Requesting administrator rights (a new elevated window will open)...' -ForegroundColor Cyan
    if ($sudo) {
        Write-Host 'Tip: set Sudo for Windows to "Inline" (Settings > System > For developers) to stay in this window.' -ForegroundColor DarkGray
    }
    try {
        $quoted = foreach ($a in $argList) { if ($a -match '\s') { '"{0}"' -f $a } else { $a } }
        $proc = Start-Process -FilePath $hostExe -ArgumentList ($quoted -join ' ') -Verb RunAs -PassThru -Wait
        exit $proc.ExitCode
    } catch {
        Write-Warning "Elevation was cancelled or failed: $($_.Exception.Message)"
        Write-Host 'Run with -NoElevate to open in view-only mode.'
        exit 1
    }
}

if ($Host.Name -eq 'Windows PowerShell ISE Host' -or [Console]::IsInputRedirected) {
    Write-Error 'NetworkManager.ps1 needs an interactive console (Windows Terminal, conhost); the ISE and redirected input are not supported.'
    exit 1
}

#endregion

#region Native Wi-Fi API ---------------------------------------------------------------------

if (-not ('NetMgr.Wlan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace NetMgr
{
    public class WlanException : Exception
    {
        public uint Code;
        public WlanException(string op, uint code, string detail)
            : base(op + " failed (error " + code + ")" + (string.IsNullOrEmpty(detail) ? "" : ": " + detail))
        {
            Code = code;
        }
    }

    public class WlanInterfaceInfo
    {
        public Guid Guid;
        public string Description;
        public int State;
    }

    public class WlanNetwork
    {
        public string Ssid;
        public byte[] SsidBytes;
        public string ProfileName;
        public uint Signal;
        public bool Secure;
        public int Auth;
        public int Cipher;
        public bool Connected;
        public bool Connectable;
    }

    public class WlanConnection
    {
        public int State;
        public string ProfileName;
        public string Ssid;
        public uint Signal;
        public int Auth;
        public int Cipher;
        public uint RxRate;
        public uint TxRate;
    }

    public static class Wlan
    {
        [StructLayout(LayoutKind.Sequential)]
        struct DOT11_SSID
        {
            public uint Length;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Ssid;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WLAN_INTERFACE_INFO
        {
            public Guid Guid;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            public int State;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WLAN_AVAILABLE_NETWORK
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
            public DOT11_SSID Ssid;
            public int BssType;
            public uint NumberOfBssids;
            public int NetworkConnectable;
            public uint NotConnectableReason;
            public uint NumberOfPhyTypes;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public int[] PhyTypes;
            public int MorePhyTypes;
            public uint SignalQuality;
            public int SecurityEnabled;
            public int AuthAlgorithm;
            public int CipherAlgorithm;
            public uint Flags;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WLAN_PROFILE_INFO
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Name;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WLAN_ASSOCIATION_ATTRIBUTES
        {
            public DOT11_SSID Ssid;
            public int BssType;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
            public int PhyType;
            public uint PhyIndex;
            public uint SignalQuality;
            public uint RxRate;
            public uint TxRate;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WLAN_SECURITY_ATTRIBUTES
        {
            public int SecurityEnabled;
            public int OneXEnabled;
            public int AuthAlgorithm;
            public int CipherAlgorithm;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WLAN_CONNECTION_ATTRIBUTES
        {
            public int State;
            public int Mode;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
            public WLAN_ASSOCIATION_ATTRIBUTES Association;
            public WLAN_SECURITY_ATTRIBUTES Security;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WLAN_CONNECTION_PARAMETERS
        {
            public int Mode;
            [MarshalAs(UnmanagedType.LPWStr)] public string Profile;
            public IntPtr Ssid;
            public IntPtr BssidList;
            public int BssType;
            public uint Flags;
        }

        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanScan(IntPtr handle, ref Guid iface, IntPtr ssid, IntPtr ie, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanGetAvailableNetworkList(IntPtr handle, ref Guid iface, uint flags, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanGetProfileList(IntPtr handle, ref Guid iface, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] static extern uint WlanSetProfile(IntPtr handle, ref Guid iface, uint flags, string xml, string security, bool overwrite, IntPtr reserved, out uint reason);
        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] static extern uint WlanDeleteProfile(IntPtr handle, ref Guid iface, string name, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanConnect(IntPtr handle, ref Guid iface, ref WLAN_CONNECTION_PARAMETERS parameters, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanDisconnect(IntPtr handle, ref Guid iface, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanQueryInterface(IntPtr handle, ref Guid iface, int opcode, IntPtr reserved, out uint size, out IntPtr data, out int valueType);
        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] static extern uint WlanReasonCodeToString(uint reason, int size, StringBuilder buffer, IntPtr reserved);

        const int OpcodeRadioState = 4;
        const int OpcodeInterfaceState = 6;
        const int OpcodeCurrentConnection = 7;

        static IntPtr Open()
        {
            uint version;
            IntPtr handle;
            uint r = WlanOpenHandle(2, IntPtr.Zero, out version, out handle);
            if (r != 0) throw new WlanException("WlanOpenHandle", r, null);
            return handle;
        }

        static IntPtr Item(IntPtr list, int index, int size)
        {
            return new IntPtr(list.ToInt64() + 8 + (long)index * size);
        }

        static string SsidToString(DOT11_SSID ssid)
        {
            int len = (int)Math.Min(ssid.Length, 32);
            return Encoding.UTF8.GetString(ssid.Ssid, 0, len);
        }

        public static WlanInterfaceInfo[] GetInterfaces()
        {
            IntPtr h = Open();
            IntPtr list = IntPtr.Zero;
            try
            {
                uint r = WlanEnumInterfaces(h, IntPtr.Zero, out list);
                if (r != 0) throw new WlanException("WlanEnumInterfaces", r, null);
                int n = Marshal.ReadInt32(list);
                int size = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));
                List<WlanInterfaceInfo> result = new List<WlanInterfaceInfo>();
                for (int i = 0; i < n; i++)
                {
                    WLAN_INTERFACE_INFO s = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(Item(list, i, size), typeof(WLAN_INTERFACE_INFO));
                    WlanInterfaceInfo info = new WlanInterfaceInfo();
                    info.Guid = s.Guid;
                    info.Description = s.Description;
                    info.State = s.State;
                    result.Add(info);
                }
                return result.ToArray();
            }
            finally
            {
                if (list != IntPtr.Zero) WlanFreeMemory(list);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }

        public static void Scan(Guid iface)
        {
            IntPtr h = Open();
            try
            {
                uint r = WlanScan(h, ref iface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (r != 0) throw new WlanException("WlanScan", r, null);
            }
            finally { WlanCloseHandle(h, IntPtr.Zero); }
        }

        public static WlanNetwork[] GetNetworks(Guid iface)
        {
            IntPtr h = Open();
            IntPtr list = IntPtr.Zero;
            try
            {
                uint r = WlanGetAvailableNetworkList(h, ref iface, 0, IntPtr.Zero, out list);
                if (r != 0) throw new WlanException("WlanGetAvailableNetworkList", r, null);
                int n = Marshal.ReadInt32(list);
                int size = Marshal.SizeOf(typeof(WLAN_AVAILABLE_NETWORK));
                List<WlanNetwork> result = new List<WlanNetwork>();
                for (int i = 0; i < n; i++)
                {
                    WLAN_AVAILABLE_NETWORK s = (WLAN_AVAILABLE_NETWORK)Marshal.PtrToStructure(Item(list, i, size), typeof(WLAN_AVAILABLE_NETWORK));
                    WlanNetwork net = new WlanNetwork();
                    int len = (int)Math.Min(s.Ssid.Length, 32);
                    net.SsidBytes = new byte[len];
                    Array.Copy(s.Ssid.Ssid, net.SsidBytes, len);
                    net.Ssid = SsidToString(s.Ssid);
                    net.ProfileName = s.ProfileName;
                    net.Signal = s.SignalQuality;
                    net.Secure = s.SecurityEnabled != 0;
                    net.Auth = s.AuthAlgorithm;
                    net.Cipher = s.CipherAlgorithm;
                    net.Connected = (s.Flags & 1) != 0;
                    net.Connectable = s.NetworkConnectable != 0;
                    result.Add(net);
                }
                return result.ToArray();
            }
            finally
            {
                if (list != IntPtr.Zero) WlanFreeMemory(list);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }

        public static string[] GetProfiles(Guid iface)
        {
            IntPtr h = Open();
            IntPtr list = IntPtr.Zero;
            try
            {
                uint r = WlanGetProfileList(h, ref iface, IntPtr.Zero, out list);
                if (r != 0) throw new WlanException("WlanGetProfileList", r, null);
                int n = Marshal.ReadInt32(list);
                int size = Marshal.SizeOf(typeof(WLAN_PROFILE_INFO));
                List<string> result = new List<string>();
                for (int i = 0; i < n; i++)
                {
                    WLAN_PROFILE_INFO s = (WLAN_PROFILE_INFO)Marshal.PtrToStructure(Item(list, i, size), typeof(WLAN_PROFILE_INFO));
                    result.Add(s.Name);
                }
                return result.ToArray();
            }
            finally
            {
                if (list != IntPtr.Zero) WlanFreeMemory(list);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }

        public static void SetProfile(Guid iface, string xml)
        {
            IntPtr h = Open();
            try
            {
                uint reason;
                uint r = WlanSetProfile(h, ref iface, 0, xml, null, true, IntPtr.Zero, out reason);
                if (r != 0)
                {
                    StringBuilder sb = new StringBuilder(512);
                    WlanReasonCodeToString(reason, sb.Capacity, sb, IntPtr.Zero);
                    throw new WlanException("WlanSetProfile", r, sb.ToString());
                }
            }
            finally { WlanCloseHandle(h, IntPtr.Zero); }
        }

        public static void DeleteProfile(Guid iface, string name)
        {
            IntPtr h = Open();
            try
            {
                uint r = WlanDeleteProfile(h, ref iface, name, IntPtr.Zero);
                if (r != 0) throw new WlanException("WlanDeleteProfile", r, null);
            }
            finally { WlanCloseHandle(h, IntPtr.Zero); }
        }

        public static void Connect(Guid iface, string profile)
        {
            IntPtr h = Open();
            try
            {
                WLAN_CONNECTION_PARAMETERS p = new WLAN_CONNECTION_PARAMETERS();
                p.Mode = 0;       // wlan_connection_mode_profile
                p.Profile = profile;
                p.BssType = 1;    // dot11_BSS_type_infrastructure
                uint r = WlanConnect(h, ref iface, ref p, IntPtr.Zero);
                if (r != 0) throw new WlanException("WlanConnect", r, null);
            }
            finally { WlanCloseHandle(h, IntPtr.Zero); }
        }

        public static void Disconnect(Guid iface)
        {
            IntPtr h = Open();
            try
            {
                uint r = WlanDisconnect(h, ref iface, IntPtr.Zero);
                if (r != 0) throw new WlanException("WlanDisconnect", r, null);
            }
            finally { WlanCloseHandle(h, IntPtr.Zero); }
        }

        // wlan_interface_state: 0 not ready, 1 connected, 2 ad hoc formed, 3 disconnecting,
        // 4 disconnected, 5 associating, 6 discovering, 7 authenticating
        public static int GetState(Guid iface)
        {
            IntPtr h = Open();
            IntPtr data = IntPtr.Zero;
            try
            {
                uint size; int type;
                uint r = WlanQueryInterface(h, ref iface, OpcodeInterfaceState, IntPtr.Zero, out size, out data, out type);
                if (r != 0) throw new WlanException("WlanQueryInterface", r, null);
                return Marshal.ReadInt32(data);
            }
            finally
            {
                if (data != IntPtr.Zero) WlanFreeMemory(data);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }

        // Returns null when not connected.
        public static WlanConnection GetConnection(Guid iface)
        {
            IntPtr h = Open();
            IntPtr data = IntPtr.Zero;
            try
            {
                uint size; int type;
                uint r = WlanQueryInterface(h, ref iface, OpcodeCurrentConnection, IntPtr.Zero, out size, out data, out type);
                if (r != 0) return null;
                WLAN_CONNECTION_ATTRIBUTES a = (WLAN_CONNECTION_ATTRIBUTES)Marshal.PtrToStructure(data, typeof(WLAN_CONNECTION_ATTRIBUTES));
                WlanConnection c = new WlanConnection();
                c.State = a.State;
                c.ProfileName = a.ProfileName;
                c.Ssid = SsidToString(a.Association.Ssid);
                c.Signal = a.Association.SignalQuality;
                c.Auth = a.Security.AuthAlgorithm;
                c.Cipher = a.Security.CipherAlgorithm;
                c.RxRate = a.Association.RxRate;
                c.TxRate = a.Association.TxRate;
                return c;
            }
            finally
            {
                if (data != IntPtr.Zero) WlanFreeMemory(data);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }

        // Returns { software, hardware }: 1 = on, 2 = off, 0 = unknown.
        public static int[] GetRadioState(Guid iface)
        {
            IntPtr h = Open();
            IntPtr data = IntPtr.Zero;
            try
            {
                uint size; int type;
                uint r = WlanQueryInterface(h, ref iface, OpcodeRadioState, IntPtr.Zero, out size, out data, out type);
                if (r != 0) return new int[] { 0, 0 };
                int n = Marshal.ReadInt32(data);
                int sw = n > 0 ? 2 : 0, hw = n > 0 ? 2 : 0;
                for (int i = 0; i < n && i < 64; i++)
                {
                    if (Marshal.ReadInt32(data, 4 + i * 12 + 4) == 1) sw = 1;
                    if (Marshal.ReadInt32(data, 4 + i * 12 + 8) == 1) hw = 1;
                }
                return new int[] { sw, hw };
            }
            finally
            {
                if (data != IntPtr.Zero) WlanFreeMemory(data);
                WlanCloseHandle(h, IntPtr.Zero);
            }
        }
    }
}
'@
}

#endregion

#region Network data ------------------------------------------------------------------------

$script:DnsPresets = @(
    [pscustomobject]@{ Name = 'Google';         V4 = @('8.8.8.8', '8.8.4.4');           V6 = @('2001:4860:4860::8888', '2001:4860:4860::8844') }
    [pscustomobject]@{ Name = 'Cloudflare';     V4 = @('1.1.1.1', '1.0.0.1');           V6 = @('2606:4700:4700::1111', '2606:4700:4700::1001') }
    [pscustomobject]@{ Name = 'AdGuard';        V4 = @('94.140.14.14', '94.140.15.15'); V6 = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff') }
    [pscustomobject]@{ Name = 'AdGuard Family'; V4 = @('94.140.14.15', '94.140.15.16'); V6 = @('2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff') }
    [pscustomobject]@{ Name = 'Quad9';          V4 = @('9.9.9.9', '149.112.112.112');   V6 = @('2620:fe::fe', '2620:fe::9') }
)

$script:Status = @()
$script:WlanAvailable = $true

function Get-AdapterKind {
    param($Adapter)
    switch ([int]$Adapter.NdisPhysicalMedium) {
        9 { 'Wi-Fi' }
        14 { 'Ethernet' }
        default { $null }
    }
}

function Get-WlanInterfaceMap {
    $map = @{}
    if (-not $script:WlanAvailable) { return $map }
    try {
        foreach ($w in [NetMgr.Wlan]::GetInterfaces()) { $map[$w.Guid.ToString()] = $w }
    } catch {
        # WLAN AutoConfig service not running / not installed.
        $script:WlanAvailable = $false
    }
    $map
}

function Split-ServerList {
    param([string]$Value)
    if (-not $Value) { return @() }
    @($Value -split '[,\s]+' | Where-Object { $_ })
}

function Get-DnsPresetName {
    param([string[]]$Servers)
    if (-not $Servers -or $Servers.Count -eq 0) { return $null }
    foreach ($p in $script:DnsPresets) {
        $all = @($p.V4) + @($p.V6)
        $unknown = @($Servers | Where-Object { $all -notcontains $_ })
        if ($unknown.Count -eq 0) { return $p.Name }
    }
    $null
}

# Status reads use CIM directly: the NetAdapter / NetTCPIP / DnsClient modules take several
# seconds to import, so they are only loaded when a setting is actually changed.
$script:CimNs = 'root/StandardCimv2'

function Get-NetCim {
    param([string]$Class, [string]$Filter)
    @(Get-CimInstance -Namespace $script:CimNs -ClassName $Class -Filter $Filter -ErrorAction SilentlyContinue)
}

function Format-LinkSpeed {
    param([double]$Bps)
    if ($Bps -le 0) { return '' }
    if ($Bps -ge 1e9) { return ('{0:0.#} Gbps' -f ($Bps / 1e9)) }
    '{0:0.#} Mbps' -f ($Bps / 1e6)
}

function Get-AdapterStatus {
    param($Adapter, [hashtable]$WlanMap)

    $kind = Get-AdapterKind $Adapter
    $idx = $Adapter.InterfaceIndex
    $guid = ([guid]$Adapter.InterfaceGuid).ToString()
    $guidB = '{' + $guid.ToUpperInvariant() + '}'

    # MSFT_NetAdapter: State 3 = disabled; InterfaceOperationalStatus 1 = up; MediaConnectState 2 = disconnected.
    $status = if ($Adapter.State -eq 3) { 'Disabled' }
    elseif ($Adapter.InterfaceOperationalStatus -eq 1) { 'Up' }
    elseif ($Adapter.MediaConnectState -eq 2) { 'Disconnected' }
    else { 'Not present' }

    $s = [ordered]@{
        Name        = $Adapter.Name
        Description = $Adapter.InterfaceDescription
        Kind        = $kind
        Index       = $idx
        Guid        = [guid]$guid
        Status      = $status
        Enabled     = ($status -ne 'Disabled')
        Up          = ($status -eq 'Up')
        LinkSpeed   = Format-LinkSpeed $Adapter.Speed
        Mac         = $Adapter.PermanentAddress
        Dhcp        = $true
        IPv4        = @()
        IPv6        = @()
        Gateway     = @()
        Dns4        = @()
        Dns6        = @()
        DnsStatic   = $false
        DnsPreset   = $null
        Ssid        = $null
        Signal      = $null
        RadioOff    = $false
        Wlan        = $null
        HasIPv6     = $true
    }

    # Persistent configuration lives in the registry and is readable even for disabled adapters.
    $reg4 = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guidB" -ErrorAction SilentlyContinue
    $reg6 = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guidB" -ErrorAction SilentlyContinue
    if ($reg4 -and $null -ne $reg4.PSObject.Properties['EnableDHCP']) { $s.Dhcp = ($reg4.EnableDHCP -eq 1) }
    $static4 = @(); $static6 = @()
    if ($reg4 -and $reg4.PSObject.Properties['NameServer']) { $static4 = Split-ServerList $reg4.NameServer }
    if ($reg6 -and $reg6.PSObject.Properties['NameServer']) { $static6 = Split-ServerList $reg6.NameServer }
    $s.DnsStatic = ($static4.Count + $static6.Count) -gt 0

    if ($s.Enabled) {
        # AddressFamily: 2 = IPv4, 23 = IPv6
        $ipIfs = Get-NetCim 'MSFT_NetIPInterface' "InterfaceIndex = $idx"
        $ipIf4 = $ipIfs | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -First 1
        if ($ipIf4) { $s.Dhcp = ($ipIf4.Dhcp -eq 1) }
        $s.HasIPv6 = [bool]($ipIfs | Where-Object { $_.AddressFamily -eq 23 })

        $addrs = Get-NetCim 'MSFT_NetIPAddress' "InterfaceIndex = $idx"
        $s.IPv4 = @($addrs | Where-Object { $_.AddressFamily -eq 2 } |
            ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        # Skip link-local and temporary (SuffixOrigin 5 = random) IPv6 addresses.
        $s.IPv6 = @($addrs | Where-Object { $_.AddressFamily -eq 23 -and $_.IPAddress -notlike 'fe80*' -and $_.SuffixOrigin -ne 5 } |
            ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        $s.Gateway = @(Get-NetCim 'MSFT_NetRoute' "InterfaceIndex = $idx AND DestinationPrefix = '0.0.0.0/0'" |
            Select-Object -ExpandProperty NextHop -Unique)

        $dns = Get-NetCim 'MSFT_DNSClientServerAddress' "InterfaceIndex = $idx"
        $s.Dns4 = @($dns | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
        $s.Dns6 = @($dns | Where-Object { $_.AddressFamily -eq 23 } | ForEach-Object { $_.ServerAddresses } |
            Where-Object { $_ -notlike 'fec0:0:0:ffff::*' } | Select-Object -Unique)
    }
    if ($s.DnsStatic) {
        if ($static4.Count) { $s.Dns4 = $static4 }
        if ($static6.Count) { $s.Dns6 = $static6 }
        $s.DnsPreset = Get-DnsPresetName (@($static4) + @($static6))
    }

    if ($kind -eq 'Wi-Fi' -and $WlanMap.ContainsKey($guid)) {
        $s.Wlan = $WlanMap[$guid]
        try {
            $radio = [NetMgr.Wlan]::GetRadioState($s.Guid)
            $s.RadioOff = ($radio[0] -eq 2 -or $radio[1] -eq 2)
            $conn = [NetMgr.Wlan]::GetConnection($s.Guid)
            if ($conn -and $conn.State -eq 1) {
                $s.Ssid = if ($conn.Ssid) { $conn.Ssid } else { $conn.ProfileName }
                $s.Signal = $conn.Signal
            }
        } catch { }
    }
    if ($kind -eq 'Wi-Fi' -and $s.Up -and -not $s.Ssid) {
        $netProfile = Get-NetCim 'MSFT_NetConnectionProfile' "InterfaceIndex = $idx" | Select-Object -First 1
        if ($netProfile) { $s.Ssid = $netProfile.Name }
    }

    [pscustomobject]$s
}

function Update-Status {
    Show-Busy 'Reading network configuration...'
    $map = Get-WlanInterfaceMap
    # Physical Wi-Fi (NdisPhysicalMedium 9) and Ethernet (14) adapters, including disabled ones.
    $adapters = @(Get-NetCim 'MSFT_NetAdapter' 'HardwareInterface = TRUE AND (NdisPhysicalMedium = 9 OR NdisPhysicalMedium = 14)' |
        Sort-Object @{ Expression = { if ((Get-AdapterKind $_) -eq 'Wi-Fi') { 0 } else { 1 } } }, Name)
    $script:Status = @(foreach ($a in $adapters) { Get-AdapterStatus $a $map })
}

function Get-StatusByName {
    param([string]$Name)
    $script:Status | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Get-AuthLabel {
    param([int]$Auth, [int]$Cipher, [bool]$Secure)
    switch ($Auth) {
        1 { if ($Secure) { 'WEP' } else { 'Open' } }
        2 { 'WEP' }
        3 { 'WPA-Enterprise' }
        4 { 'WPA-Personal' }
        6 { 'WPA2-Enterprise' }
        7 { 'WPA2-Personal' }
        8 { 'WPA3-Enterprise' }
        9 { 'WPA3-Personal' }
        10 { 'Enhanced Open' }
        11 { 'WPA3-Enterprise' }
        default { 'Unknown' }
    }
}

#endregion

#region Console UI primitives ----------------------------------------------------------------

$script:UI = @{ W = 0; H = 0 }
$script:HBar = [string][char]0x2500
$script:BarFull = [char]0x2588
$script:BarEmpty = [char]0x2591

function New-Buffer { New-Object 'System.Collections.Generic.List[object]' }

# Add-Line $buffer 'text' Color 'more text' Color ...
function Add-Line {
    param(
        [System.Collections.Generic.List[object]]$Buffer,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Parts
    )
    $segs = @()
    if ($Parts) {
        for ($i = 0; $i -lt $Parts.Count; $i += 2) {
            $fg = if ($i + 1 -lt $Parts.Count -and $Parts[$i + 1]) { [string]$Parts[$i + 1] } else { 'Gray' }
            $segs += [pscustomobject]@{ T = [string]$Parts[$i]; F = $fg; B = $null; Fill = $false }
        }
    }
    $Buffer.Add($segs)
}

# Full-width line with a background color.
function Add-Bar {
    param([System.Collections.Generic.List[object]]$Buffer, [string]$Text, [string]$Fg = 'Black', [string]$Bg = 'Cyan')
    $Buffer.Add(@([pscustomobject]@{ T = $Text; F = $Fg; B = $Bg; Fill = $true }))
}

function Add-Rule {
    param([System.Collections.Generic.List[object]]$Buffer)
    Add-Line $Buffer ($script:HBar * ([Console]::WindowWidth - 1)) 'DarkGray'
}

function Add-Title {
    param([System.Collections.Generic.List[object]]$Buffer, [string]$Title)
    $left = " Network Manager  >  $Title"
    if ($Title -eq 'Network Manager') { $left = ' Network Manager' }
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' }
    $right = '{0} {1}  |  {2} ' -f $edition, $PSVersionTable.PSVersion, $(if ($script:IsAdmin) { 'Administrator' } else { 'NOT elevated (view only)' })
    $w = [Console]::WindowWidth - 1
    $gap = $w - $left.Length - $right.Length
    $text = if ($gap -ge 1) { $left + (' ' * $gap) + $right } else { $left }
    Add-Bar $Buffer $text 'Black' $(if ($script:IsAdmin) { 'DarkCyan' } else { 'DarkYellow' })
    Add-Line $Buffer
}

function Show-Frame {
    param([System.Collections.Generic.List[object]]$Buffer)
    $w = [Math]::Max(20, [Console]::WindowWidth)
    $h = [Math]::Max(5, [Console]::WindowHeight)
    if ($w -ne $script:UI.W -or $h -ne $script:UI.H) {
        Clear-Host
        $script:UI.W = $w; $script:UI.H = $h
    }
    try { [Console]::CursorVisible = $false } catch { }
    [Console]::SetCursorPosition(0, 0)
    $width = $w - 1
    $rows = $h - 1
    $row = 0
    foreach ($line in $Buffer) {
        if ($row -ge $rows) { break }
        $used = 0
        foreach ($seg in $line) {
            if ($used -ge $width) { break }
            $t = $seg.T
            if ($t.Length -gt $width - $used) { $t = $t.Substring(0, $width - $used) }
            if ($seg.Fill) { $t = $t.PadRight($width - $used) }
            if ($t.Length -eq 0) { continue }
            if ($seg.B) { Write-Host $t -NoNewline -ForegroundColor $seg.F -BackgroundColor $seg.B }
            else { Write-Host $t -NoNewline -ForegroundColor $seg.F }
            $used += $t.Length
        }
        Write-Host (' ' * ($width - $used))
        $row++
    }
    while ($row -lt $rows) { Write-Host (' ' * $width); $row++ }
}

# Waits for a key. Returns $null when the window was resized (so the caller redraws).
function Read-KeyOrResize {
    $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
    try {
        while (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 60
            if ([Console]::WindowWidth -ne $w -or [Console]::WindowHeight -ne $h) { return $null }
        }
    } catch { }
    [Console]::ReadKey($true)
}

function Show-Busy {
    param([string]$Message)
    $buf = New-Buffer
    Add-Title $buf 'Working'
    Add-Line $buf "  $Message" 'Yellow'
    Show-Frame $buf
}

function New-MenuItem {
    param([string]$Label, $Value, [string]$Color = 'Gray', [switch]$Separator)
    [pscustomobject]@{ Label = $Label; Value = $Value; Color = $Color; Separator = [bool]$Separator }
}

<#
  Generic arrow-key menu. Returns @{ Value; Index } or $null on Esc / Backspace.
  -Header is a scriptblock receiving the buffer, used to draw information above the items.
  -Hotkeys maps a character (upper case) to a value returned immediately.
#>
function Select-Menu {
    param(
        [string]$Title,
        [scriptblock]$Header,
        [object[]]$Items,
        [int]$Index = 0,
        [hashtable]$Hotkeys = @{},
        [string]$Help = 'Up/Down move   Enter select   Esc back'
    )
    $selectable = @(for ($i = 0; $i -lt $Items.Count; $i++) { if (-not $Items[$i].Separator) { $i } })
    if ($selectable.Count -eq 0) { return $null }
    $pos = [Array]::IndexOf($selectable, $Index)
    if ($pos -lt 0) { $pos = 0 }
    $top = 0

    while ($true) {
        $sel = $selectable[$pos]
        $h = [Console]::WindowHeight

        $head = New-Buffer
        if ($Header) { & $Header $head }

        $buf = New-Buffer
        Add-Title $buf $Title
        # Items get priority over header lines when the window is small.
        $fixed = $buf.Count + 2   # blank + help
        $itemRoom = [Math]::Max(3, $h - 1 - $fixed - $head.Count - 1)
        $itemRoom = [Math]::Min($itemRoom, $Items.Count)
        $headRoom = [Math]::Max(0, $h - 1 - $fixed - $itemRoom - 1)
        if ($head.Count -le $headRoom) {
            foreach ($l in $head) { $buf.Add($l) }
        } elseif ($headRoom -gt 0) {
            for ($i = 0; $i -lt $headRoom - 1; $i++) { $buf.Add($head[$i]) }
            Add-Line $buf '  ... (enlarge the window to see more)' 'DarkGray'
        }
        if ($head.Count -gt 0 -and $headRoom -gt 0) { Add-Line $buf }

        if ($sel -lt $top) { $top = $sel }
        elseif ($sel -ge $top + $itemRoom) { $top = $sel - $itemRoom + 1 }
        if ($top -gt $Items.Count - $itemRoom) { $top = [Math]::Max(0, $Items.Count - $itemRoom) }

        for ($i = $top; $i -lt [Math]::Min($Items.Count, $top + $itemRoom); $i++) {
            $it = $Items[$i]
            if ($it.Separator) { Add-Line $buf ('   ' + $it.Label) 'DarkGray' }
            elseif ($i -eq $sel) { Add-Bar $buf (' > ' + $it.Label) 'Black' 'Cyan' }
            else { Add-Line $buf ('   ' + $it.Label) $it.Color }
        }
        while ($buf.Count -lt $h - 2) { Add-Line $buf }
        Add-Line $buf (' ' + $Help) 'DarkGray'
        Show-Frame $buf

        $key = Read-KeyOrResize
        if ($null -eq $key) { continue }
        switch ($key.Key) {
            'UpArrow' { if ($pos -gt 0) { $pos-- } else { $pos = $selectable.Count - 1 } }
            'DownArrow' { if ($pos -lt $selectable.Count - 1) { $pos++ } else { $pos = 0 } }
            'Home' { $pos = 0 }
            'End' { $pos = $selectable.Count - 1 }
            'PageUp' { $pos = [Math]::Max(0, $pos - 10) }
            'PageDown' { $pos = [Math]::Min($selectable.Count - 1, $pos + 10) }
            'Enter' { return [pscustomobject]@{ Value = $Items[$sel].Value; Index = $sel } }
            'Escape' { return $null }
            'Backspace' { return $null }
            'LeftArrow' { return $null }
            default {
                $c = [string]$key.KeyChar
                if ($c) {
                    $c = $c.ToUpperInvariant()
                    if ($Hotkeys.ContainsKey($c)) { return [pscustomobject]@{ Value = $Hotkeys[$c]; Index = $sel } }
                    $n = 0
                    if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le [Math]::Min(9, $selectable.Count)) {
                        $pos = $n - 1
                        return [pscustomobject]@{ Value = $Items[$selectable[$pos]].Value; Index = $selectable[$pos] }
                    }
                }
            }
        }
    }
}

function Show-Message {
    param([string]$Title, [string[]]$Lines, [ValidateSet('Info', 'Success', 'Error', 'Warning')][string]$Kind = 'Info')
    $color = @{ Info = 'Gray'; Success = 'Green'; Error = 'Red'; Warning = 'Yellow' }[$Kind]
    while ($true) {
        $buf = New-Buffer
        Add-Title $buf $Title
        foreach ($l in $Lines) {
            # Wrap long lines to the window width.
            $max = [Console]::WindowWidth - 5
            $rest = [string]$l
            do {
                $chunk = if ($rest.Length -gt $max) { $rest.Substring(0, $max) } else { $rest }
                Add-Line $buf ('  ' + $chunk) $color
                $rest = $rest.Substring($chunk.Length)
            } while ($rest.Length -gt 0)
        }
        Add-Line $buf
        Add-Line $buf '  Press any key to continue...' 'DarkGray'
        Show-Frame $buf
        if ($null -ne (Read-KeyOrResize)) { return }
    }
}

function Confirm-Choice {
    param([string]$Title, [string[]]$Question, [string]$Yes = 'Yes', [string]$No = 'No', [switch]$DefaultNo)
    $items = @((New-MenuItem $Yes $true), (New-MenuItem $No $false))
    $hdr = { param($b) foreach ($q in $Question) { Add-Line $b "  $q" 'Yellow' } }.GetNewClosure()
    $r = Select-Menu -Title $Title -Header $hdr -Items $items -Index $(if ($DefaultNo) { 1 } else { 0 })
    ($null -ne $r -and $r.Value)
}

# Line-mode prompt. Returns $null when the user enters nothing and there is no default.
function Read-Input {
    param([string]$Title, [string[]]$Info, [string]$Prompt, [string]$Default, [switch]$Secure)
    $buf = New-Buffer
    Add-Title $buf $Title
    foreach ($i in $Info) { Add-Line $buf "  $i" 'Gray' }
    Add-Line $buf '  (leave empty to cancel)' 'DarkGray'
    Show-Frame $buf
    [Console]::SetCursorPosition(0, $buf.Count + 1)
    try { [Console]::CursorVisible = $true } catch { }
    $script:UI.W = 0  # force a full redraw afterwards

    $label = if ($Default) { "  $Prompt [$Default]" } else { "  $Prompt" }
    if ($Secure) {
        $sec = Read-Host -Prompt $label -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } else {
        $value = Read-Host -Prompt $label
    }
    try { [Console]::CursorVisible = $false } catch { }
    if (-not $value) { if ($Default) { return $Default } else { return $null } }
    $value.Trim()
}

function Get-ErrorText {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e.InnerException -and -not ($e -is [NetMgr.WlanException])) { $e = $e.InnerException }
    $msg = $e.Message
    if (-not $script:IsAdmin -and ($msg -match 'denied|Zugriff|privilege|elevat' -or $e.HResult -eq -2147024891)) {
        $msg += '  (Administrator rights are required: restart without -NoElevate.)'
    }
    $msg
}

#endregion

#region Status rendering ---------------------------------------------------------------------

function Get-StateText {
    param($S)
    if (-not $S.Enabled) { return @('Disabled', 'DarkGray') }
    if ($S.Up) { return @('Connected', 'Green') }
    if ($S.Kind -eq 'Wi-Fi' -and $S.RadioOff) { return @('Radio off (airplane mode / switch)', 'Yellow') }
    if ($S.Status -eq 'Disconnected') { return @('Disconnected', 'Yellow') }
    @($S.Status, 'Yellow')
}

function Get-SignalBars {
    param([int]$Signal)
    $n = [Math]::Min(4, [Math]::Max(1, [int][Math]::Ceiling($Signal / 25.0)))
    ([string]$script:BarFull * $n) + ([string]$script:BarEmpty * (4 - $n))
}

function Add-AdapterLines {
    param([System.Collections.Generic.List[object]]$Buffer, $S, [switch]$Brief)
    $state = Get-StateText $S
    $speed = if ($S.Up -and $S.LinkSpeed) { "  $($S.LinkSpeed)" } else { '' }
    Add-Line $Buffer '  ' $null ('{0,-9}' -f $S.Kind) 'Cyan' (' {0}  ' -f $S.Name) 'White' $state[0] $state[1] $speed 'DarkGray' ("  $($S.Description)") 'DarkGray'
    if (-not $S.Enabled) { return }

    if ($S.Kind -eq 'Wi-Fi' -and $S.Ssid) {
        $sig = if ($null -ne $S.Signal) { '  ' + (Get-SignalBars $S.Signal) + " $($S.Signal)%" } else { '' }
        Add-Line $Buffer '      Network   ' 'DarkGray' $S.Ssid 'White' $sig 'Green'
    }

    $mode = if ($S.Dhcp) { 'DHCP' } else { 'static' }
    $ip4 = if ($S.IPv4.Count) { $S.IPv4 -join ', ' } else { '-' }
    $gw = if ($S.Gateway.Count) { $S.Gateway -join ', ' } else { '-' }
    Add-Line $Buffer '      IPv4      ' 'DarkGray' $ip4 'White' "  ($mode)" 'DarkGray' '   Gateway ' 'DarkGray' $gw 'White'
    if (-not $Brief -and $S.IPv6.Count) {
        Add-Line $Buffer '      IPv6      ' 'DarkGray' (($S.IPv6 | Select-Object -First 2) -join ', ') 'Gray'
    }

    $dnsSource = if ($S.DnsStatic) {
        if ($S.DnsPreset) { "(manual: $($S.DnsPreset))" } else { '(manual)' }
    } else { '(automatic from DHCP)' }
    $dnsColor = if ($S.DnsStatic) { 'Magenta' } else { 'DarkGray' }
    $dns4 = if ($S.Dns4.Count) { $S.Dns4 -join ', ' } else { '-' }
    Add-Line $Buffer '      DNS       ' 'DarkGray' $dns4 'White' "  $dnsSource" $dnsColor
    if (-not $Brief -and $S.Dns6.Count) {
        Add-Line $Buffer '                ' 'DarkGray' ($S.Dns6 -join ', ') 'Gray'
    }
}

function Add-StatusLines {
    param([System.Collections.Generic.List[object]]$Buffer)
    if ($script:Status.Count -eq 0) {
        Add-Line $Buffer '  No Wi-Fi or Ethernet adapters found.' 'Yellow'
        return
    }
    $first = $true
    foreach ($s in $script:Status) {
        if (-not $first) { Add-Line $Buffer }
        Add-AdapterLines $Buffer $s
        $first = $false
    }
    Add-Line $Buffer
    Add-Rule $Buffer
}

#endregion

#region Adapter selection & enable / disable -------------------------------------------------

# Lets the user pick an adapter. Returns the status object or $null.
function Select-Adapter {
    param([string]$Title, [string]$Kind, [switch]$IncludeAll, [switch]$EnabledOnly, [switch]$AutoPickSingle)
    $list = @($script:Status | Where-Object { (-not $Kind -or $_.Kind -eq $Kind) -and (-not $EnabledOnly -or $_.Enabled) })
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1 -and $AutoPickSingle -and -not $IncludeAll) { return $list[0] }

    $items = @(foreach ($s in $list) {
            $state = Get-StateText $s
            New-MenuItem ('{0,-9} {1,-28} {2}' -f $s.Kind, $s.Name, $state[0]) $s.Name
        })
    if ($IncludeAll -and $list.Count -gt 1) { $items += New-MenuItem 'All Wi-Fi and Ethernet adapters' '*' }
    $r = Select-Menu -Title $Title -Header { param($b) Add-Line $b '  Choose an adapter:' 'Gray' } -Items $items
    if (-not $r) { return $null }
    if ($r.Value -eq '*') { return '*' }
    Get-StatusByName $r.Value
}

function Set-AdapterEnabled {
    param($S, [bool]$Enable)
    if ($Enable) {
        Show-Busy "Enabling $($S.Name)..."
        Enable-NetAdapter -Name $S.Name -Confirm:$false
    } else {
        Show-Busy "Disabling $($S.Name)..."
        Disable-NetAdapter -Name $S.Name -Confirm:$false
    }
}

function Show-AdaptersScreen {
    $index = 0
    while ($true) {
        $items = @(foreach ($s in $script:Status) {
                $state = Get-StateText $s
                $action = if ($s.Enabled) { 'disable' } else { 'enable' }
                New-MenuItem ('{0,-9} {1,-28} {2,-14} -> Enter to {3}' -f $s.Kind, $s.Name, $state[0], $action) $s.Name $state[1]
            })
        if ($items.Count -eq 0) { Show-Message 'Adapters' @('No Wi-Fi or Ethernet adapters found.') 'Warning'; return }
        $r = Select-Menu -Title 'Enable / disable adapters' -Items $items -Index $index -Header {
            param($b) Add-Line $b '  Select an adapter and press Enter to toggle it on or off.' 'Gray'
        }
        if (-not $r) { return }
        $index = $r.Index
        $s = Get-StatusByName $r.Value
        if ($s.Enabled) {
            $warn = @("Disable $($s.Kind) adapter '$($s.Name)'?")
            if ($s.Up) { $warn += 'It is currently connected - you will lose this connection.' }
            if (-not (Confirm-Choice -Title 'Disable adapter' -Question $warn -Yes 'Disable' -No 'Cancel' -DefaultNo)) { continue }
        }
        try {
            Set-AdapterEnabled $s (-not $s.Enabled)
            Start-Sleep -Milliseconds 1500
        } catch {
            Show-Message 'Error' @("Could not change '$($s.Name)':", (Get-ErrorText $_)) 'Error'
        }
        Update-Status
    }
}

#endregion

#region Wi-Fi --------------------------------------------------------------------------------

function ConvertTo-XmlText { param([string]$Text) [Security.SecurityElement]::Escape($Text) }

function New-WifiProfileXml {
    param(
        [string]$Ssid,
        [byte[]]$SsidBytes,
        [ValidateSet('open', 'WEP', 'WPAPSK', 'WPA2PSK', 'WPA3SAE', 'OWE')][string]$Security,
        [string]$Encryption = 'AES',
        [string]$Key,
        [bool]$AutoConnect = $true,
        [bool]$Hidden = $false
    )
    if (-not $SsidBytes) { $SsidBytes = [Text.Encoding]::UTF8.GetBytes($Ssid) }
    $hex = -join ($SsidBytes | ForEach-Object { $_.ToString('X2') })
    $name = ConvertTo-XmlText $Ssid
    $auth = $Security
    $enc = $Encryption
    $keyXml = ''
    switch ($Security) {
        'open' { $enc = 'none' }
        'OWE' { $enc = 'AES' }
        'WEP' {
            $auth = 'open'; $enc = 'WEP'
            $keyXml = "<sharedKey><keyType>networkKey</keyType><protected>false</protected><keyMaterial>$(ConvertTo-XmlText $Key)</keyMaterial></sharedKey>"
        }
        default {
            $keyXml = "<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$(ConvertTo-XmlText $Key)</keyMaterial></sharedKey>"
        }
    }
    $mode = if ($AutoConnect) { 'auto' } else { 'manual' }
    $nonBroadcast = if ($Hidden) { 'true' } else { 'false' }
    @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$name</name>
  <SSIDConfig>
    <SSID><hex>$hex</hex><name>$name</name></SSID>
    <nonBroadcast>$nonBroadcast</nonBroadcast>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>$mode</connectionMode>
  <MSM>
    <security>
      <authEncryption><authentication>$auth</authentication><encryption>$enc</encryption><useOneX>false</useOneX></authEncryption>
      $keyXml
    </security>
  </MSM>
</WLANProfile>
"@
}

# Maps a scanned network to profile settings. Returns $null for unsupported (enterprise) networks.
function Get-ProfileSecurity {
    param($Net)
    $enc = if ($Net.Cipher -eq 2) { 'TKIP' } else { 'AES' }
    switch ($Net.Auth) {
        1 { if ($Net.Secure) { return @{ Security = 'WEP'; Encryption = 'WEP' } } else { return @{ Security = 'open'; Encryption = 'none' } } }
        2 { return @{ Security = 'WEP'; Encryption = 'WEP' } }
        4 { return @{ Security = 'WPAPSK'; Encryption = $enc } }
        7 { return @{ Security = 'WPA2PSK'; Encryption = $enc } }
        9 { return @{ Security = 'WPA3SAE'; Encryption = 'AES' } }
        10 { return @{ Security = 'OWE'; Encryption = 'AES' } }
    }
    $null
}

function Test-WifiKey {
    param([string]$Security, [string]$Key)
    switch ($Security) {
        'open' { return $true }
        'OWE' { return $true }
        'WEP' { return (($Key.Length -in @(5, 13)) -or (($Key.Length -in @(10, 26)) -and $Key -match '^[0-9a-fA-F]+$')) }
        default { return (($Key.Length -ge 8 -and $Key.Length -le 63) -or ($Key.Length -eq 64 -and $Key -match '^[0-9a-fA-F]+$')) }
    }
}

# Starts a connection with a profile and waits for the outcome.
function Wait-WifiConnection {
    param([guid]$Guid, [string]$ProfileName, [string]$Ssid, [int]$TimeoutSeconds = 25)
    Show-Busy "Connecting to '$Ssid'..."
    [NetMgr.Wlan]::Connect($Guid, $ProfileName)
    $start = Get-Date
    $downCount = 0
    Start-Sleep -Milliseconds 800
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        $conn = [NetMgr.Wlan]::GetConnection($Guid)
        if ($conn -and $conn.State -eq 1 -and $conn.ProfileName -eq $ProfileName) { return $true }
        $state = -1
        try { $state = [NetMgr.Wlan]::GetState($Guid) } catch { }
        if ($state -eq 4 -and ((Get-Date) - $start).TotalSeconds -gt 5) {
            $downCount++
            if ($downCount -ge 4) { return $false }
        } else {
            $downCount = 0
        }
        Start-Sleep -Milliseconds 500
    }
    $false
}

# Creates (or replaces) a profile, connects, and removes the profile again on failure if it is new.
function Connect-WifiWithNewProfile {
    param([guid]$Guid, [string]$Ssid, [byte[]]$SsidBytes, [hashtable]$Sec, [bool]$Hidden = $false, [string]$KnownKey)

    $key = $KnownKey
    if ($Sec.Security -notin 'open', 'OWE' -and -not $key) {
        while ($true) {
            $key = Read-Input -Title 'Wi-Fi password' -Info @("Network: $Ssid", "Security: $($Sec.Security)") -Prompt 'Password' -Secure
            if ($null -eq $key) { return }
            if (Test-WifiKey $Sec.Security $key) { break }
            Show-Message 'Wi-Fi password' @('That password is not valid for this network type.', 'WPA/WPA2/WPA3: 8-63 characters (or 64 hex digits). WEP: 5/13 characters or 10/26 hex digits.') 'Warning'
        }
    }
    $auto = Confirm-Choice -Title 'Wi-Fi' -Question @("Connect to '$Ssid' automatically in the future?") -Yes 'Yes, connect automatically' -No 'No, only when I choose to'

    $existed = @([NetMgr.Wlan]::GetProfiles($Guid)) -contains $Ssid
    $xml = New-WifiProfileXml -Ssid $Ssid -SsidBytes $SsidBytes -Security $Sec.Security -Encryption $Sec.Encryption -Key $key -AutoConnect $auto -Hidden $Hidden
    try {
        [NetMgr.Wlan]::SetProfile($Guid, $xml)
    } catch {
        Show-Message 'Error' @("Could not create a Wi-Fi profile for '$Ssid':", (Get-ErrorText $_)) 'Error'
        return
    }

    if (Wait-WifiConnection -Guid $Guid -ProfileName $Ssid -Ssid $Ssid) {
        Show-Message 'Wi-Fi' @("Connected to '$Ssid'.", 'It may take a few seconds to receive an IP address.') 'Success'
    } else {
        if (-not $existed) { try { [NetMgr.Wlan]::DeleteProfile($Guid, $Ssid) } catch { } }
        Show-Message 'Wi-Fi' @("Could not connect to '$Ssid'.", 'Check the password and that the network is in range.') 'Error'
    }
}

function Connect-WifiNetwork {
    param($Adapter, $Net)
    $guid = $Adapter.Guid
    $sec = Get-ProfileSecurity $Net

    if ($Net.ProfileName) {
        if (Wait-WifiConnection -Guid $guid -ProfileName $Net.ProfileName -Ssid $Net.Ssid) {
            Show-Message 'Wi-Fi' @("Connected to '$($Net.Ssid)'.", 'It may take a few seconds to receive an IP address.') 'Success'
            return
        }
        if ($sec -and $sec.Security -notin 'open', 'OWE') {
            if (Confirm-Choice -Title 'Wi-Fi' -Question @("Could not connect to '$($Net.Ssid)' with the saved settings.", 'Enter the password again?') -Yes 'Enter password' -No 'Cancel') {
                Connect-WifiWithNewProfile -Guid $guid -Ssid $Net.Ssid -SsidBytes $Net.SsidBytes -Sec $sec
            }
        } else {
            Show-Message 'Wi-Fi' @("Could not connect to '$($Net.Ssid)'.") 'Error'
        }
        return
    }

    if (-not $sec) {
        Show-Message 'Wi-Fi' @("'$($Net.Ssid)' uses $(Get-AuthLabel $Net.Auth $Net.Cipher $Net.Secure) (802.1X) security.",
            'Enterprise networks need certificates/credentials that this tool does not configure.',
            'Connect once from Windows Settings; afterwards it can be selected here.') 'Warning'
        return
    }
    Connect-WifiWithNewProfile -Guid $guid -Ssid $Net.Ssid -SsidBytes $Net.SsidBytes -Sec $sec
}

function Connect-HiddenWifi {
    param($Adapter)
    $ssid = Read-Input -Title 'Hidden network' -Info @('Connect to a network that does not broadcast its name.') -Prompt 'Network name (SSID)'
    if (-not $ssid) { return }
    $items = @(
        (New-MenuItem 'WPA2-Personal' @{ Security = 'WPA2PSK'; Encryption = 'AES' })
        (New-MenuItem 'WPA3-Personal' @{ Security = 'WPA3SAE'; Encryption = 'AES' })
        (New-MenuItem 'WPA-Personal (legacy)' @{ Security = 'WPAPSK'; Encryption = 'TKIP' })
        (New-MenuItem 'Open (no password)' @{ Security = 'open'; Encryption = 'none' })
    )
    $r = Select-Menu -Title 'Hidden network' -Items $items -Header { param($b) Add-Line $b "  Security type for '$ssid':" 'Gray' }.GetNewClosure()
    if (-not $r) { return }
    Connect-WifiWithNewProfile -Guid $Adapter.Guid -Ssid $ssid -Sec $r.Value -Hidden $true
}

function Remove-WifiProfile {
    param($Adapter)
    $profiles = @([NetMgr.Wlan]::GetProfiles($Adapter.Guid) | Sort-Object)
    if ($profiles.Count -eq 0) { Show-Message 'Forget network' @('There are no saved Wi-Fi networks.'); return }
    $items = @(foreach ($p in $profiles) { New-MenuItem $p $p })
    $r = Select-Menu -Title 'Forget network' -Items $items -Header { param($b) Add-Line $b '  Choose a saved network to forget (its password will be removed):' 'Gray' }
    if (-not $r) { return }
    if (-not (Confirm-Choice -Title 'Forget network' -Question @("Forget '$($r.Value)'?") -Yes 'Forget' -No 'Cancel' -DefaultNo)) { return }
    try {
        [NetMgr.Wlan]::DeleteProfile($Adapter.Guid, $r.Value)
        Show-Message 'Forget network' @("'$($r.Value)' was removed.") 'Success'
    } catch {
        Show-Message 'Error' @((Get-ErrorText $_)) 'Error'
    }
}

# Scans and returns networks de-duplicated by SSID (strongest / saved entry wins).
function Get-WifiNetworks {
    param($Adapter, [switch]$Rescan)
    if ($Rescan) {
        Show-Busy "Scanning for Wi-Fi networks on $($Adapter.Name)..."
        try { [NetMgr.Wlan]::Scan($Adapter.Guid) } catch { }
        Start-Sleep -Seconds 4
    }
    $nets = [NetMgr.Wlan]::GetNetworks($Adapter.Guid)
    $nets | Where-Object { $_.Ssid } | Group-Object Ssid | ForEach-Object {
        $g = $_.Group
        $best = $g | Sort-Object @{ Expression = { $_.Connected }; Descending = $true }, @{ Expression = { [bool]$_.ProfileName }; Descending = $true }, @{ Expression = { $_.Signal }; Descending = $true } | Select-Object -First 1
        $best.Signal = ($g | Measure-Object -Property Signal -Maximum).Maximum
        $best
    } | Sort-Object @{ Expression = { $_.Connected }; Descending = $true }, @{ Expression = { $_.Signal }; Descending = $true }
}

function Show-WifiScreen {
    $adapter = Select-Adapter -Title 'Wi-Fi' -Kind 'Wi-Fi' -AutoPickSingle
    if (-not $adapter) {
        if (-not @($script:Status | Where-Object Kind -eq 'Wi-Fi').Count) { Show-Message 'Wi-Fi' @('No Wi-Fi adapter found.') 'Warning' }
        return
    }
    if (-not $script:WlanAvailable -and $adapter.Enabled) {
        Show-Message 'Wi-Fi' @('The WLAN AutoConfig service (WlanSvc) is not running.', 'Start it with: Start-Service WlanSvc') 'Error'
        return
    }
    if (-not $adapter.Enabled) {
        if (-not (Confirm-Choice -Title 'Wi-Fi' -Question @("Wi-Fi adapter '$($adapter.Name)' is disabled.", 'Enable it now?') -Yes 'Enable' -No 'Cancel')) { return }
        try { Set-AdapterEnabled $adapter $true } catch { Show-Message 'Error' @((Get-ErrorText $_)) 'Error'; return }
        Show-Busy 'Waiting for the Wi-Fi adapter...'
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if ((Get-WlanInterfaceMap).ContainsKey($adapter.Guid.ToString())) { break }
        }
        Update-Status
        $adapter = Get-StatusByName $adapter.Name
    }

    $rescan = $true
    $index = 0
    while ($true) {
        $nets = @()
        $scanError = $null
        try { $nets = @(Get-WifiNetworks $adapter -Rescan:$rescan) } catch { $scanError = $_ }
        $rescan = $false
        Update-Status
        $adapter = Get-StatusByName $adapter.Name

        if ($scanError) {
            $code = 0
            $e = $scanError.Exception
            while ($e -and -not ($e -is [NetMgr.WlanException])) { $e = $e.InnerException }
            if ($e) { $code = $e.Code }
            if ($code -eq 5) {
                if (Confirm-Choice -Title 'Wi-Fi' -Question @('Windows denied access to the list of Wi-Fi networks.',
                        'Windows 11 requires Location services to be on for apps to scan for Wi-Fi:',
                        'Settings > Privacy & security > Location > "Location services" and "Let desktop apps access your location".',
                        'PowerShell installed from the Microsoft Store must also be allowed in that list ("Let apps access your location").') -Yes 'Open Location settings' -No 'Back') {
                    Start-Process 'ms-settings:privacy-location'
                }
            } else {
                Show-Message 'Wi-Fi' @('Could not list Wi-Fi networks:', (Get-ErrorText $scanError)) 'Error'
            }
            return
        }

        $items = @()
        foreach ($n in $nets) {
            $tags = @()
            if ($n.Connected) { $tags += 'connected' }
            elseif ($n.ProfileName) { $tags += 'saved' }
            $label = '{0} {1,3}%  {2,-32}  {3,-16} {4}' -f (Get-SignalBars $n.Signal), $n.Signal, $n.Ssid, (Get-AuthLabel $n.Auth $n.Cipher $n.Secure), ($tags -join ', ')
            $color = if ($n.Connected) { 'Green' } elseif ($n.ProfileName) { 'Cyan' } else { 'Gray' }
            $items += New-MenuItem $label $n $color
        }
        if ($items.Count -eq 0) { $items += New-MenuItem '(no networks found)' $null 'DarkGray' -Separator }
        $items += New-MenuItem '' $null -Separator
        $items += New-MenuItem '[R] Rescan' 'rescan'
        $items += New-MenuItem '[H] Connect to a hidden network...' 'hidden'
        if ($adapter.Ssid) { $items += New-MenuItem "[D] Disconnect from '$($adapter.Ssid)'" 'disconnect' }
        $items += New-MenuItem '[F] Forget a saved network...' 'forget'

        $a = $adapter
        $hdr = { param($b) Add-AdapterLines $b $a -Brief; Add-Line $b; Add-Line $b '  Available networks:' 'Gray' }.GetNewClosure()
        $hot = @{ R = 'rescan'; H = 'hidden'; F = 'forget' }
        if ($adapter.Ssid) { $hot['D'] = 'disconnect' }
        $r = Select-Menu -Title "Wi-Fi ($($adapter.Name))" -Header $hdr -Items $items -Index $index -Hotkeys $hot -Help 'Up/Down move   Enter connect   R rescan   H hidden   D disconnect   F forget   Esc back'
        if (-not $r) { return }
        $index = $r.Index

        try {
            switch ($r.Value) {
                'rescan' { $rescan = $true }
                'hidden' { Connect-HiddenWifi $adapter }
                'forget' { Remove-WifiProfile $adapter }
                'disconnect' {
                    Show-Busy 'Disconnecting...'
                    [NetMgr.Wlan]::Disconnect($adapter.Guid)
                    Start-Sleep -Seconds 1
                }
                default {
                    $net = $r.Value
                    if ($net.Connected) {
                        $choice = Select-Menu -Title 'Wi-Fi' -Items @((New-MenuItem 'Disconnect' 'disconnect'), (New-MenuItem 'Forget this network' 'forget'), (New-MenuItem 'Back' $null)) -Header {
                            param($b) Add-Line $b "  You are connected to '$($net.Ssid)'." 'Green'
                        }.GetNewClosure()
                        if ($choice -and $choice.Value -eq 'disconnect') {
                            [NetMgr.Wlan]::Disconnect($adapter.Guid); Start-Sleep -Seconds 1
                        } elseif ($choice -and $choice.Value -eq 'forget') {
                            if (Confirm-Choice -Title 'Forget network' -Question @("Forget '$($net.ProfileName)'?") -Yes 'Forget' -No 'Cancel' -DefaultNo) {
                                [NetMgr.Wlan]::DeleteProfile($adapter.Guid, $net.ProfileName)
                            }
                        }
                    } else {
                        Connect-WifiNetwork $adapter $net
                        $index = 0
                    }
                }
            }
        } catch {
            Show-Message 'Error' @((Get-ErrorText $_)) 'Error'
        }
    }
}

#endregion

#region IP / DHCP ----------------------------------------------------------------------------

function ConvertTo-PrefixLength {
    param([string]$Value)
    $n = 0
    if ([int]::TryParse($Value.TrimStart('/'), [ref]$n)) {
        if ($n -ge 1 -and $n -le 32) { return $n } else { return $null }
    }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { return $null }
    $bits = -join ($ip.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') })
    if ($bits -notmatch '^1+0*$') { return $null }
    $bits.TrimEnd('0').Length
}

function Test-IPv4 {
    param([string]$Value)
    $ip = $null
    ($Value -match '^\d{1,3}(\.\d{1,3}){3}$') -and [System.Net.IPAddress]::TryParse($Value, [ref]$ip)
}

function Set-AdapterDhcp {
    param($S)
    Show-Busy "Switching $($S.Name) to DHCP..."
    $idx = $S.Index
    # Remove manually configured addresses and gateways, then turn DHCP on.
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.Protocol -ne 'Dhcp' } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled
    if ($S.Up) { Invoke-DhcpLease $S 'RenewDHCPLease' | Out-Null }
}

function Set-AdapterStaticIP {
    param($S, [string]$Address, [int]$PrefixLength, [string]$Gateway)
    Show-Busy "Applying static IP address to $($S.Name)..."
    $idx = $S.Index
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -PolicyStore $store -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    $params = @{ InterfaceIndex = $idx; AddressFamily = 'IPv4'; IPAddress = $Address; PrefixLength = $PrefixLength }
    if ($Gateway) { $params.DefaultGateway = $Gateway }
    New-NetIPAddress @params | Out-Null
}

function Invoke-DhcpLease {
    param($S, [ValidateSet('RenewDHCPLease', 'ReleaseDHCPLease')][string]$Method)
    $cfg = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $($S.Index)"
    if (-not $cfg) { throw "Adapter '$($S.Name)' was not found." }
    $r = Invoke-CimMethod -InputObject $cfg -MethodName $Method
    [int]$r.ReturnValue
}

function Read-StaticIPSettings {
    param($S)
    $curIp = ''; $curPrefix = '24'
    if ($S.IPv4.Count -and $S.IPv4[0] -notlike '169.254.*') { $parts = $S.IPv4[0] -split '/'; $curIp = $parts[0]; $curPrefix = $parts[1] }
    $curGw = if ($S.Gateway.Count) { $S.Gateway[0] } else { '' }

    $info = @("Adapter: $($S.Name)", 'Static IPv4 configuration')
    do {
        $ip = Read-Input -Title 'Static IP' -Info $info -Prompt 'IP address' -Default $curIp
        if ($null -eq $ip) { return $null }
        $ok = Test-IPv4 $ip
        if (-not $ok) { Show-Message 'Static IP' @("'$ip' is not a valid IPv4 address.") 'Warning' }
    } until ($ok)
    do {
        $p = Read-Input -Title 'Static IP' -Info ($info + "IP address: $ip") -Prompt 'Prefix length or subnet mask (e.g. 24 or 255.255.255.0)' -Default $curPrefix
        if ($null -eq $p) { return $null }
        $prefix = ConvertTo-PrefixLength $p
        if ($null -eq $prefix) { Show-Message 'Static IP' @("'$p' is not a valid prefix length or subnet mask.") 'Warning' }
    } until ($null -ne $prefix)
    do {
        $gwInfo = $info + "IP address: $ip/$prefix" + "Enter 'none' for no gateway."
        $gw = Read-Input -Title 'Static IP' -Info $gwInfo -Prompt 'Default gateway' -Default $curGw
        if ($null -eq $gw) { return $null }
        if ($gw -eq 'none') { $gw = ''; break }
        $ok = Test-IPv4 $gw
        if (-not $ok) { Show-Message 'Static IP' @("'$gw' is not a valid IPv4 address.") 'Warning' }
    } until ($ok)

    [pscustomobject]@{ IP = $ip; Prefix = [int]$prefix; Gateway = $gw }
}

function Show-IPScreen {
    $s = Select-Adapter -Title 'IP address & DHCP' -AutoPickSingle
    if (-not $s) { return }
    if (-not $s.Enabled) { Show-Message 'IP address & DHCP' @("'$($s.Name)' is disabled. Enable it first.") 'Warning'; return }

    $index = 0
    while ($true) {
        $s = Get-StatusByName $s.Name
        $items = @(
            (New-MenuItem 'Obtain an IP address automatically (DHCP)' 'dhcp' $(if ($s.Dhcp) { 'DarkGray' } else { 'Gray' }))
            (New-MenuItem 'Set a static IP address...' 'static')
            (New-MenuItem 'Renew DHCP lease' 'renew')
            (New-MenuItem 'Release DHCP lease' 'release')
        )
        $cur = $s
        $hdr = {
            param($b)
            Add-AdapterLines $b $cur
            Add-Line $b
            $m = if ($cur.Dhcp) { 'DHCP is ON - the IP address is assigned automatically.' } else { 'DHCP is OFF - a static IP address is configured.' }
            Add-Line $b "  $m" 'Yellow'
        }.GetNewClosure()
        $r = Select-Menu -Title "IP address & DHCP ($($s.Name))" -Header $hdr -Items $items -Index $index
        if (-not $r) { return }
        $index = $r.Index

        try {
            switch ($r.Value) {
                'dhcp' {
                    if ($s.Dhcp) { Show-Message 'DHCP' @('DHCP is already enabled.'); break }
                    Set-AdapterDhcp $s
                    $note = @("DHCP enabled on '$($s.Name)'.")
                    if ($s.DnsStatic) { $note += 'Your manual DNS servers were kept (change them under DNS servers).' }
                    Show-Message 'DHCP' $note 'Success'
                }
                'static' {
                    $cfg = Read-StaticIPSettings $s
                    if (-not $cfg) { break }
                    $q = @("Apply to '$($s.Name)':", "  IP address  $($cfg.IP)/$($cfg.Prefix)", "  Gateway     $(if ($cfg.Gateway) { $cfg.Gateway } else { '(none)' })")
                    if (-not (Confirm-Choice -Title 'Static IP' -Question $q -Yes 'Apply' -No 'Cancel')) { break }
                    Set-AdapterStaticIP $s $cfg.IP $cfg.Prefix $cfg.Gateway
                    Update-Status
                    if (-not $s.DnsStatic) {
                        if (Confirm-Choice -Title 'Static IP' -Question @('Static IP applied.', 'DNS servers were provided by DHCP, which is now off - without DNS servers names will not resolve.', 'Set DNS servers now?') -Yes 'Set DNS servers' -No 'Not now') {
                            Show-DnsPresetMenu @(Get-StatusByName $s.Name)
                        }
                    } else {
                        Show-Message 'Static IP' @('Static IP applied.') 'Success'
                    }
                }
                'renew' {
                    if (-not $s.Dhcp) { Show-Message 'DHCP' @('DHCP is off for this adapter; there is no lease to renew.') 'Warning'; break }
                    if (-not $s.Up) { Show-Message 'DHCP' @('The adapter is not connected.') 'Warning'; break }
                    Show-Busy 'Renewing DHCP lease (this can take a while)...'
                    $code = Invoke-DhcpLease $s 'RenewDHCPLease'
                    if ($code -eq 0) { Show-Message 'DHCP' @('Lease renewed.') 'Success' } else { Show-Message 'DHCP' @("Renew failed (WMI return code $code).") 'Error' }
                }
                'release' {
                    if (-not $s.Dhcp) { Show-Message 'DHCP' @('DHCP is off for this adapter; there is no lease to release.') 'Warning'; break }
                    if (-not (Confirm-Choice -Title 'DHCP' -Question @("Release the DHCP lease on '$($s.Name)'?", 'The adapter will have no IP address until the lease is renewed.') -Yes 'Release' -No 'Cancel' -DefaultNo)) { break }
                    Show-Busy 'Releasing DHCP lease...'
                    $code = Invoke-DhcpLease $s 'ReleaseDHCPLease'
                    if ($code -eq 0) { Show-Message 'DHCP' @('Lease released. Use "Renew DHCP lease" to get a new address.') 'Success' } else { Show-Message 'DHCP' @("Release failed (WMI return code $code).") 'Error' }
                }
            }
        } catch {
            Show-Message 'Error' @((Get-ErrorText $_)) 'Error'
        }
        Update-Status
    }
}

#endregion

#region DNS ----------------------------------------------------------------------------------

function Set-AdapterDns {
    param($S, [string[]]$Servers)   # $Servers = $null -> back to DHCP-provided servers
    Set-DnsClientServerAddress -InterfaceIndex $S.Index -ResetServerAddresses
    if ($Servers) {
        if (-not $S.HasIPv6) { $Servers = @($Servers | Where-Object { $_ -notmatch ':' }) }
        if ($Servers) { Set-DnsClientServerAddress -InterfaceIndex $S.Index -ServerAddresses $Servers }
    }
}

function Read-CustomDns {
    while ($true) {
        $v = Read-Input -Title 'Custom DNS' -Info @('Enter one or more DNS servers separated by commas or spaces.', 'IPv4 and IPv6 addresses are both accepted, e.g.  192.168.1.2, 1.1.1.1') -Prompt 'DNS servers'
        if ($null -eq $v) { return $null }
        $list = Split-ServerList $v
        $bad = @($list | Where-Object { $ip = $null; -not [System.Net.IPAddress]::TryParse($_, [ref]$ip) })
        if ($list.Count -and -not $bad.Count) { return $list }
        Show-Message 'Custom DNS' @("Not a valid IP address: $($bad -join ', ')") 'Warning'
    }
}

function Show-DnsPresetMenu {
    param([object[]]$Targets)
    $items = @()
    foreach ($p in $script:DnsPresets) {
        $items += New-MenuItem ('{0,-16} {1}' -f $p.Name, ($p.V4 -join ', ')) $p
    }
    $items += New-MenuItem ('{0,-16} {1}' -f 'Automatic', 'use the DNS servers provided by DHCP') 'auto'
    $items += New-MenuItem ('{0,-16} {1}' -f 'Custom...', 'enter your own servers') 'custom'

    $names = ($Targets | ForEach-Object { $_.Name }) -join ', '
    $t = $Targets
    $hdr = {
        param($b)
        foreach ($s in $t) { Add-AdapterLines $b $s; Add-Line $b }
        Add-Line $b '  Choose DNS servers. The IP address stays on DHCP / its current setting.' 'Yellow'
        Add-Line $b '  IPv6 servers of a preset are added automatically when IPv6 is enabled.' 'DarkGray'
    }.GetNewClosure()
    $r = Select-Menu -Title "DNS servers ($names)" -Header $hdr -Items $items
    if (-not $r) { return }

    $servers = $null
    $label = ''
    if ($r.Value -eq 'auto') { $label = 'automatic (DHCP)' }
    elseif ($r.Value -eq 'custom') {
        $servers = Read-CustomDns
        if (-not $servers) { return }
        $label = $servers -join ', '
    } else {
        $servers = @($r.Value.V4) + @($r.Value.V6)
        $label = $r.Value.Name
    }

    $results = @()
    $failed = $false
    foreach ($s in $Targets) {
        if (-not $s.Enabled) { $results += "$($s.Name): skipped (adapter is disabled)"; continue }
        try {
            Show-Busy "Setting DNS on $($s.Name)..."
            Set-AdapterDns $s $servers
            $msg = "$($s.Name): DNS set to $label"
            if (-not $servers -and -not $s.Dhcp) { $msg += ' - note: DHCP is off for this adapter, so it now has no DNS servers' }
            $results += $msg
        } catch {
            $failed = $true
            $results += "$($s.Name): FAILED - $(Get-ErrorText $_)"
        }
    }
    try { Clear-DnsClientCache } catch { }
    Show-Message 'DNS servers' ($results + 'DNS cache flushed.') $(if ($failed) { 'Error' } else { 'Success' })
}

function Show-DnsScreen {
    $target = Select-Adapter -Title 'DNS servers' -IncludeAll -AutoPickSingle
    if (-not $target) { return }
    $targets = if ($target -eq '*') { @($script:Status) } else { @($target) }
    Show-DnsPresetMenu $targets
    Update-Status
}

#endregion

#region Main ---------------------------------------------------------------------------------

function Start-NetworkManager {
    Update-Status
    $index = 0
    while ($true) {
        $items = @(
            (New-MenuItem 'Wi-Fi networks  - scan, connect, disconnect' 'wifi')
            (New-MenuItem 'Adapters        - enable / disable Wi-Fi and Ethernet' 'adapters')
            (New-MenuItem 'IP address      - DHCP or static, renew / release lease' 'ip')
            (New-MenuItem 'DNS servers     - Google, Cloudflare, AdGuard, Quad9, custom, DHCP' 'dns')
            (New-MenuItem 'Refresh' 'refresh')
            (New-MenuItem 'Quit' 'quit')
        )
        $r = Select-Menu -Title 'Network Manager' -Header { param($b) Add-StatusLines $b } -Items $items -Index $index `
            -Hotkeys @{ R = 'refresh'; Q = 'quit'; W = 'wifi'; A = 'adapters'; I = 'ip'; D = 'dns' } `
            -Help 'Up/Down move   Enter select   W wifi  A adapters  I ip  D dns   R refresh   Q/Esc quit'
        if (-not $r -or $r.Value -eq 'quit') { return }
        $index = $r.Index
        try {
            switch ($r.Value) {
                'wifi' { Show-WifiScreen }
                'adapters' { Show-AdaptersScreen }
                'ip' { Show-IPScreen }
                'dns' { Show-DnsScreen }
            }
        } catch {
            Show-Message 'Error' @((Get-ErrorText $_)) 'Error'
        }
        Update-Status
    }
}

$originalTitle = $Host.UI.RawUI.WindowTitle
try {
    $Host.UI.RawUI.WindowTitle = 'Network Manager' + $(if ($script:IsAdmin) { ' (Administrator)' } else { '' })
    Start-NetworkManager
} catch {
    try { [Console]::CursorVisible = $true } catch { }
    Clear-Host
    Write-Host "Network Manager stopped with an error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if ($Elevated) { Write-Host 'Press any key to close...'; [void][Console]::ReadKey($true) }
    exit 1
} finally {
    try { [Console]::CursorVisible = $true } catch { }
    $Host.UI.RawUI.WindowTitle = $originalTitle
}
Clear-Host

#endregion
