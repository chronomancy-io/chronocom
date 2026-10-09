Param(
    # Root of the UnrealScript sources to scan
    [string] $SrcRoot = (Join-Path $PSScriptRoot '..\ChronoCOM\Src\ChronoCOM\Classes'),
    # A function above this cyclomatic complexity fails the check
    [int] $Threshold = 4,
    # Print every function, not just the ones over the threshold
    [switch] $All
)

# Cyclomatic complexity per UnrealScript function, by decision points:
#   1 + count of: if, else if, for, foreach, while, do, case, && , ||, ?: (ternary)
# "else" alone and "default:" add nothing. Comments and string literals are
# stripped before counting. This is the standard decision-point definition,
# applied to the text; it is exact for that definition, not an AST analysis.

$keywordPattern = '\b(if|for|foreach|while|do|case)\b'
$results = @()

foreach ($file in Get-ChildItem -Path $SrcRoot -Filter *.uc -File) {
    $text = [IO.File]::ReadAllText($file.FullName)
    # strip block comments, line comments, string literals (keep line count by replacing with spaces)
    $text = [regex]::Replace($text, '/\*.*?\*/', { param($m) ($m.Value -replace '[^\r\n]', ' ') }, 'Singleline')
    $text = [regex]::Replace($text, '//[^\r\n]*', '')
    $text = [regex]::Replace($text, '"(\\.|[^"\\])*"', '""')

    # function headers: optional modifiers, 'function' or 'event', optional return type, name, '('
    $headers = [regex]::Matches($text, '(?m)^[ \t]*(?:(?:static|simulated|native|final|private|protected|public|exec|event|protectedwrite|privatewrite|const|latent|iterator|singular|reliable|unreliable|server|client)\s+)*(?:function|event)\s+(?:[\w<>.]+\s+)?(\w+)\s*\(')
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $h = $headers[$i]
        $start = $h.Index
        # body: from the first '{' after the header to its matching '}'
        $open = $text.IndexOf('{', $start)
        $nextHeader = if ($i + 1 -lt $headers.Count) { $headers[$i + 1].Index } else { $text.Length }
        if ($open -lt 0 -or $open -gt $nextHeader) { continue }  # declaration without body (native)
        $depth = 0; $end = -1
        for ($p = $open; $p -lt $text.Length; $p++) {
            $c = $text[$p]
            if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { $end = $p; break } }
        }
        if ($end -lt 0) { continue }
        $body = $text.Substring($open, $end - $open + 1)
        $complexity = 1
        $complexity += ([regex]::Matches($body, $keywordPattern)).Count
        $complexity += ([regex]::Matches($body, '&&|\|\|')).Count
        $complexity += ([regex]::Matches($body, '\?[^?:]*:')).Count
        $line = ($text.Substring(0, $start) -split "`n").Count
        $results += [pscustomobject]@{ File = $file.Name; Function = $h.Groups[1].Value; Line = $line; Complexity = $complexity }
    }
}

$over = @($results | Where-Object { $_.Complexity -gt $Threshold } | Sort-Object Complexity -Descending)
$shown = if ($All) { $results | Sort-Object Complexity -Descending } else { $over }

Write-Host ("Cyclomatic complexity: {0} functions in {1} files, max {2}, threshold {3}" -f $results.Count, (@($results | Select-Object -ExpandProperty File -Unique)).Count, ($results | Measure-Object Complexity -Maximum).Maximum, $Threshold)
if ($shown) { $shown | Format-Table File, Function, Line, Complexity -AutoSize | Out-String -Width 160 | Write-Host }

if ($over.Count -gt 0) {
    Write-Host ("FAIL: {0} function(s) over the threshold" -f $over.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'OK: no function over the threshold' -ForegroundColor Green
exit 0
