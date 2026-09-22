# Downloads and deploys Mesa3D (llvmpipe software OpenGL) for Windows CI runs.

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Pinned Mesa3D release. Bump this together with the mesa cache key in
# .github/workflows/game-test.yml. The GitHub API is intentionally avoided:
# hosted runner IPs share a low unauthenticated rate limit.
$script:DefaultMesaVersion = '26.2.0'

function Get-SevenZipPath {
    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw '7z.exe was not found. Install 7-Zip or add it to PATH.'
}

function Get-LatestMesaVersion {
    $headers = @{ 'User-Agent' = 'CustomSkinLoader-GameTest/1.0' }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/pal1000/mesa-dist-win/releases/latest' `
        -Headers $headers -TimeoutSec 10
    return [string]$release.tag_name
}

function Install-Mesa3D {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$AdditionalDestination = @(),
        [string]$Version
    )

    New-Item -ItemType Directory -Force -Path $CacheDir, $Destination | Out-Null
    foreach ($extra in $AdditionalDestination) {
        New-Item -ItemType Directory -Force -Path $extra | Out-Null
    }

    $tag = $Version
    if (-not $tag) {
        $tag = $script:DefaultMesaVersion
    }

    $extractDir = Join-Path $CacheDir "mesa3d-$tag"
    $x64Dir = Join-Path $extractDir 'x64'
    $openglDll = Join-Path $x64Dir 'opengl32.dll'

    if (-not (Test-Path -LiteralPath $openglDll)) {
        $archiveName = "mesa3d-$tag-release-msvc.7z"
        $archive = Join-Path $CacheDir $archiveName
        if (-not (Test-Path -LiteralPath $archive)) {
            $url = "https://github.com/pal1000/mesa-dist-win/releases/download/$tag/$archiveName"
            Write-Host "Downloading Mesa3D $tag ..."
            $downloaded = $false
            for ($attempt = 1; $attempt -le 8 -and -not $downloaded; $attempt++) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile "$archive.part" -TimeoutSec 10 -HttpVersion 1.1 | Out-Null
                    Move-Item -LiteralPath "$archive.part" -Destination $archive -Force
                    $downloaded = $true
                } catch {
                    Remove-Item -LiteralPath "$archive.part" -Force -ErrorAction SilentlyContinue
                    if ($attempt -eq 8) {
                        throw "Failed to download Mesa3D from '$url': $_"
                    }
                    Start-Sleep -Seconds (2 * $attempt)
                }
            }
        }

        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

        $sevenZip = Get-SevenZipPath
        Write-Host "Extracting Mesa3D $tag ..."
        & $sevenZip x $archive "-o$extractDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $openglDll)) {
            throw "Failed to extract Mesa3D archive '$archive'"
        }
    }

    foreach ($dll in @('opengl32.dll', 'libgallium_wgl.dll', 'libglapi.dll', 'dxil.dll')) {
        $source = Join-Path $x64Dir $dll
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $dll) -Force
            foreach ($extra in $AdditionalDestination) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $extra $dll) -Force
            }
        }
    }

    return [pscustomobject]@{
        Version = $tag
        Root    = $x64Dir
        DeployedDlls = @(Get-ChildItem -LiteralPath $x64Dir -Filter '*.dll' | ForEach-Object { $_.Name })
    }
}

function Get-MesaEnvironment {
    param([string]$MesaRoot)

    $environment = @{
        GALLIUM_DRIVER     = 'llvmpipe'
        MESA_LOADER_DRIVER_OVERRIDE = 'llvmpipe'
        LIBGL_ALWAYS_SOFTWARE = '1'
    }
    if ($MesaRoot) {
        $environment['PATH'] = "$MesaRoot;$env:PATH"
    }
    return $environment
}

