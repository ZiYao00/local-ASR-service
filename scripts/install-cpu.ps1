[CmdletBinding()]
param([switch]$VerifyOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'install-support.ps1')
$venv = Join-Path $root '.venv-cpu'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements-cpu.txt'
$config = Join-Path $root 'config\local.json'
$example = Join-Path $root 'config\local.example.json'
if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
    throw "Missing project requirements: $requirements"
}
if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw 'CPU virtual environment is missing. Run the installer without -VerifyOnly.'
    }
    $null = Initialize-ASRPython -EnvironmentRoot $venv
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'config/local.json is missing.' }
    & (Join-Path $PSScriptRoot 'prepare-ffmpeg.ps1') -Mode verify
    & (Join-Path $PSScriptRoot 'prepare-models.ps1') -Mode base -Offline
} else {
    $null = Initialize-ASRPython -EnvironmentRoot $venv
    # Pin tested CPU builds. Do not globally upgrade pip or unrelated packages.
    Invoke-ASRExecutable -Executable $venvPython -Arguments @('-m','pip','install','--index-url','https://download.pytorch.org/whl/cpu','torch==2.13.0','torchaudio==2.11.0')
    Invoke-ASRExecutable -Executable $venvPython -Arguments @('-m','pip','install','-r',$requirements)
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        Copy-Item -LiteralPath $example -Destination $config
        Write-Host 'Created local configuration from public example.'
    }
    & (Join-Path $PSScriptRoot 'prepare-ffmpeg.ps1') -Mode prepare
    & (Join-Path $PSScriptRoot 'prepare-models.ps1') -Mode base
}
Invoke-ASRExecutable -Executable $venvPython -Arguments @('-c',"import torch, torchaudio, funasr, fastapi, uvicorn, soundfile, modelscope; print('CPU service Python dependency imports OK')")
Invoke-ASRExecutable -Executable $venvPython -Arguments @('-m','pip','check')
Write-Host '[OK] CPU dependency, model cache and bundled FFmpeg checks passed.'
if (-not $VerifyOnly) { Write-Host 'Next: .\service.bat start' }
