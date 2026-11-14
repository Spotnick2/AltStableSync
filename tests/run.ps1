<#
    run.ps1 - Syntax-check the addon and run every tests\test_*.lua under Lua 5.1,
    through WowTestKit at the commit tests\kit.pin names (its scripts\run.ps1),
    then the beta -> live transfer script's own self-test.

    Plain Lua 5.1 scripts (WoW's Lua - not whatever newer Lua is first on
    PATH) that load addon files against tests/wow_stubs.lua. Every
    tests/test_*.lua is picked up automatically.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev      # the ..\WowTestKit working copy, not the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

# The kit's runner syntax-checks the TOC's .lua files, then runs every
# tests\test_*.lua from the repo root, so tests can dofile('tests/wow_stubs.lua')
# and loadfile('Core.lua') with paths relative to the project.
& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Toc "AltStableSync.toc" -Lua $Lua
$failed = $LASTEXITCODE

# The beta -> live transfer script's own self-test (#12).
Write-Host "-- Transfer-Profiles.ps1 -SelfTest --" -ForegroundColor Cyan
& pwsh -NoProfile (Join-Path $RepoRoot "Tools/Transfer-Profiles.ps1") -SelfTest
if ($LASTEXITCODE -ne 0) { $failed = 1 }
if ($failed -ne 0) { Write-Host "Tests FAILED" -ForegroundColor Red; exit 1 }
Write-Host "All test files passed." -ForegroundColor Green
