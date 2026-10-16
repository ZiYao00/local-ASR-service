[CmdletBinding()]
param([switch]$VerifyOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'install-support.ps1')
$venv = Join-Path $root '.venv-qwen3-asr'
$python = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements-aligner.txt'
if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
    throw "Missing requirements file: $requirements"
}
if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw 'Optional alignment environment not installed.'
    }
    $null = Initialize-ASRPython -EnvironmentRoot $venv
    & (Join-Path $PSScriptRoot 'prepare-models.ps1') -Mode aligner -Offline
} else {
    $null = Initialize-ASRPython -EnvironmentRoot $venv
    Invoke-ASRExecutable -Executable $python -Arguments @('-m','pip','install','--index-url','https://download.pytorch.org/whl/cpu','torch==2.13.0')
    Invoke-ASRExecutable -Executable $python -Arguments @('-m','pip','install','-r',$requirements)
    & (Join-Path $PSScriptRoot 'prepare-models.ps1') -Mode aligner
}
Invoke-ASRExecutable -Executable $python -Arguments @('-c',"import torch, qwen_asr; from qwen_asr import Qwen3ForcedAligner; print('Forced Aligner imports OK')")
Invoke-ASRExecutable -Executable $python -Arguments @('-m','pip','check')
Write-Host '[OK] Optional alignment environment and model are ready.'
