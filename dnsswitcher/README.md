# DNS Switcher

A keyboard-driven terminal UI for switching the DNS servers of a Windows 11 network
adapter with one key press.

- Single file: `DNS-Switcher.ps1`
- Works in **Windows PowerShell 5.1** (built into Windows 11) and **PowerShell 7+**
- No modules or software to install
- Changes **only** DNS server settings, nothing else

Current version: **0.1.0**

## Features

- Shows the adapter's current DNS settings on start and identifies them as
  **DHCP**, one of the **presets**, or **custom**
- Recognises known providers even when their addresses were typed in manually
  (including filtered variants such as Cloudflare Families or Quad9 Unsecured)
- One-key switching between:

  | Key | Option         | IPv4 servers                     | IPv6 servers                                    |
  |-----|----------------|----------------------------------|-------------------------------------------------|
  | 1   | DHCP Default   | from your router / DHCP server   | from your router / DHCP server                  |
  | 2   | Google DNS     | 8.8.8.8, 8.8.4.4                 | 2001:4860:4860::8888, 2001:4860:4860::8844      |
  | 3   | Cloudflare DNS | 1.1.1.1, 1.0.0.1                 | 2606:4700:4700::1111, 2606:4700:4700::1001      |
  | 4   | OpenDNS        | 208.67.222.222, 208.67.220.220   | 2620:119:35::35, 2620:119:53::53                |
  | 5   | Quad9 DNS      | 9.9.9.9, 149.112.112.112         | 2620:fe::fe, 2620:fe::9                         |
  | 6   | AdGuard DNS    | 94.140.14.14, 94.140.15.15       | 2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff            |
  | 7   | Custom DNS     | your own addresses               | your own addresses                              |

- Custom addresses are validated; invalid entries get a clear error and you are asked again
- **Restore original** puts back the DNS settings from before the first change, even after
  the script was closed and reopened
- Automatically asks for administrator rights (UAC) and reopens in the same terminal type
  (Windows Terminal, or the same `powershell.exe` / `pwsh.exe` console)
- Works with any adapter (Ethernet, Wi-Fi, VPN...); the internet-facing one is picked by default

## Usage

```powershell
.\DNS-Switcher.ps1            # start the interactive UI
.\DNS-Switcher.ps1 -Version   # print the version and exit
.\DNS-Switcher.ps1 -Help      # print usage and exit
Get-Help .\DNS-Switcher.ps1 -Full
```

If script execution is blocked by your execution policy, run it once with:

```powershell
powershell -ExecutionPolicy Bypass -File .\DNS-Switcher.ps1
```

### Keys

| Key                 | Action                                      |
|---------------------|---------------------------------------------|
| Up / Down, Home/End | Move the selection                          |
| Enter               | Apply the selected option                   |
| 1 - 7               | Apply an option directly                    |
| R                   | Restore the original DNS settings           |
| A                   | Choose another network adapter              |
| F5                  | Re-read the current settings                |
| Q / Esc             | Quit                                        |

### Screen

```
   DNS Switcher   v0.1.0  Windows DNS made easy
  ────────────────────────────────────────────────────────────

  Adapter    Ethernet  [Up]  Killer E3000 2.5 Gigabit Ethernet Controller
  Current    Cloudflare DNS  (manual)
    IPv4     1.1.1.1, 1.0.0.1  (manual)
    IPv6     2606:4700:4700::1111, 2606:4700:4700::1001  (manual)
  Original   DHCP Default  (saved 2026-10-28 19:09, press R to restore)

  Choose DNS servers:

    [1]  DHCP Default         Automatic, from your router
    [2]  Google DNS           8.8.8.8, 8.8.4.4
  ► [3]  Cloudflare DNS       1.1.1.1, 1.0.0.1  ● current
    [4]  OpenDNS              208.67.222.222, 208.67.220.220
    [5]  Quad9 DNS            9.9.9.9, 149.112.112.112
    [6]  AdGuard DNS          94.140.14.14, 94.140.15.15
    [7]  Custom DNS...        Enter your own addresses
      ────────────────────────
    [R]  Restore original     Undo all changes on this adapter
    [A]  Change adapter...
    [Q]  Quit

  Switched "Ethernet" to Cloudflare DNS.
  ↑↓ Move   Enter Select   1-7 Quick pick   R Restore   A Adapter   F5 Refresh   Q Quit
```

## How it works

- **Reading settings.** Manually configured servers are read from the interface's
  `NameServer` registry value (`HKLM\SYSTEM\CurrentControlSet\Services\Tcpip[6]\Parameters\Interfaces\{GUID}`);
  an empty value means DHCP. The servers actually in use come from `Get-DnsClientServerAddress`.
- **Changing settings.** The adapter is reset to DHCP DNS with
  `Set-DnsClientServerAddress -ResetServerAddresses`, then the chosen servers are applied with
  `Set-DnsClientServerAddress -ServerAddresses`, and the DNS cache is flushed. IPv6 servers are
  only applied when IPv6 is enabled on the adapter. No other network setting is touched.
- **Original settings.** Before the first change to an adapter, its DNS settings are saved to
  `%LOCALAPPDATA%\DNS-Switcher\original-dns.json` (one entry per adapter). Later changes never
  overwrite that entry. Restoring applies it and removes the entry; the file is deleted when empty.
- **Elevation.** Without administrator rights the script relaunches itself with
  `Start-Process -Verb RunAs` using the same PowerShell executable. Inside Windows Terminal
  (`WT_SESSION` is set) it opens in Windows Terminal via `wt.exe`. If the UAC prompt is declined,
  a clear error is shown and the script exits with code 1.

## Requirements

- Windows 11 (Windows 10 should work too)
- Windows PowerShell 5.1 or PowerShell 7+
- Administrator rights (requested automatically)
- A real console: Windows Terminal, the PowerShell console, or the VS Code terminal
  (the PowerShell ISE is not supported)

## Notes

- The saved original settings belong to the Windows user that runs the elevated script. If you
  elevate with a different administrator account, its `%LOCALAPPDATA%` is used.
- Changes to DNS on an adapter that is disconnected or disabled may be rejected by Windows;
  the error is shown in the status line.

## Changelog

### 0.1.0 - 2026-10-28

- Initial release.
- Interactive TUI with arrow-key navigation, number hotkeys and flicker-free redraws.
- Presets: DHCP Default, Google, Cloudflare, OpenDNS, Quad9, AdGuard, plus custom addresses
  (IPv4 and IPv6) with validation.
- Detection of DHCP, preset and custom configurations, including manually entered provider
  addresses and their filtered variants.
- Persistent backup and restore of the original DNS settings per adapter.
- Network adapter picker; the internet-facing adapter is selected by default.
- Automatic elevation that reopens in the same terminal type, with a clear message when declined.
- `-Version` and `-Help` switches.
