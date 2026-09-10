[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,
    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$TranscriptPath,
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,
    [switch]$UseProjectOutput,
    [string]$Language = 'zh',
    [ValidateSet('voiceover', 'tutorial')]
    [string]$Preset = 'voiceover',
    [switch]$AllowScriptMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig
$cli = Join-Path $PSScriptRoot 'asr.ps1'

$inputItem = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputItem.PSIsContainer) {
    throw "Input must be a single media file, not a directory: $($inputItem.FullName)"
}
$transcriptItem = Get-Item -LiteralPath $TranscriptPath -ErrorAction Stop
if ($transcriptItem.PSIsContainer -or $transcriptItem.Extension.ToLowerInvariant() -ne '.txt') {
    throw "Transcript must be a single UTF-8 .txt file: $($transcriptItem.FullName)"
}

if ($UseProjectOutput -and $PSBoundParameters.ContainsKey('OutputDirectory')) {
    throw 'Use either -UseProjectOutput or -OutputDirectory, not both.'
}

$outputDirectory = if ($UseProjectOutput) {
    $config.Output
} elseif ($PSBoundParameters.ContainsKey('OutputDirectory')) {
    $OutputDirectory
} else {
    Join-Path (Split-Path -Parent $inputItem.FullName) $config.SiblingOutputFolder
}
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
$outputDirectory = (Get-Item -LiteralPath $outputDirectory -ErrorAction Stop).FullName

$health = ((& $cli health) -join [Environment]::NewLine) | ConvertFrom-Json
if ($health.status -ne 'ok' -or -not $health.ready) {
    throw 'local-ASR-service is not ready.'
}
if ($null -eq $health.forced_alignment -or -not [bool]$health.forced_alignment.ready) {
    throw 'Qwen3 Forced Aligner is not ready. Check the alignment runtime and local model in health output.'
}

$outputBaseName = '{0}_aligned_{1}' -f [System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name), $Preset
$srtPath = Join-Path $outputDirectory "$outputBaseName.srt"
$jsonPath = Join-Path $outputDirectory "$outputBaseName.json"
foreach ($outputPath in @($srtPath, $jsonPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Refusing to overwrite an existing output file: $outputPath"
    }
}

$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
$rawResult = if ($AllowScriptMismatch) {
    & $cli align $inputItem.FullName $transcriptItem.FullName -Language $Language -Preset $Preset -AllowScriptMismatch
} else {
    & $cli align $inputItem.FullName $transcriptItem.FullName -Language $Language -Preset $Preset
}
$result = (($rawResult) -join [Environment]::NewLine) | ConvertFrom-Json
$totalTimer.Stop()

if ($result.status -ne 'ok' -or [string]::IsNullOrWhiteSpace($result.srt)) {
    throw 'Alignment result is empty or unsuccessful.'
}

[System.IO.File]::WriteAllText($srtPath, [string]$result.srt, [System.Text.UTF8Encoding]::new($true))
[System.IO.File]::WriteAllText(
    $jsonPath,
    ((ConvertTo-Json -InputObject $result -Depth 20) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Status                 = 'completed'
    Input                  = $inputItem.FullName
    Transcript             = $transcriptItem.FullName
    SrtFile                = $srtPath
    JsonFile               = $jsonPath
    Preset                 = $Preset
    AudioDurationSeconds   = $result.duration
    ScriptMatchScore       = $result.script_match.score
    ScriptMatchStatus      = $result.script_match.status
    AlignedUnits           = $result.aligned_units
    SubtitleCount          = $result.subtitle_summary.cue_count
    MinSubtitleSeconds     = $result.subtitle_summary.min_duration
    MaxSubtitleSeconds     = $result.subtitle_summary.max_duration
    AverageSubtitleSeconds = $result.subtitle_summary.average_duration
    AlignmentSeconds       = $result.performance.alignment_seconds
    TotalSeconds           = [math]::Round($totalTimer.Elapsed.TotalSeconds, 3)
}
