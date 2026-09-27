param(
    [Parameter(Mandatory = $true)][string]$MinecraftVersion,
    [Parameter(Mandatory = $true)][string]$MinecraftJsonUrl,
    [string]$MinecraftJsonSha1 = "",
    [string]$InstallersJson = $env:INSTALLERS,
    [string]$RunDir = "run"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ThrottleLimit = 32

$ServerAddress = "127.0.0.1"
$ServerPort = 25565
$WorkingDirectory = (Get-Location).Path
$TestJarPath = Join-Path $WorkingDirectory "Test/build/libs/MCCustomSkinLoader-Test-1.0.0.jar"
$InstallerLogsDir = Join-Path $WorkingDirectory "installer-logs"
$InstallerJava = Join-Path $env:JAVA_HOME_25_X64 "bin/java.exe"

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

if (-not [System.IO.Path]::IsPathRooted($RunDir)) {
    $RunDir = Join-Path $WorkingDirectory $RunDir
}
$ClientDir = Join-Path $RunDir "client"
$ServerDir = Join-Path $RunDir "server"
$VersionsDir = Join-Path $ClientDir "versions"
$LibrariesDir = Join-Path $ClientDir "libraries"
$AssetsDir = Join-Path $ClientDir "assets"
$AssetIndexesDir = Join-Path $AssetsDir "indexes"
$AssetObjectsDir = Join-Path $AssetsDir "objects"
$LogConfigsDir = Join-Path $AssetsDir "log_configs"

function Invoke-Downloads {
    param([object[]]$Downloads)
    if (-not $Downloads -or $Downloads.Count -eq 0) { return }
    $Downloads | ForEach-Object -Parallel {
        $url = [string]$_.Url
        $path = [string]$_.Path
        $expectedSha1 = ""
        if ($_.Sha1) { $expectedSha1 = ([string]$_.Sha1).ToUpperInvariant() }
        if (-not $url) { return }
        $isValid = {
            param([string]$File)
            if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
            if ((Get-Item -LiteralPath $File -Force).Length -le 0) { return $false }
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
                Invoke-WebRequest -Uri $url -OutFile $temp -TimeoutSec 10
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

function Test-Rules {
    param($Rules)
    if (-not $Rules) { return $true }
    $ruleList = @($Rules)
    if ($ruleList.Count -eq 0) { return $true }
    $allowed = $false
    foreach ($rule in $ruleList) {
        $matched = $true
        if ($rule.os) {
            if ($rule.os.name -and ([string]$rule.os.name -ne $OsName)) { $matched = $false }
            if ($matched -and $rule.os.arch) {
                $arch = [string]$rule.os.arch
                if ($arch -eq "x86" -and $OsArch -eq "x86_64") { $matched = $false }
                if ($arch -eq "x86_64" -and $OsArch -ne "x86_64") { $matched = $false }
                if ($arch -eq "arm64" -and $OsArch -ne "arm64") { $matched = $false }
            }
            if ($matched -and $rule.os.version -and ([string]$OsVersion -notmatch [string]$rule.os.version)) { $matched = $false }
            if ($matched -and $rule.os.versionRange) {
                if ($rule.os.versionRange.min -and $OsVersion -lt [version]([string]$rule.os.versionRange.min)) { $matched = $false }
                if ($rule.os.versionRange.max -and $OsVersion -gt [version]([string]$rule.os.versionRange.max)) { $matched = $false }
            }
        }
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

function Get-LibraryCoordinate {
    param([string]$Name)
    # Maven coordinates may carry an extension ("group:artifact:version@jar"). The extension is not
    # part of the version, so it has to be stripped before the coordinates are used as a path.
    $coordinates = $Name
    $extension = "jar"
    if ($coordinates -match '@([^@]+)$') {
        $extension = $Matches[1]
        $coordinates = $coordinates.Substring(0, $coordinates.Length - $Matches[1].Length - 1)
    }
    $parts = @($coordinates -split ":")
    if ($parts.Count -lt 3) { return $null }
    $classifier = ""
    if ($parts.Count -ge 4 -and $parts[3]) { $classifier = [string]$parts[3] }
    return [pscustomobject]@{
        Group      = [string]$parts[0]
        Artifact   = [string]$parts[1]
        Version    = [string]$parts[2]
        Classifier = $classifier
        Extension  = $extension
    }
}

function Get-LibraryKey {
    # Identity of an artifact slot on the classpath. Two entries that only differ in version (or in
    # the "@ext" suffix of their name) provide the same classes, so only one of them may be kept.
    param([string]$Name)
    $coordinate = Get-LibraryCoordinate $Name
    if (-not $coordinate) { return $null }
    return "$($coordinate.Group):$($coordinate.Artifact)`:$($coordinate.Classifier)"
}

function Get-LibraryDerivedPath {
    param([string]$Name)
    $coordinate = Get-LibraryCoordinate $Name
    if (-not $coordinate) { return $null }
    $fileName = "$($coordinate.Artifact)-$($coordinate.Version)"
    if ($coordinate.Classifier) { $fileName += "-$($coordinate.Classifier)" }
    $fileName += ".$($coordinate.Extension)"
    return "$($coordinate.Group -replace '\.', '/')/$($coordinate.Artifact)/$($coordinate.Version)/$fileName"
}

function Get-LibraryArtifact {
    param($Library)
    $name = [string]$Library.name
    $parts = @($name -split ":")
    if ($parts.Count -lt 3) { return $null }
    $artifact = $Library.downloads.artifact
    if ($artifact -and $artifact.path) {
        $url = [string]$artifact.url
        if (-not $url) { $url = (Get-LibraryBaseUrl $Library $parts) + [string]$artifact.path }
        return [pscustomobject]@{
            Path = [string]$artifact.path
            Url  = $url
            Sha1 = [string]$artifact.sha1
        }
    }
    if ($Library.downloads) { return $null }
    $path = Get-LibraryDerivedPath $name
    return [pscustomobject]@{ Path = $path; Url = ((Get-LibraryBaseUrl $Library $parts) + $path); Sha1 = "" }
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

foreach ($directory in @($RunDir, $ClientDir, $ServerDir, $VersionsDir, $LibrariesDir, $AssetIndexesDir, $AssetObjectsDir, $LogConfigsDir, $InstallerLogsDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$testRunDir = Join-Path $WorkingDirectory "Test/run"
if (Test-Path -LiteralPath $testRunDir) {
    Get-ChildItem -LiteralPath $testRunDir -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $RunDir -Recurse -Force
    }
}

$info = Get-Content -LiteralPath "build.info.json" -Raw | ConvertFrom-Json
$modVersion = [string]$info.mod_version

Write-Host "[$(Get-Date -Format s)] Downloading version JSON"
$versionJsonPath = Join-Path (Join-Path $VersionsDir $MinecraftVersion) "$MinecraftVersion.json"
Invoke-Downloads -Downloads @([pscustomobject]@{
    Url  = $MinecraftJsonUrl
    Path = $versionJsonPath
    Sha1 = $MinecraftJsonSha1
})
$versionJson = Get-Content -LiteralPath $versionJsonPath -Raw | ConvertFrom-Json
$javaMajor = 8
if ($versionJson.javaVersion -and $versionJson.javaVersion.majorVersion) {
    $javaMajor = [int]$versionJson.javaVersion.majorVersion
}

$installers = @($InstallersJson | ConvertFrom-Json)
$clients = New-Object System.Collections.Generic.List[string]

$installerDownloads = @()
foreach ($installer in $installers) {
    $installerDownloads += [pscustomobject]@{
        Url  = [string]$installer.url
        Path = Join-Path $RunDir "$($installer.name)-$($installer.version)-installer.jar"
    }
}
Write-Host "[$(Get-Date -Format s)] Downloading $($installerDownloads.Count) installer(s)"
Invoke-Downloads -Downloads $installerDownloads

Write-Host "[$(Get-Date -Format s)] Installing mod loaders with $InstallerJava"
# The Forge 1.14.3 installer performs the DEOBF_REALMS post-processing step (net.minecraftforge.installertools.DeobfRealms),
# and when it downloads libraries/com/mojang/realms/1.14.17/realms-1.14.17.jar, it does not create the parent directory,
# so installing in an empty directory throws NoSuchFileException, causing "Failed to download realms jar".
# In the current matrix, only the 1.14.3 Forge installer has this processor, so the directory is created in advance here.
New-Item -ItemType Directory -Force -Path (Join-Path $LibrariesDir "com/mojang/realms/1.14.17") | Out-Null
foreach ($installer in $installers) {
    $loader = [string]$installer.name
    $installerPath = Join-Path $RunDir "$loader-$($installer.version)-installer.jar"
    $installerLog = Join-Path $InstallerLogsDir "$loader-$MinecraftVersion.log"
    "[$(Get-Date -Format s)] $loader $MinecraftVersion" | Out-File -FilePath $installerLog -Encoding utf8
    Write-Host "[$(Get-Date -Format s)] [$loader] installing for $MinecraftVersion"
    $versionsBefore = @(Get-ChildItem -LiteralPath $VersionsDir -Directory | Select-Object -ExpandProperty Name)
    switch ($loader) {
        "fabric" { & $InstallerJava -jar $installerPath client -dir $ClientDir -mcversion $MinecraftVersion 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
        "quilt" { & $InstallerJava -jar $installerPath install client $MinecraftVersion "--install-dir=$ClientDir" 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
        "forge" { & $InstallerJava -cp "$installerPath;$TestJarPath" customskinloader.test.installer.Main --installClient $ClientDir 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
        "neoforge" { & $InstallerJava -jar $installerPath --installClient $ClientDir 2>&1 | Out-File -FilePath $installerLog -Encoding utf8 -Append }
        default { throw "Unknown loader: $loader" }
    }
    "ExitCode: $LASTEXITCODE" | Out-File -FilePath $installerLog -Encoding utf8 -Append
    $installerSelfLog = Join-Path $WorkingDirectory "$(Split-Path -Leaf $installerPath).log"
    if (Test-Path -LiteralPath $installerSelfLog) {
        Move-Item -LiteralPath $installerSelfLog -Destination (Join-Path $InstallerLogsDir "$loader-$MinecraftVersion-installer.log") -Force
    }
    if ($LASTEXITCODE -ne 0) {
        throw "[$loader] failed to install for $MinecraftVersion (exit code $LASTEXITCODE)"
    }
    $newVersions = @(Get-ChildItem -LiteralPath $VersionsDir -Directory | Where-Object { $versionsBefore -notcontains $_.Name })
    if ($newVersions.Count -ne 1) {
        throw "[$loader] expected one installed version for $MinecraftVersion, got $($newVersions.Count)"
    }
    [void]$clients.Add("$($newVersions[0].Name).ps1")
}

Write-Host "[$(Get-Date -Format s)] Resolving inheritsFrom"
$versionObjects = [ordered]@{}
foreach ($directory in (Get-ChildItem -LiteralPath $VersionsDir -Directory)) {
    $jsonPath = Join-Path $directory.FullName "$($directory.Name).json"
    if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
    $versionObject = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $versionObjects[[string]$versionObject.id] = $versionObject
}
$mergedObjects = [ordered]@{}
$resolving = New-Object System.Collections.Generic.HashSet[string]
foreach ($id in @($versionObjects.Keys)) { [void](Resolve-VersionObject -Id $id) }
$allVersions = @($mergedObjects.Values)

Write-Host "[$(Get-Date -Format s)] Downloading client jars"
$clientDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $client = $versionObject.downloads.client
    if (-not $client -or -not $client.url) { continue }
    $destination = Join-Path (Join-Path $VersionsDir ([string]$versionObject.id)) "$($versionObject.id).jar"
    $clientDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$client.url
        Path = $destination
        Sha1 = [string]$client.sha1
    }
}
Invoke-Downloads -Downloads @($clientDownloads.Values)

Write-Host "[$(Get-Date -Format s)] Downloading server jars"
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
    }
}
Invoke-Downloads -Downloads @($serverDownloads.Values)

Write-Host "[$(Get-Date -Format s)] Downloading libraries"
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
            }
        }
        if ($library.natives -and $library.natives.windows) {
            $parts = @([string]$library.name -split ":")
            $classifier = ([string]$library.natives.windows).Replace('${arch}', $NativeArch)
            $download = $library.downloads.classifiers.$classifier
            $native = $null
            if ($download -and $download.path) {
                $url = [string]$download.url
                if (-not $url) { $url = (Get-LibraryBaseUrl $library $parts) + [string]$download.path }
                $native = [pscustomobject]@{
                    Path = [string]$download.path
                    Url  = $url
                    Sha1 = [string]$download.sha1
                }
            } else {
                $nativeParts = @($parts[0], $parts[1], $parts[2], $classifier)
                $path = Get-LibraryDerivedPath ($nativeParts -join ":")
                $native = [pscustomobject]@{ Path = $path; Url = ((Get-LibraryBaseUrl $library $parts) + $path); Sha1 = "" }
            }
            $destination = Join-Path $LibrariesDir $native.Path
            $libraryDownloads[$destination] = [pscustomobject]@{
                Url  = $native.Url
                Path = $destination
                Sha1 = $native.Sha1
            }
            $nativeJars[$native.Path] = @($library.extract.exclude)
        }
    }
    if ($nativeJars.Count -gt 0) { $nativeJarsByVersion[$versionId] = $nativeJars }
}
Invoke-Downloads -Downloads @($libraryDownloads.Values)

Write-Host "[$(Get-Date -Format s)] Extracting natives"
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($versionId in $nativeJarsByVersion.Keys) {
    $destination = Join-Path (Join-Path $VersionsDir $versionId) "natives"
    foreach ($nativePath in $nativeJarsByVersion[$versionId].Keys) {
        $excludeList = @($nativeJarsByVersion[$versionId][$nativePath])
        $archive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $LibrariesDir $nativePath))
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith("/")) { continue }
                $excluded = $false
                foreach ($prefix in $excludeList) {
                    if ($prefix -and $entry.FullName.StartsWith([string]$prefix)) { $excluded = $true; break }
                }
                if ($excluded) { continue }
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
    }
}

Write-Host "[$(Get-Date -Format s)] Downloading logging configs"
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
    }
}
Invoke-Downloads -Downloads @($loggingDownloads.Values)

Write-Host "[$(Get-Date -Format s)] Downloading asset indexes"
$assetIndexDownloads = [ordered]@{}
foreach ($versionObject in $allVersions) {
    $assetIndex = $versionObject.assetIndex
    if (-not $assetIndex -or -not $assetIndex.id -or -not $assetIndex.url) { continue }
    $destination = Join-Path $AssetIndexesDir "$($assetIndex.id).json"
    $assetIndexDownloads[$destination] = [pscustomobject]@{
        Url  = [string]$assetIndex.url
        Path = $destination
        Sha1 = [string]$assetIndex.sha1
    }
}
Invoke-Downloads -Downloads @($assetIndexDownloads.Values)

Write-Host "[$(Get-Date -Format s)] Downloading assets"
$assetHashes = [ordered]@{}
foreach ($indexFile in (Get-ChildItem -LiteralPath $AssetIndexesDir -Filter "*.json" -File)) {
    $assetIndex = Get-Content -LiteralPath $indexFile.FullName -Raw | ConvertFrom-Json
    if (-not $assetIndex.objects) { continue }
    foreach ($property in $assetIndex.objects.PSObject.Properties) {
        $hash = [string]$property.Value.hash
        if ($hash -and -not $assetHashes.Contains($hash)) { $assetHashes[$hash] = $true }
    }
}
$assetDownloads = New-Object System.Collections.Generic.List[object]
foreach ($hash in $assetHashes.Keys) {
    $prefix = $hash.Substring(0, 2)
    $assetDownloads.Add([pscustomobject]@{
        Url  = "https://resources.download.minecraft.net/$prefix/$hash"
        Path = Join-Path (Join-Path $AssetObjectsDir $prefix) $hash
        Sha1 = $hash
    })
}
Invoke-Downloads -Downloads $assetDownloads.ToArray()

Write-Host "[$(Get-Date -Format s)] Generating launch scripts"
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
    # Work around the 1.16.4/1.16.5 authlib returning invalid data and disabling multiplayer by setting an invalid proxy address and port.
    # Only those two versions need it: the client turns these arguments into a SOCKS proxy for its
    # authlib HTTP calls, and pointing that proxy at the game port makes every Minecraft Services
    # request hang until it times out. Minecraft 26.3 needs those services to finish logging in, so
    # the client never joins the server and the skin never loads.
    if ($MinecraftVersion -in @("1.16.4", "1.16.5")) {
        $gameArguments += @("--proxyHost", $ServerAddress, "--proxyPort", "$ServerPort")
    }

    $loggingConfigPath = ""
    $logging = $versionObject.logging
    if ($logging -and $logging.client -and $logging.client.file -and $logging.client.file.id -and $logging.client.argument) {
        $loggingConfigPath = "assets/log_configs/$($logging.client.file.id)"
        $jvmArguments += ([string]$logging.client.argument).Replace('${path}', '${logging_config_path}')
    }

    $classpathPaths = @()
    $seenLibraries = @{}
    foreach ($library in @($versionObject.libraries)) {
        if (-not (Test-Rules $library.rules)) { continue }
        # A loader profile may repeat an artifact that the game already provides, either with a
        # different version (Fabric ships its own ASM, Forge its own Guava) or with an "@ext"
        # suffix in the maven coordinates. Both copies would end up on the classpath and the
        # loader then aborts: Fabric reports "duplicate ASM classes found on classpath", Forge
        # and NeoForge fail module resolution. The loader profile is merged before the game, so
        # keeping the first occurrence keeps the loader's version.
        $libraryKey = Get-LibraryKey ([string]$library.name)
        if (-not $libraryKey) { continue }
        if ($seenLibraries.ContainsKey($libraryKey)) { continue }
        $seenLibraries[$libraryKey] = $true
        $classpathArtifact = Get-LibraryArtifact $library
        if ($classpathArtifact) { $classpathPaths += $classpathArtifact.Path }
    }

    $assetIndexId = ""
    if ($versionObject.assetIndex -and $versionObject.assetIndex.id) { $assetIndexId = [string]$versionObject.assetIndex.id }

    # Quilt classifies com.mojang:patchy as a log4j plugin jar (it carries com/mojang/patchy/LegacyXMLLayout)
    # and loads it outside the game classloader, so Minecraft's block list lookup fails on the connect thread
    # with "com.mojang.blocklist.BlockListSupplier: com.mojang.patchy.MojangBlockListSupplier not a subtype"
    # and the client never joins the server. Quilt's loader.systemLibraries property puts those two jars back
    # into a single classloader, which is what a plain launcher classpath gives by construction.
    if ($versionId -like 'quilt-loader-*' -and $MinecraftVersion -in @('1.17', '1.17.1', '1.18', '1.18.1')) {
        $systemLibraries = @($classpathPaths | Where-Object { $_ -match '[\\/]blocklist[\\/]' -or $_ -match '[\\/]patchy[\\/]' })
        if ($systemLibraries.Count -eq 2) {
            $jvmArguments += '-Dloader.systemLibraries=' + ($systemLibraries -join [IO.Path]::PathSeparator)
        } else {
            Write-Warning "Quilt system libraries for $versionId: expected blocklist and patchy, found $($systemLibraries.Count)"
        }
    }

    # Arguments are emitted as PowerShell double-quoted strings so that ${...} is resolved when the
    # generated script runs. Anything the launcher does not define would silently reach the JVM as a
    # literal, so refuse to generate a script with unresolved placeholders.
    $definedPlaceholders = @(
        'version_name', 'game_directory', 'assets_root', 'assets_index_name', 'quickPlayMultiplayer',
        'auth_player_name', 'auth_uuid', 'auth_access_token', 'clientid', 'auth_xuid', 'user_properties',
        'user_type', 'version_type', 'launcher_name', 'launcher_version', 'library_directory',
        'classpath_separator', 'primary_jar', 'natives_directory', 'logging_config_path', 'classpath'
    )
    $usedPlaceholders = New-Object System.Collections.Generic.List[string]
    foreach ($argument in (@($jvmArguments) + @($gameArguments))) {
        foreach ($match in [regex]::Matches([string]$argument, '\$\{([A-Za-z0-9_]+)\}')) {
            $usedPlaceholders.Add($match.Groups[1].Value)
        }
    }
    $unknownPlaceholders = @($usedPlaceholders | Sort-Object -Unique | Where-Object { $definedPlaceholders -notcontains $_ })
    if ($unknownPlaceholders.Count -gt 0) {
        throw "[$versionId] launch arguments reference placeholders the launcher script does not define: $($unknownPlaceholders -join ', ')"
    }

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

if ($env:GITHUB_OUTPUT) {
    # 1.16.3/1.16.4 Forge relies on Java internal APIs and is incompatible with Java 8u321+.
    "java=$("$javaMajor" -eq "8" ? '8.0.312' : "$javaMajor")" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "clients=$($clients -join ',')" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
Write-Host "[$(Get-Date -Format s)] Done. Java $javaMajor, clients: $($clients -join ', ')"
