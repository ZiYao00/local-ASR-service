[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    # The old input/test1.mp4 is private and does not exist after Git clone.
    # Generate a small deterministic spoken fixture on the user's Windows system.
    $fixtureDirectory = Join-Path $root 'runtime\test'
    if (-not (Test-Path -LiteralPath $fixtureDirectory)) {
        $null = New-Item -ItemType Directory -Path $fixtureDirectory
    }
    $InputPath = Join-Path $fixtureDirectory 'local-asr-first-run.wav'
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        try {
            Add-Type -AssemblyName System.Speech -ErrorAction Stop
            $speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
            try {
                $speaker.SetOutputToWaveFile($InputPath)
                $speaker.Speak('Hello. This is a local speech recognition test.')
                $speaker.SetOutputToNull()
            } finally {
                $speaker.Dispose()
            }
        } catch {
            throw "Windows system speech synthesis is unavailable. Pass -InputPath with a short voice recording to finish installation verification. $($_.Exception.Message)"
        }
    }
}
$cli = Join-Path $PSScriptRoot 'asr.ps1'
$inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputFile.Length -lt 4096) { throw "Smoke test media is too small or truncated: $($inputFile.FullName)" }
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

$lang = if ($inputFile.Name -eq 'local-asr-first-run.wav') { 'en' } else { 'zh' }
$transcription = ((& $cli transcribe $inputFile.FullName -Language $lang) -join [Environment]::NewLine) | ConvertFrom-Json
if ($transcription.status -ne 'ok' -or [string]::IsNullOrWhiteSpace($transcription.text)) {
    throw 'CLI transcription result is empty or unsuccessful.'
}
if ([string]::IsNullOrWhiteSpace($transcription.raw_text)) {
    throw 'CLI transcription result does not contain raw_text.'
}
if ($null -eq $transcription.duration -or [double]$transcription.duration -le 0) {
    throw 'CLI transcription result does not contain a valid duration.'
}
if ($transcription.PSObject.Properties.Name -notcontains 'segments_punctuated') {
    throw 'CLI transcription result does not expose segments_punctuated.'
}

[pscustomobject]@{
    Status = 'passed'
    Input = $inputFile.FullName
    Model = $transcription.model
    TextCharacters = $transcription.text.Length
    RawTextCharacters = $transcription.raw_text.Length
    SegmentCount = @($transcription.segments).Count
    SegmentsPunctuated = [bool]$transcription.segments_punctuated
    DurationSeconds = $transcription.duration
    ApiModels = @($models.api_models) -join ', '
}
