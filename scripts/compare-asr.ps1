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
if ($inputItem.Extension.ToLowerInvariant() -notin @('.wav', '.mp3', '.flac', '.m4a', '.ogg', '.webm', '.mp4', '.mov', '.mkv')) {
    throw "Unsupported input extension: $($inputItem.Extension)"
}

$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobe) {
    throw 'ffprobe was not found on PATH; it is required to record comparison video duration.'
}
$durationRaw = & $ffprobe.Source -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $inputItem.FullName
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

try {
    $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 10
} catch {
    throw "SenseVoiceSmall service is not reachable at $($config.BaseUrl): $($_.Exception.Message)"
}
$senseMode = if ($health.device -eq 'cuda') {
    'GPU'
} elseif ($health.device -eq 'cpu') {
    'CPU'
} else {
    throw "Unexpected SenseVoiceSmall runtime device: $($health.device)"
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputItem.Name)
$expectedOutputs = @(
    (Join-Path $outputDirectory ("{0}_sensevoice-small_{1}.txt" -f $baseName, $senseMode)),
    (Join-Path $outputDirectory ("{0}_sensevoice-small_{1}.srt" -f $baseName, $senseMode)),
    (Join-Path $outputDirectory ("{0}_qwen3-asr-0.6b_CPU.txt" -f $baseName)),
    (Join-Path $outputDirectory ("{0}_qwen3-asr-0.6b_CPU.json" -f $baseName)),
    (Join-Path $outputDirectory ("{0}_ASR-comparison.md" -f $baseName))
)
foreach ($path in $expectedOutputs) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite an existing comparison output: $path"
    }
}

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
    if ($null -eq $Value) {
        return 'N/A'
    }
    return ([double]$Value).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-PathOrMissing {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '未生成'
    }
    return $Path
}

# 保持核心脚本独立：当前版本分别执行各自已有的 FFmpeg 与 ASR 路径。
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
    throw 'One or more ASR outputs are empty; comparison report was not written.'
}

$senseApiRtf = [double]$senseResult.ApiSeconds / $durationSeconds
$senseTotalRtf = [double]$senseResult.TotalSeconds / $durationSeconds
$qwenAsrRtf = [double]$qwenResult.TranscriptionSeconds / $durationSeconds
$qwenTotalRtf = [double]$qwenResult.TotalSeconds / $durationSeconds
$reportPath = Join-Path $outputDirectory ("{0}_ASR-comparison.md" -f $baseName)
$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$report = @"
# ASR 对比报告：$baseName

生成时间：$generatedAt

## 视频信息

| 项目 | 值 |
|---|---|
| 文件名 | $($inputItem.Name) |
| 完整路径 | $($inputItem.FullName) |
| 文件大小 | $(([math]::Round($inputItem.Length / 1MB, 2)).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) MB |
| 视频时长 | $(Format-Number $durationSeconds) 秒 |

## 性能对比

| 项目 | SenseVoiceSmall CPU | Qwen3-ASR-0.6B CPU |
|---|---:|---:|
| FFmpeg 耗时 | $(Format-Number ([double]$senseResult.FfmpegSeconds)) 秒 | $(Format-Number ([double]$qwenResult.FfmpegSeconds)) 秒 |
| 模型加载 | 常驻服务，未计入单次请求 | $(Format-Number ([double]$qwenResult.ModelLoadSeconds)) 秒 |
| ASR 耗时 | $(Format-Number ([double]$senseResult.ApiSeconds)) 秒 | $(Format-Number ([double]$qwenResult.TranscriptionSeconds)) 秒 |
| ASR 实时倍率 | $(Format-Number $senseApiRtf) | $(Format-Number $qwenAsrRtf) |
| 本次总耗时 | $(Format-Number ([double]$senseResult.TotalSeconds)) 秒 | $(Format-Number ([double]$qwenResult.TotalSeconds)) 秒 |
| 总实时倍率 | $(Format-Number $senseTotalRtf) | $(Format-Number $qwenTotalRtf) |
| 输出字数 | $($senseText.Length) | $($qwenText.Length) |
| TXT | $(Format-PathOrMissing $senseResult.TextFile) | $(Format-PathOrMissing $qwenResult.TextFile) |
| SRT / JSON | $(Format-PathOrMissing $senseResult.SrtFile) | $(Format-PathOrMissing $qwenResult.JsonFile) |

说明：SenseVoiceSmall 为已常驻的共享服务；Qwen3-ASR 总耗时包括独立 Python 进程启动、包导入、模型加载、音频准备与转写。两列不能视作严格的同一生命周期延迟基准。

## SenseVoiceSmall 原始结果

~~~text
$senseText
~~~

## Qwen3-ASR-0.6B 原始结果

~~~text
$qwenText
~~~

## 人工质量判定

本报告不自动生成准确率或优劣结论。请结合原视频逐句比较两份原始结果，特别关注人名、口语、专业词、漏句、重复和标点。
"@

[System.IO.File]::WriteAllText($reportPath, $report, [System.Text.UTF8Encoding]::new($false))

return [pscustomobject]@{
    Status        = 'completed'
    Input         = $inputItem.FullName
    ReportFile    = $reportPath
    SenseVoiceTxt = $senseResult.TextFile
    SenseVoiceSrt = $senseResult.SrtFile
    QwenTxt       = $qwenResult.TextFile
    QwenJson      = $qwenResult.JsonFile
}
