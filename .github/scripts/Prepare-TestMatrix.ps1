
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ThrottleLimit = 32
$GameVersionManifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
$FabricGameVersionsUrl = "https://meta.fabricmc.net/v2/versions/game"
$QuiltGameVersionsUrl = "https://meta.quiltmc.org/v3/versions/game"
$ForgeMetadataUrl = "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
$NeoForgeMetadataUrl = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
$FabricInstallerMetadataUrl = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml"
$QuiltInstallerMetadataUrl = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml"

$ServerAddress = "127.0.0.1"
$ServerPort = 25565
$WorkingDirectory = (Get-Location).Path
$TestJarPath = Join-Path $WorkingDirectory "Test/build/libs/MCCustomSkinLoader-Test-1.0.0.jar"
$InstallerLogsDir = Join-Path $WorkingDirectory "installer-logs"

$RunDir = Join-Path $WorkingDirectory "./run"
$ClientDir = Join-Path $RunDir "client"
$ServerDir = Join-Path $RunDir "server"
$VersionsDir = Join-Path $ClientDir "versions"
$LibrariesDir = Join-Path $ClientDir "libraries"
$AssetsDir = Join-Path $ClientDir "assets"
$AssetIndexesDir = Join-Path $AssetsDir "indexes"
$AssetObjectsDir = Join-Path $AssetsDir "objects"
$LogConfigsDir = Join-Path $AssetsDir "log_configs"

$OsName = "windows"
$OsArch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
$OsVersion = [System.Environment]::OSVersion.Version
$NativeArch = if ([Environment]::Is64BitOperatingSystem) { "64" } else { "32" }
$Features = @{
    is_demo_user                 = $false
    has_custom_resolution        = $false
    has_quick_plays_support      = $false
    is_quick_play_singleplayer   = $false
    is_quick_play_multiplayer    = $true
    is_quick_play_realms         = $false
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [int]$Retries = 5
    )
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

function Invoke-Downloads {
    param([object[]]$Downloads)
    if (-not $Downloads -or $Downloads.Count -eq 0) { return }
    $Downloads | ForEach-Object -Parallel {
        $url = [string]$_.Url
        $path = [string]$_.Path
        $expectedSha1 = ""
        if ($_.Sha1) { $expectedSha1 = ([string]$_.Sha1).ToUpperInvariant() }
        $expectedSize = [long]0
        if ($_.Size) { $expectedSize = [long]$_.Size }
        if (-not $url) { return }
        $isValid = {
            param([string]$File)
            if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
            $fileSize = (Get-Item -LiteralPath $File -Force).Length
            if ($expectedSize -gt 0) {
                if ($fileSize -ne $expectedSize) { return $false }
            } elseif ($fileSize -le 0) {
                return $false
            }
            if ($expectedSha1 -and (Get-FileHash -LiteralPath $File -Algorithm SHA1).Hash -ne $expectedSha1) {
                return $false
            }
            return $true
        }
        if (& $isValid $path) { return }
        $directory = Split-Path -Parent $path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $temp = "$path.download"
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
                Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 600
                if (-not (& $isValid $temp)) { throw "SHA1/size verification failed" }
                Move-Item -LiteralPath $temp -Destination $path -Force
                return
            } catch {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
                if ($attempt -ge 5) { throw "Failed to download $url : $($_.Exception.Message)" }
                Start-Sleep -Seconds ($attempt * 2)
            }
        }
    } -ThrottleLimit $ThrottleLimit
}

function Invoke-Extractions {
    param([object[]]$Extractions)
    if (-not $Extractions -or $Extractions.Count -eq 0) { return }
    $Extractions | ForEach-Object -Parallel {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $jarPath = [string]$_.Jar
        $destination = [string]$_.Destination
        if (-not (Test-Path -LiteralPath $jarPath)) { throw "Native jar not found: $jarPath" }
        if (-not (Test-Path -LiteralPath $destination)) {
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
        }
        $archive = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith("/")) { continue }
                if ($entry.FullName.StartsWith("META-INF/")) { continue }
                $target = Join-Path $destination ($entry.FullName -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                if (Test-Path -LiteralPath $target) { continue }
                $targetDirectory = Split-Path -Parent $target
                if ($targetDirectory -and -not (Test-Path -LiteralPath $targetDirectory)) {
                    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally {
            $archive.Dispose()
        }
    } -ThrottleLimit $ThrottleLimit
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

function Test-OsRule {
    param($Os)
    if ($Os.name -and ([string]$Os.name -ne $OsName)) { return $false }
    if ($Os.arch) {
        $arch = [string]$Os.arch
        if ($arch -eq "x86" -and $OsArch -eq "x86_64") { return $false }
        if ($arch -eq "x86_64" -and $OsArch -ne "x86_64") { return $false }
        if ($arch -eq "arm64" -and $OsArch -ne "arm64") { return $false }
    }
    if ($Os.version -and ([string]$OsVersion -notmatch [string]$Os.version)) { return $false }
    if ($Os.versionRange) {
        if ($Os.versionRange.min -and $OsVersion -lt [version]([string]$Os.versionRange.min)) { return $false }
        if ($Os.versionRange.max -and $OsVersion -gt [version]([string]$Os.versionRange.max)) { return $false }
    }
    return $true
}

function Test-Rules {
    param($Rules)
    if (-not $Rules) { return $true }
    $ruleList = @($Rules)
    if ($ruleList.Count -eq 0) { return $true }
    $allowed = $false
    foreach ($rule in $ruleList) {
        $matched = $true
        if ($rule.os) { $matched = Test-OsRule $rule.os }
        if ($matched -and $rule.features) {
            foreach ($feature in $rule.features.PSObject.Properties) {
                if ($Features[$feature.Name] -ne $feature.Value) {
                    $matched = $false
                    break
                }
            }
        }
        if ($matched) { $allowed = ([string]$rule.action -eq "allow") }
    }
    return $allowed
}

function Get-LibraryBaseUrl {
    param($Library, [string[]]$Parts)
    $url = ""
    if ($Library.url) { $url = [string]$Library.url }
    if (-not $url) {
        if ($Parts[0] -eq "net.minecraftforge") { $url = "https://maven.minecraftforge.net/" }
        elseif ($Parts[0] -eq "net.neoforged") { $url = "https://maven.neoforged.net/releases/" }
        else { $url = "https://libraries.minecraft.net/" }
    }
    if (-not $url.EndsWith("/")) { $url += "/" }
    return $url
}

function Get-LibraryDerivedPath {
    param([string[]]$Parts)
    $group = $Parts[0]
    $artifactName = $Parts[1]
    $version = $Parts[2]
    $fileName = "$artifactName-$version"
    if ($Parts.Count -ge 4 -and $Parts[3]) { $fileName += "-$($Parts[3])" }
    $fileName += ".jar"
    return "$($group -replace '\.', '/')/$artifactName/$version/$fileName"
}

function Get-LibraryArtifact {
    param($Library)
    $name = [string]$Library.name
    $parts = @($name -split ":")
    if ($parts.Count -lt 3) { return $null }
    if ($parts.Count -ge 4 -and ([string]$parts[3]).StartsWith("natives-")) { return $null }
    $artifact = $Library.downloads.artifact
    if ($artifact -and $artifact.path) {
        $url = [string]$artifact.url
        if (-not $url) { $url = (Get-LibraryBaseUrl $Library $parts) + [string]$artifact.path }
        return [pscustomobject]@{
            Path = [string]$artifact.path
            Url  = $url
            Sha1 = [string]$artifact.sha1
            Size = $artifact.size
        }
    }
    if ($Library.downloads) { return $null }
    $path = Get-LibraryDerivedPath $parts
    $url = (Get-LibraryBaseUrl $Library $parts) + $path
    return [pscustomobject]@{ Path = $path; Url = $url; Sha1 = ""; Size = 0 }
}

function Get-LibraryNative {
    param($Library)
    $name = [string]$Library.name
    $parts = @($name -split ":")
    if ($parts.Count -ge 4) {
        $classifier = [string]$parts[3]
        if (-not $classifier.StartsWith("natives-windows")) { return $null }
        $artifact = $Library.downloads.artifact
        if ($artifact -and $artifact.path) {
            $url = [string]$artifact.url
            if (-not $url) { $url = (Get-LibraryBaseUrl $Library $parts) + [string]$artifact.path }
            return [pscustomobject]@{
                Path = [string]$artifact.path
                Url  = $url
                Sha1 = [string]$artifact.sha1
                Size = $artifact.size
            }
        }
        $path = Get-LibraryDerivedPath $parts
        $url = (Get-LibraryBaseUrl $Library $parts) + $path
        return [pscustomobject]@{ Path = $path; Url = $url; Sha1 = ""; Size = 0 }
    }
    if ($Library.natives -and $Library.natives.windows) {
        $classifier = ([string]$Library.natives.windows).Replace('${arch}', $NativeArch)
        $download = $Library.downloads.classifiers.$classifier
        if ($download -and $download.path) {
            $url = [string]$download.url
            if (-not $url) { $url = (Get-LibraryBaseUrl $Library $parts) + [string]$download.path }
            return [pscustomobject]@{
                Path = [string]$download.path
                Url  = $url
                Sha1 = [string]$download.sha1
                Size = $download.size
            }
        }
        $nativeParts = @($parts[0], $parts[1], $parts[2], $classifier)
        $path = Get-LibraryDerivedPath $nativeParts
        $url = (Get-LibraryBaseUrl $Library $parts) + $path
        return [pscustomobject]@{ Path = $path; Url = $url; Sha1 = ""; Size = 0 }
    }
    return $null
}

function Get-VersionClasspathPaths {
    param($VersionObject)
    $seen = @{}
    $paths = @()
    foreach ($library in @($VersionObject.libraries)) {
        if (-not (Test-Rules $library.rules)) { continue }
        $parts = @([string]$library.name -split ":")
        if ($parts.Count -lt 3) { continue }
        $key = "$($parts[0]):$($parts[1])"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $artifact = Get-LibraryArtifact $library
        if ($artifact) { $paths += $artifact.Path }
    }
    return $paths
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    if ($Value.Contains('${')) {
        $backtick = [string][char]96
        $escaped = $Value.Replace($backtick, $backtick + $backtick).Replace('"', $backtick + '"')
        return '"' + $escaped + '"'
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Expand-ArgumentList {
    param($Arguments)
    $result = @()
    foreach ($entry in @($Arguments)) {
        if ($entry -is [string]) {
            $result += $entry
            continue
        }
        if ($null -eq $entry.value) { continue }
        if (-not (Test-Rules $entry.rules)) { continue }
        if ($entry.value -is [System.Array]) {
            $result += @($entry.value)
        } else {
            $result += [string]$entry.value
        }
    }
    return $result
}

function Merge-VersionObject {
    param($Child, $Parent)
    foreach ($property in $Parent.PSObject.Properties) {
        $name = $property.Name
        $childProperty = $Child.PSObject.Properties[$name]
        if ($null -eq $childProperty) {
            $Child | Add-Member -MemberType NoteProperty -Name $name -Value $property.Value
            continue
        }
        $childValue = $childProperty.Value
        $parentValue = $property.Value
        if ($childValue -is [System.Array]) {
            $Child.$name = @($childValue) + @($parentValue)
        } elseif ($name -eq "arguments" -and $childValue -is [System.Management.Automation.PSCustomObject] -and $parentValue -is [System.Management.Automation.PSCustomObject]) {
            Merge-VersionObject -Child $childValue -Parent $parentValue
        }
    }
}

foreach ($directory in @($RunDir, $ClientDir, $ServerDir, $VersionsDir, $LibrariesDir, $AssetIndexesDir, $AssetObjectsDir, $LogConfigsDir, $InstallerLogsDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$info = Get-Content -LiteralPath "build.info.json" -Raw | ConvertFrom-Json
$loaders = @($info.loaders)
$gameVersions = @($info.game_versions)
$modVersion = [string]$info.mod_version

Write-Host "Fetching version metadata"
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

$fabricMcVersions = @($gameVersions | Where-Object { $fabricSupported.ContainsKey($_) })
$quiltMcVersions = @($gameVersions | Where-Object { $quiltSupported.ContainsKey($_) })

$forgeSelections = @()
if ($loaders -contains "forge") {
    foreach ($gameVersion in $gameVersions) {
        $prefix = "$gameVersion-"
        $matches = @($forgeVersions | Where-Object { $_.StartsWith($prefix) })
        if ($matches.Count -eq 0) {
            Write-Host "Forge: no build for $gameVersion, skipped"
            continue
        }
        $latest = @($matches | Sort-Object { Get-VersionSortKey ($_.Substring($prefix.Length)) })[-1]
        $forgeSelections += [pscustomobject]@{
            GameVersion   = $gameVersion
            Version       = $latest
            InstallerPath = Join-Path $RunDir "forge-$latest-installer.jar"
        }
    }
}

$neoForgeSelections = @()
if ($loaders -contains "neoforge") {
    foreach ($gameVersion in $gameVersions) {
        $normalized = $gameVersion -replace "^1\.", ""
        $prefix = if (($gameVersion -split "\.").Count -le 2) { "$normalized.0." } else { "$normalized." }
        $matches = @($neoForgeVersions | Where-Object { $_.StartsWith($prefix) })
        if ($matches.Count -eq 0) {
            Write-Host "NeoForge: no build for $gameVersion, skipped"
            continue
        }
        $latest = @($matches | Sort-Object { Get-VersionSortKey ($_.Substring($prefix.Length)) })[-1]
        $neoForgeSelections += [pscustomobject]@{
            GameVersion   = $gameVersion
            Version       = $latest
            InstallerPath = Join-Path $RunDir "neoforge-$latest-installer.jar"
        }
    }
}

$fabricInstallerPath = ""
if ($loaders -contains "fabric" -and $fabricMcVersions.Count -gt 0) {
    $fabricInstallerVersion = Get-MavenLatestVersion $FabricInstallerMetadataUrl
    $fabricInstallerPath = Join-Path $RunDir "fabric-installer-$fabricInstallerVersion.jar"
}
$quiltInstallerPath = ""
if ($loaders -contains "quilt" -and $quiltMcVersions.Count -gt 0) {
    $quiltInstallerVersion = Get-MavenLatestVersion $QuiltInstallerMetadataUrl
    $quiltInstallerPath = Join-Path $RunDir "quilt-installer-$quiltInstallerVersion.jar"
}

$installerDownloads = @()
if ($fabricInstallerPath) {
    $installerDownloads += [pscustomobject]@{
        Url  = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/$fabricInstallerVersion/fabric-installer-$fabricInstallerVersion.jar"
        Path = $fabricInstallerPath
    }
}
if ($quiltInstallerPath) {
    $installerDownloads += [pscustomobject]@{
        Url  = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/$quiltInstallerVersion/quilt-installer-$quiltInstallerVersion.jar"
        Path = $quiltInstallerPath
    }
}
foreach ($selection in $forgeSelections) {
    $installerDownloads += [pscustomobject]@{
        Url  = "https://maven.minecraftforge.net/net/minecraftforge/forge/$($selection.Version)/forge-$($selection.Version)-installer.jar"
        Path = $selection.InstallerPath
    }
}
foreach ($selection in $neoForgeSelections) {
    $installerDownloads += [pscustomobject]@{
        Url  = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$($selection.Version)/neoforge-$($selection.Version)-installer.jar"
        Path = $selection.InstallerPath
    }
}
Write-Host "Downloading $($installerDownloads.Count) installer(s)"
Invoke-Downloads -Downloads $installerDownloads

Write-Host "Downloading version JSONs"
$manifestEntries = @{}
foreach ($entry in $mojangManifest.versions) { $manifestEntries[[string]$entry.id] = $entry }
$versionJsonDownloads = @()
foreach ($gameVersion in $gameVersions) {
    $entry = $manifestEntries[$gameVersion]
    if (-not $entry) { throw "Version not found in Mojang manifest: $gameVersion" }
    $versionJsonDownloads += [pscustomobject]@{
        Url  = [string]$entry.url
        Path = Join-Path (Join-Path $VersionsDir $gameVersion) "$gameVersion.json"
        Sha1 = [string]$entry.sha1
        Size = $entry.size
    }
}
Invoke-Downloads -Downloads $versionJsonDownloads

$javaMajorByGameVersion = @{}
foreach ($gameVersion in $gameVersions) {
    $javaMajor = 8
    $versionJsonPath = Join-Path (Join-Path $VersionsDir $gameVersion) "$gameVersion.json"
    $versionJson = Get-Content -LiteralPath $versionJsonPath -Raw | ConvertFrom-Json
    if ($versionJson.javaVersion -and $versionJson.javaVersion.majorVersion) { $javaMajor = [int]$versionJson.javaVersion.majorVersion }
    $javaMajorByGameVersion[$gameVersion] = $javaMajor
}

$installJobs = @()
if ($fabricInstallerPath) {
    $installJobs += [pscustomobject]@{
        Loader = "fabric"
        Items  = @($fabricMcVersions | ForEach-Object { [pscustomobject]@{ GameVersion = $_; Installer = $fabricInstallerPath } })
    }
}
if ($quiltInstallerPath) {
    $installJobs += [pscustomobject]@{
        Loader = "quilt"
        Items  = @($quiltMcVersions | ForEach-Object { [pscustomobject]@{ GameVersion = $_; Installer = $quiltInstallerPath } })
    }
}
if ($forgeSelections.Count -gt 0) {
    $installJobs += [pscustomobject]@{
        Loader = "forge"
        Items  = @($forgeSelections | ForEach-Object { [pscustomobject]@{ GameVersion = $_.GameVersion; Installer = $_.InstallerPath } })
    }
}
if ($neoForgeSelections.Count -gt 0) {
    $installJobs += [pscustomobject]@{
        Loader = "neoforge"
        Items  = @($neoForgeSelections | ForEach-Object { [pscustomobject]@{ GameVersion = $_.GameVersion; Installer = $_.InstallerPath } })
    }
}

Write-Host "Installing mod loaders"
# The Forge 1.14.3 installer performs the DEOBF_REALMS post-processing step (net.minecraftforge.installertools.DeobfRealms),
# and when it downloads libraries/com/mojang/realms/1.14.17/realms-1.14.17.jar, it does not create the parent directory,
# so installing in an empty directory throws NoSuchFileException, causing "Failed to download realms jar".
# In the current matrix, only the 1.14.3 Forge installer has this processor, so the directory is created in advance here.
New-Item -ItemType Directory -Force -Path (Join-Path $LibrariesDir "com/mojang/realms/1.14.17") | Out-Null
$installJobs | ForEach-Object -Parallel {
    $clientDir = $using:ClientDir
    $testJarPath = $using:TestJarPath
    $installerLogsDir = $using:InstallerLogsDir
    $workingDirectory = $using:WorkingDirectory
    $loader = [string]$_.Loader
    foreach ($item in @($_.Items)) {
        $gameVersion = [string]$item.GameVersion
        $installer = [string]$item.Installer
        $installerLog = Join-Path $installerLogsDir "$loader-$gameVersion.log"
        "[$(Get-Date -Format s)] $loader $gameVersion" | Out-File -FilePath $installerLog -Encoding utf8
        Write-Host "[$loader] installing for $gameVersion"
        switch ($loader) {
            "fabric" { & java -jar $installer client -dir $clientDir -mcversion $gameVersion 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
            "quilt" { & java -jar $installer install client $gameVersion "--install-dir=$clientDir" 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
            "forge" { & java -cp "$installer;$testJarPath" customskinloader.test.installer.Main --installClient $clientDir 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
            "neoforge" { & java -jar $installer --installClient $clientDir 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
            default { throw "Unknown loader: $loader" }
        }
        "ExitCode: $LASTEXITCODE" | Out-File -FilePath $installerLog -Encoding utf8 -Append
        $installerSelfLog = Join-Path $workingDirectory "$(Split-Path -Leaf $installer).log"
        if (Test-Path -LiteralPath $installerSelfLog) {
            Move-Item -LiteralPath $installerSelfLog -Destination (Join-Path $installerLogsDir "$loader-$gameVersion-installer.log") -Force
        }
        if ($LASTEXITCODE -ne 0) {
            throw "[$loader] failed to install for $gameVersion (exit code $LASTEXITCODE)"
        }
    }
} -ThrottleLimit 8

Write-Host "Resolving inheritsFrom"
$versionObjects = [ordered]@{}
foreach ($directory in (Get-ChildItem -LiteralPath $VersionsDir -Directory)) {
    $jsonPath = Join-Path $directory.FullName "$($directory.Name).json"
    if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
    $versionObject = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $versionObjects[[string]$versionObject.id] = $versionObject
}

$mergedObjects = [ordered]@{}
$resolving = New-Object System.Collections.Generic.HashSet[string]
function Resolve-VersionObject {
    param([string]$Id)
    if ($mergedObjects.Contains($Id)) { return $mergedObjects[$Id] }
    if (-not $versionObjects.Contains($Id)) { throw "Missing parent version JSON: $Id" }
    if (-not $resolving.Add($Id)) { throw "Circular inheritsFrom detected at: $Id" }
    $versionObject = $versionObjects[$Id]
    if ($versionObject.PSObject.Properties["inheritsFrom"] -and $versionObject.inheritsFrom) {
        $parent = Resolve-VersionObject -Id ([string]$versionObject.inheritsFrom)
        Merge-VersionObject -Child $versionObject -Parent $parent
    }
    [void]$resolving.Remove($Id)
    $mergedObjects[$Id] = $versionObject
    return $versionObject
}
foreach ($id in @($versionObjects.Keys)) { [void](Resolve-VersionObject -Id $id) }
$allVersions = @($mergedObjects.Values)

Write-Host "Downloading client jars"
$clientDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $client = $versionObject.downloads.client
    if (-not $client -or -not $client.url) { continue }
    $destination = Join-Path (Join-Path $VersionsDir ([string]$versionObject.id)) "$($versionObject.id).jar"
    $clientDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$client.url
        Path = $destination
        Sha1 = [string]$client.sha1
        Size = $client.size
    }
}
Invoke-Downloads -Downloads @($clientDownloads.Values)

Write-Host "Downloading server jars"
$serverDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    if ($versionObject.PSObject.Properties["inheritsFrom"] -and $versionObject.inheritsFrom) { continue }
    $server = $versionObject.downloads.server
    if (-not $server -or -not $server.url) { continue }
    $destination = Join-Path $ServerDir "$($versionObject.id).jar"
    $serverDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$server.url
        Path = $destination
        Sha1 = [string]$server.sha1
        Size = $server.size
    }
}
Invoke-Downloads -Downloads @($serverDownloads.Values)

Write-Host "Downloading libraries"
$libraryDownloads = [ordered]@{}
$nativeJarsByVersion = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $versionId = [string]$versionObject.id
    $nativeJars = @{}
    foreach ($library in @($versionObject.libraries)) {
        if (-not (Test-Rules $library.rules)) { continue }
        $artifact = Get-LibraryArtifact $library
        if ($artifact) {
            $destination = Join-Path $LibrariesDir $artifact.Path
            $libraryDownloads[$destination] = [pscustomobject]@{
                Url  = $artifact.Url
                Path = $destination
                Sha1 = $artifact.Sha1
                Size = $artifact.Size
            }
        }
        $native = Get-LibraryNative $library
        if ($native) {
            $destination = Join-Path $LibrariesDir $native.Path
            $libraryDownloads[$destination] = [pscustomobject]@{
                Url  = $native.Url
                Path = $destination
                Sha1 = $native.Sha1
                Size = $native.Size
            }
            $nativeJars[$native.Path] = $true
        }
    }
    if ($nativeJars.Count -gt 0) { $nativeJarsByVersion[$versionId] = @($nativeJars.Keys) }
}
Invoke-Downloads -Downloads @($libraryDownloads.Values)

Write-Host "Extracting natives"
$extractions = New-Object System.Collections.Generic.List[object]
foreach ($versionId in $nativeJarsByVersion.Keys) {
    $destination = Join-Path (Join-Path $VersionsDir $versionId) "natives"
    foreach ($nativeJar in $nativeJarsByVersion[$versionId]) {
        $extractions.Add([pscustomobject]@{ Jar = (Join-Path $LibrariesDir $nativeJar); Destination = $destination })
    }
}
Invoke-Extractions -Extractions $extractions.ToArray()

Write-Host "Downloading logging configs"
$loggingDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $logging = $versionObject.logging
    if (-not $logging -or -not $logging.client -or -not $logging.client.file) { continue }
    $loggingFile = $logging.client.file
    if (-not $loggingFile.id -or -not $loggingFile.url) { continue }
    $destination = Join-Path $LogConfigsDir ([string]$loggingFile.id)
    if ($loggingDownloads.Contains($destination)) { continue }
    $loggingDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$loggingFile.url
        Path = $destination
        Sha1 = [string]$loggingFile.sha1
        Size = $loggingFile.size
    }
}
Invoke-Downloads -Downloads @($loggingDownloads.Values)

Write-Host "Downloading asset indexes"
$assetIndexDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $assetIndex = $versionObject.assetIndex
    if (-not $assetIndex -or -not $assetIndex.id -or -not $assetIndex.url) { continue }
    $destination = Join-Path $AssetIndexesDir "$($assetIndex.id).json"
    $assetIndexDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$assetIndex.url
        Path = $destination
        Sha1 = [string]$assetIndex.sha1
        Size = $assetIndex.size
    }
}
Invoke-Downloads -Downloads @($assetIndexDownloads.Values)

Write-Host "Downloading assets"
$assetHashes = [ordered]@{}
foreach ($indexFile in (Get-ChildItem -LiteralPath $AssetIndexesDir -Filter "*.json" -File)) {
    $assetIndex = Get-Content -LiteralPath $indexFile.FullName -Raw | ConvertFrom-Json
    if (-not $assetIndex.objects) { continue }
    foreach ($property in $assetIndex.objects.PSObject.Properties) {
        $hash = [string]$property.Value.hash
        $size = $property.Value.size
        if ($hash -and -not $assetHashes.Contains($hash)) { $assetHashes[$hash] = $size }
    }
}
$assetDownloads = New-Object System.Collections.Generic.List[object]
foreach ($hash in $assetHashes.Keys) {
    $prefix = $hash.Substring(0, 2)
    $assetDownloads.Add([pscustomobject]@{
        Url  = "https://resources.download.minecraft.net/$prefix/$hash"
        Path = Join-Path (Join-Path $AssetObjectsDir $prefix) $hash
        Sha1 = $hash
        Size = $assetHashes[$hash]
    })
}
Invoke-Downloads -Downloads $assetDownloads.ToArray()

Write-Host "Generating launch scripts"
$legacyJvmArguments = @(
    "-Dos.name=Windows 10"
    "-Dos.version=10.0"
    "-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump"
    "-Djava.library.path=`${natives_directory}"
    "-Dminecraft.launcher.brand=`${launcher_name}"
    "-Dminecraft.launcher.version=`${launcher_version}"
    "-Dminecraft.client.jar=`${primary_jar}"
    "-cp"
    '${classpath}'
)
$defaultUserJvmArguments = @(
    "-Xmx2G"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+UseG1GC"
    "-XX:G1NewSizePercent=20"
    "-XX:G1ReservePercent=20"
    "-XX:MaxGCPauseMillis=50"
    "-XX:G1HeapRegionSize=32M"
)
foreach ($versionObject in $allVersions) {
    $versionId = [string]$versionObject.id
    if ($versionObject.arguments) {
        $jvmArguments = @(Expand-ArgumentList $versionObject.arguments.jvm)
        if ($versionObject.arguments.'default-user-jvm') {
            $jvmArguments += @(Expand-ArgumentList $versionObject.arguments.'default-user-jvm')
        } else {
            $jvmArguments += $defaultUserJvmArguments
        }
        $gameArguments = @(Expand-ArgumentList $versionObject.arguments.game)
    } else {
        $jvmArguments = @($legacyJvmArguments) + $defaultUserJvmArguments
        $gameArguments = @([string]$versionObject.minecraftArguments -split "\s+" | Where-Object { $_ })
    }

    if ($gameArguments -notcontains "--quickPlayMultiplayer") {
        $gameArguments += @("--server", $ServerAddress, "--port", "$ServerPort")
    }

    $loggingConfigPath = ""
    $logging = $versionObject.logging
    if ($logging -and $logging.client -and $logging.client.file -and $logging.client.file.id -and $logging.client.argument) {
        $loggingConfigPath = "assets/log_configs/$($logging.client.file.id)"
        $jvmArguments += ([string]$logging.client.argument).Replace('${path}', '${logging_config_path}')
    }

    $classpathPaths = @(Get-VersionClasspathPaths $versionObject)
    $assetIndexId = ""
    if ($versionObject.assetIndex -and $versionObject.assetIndex.id) { $assetIndexId = [string]$versionObject.assetIndex.id }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = "Stop"')
    $lines.Add("")
    $lines.Add('$version_name = ' + (ConvertTo-PowerShellLiteral $versionId))
    $lines.Add('$game_directory = $PSScriptRoot')
    $lines.Add('$assets_root = Join-Path $PSScriptRoot "assets"')
    $lines.Add('$assets_index_name = ' + (ConvertTo-PowerShellLiteral $assetIndexId))
    $lines.Add('$quickPlayMultiplayer = ' + (ConvertTo-PowerShellLiteral ($ServerAddress + ":" + $ServerPort)))
    $lines.Add('$auth_player_name = "Player"')
    $lines.Add('$auth_uuid = "00000000-0000-0000-0000-000000000000"')
    $lines.Add('$auth_access_token = "0"')
    $lines.Add('$clientid = "0"')
    $lines.Add('$auth_xuid = "0"')
    $lines.Add('$user_properties = "{}"')
    $lines.Add('$user_type = "legacy"')
    $lines.Add('$version_type = "release"')
    $lines.Add('$launcher_name = "CustomSkinLoader"')
    $lines.Add('$launcher_version = ' + (ConvertTo-PowerShellLiteral $modVersion))
    $lines.Add('$library_directory = Join-Path $PSScriptRoot "libraries"')
    $lines.Add('$classpath_separator = [System.IO.Path]::PathSeparator')
    $lines.Add('$primary_jar = Join-Path $PSScriptRoot ' + (ConvertTo-PowerShellLiteral "versions/$versionId/$versionId.jar"))
    $lines.Add('$natives_directory = Join-Path $PSScriptRoot ' + (ConvertTo-PowerShellLiteral "versions/$versionId/natives"))
    if ($loggingConfigPath) {
        $lines.Add('$logging_config_path = Join-Path $PSScriptRoot ' + (ConvertTo-PowerShellLiteral $loggingConfigPath))
    }
    $lines.Add('$classpath = @(')
    foreach ($classpathPath in $classpathPaths) {
        $lines.Add('    (Join-Path $library_directory ' + (ConvertTo-PowerShellLiteral $classpathPath) + ')')
    }
    $lines.Add('    $primary_jar')
    $lines.Add(') -join $classpath_separator')
    $lines.Add('$java = "java"')
    $lines.Add('$mainClass = ' + (ConvertTo-PowerShellLiteral ([string]$versionObject.mainClass)))
    $lines.Add('$jvmArgs = @(')
    foreach ($jvmArgument in $jvmArguments) {
        $lines.Add('    ' + (ConvertTo-PowerShellLiteral ([string]$jvmArgument)))
    }
    $lines.Add(')')
    $lines.Add('$gameArgs = @(')
    foreach ($gameArgument in $gameArguments) {
        $lines.Add('    ' + (ConvertTo-PowerShellLiteral ([string]$gameArgument)))
    }
    $lines.Add(')')
    $lines.Add("")
    $lines.Add('& $java @jvmArgs $mainClass @gameArgs')
    $lines.Add('exit $LASTEXITCODE')
    Set-Content -LiteralPath (Join-Path $ClientDir "$versionId.ps1") -Value $lines.ToArray() -Encoding utf8
}

Write-Host "Generating test matrix"
$clientScriptNames = @(Get-ChildItem -LiteralPath $ClientDir -Filter "*.ps1" -File | Select-Object -ExpandProperty Name)
$matrixInclude = @()
foreach ($gameVersion in $gameVersions) {
    $clients = New-Object System.Collections.Generic.List[string]
    foreach ($loader in $loaders) {
        $scriptName = ""
        switch ($loader) {
            "fabric" {
                $found = @($clientScriptNames | Where-Object { $_ -like "fabric-loader-*-$gameVersion.ps1" })
                if ($found.Count -gt 0) { $scriptName = $found[0] }
            }
            "quilt" {
                $found = @($clientScriptNames | Where-Object { $_ -like "quilt-loader-*-$gameVersion.ps1" })
                if ($found.Count -gt 0) { $scriptName = $found[0] }
            }
            "forge" {
                $found = @($clientScriptNames | Where-Object { $_ -like "$gameVersion-forge*.ps1" })
                if ($found.Count -gt 0) { $scriptName = $found[0] }
            }
            "neoforge" {
                $selection = @($neoForgeSelections | Where-Object { $_.GameVersion -eq $gameVersion })
                if ($selection.Count -gt 0) {
                    $candidate = "neoforge-$($selection[0].Version).ps1"
                    if ($clientScriptNames -contains $candidate) { $scriptName = $candidate }
                }
            }
        }
        if ($scriptName) { [void]$clients.Add($scriptName) }
    }
    $matrixInclude += [pscustomobject]@{
        version = $gameVersion
        java    = $javaMajorByGameVersion[$gameVersion]
        clients = $clients.ToArray()
    }
}
$matrixJson = @{ include = $matrixInclude } | ConvertTo-Json -Compress -Depth 8
if ($env:GITHUB_OUTPUT) {
    "matrix<<EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    $matrixJson | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "EOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
Write-Host $matrixJson
Write-Host "Done. Generated $($allVersions.Count) launch script(s)"
