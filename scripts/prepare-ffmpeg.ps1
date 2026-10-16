[CmdletBinding()]
param([ValidateSet('prepare', 'verify')][string]$Mode = 'prepare')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'config\ffmpeg-distribution.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$bin = Join-Path $root 'tools\ffmpeg\bin'
$ffmpeg = Join-Path $bin 'ffmpeg.exe'
$ffprobe = Join-Path $bin 'ffprobe.exe'
$receipt = Join-Path (Split-Path -Parent $bin) 'distribution.json'

function Get-FfmpegIdentity {
    param([Parameter(Mandatory)][string]$Exe)
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $Exe
    $p.StartInfo.Arguments = '-version'
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    try {
        $null = $p.Start()
        $result = $p.StandardOutput.ReadToEnd()
        $errors = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0 -or -not ($result -match 'ffmpeg version|ffprobe version')) {
            throw "FFmpeg executable verification failed: $Exe $errors"
        }
        if ($result -match '--enable-(gpl|nonfree)') {
            throw "FFmpeg build enables GPL/nonfree components: $Exe"
        }
        $expectedRevision = 'N-127032-g6ae491a26c'
        if (-not $result.Contains($expectedRevision)) {
            throw "Unexpected FFmpeg revision in $Exe; expected $expectedRevision."
        }
        return $result
    } finally {
        $p.Dispose()
    }
}

function Assert-LocalFFmpeg {
    foreach ($file in @($ffmpeg, $ffprobe)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Project FFmpeg executable is missing: $file"
        }
        $null = Get-FfmpegIdentity -Exe $file
    }
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
        throw "Bundled FFmpeg distribution receipt is missing: $receipt"
    }
    $installed = Get-Content -LiteralPath $receipt -Raw -Encoding utf8 | ConvertFrom-Json
    if ($installed.archiveSha256 -ne $manifest.archiveSha256) {
        throw 'Bundled FFmpeg receipt does not match the pinned distribution manifest.'
    }
}

if ($Mode -eq 'verify') {
    Assert-LocalFFmpeg
    Write-Host '[OK] Project FFmpeg and ffprobe are available (pinned LGPL build).'
    return
}
if ((Test-Path -LiteralPath $ffmpeg) -and (Test-Path -LiteralPath $ffprobe) -and (Test-Path -LiteralPath $receipt)) {
    Assert-LocalFFmpeg
    Write-Host '[OK] Reusing verified project FFmpeg; no download needed.'
    return
}

if (-not (Test-Path -LiteralPath $bin)) { $null = New-Item -ItemType Directory -Path $bin -Force }
$cacheDir = Join-Path $root 'runtime\downloads'
if (-not (Test-Path -LiteralPath $cacheDir)) { $null = New-Item -ItemType Directory -Path $cacheDir -Force }
$archive = Join-Path $cacheDir $manifest.archiveName
if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
    (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.archiveSha256) {
    $temporaryArchive = "$archive.partial"
    if (Test-Path -LiteralPath $temporaryArchive) {
        throw "An incomplete FFmpeg download exists at $temporaryArchive. Inspect it before retrying; it will not be overwritten."
    }
    Write-Host "[Download] FFmpeg LGPL Windows x64 ($($manifest.releaseTag))..."
    Invoke-WebRequest -Uri $manifest.archiveUrl -OutFile $temporaryArchive -UseBasicParsing -MaximumRedirection 8
    $hash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $manifest.archiveSha256) {
        throw "FFmpeg archive checksum mismatch. Expected $($manifest.archiveSha256), got $hash. No binaries were installed."
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.archiveSha256) {
    throw 'Cached archive is not the approved pinned build.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($filename in @('ffmpeg.exe', 'ffprobe.exe')) {
        $items = @($zip.Entries | Where-Object { $_.FullName -match "(^|/)bin/$filename$" })
        if ($items.Count -ne 1) { throw "Expected exactly one $filename inside pinned archive." }
        $target = Join-Path $bin $filename
        if (-not (Test-Path -LiteralPath $target)) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($items[0], $target, $false)
        }
    }
    $licenseDir = Join-Path $root 'tools\ffmpeg\licenses'
    if (-not (Test-Path -LiteralPath $licenseDir)) { $null = New-Item -ItemType Directory -Path $licenseDir }
    # Preserve upstream license texts when present, rather than rewriting them.
    foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match '(^|/)(LICENSE|COPYING|README)(\.[a-zA-Z0-9-]+)?$' -and $_.Length -gt 0 })) {
        $destination = Join-Path $licenseDir ($entry.Name)
        if (-not (Test-Path -LiteralPath $destination)) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
        }
    }
} finally {
    $zip.Dispose()
}
foreach ($file in @($ffmpeg, $ffprobe)) {
    $null = Get-FfmpegIdentity -Exe $file
}
$record = [ordered]@{
    provider = $manifest.provider
    releaseTag = $manifest.releaseTag
    archiveName = $manifest.archiveName
    archiveSha256 = $manifest.archiveSha256
    archiveUrl = $manifest.archiveUrl
    licenseInfo = $manifest.licenseInfo
    sourceCode = $manifest.sourceCode
}
[System.IO.File]::WriteAllText($receipt, ($record | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
Assert-LocalFFmpeg
Write-Host "[OK] Project FFmpeg prepared: $bin"
