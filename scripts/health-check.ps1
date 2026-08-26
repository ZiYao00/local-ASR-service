[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

$health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 10
$models = Invoke-RestMethod -Uri "$($config.BaseUrl)/v1/models" -TimeoutSec 10
$modelIds = @($models.data | ForEach-Object { $_.id })

if ($health.status -ne 'ok') {
    throw "Health endpoint returned status '$($health.status)'."
}
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
