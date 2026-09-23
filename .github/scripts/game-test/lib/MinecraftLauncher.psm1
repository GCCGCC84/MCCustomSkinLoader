# Minimal Minecraft downloader/launcher that consumes a PrismLauncher meta profile.
#
# Provides library/asset resolution, parallel downloads, natives extraction and
# launch argument construction. Only the features needed for CI game testing are
# implemented; no GUI, no authentication, no launcher profile handling.
#
# Version 1.0 keeps uninitialized-variable checks while allowing optional JSON
# properties to be read as $null.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# MetaLauncher functions are used by this module. Import it once into the global
# session if the caller has not already done so. Never re-import with -Force
# here: that would detach the caller's imported MetaLauncher commands.
if (-not (Get-Command Get-MetaVersion -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'MetaLauncher.psm1') -Scope Global
}

function Test-MetaLibraryAllowed {
    param([Parameter(Mandatory)][object]$Library)

    $rules = @($Library.rules | Where-Object { $null -ne $_ })
    if ($rules.Count -eq 0) {
        return $true
    }

    $allowed = $false
    foreach ($rule in $rules) {
        if ($null -eq $rule) {
            continue
        }

        $matches = $true
        $os = $rule.os
        if ($null -ne $os) {
            if ($null -ne $os.name -and $os.name -ne 'windows') {
                $matches = $false
            }
            if ($matches -and $null -ne $os.arch) {
                $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
                if ($arch -ne ([string]$os.arch).ToLowerInvariant()) {
                    $matches = $false
                }
            }
            if ($matches -and $null -ne $os.version) {
                $osVersion = [System.Environment]::OSVersion.Version.ToString()
                if ($osVersion -notmatch [string]$os.version) {
                    $matches = $false
                }
            }
        }

        if ($matches) {
            $allowed = ($rule.action -eq 'allow')
        }
    }
    return $allowed
}

function Get-MavenPath {
    param([Parameter(Mandatory)][string]$Name)

    $extension = 'jar'
    $coordinates = $Name
    if ($coordinates -match '@([^@]+)$') {
        $extension = $Matches[1]
        $coordinates = $coordinates -replace '@[^@]+$', ''
    }

    $parts = @($coordinates -split ':')
    if ($parts.Count -lt 3) {
        throw "Invalid maven coordinates '$Name'"
    }

    $group = $parts[0]
    $artifact = $parts[1]
    $version = $parts[2]
    $classifier = if ($parts.Count -ge 4 -and $parts[3]) { $parts[3] } else { $null }

    $fileName = if ($classifier) { "$artifact-$version-$classifier.$extension" } else { "$artifact-$version.$extension" }
    return (($group -replace '\.', '/') + "/$artifact/$version/$fileName")
}

function Get-MinecraftLibraryPlan {
    param([AllowNull()][object[]]$Libraries)

    $plannedByName = @{}
    $order = New-Object System.Collections.Generic.List[string]

    foreach ($library in @($Libraries)) {
        if ($null -eq $library -or -not $library.name) {
            continue
        }
        $name = [string]$library.name

        if (-not (Test-MetaLibraryAllowed -Library $library)) {
            continue
        }

        $items = New-Object System.Collections.Generic.List[object]
        $downloads = $library.downloads
        $artifactDownload = $null
        if ($null -ne $downloads -and $null -ne $downloads.artifact) {
            $artifactDownload = $downloads.artifact
        }

        if ($null -ne $artifactDownload) {
            $path = if ($artifactDownload.path) { [string]$artifactDownload.path } else { Get-MavenPath -Name $name }
            $items.Add([pscustomobject]@{
                    Kind = 'artifact'
                    Name = $name
                    Path = $path
                    Url  = [string]$artifactDownload.url
                    Sha1 = [string]$artifactDownload.sha1
                    Size = $artifactDownload.size
                })
        } elseif ($library.url) {
            $path = Get-MavenPath -Name $name
            $items.Add([pscustomobject]@{
                    Kind = 'artifact'
                    Name = $name
                    Path = $path
                    Url  = "$(([string]$library.url).TrimEnd('/'))/$path"
                    Sha1 = $null
                    Size = $null
                })
        } elseif ($null -eq $library.natives) {
            # Legacy entries (for example launchwrapper) sometimes only carry
            # maven coordinates. Prism falls back to Mojang's library repository.
            $path = Get-MavenPath -Name $name
            $items.Add([pscustomobject]@{
                    Kind = 'artifact'
                    Name = $name
                    Path = $path
                    Url  = "https://libraries.minecraft.net/$path"
                    Sha1 = $null
                    Size = $null
                })
        }

        if ($null -ne $library.natives -and $null -ne $downloads -and $null -ne $downloads.classifiers) {
            $classifier = $library.natives.windows
            if ($classifier) {
                $classifier = [string]$classifier
                $classifierDownload = $downloads.classifiers.$classifier
                if ($null -ne $classifierDownload) {
                    $path = if ($classifierDownload.path) { [string]$classifierDownload.path } else { Get-MavenPath -Name "$name`:$classifier" }
                    $excludes = @()
                    if ($null -ne $library.extract -and $null -ne $library.extract.exclude) {
                        $excludes = @($library.extract.exclude | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                    }
                    $items.Add([pscustomobject]@{
                            Kind     = 'natives'
                            Name     = "$name`:$classifier"
                            Path     = $path
                            Url      = [string]$classifierDownload.url
                            Sha1     = [string]$classifierDownload.sha1
                            Size     = $classifierDownload.size
                            Excludes = $excludes
                        })
                }
            }
        }

        if ($items.Count -eq 0) {
            continue
        }

        # The meta packages repeat the same maven coordinates once per platform
        # and once for the natives classifier. Prefer the entry that carries the
        # natives over an artifact-only duplicate.
        $existing = @()
        if ($plannedByName.ContainsKey($name)) {
            $existing = @($plannedByName[$name])
        }
        $existingHasNatives = @($existing | Where-Object { $_.Kind -eq 'natives' }).Count -gt 0
        if ($existingHasNatives) {
            continue
        }
        $newHasNatives = @($items | Where-Object { $_.Kind -eq 'natives' }).Count -gt 0

        if ($existing.Count -eq 0) {
            $plannedByName[$name] = $items.ToArray()
            $order.Add($name)
        } elseif ($newHasNatives) {
            $plannedByName[$name] = $items.ToArray()
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in $order) {
        foreach ($item in @($plannedByName[$name])) {
            $result.Add($item)
        }
    }
    return $result
}

function Expand-NativeArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Excludes = @()
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $skip = $false
            foreach ($exclude in $Excludes) {
                if ($entry.FullName.StartsWith($exclude, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $skip = $true
                    break
                }
            }
            if ($skip -or -not $entry.Name) {
                continue
            }

            $target = Join-Path $Destination $entry.FullName
            $targetDir = Split-Path -Parent $target
            if ($targetDir) {
                New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Invoke-McFileDownload {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [int]$ThrottleLimit = 16,
        [int]$Retries = 6
    )

    $pending = @($Items | Where-Object { $_ -and $_.Url })
    if ($pending.Count -eq 0) {
        return @()
    }

    # Split already cached files here, single threaded, so they never pay
    # runspace task overhead. The parallel workers keep their own safety check.
    $toDownload = New-Object System.Collections.Generic.List[object]
    $alreadyCached = 0
    foreach ($item in $pending) {
        $cached = $false
        try {
            if (Test-Path -LiteralPath $item.Path) {
                $existing = Get-Item -LiteralPath $item.Path
                if ($null -eq $item.Size -or $existing.Length -eq $item.Size) {
                    $cached = $true
                }
            }
        } catch {
            # Fall through to a fresh download when the existing file is unusable.
        }

        if ($cached) {
            $alreadyCached++
        } else {
            $toDownload.Add($item)
        }
    }

    Write-Host "  $alreadyCached file(s) already cached, $($toDownload.Count) to download"
    if ($toDownload.Count -eq 0) {
        return @()
    }

    $total = $toDownload.Count
    $failed = @()
    $batchSize = [Math]::Max($ThrottleLimit * 4, 32)

    for ($offset = 0; $offset -lt $total; $offset += $batchSize) {
        $last = [Math]::Min($offset + $batchSize - 1, $total - 1)
        $batch = @($toDownload[$offset..$last])

        $batchResults = @($batch | ForEach-Object -Parallel {
                $item = $_
                $ProgressPreference = 'SilentlyContinue'
                $destination = $item.Path

                try {
                    if (Test-Path -LiteralPath $destination) {
                        $existing = Get-Item -LiteralPath $destination
                        if ($null -eq $item.Size -or $existing.Length -eq $item.Size) {
                            return $null
                        }
                    }
                } catch {
                    # Fall through to a fresh download when the existing file is unusable.
                }

                $directory = Split-Path -Parent $destination
                if ($directory) {
                    New-Item -ItemType Directory -Force -Path $directory | Out-Null
                }

                # Unique temporary name so parallel workers cannot corrupt each
                # other's partial downloads when the same file is requested twice.
                $temporary = "$destination.$([guid]::NewGuid().ToString('N')).part"
                for ($attempt = 1; $attempt -le $using:Retries; $attempt++) {
                    try {
                        Invoke-WebRequest -Uri $item.Url -OutFile $temporary -TimeoutSec 10 -HttpVersion 1.1 |
                            Out-Null

                        if ($item.Sha1) {
                            $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant()
                            if ($actual -ne ([string]$item.Sha1).ToLowerInvariant()) {
                                throw "SHA1 mismatch (expected $($item.Sha1), got $actual)"
                            }
                        }

                        Move-Item -LiteralPath $temporary -Destination $destination -Force
                        return $null
                    } catch {
                        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                        if ($attempt -eq $using:Retries) {
                            return [pscustomobject]@{ Url = $item.Url; Path = $destination; Error = "$_" }
                        }
                        Start-Sleep -Seconds (2 * $attempt)
                    }
                }
                return $null
            } -ThrottleLimit $ThrottleLimit)

        $failed += @($batchResults | Where-Object { $null -ne $_ })
        $processed = [Math]::Min($offset + $batchSize, $total)
        Write-Host "  downloaded $processed/$total files ($($failed.Count) failed)"
    }

    $failed = @($failed | Where-Object { $null -ne $_ })
    if ($failed.Count -gt 0) {
        $messages = ($failed | ForEach-Object { "  $($_.Url) -> $($_.Path): $($_.Error)" }) -join [Environment]::NewLine
        throw "Failed to download $($failed.Count) of $($pending.Count) files:`n$messages"
    }

    return $failed
}

function Get-MinecraftAssetPlan {
    param(
        [Parameter(Mandatory)][string]$AssetIndexFile,
        [Parameter(Mandatory)][string]$AssetsDir,
        [switch]$SkipSoundAssets
    )

    $index = Get-Content -LiteralPath $AssetIndexFile -Raw | ConvertFrom-Json
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($property in $index.objects.PSObject.Properties) {
        $logicalPath = $property.Name
        $object = $property.Value
        if ($SkipSoundAssets) {
            if ($logicalPath.EndsWith('.ogg', [System.StringComparison]::OrdinalIgnoreCase) -or
                $logicalPath.EndsWith('.ogg.mcmeta', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }

        $hash = [string]$object.hash
        $prefix = $hash.Substring(0, 2)
        $items.Add([pscustomobject]@{
                Url  = "https://resources.download.minecraft.net/$prefix/$hash"
                Path = Join-Path $AssetsDir "objects/$prefix/$hash"
                Sha1 = $hash
                Size = $object.size
            })
    }

    return $items
}

function Resolve-MinecraftClientJar {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][string]$CacheDir
    )

    $mainJar = $Profile['mainJar']
    $url = $null
    $sha1 = $null
    $size = $null

    if ($null -ne $mainJar -and $null -ne $mainJar.downloads -and $null -ne $mainJar.downloads.artifact) {
        $url = [string]$mainJar.downloads.artifact.url
        $sha1 = [string]$mainJar.downloads.artifact.sha1
        $size = $mainJar.downloads.artifact.size
    }

    if (-not $url) {
        $entry = Get-MinecraftVersionManifestEntry -McVersion ([string]$Profile['version']) -CacheDir $CacheDir
        $versionJson = Invoke-MetaRequest -Uri $entry.url
        $url = [string]$versionJson.downloads.client.url
        $sha1 = [string]$versionJson.downloads.client.sha1
        $size = $versionJson.downloads.client.size
    }

    if (-not $url) {
        throw "Unable to resolve the client jar for Minecraft $($Profile['version'])"
    }

    # ForgeWrapper's MultiMC/Prism file detector looks for the vanilla client jar
    # at libraries/com/mojang/minecraft/<version>/minecraft-<version>-client.jar.
    $clientDir = Join-Path (Join-Path $CacheDir 'libraries') 'com/mojang/minecraft'
    return [pscustomobject]@{
        Url  = $url
        Sha1 = $sha1
        Size = $size
        Path = Join-Path (Join-Path $clientDir ([string]$Profile['version'])) "minecraft-$($Profile['version'])-client.jar"
    }
}

function Install-MinecraftRuntime {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$WorkDir,
        [switch]$SkipSoundAssets,
        [int]$ThrottleLimit = 16
    )

    $CacheDir = [System.IO.Path]::GetFullPath($CacheDir)
    $WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
    $librariesDir = Join-Path $CacheDir 'libraries'
    $assetsDir = Join-Path $CacheDir 'assets'
    $loggingDir = Join-Path $CacheDir 'logging'
    $nativesDir = Join-Path $WorkDir 'natives'

    New-Item -ItemType Directory -Force -Path $librariesDir, $assetsDir, $loggingDir, $nativesDir | Out-Null

    $libraryPlan = Get-MinecraftLibraryPlan -Libraries @($Profile['libraries'])
    $libraryArtifacts = @($libraryPlan | Where-Object { $_.Kind -eq 'artifact' })
    $libraryNatives = @($libraryPlan | Where-Object { $_.Kind -eq 'natives' })

    $mavenPlan = Get-MinecraftLibraryPlan -Libraries @($Profile['mavenFiles'])

    $downloads = @()
    foreach ($item in @($libraryArtifacts) + @($libraryNatives) + @($mavenPlan)) {
        $downloads += [pscustomobject]@{
            Url  = $item.Url
            Path = Join-Path $librariesDir $item.Path
            Sha1 = $item.Sha1
            Size = $item.Size
        }
    }

    $clientJar = Resolve-MinecraftClientJar -Profile $Profile -CacheDir $CacheDir
    $downloads += [pscustomobject]@{
        Url  = $clientJar.Url
        Path = $clientJar.Path
        Sha1 = $clientJar.Sha1
        Size = $clientJar.Size
    }

    $assetIndex = $Profile['assetIndex']
    if ($null -eq $assetIndex -or -not $assetIndex.url) {
        throw "Launch profile for Minecraft $($Profile['version']) has no asset index"
    }
    $assetIndexFile = Join-Path $assetsDir "indexes/$($assetIndex.id).json"
    $downloads += [pscustomobject]@{
        Url  = [string]$assetIndex.url
        Path = $assetIndexFile
        Sha1 = [string]$assetIndex.sha1
        Size = $assetIndex.size
    }

    $loggingFile = $null
    $logging = $Profile['logging']
    if ($null -ne $logging -and $null -ne $logging.file -and $logging.file.url) {
        $loggingFile = Join-Path $loggingDir ([string]$logging.file.id)
        $downloads += [pscustomobject]@{
            Url  = [string]$logging.file.url
            Path = $loggingFile
            Sha1 = [string]$logging.file.sha1
            Size = $logging.file.size
        }
    }

    $uniqueDownloads = @{}
    foreach ($download in $downloads) {
        if (-not $uniqueDownloads.ContainsKey($download.Path)) {
            $uniqueDownloads[$download.Path] = $download
        }
    }
    $downloads = @($uniqueDownloads.Values)

    Write-Host "Libraries and client files for Minecraft $($Profile['version']): $($downloads.Count) reference(s)"
    Invoke-McFileDownload -Items $downloads -ThrottleLimit $ThrottleLimit

    # Forge's installertools post-processors (for example DeobfRealms on
    # 1.14.3) expect the vanilla version JSON next to the client jar.
    $clientJson = [System.IO.Path]::ChangeExtension($clientJar.Path, '.json')
    if (-not (Test-Path -LiteralPath $clientJson)) {
        try {
            $entry = Get-MinecraftVersionManifestEntry -McVersion ([string]$Profile['version']) -CacheDir $CacheDir
            $versionJson = Invoke-MetaRequest -Uri $entry.url
            $versionJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $clientJson -Encoding utf8
        } catch {
            Write-Warning "Could not write the vanilla version JSON to '$clientJson': $_"
        }
    }

    $assetItems = Get-MinecraftAssetPlan -AssetIndexFile $assetIndexFile -AssetsDir $assetsDir -SkipSoundAssets:$SkipSoundAssets
    Write-Host "Asset objects for Minecraft $($Profile['version']): $($assetItems.Count) reference(s)"
    Invoke-McFileDownload -Items $assetItems -ThrottleLimit $ThrottleLimit

    if (Test-Path -LiteralPath $nativesDir) {
        Remove-Item -LiteralPath $nativesDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $nativesDir | Out-Null

    foreach ($native in $libraryNatives) {
        $archive = Join-Path $librariesDir $native.Path
        Expand-NativeArchive -Archive $archive -Destination $nativesDir -Excludes $native.Excludes
    }

    $classpath = @($libraryArtifacts | ForEach-Object { Join-Path $librariesDir $_.Path })
    $classpath += $clientJar.Path

    return [pscustomobject]@{
        Profile      = $Profile
        CacheDir     = $CacheDir
        WorkDir      = $WorkDir
        LibrariesDir = $librariesDir
        AssetsDir    = $assetsDir
        NativesDir   = $nativesDir
        ClientJar    = $clientJar.Path
        Classpath    = $classpath
        MainClass    = [string]$Profile['mainClass']
        LoggingFile  = $loggingFile
    }
}

function Expand-MinecraftArgument {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    $result = $Text
    foreach ($key in $Variables.Keys) {
        $result = $result.Replace('${' + $key + '}', [string]$Variables[$key])
    }
    return $result
}

function Get-OfflineUuid {
    param([Parameter(Mandatory)][string]$Username)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$Username"))
    } finally {
        $md5.Dispose()
    }
    $bytes[6] = (($bytes[6] -band 0x0F) -bor 0x30)
    $bytes[8] = (($bytes[8] -band 0x3F) -bor 0x80)
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Add-MinecraftArgumentIfMissing {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Values = @()
    )

    if ($Arguments -contains $Name) {
        return $Arguments
    }
    return @($Arguments + @($Name) + @($Values))
}

function New-MinecraftLaunchArguments {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Profile,
        [Parameter(Mandatory)][object]$Runtime,
        [Parameter(Mandatory)][string]$JavaExe,
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$Username,
        [string]$ServerHost = '127.0.0.1',
        [int]$ServerPort = 25565,
        [int]$Width = 854,
        [int]$Height = 480,
        [int]$MaxMemoryMb = 2048,
        [string]$UserType = 'legacy'
    )

    $variables = @{
        auth_player_name  = $Username
        version_name      = [string]$Profile['version']
        game_directory    = $GameDir
        assets_root       = [string]$Runtime.AssetsDir
        game_assets       = [string]$Runtime.AssetsDir
        assets_index_name = [string]$Profile['assetIndex'].id
        auth_uuid         = Get-OfflineUuid -Username $Username
        auth_access_token = '0'
        user_properties   = '{}'
        user_type         = $UserType
        version_type      = 'release'
        natives_directory = [string]$Runtime.NativesDir
        launcher_name     = 'csl-game-test'
        launcher_version  = '1.0'
        classpath         = ($Runtime.Classpath -join ';')
        library_directory = [string]$Runtime.LibrariesDir
    }

    $gameArguments = @()
    $rawArguments = [string]$Profile['minecraftArguments']
    if ($rawArguments) {
        $gameArguments = @($rawArguments -split '\s+' | Where-Object { $_ } | ForEach-Object {
                Expand-MinecraftArgument -Text $_ -Variables $variables
            })
    }

    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--username' -Values $Username
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--version' -Values ([string]$Profile['version'])
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--gameDir' -Values $GameDir
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--assetsDir' -Values ([string]$Runtime.AssetsDir)
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--assetIndex' -Values ([string]$Profile['assetIndex'].id)
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--uuid' -Values $variables.auth_uuid
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--accessToken' -Values '0'
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--userType' -Values $UserType
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--versionType' -Values 'release'
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--width' -Values ([string]$Width)
    $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--height' -Values ([string]$Height)

    $traits = @($Profile['traits'])
    $quickPlay = $traits -contains 'feature:is_quick_play_multiplayer'
    if ($quickPlay) {
        $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--quickPlayMultiplayer' -Values "${ServerHost}:$ServerPort"
    } else {
        $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--server' -Values $ServerHost
        $gameArguments = Add-MinecraftArgumentIfMissing -Arguments $gameArguments -Name '--port' -Values ([string]$ServerPort)
    }

    foreach ($tweaker in @($Profile['tweakers'])) {
        if ($tweaker) {
            $gameArguments += '--tweakClass'
            $gameArguments += [string]$tweaker
        }
    }

    $jvmArguments = @(
        "-Xmx${MaxMemoryMb}M",
        '-Xms512M',
        "-Djava.library.path=$($Runtime.NativesDir)",
        "-Dorg.lwjgl.librarypath=$($Runtime.NativesDir)",
        "-DlibraryDirectory=$($Runtime.LibrariesDir)",
        "-Dforgewrapper.librariesDir=$($Runtime.LibrariesDir)",
        '-Dminecraft.launcher.brand=csl-game-test',
        '-Dminecraft.launcher.version=1.0'
    )

    if ($Runtime.LoggingFile) {
        $loggingArgument = [string]$Profile['logging'].argument
        if (-not $loggingArgument) {
            $loggingArgument = '-Dlog4j.configurationFile=${path}'
        }
        $jvmArguments += Expand-MinecraftArgument -Text $loggingArgument -Variables @{ path = [string]$Runtime.LoggingFile }
    }

    foreach ($extra in @($Profile['jvmArgs'])) {
        if ($extra) {
            $jvmArguments += Expand-MinecraftArgument -Text ([string]$extra) -Variables $variables
        }
    }

    $jvmArguments += '-cp'
    $jvmArguments += ($Runtime.Classpath -join ';')
    $jvmArguments += [string]$Profile['mainClass']

    return [pscustomobject]@{
        File       = $JavaExe
        Arguments  = @($jvmArguments + $gameArguments)
        WorkingDir = $GameDir
    }
}

function ConvertTo-ProcessArgument {
    param([AllowNull()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Start-MinecraftClient {
    param(
        [Parameter(Mandatory)][string]$JavaExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StdOutFile,
        [Parameter(Mandatory)][string]$StdErrFile,
        [hashtable]$Environment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $JavaExe
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Argument $_ }) -join ' ')

    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[[string]$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StdOutFile) | Out-Null
    $stdOutWriter = [System.IO.StreamWriter]::new($StdOutFile, $false, [System.Text.UTF8Encoding]::new($false))
    $stdErrWriter = [System.IO.StreamWriter]::new($StdErrFile, $false, [System.Text.UTF8Encoding]::new($false))
    $stdOutWriter.AutoFlush = $true
    $stdErrWriter.AutoFlush = $true

    $process.Start() | Out-Null
    $stdOutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdOutWriter.BaseStream)
    $stdErrTask = $process.StandardError.BaseStream.CopyToAsync($stdErrWriter.BaseStream)

    return [pscustomobject]@{
        Process      = $process
        StdOutWriter = $stdOutWriter
        StdErrWriter = $stdErrWriter
        StdOutTask   = $stdOutTask
        StdErrTask   = $stdErrTask
        StdOutFile   = $StdOutFile
        StdErrFile   = $StdErrFile
    }
}

function Complete-MinecraftClientOutput {
    param([Parameter(Mandatory)][object]$Client)

    foreach ($task in @($Client.StdOutTask, $Client.StdErrTask)) {
        if ($null -ne $task) {
            try { $task.Wait(10000) | Out-Null } catch { }
        }
    }
    foreach ($writer in @($Client.StdOutWriter, $Client.StdErrWriter)) {
        try { $writer.Flush(); $writer.Dispose() } catch { }
    }
    $Client.StdOutTask = $null
    $Client.StdErrTask = $null
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory)][int]$Id,
        [int]$WaitSeconds = 15
    )

    try {
        taskkill.exe /PID $Id /T /F 2>&1 | Out-Null
    } catch {
        # The process may already be gone.
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
}

