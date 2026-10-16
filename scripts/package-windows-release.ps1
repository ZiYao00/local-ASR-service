[CmdletBinding()]
param(
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$')][string]$Version = 'v0.5.0-beta',
    [ValidatePattern('^[A-Za-z0-9-]*$')][string]$BuildSuffix = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'prepare-ffmpeg.ps1') -Mode verify
& (Join-Path $PSScriptRoot 'release-audit.ps1') -IncludeHistory | Out-Null

$files = New-Object 'System.Collections.Generic.List[object]'
$single = @('README.md','AGENTS.md','LICENSE','THIRD_PARTY.md','deployment-report.md',
    'requirements-cpu.txt','requirements-aligner.txt','service.bat','.gitignore')
foreach ($rel in $single) {
    $src = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Required distribution file missing: $src" }
    $files.Add([pscustomobject]@{ Source = $src; Entry = $rel })
}
$includes = [ordered]@{
    'bin' = @('.cmd')
    'config' = @('.json', '.ps1')
    'docs' = @('.md')
    'licenses' = @('.md', '.txt')
    'scripts' = @('.ps1', '.py')
    'service' = @('.py')
    'tests' = @('.py')
}
foreach ($folder in $includes.Keys) {
    $sourceRoot = Join-Path $root $folder
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse)) {
        if ($file.Extension.ToLowerInvariant() -notin $includes[$folder] -or $file.Name -eq 'local.json') { continue }
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
        $files.Add([pscustomobject]@{ Source = $file.FullName; Entry = $relative })
    }
}
$binaryRoot = Join-Path $root 'tools\ffmpeg'
foreach ($name in @('bin\ffmpeg.exe','bin\ffprobe.exe','distribution.json','licenses\LICENSE.txt')) {
    $file = Join-Path $binaryRoot $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing FFmpeg component: $file" }
    $files.Add([pscustomobject]@{ Source = $file; Entry = ('tools/ffmpeg/' + $name.Replace('\','/')) })
}

$releaseDir = Join-Path $root 'runtime\release'
if (-not (Test-Path -LiteralPath $releaseDir)) { $null = New-Item -ItemType Directory -Path $releaseDir }
$suffix = if ($BuildSuffix) { "-$BuildSuffix" } else { '' }
$archive = Join-Path $releaseDir ("local-ASR-service-{0}{1}-windows-x64.zip" -f $Version, $suffix)
if (Test-Path -LiteralPath $archive) { throw "Refusing to overwrite existing Release package: $archive" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($archive, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entry = $zip.CreateEntry(("local-ASR-service/{0}" -f $file.Entry), [System.IO.Compression.CompressionLevel]::Optimal)
        $sourceStream = [System.IO.File]::OpenRead($file.Source)
        $targetStream = $entry.Open()
        try { $sourceStream.CopyTo($targetStream) } finally { $targetStream.Dispose(); $sourceStream.Dispose() }
    }
} finally { $zip.Dispose(); $stream.Dispose() }

Write-Host "[OK] Windows distribution: $archive"
Write-Host ("[OK] Files: {0}, SHA256: {1}" -f $files.Count, (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant())
Write-Host '[Notice] Upload/publish require separate authorization.'
