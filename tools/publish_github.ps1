#=============================================================================
# publish_github.ps1 -- create the GitHub repo and push, in one command
#
#   powershell -ExecutionPolicy Bypass -File tools\publish_github.ps1
#     -> asks for your Personal Access Token without echoing it
#
#   or: ... -Token ghp_xxx  [-Repo name] [-Private] [-Description "..."]
#
# Token: GitHub -> Settings -> Developer settings -> Personal access tokens
#   classic: scope "repo"
#   fine-grained: Administration = Read and write (create the repo)
#                 Contents       = Read and write (push)
#
# The script is idempotent: it reuses an existing repo instead of failing, and
# it never writes the token to disk or to .git/config (it is passed to git as a
# one-shot http.extraheader).
#
# NOTE: this file is intentionally ASCII-only.  PowerShell 5.1 reads a UTF-8
# file WITHOUT a BOM as ANSI, which mangles non-ASCII text inside the script
# itself and turns it into a syntax error.
#=============================================================================
[CmdletBinding()]
param(
    [string] $Token,
    [string] $Repo = 'dual-screen-fpga-wall',
    [string] $Description = 'Two Anlogic EG4S20 boards drive one 1280x480 seamless wall: no framebuffer, per-frame window-table broadcast, cross-seam drag/zoom/album, dual-screen Chinese marquee',
    [string[]] $Topics = @('fpga', 'anlogic', 'eg4s20', 'verilog', 'hdmi', 'video-wall', 'sdram', 'chinese'),
    [switch] $Private
)

$ErrorActionPreference = 'Stop'

if (-not $Token) {
    $sec = Read-Host 'Paste GitHub Personal Access Token (input hidden)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $Token) { throw 'no token, aborting' }

$api = 'https://api.github.com'
$hdr = @{
    Authorization          = "Bearer $Token"
    'User-Agent'           = 'wall-publish'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# --- 0. git and repo root ---------------------------------------------------
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) {
    $cand = 'C:\Program Files\Git\cmd\git.exe'
    if (Test-Path $cand) { $git = $cand } else { throw 'git not installed: winget install --id Git.Git -e' }
}
$root = (& $git rev-parse --show-toplevel 2>$null)
if (-not $root) { throw 'not a git repository: run git init -b main inside the wall folder first' }
Set-Location $root
Write-Host "git   : $git"
Write-Host "repo  : $root"

# --- 1. who am I ------------------------------------------------------------
$me = Invoke-RestMethod -Uri "$api/user" -Headers $hdr -Method Get
$owner = $me.login
Write-Host "github: $owner"

# --- 1b. attribute the commit to that account -------------------------------
& $git config user.name  $owner
& $git config user.email "$owner@users.noreply.github.com"
$n = [int](& $git rev-list --count HEAD)
if ($n -eq 1 -and -not (& $git remote)) {
    & $git commit --amend --no-edit --reset-author | Out-Null
    Write-Host "author: commit re-attributed to $owner"
}

# --- 2. create the repo (reuse if it exists) --------------------------------
$body = @{
    name        = $Repo
    description = $Description
    private     = [bool]$Private
    has_issues  = $true
    has_wiki    = $false
} | ConvertTo-Json
try {
    $r = Invoke-RestMethod -Uri "$api/user/repos" -Headers $hdr -Method Post -Body $body -ContentType 'application/json'
    Write-Host "created: $($r.full_name)"
} catch {
    $msg = $_.ErrorDetails.Message
    if ($msg -match 'already exists') {
        Write-Host "exists : reusing $owner/$Repo" -ForegroundColor Yellow
    } else {
        if ($msg -match 'Resource not accessible|not accessible by personal access token|403') {
            throw ("create failed: 403. A FINE-GRAINED token needs 'Administration: Read and write' " +
                   "AND repository access = 'All repositories' to create a repo. " +
                   "A CLASSIC token with the 'repo' scope is simpler and always works. Raw: $msg")
        }
        throw "create failed: $msg"
    }
}

# --- 3. topics --------------------------------------------------------------
try {
    $tb = @{ names = $Topics } | ConvertTo-Json
    Invoke-RestMethod -Uri "$api/repos/$owner/$Repo/topics" -Headers $hdr -Method Put -Body $tb -ContentType 'application/json' | Out-Null
    Write-Host "topics: $($Topics -join ', ')"
} catch { Write-Host "topics: skipped ($($_.Exception.Message))" -ForegroundColor DarkYellow }

# --- 4. push ----------------------------------------------------------------
$url = "https://github.com/$owner/$Repo.git"
$remotes = & $git remote
if ($remotes -contains 'origin') { & $git remote set-url origin $url } else { & $git remote add origin $url }
Write-Host "remote: origin -> $url"

$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
& $git -c "http.extraheader=Authorization: Basic $auth" push -u origin main
if ($LASTEXITCODE -ne 0) { throw 'push failed (does the token have Contents: write?)' }

Write-Host ''
Write-Host "DONE: https://github.com/$owner/$Repo" -ForegroundColor Green
Write-Host 'Next (optional): Releases -> new tag v1.0 -> attach the two .bit files'
