# AGENTS.md — Shared Context for Agents

Shared baseline for any agent working in this repo (Claude Code, Codex, Copilot all read
`AGENTS.md`). Keep durable project rules here. `CLAUDE.md` is a Claude-specific overlay; where the
two overlap, this file wins. The design of record is `docs/DESIGN.md`.

## Review and merge policy

- **Never merge a PR without the owner's explicit approval.** Not after a green CI, not after a
  clean Codex review, not when asked to "finish up". Open it, review it, report, and stop.
- Use `$wow-addon-review` (the shared Codex skill) as the source of truth for review routing,
  client/API evidence handling and merge-readiness verdicts. The PR-level Codex pass is in
  `docs/WORKFLOW.md`.
- Post every PR review and follow-up review on the PR, and link it in the final response.

## What this project is

AltStableSync is a **World of Warcraft: Forever addon** (interface `16001`) in **Lua 5.1**. It
syncs a *profile* — action bars, macros, keybindings, later Edit Mode, CVars and addon settings —
across characters of the same class and role, with an automatic backup before every write.

It is a companion to `..\AltStable` (the alt tracker) and becomes its first **external plugin**:
standalone, `## OptionalDeps: AltStable`, with a sidebar tab when AltStable is present (#19).

- **Target:** WoW: Forever only — Vanilla content on Blizzard's **Mainline (Retail) codebase**.
  Classic/TBC-era API advice is usually stale; Lua 5.1 semantics still apply.
- **Namespace:** one global table `AltStableSync`; every file starts `AltStableSync = AltStableSync or {}`
  (file-local alias `ASS`).
- **SavedVariables:** `AltStableSyncDB` (account-wide: schema, profiles, backups, origin),
  `AltStableSyncLAS` (account-wide, the LibAccountSync store **only**), `AltStableSyncChar` (per
  character). Read them at ADDON_LOADED, never at file scope. "It persisted" needs a **full client
  exit**, never a `/reload`.
- **Day-one goal:** the Forever launch on **2026-11-04** — beta profiles carried to live by copying
  the SavedVariables file, then fresh characters synced on first login (M1 milestone).

The canonical, addon-agnostic Forever porting guide is
`C:\Projects\References\PORTING-TBC-TO-FOREVER.md`; the API dump is
`C:\Projects\References\forever-api-<version>.<build>.md`. Addon-specific measurements go in
`docs/forever-api-notes.md`. `MEASURED_ON_BUILD` in `Core.lua` names the build they describe.

## The safety rules (non-negotiable)

This addon writes the player's bars, macros and bindings. A bug here destroys a setup someone built
over months. The full model is in `docs/DESIGN.md`; the short form:

1. **Backup before every apply** — auto, prompted, slash command, and restore itself.
2. **Preview before write**, in our own prompt frame. **Never a StaticPopup** (it taints
   Blizzard's dialog pool; Quit then fails with `ADDON_ACTION_FORBIDDEN`, measured 70205).
3. **Profile apply is adaptive; snapshot restore is exact.** Never conflate them.
4. **No clear-before-import.** Per-slot writes, verified by reading back; unresolvable entries are
   deferred and left untouched.
5. **Account macros are never edited.** Reuse only on name + body + scope match; otherwise create a
   character macro. Macro mutations first, reindex, then place.
6. **Bindings go to an explicitly selected set**, never "whatever is current".
7. **Out of combat only**; combat stops the op list and leaves a pending record.
8. **Refuse unknown or newer schemas** — never best-effort parse saved data.
9. **The LibAccountSync store never travels**: not in exports, not across flavours (#11).
10. **`auto` is prior consent** for one profile and module set; a matching class is never consent.

## Layout

Lua files at the repo root, loaded in the order listed in `AltStableSync.toc` (order matters):
`Libs\LibGlass-1.0\LibGlass-1.0.xml` → `Libs\LibStub\LibStub.lua` → `Core.lua` → (modules as they
land).

- `Libs/LibGlass-1.0/` — the glass material, a `.pkgmeta` external pinned to a tag, **gitignored**,
  deployed from `..\LibGlass` by `Tools/deploy.ps1`. Material changes are LibGlass PRs, never edits
  here; never edit `..\LibGlass` from this repo's session.
- `Libs/LibAccountSync-1.0/` — joins with #18 (cross-account sync), same embedding rules. It
  **cannot** carry beta → live: project and region are part of its proof, by design.
- `tests/` — Lua 5.1 unit tests. `Tools/` — deploy and transfer scripts (never ship).
- `docs/` — `DESIGN.md`, `WORKFLOW.md`, `RUNBOOK.md`, `forever-api-notes.md`.

## Build & validate

No build step. The Lua 5.1 toolchain is at `C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`).

- `luac -p <file>.lua` on every changed file (clean prints nothing).
- `pwsh tests/run.ps1` green before every commit.

## Testing

- `tests/wow_stubs.lua` is a minimal **Forever-shaped** WoW mock driven through the `WoW` table
  (`WoW.reset()`, `WoW.fire(event, ...)`, `WoW.chat()`). A stub that returns a Classic tuple where
  the client returns a struct makes a broken port pass — stub fidelity is part of the review surface.
- A test `dofile`s the stubs, `loadfile`s the module, sets SavedVariables, fires `ADDON_LOADED`.
- File-local internals are reached through the `AltStableSync._test` seam; extend it rather than
  promoting internals to globals.
- Add `tests/test_<area>.lua`; `run.ps1` and CI pick it up.
- **Mutation-test claims.** Break the behaviour deliberately and watch the suite go red before
  trusting a test. Anything in the safety rules above needs a test that fails when the rule is broken.

## Deploying for in-game testing

```
pwsh Tools/deploy.ps1                                    # beta (_classic_beta_)
pwsh Tools/deploy.ps1 -AddOnsPath "<flavour>\Interface\AddOns"
```

Calls LibGlass's own deploy first, then copies the addon additively (`robocopy /E`), excluding
`Tools/`, `tests/`, `docs/` and dot-entries, and substitutes `@project-version@` in the **deployed
copy only**. Never commit a literal version over that keyword. Then `/reload` in game. See
`docs/RUNBOOK.md`.

## Conventions

- **Right-size for a single maintainer.** Prefer the simplest thing that works — except where the
  safety rules say otherwise. Rigor that protects the player's setup is not over-engineering;
  rigor anywhere else usually is.
- **Match the surrounding code**; file-local aliases, `ASS.*` attachment, table-driven definitions.
- **Propose, don't expand.** Mention out-of-scope work; don't balloon the change.
- **Measured beats reasoned.** When a claim about the client can be checked in game, check it —
  the probe issue (#2) exists for exactly this.
- **Never write into another repo** (AltStable, AltStableCompanion, LibGlass, LibAccountSync) from
  this session; file an issue there only with the owner's OK.

## Git conventions

- Branch off `main` per issue (`m1/vertical-slice`). Never commit directly to `main`. Commit or push
  only when asked.
- Short imperative subject; end with the `Co-Authored-By:` trailer for the model that did the work.
- Open the PR with `Closes #N`, run the Codex review per `docs/WORKFLOW.md`, then **wait for the
  owner's approval to merge**.

## Cost control & model usage

- Prefer inline tools over subagents for a codebase this small; cap at ~2 subagents per turn.
- *Haiku:* file-finding, rote edits, deploy. *Sonnet:* routine modules, UI plumbing, tests.
  *Opus:* the apply engine, backup/restore, macro reindexing, binding sets, the quarantine, the
  transfer script — anything that writes game state or SavedVariables shape.
