[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scanRoots = @(
    (Join-Path $root 'bin'),
    (Join-Path $root 'config'),
    (Join-Path $root 'docs'),
    (Join-Path $root 'scripts'),
    (Join-Path $root 'service'),
    (Join-Path $root 'tests')
)
$rootFiles = @(
    (Join-Path $root '.gitignore'),
    (Join-Path $root 'README.md'),
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
            $_.Extension -in @('.md', '.txt', '.json', '.ps1', '.cmd', '.py')
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

$requiredIgnores = @('.venv*/', 'models/', 'runtime/', 'logs/', 'input/', 'output/', 'backups/', 'config/local.json')
$gitignorePath = Join-Path $root '.gitignore'
$gitignore = Get-Content -LiteralPath $gitignorePath -Raw -Encoding utf8
foreach ($entry in $requiredIgnores) {
    if ($gitignore -notmatch [regex]::Escape($entry)) {
        $findings += [pscustomobject]@{ File = '.gitignore'; Rule = "Missing ignore rule: $entry" }
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
