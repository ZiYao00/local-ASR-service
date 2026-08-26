[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

if (-not (Test-FunAsrGpuRuntime -Config $config)) {
    throw "GPU runtime is not installed or CUDA is unavailable. Expected GPU environment: $($config.GpuVenv). CPU fallback is intentionally disabled for this explicit GPU command."
}

Start-FunAsrServer -Config $config -RuntimeName 'gpu' -Python $config.GpuPython -Device 'cuda'
