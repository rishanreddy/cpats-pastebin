param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')]
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
$User = $User.ToLowerInvariant()
if ($Branch.Contains('..') -or $Branch.Contains('//')) { throw 'Invalid branch.' }
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Source file not found: $Source" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Run 'gh auth login' on the developer machine."
}
gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run 'gh auth login' before publishing." }
if ((Get-Content -LiteralPath $Source -TotalCount 1) -notmatch '^#!/(usr/bin/env bash|bin/bash)$') {
    throw 'Script must begin with a Bash shebang.'
}
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    throw 'Bash is required for the syntax check. Use Git Bash or WSL.'
}
bash -n -- $Source
if ($LASTEXITCODE -ne 0) { throw 'Bash syntax check failed.' }

$sourceBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source))
if ([Text.Encoding]::UTF8.GetString($sourceBytes).Contains("`r`n")) {
    throw 'Save Bash scripts with LF line endings before publishing.'
}
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_ffffff')
$remotePath = "scripts/$User/${timestamp}_${Name}_$([Guid]::NewGuid().ToString('N')).sh"
$header = [Text.Encoding]::UTF8.GetBytes("blob $($sourceBytes.Length)`0")
$sha1 = [Security.Cryptography.SHA1]::Create()
try {
    $expectedSha = [BitConverter]::ToString($sha1.ComputeHash([byte[]]($header + $sourceBytes))).Replace('-', '').ToLowerInvariant()
} finally { $sha1.Dispose() }

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('cpats-publish-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDir) | Out-Null
try {
    $payloadFile = Join-Path $tempDir 'payload.json'
    $payload = @{
        message = "script: $Name [$User]"
        content = [Convert]::ToBase64String($sourceBytes)
        branch = $Branch
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($payloadFile, $payload, [Text.UTF8Encoding]::new($false))
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $wire = gh api --include --method PUT "repos/$Repo/contents/$remotePath" --input $payloadFile 2>$null | Out-String
        $putExit = $LASTEXITCODE
        $status = 0
        if ($wire -match '^HTTP/\S+\s+(\d+)') { $status = [int]$Matches[1] }
        if ($putExit -eq 0 -and $status -in @(200, 201)) {
            $parts = $wire -split '\r?\n\r?\n', 2
            if ($parts.Count -ne 2 -or ($parts[1] | ConvertFrom-Json).content.path -ne $remotePath) {
                throw 'GitHub did not confirm the expected published path.'
            }
            Write-Output "Published: https://github.com/$Repo/blob/$Branch/$remotePath"
            Write-Output "Next (in Git Bash): bash results.sh --user $User --script $(Split-Path -Leaf $remotePath) --wait 180"
            return
        }
        if ($status -notin @(0, 409, 422, 500, 502, 503, 504)) {
            throw "Upload failed (HTTP $status). Source retained: $Source"
        }
        $existingSha = gh api --method GET "repos/$Repo/contents/${remotePath}?ref=$([Uri]::EscapeDataString($Branch))" --jq '.sha' 2>$null
        if ($LASTEXITCODE -eq 0) {
            if ($existingSha -ne $expectedSha) { throw "Refusing to overwrite different content at $remotePath" }
            Write-Output "Published: https://github.com/$Repo/blob/$Branch/$remotePath"
            Write-Output "Next (in Git Bash): bash results.sh --user $User --script $(Split-Path -Leaf $remotePath) --wait 180"
            return
        }
        if ($status -eq 422 -or $attempt -eq 5) {
            throw "Upload failed (HTTP $status). Source retained: $Source"
        }
        Write-Warning "Upload interrupted or conflicted (HTTP $status); retrying $attempt/4."
        Start-Sleep -Milliseconds (([Math]::Pow(2, $attempt - 1) * 1000) + (Get-Random -Maximum 1000))
    }
} finally { Remove-Item -LiteralPath $tempDir -Recurse -Force }
