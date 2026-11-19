<#
.SYNOPSIS
    Interactive terminal (TUI) password strength analyzer.

.DESCRIPTION
    PasswordAnalyzer.ps1 lets you type a password and see live feedback about
    its strength. Every keystroke updates:

      * Length
      * Number of uppercase letters, lowercase letters, digits and special
        characters
      * The size of the character pool an attacker would have to search
      * Entropy (in bits), adjusted for guessable patterns
      * Detected patterns: common passwords, dictionary words, l33t
        substitutions, reversed words, keyboard walks, sequences, repeats,
        years and dates
      * A strength rating (Weak / Medium / Strong)
      * Approximate brute-force time for several attack scenarios
      * Suggestions for improving the password

    Input is masked by default. Keys:

      Tab           Show / hide the password
      Backspace     Delete the last character
      Esc, Ctrl+U   Clear the password and start over
      Ctrl+Q, Ctrl+C  Quit

    The password is held only in memory, is never written to disk, and the
    screen is cleared on exit.

    The script has no external dependencies and runs on both Windows
    PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.

.PARAMETER GuessesPerSecond
    Attacker guess rate used for the headline "Time to crack" estimate.
    Defaults to 10 billion guesses per second (a fast offline attack on an
    unsalted, fast hash using GPU hardware).

.EXAMPLE
    .\PasswordAnalyzer.ps1

    Starts the interactive analyzer.

.EXAMPLE
    .\PasswordAnalyzer.ps1 -GuessesPerSecond 1e6

    Starts the analyzer, using one million guesses per second for the
    headline crack-time estimate.

.EXAMPLE
    . .\PasswordAnalyzer.ps1
    Get-PasswordAnalysis -Password 'Tr0ub4dor&3'

    Dot-sources the script (which loads the functions without starting the
    TUI) and analyzes a password non-interactively.

.NOTES
    Brute-force entropy is Length * log2(PoolSize), where the pool size is
    the sum of the character classes present in the password:

      a-z                        26
      A-Z                        26
      0-9                        10
      ASCII symbols and space    33
      Any non-ASCII character   100  (rough approximation)

    Real attackers do not brute force; they try common passwords, words,
    names, keyboard walks, dates and so on first. The analyzer therefore
    also splits the password into the cheapest combination of guessable
    patterns and plain characters (in the spirit of Dropbox's zxcvbn) and
    uses the lower of the two numbers as the effective entropy:

      Common password    log2(rank + 1) bits (rank 1 = most popular)
      Dictionary word    log2(dictionary size) bits
      Keyboard walk      log2(47) + log2(length) bits
      Sequence           log2(4, 10 or 26) + log2(length) bits
      Repeat             cost of the repeated chunk + log2(repeat count)
      Year               log2(max(|year - this year|, 20)) bits
      Date               log2(365) + year cost
      Other characters   log2(PoolSize) bits each

    Capital letters, l33t substitutions (p@ssw0rd) and reversal add a few
    bits each. A password that is, or is mostly made of, a known common
    password is always rated Weak.

    The word lists are embedded in this script and are far smaller than the
    lists real attackers use, so treat the results as an optimistic upper
    bound.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, [double]::MaxValue)]
    [double]$GuessesPerSecond = 1e10
)

Set-StrictMode -Version Latest

#region Constants -----------------------------------------------------------

# Character pool sizes used for the entropy calculation.
$script:PoolLower   = 26
$script:PoolUpper   = 26
$script:PoolDigit   = 10
$script:PoolSymbol  = 33   # printable ASCII punctuation/symbols plus space
$script:PoolUnicode = 100  # rough allowance for any non-ASCII character

# Attack scenarios shown in the crack-time table.
$script:AttackScenarios = @(
    [pscustomobject]@{ Name = 'Online, throttled';         Rate = 1e2  }
    [pscustomobject]@{ Name = 'Offline, slow hash';        Rate = 1e4  }
    [pscustomobject]@{ Name = 'Offline, fast hash (GPU)';  Rate = 1e10 }
    [pscustomobject]@{ Name = 'Massive cluster';           Rate = 1e12 }
)

# Seconds in an average (Julian) year and the age of the universe in years.
$script:SecondsPerYear  = 31557600.0
$script:UniverseAgeYears = 1.38e10

# Pattern detection settings.
$script:MinPatternLength  = 3      # shortest word/sequence/repeat that counts
$script:MinWalkLength     = 4      # shortest keyboard walk that counts
$script:KeyboardStartBits = [Math]::Log(47, 2)   # unshifted keys on a US keyboard
$script:ReferenceYear     = (Get-Date).Year      # years near this are guessed first

# l33t substitutions: symbol -> letter(s) it commonly stands for. When a
# symbol has two meanings (1 = i or l) both are tried.
$script:LeetMap = New-Object 'System.Collections.Generic.Dictionary[char,string]'
foreach ($pair in @('@a', '4a', '8b', '(c', '{c', '[c', '<c', '3e', '6g', '9g',
                    '1il', '!i', '|il', '0o', '$s', '5s', '7t', '+t', '%x', '2z')) {
    $script:LeetMap[$pair[0]] = $pair.Substring(1)
}

#endregion

#region Word lists ----------------------------------------------------------

# The most commonly used passwords, roughly most popular first, compiled from
# published "top passwords" lists and breach corpora. Entries are lowercase;
# matching is case-insensitive. A match costs only log2(rank + 1) bits, so
# the very top of the list is worth almost nothing.
$script:CommonPasswordText = @'
123456 password 123456789 12345678 12345 qwerty 1234567 111111 1234567890 123123
abc123 1234 password1 iloveyou 1q2w3e4r 000000 qwerty123 zaq12wsx dragon sunshine
princess letmein 654321 monkey 1qaz2wsx 123321 qwertyuiop superman asdfghjkl 666666
football 121212 baseball welcome 1q2w3e 7777777 starwars 555555 shadow michael
123qwe master 888888 jennifer hello 112233 trustno1 jordan 123654 ashley
987654321 hunter 696969 batman access charlie donald freedom whatever mustang
123abc qazwsx loveme 11111111 passw0rd password123 admin admin123 root login
welcome1 secret changeme default guest test test123 abcdef abcd1234 aa123456
a123456 123456a 1234qwer qwer1234 asdf1234 asdfgh zxcvbnm zxcvbn qwert 1qazxsw2
q1w2e3r4 1a2b3c 147258369 159753 123789 987654 1111 0000 2000 6969
7777 1212 4321 999999 222222 333333 444444 159357 789456 147258
123456789a 11111 iloveyou1 princess1 sunshine1 football1 monkey1 dragon1 superman1 hello123
qwerty1 password12 password1234 pass123 pass1234 pass mypassword newpassword soccer hockey
killer george harley ranger thomas robert daniel buster jessica andrew
tigger joshua pepper ginger summer cheese computer internet corvette michelle
maggie hannah liverpool chelsea arsenal barcelona dallas yankees matrix merlin
cookie butterfly flower lovely love angel babygirl baby nicole lakers
basketball blink182 chocolate anthony friends purple samsung apple orange banana
snoopy mickey minecraft pokemon naruto qwerty12 qwe123 zaq1zaq1 aaaaaa abcdefg
abc12345 asd123 iloveu loveyou 5201314 woaini 1314520 fuckyou hottie jesus
taylor austin jackson silver golden diamond tiger eagle phoenix ninja
gandalf zxcv asdf qwer 12qwaszx 1q2w3e4r5t 1q2w3e4r5t6y 123qweasd qweasd qweasdzxc
1234abcd 12345a 123456q 654321a passwd p@ssw0rd p@ssword administrator 12341234 11223344
1234554321 0987654321 abcabc letmein1 secret1 admin1 welcome123 changeme1 q1w2e3 asdasd
qweqwe zxczxc qwerty1234 password2 password01 freedom1 shadow1 master1 baseball1 superstar
starwars1 computer1 matthew william jordan23 bailey charlie1 maverick sophie hunter2
hunter1 summer1 cowboys eagles steelers packers patriots spiderman test1 test1234
temp temp123 user user123 demo guest123 iloveyou2 angel1 whatever1 trustme
mother father family forever friend money qwerty01 zaq1 1qaz 1q2w
correcthorsebatterystaple letmein123 qwertyui 123qwerty password! password1! 1234567a
'@

# Common English words, first names, places and pop-culture terms that show
# up in passwords. Every entry costs the same: log2(number of words).
$script:DictionaryWordText = @'
the and you for all one man boy god sex fun cat dog sun red big hot war car
love lover lovely loving heart honey sweet sweetie sugar angel babe darling kiss
happy smile dream dreams hope faith peace freedom friend friends forever trust
mother father mommy daddy sister brother family daughter wife husband grandma
grandpa child children girl girls lady woman women guy guys people
dog dogs cat cats bird fish horse tiger lion bear wolf eagle shark snake dragon
monkey rabbit bunny puppy kitty kitten mouse duck goose falcon hawk raven
panther jaguar leopard cheetah zebra giraffe elephant turtle frog spider bee
butterfly pony fox deer moose owl dolphin whale penguin panda koala cobra viper
lizard pig cow sheep goat chicken parrot bull buffalo
red blue green yellow black white orange purple pink brown gray grey silver
gold golden violet indigo crimson scarlet
sun moon star stars sky cloud rain snow storm thunder lightning fire water
earth wind ocean sea river lake mountain forest tree flower rose lily daisy
garden summer winter spring autumn fall beach island desert valley
january february march april june july august september october november
december monday tuesday wednesday thursday friday saturday sunday
football soccer baseball basketball hockey tennis golf boxing racing game games
gamer player master killer hunter warrior soldier ninja pirate knight king
queen prince princess lord legend hero champion winner
computer internet password admin login user system server secret access
security network google apple samsung windows linux iphone android mobile
phone email office welcome hello letmein whatever nothing something
everything anything default change changeme guest test
superman batman spiderman starwars matrix pokemon minecraft naruto gandalf
merlin wizard magic shadow ghost demon devil zombie vampire monster
pizza cheese cookie chocolate coffee candy banana cherry lemon peach pepper
ginger butter bacon burger
mustang corvette ferrari porsche honda toyota ford mercedes harley
michael jennifer jessica ashley daniel david james john robert william thomas
joseph charles christopher matthew anthony andrew joshua mark steven paul
kevin brian george edward richard jason justin ryan eric adam jordan taylor
austin jackson tyler alex alexander nicholas benjamin samuel jacob ethan
nathan aaron kyle mary patricia linda barbara elizabeth susan sarah karen
nancy lisa betty margaret sandra emily emma olivia sophia sophie isabella
mia ava abigail madison chloe hannah samantha amanda melissa michelle nicole
stephanie rachel lauren megan heather amber danielle brittany maggie bailey
buddy max charlie rocky lucky buster tigger molly luna bella lucy
time life world home house work school money power energy light dark night
day morning evening city town country america usa canada london paris york
texas florida california chicago boston miami
like want need make take give find live play stop start run jump walk talk
think know feel help call come look open close kill fight win lose
good bad great best better small little cool hot cold nice pretty beautiful
crazy funny smart strong super lucky sexy wild free fast quick slow young
old new correct horse battery staple
truck bike boat train plane ship rocket space planet galaxy universe music
song guitar piano rock metal jazz dance party movie book story paper pencil
table chair door window wall floor room kitchen bed sleep cash dollar bank
coin diamond crystal jewel pearl ruby emerald sapphire
head hand eye eyes face blood bone soul spirit mind
death cross church jesus christ lord heaven hell bible grace glory holy
birthday christmas holiday vacation weekend college student teacher doctor
nurse police army navy marine pilot captain chief boss
alpha beta gamma delta omega zero one two three four five six seven eight
nine ten hundred thousand million first last number letter
'@

# Keyboard walks: rows, columns and zig-zags on US QWERTY, QWERTZ and AZERTY
# layouts, plus the numeric keypad. Reversed walks are added automatically.
$script:KeyboardWalks = @(
    '`1234567890-=', 'qwertyuiop[]\', 'asdfghjkl;', 'zxcvbnm,./', '~!@#$%^&*()_+'
    '1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik,9ol.0p;/'
    'zaq1xsw2cde3vfr4bgt5nhy6mju7,ki8.lo9/;p0'
    '1q2w3e4r5t6y7u8i9o0p', 'q1w2e3r4t5y6u7i8o9p0'
    'qazwsxedcrfvtgbyhnujmikolp', 'qweasdzxc', 'qwertzuiop', 'yxcvbnm'
    'azertyuiop', 'qsdfghjklm', 'wxcvbn'
    '7894561230', '1472583690', '741852963', '963852741', '159753', '357951'
)

#endregion

#region Analysis functions --------------------------------------------------

function Get-PasswordAnalysis {
    <#
    .SYNOPSIS
        Analyzes a password and returns its statistics.
    .DESCRIPTION
        Counts character classes, computes pool size, brute-force entropy and
        pattern-adjusted entropy, detects guessable patterns, and rates the
        password as Weak, Medium or Strong. Returns a single object.

        Entropy is the effective (pattern-adjusted) entropy and is what the
        strength rating and crack times are based on. BruteForceEntropy is
        the naive Length * log2(PoolSize) figure.
    .PARAMETER Password
        The plain-text password to analyze. May be empty.
    .EXAMPLE
        Get-PasswordAnalysis -Password 'correct horse battery staple'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Password
    )

    $upper = 0; $lower = 0; $digit = 0; $special = 0
    foreach ($c in $Password.ToCharArray()) {
        # Counts use Unicode categories, so accented letters count as letters.
        if     ([char]::IsUpper($c)) { $upper++ }
        elseif ([char]::IsLower($c)) { $lower++ }
        elseif ([char]::IsDigit($c)) { $digit++ }
        else                         { $special++ }
    }

    $length     = $Password.Length
    $pool       = Get-CharacterPoolSize -Password $Password
    $bruteForce = Get-EntropyBit -Length $length -PoolSize $pool
    $pattern    = Get-PatternEntropy -Password $Password
    $entropy    = [Math]::Min($bruteForce, $pattern.Bits)

    # Common-password checks. "IsCommonPassword" means the whole password is
    # on the list (ignoring case and l33t). "ContainsCommonPassword" means
    # common passwords make up at least half of it, e.g. "Password-123".
    $commonRank = 0
    $covered = New-Object 'bool[]' $length
    foreach ($m in $pattern.Matches) {
        if ($m.Type -ne 'CommonPassword') { continue }
        if ($m.Start -eq 0 -and $m.Length -eq $length -and -not $m.Reversed) {
            if ($commonRank -eq 0 -or $m.Rank -lt $commonRank) { $commonRank = $m.Rank }
        }
        if ($m.Length -ge 4) {
            for ($k = $m.Start; $k -lt $m.End; $k++) { $covered[$k] = $true }
        }
    }
    $coveredCount = 0
    foreach ($flag in $covered) { if ($flag) { $coveredCount++ } }
    $isCommon       = $commonRank -gt 0
    $containsCommon = $isCommon -or ($length -gt 0 -and $coveredCount * 2 -ge $length)

    $classes = @($upper, $lower, $digit, $special | Where-Object { $_ -gt 0 }).Count

    [pscustomobject]@{
        Length                 = $length
        Uppercase              = $upper
        Lowercase              = $lower
        Digits                 = $digit
        Special                = $special
        ClassCount             = $classes
        PoolSize               = $pool
        BruteForceEntropy      = $bruteForce
        Entropy                = $entropy
        Patterns               = $pattern.Patterns
        IsCommonPassword       = $isCommon
        CommonPasswordRank     = $commonRank
        ContainsCommonPassword = $containsCommon
        Strength               = Get-StrengthRating -Length $length -ClassCount $classes `
                                    -Entropy $entropy -CommonPassword $containsCommon
    }
}

function Get-CharacterPoolSize {
    <#
    .SYNOPSIS
        Returns the brute-force character pool size for a password.
    .DESCRIPTION
        Sums the sizes of the ASCII character classes present (a-z, A-Z, 0-9,
        symbols and space) plus a rough allowance for non-ASCII characters.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Password)

    $hasLower = $false; $hasUpper = $false; $hasDigit = $false
    $hasSymbol = $false; $hasNonAscii = $false
    foreach ($c in $Password.ToCharArray()) {
        $code = [int]$c
        if     ($code -ge 97 -and $code -le 122) { $hasLower    = $true }  # a-z
        elseif ($code -ge 65 -and $code -le 90)  { $hasUpper    = $true }  # A-Z
        elseif ($code -ge 48 -and $code -le 57)  { $hasDigit    = $true }  # 0-9
        elseif ($code -ge 32 -and $code -le 126) { $hasSymbol   = $true }  # symbols, space
        else                                     { $hasNonAscii = $true }
    }

    $pool = 0
    if ($hasLower)    { $pool += $script:PoolLower }
    if ($hasUpper)    { $pool += $script:PoolUpper }
    if ($hasDigit)    { $pool += $script:PoolDigit }
    if ($hasSymbol)   { $pool += $script:PoolSymbol }
    if ($hasNonAscii) { $pool += $script:PoolUnicode }
    return $pool
}

function Get-PatternEntropy {
    <#
    .SYNOPSIS
        Estimates entropy by splitting a password into guessable patterns.
    .DESCRIPTION
        Finds every pattern match (see Find-PasswordPattern), then uses
        dynamic programming to pick the combination of matches and plain
        characters that is cheapest for an attacker. Plain characters cost
        log2(PoolSize) bits each, so the result never exceeds the brute-force
        entropy.

        Returns an object with:
          Bits      the minimum total bits
          Patterns  the matches used in that cheapest split, in order
          Matches   every match found
    .PARAMETER Password
        The password (or password fragment) to analyze.
    .PARAMETER Cache
        Memo of fragment -> bits, shared with recursive calls made while
        analyzing repeated chunks. Created automatically when omitted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Password,
        [Parameter()] [System.Collections.Generic.Dictionary[string,double]]$Cache
    )

    if ($null -eq $Cache) {
        $Cache = New-Object 'System.Collections.Generic.Dictionary[string,double]' ([StringComparer]::Ordinal)
    }

    $n = $Password.Length
    $pool = Get-CharacterPoolSize -Password $Password
    $charBits = if ($pool -gt 1) { [Math]::Log($pool, 2) } else { 0.0 }
    $found = @(Find-PasswordPattern -Password $Password -Cache $Cache)

    # Group matches by the position just past their last character.
    $byEnd = @{}
    foreach ($m in $found) {
        if (-not $byEnd.ContainsKey($m.End)) {
            $byEnd[$m.End] = New-Object System.Collections.Generic.List[object]
        }
        $byEnd[$m.End].Add($m)
    }

    # best[j] = cheapest cost of the first j characters; choice[j] = the match
    # ending at j used to get there ($null means "one plain character").
    $best   = New-Object 'double[]' ($n + 1)
    $choice = New-Object 'object[]' ($n + 1)
    for ($j = 1; $j -le $n; $j++) {
        $best[$j] = $best[$j - 1] + $charBits
        if ($byEnd.ContainsKey($j)) {
            foreach ($m in $byEnd[$j]) {
                $cost = $best[$m.Start] + $m.Bits
                if ($cost -lt $best[$j]) { $best[$j] = $cost; $choice[$j] = $m }
            }
        }
    }

    $used = New-Object System.Collections.Generic.List[object]
    $j = $n
    while ($j -gt 0) {
        $m = $choice[$j]
        if ($null -ne $m) { $used.Insert(0, $m); $j = $m.Start } else { $j-- }
    }

    [pscustomobject]@{
        Bits     = $best[$n]
        Patterns = $used.ToArray()
        Matches  = $found
    }
}

function Find-PasswordPattern {
    <#
    .SYNOPSIS
        Finds every guessable pattern in a password.
    .DESCRIPTION
        Returns one object per match with Type, Start, End, Length, Token,
        Word, Rank, Substitutions, Reversed and Bits (the cost for an
        attacker to guess that piece). Types:

          CommonPassword  on the embedded most-common-passwords list
          Dictionary      an English word, name or place
          Keyboard        a keyboard walk such as qwerty or 1qaz2wsx
          Sequence        abc, 9876, xyz ...
          Repeat          aaa, abcabc, 1212 ...
          Year            1900-2049
          Date            6 or 8 digits that form a valid date

        Words are matched case-insensitively, with l33t substitutions undone
        and reversed.
    .PARAMETER Password
        The password to search.
    .PARAMETER Cache
        Memo used when analyzing repeated chunks (see Get-PatternEntropy).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Password,
        [Parameter()] [System.Collections.Generic.Dictionary[string,double]]$Cache
    )

    if ($null -eq $Cache) {
        $Cache = New-Object 'System.Collections.Generic.Dictionary[string,double]' ([StringComparer]::Ordinal)
    }

    $n = $Password.Length
    if ($n -lt $script:MinPatternLength) { return }
    $lower = $Password.ToLowerInvariant()
    $found = New-Object System.Collections.Generic.List[object]

    # --- Common passwords and dictionary words ---------------------------
    # Texts to scan: the plain lowercase password, copies with l33t undone,
    # and the plain text reversed. Each scan stops extending a candidate as
    # soon as it is no longer the prefix of any word, which keeps this fast.
    $chars = $lower.ToCharArray()
    [Array]::Reverse($chars)
    $texts = New-Object System.Collections.Generic.List[object]
    $leetVariants = @(Get-LeetVariant -Text $lower)
    for ($v = 0; $v -lt $leetVariants.Count; $v++) {
        $texts.Add(@($leetVariants[$v], ($v -gt 0), $false))   # text, isLeet, isReversed
    }
    $texts.Add(@((-join $chars), $false, $true))

    $rank = 0
    foreach ($entry in $texts) {
        $text = $entry[0]; $isLeet = $entry[1]; $isReversed = $entry[2]
        for ($i = 0; $i -le $n - $script:MinPatternLength; $i++) {
            for ($len = $script:MinPatternLength; $i + $len -le $n; $len++) {
                $candidate = $text.Substring($i, $len)
                if (-not $script:WordPrefixes.Contains($candidate)) { break }

                # Position of the match in the original password.
                $start = if ($isReversed) { $n - $i - $len } else { $i }
                $plain = $lower.Substring($start, $len)

                foreach ($table in $script:WordTables) {
                    if (-not $table.Words.TryGetValue($candidate, [ref]$rank)) { continue }

                    $subs = 0
                    if ($isLeet) {
                        # A l33t copy identical to the plain text was already
                        # matched by the plain scan.
                        for ($k = 0; $k -lt $len; $k++) {
                            if ($candidate[$k] -cne $plain[$k]) { $subs++ }
                        }
                        if ($subs -eq 0) { continue }
                    }
                    # Palindromes and very short words do not count as reversed.
                    if ($isReversed -and ($len -lt 4 -or $candidate -ceq $plain)) { continue }

                    $token = $Password.Substring($start, $len)
                    $bits  = if ($table.ByRank) { [Math]::Log($rank + 1, 2) } else { $table.FixedBits }
                    $bits += (Get-CaseBit -Token $token) + $subs
                    if ($isReversed) { $bits += 1 }
                    $found.Add((New-PatternMatch -Type $table.Type -Start $start -Token $token `
                        -Bits $bits -Word $candidate -Rank $rank -Substitutions $subs -Reversed $isReversed))
                }
            }
        }
    }

    # --- Keyboard walks ----------------------------------------------------
    # KeyboardSet holds every walk substring, so once a candidate misses, no
    # longer candidate from the same start can hit.
    for ($i = 0; $i -le $n - $script:MinWalkLength; $i++) {
        for ($len = $script:MinWalkLength; $i + $len -le $n; $len++) {
            if (-not $script:KeyboardSet.Contains($lower.Substring($i, $len))) { break }
            $token = $Password.Substring($i, $len)
            $bits = $script:KeyboardStartBits + [Math]::Log($len, 2) + (Get-CaseBit -Token $token)
            $found.Add((New-PatternMatch -Type 'Keyboard' -Start $i -Token $token -Bits $bits))
        }
    }

    # --- Sequences (abc, 4567, zyx) --------------------------------------
    for ($i = 0; $i -le $n - 3; $i++) {
        $first = $lower[$i]
        $isDigit  = $first -ge [char]'0' -and $first -le [char]'9'
        $isLetter = $first -ge [char]'a' -and $first -le [char]'z'
        if (-not ($isDigit -or $isLetter)) { continue }

        $delta = [int]$lower[$i + 1] - [int]$first
        if ($delta -ne 1 -and $delta -ne -1) { continue }

        $end = $i + 1   # index of the last character in the run
        while ($end + 1 -lt $n -and ([int]$lower[$end + 1] - [int]$lower[$end]) -eq $delta) {
            $next = $lower[$end + 1]
            $sameClass = if ($isDigit) { $next -ge [char]'0' -and $next -le [char]'9' }
                         else          { $next -ge [char]'a' -and $next -le [char]'z' }
            if (-not $sameClass) { break }
            $end++
        }
        if ($end - $i + 1 -lt 3) { continue }

        # Obvious starting points are guessed first.
        $base = if ('a', 'z', '0', '1', '9' -ccontains [string]$first) { 4 }
                elseif ($isDigit) { 10 } else { 26 }
        for ($last = $i + 2; $last -le $end; $last++) {
            $len = $last - $i + 1
            $token = $Password.Substring($i, $len)
            $bits = [Math]::Log($base, 2) + [Math]::Log($len, 2)
            if ($delta -lt 0) { $bits += 1 }
            if ($token -cne $token.ToLowerInvariant()) { $bits += 1 }
            $found.Add((New-PatternMatch -Type 'Sequence' -Start $i -Token $token -Bits $bits))
        }
    }

    # --- Repeats (aaa, abcabc, 1212) ---------------------------------------
    # The repeated chunk is itself analyzed for patterns, so "abcabc" costs
    # about as much as "abc" plus one bit.
    for ($i = 0; $i -lt $n - 1; $i++) {
        $runs = @{}   # chunk length -> repeat count found at this position
        for ($chunkLen = 1; $i + 2 * $chunkLen -le $n; $chunkLen++) {
            $count = 1
            while ($i + ($count + 1) * $chunkLen -le $n -and
                   [string]::CompareOrdinal($Password, $i, $Password, $i + $count * $chunkLen, $chunkLen) -eq 0) {
                $count++
            }
            if ($count -lt 2) { continue }

            # Skip chunks made of a shorter repeating chunk ("abab" = "ab" x 2).
            $redundant = $false
            foreach ($shorter in $runs.Keys) {
                if ($chunkLen % $shorter -eq 0 -and $runs[$shorter] * $shorter -ge $chunkLen) {
                    $redundant = $true; break
                }
            }
            $runs[$chunkLen] = $count
            if ($redundant) { continue }

            # Skip runs that are just the tail of a run starting one chunk earlier.
            if ($i -ge $chunkLen -and
                [string]::CompareOrdinal($Password, $i - $chunkLen, $Password, $i, $chunkLen) -eq 0) {
                continue
            }
            if ($count * $chunkLen -lt $script:MinPatternLength) { continue }

            $chunk = $Password.Substring($i, $chunkLen)
            $chunkBits = 0.0
            if (-not $Cache.TryGetValue($chunk, [ref]$chunkBits)) {
                $chunkBits = (Get-PatternEntropy -Password $chunk -Cache $Cache).Bits
                $Cache[$chunk] = $chunkBits
            }
            $token = $Password.Substring($i, $count * $chunkLen)
            $bits = $chunkBits + [Math]::Log($count, 2)
            $found.Add((New-PatternMatch -Type 'Repeat' -Start $i -Token $token -Bits $bits))
        }
    }

    # --- Years and dates -----------------------------------------------------
    for ($i = 0; $i -le $n - 4; $i++) {
        foreach ($len in 4, 6, 8) {
            if ($i + $len -gt $n) { break }
            $token = $Password.Substring($i, $len)
            if ($token -notmatch '^[0-9]+$') { break }   # longer ones would fail too

            if ($len -eq 4) {
                $year = [int]$token
                if ($year -ge 1900 -and $year -le 2049) {
                    $bits = Get-YearBit -Year $year
                    $found.Add((New-PatternMatch -Type 'Year' -Start $i -Token $token -Bits $bits))
                }
            }
            else {
                $years = @(Get-DateYear -Digits $token)
                if ($years.Count -gt 0) {
                    $yearBits = ($years | ForEach-Object { Get-YearBit -Year $_ } | Measure-Object -Minimum).Minimum
                    $bits = [Math]::Log(365, 2) + $yearBits
                    $found.Add((New-PatternMatch -Type 'Date' -Start $i -Token $token -Bits $bits))
                }
            }
        }
    }

    $found.ToArray()
}

function New-PatternMatch {
    <#
    .SYNOPSIS
        Creates a pattern-match object (used by Find-PasswordPattern).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] [int]$Start,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [double]$Bits,
        [Parameter()] [string]$Word = '',
        [Parameter()] [int]$Rank = 0,
        [Parameter()] [int]$Substitutions = 0,
        [Parameter()] [bool]$Reversed = $false
    )

    [pscustomobject]@{
        Type          = $Type
        Start         = $Start
        End           = $Start + $Token.Length
        Length        = $Token.Length
        Token         = $Token
        Word          = $Word
        Rank          = $Rank
        Substitutions = $Substitutions
        Reversed      = $Reversed
        Bits          = [Math]::Max(1.0, $Bits)   # every pattern costs at least 1 bit
    }
}

function Get-LeetVariant {
    <#
    .SYNOPSIS
        Returns the text plus up to two copies with l33t substitutions undone.
    .DESCRIPTION
        "p@55w0rd1" -> "p@55w0rd1", "passwordi", "passwordl". Every variant
        has the same length, so positions line up.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)

    $first  = New-Object System.Text.StringBuilder
    $second = New-Object System.Text.StringBuilder
    $sub = $null
    foreach ($c in $Text.ToCharArray()) {
        if ($script:LeetMap.TryGetValue($c, [ref]$sub)) {
            [void]$first.Append($sub[0])
            [void]$second.Append($sub[$sub.Length - 1])
        }
        else {
            [void]$first.Append($c)
            [void]$second.Append($c)
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    $result.Add($Text)
    $a = $first.ToString(); $b = $second.ToString()
    if ($a -cne $Text) { $result.Add($a) }
    if ($b -cne $Text -and $b -cne $a) { $result.Add($b) }
    return $result.ToArray()
}

function Get-CaseBit {
    <#
    .SYNOPSIS
        Extra bits an attacker needs to guess the capitalization of a word.
    .DESCRIPTION
        All lowercase costs nothing; Capitalized, ALL CAPS or a single capital
        at the end costs 1 bit; anything else costs log2 of the number of
        ways to place that many capitals.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [string]$Token)

    $upper = 0; $lower = 0
    foreach ($c in $Token.ToCharArray()) {
        if     ([char]::IsUpper($c)) { $upper++ }
        elseif ([char]::IsLower($c)) { $lower++ }
    }
    if ($upper -eq 0) { return 0.0 }
    if ($lower -eq 0) { return 1.0 }
    if ($upper -eq 1 -and ([char]::IsUpper($Token[0]) -or [char]::IsUpper($Token[$Token.Length - 1]))) {
        return 1.0
    }

    # Sum of C(letters, k) for k = 1 .. min(upper, lower).
    $letters = $upper + $lower
    $total = 0.0; $binomial = 1.0
    for ($k = 1; $k -le [Math]::Min($upper, $lower); $k++) {
        $binomial = $binomial * ($letters - $k + 1) / $k
        $total += $binomial
    }
    return [Math]::Log($total, 2)
}

function Get-YearBit {
    <#
    .SYNOPSIS
        Bits needed to guess a year; recent years are guessed first.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [int]$Year)

    return [Math]::Log([Math]::Max([Math]::Abs($Year - $script:ReferenceYear), 20), 2)
}

function Get-DateYear {
    <#
    .SYNOPSIS
        Returns the year of every valid date reading of a 6- or 8-digit string.
    .DESCRIPTION
        Tries YYYYMMDD, DDMMYYYY and MMDDYYYY for 8 digits and YYMMDD, DDMMYY
        and MMDDYY for 6 digits. Two-digit years map to 19xx or 20xx.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)] [string]$Digits)

    # Each layout: start/length of year, month and day.
    $layouts = if ($Digits.Length -eq 8) {
        @( @(0, 4, 4, 6), @(4, 4, 2, 0), @(4, 4, 0, 2) )
    }
    elseif ($Digits.Length -eq 6) {
        @( @(0, 2, 2, 4), @(4, 2, 2, 0), @(4, 2, 0, 2) )
    }
    else { @() }

    foreach ($l in $layouts) {
        $year  = [int]$Digits.Substring($l[0], $l[1])
        $month = [int]$Digits.Substring($l[2], 2)
        $day   = [int]$Digits.Substring($l[3], 2)
        if ($l[1] -eq 2) {
            $year += if ($year -le ($script:ReferenceYear % 100) + 5) { 2000 } else { 1900 }
        }
        if ($year -ge 1900 -and $year -le 2049 -and $month -ge 1 -and $month -le 12 -and
            $day -ge 1 -and $day -le 31) {
            $year
        }
    }
}

function ConvertTo-RankTable {
    <#
    .SYNOPSIS
        Turns a whitespace-separated word list into a word -> rank lookup.
    .DESCRIPTION
        The first word gets rank 1. Duplicates keep their first rank and
        words shorter than MinLength are skipped.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string,int]])]
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter()] [int]$MinLength = 3
    )

    $table = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    foreach ($word in ($Text -split '\s+')) {
        if ($word.Length -ge $MinLength -and -not $table.ContainsKey($word)) {
            $table[$word] = $table.Count + 1
        }
    }
    # The unary comma stops PowerShell from unrolling the collection. (Write-
    # Output -NoEnumerate would wrap it in a List on PowerShell 7.)
    return , $table
}

# Build the lookup tables once, when the script loads.
$script:CommonPasswords = ConvertTo-RankTable -Text $script:CommonPasswordText -MinLength $script:MinPatternLength
$script:DictionaryWords = ConvertTo-RankTable -Text $script:DictionaryWordText -MinLength $script:MinPatternLength
$script:DictionaryWordBits = [Math]::Log($script:DictionaryWords.Count, 2)

# Common passwords cost log2(rank + 1); dictionary words cost a flat amount.
$script:WordTables = @(
    [pscustomobject]@{ Type = 'CommonPassword'; Words = $script:CommonPasswords; ByRank = $true;  FixedBits = 0.0 }
    [pscustomobject]@{ Type = 'Dictionary';     Words = $script:DictionaryWords; ByRank = $false; FixedBits = $script:DictionaryWordBits }
)
# Every prefix (of at least MinPatternLength) of every word, so scans can
# stop as soon as a candidate cannot grow into a word.
$script:WordPrefixes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($word in @($script:CommonPasswords.Keys) + @($script:DictionaryWords.Keys)) {
    for ($len = $script:MinPatternLength; $len -le $word.Length; $len++) {
        [void]$script:WordPrefixes.Add($word.Substring(0, $len))
    }
}

# Every substring (of at least MinWalkLength) of every walk and its reverse.
$script:KeyboardSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($walk in $script:KeyboardWalks) {
    $chars = $walk.ToCharArray()
    [Array]::Reverse($chars)
    foreach ($w in @($walk, (-join $chars))) {
        for ($i = 0; $i -lt $w.Length; $i++) {
            for ($len = $script:MinWalkLength; $i + $len -le $w.Length; $len++) {
                [void]$script:KeyboardSet.Add($w.Substring($i, $len))
            }
        }
    }
}

function Get-EntropyBit {
    <#
    .SYNOPSIS
        Returns brute-force entropy in bits: Length * log2(PoolSize).
    .PARAMETER Length
        Number of characters in the password.
    .PARAMETER PoolSize
        Number of possible symbols for each character.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int]$PoolSize
    )

    if ($Length -le 0 -or $PoolSize -le 1) { return 0.0 }
    return $Length * [Math]::Log($PoolSize, 2)
}

function Get-StrengthRating {
    <#
    .SYNOPSIS
        Rates a password as None, Weak, Medium or Strong.
    .DESCRIPTION
        Strong : 12+ characters, 3+ character classes, 60+ bits of entropy
        Medium : 8+ characters,  2+ character classes, 40+ bits of entropy
        Weak   : anything else, and ALWAYS when CommonPassword is set
        None   : empty password

        Entropy should be the pattern-adjusted entropy.
    .PARAMETER CommonPassword
        True when the password is, or is mostly built from, a known common
        password. Such passwords are rated Weak no matter what.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int]$ClassCount,
        [Parameter(Mandatory)] [double]$Entropy,
        [Parameter()] [bool]$CommonPassword = $false
    )

    if ($Length -eq 0) { return 'None' }
    if ($CommonPassword) { return 'Weak' }
    if ($Length -ge 12 -and $ClassCount -ge 3 -and $Entropy -ge 60) { return 'Strong' }
    if ($Length -ge 8  -and $ClassCount -ge 2 -and $Entropy -ge 40) { return 'Medium' }
    return 'Weak'
}

function Get-CrackTimeSecond {
    <#
    .SYNOPSIS
        Average seconds needed to brute-force a password of the given entropy.
    .DESCRIPTION
        On average an attacker finds the password after searching half of the
        key space, i.e. 2^(Entropy - 1) guesses.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [double]$Entropy,
        [Parameter(Mandatory)] [double]$GuessesPerSecond
    )

    if ($Entropy -le 0) { return 0.0 }
    # Very large entropy overflows to +Infinity, which Format-Duration handles.
    return [Math]::Pow(2, $Entropy - 1) / $GuessesPerSecond
}

function Format-Duration {
    <#
    .SYNOPSIS
        Converts a number of seconds into a short human-readable string.
    .EXAMPLE
        Format-Duration -Seconds 90000   # "1 day"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double]$Seconds
    )

    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return 'longer than the age of the universe'
    }
    if ($Seconds -lt 1) { return 'instantly' }

    if ($Seconds -lt $script:SecondsPerYear) {
        $units = @(
            @{ Name = 'day';    Size = 86400 }
            @{ Name = 'hour';   Size = 3600  }
            @{ Name = 'minute'; Size = 60    }
            @{ Name = 'second'; Size = 1     }
        )
        foreach ($unit in $units) {
            if ($Seconds -ge $unit.Size) {
                $value = [Math]::Floor($Seconds / $unit.Size)
                $plural = if ($value -eq 1) { '' } else { 's' }
                return '{0} {1}{2}' -f $value, $unit.Name, $plural
            }
        }
    }

    $years = $Seconds / $script:SecondsPerYear
    $magnitudes = @(
        @{ Name = 'quadrillion'; Size = 1e15 }
        @{ Name = 'trillion';    Size = 1e12 }
        @{ Name = 'billion';     Size = 1e9  }
        @{ Name = 'million';     Size = 1e6  }
        @{ Name = 'thousand';    Size = 1e3  }
    )

    if ($years -ge 1e18) {
        $text = '{0:0.0e+0} years' -f $years
    }
    else {
        $text = $null
        foreach ($m in $magnitudes) {
            if ($years -ge $m.Size) {
                $text = '{0:N0} {1} years' -f [Math]::Floor($years / $m.Size), $m.Name
                break
            }
        }
        if (-not $text) {
            $value = [Math]::Floor($years)
            $plural = if ($value -eq 1) { '' } else { 's' }
            $text = '{0:N0} year{1}' -f $value, $plural
        }
    }

    if ($years -gt $script:UniverseAgeYears) { $text += ' (> age of universe)' }
    return $text
}

function Format-Rate {
    <#
    .SYNOPSIS
        Formats a guesses-per-second rate, e.g. 1e10 -> "10 billion/s".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double]$Rate)

    $magnitudes = @(
        @{ Name = 'trillion'; Size = 1e12 }
        @{ Name = 'billion';  Size = 1e9  }
        @{ Name = 'million';  Size = 1e6  }
        @{ Name = 'thousand'; Size = 1e3  }
    )
    foreach ($m in $magnitudes) {
        if ($Rate -ge $m.Size) { return '{0:0.##} {1}/s' -f ($Rate / $m.Size), $m.Name }
    }
    return '{0:0.##}/s' -f $Rate
}

function Get-PasswordSuggestion {
    <#
    .SYNOPSIS
        Returns a list of suggestions for improving the analyzed password.
    .PARAMETER Analysis
        Object returned by Get-PasswordAnalysis.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [pscustomobject]$Analysis)

    $tips = New-Object System.Collections.Generic.List[string]
    if ($Analysis.Length -eq 0) {
        $tips.Add('Start typing a password to analyze it.')
        return $tips.ToArray()
    }

    # Pattern problems first: they matter far more than character classes.
    $patterns = @($Analysis.Patterns)
    $types = @($patterns | ForEach-Object { $_.Type })
    if ($Analysis.IsCommonPassword) {
        $tips.Add('This is one of the most commonly used passwords. Attackers try it first.')
    }
    elseif ($Analysis.ContainsCommonPassword) {
        $tips.Add('Built on a very common password; adding digits or symbols barely helps.')
    }
    if ($types -contains 'Dictionary') {
        $tips.Add('Avoid dictionary words and names, or use 5+ random unrelated words.')
    }
    if (@($patterns | Where-Object { $_.Substitutions -gt 0 }).Count -gt 0) {
        $tips.Add('Swaps like @ for a or 0 for o are well known to attackers.')
    }
    if (@($patterns | Where-Object { $_.Reversed }).Count -gt 0) {
        $tips.Add('Reversed words are no harder to guess than normal ones.')
    }
    if ($types -contains 'Keyboard') { $tips.Add('Avoid keyboard patterns such as qwerty or 1qaz2wsx.') }
    if ($types -contains 'Sequence') { $tips.Add('Avoid sequences such as abc or 123.') }
    if ($types -contains 'Repeat')   { $tips.Add('Avoid repeated characters or chunks such as aaa or abcabc.') }
    if ($types -contains 'Year' -or $types -contains 'Date') {
        $tips.Add('Avoid years and dates; they are easy to guess.')
    }

    if ($Analysis.Length -lt 12)   { $tips.Add('Use at least 12 characters (16+ is even better).') }
    if ($Analysis.Uppercase -eq 0) { $tips.Add('Add uppercase letters.') }
    if ($Analysis.Lowercase -eq 0) { $tips.Add('Add lowercase letters.') }
    if ($Analysis.Digits -eq 0)    { $tips.Add('Add digits.') }
    if ($Analysis.Special -eq 0)   { $tips.Add('Add special characters (e.g. ! @ # $ %).') }
    if ($tips.Count -eq 0) {
        $tips.Add('Looks good! Never reuse passwords; a password manager helps.')
    }
    return $tips.ToArray()
}

function Format-PatternLabel {
    <#
    .SYNOPSIS
        Describes a pattern match for display.
    .DESCRIPTION
        When Reveal is false only the kind of pattern and its length are
        shown, so a masked password is not leaked through this text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Pattern,
        [Parameter(Mandatory)] [bool]$Reveal
    )

    $name = switch ($Pattern.Type) {
        'CommonPassword' { 'common password' }
        'Dictionary'     { 'word' }
        'Keyboard'       { 'keyboard walk' }
        'Sequence'       { 'sequence' }
        'Repeat'         { 'repeat' }
        'Year'           { 'year' }
        'Date'           { 'date' }
        default          { $Pattern.Type }
    }
    $text = if ($Reveal) { '{0} "{1}"' -f $name, $Pattern.Token }
            else         { '{0} ({1} chars)' -f $name, $Pattern.Length }

    $notes = @()
    if ($Pattern.Substitutions -gt 0) { $notes += 'l33t' }
    if ($Pattern.Reversed)            { $notes += 'reversed' }
    if ($notes.Count -gt 0) { $text += ' [' + ($notes -join ', ') + ']' }
    return $text
}

#endregion

#region Rendering functions -------------------------------------------------

function New-UiSegment {
    <#
    .SYNOPSIS
        Creates a piece of colored text for Write-UiLine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [string]$Text,
        [Parameter(Position = 1)] [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Write-UiLine {
    <#
    .SYNOPSIS
        Writes colored segments on a given screen row, padding the remainder
        of the row with spaces so stale text from a previous frame is erased.
    .DESCRIPTION
        Text is truncated to the window width to avoid line wrapping, which
        would otherwise corrupt the fixed layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Row,
        [Parameter()] [object[]]$Segment = @()
    )

    if ($Row -ge [Console]::BufferHeight) { return }

    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    [Console]::SetCursorPosition(0, $Row)

    $written = 0
    foreach ($seg in $Segment) {
        $remaining = $width - $written
        if ($remaining -le 0) { break }
        $text = $seg.Text
        if ($text.Length -gt $remaining) { $text = $text.Substring(0, $remaining) }
        Write-Host -Object $text -ForegroundColor $seg.Color -NoNewline
        $written += $text.Length
    }
    if ($written -lt $width) {
        Write-Host -Object (' ' * ($width - $written)) -NoNewline
    }
}

function Get-StrengthColor {
    <#
    .SYNOPSIS
        Maps a strength rating to a console color.
    #>
    [CmdletBinding()]
    [OutputType([ConsoleColor])]
    param([Parameter(Mandatory)] [string]$Strength)

    switch ($Strength) {
        'Strong' { [ConsoleColor]::Green }
        'Medium' { [ConsoleColor]::Yellow }
        'Weak'   { [ConsoleColor]::Red }
        default  { [ConsoleColor]::DarkGray }
    }
}

function Get-CrackTimeColor {
    <#
    .SYNOPSIS
        Colors a crack time: red under a day, yellow under a century, green beyond.
    #>
    [CmdletBinding()]
    [OutputType([ConsoleColor])]
    param([Parameter(Mandatory)] [double]$Seconds)

    if ($Seconds -lt 86400)                         { return [ConsoleColor]::Red }
    if ($Seconds -lt 100 * $script:SecondsPerYear)  { return [ConsoleColor]::Yellow }
    return [ConsoleColor]::Green
}

function Show-AnalyzerScreen {
    <#
    .SYNOPSIS
        Draws the entire analyzer UI for the current password state.
    .PARAMETER Password
        The current plain-text password.
    .PARAMETER Reveal
        When set, the password is shown in plain text instead of masked.
    .PARAMETER GuessesPerSecond
        Guess rate used for the headline crack-time estimate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Password,
        [Parameter(Mandatory)] [bool]$Reveal,
        [Parameter(Mandatory)] [double]$GuessesPerSecond
    )

    $a = Get-PasswordAnalysis -Password $Password
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $label = 22   # width of the label column
    $row = 0

    [Console]::CursorVisible = $false

    # --- Header ---------------------------------------------------------
    $rule = '=' * [Math]::Min($width, 72)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  PASSWORD ANALYZER' Cyan)
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)

    # --- Password field -------------------------------------------------
    $display = if ($Reveal) { $Password } else { '*' * $Password.Length }
    $prefix = '  Password: '
    $fieldWidth = $width - $prefix.Length - 12   # leave room for "[visible]"
    if ($fieldWidth -lt 5) { $fieldWidth = 5 }
    if ($display.Length -gt $fieldWidth) {
        # Show the tail of a long password so the user sees what they type.
        $display = '...' + $display.Substring($display.Length - ($fieldWidth - 3))
    }
    $modeText  = if ($Reveal) { ' [visible]' } else { ' [hidden]' }
    $modeColor = if ($Reveal) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
    $passwordRow = $row
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment $prefix White)
        (New-UiSegment $display White)
        (New-UiSegment $modeText $modeColor)
    )
    $cursorColumn = $prefix.Length + $display.Length
    Write-UiLine -Row ($row++)

    # --- Statistics -----------------------------------------------------
    $countColor = {
        param([int]$n)
        if ($n -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
    }

    $lengthColor = if ($a.Length -ge 12) { [ConsoleColor]::Green }
                   elseif ($a.Length -ge 8) { [ConsoleColor]::Yellow }
                   elseif ($a.Length -gt 0) { [ConsoleColor]::Red }
                   else { [ConsoleColor]::DarkGray }

    $stats = @(
        ,@('Length',            $a.Length,    $lengthColor)
        ,@('Uppercase letters', $a.Uppercase, (& $countColor $a.Uppercase))
        ,@('Lowercase letters', $a.Lowercase, (& $countColor $a.Lowercase))
        ,@('Digits',            $a.Digits,    (& $countColor $a.Digits))
        ,@('Special characters',$a.Special,   (& $countColor $a.Special))
        ,@('Character pool',    $a.PoolSize,  [ConsoleColor]::Cyan)
    )
    foreach ($s in $stats) {
        Write-UiLine -Row ($row++) -Segment @(
            (New-UiSegment ('  ' + $s[0]).PadRight($label) Gray)
            (New-UiSegment ': ' DarkGray)
            (New-UiSegment ([string]$s[1]) $s[2])
        )
    }

    # Entropy with a simple bar (100 bits = full bar). When patterns lowered
    # it, the naive brute-force figure is shown for comparison.
    $strengthColor = Get-StrengthColor -Strength $a.Strength
    $barSize = 20
    $filled = [int][Math]::Min($barSize, [Math]::Round($a.Entropy / 100 * $barSize))
    $bruteText = if ($a.BruteForceEntropy - $a.Entropy -ge 0.05) {
        '  (brute force: {0:N1})' -f $a.BruteForceEntropy
    } else { '' }
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Entropy'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment ('{0:N1} bits ' -f $a.Entropy) Cyan)
        (New-UiSegment '[' DarkGray)
        (New-UiSegment ('#' * $filled) $strengthColor)
        (New-UiSegment ('-' * ($barSize - $filled)) DarkGray)
        (New-UiSegment ']' DarkGray)
        (New-UiSegment $bruteText DarkGray)
    )

    # Patterns found (tokens are only shown when the password is visible).
    $patternSegments = New-Object System.Collections.Generic.List[object]
    $patternSegments.Add((New-UiSegment '  Patterns'.PadRight($label) Gray))
    $patternSegments.Add((New-UiSegment ': ' DarkGray))
    if ($a.Length -eq 0) {
        $patternSegments.Add((New-UiSegment '-' DarkGray))
    }
    elseif ($a.Patterns.Count -eq 0) {
        $patternSegments.Add((New-UiSegment 'none detected' Green))
    }
    else {
        for ($i = 0; $i -lt $a.Patterns.Count; $i++) {
            if ($i -gt 0) { $patternSegments.Add((New-UiSegment ', ' DarkGray)) }
            $p = $a.Patterns[$i]
            $color = if ($p.Type -eq 'CommonPassword') { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }
            $patternSegments.Add((New-UiSegment (Format-PatternLabel -Pattern $p -Reveal $Reveal) $color))
        }
    }
    Write-UiLine -Row ($row++) -Segment $patternSegments.ToArray()

    $strengthText = if ($a.Strength -eq 'None') { '-' } else { $a.Strength.ToUpper() }
    $strengthNote = if ($a.IsCommonPassword) { '  - one of the most common passwords!' }
                    elseif ($a.ContainsCommonPassword) { '  - built on a common password' }
                    else { '' }
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Strength'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment $strengthText $strengthColor)
        (New-UiSegment $strengthNote Red)
    )

    $headline = Get-CrackTimeSecond -Entropy $a.Entropy -GuessesPerSecond $GuessesPerSecond
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  Time to crack'.PadRight($label) Gray)
        (New-UiSegment ': ' DarkGray)
        (New-UiSegment (Format-Duration -Seconds $headline) (Get-CrackTimeColor -Seconds $headline))
        (New-UiSegment ('  @ ' + (Format-Rate -Rate $GuessesPerSecond)) DarkGray)
    )
    Write-UiLine -Row ($row++)

    # --- Attack scenarios -----------------------------------------------
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  Estimated time to crack by attack scenario' White)
    foreach ($scenario in $script:AttackScenarios) {
        $secs = Get-CrackTimeSecond -Entropy $a.Entropy -GuessesPerSecond $scenario.Rate
        Write-UiLine -Row ($row++) -Segment @(
            (New-UiSegment ('    ' + $scenario.Name).PadRight(30) Gray)
            (New-UiSegment (Format-Rate -Rate $scenario.Rate).PadLeft(16) DarkGray)
            (New-UiSegment '  ' Gray)
            (New-UiSegment (Format-Duration -Seconds $secs) (Get-CrackTimeColor -Seconds $secs))
        )
    }
    Write-UiLine -Row ($row++)

    # --- Suggestions (fixed number of rows so the layout never shifts) ---
    Write-UiLine -Row ($row++) -Segment (New-UiSegment '  Suggestions' White)
    $tips = @(Get-PasswordSuggestion -Analysis $a)
    $maxTips = 5
    for ($i = 0; $i -lt $maxTips; $i++) {
        if ($i -lt $tips.Count) {
            Write-UiLine -Row ($row++) -Segment @(
                (New-UiSegment '    - ' DarkGray)
                (New-UiSegment $tips[$i] Yellow)
            )
        }
        else {
            Write-UiLine -Row ($row++)
        }
    }

    # --- Footer ---------------------------------------------------------
    Write-UiLine -Row ($row++) -Segment (New-UiSegment $rule DarkCyan)
    Write-UiLine -Row ($row++) -Segment @(
        (New-UiSegment '  [Tab]' Cyan);        (New-UiSegment ' show/hide   ' Gray)
        (New-UiSegment '[Esc]' Cyan);          (New-UiSegment ' clear   ' Gray)
        (New-UiSegment '[Backspace]' Cyan);    (New-UiSegment ' delete   ' Gray)
        (New-UiSegment '[Ctrl+Q]' Cyan);       (New-UiSegment ' quit' Gray)
    )

    # Park the cursor at the end of the password field.
    $cursorColumn = [Math]::Min($cursorColumn, [Console]::WindowWidth - 1)
    if ($passwordRow -lt [Console]::BufferHeight) {
        [Console]::SetCursorPosition($cursorColumn, $passwordRow)
    }
    [Console]::CursorVisible = $true
}

#endregion

#region Main loop -----------------------------------------------------------

function Start-PasswordAnalyzer {
    <#
    .SYNOPSIS
        Runs the interactive password analyzer until the user quits.
    .PARAMETER GuessesPerSecond
        Guess rate used for the headline crack-time estimate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [double]$GuessesPerSecond)

    # The TUI needs a real console (not ISE, not redirected input).
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) {
        throw 'PasswordAnalyzer must be run in an interactive console window (e.g. Windows Terminal, powershell.exe or pwsh.exe).'
    }

    $password = New-Object System.Text.StringBuilder
    $reveal = $false
    $originalCtrlC = [Console]::TreatControlCAsInput
    $lastWidth = [Console]::WindowWidth
    $lastHeight = [Console]::WindowHeight

    try {
        # Read Ctrl+C as a key so we can exit cleanly and wipe the screen.
        [Console]::TreatControlCAsInput = $true
        Clear-Host
        Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond

        $running = $true
        while ($running) {
            # Poll so we can also react to window resizes between keystrokes.
            if (-not [Console]::KeyAvailable) {
                if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                    $lastWidth = [Console]::WindowWidth
                    $lastHeight = [Console]::WindowHeight
                    Clear-Host
                    Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond
                }
                Start-Sleep -Milliseconds 50
                continue
            }

            # Drain every pending key before redrawing (keeps pasting fast).
            while ($running -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0

                if ($ctrl -and ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::C)) {
                    $running = $false
                }
                elseif ($key.Key -eq [ConsoleKey]::Escape -or ($ctrl -and $key.Key -eq [ConsoleKey]::U)) {
                    [void]$password.Clear()
                }
                elseif ($key.Key -eq [ConsoleKey]::Tab) {
                    $reveal = -not $reveal
                }
                elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($password.Length -gt 0) { [void]$password.Remove($password.Length - 1, 1) }
                }
                elseif (-not [char]::IsControl($key.KeyChar) -and $key.KeyChar -ne [char]0) {
                    [void]$password.Append($key.KeyChar)
                }
                # Any other key (arrows, function keys, ...) is ignored.
            }

            if ($running) {
                if ([Console]::WindowWidth -ne $lastWidth -or [Console]::WindowHeight -ne $lastHeight) {
                    $lastWidth = [Console]::WindowWidth
                    $lastHeight = [Console]::WindowHeight
                    Clear-Host
                }
                Show-AnalyzerScreen -Password $password.ToString() -Reveal $reveal -GuessesPerSecond $GuessesPerSecond
            }
        }
    }
    finally {
        # Wipe the password from memory and the screen, restore console state.
        [void]$password.Clear()
        [Console]::TreatControlCAsInput = $originalCtrlC
        [Console]::CursorVisible = $true
        Clear-Host
    }
}

#endregion

# Start the TUI unless the script is being dot-sourced (which only loads the
# functions, e.g. for testing or scripting).
if ($MyInvocation.InvocationName -ne '.') {
    Start-PasswordAnalyzer -GuessesPerSecond $GuessesPerSecond
}
