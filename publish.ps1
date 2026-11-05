param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9_-]{0,31}$')]
    [string]$User,

    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9_-]{0,39}$')]
    [string]$Name,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repo = 'rishanreddy/cpats-pastebin',

    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

if ($Branch.Contains('..') -or $Branch.Contains('//')) {
    throw 'Invalid branch.'
}
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Source file not found: $Source"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Install it on Windows, then run 'gh auth login'."
}
gh auth status | Out-Null

$firstLine = (Get-Content -LiteralPath $Source -TotalCount 1)
if ($firstLine -notmatch '^#!/(usr/bin/env bash|bin/bash)$') {
    throw 'Script must begin with a Bash shebang.'
}
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    throw 'Bash is required for the syntax check. Run this from Git Bash or WSL.'
}
bash -n -- $Source

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss')
$suffix = (Get-Random -Maximum 65536).ToString('x4')
$remotePath = "scripts/$User/${timestamp}_${Name}_${suffix}.sh"
$content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source)))

$publishedPath = gh api --method PUT "repos/$Repo/contents/$remotePath" `
    --field "message=script: $Name [$User]" `
    --field "content=$content" `
    --field "branch=$Branch" `
    --jq '.content.path'

if ($publishedPath -ne $remotePath) {
    throw "GitHub did not confirm the expected published path."
}
Write-Output "Published: https://github.com/$Repo/blob/$Branch/$remotePath"
