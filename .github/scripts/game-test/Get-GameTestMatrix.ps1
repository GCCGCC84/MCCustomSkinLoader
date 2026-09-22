# Builds the GitHub Actions matrix for the game compatibility tests.
#
# For every Minecraft version in build.info.json the script resolves the loader
# versions that actually exist for that version from PrismLauncher meta indexes
# and reads the compatible Java major version from the net.minecraft component.

[CmdletBinding()]
param(
    [string]$InfoFile = 'build.info.json',
    [string]$GameVersions = '',
    [string]$Loaders = '',
    [string]$CacheDir,
    [string]$OutputFile,
    [string]$SummaryFile,
    [switch]$SkipSoundAssets,
    [switch]$Pretty
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/MetaLauncher.psm1') -Force

$script:QuiltSupportedGameVersions = $null
$script:QuiltSupportedGameVersionsLoaded = $false

function Get-JavaMajor {
    param(
        [Parameter(Mandatory)][string]$McVersion,
        [Parameter(Mandatory)][string]$CacheDir
    )

    try {
        $component = Get-MetaVersion -Uid 'net.minecraft' -Version $McVersion
        $majors = @($component.compatibleJavaMajors | ForEach-Object { [int]$_ })
        if ($majors.Count -gt 0) {
            return ($majors | Measure-Object -Maximum).Maximum
        }
    } catch {
        Write-Warning "Could not read compatibleJavaMajors for $McVersion : $_"
    }

    # Fallback table based on Mojang launcher metadata.
    if ($McVersion -match '^26\.') { return 25 }
    $parts = $McVersion -split '\.'
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -eq 1 -and $minor -ge 21) { return 21 }
    if ($major -eq 1 -and $minor -eq 20 -and $parts.Count -ge 3 -and [int]$parts[2] -ge 5) { return 21 }
    if ($major -eq 1 -and $minor -ge 18) { return 17 }
    if ($major -eq 1 -and $minor -eq 17) { return 17 }
    return 8
}

function Get-QuiltSupportedGameVersions {
    if ($script:QuiltSupportedGameVersionsLoaded) {
        return $script:QuiltSupportedGameVersions
    }
    $script:QuiltSupportedGameVersionsLoaded = $true

    try {
        $games = Invoke-MetaRequest -Uri 'https://meta.quiltmc.org/v3/versions/game'
        $set = @{}
        foreach ($game in @($games)) {
            $set[[string]$game.version] = $true
        }
        $script:QuiltSupportedGameVersions = $set
    } catch {
        Write-Warning "Could not read Quilt's supported game versions; falling back to intermediary availability: $_"
        $script:QuiltSupportedGameVersions = $null
    }
    return $script:QuiltSupportedGameVersions
}

function Get-LoaderEntry {
    param(
        [Parameter(Mandatory)][string]$Loader,
        [Parameter(Mandatory)][string]$McVersion
    )

    switch ($Loader.ToLowerInvariant()) {
        'forge' {
            $version = Select-MetaVersionForMinecraft -Uid 'net.minecraftforge' -MinecraftVersion $McVersion
            if ($version) { return [pscustomobject]@{ name = 'forge'; version = $version } }
            return $null
        }
        'neoforge' {
            $version = Select-MetaVersionForMinecraft -Uid 'net.neoforged' -MinecraftVersion $McVersion
            if ($version) { return [pscustomobject]@{ name = 'neoforge'; version = $version } }
            return $null
        }
        'fabric' {
            $intermediary = Select-MetaVersionForMinecraft -Uid 'net.fabricmc.intermediary' -MinecraftVersion $McVersion
            if (-not $intermediary) { return $null }
            return [pscustomobject]@{ name = 'fabric'; version = (Get-LatestMetaVersion -Uid 'net.fabricmc.fabric-loader') }
        }
        'quilt' {
            $intermediary = Select-MetaVersionForMinecraft -Uid 'net.fabricmc.intermediary' -MinecraftVersion $McVersion
            if (-not $intermediary) { return $null }
            $supported = Get-QuiltSupportedGameVersions
            if ($null -ne $supported -and -not $supported.ContainsKey($McVersion)) { return $null }
            return [pscustomobject]@{ name = 'quilt'; version = (Get-LatestMetaVersion -Uid 'org.quiltmc.quilt-loader') }
        }
        default {
            throw "Unknown loader '$Loader'"
        }
    }
}

$info = Get-Content -LiteralPath $InfoFile -Raw | ConvertFrom-Json
$allVersions = @($info.game_versions | ForEach-Object { [string]$_ })
$configuredLoaders = @($info.loaders | ForEach-Object { [string]$_ })

if ($GameVersions) {
    $requested = @($GameVersions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $missing = @($requested | Where-Object { $_ -notin $allVersions })
    if ($missing.Count -gt 0) {
        throw "Requested game versions are not listed in build.info.json: $($missing -join ', ')"
    }
    $allVersions = @($requested)
}

if ($Loaders) {
    $configuredLoaders = @($Loaders -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

$include = @()
$summaryLines = @()
$skippedVersions = @()
$cacheEntries = @()

foreach ($mcVersion in $allVersions) {
    $javaMajor = Get-JavaMajor -McVersion $mcVersion -CacheDir $CacheDir
    $loaderEntries = @()
    foreach ($loader in $configuredLoaders) {
        try {
            $entry = Get-LoaderEntry -Loader $loader -McVersion $mcVersion
        } catch {
            Write-Warning "Failed to resolve $loader for $mcVersion : $_"
            $entry = $null
        }
        if ($entry) {
            $loaderEntries += $entry
        }
    }

    if ($loaderEntries.Count -eq 0) {
        $skippedVersions += $mcVersion
        $summaryLines += "| $mcVersion | $javaMajor | _no loader available_ |"
        continue
    }

    $loaderJson = ConvertTo-Json -InputObject @($loaderEntries) -Compress -Depth 5
    $include += [ordered]@{
        mc      = $mcVersion
        java    = "$javaMajor"
        loaders = $loaderJson
    }
    $cacheEntries += [ordered]@{
        mc      = $mcVersion
        loaders = $loaderJson
    }

    $loaderText = ($loaderEntries | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '
    $summaryLines += "| $mcVersion | $javaMajor | $loaderText |"
}

# One shared download cache is prepared in the Prepare stage so test jobs
# restore a read-only cache instead of writing per-version caches. The key pins
# the exact matrix content (Minecraft + loader versions) and the sound asset
# setting, so a changed matrix produces a fresh cache.
$cacheInclude = @()
$groupSummary = @()
if ($cacheEntries.Count -gt 0) {
    $payload = [ordered]@{
        schema     = 1
        skipSounds = [bool]$SkipSoundAssets
        entries    = $cacheEntries
    }
    $payloadJson = ConvertTo-Json -InputObject $payload -Compress -Depth 10
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
    } finally {
        $sha.Dispose()
    }
    $hash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    $key = "mc-shared-win-$hash-v1"

    $cacheInclude += [ordered]@{
        key     = $key
        entries = (ConvertTo-Json -InputObject @($cacheEntries) -Compress -Depth 10)
    }
    foreach ($entry in $include) {
        $entry['cacheKey'] = $key
    }
    $groupSummary += "- $($cacheEntries.Count) Minecraft version(s), cache key ``$key``"
}

$matrix = [ordered]@{ include = $include }
$matrixJson = ConvertTo-Json -InputObject $matrix -Compress -Depth 10
$cacheMatrixJson = ConvertTo-Json -InputObject ([ordered]@{ include = $cacheInclude }) -Compress -Depth 10

Write-Host "Prepared $($include.Count) Minecraft version job(s); $($skippedVersions.Count) version(s) had no supported loader."
$groupSummary | ForEach-Object { Write-Host $_ }

if ($OutputFile) {
    $matrixJson | Set-Content -LiteralPath $OutputFile -Encoding utf8
}

$summary = @(
    '## Game test matrix',
    '',
    "Versions: $($include.Count), skipped (no loader): $($skippedVersions.Count)",
    '',
    '### Shared download cache',
    ''
) + $groupSummary + @(
    '',
    '| Minecraft | Java | Loaders |',
    '| --- | --- | --- |'
) + $summaryLines

if ($SummaryFile) {
    $summary | Set-Content -LiteralPath $SummaryFile -Encoding utf8
}
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($env:GITHUB_OUTPUT) {
    "count=$($include.Count)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "matrix<<EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    $matrixJson | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

    "cache_count=$($cacheInclude.Count)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "cache_matrix<<EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    $cacheMatrixJson | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

if ($Pretty) {
    $matrixJson
}
