# Runs a single Minecraft version + mod loader combination end to end:
# downloads the client, starts a vanilla server, launches the client with Mesa3D
# software rendering, connects to the server, takes a screenshot and asserts that
# CustomSkinLoader applied the local test skin.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$McVersion,
    [string]$Loader = 'vanilla',
    [string]$LoaderVersion,
    [Parameter(Mandatory)][string]$ModJar,
    [string]$SkinPng,
    [string]$CapePng,
    [Parameter(Mandatory)][string]$JavaHome,
    [string]$JavaMajor,
    [string]$WorkDir,
    [string]$CacheDir,
    [string]$MesaCacheDir,
    [string]$ResultDir,
    [string]$ServerHost = '127.0.0.1',
    [int]$ServerPort = 25565,
    [string]$Username = 'CslTest',
    [switch]$SkipSoundAssets,
    [switch]$SkipMesa,
    [int]$JoinTimeoutSeconds = 300,
    [int]$ServerTimeoutSeconds = 300,
    [int]$WindowTimeoutSeconds = 120,
    [int]$ScreenshotTimeoutSeconds = 30,
    [int]$MaxMemoryMb = 2048
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/MetaLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MinecraftLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Mesa3D.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/GameWindow.psm1') -Force

$requiredCommands = @('Get-MergedLaunchProfile', 'Install-MinecraftRuntime', 'Install-Mesa3D', 'Get-ProcessTreeId')
$missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingCommands.Count -gt 0) {
    Get-Module | ForEach-Object { Write-Warning "loaded module: $($_.Name) ($($_.Path))" }
    throw "Test harness commands are missing after module import: $($missingCommands -join ', ')"
}

function Write-CustomSkinLoaderConfig {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$SkinPng,
        [Parameter(Mandatory)][string]$CapePng
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $config = [ordered]@{
        version                 = '15.1'
        buildNumber             = 0
        loadlist                = @(
            [ordered]@{
                name     = 'LocalSkin'
                type     = 'Legacy'
                skin     = 'LocalSkin/skins/{USERNAME}.png'
                cape     = 'LocalSkin/capes/{USERNAME}.png'
                elytra   = 'LocalSkin/elytras/{USERNAME}.png'
                model    = 'auto'
                checkPNG = $false
            }
        )
        enableTransparentSkin   = $true
        forceLoadAllTextures    = $true
        enableCape              = $true
        threadPoolSize          = 4
        enableLogStdOut         = $true
        cacheExpiry             = 30
        forceUpdateSkull        = $false
        enableLocalProfileCache = $false
        enableCacheAutoClean    = $false
        forceDisableCache       = $false
    }

    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Directory 'CustomSkinLoader.json') -Encoding utf8

    $skinPath = Join-Path $Directory "LocalSkin/skins/$Username.png"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skinPath) | Out-Null
    Copy-Item -LiteralPath $SkinPng -Destination $skinPath -Force

    $capePath = Join-Path $Directory "LocalSkin/capes/$Username.png"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $capePath) | Out-Null
    Copy-Item -LiteralPath $CapePng -Destination $capePath -Force
}

function Wait-ServerJoin {
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Client,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Client.Process.HasExited) {
            throw "Minecraft client exited with code $($Client.Process.ExitCode) before joining the server"
        }
        if ($Server.Process.HasExited) {
            throw "Minecraft server exited with code $($Server.Process.ExitCode) while waiting for the client to join"
        }
        if (Test-Path -LiteralPath $Server.LogFile) {
            $content = Get-Content -LiteralPath $Server.LogFile -Raw -ErrorAction SilentlyContinue
            if ($content -match 'joined the game') {
                return $true
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-SkinProfileLoaded {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $LogPath) {
            $content = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
            if ($content -match "'s profile loaded\.") {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-MinecraftScreenshot {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][string]$Directory,
        [string]$ViewKey,
        [int]$TimeoutSeconds = 30
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Set-GameWindowForeground -Handle $Handle
        if ($ViewKey) {
            Send-GameKey -Handle $Handle -Key $ViewKey
            Start-Sleep -Seconds 4
        }
        $since = Get-Date
        Send-GameKey -Handle $Handle -Key 'F2'
        $attemptTimeout = [Math]::Max(8, [int][Math]::Ceiling($TimeoutSeconds / 3.0))
        $screenshot = Wait-MinecraftScreenshot -Directory $Directory -Since $since -TimeoutSeconds $attemptTimeout
        if ($screenshot) {
            return $screenshot
        }
        Write-Warning "Screenshot attempt $attempt did not produce a file"
    }
    return $null
}

function Get-FileTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Lines = 40
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    return @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue)
}

function Copy-ResultArtifacts {
    param(
        [Parameter(Mandatory)][string]$ResultDirectory,
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowNull()][object]$Server,
        [Parameter(Mandatory)][AllowNull()][object]$Client,
        [AllowNull()][string[]]$Screenshots = @()
    )

    $logDir = Join-Path $ResultDirectory 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    $files = @(
        @{ Source = (Join-Path $GameDir 'logs/latest.log'); Name = 'latest.log' },
        @{ Source = (Join-Path $GameDir 'CustomSkinLoader/CustomSkinLoader.log'); Name = 'CustomSkinLoader.log' },
        @{ Source = (Join-Path $Root 'client-stdout.log'); Name = 'client-stdout.log' },
        @{ Source = (Join-Path $Root 'client-stderr.log'); Name = 'client-stderr.log' }
    )
    if ($null -ne $Server) {
        $files += @{ Source = $Server.LogFile; Name = 'server-stdout.log' }
        $files += @{ Source = $Server.ErrorFile; Name = 'server-stderr.log' }
    }
    if ($null -ne $Client) {
        $files += @{ Source = $Client.StdOutFile; Name = 'client-wrapper-stdout.log' }
        $files += @{ Source = $Client.StdErrFile; Name = 'client-wrapper-stderr.log' }
    }

    foreach ($file in $files) {
        if ($file.Source -and (Test-Path -LiteralPath $file.Source)) {
            Copy-Item -LiteralPath $file.Source -Destination (Join-Path $logDir $file.Name) -Force
        }
    }

    foreach ($screenshotPath in @($Screenshots)) {
        if ($screenshotPath -and (Test-Path -LiteralPath $screenshotPath)) {
            $screenshotDir = Join-Path $ResultDirectory 'screenshots'
            New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null
            Copy-Item -LiteralPath $screenshotPath -Destination (Join-Path $screenshotDir (Split-Path -Leaf $screenshotPath)) -Force
        }
    }
}

$startTime = Get-Date
if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "csl-game-test/$McVersion/$Loader"
}
if (-not $CacheDir) {
    $CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'csl-game-test-cache'
}
if (-not $MesaCacheDir) {
    $MesaCacheDir = Join-Path $CacheDir 'mesa'
}
if (-not $ResultDir) {
    $ResultDir = $WorkDir
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
$CacheDir = [System.IO.Path]::GetFullPath($CacheDir)
$ResultDir = [System.IO.Path]::GetFullPath($ResultDir)
$gameDir = Join-Path $WorkDir 'game'
$serverDir = Join-Path $WorkDir 'server'

if (-not $SkinPng) {
    $SkinPng = Join-Path $PSScriptRoot 'assets/skin.png'
}
if (-not $CapePng) {
    $CapePng = Join-Path $PSScriptRoot 'assets/cape.png'
}
if (-not (Test-Path -LiteralPath $SkinPng)) {
    throw "Test skin was not found at '$SkinPng'"
}
if (-not (Test-Path -LiteralPath $CapePng)) {
    throw "Test cape was not found at '$CapePng'"
}

$javaExe = Join-Path $JavaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaExe)) {
    throw "java.exe was not found under '$JavaHome'"
}
if (-not $JavaMajor) {
    $JavaMajor = Split-Path -Leaf $JavaHome
}

New-Item -ItemType Directory -Force -Path $WorkDir, $ResultDir | Out-Null

$result = [ordered]@{
    mc               = $McVersion
    loader           = $Loader
    loaderVersion    = $LoaderVersion
    java             = $JavaMajor
    javaHome         = $JavaHome
    status           = 'failed'
    joined           = $false
    skinLogLoaded    = $false
    capeLogLoaded    = $false
    skinPixelsPassed = $false
    screenshot       = $null
    capeScreenshot   = $null
    durationSeconds  = 0
    error            = $null
}

$server = $null
$client = $null
$windowHandle = [IntPtr]::Zero
$screenshot = $null
$capeScreenshot = $null

try {
    Write-Output "=== CustomSkinLoader game test: Minecraft $McVersion / $Loader $(if ($LoaderVersion) { $LoaderVersion }) ==="

    $profile = Get-MergedLaunchProfile -McVersion $McVersion -Loader $Loader -LoaderVersion $LoaderVersion
    Write-Output "Resolved launch profile (mainClass=$($profile['mainClass']))"

    $runtime = Install-MinecraftRuntime -Profile $profile -CacheDir $CacheDir -WorkDir $WorkDir -SkipSoundAssets:$SkipSoundAssets

    $mesaEnvironment = @{}
    if (-not $SkipMesa) {
        $mesa = Install-Mesa3D -CacheDir $MesaCacheDir -Destination $runtime.NativesDir
        Write-Output "Mesa3D $($mesa.Version) deployed to $($runtime.NativesDir)"
        $mesaEnvironment = Get-MesaEnvironment -MesaRoot $mesa.Root
    }

    if (Test-Path -LiteralPath $gameDir) {
        Remove-Item -LiteralPath $gameDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $gameDir 'mods') | Out-Null
    Copy-Item -LiteralPath $ModJar -Destination (Join-Path $gameDir "mods/$(Split-Path -Leaf $ModJar)") -Force
    Write-CustomSkinLoaderConfig -Directory (Join-Path $gameDir 'CustomSkinLoader') -Username $Username `
        -SkinPng $SkinPng -CapePng $CapePng

    $server = & (Join-Path $PSScriptRoot 'Start-VanillaServer.ps1') -McVersion $McVersion -JavaExe $javaExe `
        -ServerDir $serverDir -CacheDir $CacheDir -Port $ServerPort -TimeoutSeconds $ServerTimeoutSeconds

    $launch = New-MinecraftLaunchArguments -Profile $profile -Runtime $runtime -JavaExe $javaExe `
        -GameDir $gameDir -Username $Username -ServerHost $ServerHost -ServerPort $ServerPort `
        -MaxMemoryMb $MaxMemoryMb

    Write-Output "Launching Minecraft client ..."
    $client = Start-MinecraftClient -JavaExe $launch.File -Arguments $launch.Arguments `
        -WorkingDirectory $launch.WorkingDir -StdOutFile (Join-Path $WorkDir 'client-stdout.log') `
        -StdErrFile (Join-Path $WorkDir 'client-stderr.log') -Environment $mesaEnvironment

    Write-Output "Waiting for the client to join the server ..."
    if (-not (Wait-ServerJoin -Server $server -Client $client -TimeoutSeconds $JoinTimeoutSeconds)) {
        throw "Client did not join the server within $JoinTimeoutSeconds seconds"
    }
    $result.joined = $true
    Write-Output "Client joined the server."

    # Wait until CustomSkinLoader has applied a profile (and give the world a
    # moment to render) before taking the screenshots.
    $cslLog = Join-Path $gameDir 'CustomSkinLoader/CustomSkinLoader.log'
    [void](Wait-SkinProfileLoaded -LogPath $cslLog -TimeoutSeconds 60)
    Start-Sleep -Seconds 3

    $processIds = Get-ProcessTreeId -RootId $client.Process.Id
    $windowHandle = Get-GameWindow -ProcessIds $processIds -TitleLike 'Minecraft' -TimeoutSeconds $WindowTimeoutSeconds
    $screenshotsDir = Join-Path $gameDir 'screenshots'

    if ($windowHandle -ne [IntPtr]::Zero) {
        # First F5 press: third person, camera behind the player (cape visible).
        $capeScreenshot = Get-MinecraftScreenshot -Handle $windowHandle -Directory $screenshotsDir `
            -ViewKey 'F5' -TimeoutSeconds $ScreenshotTimeoutSeconds

        # Second F5 press: third person, camera in front of the player (skin visible).
        $screenshot = Get-MinecraftScreenshot -Handle $windowHandle -Directory $screenshotsDir `
            -ViewKey 'F5' -TimeoutSeconds $ScreenshotTimeoutSeconds
    } else {
        Write-Warning 'Minecraft window was not found; skipping key injection'
    }

    if (-not $screenshot -and $windowHandle -ne [IntPtr]::Zero) {
        Write-Warning 'F2 screenshot was not produced; falling back to a window capture'
        try {
            $screenshot = Save-WindowScreenshot -Handle $windowHandle -Path (Join-Path $WorkDir 'screenshots/window-capture.png')
        } catch {
            Write-Warning "Window capture failed: $_"
        }
    }

    if ($screenshot) {
        $result.screenshot = $screenshot
        try {
            $pixelResult = Test-SkinScreenshot -Path $screenshot
            $result.skinPixelsPassed = [bool]$pixelResult.Pass
            Write-Output "Skin pixel check: $($pixelResult.MatchedPixels) matching pixels (pass=$($pixelResult.Pass))"
        } catch {
            Write-Warning "Skin pixel check failed: $_"
            if (-not $result.error) {
                $result.error = "Skin pixel check failed: $_"
            }
        }
    } else {
        Write-Warning 'No screenshot could be captured'
    }
    if ($capeScreenshot) {
        $result.capeScreenshot = $capeScreenshot
    }

    if (Test-Path -LiteralPath $cslLog) {
        $cslContent = Get-Content -LiteralPath $cslLog -Raw
        $result.skinLogLoaded = ($cslContent -match "Try to load profile from 'LocalSkin'\.") -and
            ($cslContent -match "'s profile loaded\.")
        $result.capeLogLoaded = $cslContent -match 'CapeUrl:\s*\(LOCAL_LEGACY\)'
        if (-not $result.skinLogLoaded) {
            $result.error = 'CustomSkinLoader.log does not report a loaded LocalSkin profile'
        } elseif (-not $result.capeLogLoaded) {
            $result.error = 'CustomSkinLoader.log does not report a loaded local cape'
        }
    } else {
        $result.error = "CustomSkinLoader.log was not created at '$cslLog'"
    }

    if ($result.joined -and $result.skinLogLoaded -and $result.capeLogLoaded -and $result.skinPixelsPassed) {
        $result.status = 'passed'
    } elseif ($result.joined -and -not $result.skinPixelsPassed -and -not $result.error) {
        $result.error = 'Skin pixels were not detected in the screenshot'
    }
} catch {
    $result.error = "$_"
    Write-Warning "Game test failed: $_"
    if ($client) {
        Write-Warning "--- client stdout (tail) ---"
        Get-FileTail -Path $client.StdOutFile | ForEach-Object { Write-Warning $_ }
    }
    if ($server) {
        Write-Warning "--- server stdout (tail) ---"
        Get-FileTail -Path $server.LogFile | ForEach-Object { Write-Warning $_ }
    }
} finally {
    if ($client) {
        try {
            if (-not $client.Process.HasExited) {
                Stop-ProcessTree -Id $client.Process.Id
            }
        } catch { }
        Complete-MinecraftClientOutput -Client $client
    }
    if ($server) {
        try {
            if (-not $server.Process.HasExited) {
                Stop-ProcessTree -Id $server.Process.Id
            }
        } catch { }
    }

    Start-Sleep -Seconds 2
    $result.durationSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

    try {
        Copy-ResultArtifacts -ResultDirectory $ResultDir -GameDir $gameDir -Root $WorkDir `
            -Server $server -Client $client -Screenshots @($capeScreenshot, $screenshot)
    } catch {
        Write-Warning "Failed to copy result artifacts: $_"
    }

    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultDir 'result.json') -Encoding utf8
    Write-Output "Result: $($result.status) ($($result.durationSeconds)s)"
}

if ($result.status -ne 'passed') {
    exit 1
}
exit 0
