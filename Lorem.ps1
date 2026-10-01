<#
.SYNOPSIS
    Generates random lorem ipsum placeholder text.

.DESCRIPTION
    Writes lorem ipsum text to standard output, built from the standard lorem
    ipsum vocabulary. Output is randomized on every run. By default the text
    begins with "Lorem ipsum dolor sit amet"; use -NoLorem to suppress that.

    Exactly one of -Paragraphs, -Words or -Bytes may be given. With none of
    them, 5 paragraphs are generated.

.PARAMETER Paragraphs
    Number of paragraphs to generate (default 5). Paragraphs are separated by
    a blank line.

.PARAMETER Words
    Number of words to generate, formatted as sentences.

.PARAMETER Bytes
    Number of bytes (ASCII characters) to generate, not counting the trailing
    newline added by the console. Text is cut at exactly this length.

.PARAMETER NoLorem
    Do not start the output with "Lorem ipsum dolor sit amet".

.EXAMPLE
    .\Lorem.ps1
    Five paragraphs starting with "Lorem ipsum dolor sit amet".

.EXAMPLE
    .\Lorem.ps1 -Paragraphs 2 -NoLorem

.EXAMPLE
    .\Lorem.ps1 -Words 50

.EXAMPLE
    .\Lorem.ps1 -Bytes 1024 | Set-Content filler.txt
#>
[CmdletBinding(DefaultParameterSetName = 'Paragraphs')]
param(
    [Parameter(ParameterSetName = 'Paragraphs', Position = 0)]
    [ValidateRange(1, 100000)]
    [int]$Paragraphs = 5,

    [Parameter(ParameterSetName = 'Words', Mandatory = $true)]
    [ValidateRange(1, 10000000)]
    [int]$Words,

    [Parameter(ParameterSetName = 'Bytes', Mandatory = $true)]
    [ValidateRange(1, 100000000)]
    [int]$Bytes,

    [Alias('NoStart')]
    [switch]$NoLorem
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Standard lorem ipsum vocabulary (from Cicero's "De finibus bonorum et malorum"
# as used in the classic lorem ipsum passage).
$Vocabulary = @(
    'a', 'ac', 'accumsan', 'ad', 'adipiscing', 'aenean', 'aliquam', 'aliquet',
    'amet', 'ante', 'aptent', 'arcu', 'at', 'auctor', 'augue', 'bibendum',
    'blandit', 'class', 'commodo', 'condimentum', 'congue', 'consectetur',
    'consequat', 'conubia', 'convallis', 'cras', 'cubilia', 'curabitur',
    'curae', 'cursus', 'dapibus', 'diam', 'dictum', 'dictumst', 'dignissim',
    'dis', 'dolor', 'donec', 'dui', 'duis', 'efficitur', 'egestas', 'eget',
    'eleifend', 'elementum', 'elit', 'enim', 'erat', 'eros', 'est', 'et',
    'etiam', 'eu', 'euismod', 'ex', 'facilisi', 'facilisis', 'fames',
    'faucibus', 'felis', 'fermentum', 'feugiat', 'finibus', 'fringilla',
    'fusce', 'gravida', 'habitant', 'habitasse', 'hac', 'hendrerit',
    'himenaeos', 'iaculis', 'id', 'imperdiet', 'in', 'inceptos', 'integer',
    'interdum', 'ipsum', 'justo', 'lacinia', 'lacus', 'laoreet', 'lectus',
    'leo', 'libero', 'ligula', 'litora', 'lobortis', 'lorem', 'luctus',
    'maecenas', 'magna', 'magnis', 'malesuada', 'massa', 'mattis', 'mauris',
    'maximus', 'metus', 'mi', 'molestie', 'mollis', 'montes', 'morbi', 'mus',
    'nam', 'nascetur', 'natoque', 'nec', 'neque', 'netus', 'nibh', 'nisi',
    'nisl', 'non', 'nostra', 'nulla', 'nullam', 'nunc', 'odio', 'orci',
    'ornare', 'parturient', 'pellentesque', 'penatibus', 'per', 'pharetra',
    'phasellus', 'placerat', 'platea', 'porta', 'porttitor', 'posuere',
    'potenti', 'praesent', 'pretium', 'primis', 'proin', 'pulvinar', 'purus',
    'quam', 'quis', 'quisque', 'rhoncus', 'ridiculus', 'risus', 'rutrum',
    'sagittis', 'sapien', 'scelerisque', 'sed', 'sem', 'semper', 'senectus',
    'sit', 'sociosqu', 'sodales', 'sollicitudin', 'suscipit', 'suspendisse',
    'taciti', 'tellus', 'tempor', 'tempus', 'tincidunt', 'torquent',
    'tortor', 'tristique', 'turpis', 'ullamcorper', 'ultrices', 'ultricies',
    'urna', 'ut', 'varius', 'vehicula', 'vel', 'velit', 'venenatis',
    'vestibulum', 'vitae', 'vivamus', 'viverra', 'volutpat', 'vulputate'
)

$Opening = @('Lorem', 'ipsum', 'dolor', 'sit', 'amet,', 'consectetur', 'adipiscing', 'elit.')

$Rng = New-Object System.Random

function Get-RandomWord {
    param([string]$Previous)
    do {
        $w = $Vocabulary[$Rng.Next($Vocabulary.Count)]
    } while ($w -eq $Previous)
    return $w
}

# Returns one sentence as an array of tokens (words with punctuation attached).
function New-Sentence {
    $length = $Rng.Next(5, 16)          # 5..15 words
    $tokens = New-Object System.Collections.Generic.List[string]
    $prev = ''
    for ($i = 0; $i -lt $length; $i++) {
        $prev = Get-RandomWord $prev
        $tokens.Add($prev)
    }
    $tokens[0] = $tokens[0].Substring(0, 1).ToUpper() + $tokens[0].Substring(1)

    # Longer sentences sometimes get a comma somewhere in the middle.
    if ($length -ge 8 -and $Rng.NextDouble() -lt 0.6) {
        $at = $Rng.Next(2, $length - 3)
        $tokens[$at] += ','
    }
    $tokens[$length - 1] += '.'
    return , $tokens.ToArray()
}

# Returns a flat token stream of at least $MinTokens tokens, or of at least
# $MinChars characters when joined with single spaces.
function New-TokenStream {
    param([int]$MinTokens = 0, [int]$MinChars = 0)
    $tokens = New-Object System.Collections.Generic.List[string]
    $chars = -1
    if (-not $NoLorem) {
        foreach ($t in $Opening) { $tokens.Add($t); $chars += $t.Length + 1 }
    }
    while ($tokens.Count -lt $MinTokens -or $chars -lt $MinChars) {
        foreach ($t in (New-Sentence)) { $tokens.Add($t); $chars += $t.Length + 1 }
    }
    return , $tokens
}

function New-Paragraph {
    param([bool]$IsFirst)
    $count = $Rng.Next(4, 9)            # 4..8 sentences
    $sentences = New-Object System.Collections.Generic.List[string]
    if ($IsFirst -and -not $NoLorem) {
        $sentences.Add($Opening -join ' ')
        $count--
    }
    for ($i = 0; $i -lt $count; $i++) {
        $sentences.Add((New-Sentence) -join ' ')
    }
    return $sentences -join ' '
}

switch ($PSCmdlet.ParameterSetName) {
    'Paragraphs' {
        $out = for ($p = 0; $p -lt $Paragraphs; $p++) { New-Paragraph -IsFirst ($p -eq 0) }
        Write-Output ($out -join ([Environment]::NewLine + [Environment]::NewLine))
    }

    'Words' {
        $tokens = New-TokenStream -MinTokens $Words
        $result = $tokens.GetRange(0, $Words).ToArray()
        # Make the last word end the text cleanly.
        $last = $result[$Words - 1].TrimEnd(',', '.')
        $result[$Words - 1] = $last + '.'
        Write-Output ($result -join ' ')
    }

    'Bytes' {
        $tokens = New-TokenStream -MinChars $Bytes
        $text = ($tokens -join ' ').Substring(0, $Bytes)
        # Avoid ending on a dangling space or comma when cut mid-sentence.
        if ($Bytes -gt 1 -and ($text.EndsWith(' ') -or $text.EndsWith(','))) {
            $text = $text.Substring(0, $Bytes - 1) + '.'
        }
        Write-Output $text
    }
}
