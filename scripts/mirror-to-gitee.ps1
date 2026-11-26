<#
.SYNOPSIS
    Mirror one Windows release to Gitee: push code + tag, create Release,
    upload assets, and write the latest.json manifest on the `update` branch.

.DESCRIPTION
    Design notes (read lib/services/update_service.dart before changing this):

    1. GitHub stays the single source of truth. Gitee is a mirror. Any failure
       here must NOT fail the GitHub release (workflow sets continue-on-error).
    2. The client never calls the Gitee API: anonymous calls get
       `403 Rate Limit Exceeded`. It only reads `update/latest.json` via raw
       (anonymous, no quota) and downloads the Release asset directly
       (verified: anonymous 200).
    3. Therefore download_url must be the fixed asset form:
       https://gitee.com/<owner>/<repo>/releases/download/<tag>/release.zip
    4. Idempotent: an existing tag/Release/asset is reused; the manifest is
       always overwritten with the newest version.

    NOTE: keep this file ASCII-only. PowerShell 5.1 decodes scripts without a
    BOM as ANSI(GBK) on Chinese Windows, which corrupts non-ASCII comments and
    silently breaks the script (same trap as the updater helper).

    Environment variables:
      GITEE_TOKEN      required, Gitee private token with `projects` scope
      GITEE_REPO       optional, owner/repo, default RuizeSun/class_score
      COMMIT_MESSAGE   optional, used to read the version (first line `build: x`)
      DIST_DIR         optional, artifact directory, default ./dist
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Section([string]$text) {
    Write-Host ''
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function Write-Info([string]$text) {
    Write-Host "  $text"
}

# ---------- 1. Read and validate input ----------
$token = $env:GITEE_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host 'GITEE_TOKEN is not configured, skipping Gitee mirror.' -ForegroundColor Yellow
    exit 0
}

$repo = $env:GITEE_REPO
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = 'RuizeSun/class_score' }
$parts = $repo.Split('/')
if ($parts.Count -ne 2) {
    throw "GITEE_REPO must be owner/repo, got: $repo"
}
$owner = $parts[0]
$repoName = $parts[1]

$distDir = $env:DIST_DIR
if ([string]::IsNullOrWhiteSpace($distDir)) { $distDir = './dist' }

# Same rule as the Extract step in flutter.yml: first line `build: <version>`.
# RELEASE_VERSION overrides it so a mirror can be re-run for an already-built
# release (workflow_dispatch backfill) without a new `build:` commit.
$version = $env:RELEASE_VERSION
if (-not [string]::IsNullOrWhiteSpace($version)) { $version = $version.Trim() }
if ([string]::IsNullOrWhiteSpace($version)) {
    $commitMessage = $env:COMMIT_MESSAGE
    if ([string]::IsNullOrWhiteSpace($commitMessage)) { $commitMessage = '' }
    foreach ($line in ($commitMessage -split "`r?`n")) {
        if ($line -match '^build:\s*(\S+)') { $version = $Matches[1].Trim(); break }
    }
}
if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Host 'Not a release commit (build: <version>), skipping Gitee mirror.' -ForegroundColor Yellow
    exit 0
}
$tag = $version

Write-Section "Gitee mirror $repo version $version"

# ---------- 2. Locate artifacts ----------
$zipPath = Join-Path $distDir 'release.zip'
$shaPath = Join-Path $distDir 'release.zip.sha256'
foreach ($f in @($zipPath, $shaPath)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing artifact: $f (did build-windows succeed?)" }
}
$zipSize = (Get-Item -LiteralPath $zipPath).Length
$shaValue = ((Get-Content -LiteralPath $shaPath -Raw) -replace '\s', '')
if ($shaValue -notmatch '^[0-9a-fA-F]{64}$') {
    throw "release.zip.sha256 is not a valid hash: $shaValue"
}
Write-Info ("artifact: release.zip {0:N0} bytes, sha256 {1}..." -f $zipSize, $shaValue.Substring(0, 12))
if ($zipSize -gt 100MB) {
    throw "release.zip is larger than the Gitee per-asset limit of 100MB"
}

# ---------- 3. Push code and tag ----------
Write-Section 'Push code and tag'
$remote = "https://oauth2:$token@gitee.com/$owner/$repoName.git"
git remote remove gitee 2>$null | Out-Null
git remote add gitee $remote
# Push the tag after main: creating the Release needs the tag to exist.
git push --quiet gitee "HEAD:refs/heads/main"
if ($LASTEXITCODE -ne 0) { throw 'Failed to push main to Gitee (resolve divergence manually first)' }
Write-Info 'main synced'

# The tag may already exist (re-run), skip in that case.
# NOTE: use ${tag} not $tag here. In PowerShell `$tag:` parses the colon as part
# of the variable name, so "refs/tags/$tag:refs/tags/$tag" silently becomes
# "refs/tags//tags/1.6.2" and git fails with "invalid refspec" (hit on 1.6.2).
$remoteTags = git ls-remote --tags gitee "refs/tags/${tag}"
if ([string]::IsNullOrWhiteSpace(($remoteTags -join ''))) {
    git push --quiet gitee "refs/tags/${tag}:refs/tags/${tag}"
    if ($LASTEXITCODE -ne 0) { throw "Failed to push tag $tag to Gitee" }
    Write-Info "tag $tag pushed"
} else {
    Write-Info "tag $tag already exists, skip"
}

# ---------- 4. Create Release (reuse when it exists) ----------
Write-Section 'Create Gitee Release'
$apiBase = "https://gitee.com/api/v5/repos/$owner/$repoName"
$headers = @{ 'Content-Type' = 'application/json;charset=UTF-8' }

$releaseBody = @{
    access_token     = $token
    tag_name         = $tag
    name             = "Release $version"
    body             = "Automated release for version $version"
    target_commitish = 'main'
} | ConvertTo-Json -Compress

try {
    $release = Invoke-RestMethod -Method Post -Uri "$apiBase/releases" -Headers $headers -Body $releaseBody
} catch {
    $detail = $_.ErrorDetails.Message
    Write-Info "Create Release failed (probably exists): $detail"
    $existing = Invoke-RestMethod -Uri "$apiBase/releases?access_token=$token&per_page=50"
    $release = $existing | Where-Object { $_.tag_name -eq $tag } | Select-Object -First 1
    if ($null -eq $release) { throw "Release $tag not created and not found: $detail" }
    Write-Info "reusing Release id=$($release.id)"
}
$releaseId = $release.id
Write-Info "Release id=$releaseId"

# ---------- 5. Upload assets (skip when present) ----------
Write-Section 'Upload Release assets'
$existingAttach = @()
try {
    $existingAttach = @(Invoke-RestMethod -Uri "$apiBase/releases/$releaseId/attach_files?access_token=$token")
} catch {
    Write-Info "reading existing assets failed (treat as none): $($_.Exception.Message)"
}
$existingNames = @($existingAttach | ForEach-Object { $_.name })

foreach ($file in @($zipPath, $shaPath)) {
    $name = Split-Path -Leaf $file
    if ($existingNames -contains $name) {
        Write-Info "$name exists, skip upload"
        continue
    }
    # multipart/form-data via curl.exe: hand-rolling boundaries in PS 5.1 is fragile
    $uploadUrl = "$apiBase/releases/$releaseId/attach_files?access_token=$token"
    & curl.exe -sS -f -X POST $uploadUrl -F "file=@$file" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload $name to Gitee" }
    Write-Info "$name uploaded"
}

# ---------- 6. Write latest.json on the update branch (client entry point) ----------
Write-Section 'Write latest.json manifest'
$downloadUrl = "https://gitee.com/$owner/$repoName/releases/download/$tag/release.zip"
$manifest = [ordered]@{
    version      = $version
    tag          = $tag
    notes        = "Automated release for version $version"
    download_url = $downloadUrl
    sha256       = $shaValue.ToLower()
    size         = $zipSize
    published_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$manifestJson = $manifest | ConvertTo-Json -Depth 3
Write-Info "download_url: $downloadUrl"

# Orphan branch so main history stays clean.
$work = Join-Path $env:RUNNER_TEMP 'gitee-manifest'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

Push-Location $work
try {
    git init --quiet --initial-branch=update
    git config user.name 'github-actions[bot]'
    git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    # UTF-8 without BOM: jsonDecode on the client rejects a BOM prefix.
    [System.IO.File]::WriteAllText(
        (Join-Path $work 'latest.json'),
        $manifestJson,
        (New-Object System.Text.UTF8Encoding($false))
    )
    git add latest.json
    git commit --quiet -m "chore(update): latest.json for $version"
    git push --quiet --force gitee 'HEAD:refs/heads/update'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to push update branch to Gitee' }
} finally {
    Pop-Location
}
Write-Info 'update branch updated'

# ---------- 7. Anonymous verification ----------
Write-Section 'Verify manifest and asset anonymously'
try {
    $rawUrl = "https://gitee.com/$owner/$repoName/raw/update/latest.json"
    $manifestCheck = Invoke-RestMethod -Uri $rawUrl -TimeoutSec 30
    if ($manifestCheck.version -ne $version) {
        throw "manifest version mismatch: expected $version, got $($manifestCheck.version)"
    }
    Write-Info "manifest readable anonymously: version=$($manifestCheck.version)"

    $head = Invoke-WebRequest -Uri $downloadUrl -Method Head -UseBasicParsing -TimeoutSec 30
    Write-Info "asset reachable anonymously: HTTP $($head.StatusCode)"
} catch {
    # Verification failure must not fail the release (raw may still cache 60s).
    Write-Host "  verification failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Gitee mirror done: $repo $version" -ForegroundColor Green
