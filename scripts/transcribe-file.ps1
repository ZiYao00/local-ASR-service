[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,
    [switch]$UseProjectOutput
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

$outputBaseName = '{0}_sensevoice-small_{1}' -f [System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name), $health.device.ToUpperInvariant()
$textPath = Join-Path $outputDirectory "$outputBaseName.txt"
$possibleSrtPath = Join-Path $outputDirectory "$outputBaseName.srt"
foreach ($outputPath in @($textPath, $possibleSrtPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Refusing to overwrite an existing output file: $outputPath"
    }
}

$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
$result = ((& $cli transcribe $inputItem.FullName) -join [Environment]::NewLine) | ConvertFrom-Json
$totalTimer.Stop()

if ($result.status -ne 'ok' -or [string]::IsNullOrWhiteSpace($result.text)) {
    throw 'Transcription result is empty or unsuccessful.'
}

[System.IO.File]::WriteAllText($textPath, $result.text.Trim() + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$segments = @($result.segments | Where-Object { $null -ne $_ })
$validSegments = $segments.Count -gt 0 -and @($segments | Where-Object {
    $_.PSObject.Properties.Name -contains 'start' -and $_.PSObject.Properties.Name -contains 'end' -and
    $null -ne $_.start -and $null -ne $_.end -and -not [string]::IsNullOrWhiteSpace($_.text)
}).Count -eq $segments.Count

$srtPath = $null
$segmentsPunctuated = ($result.PSObject.Properties.Name -contains 'segments_punctuated') -and [bool]$result.segments_punctuated
if ($validSegments) {
    $formatTimestamp = {
        param([TimeSpan]$value)
        '{0:00}:{1:00}:{2:00},{3:000}' -f [math]::Floor($value.TotalHours), $value.Minutes, $value.Seconds, $value.Milliseconds
    }
    $blocks = for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        $start = [TimeSpan]::FromSeconds([double]$segment.start)
        $end = [TimeSpan]::FromSeconds([double]$segment.end)
        "{0}`r`n{1} --> {2}`r`n{3}" -f ($index + 1), (& $formatTimestamp $start), (& $formatTimestamp $end), $segment.text.Trim()
    }
    $srtPath = $possibleSrtPath
    [System.IO.File]::WriteAllText($srtPath, (($blocks -join "`r`n`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

[pscustomobject]@{
    Status               = 'completed'
    Input                = $inputItem.FullName
    TextFile             = $textPath
    SrtFile              = $srtPath
    AudioDurationSeconds = $result.duration
    TotalSeconds         = [math]::Round($totalTimer.Elapsed.TotalSeconds, 3)
    TextCharacters       = $result.text.Length
    SegmentCount         = $segments.Count
    SegmentsPunctuated   = $segmentsPunctuated
}
