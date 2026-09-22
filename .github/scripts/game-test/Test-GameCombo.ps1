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

function New-TestSkin {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.Drawing
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $bitmap = [System.Drawing.Bitmap]::new(64, 64)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            # Pure magenta: easy to detect in a screenshot and never produced by
            # the vanilla fallback skin.
            $graphics.Clear([System.Drawing.Color]::FromArgb(255, 255, 0, 255))
        } finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
}

function Write-CustomSkinLoaderConfig {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Username
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
    New-TestSkin -Path $skinPath
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
        [AllowNull()][string]$Screenshot
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

    if ($Screenshot -and (Test-Path -LiteralPath $Screenshot)) {
        $screenshotDir = Join-Path $ResultDirectory 'screenshots'
        New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null
        Copy-Item -LiteralPath $Screenshot -Destination (Join-Path $screenshotDir (Split-Path -Leaf $Screenshot)) -Force
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
    skinPixelsPassed = $false
    screenshot       = $null
    durationSeconds  = 0
    error            = $null
}

$server = $null
$client = $null
$windowHandle = [IntPtr]::Zero
$screenshot = $null

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
    Write-CustomSkinLoaderConfig -Directory (Join-Path $gameDir 'CustomSkinLoader') -Username $Username

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
    # moment to render) before taking the screenshot.
    $cslLog = Join-Path $gameDir 'CustomSkinLoader/CustomSkinLoader.log'
    [void](Wait-SkinProfileLoaded -LogPath $cslLog -TimeoutSeconds 60)
    Start-Sleep -Seconds 3

    $processIds = Get-ProcessTreeId -RootId $client.Process.Id
    $windowHandle = Get-GameWindow -ProcessIds $processIds -TitleLike 'Minecraft' -TimeoutSeconds $WindowTimeoutSeconds

    $screenshotStart = Get-Date
    if ($windowHandle -ne [IntPtr]::Zero) {
        Set-GameWindowForeground -Handle $windowHandle
        Send-GameKey -Handle $windowHandle -Key 'F5'
        Start-Sleep -Seconds 3
        Send-GameKey -Handle $windowHandle -Key 'F5'
        Start-Sleep -Seconds 4
        Send-GameKey -Handle $windowHandle -Key 'F2'
    } else {
        Write-Warning 'Minecraft window was not found; skipping key injection'
    }

    $screenshotsDir = Join-Path $gameDir 'screenshots'
    $screenshot = Wait-MinecraftScreenshot -Directory $screenshotsDir -Since $screenshotStart -TimeoutSeconds $ScreenshotTimeoutSeconds
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
            Write-Output "Skin pixel check: $($pixelResult.MagentaPixels) magenta pixels (pass=$($pixelResult.Pass))"
        } catch {
            Write-Warning "Skin pixel check failed: $_"
            if (-not $result.error) {
                $result.error = "Skin pixel check failed: $_"
            }
        }
    } else {
        Write-Warning 'No screenshot could be captured'
    }

    if (Test-Path -LiteralPath $cslLog) {
        $cslContent = Get-Content -LiteralPath $cslLog -Raw
        $result.skinLogLoaded = ($cslContent -match "Try to load profile from 'LocalSkin'\.") -and
            ($cslContent -match "'s profile loaded\.")
        if (-not $result.skinLogLoaded) {
            $result.error = "CustomSkinLoader.log does not report a loaded LocalSkin profile"
        }
    } else {
        $result.error = "CustomSkinLoader.log was not created at '$cslLog'"
    }

    if ($result.joined -and $result.skinLogLoaded -and $result.skinPixelsPassed) {
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
            -Server $server -Client $client -Screenshot $screenshot
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
