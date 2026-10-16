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
$root = $config.Root
$python = Join-Path $root '.venv-qwen3-asr\Scripts\python.exe'
$modelPath = Join-Path $root 'models\qwen3-asr-0.6b'
$pythonScript = Join-Path $PSScriptRoot 'qwen3-asr-infer.py'

# This experimental model is checked only when the experiment is explicitly run.
# Checking the complete snapshot also resumes a partially downloaded model.
if (Test-Path -LiteralPath $python -PathType Leaf) {
    & (Join-Path $PSScriptRoot 'prepare-models.ps1') -Mode qwen-asr
}
foreach ($requiredPath in @($python, $pythonScript, $modelPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required Qwen3-ASR test component was not found: $requiredPath"
    }
}

$inputItem = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputItem.PSIsContainer) {
    throw "Input must be a single media file, not a directory: $($inputItem.FullName)"
}
if ($inputItem.Extension.ToLowerInvariant() -notin @('.wav', '.mp3', '.flac', '.m4a', '.ogg', '.webm', '.mp4', '.mov', '.mkv')) {
    throw "Unsupported input extension: $($inputItem.Extension)"
}

$outputDirectory = if ($UseProjectOutput) {
    $config.Output
} else {
    Join-Path (Split-Path -Parent $inputItem.FullName) $config.SiblingOutputFolder
}
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
$outputDirectory = (Get-Item -LiteralPath $outputDirectory -ErrorAction Stop).FullName
$outputBaseName = '{0}_qwen3-asr-0.6b_CPU' -f $inputItem.BaseName
$outputBase = Join-Path $outputDirectory $outputBaseName
$textFile = "$outputBase.txt"
$jsonFile = "$outputBase.json"
foreach ($outputPath in @($textFile, $jsonFile)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Refusing to overwrite existing Qwen3-ASR output: $outputPath"
    }
}

$ffmpeg = Get-FunAsrBundledTool -Name ffmpeg

$env:MODELSCOPE_CACHE = Join-Path $root 'models\modelscope-qwen3-asr'
$env:HF_HOME = Join-Path $root 'runtime\cache\huggingface-qwen3-asr'
$env:HF_HUB_OFFLINE = '1'
$env:TEMP = $config.Temp
$env:TMP = $config.Temp
$env:PYTHONUTF8 = '1'
$temporaryWav = Join-Path $config.Temp (([System.IO.Path]::GetRandomFileName()) + '.wav')
$ffmpegSeconds = 0.0
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $ffmpegTimer = [System.Diagnostics.Stopwatch]::StartNew()
    & $ffmpeg -hide_banner -loglevel error -n -i $inputItem.FullName -vn -ac 1 -ar 16000 -c:a pcm_s16le $temporaryWav
    $ffmpegTimer.Stop()
    $ffmpegSeconds = [math]::Round($ffmpegTimer.Elapsed.TotalSeconds, 3)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryWav -PathType Leaf)) {
        throw "FFmpeg could not extract 16 kHz mono WAV from '$($inputItem.FullName)'."
    }

    & $python $pythonScript --model $modelPath --audio $temporaryWav --result-json $jsonFile --language Chinese
    if ($LASTEXITCODE -ne 0) {
        throw "Qwen3-ASR inference failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $jsonFile -PathType Leaf)) {
        throw "Qwen3-ASR did not write the expected JSON result: $jsonFile"
    }

    $result = Get-Content -LiteralPath $jsonFile -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($result.text)) {
        throw 'Qwen3-ASR result has no text; TXT output was not written.'
    }
    [System.IO.File]::WriteAllText($textFile, ($result.text.Trim() + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $totalTimer.Stop()

    return [pscustomobject]@{
        Status               = 'completed'
        Model                = $result.model
        Runtime              = $result.runtime
        Input                = $inputItem.FullName
        TextFile             = $textFile
        JsonFile             = $jsonFile
        FfmpegSeconds        = $ffmpegSeconds
        ModelLoadSeconds     = $result.model_load_seconds
        TranscriptionSeconds = $result.transcription_seconds
        TotalSeconds         = [math]::Round($totalTimer.Elapsed.TotalSeconds, 3)
        Language             = $result.language
        TextCharacters       = $result.text.Trim().Length
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryWav -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryWav
    }
}
