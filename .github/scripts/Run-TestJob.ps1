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
# Must match Prepare-TestVersion.ps1: the address the generated launch scripts and the deferred join use.
$ServerAddress = "127.0.0.1"
$ServerPort = 25565

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TestJobNativeMethods {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);
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

function Get-GameWindow {
    return (Get-Process -Name java -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "Minecraft*"
    } | Select-Object -First 1)
}

function Wait-GameWindow {
    param([int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $window = Get-GameWindow
        if ($window) { return $window }
        Start-Sleep -Seconds 2
    }
    $seen = @(Get-Process -Name java -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id):'$($_.MainWindowTitle)'" })
    Write-Host "[keys] no Minecraft window yet, java processes: $($seen -join ', ')"
    return $null
}

function Save-WindowCapture {
    # PrintWindow capture: works without the window being in the foreground, used as join evidence.
    param([IntPtr]$Handle, [string]$Path)
    $rect = New-Object TestJobNativeMethods+RECT
    if (-not [TestJobNativeMethods]::GetClientRect($Handle, [ref]$rect)) { return $false }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { return $false }
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $dpi = [TestJobNativeMethods]::GetDpiForWindow($Handle)
    if ($dpi -le 0) { $dpi = 96 }
    $width = [int][Math]::Round($width * ($dpi / 96.0))
    $height = [int][Math]::Round($height * ($dpi / 96.0))
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    try {
        [void][TestJobNativeMethods]::PrintWindow($Handle, $hdc, 1)
    } finally {
        $graphics.ReleaseHdc($hdc)
        $graphics.Dispose()
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    return $true
}

function Send-GuiClick {
    param([IntPtr]$Handle, [int]$X, [int]$Y)
    $lParam = [IntPtr](($Y -shl 16) -bor ($X -band 0xFFFF))
    [void][TestJobNativeMethods]::PostMessage($Handle, 0x0201, [IntPtr]1, $lParam)
    Start-Sleep -Milliseconds 120
    [void][TestJobNativeMethods]::PostMessage($Handle, 0x0202, [IntPtr]0, $lParam)
}

function Send-GuiText {
    param([IntPtr]$Handle, [string]$Text)
    foreach ($character in $Text.ToCharArray()) {
        [void][TestJobNativeMethods]::PostMessage($Handle, 0x0102, [IntPtr][int]$character, [IntPtr]1)
        Start-Sleep -Milliseconds 70
    }
}

function Wait-ResourceLoadComplete {
    # The title screen is only usable after the first resource reload; the atlas marker appears when
    # the block/item atlases are built. Require it to stay quiet for a few seconds to skip the first
    # partial reloads.
    param([string]$LogPath, [int]$HoldSeconds = 8, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $seenAt = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $LogPath) {
            $content = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
            if ($content -match 'Created:.*atlas') {
                if ($null -eq $seenAt) { $seenAt = Get-Date }
                elseif (((Get-Date) - $seenAt).TotalSeconds -ge $HoldSeconds) { return $true }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-DeferredJoin {
    # Drive the vanilla menus (Multiplayer -> Direct Connection -> address -> Join Server) so the client
    # connects after the game finished loading, the same way a player does. PostMessage keeps it
    # independent of window focus.
    param([string]$ClientName, [string]$GameLogPath, [string]$CaptureDir, [string]$ServerAddress, [int]$ServerPort)

    if (-not (Wait-ResourceLoadComplete -LogPath $GameLogPath)) {
        Write-Host "[$ClientName] resource reload did not complete before the deferred join"
        return $false
    }

    $game = Wait-GameWindow -TimeoutSeconds 60
    if (-not $game) {
        Write-Host "[$ClientName] Minecraft window not found for deferred join"
        return $false
    }
    $handle = $game.MainWindowHandle
    Write-Host "[$ClientName] deferred join into $($game.MainWindowTitle)"

    $rect = New-Object TestJobNativeMethods+RECT
    if (-not [TestJobNativeMethods]::GetClientRect($handle, [ref]$rect)) {
        Write-Host "[$ClientName] GetClientRect failed for deferred join"
        return $false
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    # PowerShell is not per-monitor DPI aware, so GetClientRect (and any bitmap sized from it) comes
    # back in virtualized pixels while the game window, its framebuffer and the coordinates it expects
    # in window messages are physical. Scale by the window's DPI before doing any menu geometry.
    $dpi = [TestJobNativeMethods]::GetDpiForWindow($handle)
    if ($dpi -le 0) { $dpi = 96 }
    $dpiScale = $dpi / 96.0
    $width = [int][Math]::Round($width * $dpiScale)
    $height = [int][Math]::Round($height * $dpiScale)
    # Minecraft picks the largest GUI scale (1..4) whose virtual resolution still fits 320x240
    # (see Window.calculateScale / Options.guiScale == auto). The menu coordinates below are in GUI
    # pixels, so the scale has to be derived from the window instead of assumed.
    $guiScale = 1
    while ($guiScale -lt 4 -and
           [Math]::Floor($width / ($guiScale + 1)) -ge 320 -and
           [Math]::Floor($height / ($guiScale + 1)) -ge 240) { $guiScale++ }
    $guiWidth = [int][Math]::Floor($width / $guiScale)
    $guiHeight = [int][Math]::Floor($height / $guiScale)
    Write-Host "[$ClientName] join window ${width}x${height} (dpi $dpi), gui ${guiWidth}x${guiHeight} at scale $guiScale"

    # Vanilla menu geometry (1.13 - 1.20): the title screen puts Multiplayer at
    # height/4 + 72 (20 px tall), the multiplayer list puts Direct Connection in the middle of the
    # bottom row at height - 52, and the direct connect screen has the address box at y = 116 with
    # Join Server at height/4 + 108. All values are GUI pixels; +scale/2 targets the button centre.
    $centerX = [int]($guiWidth / 2 * $guiScale + $guiScale / 2)
    $multiplayerY = [int](($guiHeight / 4 + 82) * $guiScale + $guiScale / 2)
    $directConnectY = [int](($guiHeight - 42) * $guiScale + $guiScale / 2)
    $addressFieldY = [int](126 * $guiScale + $guiScale / 2)
    $joinServerY = [int](($guiHeight / 4 + 118) * $guiScale + $guiScale / 2)

    [void][TestJobNativeMethods]::ShowWindow($handle, 9)
    [void][TestJobNativeMethods]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 500
    [void](Save-WindowCapture -Handle $handle -Path (Join-Path $CaptureDir 'ui-0-title.png'))

    Send-GuiClick -Handle $handle -X $centerX -Y $multiplayerY
    Start-Sleep -Seconds 3
    [void](Save-WindowCapture -Handle $handle -Path (Join-Path $CaptureDir 'ui-1-multiplayer.png'))

    Send-GuiClick -Handle $handle -X $centerX -Y $directConnectY
    Start-Sleep -Seconds 2
    [void](Save-WindowCapture -Handle $handle -Path (Join-Path $CaptureDir 'ui-2-direct-connect.png'))

    Send-GuiClick -Handle $handle -X $centerX -Y $addressFieldY
    Send-GuiText -Handle $handle -Text "${ServerAddress}:$ServerPort"
    Start-Sleep -Seconds 1
    [void](Save-WindowCapture -Handle $handle -Path (Join-Path $CaptureDir 'ui-3-address.png'))

    Send-GuiClick -Handle $handle -X $centerX -Y $joinServerY
    Start-Sleep -Seconds 3
    [void](Save-WindowCapture -Handle $handle -Path (Join-Path $CaptureDir 'ui-4-joining.png'))

    # Give the connect a moment and report whether the client actually reached the server, so a
    # coordinate regression is visible in the job log instead of only as a missing skin.
    $connectedAt = (Get-Date).AddSeconds(30)
    $connected = $false
    while ((Get-Date) -lt $connectedAt) {
        if ((Test-Path -LiteralPath $GameLogPath) -and
            (Get-Content -LiteralPath $GameLogPath -Raw -ErrorAction SilentlyContinue) -match 'Connecting to') {
            $connected = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "[$ClientName] deferred join submitted for ${ServerAddress}:$ServerPort (client connecting: $connected)"
    return $connected
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

# Clients listed here were started without --server/--quickPlayMultiplayer and have to join through the
# game menus (see Prepare-TestVersion.ps1).
$DeferredJoinClients = @()
$deferredJoinFile = Join-Path $ClientDir 'deferred-join.txt'
if (Test-Path -LiteralPath $deferredJoinFile) {
    $DeferredJoinClients = @(Get-Content -LiteralPath $deferredJoinFile | Where-Object { $_ })
}
$DeferredJoinCaptureDir = Join-Path $ClientLogDir 'deferred-join'

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

        if ($DeferredJoinClients -contains $clientName) {
            # Use the client's own stdout log: run/client/logs/latest.log still holds the previous
            # client's content until this client writes its own.
            [void](Invoke-DeferredJoin -ClientName $clientName -GameLogPath $clientOut `
                -CaptureDir $DeferredJoinCaptureDir -ServerAddress $ServerAddress -ServerPort $ServerPort)
        }

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
