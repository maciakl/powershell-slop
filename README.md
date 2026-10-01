# Get-Ip

A single-file PowerShell script that shows IP address information for the network interface your machine uses to reach the internet:

- Routable (public) IP address
- Local LAN IP address
- Subnet (network/prefix and mask)
- Default gateway
- Primary DNS server
- MAC address
- Interface name
- VPN IP and VPN interface (only when a VPN is in use)

It runs on the Windows PowerShell 5.1 that ships with Windows 11 and has no external dependencies.

## Usage

```powershell
.\Get-Ip.ps1 [-RoutableIP] [-LocalIP] [-Gateway] [-Dns] [-MacAddress]
             [-VpnIP] [-AsText] [-ApiUrl <url>] [-TimeoutSec <seconds>]
             [-Version] [-Help]
```

| Switch        | Aliases                  | Description |
|---------------|--------------------------|-------------|
| `-RoutableIP` | `-Routable`, `-Public`   | Routable (public) IP only |
| `-LocalIP`    | `-Local`, `-LAN`         | Local LAN IP only |
| `-Gateway`    | `-GW`                    | Default gateway only |
| `-Dns`        | `-DnsServer`             | Primary DNS server only |
| `-MacAddress` | `-Mac`, `-PhysicalAddress` | MAC address only |
| `-VpnIP`      | `-Vpn`                   | VPN IP only (exit code `1` if no VPN is in use) |
| `-AsText`     |                          | Emit plain text instead of an object when piped or captured |
| `-ApiUrl`     | `-Url`, `-Api`           | Use your own routable IP lookup service |
| `-TimeoutSec` |                          | Timeout for the routable IP lookup (default `10`) |
| `-Version`    |                          | Show the script version |
| `-Help`       | `-h`                     | Show usage |

The `-RoutableIP`, `-LocalIP`, `-Gateway`, `-Dns`, `-MacAddress` and `-VpnIP` switches can be combined. They output the address only, with no label, one per line in the order listed above.

`Get-Help .\Get-Ip.ps1 -Full` also works.

## Output

The output adapts to where it is going:

| Destination | Output |
|-------------|--------|
| Console | Colorized display |
| Piped or captured (`\| ...`, `$x = ...`, `(...).Prop`) | PowerShell object (plain text with `-AsText`) |
| Redirected to a file (`>`, `*>`, `\| Out-File`, `\| Set-Content`, `\| Add-Content`) | Plain text |
| Run from `cmd.exe` with stdout redirected (`powershell -File Get-Ip.ps1 > out.txt`) | Plain text |

Without switches, plain text output uses `Label : value` lines:

```
Routable IP     : 203.0.113.25
Local IP        : 192.168.1.20
Subnet          : 192.168.1.0/24 (255.255.255.0)
Default Gateway : 192.168.1.1
DNS Server      : 192.168.1.1
MAC Address     : 00-1A-2B-3C-4D-5E
Interface       : Ethernet (Intel(R) Ethernet Controller)
```

When a VPN is in use, two more lines follow:

```
VPN IP          : 100.64.0.5
VPN Interface   : Tailscale (Tailscale Tunnel)
```

The object has the properties `RoutableIP`, `LocalIP`, `Subnet`, `DefaultGateway`, `DnsServer`, `MacAddress`, `Interface`, `VpnIP` and `VpnInterface`. The VPN properties are `$null` when no VPN is in use. With value switches, only the selected properties are included.

## Examples

```powershell
# Colorized summary
.\Get-Ip.ps1

# Just the public IP
.\Get-Ip.ps1 -RoutableIP

# Local IP and gateway, one per line
.\Get-Ip.ps1 -LocalIP -Gateway

# Just the MAC address
.\Get-Ip.ps1 -MacAddress

# Just the VPN IP, or exit code 1 if no VPN is in use
.\Get-Ip.ps1 -VpnIP

# Script version
.\Get-Ip.ps1 -Version

# Work with the object
.\Get-Ip.ps1 | Select-Object LocalIP, DefaultGateway
$gw = (.\Get-Ip.ps1 -Gateway).DefaultGateway

# Copy the public IP to the clipboard as text
.\Get-Ip.ps1 -RoutableIP -AsText | Set-Clipboard

# Save to a file
.\Get-Ip.ps1 > ipinfo.txt

# Use a different lookup service
.\Get-Ip.ps1 -ApiUrl https://ifconfig.me/ip
```

## How it works

- **Routable IP**: queried from `https://api.ipify.org`. If that fails, the script falls back to `https://checkip.amazonaws.com` and then `https://ipv4.icanhazip.com`. A URL given with `-ApiUrl` is used on its own, with no fallback. The service may return plain text or JSON with an `ip` property.
- **Interface selection**: the script asks Windows which local address it would use to reach the lookup host (a UDP socket "connect", which sends no packets). The subnet, gateway, DNS server and MAC address come from that same interface. If that turns out to be a virtual adapter (a VPN), the script reports the physical adapter underneath it instead: the hardware adapter with an IPv4 address and default gateway and the lowest default route metric. The VPN's own address and adapter are shown as `VPN IP` and `VPN Interface`. If no physical adapter qualifies (for example, a Hyper-V external switch), the virtual adapter is reported as before. If no route is available, it falls back to the first active interface with an IPv4 default gateway.
- **Output detection**: PowerShell doesn't tell a script when its output is redirected with `>`, so the script parses the command line it was invoked from to see whether its output is piped, captured or redirected.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Success |
| `1`  | One or more requested values could not be determined (including `-VpnIP` when no VPN is in use) |
| `2`  | Invalid `-ApiUrl` |

## Notes

- If PowerShell blocks the script, you can run it with `powershell -ExecutionPolicy Bypass -File .\Get-Ip.ps1`, or allow local scripts with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- If a command is split across several lines with backticks, output detection relies only on PowerShell's built-in pipeline information.
- `| Out-Host` counts as piped, so you get an object rather than colors.
