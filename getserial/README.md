# Get-SerialNumber

A single-file PowerShell script that shows the computer's make, model and serial number.

It runs on the Windows PowerShell 5.1 that ships with Windows 11, and on PowerShell 7. It has no external dependencies.

## Usage

```powershell
.\Get-SerialNumber.ps1 [-Make] [-Model] [-Serial] [-AsText | -AsObject] [-Help]
```

| Switch | Description |
|---|---|
| `-Make` | Output only the make (manufacturer), with no label. Aliases: `-Manufacturer`, `-Vendor` |
| `-Model` | Output only the model, with no label. |
| `-Serial` | Output only the serial number, with no label. Aliases: `-SerialNumber`, `-SN`, `-ServiceTag` |
| `-AsText` | Force plain, uncolored text output. |
| `-AsObject` | Force PowerShell object output. |
| `-Help` | Show usage. Alias: `-h`. `Get-Help .\Get-SerialNumber.ps1 -Full` also works. |

You can combine `-Make`, `-Model` and `-Serial`. The values print one per line, in make, model, serial order. With `-AsObject`, they return an object that has only the selected properties.

## Output

By default, the script picks the output format from where the output is going:

| Invocation | Output |
|---|---|
| `.\Get-SerialNumber.ps1` | Colorized, labelled report on the console |
| `.\Get-SerialNumber.ps1 \| Format-List` | Object with `Make`, `Model`, `SerialNumber` |
| `$info = .\Get-SerialNumber.ps1` | Object |
| `(.\Get-SerialNumber.ps1).Model` | Object |
| `.\Get-SerialNumber.ps1 > info.txt` | Plain text |
| `powershell -File Get-SerialNumber.ps1 > info.txt` (from cmd.exe) | Plain text |

Plain-text output looks like this:

```
Make:          Dell
Model:         Latitude 7440
Serial Number: 5ABC123
```

If a value can't be found, the report shows `Not found`, the object property is `$null`, and the value-only switches print an empty line.

## Examples

```powershell
# Colorized report
.\Get-SerialNumber.ps1

# Just the serial number (e.g. for scripts)
$sn = .\Get-SerialNumber.ps1 -Serial

# Make and model as an object
.\Get-SerialNumber.ps1 -Make -Model -AsObject

# Append to an inventory CSV
.\Get-SerialNumber.ps1 | Export-Csv inventory.csv -Append -NoTypeInformation

# Plain-text report to a file
.\Get-SerialNumber.ps1 > info.txt
```

## How it works

The script reads these sources and uses the first meaningful value it finds:

- **Make:** `Win32_ComputerSystem.Manufacturer`, `Win32_ComputerSystemProduct.Vendor`, the BIOS registry key, then `Win32_BaseBoard`.
- **Model:** `Win32_ComputerSystem.Model`, `Win32_ComputerSystemProduct.Name`, the BIOS registry key, then `Win32_BaseBoard.Product`.
- **Serial:** `Win32_BIOS.SerialNumber`, `Win32_ComputerSystemProduct.IdentifyingNumber`, `Win32_SystemEnclosure`, then `Win32_BaseBoard`.

It also applies some vendor-specific handling:

- **Placeholder values:** firmware filler such as `To be filled by O.E.M.`, `Default string`, `System Serial Number`, all-zero values and repeated-character values is skipped.
- **Lenovo:** the model is the marketing name plus the machine type, e.g. `ThinkPad X1 Carbon Gen 9 (20XW)`.
- **Custom-built PCs:** when the system fields are blank, the motherboard's make, model and serial are used.
- **Make names:** manufacturer names are shortened, e.g. `ASUSTeK COMPUTER INC.` → `ASUS`, `Hewlett-Packard` → `HP`, `Micro-Star International` → `MSI`, `innotek GmbH` → `VirtualBox`.

The serial is the Dell service tag on Dell systems. On HP, Lenovo, Acer, ASUS, Sony, Razer, Microsoft Surface and most other brands, it's the standard firmware serial.

## Running

If the execution policy blocks the script, run it with a process-scoped bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-SerialNumber.ps1
```
