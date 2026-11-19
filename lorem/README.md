# Lorem.ps1

A small PowerShell script that generates random lorem ipsum placeholder text.

Text is built from the standard lorem ipsum vocabulary and is different on every
run. By default it begins with the classic "Lorem ipsum dolor sit amet,
consectetur adipiscing elit."

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no modules or dependencies)

## Usage

```powershell
.\Lorem.ps1 [[-Paragraphs] <int>] [-NoLorem]
.\Lorem.ps1 -Words <int> [-NoLorem]
.\Lorem.ps1 -Bytes <int> [-NoLorem]
```

Only one of `-Paragraphs`, `-Words` or `-Bytes` can be used at a time. With none
of them, 5 paragraphs are generated.

| Parameter     | Description                                                                                               | Range           |
| ------------- | --------------------------------------------------------------------------------------------------------- | --------------- |
| `-Paragraphs` | Number of paragraphs (default `5`). Each has 4–8 sentences; paragraphs are separated by a blank line. Positional. | 1 – 100,000     |
| `-Words`      | Exact number of words, formatted as sentences and ending with a period.                                  | 1 – 10,000,000  |
| `-Bytes`      | Exact number of ASCII characters, not counting the trailing newline. Text is cut at this length.         | 1 – 100,000,000 |
| `-NoLorem`    | Don't start the output with "Lorem ipsum dolor sit amet". Alias: `-NoStart`.                              |                 |

## Examples

```powershell
# Five paragraphs starting with "Lorem ipsum dolor sit amet"
.\Lorem.ps1

# Two paragraphs, fully random (positional form of -Paragraphs)
.\Lorem.ps1 2 -NoLorem

# Exactly 50 words
.\Lorem.ps1 -Words 50

# 1 KB of filler text saved to a file
.\Lorem.ps1 -Bytes 1024 | Set-Content filler.txt

# Copy three paragraphs to the clipboard
.\Lorem.ps1 3 | Set-Clipboard
```

Full built-in help is available with:

```powershell
Get-Help .\Lorem.ps1 -Full
```

## Running scripts

If PowerShell refuses to run the script because of the execution policy, allow
local scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```
