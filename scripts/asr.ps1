[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('transcribe', 'align', 'health', 'models')]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$InputPath,
    [Parameter(Position = 2)]
    [string]$TranscriptPath,
    [string]$Language = 'zh',
    [ValidateSet('voiceover', 'tutorial')]
    [string]$Preset = 'voiceover',
    [switch]$AllowScriptMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

function Write-StableJson {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    Write-Output (ConvertTo-Json -InputObject $Value -Depth 12 -Compress)
}

function Get-MediaContentType {
    param(
        [Parameter(Mandatory)]
        [string]$Extension
    )

    switch ($Extension.ToLowerInvariant()) {
        '.wav'  { return 'audio/wav' }
        '.mp3'  { return 'audio/mpeg' }
        '.flac' { return 'audio/flac' }
        '.m4a'  { return 'audio/mp4' }
        '.ogg'  { return 'audio/ogg' }
        '.webm' { return 'audio/webm' }
        '.mp4'  { return 'video/mp4' }
        '.mov'  { return 'video/quicktime' }
        '.mkv'  { return 'video/x-matroska' }
        default { return 'application/octet-stream' }
    }
}

function Invoke-Transcription {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$InputFile,
        [Parameter(Mandatory)]
        [string]$RequestedLanguage,
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $client = $null
    $form = $null
    $stream = $null
    $fileContent = $null

    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($Config.RequestTimeoutSeconds)
        $form = [System.Net.Http.MultipartFormDataContent]::new()
        $stream = [System.IO.File]::OpenRead($InputFile.FullName)
        $fileContent = [System.Net.Http.StreamContent]::new($stream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-MediaContentType -Extension $InputFile.Extension))
        $form.Add($fileContent, 'file', $InputFile.Name)
        $form.Add([System.Net.Http.StringContent]::new($Config.ModelAlias), 'model')
        $form.Add([System.Net.Http.StringContent]::new($RequestedLanguage), 'language')
        $form.Add([System.Net.Http.StringContent]::new('verbose_json'), 'response_format')

        $response = $client.PostAsync("$($Config.BaseUrl)/v1/audio/transcriptions", $form).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Transcription API returned HTTP $([int]$response.StatusCode): $body"
        }

        $result = $body | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($result.text)) {
            throw 'Transcription API returned no text.'
        }

        return $body.Trim()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($fileContent) { $fileContent.Dispose() }
        if ($form) { $form.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-Alignment {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$InputFile,
        [Parameter(Mandatory)]
        [string]$Transcript,
        [Parameter(Mandatory)]
        [string]$RequestedLanguage,
        [Parameter(Mandatory)]
        [string]$RequestedPreset,
        [Parameter(Mandatory)]
        [bool]$AllowMismatch,
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $client = $null
    $form = $null
    $stream = $null
    $fileContent = $null

    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($Config.RequestTimeoutSeconds)
        $form = [System.Net.Http.MultipartFormDataContent]::new()
        $stream = [System.IO.File]::OpenRead($InputFile.FullName)
        $fileContent = [System.Net.Http.StreamContent]::new($stream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-MediaContentType -Extension $InputFile.Extension))
        $form.Add($fileContent, 'file', $InputFile.Name)
        $form.Add([System.Net.Http.StringContent]::new($Transcript, [System.Text.Encoding]::UTF8), 'transcript')
        $form.Add([System.Net.Http.StringContent]::new($RequestedLanguage), 'language')
        $form.Add([System.Net.Http.StringContent]::new($RequestedPreset), 'preset')
        $form.Add([System.Net.Http.StringContent]::new($AllowMismatch.ToString().ToLowerInvariant()), 'allow_script_mismatch')

        $response = $client.PostAsync("$($Config.BaseUrl)/v1/audio/alignments", $form).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Alignment API returned HTTP $([int]$response.StatusCode): $body"
        }

        $result = $body | ConvertFrom-Json
        if ($result.status -ne 'ok' -or [string]::IsNullOrWhiteSpace($result.srt)) {
            throw 'Alignment API returned no usable SRT.'
        }
        return $body.Trim()
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($fileContent) { $fileContent.Dispose() }
        if ($form) { $form.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

switch ($Command) {
    'health' {
        $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec $config.RequestTimeoutSeconds
        Write-StableJson -Value ([ordered]@{
            status = $health.status
            ready = ($health.status -eq 'ok')
            service = if ($health.PSObject.Properties.Name -contains 'service') { $health.service } else { 'unknown' }
            model = if ($health.PSObject.Properties.Name -contains 'model') { $health.model } else { $config.ModelName }
            device = $health.device
            vad = if ($health.PSObject.Properties.Name -contains 'vad') { [bool]$health.vad } else { $false }
            punctuation = if ($health.PSObject.Properties.Name -contains 'punctuation') { [bool]$health.punctuation } else { $false }
            queue = if ($health.PSObject.Properties.Name -contains 'queue') { $health.queue } else { [ordered]@{ running = 0; waiting = 0 } }
            ffmpeg = if ($health.PSObject.Properties.Name -contains 'ffmpeg') { [bool]$health.ffmpeg } else { $null }
            forced_alignment = if ($health.PSObject.Properties.Name -contains 'forced_alignment') { $health.forced_alignment } else { $null }
        })
    }
    'models' {
        $models = Invoke-RestMethod -Uri "$($config.BaseUrl)/v1/models" -TimeoutSec $config.RequestTimeoutSeconds
        Write-StableJson -Value ([ordered]@{
            status = 'ok'
            default_model = $config.ModelName
            api_models = @($models.data | ForEach-Object { $_.id })
        })
    }
    'transcribe' {
        if ([string]::IsNullOrWhiteSpace($InputPath)) {
            throw 'Usage: asr transcribe <local-media-file> [-Language zh]'
        }

        $inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
        if ($inputFile.PSIsContainer) {
            throw "Input must be one local media file, not a directory: $($inputFile.FullName)"
        }

        $supportedExtensions = @('.wav', '.mp3', '.flac', '.m4a', '.ogg', '.webm', '.mp4', '.mov', '.mkv')
        if ($inputFile.Extension.ToLowerInvariant() -notin $supportedExtensions) {
            throw "Unsupported input '$($inputFile.Extension)'. Supported: $($supportedExtensions -join ', ')"
        }

        Write-Output (Invoke-Transcription -InputFile $inputFile -RequestedLanguage $Language -Config $config)
    }
    'align' {
        if ([string]::IsNullOrWhiteSpace($InputPath) -or [string]::IsNullOrWhiteSpace($TranscriptPath)) {
            throw 'Usage: asr align <local-media-file> <transcript.txt> [-Language zh] [-Preset voiceover|tutorial] [-AllowScriptMismatch]'
        }

        $inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
        if ($inputFile.PSIsContainer) {
            throw "Input must be one local media file, not a directory: $($inputFile.FullName)"
        }
        $transcriptFile = Get-Item -LiteralPath $TranscriptPath -ErrorAction Stop
        if ($transcriptFile.PSIsContainer) {
            throw "Transcript must be one UTF-8 text file, not a directory: $($transcriptFile.FullName)"
        }

        $supportedExtensions = @('.wav', '.mp3', '.flac', '.m4a', '.ogg', '.webm', '.mp4', '.mov', '.mkv')
        if ($inputFile.Extension.ToLowerInvariant() -notin $supportedExtensions) {
            throw "Unsupported input '$($inputFile.Extension)'. Supported: $($supportedExtensions -join ', ')"
        }
        if ($transcriptFile.Extension.ToLowerInvariant() -ne '.txt') {
            throw "Transcript must be a UTF-8 .txt file: $($transcriptFile.FullName)"
        }

        $transcript = Get-Content -LiteralPath $transcriptFile.FullName -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($transcript)) {
            throw "Transcript is empty: $($transcriptFile.FullName)"
        }

        Write-Output (Invoke-Alignment -InputFile $inputFile -Transcript $transcript.Trim() -RequestedLanguage $Language -RequestedPreset $Preset -AllowMismatch ([bool]$AllowScriptMismatch) -Config $config)
    }
}
