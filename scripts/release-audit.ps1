[CmdletBinding()]
param([switch]$IncludeHistory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scanRoots = @(
    (Join-Path $root 'bin'),
    (Join-Path $root 'config'),
    (Join-Path $root 'docs'),
    (Join-Path $root 'licenses'),
    (Join-Path $root 'scripts'),
    (Join-Path $root 'service'),
    (Join-Path $root 'tests')
)
$rootFiles = @(
    (Join-Path $root '.gitignore'),
    (Join-Path $root 'README.md'),
    (Join-Path $root 'AGENTS.md'),
    (Join-Path $root 'service.bat'),
    (Join-Path $root 'deployment-report.md'),
    (Join-Path $root 'requirements-cpu.txt'),
    (Join-Path $root 'requirements-aligner.txt'),
    (Join-Path $root 'LICENSE'),
    (Join-Path $root 'THIRD_PARTY.md')
)

$files = @()
foreach ($scanRoot in $scanRoots) {
    if (Test-Path -LiteralPath $scanRoot -PathType Container) {
        $files += Get-ChildItem -LiteralPath $scanRoot -Recurse -File | Where-Object {
            $_.FullName -ne (Join-Path $root 'config\local.json') -and
            $_.Extension -in @('.md', '.txt', '.json', '.ps1', '.cmd', '.bat', '.py')
        }
    }
}
$files += $rootFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { Get-Item -LiteralPath $_ }
$files = $files | Sort-Object -Property FullName -Unique

$patterns = [ordered]@{
    'Windows user profile path' = '(?i)[A-Z]:[\\/]Users[\\/]'
    'Private GitHub workspace path' = '(?i)G:[\\/]GitHub[\\/]'
    'Private note-drive path' = '(?i)M:[\\/]'
    'Known local username path fragment' = '(?i)[\\/]YAO[\\/]'
    'Likely embedded secret assignment' = '(?i)(api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*["''][^"''\s]{8,}'
}

$findings = @()
foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($entry in $patterns.GetEnumerator()) {
        if ($content -match $entry.Value) {
            $findings += [pscustomobject]@{
                File = $file.FullName.Substring($root.Length + 1)
                Rule = $entry.Key
            }
        }
    }
}

$requiredIgnores = @('.venv*/', 'models/', 'runtime/', 'logs/', 'input/', 'output/', 'backups/', 'config/local.json', 'tools/ffmpeg/')
$gitignorePath = Join-Path $root '.gitignore'
$gitignore = Get-Content -LiteralPath $gitignorePath -Raw -Encoding utf8
foreach ($entry in $requiredIgnores) {
    if ($gitignore -notmatch [regex]::Escape($entry)) {
        $findings += [pscustomobject]@{ File = '.gitignore'; Rule = "Missing ignore rule: $entry" }
    }
}

if ($IncludeHistory) {
    # Inspect all committed text blobs without printing private source lines.
    function Invoke-GitText {
        param([Parameter(Mandatory)][string]$Arguments)
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo.FileName = 'git.exe'
        $p.StartInfo.Arguments = ('-C "{0}" {1}' -f $root, $Arguments)
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.RedirectStandardOutput = $true
        $p.StartInfo.RedirectStandardError = $true
        try {
            $null = $p.Start()
            $result = $p.StandardOutput.ReadToEnd()
            $errorText = $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            if ($p.ExitCode -ne 0) { throw "Git history audit failed: $errorText" }
            return $result
        } finally { $p.Dispose() }
    }
    $commits = @((Invoke-GitText -Arguments 'rev-list --all') -split "[\r\n]+" | Where-Object { $_ })
    foreach ($commit in $commits) {
        $names = @((Invoke-GitText -Arguments ("ls-tree -r --name-only {0}" -f $commit)) -split "[\r\n]+" | Where-Object { $_ })
        foreach ($name in $names) {
            if ($name -match '(^|/)(models|runtime|logs|backups|input|output|\.venv[^/]*)/' -or $name -eq 'config/local.json') {
                $findings += [pscustomobject]@{ File = "history:$($commit.Substring(0,8))/$name"; Rule = 'Private runtime data in commit' }
                continue
            }
            $ext = [System.IO.Path]::GetExtension($name)
            if ($ext -notin @('.md','.txt','.json','.ps1','.py','.cmd','.bat','.yaml','.yml') -and $name -notin @('.gitignore','LICENSE')) { continue }
            $source = Invoke-GitText -Arguments ("show {0}:{1}" -f $commit, $name)
            foreach ($entry in $patterns.GetEnumerator()) {
                if ($source -match $entry.Value) {
                    $findings += [pscustomobject]@{ File = "history:$($commit.Substring(0,8))/$name"; Rule = $entry.Key }
                }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize
    throw "Release audit found $($findings.Count) issue(s)."
}

[pscustomobject]@{
    Status = 'passed'
    FilesScanned = $files.Count
    PrivacyFindings = 0
    RequiredIgnoreRules = $requiredIgnores.Count
}
