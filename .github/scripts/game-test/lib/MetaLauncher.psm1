# Minimal PrismLauncher-compatible meta-launcher resolver.
#
# Reads component/version JSONs from the PrismLauncher meta-launcher repository
# (raw GitHub mirror, with meta.prismlauncher.org as fallback), resolves the
# "requires" dependency chain and merges components into a single launch profile.

# Version 1.0 keeps uninitialized-variable checks while allowing optional JSON
# properties to be read as $null.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Optional override for networks where raw.githubusercontent.com is unreliable.
# Can contain multiple semicolon separated base URLs.
$script:MetaBaseUrls = @()
if ($env:CSL_META_BASE_URL) {
    $script:MetaBaseUrls += @($env:CSL_META_BASE_URL -split ';' | Where-Object { $_ })
}
$script:MetaBaseUrls += @(
    'https://raw.githubusercontent.com/PrismLauncher/meta-launcher/refs/heads/master',
    'https://meta.prismlauncher.org/v1'
)
$script:MetaIndexCache = @{}
$script:MetaVersionCache = @{}
$script:MetaUserAgent = 'CustomSkinLoader-GameTest/1.0'

function Invoke-MetaRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$Retries = 6,
        [int]$TimeoutSec = 10
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -MaximumRedirection 5 -HttpVersion 1.1 `
                -Headers @{ 'User-Agent' = $script:MetaUserAgent }
        } catch {
            $lastError = $_
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds (3 * $attempt)
            }
        }
    }
    throw "Failed to request '$Uri' after $Retries attempts: $lastError"
}

function Get-MetaIndex {
    param([Parameter(Mandatory)][string]$Uid)

    if ($script:MetaIndexCache.ContainsKey($Uid)) {
        return $script:MetaIndexCache[$Uid]
    }

    $lastError = $null
    foreach ($baseUrl in $script:MetaBaseUrls) {
        try {
            $index = Invoke-MetaRequest -Uri "$baseUrl/$Uid/index.json"
            $script:MetaIndexCache[$Uid] = $index
            return $index
        } catch {
            $lastError = $_
        }
    }
    throw "Failed to load meta index for '$Uid': $lastError"
}

function Get-MetaVersion {
    param(
        [Parameter(Mandatory)][string]$Uid,
        [Parameter(Mandatory)][string]$Version
    )

    $key = "$Uid/$Version"
    if ($script:MetaVersionCache.ContainsKey($key)) {
        return $script:MetaVersionCache[$key]
    }

    $lastError = $null
    foreach ($baseUrl in $script:MetaBaseUrls) {
        try {
            $component = Invoke-MetaRequest -Uri "$baseUrl/$Uid/$Version.json"
            $script:MetaVersionCache[$key] = $component
            return $component
        } catch {
            $lastError = $_
        }
    }
    throw "Failed to load meta version '$key': $lastError"
}

function Get-MetaPropertyValue {
    # JSON objects can carry properties whose names collide with .NET methods
    # (for example "equals"). Always read them through PSObject.Properties.
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Select-MetaVersionForMinecraft {
    param(
        [Parameter(Mandatory)][string]$Uid,
        [Parameter(Mandatory)][string]$MinecraftVersion
    )

    $index = Get-MetaIndex -Uid $Uid
    $versions = @($index.versions)

    $matched = @($versions | Where-Object {
            $requires = @($_.requires | Where-Object { $null -ne $_ })
            $null -ne ($requires | Where-Object {
                    (Get-MetaPropertyValue -Object $_ -Name 'uid') -eq 'net.minecraft' -and
                    (Get-MetaPropertyValue -Object $_ -Name 'equals') -eq $MinecraftVersion
                })
        })

    if ($matched.Count -eq 0) {
        # Some packages encode the Minecraft version as their own version.
        $matched = @($versions | Where-Object { $_.version -eq $MinecraftVersion })
    }

    if ($matched.Count -eq 0) {
        return $null
    }

    $selected = $matched |
        Sort-Object -Property @{ Expression = { [datetime]$_.releaseTime }; Descending = $true } |
        Select-Object -First 1
    return [string]$selected.version
}

function Get-LatestMetaVersion {
    param(
        [Parameter(Mandatory)][string]$Uid,
        [switch]$AllowPreRelease
    )

    $index = Get-MetaIndex -Uid $Uid
    $versions = @($index.versions)

    if (-not $AllowPreRelease) {
        # Some packages (Quilt) mark beta releases as type=release, so also
        # filter on the version string.
        $stable = @($versions | Where-Object { $_.version -notmatch '-(beta|alpha|rc|pre)' })
        if ($stable.Count -gt 0) {
            $versions = $stable
        }
    }

    $selected = $versions |
        Sort-Object -Property @{ Expression = { [datetime]$_.releaseTime }; Descending = $true } |
        Select-Object -First 1
    return [string]$selected.version
}

function ConvertTo-MetaMap {
    param([AllowNull()][object]$InputObject)

    $map = [ordered]@{}
    if ($null -eq $InputObject) {
        return $map
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $map[[string]$key] = $InputObject[$key]
        }
    } else {
        foreach ($property in $InputObject.PSObject.Properties) {
            $map[$property.Name] = $property.Value
        }
    }
    return $map
}

function Merge-MetaComponent {
    param(
        [AllowNull()][object]$Base,
        [AllowNull()][object]$Patch
    )

    $result = ConvertTo-MetaMap $Base
    $entries = ConvertTo-MetaMap $Patch

    foreach ($name in $entries.Keys) {
        $value = $entries[$name]

        if ($name.StartsWith('+')) {
            $key = $name.Substring(1)
            $existing = @()
            if ($result.Contains($key) -and $null -ne $result[$key]) {
                $existing = @($result[$key])
            }
            $result[$key] = @($existing + @($value))
        } elseif ($name.StartsWith('-')) {
            # Removal patches are not used by the packages this harness consumes.
            continue
        } elseif ($name -in @('libraries', 'mavenFiles', 'jarMods', 'mods', 'agents')) {
            $existing = @()
            if ($result.Contains($name) -and $null -ne $result[$name]) {
                $existing = @($result[$name])
            }
            $result[$name] = @($existing + @($value))
        } elseif ($name -in @('mainClass', 'minecraftArguments', 'appletClass', 'mainJar', 'assetIndex', 'logging', 'compatibleJavaMajors', 'compatibleJavaName')) {
            if ($null -ne $value -and (($value -isnot [string]) -or $value -ne '')) {
                $result[$name] = $value
            }
        } else {
            $result[$name] = $value
        }
    }

    return $result
}

function Compare-MavenVersion {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    if ($Left -eq $Right) {
        return 0
    }

    $leftParts = @($Left -split '[.\-_+]' | Where-Object { $_ -ne '' })
    $rightParts = @($Right -split '[.\-_+]' | Where-Object { $_ -ne '' })
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)

    for ($index = 0; $index -lt $count; $index++) {
        $leftPart = if ($index -lt $leftParts.Count) { $leftParts[$index] } else { $null }
        $rightPart = if ($index -lt $rightParts.Count) { $rightParts[$index] } else { $null }

        if ($null -eq $leftPart -and $null -eq $rightPart) {
            continue
        }
        # A missing segment ranks above a qualifier (1.0 > 1.0-beta) but below
        # a numeric segment (1.0 < 1.0.1).
        if ($null -eq $leftPart) {
            if ($rightPart -match '^\d+$') { return -1 }
            return 1
        }
        if ($null -eq $rightPart) {
            if ($leftPart -match '^\d+$') { return 1 }
            return -1
        }

        $leftNumber = 0
        $rightNumber = 0
        $leftIsNumber = [int]::TryParse($leftPart, [ref]$leftNumber)
        $rightIsNumber = [int]::TryParse($rightPart, [ref]$rightNumber)

        if ($leftIsNumber -and $rightIsNumber) {
            if ($leftNumber -ne $rightNumber) {
                return $leftNumber - $rightNumber
            }
        } elseif ($leftIsNumber) {
            return 1
        } elseif ($rightIsNumber) {
            return -1
        } else {
            $comparison = [string]::Compare($leftPart, $rightPart, [System.StringComparison]::OrdinalIgnoreCase)
            if ($comparison -ne 0) {
                return $comparison
            }
        }
    }

    return 0
}

function Get-MetaLibraryPlatformKey {
    param([AllowNull()][object]$Library)

    # Platform-specific variants (for example org.lwjgl:lwjgl-glfw with
    # linux-arm64 or osx-arm64 rules) share the same maven coordinate with the
    # Windows build, so the rules must be part of the dedup key.
    $parts = @()
    foreach ($rule in @($Library.rules)) {
        if ($null -eq $rule) {
            continue
        }
        $os = $rule.os
        $osName = if ($null -ne $os) { [string]$os.name } else { '' }
        $osArch = if ($null -ne $os) { [string]$os.arch } else { '' }
        $osVersion = if ($null -ne $os) { [string]$os.version } else { '' }
        $parts += "$($rule.action)/$osName/$osArch/$osVersion"
    }
    return ($parts -join ';')
}

function Select-MinecraftLibraries {
    param([AllowNull()][object[]]$Libraries)

    # Loader components repeat some vanilla libraries with a newer version (for
    # example org.ow2.asm:asm) and both copies would end up on the classpath,
    # which makes the loader fail. Keep the highest version per maven
    # coordinate (group:artifact:classifier) and per rules variant in
    # first-seen order.
    $selected = [ordered]@{}
    $unparsed = @()

    foreach ($library in @($Libraries)) {
        if ($null -eq $library) {
            continue
        }
        if (-not $library.name) {
            $unparsed += $library
            continue
        }

        $coordinates = ([string]$library.name) -replace '@[^@]+$', ''
        $parts = @($coordinates -split ':')
        if ($parts.Count -lt 3) {
            $unparsed += $library
            continue
        }

        $group = $parts[0]
        $artifact = $parts[1]
        $version = [string]$parts[2]
        $classifier = if ($parts.Count -ge 4 -and $parts[3]) { [string]$parts[3] } else { '' }
        $platform = Get-MetaLibraryPlatformKey -Library $library
        $key = "$group`:$artifact`:$classifier`:$platform"

        if (-not $selected.Contains($key)) {
            $selected[$key] = [pscustomobject]@{ Library = $library; Version = $version }
            continue
        }

        $current = $selected[$key]
        $comparison = Compare-MavenVersion -Left $version -Right $current.Version
        if ($comparison -gt 0) {
            $selected[$key] = [pscustomobject]@{ Library = $library; Version = $version }
        } elseif ($comparison -eq 0 -and $null -eq $current.Library.natives -and $null -ne $library.natives) {
            # Same version: prefer the entry that carries the natives metadata.
            $selected[$key] = [pscustomobject]@{ Library = $library; Version = $version }
        }
    }

    return @(@($selected.Values | ForEach-Object { $_.Library }) + $unparsed)
}

function Resolve-MetaComponent {
    param(
        [Parameter(Mandatory)][string]$Uid,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [hashtable]$Cache = @{}
    )

    $key = "$Uid/$Version"
    if ($Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    $component = Get-MetaVersion -Uid $Uid -Version $Version
    $result = $null

    foreach ($requirement in @($component.requires | Where-Object { $null -ne $_ })) {
        if ($requirement.uid -eq 'net.minecraft') {
            continue
        }

        $dependencyVersion = $null
        $equals = Get-MetaPropertyValue -Object $requirement -Name 'equals'
        $suggests = Get-MetaPropertyValue -Object $requirement -Name 'suggests'
        if ($null -ne $equals) {
            $dependencyVersion = [string]$equals
        } elseif ($null -ne $suggests) {
            $dependencyVersion = [string]$suggests
        } else {
            $dependencyVersion = Select-MetaVersionForMinecraft -Uid $requirement.uid -MinecraftVersion $MinecraftVersion
        }

        if (-not $dependencyVersion) {
            Write-Warning "Cannot resolve requirement '$($requirement.uid)' for $key (Minecraft $MinecraftVersion)"
            continue
        }

        $dependency = Resolve-MetaComponent -Uid $requirement.uid -Version $dependencyVersion `
            -MinecraftVersion $MinecraftVersion -Cache $Cache
        $result = Merge-MetaComponent -Base $result -Patch $dependency
    }

    $result = Merge-MetaComponent -Base $result -Patch $component
    $Cache[$key] = $result
    return $result
}

function Get-LoaderMetaUid {
    param([Parameter(Mandatory)][string]$Loader)

    switch ($Loader.ToLowerInvariant()) {
        'vanilla' { return $null }
        'fabric' { return 'net.fabricmc.fabric-loader' }
        'quilt' { return 'org.quiltmc.quilt-loader' }
        'forge' { return 'net.minecraftforge' }
        'neoforge' { return 'net.neoforged' }
        default { throw "Unknown loader '$Loader'" }
    }
}

function Get-MergedLaunchProfile {
    param(
        [Parameter(Mandatory)][string]$McVersion,
        [string]$Loader = 'vanilla',
        [string]$LoaderVersion
    )

    # Resolve the vanilla component including its dependencies (org.lwjgl /
    # org.lwjgl3), then apply the loader component on top.
    $base = Resolve-MetaComponent -Uid 'net.minecraft' -Version $McVersion `
        -MinecraftVersion $McVersion -Cache @{}
    if (-not $base.Contains('mainClass')) {
        throw "net.minecraft/$McVersion has no mainClass"
    }

    $loaderUid = Get-LoaderMetaUid -Loader $Loader
    $profile = $base
    if ($null -ne $loaderUid) {
        if (-not $LoaderVersion) {
            throw "A loader version is required for '$Loader'"
        }
        $component = Resolve-MetaComponent -Uid $loaderUid -Version $LoaderVersion `
            -MinecraftVersion $McVersion -Cache @{}
        $profile = Merge-MetaComponent -Base $base -Patch $component
    }

    # Loader components carry their own "version"/"uid"/"name" fields. Keep the
    # Minecraft identity authoritative: launch arguments, client jar paths and
    # ForgeWrapper's file detector all depend on the actual game version.
    $profile['version'] = $McVersion
    $profile['uid'] = 'net.minecraft'

    if ($null -ne $profile['libraries'] -and @($profile['libraries']).Count -gt 0) {
        $profile['libraries'] = @(Select-MinecraftLibraries -Libraries @($profile['libraries']))
    }

    return $profile
}

function Get-MinecraftVersionManifest {
    param([string]$CacheDir)

    $manifestUrl = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
    if ($CacheDir) {
        $cacheFile = Join-Path $CacheDir 'version_manifest_v2.json'
        if (Test-Path -LiteralPath $cacheFile) {
            try {
                return Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
            } catch {
                Remove-Item -LiteralPath $cacheFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $manifest = Invoke-MetaRequest -Uri $manifestUrl
    if ($CacheDir) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $CacheDir 'version_manifest_v2.json') -Encoding utf8
    }
    return $manifest
}

function Get-MinecraftVersionManifestEntry {
    param(
        [Parameter(Mandatory)][string]$McVersion,
        [string]$CacheDir
    )

    $manifest = Get-MinecraftVersionManifest -CacheDir $CacheDir
    $entry = @($manifest.versions) | Where-Object { $_.id -eq $McVersion } | Select-Object -First 1
    if (-not $entry) {
        throw "Minecraft version '$McVersion' was not found in the Mojang version manifest"
    }
    return $entry
}

