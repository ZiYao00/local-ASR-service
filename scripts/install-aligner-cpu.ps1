[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root '.venv-qwen3-asr'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements-aligner.txt'
$modelDirectory = Join-Path $root 'models\qwen3-forced-aligner-0.6b'
$modelWeights = Join-Path $modelDirectory 'model.safetensors'

if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
    throw "Missing requirements file: $requirements"
}

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3.11 -c "import sys; assert sys.version_info[:2] == (3, 11), sys.version"
        if ($LASTEXITCODE -ne 0) {
            throw 'Python 3.11 is required. Install Python 3.11 and retry.'
        }
        & $py.Source -3.11 -m venv $venv
    } else {
        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $python) {
            throw 'Python 3.11 was not found. Install Python 3.11 first.'
        }
        & $python.Source -c "import sys; assert sys.version_info[:2] == (3, 11), sys.version"
        if ($LASTEXITCODE -ne 0) {
            throw 'The default python.exe is not Python 3.11.'
        }
        & $python.Source -m venv $venv
    }
}

& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed.' }

# Keep the optional aligner isolated from the main FunASR environment.
& $venvPython -m pip install --index-url https://download.pytorch.org/whl/cpu torch
if ($LASTEXITCODE -ne 0) { throw 'PyTorch CPU installation failed.' }

& $venvPython -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) { throw 'Qwen3 alignment dependency installation failed.' }

& $venvPython -c "import sys, torch, qwen_asr; from qwen_asr import Qwen3ForcedAligner; print('Python', sys.version.split()[0]); print('PyTorch', torch.__version__); print('qwen-asr ready:', Qwen3ForcedAligner is not None); print('CPU ready:', not torch.cuda.is_available())"
if ($LASTEXITCODE -ne 0) { throw 'Installed alignment environment import check failed.' }

Write-Host ''
Write-Host 'Optional Qwen3 Forced Aligner runtime is ready.'
if (Test-Path -LiteralPath $modelWeights -PathType Leaf) {
    Write-Host "Local model found: $modelDirectory"
} else {
    Write-Warning "Model weights are not installed. Download Qwen/Qwen3-ForcedAligner-0.6B and place the complete model in: $modelDirectory"
}
Write-Host 'The installer does not download model weights automatically.'
