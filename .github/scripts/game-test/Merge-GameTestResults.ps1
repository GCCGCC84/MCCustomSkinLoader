# Merges every result.json produced by the game test jobs into a job summary.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [string]$SummaryFile
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Get-VersionSortKey {
    param([string]$Version)

    $parts = @($Version -split '[.\-]')
    $key = 0.0
    for ($i = 0; $i -lt [Math]::Min(3, $parts.Count); $i++) {
        $number = 0
        [void][int]::TryParse($parts[$i], [ref]$number)
        $key = $key * 1000 + $number
    }
    return $key
}

$loaderOrder = @{ 'fabric' = 1; 'forge' = 2; 'neoforge' = 3; 'quilt' = 4 }

$resultFiles = @()
if (Test-Path -LiteralPath $ResultsDir) {
    $resultFiles = @(Get-ChildItem -LiteralPath $ResultsDir -Recurse -Filter 'result.json' -File -ErrorAction SilentlyContinue)
}

$rows = @()
foreach ($file in $resultFiles) {
    try {
        $result = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $rows += $result
    } catch {
        $rows += [pscustomobject]@{
            mc              = $file.Directory.Name
            loader          = '?'
            loaderVersion   = ''
            status          = 'invalid'
            error           = "Could not parse $($file.FullName): $_"
            durationSeconds = 0
        }
    }
}

$rows = @($rows | Sort-Object -Property `
        @{ Expression = { Get-VersionSortKey ([string]$_.mc) } }, `
        @{ Expression = { if ($loaderOrder.ContainsKey([string]$_.loader)) { $loaderOrder[[string]$_.loader] } else { 9 } } })

$passed = @($rows | Where-Object { $_.status -eq 'passed' }).Count
$failed = @($rows | Where-Object { $_.status -ne 'passed' }).Count

$summary = @(
    '## Game test results',
    '',
    "Passed: $passed, Failed: $failed, Total: $($rows.Count)",
    '',
    '| Minecraft | Java | Loader | Loader version | Status | Joined | Skin log | Skin pixels | Duration | Error |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
)

foreach ($row in $rows) {
    $statusIcon = if ($row.status -eq 'passed') { 'PASS' } else { 'FAIL' }
    $error = [string]$row.error
    $error = $error -replace '\|', '\|' -replace '\r?\n', ' '
    if ($error.Length -gt 200) {
        $error = $error.Substring(0, 200) + '...'
    }
    $summary += "| $($row.mc) | $($row.java) | $($row.loader) | $($row.loaderVersion) | $statusIcon | $($row.joined) | $($row.skinLogLoaded) | $($row.skinPixelsPassed) | $($row.durationSeconds)s | $error |"
}

if ($rows.Count -eq 0) {
    $summary += @('', '_No game test results were produced. Check the test jobs for failures before the harness could run._')
}

if ($SummaryFile) {
    $summary | Set-Content -LiteralPath $SummaryFile -Encoding utf8
}
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

$summary | Write-Output

if ($rows.Count -gt 0 -and $failed -gt 0) {
    exit 1
}
exit 0
