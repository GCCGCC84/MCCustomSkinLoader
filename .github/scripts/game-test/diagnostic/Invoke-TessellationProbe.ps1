[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$McVersion,
    [Parameter(Mandatory)][string]$Loader,
    [Parameter(Mandatory)][string]$LoaderVersion,
    [Parameter(Mandatory)][string]$Mode,
    [bool]$WithCsl = $true,
    [bool]$DeferredJoin = $false,
    [bool]$QuiltSystemLibraries = $false,
    [Parameter(Mandatory)][string]$ModJar,
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$CacheDir,
    [Parameter(Mandatory)][string]$MesaCacheDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$ResultDir,
    [int]$ObserveSeconds = 90
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
Import-Module (Join-Path $lib 'MetaLauncher.psm1') -Force
Import-Module (Join-Path $lib 'MinecraftLauncher.psm1') -Force
Import-Module (Join-Path $lib 'Mesa3D.psm1') -Force
Import-Module (Join-Path $lib 'GameWindow.psm1') -Force
if ($DeferredJoin) {
    Import-Module (Join-Path $PSScriptRoot 'DiagnosticWindow.psm1') -Force
}

$WorkDir = [IO.Path]::GetFullPath($WorkDir)
$ResultDir = [IO.Path]::GetFullPath($ResultDir)
$gameDir = Join-Path $WorkDir 'game'
$serverDir = Join-Path $WorkDir 'server'
$javaExe = Join-Path $JavaHome 'bin/java.exe'
New-Item -ItemType Directory -Force -Path $ResultDir, $gameDir, (Join-Path $gameDir 'mods') | Out-Null
$events = New-Object System.Collections.Generic.List[object]
$watch = [Diagnostics.Stopwatch]::StartNew()
$server = $null
$client = $null
$handle = [IntPtr]::Zero
$result = [ordered]@{
    mc = $McVersion; loader = $Loader; loaderVersion = $LoaderVersion; mode = $Mode
    withCsl = $WithCsl; deferredJoin = $DeferredJoin; quiltSystemLibraries = $QuiltSystemLibraries
    status = 'setup-failed'
    serverJoined = $false; clientWorldLoaded = $false; skinProfileLoaded = $false
    tessellationCrash = $false; renderingCrash = $false; stackOverflow = $false
    exitCode = $null; disconnectReason = $null; error = $null; durationSeconds = 0
}

function Record-Event([string]$Name, [string]$Detail = '') {
    $event = [ordered]@{ seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3); utc = [DateTime]::UtcNow.ToString('o'); name = $Name; detail = $Detail }
    $events.Add($event)
    Write-Host "[$($event.seconds)s] $Name $Detail"
}

function Read-IfPresent([string]$File) {
    if (Test-Path -LiteralPath $File) {
        return [string](Get-Content -LiteralPath $File -Raw -ErrorAction SilentlyContinue)
    }
    return ''
}

function Capture-Window([string]$Name) {
    try {
        $ids = Get-ProcessTreeId -RootId $client.Process.Id
        $script:handle = Get-GameWindow -ProcessIds $ids -TitleLike 'Minecraft' -TimeoutSeconds 1
        if ($script:handle -ne [IntPtr]::Zero) {
            Set-GameWindowForeground -Handle $script:handle
            Save-WindowScreenshot -Handle $script:handle -Path (Join-Path $ResultDir "screenshots/$Name.png") | Out-Null
            Record-Event 'screenshot' $Name
        }
    } catch { Record-Event 'screenshot-error' "$_" }
}

try {
    Record-Event 'setup' "$McVersion/$Loader/$Mode"
    & $javaExe -version 2>&1 | Set-Content (Join-Path $ResultDir 'java-version.txt')
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, TotalVisibleMemorySize |
        ConvertTo-Json | Set-Content (Join-Path $ResultDir 'runner-os.json')
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors |
        ConvertTo-Json | Set-Content (Join-Path $ResultDir 'runner-cpu.json')
    Get-FileHash $ModJar -Algorithm SHA1 | ConvertTo-Json | Set-Content (Join-Path $ResultDir 'mod-hash.json')

    $profile = Get-MergedLaunchProfile -McVersion $McVersion -Loader $Loader -LoaderVersion $LoaderVersion
    $profile | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $ResultDir 'launch-profile.json')
    $runtime = Install-MinecraftRuntime -Profile $profile -CacheDir $CacheDir -WorkDir $WorkDir
    $mesa = Install-Mesa3D -CacheDir $MesaCacheDir -Destination $runtime.NativesDir -AdditionalDestination (Split-Path -Parent $javaExe)
    $mesaEnvironment = Get-MesaEnvironment -MesaRoot $mesa.Root
    $mesa | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultDir 'mesa.json')

    @('guiScale:2', 'lang:en_us', 'skipMultiplayerWarning:true', 'onboardAccessibility:false') | Set-Content (Join-Path $gameDir 'options.txt') -Encoding ascii
    if ($WithCsl) {
        Copy-Item $ModJar (Join-Path $gameDir "mods/$(Split-Path -Leaf $ModJar)")
        $csl = Join-Path $gameDir 'CustomSkinLoader'
        New-Item -ItemType Directory -Force -Path (Join-Path $csl 'LocalSkin/skins'), (Join-Path $csl 'LocalSkin/capes') | Out-Null
        $assets = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
        Copy-Item (Join-Path $assets 'skin.png') (Join-Path $csl 'LocalSkin/skins/CslTest.png')
        Copy-Item (Join-Path $assets 'cape.png') (Join-Path $csl 'LocalSkin/capes/CslTest.png')
        [ordered]@{
            version = '15.1'; buildNumber = 0
            loadlist = @([ordered]@{ name = 'LocalSkin'; type = 'Legacy'; skin = 'LocalSkin/skins/{USERNAME}.png'; cape = 'LocalSkin/capes/{USERNAME}.png'; elytra = 'LocalSkin/elytras/{USERNAME}.png'; model = 'auto'; checkPNG = $false })
            enableTransparentSkin = $true; forceLoadAllTextures = $true; enableCape = $true; threadPoolSize = 4
            enableLogStdOut = $true; cacheExpiry = 30; forceUpdateSkull = $false; enableLocalProfileCache = $false
            enableCacheAutoClean = $false; forceDisableCache = $false
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $csl 'CustomSkinLoader.json') -Encoding utf8
    }

    $server = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-VanillaServer.ps1') `
        -McVersion $McVersion -JavaExe $javaExe -ServerDir $serverDir -CacheDir $CacheDir -TimeoutSeconds 300
    Record-Event 'server-ready'
    $launch = New-MinecraftLaunchArguments -Profile $profile -Runtime $runtime -JavaExe $javaExe `
        -GameDir $gameDir -Username 'CslTest' -QuiltSystemLibraries:$QuiltSystemLibraries
    if ($DeferredJoin) {
        $filtered = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $launch.Arguments.Count; $i++) {
            if ($launch.Arguments[$i] -in @('--server', '--port', '--quickPlayMultiplayer')) { $i++; continue }
            $filtered.Add($launch.Arguments[$i])
        }
        $launch.Arguments = $filtered.ToArray()
    }
    $launch | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultDir 'launch-command.json')
    $client = Start-MinecraftClient -JavaExe $launch.File -Arguments $launch.Arguments -WorkingDirectory $launch.WorkingDir `
        -StdOutFile (Join-Path $WorkDir 'client-stdout.log') -StdErrFile (Join-Path $WorkDir 'client-stderr.log') -Environment $mesaEnvironment
    Record-Event 'client-started' "pid=$($client.Process.Id)"
    $clientStart = $watch.Elapsed.TotalSeconds
    $joinAt = $null
    $uiJoinSent = $false
    $atlasAt = $null
    $seenAtlas = $false
    $capturedJoined = $false
    $threadDumpTaken = $false
    $deadline = (Get-Date).AddSeconds(360)

    while ((Get-Date) -lt $deadline) {
        $latest = Read-IfPresent (Join-Path $gameDir 'logs/latest.log')
        $stdout = Read-IfPresent $client.StdOutFile
        $stderr = Read-IfPresent $client.StdErrFile
        $all = $latest + "`n" + $stdout + "`n" + $stderr
        $serverLog = Read-IfPresent $server.LogFile
        if (-not $seenAtlas -and $all -match 'Created:.*(?:atlas|textures/atlas/)') {
            $seenAtlas = $true; $atlasAt = $watch.Elapsed.TotalSeconds
            Record-Event 'final-atlas-observed'
        }
        if ($all -match 'Tess?el[l]?ating block in world') { $result.tessellationCrash = $true }
        if ($all -match 'Description: Rendering screen|class_5944\.method_34583|class_761\.method_3251') { $result.renderingCrash = $true }
        if ($all -match 'StackOverflowError') { $result.stackOverflow = $true }
        if ($all -match 'Loaded \d+ advancements') { $result.clientWorldLoaded = $true }
        $cslLog = Read-IfPresent (Join-Path $gameDir 'CustomSkinLoader/CustomSkinLoader.log')
        if ($cslLog -match "'s profile loaded\.") { $result.skinProfileLoaded = $true }
        if (-not $result.serverJoined -and $serverLog -match 'joined the game') {
            $result.serverJoined = $true; $joinAt = $watch.Elapsed.TotalSeconds
            Record-Event 'server-join-observed'
        }
        if ($serverLog -match 'lost connection: ([^\r\n]+)') { $result.disconnectReason = $Matches[1].Trim() }
        if ($client.Process.HasExited) {
            $result.exitCode = $client.Process.ExitCode; $result.status = 'client-exited'
            Record-Event 'client-exited' "$($result.exitCode)"; break
        }
        if ($result.tessellationCrash -or $result.renderingCrash) {
            $result.status = 'client-crash'; Capture-Window 'crash'; break
        }
        if ($result.serverJoined -and $result.disconnectReason -and -not $result.clientWorldLoaded) {
            $result.status = 'disconnected-before-world'; break
        }
        if ($DeferredJoin -and -not $uiJoinSent -and $seenAtlas -and ($watch.Elapsed.TotalSeconds - $atlasAt) -ge 10) {
            Capture-Window 'before-deferred-join'
            if ($handle -eq [IntPtr]::Zero) { throw 'No game window for deferred join' }
            Record-Event 'deferred-join-start'
            Invoke-DiagnosticJoin -Handle $handle -ServerHost '127.0.0.1' -ServerPort 25565 -ScreenshotDir (Join-Path $ResultDir 'screenshots')
            $uiJoinSent = $true; Record-Event 'deferred-join-sent'
        }
        if ($result.serverJoined -and -not $capturedJoined -and ($watch.Elapsed.TotalSeconds - $joinAt) -ge 30) {
            Capture-Window 'joined-plus-30'; $capturedJoined = $true
        }
        if ($result.serverJoined -and -not $threadDumpTaken -and ($watch.Elapsed.TotalSeconds - $joinAt) -ge 35) {
            & (Join-Path $JavaHome 'bin/jstack.exe') $client.Process.Id 2>&1 | Set-Content (Join-Path $ResultDir 'client-threads.txt')
            $threadDumpTaken = $true
        }
        if ($result.serverJoined -and ($watch.Elapsed.TotalSeconds - $joinAt) -ge $ObserveSeconds) {
            $result.status = if ($result.disconnectReason) { 'disconnected' } elseif ($result.clientWorldLoaded) { 'stable-world' } else { 'joined-without-world' }
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($result.status -eq 'setup-failed') {
        $result.status = if ($DeferredJoin -and -not $seenAtlas) { 'resource-marker-timeout' } else { 'join-timeout' }
    }
    if (-not $client.Process.HasExited) { Capture-Window 'final' }
} catch {
    $result.error = "$_"
    Record-Event 'probe-error' "$_"
} finally {
    if ($client) {
        if (-not $client.Process.HasExited) { Stop-ProcessTree -Id $client.Process.Id }
        Complete-MinecraftClientOutput -Client $client
    }
    if ($server -and -not $server.Process.HasExited) { Stop-ProcessTree -Id $server.Process.Id }
    Start-Sleep -Seconds 1
    foreach ($entry in @(
        @{from=(Join-Path $WorkDir 'client-stdout.log'); to='client-stdout.log'},
        @{from=(Join-Path $WorkDir 'client-stderr.log'); to='client-stderr.log'},
        @{from=(Join-Path $gameDir 'logs'); to='client-logs'},
        @{from=(Join-Path $gameDir 'crash-reports'); to='crash-reports'},
        @{from=(Join-Path $gameDir 'CustomSkinLoader/CustomSkinLoader.log'); to='CustomSkinLoader.log'},
        @{from=(Join-Path $gameDir 'options.txt'); to='options.txt'},
        @{from=(Join-Path $serverDir 'server-stdout.log'); to='server-stdout.log'},
        @{from=(Join-Path $serverDir 'server-stderr.log'); to='server-stderr.log'},
        @{from=(Join-Path $serverDir 'server.properties'); to='server.properties'}
    )) {
        if (Test-Path -LiteralPath $entry.from) { Copy-Item -LiteralPath $entry.from -Destination (Join-Path $ResultDir $entry.to) -Recurse -Force }
    }
    $result.durationSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
    $events | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultDir 'events.json')
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultDir 'result.json')
    $result | ConvertTo-Json -Depth 8 | Write-Host
}
if ($result.status -eq 'setup-failed' -or $result.error) { exit 1 }
exit 0
