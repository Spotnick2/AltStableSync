# AltStableSync — design

> The approved plan of 2026-10-06 (issue #1), adversarially reviewed by Codex before approval.
> Issue numbers below are the GitHub issues. Update this file when a decision changes; it is the
> design of record, and `AGENTS.md` points here.

## Context

AltStableSync is a new WoW: Forever addon (interface 16001, Lua 5.1, Vanilla content on the Mainline
codebase). It syncs a "profile" (action bars, macros, keybindings, then Edit Mode, CVars and addon
settings) across characters of the same class and role, with mandatory backups so a bad apply can
always be rolled back.

The day-one goal is **Nov 4, 2026 (Forever launch)**: profiles built on the beta are carried to live,
and fresh characters are synced on first login. Myslot v6.2.0 is the inspiration. Its model is
obsolete for this purpose: it uses manual paste strings, protobuf+CRC, StaticPopups, exact spell IDs
with no rank handling, clear-before-import, and `/myslot load` skips the backup.

Decisions the owner has made: the repo is **private until launch**. Beta→live is done by **copying the
SavedVariables file** (same machine). The addon is **personal use for now**: no CurseForge release
machinery, but the layout stays packager-ready. Never merge a PR without the owner's approval.

### Facts established by research (treat as given)

- **LibAccountSync cannot do beta→live.** By design it checks `wowProjectID` and `regionID` during
  discovery and also inside the proof/MAC (LibAccountSync `docs/PLAN.md:345,404,660`). It *can* sync
  between the owner's live WoW accounts (`50284074#1` ↔ `#12`): BNet game data, 32 KB cap (16 KB
  recommended), no delivery ack, no compression, `addon` tag plus an account-wide `store`. **The store
  holds a household key and must never be copied across flavours or exported.**
- **Characters on one WoW account already share account-wide SavedVariables.** Profiles stored there
  need no network at all. Network is only for the second WoW account.
- **Beta WTF layout** (measured on disk):
  - `_classic_beta_\WTF\Account\50284074#1\SavedVariables\` (account-wide).
  - Realm folder `70\`, character folders `Name-Surname\`.
  - The server-side caches (`bindings-cache.wtf`, `macros-cache.txt`, `edit-mode-cache-*`) are
    per-flavour, so Blizzard's own sync will not carry them to live.
  - The live Forever folder name is **unknown**, so tools take explicit paths.
- **Forever APIs present** (dump 70235):
  - Globals: `GetActionInfo`, `PickupAction`, `PlaceAction`, `GetCursorInfo`, `ClearCursor`,
    `PickupMacro`, `GetMacroInfo`, `CreateMacro`, `EditMacro`, `GetNumMacros`, `GetBinding`,
    `SetBinding`, `SaveBindings`, `GetCurrentBindingSet`.
  - `Enum.BindingSet`.
  - `C_Spell.PickupSpell`/`GetSpellName`/`GetBaseSpell`, `C_SpellBook.FindSpellBookSlotForSpell`/
    `IsSpellBookItemLowRank`, `C_Item.PickupItem`.
  - `C_EditMode.GetLayouts`/`SaveLayouts`/`ConvertLayoutInfoToString`/`ConvertStringToLayoutInfo`/
    `OnLayoutAdded`.
  - `C_EncodingUtil.SerializeCBOR`/`CompressString`/`EncodeBase64`. This is the same CBOR→Deflate→Base64
    scheme Blizzard's CooldownViewer uses.
  - `C_CVar.GetCVarInfo`.
  - `C_SpecializationInfo` and `C_ClassTalents` exist, but **no one has measured whether they return
    Vanilla data**.
- **Absent:** `PickupSpell`/`PickupItem`/`GetSpellInfo` globals, `MAX_*_MACROS` (nil; character
  macros start at 121), `EasyMenu`.
- **Hard rules inherited from siblings:**
  - **Never a StaticPopup.** It taints Blizzard's dialog pool; Quit then fails with
    `ADDON_ACTION_FORBIDDEN` (measured 70205). Use own prompt frames.
  - No protected work in combat.
  - `ReloadUI()` is protected; tell the user to `/reload`.
  - Read SavedVariables at ADDON_LOADED/PLAYER_LOGIN, never at file scope.
  - Verify persistence with a full client exit, not `/reload`.
  - Guard secret values.
  - Characters have surnames.
- **AltStable plugin hook exists:** `AltStable.RegisterPlugin({id,label,icon,OnActivate,...})`
  (`..\AltStable\Core.lua:3973`) adds a sidebar tab. A *non-LoadOnDemand* addon with
  `## OptionalDeps: AltStable` can call it today. It is not part of the documented public API
  (`docs/PUBLIC-API.md`, `PUBLIC_API_VERSION=1`): there is no Options toggle for external plugins
  (hardcoded `LOD_PLUGINS`, `Core.lua:3898`), and the skin helpers are unversioned internals.

## Recommended architecture

### Standalone addon first, AltStable plugin second

AltStableSync is its **own addon in its own repo**, fully functional without AltStable.

- It declares `## OptionalDeps: AltStable`.
- When AltStable is loaded, it registers a sidebar tab via `AltStable.RegisterPlugin` that hosts the
  same profile panel.
- The tab touches only a minimal surface (`RegisterPlugin` plus theme colours) to limit coupling to
  unversioned internals.
- An AltStable-side issue (filed only with the owner's OK) would formalise external plugins:
  - document `RegisterPlugin` and add a `PLUGIN_API_VERSION`;
  - let external plugins self-register for the Options toggle;
  - provide a small, stable skin surface.

This makes it AltStable's first external plugin without making AltStable a hard dependency.

**Why not inside the AltStable repo?** Sync writes protected game state (bars, bindings, macros) and
has its own risk profile, cadence and tests. Separating it keeps AltStable's sync wire and SV shape
untouched.

### Two different operations (from the Codex review)

- **Profile apply** is adaptive. It resolves the highest known rank within a *verified* spell family
  (it refuses on ambiguity, with an option to keep the selected rank) and skips unresolvable entries,
  marking them *deferred*.
- **Snapshot restore** is exact. It uses the original spell IDs, the raw binding list per set, and the
  full macro contents and scope. A backup is a snapshot, never a profile. Restore takes its own
  backup first.

### Data model (SavedVariables)

- `AltStableSyncDB` (account-wide):
  - `schema`.
  - `profiles[profileId] = { class, name, rev, updated, sourceChar, build, modules = { actions, macros, bindings, editmode?, cvars? } }`.
  - `backups[charKey] = ring of N (default 5) snapshots + 1 pinned "first-seen" snapshot`.
  - `charKey` = GUID, plus name/realm for display.
- `AltStableSyncChar` (per-character): `profileId`, `autoApply` (`off|ask|auto`), `lastAppliedRev`, per-module enable flags.
- `AltStableSyncLAS` (account-wide, **separate variable**): the LibAccountSync store only, so the
  transfer tool can strip it.
- `AltStableSyncDB.origin = { project, region, build, accountDir }`: a flavour fingerprint (see
  Beta → live).
- `AltStableSyncChar.pending = { profileId, rev, done = {op...}, deferred = {op...} }`.
  `lastAppliedRev` is set per module only when that module completes. Changing module flags triggers
  re-evaluation.
- Schema number only. Unknown or newer schemas are refused. No migration framework until a real
  change needs one.
- **Profiles have an opaque stable ID.** Class plus a user-chosen name ("Warrior – Tank") is metadata,
  never realm or GUID, so profiles survive the beta→live move. Spec-based auto-matching is deferred until the spec APIs are
  probed. Until then, a user-defined name stands in for the role.
- Module payloads are plain Lua tables in the SV, for readability and diffability. The **envelope**
  (CBOR→Deflate→Base64 plus schema and checksum, via `C_EncodingUtil`) is used only for export strings
  and LibAccountSync transfer.

### Safety model (non-negotiable)

1. **Automatic backup before every apply**, including auto-apply and slash-command applies. The
   restore path is itself an apply, so it backs up first too.
2. **Preview before write.** A diff summary ("14 slots change, 2 macros created, 3 bindings
   rebound") shown in our own prompt frame, modelled on AltStable's `Prompt.lua`.
3. **No clear-before-import.** Write per slot and verify after the write by reading back with
   `GetActionInfo`. Leave a slot untouched when its value can't be resolved (rank not learned, item
   not owned), mark it deferred, and offer a retry later (e.g. on `LEARNED_SPELL_IN_SKILL_LINE`).
   Empty profile slots leave the destination unchanged unless "clear" is chosen, and the preview
   shows it.
   - **Cursor hygiene:** require an empty cursor to start, validate `GetCursorInfo()` before every
     `PlaceAction`, and clear any displaced payload.
4. **Out of combat only.** A plain explicit op list with a completion record. Measure whether it needs
   yielding before adding a coroutine. `PLAYER_REGEN_DISABLED` stops it. On resume, the preview is
   re-run against current state.
5. **Readiness gate.** Capture and apply wait until the spellbook, macros and bindings report ready
   (`SPELLS_CHANGED`, `UPDATE_MACROS`, `UPDATE_BINDINGS` after login, per the probe), never on bare
   PLAYER_LOGIN.
6. **Validation:** schema and per-module version checks before apply.
7. **Rank resolution:** store the original spell ID, the name, and a spell-family key. On apply,
   resolve only within the verified family (the probe measures how ranks map).
8. **Bindings:** select the destination set explicitly (Character, per the probe) and snapshot it,
   plus the active-set choice. The policy is that the profile's commands win and displaced keys are
   shown in the preview, with both keys per command preserved. Verify after save and after a restart.
9. **Macros: account macros are never edited.**
   - An existing macro is reused only when its name, body *and* scope match.
   - Otherwise a **character** macro is created after checking limits.
   - All macro mutations run first. The name/body→index map is then rebuilt before any macro action
     is placed.
   - Macros are never deleted unless the user asks.
10. **`auto` = prior consent** for one specified profile and set of modules. New conflicts still
    prompt. Fresh characters default to `ask`, so a matching class is never treated as consent.

### Beta → live (Nov 4)

There is **no Lua parsing in PowerShell**; the addon owns the merge logic, where it can be tested in
Lua.

- **`Tools/Transfer-Profiles.ps1 -From <beta Account dir> -To <live Account dir>`**:
  - validates both account dirs and the exact SV path;
  - refuses while any `Wow*.exe` runs (checked again just before the write);
  - **refuses if the live `AltStableSync.lua` already exists**, unless `-Force`, which backs it up to
    `.pre-transfer-<ts>`;
  - copies to a temp file, then moves it into place;
  - prints source, destination and the profile count.

  On Nov 4 the live file will not exist yet, so this is a plain, safe copy.
- **In-game, the first load on a new flavour** happens when `origin` ≠ the current project/region/
  build/account. The addon then:
  - wipes `AltStableSyncLAS` *before* LibAccountSync is constructed (it never carries over);
  - moves every beta backup and character state into `imported.archive` (read-only, never attached
    to a live GUID);
  - keeps the profiles, flagged with build provenance;
  - stamps the new `origin`.
- Merging into an existing live install with collisions uses the M2 export string, not the script.
- **Launch gate.** The first live action is capture-only on one character, then a preview, then a
  manual apply, then a full exit and restart to verify, and only then `ask`/`auto` for the rest.
- Moving this into AltStableCompanion is a later, separate issue.

## Backlog

Milestones M0–M4 and the issues under them live on GitHub (`gh issue list`). If the time slips
before Nov 4, cut `auto` (#10) first, never backup/restore correctness.

## Review record

- **Plan critique:** done. Codex (medium effort, read-only, on stdin) reviewed this plan, and its
  findings are reconciled above.
  - Accepted:
    - exact restore separate from profile apply;
    - macro ownership and reindexing;
    - cursor hygiene;
    - explicit binding set and policy;
    - the pending/deferred record and readiness gate;
    - profiles-only transfer and opaque IDs;
    - `auto` as consent;
    - the vertical slice;
    - a minimal UI in M1;
    - the launch gate;
    - deferring LAS and the envelope;
    - no migration framework.
  - Diverged: instead of a restricted Lua parser in PowerShell, the script refuses when the
    destination exists, and the addon does the quarantine in Lua, where it is testable.
  - Kept, at the owner's request: AGENTS.md + CLAUDE.md and the copied skills, so this repo matches its
    siblings, with a lean label set.
- The full Codex verdict is posted on issue #1.
