---
name: client-update
description: Handle a new WoW Forever client build for AltStableSync - check the newest API dump in C:\Projects\References against what this addon calls, re-verify the measured behaviour that sync depends on, and prepare the MEASURED_ON_BUILD bump PR. Use when the owner says there is a new build/API bump, "apidump done", "new api build", or the addon's login warning names a build other than MEASURED_ON_BUILD.
version: 1.0.0
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

# A new Forever client build

AltStableSync does **not** own the API dump tooling: the dump is taken and converted from the
AltStable repo (`..\AltStable\Tools\ForeverAPIDump\`, see AltStable's own `client-update` skill),
which writes `C:\Projects\References\forever-api-<version>.<build>.md`. This skill starts once that
file exists.

## Who does what

| Step | Who | What |
|---|---|---|
| 1. Dump + convert | owner + the AltStable session | `/apidump`, `/reload`, `Convert-Dump.ps1` in AltStable |
| 2. Diff | you | `pwsh ..\AltStable\Tools\ForeverAPIDump\Compare-Dumps.ps1` |
| 3. Sync-surface check | you | grep this repo for every changed name (below) |
| 4. Behaviour | **owner** pastes `/run` lines; you judge them | the probe lines in `docs/forever-api-notes.md` |
| 5. Bump PR | you | edits, tests, branch, PR (commit/push only when asked; never merge without approval) |

If no dump exists for the new build, say so and stop — never bump on an unmeasured build.

## 3. Sync-surface check

The diff's documented sections are the client. For every changed or removed function, event or
enum, grep `*.lua`, `tests/wow_stubs.lua` and `docs/forever-api-notes.md`. The surface this addon
lives on — any change here is a **finding, not a note**:

- action bars: `GetActionInfo`, `PickupAction`, `PlaceAction`, `GetCursorInfo`, `ClearCursor`, `C_ActionBar.*`
- spells/items: `C_Spell.*`, `C_SpellBook.*`, `FindBaseSpellByID`, `C_Item.PickupItem`
- macros: `GetMacroInfo`, `CreateMacro`, `EditMacro`, `GetNumMacros`, `PickupMacro`, `Constants.MacroConsts`
- bindings: `GetBinding`, `SetBinding`, `SaveBindings`, `LoadBindings`, `GetCurrentBindingSet`, `Enum.BindingSet`, `C_KeyBindings.*`
- `C_EditMode.*`, `C_CVar.*`, `C_EncodingUtil.*`, `C_SpecializationInfo.*`
- events: `ACTIONBAR_SLOT_CHANGED`, `SPELLS_CHANGED`, `UPDATE_MACROS`, `UPDATE_BINDINGS`, `PLAYER_REGEN_*`

## 4. Behaviour

The dump proves shape, not behaviour. The `/run` lines recorded under the probe section of
`docs/forever-api-notes.md` are re-run by the owner; compare against the recorded values. Chat
lines are capped at 255 characters — anything longer belongs in a probe slash command, not chat.
"It persisted" needs a **full client exit**, never a `/reload`.

## 5. The bump PR

Branch `build-<build>` from `main`:

1. `Core.lua` — `MEASURED_ON_BUILD = "<build>"` (silences the login warning).
2. `tests/wow_stubs.lua` — `GetBuildInfo()` returns the new build.
3. `docs/forever-api-notes.md` — a `## Build <version>.<build>` section: the diff summary, the
   behaviour lines as pasted, the verdict.

Then `luac -p` on touched files, `pwsh tests/run.ps1` green, `pwsh Tools/deploy.ps1`. Open the PR
only when the owner asks, and **never merge without the owner's approval**.
