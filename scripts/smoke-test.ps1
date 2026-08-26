[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'input\test1.mp4')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cli = Join-Path $PSScriptRoot 'asr.ps1'
$inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputFile.PSIsContainer) {
    throw "Smoke-test input must be a file: $($inputFile.FullName)"
}

$health = ((& $cli health) -join [Environment]::NewLine) | ConvertFrom-Json
if ($health.status -ne 'ok' -or -not $health.ready) {
    throw 'CLI health result is not ready.'
}
if (-not $health.vad -or -not $health.punctuation) {
    throw 'Required VAD/punctuation capabilities are not enabled.'
}

$models = ((& $cli models) -join [Environment]::NewLine) | ConvertFrom-Json
if (@($models.api_models) -notcontains 'custom') {
    throw 'CLI model list does not expose the configured API model.'
}

$transcription = ((& $cli transcribe $inputFile.FullName) -join [Environment]::NewLine) | ConvertFrom-Json
if ($transcription.status -ne 'ok' -or [string]::IsNullOrWhiteSpace($transcription.text)) {
    throw 'CLI transcription result is empty or unsuccessful.'
}
if ([string]::IsNullOrWhiteSpace($transcription.raw_text)) {
    throw 'CLI transcription result does not contain raw_text.'
}
if ($null -eq $transcription.duration -or [double]$transcription.duration -le 0) {
    throw 'CLI transcription result does not contain a valid duration.'
}

[pscustomobject]@{
    Status = 'passed'
    Input = $inputFile.FullName
    Model = $transcription.model
    TextCharacters = $transcription.text.Length
    RawTextCharacters = $transcription.raw_text.Length
    SegmentCount = @($transcription.segments).Count
    DurationSeconds = $transcription.duration
    ApiModels = @($models.api_models) -join ', '
}
