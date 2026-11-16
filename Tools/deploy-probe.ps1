<#
    deploy-probe.ps1 - Deploy AltStableSyncProbe, a ForeverProbe module (#85).

    In order, each step stopping the rest if it refuses:
      1. ForeverProbe, the host (..\ForeverProbe, or $env:FOREVERPROBE), with its own deploy;
      2. the module's TOC and Lua into AddOns\AltStableSyncProbe (never legacy\, the old
         /syncprobe kept for porting; its TOC has the same folder and SavedVariables names).

    Never packaged: it lives under Tools/, which .pkgmeta ignores, and
    Tools/deploy.ps1 never copies it.

    Usage:
        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns"
    Then /reload in game and /fp steps sync stress.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ProbeDir = Join-Path $RepoRoot "Tools\AltStableSyncProbe"
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }
# The TOC names the Lua files, so a file added to it is deployed too (Measure.lua
# was left behind when #105 added it to the TOC only).
$toc = Join-Path $ProbeDir "AltStableSyncProbe.toc"
if (-not (Test-Path -LiteralPath $toc)) { Write-Error "Missing probe file: AltStableSyncProbe.toc"; exit 1 }
$LuaFiles = @(Get-Content -LiteralPath $toc | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.lua$' -and $_ -notmatch '^#' })
if ($LuaFiles.Count -eq 0) { Write-Error "AltStableSyncProbe.toc names no Lua file"; exit 1 }
$Files = @("AltStableSyncProbe.toc") + $LuaFiles

if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProbeDir $f))) { Write-Error "Missing probe file: $f"; exit 1 }
}
$luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
if (Test-Path -LiteralPath $luac) {
    foreach ($f in $LuaFiles) {
        & $luac -p (Join-Path $ProbeDir $f)
        if ($LASTEXITCODE -ne 0) { Write-Error "luac -p failed on $f"; exit 1 }
    }
    Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
} else {
    Write-Host "  luac -p SKIPPED (no $luac)" -ForegroundColor Yellow
}

# 1. The host.
$hostDeploy = Join-Path $ForeverProbe "Tools\deploy.ps1"
if (-not (Test-Path -LiteralPath $hostDeploy)) {
    Write-Error "ForeverProbe checkout not found at $ForeverProbe (or set `$env:FOREVERPROBE)"; exit 1
}
& pwsh -NoProfile -File $hostDeploy -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; AltStableSyncProbe was not touched"; exit 1 }

# 2. The module. The old probe's files (Probe.lua) go: the new TOC no longer
# loads them, and a stale copy would only confuse.
$dest = Join-Path (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath "AltStableSyncProbe"
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }
$old = Join-Path $dest "Probe.lua"
if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }
foreach ($f in $Files) { Copy-Item -LiteralPath (Join-Path $ProbeDir $f) -Destination (Join-Path $dest $f) -Force }
Write-Host "AltStableSyncProbe deployed to $dest." -ForegroundColor Green
Write-Host "In game: /console scriptErrors 1, /reload, then /fp steps sync stress (or /fp sync for the commands)." -ForegroundColor Yellow
