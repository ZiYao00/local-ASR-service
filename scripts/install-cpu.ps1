[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root '.venv-cpu'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements-cpu.txt'
$localConfig = Join-Path $root 'config\local.json'
$exampleConfig = Join-Path $root 'config\local.example.json'

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

# Install CPU wheels first so FunASR dependencies do not pull a CUDA-enabled PyTorch build.
& $venvPython -m pip install --index-url https://download.pytorch.org/whl/cpu torch torchaudio
if ($LASTEXITCODE -ne 0) { throw 'PyTorch CPU installation failed.' }

& $venvPython -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed.' }

if (-not (Test-Path -LiteralPath $localConfig -PathType Leaf)) {
    Copy-Item -LiteralPath $exampleConfig -Destination $localConfig
    Write-Host 'Created config\local.json from the public example.'
}

$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    Write-Warning 'FFmpeg was not found on PATH. Install FFmpeg and expose ffmpeg.exe before transcribing media.'
}

& $venvPython -c "import sys, torch, funasr, fastapi, uvicorn, soundfile, modelscope; print('Python', sys.version.split()[0]); print('PyTorch', torch.__version__); print('FunASR', getattr(funasr, '__version__', 'unknown')); print('CPU ready:', not torch.cuda.is_available())"
if ($LASTEXITCODE -ne 0) { throw 'Installed environment import check failed.' }

Write-Host ''
Write-Host 'CPU environment is ready.'
Write-Host 'Next: .\scripts\start-server.ps1'
