param(
    [Parameter(Mandatory = $true)][string]$MinecraftVersion,
    [Parameter(Mandatory = $true)][string]$Clients,
    [string]$RunDir = "run"
)

$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RunDir)) {
    $RunDir = Join-Path (Get-Location).Path $RunDir
}
$ServerDir = Join-Path $RunDir "server"
$ClientDir = Join-Path $RunDir "client"
$ClientLogDir = Join-Path $ClientDir "logs"
$ScreenshotsDir = Join-Path $ClientDir "screenshots"
$CustomSkinLoaderLog = Join-Path $ClientDir "CustomSkinLoader/CustomSkinLoader.log"
$SkinLoadedMarkers = @("'s profile loaded. (", "Cached profile will be used.")
$ServerReadyPattern = "Done \("

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TestJobNativeMethods {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

function Get-NewLines {
    param([string]$Path, [int]$FromLine)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -lt $FromLine) { $FromLine = 0 }
    if ($lines.Count -le $FromLine) { return @() }
    return @($lines[$FromLine..($lines.Count - 1)])
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($Process -and -not $Process.HasExited) {
        taskkill /PID $Process.Id /T /F 2>&1 | Out-Null
        $Process.WaitForExit(30000) | Out-Null
    }
}

function Send-GameKeys {
    $game = Get-Process -Name java -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "Minecraft*"
    } | Select-Object -First 1
    if (-not $game) {
        Write-Host "[keys] Minecraft window not found"
        return $false
    }
    Write-Host "[keys] window: $($game.MainWindowTitle)"
    # SetForegroundWindow can be refused by the foreground lock, so ask twice before injecting keys.
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        [TestJobNativeMethods]::ShowWindow($game.MainWindowHandle, 9) | Out-Null
        $foreground = [TestJobNativeMethods]::SetForegroundWindow($game.MainWindowHandle)
        if ($foreground) { break }
        Write-Host "[keys] SetForegroundWindow refused (attempt $attempt)"
        Start-Sleep -Milliseconds 1000
    }
    Start-Sleep -Milliseconds 1000
    [System.Windows.Forms.SendKeys]::SendWait("{F5}")
    Start-Sleep -Milliseconds 500
    [TestJobNativeMethods]::keybd_event(0x09, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("{F2}")
    Start-Sleep -Milliseconds 500
    [TestJobNativeMethods]::keybd_event(0x09, 0, 2, [UIntPtr]::Zero)
    return $true
}

New-Item -ItemType Directory -Force -Path $ClientLogDir, $ScreenshotsDir | Out-Null

$serverJar = Join-Path $ServerDir "$MinecraftVersion.jar"
if (-not (Test-Path -LiteralPath $serverJar)) {
    throw "Server jar not found: $serverJar"
}

Write-Host "Starting server for $MinecraftVersion"
$serverOut = Join-Path $ServerDir "test-server.log"
$serverErr = Join-Path $ServerDir "test-server.err.log"
$server = Start-Process -FilePath "java" -ArgumentList @("-Xmx2G", "-jar", "`"$serverJar`"", "nogui") `
    -WorkingDirectory $ServerDir -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru -NoNewWindow

$serverLineCount = 0
$serverReady = $false
$serverDeadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $serverDeadline) {
    $newLines = Get-NewLines $serverOut $serverLineCount
    foreach ($line in $newLines) { Write-Host "[server] $line" }
    $serverLineCount += $newLines.Count
    $serverText = if (Test-Path -LiteralPath $serverOut) { Get-Content -LiteralPath $serverOut -Raw } else { "" }
    if ($serverText -match $ServerReadyPattern) { $serverReady = $true; break }
    if ($server.HasExited) { break }
    Start-Sleep -Milliseconds 500
}

$failed = $false
if (-not $serverReady) {
    Write-Host "[server] failed to start"
    $failed = $true
} else {
    Write-Host "[server] ready"
}

if ($serverReady) {
    foreach ($clientName in ($Clients -split ",")) {
        $clientName = $clientName.Trim()
        if (-not $clientName) { continue }
        $clientScript = Join-Path $ClientDir $clientName
        if (-not (Test-Path -LiteralPath $clientScript)) {
            Write-Host "[$clientName] launch script not found"
            $failed = $true
            continue
        }

        $clientOut = Join-Path $ClientLogDir "$clientName.log"
        Remove-Item -LiteralPath $clientOut -Force -ErrorAction SilentlyContinue

        $screenshotsBefore = @(Get-ChildItem -LiteralPath $ScreenshotsDir -File -ErrorAction SilentlyContinue).Count
        $cslLaunchTime = (Get-Date).ToUniversalTime()

        Write-Host "[$clientName] launching"
        $command = "& '$clientScript' 2>&1 | Tee-Object -FilePath '$clientOut'"
        $client = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-Command", $command) -WorkingDirectory $ClientDir -PassThru -NoNewWindow

        $clientLineCount = 0
        $cslLineCount = 0
        $skinLoaded = $false
        $clientDeadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $clientDeadline) {
            $newLines = Get-NewLines $clientOut $clientLineCount
            foreach ($line in $newLines) {
                Write-Host "[$clientName] $line"
                foreach ($marker in $SkinLoadedMarkers) { if ($line.Contains($marker)) { $skinLoaded = $true } }
            }
            $clientLineCount += $newLines.Count

            if (Test-Path -LiteralPath $CustomSkinLoaderLog) {
                $cslInfo = Get-Item -LiteralPath $CustomSkinLoaderLog
                if ($cslInfo.LastWriteTimeUtc -gt $cslLaunchTime) {
                    $cslNewLines = Get-NewLines $CustomSkinLoaderLog $cslLineCount
                    foreach ($line in $cslNewLines) {
                        Write-Host "[$clientName:csl] $line"
                        foreach ($marker in $SkinLoadedMarkers) { if ($line.Contains($marker)) { $skinLoaded = $true } }
                    }
                    $cslLineCount += $cslNewLines.Count
                }
            }

            if ($skinLoaded) { break }
            if ($client.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }

        if (-not $skinLoaded) {
            Write-Host "[$clientName] skin not loaded"
            $failed = $true
            Stop-ProcessTree $client
            continue
        }

        Write-Host "[$clientName] skin loaded, waiting 1 second"
        Start-Sleep -Seconds 1
        # Key injection is single-shot by nature and the runner desktop is busy, so retry instead of
        # failing the run when the first attempt does not produce a file.
        $screenshotFound = $false
        for ($attempt = 1; $attempt -le 3 -and -not $screenshotFound; $attempt++) {
            if (-not (Send-GameKeys)) {
                $failed = $true
                break
            }

            $screenshotDeadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $screenshotDeadline) {
                $screenshotsAfter = @(Get-ChildItem -LiteralPath $ScreenshotsDir -File -ErrorAction SilentlyContinue).Count
                if ($screenshotsAfter -gt $screenshotsBefore) { $screenshotFound = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $screenshotFound) {
                Write-Host "[$clientName] screenshot attempt $attempt produced no file"
            }
        }
        if ($screenshotFound) {
            Write-Host "[$clientName] screenshot captured"
        } else {
            Write-Host "[$clientName] screenshot not found"
            $failed = $true
        }

        $remainingLines = Get-NewLines $clientOut $clientLineCount
        foreach ($line in $remainingLines) { Write-Host "[$clientName] $line" }
        if (Test-Path -LiteralPath $CustomSkinLoaderLog) {
            Copy-Item -LiteralPath $CustomSkinLoaderLog -Destination (Join-Path $ClientLogDir "$clientName-CustomSkinLoader.log") -Force
        }
        Stop-ProcessTree $client
        Start-Sleep -Seconds 2
    }
}

if ($server) { Stop-ProcessTree $server }
Write-Host "Test finished for $MinecraftVersion (failed: $failed)"
if ($failed) { exit 1 }
exit 0
