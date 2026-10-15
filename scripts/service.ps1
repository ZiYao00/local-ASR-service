[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('menu', 'start', 'stop', 'restart', 'status', 'open', 'start-open', 'logs')]
    [string]$Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

function Get-ServiceState {
    $listener = Get-FunAsrPortListener -Port $config.Port
    if ($listener) {
        try {
            $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 3
        } catch {
            throw "Port $($config.Port) is occupied but the ASR health endpoint is unavailable. $($_.Exception.Message)"
        }
        if ($health.PSObject.Properties.Name -notcontains 'service' -or
            $health.service -ne 'local-ASR-service' -or $health.model -ne $config.ModelName) {
            throw "Port $($config.Port) is occupied by an unexpected service."
        }
        return $(if ($health.status -eq 'ok') { 'running' } else { 'starting' })
    }

    if (Test-Path -LiteralPath $config.PidFile -PathType Leaf) {
        $recordedPid = 0
        $pidText = (Get-Content -LiteralPath $config.PidFile -Raw -Encoding utf8).Trim()
        if ([int]::TryParse($pidText, [ref]$recordedPid) -and $recordedPid -gt 0) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $recordedPid" -ErrorAction SilentlyContinue
            if ($null -ne $processInfo -and
                $processInfo.ExecutablePath -in @($config.CpuPython, $config.GpuPython) -and
                $processInfo.CommandLine -match 'service\.app:app') {
                return 'starting'
            }
        }
    }
    return 'stopped'
}

function Start-ServiceAndWait {
    $state = Get-ServiceState
    if ($state -eq 'running') {
        $health = & (Join-Path $PSScriptRoot 'health-check.ps1')
        Write-Host '[成功] 服务已经就绪，无需重复启动。' -ForegroundColor Green
    } else {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        if ($state -eq 'stopped') {
            $started = & (Join-Path $PSScriptRoot 'start-server-cpu.ps1')
            Write-Host "[启动] 后台进程已创建，PID $($started.PID)。" -ForegroundColor Cyan
        } else {
            Write-Host '[等待] 服务已经在启动中，将等待现有进程就绪。' -ForegroundColor Yellow
        }
        Write-Host '正在加载 SenseVoice、VAD 和标点模型，通常需要约 1-2 分钟。'
        Write-Host "最多等待 120 秒；日志目录：$($config.Logs)"
        $health = & (Join-Path $PSScriptRoot 'health-check.ps1') -WaitSeconds 120
        Write-Host "[成功] 服务已就绪，用时 $([math]::Round($timer.Elapsed.TotalSeconds, 1)) 秒。" -ForegroundColor Green
    }
    Write-Host "模型：$($health.Model)  |  运行模式：$($health.Device.ToUpperInvariant())"
    Write-Host "地址：$($config.BaseUrl)"
}

function Write-ServiceOverview {
    param([switch]$Detailed)

    $state = Get-ServiceState
    $labels = @{ running = '运行中（已就绪）'; starting = '启动中（模型加载中）'; stopped = '未启动' }
    $color = if ($state -eq 'running') { 'Green' } elseif ($state -eq 'starting') { 'Yellow' } else { 'DarkGray' }
    $listener = Get-FunAsrPortListener -Port $config.Port
    $pidLabel = if ($null -ne $listener) { "  |  PID $($listener.OwningProcess)" } else { '' }
    Write-Host "服务状态：$($labels[$state])$pidLabel" -ForegroundColor $color
    Write-Host "项目目录：$($config.Root)"
    Write-Host "服务地址：$($config.BaseUrl)"
    Write-Host "日志目录：$($config.Logs)"

    if ($state -eq 'running') {
        $health = Invoke-RestMethod -Uri "$($config.BaseUrl)/health" -TimeoutSec 3
        Write-Host "当前模型：$($health.model)  |  运行模式：$($health.device.ToUpperInvariant())"
        Write-Host "任务队列：运行 $($health.queue.running) / 等待 $($health.queue.waiting)"
        if ($Detailed) {
            $checked = & (Join-Path $PSScriptRoot 'health-check.ps1')
            $checks = @()
            foreach ($entry in @(@('VAD', $checked.Vad), @('标点恢复', $checked.Punctuation), @('FFmpeg', $checked.Ffmpeg))) {
                $checks += "$($entry[0])：$(if ($entry[1]) { '正常' } else { '不可用' })"
            }
            Write-Host ($checks -join '  |  ')
            Write-Host "可选 Forced Aligner：$(if ($checked.ForcedAligner) { '就绪' } else { '未就绪' })"
        }
    }
}

function Invoke-ServiceAction {
    param([string]$Action)

    switch ($Action) {
        'status' {
            Write-ServiceOverview -Detailed
        }
        'start' { Start-ServiceAndWait }
        'stop' {
            $state = Get-ServiceState
            if ($state -eq 'starting') {
                throw '模型仍在加载，请等待服务就绪后再停止。'
            }
            if ($state -eq 'stopped') {
                Write-Host '[成功] 服务已经停止。' -ForegroundColor Green
                return
            }
            $null = & (Join-Path $PSScriptRoot 'stop-server.ps1')
            Write-Host '[成功] 服务已停止，端口已释放。' -ForegroundColor Green
        }
        'restart' {
            $state = Get-ServiceState
            if ($state -eq 'starting') {
                throw '模型仍在加载，请等待服务就绪后再重启。'
            }
            if ($state -eq 'running') {
                Write-Host '[重启] 正在停止旧服务...' -ForegroundColor Cyan
                $null = & (Join-Path $PSScriptRoot 'stop-server.ps1')
            }
            Start-ServiceAndWait
        }
        'open' {
            if ((Get-ServiceState) -ne 'running') {
                throw '服务尚未就绪，请先启动，或选择“启动并打开接口文档”。'
            }
            Start-Process "$($config.BaseUrl)/docs"
            Write-Host '[成功] 已在默认浏览器中打开接口文档。' -ForegroundColor Green
        }
        'start-open' {
            Start-ServiceAndWait
            Invoke-ServiceAction -Action open
        }
        'logs' {
            if (-not (Test-Path -LiteralPath $config.Logs -PathType Container)) {
                throw '日志目录尚未创建，首次启动服务后即可查看。'
            }
            Start-Process explorer.exe -ArgumentList ('"{0}"' -f $config.Logs)
            Write-Host '[成功] 已打开日志目录。' -ForegroundColor Green
        }
    }
}

function Show-ServiceMenu {
    $lastResult = ''
    $lastColor = 'Green'
    while ($true) {
        Clear-Host
        Write-Host 'local-ASR-service 服务管理' -ForegroundColor Cyan
        Write-Host ('-' * 54)
        try {
            Write-ServiceOverview
        } catch {
            Write-Host "服务状态：检查失败。$($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host ('-' * 54)
        if ($lastResult) {
            Write-Host "上次操作：$lastResult" -ForegroundColor $lastColor
            Write-Host ''
        }
        Write-Host '1. 后台启动服务'
        Write-Host '2. 停止服务'
        Write-Host '3. 重启服务'
        Write-Host '4. 检查详细状态'
        Write-Host '5. 打开接口文档'
        Write-Host '6. 启动并打开接口文档'
        Write-Host '7. 打开日志目录'
        Write-Host '0. 退出菜单（后台服务继续运行）'
        Write-Host ''
        $selection = Read-Host '输入编号并按回车'
        if ($selection -in @('0', 'q', 'Q')) { return }
        $actions = @{ '1' = 'start'; '2' = 'stop'; '3' = 'restart'; '4' = 'status'; '5' = 'open'; '6' = 'start-open'; '7' = 'logs' }
        $names = @{ '1' = '启动'; '2' = '停止'; '3' = '重启'; '4' = '状态检查'; '5' = '打开接口文档'; '6' = '启动并打开文档'; '7' = '打开日志目录' }
        if (-not $actions.ContainsKey($selection)) {
            $lastResult = '无效选择，请输入 0-7。'
            $lastColor = 'Yellow'
            continue
        }
        Write-Host ''
        try {
            Invoke-ServiceAction -Action $actions[$selection]
            $lastResult = "$($names[$selection])完成"
            $lastColor = 'Green'
        } catch {
            $lastResult = "$($names[$selection])失败：$($_.Exception.Message)"
            $lastColor = 'Red'
            Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "可通过状态检查或日志目录排查：$($config.Logs)"
        }
        Write-Host ''
        $null = Read-Host '按回车返回菜单'
    }
}

try {
    if ($Command -eq 'menu') {
        Show-ServiceMenu
    } else {
        Invoke-ServiceAction -Action $Command
    }
} catch {
    Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "请检查服务状态或日志目录：$($config.Logs)"
    exit 1
}
