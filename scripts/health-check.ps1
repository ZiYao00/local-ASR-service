[CmdletBinding()]
param(
    [ValidateRange(0, 600)]
    [int]$WaitSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$health = $null
$lastError = $null
$requestTimeout = if ($WaitSeconds -gt 0) { 3 } else { 10 }

do {
    try {
        $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec $requestTimeout
        if ($health.status -eq 'ok') {
            break
        }
        $lastError = "Health endpoint returned status '$($health.status)'."
    } catch {
        $lastError = $_.Exception.Message
        $health = $null
    }

    if ($WaitSeconds -le 0 -or (Get-Date) -ge $deadline) {
        throw "local-ASR-service is not ready at $($config.BaseUrl). $lastError"
    }
    Start-Sleep -Seconds 1
} while ($true)

$models = Invoke-RestMethod -Uri "$($config.BaseUrl)/v1/models" -TimeoutSec 10
$modelIds = @($models.data | ForEach-Object { $_.id })

if ($health.device -notin @('cpu', 'cuda')) {
    throw "Expected a CPU or CUDA service, but /health reported '$($health.device)'."
}
if ($modelIds -notcontains $config.ModelAlias) {
    throw "Expected model alias '$($config.ModelAlias)' was not listed by /v1/models."
}
if (-not $health.vad -or -not $health.punctuation) {
    throw 'ASR service is running without the required VAD/punctuation pipeline.'
}

[pscustomobject]@{
    Status       = $health.status
    Service      = $health.service
    Device       = $health.device
    Runtime      = if ($health.device -eq 'cuda') { 'gpu' } else { 'cpu' }
    Model        = $health.model
    Vad          = [bool]$health.vad
    Punctuation  = [bool]$health.punctuation
    QueueRunning = [int]$health.queue.running
    QueueWaiting = [int]$health.queue.waiting
    Ffmpeg       = [bool]$health.ffmpeg
    ModelAliases = $modelIds -join ', '
    BaseUrl      = $config.BaseUrl
}
