<#
    deploy.ps1 - Deploy AltStableSync to the WoW: Forever AddOns folder.

    Usage:
        pwsh Tools/deploy.ps1
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\Games\WoW\<flavour>\Interface\AddOns"

    The default is the beta (_classic_beta_). The live Forever flavour folder
    is not known yet - pass -AddOnsPath for it.

    LibGlass-1.0 is the embedded external (.pkgmeta). For a dev copy this
    script hands that job to the LibGlass checkout's own deploy.ps1, FIRST
    ($env:LIBGLASS, else ..\LibGlass), which checks the checkout and may refuse.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Addon = "AltStableSync"

if (-not (Test-Path $AddOnsPath)) {
    throw "AddOns path not found: $AddOnsPath"
}

$dest = Join-Path $AddOnsPath $Addon

$glassRoot = if ($env:LIBGLASS) { $env:LIBGLASS } else { Join-Path (Split-Path -Parent $RepoRoot) "LibGlass" }
if (-not (Test-Path -LiteralPath (Join-Path $glassRoot "Tools\deploy.ps1"))) {
    throw "LibGlass checkout not found at $glassRoot (clone github.com/Spotnick2/LibGlass there, or set `$env:LIBGLASS)"
}

# The tag .pkgmeta pins is what a release would ship. Another checkout state is
# legitimate (trying a library change), but say so.
$pin = $null; $inBlock = $false
foreach ($line in Get-Content -LiteralPath (Join-Path $RepoRoot ".pkgmeta")) {
    if ($line -match '^  (\S+):\s*$') { $inBlock = ($Matches[1] -eq "Libs/LibGlass-1.0"); continue }
    if ($line -match '^\S') { $inBlock = $false }
    if ($inBlock -and $line -match '^\s+(commit|tag):\s*(\S+)\s*$') { $pin = $Matches[2]; break }
}
if (-not $pin) {
    # A reformatted .pkgmeta must not switch the pin check off silently.
    Write-Host "  WARNING: could not read the LibGlass pin from .pkgmeta - the checkout was not checked against it" -ForegroundColor Yellow
} else {
    $want = $null; $head = $null; $dirty = $null
    try {
        $want = (git -C $glassRoot rev-parse --verify --quiet "$pin^{commit}" 2>$null)
        $head = (git -C $glassRoot rev-parse HEAD 2>$null)
        $dirty = (git -C $glassRoot status --porcelain 2>$null)
    } catch { }
    if (-not $want -or $want -ne $head -or $dirty) {
        Write-Host "  WARNING: the LibGlass checkout is not at the .pkgmeta pin ($pin)$(if ($dirty) { ', or has uncommitted changes' })" -ForegroundColor Yellow
    }
}

# The library first: a refusal must leave the deployed addon as it was.
& pwsh -NoProfile -File (Join-Path $glassRoot "Tools\deploy.ps1") -Addon $Addon -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { throw "LibGlass deploy refused; $Addon was not touched" }

Write-Host "Deploying $Addon ..." -ForegroundColor Cyan

# /E copies without purging. robocopy exit codes 0-7 are success.
$excludeDirs = @(
    (Join-Path $RepoRoot "Tools"),
    (Join-Path $RepoRoot "tests"),
    (Join-Path $RepoRoot "docs"),
    (Join-Path $RepoRoot "dist"),
    (Join-Path $RepoRoot "Libs\LibGlass-1.0"),
    # Every dot-entry: .git (a FILE in a worktree), .github, .claude, .vscode, ...
    ".*"
)
# Mirror .gitignore's captures too: robocopy doesn't read it, and a pulled
# SavedVariables capture carries real names, macros and bindings.
$excludeFiles = @("*.log", "*.zip", "*.md", ".*", "*.sv.lua", "*.bak")

$roboArgs = @($RepoRoot, $dest, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
              "/XD") + $excludeDirs + @("/XF") + $excludeFiles
robocopy @roboArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }

# /E never purges: remove what an older deploy may have left that this one
# excludes - dot-entries, the development folders, captures - and only those,
# and only inside the addon's own folder.
$leftovers = @(Get-ChildItem -LiteralPath $dest -Force -Filter ".*") +
             @(foreach ($d in "Tools", "tests", "docs", "dist") {
                   Get-Item -LiteralPath (Join-Path $dest $d) -Force -ErrorAction SilentlyContinue }) +
             @(Get-ChildItem -LiteralPath $dest -Recurse -Force -File -Include "*.sv.lua", "*.bak" -ErrorAction SilentlyContinue)
foreach ($item in $leftovers) {
    if (-not $item -or -not (Test-Path -LiteralPath $item.FullName)) { continue }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
    Write-Host "  removed leftover $($item.Name)" -ForegroundColor DarkYellow
}

# @project-version@ is substituted in the DEPLOYED copy only. Never commit a
# literal version over the keyword (it has happened twice on sibling projects).
$rev = $null; $dirty = $null
try {
    $rev = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
    $dirty = (git -C $RepoRoot status --porcelain 2>$null)
} catch { $rev = $null }
# -dirty: the deployed code is not that commit, so an in-game check must not
# be recorded against it.
$label = if ($rev) { "dev-$rev$(if ($dirty) { '-dirty' })" } else { "dev" }
$toc = Join-Path $dest "$Addon.toc"
(Get-Content $toc -Raw).Replace('@project-version@', $label) | Set-Content $toc -NoNewline
Write-Host "  version -> $label (deployed copy only)" -ForegroundColor DarkGray

Write-Host "Done -> $dest" -ForegroundColor Green
Write-Host ""
Write-Host "In-game:" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1   (errors are OFF by default on this client)"
Write-Host "  /reload"
Write-Host "  /altsync"
