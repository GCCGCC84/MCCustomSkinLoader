param(
    [Parameter(Mandatory = $true)][string]$MinecraftVersion,
    [Parameter(Mandatory = $true)][string]$Clients,
    [string]$RunDir = "Test/run"
)

$ErrorActionPreference = "Stop"

$StallSeconds = 30
$MaxAttempts = 3
$AttemptDeadlineMinutes = 3

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

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TestJobNativeMethods {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);
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

function Send-GameKey {
    param([IntPtr]$Window, [int]$VirtualKey, [bool]$Down)
    $scan = [long][TestJobNativeMethods]::MapVirtualKey([uint32]$VirtualKey, 0)
    if ($Down) {
        [TestJobNativeMethods]::SendMessage($Window, 0x0100, [IntPtr]$VirtualKey, [IntPtr](1 -bor ($scan -shl 16))) | Out-Null
    } else {
        [TestJobNativeMethods]::SendMessage($Window, 0x0101, [IntPtr]$VirtualKey, [IntPtr](0xC0000001 -bor ($scan -shl 16))) | Out-Null
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
    $window = $game.MainWindowHandle
    Send-GameKey -Window $window -VirtualKey 0x74 -Down $true
    Send-GameKey -Window $window -VirtualKey 0x74 -Down $false
    Start-Sleep -Milliseconds 500
    Send-GameKey -Window $window -VirtualKey 0x09 -Down $true
    Start-Sleep -Milliseconds 500
    Send-GameKey -Window $window -VirtualKey 0x71 -Down $true
    Send-GameKey -Window $window -VirtualKey 0x71 -Down $false
    Start-Sleep -Milliseconds 500
    Send-GameKey -Window $window -VirtualKey 0x09 -Down $false
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
$server = $null
$serverReady = $false
$serverReason = ""
for ($serverAttempt = 1; $serverAttempt -le $MaxAttempts; $serverAttempt++) {
    if ($server) {
        Stop-ProcessTree $server
        Start-Sleep -Seconds 3
    }
    $previousReason = if ($serverAttempt -gt 1) { " (previous attempt: $serverReason)" } else { "" }
    Write-Host "[server] attempt $serverAttempt/$MaxAttempts starting$previousReason"
    $server = Start-Process -FilePath "java" -ArgumentList @("-Xmx2G", "-jar", "`"$serverJar`"", "nogui") `
        -WorkingDirectory $ServerDir -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru -NoNewWindow

    $serverOutLineCount = 0
    $serverErrLineCount = 0
    $lastOutputAt = Get-Date
    $attemptDeadline = (Get-Date).AddMinutes($AttemptDeadlineMinutes)
    $serverReason = ""
    while ((Get-Date) -lt $attemptDeadline) {
        $newOutLines = Get-NewLines $serverOut $serverOutLineCount
        foreach ($line in $newOutLines) { Write-Host "[server] $line" }
        if ($newOutLines.Count -gt 0) { $lastOutputAt = Get-Date }
        $serverOutLineCount += $newOutLines.Count

        $newErrLines = Get-NewLines $serverErr $serverErrLineCount
        foreach ($line in $newErrLines) { Write-Host "[server] $line" }
        if ($newErrLines.Count -gt 0) { $lastOutputAt = Get-Date }
        $serverErrLineCount += $newErrLines.Count

        $serverText = if (Test-Path -LiteralPath $serverOut) { Get-Content -LiteralPath $serverOut -Raw } else { "" }
        if ($serverText -match $ServerReadyPattern) { $serverReady = $true; break }
        if ($server.HasExited) { $serverReason = "exited"; break }
        if (((Get-Date) - $lastOutputAt).TotalSeconds -ge $StallSeconds) {
            $serverReason = "stall, no output for $($StallSeconds)s"
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if ($serverReady) { break }
    if (-not $serverReason) {
        $serverReason = "deadline, no ready marker after $($AttemptDeadlineMinutes) minutes"
    }
    Write-Host "[server] attempt $serverAttempt/$MaxAttempts failed: $serverReason"
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

        $clientReason = ""
        $clientSucceeded = $false
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $attemptSuffix = if ($attempt -eq 1) { "" } else { ".attempt$attempt" }
            $clientOut = Join-Path $ClientLogDir "$clientName$attemptSuffix.log"
            Remove-Item -LiteralPath $clientOut -Force -ErrorAction SilentlyContinue

            $screenshotsBefore = @(Get-ChildItem -LiteralPath $ScreenshotsDir -File -ErrorAction SilentlyContinue).Count
            $cslLaunchTime = (Get-Date).ToUniversalTime()
            $clientLineCount = 0
            $cslLineCount = 0
            $skinLoaded = $false

            $previousReason = if ($attempt -gt 1) { " (previous attempt: $clientReason)" } else { "" }
            Write-Host "[$clientName] attempt $attempt/$MaxAttempts launching$previousReason"
            $command = "& '$clientScript' 2>&1 | Tee-Object -FilePath '$clientOut'"
            $client = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-Command", $command) -WorkingDirectory $ClientDir -PassThru -NoNewWindow

            $lastOutputAt = Get-Date
            $attemptDeadline = (Get-Date).AddMinutes($AttemptDeadlineMinutes)
            $clientReason = ""
            while ((Get-Date) -lt $attemptDeadline) {
                $newLines = Get-NewLines $clientOut $clientLineCount
                foreach ($line in $newLines) {
                    Write-Host "[$clientName] $line"
                    foreach ($marker in $SkinLoadedMarkers) { if ($line.Contains($marker)) { $skinLoaded = $true } }
                }
                if ($newLines.Count -gt 0) { $lastOutputAt = Get-Date }
                $clientLineCount += $newLines.Count

                if (Test-Path -LiteralPath $CustomSkinLoaderLog) {
                    $cslInfo = Get-Item -LiteralPath $CustomSkinLoaderLog
                    if ($cslInfo.LastWriteTimeUtc -gt $cslLaunchTime) {
                        $cslNewLines = Get-NewLines $CustomSkinLoaderLog $cslLineCount
                        foreach ($line in $cslNewLines) {
                            Write-Host "[$clientName:csl] $line"
                            foreach ($marker in $SkinLoadedMarkers) { if ($line.Contains($marker)) { $skinLoaded = $true } }
                        }
                        if ($cslNewLines.Count -gt 0) { $lastOutputAt = Get-Date }
                        $cslLineCount += $cslNewLines.Count
                    }
                }

                if ($skinLoaded) { break }
                if ($client.HasExited) { $clientReason = "exited"; break }
                if (((Get-Date) - $lastOutputAt).TotalSeconds -ge $StallSeconds) {
                    $clientReason = "stall, no output for $($StallSeconds)s"
                    break
                }
                Start-Sleep -Milliseconds 500
            }
            if (-not $skinLoaded -and -not $clientReason) {
                $clientReason = "deadline, no skin marker after $($AttemptDeadlineMinutes) minutes"
            }

            if ($skinLoaded) {
                Write-Host "[$clientName] skin loaded, waiting 15 second"
                Start-Sleep -Seconds 15 # Wait for the "Chat message can't be verified" popup to auto-close so it doesn't block the Tab player list.
                if (-not (Send-GameKeys)) {
                    $clientReason = "window not found"
                } else {
                    $screenshotFound = $false
                    $screenshotDeadline = (Get-Date).AddSeconds(30)
                    while ((Get-Date) -lt $screenshotDeadline) {
                        $screenshotsAfter = @(Get-ChildItem -LiteralPath $ScreenshotsDir -File -ErrorAction SilentlyContinue).Count
                        if ($screenshotsAfter -gt $screenshotsBefore) { $screenshotFound = $true; break }
                        Start-Sleep -Milliseconds 500
                    }
                    if ($screenshotFound) {
                        Write-Host "[$clientName] screenshot captured"
                    } else {
                        Write-Host "[$clientName] screenshot not found"
                        $clientReason = "screenshot not found"
                    }
                }
            }

            $remainingLines = Get-NewLines $clientOut $clientLineCount
            foreach ($line in $remainingLines) { Write-Host "[$clientName] $line" }
            if (Test-Path -LiteralPath $CustomSkinLoaderLog) {
                Copy-Item -LiteralPath $CustomSkinLoaderLog -Destination (Join-Path $ClientLogDir "$clientName-CustomSkinLoader$attemptSuffix.log") -Force
            }

            if (-not $clientReason) {
                $clientSucceeded = $true
                Stop-ProcessTree $client
                Start-Sleep -Seconds 2
                break
            }

            Write-Host "[$clientName] attempt $attempt/$MaxAttempts failed: $clientReason"
            Stop-ProcessTree $client
            if ($attempt -ge $MaxAttempts) { break }

            $serverReleaseFrom = @(Get-Content -LiteralPath $serverOut -ErrorAction SilentlyContinue).Count
            $releaseDeadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $releaseDeadline) {
                $releaseLines = Get-NewLines $serverOut $serverReleaseFrom
                if (($releaseLines -join "`n").Contains(" left the game")) { break }
                Start-Sleep -Milliseconds 500
            }
        }

        if (-not $clientSucceeded) {
            Write-Host "[$clientName] skin not loaded"
            $failed = $true
        }
    }
}

if ($server) { Stop-ProcessTree $server }
Write-Host "Test finished for $MinecraftVersion (failed: $failed)"
if ($failed) { exit 1 }
exit 0
