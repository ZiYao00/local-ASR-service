# Common Windows Python launcher for agent-friendly CPU installation.
Set-StrictMode -Version Latest

function Invoke-ASRExecutable {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @()
    )
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $Executable
    $p.StartInfo.Arguments = (($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ')
    $p.StartInfo.UseShellExecute = $false
    try {
        $null = $p.Start()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            throw "Command failed (exit=$($p.ExitCode)): $Executable"
        }
    } finally {
        $p.Dispose()
    }
}

function Initialize-ASRPython {
    param([Parameter(Mandatory)][string]$EnvironmentRoot)
    $envPython = Join-Path $EnvironmentRoot 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $envPython -PathType Leaf)) {
        $created = $false
        $py = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($py) {
            try {
                Invoke-ASRExecutable -Executable $py.Source -Arguments @('-3.11','-c',"import sys; assert sys.version_info[:2] == (3, 11)")
                Invoke-ASRExecutable -Executable $py.Source -Arguments @('-3.11','-m','venv',$EnvironmentRoot)
                $created = $true
            } catch {
                Write-Warning "Python launcher could not provide 3.11; checking python.exe. $($_.Exception.Message)"
            }
        }
        if (-not $created) {
            $python = Get-Command python.exe -ErrorAction SilentlyContinue
            if (-not $python) { throw 'Python 3.11 was not found. Install it first, then retry.' }
            Invoke-ASRExecutable -Executable $python.Source -Arguments @('-c',"import sys; assert sys.version_info[:2] == (3, 11)")
            Invoke-ASRExecutable -Executable $python.Source -Arguments @('-m','venv',$EnvironmentRoot)
        }
    }
    if (-not (Test-Path -LiteralPath $envPython -PathType Leaf)) {
        throw "Python virtual environment was not created: $envPython"
    }
    Invoke-ASRExecutable -Executable $envPython -Arguments @('-c',"import sys; assert sys.version_info[:2] == (3, 11)")
    return $envPython
}
