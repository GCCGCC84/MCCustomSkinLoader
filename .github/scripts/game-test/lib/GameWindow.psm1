# Game window discovery, key injection, screenshot capture and skin pixel checks.

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

if (-not ('CslGameTest.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CslGameTest
{
    public static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern uint MapVirtualKey(uint code, uint mapType);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        public static List<IntPtr> FindWindows(uint[] processIds, string titleContains)
        {
            List<IntPtr> found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                {
                    return true;
                }

                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);
                bool processMatches = processIds == null || processIds.Length == 0 || Array.IndexOf(processIds, processId) >= 0;
                if (!processMatches)
                {
                    return true;
                }

                int length = GetWindowTextLength(hWnd);
                if (length <= 0)
                {
                    return true;
                }

                StringBuilder builder = new StringBuilder(length + 1);
                GetWindowText(hWnd, builder, builder.Capacity);
                string title = builder.ToString();
                if (string.IsNullOrEmpty(titleContains) || title.IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found.Add(hWnd);
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
}

$script:VirtualKeys = @{
    'F2' = 0x71
    'F5' = 0x74
    'F11' = 0x7A
    'ESCAPE' = 0x1B
}
$script:WmKeyDown = 0x0100
$script:WmKeyUp = 0x0101

function Get-ProcessTreeId {
    param([Parameter(Mandatory)][int]$RootId)

    $ids = New-Object System.Collections.Generic.List[uint32]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    $seen = @{}

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($seen.ContainsKey($current)) {
            continue
        }
        $seen[$current] = $true
        $ids.Add([uint32]$current)

        try {
            $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$current" -ErrorAction SilentlyContinue
            foreach ($child in @($children)) {
                $queue.Enqueue([int]$child.ProcessId)
            }
        } catch {
            # Process may have exited while walking the tree.
        }
    }
    return $ids.ToArray()
}

function Get-GameWindow {
    param(
        [uint32[]]$ProcessIds = @(),
        [string]$TitleLike = 'Minecraft',
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $handles = [CslGameTest.Native]::FindWindows($ProcessIds, $TitleLike)
        if ($handles.Count -gt 0) {
            return $handles[0]
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [IntPtr]::Zero
}

function Set-GameWindowForeground {
    param([Parameter(Mandatory)][IntPtr]$Handle)

    # SW_RESTORE then bring the window to the foreground so injected key events
    # and screen captures behave predictably.
    [CslGameTest.Native]::ShowWindow($Handle, 9) | Out-Null
    [CslGameTest.Native]::SetForegroundWindow($Handle) | Out-Null
    Start-Sleep -Seconds 1
}

function Send-GameKey {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][string]$Key,
        [int]$HoldMilliseconds = 80
    )

    $keyName = $Key.ToUpperInvariant()
    if (-not $script:VirtualKeys.ContainsKey($keyName)) {
        throw "Unsupported key '$Key'"
    }
    $virtualKey = [uint32]$script:VirtualKeys[$keyName]

    # lParam must carry repeat count 1 and the scan code: several input stacks
    # (LWJGL included) resolve the pressed key from the scan code.
    $scanCode = [int64][CslGameTest.Native]::MapVirtualKey($virtualKey, 0)
    $downLParam = [IntPtr](1 -bor ($scanCode -shl 16))
    $upLParam = [IntPtr](0xC0000001 -bor ($scanCode -shl 16))

    # Send an extra key-up first: if a previous injected key-up was lost, the
    # game would treat the key as still pressed and ignore the next key-down.
    [CslGameTest.Native]::PostMessage($Handle, $script:WmKeyUp, [IntPtr]$virtualKey, $upLParam) | Out-Null
    Start-Sleep -Milliseconds 100
    [CslGameTest.Native]::PostMessage($Handle, $script:WmKeyDown, [IntPtr]$virtualKey, $downLParam) | Out-Null
    Start-Sleep -Milliseconds $HoldMilliseconds
    [CslGameTest.Native]::PostMessage($Handle, $script:WmKeyUp, [IntPtr]$virtualKey, $upLParam) | Out-Null
}

function Wait-MinecraftScreenshot {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][datetime]$Since,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $Directory) {
            $file = Get-ChildItem -LiteralPath $Directory -Filter '*.png' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $Since } |
                Sort-Object -Property LastWriteTime -Descending |
                Select-Object -First 1
            if ($file) {
                # Wait until the game finished writing the file before returning.
                $lastSize = -1
                for ($i = 0; $i -lt 20; $i++) {
                    $currentSize = (Get-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue).Length
                    if ($null -ne $currentSize -and $currentSize -gt 0 -and $currentSize -eq $lastSize) {
                        return $file.FullName
                    }
                    $lastSize = $currentSize
                    Start-Sleep -Milliseconds 500
                }
                return $file.FullName
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Save-WindowScreenshot {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][string]$Path
    )

    Add-Type -AssemblyName System.Drawing
    $rect = New-Object CslGameTest.Native+RECT
    if (-not [CslGameTest.Native]::GetWindowRect($Handle, [ref]$rect)) {
        throw 'GetWindowRect failed'
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        throw "Invalid window rectangle ${width}x${height}"
    }

    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [System.Drawing.Size]::new($width, $height))
        } finally {
            $graphics.Dispose()
        }
        $directory = Split-Path -Parent $Path
        if ($directory) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
    return $Path
}

function Test-SkinScreenshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinPixels = 40,
        [int]$SampleStep = 2
    )

    Add-Type -AssemblyName System.Drawing
    $bitmap = $null
    for ($attempt = 1; $attempt -le 5 -and $null -eq $bitmap; $attempt++) {
        try {
            $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
        } catch {
            if ($attempt -eq 5) {
                throw
            }
            Start-Sleep -Seconds 1
        }
    }
    try {
        # Third-person front view keeps the player centered; only scan the middle
        # of the frame so world textures cannot influence the result.
        $xStart = [int]($bitmap.Width * 0.30)
        $xEnd = [int]($bitmap.Width * 0.70)
        $yStart = [int]($bitmap.Height * 0.20)
        $yEnd = [int]($bitmap.Height * 0.85)

        # The repository test skin is a green legacy skin. Count pixels where
        # green clearly dominates red and blue; flat-world grass (G - R ~ 51)
        # stays below the threshold.
        $matched = 0
        for ($y = $yStart; $y -lt $yEnd; $y += $SampleStep) {
            for ($x = $xStart; $x -lt $xEnd; $x += $SampleStep) {
                $color = $bitmap.GetPixel($x, $y)
                if ($color.G -ge 80 -and ($color.G - [Math]::Max($color.R, $color.B)) -ge 60) {
                    $matched++
                }
            }
        }
    } finally {
        $bitmap.Dispose()
    }

    return [pscustomobject]@{
        Width         = ($xEnd - $xStart)
        Height        = ($yEnd - $yStart)
        MatchedPixels = $matched
        Pass          = ($matched -ge $MinPixels)
    }
}


function Test-WorldScreenshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinSkyRatio = 0.35
    )

    # The "Loading terrain" and other loading screens use the dark title
    # background; a rendered world shows sky in the upper part of the frame.
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $width = $bitmap.Width
        $height = $bitmap.Height
        if ($width -le 0 -or $height -le 0) {
            return $false
        }

        $stepX = [Math]::Max(1, [int]($width / 24))
        $stepY = [Math]::Max(1, [int]($height / 12))
        $samples = 0
        $sky = 0
        for ($x = 0; $x -lt $width; $x += $stepX) {
            for ($y = 0; $y -lt [int]($height / 3); $y += $stepY) {
                $color = $bitmap.GetPixel($x, $y)
                $samples++
                if ($color.B -gt 150 -and $color.B -gt ($color.R + 40) -and $color.B -gt ($color.G + 10)) {
                    $sky++
                }
            }
        }
        if ($samples -eq 0) {
            return $false
        }
        return (($sky / $samples) -ge $MinSkyRatio)
    } finally {
        $bitmap.Dispose()
    }
}



