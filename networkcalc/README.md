# NetworkCalc

An interactive IPv4 subnet calculator for the Windows console, packaged as one
PowerShell script: `NetworkCalc.ps1`.

```
┌─ NetworkCalc - IPv4 Subnet Calculator ─────────────────────────────────────┐
│  F1 CIDR    F2 IP + Subnet mask    F3 IP + Host count                      │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│ IP address        172.16.40.9          e.g. 192.168.1.10                   │
│ Number of hosts   50                   e.g. 50                             │
│                                                                            │
│ Smallest subnet for 50 host(s) is /26 with 62 usable.                      │
├─ Results ──────────────────────────────────────────────────────────────────┤
│   IP address         172.16.40.9                                           │
│   Address type       Private (RFC 1918)                                    │
│   CIDR notation      172.16.40.0/26                                        │
│   Subnet mask        255.255.255.192                                       │
│   Wildcard mask      0.0.0.63                                              │
│   Network address    172.16.40.0                                           │
│   Broadcast address  172.16.40.63                                          │
│   Usable host range  172.16.40.1 - 172.16.40.62                            │
│   Usable hosts       62                                                    │
│   Total addresses    64                                                    │
│   Requested hosts    50  (12 spare)                                        │
│   Binary address     10101100.00010000.00101000.00001001                   │
│   Binary mask        11111111.11111111.11111111.11000000                   │
├────────────────────────────────────────────────────────────────────────────┤
│ Tab/Up/Down Field   F1-F3/PgUp/PgDn Mode   Esc Clear all   Ctrl+Q Quit     │
└────────────────────────────────────────────────────────────────────────────┘
```

## Features

Three calculator modes:

| Key | Mode             | You enter                                   | You get                                                         |
|-----|------------------|---------------------------------------------|-----------------------------------------------------------------|
| F1  | CIDR             | `192.168.1.10/24`                           | Network, broadcast and usable host range                        |
| F2  | IP + Subnet mask | `10.0.0.5` and `255.255.252.0` (or `/22`)   | The same, plus the CIDR notation                                |
| F3  | IP + Host count  | `10.0.0.5` and `500`                        | The smallest subnet that fits, its mask, CIDR, network, broadcast and range |

Every mode also shows the subnet and wildcard masks, host and address counts,
the address type (private, public, loopback, CGNAT, documentation, multicast,
and so on) and the address and mask in binary, with network bits and host bits
in different colors.

- **Live results**: everything recalculates on each key press.
- **Helpful validation**: partial or invalid input shows what is wrong (for
  example "Incomplete IP address" or "its 1 bits must be contiguous"), and the
  invalid field is highlighted.
- **Per-mode input**: each mode keeps its own fields, so you can switch modes
  without losing what you typed.
- **Clear and start over**: Esc empties every field.
- **Leaves your console alone**: the calculator draws on the alternate screen
  buffer when the console supports it, so your previous output comes back
  when you quit. It redraws itself when the window is resized.

/31 subnets follow [RFC 3021](https://www.rfc-editor.org/rfc/rfc3021)
(two usable addresses, no broadcast), and /32 is a single host.

## Requirements

- Windows 11 with the built-in Windows PowerShell 5.1, or PowerShell 7+.
- A console window of at least 80 x 26 characters (Windows Terminal or the
  classic console host).

There is nothing to install and no modules are needed.

## Usage

### Interactive

```powershell
.\NetworkCalc.ps1
```

If scripts are blocked by your execution policy, run it with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\NetworkCalc.ps1
```

| Key                         | Action                         |
|-----------------------------|--------------------------------|
| Tab, Down, Enter            | Next input field               |
| Shift+Tab, Up               | Previous input field           |
| Left, Right, Home, End      | Move within the field          |
| Backspace, Delete           | Edit the field                 |
| F1, F2, F3                  | Switch to that mode            |
| PgUp, PgDn                  | Previous / next mode           |
| Esc                         | Clear every field              |
| Ctrl+Q, Ctrl+C, F10         | Quit                           |

The subnet mask field accepts dotted masks (`255.255.255.0`) and prefix
lengths (`/24` or `24`). Fields accept only the characters that make sense for
them, so stray keys are ignored.

### Non-interactive

Pass parameters to run one calculation and get an object on the pipeline
instead of the interface:

```powershell
.\NetworkCalc.ps1 -Cidr 192.168.1.10/24
.\NetworkCalc.ps1 -IPAddress 10.0.0.5 -SubnetMask 255.255.252.0
.\NetworkCalc.ps1 -IPAddress 10.0.0.5 -SubnetMask /22
.\NetworkCalc.ps1 -IPAddress 10.0.0.5 -Hosts 500
```

```
IPAddress        : 192.168.1.10
CIDR             : 192.168.1.0/24
PrefixLength     : 24
NetworkAddress   : 192.168.1.0
BroadcastAddress : 192.168.1.255
FirstUsable      : 192.168.1.1
LastUsable       : 192.168.1.254
UsableHosts      : 254
TotalAddresses   : 256
SubnetMask       : 255.255.255.0
WildcardMask     : 0.0.0.255
AddressType      : Private (RFC 1918)
RequestedHosts   :
BinaryAddress    : 11000000.10101000.00000001.00001010
BinaryMask       : 11111111.11111111.11111111.00000000
```

`BroadcastAddress` is empty for /31 and /32 subnets. `RequestedHosts` is set
only when `-Hosts` is used. Invalid input raises a terminating error with a
description of the problem.

Full help is built in:

```powershell
Get-Help .\NetworkCalc.ps1 -Full
```

## How it works

The script is split into two regions:

- **Calculation functions** parse and validate input (`ConvertTo-IPv4Integer`,
  `ConvertTo-PrefixLength`, `ConvertFrom-CidrNotation`), size subnets
  (`Get-PrefixFromHostCount`, `Get-UsableHostCount`) and build the result
  object (`Get-SubnetInfo`). Addresses are handled as 64-bit integers so the
  whole unsigned 32-bit range works the same in Windows PowerShell and
  PowerShell 7.
- **Text user interface** functions hold the screen state, translate key
  presses (`Invoke-TuiKeyPress`) and draw the frame (`Show-TuiScreen`). Each
  redraw overwrites rows in place instead of clearing the screen, which keeps
  live updates flicker-free.

The file is pure ASCII (box-drawing characters are created from their code
points), so Windows PowerShell 5.1 reads it correctly whatever its encoding.
