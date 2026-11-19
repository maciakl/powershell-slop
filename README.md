# Get-DocumentsPath

A PowerShell script that prints the **true absolute path** of a user's Documents folder on Windows.

`$HOME\Documents` is often the wrong answer. The real location may have moved to OneDrive, been redirected to a file server, or sit behind a junction. This script checks for all of these and prints one line: the folder where the files actually live.

## What it handles

- **OneDrive Known Folder Move**: OneDrive Personal, OneDrive for Business (`OneDrive - <Org>`) and the legacy SkyDrive client
- **Folder Redirection**: Group Policy or manual, to local or UNC paths
- **Relocated user profiles**: a `ProfileImagePath` outside `C:\Users`
- **Symbolic links, junctions and mount points** anywhere in the path
- **Other users**: local, domain or Azure AD accounts, whether or not they are logged on

## Requirements

- Windows
- Windows PowerShell 5.1 (included with Windows 10/11) or PowerShell 7+
- No external modules or tools
- Looking up a user who is **not logged on** requires an elevated (Administrator) session, because the script has to load that user's `NTUSER.DAT` for a moment

## Usage

```powershell
.\Get-DocumentsPath.ps1 [[-User] <name|SID>] [-NoResolveLinks] [-Help]
```

| Parameter | Alias | Description |
|---|---|---|
| `-User` | `-u`, `-UserName` | The user to look up: `user`, `DOMAIN\user`, `AzureAD\user`, `user@domain` or a SID. Defaults to the current user. |
| `-NoResolveLinks` | `-n` | Print the configured path without resolving symbolic links or junctions. |
| `-Help` | `-h` | Show usage and exit. |

### Examples

```powershell
# Current user
PS> .\Get-DocumentsPath.ps1
C:\Users\jane\OneDrive\Documents

# A domain user whose folder is redirected
PS> .\Get-DocumentsPath.ps1 -User CONTOSO\bob
\\fileserver\home$\bob\Documents

# Look up by SID
PS> .\Get-DocumentsPath.ps1 S-1-5-21-1111111111-2222222222-3333333333-1001

# Use the result directly
PS> cd (.\Get-DocumentsPath.ps1)
```

If script execution is blocked, run it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-DocumentsPath.ps1
```

## Output and exit codes

On success, the script writes only the resolved path to standard output, so it is easy to use in other scripts.

| Exit code | Meaning |
|---|---|
| `0` | Success; the path is on stdout |
| `1` | Error; a message prefixed with `Get-DocumentsPath:` is on stderr |

## How it works

1. **Find the user.** The script turns the name into a SID through `NTAccount` translation. If that fails (for example, with a cached Azure AD account or an orphaned account), it matches the name against profile folder names in `HKLM\...\ProfileList`.
2. **Find the configured location.**
   - **Current user:** `Environment.GetFolderPath(MyDocuments)` (`SHGetFolderPath`), which already accounts for OneDrive, redirection and relocated profiles. If that path is missing, the script falls back to the registry, as for other users.
   - **Other users:** the script reads `User Shell Folders`, then the legacy `Shell Folders` key, from the user's registry hive. It uses `HKU\<SID>` if the user is logged on, and otherwise loads `NTUSER.DAT` temporarily. Variables such as `%USERPROFILE%` and `%OneDrive%` are expanded with that user's environment, not the caller's.
3. **Fall back to OneDrive.** If the configured folder does not exist, the script tries the `Documents` folder inside each configured OneDrive account (Business first, then Personal, then SkyDrive).
4. **Resolve links.** The script calls `GetFinalPathNameByHandleW` to get the final path. If native code cannot be loaded (for example, in Constrained Language Mode), it walks the path one part at a time with pure PowerShell instead. Volume GUID paths and `\\?\` prefixes are removed from the result.

## Notes

- If the configured Documents folder does not exist and no OneDrive fallback is found, the script still prints the configured path, which is where Windows expects the folder to be.
- Links are resolved only if the folder exists. With `-NoResolveLinks`, the path is printed as configured.
