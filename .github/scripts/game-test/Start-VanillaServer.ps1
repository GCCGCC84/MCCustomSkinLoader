# Starts a vanilla Minecraft server for the requested version and waits until it
# is ready to accept connections.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$McVersion,
    [Parameter(Mandatory)][string]$JavaExe,
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory)][string]$CacheDir,
    [int]$Port = 25565,
    [int]$TimeoutSeconds = 300,
    [int]$MaxMemoryMb = 1024
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/MetaLauncher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MinecraftLauncher.psm1') -Force

function Get-VanillaServerJar {
    param(
        [Parameter(Mandatory)][string]$McVersion,
        [Parameter(Mandatory)][string]$CacheDir
    )

    $serverDir = Join-Path $CacheDir 'server'
    New-Item -ItemType Directory -Force -Path $serverDir | Out-Null
    $jarPath = Join-Path $serverDir "$McVersion.jar"

    $entry = Get-MinecraftVersionManifestEntry -McVersion $McVersion -CacheDir $CacheDir
    $versionJson = Invoke-MetaRequest -Uri $entry.url
    $serverDownload = $versionJson.downloads.server
    if ($null -eq $serverDownload -or -not $serverDownload.url) {
        throw "Minecraft $McVersion does not provide a vanilla server download"
    }

    if (Test-Path -LiteralPath $jarPath) {
        $existing = Get-Item -LiteralPath $jarPath
        if ($null -eq $serverDownload.size -or $existing.Length -eq $serverDownload.size) {
            return $jarPath
        }
    }

    $download = [pscustomobject]@{
        Url  = [string]$serverDownload.url
        Path = $jarPath
        Sha1 = [string]$serverDownload.sha1
        Size = $serverDownload.size
    }
    Write-Host "Downloading vanilla server $McVersion ..."
    Invoke-McFileDownload -Items @($download) -ThrottleLimit 1
    return $jarPath
}

New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null
$serverJar = Get-VanillaServerJar -McVersion $McVersion -CacheDir $CacheDir

$eulaFile = Join-Path $ServerDir 'eula.txt'
if (-not (Test-Path -LiteralPath $eulaFile)) {
    "eula=true" | Set-Content -LiteralPath $eulaFile -Encoding ascii
}

$propertiesFile = Join-Path $ServerDir 'server.properties'
if (-not (Test-Path -LiteralPath $propertiesFile)) {
    @(
        'online-mode=false'
        "server-port=$Port"
        'server-ip=127.0.0.1'
        'white-list=false'
        'enforce-whitelist=false'
        # Keep world packets large so the join relay can hold them by frame
        # size; compression squashes the flat world's mostly-air chunks below
        # the relay threshold and they would leak through before the client
        # finished its first resource reload.
        'network-compression-threshold=-1'
        'level-type=flat'
        'spawn-protection=0'
        'view-distance=6'
        'simulation-distance=6'
        'allow-nether=false'
        'generate-structures=false'
        'spawn-monsters=false'
        'difficulty=peaceful'
        'max-players=2'
        'motd=CSL Game Test'
    ) | Set-Content -LiteralPath $propertiesFile -Encoding ascii
}

$logFile = Join-Path $ServerDir 'server-stdout.log'
$errorFile = Join-Path $ServerDir 'server-stderr.log'

# A previous loader in the same job may still be releasing the port.
$portDeadline = (Get-Date).AddSeconds(60)
$portFree = $false
while (-not $portFree -and (Get-Date) -lt $portDeadline) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        $listener.Stop()
        $portFree = $true
    } catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $portFree) {
    throw "TCP port $Port is still in use after waiting 60 seconds"
}

$arguments = @(
    "-Xmx${MaxMemoryMb}M",
    '-Dminecraft.api.env=prod',
    '-jar',
    (ConvertTo-ProcessArgument -Argument $serverJar),
    'nogui'
) -join ' '

$process = Start-Process -FilePath $JavaExe -ArgumentList $arguments -WorkingDirectory $ServerDir `
    -RedirectStandardOutput $logFile -RedirectStandardError $errorFile -PassThru -NoNewWindow

Write-Host "Waiting for vanilla server $McVersion to start (pid $($process.Id)) ..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if ($process.HasExited) {
        $tail = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Tail 40 -ErrorAction SilentlyContinue } else { @() }
        throw "Minecraft server $McVersion exited with code $($process.ExitCode) before becoming ready.`n$($tail -join [Environment]::NewLine)"
    }

    if (Test-Path -LiteralPath $logFile) {
        $content = Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue
        if ($content -match 'Done \(') {
            $ready = $true
            break
        }
    }
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    try { taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { }
    throw "Minecraft server $McVersion did not become ready within $TimeoutSeconds seconds"
}

Write-Host "Vanilla server $McVersion is ready."

[pscustomobject]@{
    Process   = $process
    LogFile   = $logFile
    ErrorFile = $errorFile
    Port      = $Port
    McVersion = $McVersion
}
