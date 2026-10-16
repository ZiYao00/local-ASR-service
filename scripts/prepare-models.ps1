[CmdletBinding()]
param(
    [ValidateSet('base','aligner','qwen-asr')][string]$Mode = 'base',
    [switch]$Offline
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$venv = if ($Mode -eq 'base') { '.venv-cpu' } else { '.venv-qwen3-asr' }
$python = Join-Path $root "$venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Missing Python environment: $python. Install the matching runtime first."
}
$script = Join-Path $PSScriptRoot 'prepare-models.py'
$arguments = ('"{0}" --mode {1}' -f $script, $Mode)
if ($Offline) { $arguments += ' --offline' }
# Process.ExitCode is reliable across nested PowerShell/Agent shells.
$p = New-Object System.Diagnostics.Process
$p.StartInfo.FileName = $python
$p.StartInfo.Arguments = $arguments
$p.StartInfo.UseShellExecute = $false
try {
    $null = $p.Start()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Model preparation failed for mode '$Mode' (exit $($p.ExitCode))." }
} finally {
    $p.Dispose()
}
