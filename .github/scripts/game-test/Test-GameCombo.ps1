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
    [int]$MaxMemoryMb = 2048,
    [int]$JoinRelayHoldSeconds = 12,
    [switch]$QuiltSystemLibraries
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/MetaLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MinecraftLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Mesa3D.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/GameWindow.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/JoinRelay.psm1') -Force

$requiredCommands = @(
    'Get-MergedLaunchProfile', 'Install-MinecraftRuntime', 'Install-Mesa3D', 'Get-ProcessTreeId',
    'Test-JoinRelayRequired', 'Start-JoinRelay', 'Set-JoinRelayRelease', 'Stop-JoinRelay', 'Get-FreeTcpPort',
    'Test-JoinRelayKeepAliveReady', 'Get-JoinRelayKeepAliveIds', 'Get-JoinRelayWorkerFaults'
)
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

function Get-ServerSessionDropReason {
    param([Parameter(Mandatory)][object]$Server)

    if (-not $Server.LogFile -or -not (Test-Path -LiteralPath $Server.LogFile)) {
        return $null
    }
    $lines = @(Get-Content -LiteralPath $Server.LogFile -ErrorAction SilentlyContinue)
    $lastJoin = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match 'joined the game') {
            $lastJoin = $index
        }
    }
    if ($lastJoin -lt 0) {
        return $null
    }
    for ($index = $lastJoin + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match 'lost connection: (.+)') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Assert-ClientSession {
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][string]$GameDir
    )

    $reason = Get-ServerSessionDropReason -Server $Server
    if ($reason) {
        throw "The client did not stay connected to the server (lost connection: $reason)"
    }
    if ($Client.Process.HasExited) {
        $detail = "Minecraft client exited with code $($Client.Process.ExitCode) after joining the server"
        $reportDir = Join-Path $GameDir 'crash-reports'
        if (Test-Path -LiteralPath $reportDir) {
            $report = Get-ChildItem -LiteralPath $reportDir -Filter '*.txt' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($report) {
                $detail += " (crash report: $($report.Name))"
            }
        }
        throw $detail
    }
}

function Wait-JoinRelayRelease {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][string]$GameDir,
        [int]$HoldSeconds = 12,
        [int]$TimeoutSeconds = 180
    )

    # The atlas marker is written while the first resource reload finishes; the
    # extra hold is a safety margin because the model registry and the block
    # state cache are populated right after it. The client is parked at
    # "Joining world" and keeps answering keep-alives, so waiting longer is
    # harmless.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $atlasSeenAt = $null
    while ((Get-Date) -lt $deadline) {
        Assert-ClientSession -Server $Server -Client $Client -GameDir $GameDir
        if (Test-Path -LiteralPath $LogPath) {
            $content = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $content -and $content -match 'Created: .*atlas') {
                if ($null -eq $atlasSeenAt) {
                    $atlasSeenAt = Get-Date
                } elseif (((Get-Date) - $atlasSeenAt).TotalSeconds -ge $HoldSeconds) {
                    return $true
                }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-SkinProfileLoaded {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][string]$GameDir,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Assert-ClientSession -Server $Server -Client $Client -GameDir $GameDir
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

    # Crash reports, hs_err and replay logs explain failures where the client
    # exits without a readable stack in latest.log.
    foreach ($pattern in @(
            @{ Dir = (Join-Path $GameDir 'crash-reports'); Filter = '*.txt' },
            @{ Dir = $GameDir; Filter = 'hs_err_pid*.log' },
            @{ Dir = $GameDir; Filter = 'replay_pid*.log' }
        )) {
        if (-not (Test-Path -LiteralPath $pattern.Dir)) {
            continue
        }
        foreach ($crashFile in @(Get-ChildItem -LiteralPath $pattern.Dir -Filter $pattern.Filter -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $crashFile.FullName -Destination (Join-Path $logDir $crashFile.Name) -Force
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

    # The runner has no audio device; without a null OpenAL backend the sound
    # engine error handling can stall the first resource reload for up to 30
    # seconds, which is long enough for the server to time the client out.
    $mesaEnvironment = @{ ALSOFT_DRIVERS = 'null' }
    if (-not $SkipMesa) {
        # LWJGL 2 loads opengl32.dll with the Win32 LoadLibrary search order,
        # where the executable directory beats PATH. Deploy Mesa next to
        # java.exe as well so the software renderer is actually picked up.
        $mesa = Install-Mesa3D -CacheDir $MesaCacheDir -Destination $runtime.NativesDir `
            -AdditionalDestination (Split-Path -Parent $javaExe)
        Write-Output "Mesa3D $($mesa.Version) deployed to $($runtime.NativesDir) and $((Split-Path -Parent $javaExe))"
        $mesaEnv = Get-MesaEnvironment -MesaRoot $mesa.Root
        foreach ($key in $mesaEnv.Keys) {
            $mesaEnvironment[$key] = $mesaEnv[$key]
        }
    }

    if (Test-Path -LiteralPath $gameDir) {
        Remove-Item -LiteralPath $gameDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $gameDir 'mods') | Out-Null
    Copy-Item -LiteralPath $ModJar -Destination (Join-Path $gameDir "mods/$(Split-Path -Leaf $ModJar)") -Force
    Write-CustomSkinLoaderConfig -Directory (Join-Path $gameDir 'CustomSkinLoader') -Username $Username `
        -SkinPng $SkinPng -CapePng $CapePng

    # A fresh game directory shows the accessibility onboarding screen on
    # Minecraft 1.19.1+, which blocks quick play from joining the server.
    Set-Content -LiteralPath (Join-Path $gameDir 'options.txt') -Value 'onboardAccessibility:false' -Encoding utf8

    $useJoinRelay = Test-JoinRelayRequired -McVersion $McVersion -Loader $Loader
    # Minecraft 1.16.4/1.16.5 silently treats the offline privileges response as
    # "servers not allowed" and skips the --server auto-connect. Pointing the
    # game proxy at a closed local port makes the request fail, so the client
    # falls back to the offline social service and allows servers again.
    $useDeadProxy = ($McVersion -match '^1\.16\.[45]$')
    $upstreamPort = if ($useJoinRelay) { [int]$ServerPort + 1 } else { [int]$ServerPort }

    $server = & (Join-Path $PSScriptRoot 'Start-VanillaServer.ps1') -McVersion $McVersion -JavaExe $javaExe `
        -ServerDir $serverDir -CacheDir $CacheDir -Port $upstreamPort -TimeoutSeconds $ServerTimeoutSeconds

    if ($useJoinRelay) {
        Write-Output "Join relay: client -> $ServerPort -> server $upstreamPort"
        $keepAliveHint = Get-JoinRelayKeepAliveIds -McVersion $McVersion
        $relayArguments = @{ ListenPort = $ServerPort; UpstreamPort = $upstreamPort }
        if ($keepAliveHint) {
            $relayArguments.ClientboundKeepAliveId = [int]$keepAliveHint.Clientbound
            $relayArguments.ServerboundKeepAliveId = [int]$keepAliveHint.Serverbound
        }
        [void](Start-JoinRelay @relayArguments)
    }

    $launch = New-MinecraftLaunchArguments -Profile $profile -Runtime $runtime -JavaExe $javaExe `
        -GameDir $gameDir -Username $Username -ServerHost $ServerHost -ServerPort $ServerPort `
        -MaxMemoryMb $MaxMemoryMb -QuiltSystemLibraries:$QuiltSystemLibraries

    $extraGameArguments = @()
    if ($useDeadProxy) {
        $deadProxyPort = Get-FreeTcpPort
        $extraGameArguments += @('--proxyHost', '127.0.0.1', '--proxyPort', [string]$deadProxyPort)
        Write-Output "Dead proxy for the offline privileges check: 127.0.0.1:$deadProxyPort"
    }
    if ($extraGameArguments.Count -gt 0) {
        $launch.Arguments = @($launch.Arguments) + $extraGameArguments
    }

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

    if ($useJoinRelay) {
        $clientLog = Join-Path $gameDir 'logs/latest.log'
        if (-not (Wait-JoinRelayRelease -LogPath $clientLog -Server $server -Client $client -GameDir $gameDir `
                -HoldSeconds $JoinRelayHoldSeconds -TimeoutSeconds 180)) {
            Write-Warning 'Resource reload marker was not seen; releasing the join relay anyway'
        }
        # The relay answers keep-alives for the client while the first terrain
        # render blocks the main thread; wait until it has learned the packet
        # ids from a real client answer (not needed when a verified fallback
        # table already provides them).
        if (-not (Get-JoinRelayKeepAliveIds -McVersion $McVersion)) {
            $keepAliveDeadline = (Get-Date).AddSeconds(30)
            while (-not (Test-JoinRelayKeepAliveReady) -and (Get-Date) -lt $keepAliveDeadline) {
                Assert-ClientSession -Server $server -Client $client -GameDir $gameDir
                Start-Sleep -Seconds 2
            }
        }
        Write-Output "Join relay keep-alive ids learned: $(Test-JoinRelayKeepAliveReady)"
        Set-JoinRelayRelease
        Write-Output "Join relay: $(Get-JoinRelayStatus)"
        Start-Sleep -Seconds 5
    }
    Assert-ClientSession -Server $server -Client $client -GameDir $gameDir

    # Wait until CustomSkinLoader has applied a profile (and give the world a
    # moment to render) before taking the screenshots.
    $cslLog = Join-Path $gameDir 'CustomSkinLoader/CustomSkinLoader.log'
    [void](Wait-SkinProfileLoaded -LogPath $cslLog -Server $server -Client $client -GameDir $gameDir -TimeoutSeconds 60)
    Start-Sleep -Seconds 3
    Assert-ClientSession -Server $server -Client $client -GameDir $gameDir

    $processIds = Get-ProcessTreeId -RootId $client.Process.Id
    $windowHandle = Get-GameWindow -ProcessIds $processIds -TitleLike 'Minecraft' -TimeoutSeconds $WindowTimeoutSeconds
    $screenshotsDir = Join-Path $gameDir 'screenshots'

    if ($windowHandle -ne [IntPtr]::Zero) {
        # On slow software rendering the terrain can still be loading right
        # after the skin profile is reported. Window captures are unreliable
        # with software OpenGL, so probe with in-game F2 screenshots until the
        # world is actually visible.
        $worldReady = $false
        $worldDeadline = (Get-Date).AddSeconds(150)
        while ((Get-Date) -lt $worldDeadline) {
            Assert-ClientSession -Server $server -Client $client -GameDir $gameDir
            $probe = Get-MinecraftScreenshot -Handle $windowHandle -Directory $screenshotsDir -TimeoutSeconds 30
            Assert-ClientSession -Server $server -Client $client -GameDir $gameDir
            if ($probe) {
                try {
                    if (Test-WorldScreenshot -Path $probe) {
                        $worldReady = $true
                        break
                    }
                } catch {
                }
            }
            Start-Sleep -Seconds 3
        }
        if ($worldReady) {
            Write-Output 'World is visible.'
        } else {
            Write-Warning 'The world did not become visible within 150 seconds; continuing with the screenshots'
        }

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
    Assert-ClientSession -Server $server -Client $client -GameDir $gameDir
    if ($useJoinRelay -and (Get-JoinRelayWorkerFaults) -gt 0) {
        throw "Join relay worker failed: $(Get-JoinRelayStatus)"
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
        if (-not $result.error) {
            $result.error = "CustomSkinLoader.log was not created at '$cslLog'"
        }
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
    Stop-JoinRelay

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
