<#
    Transfer-Profiles.ps1 - copy the AltStableSync catalog from a beta WoW
    account to a live one (#12, docs/DESIGN.md "Beta -> live").

    Usage, once per live WoW account, with every WoW client closed:
        pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>" -WhatIf
        pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>"
        pwsh Tools/Transfer-Profiles.ps1 ... -Force   # replace an existing live file (kept as .pre-transfer-<time>)
        pwsh Tools/Transfer-Profiles.ps1 -SelfTest    # no WoW install needed; runs on any OS

    Copies SavedVariables\AltStableSync.lua and nothing else: never
    AltStableSyncLink.lua (LibAccountSync's store must never cross flavours),
    never a per-character file. Refuses a source that assigns a value to
    AltStableSyncLAS (a line-level check of the client-written file, not Lua
    parsing; "= nil" is fine). The bytes checked are the bytes written: the
    source is read once. The addon validates the content on its first load.

    Real transfers run on Windows only (pwsh 7); the self-test runs anywhere.

    Exit codes: 0 done (or -WhatIf passed), 1 refused before any write,
    2 failed after the write phase began (the state and any backup are printed).
#>

#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$From,
    [string]$To,
    [switch]$Force,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3

$FileName = "AltStableSync.lua"

function Get-Sha([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-FileSha([string]$Path) { Get-Sha ([IO.File]::ReadAllBytes($Path)) }

# Any running WoW client: its name, or $null. The client rewrites
# SavedVariables on exit, so a running one would undo or clobber the copy.
$DefaultClientRunning = {
    $p = Get-Process | Where-Object { $_.ProcessName -like "Wow*" } | Select-Object -First 1
    if ($p) { "$($p.ProcessName) (pid $($p.Id))" }
}

# An Account directory: its full path and its WTF's parent (the "root").
function Resolve-AccountDir([string]$Label, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return @{ Error = "-$Label is required: the WTF\Account\<id> folder." } }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @{ Error = "-$Label not found: $Path" } }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $dir = [IO.DirectoryInfo]::new($full)
    if (-not $dir.Parent -or $dir.Parent.Name -ne "Account" -or -not $dir.Parent.Parent -or $dir.Parent.Parent.Name -ne "WTF" `
        -or -not $dir.Parent.Parent.Parent) {
        return @{ Error = "-$Label must be a WTF\Account\<id> folder: $full" }
    }
    @{ Error = $null; Full = $full; Root = $dir.Parent.Parent.Parent.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar) }
}

# The transfer. Returns @{ Code; Lines } and prints nothing, so the self-test
# can call it. ClientRunning, Hook, Fault, OsIsWindows and Stamp are seams for
# the self-test only; a real run passes none of them.
function Invoke-Transfer {
    param(
        [string]$From,
        [string]$To,
        [switch]$Force,
        [switch]$DryRun,
        [scriptblock]$ClientRunning = $DefaultClientRunning,
        [scriptblock]$Hook = {},
        [string]$Fault = "",
        [bool]$OsIsWindows = $IsWindows,
        [string]$Stamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    )
    $lines = [Collections.Generic.List[string]]::new()
    function Done([int]$Code) { @{ Code = $Code; Lines = $lines.ToArray() } }
    function Refuse([string]$Why) { $lines.Add("Refused, nothing written: $Why"); Done 1 }

    # .NET's non-overwriting File.Move checks then renames on Unix, which can
    # overwrite a file that appears in between; on Windows it is the native
    # move with overwrite off (Codex on the #12 plan).
    if (-not $OsIsWindows) { return Refuse "real transfers run on Windows only (-SelfTest runs anywhere)." }

    # 1. Paths.
    $f = Resolve-AccountDir "From" $From
    if ($f.Error) { return Refuse $f.Error }
    $t = Resolve-AccountDir "To" $To
    if ($t.Error) { return Refuse $t.Error }
    if ($f.Full -eq $t.Full) { return Refuse "-From and -To are the same folder." }
    # A scope rule for a beta -> live tool, not flavour detection.
    if ($f.Root -eq $t.Root) { return Refuse "-From and -To are in the same WoW folder ($($f.Root)); this copies beta to live. Linked accounts sync instead." }

    # 2. The client is closed.
    $running = & $ClientRunning
    if ($running) { return Refuse "close every WoW client first ($running is running), and keep them closed until this finishes." }

    # 3. The source, read ONCE: these bytes are checked, hashed and written.
    $src = Join-Path (Join-Path $f.Full "SavedVariables") $FileName
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return Refuse "no $FileName in $(Join-Path $f.Full 'SavedVariables')." }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($src)
    & $Hook "afterSnapshot" | Out-Null
    if ($bytes.Length -eq 0) { return Refuse "$src is empty." }
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF)
    $srcLines = $text -split "\r?\n"
    if (-not ($srcLines | Where-Object { $_.StartsWith("AltStableSyncDB = ", [StringComparison]::Ordinal) })) {
        return Refuse "$src has no 'AltStableSyncDB = ' line; it isn't AltStableSync's file."
    }
    foreach ($l in $srcLines) {
        if ($l -match '^\s*AltStableSyncLAS\s*=(.*)$' -and $Matches[1].Trim() -ne "nil") {
            return Refuse "$src assigns a value to AltStableSyncLAS (LibAccountSync's store must never cross flavours). An older version wrote it: log in on beta once with the current version and exit, and the client rewrites the file without it."
        }
    }
    $srcHash = Get-Sha $bytes

    # 4. The destination folder: never created (a typo'd account id fails here).
    $svDir = Join-Path $t.Full "SavedVariables"
    if (-not (Test-Path -LiteralPath $svDir -PathType Container)) {
        return Refuse "$svDir doesn't exist. Log that live account in once, exit the game, then run this again."
    }

    # 5. The destination file.
    $dest = Join-Path $svDir $FileName
    $backup, $oldHash = $null, $null
    if (Test-Path -LiteralPath $dest) {
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { return Refuse "$dest exists and isn't a file." }
        if (-not $Force) {
            return Refuse "$dest exists. This would replace that whole live catalog and its backups, not merge (merging is the export string, #17). -Force replaces it, keeping a copy."
        }
        [byte[]]$oldBytes = [IO.File]::ReadAllBytes($dest)
        $oldHash = Get-Sha $oldBytes
        $backup = "$dest.pre-transfer-$Stamp"
        if (Test-Path -LiteralPath $backup) { return Refuse "$backup already exists; wait a second and run again." }
    }

    # 6. -WhatIf: the preflight passed; nothing is written.
    if ($DryRun) {
        $lines.Add("Would copy $src ($($bytes.Length) bytes, SHA-256 $srcHash)")
        $lines.Add("        to $dest")
        if ($backup) { $lines.Add("Would first keep the current live file as $backup") }
        $lines.Add("Checks passed. This doesn't prove the writes will succeed. Run again without -WhatIf.")
        return Done 0
    }

    # Write phase. Any failure from here on exits 2 with the state printed.
    $tmp, $tmpCreated, $backupOk = $null, $false, $false
    function Fail([string]$Why) {
        $lines.Add("FAILED: $Why")
        try {
            try {
                if ($tmpCreated -and (Test-Path -LiteralPath $tmp)) {
                    if ($Fault -eq "cleanup") { throw "injected fault: cleanup" }
                    [IO.File]::Delete($tmp)
                }
            } catch { $lines.Add("Couldn't delete the temp file $tmp ($_). Delete it by hand.") }
            try {
                if (Test-Path -LiteralPath $dest -PathType Leaf) {
                    $h = Get-FileSha $dest
                    $what = if ($h -eq $srcHash) { "the beta catalog" } elseif ($oldHash -and $h -eq $oldHash) { "the live file as it was" } else { "something else" }
                    $lines.Add("The destination $dest now holds $what (SHA-256 $h).")
                } else { $lines.Add("The destination $dest is missing.") }
            } catch { $lines.Add("The destination's state is unknown ($_).") }
        } finally {
            if ($backupOk) {
                $lines.Add("Your previous live file is kept, verified, at $backup")
                $lines.Add("To put it back: Copy-Item -LiteralPath '$backup' -Destination '$dest' -Force")
            } elseif ($backup -and (Test-Path -LiteralPath $backup)) {
                $lines.Add("A backup at $backup did NOT verify; don't rely on it.")
            }
        }
        Done 2
    }
    function WriteNew([string]$Path, [byte[]]$Data, [string]$Kind) {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($Kind -eq "tmp") { Set-Variable -Name tmpCreated -Value $true -Scope 1 }
        try { $fs.Write($Data, 0, $Data.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    }

    try {
        # 7. Backup (with -Force): a new file, verified.
        if ($backup) {
            WriteNew $backup $oldBytes "backup"
            & $Hook "afterBackup" | Out-Null
            $h = Get-FileSha $backup
            if ($Fault -eq "backupVerify") { $h = "injected" }
            if ($h -ne $oldHash) { return Fail "the backup didn't verify. Nothing was replaced." }
            $backupOk = $true
        }

        # 8. Stage the snapshot next to the destination, verified.
        $tmp = Join-Path $svDir ("$FileName.transfer-{0}.tmp" -f [guid]::NewGuid().ToString("N").Substring(0, 12))
        WriteNew $tmp $bytes "tmp"
        & $Hook "afterStage" | Out-Null
        $h = Get-FileSha $tmp
        if ($Fault -eq "stageVerify") { $h = "injected" }
        if ($h -ne $srcHash) { return Fail "the staged copy didn't verify. Nothing was replaced." }

        # 9. Recheck: the client is still closed, the destination unchanged.
        & $Hook "beforeCommit" | Out-Null
        $running = & $ClientRunning
        if ($running) { return Fail "$running started. Nothing was replaced; close it and run again." }
        if ($oldHash) {
            if (-not (Test-Path -LiteralPath $dest -PathType Leaf) -or (Get-FileSha $dest) -ne $oldHash) {
                return Fail "the live file changed or vanished since the check. Nothing was replaced."
            }
        } elseif (Test-Path -LiteralPath $dest) {
            return Fail "a live $FileName appeared since the check. Nothing was replaced."
        }
    } catch { return Fail "$_" }

    # 10. Commit: a rename that never overwrites, or a replace in place
    # (never Move-Item -Force, which deletes the destination first).
    try {
        if ($Fault -eq "commit") { throw "injected fault: commit" }
        if ($oldHash) {
            if ($Fault -eq "commitAfterDelete") { [IO.File]::Delete($dest); throw "injected fault: commitAfterDelete" }
            # [NullString]: PowerShell would pass $null as "", which throws.
            [IO.File]::Replace($tmp, $dest, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $dest)
        }
    } catch { return Fail "couldn't put the copy in place ($_)." }
    & $Hook "afterCommit" | Out-Null

    # 11. Verify what landed.
    try {
        $h = Get-FileSha $dest
        if ($Fault -eq "verify") { $h = "injected" }
    } catch { return Fail "replaced, but the result can't be read back ($_)." }
    if ($h -ne $srcHash) { return Fail "replaced, but the result doesn't match the source." }

    # 12. Done.
    $lines.Add("Copied $src")
    $lines.Add("    to $dest ($($bytes.Length) bytes, SHA-256 $srcHash, verified)")
    if ($backup) { $lines.Add("The previous live file is kept at $backup") }
    $lines.Add("Next: pwsh Tools/deploy.ps1 -AddOnsPath `"<live>\Interface\AddOns`", log in, then /altsync list and /altsync status.")
    Done 0
}

# ---------------------------------------------------------------------------
# Self-test: fake beta and live trees in the temp folder, no WoW install.
# ---------------------------------------------------------------------------
function Invoke-SelfTest {
    $script:failures = 0
    $script:passes = 0
    function Check([string]$Name, [bool]$Ok, $Detail = $null) {
        if ($Ok) { $script:passes++ } else {
            $script:failures++
            Write-Host "FAIL $Name$(if ($null -ne $Detail) { ': ' + ($Detail | Out-String).Trim() })" -ForegroundColor Red
        }
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $SrcText = "`r`nAltStableSyncDB = {`r`n[`"presets`"] = {`r`n[`"name`"] = `"Soins rapides — Frère`",`r`n},`r`n[`"schema`"] = 8,`r`n}`r`n"
    $OldText = "`r`nAltStableSyncDB = {`r`n[`"schema`"] = 8,`r`n[`"live`"] = true,`r`n}`r`n"
    $LinkText = "`r`nAltStableSyncLAS = {`r`n[`"key`"] = `"secret`",`r`n}`r`n"
    $base = Join-Path ([IO.Path]::GetTempPath()) ("ass-transfer-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    function New-Tree([string]$Source = $SrcText, [switch]$Bom, [switch]$Link, [string]$Live = $null, [switch]$NoLiveSV) {
        $root = Join-Path $base ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $from = Join-Path (Join-Path (Join-Path (Join-Path $root "beta") "WTF") "Account") "A"
        $to = Join-Path (Join-Path (Join-Path (Join-Path $root "live") "WTF") "Account") "A"
        $fsv = Join-Path $from "SavedVariables"
        New-Item -ItemType Directory -Force $fsv | Out-Null
        New-Item -ItemType Directory -Force $to | Out-Null
        $tsv = Join-Path $to "SavedVariables"
        if (-not $NoLiveSV) { New-Item -ItemType Directory -Force $tsv | Out-Null }
        $b = $utf8.GetBytes($Source)
        if ($Bom) { $b = [byte[]](0xEF, 0xBB, 0xBF) + $b }
        [IO.File]::WriteAllBytes((Join-Path $fsv $FileName), $b)
        # A per-character file on each side: never read, never touched.
        foreach ($acct in @($from, $to)) {
            $c = Join-Path (Join-Path (Join-Path $acct "Realm") "Char") "SavedVariables"
            New-Item -ItemType Directory -Force $c | Out-Null
            [IO.File]::WriteAllText((Join-Path $c $FileName), "AltStableSyncChar = {}`r`n")
        }
        if ($Link) {
            [IO.File]::WriteAllText((Join-Path $fsv "AltStableSyncLink.lua"), $LinkText)
            if (-not $NoLiveSV) { [IO.File]::WriteAllText((Join-Path $tsv "AltStableSyncLink.lua"), $LinkText + "-- live`r`n") }
        }
        if ($Live) { [IO.File]::WriteAllBytes((Join-Path $tsv $FileName), $utf8.GetBytes($Live)) }
        @{ Root = $root; From = $from; To = $to; Src = (Join-Path $fsv $FileName); SV = $tsv; Dest = (Join-Path $tsv $FileName); Bytes = $b }
    }
    # Every file under the root, path -> hash.
    function State($Tree) {
        $s = @{}
        Get-ChildItem -LiteralPath $Tree.Root -Recurse -File | ForEach-Object { $s[$_.FullName] = Get-FileSha $_.FullName }
        $s
    }
    function Same($A, $B) {
        if ($A.Count -ne $B.Count) { return $false }
        foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $B[$k] -ne $A[$k]) { return $false } }
        $true
    }
    function Run($Tree, [hashtable]$More = @{}) {
        $a = @{ From = $Tree.From; To = $Tree.To; OsIsWindows = $true; ClientRunning = { $null } }
        foreach ($k in $More.Keys) { $a[$k] = $More[$k] }
        Invoke-Transfer @a
    }
    function Bytes([string]$Path) { if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllBytes($Path) } }
    function Eq([byte[]]$A, [byte[]]$B) { $null -ne $A -and $null -ne $B -and (Get-Sha $A) -eq (Get-Sha $B) }
    function NoTmp($Tree) { -not (Get-ChildItem -LiteralPath $Tree.SV -Filter "*.tmp" -ErrorAction SilentlyContinue) }
    function Backups($Tree) { @(Get-ChildItem -LiteralPath $Tree.SV -Filter "$FileName.pre-transfer-*" -ErrorAction SilentlyContinue) }
    function Says($R, [string]$Text) { [bool]($R.Lines | Where-Object { $_ -like "*$Text*" }) }

    try {
        # Success, byte for byte: no BOM, BOM, non-ASCII.
        foreach ($bom in @($false, $true)) {
            $tr = New-Tree -Bom:$bom
            $r = Run $tr
            Check "copy (bom=$bom): exit 0" ($r.Code -eq 0) $r.Lines
            Check "copy (bom=$bom): same bytes" (Eq (Bytes $tr.Dest) $tr.Bytes)
            Check "copy (bom=$bom): no temp file" (NoTmp $tr)
            Check "copy (bom=$bom): no backup" (@(Backups $tr).Count -eq 0)
            Check "copy (bom=$bom): source unchanged" (Eq (Bytes $tr.Src) $tr.Bytes)
        }

        # A BOM right before the first line: still recognised.
        $tr = New-Tree -Bom -Source $SrcText.TrimStart()
        $r = Run $tr
        Check "BOM on the AltStableSyncDB line: accepted" ($r.Code -eq 0) $r.Lines
        Check "BOM on the AltStableSyncDB line: same bytes" (Eq (Bytes $tr.Dest) $tr.Bytes)

        # A BOM right before an AltStableSyncLAS line: still refused.
        $tr = New-Tree -Bom -Source ("AltStableSyncLAS = {}" + $SrcText)
        $r = Run $tr
        Check "BOM on the AltStableSyncLAS line: refused" ($r.Code -eq 1 -and (Says $r "AltStableSyncLAS")) $r.Lines

        # A41: non-empty Link stores on both sides don't block, and stay as they were;
        # with none, none appears. Per-character files are never touched.
        $tr = New-Tree -Link
        $before = State $tr
        $r = Run $tr
        $after = State $tr
        Check "A41 link present: exit 0" ($r.Code -eq 0) $r.Lines
        foreach ($k in @($before.Keys)) {
            if ($k -ne $tr.Dest) { Check "A41 link present: unchanged $k" ($after[$k] -eq $before[$k]) }
        }
        Check "A41 link present: only the destination added" ($after.Count -eq $before.Count + 1)
        $tr = New-Tree
        $r = Run $tr
        Check "A41 link absent: exit 0" ($r.Code -eq 0) $r.Lines
        Check "A41 link absent: none appears" (-not (Test-Path -LiteralPath (Join-Path $tr.SV "AltStableSyncLink.lua")))

        # The LAS line check.
        $ok = @(
            @("= nil", ($SrcText + "AltStableSyncLAS = nil`r`n")),
            @("a table key", ($SrcText.Replace("[`"schema`"] = 8,", "[`"AltStableSyncLAS`"] = { 1 },`r`n[`"schema`"] = 8,")))
        )
        foreach ($c in $ok) {
            $tr = New-Tree -Source $c[1]
            $r = Run $tr
            Check "LAS $($c[0]): accepted" ($r.Code -eq 0) $r.Lines
        }
        $bad = @(
            @("a table", ($SrcText + "AltStableSyncLAS = {`r`n[`"k`"] = 1,`r`n}`r`n")),
            @("indented string", ($SrcText + "  AltStableSyncLAS = `"x`"`r`n")),
            @("no spaces", ($SrcText + "AltStableSyncLAS={}`r`n"))
        )
        foreach ($c in $bad) {
            $tr = New-Tree -Source $c[1]
            $before = State $tr
            $r = Run $tr
            Check "LAS $($c[0]): refused" ($r.Code -eq 1 -and (Says $r "AltStableSyncLAS")) $r.Lines
            Check "LAS $($c[0]): nothing written" (Same $before (State $tr))
        }

        # Not this addon's file; empty; missing.
        $tr = New-Tree -Source "`r`nSomethingElseDB = {}`r`n"
        $r = Run $tr
        Check "no AltStableSyncDB: refused" ($r.Code -eq 1 -and (Says $r "isn't AltStableSync's file")) $r.Lines
        $tr = New-Tree -Source ""
        $r = Run $tr
        Check "empty source: refused" ($r.Code -eq 1 -and (Says $r "is empty")) $r.Lines
        $tr = New-Tree
        Remove-Item -LiteralPath $tr.Src
        $r = Run $tr
        Check "missing source: refused" ($r.Code -eq 1 -and (Says $r "no $FileName")) $r.Lines

        # Paths.
        $tr = New-Tree -NoLiveSV
        $r = Run $tr
        Check "no live SavedVariables: refused" ($r.Code -eq 1 -and (Says $r "Log that live account in once")) $r.Lines
        Check "no live SavedVariables: not created" (-not (Test-Path -LiteralPath $tr.SV))
        $tr = New-Tree
        $r = Run $tr @{ To = $tr.From }
        Check "same folder: refused" ($r.Code -eq 1 -and (Says $r "the same folder")) $r.Lines
        $tr = New-Tree
        $other = Join-Path (Split-Path -Parent $tr.From) "B"
        New-Item -ItemType Directory -Force (Join-Path $other "SavedVariables") | Out-Null
        $r = Run $tr @{ To = $other }
        Check "same root: refused" ($r.Code -eq 1 -and (Says $r "same WoW folder")) $r.Lines
        $r = Run $tr @{ To = $tr.SV }
        Check "not WTF\Account\<id>: refused" ($r.Code -eq 1 -and (Says $r "must be a WTF")) $r.Lines
        $r = Run $tr @{ From = (Join-Path $tr.Root "nowhere") }
        Check "missing -From: refused" ($r.Code -eq 1 -and (Says $r "-From not found")) $r.Lines
        $r = Run $tr @{ From = "" }
        Check "blank -From: refused" ($r.Code -eq 1 -and (Says $r "-From is required")) $r.Lines
        $r = Run $tr @{ OsIsWindows = $false }
        Check "not Windows: refused" ($r.Code -eq 1 -and (Says $r "Windows only")) $r.Lines
        Check "not Windows: nothing written" (-not (Test-Path -LiteralPath $tr.Dest))

        # An existing live file: refused; -Force keeps a verified copy.
        $tr = New-Tree -Live $OldText
        $r = Run $tr
        Check "live exists: refused" ($r.Code -eq 1 -and (Says $r "not merge")) $r.Lines
        Check "live exists: unchanged" (Eq (Bytes $tr.Dest) $utf8.GetBytes($OldText))
        $r = Run $tr @{ Force = $true; Stamp = "T1" }
        Check "-Force: exit 0" ($r.Code -eq 0) $r.Lines
        Check "-Force: new bytes" (Eq (Bytes $tr.Dest) $tr.Bytes)
        Check "-Force: backup has the old bytes" (Eq (Bytes "$($tr.Dest).pre-transfer-T1") $utf8.GetBytes($OldText))
        Check "-Force: no temp file" (NoTmp $tr)
        $tr = New-Tree -Live $OldText
        [IO.File]::WriteAllText("$($tr.Dest).pre-transfer-T2", "older")
        $before = State $tr
        $r = Run $tr @{ Force = $true; Stamp = "T2" }
        Check "backup name taken: refused" ($r.Code -eq 1 -and (Says $r "already exists")) $r.Lines
        Check "backup name taken: nothing written" (Same $before (State $tr))

        # -WhatIf: a read-only preflight.
        foreach ($case in @(@{ n = "new"; live = $null; force = $false }, @{ n = "force"; live = $OldText; force = $true })) {
            $tr = New-Tree -Live $case.live
            $before = State $tr
            $r = Run $tr @{ DryRun = $true; Force = $case.force }
            Check "-WhatIf ($($case.n)): exit 0" ($r.Code -eq 0 -and (Says $r "Would copy")) $r.Lines
            Check "-WhatIf ($($case.n)): nothing written" (Same $before (State $tr))
        }

        # The source swapped after the snapshot: the snapshot travels.
        $tr = New-Tree
        $swap = { param($step) if ($step -eq "afterSnapshot") { [IO.File]::WriteAllText($tr.Src, $SrcText + "AltStableSyncLAS = {}`r`n") } }.GetNewClosure()
        $r = Run $tr @{ Hook = $swap }
        Check "source swapped: exit 0" ($r.Code -eq 0) $r.Lines
        Check "source swapped: the checked bytes travel" (Eq (Bytes $tr.Dest) $tr.Bytes)

        # The destination appears or changes before the commit.
        $tr = New-Tree
        $appear = { param($step) if ($step -eq "beforeCommit") { [IO.File]::WriteAllText($tr.Dest, "appeared") } }.GetNewClosure()
        $r = Run $tr @{ Hook = $appear }
        Check "appeared: exit 2" ($r.Code -eq 2 -and (Says $r "appeared since")) $r.Lines
        Check "appeared: left as it is" ([IO.File]::ReadAllText($tr.Dest) -eq "appeared")
        Check "appeared: no temp file" (NoTmp $tr)
        $tr = New-Tree -Live $OldText
        $change = { param($step) if ($step -eq "beforeCommit") { [IO.File]::WriteAllText($tr.Dest, "changed") } }.GetNewClosure()
        $r = Run $tr @{ Hook = $change; Force = $true; Stamp = "T3" }
        Check "changed: exit 2" ($r.Code -eq 2 -and (Says $r "changed or vanished")) $r.Lines
        Check "changed: left as it is" ([IO.File]::ReadAllText($tr.Dest) -eq "changed")
        Check "changed: backup kept" (Eq (Bytes "$($tr.Dest).pre-transfer-T3") $utf8.GetBytes($OldText) -and (Says $r "To put it back"))
        Check "changed: no temp file" (NoTmp $tr)

        # Faults.
        $tr = New-Tree -Live $OldText
        $r = Run $tr @{ Force = $true; Fault = "backupVerify"; Stamp = "F1" }
        Check "backupVerify: exit 2" ($r.Code -eq 2 -and (Says $r "backup didn't verify")) $r.Lines
        Check "backupVerify: destination untouched" (Eq (Bytes $tr.Dest) $utf8.GetBytes($OldText))
        Check "backupVerify: no recovery line for an unverified backup" (-not (Says $r "To put it back") -and (Says $r "did NOT verify"))
        $tr = New-Tree -Live $OldText
        $r = Run $tr @{ Force = $true; Fault = "stageVerify"; Stamp = "F2" }
        Check "stageVerify: exit 2" ($r.Code -eq 2 -and (Says $r "staged copy didn't verify")) $r.Lines
        Check "stageVerify: destination untouched" (Eq (Bytes $tr.Dest) $utf8.GetBytes($OldText))
        Check "stageVerify: temp deleted" (NoTmp $tr)
        Check "stageVerify: backup kept" (Eq (Bytes "$($tr.Dest).pre-transfer-F2") $utf8.GetBytes($OldText))
        $tr = New-Tree
        $r = Run $tr @{ Fault = "commit" }
        Check "commit: exit 2" ($r.Code -eq 2 -and (Says $r "couldn't put the copy in place")) $r.Lines
        Check "commit: says the destination is missing" (Says $r "is missing") $r.Lines
        Check "commit: temp deleted" (NoTmp $tr)
        $tr = New-Tree -Live $OldText
        $r = Run $tr @{ Force = $true; Fault = "commitAfterDelete"; Stamp = "F3" }
        Check "commitAfterDelete: exit 2" ($r.Code -eq 2) $r.Lines
        Check "commitAfterDelete: says missing" (Says $r "is missing") $r.Lines
        Check "commitAfterDelete: recovery line" (Says $r "To put it back") $r.Lines
        Check "commitAfterDelete: backup intact" (Eq (Bytes "$($tr.Dest).pre-transfer-F3") $utf8.GetBytes($OldText))
        Check "commitAfterDelete: temp removed" (NoTmp $tr)
        $tr = New-Tree -Live $OldText
        $r = Run $tr @{ Force = $true; Fault = "cleanup"; Stamp = "F4"; ClientRunning = { $null } ; Hook = { param($s) if ($s -eq "beforeCommit") { throw "boom" } } }
        Check "cleanup: exit 2" ($r.Code -eq 2) $r.Lines
        Check "cleanup: names the temp file" (Says $r "Couldn't delete the temp file") $r.Lines
        Check "cleanup: recovery line still printed" (Says $r "To put it back") $r.Lines
        $tr = New-Tree -Live $OldText
        $r = Run $tr @{ Force = $true; Fault = "verify"; Stamp = "F5" }
        Check "verify: exit 2" ($r.Code -eq 2 -and (Says $r "doesn't match")) $r.Lines
        Check "verify: recovery line" (Says $r "To put it back") $r.Lines

        # A running client: at the start, and between the checks.
        $tr = New-Tree
        $r = Run $tr @{ ClientRunning = { "WowClassic (pid 1)" } }
        Check "client at start: refused" ($r.Code -eq 1 -and (Says $r "WowClassic")) $r.Lines
        Check "client at start: nothing written" (-not (Test-Path -LiteralPath $tr.Dest) -and (NoTmp $tr))
        $tr = New-Tree -Live $OldText
        $n = @{ calls = 0 }
        $flip = { $n.calls++; if ($n.calls -ge 2) { "WowClassic (pid 2)" } }.GetNewClosure()
        $r = Run $tr @{ ClientRunning = $flip; Force = $true; Stamp = "C1" }
        Check "client at recheck: exit 2" ($r.Code -eq 2 -and (Says $r "WowClassic")) $r.Lines
        Check "client at recheck: destination unchanged" (Eq (Bytes $tr.Dest) $utf8.GetBytes($OldText))
        Check "client at recheck: no temp file" (NoTmp $tr)
    } finally {
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
    $color = if ($script:failures -eq 0) { "Green" } else { "Red" }
    Write-Host "Transfer-Profiles self-test: $($script:passes) passed, $($script:failures) failed" -ForegroundColor $color
    if ($script:failures -eq 0) { 0 } else { 1 }
}

if ($SelfTest) { exit (Invoke-SelfTest) }

if (-not $From -or -not $To) {
    Write-Host 'Usage: pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>" [-Force] [-WhatIf]'
    exit 1
}
$result = Invoke-Transfer -From $From -To $To -Force:$Force -DryRun:$WhatIfPreference
foreach ($l in $result.Lines) { Write-Host $l }
exit $result.Code
