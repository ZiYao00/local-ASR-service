[CmdletBinding()]
param(
    [string]$InputPath,
    [int]$ObserveTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Join-Path $root 'input\test2.mp4'
}
$cli = Join-Path $PSScriptRoot 'asr.ps1'
$inputFile = (Get-Item -LiteralPath $InputPath -ErrorAction Stop).FullName
. (Join-Path $root 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

$health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 10
if ($health.status -ne 'ok') {
    throw 'local-ASR-service is not ready.'
}

$jobScript = {
    param($CliPath, $MediaPath)
    $text = (& $CliPath transcribe $MediaPath) -join [Environment]::NewLine
    if (-not $?) {
        throw 'CLI transcription failed inside the background job.'
    }
    return $text
}

$job1 = Start-Job -ScriptBlock $jobScript -ArgumentList $cli, $inputFile
Start-Sleep -Milliseconds 150
$job2 = Start-Job -ScriptBlock $jobScript -ArgumentList $cli, $inputFile

$observedWaiting = $false
$deadline = (Get-Date).AddSeconds($ObserveTimeoutSeconds)
try {
    while ((Get-Date) -lt $deadline) {
        $snapshot = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 10
        if ([int]$snapshot.queue.running -eq 1 -and [int]$snapshot.queue.waiting -ge 1) {
            $observedWaiting = $true
            break
        }
        if ($job1.State -in @('Completed', 'Failed', 'Stopped') -and $job2.State -in @('Completed', 'Failed', 'Stopped')) {
            break
        }
        Start-Sleep -Milliseconds 100
    }

    Wait-Job -Job $job1, $job2 -Timeout ($ObserveTimeoutSeconds * 3) | Out-Null
    if ($job1.State -ne 'Completed' -or $job2.State -ne 'Completed') {
        $reason1 = if ($job1.ChildJobs.Count -gt 0 -and $job1.ChildJobs[0].JobStateInfo.Reason) { $job1.ChildJobs[0].JobStateInfo.Reason.Message } else { '<none>' }
        $reason2 = if ($job2.ChildJobs.Count -gt 0 -and $job2.ChildJobs[0].JobStateInfo.Reason) { $job2.ChildJobs[0].JobStateInfo.Reason.Message } else { '<none>' }
        throw "Queue jobs did not both complete. job1=$($job1.State): $reason1; job2=$($job2.State): $reason2"
    }

    $result1 = ((Receive-Job -Job $job1) -join [Environment]::NewLine) | ConvertFrom-Json
    $result2 = ((Receive-Job -Job $job2) -join [Environment]::NewLine) | ConvertFrom-Json
    if ($result1.status -ne 'ok' -or $result2.status -ne 'ok') {
        throw 'One or both queued transcriptions failed.'
    }

    if (-not $observedWaiting) {
        throw 'Both requests completed, but queue.waiting was not observed. Retry with a longer media file.'
    }

    $finalHealth = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 10
    if ([int]$finalHealth.queue.running -ne 0 -or [int]$finalHealth.queue.waiting -ne 0) {
        throw 'Queue did not return to idle after the test.'
    }

    [pscustomobject]@{
        Status = 'passed'
        WaitingObserved = $observedWaiting
        FinalRunning = [int]$finalHealth.queue.running
        FinalWaiting = [int]$finalHealth.queue.waiting
    }
} finally {
    Remove-Job -Job $job1, $job2 -Force -ErrorAction SilentlyContinue
}
