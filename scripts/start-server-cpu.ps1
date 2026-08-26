[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\environment.ps1')
$config = Get-FunAsrServiceConfig

Start-FunAsrServer -Config $config -RuntimeName 'cpu' -Python $config.CpuPython -Device 'cpu'
