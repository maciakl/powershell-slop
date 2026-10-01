# Get-Ip

A single-file PowerShell script that shows IP address information for the network interface your machine uses to reach the internet:

- Routable (public) IP address
- Local LAN IP address
- Subnet (network/prefix and mask)
- Default gateway
- Primary DNS server
- Interface name

It runs on the Windows PowerShell 5.1 that ships with Windows 11 and has no external dependencies.

## Usage

```powershell
.\Get-Ip.ps1 [-RoutableIP] [-LocalIP] [-Gateway] [-Dns] [-AsText]
             [-ApiUrl <url>] [-TimeoutSec <seconds>] [-Help]
```

| Switch        | Aliases                  | Description |
|---------------|--------------------------|-------------|
| `-RoutableIP` | `-Routable`, `-Public`   | Routable (public) IP only |
| `-LocalIP`    | `-Local`, `-LAN`         | Local LAN IP only |
| `-Gateway`    | `-GW`                    | Default gateway only |
| `-Dns`        | `-DnsServer`             | Primary DNS server only |
| `-AsText`     |                          | Emit plain text instead of an object when piped or captured |
| `-ApiUrl`     | `-Url`, `-Api`           | Use your own routable IP lookup service |
| `-TimeoutSec` |                          | Timeout for the routable IP lookup (default `10`) |
| `-Help`       | `-h`                     | Show usage |

The `-RoutableIP`, `-LocalIP`, `-Gateway` and `-Dns` switches can be combined. They output the address only, with no label, one per line in the order listed above.

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
Interface       : Ethernet (Intel(R) Ethernet Controller)
```

The object has the properties `RoutableIP`, `LocalIP`, `Subnet`, `DefaultGateway`, `DnsServer` and `Interface`. With value switches, only the selected properties are included.

## Examples

```powershell
# Colorized summary
.\Get-Ip.ps1

# Just the public IP
.\Get-Ip.ps1 -RoutableIP

# Local IP and gateway, one per line
.\Get-Ip.ps1 -LocalIP -Gateway

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
- **Interface selection**: the script asks Windows which local address it would use to reach the lookup host (a UDP socket "connect", which sends no packets). The subnet, gateway and DNS server come from that same interface. If you're on a VPN, that's the VPN interface. If no route is available, it falls back to the first active interface with an IPv4 default gateway.
- **Output detection**: PowerShell doesn't tell a script when its output is redirected with `>`, so the script parses the command line it was invoked from to see whether its output is piped, captured or redirected.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Success |
| `1`  | One or more requested values could not be determined |
| `2`  | Invalid `-ApiUrl` |

## Notes

- If PowerShell blocks the script, you can run it with `powershell -ExecutionPolicy Bypass -File .\Get-Ip.ps1`, or allow local scripts with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- If a command is split across several lines with backticks, output detection relies only on PowerShell's built-in pipeline information.
- `| Out-Host` counts as piped, so you get an object rather than colors.
