[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,
    [switch]$UseProjectOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig
$senseScript = Join-Path $PSScriptRoot 'transcribe-file.ps1'
$qwenScript = Join-Path $PSScriptRoot 'test-qwen3-asr.ps1'

foreach ($requiredPath in @($senseScript, $qwenScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required comparison component was not found: $requiredPath"
    }
}

$inputItem = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputItem.PSIsContainer) {
    throw "Input must be a single media file, not a directory: $($inputItem.FullName)"
}

$ffprobe = Get-FunAsrBundledTool -Name ffprobe
$durationRaw = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $inputItem.FullName
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($durationRaw)) {
    throw "ffprobe could not read duration from '$($inputItem.FullName)'."
}
$durationSeconds = [double]::Parse($durationRaw.Trim(), [Globalization.CultureInfo]::InvariantCulture)

$outputDirectory = if ($UseProjectOutput) {
    $config.Output
} else {
    Join-Path (Split-Path -Parent $inputItem.FullName) $config.SiblingOutputFolder
}
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
$outputDirectory = (Get-Item -LiteralPath $outputDirectory -ErrorAction Stop).FullName

function Get-CompletedResult {
    param(
        [Parameter(Mandatory)]
        [object[]]$InvocationOutput,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $completed = @($InvocationOutput | Where-Object {
        $_.PSObject.Properties['Status'] -and $_.Status -eq 'completed'
    })
    if ($completed.Count -ne 1) {
        throw "$Name did not return exactly one completed result object."
    }
    return $completed[0]
}

function Format-Number {
    param([Nullable[double]]$Value)
    if ($null -eq $Value) { return 'N/A' }
    return ([double]$Value).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name)
$reportPath = Join-Path $outputDirectory ("{0}_ASR-comparison.md" -f $baseName)
if (Test-Path -LiteralPath $reportPath) {
    throw "Refusing to overwrite an existing comparison report: $reportPath"
}

$senseInvocation = @(& $senseScript $inputItem.FullName -UseProjectOutput:$UseProjectOutput)
$senseResult = Get-CompletedResult -InvocationOutput $senseInvocation -Name 'SenseVoiceSmall'
$qwenInvocation = @(& $qwenScript $inputItem.FullName -UseProjectOutput:$UseProjectOutput)
$qwenResult = Get-CompletedResult -InvocationOutput $qwenInvocation -Name 'Qwen3-ASR-0.6B'

foreach ($resultPath in @($senseResult.TextFile, $qwenResult.TextFile, $qwenResult.JsonFile)) {
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "Expected model output was not written: $resultPath"
    }
}

$senseText = (Get-Content -LiteralPath $senseResult.TextFile -Raw -Encoding utf8).Trim()
$qwenText = (Get-Content -LiteralPath $qwenResult.TextFile -Raw -Encoding utf8).Trim()
if ([string]::IsNullOrWhiteSpace($senseText) -or [string]::IsNullOrWhiteSpace($qwenText)) {
    throw 'One or more ASR outputs are empty.'
}

$senseTotalRtf = [double]$senseResult.TotalSeconds / $durationSeconds
$qwenTotalRtf = [double]$qwenResult.TotalSeconds / $durationSeconds
$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$segmentsPunctuated = if ($senseResult.PSObject.Properties.Name -contains 'SegmentsPunctuated') { [bool]$senseResult.SegmentsPunctuated } else { $false }

$report = @"
# ASR comparison: $baseName

Generated: $generatedAt

## Input

| Item | Value |
|---|---|
| File | $($inputItem.Name) |
| Size | $(([math]::Round($inputItem.Length / 1MB, 2)).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) MiB |
| Duration | $(Format-Number $durationSeconds) s |

## Performance

| Item | SenseVoiceSmall | Qwen3-ASR-0.6B |
|---|---:|---:|
| Total time | $(Format-Number ([double]$senseResult.TotalSeconds)) s | $(Format-Number ([double]$qwenResult.TotalSeconds)) s |
| Total RTF | $(Format-Number $senseTotalRtf) | $(Format-Number $qwenTotalRtf) |
| Text characters | $($senseText.Length) | $($qwenText.Length) |
| Qwen model load | N/A | $(Format-Number ([double]$qwenResult.ModelLoadSeconds)) s |
| Qwen transcription | N/A | $(Format-Number ([double]$qwenResult.TranscriptionSeconds)) s |
| SenseVoice segments | $($senseResult.SegmentCount) | N/A |
| SenseVoice segments punctuated | $segmentsPunctuated | N/A |

The SenseVoice path uses the resident shared service. The Qwen path starts a separate Python process and loads its model for each comparison run, so the total times are not equivalent lifecycle benchmarks.

## SenseVoiceSmall output

~~~text
$senseText
~~~

## Qwen3-ASR-0.6B output

~~~text
$qwenText
~~~

## Manual review

No automatic accuracy winner is reported. Compare both transcripts against the source media, especially names, domain terms, omissions, repetitions and punctuation.
"@

[System.IO.File]::WriteAllText($reportPath, $report, [System.Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Status = 'completed'
    Input = $inputItem.FullName
    ReportFile = $reportPath
    SenseVoiceTxt = $senseResult.TextFile
    SenseVoiceSrt = $senseResult.SrtFile
    QwenTxt = $qwenResult.TextFile
    QwenJson = $qwenResult.JsonFile
}
