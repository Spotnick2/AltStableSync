<#
    deploy-probe.ps1 - Deploy the throwaway AltStableSyncProbe addon (issue #2).

    Never packaged: it lives under Tools/, which .pkgmeta ignores, and
    Tools/deploy.ps1 never copies it.

    Usage:
        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "<flavour>\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$from = Join-Path $RepoRoot "Tools\AltStableSyncProbe"
if (-not (Test-Path $AddOnsPath)) { throw "AddOns path not found: $AddOnsPath" }

# /MIR: we own this folder wholesale. SavedVariables live in WTF\, not here.
$to = Join-Path $AddOnsPath "AltStableSyncProbe"
Write-Host "Deploying AltStableSyncProbe ..." -ForegroundColor Cyan
robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }

Write-Host "Done -> $to" -ForegroundColor Green
Write-Host ""
Write-Host "In-game (out of combat):" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1, /reload"
Write-Host "  /syncprobe                read-only sections, opens a copy window"
Write-Host "  /syncprobe place          one empty-slot write, read back, cleared"
Write-Host "  /syncprobe macro | bind | cvar   then FULL EXIT, relaunch, /syncprobe restart"
Write-Host "  /syncprobe clean          undo the restart-test markers"
