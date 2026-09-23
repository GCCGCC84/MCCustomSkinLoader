Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

if (-not ('CslDiagnosticWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CslDiagnosticWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
}
'@
}

function Send-DiagnosticClick {
    param([IntPtr]$Handle, [int]$X, [int]$Y)
    $point = [IntPtr](($Y -shl 16) -bor ($X -band 0xffff))
    [CslGameTest.Native]::PostMessage($Handle, 0x0200, [IntPtr]::Zero, $point) | Out-Null
    Start-Sleep -Milliseconds 150
    [CslGameTest.Native]::PostMessage($Handle, 0x0201, [IntPtr]1, $point) | Out-Null
    Start-Sleep -Milliseconds 150
    [CslGameTest.Native]::PostMessage($Handle, 0x0202, [IntPtr]::Zero, $point) | Out-Null
}

function Invoke-DiagnosticJoin {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [string]$ServerHost = '127.0.0.1',
        [int]$ServerPort = 25565,
        [Parameter(Mandatory)][string]$ScreenshotDir
    )
    $rect = New-Object CslDiagnosticWindow+Rect
    if (-not [CslDiagnosticWindow]::GetClientRect($Handle, [ref]$rect)) { throw 'GetClientRect failed' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $guiWidth = [Math]::Ceiling($width / 2.0)
    $guiHeight = [Math]::Ceiling($height / 2.0)
    $scaleX = $width / $guiWidth
    $scaleY = $height / $guiHeight
    New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
    Set-GameWindowForeground -Handle $Handle
    Write-Host "Deferred join: client=${width}x${height}, gui=${guiWidth}x${guiHeight}"
    Save-WindowScreenshot -Handle $Handle -Path (Join-Path $ScreenshotDir 'ui-0-title.png') | Out-Null

    Send-DiagnosticClick -Handle $Handle -X ([int]($width / 2)) -Y ([int](($guiHeight / 4 + 82) * $scaleY))
    Start-Sleep -Seconds 3
    Save-WindowScreenshot -Handle $Handle -Path (Join-Path $ScreenshotDir 'ui-1-multiplayer.png') | Out-Null

    Send-DiagnosticClick -Handle $Handle -X ([int]($width / 2)) -Y ([int](($guiHeight - 42) * $scaleY))
    Start-Sleep -Seconds 2
    Save-WindowScreenshot -Handle $Handle -Path (Join-Path $ScreenshotDir 'ui-2-direct-connect.png') | Out-Null

    Send-DiagnosticClick -Handle $Handle -X ([int]($width / 2)) -Y ([int](126 * $scaleY))
    $address = "${ServerHost}:$ServerPort"
    foreach ($character in $address.ToCharArray()) {
        [CslGameTest.Native]::PostMessage($Handle, 0x0102, [IntPtr][int]$character, [IntPtr]1) | Out-Null
        Start-Sleep -Milliseconds 70
    }
    Start-Sleep -Seconds 1
    Save-WindowScreenshot -Handle $Handle -Path (Join-Path $ScreenshotDir 'ui-3-address.png') | Out-Null

    Send-DiagnosticClick -Handle $Handle -X ([int]($width / 2)) -Y ([int](($guiHeight / 4 + 118) * $scaleY))
    Start-Sleep -Seconds 3
    Save-WindowScreenshot -Handle $Handle -Path (Join-Path $ScreenshotDir 'ui-4-joining.png') | Out-Null
    Write-Host "Deferred join submitted for $address"
}

Export-ModuleMember -Function Invoke-DiagnosticJoin
