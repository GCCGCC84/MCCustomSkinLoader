# Downloads the libraries and assets for one shared cache group.
#
# Called by the Prepare Cache jobs. All files land in a single shared directory
# (Maven-style libraries plus content-addressed assets) that is then saved as
# one cache entry and restored read-only by the test jobs.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Entries,
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [switch]$SkipSoundAssets,
    [int]$MaxParallel = 3,
    [int]$ThrottleLimit = 12
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
Import-Module (Join-Path $libDir 'MetaLauncher.psm1') -Force
Import-Module (Join-Path $libDir 'MinecraftLauncher.psm1') -Force

$parsedEntries = ConvertFrom-Json -InputObject $Entries
$entryList = @($parsedEntries)
New-Item -ItemType Directory -Force -Path $CacheDir, $WorkDir | Out-Null

Write-Host "Preparing shared cache for $($entryList.Count) Minecraft version(s) (skipSounds=$([bool]$SkipSoundAssets), parallel=$MaxParallel)"
Write-Host "Cache directory: $CacheDir"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$failed = @($entryList | ForEach-Object -Parallel {
        $entry = $_
        $ProgressPreference = 'SilentlyContinue'
        $skipSounds = [bool]$using:SkipSoundAssets
        Import-Module (Join-Path $using:libDir 'MetaLauncher.psm1') -Force
        Import-Module (Join-Path $using:libDir 'MinecraftLauncher.psm1') -Force

        $loaders = @($entry.loaders | ConvertFrom-Json)
        Write-Host "[$($entry.mc)] start ($($loaders.Count) loader(s))"
        foreach ($loader in $loaders) {
            try {
                $profile = Get-MergedLaunchProfile -McVersion $entry.mc -Loader $loader.name -LoaderVersion $loader.version
                $null = Install-MinecraftRuntime -Profile $profile -CacheDir $using:CacheDir `
                    -WorkDir (Join-Path $using:WorkDir "$($entry.mc)/$($loader.name)") `
                    -SkipSoundAssets:$skipSounds -ThrottleLimit $using:ThrottleLimit
                Write-Host "[$($entry.mc)/$($loader.name)] cached"
            } catch {
                return [pscustomobject]@{ mc = $entry.mc; loader = $loader.name; error = "$_" }
            }
        }
        return $null
    } -ThrottleLimit $MaxParallel)

$failed = @($failed | Where-Object { $null -ne $_ })
$stopwatch.Stop()

$files = @(Get-ChildItem -LiteralPath $CacheDir -Recurse -File -ErrorAction SilentlyContinue)
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }
Write-Host ("Shared cache: {0} files, {1:N2} GB, prepared in {2:N1}s" -f $files.Count, ($totalBytes / 1GB), $stopwatch.Elapsed.TotalSeconds)

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Warning "cache preparation failed: $($_.mc)/$($_.loader): $($_.error)" }
    throw "Shared cache preparation failed for $($failed.Count) combo(s)"
}
