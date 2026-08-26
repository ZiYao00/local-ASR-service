Set-StrictMode -Version Latest

function Get-FunAsrLocalSetting {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Settings,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Settings.PSObject.Properties.Name -notcontains $Name) {
        throw "Missing required setting '$Name' in config\\local.json."
    }

    $value = $Settings.$Name
    if ($null -eq $value -or ([string]$value).Length -eq 0) {
        throw "Setting '$Name' in config\\local.json must not be empty."
    }

    return $value
}

function Resolve-FunAsrProjectPath {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Machine-local paths must be relative to the project root: $RelativePath"
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
}

function Get-FunAsrServiceConfig {
    $serviceRoot = Split-Path -Parent $PSScriptRoot
    $localConfigPath = Join-Path $serviceRoot 'config\local.json'
    if (-not (Test-Path -LiteralPath $localConfigPath -PathType Leaf)) {
        throw "Missing machine-local configuration: $localConfigPath. Copy config\\local.example.json to config\\local.json first."
    }

    try {
        $settings = Get-Content -LiteralPath $localConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot parse $localConfigPath as UTF-8 JSON. $($_.Exception.Message)"
    }

    $bindHost = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'host')
    $port = [int](Get-FunAsrLocalSetting -Settings $settings -Name 'port')
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Setting 'port' in config\\local.json is invalid: $port"
    }

    $runtimeDataRoot = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'runtimeDataRoot'))
    $cpuVenv = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'cpuVenv'))
    $gpuVenv = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'gpuVenv'))

    return [pscustomobject]@{
        Root            = $serviceRoot
        RuntimeDataRoot = $runtimeDataRoot
        LocalConfigPath = $localConfigPath
        CpuVenv         = $cpuVenv
        CpuPython       = Join-Path $cpuVenv 'Scripts\python.exe'
        GpuVenv         = $gpuVenv
        GpuPython       = Join-Path $gpuVenv 'Scripts\python.exe'
        Host            = $bindHost
        Port            = $port
        BaseUrl         = "http://${bindHost}:$port"
        ModelAlias      = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'modelAlias')
        ModelName       = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'modelName')
        ModelPath       = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'modelPath')
        VadModel        = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'vadModel')
        PuncModel       = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'puncModel')
        MaxSingleSegmentMs = [int](Get-FunAsrLocalSetting -Settings $settings -Name 'maxSingleSegmentMs')
        ModelScopeCache = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'modelScopeCache'))
        RuntimeCache    = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'runtimeCache'))
        Temp            = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'temp'))
        Test            = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'test'))
        Output          = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'output'))
        SiblingOutputFolder = [string](Get-FunAsrLocalSetting -Settings $settings -Name 'siblingOutputFolder')
        Logs            = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'logs'))
        PidFile         = Resolve-FunAsrProjectPath -ProjectRoot $serviceRoot -RelativePath ([string](Get-FunAsrLocalSetting -Settings $settings -Name 'pidFile'))
        QueueTimeoutSeconds = [int](Get-FunAsrLocalSetting -Settings $settings -Name 'queueTimeoutSeconds')
        RequestTimeoutSeconds = [int](Get-FunAsrLocalSetting -Settings $settings -Name 'requestTimeoutSeconds')
    }
}

function Set-FunAsrProcessEnvironment {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    foreach ($directory in @($Config.ModelScopeCache, $Config.RuntimeCache, $Config.Temp, $Config.Test, $Config.Logs)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
    }

    $env:MODELSCOPE_CACHE = $Config.ModelScopeCache
    $env:HF_HOME = Join-Path $Config.RuntimeCache 'huggingface'
    $env:TORCH_HOME = Join-Path $Config.RuntimeCache 'torch'
    $env:TEMP = $Config.Temp
    $env:TMP = $Config.Temp
    $env:PYTHONUTF8 = '1'
    $env:TOKENIZERS_PARALLELISM = 'false'
}

function Get-FunAsrPortListener {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    return Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::') } |
        Select-Object -First 1
}

function Test-FunAsrGpuRuntime {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    if (-not (Test-Path -LiteralPath $Config.GpuPython -PathType Leaf)) {
        return $false
    }

    try {
        & $Config.GpuPython -c "import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)" 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Test-FunAsrConfiguredLocalModel {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [string]$Reference
    )

    if ([System.IO.Path]::IsPathRooted($Reference)) {
        throw "$Label model path must be relative to the project root: $Reference"
    }

    $candidate = Join-Path $ProjectRoot $Reference
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate 'model.pt') -PathType Leaf)) {
            throw "$Label model is incomplete: $candidate"
        }
        return
    }

    if ($Reference -match '^(models[\\/])') {
        throw "$Label model directory is missing: $candidate"
    }
}

function Start-FunAsrServer {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [ValidateSet('cpu', 'gpu')]
        [string]$RuntimeName,
        [Parameter(Mandatory)]
        [string]$Python,
        [Parameter(Mandatory)]
        [ValidateSet('cpu', 'cuda')]
        [string]$Device
    )

    Set-FunAsrProcessEnvironment -Config $Config

    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "The $RuntimeName runtime Python executable was not found: $Python"
    }
    Test-FunAsrConfiguredLocalModel -ProjectRoot $Config.Root -Label $Config.ModelName -Reference $Config.ModelPath
    Test-FunAsrConfiguredLocalModel -ProjectRoot $Config.Root -Label 'FSMN-VAD' -Reference $Config.VadModel
    Test-FunAsrConfiguredLocalModel -ProjectRoot $Config.Root -Label 'CT-Transformer punctuation' -Reference $Config.PuncModel

    $listener = Get-FunAsrPortListener -Port $Config.Port
    if ($listener) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        $name = if ($process) { $process.ProcessName } else { '<unavailable>' }
        throw "Port $($Config.Port) is already occupied by PID $($listener.OwningProcess) ($name). The script will not stop another service."
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stdout = Join-Path $Config.Logs "server-$RuntimeName-$stamp.stdout.log"
    $stderr = Join-Path $Config.Logs "server-$RuntimeName-$stamp.stderr.log"
    $env:LOCAL_ASR_DEVICE = $Device
    $ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($ffmpeg) {
        $env:LOCAL_ASR_FFMPEG = $ffmpeg.Source
    } else {
        Remove-Item Env:LOCAL_ASR_FFMPEG -ErrorAction SilentlyContinue
    }
    $arguments = @(
        '-m', 'uvicorn',
        'service.app:app',
        '--host', $Config.Host,
        '--port', $Config.Port
    )

    $process = Start-Process -FilePath $Python -ArgumentList $arguments -WorkingDirectory $Config.Root `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru

    [System.IO.File]::WriteAllText($Config.PidFile, $process.Id.ToString(), [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Status    = 'started'
        Runtime   = $RuntimeName
        Device    = $Device
        PID       = $process.Id
        BaseUrl   = $Config.BaseUrl
        StdoutLog = $stdout
        StderrLog = $stderr
    }
}
