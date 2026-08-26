[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

$listener = Get-FunAsrPortListener -Port $config.Port
if (-not $listener) {
    Write-Output "No listener is using port $($config.Port)."
    exit 0
}

try {
    $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 5
} catch {
    throw "Port $($config.Port) is occupied, but it did not identify itself as this FunASR service. Nothing was stopped. $($_.Exception.Message)"
}

if ($health.status -ne 'ok' -or $health.device -ne 'cpu') {
    throw "Port $($config.Port) is occupied by an unexpected service response. Nothing was stopped."
}

$legacyOwner = ($health.PSObject.Properties.Name -contains 'models_loaded') -and
    (@($health.models_loaded) -contains $config.ModelAlias)
$newOwner = ($health.PSObject.Properties.Name -contains 'service') -and
    ($health.service -eq 'local-ASR-service') -and
    ($health.PSObject.Properties.Name -contains 'model') -and
    ($health.model -eq $config.ModelName) -and
    ([bool]$health.vad) -and
    ([bool]$health.punctuation)

if (-not ($legacyOwner -or $newOwner)) {
    throw "Port $($config.Port) is occupied by an unexpected service response. Nothing was stopped."
}

$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction Stop
$parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($processInfo.ParentProcessId)" -ErrorAction Stop
if ($parent.ExecutablePath -notin @($config.CpuPython, $config.GpuPython)) {
    throw "Port $($config.Port) is not owned by this deployment's isolated Python launcher. Nothing was stopped."
}

$process = Get-Process -Id $listener.OwningProcess -ErrorAction Stop
Stop-Process -Id $process.Id -ErrorAction Stop

if (Test-Path -LiteralPath $config.PidFile -PathType Leaf) {
    Remove-Item -LiteralPath $config.PidFile -Force
}

Start-Sleep -Milliseconds 500
if (Get-FunAsrPortListener -Port $config.Port) {
    throw "The process was stopped, but port $($config.Port) is still occupied. Check the listener before trying to start FunASR again."
}

Write-Output "Stopped FunASR server process $($process.Id)."
