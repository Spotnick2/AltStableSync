<#
    run.ps1 - Run all AltStableSync unit tests.

    Plain Lua 5.1 scripts (WoW's Lua - not whatever newer Lua is first on
    PATH) that load addon files against tests/wow_stubs.lua. Every
    tests/test_*.lua is picked up automatically.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Lua)) {
    Write-Error "Lua 5.1 interpreter not found at: $Lua  (pass -Lua <path>)"
    exit 1
}

# Run from the repo root so tests can dofile('tests/wow_stubs.lua') and
# loadfile('Core.lua') with paths relative to the project.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    $failed = 0
    $files = @(Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name)
    if ($files.Count -eq 0) { Write-Error "no tests/test_*.lua found - nothing would be proven"; exit 1 }
    foreach ($f in $files) {
        Write-Host "-- $($f.Name) --" -ForegroundColor Cyan
        & $Lua $f.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
        Write-Host ""
    }
    if ($failed -gt 0) {
        Write-Host "$failed test file(s) FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "All test files passed." -ForegroundColor Green
}
finally {
    Pop-Location
}
