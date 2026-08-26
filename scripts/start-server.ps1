[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

# 第一版固定 CPU-first；GPU 仅通过 start-server-gpu.ps1 显式启用。
& (Join-Path $PSScriptRoot 'start-server-cpu.ps1')
