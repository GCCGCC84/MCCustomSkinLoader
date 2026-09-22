# Downloads the libraries and assets for the shared test cache.
#
# Versions are processed one after another on purpose: assets and libraries are
# heavily shared between versions, and the download helper skips files that are
# already present, so a cold cache only ever downloads the union of all files
# instead of re-fetching the same objects for every version.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Entries,
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [switch]$SkipSoundAssets,
    [int]$ThrottleLimit = 16
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
Import-Module (Join-Path $libDir 'MetaLauncher.psm1') -Force
Import-Module (Join-Path $libDir 'MinecraftLauncher.psm1') -Force

$parsedEntries = ConvertFrom-Json -InputObject $Entries
$entryList = @($parsedEntries)
New-Item -ItemType Directory -Force -Path $CacheDir, $WorkDir | Out-Null

Write-Host "Preparing shared cache for $($entryList.Count) Minecraft version(s) (skipSounds=$([bool]$SkipSoundAssets))"
Write-Host "Cache directory: $CacheDir"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @()
$index = 0

foreach ($entry in $entryList) {
    $index++
    $loaders = @($entry.loaders | ConvertFrom-Json)
    Write-Host "[$index/$($entryList.Count)] $($entry.mc): $($loaders.Count) loader(s)"

    foreach ($loader in $loaders) {
        $loaderWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $profile = Get-MergedLaunchProfile -McVersion $entry.mc -Loader $loader.name -LoaderVersion $loader.version
            $null = Install-MinecraftRuntime -Profile $profile -CacheDir $CacheDir `
                -WorkDir (Join-Path $WorkDir "$($entry.mc)/$($loader.name)") `
                -SkipSoundAssets:$SkipSoundAssets -ThrottleLimit $ThrottleLimit
            Write-Host "[$($entry.mc)/$($loader.name)] cached in $([Math]::Round($loaderWatch.Elapsed.TotalSeconds, 1))s"
        } catch {
            $failed += [pscustomobject]@{ mc = $entry.mc; loader = $loader.name; error = "$_" }
        }
    }
}

$stopwatch.Stop()

$files = @(Get-ChildItem -LiteralPath $CacheDir -Recurse -File -ErrorAction SilentlyContinue)
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }
Write-Host ("Shared cache: {0} files, {1:N2} GB, prepared in {2:N1}s" -f $files.Count, ($totalBytes / 1GB), $stopwatch.Elapsed.TotalSeconds)

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Warning "cache preparation failed: $($_.mc)/$($_.loader): $($_.error)" }
    throw "Shared cache preparation failed for $($failed.Count) combo(s)"
}
