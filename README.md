# Get-WinVer

A PowerShell script that displays detailed Windows version, build and
environment information: everything typically needed to identify a Windows
environment when troubleshooting.

It reports the product name, edition, display version (e.g. `25H2`), build
number, update build revision (UBR), kernel and Feature Experience Pack
versions, architecture, languages, install and boot times, and runtime
versions.

- No external modules required
- Works on Windows PowerShell 5.1 and PowerShell 7+

## Usage

```powershell
.\Get-WinVer.ps1 [-AsText | -AsObject] [<field switches>...]
.\Get-WinVer.ps1 -Help
```

Output adapts to how the script is invoked:

| Invocation                | Output                                     |
| ------------------------- | ------------------------------------------ |
| At the console            | Colorized, human-friendly report           |
| Piped or assigned         | A `[pscustomobject]` (`GetWinVer.Info`)    |
| Redirected to a file      | Plain text report                          |

### Options

| Switch      | Description                                                         |
| ----------- | ------------------------------------------------------------------- |
| `-AsText`   | Always return plain text.                                           |
| `-AsObject` | Always return an object (with field switches: only those fields).   |
| `-Help`     | Show usage information, including all field switches, and exit.     |

Set the `NO_COLOR` environment variable to disable colored output.

### Field switches

Each field switch returns only that value. Values are returned as bare text, in
the order given on the command line; add `-AsObject` to get a labeled object
instead.

| Section | Switches |
| ------- | -------- |
| Windows | `-ProductName`, `-OSName`, `-DisplayVersion` (`-DisplayName`), `-Edition`, `-CompositionEdition`, `-InstallationType`, `-ProductType`, `-SKU`, `-ReleaseId` |
| Version | `-Version`, `-Build`, `-UBR` (`-Revision`), `-FullBuild`, `-FullVersion`, `-LCUVersion`, `-KernelVersion`, `-FeatureExperiencePack` (`-FEP`), `-BuildLab`, `-BuildLabEx`, `-BuildBranch`, `-InsiderChannel` |
| System  | `-ComputerName`, `-Architecture` (`-Arch`), `-ProcessArchitecture`, `-OSLanguage`, `-UILanguage`, `-SystemLocale`, `-WindowsDirectory`, `-RegisteredOwner`, `-InstallDate`, `-LastBootTime`, `-Uptime` |
| Runtime | `-PowerShellVersion`, `-DotNetFramework` |

Aliases are shown in parentheses.

## Examples

Show a colorized report:

```powershell
.\Get-WinVer.ps1
```

Write a plain text report to a file:

```powershell
.\Get-WinVer.ps1 > winver.txt
```

Pipe the information object into another command:

```powershell
.\Get-WinVer.ps1 | Select-Object ProductName, DisplayVersion, FullBuild
```

Return just the build string, e.g. `26200.6584`:

```powershell
.\Get-WinVer.ps1 -FullBuild
```

Return an object with `DisplayVersion` and `Build` properties:

```powershell
.\Get-WinVer.ps1 -DisplayVersion -Build -AsObject
```

Show usage information:

```powershell
.\Get-WinVer.ps1 -Help
```

For the full comment-based help:

```powershell
Get-Help .\Get-WinVer.ps1 -Full
```
