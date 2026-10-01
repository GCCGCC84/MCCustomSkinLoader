param(
    # Optional comma-separated subset of the versions in build.info.json, for quick iteration on a
    # problematic version instead of the whole matrix. The name must not collide with $gameVersions
    # below: PowerShell variable names are case insensitive, and a [string] parameter would coerce the
    # array of versions into one space separated string.
    [string]$VersionFilter = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$GameVersionManifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
$FabricGameVersionsUrl = "https://meta.fabricmc.net/v2/versions/game"
$QuiltGameVersionsUrl = "https://meta.quiltmc.org/v3/versions/game"
$ForgeMetadataUrl = "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
$NeoForgeMetadataUrl = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
$FabricInstallerMetadataUrl = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml"
$QuiltInstallerMetadataUrl = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml"

function Invoke-WithRetry {
    param([scriptblock]$Script, [int]$Retries = 5)
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return & $Script
        } catch {
            if ($attempt -ge $Retries) { throw }
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Get-RemoteString {
    param([string]$Url)
    return Invoke-WithRetry { (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120).Content }
}

function Get-RemoteJson {
    param([string]$Url)
    return Invoke-WithRetry { Invoke-RestMethod -Uri $Url -TimeoutSec 120 }
}

function Get-VersionSortKey {
    param([string]$Value)
    $core = ($Value -split "-")[0]
    $key = ""
    foreach ($part in @($core -split "\.")) {
        $number = 0
        if ($part -match "^\d+$") { $number = [int]$part }
        $key += $number.ToString("D10")
    }
    return $key.PadRight(80, "0")
}

function Get-MavenLatestVersion {
    param([string]$MetadataUrl)
    $metadata = [xml](Get-RemoteString $MetadataUrl)
    $version = [string]$metadata.metadata.versioning.release
    if (-not $version) { $version = [string]$metadata.metadata.versioning.latest }
    if (-not $version) { $version = [string]@($metadata.metadata.versioning.versions.version)[-1] }
    return $version
}

$info = Get-Content -LiteralPath "build.info.json" -Raw | ConvertFrom-Json
$loaders = @($info.loaders)
$gameVersions = @($info.game_versions)
if ($VersionFilter) {
    $requested = @($VersionFilter -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($requested | Where-Object { $gameVersions -notcontains $_ })
    if ($unknown) { throw "Unknown Minecraft version(s) in -VersionFilter: $($unknown -join ', ')" }
    $gameVersions = $requested
}

Write-Host "[$(Get-Date -Format s)] Fetching version metadata"
$mojangManifest = Get-RemoteJson $GameVersionManifestUrl
$fabricGame = Get-RemoteJson $FabricGameVersionsUrl
$quiltGame = Get-RemoteJson $QuiltGameVersionsUrl
$forgeMetadata = [xml](Get-RemoteString $ForgeMetadataUrl)
$neoForgeMetadata = [xml](Get-RemoteString $NeoForgeMetadataUrl)
$forgeVersions = @($forgeMetadata.metadata.versioning.versions.version)
$neoForgeVersions = @($neoForgeMetadata.metadata.versioning.versions.version)

$fabricSupported = @{}
foreach ($entry in $fabricGame) { $fabricSupported[[string]$entry.version] = $true }
$quiltSupported = @{}
foreach ($entry in $quiltGame) { $quiltSupported[[string]$entry.version] = $true }

$fabricInstallerVersion = ""
if ($loaders -contains "fabric") {
    $fabricInstallerVersion = Get-MavenLatestVersion $FabricInstallerMetadataUrl
}
$quiltInstallerVersion = ""
if ($loaders -contains "quilt") {
    $quiltInstallerVersion = Get-MavenLatestVersion $QuiltInstallerMetadataUrl
}

$forgeByGameVersion = @{}
if ($loaders -contains "forge") {
    foreach ($gameVersion in $gameVersions) {
        $prefix = "$gameVersion-"
        $matches = @($forgeVersions | Where-Object { $_.StartsWith($prefix) })
        if ($matches.Count -eq 0) {
            Write-Host "[$(Get-Date -Format s)] Forge: no build for $gameVersion, skipped"
            continue
        }
        $forgeByGameVersion[$gameVersion] = [string]@($matches | Sort-Object { Get-VersionSortKey ($_.Substring($prefix.Length)) })[-1]
    }
}

$neoForgeByGameVersion = @{}
if ($loaders -contains "neoforge") {
    foreach ($gameVersion in $gameVersions) {
        $normalized = $gameVersion -replace "^1\.", ""
        $prefix = if (($gameVersion -split "\.").Count -le 2) { "$normalized.0." } else { "$normalized." }
        $matches = @($neoForgeVersions | Where-Object { $_.StartsWith($prefix) })
        if ($matches.Count -eq 0) {
            Write-Host "[$(Get-Date -Format s)] NeoForge: no build for $gameVersion, skipped"
            continue
        }
        $neoForgeByGameVersion[$gameVersion] = [string]@($matches | Sort-Object { Get-VersionSortKey ($_.Substring($prefix.Length)) })[-1]
    }
}

Write-Host "[$(Get-Date -Format s)] Generating test matrix"
$manifestEntries = @{}
foreach ($entry in $mojangManifest.versions) { $manifestEntries[[string]$entry.id] = $entry }

$matrixInclude = @()
foreach ($gameVersion in $gameVersions) {
    $entry = $manifestEntries[$gameVersion]
    if (-not $entry) { throw "Version not found in Mojang manifest: $gameVersion" }
    $entryLoaders = New-Object System.Collections.Generic.List[object]
    if (($loaders -contains "fabric") -and $fabricSupported.ContainsKey($gameVersion)) {
        $entryLoaders.Add([pscustomobject]@{
            name    = "fabric"
            version = $fabricInstallerVersion
            url     = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/$fabricInstallerVersion/fabric-installer-$fabricInstallerVersion.jar"
        })
    }
    if ($loaders -contains "forge" -and $forgeByGameVersion.ContainsKey($gameVersion)) {
        $forgeVersion = $forgeByGameVersion[$gameVersion]
        $entryLoaders.Add([pscustomobject]@{
            name    = "forge"
            version = $forgeVersion
            url     = "https://maven.minecraftforge.net/net/minecraftforge/forge/$forgeVersion/forge-$forgeVersion-installer.jar"
        })
    }
    if ($loaders -contains "neoforge" -and $neoForgeByGameVersion.ContainsKey($gameVersion)) {
        $neoForgeVersion = $neoForgeByGameVersion[$gameVersion]
        $entryLoaders.Add([pscustomobject]@{
            name    = "neoforge"
            version = $neoForgeVersion
            url     = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$neoForgeVersion/neoforge-$neoForgeVersion-installer.jar"
        })
    }
    if ($loaders -contains "quilt" -and $quiltSupported.ContainsKey($gameVersion)) {
        $entryLoaders.Add([pscustomobject]@{
            name    = "quilt"
            version = $quiltInstallerVersion
            url     = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/$quiltInstallerVersion/quilt-installer-$quiltInstallerVersion.jar"
        })
    }
    if ($entryLoaders.Count -eq 0) {
        Write-Host "[$(Get-Date -Format s)] No loader available for $gameVersion, skipped"
        continue
    }
    $matrixInclude += [pscustomobject]@{
        version   = $gameVersion
        json_url  = [string]$entry.url
        json_sha1 = [string]$entry.sha1
        loaders   = $entryLoaders.ToArray()
    }
}

$matrixJson = @{ include = $matrixInclude } | ConvertTo-Json -Compress -Depth 10
if ($env:GITHUB_OUTPUT) {
    "matrix<<EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    $matrixJson | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
Write-Host "[$(Get-Date -Format s)] $matrixJson"
Write-Host "[$(Get-Date -Format s)] Done. Generated $($matrixInclude.Count) matrix entry(ies)"
