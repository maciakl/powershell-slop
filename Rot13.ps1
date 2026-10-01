<#
.SYNOPSIS
    Applies the ROT13 substitution cipher to text.

.DESCRIPTION
    Rotates every ASCII letter 13 places through the alphabet, preserving case.
    All other characters (digits, punctuation, whitespace, non-ASCII) pass
    through unchanged. Because ROT13 is its own inverse, running the output
    through the script again restores the original text.

    Input is read from the file given as an argument, or from standard input
    when no file is given. Output is written to standard output.

.PARAMETER Path
    Path to a text file to encode. If omitted, standard input is read.

.PARAMETER Help
    Displays usage information and exits.

.EXAMPLE
    .\Rot13.ps1 secret.txt

.EXAMPLE
    "Hello, World!" | .\Rot13.ps1

.EXAMPLE
    Get-Content secret.txt | .\Rot13.ps1 > decoded.txt
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$InputObject,

    [Alias('h')]
    [switch]$Help
)

begin {
    function Show-Usage {
        $name = 'Rot13.ps1'
        @"
Usage: $name [-Path] <file>
       <command> | $name
       $name -Help

Applies the ROT13 cipher to text. Letters A-Z and a-z are rotated 13 places;
all other characters are left unchanged. Applying ROT13 twice restores the
original text.

Arguments:
  <file>        Path of a text file to read. If omitted, reads standard input.

Options:
  -Help, -h     Show this help message and exit.

Examples:
  .\$name secret.txt
  "Hello, World!" | .\$name
  Get-Content secret.txt | .\$name > decoded.txt
  type secret.txt | powershell -NoProfile -File $name
"@
    }

    function ConvertTo-Rot13([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $chars = $Text.ToCharArray()
        for ($i = 0; $i -lt $chars.Length; $i++) {
            $c = [int]$chars[$i]
            if ($c -ge 65 -and $c -le 90) {          # A-Z
                $chars[$i] = [char](65 + (($c - 65 + 13) % 26))
            }
            elseif ($c -ge 97 -and $c -le 122) {     # a-z
                $chars[$i] = [char](97 + (($c - 97 + 13) % 26))
            }
        }
        return -join $chars
    }

    if ($Help) {
        Show-Usage
        exit 0
    }

    $receivedPipelineInput = $false
}

process {
    if ($PSBoundParameters.ContainsKey('InputObject')) {
        $receivedPipelineInput = $true
        if ($Path) {
            Write-Error 'Specify either a file path or piped input, not both.'
            exit 1
        }
        ConvertTo-Rot13 $InputObject
    }
}

end {
    if ($receivedPipelineInput) { return }

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Error "File not found: $Path"
            exit 1
        }
        $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        try {
            $text = [System.IO.File]::ReadAllText($fullPath)
        }
        catch {
            Write-Error "Unable to read file '$Path': $($_.Exception.Message)"
            exit 1
        }
        # Emit line by line so output behaves like Get-Content in the pipeline.
        if ($text.Length -eq 0) { return }
        $text = $text -replace '\r?\n$', ''
        foreach ($line in ($text -split '\r?\n')) {
            ConvertTo-Rot13 $line
        }
        return
    }

    # No file and nothing piped from PowerShell: read raw standard input
    # (e.g. redirected from cmd.exe, or typed interactively until Ctrl+Z, Enter).
    $reader = [Console]::In
    while ($null -ne ($line = $reader.ReadLine())) {
        ConvertTo-Rot13 $line
    }
}
