# Network Manager

A keyboard-driven console (TUI) tool for managing Wi-Fi and Ethernet connections on Windows, written as a single PowerShell script.

## Features

- **Status overview** of every physical Wi-Fi and Ethernet adapter: state, link speed, SSID and signal strength, IPv4/IPv6 addresses, default gateway and DNS servers (marking whether DNS comes from DHCP or was set manually).
- **Wi-Fi**
  - Scan and list nearby networks with signal bars, security type, and connected/saved tags
  - Connect to open, WEP, WPA, WPA2, WPA3-Personal and Enhanced Open (OWE) networks
  - Connect to hidden networks
  - Disconnect, and forget saved networks
  - Choose whether a new network connects automatically in the future
- **Adapters**: enable or disable Wi-Fi and Ethernet adapters.
- **IP address**: switch IPv4 between DHCP and a static address (prefix length or subnet mask, optional gateway), and renew or release the DHCP lease.
- **DNS servers**: set DNS per adapter or for all adapters at once, without changing how the IP address is assigned. Presets:

  | Preset         | IPv4                            |
  | -------------- | ------------------------------- |
  | Google         | 8.8.8.8, 8.8.4.4                |
  | Cloudflare     | 1.1.1.1, 1.0.0.1                |
  | AdGuard        | 94.140.14.14, 94.140.15.15      |
  | AdGuard Family | 94.140.14.15, 94.140.15.16      |
  | Quad9          | 9.9.9.9, 149.112.112.112        |

  The matching IPv6 servers are added when the adapter has IPv6 enabled. You can also enter custom servers, or go back to the servers provided by DHCP. The DNS cache is flushed after every change.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (included with Windows) or PowerShell 7+
- An interactive console such as Windows Terminal or conhost. The PowerShell ISE and redirected input are not supported.
- The **WLAN AutoConfig** service (`WlanSvc`) for Wi-Fi features
- **Location services** turned on for Wi-Fi scanning. Windows 11 requires this before apps can list Wi-Fi networks: *Settings > Privacy & security > Location*, enable "Location services" and "Let desktop apps access your location".

No external modules are needed. The script uses the built-in NetAdapter, NetTCPIP and DnsClient modules, CIM, and the Native Wi-Fi API (`wlanapi.dll`) via an inline C# type.

## Usage

```powershell
.\NetworkManager.ps1
```

If the execution policy blocks the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\NetworkManager.ps1
```

### Administrator rights

Changing adapter, IP or DNS settings requires administrator rights. When started without them, the script relaunches itself elevated, using the same PowerShell edition it was started from:

- If [Sudo for Windows](https://learn.microsoft.com/windows/sudo/) is enabled in **Inline** mode, the elevated copy runs in the same console window.
- Otherwise a UAC prompt opens a new elevated window, and the original window waits for it to close.

To skip elevation, use `-NoElevate`:

```powershell
.\NetworkManager.ps1 -NoElevate
```

In this mode you can still view status and connect to or disconnect from Wi-Fi networks, but changes to adapters, IP and DNS settings will fail. The title bar shows "NOT elevated (view only)".

## Keyboard controls

| Key                     | Action                                 |
| ----------------------- | -------------------------------------- |
| Up / Down, Home / End, PgUp / PgDn | Move the selection          |
| Enter                   | Select                                 |
| 1-9                     | Jump to and select an item              |
| Esc / Backspace / Left  | Go back (quit from the main menu)      |

**Main menu:** `W` Wi-Fi, `A` adapters, `I` IP address, `D` DNS, `R` refresh, `Q` quit.

**Wi-Fi screen:** `R` rescan, `H` connect to a hidden network, `D` disconnect, `F` forget a saved network.

The interface redraws automatically when the console window is resized.

## Notes and limitations

- Only physical Wi-Fi and Ethernet adapters are shown. Virtual adapters (VPN, Hyper-V, WSL, etc.) are ignored.
- Static IP configuration is IPv4 only.
- WPA/WPA2/WPA3-Enterprise (802.1X) networks cannot be set up from this tool. Connect to them once from Windows Settings; afterwards they can be selected here.
- Switching an adapter to a static IP turns off DHCP-provided DNS. If no manual DNS servers are configured, the tool offers to set them right away.
- If connecting to a new network fails, the Wi-Fi profile that was just created is removed again.
